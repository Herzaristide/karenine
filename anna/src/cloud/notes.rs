//! The notes, synced with the Nextcloud Notes app of the account (its REST
//! API, `/index.php/apps/notes/api/v1/notes`).
//!
//! `notes.json` stays the copy the shell reads (notes.rs): a sync only
//! rewrites it. The text notes go to the server; the images stay here.
//! A note's text is the server note's content (Nextcloud takes its title
//! from the first line), « pinned » is its favorite.
//!
//! One run:
//!   1. under the lock, a snapshot of what has to go (new notes, notes
//!      changed here, notes deleted here);
//!   2. without it, the requests: deletions, then each change (a conflict —
//!      the note changed on both sides — goes to the newest), then the
//!      server's whole list;
//!   3. under the lock again, the answers merged into the notes as they are
//!      now: a note edited during the requests stays to send.
//!
//! The daemon runs it within seconds of a change here, and every minute for
//! the changes made elsewhere (`sync_loop`).

use super::{send, Account, Fail};
use crate::notes::{lock, Note, Store};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::Path;
use std::time::{Duration, Instant};

/// The server's changes are fetched this often.
const PULL_EVERY: Duration = Duration::from_secs(60);
/// A change here is looked for this often.
const TICK: Duration = Duration::from_secs(5);

/// A note as the server has it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Remote {
    pub id: u64,
    pub etag: String,
    /// Unix seconds.
    pub modified: u64,
    pub content: String,
    pub favorite: bool,
    pub readonly: bool,
}

impl Remote {
    fn parse(v: &Value) -> Option<Remote> {
        Some(Remote {
            id: v.get("id")?.as_u64()?,
            etag: v.get("etag").and_then(Value::as_str).unwrap_or("").into(),
            modified: v.get("modified").and_then(Value::as_u64).unwrap_or(0),
            content: v
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or("")
                .into(),
            favorite: v.get("favorite").and_then(Value::as_bool).unwrap_or(false),
            readonly: v.get("readonly").and_then(Value::as_bool).unwrap_or(false),
        })
    }
}

/// What the sync asks of the server; a trait so that the tests can stand in
/// for it.
pub trait Api {
    fn list(&self) -> Result<Vec<Remote>, Fail>;
    fn get(&self, id: u64) -> Result<Remote, Fail>;
    fn create(&self, text: &str, favorite: bool) -> Result<Remote, Fail>;
    /// `etag`: only if the server still has that version (else 412).
    fn update(
        &self,
        id: u64,
        etag: Option<&str>,
        text: &str,
        favorite: bool,
    ) -> Result<Remote, Fail>;
    fn delete(&self, id: u64) -> Result<(), Fail>;
}

/// The title Nextcloud files the note under: its first line, without the
/// heading marks.
pub fn title(text: &str) -> String {
    let line = text
        .lines()
        .map(|l| l.trim().trim_start_matches('#').trim())
        .find(|l| !l.is_empty())
        .unwrap_or("");
    let title: String = line.chars().take(80).collect();
    if title.is_empty() {
        "Note".into()
    } else {
        title
    }
}

pub struct NotesApi<'a> {
    pub account: &'a Account,
}

impl NotesApi<'_> {
    fn url(&self, id: Option<u64>) -> String {
        let base = format!(
            "{}/index.php/apps/notes/api/v1/notes",
            self.account.config.server
        );
        match id {
            Some(id) => format!("{base}/{id}"),
            None => base,
        }
    }

    fn one(text: &str) -> Result<Remote, Fail> {
        serde_json::from_str::<Value>(text)
            .ok()
            .as_ref()
            .and_then(Remote::parse)
            .ok_or_else(|| Fail::Net("réponse illisible".into()))
    }

    fn body(text: &str, favorite: bool) -> String {
        json!({ "title": title(text), "content": text, "favorite": favorite }).to_string()
    }
}

impl Api for NotesApi<'_> {
    fn list(&self) -> Result<Vec<Remote>, Fail> {
        let req = self
            .account
            .request("GET", &self.url(None))
            .set("Accept", "application/json");
        let text = send(req, None)?;
        let all: Value =
            serde_json::from_str(&text).map_err(|_| Fail::Net("réponse illisible".into()))?;
        Ok(all
            .as_array()
            .map(|a| a.iter().filter_map(Remote::parse).collect())
            .unwrap_or_default())
    }

    fn get(&self, id: u64) -> Result<Remote, Fail> {
        let req = self
            .account
            .request("GET", &self.url(Some(id)))
            .set("Accept", "application/json");
        Self::one(&send(req, None)?)
    }

    fn create(&self, text: &str, favorite: bool) -> Result<Remote, Fail> {
        let req = self
            .account
            .request("POST", &self.url(None))
            .set("Accept", "application/json");
        Self::one(&send(
            req,
            Some(("application/json", &Self::body(text, favorite))),
        )?)
    }

    fn update(
        &self,
        id: u64,
        etag: Option<&str>,
        text: &str,
        favorite: bool,
    ) -> Result<Remote, Fail> {
        let mut req = self
            .account
            .request("PUT", &self.url(Some(id)))
            .set("Accept", "application/json");
        if let Some(etag) = etag.filter(|e| !e.is_empty()) {
            req = req.set("If-Match", &format!("\"{etag}\""));
        }
        Self::one(&send(
            req,
            Some(("application/json", &Self::body(text, favorite))),
        )?)
    }

    fn delete(&self, id: u64) -> Result<(), Fail> {
        send(self.account.request("DELETE", &self.url(Some(id))), None).map(|_| ())
    }
}

// ── One run ─────────────────────────────────────────────────────────────────

/// A note sent, and what the server made of it.
#[derive(Debug, Clone)]
struct Sent {
    /// The local note, and the text and pin that were sent.
    local: String,
    text: String,
    pinned: bool,
    remote: Remote,
    /// The server's version won a conflict: it replaces the local one.
    adopt: bool,
}

#[derive(Debug, Default)]
struct Outcome {
    deleted: Vec<u64>,
    sent: Vec<Sent>,
    /// The server's notes, when the run got that far.
    list: Option<Vec<Remote>>,
    error: Option<String>,
}

/// A note that has to go: new here, or changed since it was last sent.
fn to_send(n: &Note) -> bool {
    n.image.is_empty() && !n.text.trim().is_empty() && (n.remote == 0 || n.dirty)
}

/// Is there anything to send?
pub fn pending(store: &Store) -> bool {
    !store.sync.deleted.is_empty() || store.notes.iter().any(to_send)
}

/// Sends one note; a conflict goes to the newest side.
fn send_one(api: &dyn Api, n: &Note) -> Result<Sent, Fail> {
    let sent = |remote: Remote, adopt: bool| Sent {
        local: n.id.clone(),
        text: n.text.clone(),
        pinned: n.pinned,
        remote,
        adopt,
    };
    if n.remote == 0 {
        return api.create(&n.text, n.pinned).map(|r| sent(r, false));
    }
    match api.update(n.remote, Some(&n.etag), &n.text, n.pinned) {
        Ok(r) => Ok(sent(r, false)),
        // Deleted on the server: the edit made here brings it back.
        Err(Fail::Status(404)) => api.create(&n.text, n.pinned).map(|r| sent(r, false)),
        // Changed on both sides, or shared read-only with us.
        Err(Fail::Status(code @ (403 | 412))) => {
            let theirs = api.get(n.remote)?;
            if code == 403 || theirs.readonly || theirs.modified > n.updated {
                Ok(sent(theirs, true))
            } else {
                api.update(n.remote, None, &n.text, n.pinned)
                    .map(|r| sent(r, false))
            }
        }
        Err(e) => Err(e),
    }
}

/// The requests, from a snapshot of the notes. Stops at the first failure,
/// keeping what was done before it.
fn exchange(api: &dyn Api, snapshot: &Store) -> Outcome {
    let mut out = Outcome::default();
    for &id in &snapshot.sync.deleted {
        match api.delete(id) {
            Ok(()) | Err(Fail::Status(404)) => out.deleted.push(id),
            Err(e) => {
                out.error = Some(e.to_string());
                return out;
            }
        }
    }
    for n in snapshot.notes.iter().filter(|n| to_send(n)) {
        match send_one(api, n) {
            Ok(s) => out.sent.push(s),
            Err(e) => {
                out.error = Some(e.to_string());
                return out;
            }
        }
    }
    match api.list() {
        Ok(list) => out.list = Some(list),
        Err(e) => out.error = Some(e.to_string()),
    }
    out
}

/// The answers, merged into the notes as they are now. True when the notes
/// changed.
fn merge(store: &mut Store, out: &Outcome) -> bool {
    let mut changed = false;
    store.sync.deleted.retain(|id| !out.deleted.contains(id));

    for s in &out.sent {
        let Some(n) = store.notes.iter_mut().find(|n| n.id == s.local) else {
            // Deleted here while it was being sent: deleted there next.
            store.sync.deleted.push(s.remote.id);
            continue;
        };
        let untouched = n.text == s.text && n.pinned == s.pinned;
        n.remote = s.remote.id;
        n.etag = s.remote.etag.clone();
        n.dirty = !untouched;
        if untouched && s.adopt {
            n.text = s.remote.content.clone();
            n.pinned = s.remote.favorite;
            n.updated = s.remote.modified;
        }
        changed = true;
    }

    let Some(list) = &out.list else {
        return changed;
    };
    let there: HashSet<u64> = list.iter().map(|r| r.id).collect();
    // Gone from the server: deleted elsewhere. One edited here since goes
    // back as a new note.
    let before = store.notes.len();
    store.notes.retain_mut(|n| {
        if n.remote == 0 || there.contains(&n.remote) {
            return true;
        }
        if n.dirty {
            n.remote = 0;
            n.etag.clear();
            return true;
        }
        false
    });
    changed |= store.notes.len() != before;

    for r in list {
        if store.sync.deleted.contains(&r.id) {
            continue;
        }
        match store.notes.iter_mut().find(|n| n.remote == r.id) {
            // Changed elsewhere, and not here.
            Some(n) if !n.dirty && n.etag != r.etag => {
                n.text = r.content.clone();
                n.pinned = r.favorite;
                n.updated = r.modified;
                n.etag = r.etag.clone();
                changed = true;
            }
            Some(_) => {}
            // New elsewhere. An empty note (just created in the app) waits
            // for its text.
            None if !r.content.trim().is_empty() => {
                let note = Note {
                    id: store.new_id(),
                    text: r.content.clone(),
                    pinned: r.favorite,
                    created: r.modified,
                    updated: r.modified,
                    remote: r.id,
                    etag: r.etag.clone(),
                    ..Default::default()
                };
                store.notes.push(note);
                changed = true;
            }
            None => {}
        }
    }
    changed
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// One run against `api`, for the account `key`. True when the notes
/// changed.
pub fn sync(dir: &Path, key: &str, api: &dyn Api) -> Result<bool, String> {
    let snapshot = {
        let _held = lock(dir)?;
        let mut store = Store::open(dir);
        // Another account: the ids of the old one mean nothing there, every
        // text note is sent as new.
        if store.sync.account != key {
            for n in &mut store.notes {
                n.remote = 0;
                n.etag.clear();
                n.dirty = false;
            }
            store.sync = crate::notes::SyncState {
                account: key.to_string(),
                ..Default::default()
            };
            store.save_notes()?;
            store.save_sync()?;
        }
        store
    };

    let out = exchange(api, &snapshot);

    let _held = lock(dir)?;
    let mut store = Store::open(dir);
    let changed = merge(&mut store, &out);
    if changed {
        store.save_notes()?;
    }
    match &out.error {
        None => {
            store.sync.last = now();
            store.sync.error.clear();
        }
        Some(e) => store.sync.error = e.clone(),
    }
    store.save_sync()?;
    match out.error {
        Some(e) => Err(e),
        None => Ok(changed),
    }
}

/// `anna notes sync`: one run now, with the connected account.
pub fn sync_now(dir: &Path) -> Result<bool, String> {
    let account = Account::load()?;
    sync(dir, &account.config.key(), &NotesApi { account: &account })
}

/// The daemon's part: a run within seconds of a change here, and every
/// minute for the changes made elsewhere. After a failure (offline), the
/// next try waits the minute.
pub async fn sync_loop() {
    let mut last_run: Option<Instant> = None;
    let mut failed = false;
    loop {
        tokio::time::sleep(TICK).await;
        if super::Config::load().is_none() {
            continue;
        }
        let since = last_run.map(|t| t.elapsed()).unwrap_or(Duration::MAX);
        let dir = crate::notes::dir();
        let local = {
            let dir = dir.clone();
            tokio::task::spawn_blocking(move || pending(&Store::open(&dir)))
                .await
                .unwrap_or(false)
        };
        let due = since >= PULL_EVERY || (local && !failed);
        if !due {
            continue;
        }
        last_run = Some(Instant::now());
        let result = tokio::task::spawn_blocking(move || sync_now(&dir)).await;
        failed = match result {
            Ok(Ok(_)) => false,
            Ok(Err(e)) => {
                eprintln!("anna: synchro des notes : {e}");
                true
            }
            Err(e) => {
                eprintln!("anna: synchro des notes : {e}");
                true
            }
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// A Nextcloud Notes in memory.
    #[derive(Default)]
    struct Fake {
        notes: RefCell<Vec<Remote>>,
        next: RefCell<u64>,
        offline: bool,
    }

    impl Fake {
        fn put(&self, id: u64, text: &str, favorite: bool) -> Remote {
            let r = Remote {
                id,
                etag: format!("e{id}-{}", text.len()),
                modified: 2_000_000_000,
                content: text.into(),
                favorite,
                readonly: false,
            };
            let mut notes = self.notes.borrow_mut();
            notes.retain(|n| n.id != id);
            notes.push(r.clone());
            r
        }
    }

    impl Api for Fake {
        fn list(&self) -> Result<Vec<Remote>, Fail> {
            if self.offline {
                return Err(Fail::Net("hors ligne".into()));
            }
            Ok(self.notes.borrow().clone())
        }
        fn get(&self, id: u64) -> Result<Remote, Fail> {
            self.notes
                .borrow()
                .iter()
                .find(|n| n.id == id)
                .cloned()
                .ok_or(Fail::Status(404))
        }
        fn create(&self, text: &str, favorite: bool) -> Result<Remote, Fail> {
            if self.offline {
                return Err(Fail::Net("hors ligne".into()));
            }
            *self.next.borrow_mut() += 1;
            let id = *self.next.borrow() + 100;
            Ok(self.put(id, text, favorite))
        }
        fn update(
            &self,
            id: u64,
            etag: Option<&str>,
            text: &str,
            favorite: bool,
        ) -> Result<Remote, Fail> {
            let current = self.get(id)?;
            if etag.is_some_and(|e| e != current.etag) {
                return Err(Fail::Status(412));
            }
            Ok(self.put(id, text, favorite))
        }
        fn delete(&self, id: u64) -> Result<(), Fail> {
            let mut notes = self.notes.borrow_mut();
            let before = notes.len();
            notes.retain(|n| n.id != id);
            if notes.len() == before {
                Err(Fail::Status(404))
            } else {
                Ok(())
            }
        }
    }

    fn temp_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("anna-sync-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn titles_come_from_the_first_line() {
        assert_eq!(title("\n# Courses \npain"), "Courses");
        assert_eq!(title("   "), "Note");
        assert_eq!(title(&"x".repeat(200)).len(), 80);
    }

    #[test]
    fn local_text_notes_go_up_and_images_stay() {
        let dir = temp_dir("up");
        let mut s = Store::open(&dir);
        let a = s.add_text("Courses\npain").unwrap();
        s.pin(&a.id).unwrap();
        s.add_image(b"\x89PNG", "png").unwrap();
        let fake = Fake::default();

        assert!(sync(&dir, "a@srv", &fake).unwrap());
        let up = fake.notes.borrow().clone();
        assert_eq!(up.len(), 1);
        assert_eq!(
            (up[0].content.as_str(), up[0].favorite),
            ("Courses\npain", true)
        );
        let s = Store::open(&dir);
        let a = s.notes.iter().find(|n| n.id == a.id).unwrap();
        assert_eq!(a.remote, up[0].id);
        assert!(!a.dirty);
        assert!(!pending(&s));
        // Nothing new: nothing rewritten.
        assert!(!sync(&dir, "a@srv", &fake).unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn changes_made_elsewhere_come_down() {
        let dir = temp_dir("down");
        let fake = Fake::default();
        fake.put(7, "Écrite sur le téléphone", false);
        fake.put(8, "", false);
        sync(&dir, "a@srv", &fake).unwrap();
        let s = Store::open(&dir);
        // The empty one waits for its text.
        assert_eq!(s.notes.len(), 1);
        assert_eq!(s.notes[0].text, "Écrite sur le téléphone");

        fake.put(7, "Modifiée là-bas", true);
        sync(&dir, "a@srv", &fake).unwrap();
        let s = Store::open(&dir);
        assert_eq!(
            (s.notes[0].text.as_str(), s.notes[0].pinned),
            ("Modifiée là-bas", true)
        );

        fake.delete(7).unwrap();
        sync(&dir, "a@srv", &fake).unwrap();
        assert!(Store::open(&dir).notes.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn edits_and_deletions_made_here_go_up() {
        let dir = temp_dir("edit");
        let fake = Fake::default();
        let mut s = Store::open(&dir);
        let a = s.add_text("un").unwrap();
        let b = s.add_text("deux").unwrap();
        sync(&dir, "a@srv", &fake).unwrap();

        let mut s = Store::open(&dir);
        s.edit(&a.id, "un, corrigé").unwrap();
        s.delete(&b.id).unwrap();
        assert!(pending(&s));
        sync(&dir, "a@srv", &fake).unwrap();
        let up = fake.notes.borrow().clone();
        assert_eq!(up.len(), 1);
        assert_eq!(up[0].content, "un, corrigé");
        assert!(Store::open(&dir).sync.deleted.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_conflict_goes_to_the_newest() {
        let dir = temp_dir("conflict");
        let fake = Fake::default();
        let mut s = Store::open(&dir);
        let a = s.add_text("v1").unwrap();
        sync(&dir, "a@srv", &fake).unwrap();
        let remote = Store::open(&dir).notes[0].remote;

        // Both sides change; the server's is newer (2e9 > now).
        let mut s = Store::open(&dir);
        s.edit(&a.id, "v2 ici").unwrap();
        fake.put(remote, "v2 là-bas", false);
        sync(&dir, "a@srv", &fake).unwrap();
        let s = Store::open(&dir);
        assert_eq!(s.notes[0].text, "v2 là-bas");
        assert!(!s.notes[0].dirty);
        assert_eq!(fake.get(remote).unwrap().content, "v2 là-bas");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn offline_nothing_is_lost() {
        let dir = temp_dir("offline");
        let mut s = Store::open(&dir);
        s.add_text("hors ligne").unwrap();
        let fake = Fake {
            offline: true,
            ..Default::default()
        };
        assert!(sync(&dir, "a@srv", &fake).is_err());
        let s = Store::open(&dir);
        assert_eq!(s.notes.len(), 1);
        assert!(pending(&s));
        assert!(!s.sync.error.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn another_account_starts_afresh() {
        let dir = temp_dir("account");
        let mut s = Store::open(&dir);
        s.add_text("à moi").unwrap();
        let first = Fake::default();
        sync(&dir, "a@srv", &first).unwrap();
        let second = Fake::default();
        sync(&dir, "b@autre", &second).unwrap();
        assert_eq!(second.notes.borrow().len(), 1);
        assert_eq!(Store::open(&dir).sync.account, "b@autre");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
