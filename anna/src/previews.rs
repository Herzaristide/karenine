//! The Explorer's previews (`anna previews`): a long-lived worker the shell
//! starts once (services/Previews.qml) and feeds on stdin, one request per
//! line:
//!
//!   <base>\t<path>      the preview of <path>, written next to <base>
//!   clear               forget the requests still waiting (the folder changed)
//!
//! It answers each request on stdout with `<base>\t<file>`, <file> being the
//! preview (`<base>.png`, or `<base>.svg` for a waveform or a piano roll) or
//! empty when there is none. The shell picks <base> in its cache
//! (~/.cache/karenine/previews/<md5 of path|mtime|size>): a file touched
//! gets a new name, so nothing here ever goes stale. A preview already made
//! (or already failed: `<base>.fail`) is answered at once; the others wait
//! for one of two workers, newest request first (what is on screen now).
//!
//!   video       a frame at 10 % of the length (ffprobe, ffmpeg)
//!   audio       the embedded cover, else the waveform (ffmpeg → SVG)
//!   3D model    f3d's thumbnail render, transparent background, through
//!               EGL with no display at all (no window ever shows)
//!   PDF         the first page (pdftoppm)
//!   LilyPond    the first system, engraved (lilypond -dpreview), inside
//!               bubblewrap: a .ly file is a program (Scheme), and one
//!               dropped in ~/drop must not run with the user's rights
//!   MusicXML    musicxml2ly, then as LilyPond
//!   MIDI        a piano roll, read here (→ SVG)
//!   EPUB        the cover named by the package (unzip)
//!
//! Every tool runs under `timeout` (a broken file must not hold a worker),
//! and the whole worker under `nice`/`ionice` (set by the shell). The SVGs
//! are white: the shell tints them to the theme.

use std::collections::VecDeque;
use std::fs;
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

/// The longest side of a raster preview.
const SIZE: u32 = 256;
const WORKERS: usize = 2;
/// Seconds a tool may run (then SIGTERM, and SIGKILL 2 s later).
const TIMEOUT: &str = "20";

#[derive(Clone, Copy, PartialEq)]
enum Kind {
    Video,
    Audio,
    Model,
    Pdf,
    Lily,
    MusicXml,
    Midi,
    Epub,
}

fn kind_of(path: &str) -> Option<Kind> {
    let ext = Path::new(path).extension()?.to_str()?.to_ascii_lowercase();
    Some(match ext.as_str() {
        "mp4" | "m4v" | "mkv" | "webm" | "mov" | "avi" | "mpg" | "mpeg" | "flv" | "ogv" | "wmv"
        | "ts" | "m2ts" | "3gp" => Kind::Video,
        "mp3" | "flac" | "ogg" | "oga" | "opus" | "wav" | "m4a" | "aac" | "aif" | "aiff"
        | "ape" | "wv" | "wma" | "mka" => Kind::Audio,
        "glb" | "gltf" | "obj" | "stl" | "ply" | "fbx" | "3mf" | "dae" | "3ds" | "usd" | "usda"
        | "usdc" | "usdz" => Kind::Model,
        "pdf" => Kind::Pdf,
        "ly" => Kind::Lily,
        "musicxml" | "mxl" => Kind::MusicXml,
        "mid" | "midi" => Kind::Midi,
        "epub" => Kind::Epub,
        _ => return None,
    })
}

struct Job {
    base: String,
    path: String,
}

type Queue = Arc<(Mutex<VecDeque<Job>>, Condvar)>;

pub fn run(_args: &[String]) {
    let queue: Queue = Arc::new((Mutex::new(VecDeque::new()), Condvar::new()));
    let out = Arc::new(Mutex::new(std::io::stdout()));

    for _ in 0..WORKERS {
        let queue = queue.clone();
        let out = out.clone();
        thread::spawn(move || loop {
            let job = {
                let (lock, cv) = &*queue;
                let mut q = lock.lock().unwrap();
                loop {
                    if let Some(job) = q.pop_back() {
                        break job;
                    }
                    q = cv.wait(q).unwrap();
                }
            };
            // Asked twice (the tile came back): the first one made it.
            let file = match cached(&job.base) {
                Some(done) => done,
                None => generate(&job),
            };
            reply(&out, &job.base, &file);
        });
    }

    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line == "clear" {
            queue.0.lock().unwrap().clear();
            continue;
        }
        let Some((base, path)) = line.split_once('\t') else {
            continue;
        };
        if let Some(done) = cached(base) {
            reply(&out, base, &done);
            continue;
        }
        if kind_of(path).is_none() {
            reply(&out, base, "");
            continue;
        }
        let (lock, cv) = &*queue;
        let mut q = lock.lock().unwrap();
        q.retain(|j| j.base != base);
        q.push_back(Job {
            base: base.to_string(),
            path: path.to_string(),
        });
        cv.notify_one();
    }
    // The shell is gone: so are we (the workers with us).
    std::process::exit(0);
}

fn reply(out: &Mutex<std::io::Stdout>, base: &str, file: &str) {
    let mut o = out.lock().unwrap();
    let _ = writeln!(o, "{base}\t{file}");
    let _ = o.flush();
}

/// A preview made before: its file, or "" for a known failure.
fn cached(base: &str) -> Option<String> {
    for ext in ["png", "svg"] {
        let f = format!("{base}.{ext}");
        if Path::new(&f).is_file() {
            return Some(f);
        }
    }
    Path::new(&format!("{base}.fail"))
        .is_file()
        .then(String::new)
}

fn generate(job: &Job) -> String {
    let base = job.base.as_str();
    if let Some(dir) = Path::new(base).parent() {
        let _ = fs::create_dir_all(dir);
    }
    let made = match kind_of(&job.path) {
        Some(Kind::Video) => video(&job.path, base),
        Some(Kind::Audio) => audio(&job.path, base),
        Some(Kind::Model) => model(&job.path, base),
        Some(Kind::Pdf) => pdf(&job.path, base),
        Some(Kind::Lily) => lily(&job.path, base),
        Some(Kind::MusicXml) => musicxml(&job.path, base),
        Some(Kind::Midi) => midi(&job.path, base),
        Some(Kind::Epub) => epub(&job.path, base),
        None => None,
    };
    let _ = fs::remove_file(format!("{base}.part.png"));
    let _ = fs::remove_dir_all(format!("{base}.d"));
    match made {
        Some(f) => f,
        None => {
            let _ = fs::write(format!("{base}.fail"), b"");
            String::new()
        }
    }
}

// ── Running the tools ──────────────────────────────────────────────────────

/// `prog args…` under timeout, silent: did it succeed?
fn ok(prog: &str, args: &[&str], cwd: Option<&Path>) -> bool {
    run_silent(prog, args, cwd, false)
}

/// The same, `headless`: without DISPLAY nor WAYLAND_DISPLAY, so that it
/// cannot open a window even if it tried.
fn run_silent(prog: &str, args: &[&str], cwd: Option<&Path>, headless: bool) -> bool {
    let mut c = Command::new("timeout");
    c.args(["-k", "2", TIMEOUT, prog])
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if let Some(d) = cwd {
        c.current_dir(d);
    }
    if headless {
        c.env_remove("DISPLAY").env_remove("WAYLAND_DISPLAY");
    }
    c.status().map(|s| s.success()).unwrap_or(false)
}

/// Its standard output, if it succeeded.
fn capture(prog: &str, args: &[&str]) -> Option<Vec<u8>> {
    let o = Command::new("timeout")
        .args(["-k", "2", TIMEOUT, prog])
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    o.status.success().then_some(o.stdout)
}

fn nonempty(f: &str) -> bool {
    fs::metadata(f).map(|m| m.len() > 0).unwrap_or(false)
}

/// `<base>.part.png` (or `src`) becomes `<base>.png`.
fn finish_png(src: &str, base: &str) -> Option<String> {
    if !nonempty(src) {
        return None;
    }
    let dst = format!("{base}.png");
    fs::rename(src, &dst).ok()?;
    Some(dst)
}

fn scale_filter() -> String {
    format!("scale={SIZE}:{SIZE}:force_original_aspect_ratio=decrease")
}

/// Any image ffmpeg reads (a cover, an engraving), fitted to SIZE.
fn fit(src: &str, base: &str) -> Option<String> {
    let part = format!("{base}.part.png");
    let vf = scale_filter();
    if !ok(
        "ffmpeg",
        &[
            "-v",
            "error",
            "-y",
            "-i",
            src,
            "-frames:v",
            "1",
            "-vf",
            &vf,
            &part,
        ],
        None,
    ) {
        return None;
    }
    finish_png(&part, base)
}

fn write_svg(base: &str, svg: &str) -> Option<String> {
    let part = format!("{base}.part.svg");
    let dst = format!("{base}.svg");
    fs::write(&part, svg).ok()?;
    fs::rename(&part, &dst).ok()?;
    Some(dst)
}

// ── Video ──────────────────────────────────────────────────────────────────

fn video(path: &str, base: &str) -> Option<String> {
    let length = capture(
        "ffprobe",
        &[
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "csv=p=0",
            path,
        ],
    )
    .and_then(|o| String::from_utf8_lossy(&o).trim().parse::<f64>().ok())
    .unwrap_or(0.0);
    // Past the titles, not the end credits; a keyframe seek (before -i).
    let at = format!("{:.2}", length * 0.1);
    let part = format!("{base}.part.png");
    let vf = scale_filter();
    let args = [
        "-v",
        "error",
        "-y",
        "-ss",
        &at,
        "-i",
        path,
        "-frames:v",
        "1",
        "-an",
        "-vf",
        &vf,
        &part,
    ];
    if !ok("ffmpeg", &args, None) || !nonempty(&part) {
        // Shorter than its own 10 % keyframe, or no duration: the first frame.
        let args = [
            "-v",
            "error",
            "-y",
            "-i",
            path,
            "-frames:v",
            "1",
            "-an",
            "-vf",
            &vf,
            &part,
        ];
        if !ok("ffmpeg", &args, None) {
            return None;
        }
    }
    finish_png(&part, base)
}

// ── Audio ──────────────────────────────────────────────────────────────────

const WAVE_BARS: usize = 40;

fn audio(path: &str, base: &str) -> Option<String> {
    // The cover: the first picture stream (an attached picture).
    let part = format!("{base}.part.png");
    let vf = scale_filter();
    let args = [
        "-v",
        "error",
        "-y",
        "-i",
        path,
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
        "-vf",
        &vf,
        &part,
    ];
    if ok("ffmpeg", &args, None) && nonempty(&part) {
        return finish_png(&part, base);
    }
    // Else the waveform: mono, 2 kHz (the envelope is all we draw), s16le.
    let pcm = capture(
        "ffmpeg",
        &[
            "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", "2000", "-f", "s16le", "-",
        ],
    )?;
    let samples: Vec<i16> = pcm
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect();
    if samples.is_empty() {
        return None;
    }
    write_svg(base, &waveform_svg(&samples))
}

/// WAVE_BARS bars, mirrored around the middle, each the loudest moment of
/// its slice (normalised to the loudest of all).
fn waveform_svg(samples: &[i16]) -> String {
    let n = WAVE_BARS;
    let slice = samples.len().div_ceil(n).max(1);
    let peaks: Vec<f32> = samples
        .chunks(slice)
        .map(|c| c.iter().map(|s| s.unsigned_abs()).max().unwrap_or(0) as f32)
        .collect();
    let top = peaks.iter().cloned().fold(1.0f32, f32::max);
    let (w, h) = (120.0f32, 80.0f32);
    let step = w / n as f32;
    let bar = step * 0.6;
    let mut svg = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" fill="#ffffff">"##
    );
    for (i, p) in peaks.iter().enumerate() {
        let v = (p / top).powf(0.8);
        let bh = (v * (h - 4.0)).max(2.0);
        let x = i as f32 * step + (step - bar) / 2.0;
        let y = (h - bh) / 2.0;
        svg.push_str(&format!(
            r#"<rect x="{x:.2}" y="{y:.2}" width="{bar:.2}" height="{bh:.2}" rx="{:.2}"/>"#,
            bar / 2.0
        ));
    }
    svg.push_str("</svg>");
    svg
}

// ── 3D models ──────────────────────────────────────────────────────────────

fn model(path: &str, base: &str) -> Option<String> {
    let ext = Path::new(path).extension()?.to_str()?.to_ascii_lowercase();
    // The reader f3d's own thumbnailers pick for each format.
    let plugin = match ext.as_str() {
        "fbx" | "3mf" | "dae" => "assimp",
        "usd" | "usda" | "usdc" | "usdz" => "usd",
        _ => "native",
    };
    let part = format!("{base}.part.png");
    let output = format!("--output={part}");
    let resolution = format!("--resolution={SIZE},{SIZE}");
    let plugins = format!("--load-plugins={plugin}");
    // EGL: rendered on the GPU without a window. Left to `auto`, f3d picks
    // GLX, which maps a real (XWayland) window for every preview.
    let args = [
        "--rendering-backend=egl",
        "--config=thumbnail",
        &plugins,
        "--verbose=quiet",
        "--no-background",
        &output,
        &resolution,
        path,
    ];
    if !run_silent("f3d", &args, None, true) {
        return None;
    }
    finish_png(&part, base)
}

// ── PDF ────────────────────────────────────────────────────────────────────

fn pdf(path: &str, base: &str) -> Option<String> {
    // pdftoppm adds the extension itself: <base>.part → <base>.part.png.
    let stem = format!("{base}.part");
    let size = SIZE.to_string();
    let args = [
        "-png",
        "-f",
        "1",
        "-l",
        "1",
        "-scale-to",
        &size,
        "-singlefile",
        path,
        &stem,
    ];
    if !ok("pdftoppm", &args, None) {
        return None;
    }
    finish_png(&format!("{stem}.png"), base)
}

// ── Scores ─────────────────────────────────────────────────────────────────

/// Engrave `ly` (in `cwd`, for its \include) into `dir`, sandboxed: the
/// whole system read-only, `dir` the only place it may write, no network.
fn engrave(ly: &str, cwd: &Path, dir: &Path) -> Option<PathBuf> {
    let d = dir.to_str()?;
    let out = format!("{d}/p");
    let ok = ok(
        "bwrap",
        &[
            "--ro-bind",
            "/",
            "/",
            "--dev",
            "/dev",
            "--proc",
            "/proc",
            // No tmpfs on /tmp: it would hide a score that lives there. Its
            // temporary files go to `dir` instead.
            "--bind",
            d,
            d,
            "--setenv",
            "TMPDIR",
            d,
            "--unshare-all",
            "--die-with-parent",
            "--chdir",
            cwd.to_str()?,
            "lilypond",
            "-dpreview",
            "-dno-print-pages",
            "-dresolution=150",
            "--png",
            "--loglevel=ERROR",
            "-o",
            &out,
            ly,
        ],
        None,
    );
    let preview = dir.join("p.preview.png");
    (ok && preview.is_file()).then_some(preview)
}

fn lily(path: &str, base: &str) -> Option<String> {
    let dir = PathBuf::from(format!("{base}.d"));
    fs::create_dir_all(&dir).ok()?;
    let cwd = Path::new(path).parent()?;
    let png = engrave(path, cwd, &dir)?;
    fit(png.to_str()?, base)
}

fn musicxml(path: &str, base: &str) -> Option<String> {
    let dir = PathBuf::from(format!("{base}.d"));
    fs::create_dir_all(&dir).ok()?;
    let ly = dir.join("score.ly");
    let lys = ly.to_str()?;
    if !ok("musicxml2ly", &["--output", lys, path], None) || !ly.is_file() {
        return None;
    }
    let png = engrave(lys, &dir, &dir)?;
    fit(png.to_str()?, base)
}

// ── MIDI ───────────────────────────────────────────────────────────────────

struct Note {
    track: usize,
    start: u64,
    end: u64,
    pitch: u8,
}

fn midi(path: &str, base: &str) -> Option<String> {
    let data = fs::read(path).ok()?;
    let notes = parse_midi(&data)?;
    if notes.is_empty() {
        return None;
    }
    write_svg(base, &piano_roll_svg(&notes))
}

/// A variable-length quantity at `*i`.
fn vlq(d: &[u8], i: &mut usize) -> Option<u64> {
    let mut v = 0u64;
    for _ in 0..4 {
        let b = *d.get(*i)?;
        *i += 1;
        v = (v << 7) | (b & 0x7f) as u64;
        if b & 0x80 == 0 {
            return Some(v);
        }
    }
    Some(v)
}

/// The notes of a Standard MIDI File, in ticks (tempo changes ignored: the
/// roll shows the shape, not the timing).
fn parse_midi(d: &[u8]) -> Option<Vec<Note>> {
    if d.get(0..4)? != b"MThd" {
        return None;
    }
    let hlen = u32::from_be_bytes(d.get(4..8)?.try_into().ok()?) as usize;
    let mut i = 8 + hlen;
    let mut notes = Vec::new();
    let mut track = 0usize;
    while i + 8 <= d.len() {
        let id = &d[i..i + 4];
        let len = u32::from_be_bytes(d[i + 4..i + 8].try_into().ok()?) as usize;
        let start = i + 8;
        let end = (start + len).min(d.len());
        i = end;
        if id != b"MTrk" {
            continue;
        }
        let t = &d[start..end];
        let mut j = 0usize;
        let mut tick = 0u64;
        let mut status = 0u8;
        // Sounding notes: (channel, pitch) → start tick.
        let mut on: std::collections::HashMap<(u8, u8), u64> = std::collections::HashMap::new();
        let mut any = false;
        while j < t.len() {
            tick += vlq(t, &mut j)?;
            let mut b = *t.get(j)?;
            if b & 0x80 != 0 {
                status = b;
                j += 1;
            } else {
                // Running status: `b` is already the first data byte.
                b = status;
            }
            match b {
                0xff => {
                    j += 1; // meta type
                    let l = vlq(t, &mut j)? as usize;
                    j += l;
                }
                0xf0 | 0xf7 => {
                    let l = vlq(t, &mut j)? as usize;
                    j += l;
                }
                _ => {
                    let kind = b & 0xf0;
                    let ch = b & 0x0f;
                    let n = if kind == 0xc0 || kind == 0xd0 { 1 } else { 2 };
                    let a = *t.get(j)?;
                    let v = if n == 2 { *t.get(j + 1)? } else { 0 };
                    j += n;
                    if kind == 0x90 && v > 0 {
                        on.insert((ch, a), tick);
                    } else if kind == 0x80 || (kind == 0x90 && v == 0) {
                        if let Some(s) = on.remove(&(ch, a)) {
                            notes.push(Note {
                                track,
                                start: s,
                                end: tick.max(s + 1),
                                pitch: a,
                            });
                            any = true;
                        }
                    }
                }
            }
        }
        if any {
            track += 1;
        }
    }
    Some(notes)
}

/// The notes as bars, time across, pitch up; each track its own shade of
/// white (the tint keeps them apart).
fn piano_roll_svg(notes: &[Note]) -> String {
    let (w, h) = (120.0f64, 80.0f64);
    let first = notes.iter().map(|n| n.start).min().unwrap_or(0);
    let last = notes
        .iter()
        .map(|n| n.end)
        .max()
        .unwrap_or(1)
        .max(first + 1);
    let lo = notes.iter().map(|n| n.pitch).min().unwrap_or(60) as f64;
    let hi = notes.iter().map(|n| n.pitch).max().unwrap_or(72) as f64;
    // At least two octaves tall, so a melody does not fill the whole tile.
    let range = (hi - lo + 1.0).max(24.0);
    let lo = lo - ((range - (hi - lo + 1.0)) / 2.0).floor();
    let row = h / range;
    let span = (last - first) as f64;
    let shades = [1.0, 0.55, 0.8, 0.4, 0.68];
    let mut svg = format!(
        r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" fill="#ffffff">"##
    );
    // A dense file: a regular sample of its notes is the same picture.
    let stride = notes.len().div_ceil(3000).max(1);
    for n in notes.iter().step_by(stride) {
        let x = (n.start - first) as f64 / span * w;
        let nw = ((n.end - n.start) as f64 / span * w).max(0.8);
        let y = h - (n.pitch as f64 - lo + 1.0) * row;
        let o = shades[n.track % shades.len()];
        svg.push_str(&format!(
            r#"<rect x="{x:.2}" y="{y:.2}" width="{nw:.2}" height="{:.2}" opacity="{o}"/>"#,
            (row * 0.85).max(0.8)
        ));
    }
    svg.push_str("</svg>");
    svg
}

// ── EPUB ───────────────────────────────────────────────────────────────────

/// The value of `name="…"` (or '…') in an XML tag.
fn attr(tag: &str, name: &str) -> Option<String> {
    for q in ['"', '\''] {
        let key = format!(" {name}={q}");
        if let Some(at) = tag.find(&key) {
            let rest = &tag[at + key.len()..];
            return rest.find(q).map(|e| rest[..e].to_string());
        }
    }
    None
}

/// The `<item …>` tags of an OPF manifest.
fn items(opf: &str) -> Vec<&str> {
    opf.match_indices("<item ")
        .filter_map(|(at, _)| opf[at..].find('>').map(|e| &opf[at..at + e]))
        .collect()
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn epub(path: &str, base: &str) -> Option<String> {
    let container = capture("unzip", &["-p", path, "META-INF/container.xml"])?;
    let container = String::from_utf8_lossy(&container);
    let rootfile = container.find("<rootfile")?;
    let opf_path = attr(&container[rootfile..], "full-path")?;
    let opf = capture("unzip", &["-p", path, &opf_path])?;
    let opf = String::from_utf8_lossy(&opf);
    let items = items(&opf);

    // EPUB 3: properties="cover-image"; EPUB 2: <meta name="cover"
    // content="<id>">; else an image whose id or name says "cover".
    let href = items
        .iter()
        .find(|t| {
            attr(t, "properties").is_some_and(|p| p.split_whitespace().any(|w| w == "cover-image"))
        })
        .and_then(|t| attr(t, "href"))
        .or_else(|| {
            let meta = opf
                .match_indices("<meta ")
                .filter_map(|(at, _)| opf[at..].find('>').map(|e| &opf[at..at + e]))
                .find(|t| attr(t, "name").as_deref() == Some("cover"))?;
            let id = attr(meta, "content")?;
            items
                .iter()
                .find(|t| attr(t, "id").as_deref() == Some(id.as_str()))
                .and_then(|t| attr(t, "href"))
        })
        .or_else(|| {
            items
                .iter()
                .find(|t| {
                    attr(t, "media-type").is_some_and(|m| m.starts_with("image/"))
                        && (attr(t, "id").is_some_and(|i| i.to_lowercase().contains("cover"))
                            || attr(t, "href").is_some_and(|h| h.to_lowercase().contains("cover")))
                })
                .and_then(|t| attr(t, "href"))
        })?;

    let dir = Path::new(&opf_path)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default();
    let entry = percent_decode(&if dir.is_empty() {
        href
    } else {
        format!("{dir}/{href}")
    });
    // unzip reads its names as patterns: escape the wildcards.
    let pattern: String = entry
        .chars()
        .flat_map(|c| match c {
            '[' | ']' | '*' | '?' => vec!['\\', c],
            _ => vec![c],
        })
        .collect();
    let image = capture("unzip", &["-p", path, &pattern])?;
    if image.is_empty() {
        return None;
    }
    let cover = format!("{base}.d");
    fs::create_dir_all(&cover).ok()?;
    let cover = format!("{cover}/cover");
    fs::write(&cover, image).ok()?;
    fit(&cover, base)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kinds_by_extension() {
        assert!(kind_of("/a/b.MP4") == Some(Kind::Video));
        assert!(kind_of("/a/b.flac") == Some(Kind::Audio));
        assert!(kind_of("/a/b.glb") == Some(Kind::Model));
        assert!(kind_of("/a/b.ly") == Some(Kind::Lily));
        assert!(kind_of("/a/b.mid") == Some(Kind::Midi));
        assert!(kind_of("/a/b.txt").is_none());
        assert!(kind_of("/a/noext").is_none());
    }

    #[test]
    fn midi_notes_with_running_status() {
        // Format 0, one track, 96 ticks per quarter: C4 on, (running) E4 on,
        // both off 96 ticks later (note-on velocity 0, running status).
        let mut f = b"MThd\0\0\0\x06\0\0\0\x01\0\x60".to_vec();
        let track: &[u8] = &[
            0x00, 0x90, 60, 100, // C4 on
            0x00, 64, 100, // E4 on (running status)
            0x60, 60, 0, // C4 off (velocity 0)
            0x00, 64, 0, // E4 off
            0x00, 0xff, 0x2f, 0x00, // end of track
        ];
        f.extend_from_slice(b"MTrk");
        f.extend_from_slice(&(track.len() as u32).to_be_bytes());
        f.extend_from_slice(track);
        let notes = parse_midi(&f).unwrap();
        assert_eq!(notes.len(), 2);
        assert!(notes.iter().all(|n| n.start == 0 && n.end == 96));
        assert!(piano_roll_svg(&notes).contains("<rect"));
    }

    #[test]
    fn epub_attributes() {
        let opf = r#"<manifest><item id="c" href="img/My%20Cover.jpg" media-type="image/jpeg" properties="cover-image"/></manifest>"#;
        let it = items(opf);
        assert_eq!(it.len(), 1);
        assert_eq!(attr(it[0], "href").as_deref(), Some("img/My%20Cover.jpg"));
        assert_eq!(percent_decode("img/My%20Cover.jpg"), "img/My Cover.jpg");
    }

    #[test]
    fn waveform_has_every_bar() {
        let s: Vec<i16> = (0..10000)
            .map(|i| ((i as f32 / 50.0).sin() * 20000.0) as i16)
            .collect();
        assert_eq!(waveform_svg(&s).matches("<rect").count(), WAVE_BARS);
    }
}
