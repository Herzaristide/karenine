//! The notes of the « Notes » tab: a wall of cards, Keep-like. Kept on this
//! machine, and, once a Nextcloud account is connected (cloud/), synced with
//! its Notes app: the text notes only, the images stay here.
//!
//! `anna notes <action>` works on the files directly, without the daemon: the
//! shell runs it for each change and reads one JSON line back.
//!
//!   anna notes list                  → {"ok":true,"notes":[Note…]}
//!   anna notes add <text>            → {"ok":true,"note":Note}
//!   anna notes paste                 → the clipboard as a new note
//!   anna notes edit <id> <text>      → its text (an image's caption)
//!   anna notes pin <id>              → pinned ↔ not
//!   anna notes copy <id>             → back to the clipboard
//!   anna notes delete <id>
//!   anna notes sync                  → now, instead of within the minute
//!
//! The wallpaper blackboard (panels/Blackboard.qml) shows the notes that have
//! a place on it, and the chalk strokes drawn around them:
//!
//!   anna notes add --at <x>,<y> [--on <screen>] <text>
//!                                       → a new note, already on the board
//!   anna notes place <id> <x> <y> [<screen>]
//!                                       → on the board (or moved there)
//!   anna notes unplace <id>             → off the board, still a note
//!   anna notes board [list]             → {"ok":true,"strokes":[Stroke…]}
//!   anna notes board draw <json>        → one stroke, or an array of them
//!   anna notes board erase <id>…        → {"ok":true,"strokes":[erased…]}
//!   anna notes board clear [<screen>]   → {"ok":true,"strokes":[erased…]}
//!
//! Positions are fractions of the screen (0 to 1), so a board survives a
//! change of resolution. Erasing returns what it removed: drawing it again is
//! the shell's « undo ».
//!
//! Every screen has its own board. A note's `screen` (and a stroke's) is the
//! key the shell gives that screen (services/Display.qml: its model, else its
//! connector); "" is the interface screen, where everything drawn before
//! there were several boards stays.
//!
//! Everything lives in `$XDG_DATA_HOME/anna/notes` (`~/.local/share/…`):
//! `notes.json`, `board.json` (the strokes), and one file per pasted image,
//! named after its note. Each list is rewritten whole (a temporary file, then renamed): a crash never
//! leaves half of it.
//!
//! The daemon also turns every screenshot into an image note
//! (`watch_screenshots`).
//!
//! `notes.json` stays the copy the shell reads, whether an account is
//! connected or not; `sync.json` next to it is what the sync needs (the
//! notes deleted here, to delete there too). The daemon syncs within seconds
//! of a change, and fetches the server's changes every minute
//! (cloud/notes.rs). The CLI and the daemon both write these files: each
//! change holds `.lock` (`lock`) while it reads and rewrites them.
//!
//! The clipboard is read with `wl-paste`: an image first (a screenshot, an
//! image copied from a browser), then an image file copied from a file
//! manager (`text/uri-list`), then text.

use serde::{Deserialize, Serialize};
use serde_json::json;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Note {
    pub id: String,
    pub text: String,
    /// Absolute path of the image, "" for a text note.
    pub image: String,
    pub pinned: bool,
    /// Unix seconds.
    pub created: u64,
    pub updated: u64,
    /// Its place on the blackboard, None when it is only in the tab.
    pub board: Option<Spot>,
    /// The screen whose board holds it, "" for the interface screen.
    pub screen: String,
    /// Its id in the Nextcloud Notes app, 0 while it is only here.
    pub remote: u64,
    /// The server's version of it, as last seen.
    pub etag: String,
    /// Changed here since it was last sent.
    pub dirty: bool,
}

/// What the sync keeps between two runs (cloud/notes.rs).
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct SyncState {
    /// The account the notes' `remote` ids belong to.
    pub account: String,
    /// Notes deleted here, still to delete on the server.
    pub deleted: Vec<u64>,
    /// The last sync that went through (Unix seconds), and the last error.
    pub last: u64,
    pub error: String,
}

/// A point of the blackboard, as fractions of its width and height.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, Default, PartialEq)]
pub struct Spot {
    pub x: f64,
    pub y: f64,
}

impl Spot {
    /// A spot inside the board, or None for anything that is not a number.
    pub fn new(x: f64, y: f64) -> Option<Spot> {
        (x.is_finite() && y.is_finite()).then(|| Spot {
            x: x.clamp(0.0, 1.0),
            y: y.clamp(0.0, 1.0),
        })
    }

    /// `0.25,0.4`, as `--at` takes it.
    fn parse(text: &str) -> Option<Spot> {
        let (x, y) = text.split_once(',')?;
        Spot::new(x.trim().parse().ok()?, y.trim().parse().ok()?)
    }
}

pub fn dir() -> PathBuf {
    let data = std::env::var("XDG_DATA_HOME")
        .ok()
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::paths::home_dir().join(".local/share"));
    data.join("anna/notes")
}

// ── The store ───────────────────────────────────────────────────────────────

pub struct Store {
    dir: PathBuf,
    pub notes: Vec<Note>,
    pub sync: SyncState,
}

/// Held while a change reads and rewrites the notes' files; released when
/// dropped.
pub struct Lock(#[allow(dead_code)] std::fs::File);

/// Waits for the other writers (the CLI, the daemon's sync) to be done.
pub fn lock(dir: &Path) -> Result<Lock, String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(".lock"))
        .map_err(|e| e.to_string())?;
    file.lock().map_err(|e| e.to_string())?;
    Ok(Lock(file))
}

/// A list rewritten whole: a temporary file, then renamed. A crash never
/// leaves half of it.
fn write_json(dir: &Path, name: &str, value: &impl Serialize) -> Result<(), String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let tmp = dir.join(format!("{name}.tmp"));
    let text = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, dir.join(name)).map_err(|e| e.to_string())
}

fn read_json<T: serde::de::DeserializeOwned + Default>(dir: &Path, name: &str) -> T {
    std::fs::read_to_string(dir.join(name))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

impl Store {
    pub fn open(dir: &Path) -> Store {
        Store {
            dir: dir.to_path_buf(),
            notes: read_json(dir, "notes.json"),
            sync: read_json(dir, "sync.json"),
        }
    }

    fn save(&self) -> Result<(), String> {
        self.save_notes()?;
        self.save_sync()
    }

    /// The notes alone: the shell follows this file, and reloads on every
    /// write.
    pub fn save_notes(&self) -> Result<(), String> {
        write_json(&self.dir, "notes.json", &self.notes)
    }

    pub fn save_sync(&self) -> Result<(), String> {
        write_json(&self.dir, "sync.json", &self.sync)
    }

    /// Pinned first, then the most recently changed; within the same second,
    /// the newest (ids grow with time).
    pub fn sorted(&self) -> Vec<Note> {
        let mut notes = self.notes.clone();
        notes.sort_by(|a, b| {
            b.pinned
                .cmp(&a.pinned)
                .then(b.updated.cmp(&a.updated))
                .then(b.id.len().cmp(&a.id.len()))
                .then(b.id.cmp(&a.id))
        });
        notes
    }

    /// A new id: the time in milliseconds, in hex, bumped past any taken one.
    pub fn new_id(&self) -> String {
        let mut n = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        while self.notes.iter().any(|x| x.id == format!("{n:x}")) {
            n += 1;
        }
        format!("{n:x}")
    }

    fn find(&mut self, id: &str) -> Result<&mut Note, String> {
        self.notes
            .iter_mut()
            .find(|n| n.id == id)
            .ok_or_else(|| crate::i18n::tr("notes.unknown"))
    }

    pub fn add_text(&mut self, text: &str) -> Result<Note, String> {
        if text.trim().is_empty() {
            return Err(crate::i18n::tr("notes.empty"));
        }
        let note = Note {
            id: self.new_id(),
            text: text.to_string(),
            created: now(),
            updated: now(),
            ..Default::default()
        };
        self.notes.push(note.clone());
        self.save()?;
        Ok(note)
    }

    /// An image note, from its bytes and their extension.
    pub fn add_image(&mut self, bytes: &[u8], ext: &str) -> Result<Note, String> {
        if bytes.is_empty() {
            return Err(crate::i18n::tr("notes.empty"));
        }
        std::fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        let id = self.new_id();
        let path = self.dir.join(format!("{id}.{ext}"));
        std::fs::write(&path, bytes).map_err(|e| e.to_string())?;
        let note = Note {
            id,
            image: path.to_string_lossy().into_owned(),
            created: now(),
            updated: now(),
            ..Default::default()
        };
        self.notes.push(note.clone());
        self.save()?;
        Ok(note)
    }

    pub fn edit(&mut self, id: &str, text: &str) -> Result<Note, String> {
        let note = self.find(id)?;
        // A text note emptied is deleted: the shell's « clear and close ».
        if note.image.is_empty() && text.trim().is_empty() {
            return self.delete(id).map(|_| Note::default());
        }
        note.text = text.to_string();
        note.updated = now();
        note.dirty = note.image.is_empty();
        let note = note.clone();
        self.save()?;
        Ok(note)
    }

    pub fn pin(&mut self, id: &str) -> Result<Note, String> {
        let note = self.find(id)?;
        note.pinned = !note.pinned;
        note.dirty = note.image.is_empty();
        let note = note.clone();
        self.save()?;
        Ok(note)
    }

    /// On the board, or moved there. Not « updated »: moving a note does not
    /// bring it to the top of the tab.
    pub fn place(&mut self, id: &str, spot: Spot, screen: &str) -> Result<Note, String> {
        let note = self.find(id)?;
        note.board = Some(spot);
        note.screen = screen.to_string();
        let note = note.clone();
        self.save()?;
        Ok(note)
    }

    pub fn unplace(&mut self, id: &str) -> Result<Note, String> {
        let note = self.find(id)?;
        note.board = None;
        note.screen.clear();
        let note = note.clone();
        self.save()?;
        Ok(note)
    }

    pub fn delete(&mut self, id: &str) -> Result<(), String> {
        let at = self
            .notes
            .iter()
            .position(|n| n.id == id)
            .ok_or_else(|| crate::i18n::tr("notes.unknown"))?;
        let note = self.notes.remove(at);
        if note.remote != 0 {
            self.sync.deleted.push(note.remote);
        }
        // Only an image of our own folder: never a file elsewhere.
        if !note.image.is_empty() && Path::new(&note.image).parent() == Some(self.dir.as_path()) {
            let _ = std::fs::remove_file(&note.image);
        }
        self.save()
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ── The clipboard ───────────────────────────────────────────────────────────

/// What the clipboard holds, in the order a note prefers it.
#[derive(Debug, PartialEq)]
pub enum Clip {
    /// A MIME type to read, and the extension to save it under.
    Image(String, &'static str),
    /// An image file, copied from a file manager.
    File(PathBuf),
    Text,
    Nothing,
}

/// The extension of an image type Qt can show, None for any other.
fn image_ext(mime: &str) -> Option<&'static str> {
    match mime {
        "image/png" => Some("png"),
        "image/jpeg" | "image/jpg" => Some("jpg"),
        "image/webp" => Some("webp"),
        "image/gif" => Some("gif"),
        "image/bmp" => Some("bmp"),
        "image/svg+xml" => Some("svg"),
        _ => None,
    }
}

/// Picks from `wl-paste --list-types`; `uris` reads the `text/uri-list` only
/// when it is needed.
pub fn choose(types: &[&str], uris: impl FnOnce() -> String) -> Clip {
    // PNG first: lossless, and what screenshots and browsers offer.
    for mime in std::iter::once("image/png").chain(types.iter().copied()) {
        if types.contains(&mime) {
            if let Some(ext) = image_ext(mime) {
                return Clip::Image(mime.to_string(), ext);
            }
        }
    }
    if types.contains(&"text/uri-list") {
        let list = uris();
        let file = list
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .find_map(|l| l.strip_prefix("file://").map(percent_decode))
            .map(PathBuf::from)
            .filter(|p| file_ext(p).is_some());
        if let Some(file) = file {
            return Clip::File(file);
        }
    }
    if types
        .iter()
        .any(|t| t.starts_with("text/") || *t == "UTF8_STRING" || *t == "STRING")
    {
        return Clip::Text;
    }
    Clip::Nothing
}

/// The extension of an image file, by its name.
fn file_ext(path: &Path) -> Option<&'static str> {
    let ext = path.extension()?.to_str()?.to_ascii_lowercase();
    match ext.as_str() {
        "png" => Some("png"),
        "jpg" | "jpeg" => Some("jpg"),
        "webp" => Some("webp"),
        "gif" => Some("gif"),
        "bmp" => Some("bmp"),
        "svg" => Some("svg"),
        _ => None,
    }
}

/// `%20` and the like, as file managers write them in URIs.
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

fn wl_paste(args: &[&str]) -> Result<Vec<u8>, String> {
    let out = Command::new("wl-paste")
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| format!("wl-paste : {e}"))?;
    if !out.status.success() {
        return Err(crate::i18n::tr("notes.clipboard_empty"));
    }
    Ok(out.stdout)
}

fn paste(store: &mut Store) -> Result<Note, String> {
    let types = String::from_utf8_lossy(&wl_paste(&["--list-types"])?).into_owned();
    let types: Vec<&str> = types.lines().map(str::trim).collect();
    let uris = || {
        wl_paste(&["--no-newline", "--type", "text/uri-list"])
            .map(|b| String::from_utf8_lossy(&b).into_owned())
            .unwrap_or_default()
    };
    match choose(&types, uris) {
        Clip::Image(mime, ext) => store.add_image(&wl_paste(&["--type", &mime])?, ext),
        Clip::File(path) => {
            let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
            store.add_image(&bytes, file_ext(&path).unwrap_or("png"))
        }
        Clip::Text => {
            let text = wl_paste(&["--no-newline", "--type", "text"])?;
            store.add_text(&String::from_utf8_lossy(&text))
        }
        Clip::Nothing => Err(crate::i18n::tr("notes.clipboard_empty")),
    }
}

/// A note back to the clipboard: its image, or its text.
fn copy(store: &mut Store, id: &str) -> Result<(), String> {
    let note = store.find(id)?.clone();
    let (args, bytes) = if note.image.is_empty() {
        (vec![], note.text.into_bytes())
    } else {
        (
            vec!["--type".to_string(), mime_of(&note.image).to_string()],
            std::fs::read(&note.image).map_err(|e| e.to_string())?,
        )
    };
    let mut child = Command::new("wl-copy")
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("wl-copy : {e}"))?;
    child
        .stdin
        .take()
        .ok_or("wl-copy")?
        .write_all(&bytes)
        .map_err(|e| e.to_string())?;
    // wl-copy forks to serve the clipboard: the parent returns at once.
    child.wait().map_err(|e| e.to_string())?;
    Ok(())
}

fn mime_of(path: &str) -> &'static str {
    match file_ext(Path::new(path)) {
        Some("jpg") => "image/jpeg",
        Some("webp") => "image/webp",
        Some("gif") => "image/gif",
        Some("bmp") => "image/bmp",
        Some("svg") => "image/svg+xml",
        _ => "image/png",
    }
}

// ── The pilot ───────────────────────────────────────────────────────────────

/// The pilot's `creer_note` (claude/desk.rs): a text note, pinned if asked.
pub fn pilot_create(text: &str, pin: bool) -> Result<String, String> {
    let _held = lock(&dir()).ok();
    let mut store = Store::open(&dir());
    let note = store.add_text(text)?;
    if pin {
        store.pin(&note.id)?;
    }
    Ok("note créée dans l'onglet Notes".into())
}

/// The pilot's `lire_notes`: the notes as text, pinned first, those holding
/// every word of `query` when it is not empty.
pub fn pilot_read(query: &str) -> String {
    summary(&Store::open(&dir()).sorted(), query)
}

pub fn summary(notes: &[Note], query: &str) -> String {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    let lines: Vec<String> = notes
        .iter()
        .filter(|n| {
            let text = n.text.to_lowercase();
            words.iter().all(|w| text.contains(w))
        })
        .map(|n| {
            let mut line = String::from("- ");
            if n.pinned {
                line.push_str("[épinglée] ");
            }
            if !n.image.is_empty() {
                line.push_str(&format!("[image {}] ", n.image));
            }
            line.push_str(&n.text.replace('\n', " / "));
            line
        })
        .collect();
    if lines.is_empty() {
        return if words.is_empty() {
            "aucune note".into()
        } else {
            "aucune note ne correspond".into()
        };
    }
    lines.join("\n")
}

// ── Screenshots ─────────────────────────────────────────────────────────────

/// Where the shell's screenshots land, and how their names start: the Print
/// keys and the search (`/tmp/screenshot-…`), the top bar's button
/// (`<Pictures>/capture-…`), the pilot (`/tmp/screenshot-…`, desk.rs).
fn shot_places() -> Vec<(PathBuf, &'static str)> {
    vec![
        (PathBuf::from("/tmp"), "screenshot-"),
        (pictures_dir(), "capture-"),
    ]
}

/// `XDG_PICTURES_DIR`, else `~/Pictures`.
fn pictures_dir() -> PathBuf {
    crate::paths::user_dir("PICTURES", "Pictures")
}

/// Is this file a screenshot of ours, by its name?
pub fn is_shot(name: &str, prefix: &str) -> bool {
    name.starts_with(prefix) && name.to_ascii_lowercase().ends_with(".png")
}

/// Every screenshot taken while the daemon runs becomes an image note.
///
/// The places are read every second (no inotify crate for two folders); a
/// file is taken once its size has stopped changing for a tick, so that
/// grimblast has finished writing it. Older files are left alone.
pub async fn watch_screenshots() {
    watch(shot_places(), dir()).await;
}

async fn watch(places: Vec<(PathBuf, &'static str)>, notes: PathBuf) {
    use std::collections::{HashMap, HashSet};
    let start = SystemTime::now();
    let mut done: HashSet<PathBuf> = HashSet::new();
    let mut sizes: HashMap<PathBuf, u64> = HashMap::new();
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        // The folders are read on a blocking thread: a slow disk must not
        // stall the daemon's other connections.
        let scan_places = places.clone();
        let found = tokio::task::spawn_blocking(move || fresh_shots(&scan_places, start))
            .await
            .unwrap_or_default();
        for (path, len) in found {
            if done.contains(&path) {
                continue;
            }
            if sizes.get(&path) != Some(&len) {
                sizes.insert(path, len);
                continue;
            }
            sizes.remove(&path);
            done.insert(path.clone());
            let notes = notes.clone();
            let added = tokio::task::spawn_blocking(move || {
                let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
                let _held = lock(&notes)?;
                Store::open(&notes).add_image(&bytes, "png")
            })
            .await;
            match added {
                Ok(Ok(_)) => {}
                Ok(Err(e)) => eprintln!("anna: capture vers les notes : {e}"),
                Err(e) => eprintln!("anna: capture vers les notes : {e}"),
            }
        }
    }
}

/// The non-empty screenshots of `places` written since `start`, with their
/// size.
fn fresh_shots(places: &[(PathBuf, &'static str)], start: SystemTime) -> Vec<(PathBuf, u64)> {
    let mut out = Vec::new();
    for (folder, prefix) in places {
        let Ok(entries) = std::fs::read_dir(folder) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if !is_shot(&name, prefix) {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            let fresh = meta.modified().map(|m| m >= start).unwrap_or(false);
            if fresh && meta.len() > 0 {
                out.push((entry.path(), meta.len()));
            }
        }
    }
    out
}

// ── The blackboard's strokes ────────────────────────────────────────────────

/// One line of chalk: its points as fractions of the board.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Stroke {
    pub id: String,
    /// "chalk" (the text color) or "accent".
    pub ink: String,
    /// In logical pixels.
    pub width: f64,
    pub points: Vec<[f64; 2]>,
    /// The screen whose board holds it, "" for the interface screen.
    pub screen: String,
}

/// The inks a stroke may use; the shell picks the colors.
const INKS: [&str; 2] = ["chalk", "accent"];
/// A stroke longer than this is a bug of the caller, not a drawing.
const MAX_POINTS: usize = 20_000;

pub struct Board {
    dir: PathBuf,
    pub strokes: Vec<Stroke>,
}

impl Board {
    pub fn open(dir: &Path) -> Board {
        let strokes = std::fs::read_to_string(dir.join("board.json"))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Board {
            dir: dir.to_path_buf(),
            strokes,
        }
    }

    fn save(&self) -> Result<(), String> {
        std::fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        let tmp = self.dir.join("board.json.tmp");
        let text = serde_json::to_string(&self.strokes).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, self.dir.join("board.json")).map_err(|e| e.to_string())
    }

    /// Strokes drawn, or drawn again by an undo: a stroke keeps its id when
    /// it is free, so that the next undo still finds it. All or nothing: one
    /// bad stroke and none is kept.
    pub fn draw(&mut self, strokes: Vec<Stroke>) -> Result<Vec<Stroke>, String> {
        let bad = || crate::i18n::tr("notes.bad_stroke");
        let mut added: Vec<Stroke> = Vec::with_capacity(strokes.len());
        for mut s in strokes {
            if !INKS.contains(&s.ink.as_str())
                || s.points.is_empty()
                || s.points.len() > MAX_POINTS
                || !s.width.is_finite()
            {
                return Err(bad());
            }
            s.width = s.width.clamp(0.5, 200.0);
            for p in &mut s.points {
                let spot = Spot::new(p[0], p[1]).ok_or_else(bad)?;
                *p = [spot.x, spot.y];
            }
            if s.id.is_empty() || self.taken(&s.id, &added) {
                s.id = self.new_id(&added);
            }
            added.push(s);
        }
        self.strokes.extend(added.iter().cloned());
        self.save()?;
        Ok(added)
    }

    /// The strokes removed, in their order. An unknown id is not an error:
    /// that stroke is already gone.
    pub fn erase(&mut self, ids: &[String]) -> Result<Vec<Stroke>, String> {
        let (gone, kept) = std::mem::take(&mut self.strokes)
            .into_iter()
            .partition(|s| ids.contains(&s.id));
        self.strokes = kept;
        self.save()?;
        Ok(gone)
    }

    /// Every stroke, or only those of one screen's board.
    pub fn clear(&mut self, screen: Option<&str>) -> Result<Vec<Stroke>, String> {
        let (gone, kept) = std::mem::take(&mut self.strokes)
            .into_iter()
            .partition(|s| screen.is_none_or(|k| s.screen == k));
        self.strokes = kept;
        self.save()?;
        Ok(gone)
    }

    fn taken(&self, id: &str, pending: &[Stroke]) -> bool {
        self.strokes.iter().chain(pending).any(|s| s.id == id)
    }

    /// Like the notes' ids, prefixed with `s` so the two never meet.
    fn new_id(&self, pending: &[Stroke]) -> String {
        let mut n = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0);
        while self.taken(&format!("s{n:x}"), pending) {
            n += 1;
        }
        format!("s{n:x}")
    }
}

/// `draw`'s argument: one stroke, or an array of them.
fn parse_strokes(text: &str) -> Result<Vec<Stroke>, String> {
    let bad = |_| crate::i18n::tr("notes.bad_stroke");
    let value: serde_json::Value = serde_json::from_str(text).map_err(bad)?;
    let value = if value.is_array() {
        value
    } else {
        json!([value])
    };
    serde_json::from_value(value).map_err(bad)
}

fn board_run(args: &[String]) -> Result<serde_json::Value, String> {
    let mut board = Board::open(&dir());
    let rest = &args[1.min(args.len())..];
    let strokes = |r: Result<Vec<Stroke>, String>| r.map(|s| json!({ "ok": true, "strokes": s }));
    match args.first().map(String::as_str).unwrap_or("") {
        "" | "list" => Ok(json!({ "ok": true, "strokes": board.strokes })),
        "draw" => strokes(parse_strokes(&rest.join(" ")).and_then(|s| board.draw(s))),
        "erase" => strokes(board.erase(rest)),
        "clear" => strokes(board.clear(rest.first().map(String::as_str))),
        other => Err(format!("notes board : action inconnue « {other} »")),
    }
}

/// `add`'s arguments: `--at x,y` first when given, then `--on <screen>` when
/// given, then the text. The spot is None when absent, Some(None) when it
/// does not parse; the screen "" when absent.
fn add_args(args: &[String]) -> (Option<Option<Spot>>, String, String) {
    let (at, args) = match args {
        [flag, at, rest @ ..] if flag == "--at" => (Some(Spot::parse(at)), rest),
        _ => (None, args),
    };
    match args {
        [flag, screen, rest @ ..] if flag == "--on" => (at, screen.clone(), rest.join(" ")),
        _ => (at, String::new(), args.join(" ")),
    }
}

fn add(store: &mut Store, args: &[String]) -> Result<Note, String> {
    let (at, screen, text) = add_args(args);
    let spot = match at {
        None => None,
        Some(None) => return Err(crate::i18n::tr("notes.bad_position")),
        Some(spot) => spot,
    };
    let note = store.add_text(&text)?;
    match spot {
        Some(spot) => store.place(&note.id, spot, &screen),
        None => Ok(note),
    }
}

fn place(store: &mut Store, id: &str, x: &str, y: &str, screen: &str) -> Result<Note, String> {
    let spot = match (x.parse(), y.parse()) {
        (Ok(x), Ok(y)) => Spot::new(x, y),
        _ => None,
    };
    store.place(
        id,
        spot.ok_or_else(|| crate::i18n::tr("notes.bad_position"))?,
        screen,
    )
}

// ── The command line ────────────────────────────────────────────────────────

/// `anna notes …`: one JSON line on stdout, whatever happens.
pub fn run(args: &[String]) {
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    // The sync takes the lock itself, between its requests.
    if arg(2) == "sync" {
        let line = match crate::cloud::notes::sync_now(&dir()) {
            Ok(changed) => json!({ "ok": true, "changed": changed }),
            Err(e) => json!({ "ok": false, "error": e }),
        };
        println!("{line}");
        return;
    }
    // Without the lock (a read-only home), the change still goes through.
    let _held = lock(&dir()).ok();
    let mut store = Store::open(&dir());
    let note = |r: Result<Note, String>| r.map(|n| json!({ "ok": true, "note": n }));
    let result = match arg(2) {
        "" | "list" => Ok(json!({ "ok": true, "notes": store.sorted() })),
        "add" => note(add(&mut store, &args[3.min(args.len())..])),
        "paste" => note(paste(&mut store)),
        "edit" => note(store.edit(arg(3), &args[4.min(args.len())..].join(" "))),
        "pin" => note(store.pin(arg(3))),
        "place" => note(place(&mut store, arg(3), arg(4), arg(5), arg(6))),
        "unplace" => note(store.unplace(arg(3))),
        "board" => board_run(&args[3.min(args.len())..]),
        "copy" => copy(&mut store, arg(3)).map(|_| json!({ "ok": true })),
        "delete" => store.delete(arg(3)).map(|_| json!({ "ok": true })),
        other => Err(format!("notes : action inconnue « {other} »")),
    };
    let line = result.unwrap_or_else(|e| json!({ "ok": false, "error": e }));
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_store(name: &str) -> Store {
        let dir = std::env::temp_dir().join(format!("anna-notes-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Store::open(&dir)
    }

    #[test]
    fn notes_survive_a_reopen_pinned_first() {
        let mut s = temp_store("reopen");
        let a = s.add_text("première").unwrap();
        let b = s.add_text("deuxième").unwrap();
        assert_ne!(a.id, b.id);
        s.pin(&a.id).unwrap();
        let s = Store::open(&s.dir);
        let sorted = s.sorted();
        assert_eq!(sorted.len(), 2);
        assert_eq!(sorted[0].id, a.id);
        assert!(sorted[0].pinned);
        let _ = std::fs::remove_dir_all(&s.dir);
    }

    #[test]
    fn an_image_is_stored_and_deleted_with_its_note() {
        let mut s = temp_store("image");
        let n = s.add_image(b"\x89PNG", "png").unwrap();
        assert!(Path::new(&n.image).exists());
        s.edit(&n.id, "légende").unwrap();
        s.delete(&n.id).unwrap();
        assert!(!Path::new(&n.image).exists());
        assert!(s.notes.is_empty());
        let _ = std::fs::remove_dir_all(&s.dir);
    }

    #[test]
    fn emptying_a_text_note_deletes_it() {
        let mut s = temp_store("empty");
        assert!(s.add_text("   ").is_err());
        let n = s.add_text("x").unwrap();
        s.edit(&n.id, "").unwrap();
        assert!(s.notes.is_empty());
        let _ = std::fs::remove_dir_all(&s.dir);
    }

    #[test]
    fn notes_saved_with_a_color_still_load() {
        let s = temp_store("legacy");
        std::fs::create_dir_all(&s.dir).unwrap();
        std::fs::write(
            s.dir.join("notes.json"),
            r#"[{"id":"1","text":"x","image":"","color":"teal","pinned":true,"created":1,"updated":1}]"#,
        )
        .unwrap();
        let s = Store::open(&s.dir);
        assert_eq!(s.notes.len(), 1);
        assert!(s.notes[0].pinned);
        let _ = std::fs::remove_dir_all(&s.dir);
    }

    #[test]
    fn the_clipboard_prefers_png_then_files_then_text() {
        let none = || String::new();
        assert_eq!(
            choose(&["text/plain", "image/jpeg", "image/png"], none),
            Clip::Image("image/png".into(), "png")
        );
        assert_eq!(
            choose(&["image/jpeg", "TEXT"], none),
            Clip::Image("image/jpeg".into(), "jpg")
        );
        assert_eq!(
            choose(&["text/uri-list", "text/plain"], || {
                "file:///home/a/Mes%20images/chat.JPG\r\n".into()
            }),
            Clip::File(PathBuf::from("/home/a/Mes images/chat.JPG"))
        );
        // A copied file that is not an image: its path, as text.
        assert_eq!(
            choose(&["text/uri-list", "text/plain"], || "file:///home/a/x.pdf"
                .into()),
            Clip::Text
        );
        assert_eq!(choose(&["text/plain;charset=utf-8"], none), Clip::Text);
        assert_eq!(choose(&["application/x-thing"], none), Clip::Nothing);
    }

    #[tokio::test]
    async fn a_new_screenshot_becomes_a_note_once() {
        let base = std::env::temp_dir().join(format!("anna-shots-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let (shots, notes) = (base.join("shots"), base.join("notes"));
        std::fs::create_dir_all(&shots).unwrap();
        // Older than the watch: left alone.
        std::fs::write(shots.join("screenshot-old.png"), b"\x89PNG old").unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(1100)).await;
        let task = tokio::spawn(watch(vec![(shots.clone(), "screenshot-")], notes.clone()));
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        std::fs::write(shots.join("screenshot-new.png"), b"\x89PNG new").unwrap();
        std::fs::write(shots.join("autre.png"), b"\x89PNG").unwrap();
        tokio::time::sleep(std::time::Duration::from_millis(3500)).await;
        task.abort();
        let store = Store::open(&notes);
        assert_eq!(store.notes.len(), 1);
        assert_eq!(
            std::fs::read(&store.notes[0].image).unwrap(),
            b"\x89PNG new"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn the_pilot_reads_notes_as_lines() {
        let mut s = temp_store("summary");
        assert_eq!(summary(&s.sorted(), ""), "aucune note");
        s.add_text("Courses\npain, lait").unwrap();
        let rdv = s.add_text("RDV dentiste jeudi").unwrap();
        s.pin(&rdv.id).unwrap();
        s.add_image(b"\x89PNG", "png").unwrap();
        let all = summary(&s.sorted(), "");
        assert!(all.starts_with("- [épinglée] RDV dentiste jeudi"));
        assert!(all.contains("- Courses / pain, lait"));
        assert!(all.contains("[image "));
        assert_eq!(
            summary(&s.sorted(), "LAIT courses"),
            "- Courses / pain, lait"
        );
        assert_eq!(summary(&s.sorted(), "piano"), "aucune note ne correspond");
        let _ = std::fs::remove_dir_all(&s.dir);
    }

    fn strings(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    fn stroke(id: &str, points: &[[f64; 2]]) -> Stroke {
        Stroke {
            id: id.into(),
            ink: "chalk".into(),
            width: 3.0,
            points: points.to_vec(),
            screen: String::new(),
        }
    }

    #[test]
    fn a_note_goes_on_the_board_and_off_it() {
        let mut s = temp_store("place");
        let n = add(&mut s, &strings(&["--at", "0.25,1.5", "au", "tableau"])).unwrap();
        assert_eq!(n.text, "au tableau");
        // Clamped to the board.
        assert_eq!(n.board, Some(Spot { x: 0.25, y: 1.0 }));
        let moved = place(&mut s, &n.id, "0.5", "0.1", "").unwrap();
        assert_eq!(moved.board, Some(Spot { x: 0.5, y: 0.1 }));
        // Moving it does not bring it to the top of the tab.
        assert_eq!(moved.updated, n.updated);
        assert!(place(&mut s, &n.id, "x", "0.1", "").is_err());
        assert!(add(&mut s, &strings(&["--at", "nan,0", "x"])).is_err());
        let s2 = Store::open(&s.dir);
        assert_eq!(s2.notes[0].board, Some(Spot { x: 0.5, y: 0.1 }));
        assert_eq!(s.unplace(&n.id).unwrap().board, None);
        // Without --at, a note of the tab only.
        assert_eq!(add(&mut s, &strings(&["juste", "là"])).unwrap().board, None);
        let _ = std::fs::remove_dir_all(&s.dir);
    }

    #[test]
    fn each_screen_has_its_own_board() {
        let mut s = temp_store("screens");
        let n = add(
            &mut s,
            &strings(&["--at", "0.1,0.2", "--on", "LG ULTRAGEAR", "à", "droite"]),
        )
        .unwrap();
        assert_eq!(n.text, "à droite");
        assert_eq!(n.screen, "LG ULTRAGEAR");
        // Moved to another screen, then back to the interface screen.
        assert_eq!(
            place(&mut s, &n.id, "0.5", "0.5", "eDP-1").unwrap().screen,
            "eDP-1"
        );
        assert_eq!(place(&mut s, &n.id, "0.5", "0.5", "").unwrap().screen, "");
        // Off the board, it belongs to no screen.
        place(&mut s, &n.id, "0.5", "0.5", "eDP-1").unwrap();
        assert_eq!(s.unplace(&n.id).unwrap().screen, "");
        // Without --on: the interface screen.
        let m = add(&mut s, &strings(&["--at", "0,0", "ici"])).unwrap();
        assert_eq!((m.screen.as_str(), m.text.as_str()), ("", "ici"));
        let _ = std::fs::remove_dir_all(&s.dir);

        let dir = std::env::temp_dir().join(format!("anna-board-screens-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut b = Board::open(&dir);
        let mut there = stroke("", &[[0.3, 0.3]]);
        there.screen = "eDP-1".into();
        b.draw(vec![stroke("", &[[0.1, 0.1]]), there]).unwrap();
        assert_eq!(Board::open(&dir).strokes[1].screen, "eDP-1");
        // Clearing one board leaves the others.
        let gone = b.clear(Some("eDP-1")).unwrap();
        assert_eq!(gone.len(), 1);
        assert_eq!(gone[0].screen, "eDP-1");
        assert_eq!(b.strokes.len(), 1);
        assert_eq!(b.strokes[0].screen, "");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn notes_saved_before_the_board_still_load() {
        let s = temp_store("preboard");
        std::fs::create_dir_all(&s.dir).unwrap();
        std::fs::write(
            s.dir.join("notes.json"),
            r#"[{"id":"1","text":"x","image":"","pinned":false,"created":1,"updated":1}]"#,
        )
        .unwrap();
        let s = Store::open(&s.dir);
        assert_eq!(s.notes.len(), 1);
        assert_eq!(s.notes[0].board, None);
        let _ = std::fs::remove_dir_all(&s.dir);
    }

    #[test]
    fn strokes_are_drawn_erased_and_drawn_again() {
        let dir = std::env::temp_dir().join(format!("anna-board-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut b = Board::open(&dir);
        let drawn = b
            .draw(vec![
                stroke("", &[[0.1, 0.1], [2.0, -1.0]]),
                stroke("", &[[0.5, 0.5]]),
            ])
            .unwrap();
        assert_eq!(drawn.len(), 2);
        assert_ne!(drawn[0].id, drawn[1].id);
        assert!(drawn[0].id.starts_with('s'));
        assert_eq!(drawn[0].points[1], [1.0, 0.0]);

        let gone = b.erase(&[drawn[0].id.clone(), "inconnu".into()]).unwrap();
        assert_eq!(gone, vec![drawn[0].clone()]);
        assert_eq!(Board::open(&dir).strokes, vec![drawn[1].clone()]);

        // Undo: drawn again, under the same id.
        let back = b.draw(gone).unwrap();
        assert_eq!(back[0].id, drawn[0].id);
        // An id already on the board is not reused.
        let twin = b.draw(vec![stroke(&drawn[1].id, &[[0.0, 0.0]])]).unwrap();
        assert_ne!(twin[0].id, drawn[1].id);

        let cleared = b.clear(None).unwrap();
        assert_eq!(cleared.len(), 3);
        assert!(Board::open(&dir).strokes.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_bad_stroke_draws_nothing() {
        let dir = std::env::temp_dir().join(format!("anna-board-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut b = Board::open(&dir);
        let mut odd = stroke("", &[[0.1, 0.1]]);
        odd.ink = "red".into();
        assert!(b.draw(vec![stroke("", &[[0.2, 0.2]]), odd]).is_err());
        assert!(b.draw(vec![stroke("", &[])]).is_err());
        assert!(b.draw(vec![stroke("", &[[f64::NAN, 0.0]])]).is_err());
        assert!(b.strokes.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn draw_takes_one_stroke_or_many() {
        let one = parse_strokes(r#"{"ink":"accent","width":4,"points":[[0.1,0.2]]}"#).unwrap();
        assert_eq!(one.len(), 1);
        assert_eq!(one[0].ink, "accent");
        let many =
            parse_strokes(r#"[{"ink":"chalk","points":[[0,0]]},{"ink":"chalk","points":[[1,1]]}]"#)
                .unwrap();
        assert_eq!(many.len(), 2);
        assert!(parse_strokes("pas du json").is_err());
    }

    #[test]
    fn screenshots_are_known_by_their_names() {
        assert!(is_shot("screenshot-20261018_223000.png", "screenshot-"));
        assert!(is_shot("capture-20261018_223000.PNG", "capture-"));
        assert!(!is_shot("screenshot-x.png.part", "screenshot-"));
        assert!(!is_shot("photo.png", "capture-"));
    }
}
