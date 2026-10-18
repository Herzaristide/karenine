//! The pilot's permission requests, answered from the dock.
//!
//! Before the pilot runs a sensitive tool (desk.rs, SENSITIVE), it asks: the
//! request sits on the pilot's session until the dock answers it — allow,
//! always or deny — or nobody does in time, which counts as no.
//!
//! Claude Code sessions are not concerned: their own terminal dialog answers
//! their permission requests.

use super::{excerpt, HookEvent, Outcome, Sessions};
use serde_json::Value;
use std::time::Duration;

/// Longest summary shown for a request (characters).
const SUMMARY_MAX: usize = 300;

/// `/home/u/x` → `~/x`, relative to the session when inside it.
fn short_path(path: &str, cwd: &str) -> String {
    if !cwd.is_empty() {
        if let Some(rest) = path.strip_prefix(cwd).and_then(|r| r.strip_prefix('/')) {
            return rest.to_string();
        }
    }
    let home = crate::paths::home_dir();
    match path.strip_prefix(home.to_string_lossy().as_ref()) {
        Some(rest) if rest.starts_with('/') => format!("~{rest}"),
        _ => path.to_string(),
    }
}

/// One line saying what the tool would do. Built in the hook, so the tool's
/// full input (file contents…) never leaves Claude's side.
pub fn summarize(tool: &str, input: &Value, cwd: &str) -> String {
    let s = |k: &str| input.get(k).and_then(Value::as_str).unwrap_or("");
    let text = match tool {
        "Bash" => s("command").to_string(),
        "Write" | "Edit" | "MultiEdit" | "Read" | "NotebookEdit" => {
            let p = if s("file_path").is_empty() {
                s("notebook_path")
            } else {
                s("file_path")
            };
            short_path(p, cwd)
        }
        "WebFetch" => s("url").to_string(),
        "WebSearch" => s("query").to_string(),
        "Glob" | "Grep" => format!("{} {}", s("pattern"), short_path(s("path"), cwd))
            .trim()
            .to_string(),
        _ => input.to_string(),
    };
    excerpt(&text, SUMMARY_MAX)
}

/// The session the pilot's own requests are shown under, for as long as
/// they are open.
pub const PILOT_SESSION: &str = "pilote";

/// How long the pilot waits for a yes before giving up.
const PILOT_ANSWER_WITHIN: Duration = Duration::from_secs(120);

/// Ask the user, in the dock, before the pilot runs a sensitive tool
/// (desk.rs, SENSITIVE). Only a yes ("allow" or "always") lets it run; no
/// shell or no answer in time count as no.
pub async fn confirm(sessions: &Sessions, tool: &str, summary: &str) -> bool {
    if !sessions.watched() {
        return false;
    }
    let event = HookEvent {
        hook_event_name: "PermissionRequest".into(),
        session_id: PILOT_SESSION.into(),
        cwd: PILOT_SESSION.into(),
        ..Default::default()
    };
    let (req, answer) = sessions.open_request(&event, None, (tool, summary, ""));
    let outcome = tokio::time::timeout(PILOT_ANSWER_WITHIN, answer)
        .await
        .ok()
        .and_then(Result::ok)
        .unwrap_or(Outcome::Terminal);
    sessions.close_request(req, outcome);
    // The pilot is not a session: its dot goes with the request.
    sessions.apply(
        &HookEvent {
            hook_event_name: "SessionEnd".into(),
            session_id: PILOT_SESSION.into(),
            ..Default::default()
        },
        None,
    );
    matches!(outcome, Outcome::Allow | Outcome::Always)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn summaries_say_what_the_tool_would_do() {
        let cwd = "/home/u/p";
        assert_eq!(
            summarize(
                "Bash",
                &json!({"command": "npm test", "description": "x"}),
                cwd
            ),
            "npm test"
        );
        assert_eq!(
            summarize(
                "Write",
                &json!({"file_path": "/home/u/p/src/a.rs", "content": "secret"}),
                cwd
            ),
            "src/a.rs"
        );
        assert_eq!(
            summarize("WebFetch", &json!({"url": "https://x.org"}), cwd),
            "https://x.org"
        );
        // Unknown tools (MCP…) show their input, cut short.
        let long = summarize("mcp__x__y", &json!({"q": "a".repeat(1000)}), cwd);
        assert!(long.chars().count() <= SUMMARY_MAX);
    }
}
