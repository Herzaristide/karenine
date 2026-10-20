//! The pilot's answers, spoken.
//!
//! A Piper voice (VITS, ONNX) runs here with ONNX Runtime, as the wake word
//! does — no Python, nothing leaves the machine:
//!
//!   text → espeak-ng → phonemes → the voice's id map → model → `pw-play`
//!
//! espeak-ng is libespeak-ng, loaded at run time (`ESPEAK_DYLIB_PATH`, set
//! by the wrapper), called exactly as Piper calls it: one clause at a time
//! with its terminator, the punctuation kept as a phoneme, one synthesis per
//! sentence.
//!
//! The answer is spoken while it streams in: each finished sentence is
//! synthesised as the next one is written. Code blocks, links and markdown
//! marks are left out. A new request, the wake word, Super+V or `anna voice
//! hush` cut it short.
//!
//! When it speaks (`mode`): `off`, `voice` — answers to a spoken request
//! only, the default — or `always`. Which voice: any `<name>.onnx` with its
//! `<name>.onnx.json` in `ANNA_PIPER_VOICES`, else `~/.local/share/anna/piper`
//! (the NixOS configuration links them there); a voice with several speakers
//! counts once per speaker. Both choices are kept in
//! `~/.local/state/anna/speech.json`.

use ort::session::builder::GraphOptimizationLevel;
use ort::session::{Session, SessionInputValue};
use ort::value::TensorRef;
use serde_json::{json, Value};
use std::borrow::Cow;
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::sync::broadcast;

/// The loaded voice is dropped after this long without speaking.
const IDLE: Duration = Duration::from_secs(10 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Off,
    Voice,
    Always,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Off => "off",
            Mode::Voice => "voice",
            Mode::Always => "always",
        }
    }

    pub fn parse(s: &str) -> Option<Mode> {
        match s {
            "off" => Some(Mode::Off),
            "voice" => Some(Mode::Voice),
            "always" => Some(Mode::Always),
            _ => None,
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// ── Voices ──────────────────────────────────────────────────────────────

pub fn voices_dir() -> PathBuf {
    std::env::var_os("ANNA_PIPER_VOICES")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::paths::home_dir().join(".local/share/anna/piper"))
}

/// One voice the settings can pick.
#[derive(Debug, Clone, PartialEq)]
pub struct Choice {
    /// `fr_FR-siwis-medium`, or `fr_FR-upmc-medium:pierre` for one speaker
    /// of a voice that has several.
    pub id: String,
    /// « Siwis (fr_FR) », « Upmc · pierre (fr_FR) ».
    pub name: String,
    model: PathBuf,
    speaker: Option<(String, i64)>,
}

/// `fr_FR-siwis-medium` → (« Siwis », « fr_FR »).
fn describe(stem: &str) -> (String, String) {
    let parts: Vec<&str> = stem.split('-').collect();
    let (lang, name) = match parts.as_slice() {
        [lang, name, ..] => (lang.to_string(), name.to_string()),
        _ => (String::new(), stem.to_string()),
    };
    let mut chars = name.chars();
    let name = match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => name,
    };
    (name, lang)
}

/// The voices of a directory, sorted by id.
pub fn voices_in(dir: &Path) -> Vec<Choice> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for e in entries.flatten() {
        let model = e.path();
        if model.extension().and_then(|x| x.to_str()) != Some("onnx") {
            continue;
        }
        let Some(stem) = model
            .file_stem()
            .and_then(|s| s.to_str())
            .map(str::to_string)
        else {
            continue;
        };
        let Some(config) = std::fs::read_to_string(config_path(&model))
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        else {
            continue;
        };
        let (name, lang) = describe(&stem);
        let speakers: Vec<(String, i64)> = config
            .get("speaker_id_map")
            .and_then(Value::as_object)
            .map(|m| {
                let mut v: Vec<(String, i64)> = m
                    .iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_i64()?)))
                    .collect();
                v.sort_by_key(|(_, id)| *id);
                v
            })
            .unwrap_or_default();
        let several = config
            .get("num_speakers")
            .and_then(Value::as_i64)
            .unwrap_or(1)
            > 1;
        if several && !speakers.is_empty() {
            for (speaker, sid) in speakers {
                out.push(Choice {
                    id: format!("{stem}:{speaker}"),
                    name: format!("{name} · {speaker} ({lang})"),
                    model: model.clone(),
                    speaker: Some((speaker, sid)),
                });
            }
        } else {
            out.push(Choice {
                id: stem,
                name: format!("{name} ({lang})"),
                model,
                speaker: None,
            });
        }
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

fn config_path(model: &Path) -> PathBuf {
    let mut p = model.as_os_str().to_owned();
    p.push(".json");
    PathBuf::from(p)
}

/// The voice to use: the one chosen, else the first in the spoken language,
/// else the first.
pub fn pick<'a>(voices: &'a [Choice], chosen: &str, lang: &str) -> Option<&'a Choice> {
    voices
        .iter()
        .find(|v| v.id == chosen)
        .or_else(|| voices.iter().find(|v| v.id.starts_with(lang)))
        .or_else(|| voices.first())
}

// ── Settings ────────────────────────────────────────────────────────────

fn settings_file() -> PathBuf {
    crate::paths::home_dir().join(".local/state/anna/speech.json")
}

#[derive(Debug, Clone, PartialEq)]
struct Settings {
    mode: Mode,
    voice: String,
}

impl Settings {
    fn load() -> Settings {
        let v: Value = std::fs::read_to_string(settings_file())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(Value::Null);
        Settings {
            mode: v
                .get("mode")
                .and_then(Value::as_str)
                .and_then(Mode::parse)
                .unwrap_or(Mode::Voice),
            voice: v
                .get("voice")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
        }
    }

    fn save(&self) {
        let f = settings_file();
        if let Some(d) = f.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let _ = std::fs::write(
            &f,
            json!({ "mode": self.mode.as_str(), "voice": self.voice }).to_string(),
        );
    }
}

// ── Text ────────────────────────────────────────────────────────────────

/// One line of markdown as it is read aloud: marks, links and URLs out.
pub fn speakable(line: &str) -> String {
    let mut l = line.trim();
    // Table rule, horizontal rule.
    if !l.is_empty()
        && l.chars()
            .all(|c| matches!(c, '|' | '-' | ':' | ' ' | '*' | '_' | '='))
    {
        return String::new();
    }
    l = l
        .trim_start_matches('#')
        .trim_start_matches('>')
        .trim_start();
    for marker in ["- ", "* ", "+ "] {
        if let Some(rest) = l.strip_prefix(marker) {
            l = rest;
        }
    }
    // « 1. », « 2) » at the start of a line.
    let digits = l.chars().take_while(char::is_ascii_digit).count();
    if digits > 0 {
        let rest = &l[digits..];
        if let Some(r) = rest.strip_prefix(". ").or_else(|| rest.strip_prefix(") ")) {
            l = r;
        }
    }

    // [texte](url) → texte.
    let mut out = String::with_capacity(l.len());
    let mut rest = l;
    while let Some(open) = rest.find('[') {
        let after = &rest[open + 1..];
        match after.find("](").and_then(|close| {
            let url = &after[close + 2..];
            url.find(')').map(|end| (close, close + 2 + end + 1))
        }) {
            Some((close, skip)) => {
                out.push_str(&rest[..open]);
                out.push_str(&after[..close]);
                rest = &after[skip..];
            }
            None => {
                out.push_str(&rest[..=open]);
                rest = after;
            }
        }
    }
    out.push_str(rest);

    let words: Vec<&str> = out
        .split_whitespace()
        .filter(|w| !w.contains("://"))
        .collect();
    let text = words.join(" ");
    let text: String = text
        .chars()
        .filter(|c| {
            !matches!(c, '*' | '`' | '~' | '|' | '#')
                && !matches!(*c as u32, 0x2600..=0x27BF | 0x1F000..=0x1FAFF | 0xFE0F)
        })
        .collect();
    // `__gras__` (but not snake_case names). The project's name as it is
    // said (espeak reads « karenine » as « carnine »).
    let text = text
        .replace("__", "")
        .replace("karenine", "Karénine")
        .replace("Karenine", "Karénine");
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Cuts the streamed reply into what can be spoken already: whole lines,
/// or sentences finished by « . ! ? … » and a space. Code blocks are
/// skipped whole.
#[derive(Default)]
pub struct Splitter {
    buf: String,
    in_code: bool,
}

impl Splitter {
    pub fn push(&mut self, piece: &str) -> Vec<String> {
        self.buf.push_str(piece);
        let mut out = Vec::new();
        loop {
            if let Some(nl) = self.buf.find('\n') {
                let line: String = self.buf.drain(..=nl).collect();
                self.line(&line, &mut out);
                continue;
            }
            if self.in_code || self.buf.trim_start().starts_with('`') {
                break;
            }
            match sentence_end(&self.buf) {
                Some(end) => {
                    let s: String = self.buf.drain(..end).collect();
                    self.line(&s, &mut out);
                }
                None => break,
            }
        }
        out
    }

    /// The rest, once the text is over.
    pub fn finish(&mut self) -> Vec<String> {
        let rest = std::mem::take(&mut self.buf);
        let mut out = Vec::new();
        self.line(&rest, &mut out);
        self.in_code = false;
        out
    }

    pub fn clear(&mut self) {
        self.buf.clear();
        self.in_code = false;
    }

    fn line(&mut self, line: &str, out: &mut Vec<String>) {
        if line.trim_start().starts_with("```") {
            self.in_code = !self.in_code;
            return;
        }
        if self.in_code {
            return;
        }
        let s = speakable(line);
        if s.chars().any(char::is_alphanumeric) {
            out.push(s);
        }
    }
}

/// Where the first finished sentence of `text` ends (after its space), if
/// one is. A list number (« 1. ») is not a sentence.
fn sentence_end(text: &str) -> Option<usize> {
    let mut prev: Option<(usize, char)> = None;
    for (i, c) in text.char_indices() {
        if c.is_whitespace() {
            if let Some((at, p)) = prev {
                if matches!(p, '.' | '!' | '?' | '…') {
                    let head = text[..at].trim();
                    if !head.is_empty() && !head.chars().all(|c| c.is_ascii_digit()) {
                        return Some(i + c.len_utf8());
                    }
                }
            }
        }
        prev = Some((i, c));
    }
    None
}

// ── espeak-ng ───────────────────────────────────────────────────────────

type InitFn = unsafe extern "C" fn(c_int, c_int, *const c_char, c_int) -> c_int;
type SetVoiceFn = unsafe extern "C" fn(*const c_char) -> c_int;
type ToPhonemesFn =
    unsafe extern "C" fn(*mut *const c_void, c_int, c_int, *mut c_int) -> *const c_char;

/// espeak-ng's clause terminators (translate.h): the pause in the low bits,
/// then the intonation and the clause type.
const CLAUSE_MASK: c_int = 0x000F_FFFF;
const CLAUSE_TYPE_SENTENCE: c_int = 0x0008_0000;
const CLAUSE_PERIOD: c_int = 40 | CLAUSE_TYPE_SENTENCE;
const CLAUSE_QUESTION: c_int = 40 | 0x2000 | CLAUSE_TYPE_SENTENCE;
const CLAUSE_EXCLAMATION: c_int = 45 | 0x3000 | CLAUSE_TYPE_SENTENCE;
const CLAUSE_COMMA: c_int = 20 | 0x1000 | 0x0004_0000;
const CLAUSE_COLON: c_int = 30 | 0x0004_0000;
const CLAUSE_SEMICOLON: c_int = 30 | 0x1000 | 0x0004_0000;

const AUDIO_OUTPUT_SYNCHRONOUS: c_int = 2;
const ESPEAK_CHARS_UTF8: c_int = 1;
const ESPEAK_PHONEMES_IPA: c_int = 0x02;

pub fn terminator(term: c_int) -> (&'static str, bool) {
    let punct = match term & CLAUSE_MASK {
        CLAUSE_PERIOD => ".",
        CLAUSE_QUESTION => "?",
        CLAUSE_EXCLAMATION => "!",
        CLAUSE_COMMA => ",",
        CLAUSE_COLON => ":",
        CLAUSE_SEMICOLON => ";",
        _ => "",
    };
    (punct, term & CLAUSE_TYPE_SENTENCE != 0)
}

struct Espeak {
    _lib: libloading::Library,
    set_voice: SetVoiceFn,
    to_phonemes: ToPhonemesFn,
    voice: String,
}

// Only ever used under the mutex below.
unsafe impl Send for Espeak {}

fn espeak() -> Result<&'static Mutex<Espeak>, String> {
    static ESPEAK: OnceLock<Result<Mutex<Espeak>, String>> = OnceLock::new();
    ESPEAK
        .get_or_init(|| {
            let path =
                std::env::var_os("ESPEAK_DYLIB_PATH").unwrap_or_else(|| "libespeak-ng.so.1".into());
            let err = |e: &dyn std::fmt::Display| format!("espeak-ng : {e}");
            // SAFETY: libespeak-ng's documented C API, with its own signatures.
            unsafe {
                let lib = libloading::Library::new(&path).map_err(|e| err(&e))?;
                let init: InitFn = *lib.get(b"espeak_Initialize\0").map_err(|e| err(&e))?;
                let set_voice: SetVoiceFn =
                    *lib.get(b"espeak_SetVoiceByName\0").map_err(|e| err(&e))?;
                let to_phonemes: ToPhonemesFn = *lib
                    .get(b"espeak_TextToPhonemesWithTerminator\0")
                    .map_err(|e| err(&e))?;
                if init(AUDIO_OUTPUT_SYNCHRONOUS, 0, std::ptr::null(), 0) < 0 {
                    return Err(err(&"initialisation impossible (données absentes ?)"));
                }
                Ok(Mutex::new(Espeak {
                    _lib: lib,
                    set_voice,
                    to_phonemes,
                    voice: String::new(),
                }))
            }
        })
        .as_ref()
        .map_err(Clone::clone)
}

/// The few precomposed letters espeak's IPA can hold, decomposed as
/// Piper's NFD does (the id maps know the combining marks).
fn decompose(c: char, out: &mut Vec<String>) {
    let (base, mark) = match c {
        'ç' => ('c', '\u{327}'),
        'ã' => ('a', '\u{303}'),
        'ẽ' => ('e', '\u{303}'),
        'ĩ' => ('i', '\u{303}'),
        'õ' => ('o', '\u{303}'),
        'ũ' => ('u', '\u{303}'),
        'ỹ' => ('y', '\u{303}'),
        'ñ' => ('n', '\u{303}'),
        c => {
            out.push(c.to_string());
            return;
        }
    };
    out.push(base.to_string());
    out.push(mark.to_string());
}

/// Drop espeak's language switches, « (en) » … « (fr) ».
fn strip_flags(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut depth = 0;
    for c in s.chars() {
        match c {
            '(' => depth += 1,
            ')' if depth > 0 => depth -= 1,
            c if depth == 0 => out.push(c),
            _ => {}
        }
    }
    out
}

/// Text → phonemes, one list per sentence, as Piper makes them.
pub fn phonemize(voice: &str, text: &str) -> Result<Vec<Vec<String>>, String> {
    let mut e = lock(espeak()?);
    if e.voice != voice {
        let name = CString::new(voice).map_err(|e| e.to_string())?;
        // SAFETY: a valid C string; espeak copies what it keeps.
        if unsafe { (e.set_voice)(name.as_ptr()) } != 0 {
            return Err(format!("espeak-ng : voix « {voice} » inconnue"));
        }
        e.voice = voice.to_string();
    }
    let text = CString::new(text.replace('\0', " ")).map_err(|e| e.to_string())?;
    let mut ptr: *const c_void = text.as_ptr().cast();
    let mut sentences = Vec::new();
    let mut sentence: Vec<String> = Vec::new();
    while !ptr.is_null() {
        let mut term: c_int = 0;
        // SAFETY: `ptr` walks `text`, which outlives the loop; espeak sets
        // it to null after the last clause. The result is valid until the
        // next call, and copied at once.
        let clause = unsafe {
            let out = (e.to_phonemes)(&mut ptr, ESPEAK_CHARS_UTF8, ESPEAK_PHONEMES_IPA, &mut term);
            if out.is_null() {
                String::new()
            } else {
                CStr::from_ptr(out).to_string_lossy().into_owned()
            }
        };
        let (punct, end) = terminator(term);
        let mut phonemes = strip_flags(&clause);
        phonemes.push_str(punct);
        if matches!(punct, "," | ":" | ";") {
            phonemes.push(' ');
        }
        for c in phonemes.chars() {
            decompose(c, &mut sentence);
        }
        if end {
            sentences.push(std::mem::take(&mut sentence));
        }
    }
    if !sentence.is_empty() {
        sentences.push(sentence);
    }
    sentences.retain(|s| !s.is_empty());
    Ok(sentences)
}

// ── Synthesis ───────────────────────────────────────────────────────────

/// Merge the vowel clusters a voice knows as one phoneme (`vowel_clusters`).
fn merge_clusters(phones: Vec<String>, clusters: &HashSet<Vec<String>>) -> Vec<String> {
    if clusters.is_empty() {
        return phones;
    }
    let max = clusters.iter().map(Vec::len).max().unwrap_or(0);
    let mut out = Vec::with_capacity(phones.len());
    let mut i = 0;
    while i < phones.len() {
        let hit = (2..=max.min(phones.len() - i))
            .rev()
            .find(|n| clusters.contains(&phones[i..i + n].to_vec()));
        match hit {
            Some(n) => {
                out.push(phones[i..i + n].concat());
                i += n;
            }
            None => {
                out.push(phones[i].clone());
                i += 1;
            }
        }
    }
    out
}

/// Phonemes → ids: BOS, each phoneme followed by the pad, EOS. Unknown
/// phonemes are skipped.
pub fn to_ids(phones: &[String], map: &HashMap<String, Vec<i64>>) -> Vec<i64> {
    let get = |k: &str| map.get(k).cloned().unwrap_or_default();
    let pad = get("_");
    let mut ids = get("^");
    ids.extend(&pad);
    for p in phones {
        if let Some(id) = map.get(p) {
            ids.extend(id);
            ids.extend(&pad);
        }
    }
    ids.extend(get("$"));
    ids
}

/// A loaded voice.
pub struct Engine {
    pub id: String,
    session: Session,
    pub rate: u32,
    espeak_voice: String,
    map: HashMap<String, Vec<i64>>,
    clusters: HashSet<Vec<String>>,
    speaker: Option<i64>,
    scales: [f32; 3],
}

impl Engine {
    pub fn load(choice: &Choice) -> Result<Engine, String> {
        let text = std::fs::read_to_string(config_path(&choice.model))
            .map_err(|e| format!("{} : {e}", choice.model.display()))?;
        let c: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
        if let Some(t) = c.get("phoneme_type").and_then(Value::as_str) {
            if t != "espeak" {
                return Err(format!(
                    "voix « {} » : phonèmes {t} non pris en charge",
                    choice.id
                ));
            }
        }
        let map = c
            .get("phoneme_id_map")
            .and_then(Value::as_object)
            .ok_or("phoneme_id_map absent")?
            .iter()
            .map(|(k, v)| {
                let ids = v
                    .as_array()
                    .map(|a| a.iter().filter_map(Value::as_i64).collect())
                    .unwrap_or_default();
                (k.clone(), ids)
            })
            .collect();
        let clusters = c
            .get("vowel_clusters")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|v| {
                        v.as_array().map(|p| {
                            p.iter()
                                .filter_map(|x| x.as_str().map(str::to_string))
                                .collect()
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        let inference = c.get("inference");
        let scale = |k: &str, d: f32| {
            inference
                .and_then(|i| i.get(k))
                .and_then(Value::as_f64)
                .map(|v| v as f32)
                .unwrap_or(d)
        };
        let several = c.get("num_speakers").and_then(Value::as_i64).unwrap_or(1) > 1;
        let speaker = several.then(|| {
            choice
                .speaker
                .as_ref()
                .map(|(_, sid)| *sid)
                .or_else(|| c.get("default_speaker_id").and_then(Value::as_i64))
                .unwrap_or(0)
        });
        let threads = std::thread::available_parallelism()
            .map(|n| n.get().min(4))
            .unwrap_or(2);
        let err = |e: &dyn std::fmt::Display| format!("{} : {e}", choice.model.display());
        let session = Session::builder()
            .map_err(|e| err(&e))?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .map_err(|e| err(&e))?
            .with_intra_threads(threads)
            .map_err(|e| err(&e))?
            .with_intra_op_spinning(false)
            .map_err(|e| err(&e))?
            .commit_from_file(&choice.model)
            .map_err(|e| err(&e))?;
        Ok(Engine {
            id: choice.id.clone(),
            session,
            rate: c
                .pointer("/audio/sample_rate")
                .and_then(Value::as_u64)
                .unwrap_or(22050) as u32,
            espeak_voice: c
                .pointer("/espeak/voice")
                .and_then(Value::as_str)
                .unwrap_or("en-us")
                .to_string(),
            map,
            clusters,
            speaker,
            scales: [
                scale("noise_scale", 0.667),
                scale("length_scale", 1.0),
                scale("noise_w", 0.8),
            ],
        })
    }

    /// Text → phoneme ids, one list per sentence.
    pub fn sentences(&self, text: &str) -> Result<Vec<Vec<i64>>, String> {
        Ok(phonemize(&self.espeak_voice, text)?
            .into_iter()
            .map(|p| to_ids(&merge_clusters(p, &self.clusters), &self.map))
            .collect())
    }

    /// One sentence's ids → 16-bit samples, at `rate`, peak-normalised.
    pub fn synthesize(&mut self, ids: &[i64]) -> Result<Vec<i16>, String> {
        let n = ids.len();
        let lengths = [n as i64];
        let sid = self.speaker.map(|s| [s]);
        let e = |e: ort::Error| e.to_string();
        let mut inputs: Vec<(Cow<str>, SessionInputValue)> = ort::inputs! {
            "input" => TensorRef::from_array_view(([1usize, n], ids)).map_err(e)?,
            "input_lengths" => TensorRef::from_array_view(([1usize], &lengths[..])).map_err(e)?,
            "scales" => TensorRef::from_array_view(([3usize], &self.scales[..])).map_err(e)?,
        };
        if let Some(sid) = &sid {
            inputs.push((
                Cow::from("sid"),
                TensorRef::from_array_view(([1usize], &sid[..]))
                    .map_err(e)?
                    .into(),
            ));
        }
        let outputs = self.session.run(inputs).map_err(e)?;
        let (_, audio) = outputs[0].try_extract_tensor::<f32>().map_err(e)?;
        let peak = audio.iter().fold(0f32, |m, s| m.max(s.abs()));
        if peak < 1e-8 {
            return Ok(vec![0; audio.len()]);
        }
        Ok(audio
            .iter()
            .map(|s| ((s / peak).clamp(-1.0, 1.0) * 32767.0) as i16)
            .collect())
    }
}

// ── Playback ────────────────────────────────────────────────────────────

fn play(rate: u32) -> Result<(Child, ChildStdin), String> {
    let mut child = Command::new("pw-play")
        .args(["--raw", "--format", "s16", "--channels", "1"])
        .args(["--rate", &rate.to_string()])
        .args(["--media-role", "Assistant"])
        .args([
            "-P",
            r#"{ "media.name": "Karénine", "application.name": "anna" }"#,
        ])
        .arg("-")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("pw-play : {e}"))?;
    let stdin = child
        .stdin
        .take()
        .ok_or("pw-play : pas d'entrée standard")?;
    Ok((child, stdin))
}

fn bytes(samples: &[i16]) -> Vec<u8> {
    samples.iter().flat_map(|s| s.to_le_bytes()).collect()
}

// ── The voice of the pilot ──────────────────────────────────────────────

enum Job {
    Say {
        generation: u64,
        text: String,
    },
    /// The answer is over: let the player finish and close.
    End {
        generation: u64,
    },
}

/// What the current answer does.
struct Turn {
    speaks: bool,
    splitter: Splitter,
}

pub struct Speech {
    settings: Mutex<Settings>,
    error: Mutex<String>,
    turn: Mutex<Turn>,
    /// Bumped by `stop`: jobs of an older generation are dropped.
    generation: Arc<AtomicU64>,
    /// The playing `pw-play`, killed by `stop`.
    player: Arc<Mutex<Option<Child>>>,
    jobs: mpsc::Sender<Job>,
    changed: broadcast::Sender<()>,
    /// The voices found, with the directory's modification time.
    voices: Mutex<Option<(Option<std::time::SystemTime>, Vec<Choice>)>>,
}

impl Speech {
    pub fn new() -> Arc<Speech> {
        let (jobs, rx) = mpsc::channel();
        let (changed, _) = broadcast::channel(8);
        let me = Arc::new(Speech {
            settings: Mutex::new(Settings::load()),
            error: Mutex::new(String::new()),
            turn: Mutex::new(Turn {
                speaks: false,
                splitter: Splitter::default(),
            }),
            generation: Arc::new(AtomicU64::new(0)),
            player: Arc::new(Mutex::new(None)),
            jobs,
            changed,
            voices: Mutex::new(None),
        });
        let weak = Arc::downgrade(&me);
        std::thread::spawn(move || worker(rx, weak));
        me
    }

    /// Told when the settings or the error change.
    pub fn subscribe(&self) -> broadcast::Receiver<()> {
        self.changed.subscribe()
    }

    fn notify(&self) {
        let _ = self.changed.send(());
    }

    /// The voices, read again only when their directory changes.
    fn voices(&self) -> Vec<Choice> {
        let dir = voices_dir();
        let mtime = std::fs::metadata(&dir).and_then(|m| m.modified()).ok();
        let mut cache = lock(&self.voices);
        match cache.as_ref() {
            Some((t, v)) if *t == mtime => v.clone(),
            _ => {
                let v = voices_in(&dir);
                *cache = Some((mtime, v.clone()));
                v
            }
        }
    }

    fn set_error(&self, e: String) {
        let mut cur = lock(&self.error);
        if *cur != e {
            *cur = e;
            drop(cur);
            self.notify();
        }
    }

    /// `{"mode":…,"voice":…,"voices":[{id,name}…],"error":…}` for the
    /// settings. `voice` is the one actually used.
    pub fn state(&self) -> Value {
        let s = lock(&self.settings).clone();
        let voices = self.voices();
        let used = pick(&voices, &s.voice, &crate::i18n::voice_lang())
            .map(|v| v.id.clone())
            .unwrap_or_default();
        json!({
            "mode": s.mode.as_str(),
            "voice": used,
            "voices": voices.iter().map(|v| json!({ "id": v.id, "name": v.name })).collect::<Vec<_>>(),
            "error": *lock(&self.error),
        })
    }

    pub fn set(&self, mode: Option<Mode>, voice: Option<String>) {
        {
            let mut s = lock(&self.settings);
            if let Some(m) = mode {
                s.mode = m;
            }
            if let Some(v) = voice {
                s.voice = v;
            }
            s.save();
        }
        if mode == Some(Mode::Off) {
            self.stop();
        }
        lock(&self.error).clear();
        self.notify();
    }

    /// Silence now: what is playing and what was about to.
    pub fn stop(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        lock(&self.turn).splitter.clear();
        if let Some(mut child) = lock(&self.player).take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    /// A new answer begins (interrupting the last one). `spoken`: the
    /// request was said, not typed. Whether it will be read aloud.
    pub fn begin(&self, spoken: bool) -> bool {
        self.stop();
        let mode = lock(&self.settings).mode;
        let speaks = match mode {
            Mode::Off => false,
            Mode::Voice => spoken,
            Mode::Always => true,
        };
        lock(&self.turn).speaks = speaks;
        speaks
    }

    fn send(&self, texts: Vec<String>) {
        let generation = self.generation.load(Ordering::SeqCst);
        for text in texts {
            let _ = self.jobs.send(Job::Say { generation, text });
        }
    }

    /// A piece of the answer, as it streams.
    pub fn feed(&self, piece: &str) {
        let texts = {
            let mut t = lock(&self.turn);
            if !t.speaks {
                return;
            }
            t.splitter.push(piece)
        };
        self.send(texts);
    }

    /// A block of the answer is over (more may follow, after a tool call).
    pub fn flush(&self) {
        let texts = {
            let mut t = lock(&self.turn);
            if !t.speaks {
                return;
            }
            t.splitter.finish()
        };
        self.send(texts);
    }

    /// The whole answer is in.
    pub fn end(&self) {
        self.flush();
        let speaks = std::mem::replace(&mut lock(&self.turn).speaks, false);
        if speaks {
            let generation = self.generation.load(Ordering::SeqCst);
            let _ = self.jobs.send(Job::End { generation });
        }
    }

    /// Say a text now, whatever the mode (`anna voice say`).
    pub fn say(&self, text: &str) {
        self.stop();
        lock(&self.turn).speaks = true;
        self.feed(text);
        self.end();
    }

    fn voice(&self) -> Result<Choice, String> {
        let chosen = lock(&self.settings).voice.clone();
        let voices = self.voices();
        pick(&voices, &chosen, &crate::i18n::voice_lang())
            .cloned()
            .ok_or_else(|| {
                crate::i18n::tr_args(
                    "speech.no_voice",
                    &[("path", &voices_dir().display().to_string())],
                )
            })
    }
}

/// The synthesis thread: one sentence after the other, into one `pw-play`
/// per answer.
fn worker(rx: mpsc::Receiver<Job>, speech: std::sync::Weak<Speech>) {
    let mut engine: Option<Engine> = None;
    // The open player's input: its generation, rate and pipe.
    let mut pipe: Option<(u64, u32, ChildStdin)> = None;
    loop {
        let job = match rx.recv_timeout(IDLE) {
            Ok(job) => job,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                engine = None;
                continue;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        let Some(me) = speech.upgrade() else { break };
        let current = me.generation.load(Ordering::SeqCst);
        if pipe.as_ref().is_some_and(|(g, _, _)| *g != current) {
            pipe = None;
        }
        match job {
            Job::End { generation } => {
                if generation == current {
                    // Closing its input lets pw-play play the rest and exit.
                    pipe = None;
                }
            }
            Job::Say { generation, text } => {
                if generation != current {
                    continue;
                }
                if let Err(e) = say(&me, &mut engine, &mut pipe, generation, &text) {
                    eprintln!("anna: parole : {e}");
                    me.set_error(e);
                }
            }
        }
    }
}

fn say(
    me: &Speech,
    engine: &mut Option<Engine>,
    pipe: &mut Option<(u64, u32, ChildStdin)>,
    generation: u64,
    text: &str,
) -> Result<(), String> {
    let choice = me.voice()?;
    if engine.as_ref().is_none_or(|e| e.id != choice.id) {
        *engine = None;
        *engine = Some(Engine::load(&choice)?);
    }
    let engine = engine.as_mut().ok_or("voix absente")?;
    for ids in engine.sentences(text)? {
        let samples = engine.synthesize(&ids)?;
        if me.generation.load(Ordering::SeqCst) != generation {
            return Ok(());
        }
        if pipe
            .as_ref()
            .is_some_and(|(_, rate, _)| *rate != engine.rate)
        {
            *pipe = None;
        }
        if pipe.is_none() {
            let (child, stdin) = play(engine.rate)?;
            let mut slot = lock(&me.player);
            // Stopped meanwhile: not a word more.
            if me.generation.load(Ordering::SeqCst) != generation {
                drop(slot);
                let mut child = child;
                let _ = child.kill();
                let _ = child.wait();
                return Ok(());
            }
            if let Some(mut old) = slot.replace(child) {
                // The last answer's player, done or nearly: reaped here.
                let _ = old.try_wait();
            }
            *pipe = Some((generation, engine.rate, stdin));
        }
        if let Some((_, _, stdin)) = pipe.as_mut() {
            // A killed player breaks the pipe: that is how `stop` lands.
            if stdin.write_all(&bytes(&samples)).is_err() {
                *pipe = None;
                return Ok(());
            }
        }
    }
    me.set_error(String::new());
    Ok(())
}

/// `anna say <texte> [fichier.wav]`: speak (or write) a text with the chosen
/// voice, without the daemon.
pub fn say_offline(args: &[String]) {
    let text = args.get(2).cloned().unwrap_or_default();
    if text.trim().is_empty() {
        eprintln!("usage : anna say <texte> [fichier.wav]");
        std::process::exit(2);
    }
    let run = || -> Result<(), String> {
        let settings = Settings::load();
        let voices = voices_in(&voices_dir());
        let choice = std::env::var("ANNA_SPEECH_VOICE")
            .ok()
            .and_then(|id| voices.iter().find(|v| v.id == id).cloned())
            .or_else(|| pick(&voices, &settings.voice, &crate::i18n::voice_lang()).cloned())
            .ok_or_else(|| format!("aucune voix dans {}", voices_dir().display()))?;
        let mut engine = Engine::load(&choice)?;
        let mut all: Vec<i16> = Vec::new();
        let mut splitter = Splitter::default();
        let mut parts = splitter.push(&text);
        parts.extend(splitter.finish());
        for part in parts {
            for ids in engine.sentences(&part)? {
                let started = std::time::Instant::now();
                let samples = engine.synthesize(&ids)?;
                eprintln!(
                    "{} : {:.2} s d'audio en {:.2} s",
                    choice.id,
                    samples.len() as f32 / engine.rate as f32,
                    started.elapsed().as_secs_f32()
                );
                all.extend(samples);
            }
        }
        match args.get(3) {
            Some(path) => {
                let f: Vec<f32> = all.iter().map(|s| *s as f32 / 32767.0).collect();
                std::fs::write(path, super::voice::wav(&f, engine.rate))
                    .map_err(|e| format!("{path} : {e}"))
            }
            None => {
                let (mut child, mut stdin) = play(engine.rate)?;
                stdin.write_all(&bytes(&all)).map_err(|e| e.to_string())?;
                drop(stdin);
                let _ = child.wait();
                Ok(())
            }
        }
    };
    if let Err(e) = run() {
        eprintln!("anna: {e}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_is_read_without_its_marks() {
        assert_eq!(speakable("## **Volume** à 30 %"), "Volume à 30 %");
        assert_eq!(
            speakable("- ouvre `karenine` dans Zed"),
            "ouvre Karénine dans Zed"
        );
        assert_eq!(speakable("1. Premier point"), "Premier point");
        assert_eq!(
            speakable("Voir [la doc](https://example.org/x) ici"),
            "Voir la doc ici"
        );
        assert_eq!(speakable("Lien : https://example.org fin"), "Lien : fin");
        assert_eq!(speakable("|---|---|"), "");
        assert_eq!(speakable("C'est fait ✅"), "C'est fait");
        assert_eq!(speakable("mon_fichier_test"), "mon_fichier_test");
    }

    #[test]
    fn sentences_come_out_as_they_end() {
        let mut s = Splitter::default();
        assert!(s.push("Volume à 30").is_empty());
        assert_eq!(s.push(" %. Zed ouvert"), vec!["Volume à 30 %."]);
        assert!(s.push(" sur karenine").is_empty());
        assert_eq!(s.finish(), vec!["Zed ouvert sur Karénine"]);
    }

    #[test]
    fn numbers_and_lines_split_where_they_should() {
        let mut s = Splitter::default();
        // « 3.5 » has no space after its dot; « 1. » is a list number.
        assert!(s.push("Il reste 3.5 Go").is_empty());
        assert_eq!(s.push("\n1. Premier"), vec!["Il reste 3.5 Go"]);
        assert_eq!(s.finish(), vec!["Premier"]);
    }

    #[test]
    fn code_blocks_are_not_read() {
        let mut s = Splitter::default();
        let mut out = s.push("Voici :\n```sh\nls -la\n");
        out.extend(s.push("echo fin\n```\nC'est tout."));
        out.extend(s.finish());
        assert_eq!(out, vec!["Voici :", "C'est tout."]);
    }

    #[test]
    fn terminators_as_piper_reads_them() {
        // Raw values from espeak-ng 1.52 (« Bonjour, ça va ? Oui ! … »).
        assert_eq!(terminator(0x0048_0028), (".", true));
        assert_eq!(terminator(0x0004_1014), (",", false));
        assert_eq!(terminator(0x0008_2028), ("?", true));
        assert_eq!(terminator(0x0008_302d), ("!", true));
        assert_eq!(terminator(0x0004_001e), (":", false));
        assert_eq!(terminator(0x0004_101e), (";", false));
        // End of text without punctuation; an ellipsis.
        assert_eq!(terminator(0x0009_0028), ("", true));
        assert_eq!(terminator(0x0024_901e), ("", false));
    }

    #[test]
    fn ids_are_padded_between_phonemes() {
        let map: HashMap<String, Vec<i64>> = [("_", 0), ("^", 1), ("$", 2), ("a", 14), ("b", 15)]
            .into_iter()
            .map(|(k, v)| (k.to_string(), vec![v]))
            .collect();
        let p = |s: &str| s.chars().map(|c| c.to_string()).collect::<Vec<_>>();
        assert_eq!(to_ids(&p("ab"), &map), vec![1, 0, 14, 0, 15, 0, 2]);
        // Unknown phonemes are skipped.
        assert_eq!(to_ids(&p("aX"), &map), vec![1, 0, 14, 0, 2]);
    }

    #[test]
    fn language_flags_are_dropped() {
        assert_eq!(strip_flags("(en)zˈɛd(fr) uvˈɛʁ"), "zˈɛd uvˈɛʁ");
    }

    #[test]
    fn voices_are_listed_per_speaker() {
        let dir = std::env::temp_dir().join(format!("anna-voices-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("fr_FR-siwis-medium.onnx"), "").unwrap();
        std::fs::write(
            dir.join("fr_FR-siwis-medium.onnx.json"),
            r#"{"num_speakers":1}"#,
        )
        .unwrap();
        std::fs::write(dir.join("fr_FR-upmc-medium.onnx"), "").unwrap();
        std::fs::write(
            dir.join("fr_FR-upmc-medium.onnx.json"),
            r#"{"num_speakers":2,"speaker_id_map":{"pierre":1,"jessica":0}}"#,
        )
        .unwrap();
        // A model without its config is not a voice.
        std::fs::write(dir.join("en_US-x-low.onnx"), "").unwrap();
        let v = voices_in(&dir);
        let ids: Vec<&str> = v.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "fr_FR-siwis-medium",
                "fr_FR-upmc-medium:jessica",
                "fr_FR-upmc-medium:pierre"
            ]
        );
        assert_eq!(v[0].name, "Siwis (fr_FR)");
        assert_eq!(v[2].name, "Upmc · pierre (fr_FR)");
        assert_eq!(
            pick(&v, "fr_FR-upmc-medium:pierre", "en").unwrap().id,
            ids[2]
        );
        assert_eq!(pick(&v, "", "fr").unwrap().id, ids[0]);
        assert_eq!(pick(&v, "gone", "de").unwrap().id, ids[0]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
