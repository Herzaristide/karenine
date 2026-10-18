//! The notes of the « Notes » tab: a wall of cards, Keep-like, kept on this
//! machine only.
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
//!
//! Everything lives in `$XDG_DATA_HOME/anna/notes` (`~/.local/share/…`):
//! `notes.json`, and one file per pasted image, named after its note. The
//! list is rewritten whole (a temporary file, then renamed): a crash never
//! leaves half of it.
//!
//! The daemon also turns every screenshot into an image note
//! (`watch_screenshots`).
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
}

impl Store {
    pub fn open(dir: &Path) -> Store {
        let notes = std::fs::read_to_string(dir.join("notes.json"))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Store { dir: dir.to_path_buf(), notes }
    }

    fn save(&self) -> Result<(), String> {
        std::fs::create_dir_all(&self.dir).map_err(|e| e.to_string())?;
        let tmp = self.dir.join("notes.json.tmp");
        let text = serde_json::to_string_pretty(&self.notes).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, self.dir.join("notes.json")).map_err(|e| e.to_string())
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
    fn new_id(&self) -> String {
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
        let note = note.clone();
        self.save()?;
        Ok(note)
    }

    pub fn pin(&mut self, id: &str) -> Result<Note, String> {
        let note = self.find(id)?;
        note.pinned = !note.pinned;
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
    if types.iter().any(|t| t.starts_with("text/") || *t == "UTF8_STRING" || *t == "STRING") {
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
        (vec!["--type".to_string(), mime_of(&note.image).to_string()],
         std::fs::read(&note.image).map_err(|e| e.to_string())?)
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
        return if words.is_empty() { "aucune note".into() } else { "aucune note ne correspond".into() };
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

/// `XDG_PICTURES_DIR` from `~/.config/user-dirs.dirs`, else `~/Pictures`.
fn pictures_dir() -> PathBuf {
    let home = crate::paths::home_dir();
    std::fs::read_to_string(home.join(".config/user-dirs.dirs"))
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|l| l.trim().strip_prefix("XDG_PICTURES_DIR="))
                .map(|v| v.trim_matches('"').replace("$HOME", &home.to_string_lossy()))
        })
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("Pictures"))
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
        let Ok(entries) = std::fs::read_dir(folder) else { continue };
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

// ── The command line ────────────────────────────────────────────────────────

/// `anna notes …`: one JSON line on stdout, whatever happens.
pub fn run(args: &[String]) {
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    let mut store = Store::open(&dir());
    let note = |r: Result<Note, String>| r.map(|n| json!({ "ok": true, "note": n }));
    let result = match arg(2) {
        "" | "list" => Ok(json!({ "ok": true, "notes": store.sorted() })),
        "add" => note(store.add_text(&args[3.min(args.len())..].join(" "))),
        "paste" => note(paste(&mut store)),
        "edit" => note(store.edit(arg(3), &args[4.min(args.len())..].join(" "))),
        "pin" => note(store.pin(arg(3))),
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
        assert_eq!(choose(&["image/jpeg", "TEXT"], none), Clip::Image("image/jpeg".into(), "jpg"));
        assert_eq!(
            choose(&["text/uri-list", "text/plain"], || "file:///home/a/Mes%20images/chat.JPG\r\n".into()),
            Clip::File(PathBuf::from("/home/a/Mes images/chat.JPG"))
        );
        // A copied file that is not an image: its path, as text.
        assert_eq!(
            choose(&["text/uri-list", "text/plain"], || "file:///home/a/x.pdf".into()),
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
        assert_eq!(std::fs::read(&store.notes[0].image).unwrap(), b"\x89PNG new");
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
        assert_eq!(summary(&s.sorted(), "LAIT courses"), "- Courses / pain, lait");
        assert_eq!(summary(&s.sorted(), "piano"), "aucune note ne correspond");
        let _ = std::fs::remove_dir_all(&s.dir);
    }

    #[test]
    fn screenshots_are_known_by_their_names() {
        assert!(is_shot("screenshot-20261018_223000.png", "screenshot-"));
        assert!(is_shot("capture-20261018_223000.PNG", "capture-"));
        assert!(!is_shot("screenshot-x.png.part", "screenshot-"));
        assert!(!is_shot("photo.png", "capture-"));
    }
}
