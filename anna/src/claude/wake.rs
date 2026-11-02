//! The wake word: saying « Karénine » starts listening, as Super+V does.
//! The word is chosen per machine (`ANNA_WAKE_WORD`, set by the NixOS
//! configuration from the host name): « Bernanos » on bernanos, « Exupéry »
//! on exupery, « Karénine » wherever no model of its own was trained.
//!
//! openWakeWord's pipeline (Apache-2.0), run on the processor every 80 ms:
//!
//!   1. `melspectrogram.onnx`: the last 1 760 samples at 16 kHz (80 ms plus
//!      30 ms of context) → 8 frames of 32 mel bands, scaled `x / 10 + 2`.
//!   2. `embedding_model.onnx` (Google's speech embedding, shared by every
//!      wake word): the last 76 mel frames → one vector of 96.
//!   3. `<word>.onnx`, trained for this word only (lab/wakeword-<word>):
//!      the last 16 vectors (~1.3 s) → a score between 0 and 1.
//!
//! Next to it, `<word>.json` says how the word is written and heard
//! (`WakeWord`).
//!
//! A score over the threshold hands the last seconds of audio to the voice
//! (voice.rs), which listens to the request with them in front: the word
//! must be among the transcript's first, or the turn is dropped in silence
//! (the bar shows it as `waking` until then). A false trigger thus costs a
//! few transcriptions, never a request.
//!
//! The microphone stays open only while the wake word is on (`anna voice wake
//! on|off`, remembered across restarts). Nothing leaves the machine.

use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use ort::value::TensorRef;
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use super::voice::{resample, Resampler, Voice};

/// 80 ms at 16 kHz: one step of the pipeline.
const CHUNK: usize = 1280;
/// The mel model's input: the step plus three hops of context.
const MEL_INPUT: usize = CHUNK + 160 * 3;
const MEL_BANDS: usize = 32;
const MEL_WINDOW: usize = 76;
const EMBEDDING: usize = 96;
const FEATURES: usize = 16;
/// Audio kept for the voice, in front of the request: the word itself.
const PREROLL: Duration = Duration::from_millis(2500);
/// After a turn, the word just said must not trigger again.
const COOLDOWN: Duration = Duration::from_millis(1500);

/// Where the models live: the package's share dir, set by the wrapper.
pub fn models_dir() -> PathBuf {
    std::env::var_os("ANNA_WAKE_MODELS")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/current-system/sw/share/anna/wake"))
}

/// The word listened for, as its model is named (`ANNA_WAKE_WORD`, set by the
/// NixOS configuration); « Karénine » without one.
fn word_name() -> String {
    std::env::var("ANNA_WAKE_WORD")
        .ok()
        .filter(|w| {
            !w.is_empty()
                && w.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
        })
        .unwrap_or_else(|| "karenine".into())
}

/// A wake word, from `<name>.json` next to its model.
#[derive(Clone, Debug, serde::Deserialize)]
#[serde(default)]
pub struct WakeWord {
    /// Its model: `<name>.onnx`.
    #[serde(skip)]
    pub name: String,
    /// As shown: « Karénine ».
    pub display: String,
    /// How the transcript may write it, folded (voice.rs `fold`): within two
    /// letters of one of these, it was heard.
    pub near: Vec<String>,
    /// Its neighbours, folded, which don't count even when near.
    pub neighbours: Vec<String>,
    /// The letters the heard word may start with; those of `near` if empty.
    pub initials: Vec<char>,
    /// Score from which it counts as said (`ANNA_WAKE_THRESHOLD` overrides).
    pub threshold: f32,
}

impl Default for WakeWord {
    fn default() -> Self {
        WakeWord {
            name: String::new(),
            display: String::new(),
            near: Vec::new(),
            neighbours: Vec::new(),
            initials: Vec::new(),
            threshold: 0.6,
        }
    }
}

impl WakeWord {
    /// `<name>.json` from `dir`; a missing or broken file leaves the word
    /// written as its name, heard only as itself.
    pub fn load(dir: &Path, name: &str) -> Self {
        let mut w: WakeWord = std::fs::read_to_string(dir.join(format!("{name}.json")))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        w.name = name.to_string();
        if w.display.is_empty() {
            let mut c = name.chars();
            w.display = c
                .next()
                .map(|f| f.to_uppercase().chain(c).collect())
                .unwrap_or_default();
        }
        if w.near.is_empty() {
            w.near.push(name.to_string());
        }
        if w.initials.is_empty() {
            w.initials = w.near.iter().filter_map(|n| n.chars().next()).collect();
        }
        if let Some(t) = std::env::var("ANNA_WAKE_THRESHOLD")
            .ok()
            .and_then(|v| v.parse().ok())
        {
            w.threshold = t;
        }
        w
    }

    /// The word of this machine, read once.
    pub fn current() -> &'static WakeWord {
        static WORD: OnceLock<WakeWord> = OnceLock::new();
        WORD.get_or_init(|| WakeWord::load(&models_dir(), &word_name()))
    }
}

fn load(path: &Path) -> Result<Session, String> {
    let err = |e: &dyn std::fmt::Display| format!("{}: {e}", path.display());
    Session::builder()
        .map_err(|e| err(&e))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| err(&e))?
        // Tiny models every 80 ms: one thread, no busy-waiting between runs.
        .with_intra_threads(1)
        .map_err(|e| err(&e))?
        .with_intra_op_spinning(false)
        .map_err(|e| err(&e))?
        .with_inter_op_spinning(false)
        .map_err(|e| err(&e))?
        .commit_from_file(path)
        .map_err(|e| err(&e))
}

fn run(session: &mut Session, shape: &[usize], data: &[f32]) -> Result<Vec<f32>, String> {
    let input = TensorRef::from_array_view((shape.to_vec(), data)).map_err(|e| e.to_string())?;
    let outputs = session
        .run(ort::inputs![input])
        .map_err(|e| e.to_string())?;
    let (_, out) = outputs[0]
        .try_extract_tensor::<f32>()
        .map_err(|e| e.to_string())?;
    Ok(out.to_vec())
}

pub struct Detector {
    mel: Session,
    embedding: Session,
    word: Session,
    /// 16 kHz samples, int16 scale (as openWakeWord feeds its models).
    pending: Vec<f32>,
    raw: VecDeque<f32>,
    mels: VecDeque<[f32; MEL_BANDS]>,
    features: VecDeque<[f32; EMBEDDING]>,
}

impl Detector {
    pub fn new(dir: &Path, word: &str) -> Result<Self, String> {
        let mut d = Detector {
            mel: load(&dir.join("melspectrogram.onnx"))?,
            embedding: load(&dir.join("embedding_model.onnx"))?,
            word: load(&dir.join(format!("{word}.onnx")))?,
            pending: Vec::new(),
            raw: VecDeque::new(),
            mels: VecDeque::new(),
            features: VecDeque::new(),
        };
        d.reset();
        Ok(d)
    }

    /// Forget what was heard (openWakeWord starts its mel buffer at ones).
    pub fn reset(&mut self) {
        self.pending.clear();
        self.raw = std::iter::repeat_n(0.0, MEL_INPUT).collect();
        self.mels = std::iter::repeat_n([1.0; MEL_BANDS], MEL_WINDOW).collect();
        self.features.clear();
    }

    /// Feed 16 kHz samples (−1…1). Returns the best score of the 80 ms
    /// steps completed, if the history is long enough to score.
    pub fn feed(&mut self, samples: &[f32]) -> Result<Option<f32>, String> {
        self.pending.extend(samples.iter().map(|s| s * 32767.0));
        let mut best: Option<f32> = None;
        while self.pending.len() >= CHUNK {
            let chunk: Vec<f32> = self.pending.drain(..CHUNK).collect();
            self.raw.extend(chunk);
            while self.raw.len() > MEL_INPUT {
                self.raw.pop_front();
            }
            let input: Vec<f32> = self.raw.iter().copied().collect();
            let mel = run(&mut self.mel, &[1, MEL_INPUT], &input)?;
            for frame in mel.as_chunks::<MEL_BANDS>().0 {
                let mut f = [0.0; MEL_BANDS];
                for (o, v) in f.iter_mut().zip(frame) {
                    *o = v / 10.0 + 2.0;
                }
                self.mels.push_back(f);
            }
            while self.mels.len() > MEL_WINDOW {
                self.mels.pop_front();
            }
            let window: Vec<f32> = self.mels.iter().flatten().copied().collect();
            let e = run(&mut self.embedding, &[1, MEL_WINDOW, MEL_BANDS, 1], &window)?;
            let mut f = [0.0; EMBEDDING];
            f.copy_from_slice(e.get(..EMBEDDING).ok_or("embedding : sortie trop courte")?);
            self.features.push_back(f);
            while self.features.len() > FEATURES {
                self.features.pop_front();
            }
            if self.features.len() == FEATURES {
                let x: Vec<f32> = self.features.iter().flatten().copied().collect();
                let s = run(&mut self.word, &[1, FEATURES, EMBEDDING], &x)?;
                let s = s.first().copied().unwrap_or(0.0);
                best = Some(best.map_or(s, |b: f32| b.max(s)));
            }
        }
        Ok(best)
    }
}

/// Whether the wake word is on, remembered across restarts.
fn state_file() -> PathBuf {
    crate::paths::home_dir().join(".local/state/anna/wake-on")
}

pub fn remembered() -> bool {
    state_file().exists()
}

pub fn remember(on: bool) {
    let f = state_file();
    if on {
        if let Some(d) = f.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let _ = std::fs::write(&f, "");
    } else {
        let _ = std::fs::remove_file(&f);
    }
}

/// Listen for the word while `voice.wake_on()`; the microphone is released
/// whenever it is off. Runs on its own thread for the daemon's lifetime.
pub fn listen(voice: Arc<Voice>) {
    let word = WakeWord::current();
    let threshold = word.threshold;
    loop {
        while !voice.wake_on() {
            std::thread::sleep(Duration::from_millis(300));
        }
        let mut detector = match Detector::new(&models_dir(), &word.name) {
            Ok(d) => d,
            Err(e) => {
                voice.wake_failed(format!("mot d'activation : {e}"));
                continue;
            }
        };
        let (capture, rx) = match crate::audio::start_voice_capture() {
            Ok(c) => c,
            Err(e) => {
                voice.wake_failed(format!("micro : {e}"));
                continue;
            }
        };
        let rate = capture.sample_rate;
        let keep = (rate as f64 * PREROLL.as_secs_f64()) as usize;
        let mut recent: VecDeque<f32> = VecDeque::with_capacity(keep + 4096);
        let mut quiet_until = Instant::now();
        let mut was_busy = false;
        let mut resampler = Resampler::new(rate, super::parakeet::RATE);
        let mut samples = Vec::new();
        while voice.wake_on() {
            let chunk = match rx.recv_timeout(Duration::from_millis(300)) {
                Ok(c) => c,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(_) => break,
            };
            recent.extend(chunk.iter().copied());
            while recent.len() > keep {
                recent.pop_front();
            }
            // While a turn is under way (whatever started it), the word is
            // not listened for, and its echo is let go afterwards.
            if voice.busy() {
                was_busy = true;
                continue;
            }
            if was_busy {
                was_busy = false;
                detector.reset();
                quiet_until = Instant::now() + COOLDOWN;
                resampler = Resampler::new(rate, super::parakeet::RATE);
            }
            samples.clear();
            resampler.push(&chunk, &mut samples);
            let score = match detector.feed(&samples) {
                Ok(s) => s,
                Err(e) => {
                    voice.wake_failed(format!("mot d'activation : {e}"));
                    break;
                }
            };
            if score.is_some_and(|s| s >= threshold) && Instant::now() >= quiet_until {
                eprintln!("anna: mot d'activation ({:.2})", score.unwrap_or(0.0));
                voice.woken(recent.iter().copied().collect(), rate);
                detector.reset();
            }
        }
        drop(capture);
    }
}

/// `anna wake-score file.wav`: the score of every 80 ms step over a WAV
/// file, to compare with openWakeWord's own pipeline or tune the threshold.
pub fn score_file(path: Option<&str>) {
    let Some(path) = path else {
        eprintln!("usage : anna wake-score <fichier.wav>");
        std::process::exit(2);
    };
    let result = (|| -> Result<(), String> {
        let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
        let (samples, rate) = super::voice::read_wav(&bytes)
            .ok_or_else(|| format!("{path}: WAV 16 bits illisible"))?;
        let mut d = Detector::new(&models_dir(), &WakeWord::current().name)?;
        for (i, chunk) in resample(&samples, rate).chunks(CHUNK).enumerate() {
            if let Some(s) = d.feed(chunk)? {
                println!("{:.2}\t{s:.4}", (i + 1) as f32 * 0.08);
            }
        }
        Ok(())
    })();
    if let Err(e) = result {
        eprintln!("anna: {e}");
        std::process::exit(1);
    }
}
