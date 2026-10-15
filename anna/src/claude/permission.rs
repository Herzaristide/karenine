//! Answering Claude Code's permission requests from the bar.
//!
//! When Claude is about to show its "may I…?" dialog, it first runs the
//! `PermissionRequest` hook. `anna hook` sends the request here and waits;
//! the bar shows it with four answers:
//!
//!   allow     — run the tool this once
//!   always    — run it, and apply the rule Claude Code itself suggests
//!               ("don't ask again for …"), exactly as its own dialog would
//!   deny      — refuse; Claude is told and carries on
//!   terminal  — no answer from here: the terminal's dialog appears
//!
//! The terminal stays in charge whenever the bar can't help: nothing watches
//! the sessions, the session's own window is the one in front (the user is
//! right there), it comes to the front while the request is open, or nobody
//! answers in time. In all those cases the hook prints nothing, and Claude
//! Code falls back to its dialog as if no hook had run.

use super::{excerpt, focus, HookEvent, Outcome, Sessions};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::io::BufReader;
use tokio::net::unix::OwnedReadHalf;

/// How long a request waits for the bar before handing over to the terminal.
/// The hook's own timeout (Claude Code settings) must be longer.
pub const ANSWER_WITHIN: Duration = Duration::from_secs(300);

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

/// What "always" would allow, in words, from Claude Code's own suggestions.
/// Empty when it offers none.
pub fn always_label(suggestions: &Value) -> String {
    let scope = |d: &str| match d {
        "session" => "cette session",
        "localSettings" | "projectSettings" => "ce projet",
        "userSettings" => "partout",
        _ => "",
    };
    let Some(list) = suggestions.as_array() else {
        return String::new();
    };
    let parts: Vec<String> = list
        .iter()
        .filter_map(|sug| {
            let dest = scope(sug.get("destination")?.as_str().unwrap_or(""));
            let what = match sug.get("type")?.as_str()? {
                "setMode" => match sug.get("mode")?.as_str()? {
                    "acceptEdits" => "les modifications de fichiers".to_string(),
                    m => format!("le mode {m}"),
                },
                "addDirectories" => {
                    let dirs: Vec<String> = sug
                        .get("directories")?
                        .as_array()?
                        .iter()
                        .filter_map(Value::as_str)
                        .map(|d| short_path(d, ""))
                        .collect();
                    format!("l'accès à {}", dirs.join(", "))
                }
                "addRules" => {
                    let rules: Vec<String> = sug
                        .get("rules")?
                        .as_array()?
                        .iter()
                        .filter_map(|r| {
                            let tool = r.get("toolName")?.as_str()?;
                            Some(match r.get("ruleContent").and_then(Value::as_str) {
                                Some(c) => format!("{tool}({c})"),
                                None => tool.to_string(),
                            })
                        })
                        .collect();
                    rules.join(", ")
                }
                _ => return None,
            };
            Some(if dest.is_empty() {
                what
            } else {
                format!("{what} ({dest})")
            })
        })
        .collect();
    parts.join(" · ")
}

/// The hook's stdout for an answer, or `None` to leave it to the terminal.
/// "always" hands Claude Code back its own suggestions, so the rule it
/// records is exactly the one its dialog would have.
pub fn hook_output(outcome: Outcome, suggestions: &Value) -> Option<String> {
    let decision = match outcome {
        Outcome::Terminal => return None,
        Outcome::Allow => json!({ "behavior": "allow" }),
        Outcome::Always => match suggestions.as_array() {
            Some(s) if !s.is_empty() => {
                json!({ "behavior": "allow", "updatedPermissions": suggestions })
            }
            _ => json!({ "behavior": "allow" }),
        },
        Outcome::Deny => json!({
            "behavior": "deny",
            "message": "Refusé par l'utilisateur depuis la barre.",
        }),
    };
    Some(
        json!({
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision,
            }
        })
        .to_string(),
    )
}

async fn focused(pid: Option<u32>) -> bool {
    let Some(pid) = pid else { return false };
    tokio::task::spawn_blocking(move || focus::is_focused(pid))
        .await
        .unwrap_or(false)
}

/// Daemon side: hold one request until the bar answers, the terminal takes
/// over, or the hook goes away (`hook_rx` is its connection: EOF means
/// Claude gave up on the hook).
pub async fn run(
    sessions: &Sessions,
    pid: Option<u32>,
    event: &HookEvent,
    what: (&str, &str, &str),
    hook_rx: &mut tokio::io::Lines<BufReader<OwnedReadHalf>>,
) -> Outcome {
    if !sessions.watched() || focused(pid).await {
        return Outcome::Terminal;
    }

    let (req, mut answer) = sessions.open_request(event, pid, what);
    let deadline = tokio::time::sleep(ANSWER_WITHIN);
    tokio::pin!(deadline);
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    tick.tick().await;

    let outcome = loop {
        tokio::select! {
            a = &mut answer => break a.unwrap_or(Outcome::Terminal),
            _ = &mut deadline => break Outcome::Terminal,
            line = hook_rx.next_line() => {
                if !matches!(line, Ok(Some(_))) {
                    break Outcome::Terminal;
                }
            }
            // The user went to the session's terminal: answer there.
            _ = tick.tick() => {
                if focused(pid).await {
                    break Outcome::Terminal;
                }
            }
        }
    };
    sessions.close_request(req, outcome);
    outcome
}

/// The session the pilot's own requests are shown under, for as long as
/// they are open.
pub const PILOT_SESSION: &str = "pilote";

/// How long the pilot waits for a yes before giving up.
const PILOT_ANSWER_WITHIN: Duration = Duration::from_secs(120);

/// Ask the user, in the bar's bubble, before the pilot runs a sensitive tool
/// (desk.rs, SENSITIVE). Only a yes ("allow" or "always") lets it run; no
/// bar, no answer in time or "terminal" — the pilot has none — count as no.
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

    #[test]
    fn always_reads_claude_codes_suggestions() {
        // Captured from Claude Code 2.1.296.
        let s = json!([
            {"type": "addDirectories", "directories": ["/srv/data"], "destination": "session"},
            {"type": "setMode", "mode": "acceptEdits", "destination": "session"}
        ]);
        assert_eq!(
            always_label(&s),
            "l'accès à /srv/data (cette session) · les modifications de fichiers (cette session)"
        );
        let r = json!([{
            "type": "addRules",
            "rules": [{"toolName": "Bash", "ruleContent": "npm test:*"}],
            "behavior": "allow",
            "destination": "localSettings"
        }]);
        assert_eq!(always_label(&r), "Bash(npm test:*) (ce projet)");
        assert_eq!(always_label(&json!([])), "");
        assert_eq!(always_label(&Value::Null), "");
    }

    #[test]
    fn outputs_match_claude_codes_schema() {
        let sug = json!([{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]);
        assert_eq!(hook_output(Outcome::Terminal, &sug), None);

        let allow: Value =
            serde_json::from_str(&hook_output(Outcome::Allow, &sug).unwrap()).unwrap();
        assert_eq!(
            allow["hookSpecificOutput"]["hookEventName"],
            "PermissionRequest"
        );
        assert_eq!(
            allow["hookSpecificOutput"]["decision"],
            json!({"behavior": "allow"})
        );

        let always: Value =
            serde_json::from_str(&hook_output(Outcome::Always, &sug).unwrap()).unwrap();
        assert_eq!(
            always["hookSpecificOutput"]["decision"]["updatedPermissions"],
            sug
        );

        let deny: Value = serde_json::from_str(&hook_output(Outcome::Deny, &sug).unwrap()).unwrap();
        assert_eq!(deny["hookSpecificOutput"]["decision"]["behavior"], "deny");
    }
}
