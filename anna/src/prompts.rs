//! The requests the system makes of the user, all answered in karenine.
//!
//! An askpass (SSH, git, sudo), and later the agents anna runs itself
//! (portal, NetworkManager, BlueZ…), open a prompt here; the shell, which
//! follows `prompt_watch`, shows it as a card (panels/PromptHost.qml) and
//! sends the answer back with `prompt_reply`. The prompt waits for that
//! answer, for its deadline, or for its requester to go away.
//!
//! Secrets: an answer goes to the requester of its prompt only, never to the
//! other watchers; nothing of it is logged or written to disk. A prompt's id
//! is 128 random bits, so another client of the socket cannot answer one it
//! has not been shown.
//!
//! Without a shell to show it (nobody follows `prompt_watch`), a prompt is
//! refused at once with `no_shell`, so the requester can fall back to the
//! standard dialog instead of waiting for nothing.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::{oneshot, watch};

/// The longest a prompt may wait, whatever its requester asks.
const MAX_TIMEOUT: u64 = 600;
const DEFAULT_TIMEOUT: u64 = 120;

/// One field of a prompt's card.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Field {
    /// Its key in the answer's `values`.
    pub key: String,
    /// "password", "text", "check" or "choice".
    #[serde(default = "password")]
    pub kind: String,
    #[serde(default)]
    pub label: String,
    /// The initial value: text, "true"/"false" for a check, an option id
    /// for a choice.
    #[serde(default)]
    pub value: String,
    /// The options of a choice.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<Choice>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Choice {
    pub id: String,
    pub label: String,
    /// A second line (a window's class, a screen's size).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub sub: String,
    /// The heading it is listed under (« Écrans », « Fenêtres »…).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub group: String,
    /// What the shell can show live in its tile: `{"screen":"DP-1"}` or
    /// `{"window":"<hyprland address, hex>"}`. A choice with previews is
    /// drawn as a grid of tiles.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preview: Option<serde_json::Value>,
}

/// A button of the card. Escape and a click beside the card answer
/// `cancel`, which needs no button.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Action {
    pub id: String,
    pub label: String,
    /// The default button (Enter).
    #[serde(default)]
    pub primary: bool,
    /// Drawn in the danger color (kill, erase…).
    #[serde(default)]
    pub danger: bool,
}

/// What a requester asks.
#[derive(Debug, Clone, Deserialize, Default)]
pub struct Spec {
    /// What it is, for the card's icon: "ssh", "git", "sudo", "confirm",
    /// "notice"…
    #[serde(default)]
    pub kind: String,
    /// Who asks (the program), shown under the title.
    #[serde(default)]
    pub source: String,
    pub title: String,
    #[serde(default)]
    pub text: String,
    /// A detail in monospace (a key's fingerprint, a path, an action id).
    #[serde(default)]
    pub detail: String,
    #[serde(default)]
    pub fields: Vec<Field>,
    #[serde(default)]
    pub actions: Vec<Action>,
    /// Seconds, clamped to MAX_TIMEOUT; DEFAULT_TIMEOUT when absent.
    #[serde(default)]
    pub timeout: Option<u64>,
}

/// A prompt as the shell is shown it.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct View {
    pub id: String,
    pub kind: String,
    pub source: String,
    pub title: String,
    pub text: String,
    pub detail: String,
    pub fields: Vec<Field>,
    pub actions: Vec<Action>,
    /// When it gives up, in ms since the epoch.
    pub deadline: u64,
}

/// The answer to a prompt.
#[derive(Debug, Clone, Deserialize, Serialize, Default)]
pub struct Answer {
    /// The button's id, or "cancel".
    pub action: String,
    #[serde(default)]
    pub values: HashMap<String, String>,
}

impl Drop for Answer {
    /// Overwrite the values (passwords) before their memory is freed.
    fn drop(&mut self) {
        for v in self.values.values_mut() {
            wipe(v);
        }
    }
}

/// Zero a string's bytes in place.
pub fn wipe(s: &mut String) {
    // SAFETY: zero bytes are valid UTF-8.
    unsafe {
        for b in s.as_bytes_mut() {
            std::ptr::write_volatile(b, 0);
        }
    }
    s.clear();
}

#[derive(Debug, PartialEq, Eq)]
pub enum Refused {
    /// No shell follows the prompts.
    NoShell,
    Timeout,
    /// The prompt was withdrawn (its requester left, the shell restarted…).
    Gone,
}

impl Refused {
    pub fn code(&self) -> &'static str {
        match self {
            Refused::NoShell => "no_shell",
            Refused::Timeout => "timeout",
            Refused::Gone => "gone",
        }
    }
}

struct Pending {
    view: View,
    reply: oneshot::Sender<Answer>,
}

pub struct Prompts {
    pending: Mutex<Vec<Pending>>,
    /// The pending prompts, oldest first, for the watchers.
    tx: watch::Sender<Vec<View>>,
}

impl Prompts {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            pending: Mutex::new(Vec::new()),
            tx: watch::channel(Vec::new()).0,
        })
    }

    pub fn subscribe(&self) -> watch::Receiver<Vec<View>> {
        self.tx.subscribe()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Pending>> {
        self.pending.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn publish(&self, pending: &[Pending]) {
        let views = pending.iter().map(|p| p.view.clone()).collect();
        self.tx.send_replace(views);
    }

    /// Show `spec` and wait for its answer. Dropping the future (the
    /// requester left) withdraws the prompt.
    pub async fn ask(self: &Arc<Self>, spec: Spec) -> Result<Answer, Refused> {
        if self.tx.receiver_count() == 0 {
            return Err(Refused::NoShell);
        }
        let timeout = spec.timeout.unwrap_or(DEFAULT_TIMEOUT).clamp(1, MAX_TIMEOUT);
        let id = new_id();
        let (reply, answer) = oneshot::channel();
        let view = View {
            id: id.clone(),
            kind: spec.kind,
            source: spec.source,
            title: spec.title,
            text: spec.text,
            detail: spec.detail,
            fields: spec.fields,
            actions: spec.actions,
            deadline: now_ms() + timeout * 1000,
        };
        {
            let mut pending = self.lock();
            pending.push(Pending { view, reply });
            self.publish(&pending);
        }
        let _withdraw = Withdraw {
            prompts: Arc::clone(self),
            id,
        };
        match tokio::time::timeout(Duration::from_secs(timeout), answer).await {
            Ok(Ok(a)) => Ok(a),
            Ok(Err(_)) => Err(Refused::Gone),
            Err(_) => Err(Refused::Timeout),
        }
    }

    /// The shell's answer to prompt `id`: false if no such prompt waits.
    pub fn reply(&self, id: &str, answer: Answer) -> bool {
        let mut pending = self.lock();
        let Some(i) = pending.iter().position(|p| p.view.id == id) else {
            return false;
        };
        let p = pending.remove(i);
        self.publish(&pending);
        drop(pending);
        // The requester may have just left: the answer is then dropped (and
        // wiped).
        let _ = p.reply.send(answer);
        true
    }

    fn withdraw(&self, id: &str) {
        let mut pending = self.lock();
        if let Some(i) = pending.iter().position(|p| p.view.id == id) {
            pending.remove(i);
            self.publish(&pending);
        }
    }
}

/// Withdraws its prompt when the wait ends, however it ends.
struct Withdraw {
    prompts: Arc<Prompts>,
    id: String,
}

impl Drop for Withdraw {
    fn drop(&mut self) {
        self.prompts.withdraw(&self.id);
    }
}

fn password() -> String {
    "password".into()
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 128 random bits, in hex, from the kernel.
fn new_id() -> String {
    use std::io::Read;
    let mut bytes = [0u8; 16];
    if std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .is_err()
    {
        // No /dev/urandom: the time and a counter, unique if guessable.
        static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        bytes[..8].copy_from_slice(&now_ms().to_le_bytes());
        bytes[8..].copy_from_slice(&n.to_le_bytes());
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec(timeout: u64) -> Spec {
        Spec {
            title: "t".into(),
            timeout: Some(timeout),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn without_a_shell_prompts_are_refused() {
        let p = Prompts::new();
        assert_eq!(p.ask(spec(5)).await.err(), Some(Refused::NoShell));
    }

    #[tokio::test]
    async fn the_answer_reaches_the_requester() {
        let p = Prompts::new();
        let mut rx = p.subscribe();
        let asker = {
            let p = Arc::clone(&p);
            tokio::spawn(async move { p.ask(spec(5)).await })
        };
        rx.changed().await.unwrap();
        let id = rx.borrow_and_update()[0].id.clone();
        assert_eq!(id.len(), 32);
        assert!(!p.reply("not-an-id", Answer::default()));
        let mut values = HashMap::new();
        values.insert("password".into(), "s3cret".into());
        assert!(p.reply(&id, Answer { action: "ok".into(), values }));
        let a = asker.await.unwrap().unwrap();
        assert_eq!(a.action, "ok");
        assert_eq!(a.values["password"], "s3cret");
        assert!(rx.borrow().is_empty());
    }

    #[tokio::test]
    async fn a_prompt_gives_up_at_its_deadline() {
        let p = Prompts::new();
        let _rx = p.subscribe();
        let r = p.ask(spec(1)).await;
        assert_eq!(r.err(), Some(Refused::Timeout));
        assert!(p.subscribe().borrow().is_empty());
    }

    #[tokio::test]
    async fn a_requester_that_leaves_withdraws_its_prompt() {
        let p = Prompts::new();
        let mut rx = p.subscribe();
        let asker = {
            let p = Arc::clone(&p);
            tokio::spawn(async move { p.ask(spec(60)).await })
        };
        rx.changed().await.unwrap();
        assert_eq!(rx.borrow_and_update().len(), 1);
        asker.abort();
        rx.changed().await.unwrap();
        assert!(rx.borrow().is_empty());
    }

    #[test]
    fn wipe_clears_the_string() {
        let mut s = String::from("hunter2");
        wipe(&mut s);
        assert!(s.is_empty());
    }
}
