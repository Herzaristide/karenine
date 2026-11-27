//! A Claude Code conversation, as the « Claude » tab shows it: its
//! transcript (`~/.claude/projects/<folder>/<id>.jsonl`) read as a list of
//! items — the user's requests, Claude's text and thinking, each tool call
//! with its result (output, diff) — a page at a time, then followed as it
//! grows.
//!
//! The transcript is the one source, whether the session runs in a terminal
//! or is driven by anna (drive.rs): Claude Code writes every message there,
//! with the same ids as on its stream, so an item is never shown twice.
//!
//! The format is not documented: unknown lines are skipped, unknown blocks
//! become `other` items, and nothing fails on a field that is missing.
//! Transcripts can weigh tens of megabytes: lines are found through an
//! index of their offsets, and only the lines of a page are read.

use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

/// The longest text kept in an item (a tool's output, a file written).
const MAX_TEXT: usize = 20_000;
/// The longest string kept in a tool's input.
const MAX_INPUT: usize = 20_000;
/// Lines read after a page, for the results of its last tool calls.
const LOOKAHEAD: usize = 64;
/// The tool calls a feed remembers, for the results still to come.
const TOOLS_KEPT: usize = 400;

/// One thing shown in the conversation.
#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Item {
    /// Unique and stable: the line's uuid and the block's rank, or the tool
    /// call's id.
    pub key: String,
    /// `user`, `text`, `thinking`, `tool`, `note` or `other`.
    pub kind: String,
    pub text: String,
    /// Images attached to a request.
    #[serde(skip_serializing_if = "is_zero")]
    pub images: u32,
    /// A tool call: its name, what it works on, its input.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub tool: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub summary: String,
    #[serde(skip_serializing_if = "Value::is_null")]
    pub input: Value,
    /// Its result, once there: the text, whether it failed, the diff of an
    /// edit (`structuredPatch` hunks), the file holding a long output.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub output: String,
    pub done: bool,
    pub error: bool,
    /// The text was cut at MAX_TEXT.
    pub cut: bool,
    #[serde(skip_serializing_if = "Value::is_null")]
    pub patch: Value,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub persisted: String,
    /// A subagent's call (`Agent`, `Task`): the subagent, whose own
    /// conversation can be opened (`subagents/agent-<id>.jsonl`).
    #[serde(skip_serializing_if = "String::is_empty")]
    pub agent: String,
    /// The tool call of the subagent that said it, "" for the main thread.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub parent: String,
    /// When (ISO 8601), "" when unknown.
    pub ts: String,
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}

pub(super) fn s<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or_default()
}

/// `text`, cut at `max` characters; whether it was.
pub(super) fn cut(text: &str, max: usize) -> (String, bool) {
    match text.char_indices().nth(max) {
        Some((i, _)) => (text[..i].to_string(), true),
        None => (text.to_string(), false),
    }
}

/// A tool's input, every long string cut.
fn trim_input(v: &Value) -> Value {
    match v {
        Value::String(t) => Value::String(cut(t, MAX_INPUT).0),
        Value::Array(a) => Value::Array(a.iter().map(trim_input).collect()),
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, v)| (k.clone(), trim_input(v)))
                .collect::<Map<_, _>>(),
        ),
        other => other.clone(),
    }
}

/// The text of a block's `content`: a string, or the text parts of a list.
pub(super) fn content_text(content: &Value) -> String {
    match content {
        Value::String(t) => t.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|p| match p.get("type").and_then(Value::as_str) {
                Some("text") => p.get("text").and_then(Value::as_str).map(str::to_string),
                Some("image") => Some("[image]".into()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// What a request the user typed shows, or `None` for what Claude Code
/// wrote itself in the user's name (caveats, command output, reminders).
/// A slash command shows as a note: « /clear ».
fn request(text: &str) -> Option<(&'static str, String)> {
    let t = text.trim();
    if t.is_empty() {
        return None;
    }
    if let Some(name) = between(t, "<command-name>", "</command-name>") {
        let args = between(t, "<command-args>", "</command-args>").unwrap_or_default();
        let line = format!("{} {}", name.trim(), args.trim());
        return Some(("note", line.trim().to_string()));
    }
    if t.starts_with('<') {
        return None;
    }
    if t.starts_with("[Request interrupted") {
        return Some(("note", "interrupted".into()));
    }
    Some(("user", t.to_string()))
}

fn between<'a>(text: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let start = text.find(open)? + open.len();
    let end = text[start..].find(close)? + start;
    Some(&text[start..end])
}

/// Text without its terminal colours (`ESC [ … letter`).
fn plain(text: &str) -> String {
    let mut out = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            out.push(c);
        } else if chars.peek() == Some(&'[') {
            chars.next();
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        }
    }
    out
}

// ── From lines to items ─────────────────────────────────────────────────────

/// Turns transcript (or stream) lines into items, one line at a time. It
/// keeps the tool calls it has seen, so that a result, which comes on a
/// later line, can complete its call.
#[derive(Default)]
pub struct Feed {
    tools: HashMap<String, Item>,
    order: Vec<String>,
}

impl Feed {
    /// The items line `v` adds, and the tool calls it completes (same key:
    /// they replace the call shown).
    pub fn line(&mut self, v: &Value) -> Vec<Item> {
        let ts = s(v, "timestamp").to_string();
        let uuid = s(v, "uuid").to_string();
        let parent = s(v, "parent_tool_use_id").to_string();
        let key = |i: usize| format!("{uuid}:{i}");
        let mut out = Vec::new();
        match s(v, "type") {
            "user" => {
                if v.get("isMeta").and_then(Value::as_bool) == Some(true) {
                    return out;
                }
                // The details of a result: `toolUseResult` in the
                // transcript, `tool_use_result` on the stream.
                let extra = v
                    .get("toolUseResult")
                    .or_else(|| v.get("tool_use_result"))
                    .unwrap_or(&Value::Null);
                match v.pointer("/message/content").unwrap_or(&Value::Null) {
                    Value::String(t) => {
                        if let Some((kind, text)) = request(t) {
                            out.push(Item {
                                key: key(0),
                                kind: kind.into(),
                                text,
                                parent: parent.clone(),
                                ts: ts.clone(),
                                ..Default::default()
                            });
                        }
                    }
                    Value::Array(parts) => {
                        let mut text = Vec::new();
                        let mut images = 0;
                        for p in parts {
                            match s(p, "type") {
                                "text" => text.push(s(p, "text").to_string()),
                                "image" => images += 1,
                                "tool_result" => {
                                    if let Some(item) = self.result(p, extra) {
                                        out.push(item);
                                    }
                                }
                                _ => {}
                            }
                        }
                        let joined = text.join("\n");
                        if let Some((kind, text)) = request(&joined)
                            .or_else(|| (images > 0).then(|| ("user", String::new())))
                        {
                            out.push(Item {
                                key: key(0),
                                kind: kind.into(),
                                text,
                                images,
                                parent: parent.clone(),
                                ts: ts.clone(),
                                ..Default::default()
                            });
                        }
                    }
                    _ => {}
                }
            }
            "assistant" => {
                let blocks = v
                    .pointer("/message/content")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let cwd = s(v, "cwd").to_string();
                for (i, b) in blocks.iter().enumerate() {
                    let base = Item {
                        key: key(i),
                        parent: parent.clone(),
                        ts: ts.clone(),
                        ..Default::default()
                    };
                    match s(b, "type") {
                        "text" => {
                            let text = s(b, "text").trim();
                            if !text.is_empty() {
                                out.push(Item {
                                    kind: "text".into(),
                                    text: text.to_string(),
                                    ..base
                                });
                            }
                        }
                        "thinking" => {
                            // Often empty: the model's thinking is then
                            // only a signature.
                            let text = s(b, "thinking").trim();
                            if !text.is_empty() {
                                out.push(Item {
                                    kind: "thinking".into(),
                                    text: text.to_string(),
                                    ..base
                                });
                            }
                        }
                        "redacted_thinking" => {}
                        "tool_use" | "server_tool_use" => {
                            let input = b.get("input").cloned().unwrap_or(Value::Null);
                            let item = Item {
                                key: s(b, "id").to_string(),
                                kind: "tool".into(),
                                tool: s(b, "name").to_string(),
                                summary: super::sessions::target(&input, &cwd),
                                input: trim_input(&input),
                                ..base
                            };
                            self.remember(item.clone());
                            out.push(item);
                        }
                        t if t.ends_with("_tool_result") => {
                            if let Some(item) = self.result(b, &Value::Null) {
                                out.push(item);
                            }
                        }
                        other => out.push(Item {
                            kind: "other".into(),
                            text: other.to_string(),
                            ..base
                        }),
                    }
                }
            }
            "system" if s(v, "subtype") == "compact_boundary" => {
                out.push(Item {
                    key: key(0),
                    kind: "note".into(),
                    text: "compacted".into(),
                    ts,
                    ..Default::default()
                });
            }
            // A slash command Claude Code ran itself: what it answered, or
            // the command's own name when it has no other line.
            "system" if s(v, "subtype") == "local_command" => {
                let content = s(v, "content");
                let (kind, text) =
                    match between(content, "<local-command-stdout>", "</local-command-stdout>")
                        .or_else(|| {
                            between(content, "<local-command-stderr>", "</local-command-stderr>")
                        }) {
                        Some(out) => ("text", plain(out)),
                        None if content.starts_with('/') => ("note", content.to_string()),
                        None => return out,
                    };
                let text = text.trim().to_string();
                if !text.is_empty() {
                    out.push(Item {
                        key: key(0),
                        kind: kind.into(),
                        text,
                        ts,
                        ..Default::default()
                    });
                }
            }
            _ => {}
        }
        out
    }

    fn remember(&mut self, item: Item) {
        if !self.tools.contains_key(&item.key) {
            self.order.push(item.key.clone());
        }
        self.tools.insert(item.key.clone(), item);
        if self.order.len() > TOOLS_KEPT {
            let old = self.order.remove(0);
            self.tools.remove(&old);
        }
    }

    /// The tool call result block `b` completes, completed; `None` if the
    /// call was not seen (it is on an earlier page).
    fn result(&mut self, b: &Value, extra: &Value) -> Option<Item> {
        let id = s(b, "tool_use_id");
        let mut item = self.tools.get(id)?.clone();
        let mut text = content_text(b.get("content").unwrap_or(&Value::Null));
        if let Some(out) = extra.get("stdout").and_then(Value::as_str) {
            // A command: its own output, and its errors after it.
            text = out.to_string();
            let err = s(extra, "stderr");
            if !err.is_empty() {
                if !text.is_empty() {
                    text.push('\n');
                }
                text.push_str(err);
            }
        }
        // A subagent: its report (the result itself only says where it
        // went), and which one it was.
        if let Some(report) = extra
            .get("handbackReport")
            .and_then(Value::as_str)
            .filter(|r| !r.is_empty())
        {
            text = report.to_string();
        }
        item.agent = s(extra, "agentId").to_string();
        let (output, was_cut) = cut(&text, MAX_TEXT);
        item.output = output;
        item.cut = was_cut;
        item.done = true;
        item.error = b.get("is_error").and_then(Value::as_bool) == Some(true);
        if let Some(p) = extra.get("structuredPatch").filter(|p| p.is_array()) {
            item.patch = p.clone();
        }
        item.persisted = s(extra, "persistedOutputPath").to_string();
        self.remember(item.clone());
        Some(item)
    }
}

/// Add `items` to `list`, a completed tool call replacing its call.
pub fn upsert(list: &mut Vec<Item>, items: Vec<Item>) {
    for item in items {
        match list.iter().position(|i| i.key == item.key) {
            Some(i) => list[i] = item,
            None => list.push(item),
        }
    }
}

// ── The lines of a transcript ───────────────────────────────────────────────

/// Where each complete line of a transcript starts, and where the complete
/// lines end. Transcripts only grow: the index is extended, not rebuilt.
#[derive(Default, Clone)]
pub(super) struct Index {
    pub(super) starts: Vec<u64>,
    end: u64,
}

static INDEXES: LazyLock<Mutex<HashMap<PathBuf, Index>>> = LazyLock::new(Default::default);

pub(super) fn index(path: &Path) -> Index {
    let len = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    let mut all = INDEXES.lock().unwrap();
    let mut idx = all.get(path).cloned().unwrap_or_default();
    if len < idx.end {
        idx = Index::default(); // rewritten
    }
    if len > idx.end {
        if let Ok(mut f) = std::fs::File::open(path) {
            if f.seek(SeekFrom::Start(idx.end)).is_ok() {
                let mut buf = Vec::new();
                let _ = f.take(len - idx.end).read_to_end(&mut buf);
                let mut start = idx.end;
                for (i, b) in buf.iter().enumerate() {
                    if *b == b'\n' {
                        idx.starts.push(start);
                        start = idx.end + i as u64 + 1;
                    }
                }
                idx.end = start;
            }
        }
    }
    all.insert(path.to_path_buf(), idx.clone());
    idx
}

/// Lines `from..to` of the transcript, parsed (`Null` for a broken one).
pub(super) fn read_lines(path: &Path, idx: &Index, from: usize, to: usize) -> Vec<Value> {
    let to = to.min(idx.starts.len());
    if from >= to {
        return Vec::new();
    }
    let start = idx.starts[from];
    let end = idx.starts.get(to).copied().unwrap_or(idx.end);
    let mut buf = Vec::new();
    if let Ok(mut f) = std::fs::File::open(path) {
        if f.seek(SeekFrom::Start(start)).is_ok() {
            let _ = f.take(end - start).read_to_end(&mut buf);
        }
    }
    buf.split(|b| *b == b'\n')
        .take(to - from)
        .map(|l| serde_json::from_slice(l).unwrap_or(Value::Null))
        .collect()
}

/// A page of a conversation.
#[derive(Serialize, Default)]
pub struct Page {
    pub items: Vec<Item>,
    /// The line it starts at: the `before` of the page above it, 0 when it
    /// is the beginning.
    pub first: usize,
    /// The transcript's lines.
    pub total: usize,
}

/// The items of the lines before line `before` (the end when `None`): at
/// least `limit` of them when the transcript has that many. The feed it
/// returns knows the page's tool calls, to complete them later (`Tail`).
pub fn page(path: &Path, before: Option<usize>, limit: usize) -> (Page, Feed) {
    let idx = index(path);
    let total = idx.starts.len();
    let before = before.unwrap_or(total).min(total);
    let mut span = 400;
    loop {
        let first = before.saturating_sub(span);
        let mut feed = Feed::default();
        let mut items = Vec::new();
        for v in read_lines(path, &idx, first, before) {
            let new = feed.line(&v);
            upsert(&mut items, new);
        }
        if items.len() >= limit || first == 0 {
            // The results of the last calls, just after the page.
            for v in read_lines(path, &idx, before, before + LOOKAHEAD) {
                let done: Vec<Item> = feed
                    .line(&v)
                    .into_iter()
                    .filter(|i| i.kind == "tool" && items.iter().any(|x| x.key == i.key))
                    .collect();
                upsert(&mut items, done);
            }
            return (
                Page {
                    items,
                    first,
                    total,
                },
                feed,
            );
        }
        span *= 3;
    }
}

/// Follows a transcript's end: the items of the lines written since.
pub struct Tail {
    path: PathBuf,
    line: usize,
    feed: Feed,
}

impl Tail {
    /// From line `line` on, the calls `feed` knows still to complete.
    pub fn new(path: PathBuf, line: usize, feed: Feed) -> Self {
        Self { path, line, feed }
    }

    pub fn read(&mut self) -> Vec<Item> {
        let idx = index(&self.path);
        let total = idx.starts.len();
        if total < self.line {
            self.line = 0; // rewritten
        }
        let mut items = Vec::new();
        for v in read_lines(&self.path, &idx, self.line, total) {
            let new = self.feed.line(&v);
            upsert(&mut items, new);
        }
        self.line = total;
        items
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// The transcript of session `id`, or of its subagent `agent`
/// (`<session>/subagents/agent-<agent>.jsonl`).
pub fn conversation(id: &str, agent: Option<&str>) -> Option<PathBuf> {
    let main = super::sessions::transcript_of(id)?;
    match agent {
        None => Some(main),
        Some(a) => {
            // An id, never a path.
            if a.is_empty() || !a.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
                return None;
            }
            let p = main
                .with_extension("")
                .join("subagents")
                .join(format!("agent-{a}.jsonl"));
            p.exists().then_some(p)
        }
    }
}

/// The long output of a tool call, which Claude Code keeps in a file of its
/// own beside session `id`'s transcript, or a background command's output
/// (`/tmp/claude-<uid>/<project>/<id>/tasks/<task>.output`): only those
/// files.
pub fn output(id: &str, path: &str) -> Result<String, String> {
    let transcript = super::sessions::transcript_of(id).ok_or("session inconnue")?;
    let dir = transcript.with_extension("");
    let real = std::fs::canonicalize(path).map_err(|e| e.to_string())?;
    let dir = std::fs::canonicalize(&dir).unwrap_or(dir);
    let task = real.starts_with("/tmp")
        && real.extension().and_then(|e| e.to_str()) == Some("output")
        && real.to_string_lossy().contains(&format!("/{id}/tasks/"));
    if !real.starts_with(&dir) && !task {
        return Err("hors de la session".into());
    }
    let text = std::fs::read_to_string(&real).map_err(|e| e.to_string())?;
    Ok(cut(&text, 2_000_000).0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn feed_all(lines: &[Value]) -> Vec<Item> {
        let mut feed = Feed::default();
        let mut items = Vec::new();
        for l in lines {
            let new = feed.line(l);
            upsert(&mut items, new);
        }
        items
    }

    #[test]
    fn requests_text_thinking_and_tools_become_items() {
        let items = feed_all(&[
            json!({"type":"user","uuid":"u1","message":{"content":"Fix the bar"}}),
            json!({"type":"assistant","uuid":"a1","cwd":"/p","message":{"content":[
                {"type":"thinking","thinking":"Let me look"},
                {"type":"thinking","thinking":"","signature":"x"},
                {"type":"text","text":"On it."},
                {"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/Bar.qml"}}
            ]}}),
        ]);
        let kinds: Vec<_> = items.iter().map(|i| i.kind.as_str()).collect();
        assert_eq!(kinds, ["user", "thinking", "text", "tool"]);
        assert_eq!(items[3].summary, "Bar.qml");
        assert!(!items[3].done);
    }

    #[test]
    fn a_result_completes_its_call_in_place() {
        let items = feed_all(&[
            json!({"type":"assistant","uuid":"a1","message":{"content":[
                {"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}),
            json!({"type":"user","uuid":"u2","message":{"content":[
                {"type":"tool_result","tool_use_id":"t1","content":"ignored"}]},
                "toolUseResult":{"stdout":"a\nb","stderr":"warn"}}),
            json!({"type":"assistant","uuid":"a2","message":{"content":[
                {"type":"tool_use","id":"t2","name":"Edit","input":{}}]}}),
            json!({"type":"user","uuid":"u3","message":{"content":[
                {"type":"tool_result","tool_use_id":"t2","content":"ok","is_error":true}]},
                "tool_use_result":{"structuredPatch":[{"oldStart":1,"lines":["-a","+b"]}]}}),
        ]);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].output, "a\nb\nwarn");
        assert!(items[0].done && !items[0].error);
        assert!(items[1].error);
        assert_eq!(items[1].patch[0]["lines"][1], "+b");
    }

    #[test]
    fn what_claude_code_writes_itself_is_hidden_and_commands_are_notes() {
        let items = feed_all(&[
            json!({"type":"user","uuid":"m","isMeta":true,"message":{"content":"caveat"}}),
            json!({"type":"user","uuid":"r","message":{"content":"<system-reminder>x</system-reminder>"}}),
            json!({"type":"user","uuid":"c","message":{"content":
                "<command-name>/model</command-name><command-args>opus</command-args>"}}),
            json!({"type":"user","uuid":"i","message":{"content":[
                {"type":"text","text":"[Request interrupted by user]"}]}}),
            json!({"type":"attachment","uuid":"x"}),
            json!({"type":"user","uuid":"img","message":{"content":[{"type":"image","source":{}}]}}),
        ]);
        let shown: Vec<_> = items
            .iter()
            .map(|i| (i.kind.as_str(), i.text.as_str(), i.images))
            .collect();
        assert_eq!(
            shown,
            [
                ("note", "/model opus", 0),
                ("note", "interrupted", 0),
                ("user", "", 1)
            ]
        );
    }

    #[test]
    fn a_local_command_shows_its_answer() {
        let items = feed_all(&[
            json!({"type":"system","subtype":"local_command","uuid":"a","content":"/permissions"}),
            json!({"type":"system","subtype":"local_command","uuid":"b","content":
                "<local-command-stdout>\u{1b}[1mRenamed\u{1b}[22m</local-command-stdout>"}),
            json!({"type":"system","subtype":"local_command","uuid":"c","content":
                "<local-command-stdout></local-command-stdout>"}),
        ]);
        let shown: Vec<_> = items
            .iter()
            .map(|i| (i.kind.as_str(), i.text.as_str()))
            .collect();
        assert_eq!(shown, [("note", "/permissions"), ("text", "Renamed")]);
    }

    #[test]
    fn subagent_lines_name_their_call_and_unknown_blocks_show() {
        let items = feed_all(&[
            json!({"type":"assistant","uuid":"a","parent_tool_use_id":"t9",
            "message":{"content":[{"type":"text","text":"sub"},{"type":"mystery"}]}}),
        ]);
        assert_eq!(items[0].parent, "t9");
        assert_eq!(
            (items[1].kind.as_str(), items[1].text.as_str()),
            ("other", "mystery")
        );
    }

    #[test]
    fn long_outputs_are_cut() {
        let long = "x".repeat(MAX_TEXT + 10);
        let items = feed_all(&[
            json!({"type":"assistant","uuid":"a","message":{"content":[
                {"type":"tool_use","id":"t","name":"Read","input":{}}]}}),
            json!({"type":"user","uuid":"u","message":{"content":[
                {"type":"tool_result","tool_use_id":"t","content":[{"type":"text","text":long}]}]}}),
        ]);
        assert!(items[0].cut);
        assert_eq!(items[0].output.chars().count(), MAX_TEXT);
    }

    fn transcript(lines: &[Value], partial: &str) -> PathBuf {
        use std::io::Write;
        let dir = std::env::temp_dir().join(format!(
            "anna-transcript-{}-{}",
            std::process::id(),
            lines.len()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("s.jsonl");
        let mut f = std::fs::File::create(&path).unwrap();
        for l in lines {
            writeln!(f, "{l}").unwrap();
        }
        write!(f, "{partial}").unwrap();
        path
    }

    #[test]
    fn pages_go_back_from_the_end_and_skip_a_cut_last_line() {
        let mut lines: Vec<Value> = (0..1000)
            .map(|i| json!({"type":"user","uuid":format!("u{i}"),"message":{"content":format!("m{i}")}}))
            .collect();
        lines.insert(500, json!({"type":"attachment"}));
        let path = transcript(&lines, "{\"type\":\"user\",\"uuid\":\"cut");
        let (p, _) = page(&path, None, 50);
        assert_eq!(p.total, 1001);
        assert!(p.items.len() >= 50);
        assert_eq!(p.items.last().unwrap().text, "m999");
        let (up, _) = page(&path, Some(p.first), 50);
        assert_eq!(up.items.last().unwrap().text, format!("m{}", p.first - 2));
        let (top, _) = page(&path, Some(10), 50);
        assert_eq!((top.first, top.items.len()), (0, 10));
    }

    #[test]
    fn a_page_finds_the_results_just_after_it_and_the_tail_the_later_ones() {
        let call = |id: &str| {
            json!({"type":"assistant","uuid":id,"message":{"content":[
            {"type":"tool_use","id":id,"name":"Bash","input":{}}]}})
        };
        let result = |id: &str| {
            json!({"type":"user","uuid":format!("r{id}"),"message":{"content":[
            {"type":"tool_result","tool_use_id":id,"content":"done"}]}})
        };
        let path = transcript(&[call("t1"), result("t1"), call("t2")], "");
        let (p, feed) = page(&path, Some(1), 10);
        assert!(p.items[0].done, "result read ahead");
        let (p, feed2) = page(&path, None, 10);
        assert!(!p.items[1].done);
        drop(feed);
        let mut tail = Tail::new(path.clone(), p.total, feed2);
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap();
        writeln!(f, "{}", result("t2")).unwrap();
        let new = tail.read();
        assert_eq!((new[0].key.as_str(), new[0].done), ("t2", true));
        assert!(tail.read().is_empty());
    }
}
