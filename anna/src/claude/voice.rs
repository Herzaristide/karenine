//! Speaking to the pilot.
//!
//! One trigger (`anna voice`, a key bound to it, the FIFO's `voix`, or the
//! bar's 🎙) starts listening; the end of speech stops it — or the same
//! trigger again. Like Claude Code's own dictation, the transcript shows up
//! while the user speaks: the recording so far is transcribed again every
//! half second by Parakeet, kept loaded (parakeet.rs). At the end, the whole
//! is transcribed once more and either handed to the pilot (Super+V) or only
//! shown (`anna voice dictate`). Nothing leaves the machine but the
//! transcript.
//!
//!   idle → listening → transcribing → idle
//!
//! The end of speech is found on the signal's energy: the first moments set
//! the room's noise floor, speech is what rises clearly above it, and a
//! long-enough silence after speech ends the turn. Simple, and enough for a
//! request said into a laptop or a desk microphone.
//!
//! The model is a directory of ONNX files (parakeet.rs): `ANNA_PARAKEET_MODEL`,
//! else `~/.local/share/anna/parakeet` (the NixOS configuration links it
//! there).

use super::parakeet;
use super::pilot::Pilot;
use super::wake::WakeWord;
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

    /// The last frame fed was speech.
    pub fn in_speech(&self) -> bool {
        self.speaking && self.silence == 0.0
    }

    /// How loud the last frame was relative to speech, 0–1, for the bar.
    pub fn meter(frame: &[f32]) -> f32 {
        (rms(frame) * 12.0).min(1.0)
    }
}

/// Linear resampling to the model's 16 kHz.
pub fn resample(input: &[f32], from: u32) -> Vec<f32> {
    resample_rate(input, from, parakeet::RATE)
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

pub fn model_dir() -> PathBuf {
    std::env::var_os("ANNA_PARAKEET_MODEL")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::paths::home_dir().join(".local/share/anna/parakeet"))
}

fn load_model() -> Result<parakeet::Model, String> {
    let dir = model_dir();
    if !dir.join("encoder-model.int8.onnx").is_file() {
        return Err(crate::i18n::tr_args(
            "voice.no_model",
            &[("path", &dir.display().to_string())],
        ));
    }
    parakeet::Model::load(&dir)
}

/// Lowercase, without accents, « c » written « k »: how the wake word is
/// compared with whatever the model wrote for it.
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

/// The request after the wake word of this machine, if the transcript starts
/// with it.
pub fn strip_wake(text: &str) -> Option<String> {
    strip_word(text, WakeWord::current())
}

/// The request after `wake`, if the transcript starts with it, however the
/// model wrote it (Karénine, Carénine, Exu Péry…): its first one to three
/// words, if only spaces part them, joined and within two letters of one of
/// its `near` forms, but none of its `neighbours` (Karine, Catherine) nor a
/// word starting otherwise (Lénine).
fn strip_word(text: &str, wake: &WakeWord) -> Option<String> {
    let t = text.trim_start();
    let shortest = wake
        .near
        .iter()
        .map(|w| w.chars().count())
        .min()
        .unwrap_or(0);
    // Where each of the first words ends; punctuation ends the name.
    let mut ends = Vec::new();
    let mut at = 0;
    while ends.len() < 3 {
        let rest = &t[at..];
        let len = rest
            .find(|c: char| !c.is_alphabetic() && c != '-')
            .unwrap_or(rest.len());
        if len == 0 {
            break;
        }
        at += len;
        ends.push(at);
        let gap = t[at..].len() - t[at..].trim_start_matches(' ').len();
        if gap == 0 {
            break;
        }
        at += gap;
    }
    let first = fold(&t[..*ends.first()?]);
    if wake.neighbours.contains(&first)
        || !first
            .chars()
            .next()
            .is_some_and(|c| wake.initials.contains(&c))
    {
        return None;
    }
    let end = ends.into_iter().find(|&end| {
        let word: String = fold(&t[..end]).chars().filter(|c| *c != ' ').collect();
        word.chars().count() + 1 >= shortest && wake.near.iter().any(|w| levenshtein(&word, w) <= 2)
    })?;
    let rest = t[end..].trim_start_matches(|c: char| !c.is_alphanumeric());
    let mut chars = rest.chars();
    Some(match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    })
}

/// Transcribe a 16-bit WAV file, loading the model for it.
pub fn transcribe(wav_path: &std::path::Path) -> Result<String, String> {
    let bytes = std::fs::read(wav_path).map_err(|e| format!("{} : {e}", wav_path.display()))?;
    let (samples, rate) = read_wav(&bytes)
        .ok_or_else(|| format!("WAV 16 bits illisible : {}", wav_path.display()))?;
    load_model()?.transcribe(&resample(&samples, rate))
}

/// While speech goes on, the recording is transcribed again this often.
const PARTIAL_EVERY: Duration = Duration::from_millis(500);
/// A partial transcript made this long after the last loud frame (a word's
/// soft ending stays under the threshold) already holds the whole request:
/// it is kept as the final one instead of transcribing everything again.
const FINAL_MARGIN: f32 = 0.4;

pub struct Voice {
    phase: Mutex<Phase>,
    level: Mutex<f32>,
    /// What was understood so far (while listening) or in the end.
    text: Mutex<String>,
    /// `text` is a live, partial transcript.
    partial: AtomicBool,
    error: Mutex<String>,
    /// Hand the transcript to the pilot (`anna voice`, Super+V), or only
    /// show it (`anna voice dictate`).
    send: AtomicBool,
    /// Listening for the wake word (wake.rs).
    wake: AtomicBool,
    /// The current turn was started by the wake word, whose audio is
    /// `preroll` (samples, rate) until the recording takes it.
    woken: AtomicBool,
    preroll: Mutex<Option<(Vec<f32>, u32)>>,
    /// For handing transcripts to the pilot from plain threads.
    rt: tokio::runtime::Handle,
    /// Set to end the current recording now.
    stop: Arc<AtomicBool>,
    /// The model, while loaded (parakeet.rs).
    model: Arc<Mutex<Option<parakeet::Model>>>,
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
            wake: AtomicBool::new(super::wake::remembered()),
            woken: AtomicBool::new(false),
            preroll: Mutex::new(None),
            rt: tokio::runtime::Handle::current(),
            stop: Arc::new(AtomicBool::new(false)),
            model: Arc::new(Mutex::new(None)),
            starting: Arc::new(AtomicBool::new(false)),
            tx,
            pilot,
        });
        // An idle model gives its memory back.
        let weak = Arc::downgrade(&me);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(60));
            loop {
                tick.tick().await;
                let Some(me) = weak.upgrade() else { break };
                let mut slot = lock(&me.model);
                if slot
                    .as_ref()
                    .is_some_and(|s| s.last_use.elapsed() > parakeet::IDLE)
                {
                    *slot = None;
                }
            }
        });
        // The speech's settings and errors are shown with the voice's.
        let weak = Arc::downgrade(&me);
        let mut changed = me.pilot.speech().subscribe();
        tokio::spawn(async move {
            while let Ok(()) | Err(broadcast::error::RecvError::Lagged(_)) = changed.recv().await {
                let Some(me) = weak.upgrade() else { break };
                me.publish();
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
            "wakeWord": WakeWord::current().display,
            "error": *lock(&self.error),
            // Reading the answers aloud (speech.rs), for the settings.
            "speech": self.pilot.speech().state(),
        }})
        .to_string()
    }

    pub fn publish(&self) {
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
            Phase::Idle => self.start(send),
            Phase::Listening => self.stop.store(true, Ordering::SeqCst),
            Phase::Transcribing => {}
        }
    }

    /// Have the model loaded (load it in the background if not).
    fn warm(&self) {
        if lock(&self.model).is_some() || self.starting.swap(true, Ordering::SeqCst) {
            return;
        }
        let slot = Arc::clone(&self.model);
        let starting = Arc::clone(&self.starting);
        std::thread::spawn(move || {
            match load_model() {
                Ok(m) => *lock(&slot) = Some(m),
                Err(e) => eprintln!("anna: voix : {e}"),
            }
            starting.store(false, Ordering::SeqCst);
        });
    }

    /// Transcribe with the loaded model. `None`: it isn't loaded.
    fn transcribe_warm(&self, samples: &[f32], rate: u32) -> Option<Result<String, String>> {
        let mut slot = lock(&self.model);
        let model = slot.as_mut()?;
        Some(model.transcribe(&resample(samples, rate)))
    }

    /// Enter listening (false if a turn is already under way).
    fn begin(&self, send: bool) -> bool {
        {
            let mut p = lock(&self.phase);
            if *p != Phase::Idle {
                return false;
            }
            *p = Phase::Listening;
        }
        // Speaking over the answer being read cuts it short.
        self.pilot.speech().stop();
        self.stop.store(false, Ordering::SeqCst);
        self.send.store(send, Ordering::SeqCst);
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
        // Started by the wake word: the model must have heard it first, or the
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
                        if let Err(e) = me.pilot.ask(&text, false, true).await {
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

    pub fn start(self: &Arc<Self>, send: bool) {
        if !self.begin(send) {
            return;
        }
        self.spawn_record();
    }

    /// The wake word was heard (wake.rs): listen to the request, with the
    /// word's audio in front so that the transcript confirms it.
    pub fn woken(self: &Arc<Self>, preroll: Vec<f32>, rate: u32) {
        if !self.begin(true) {
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
    pub fn simulate(self: &Arc<Self>, samples: Vec<f32>, rate: u32, send: bool) {
        if !self.begin(send) {
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
                Err(_) => Err(crate::i18n::tr("voice.mic_closed")),
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
        // Started by the wake word: its first transcript must begin with
        // the wake word, or the detector was wrong and the turn stops there.
        let woken = self.woken.load(Ordering::SeqCst);
        let mut confirmed = false;
        // Where speech was last heard (samples into `all`), and the last
        // partial transcript with how much of `all` it covered.
        let mut speech_end = 0usize;
        let mut last_partial_text: Option<(usize, String)> = None;
        let outcome = 'listen: loop {
            if self.stop.load(Ordering::SeqCst) {
                // Stopped by hand: only what followed real speech counts.
                break if ep.heard_speech() && all.len() > rate as usize / 2 {
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
                let fed = ep.feed(&frame);
                if ep.in_speech() {
                    speech_end = all.len() - pending.len();
                }
                match fed {
                    Endpoint::More => {}
                    end => break 'listen end,
                }
            }
            // The transcript so far. Audio arriving meanwhile waits in the
            // capture channel: nothing is lost, the pass is just late.
            if (woken || ep.heard_speech()) && last_partial.elapsed() >= PARTIAL_EVERY {
                if let Some(Ok(text)) = self.transcribe_warm(&all, rate) {
                    last_partial_text = Some((all.len(), text.clone()));
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

        // The last partial came after the end of speech: it is the final
        // transcript already.
        if let Some((covered, text)) = last_partial_text {
            let margin = (rate as f32 * FINAL_MARGIN) as usize;
            if !text.is_empty() && covered >= speech_end + margin {
                return Ok(Some(text));
            }
        }

        self.set_phase(Phase::Transcribing);
        // A model still loading is waited for; one that failed to load is
        // tried once more, here.
        let deadline = Instant::now() + Duration::from_secs(45);
        while self.starting.load(Ordering::SeqCst) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        if let Some(result) = self.transcribe_warm(&all, rate) {
            return result.map(Some);
        }
        let mut model = load_model()?;
        let text = model.transcribe(&resample(&all, rate));
        *lock(&self.model) = Some(model);
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

    /// A wake word as the package ships it (models/wake/<name>.json).
    fn word(name: &str) -> WakeWord {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("models/wake");
        WakeWord::load(&dir, name)
    }

    #[test]
    fn the_wake_word_is_confirmed_and_dropped() {
        let k = word("karenine");
        assert_eq!(k.display, "Karénine");
        assert_eq!(
            strip_word("Karénine, baisse le son.", &k).as_deref(),
            Some("Baisse le son.")
        );
        // How the model writes it without context.
        assert_eq!(
            strip_word("Karenin. ouvre Zed", &k).as_deref(),
            Some("Ouvre Zed")
        );
        assert_eq!(strip_word("Carénine !", &k).as_deref(), Some(""));
        // Its neighbours, and a request without it.
        assert_eq!(strip_word("Karine, tu viens ?", &k), None);
        assert_eq!(strip_word("Catherine arrive.", &k), None);
        assert_eq!(strip_word("Lénine", &k), None);
        assert_eq!(strip_word("Arène, baisse le son.", &k), None);
        assert_eq!(strip_word("Baisse le son.", &k), None);
    }

    #[test]
    fn each_machine_answers_to_its_name() {
        let b = word("bernanos");
        assert_eq!(
            strip_word("Bernanos, ouvre Zed.", &b).as_deref(),
            Some("Ouvre Zed.")
        );
        assert_eq!(
            strip_word("Bernano ouvre Zed", &b).as_deref(),
            Some("Ouvre Zed")
        );
        assert_eq!(strip_word("Bernard, ouvre Zed.", &b), None);
        assert_eq!(strip_word("Karénine, ouvre Zed.", &b), None);

        let e = word("exupery");
        assert_eq!(e.display, "Exupéry");
        assert_eq!(
            strip_word("Exupéry, baisse le son.", &e).as_deref(),
            Some("Baisse le son.")
        );
        assert_eq!(
            strip_word("Saint-Exupéry, baisse le son.", &e).as_deref(),
            Some("Baisse le son.")
        );
        assert_eq!(strip_word("Bernanos, baisse le son.", &e), None);
        // A name the model splits in two.
        assert_eq!(
            strip_word("Exu Péry, baisse le son.", &e).as_deref(),
            Some("Baisse le son.")
        );
        assert_eq!(strip_word("Exu, baisse le son.", &e), None);

        // Without its JSON, a word is heard only as its name.
        let z = word("absent");
        assert_eq!(z.display, "Absent");
        assert_eq!(
            strip_word("Absent, ouvre Zed", &z).as_deref(),
            Some("Ouvre Zed")
        );
    }
}
