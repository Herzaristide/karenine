//! A session's conversation, read from the JSONL Claude Code writes as it
//! goes (`~/.claude/projects/<cwd>/<session>.jsonl`) — the same file whatever
//! started the session, terminal or dock, and the one `--resume` reopens.
//!
//! The dock follows one session at a time (`claude_transcript`): it gets the
//! end of the conversation, then each message as it is appended. Kept: what
//! the user wrote, what Claude answered, and one line per tool call. Dropped:
//! sub-agents (sidechains), internal records, tool results, and user turns
//! that are only a command tag or a system reminder.

use serde::Serialize;
use serde_json::Value;
use std::io::{Read, Seek, SeekFrom};
use std::time::Duration;

/// Messages sent when following starts: the dock shows the latest exchanges,
/// and some transcripts weigh tens of megabytes.
const TAIL_LINES: usize = 400;
/// Bytes read from the end of the file to find those lines.
const TAIL_BYTES: u64 = 4 * 1024 * 1024;
/// Longest text kept per message (characters).
const TEXT_MAX: usize = 6000;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Message {
    /// "user", "assistant" or "tool".
    pub role: &'static str,
    pub text: String,
}

fn cut(s: &str) -> String {
    if s.chars().count() <= TEXT_MAX {
        return s.to_string();
    }
    let mut out: String = s.chars().take(TEXT_MAX - 1).collect();
    out.push('…');
    out
}

/// The messages one JSONL record contributes, in order.
pub fn parse_line(line: &str) -> Vec<Message> {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return Vec::new();
    };
    let flag = |k: &str| v.get(k).and_then(Value::as_bool).unwrap_or(false);
    if flag("isSidechain") || flag("isMeta") {
        return Vec::new();
    }
    let role = match v.get("type").and_then(Value::as_str) {
        Some("user") => "user",
        Some("assistant") => "assistant",
        _ => return Vec::new(),
    };
    let cwd = v.get("cwd").and_then(Value::as_str).unwrap_or("");
    let content = v.pointer("/message/content");

    let mut out = Vec::new();
    match content {
        Some(Value::String(s)) => {
            if role == "assistant" || !s.trim_start().starts_with('<') {
                out.push(Message {
                    role,
                    text: cut(s.trim()),
                });
            }
        }
        Some(Value::Array(blocks)) => {
            for b in blocks {
                match b.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        let t = b.get("text").and_then(Value::as_str).unwrap_or("").trim();
                        if !t.is_empty() && (role == "assistant" || !t.starts_with('<')) {
                            out.push(Message { role, text: cut(t) });
                        }
                    }
                    Some("tool_use") => {
                        let name = b.get("name").and_then(Value::as_str).unwrap_or("outil");
                        let input = b.get("input").cloned().unwrap_or(Value::Null);
                        let what = super::permission::summarize(name, &input, cwd);
                        out.push(Message {
                            role: "tool",
                            text: if what.is_empty() || what == "null" || what == "{}" {
                                name.to_string()
                            } else {
                                format!("{name} · {what}")
                            },
                        });
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    out
}

/// The last complete lines of `text` (a chunk from the end of a file: its
/// first line may be cut, unless the chunk starts the file).
fn last_lines(text: &str, from_start: bool, n: usize) -> Vec<&str> {
    let mut lines: Vec<&str> = text.lines().collect();
    if !from_start && !lines.is_empty() {
        lines.remove(0);
    }
    let skip = lines.len().saturating_sub(n);
    lines.into_iter().skip(skip).collect()
}

/// Read the end of the transcript; returns its messages and the offset to
/// follow from.
pub fn read_tail(path: &str) -> std::io::Result<(Vec<Message>, u64)> {
    let mut f = std::fs::File::open(path)?;
    let len = f.metadata()?.len();
    let start = len.saturating_sub(TAIL_BYTES);
    f.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;
    let text = String::from_utf8_lossy(&buf);
    let msgs = last_lines(&text, start == 0, TAIL_LINES)
        .into_iter()
        .flat_map(parse_line)
        .collect();
    Ok((msgs, len))
}

/// Complete lines appended since `offset`; returns their messages and the new
/// offset (a line still being written is left for next time).
pub fn read_from(path: &str, offset: u64) -> std::io::Result<(Vec<Message>, u64)> {
    let mut f = std::fs::File::open(path)?;
    let len = f.metadata()?.len();
    if len < offset {
        // Rewritten from scratch: the follower must start over with
        // `read_tail`, not append.
        return Err(std::io::Error::other("transcript rewritten"));
    }
    if len == offset {
        return Ok((Vec::new(), offset));
    }
    f.seek(SeekFrom::Start(offset))?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;
    let Some(end) = buf.iter().rposition(|b| *b == b'\n') else {
        return Ok((Vec::new(), offset));
    };
    let text = String::from_utf8_lossy(&buf[..end]);
    let msgs = text.lines().flat_map(parse_line).collect();
    Ok((msgs, offset + end as u64 + 1))
}

/// How often a followed transcript is checked for new lines.
pub const POLL: Duration = Duration::from_millis(400);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_what_the_conversation_shows() {
        let user =
            r#"{"type":"user","cwd":"/p","message":{"role":"user","content":"corrige le dock"}}"#;
        assert_eq!(
            parse_line(user),
            [Message {
                role: "user",
                text: "corrige le dock".into()
            }]
        );

        let assistant = r#"{"type":"assistant","cwd":"/p","message":{"content":[
            {"type":"thinking","thinking":"hmm"},
            {"type":"text","text":"Je regarde."},
            {"type":"tool_use","name":"Bash","input":{"command":"ls src"}},
            {"type":"tool_use","name":"Read","input":{"file_path":"/p/src/a.rs"}}
        ]}}"#;
        let m = parse_line(assistant);
        assert_eq!(m.len(), 3);
        assert_eq!(m[0].text, "Je regarde.");
        assert_eq!((m[1].role, m[1].text.as_str()), ("tool", "Bash · ls src"));
        assert_eq!(m[2].text, "Read · src/a.rs");
    }

    #[test]
    fn drops_plumbing() {
        for line in [
            r#"{"type":"user","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
            r#"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#,
            r#"{"type":"user","isMeta":true,"message":{"content":"meta"}}"#,
            r#"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"sub"}]}}"#,
            r#"{"type":"summary","summary":"x"}"#,
            "not json",
        ] {
            assert!(parse_line(line).is_empty(), "{line}");
        }
    }

    #[test]
    fn tail_skips_a_cut_first_line() {
        assert_eq!(last_lines("ut line\nb\nc", false, 10), ["b", "c"]);
        assert_eq!(last_lines("a\nb\nc", true, 2), ["b", "c"]);
    }

    #[test]
    fn follows_appended_lines_only_when_complete() {
        let p = std::env::temp_dir().join(format!("anna-tr-{}.jsonl", std::process::id()));
        let path = p.to_string_lossy().to_string();
        let line = |t: &str| format!(r#"{{"type":"user","message":{{"content":"{t}"}}}}"#) + "\n";
        std::fs::write(&p, line("un")).unwrap();
        let (m, off) = read_tail(&path).unwrap();
        assert_eq!(m.len(), 1);

        // Half a line: not yet.
        let next = line("deux");
        let (half, rest) = next.split_at(10);
        std::fs::OpenOptions::new()
            .append(true)
            .open(&p)
            .and_then(|mut f| std::io::Write::write_all(&mut f, half.as_bytes()))
            .unwrap();
        let (m, off2) = read_from(&path, off).unwrap();
        assert!(m.is_empty());
        assert_eq!(off2, off);

        std::fs::OpenOptions::new()
            .append(true)
            .open(&p)
            .and_then(|mut f| std::io::Write::write_all(&mut f, rest.as_bytes()))
            .unwrap();
        let (m, _) = read_from(&path, off2).unwrap();
        assert_eq!(m[0].text, "deux");
        let _ = std::fs::remove_file(&p);
    }
}
