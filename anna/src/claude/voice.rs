//! Speaking to the pilot.
//!
//! One trigger (`anna voice`, a key bound to it, the FIFO's `voix`, or the
//! dock's 🎙) starts listening; the end of speech stops it — or the same
//! trigger again. Like Claude Code's own dictation, the transcript shows up
//! while the user speaks: the recording so far is transcribed again every
//! half second by a warm whisper.cpp server (whisper.rs). At the end, the
//! whole is transcribed once more and either handed to the pilot (Super+V)
//! or left in the dock's input field to read over (the dock's 🎙). Nothing
//! leaves the machine but the transcript.
//!
//!   idle → listening → transcribing → idle
//!
//! The end of speech is found on the signal's energy: the first moments set
//! the room's noise floor, speech is what rises clearly above it, and a
//! long-enough silence after speech ends the turn. Simple, and enough for a
//! request said into a laptop or a desk microphone.
//!
//! The model is a whisper.cpp ggml file: `ANNA_WHISPER_MODEL`, else
//! `~/.local/share/anna/whisper/ggml-small.bin` (the NixOS configuration
//! links it there).

use super::pilot::Pilot;
use super::whisper;
use serde_json::json;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::broadcast;

/// Analysis frame (seconds).
const FRAME: f32 = 0.03;
/// The noise floor is measured over the first frames.
const NOISE_FRAMES: usize = 10;
/// Speech starts after this many loud frames in a row…
const SPEECH_FRAMES: usize = 3;
/// …and ends after this much silence.
const END_SILENCE: f32 = 1.2;
/// Give up if nothing is said within this time…
const NO_SPEECH: f32 = 6.0;
/// …and never record longer than this.
const MAX_LEN: f32 = 30.0;
/// Push-to-talk ends with the key, or after this long.
const HOLD_MAX: f32 = 120.0;
/// Whisper's input rate.
const WHISPER_RATE: u32 = 16_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Listening,
    Transcribing,
}

impl Phase {
    fn as_str(self) -> &'static str {
        match self {
            Phase::Idle => "idle",
            Phase::Listening => "listening",
            Phase::Transcribing => "transcribing",
        }
    }
}

/// Where a recording stands, frame after frame.
#[derive(Debug, PartialEq)]
pub enum Endpoint {
    /// Keep listening.
    More,
    /// The speech is over: keep what was recorded.
    Done,
    /// Nothing was said.
    Nothing,
}

/// Energy-based end-of-speech detection.
pub struct Endpointer {
    noise: Vec<f32>,
    threshold: f32,
    loud_run: usize,
    speaking: bool,
    silence: f32,
    elapsed: f32,
}

impl Default for Endpointer {
    fn default() -> Self {
        Endpointer {
            noise: Vec::new(),
            threshold: 0.0,
            loud_run: 0,
            speaking: false,
            silence: 0.0,
            elapsed: 0.0,
        }
    }
}

fn rms(frame: &[f32]) -> f32 {
    if frame.is_empty() {
        return 0.0;
    }
    (frame.iter().map(|s| s * s).sum::<f32>() / frame.len() as f32).sqrt()
}

impl Endpointer {
    /// Feed one frame (FRAME seconds); says whether to go on.
    pub fn feed(&mut self, frame: &[f32]) -> Endpoint {
        let level = rms(frame);
        self.elapsed += FRAME;
        if self.noise.len() < NOISE_FRAMES {
            self.noise.push(level);
            if self.noise.len() == NOISE_FRAMES {
                let mut n = self.noise.clone();
                n.sort_by(|a, b| a.total_cmp(b));
                // Well above the room, never so low that hiss counts.
                self.threshold = (n[NOISE_FRAMES / 2] * 3.5).max(0.012);
            }
            return Endpoint::More;
        }
        if level > self.threshold {
            self.loud_run += 1;
            self.silence = 0.0;
            if self.loud_run >= SPEECH_FRAMES {
                self.speaking = true;
            }
        } else {
            self.loud_run = 0;
            self.silence += FRAME;
        }
        if self.speaking && self.silence >= END_SILENCE {
            return Endpoint::Done;
        }
        if !self.speaking && self.elapsed >= NO_SPEECH {
            return Endpoint::Nothing;
        }
        if self.elapsed >= MAX_LEN {
            return if self.speaking {
                Endpoint::Done
            } else {
                Endpoint::Nothing
            };
        }
        Endpoint::More
    }

    /// Whether speech has been heard so far.
    pub fn heard_speech(&self) -> bool {
        self.speaking
    }

    /// How loud the last frame was relative to speech, 0–1, for the bar.
    pub fn meter(frame: &[f32]) -> f32 {
        (rms(frame) * 12.0).min(1.0)
    }
}

/// Linear resampling to Whisper's 16 kHz.
pub fn resample(input: &[f32], from: u32) -> Vec<f32> {
    resample_rate(input, from, WHISPER_RATE)
}

/// Linear resampling between any two rates.
pub fn resample_rate(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    if from == to || input.is_empty() {
        return input.to_vec();
    }
    let ratio = from as f64 / to as f64;
    let n = (input.len() as f64 / ratio) as usize;
    (0..n)
        .map(|i| {
            let x = i as f64 * ratio;
            let i0 = x.floor() as usize;
            let i1 = (i0 + 1).min(input.len() - 1);
            let t = (x - i0 as f64) as f32;
            input[i0] * (1.0 - t) + input[i1] * t
        })
        .collect()
}

/// 16-bit mono PCM WAV.
pub fn wav(samples: &[f32], rate: u32) -> Vec<u8> {
    let data_len = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data_len as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_len).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        let v = (s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

/// A 16-bit PCM WAV as mono samples and its rate (channels are mixed down).
pub fn read_wav(bytes: &[u8]) -> Option<(Vec<f32>, u32)> {
    if bytes.len() < 12 || &bytes[..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return None;
    }
    let (mut channels, mut rate, mut bits) = (0u16, 0u32, 0u16);
    let mut at = 12;
    while at + 8 <= bytes.len() {
        let id = &bytes[at..at + 4];
        let len = u32::from_le_bytes(bytes[at + 4..at + 8].try_into().ok()?) as usize;
        let body = bytes.get(at + 8..(at + 8 + len).min(bytes.len()))?;
        if id == b"fmt " && body.len() >= 16 {
            channels = u16::from_le_bytes(body[2..4].try_into().ok()?);
            rate = u32::from_le_bytes(body[4..8].try_into().ok()?);
            bits = u16::from_le_bytes(body[14..16].try_into().ok()?);
        } else if id == b"data" {
            if bits != 16 || channels == 0 {
                return None;
            }
            let frame = 2 * channels as usize;
            let samples = body
                .chunks_exact(frame)
                .map(|f| {
                    f.as_chunks::<2>()
                        .0
                        .iter()
                        .map(|s| i16::from_le_bytes(*s) as f32 / i16::MAX as f32)
                        .sum::<f32>()
                        / channels as f32
                })
                .collect();
            return Some((samples, rate));
        }
        at += 8 + len + (len & 1);
    }
    None
}

pub fn model_path() -> PathBuf {
    std::env::var_os("ANNA_WHISPER_MODEL")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            crate::paths::home_dir().join(".local/share/anna/whisper/ggml-small.bin")
        })
}

/// What Whisper is known to "hear" in silence or noise — credits from the
/// subtitles it was trained on. Never a request.
const HALLUCINATIONS: [&str; 6] = [
    "sous-titres réalisés par",
    "sous-titrage",
    "amara.org",
    "merci d'avoir regardé",
    "abonnez-vous",
    "vocabulaire :",
];

/// whisper.cpp's text output, joined into one request. Its markers for
/// non-speech (`[BLANK_AUDIO]`, `(musique)`…) and its known hallucinations
/// are dropped.
pub fn clean_transcript(raw: &str) -> String {
    let text = clean_lines(raw);
    let low = text.to_lowercase();
    if HALLUCINATIONS.iter().any(|h| low.contains(h)) {
        return String::new();
    }
    text
}

fn clean_lines(raw: &str) -> String {
    let mut out = String::new();
    for line in raw.lines() {
        let l = line.trim();
        let l = if l.starts_with('[') && l.contains(']') && l.contains("-->") {
            l.split_once(']').map(|x| x.1.trim()).unwrap_or(l)
        } else {
            l
        };
        let spoken = (l.starts_with('[') && l.ends_with(']'))
            || (l.starts_with('(') && l.ends_with(')'))
            || (l.len() > 1 && l.starts_with('*') && l.ends_with('*'));
        if l.is_empty() || spoken {
            continue;
        }
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(l);
    }
    out
}

/// Lowercase, without accents, « c » written « k »: how « Karénine » is
/// compared with whatever Whisper wrote for it.
fn fold(word: &str) -> String {
    word.to_lowercase()
        .chars()
        .map(|c| match c {
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'à' | 'â' | 'ä' => 'a',
            'î' | 'ï' => 'i',
            'ô' | 'ö' => 'o',
            'ù' | 'û' | 'ü' => 'u',
            'c' => 'k',
            c => c,
        })
        .collect()
}

fn levenshtein(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut row: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut prev = row[0];
        row[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cur = row[j + 1];
            row[j + 1] = (row[j + 1] + 1)
                .min(row[j] + 1)
                .min(prev + (ca != *cb) as usize);
            prev = cur;
        }
    }
    row[b.len()]
}

/// The request after « Karénine », if the transcript starts with it (as
/// Whisper writes it: Karénine, Karenin, Carénine…). Its neighbours —
/// Karine, Catherine, Lénine — don't count.
pub fn strip_wake(text: &str) -> Option<String> {
    let t = text.trim_start();
    let end = t
        .find(|c: char| !c.is_alphabetic() && c != '-')
        .unwrap_or(t.len());
    let word = fold(&t[..end]);
    let near = ["karenine", "karenin"]
        .iter()
        .any(|w| levenshtein(&word, w) <= 2);
    let neighbour = ["karine", "karin", "korinne", "katherine", "karen"].contains(&word.as_str());
    if !(word.starts_with('k') || word.starts_with('g')) || word.len() < 6 || !near || neighbour {
        return None;
    }
    let rest = t[end..].trim_start_matches(|c: char| !c.is_alphanumeric());
    let mut chars = rest.chars();
    Some(match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    })
}

/// Words Whisper can't guess the spelling of: the project names, and the
/// tools the pilot is asked about. Given as its initial prompt, they steer
/// "Carnine" back to "karenine" and "Z" to "Zed".
pub fn vocabulary() -> String {
    let mut words: Vec<String> = super::runner::projects()
        .into_iter()
        .map(|p| p.name)
        .filter(|n| n != "recherche")
        .collect();
    words.extend(
        [
            "Zed",
            "anna",
            "dock",
            "Claude",
            "Obsidian",
            "Hyprland",
            "NixOS",
            "worktree",
            "workspace",
        ]
        .map(String::from),
    );
    format!("Vocabulaire : {}.", words.join(", "))
}

/// Transcribe a WAV file with whisper.cpp, in French.
pub fn transcribe(wav_path: &std::path::Path) -> Result<String, String> {
    let model = model_path();
    if !model.is_file() {
        return Err(format!("modèle Whisper absent : {}", model.display()));
    }
    let threads = std::thread::available_parallelism()
        .map(|n| n.get().min(8))
        .unwrap_or(4)
        .to_string();
    let out = std::process::Command::new("whisper-cli")
        .arg("-m")
        .arg(&model)
        .args([
            "-l",
            "fr",
            "-nt",
            "-np",
            "-t",
            &threads,
            "--prompt",
            &vocabulary(),
            "-f",
        ])
        .arg(wav_path)
        .output()
        .map_err(|e| format!("whisper-cli : {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr)
            .lines()
            .last()
            .unwrap_or("whisper-cli a échoué")
            .to_string());
    }
    Ok(clean_transcript(&String::from_utf8_lossy(&out.stdout)))
}

/// While speech goes on, the recording is transcribed again this often.
const PARTIAL_EVERY: Duration = Duration::from_millis(500);

pub struct Voice {
    phase: Mutex<Phase>,
    level: Mutex<f32>,
    /// What was understood so far (while listening) or in the end.
    text: Mutex<String>,
    /// `text` is a live, partial transcript.
    partial: AtomicBool,
    error: Mutex<String>,
    /// Hand the transcript to the pilot (`anna voice`, Super+V), or only
    /// show it (the dock's 🎙 fills its input field with it).
    send: AtomicBool,
    /// Push-to-talk (the dock's held Space): only the release ends the
    /// recording, whatever the silences.
    hold: AtomicBool,
    /// Listening for « Karénine » (wake.rs).
    wake: AtomicBool,
    /// The current turn was started by the wake word, whose audio is
    /// `preroll` (samples, rate) until the recording takes it.
    woken: AtomicBool,
    preroll: Mutex<Option<(Vec<f32>, u32)>>,
    /// For handing transcripts to the pilot from plain threads.
    rt: tokio::runtime::Handle,
    /// Set to end the current recording now.
    stop: Arc<AtomicBool>,
    /// The warm whisper.cpp server, when running (whisper.rs).
    server: Arc<Mutex<Option<whisper::Server>>>,
    starting: Arc<AtomicBool>,
    tx: broadcast::Sender<String>,
    pilot: Arc<Pilot>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Voice {
    pub fn new(pilot: Arc<Pilot>) -> Arc<Self> {
        let (tx, _) = broadcast::channel(64);
        let me = Arc::new(Voice {
            phase: Mutex::new(Phase::Idle),
            level: Mutex::new(0.0),
            text: Mutex::new(String::new()),
            partial: AtomicBool::new(false),
            error: Mutex::new(String::new()),
            send: AtomicBool::new(true),
            hold: AtomicBool::new(false),
            wake: AtomicBool::new(super::wake::remembered()),
            woken: AtomicBool::new(false),
            preroll: Mutex::new(None),
            rt: tokio::runtime::Handle::current(),
            stop: Arc::new(AtomicBool::new(false)),
            server: Arc::new(Mutex::new(None)),
            starting: Arc::new(AtomicBool::new(false)),
            tx,
            pilot,
        });
        // An idle server lets the GPU sleep.
        let weak = Arc::downgrade(&me);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(60));
            loop {
                tick.tick().await;
                let Some(me) = weak.upgrade() else { break };
                let mut slot = lock(&me.server);
                if slot
                    .as_ref()
                    .is_some_and(|s| s.last_use.elapsed() > whisper::IDLE)
                {
                    *slot = None;
                }
            }
        });
        // The wake word, for the daemon's lifetime (idle while off).
        let w = Arc::clone(&me);
        std::thread::spawn(move || super::wake::listen(w));
        me
    }

    pub fn snapshot_line(&self) -> String {
        json!({ "voice": {
            "phase": lock(&self.phase).as_str(),
            "level": *lock(&self.level),
            "text": *lock(&self.text),
            "partial": self.partial.load(Ordering::SeqCst),
            "send": self.send.load(Ordering::SeqCst),
            "wake": self.wake.load(Ordering::SeqCst),
            "error": *lock(&self.error),
        }})
        .to_string()
    }

    fn publish(&self) {
        let _ = self.tx.send(self.snapshot_line());
    }

    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.tx.subscribe()
    }

    fn set_phase(&self, p: Phase) {
        *lock(&self.phase) = p;
        if p != Phase::Listening {
            *lock(&self.level) = 0.0;
        }
        self.publish();
    }

    /// Start listening, or — while listening — end the recording now.
    /// `send`: give the transcript to the pilot, or only show it.
    pub fn toggle(self: &Arc<Self>, send: bool) {
        let phase = *lock(&self.phase);
        match phase {
            Phase::Idle => self.start(send, false),
            Phase::Listening => self.stop.store(true, Ordering::SeqCst),
            Phase::Transcribing => {}
        }
    }

    /// Push-to-talk: record while the key is held, until `release`. The
    /// transcript is only shown (the dock puts it in its input field).
    pub fn hold(self: &Arc<Self>) {
        self.start(false, true);
    }

    /// The held key is released: end the recording (if there is one).
    pub fn release(&self) {
        if *lock(&self.phase) == Phase::Listening {
            self.stop.store(true, Ordering::SeqCst);
        }
    }

    /// Have the warm server running (start it in the background if not).
    fn warm(&self) {
        let model = model_path();
        if !model.is_file() || self.starting.swap(true, Ordering::SeqCst) {
            return;
        }
        {
            let mut slot = lock(&self.server);
            if slot.as_mut().is_some_and(|s| s.alive()) {
                self.starting.store(false, Ordering::SeqCst);
                return;
            }
            *slot = None;
        }
        let server = Arc::clone(&self.server);
        let starting = Arc::clone(&self.starting);
        std::thread::spawn(move || {
            match whisper::Server::start(&model, &vocabulary()) {
                Ok(s) => *lock(&server) = Some(s),
                Err(e) => eprintln!("anna: voix : {e}"),
            }
            starting.store(false, Ordering::SeqCst);
        });
    }

    /// Transcribe with the warm server if it is up. `None`: it isn't.
    fn transcribe_warm(&self, samples: &[f32], rate: u32) -> Option<Result<String, String>> {
        let mut slot = lock(&self.server);
        let server = slot.as_mut()?;
        Some(server.transcribe(&wav(&resample(samples, rate), WHISPER_RATE)))
    }

    /// Enter listening (false if a turn is already under way).
    fn begin(&self, send: bool, hold: bool) -> bool {
        {
            let mut p = lock(&self.phase);
            if *p != Phase::Idle {
                return false;
            }
            *p = Phase::Listening;
        }
        self.stop.store(false, Ordering::SeqCst);
        self.send.store(send, Ordering::SeqCst);
        self.hold.store(hold, Ordering::SeqCst);
        self.partial.store(false, Ordering::SeqCst);
        lock(&self.error).clear();
        lock(&self.text).clear();
        self.publish();
        self.warm();
        true
    }

    /// The turn is over: show its transcript, and hand it to the pilot if
    /// asked to.
    fn finish(
        self: &Arc<Self>,
        result: Result<Option<String>, String>,
        handle: &tokio::runtime::Handle,
    ) {
        self.partial.store(false, Ordering::SeqCst);
        // Started by the wake word: Whisper must have heard it first, or the
        // detector was wrong and the turn ends in silence.
        let result = if self.woken.swap(false, Ordering::SeqCst) {
            match result {
                Ok(Some(text)) => match strip_wake(&text) {
                    Some(rest) => Ok(Some(rest)),
                    None => {
                        eprintln!("anna: mot d'activation non confirmé : « {text} »");
                        lock(&self.text).clear();
                        self.set_phase(Phase::Idle);
                        return;
                    }
                },
                Ok(None) => {
                    lock(&self.text).clear();
                    self.set_phase(Phase::Idle);
                    return;
                }
                Err(e) => Err(e),
            }
        } else {
            result
        };
        match result {
            Ok(Some(text)) if !text.is_empty() => {
                *lock(&self.text) = text.clone();
                self.set_phase(Phase::Idle);
                if self.send.load(Ordering::SeqCst) {
                    let me = Arc::clone(self);
                    handle.spawn(async move {
                        if let Err(e) = me.pilot.ask(&text, false).await {
                            *lock(&me.error) = e;
                            me.publish();
                        }
                    });
                }
            }
            Ok(_) => {
                lock(&self.text).clear();
                *lock(&self.error) = "rien entendu".into();
                self.set_phase(Phase::Idle);
            }
            Err(e) => {
                *lock(&self.error) = e;
                self.set_phase(Phase::Idle);
            }
        }
    }

    pub fn start(self: &Arc<Self>, send: bool, hold: bool) {
        if !self.begin(send, hold) {
            return;
        }
        self.spawn_record();
    }

    /// « Karénine » was heard (wake.rs): listen to the request, with the
    /// word's audio in front so that Whisper confirms it.
    pub fn woken(self: &Arc<Self>, preroll: Vec<f32>, rate: u32) {
        if !self.begin(true, false) {
            return;
        }
        self.woken.store(true, Ordering::SeqCst);
        *lock(&self.preroll) = Some((preroll, rate));
        self.spawn_record();
    }

    fn spawn_record(self: &Arc<Self>) {
        let me = Arc::clone(self);
        let handle = self.rt.clone();
        std::thread::spawn(move || {
            let result = me.record();
            me.finish(result, &handle);
        });
    }

    /// A turn is under way (listening or transcribing).
    pub fn busy(&self) -> bool {
        *lock(&self.phase) != Phase::Idle
    }

    pub fn wake_on(&self) -> bool {
        self.wake.load(Ordering::SeqCst)
    }

    /// Turn the wake word on or off (and remember it).
    pub fn set_wake(&self, on: bool) {
        self.wake.store(on, Ordering::SeqCst);
        super::wake::remember(on);
        lock(&self.error).clear();
        self.publish();
    }

    /// The wake word can't run (models, microphone): off until asked again.
    pub fn wake_failed(&self, error: String) {
        eprintln!("anna: {error}");
        self.wake.store(false, Ordering::SeqCst);
        *lock(&self.error) = error;
        self.publish();
    }

    /// Play a recording through the listening loop in real time, as if said
    /// into the microphone: the same end-of-speech detection, live
    /// transcript and outcome. For trying the whole path without speaking.
    pub fn simulate(self: &Arc<Self>, samples: Vec<f32>, rate: u32, send: bool, hold: bool) {
        if !self.begin(send, hold) {
            return;
        }
        let me = Arc::clone(self);
        let handle = self.rt.clone();
        std::thread::spawn(move || {
            let chunk = (rate as f32 * FRAME) as usize;
            // A quiet room first (the noise floor), then the recording,
            // then silence until the end of speech is found.
            let mut feed: Vec<f32> = (0..rate as usize * 2 / 5)
                .map(|i| 0.002 * (i as f32 * 0.7).sin())
                .collect();
            feed.extend(samples);
            let mut at = 0usize;
            let result = me.listen(rate, Vec::new(), || {
                std::thread::sleep(Duration::from_secs_f32(FRAME));
                let piece = if at < feed.len() {
                    feed[at..(at + chunk).min(feed.len())].to_vec()
                } else {
                    vec![0.0; chunk]
                };
                at += chunk;
                Ok(Some(piece))
            });
            me.finish(result, &handle);
        });
    }

    /// Record until the end of speech, showing the transcript as it comes,
    /// then transcribe the whole. `None`: nothing said.
    fn record(&self) -> Result<Option<String>, String> {
        let (capture, rx) = crate::audio::start_voice_capture()?;
        let rate = capture.sample_rate;
        // The wake word's audio, if it started the turn.
        let preroll = lock(&self.preroll)
            .take()
            .map(|(p, from)| resample_rate(&p, from, rate))
            .unwrap_or_default();
        let result = self.listen(rate, preroll, || {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(c) => Ok(Some(c)),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Ok(None),
                Err(_) => Err("le micro s'est fermé".into()),
            }
        });
        drop(capture);
        result
    }

    /// The listening loop, fed by `next` — the microphone, or a file played
    /// in real time (`simulate`). `Ok(None)` from `next` means "nothing yet".
    /// `preroll`: audio from before the turn (the wake word), transcribed
    /// with the rest but kept out of the end-of-speech detection.
    fn listen(
        &self,
        rate: u32,
        preroll: Vec<f32>,
        mut next: impl FnMut() -> Result<Option<Vec<f32>>, String>,
    ) -> Result<Option<String>, String> {
        let frame_len = (rate as f32 * FRAME) as usize;
        let mut ep = Endpointer::default();
        let mut all: Vec<f32> = preroll;
        let mut pending: Vec<f32> = Vec::new();
        let mut frames = 0usize;
        let mut last_partial = Instant::now();
        let hold = self.hold.load(Ordering::SeqCst);
        // Started by the wake word: its first transcript must begin with
        // « Karénine », or the detector was wrong and the turn stops there.
        let woken = self.woken.load(Ordering::SeqCst);
        let mut confirmed = false;
        let outcome = 'listen: loop {
            if self.stop.load(Ordering::SeqCst) {
                // Stopped by hand: only what followed real speech counts.
                // A held key marks speech itself (one speaks at once, so
                // the room noise is never measured).
                break if (hold || ep.heard_speech()) && all.len() > rate as usize / 2 {
                    Endpoint::Done
                } else {
                    Endpoint::Nothing
                };
            }
            let Some(chunk) = next()? else {
                continue;
            };
            all.extend_from_slice(&chunk);
            pending.extend_from_slice(&chunk);
            while pending.len() >= frame_len {
                let frame: Vec<f32> = pending.drain(..frame_len).collect();
                frames += 1;
                // The bar's meter, a few times a second.
                if frames.is_multiple_of(3) {
                    *lock(&self.level) = Endpointer::meter(&frame);
                    self.publish();
                }
                match ep.feed(&frame) {
                    Endpoint::More => {}
                    // Key held: silences are pauses; only a runaway hold ends.
                    _ if hold && (all.len() as f32) < rate as f32 * HOLD_MAX => {}
                    end => break 'listen end,
                }
            }
            // The transcript so far. Audio arriving meanwhile waits in the
            // capture channel: nothing is lost, the pass is just late.
            if (hold || woken || ep.heard_speech()) && last_partial.elapsed() >= PARTIAL_EVERY {
                if let Some(Ok(text)) = self.transcribe_warm(&all, rate) {
                    // The wake word isn't part of the request.
                    let text = match (woken, strip_wake(&text)) {
                        (true, Some(rest)) => {
                            confirmed = true;
                            rest
                        }
                        (true, None) if !confirmed && !text.is_empty() => {
                            eprintln!("anna: mot d'activation non confirmé : « {text} »");
                            return Ok(None);
                        }
                        _ => text,
                    };
                    if !text.is_empty() {
                        *lock(&self.text) = text;
                        self.partial.store(true, Ordering::SeqCst);
                        self.publish();
                    }
                }
                last_partial = Instant::now();
            }
        };
        if outcome == Endpoint::Nothing {
            return Ok(None);
        }

        self.set_phase(Phase::Transcribing);
        // A server still starting is worth waiting for: it is faster than
        // a cold whisper-cli run.
        let deadline = Instant::now() + Duration::from_secs(45);
        while self.starting.load(Ordering::SeqCst) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        if let Some(result) = self.transcribe_warm(&all, rate) {
            return result.map(Some);
        }
        let path = std::env::temp_dir().join(format!("anna-voix-{}.wav", std::process::id()));
        std::fs::write(&path, wav(&resample(&all, rate), WHISPER_RATE))
            .map_err(|e| format!("enregistrement : {e}"))?;
        let text = transcribe(&path);
        let _ = std::fs::remove_file(&path);
        text.map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(amplitude: f32) -> Vec<f32> {
        let n = (16_000.0 * FRAME) as usize;
        (0..n).map(|i| amplitude * (i as f32 * 0.3).sin()).collect()
    }

    fn run(script: &[(f32, usize)]) -> Endpoint {
        let mut ep = Endpointer::default();
        for &(amp, count) in script {
            for _ in 0..count {
                match ep.feed(&frame(amp)) {
                    Endpoint::More => {}
                    end => return end,
                }
            }
        }
        Endpoint::More
    }

    #[test]
    fn speech_then_silence_ends_the_turn() {
        // Room noise, two seconds of speech, then quiet.
        assert_eq!(run(&[(0.002, 20), (0.2, 66), (0.002, 60)]), Endpoint::Done);
    }

    #[test]
    fn short_pauses_do_not_cut_a_sentence() {
        // A half-second pause in the middle is not the end.
        assert_eq!(
            run(&[(0.002, 20), (0.2, 30), (0.002, 16), (0.2, 30)]),
            Endpoint::More
        );
    }

    #[test]
    fn silence_alone_gives_up() {
        assert_eq!(run(&[(0.002, 400)]), Endpoint::Nothing);
        // A click (two loud frames) is not speech.
        assert_eq!(
            run(&[(0.002, 20), (0.3, 2), (0.002, 400)]),
            Endpoint::Nothing
        );
    }

    #[test]
    fn resampling_keeps_duration() {
        let one_second: Vec<f32> = vec![0.1; 48_000];
        assert_eq!(resample(&one_second, 48_000).len(), 16_000);
        assert_eq!(resample(&[0.5; 160], 16_000).len(), 160);
    }

    #[test]
    fn wav_round_trips() {
        let (samples, rate) = read_wav(&wav(&[0.0, 0.5, -0.5], 16_000)).unwrap();
        assert_eq!(rate, 16_000);
        assert_eq!(samples.len(), 3);
        assert!((samples[1] - 0.5).abs() < 0.001 && (samples[2] + 0.5).abs() < 0.001);
        assert!(read_wav(b"not a wav").is_none());
    }

    #[test]
    fn wav_header_is_valid() {
        let w = wav(&[0.0, 0.5, -0.5], 16_000);
        assert_eq!(&w[..4], b"RIFF");
        assert_eq!(&w[8..16], b"WAVEfmt ");
        assert_eq!(u32::from_le_bytes(w[24..28].try_into().unwrap()), 16_000);
        assert_eq!(u32::from_le_bytes(w[40..44].try_into().unwrap()), 6);
        assert_eq!(w.len(), 44 + 6);
    }

    #[test]
    fn transcripts_drop_non_speech_markers() {
        assert_eq!(clean_transcript(" Baisse le son.\n"), "Baisse le son.");
        assert_eq!(clean_transcript("[BLANK_AUDIO]\n"), "");
        assert_eq!(clean_transcript("(musique)\n Ouvre Zed.\n"), "Ouvre Zed.");
        assert_eq!(
            clean_transcript("[00:00:00.000 --> 00:00:02.000]  Bonjour.\n"),
            "Bonjour."
        );
        // What Whisper "hears" in silence is never a request.
        assert_eq!(
            clean_transcript(" Sous-titres réalisés par la communauté d'Amara.org\n"),
            ""
        );
        assert_eq!(clean_transcript(" Merci d'avoir regardé !\n"), "");
        // Noise it names between asterisks.
        assert_eq!(clean_transcript(" *Bip*\n"), "");
    }

    #[test]
    fn the_wake_word_is_confirmed_and_dropped() {
        assert_eq!(
            strip_wake("Karénine, baisse le son.").as_deref(),
            Some("Baisse le son.")
        );
        // How Whisper writes it without context.
        assert_eq!(
            strip_wake("Karenin. ouvre Zed").as_deref(),
            Some("Ouvre Zed")
        );
        assert_eq!(strip_wake("Carénine !").as_deref(), Some(""));
        // Its neighbours, and a request without it.
        assert_eq!(strip_wake("Karine, tu viens ?"), None);
        assert_eq!(strip_wake("Catherine arrive."), None);
        assert_eq!(strip_wake("Lénine"), None);
        assert_eq!(strip_wake("Arène, baisse le son."), None);
        assert_eq!(strip_wake("Baisse le son."), None);
    }
}
