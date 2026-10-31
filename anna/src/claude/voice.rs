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

    /// How long it has been quiet since the last loud frame (seconds).
    pub fn silence(&self) -> f32 {
        self.silence
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

/// Resampling to the model's 16 kHz.
pub fn resample(input: &[f32], from: u32) -> Vec<f32> {
    resample_rate(input, from, parakeet::RATE)
}

/// Resampling between any two rates.
pub fn resample_rate(input: &[f32], from: u32, to: u32) -> Vec<f32> {
    let mut r = Resampler::new(from, to);
    let mut out = Vec::with_capacity((input.len() as u64 * to as u64 / from as u64) as usize);
    r.push(input, &mut out);
    r.finish(&mut out);
    out
}

/// Zero crossings of the sinc on each side of a resampled point.
const SINC_ZEROS: f64 = 8.0;

/// Band-limited resampling (Hann-windowed sinc), fed piece by piece: the
/// microphone's 48 kHz interpolated straight to 16 kHz would fold
/// everything above 8 kHz back over the voice. Only the input still needed
/// is kept.
pub struct Resampler {
    from: u64,
    to: u64,
    /// Cut-off, in cycles per input sample.
    cutoff: f64,
    /// Half the kernel, in input samples.
    half: i64,
    input: Vec<f32>,
    /// Index of `input[0]` since the start.
    base: i64,
    produced: u64,
}

impl Resampler {
    pub fn new(from: u32, to: u32) -> Self {
        let cutoff = 0.5 * (to as f64 / from as f64).min(1.0) * 0.95;
        Resampler {
            from: from as u64,
            to: to as u64,
            cutoff,
            half: (SINC_ZEROS / (2.0 * cutoff)).ceil() as i64,
            input: Vec::new(),
            base: 0,
            produced: 0,
        }
    }

    /// Where output sample `j` falls in the input.
    fn at(&self, j: u64) -> f64 {
        j as f64 * self.from as f64 / self.to as f64
    }

    fn sample(&self, j: u64) -> f32 {
        use std::f64::consts::PI;
        let x = self.at(j);
        let c = x.floor() as i64;
        let (mut acc, mut sum) = (0f64, 0f64);
        for k in (c - self.half + 1).max(self.base)..=(c + self.half) {
            let Some(&v) = self.input.get((k - self.base) as usize) else {
                break;
            };
            let t = x - k as f64;
            let arg = PI * 2.0 * self.cutoff * t;
            let sinc = if arg == 0.0 { 1.0 } else { arg.sin() / arg };
            let w = sinc * (0.5 + 0.5 * (PI * t / self.half as f64).cos());
            acc += v as f64 * w;
            sum += w;
        }
        // Normalised: unity gain, at the edges too.
        if sum == 0.0 {
            0.0
        } else {
            (acc / sum) as f32
        }
    }

    /// Add input; the output samples it completes go to `out`.
    pub fn push(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if self.from == self.to {
            out.extend_from_slice(input);
            return;
        }
        self.input.extend_from_slice(input);
        let end = self.base + self.input.len() as i64;
        while (self.at(self.produced).floor() as i64) + self.half < end {
            out.push(self.sample(self.produced));
            self.produced += 1;
        }
        let keep_from = (self.at(self.produced).floor() as i64 - self.half + 1).max(self.base);
        self.input.drain(..(keep_from - self.base) as usize);
        self.base = keep_from;
    }

    /// The input is over: its last samples, with what there is.
    pub fn finish(&mut self, out: &mut Vec<f32>) {
        if self.from == self.to {
            return;
        }
        let total = (self.base as u64 + self.input.len() as u64) * self.to / self.from;
        while self.produced < total {
            out.push(self.sample(self.produced));
            self.produced += 1;
        }
    }
}

/// 16-bit mono PCM WAV, for the tests.
#[cfg(test)]
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

/// Words the transcript may hold before the wake word: the audio kept from
/// before the detection often starts with the end of something else (« Euh,
/// Exupéry… »).
const WAKE_LEAD: usize = 2;
/// A partial transcript of this many words without the wake word: the
/// detector was wrong. Shorter, the word may be there but not written yet.
const WAKE_GIVE_UP: usize = WAKE_LEAD + 3;

/// The request after the wake word of this machine, if the transcript starts
/// with it.
pub fn strip_wake(text: &str) -> Option<String> {
    strip_word(text, WakeWord::current())
}

/// `text` without its first word, capitalised again.
fn drop_first_word(text: &str) -> String {
    let rest = text
        .trim_start()
        .split_once(char::is_whitespace)
        .map_or("", |(_, r)| r)
        .trim_start_matches(|c: char| !c.is_alphanumeric());
    let mut chars = rest.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// The request after `wake`, if it is among the transcript's first words
/// (`WAKE_LEAD` may come before it).
fn strip_word(text: &str, wake: &WakeWord) -> Option<String> {
    let mut t = text.trim_start();
    for _ in 0..=WAKE_LEAD {
        if let Some(rest) = strip_first(t, wake) {
            return Some(rest);
        }
        // The next word, past its punctuation.
        let end = t.find(char::is_whitespace)?;
        t = t[end..].trim_start();
    }
    None
}

/// The request after `wake`, if `t` starts with it, however the model wrote
/// it (Karénine, Carénine, Exu Péry…): its first one to three words, if only
/// spaces part them, joined and close to one of its `near` forms, but none of its `neighbours` (Karine, Catherine) nor a word
/// starting otherwise (Lénine).
fn strip_first(t: &str, wake: &WakeWord) -> Option<String> {
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
        let len = word.chars().count();
        wake.near.iter().any(|w| {
            let n = w.chars().count();
            // Two letters off for a long form, one for a short one (Expé).
            len + 1 >= n && levenshtein(&word, w) <= if n >= 6 { 2 } else { 1 }
        })
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
/// A transcript that ends a sentence (. ? !) ends the turn after this much
/// silence, instead of END_SILENCE: Parakeet punctuates, and a request said
/// in one go needn't wait as long as one left hanging (« ouvre… euh… »).
const QUICK_END: f32 = 0.5;
/// After this much silence the request is likely over: the pilot's context
/// block is built then, while the transcript is finished.
const CONTEXT_AT: f32 = 0.3;

/// The partial transcript `last` covers the recording up to `end`.
fn covers(last: &Option<(usize, String)>, end: usize) -> bool {
    last.as_ref().is_some_and(|(covered, _)| *covered >= end)
}

/// The request a partial transcript holds ends a sentence.
fn ends_sentence(text: &str) -> bool {
    text.trim_end().ends_with(['.', '?', '!', '…'])
}

/// A partial transcript: how many samples it covered, and the text (`None`:
/// no model yet).
type Partial = (usize, Option<Result<String, String>>);

/// The recording so far, transcribed on a thread of its own: the end of
/// speech is still watched while a pass runs.
fn spawn_partials(
    model: Arc<Mutex<Option<parakeet::Model>>>,
) -> (
    std::sync::mpsc::Sender<Vec<f32>>,
    std::sync::mpsc::Receiver<Partial>,
) {
    let (req_tx, req_rx) = std::sync::mpsc::channel::<Vec<f32>>();
    let (res_tx, res_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        while let Ok(samples) = req_rx.recv() {
            let text = lock(&model).as_mut().map(|m| m.transcribe(&samples));
            if res_tx.send((samples.len(), text)).is_err() {
                break;
            }
        }
    });
    (req_tx, res_rx)
}

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
    /// The transcript has heard the wake word: until then the bar shows the
    /// turn as `waking`, a word heard but not yet confirmed.
    confirmed: AtomicBool,
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
            confirmed: AtomicBool::new(false),
            preroll: Mutex::new(None),
            rt: tokio::runtime::Handle::current(),
            stop: Arc::new(AtomicBool::new(false)),
            model: Arc::new(Mutex::new(None)),
            starting: Arc::new(AtomicBool::new(false)),
            tx,
            pilot,
        });
        // An idle model gives its memory back — unless the wake word is on:
        // a turn it starts must be transcribed at once, not after loading.
        let weak = Arc::downgrade(&me);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(60));
            loop {
                tick.tick().await;
                let Some(me) = weak.upgrade() else { break };
                if me.wake_on() {
                    continue;
                }
                let mut slot = lock(&me.model);
                if slot
                    .as_ref()
                    .is_some_and(|s| s.last_use.elapsed() > parakeet::IDLE)
                {
                    *slot = None;
                }
            }
        });
        if me.wake_on() {
            me.warm();
        }
        // The wake word, for the daemon's lifetime (idle while off).
        let w = Arc::clone(&me);
        std::thread::spawn(move || super::wake::listen(w));
        me
    }

    /// A turn started by the wake word, not confirmed yet.
    fn unconfirmed(&self) -> bool {
        self.woken.load(Ordering::SeqCst) && !self.confirmed.load(Ordering::SeqCst)
    }

    pub fn snapshot_line(&self) -> String {
        json!({ "voice": {
            "phase": lock(&self.phase).as_str(),
            "waking": self.unconfirmed(),
            "level": *lock(&self.level),
            "text": *lock(&self.text),
            "partial": self.partial.load(Ordering::SeqCst),
            "send": self.send.load(Ordering::SeqCst),
            "wake": self.wake.load(Ordering::SeqCst),
            "wakeWord": WakeWord::current().display,
            "error": *lock(&self.error),
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
            // The word is not confirmed yet: asked by hand, the turn is
            // the user's from now on, wake word or not.
            Phase::Listening if self.unconfirmed() => {
                self.woken.store(false, Ordering::SeqCst);
                self.send.store(send, Ordering::SeqCst);
                self.publish();
            }
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

    /// Transcribe 16 kHz samples with the loaded model. `None`: it isn't
    /// loaded.
    fn transcribe_warm(&self, samples: &[f32]) -> Option<Result<String, String>> {
        let mut slot = lock(&self.model);
        let model = slot.as_mut()?;
        Some(model.transcribe(samples))
    }

    /// Enter listening (false if a turn is already under way). `woken`:
    /// started by the wake word, to be confirmed.
    fn begin(&self, send: bool, woken: bool) -> bool {
        {
            let mut p = lock(&self.phase);
            if *p != Phase::Idle {
                return false;
            }
            *p = Phase::Listening;
        }
        self.woken.store(woken, Ordering::SeqCst);
        self.confirmed.store(false, Ordering::SeqCst);
        self.stop.store(false, Ordering::SeqCst);
        self.send.store(send, Ordering::SeqCst);
        self.partial.store(false, Ordering::SeqCst);
        lock(&self.error).clear();
        lock(&self.text).clear();
        self.publish();
        self.warm();
        // The pilot is started (or renewed) while the user speaks, not
        // after: its start-up takes seconds.
        if send {
            let pilot = Arc::clone(&self.pilot);
            self.rt.spawn(async move { pilot.prewarm().await });
        }
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
        // detector was wrong and the turn ends in silence. Confirmed while
        // listening, the turn stands even if the final transcript writes the
        // word otherwise (Exupéri, then Exupé): its first word goes.
        let result = if self.woken.swap(false, Ordering::SeqCst) {
            let confirmed = self.confirmed.swap(true, Ordering::SeqCst);
            match result {
                Ok(Some(text)) => match strip_wake(&text) {
                    Some(rest) => {
                        if !confirmed {
                            eprintln!("anna: mot d'activation confirmé : « {text} »");
                        }
                        Ok(Some(rest))
                    }
                    None if confirmed => Ok(Some(drop_first_word(&text))),
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

    pub fn start(self: &Arc<Self>, send: bool) {
        if !self.begin(send, false) {
            return;
        }
        self.spawn_record();
    }

    /// The wake word was heard (wake.rs): listen to the request, with the
    /// word's audio in front so that the transcript confirms it.
    pub fn woken(self: &Arc<Self>, preroll: Vec<f32>, rate: u32) {
        if !self.begin(true, true) {
            return;
        }
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
        if on {
            self.warm();
        }
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
        if !self.begin(send, false) {
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
            .map(|(p, from)| resample(&p, from))
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
    /// `preroll`: audio from before the turn (the wake word), at 16 kHz,
    /// transcribed with the rest but kept out of the end-of-speech detection.
    fn listen(
        &self,
        rate: u32,
        preroll: Vec<f32>,
        mut next: impl FnMut() -> Result<Option<Vec<f32>>, String>,
    ) -> Result<Option<String>, String> {
        let frame_len = (rate as f32 * FRAME) as usize;
        let mut ep = Endpointer::default();
        // Everything heard, at the model's 16 kHz.
        let mut all: Vec<f32> = preroll;
        let start = all.len();
        let mut resampler = Resampler::new(rate, parakeet::RATE);
        // Microphone samples received, and those not yet cut into frames.
        let mut received = 0usize;
        let mut pending: Vec<f32> = Vec::new();
        let mut frames = 0usize;
        let mut last_partial = Instant::now();
        let (partial_tx, partials) = spawn_partials(Arc::clone(&self.model));
        let mut in_flight = false;
        // Started by the wake word: the transcript must soon hold it, or
        // the detector was wrong and the turn stops there.
        let woken = self.woken.load(Ordering::SeqCst);
        // Where speech was last heard (samples into `all`), the last partial
        // transcript with how much of `all` it covered, and whether the
        // request it holds ends a sentence.
        let mut speech_end = 0usize;
        let mut last_partial_text: Option<(usize, String)> = None;
        let mut request_ends = false;
        let margin = (parakeet::RATE as f32 * FINAL_MARGIN) as usize;
        let mut context_ready = false;
        let send = self.send.load(Ordering::SeqCst);
        let outcome = 'listen: loop {
            if self.stop.load(Ordering::SeqCst) {
                // Stopped by hand: only what followed real speech counts.
                break if ep.heard_speech() && all.len() > parakeet::RATE as usize / 2 {
                    Endpoint::Done
                } else {
                    Endpoint::Nothing
                };
            }

            // The transcript so far, as the partials come back.
            while let Ok((covered, text)) = partials.try_recv() {
                in_flight = false;
                let Some(Ok(text)) = text else { continue };
                last_partial_text = Some((covered, text.clone()));
                // The wake word isn't part of the request. A transcript
                // still short may not have it written yet (the word alone,
                // the model hears it as something else): only a longer one
                // without it ends the turn.
                let still_woken = self.woken.load(Ordering::SeqCst);
                let (text, request) = match (still_woken, strip_wake(&text)) {
                    (true, Some(rest)) => {
                        if !self.confirmed.swap(true, Ordering::SeqCst) {
                            eprintln!("anna: mot d'activation confirmé : « {text} »");
                        }
                        (rest, true)
                    }
                    (true, None) if self.confirmed.load(Ordering::SeqCst) => (text, true),
                    (true, None) if text.split_whitespace().count() >= WAKE_GIVE_UP => {
                        eprintln!("anna: mot d'activation non confirmé : « {text} »");
                        return Ok(None);
                    }
                    // Shown as heard, for the user to see why.
                    (true, None) => (text, false),
                    _ => (text, true),
                };
                request_ends = request && ends_sentence(&text);
                if !text.is_empty() {
                    *lock(&self.text) = text;
                    self.partial.store(true, Ordering::SeqCst);
                    self.publish();
                }
            }
            let Some(chunk) = next()? else {
                continue;
            };
            received += chunk.len();
            resampler.push(&chunk, &mut all);
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
                    let heard = (received - pending.len()) as u64;
                    speech_end = start + (heard * parakeet::RATE as u64 / rate as u64) as usize;
                    context_ready = false;
                }
                match fed {
                    Endpoint::More => {}
                    end => break 'listen end,
                }
            }

            if ep.heard_speech() {
                // A sentence said and finished: no need to wait longer.
                if ep.silence() >= QUICK_END
                    && request_ends
                    && covers(&last_partial_text, speech_end + margin)
                {
                    break Endpoint::Done;
                }
                // The request is likely over: the pilot's context, now.
                if send && !context_ready && ep.silence() >= CONTEXT_AT {
                    context_ready = true;
                    let pilot = Arc::clone(&self.pilot);
                    self.rt.spawn(async move { pilot.prepare() });
                }
            }

            // Another pass, every PARTIAL_EVERY — and right after the end
            // of speech, for the final transcript to be ready early.
            let due = last_partial.elapsed() >= PARTIAL_EVERY
                || (ep.heard_speech()
                    && ep.silence() >= FINAL_MARGIN + FRAME
                    && !covers(&last_partial_text, speech_end + margin));
            if (woken || ep.heard_speech()) && !in_flight && due {
                in_flight = partial_tx.send(all.clone()).is_ok();
                last_partial = Instant::now();
            }
        };
        if outcome == Endpoint::Nothing {
            return Ok(None);
        }
        resampler.finish(&mut all);

        // A pass still running may cover the end: the model is busy with it
        // anyway.
        drop(partial_tx);
        if in_flight {
            if let Ok((covered, Some(Ok(text)))) = partials.recv() {
                last_partial_text = Some((covered, text));
            }
        }
        // The last partial came after the end of speech: it is the final
        // transcript already.
        if let Some((covered, text)) = last_partial_text {
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
        if let Some(result) = self.transcribe_warm(&all) {
            return result.map(Some);
        }
        let mut model = load_model()?;
        let text = model.transcribe(&all);
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
        assert_eq!(resample(&vec![0.1; 44_100], 44_100).len(), 16_000);
    }

    fn tone(freq: f32, rate: u32) -> Vec<f32> {
        (0..rate as usize)
            .map(|i| (2.0 * std::f32::consts::PI * freq * i as f32 / rate as f32).sin() * 0.5)
            .collect()
    }

    /// Middle of the signal, away from the edges.
    fn level(s: &[f32]) -> f32 {
        rms(&s[s.len() / 4..s.len() * 3 / 4])
    }

    #[test]
    fn resampling_keeps_the_voice_and_drops_what_would_fold_over_it() {
        // 1 kHz stays…
        let kept = level(&resample(&tone(1_000.0, 48_000), 48_000));
        assert!((kept - 0.5 / 2f32.sqrt()).abs() < 0.01, "{kept}");
        // …12 kHz, which would come back as 4 kHz, is gone.
        let folded = level(&resample(&tone(12_000.0, 48_000), 48_000));
        assert!(folded < 0.01, "{folded}");
    }

    #[test]
    fn resampling_piece_by_piece_is_resampling_at_once() {
        let input = tone(440.0, 48_000);
        let whole = resample(&input, 48_000);
        let mut r = Resampler::new(48_000, 16_000);
        let mut pieces = Vec::new();
        for chunk in input.chunks(480) {
            r.push(chunk, &mut pieces);
        }
        r.finish(&mut pieces);
        assert_eq!(pieces.len(), whole.len());
        assert!(pieces.iter().zip(&whole).all(|(a, b)| (a - b).abs() < 1e-6));
    }

    #[test]
    fn a_finished_sentence_is_seen() {
        assert!(ends_sentence("Baisse le son."));
        assert!(ends_sentence("Quelle heure est-il ? "));
        assert!(!ends_sentence("Ouvre le projet"));
        assert!(!ends_sentence(""));
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
    fn a_confirmed_turn_drops_the_word_however_written() {
        assert_eq!(
            drop_first_word("Exupé, change de workspace."),
            "Change de workspace."
        );
        assert_eq!(drop_first_word("Exupéry."), "");
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
        // How Parakeet writes it, heard in use.
        for heard in ["Exupéri", "Expéri,", "Exupé,", "Expé.", "Exupérie"] {
            assert_eq!(
                strip_word(&format!("{heard} change de workspace."), &e).as_deref(),
                Some("Change de workspace."),
                "{heard}"
            );
        }
        // A short form is matched closely: « Elle » is not « Expé ».
        assert_eq!(strip_word("Elle change de workspace.", &e), None);
        // The end of something said before it, kept with the word's audio.
        assert_eq!(
            strip_word("Euh, Exupéry, baisse le son.", &e).as_deref(),
            Some("Baisse le son.")
        );
        assert_eq!(
            strip_word("Oui donc Exupéri mets de la musique", &e).as_deref(),
            Some("Mets de la musique")
        );
        // Further in, it is only a name in a sentence.
        assert_eq!(strip_word("Je crois que Exupéry a écrit ça.", &e), None);

        // Without its JSON, a word is heard only as its name.
        let z = word("absent");
        assert_eq!(z.display, "Absent");
        assert_eq!(
            strip_word("Absent, ouvre Zed", &z).as_deref(),
            Some("Ouvre Zed")
        );
    }
}
