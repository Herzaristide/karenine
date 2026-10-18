//! `anna hook` — the command Claude Code runs on its lifecycle events.
//!
//! Declared once in the Claude Code settings for SessionStart,
//! UserPromptSubmit, PostToolUse, Notification, Stop and SessionEnd, it
//! reads the event JSON on stdin and hands a trimmed copy to the daemon.
//! Permission requests are left to Claude Code's own dialog: a
//! PermissionRequest still declared there is ignored.
//!
//! It must never get in Claude's way:
//!   - exit 0, always — for Claude Code, exit 2 means "block this prompt /
//!     this tool";
//!   - print nothing — on SessionStart and UserPromptSubmit, stdout is added
//!     to the model's context;
//!   - be quick — PostToolUse runs after every tool call. A missing daemon
//!     costs one failed connect, and the write is bounded by a timeout.

use super::{excerpt, focus, HookEvent};
use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// Environment variables that mark a `claude` run as plumbing, not a session
/// the user is working in: the journal's own summarizer (claude-journal.nix)
/// and anything that opts out explicitly.
const SILENT_ENV: [&str; 2] = ["CLAUDE_JOURNAL_CHILD", "ANNA_HOOK_IGNORE"];

/// Prompts travel truncated: the bar shows an excerpt, never the whole text.
const PROMPT_MAX: usize = 400;

/// Trim the raw hook payload to what the daemon tracks. Tool inputs and
/// outputs (file contents, command output…) never leave this process.
fn trim(v: &Value) -> Option<HookEvent> {
    let s = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
    let ev = HookEvent {
        hook_event_name: s("hook_event_name"),
        session_id: s("session_id"),
        cwd: s("cwd"),
        transcript_path: s("transcript_path"),
        prompt: excerpt(&s("prompt"), PROMPT_MAX),
        message: s("message"),
        notification_type: s("notification_type"),
    };
    (!ev.hook_event_name.is_empty() && !ev.session_id.is_empty()).then_some(ev)
}

/// The `claude` process that ran this hook: the nearest ancestor whose name
/// says so. Hooks may run through a shell, so it is not always the parent.
fn claude_pid() -> Option<u32> {
    let mut p = std::os::unix::process::parent_id();
    for _ in 0..4 {
        let (ppid, comm) = focus::parent_and_comm(p)?;
        if comm.contains("claude") {
            return Some(p);
        }
        p = ppid;
    }
    None
}

pub fn run() {
    if SILENT_ENV.iter().any(|k| std::env::var_os(k).is_some()) {
        return;
    }
    let mut raw = String::new();
    if std::io::stdin().read_to_string(&mut raw).is_err() {
        return;
    }
    let Ok(v) = serde_json::from_str::<Value>(&raw) else {
        return;
    };
    let Some(event) = trim(&v) else { return };
    // Claude Code's dialog answers it: printing nothing leaves it there.
    if event.hook_event_name == "PermissionRequest" {
        return;
    }
    let Ok(mut sock) = UnixStream::connect(crate::paths::socket_path()) else {
        return;
    };

    let msg = serde_json::json!({
        "cmd": "claude_hook",
        "pid": claude_pid(),
        "event": event,
    });
    let _ = sock.set_write_timeout(Some(Duration::from_millis(300)));
    let _ = writeln!(sock, "{msg}");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trim_str(raw: &str) -> Option<HookEvent> {
        trim(&serde_json::from_str(raw).ok()?)
    }

    #[test]
    fn trim_keeps_only_tracked_fields() {
        let raw = r#"{
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "cwd": "/tmp/p",
            "transcript_path": "/tmp/t.jsonl",
            "tool_name": "Read",
            "tool_input": {"file_path": "/etc/secret"},
            "tool_response": {"content": "very long file"}
        }"#;
        let ev = trim_str(raw).unwrap();
        assert_eq!(ev.hook_event_name, "PostToolUse");
        assert_eq!(ev.cwd, "/tmp/p");
        let out = serde_json::to_string(&ev).unwrap();
        assert!(!out.contains("secret") && !out.contains("very long file"));
    }

    #[test]
    fn trim_rejects_garbage_and_incomplete_events() {
        assert!(trim_str("not json").is_none());
        assert!(trim_str(r#"{"hook_event_name":"Stop"}"#).is_none());
        assert!(trim_str(r#"{"session_id":"s"}"#).is_none());
    }

    #[test]
    fn long_prompts_are_cut() {
        let raw = serde_json::json!({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s",
            "prompt": "x".repeat(5000),
        })
        .to_string();
        assert!(trim_str(&raw).unwrap().prompt.chars().count() <= PROMPT_MAX);
    }
}
