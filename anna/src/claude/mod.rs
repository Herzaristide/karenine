//! Live Claude Code sessions, as reported by Claude Code's own hooks.
//!
//! Every `claude` process on the machine — in a terminal or headless — runs
//! `anna hook` on its lifecycle events (see `hook.rs`). The hook forwards a
//! trimmed copy of the event here, and this module folds the stream into one
//! state per session:
//!
//!   working  — a turn is in flight (prompt submitted, tools running)
//!   waiting  — Claude is blocked on the user (a permission prompt, a question)
//!   idle     — the turn is over; the session waits for the next prompt
//!
//! Subscribers (`claude_watch`) get the full list on every change.
//!
//! Permission requests are Claude Code's own business: its terminal dialog
//! answers them.
//!
//! Nothing is persisted: a session reappears with its next event after a
//! daemon restart. Sessions whose `claude` process is gone are reaped.

pub mod desk;
pub mod focus;
pub mod hook;
pub mod mcp;
pub mod pilot;
pub mod skills;
pub mod voice;
pub mod wake;
pub mod whisper;

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::sync::broadcast;

/// Sessions without a known process are forgotten after this much silence.
const STALE_AFTER: u64 = 6 * 3600;

/// Longest prompt excerpt kept per session (characters).
const PROMPT_EXCERPT: usize = 120;

/// One hook event, as forwarded by `anna hook`. Only what the state machine
/// needs travels — tool inputs and outputs are dropped at the source.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct HookEvent {
    pub hook_event_name: String,
    pub session_id: String,
    #[serde(default)]
    pub cwd: String,
    /// UserPromptSubmit: the prompt (already truncated by the hook).
    #[serde(default)]
    pub prompt: String,
    /// Notification: what Claude is waiting for.
    #[serde(default)]
    pub message: String,
    /// Notification: its kind, when this Claude Code version reports one.
    #[serde(default)]
    pub notification_type: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Working,
    Waiting,
    Idle,
}

#[derive(Debug, Clone, Serialize)]
pub struct Session {
    pub id: String,
    /// Basename of the working directory.
    pub project: String,
    pub cwd: String,
    pub state: State,
    /// Unix seconds of the last state change.
    pub since: u64,
    /// Unix seconds the current (or last) turn started, 0 if none yet.
    pub turn_started: u64,
    /// Excerpt of the last prompt.
    pub prompt: String,
    /// While waiting: what for.
    pub message: String,
    #[serde(skip)]
    pub pid: Option<u32>,
    /// Unix seconds of the last event, for reaping pid-less sessions.
    #[serde(skip)]
    last_event: u64,
    /// Order of first appearance, so the bar's dots don't reshuffle.
    #[serde(skip)]
    seq: u64,
}

#[derive(Default)]
struct Inner {
    sessions: HashMap<String, Session>,
    next_seq: u64,
}

pub struct Sessions {
    inner: Mutex<Inner>,
    tx: broadcast::Sender<String>,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// The project a session belongs to: its directory.
fn project_of(cwd: &str) -> String {
    std::path::Path::new(cwd)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "~".into())
}

/// Truncate on a char boundary, flattened to one line.
pub fn excerpt(s: &str, max: usize) -> String {
    let flat: String = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= max {
        return flat;
    }
    let mut out: String = flat.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

/// A Notification is either Claude blocking on the user (permission, question)
/// or the "still waiting for your input" reminder of an idle session. Newer
/// Claude Code versions say which; older ones only send the message.
fn notification_is_idle(ev: &HookEvent) -> bool {
    match ev.notification_type.as_str() {
        "idle_prompt" => true,
        "" => ev.message.to_lowercase().contains("waiting for your input"),
        _ => false,
    }
}

impl Inner {
    /// The session an event belongs to, created on first sight and refreshed
    /// with what the event knows (pid, cwd). Also says whether it is new.
    fn upsert(&mut self, ev: &HookEvent, pid: Option<u32>, t: u64) -> (&mut Session, bool) {
        let seq = self.next_seq;
        let s = self
            .sessions
            .entry(ev.session_id.clone())
            .or_insert_with(|| Session {
                id: ev.session_id.clone(),
                project: project_of(&ev.cwd),
                cwd: ev.cwd.clone(),
                state: State::Idle,
                since: t,
                turn_started: 0,
                prompt: String::new(),
                message: String::new(),
                pid: None,
                last_event: t,
                seq,
            });
        let is_new = s.seq == seq;
        if is_new {
            self.next_seq += 1;
        }

        s.last_event = t;
        if pid.is_some() {
            s.pid = pid;
        }
        if !ev.cwd.is_empty() && ev.cwd != s.cwd {
            s.cwd = ev.cwd.clone();
            s.project = project_of(&ev.cwd);
        }
        (s, is_new)
    }

    /// Fold one event into the state. Returns whether anything visible
    /// changed.
    fn apply(&mut self, ev: &HookEvent, pid: Option<u32>, t: u64) -> bool {
        if ev.session_id.is_empty() {
            return false;
        }

        if ev.hook_event_name == "SessionEnd" {
            return self.sessions.remove(&ev.session_id).is_some();
        }

        let (s, is_new) = self.upsert(ev, pid, t);
        let before = (s.state, s.prompt.clone(), s.message.clone());

        match ev.hook_event_name.as_str() {
            "SessionStart" => {}
            "UserPromptSubmit" => {
                s.state = State::Working;
                s.turn_started = t;
                s.message.clear();
                s.prompt = excerpt(&ev.prompt, PROMPT_EXCERPT);
            }
            // A tool ran: whatever Claude was waiting on has been answered.
            "PostToolUse" => {
                if s.state != State::Working {
                    s.state = State::Working;
                    s.message.clear();
                }
            }
            "Notification" => {
                if notification_is_idle(ev) {
                    s.state = State::Idle;
                    s.message.clear();
                } else {
                    s.state = State::Waiting;
                    s.message = excerpt(&ev.message, PROMPT_EXCERPT);
                }
            }
            "Stop" => {
                s.state = State::Idle;
                s.message.clear();
            }
            _ => return is_new,
        }

        let changed =
            is_new || before.0 != s.state || before.1 != s.prompt || before.2 != s.message;
        if before.0 != s.state {
            s.since = t;
        }
        changed
    }

    /// Drop sessions whose process is gone, or silent for too long when the
    /// process is unknown. Returns whether any were removed.
    fn reap(&mut self, t: u64, alive: impl Fn(u32) -> bool) -> bool {
        let n = self.sessions.len();
        self.sessions.retain(|_, s| match s.pid {
            Some(pid) => alive(pid),
            None => t.saturating_sub(s.last_event) < STALE_AFTER,
        });
        self.sessions.len() != n
    }

    fn list(&self) -> Vec<Session> {
        let mut v: Vec<Session> = self.sessions.values().cloned().collect();
        v.sort_by_key(|s| s.seq);
        v
    }
}

impl Sessions {
    pub fn new() -> std::sync::Arc<Self> {
        let (tx, _) = broadcast::channel(64);
        let me = std::sync::Arc::new(Sessions {
            inner: Mutex::new(Inner::default()),
            tx,
        });
        // Reaper: a `claude` killed without a SessionEnd must not linger.
        let weak = std::sync::Arc::downgrade(&me);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(15));
            loop {
                tick.tick().await;
                let Some(me) = weak.upgrade() else { break };
                let removed = me.lock().reap(now(), |pid| {
                    std::path::Path::new(&format!("/proc/{pid}")).exists()
                });
                if removed {
                    me.publish();
                }
            }
        });
        me
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn apply(&self, ev: &HookEvent, pid: Option<u32>) {
        if self.lock().apply(ev, pid, now()) {
            self.publish();
        }
    }

    pub fn list(&self) -> Vec<Session> {
        self.lock().list()
    }

    pub fn pid_of(&self, id: &str) -> Option<u32> {
        self.lock().sessions.get(id).and_then(|s| s.pid)
    }

    /// The line pushed to watchers: the whole list.
    pub fn snapshot_line(&self) -> String {
        serde_json::json!({ "sessions": self.list() }).to_string()
    }

    fn publish(&self) {
        let _ = self.tx.send(self.snapshot_line());
    }

    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.tx.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(name: &str) -> HookEvent {
        HookEvent {
            hook_event_name: name.into(),
            session_id: "abc".into(),
            cwd: "/home/u/ciph3r/karenine".into(),
            ..Default::default()
        }
    }

    fn state(i: &Inner) -> State {
        i.sessions["abc"].state
    }

    #[test]
    fn a_turn_goes_working_then_idle() {
        let mut i = Inner::default();
        assert!(i.apply(&ev("SessionStart"), Some(42), 100));
        assert_eq!(state(&i), State::Idle);
        assert_eq!(i.sessions["abc"].project, "karenine");

        let mut p = ev("UserPromptSubmit");
        p.prompt = "corrige\nla   barre".into();
        i.apply(&p, None, 110);
        assert_eq!(state(&i), State::Working);
        assert_eq!(i.sessions["abc"].prompt, "corrige la barre");
        assert_eq!(
            i.sessions["abc"].pid,
            Some(42),
            "a pid-less event keeps the known pid"
        );

        i.apply(&ev("Stop"), None, 115);
        assert_eq!(state(&i), State::Idle);
    }

    #[test]
    fn permission_prompt_waits_until_the_tool_runs() {
        let mut i = Inner::default();
        i.apply(&ev("UserPromptSubmit"), None, 100);

        let mut n = ev("Notification");
        n.message = "Claude needs your permission to use Bash".into();
        assert!(i.apply(&n, None, 101));
        assert_eq!(state(&i), State::Waiting);
        // A repeated notification while still waiting changes nothing.
        assert!(!i.apply(&n, None, 102));

        // The user said yes: the tool ran.
        i.apply(&ev("PostToolUse"), None, 103);
        assert_eq!(state(&i), State::Working);
        assert!(i.sessions["abc"].message.is_empty());
    }

    #[test]
    fn idle_reminder_is_not_waiting() {
        let mut i = Inner::default();
        i.apply(&ev("SessionStart"), None, 100);

        let mut n = ev("Notification");
        n.message = "Claude is waiting for your input".into();
        i.apply(&n, None, 160);
        assert_eq!(state(&i), State::Idle);

        let mut typed = ev("Notification");
        typed.notification_type = "idle_prompt".into();
        typed.message = "anything".into();
        i.apply(&typed, None, 170);
        assert_eq!(state(&i), State::Idle);
    }

    #[test]
    fn session_end_removes_and_unknown_events_are_ignored() {
        let mut i = Inner::default();
        i.apply(&ev("SessionStart"), None, 100);
        assert!(!i.apply(&ev("SubagentStop"), None, 101));
        assert!(i.apply(&ev("SessionEnd"), None, 102));
        assert!(i.sessions.is_empty());
        // An end for a session we never saw changes nothing.
        assert!(!i.apply(&ev("SessionEnd"), None, 103));
    }

    #[test]
    fn reap_drops_dead_and_stale_sessions() {
        let mut i = Inner::default();
        i.apply(&ev("SessionStart"), Some(7), 100);
        let mut other = ev("SessionStart");
        other.session_id = "nopid".into();
        i.apply(&other, None, 100);

        assert!(!i.reap(200, |_| true));
        assert!(i.reap(200, |_| false), "dead pid is reaped");
        assert!(i.sessions.contains_key("nopid"));
        assert!(
            i.reap(100 + STALE_AFTER, |_| true),
            "silent pid-less session expires"
        );
        assert!(i.sessions.is_empty());
    }

    #[test]
    fn list_keeps_first_seen_order() {
        let mut i = Inner::default();
        for id in ["b", "a", "c"] {
            let mut e = ev("SessionStart");
            e.session_id = id.into();
            i.apply(&e, None, 100);
        }
        let mut e = ev("UserPromptSubmit");
        e.session_id = "a".into();
        i.apply(&e, None, 101);
        let ids: Vec<_> = i.list().into_iter().map(|s| s.id).collect();
        assert_eq!(ids, ["b", "a", "c"]);
    }

    #[test]
    fn excerpt_cuts_on_char_boundary() {
        assert_eq!(excerpt("é".repeat(10).as_str(), 5), "éééé…");
        assert_eq!(excerpt("court", 10), "court");
    }
}
