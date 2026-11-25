//! What a whole Claude Code session amounts to, for the panes beside its
//! conversation in the « Claude » tab — as in Claude Desktop:
//!
//! - **context**: how full the model's context is (the last request's
//!   input tokens against its window), the model, the connectors (MCP
//!   servers) it called and the files it read;
//! - **changes**: every file it edited or wrote, with the lines added and
//!   removed (the diff itself on demand: `diff`);
//! - **outputs**: what it produced to look at or reuse (outputs.rs);
//! - **jobs**: its subagents (`Agent`, `Task`), its background commands
//!   (`run_in_background`) and the tasks that report back
//!   (`<task-notification>`), with their state; and its task list
//!   (`TaskCreate` / `TaskUpdate`, `TodoWrite` before them).
//!
//! It is read from the whole transcript, once, then from its new lines
//! only (the state is kept per transcript). The subagents are completed from
//! their own files, `<session>/subagents/agent-<id>.meta.json`, which say
//! which call started them before that call has a result.

use super::outputs::{Finder, Output};
use super::transcript::{content_text, cut, index, read_lines, s};
use serde::Serialize;
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

/// The files read that are listed (the latest).
const READ_KEPT: usize = 40;
/// The hunks kept per changed file, for `diff`.
const HUNKS_KEPT: usize = 200;
/// The longest report or summary of a job kept.
const REPORT_MAX: usize = 6_000;

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Context {
    /// The input of the last request: what the context holds now.
    pub tokens: u64,
    /// The model's window (`window_of`).
    pub window: u64,
    pub model: String,
    /// Times the conversation was compacted.
    pub compactions: u32,
    /// The connectors called: `[{name, calls}]`, most called first.
    pub connectors: Vec<Count>,
    /// The tools called, most called first.
    pub tools: Vec<Count>,
    /// The files read, latest first.
    pub read: Vec<String>,
    /// What the session cost so far (dollars, list price), as Claude Code
    /// keeps it (`cost-state` lines): in all, and per model.
    pub cost: f64,
    pub cost_models: Vec<Cost>,
    /// The lines Claude Code counts as added and removed by the session.
    pub lines_added: u64,
    pub lines_removed: u64,
}

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Count {
    pub name: String,
    pub calls: u32,
}

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Cost {
    pub model: String,
    pub cost: f64,
}

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Change {
    pub path: String,
    pub added: u32,
    pub removed: u32,
    /// Created by the session (it did not exist before).
    pub created: bool,
    pub edits: u32,
    /// Its hunks (`structuredPatch`), oldest first: sent by `diff` only.
    #[serde(skip)]
    pub hunks: Vec<Value>,
}

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Job {
    /// The tool call that started it, or the task's id.
    pub key: String,
    /// `agent`, `background` or `task`.
    pub kind: String,
    pub title: String,
    /// The subagent's type (« Explore »), the command…
    pub detail: String,
    /// `running`, `completed`, `failed`, `stopped`…
    pub status: String,
    /// A subagent: its id (its conversation), what it reported, its work.
    pub agent: String,
    pub report: String,
    pub tokens: u64,
    pub duration_ms: u64,
    pub tool_uses: u64,
    /// A background command: the file its output goes to.
    pub output_file: String,
    /// The task id it reports under (`<task-id>`).
    #[serde(skip)]
    pub task: String,
}

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Todo {
    pub id: String,
    pub subject: String,
    /// `pending`, `in_progress`, `completed`.
    pub status: String,
}

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Summary {
    pub context: Context,
    pub changes: Vec<Change>,
    pub outputs: Vec<Output>,
    pub jobs: Vec<Job>,
    pub todos: Vec<Todo>,
}

/// The context window of `model`, as Claude Code reports it
/// (`modelUsage.contextWindow`): a million for the 5 family, 200 000
/// before; `[1m]` asks for the million.
pub fn window_of(model: &str) -> u64 {
    let m = model.to_ascii_lowercase();
    // The generation: the first number of the name (`claude-opus-5-5`,
    // `claude-3-5-sonnet`).
    let generation = m
        .split(['-', '['])
        .find_map(|p| p.parse::<u32>().ok())
        .unwrap_or(0);
    if m.contains("[1m]") || generation >= 5 {
        1_000_000
    } else {
        200_000
    }
}

/// The summary being built, and what it needs to go on.
#[derive(Default)]
pub struct Builder {
    summary: Summary,
    cwd: String,
    /// Tool calls seen: their name and input.
    calls: HashMap<String, (String, Value)>,
    connectors: HashMap<String, u32>,
    tools: HashMap<String, u32>,
    /// The line it has read up to.
    line: usize,
    /// A subagent's own transcript: its lines are all side ones.
    subagent: bool,
    outputs: Finder,
    /// The folder of the last line: what a command names is relative to it.
    here: String,
}

impl Builder {
    fn rel(&self, path: &str) -> String {
        if self.cwd.is_empty() {
            return path.to_string();
        }
        path.strip_prefix(&format!("{}/", self.cwd))
            .unwrap_or(path)
            .to_string()
    }

    fn job(&mut self, key: &str) -> Option<&mut Job> {
        self.summary.jobs.iter_mut().find(|j| j.key == key)
    }

    /// Take line `v` into account.
    pub fn line(&mut self, v: &Value) {
        // Only the main thread: a subagent's lines are its own (unless this
        // is that subagent's transcript).
        if (!self.subagent && v.get("isSidechain").and_then(Value::as_bool) == Some(true))
            || !s(v, "parent_tool_use_id").is_empty()
        {
            return;
        }
        if matches!(s(v, "type"), "user" | "assistant") {
            self.outputs.time(s(v, "timestamp"));
            let here = s(v, "cwd");
            if !here.is_empty() {
                self.here = here.to_string();
            }
        }
        if self.cwd.is_empty() {
            self.cwd = s(v, "cwd").to_string();
        }
        match s(v, "type") {
            "assistant" => self.assistant(v),
            "user" => self.user(v),
            "system" if s(v, "subtype") == "compact_boundary" => {
                self.summary.context.compactions += 1;
            }
            // The running totals: the last one holds.
            "cost-state" => {
                let ctx = &mut self.summary.context;
                ctx.cost = v
                    .get("totalCostUSD")
                    .and_then(Value::as_f64)
                    .unwrap_or(ctx.cost);
                ctx.lines_added = v
                    .get("totalLinesAdded")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                ctx.lines_removed = v
                    .get("totalLinesRemoved")
                    .and_then(Value::as_u64)
                    .unwrap_or(0);
                let mut models: Vec<Cost> = v
                    .get("modelUsage")
                    .and_then(Value::as_object)
                    .into_iter()
                    .flatten()
                    .map(|(m, u)| Cost {
                        model: m.clone(),
                        cost: u.get("costUSD").and_then(Value::as_f64).unwrap_or(0.0),
                    })
                    .collect();
                models.sort_by(|a, b| b.cost.total_cmp(&a.cost));
                ctx.cost_models = models;
            }
            _ => {}
        }
    }

    fn assistant(&mut self, v: &Value) {
        let msg = v.get("message").unwrap_or(&Value::Null);
        if let Some(u) = msg.get("usage") {
            let n = |k: &str| u.get(k).and_then(Value::as_u64).unwrap_or(0);
            let tokens =
                n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens");
            if tokens > 0 {
                self.summary.context.tokens = tokens;
            }
        }
        let model = s(msg, "model");
        if !model.is_empty() && !model.starts_with('<') {
            self.summary.context.model = model.to_string();
            self.summary.context.window = window_of(model);
        }
        for b in msg
            .get("content")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if s(b, "type") != "tool_use" {
                continue;
            }
            let id = s(b, "id").to_string();
            let name = s(b, "name").to_string();
            let input = b.get("input").cloned().unwrap_or(Value::Null);
            *self.tools.entry(name.clone()).or_default() += 1;
            if let Some(server) = name
                .strip_prefix("mcp__")
                .and_then(|r| r.split("__").next())
            {
                *self.connectors.entry(connector(server)).or_default() += 1;
            }
            match name.as_str() {
                "Read" | "NotebookRead" => {
                    let p = self.rel(s(&input, "file_path"));
                    if !p.is_empty() {
                        let read = &mut self.summary.context.read;
                        read.retain(|r| *r != p);
                        read.insert(0, p);
                        read.truncate(READ_KEPT);
                    }
                }
                "Agent" | "Task" => self.summary.jobs.push(Job {
                    key: id.clone(),
                    kind: "agent".into(),
                    title: s(&input, "description").to_string(),
                    detail: s(&input, "subagent_type").to_string(),
                    status: "running".into(),
                    ..Default::default()
                }),
                "Bash" if input.get("run_in_background").and_then(Value::as_bool) == Some(true) => {
                    let title = match s(&input, "description") {
                        "" => s(&input, "command").lines().next().unwrap_or_default(),
                        d => d,
                    };
                    self.summary.jobs.push(Job {
                        key: id.clone(),
                        kind: "background".into(),
                        title: title.chars().take(120).collect(),
                        detail: cut(s(&input, "command"), 400).0,
                        status: "running".into(),
                        ..Default::default()
                    });
                }
                "TodoWrite" => {
                    self.summary.todos = input
                        .get("todos")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                        .enumerate()
                        .map(|(i, t)| Todo {
                            id: i.to_string(),
                            subject: s(t, "content").to_string(),
                            status: s(t, "status").to_string(),
                        })
                        .collect();
                }
                "TaskUpdate" => {
                    let task = s(&input, "taskId");
                    let status = s(&input, "status");
                    if let Some(t) = self.summary.todos.iter_mut().find(|t| t.id == task) {
                        if !status.is_empty() {
                            t.status = status.to_string();
                        }
                        if let Some(sub) = input.get("subject").and_then(Value::as_str) {
                            t.subject = sub.to_string();
                        }
                    }
                    if status == "deleted" {
                        self.summary.todos.retain(|t| t.id != task);
                    }
                }
                _ => {}
            }
            self.calls.insert(id, (name, input));
        }
    }

    fn user(&mut self, v: &Value) {
        let extra = v
            .get("toolUseResult")
            .or_else(|| v.get("tool_use_result"))
            .unwrap_or(&Value::Null);
        let content = v.pointer("/message/content").unwrap_or(&Value::Null);
        if let Value::String(t) = content {
            self.notification(t);
        }
        for p in content.as_array().into_iter().flatten() {
            match s(p, "type") {
                "text" => self.notification(s(p, "text")),
                "tool_result" => {
                    let error = p.get("is_error").and_then(Value::as_bool) == Some(true);
                    let text = content_text(p.get("content").unwrap_or(&Value::Null));
                    self.result(s(p, "tool_use_id"), extra, error, &text);
                }
                _ => {}
            }
        }
    }

    fn result(&mut self, id: &str, extra: &Value, error: bool, text: &str) {
        let Some((name, input)) = self.calls.get(id).cloned() else {
            return;
        };
        // What it produced: named by a command or a connector, or published.
        if name == "Bash" || name.starts_with("mcp__") {
            let home = crate::paths::home_dir();
            let here = match cd(s(&input, "command")) {
                Some(dir) => Path::new(&self.here)
                    .join(dir)
                    .to_string_lossy()
                    .into_owned(),
                None => self.here.clone(),
            };
            self.outputs.mention_value(&input, &here, &home);
            self.outputs.mention(text, &here, &home);
        } else if name == "Artifact" && !error {
            self.outputs.artifact(&input, text);
        }
        match name.as_str() {
            "Edit" | "MultiEdit" | "Write" | "NotebookEdit" if !error => {
                let path = s(extra, "filePath");
                let path = if path.is_empty() {
                    s(&input, "file_path")
                } else {
                    path
                };
                if path.is_empty() {
                    return;
                }
                let created = s(extra, "type") == "create";
                let hunks: Vec<Value> = extra
                    .get("structuredPatch")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let (mut added, mut removed) = (0, 0);
                for h in &hunks {
                    for l in h
                        .get("lines")
                        .and_then(Value::as_array)
                        .into_iter()
                        .flatten()
                    {
                        match l.as_str().and_then(|l| l.chars().next()) {
                            Some('+') => added += 1,
                            Some('-') => removed += 1,
                            _ => {}
                        }
                    }
                }
                if created {
                    added = s(extra, "content").lines().count() as u32;
                }
                let rel = self.rel(path);
                let changes = &mut self.summary.changes;
                let i = match changes.iter().position(|c| c.path == rel) {
                    Some(i) => i,
                    None => {
                        changes.push(Change {
                            path: rel.clone(),
                            created,
                            ..Default::default()
                        });
                        changes.len() - 1
                    }
                };
                let c = &mut changes[i];
                c.added += added;
                c.removed += removed;
                c.edits += 1;
                if created {
                    c.hunks.push(serde_json::json!({
                        "oldStart": 0, "newStart": 1,
                        "lines": s(extra, "content").lines().map(|l| format!("+{l}")).collect::<Vec<_>>(),
                    }));
                } else {
                    c.hunks.extend(hunks);
                }
                if c.hunks.len() > HUNKS_KEPT {
                    let extra = c.hunks.len() - HUNKS_KEPT;
                    c.hunks.drain(..extra);
                }
                if created {
                    self.outputs.wrote(path, &crate::paths::home_dir());
                }
            }
            "Agent" | "Task" => {
                let status = match s(extra, "status") {
                    "" if error => "failed",
                    "" => "completed",
                    st => st,
                }
                .to_string();
                let n = |k: &str| extra.get(k).and_then(Value::as_u64).unwrap_or(0);
                let report = match extra.get("handbackReport").and_then(Value::as_str) {
                    Some(r) if !r.is_empty() => r.to_string(),
                    _ => content_text(extra.get("content").unwrap_or(&Value::Null)),
                };
                let agent = s(extra, "agentId").to_string();
                let (tokens, duration, uses) = (
                    n("totalTokens"),
                    n("totalDurationMs"),
                    n("totalToolUseCount"),
                );
                if let Some(j) = self.job(id) {
                    j.status = if error { "failed".into() } else { status };
                    j.report = cut(&report, REPORT_MAX).0;
                    if !agent.is_empty() {
                        j.agent = agent;
                    }
                    j.tokens = tokens;
                    j.duration_ms = duration;
                    j.tool_uses = uses;
                }
            }
            "Bash" => {
                let task = s(extra, "backgroundTaskId").to_string();
                if let Some(j) = self.job(id) {
                    if task.is_empty() {
                        // Ran in the foreground after all, or failed to start.
                        j.status = if error { "failed" } else { "completed" }.into();
                    } else {
                        j.task = task;
                    }
                }
            }
            "TaskCreate" => {
                let task = extra.get("task").unwrap_or(&Value::Null);
                let id = s(task, "id").to_string();
                if !id.is_empty() {
                    self.summary.todos.push(Todo {
                        id,
                        subject: match s(task, "subject") {
                            "" => s(&input, "subject"),
                            sub => sub,
                        }
                        .to_string(),
                        status: "pending".into(),
                    });
                }
            }
            _ => {}
        }
    }

    /// A task reporting back: `<task-notification><task-id>…</task-id>
    /// <tool-use-id>…</tool-use-id><output-file>…</output-file><status>…
    /// </status><summary>…</summary></task-notification>`.
    fn notification(&mut self, text: &str) {
        let Some(body) = between(text, "<task-notification>", "</task-notification>") else {
            return;
        };
        let tag = |t: &str| {
            between(body, &format!("<{t}>"), &format!("</{t}>"))
                .unwrap_or_default()
                .trim()
                .to_string()
        };
        let (task, call, status, summary, file) = (
            tag("task-id"),
            tag("tool-use-id"),
            tag("status"),
            tag("summary"),
            tag("output-file"),
        );
        let found =
            self.summary.jobs.iter_mut().find(|j| {
                (!call.is_empty() && j.key == call) || (!task.is_empty() && j.task == task)
            });
        let job = match found {
            Some(j) => j,
            None => {
                self.summary.jobs.push(Job {
                    key: if call.is_empty() { task.clone() } else { call },
                    kind: "task".into(),
                    title: summary.clone(),
                    task: task.clone(),
                    ..Default::default()
                });
                self.summary.jobs.last_mut().unwrap()
            }
        };
        if !status.is_empty() {
            job.status = status;
        }
        if !summary.is_empty() {
            job.report = cut(&summary, REPORT_MAX).0;
        }
        if !file.is_empty() {
            job.output_file = file;
        }
        let result = tag("result");
        if !result.is_empty() && job.kind == "task" {
            job.report = cut(&format!("{}\n{result}", job.report), REPORT_MAX).0;
        }
    }

    /// The summary, with what changes without a line being written: the
    /// counts sorted, the outputs looked at on disk, the subagents' files.
    fn finish(&self, transcript: &Path) -> Summary {
        let mut sum = self.summary.clone();
        let sorted = |m: &HashMap<String, u32>| {
            let mut v: Vec<Count> = m
                .iter()
                .map(|(name, calls)| Count {
                    name: name.clone(),
                    calls: *calls,
                })
                .collect();
            v.sort_by(|a, b| b.calls.cmp(&a.calls).then(a.name.cmp(&b.name)));
            v
        };
        sum.context.connectors = sorted(&self.connectors);
        sum.context.tools = sorted(&self.tools);
        let home = crate::paths::home_dir();
        let edited: HashSet<String> = sum
            .changes
            .iter()
            .filter(|c| !c.created)
            .map(|c| {
                Path::new(&self.cwd)
                    .join(&c.path)
                    .to_string_lossy()
                    .into_owned()
            })
            .collect();
        let project = Path::new(&self.cwd)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        sum.outputs = self.outputs.list(&project, &home, &edited);
        // The subagents' own files: which call started each, whether done.
        let dir = transcript.with_extension("").join("subagents");
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            let Some(agent) = name
                .strip_prefix("agent-")
                .and_then(|n| n.strip_suffix(".meta.json"))
            else {
                continue;
            };
            let Ok(meta) = std::fs::read_to_string(e.path())
                .map_err(|_| ())
                .and_then(|t| serde_json::from_str::<Value>(&t).map_err(|_| ()))
            else {
                continue;
            };
            let call = s(&meta, "toolUseId");
            let finished = meta.get("finished").and_then(Value::as_bool) == Some(true);
            match sum.jobs.iter_mut().find(|j| j.key == call) {
                Some(j) => {
                    j.agent = agent.to_string();
                    if finished && j.status == "running" {
                        j.status = "completed".into();
                    }
                }
                None => sum.jobs.push(Job {
                    key: if call.is_empty() {
                        agent.to_string()
                    } else {
                        call.to_string()
                    },
                    kind: "agent".into(),
                    title: s(&meta, "description").to_string(),
                    detail: s(&meta, "agentType").to_string(),
                    status: if finished { "completed" } else { "running" }.into(),
                    agent: agent.to_string(),
                    ..Default::default()
                }),
            }
        }
        sum
    }
}

/// The folder a command starts by going to: `cd /x && …`.
fn cd(command: &str) -> Option<&str> {
    let rest = command.trim_start().strip_prefix("cd ")?;
    let end = rest.find(['&', ';', '\n']).unwrap_or(rest.len());
    let dir = rest[..end].trim().trim_matches(['"', '\'']);
    (!dir.is_empty() && !dir.contains(['$', '~', ' '])).then_some(dir)
}

/// A connector's name as people know it, from the one in its tools' names:
/// `plugin_hm_codegraph` → `codegraph`, `claude_ai_Gmail` → `claude.ai
/// Gmail`.
fn connector(server: &str) -> String {
    if let Some(rest) = server.strip_prefix("claude_ai_") {
        return format!("claude.ai {}", rest.replace('_', " "));
    }
    if let Some(rest) = server.strip_prefix("plugin_") {
        // plugin_<plugin>_<server>: the server.
        if let Some((_, name)) = rest.split_once('_') {
            return name.to_string();
        }
    }
    server.to_string()
}

fn between<'a>(text: &'a str, open: &str, close: &str) -> Option<&'a str> {
    let start = text.find(open)? + open.len();
    let end = text[start..].find(close)? + start;
    Some(&text[start..end])
}

static BUILDERS: LazyLock<Mutex<HashMap<PathBuf, Builder>>> = LazyLock::new(Default::default);

/// The summary of transcript `path`, read on from where it was left.
pub fn summary(path: &Path) -> Summary {
    let idx = index(path);
    let total = idx.starts.len();
    let mut all = BUILDERS.lock().unwrap();
    let subagent = path
        .parent()
        .and_then(|p| p.file_name())
        .is_some_and(|n| n == "subagents");
    let b = all.entry(path.to_path_buf()).or_insert_with(|| Builder {
        subagent,
        ..Default::default()
    });
    if total < b.line {
        *b = Builder {
            subagent,
            ..Default::default()
        }; // rewritten
    }
    // A long session is read in slices, so the lines never all sit in
    // memory at once.
    while b.line < total {
        let to = (b.line + 2_000).min(total);
        for v in read_lines(path, &idx, b.line, to) {
            b.line(&v);
        }
        b.line = to;
    }
    b.finish(path)
}

/// The hunks of the changes made to `file` (as `Change::path` names it).
pub fn diff(path: &Path, file: &str) -> Vec<Value> {
    summary(path);
    let all = BUILDERS.lock().unwrap();
    all.get(path)
        .and_then(|b| b.summary.changes.iter().find(|c| c.path == file))
        .map(|c| c.hunks.clone())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn build(lines: &[Value]) -> Summary {
        let mut b = Builder::default();
        for l in lines {
            b.line(l);
        }
        b.finish(Path::new("/nonexistent/x.jsonl"))
    }

    fn call(id: &str, name: &str, input: Value) -> Value {
        json!({"type":"assistant","cwd":"/p","message":{"model":"claude-opus-5-5",
            "usage":{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":20},
            "content":[{"type":"tool_use","id":id,"name":name,"input":input}]}})
    }

    fn result(id: &str, extra: Value) -> Value {
        json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":id,"content":"x"}]},
            "toolUseResult": extra})
    }

    #[test]
    fn context_counts_the_last_request_and_the_connectors() {
        let s = build(&[
            call("1", "Read", json!({"file_path":"/p/a.rs"})),
            call("2", "mcp__codegraph__explore", json!({})),
            call("3", "mcp__codegraph__explore", json!({})),
            call("4", "Read", json!({"file_path":"/p/b.rs"})),
            call("5", "Read", json!({"file_path":"/p/a.rs"})),
            json!({"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":999999}}}),
        ]);
        assert_eq!((s.context.tokens, s.context.window), (1025, 1_000_000));
        assert_eq!(s.context.read, ["a.rs", "b.rs"]);
        assert_eq!(
            s.context.connectors,
            [Count {
                name: "codegraph".into(),
                calls: 2
            }]
        );
        assert_eq!(s.context.tools[0].name, "Read");
    }

    #[test]
    fn edits_and_new_files_add_up_per_file() {
        let s = build(&[
            call("e1", "Edit", json!({"file_path":"/p/a.rs"})),
            result(
                "e1",
                json!({"filePath":"/p/a.rs","structuredPatch":[{"lines":[" k","-a","+b","+c"]}]}),
            ),
            call("e2", "Edit", json!({"file_path":"/p/a.rs"})),
            result(
                "e2",
                json!({"filePath":"/p/a.rs","structuredPatch":[{"lines":["-x"]}]}),
            ),
            call("w", "Write", json!({"file_path":"/p/new.md"})),
            result(
                "w",
                json!({"type":"create","filePath":"/p/new.md","content":"1\n2\n3"}),
            ),
        ]);
        let c: Vec<_> = s
            .changes
            .iter()
            .map(|c| (c.path.as_str(), c.added, c.removed, c.created, c.edits))
            .collect();
        assert_eq!(c, [("a.rs", 2, 2, false, 2), ("new.md", 3, 0, true, 1)]);
        assert_eq!(s.changes[0].hunks.len(), 2);
        assert_eq!(s.outputs[0].path, "/p/new.md");
    }

    #[test]
    fn subagents_and_background_commands_are_followed_to_their_end() {
        let s = build(&[
            call(
                "a",
                "Agent",
                json!({"description":"Look around","subagent_type":"Explore"}),
            ),
            call(
                "b",
                "Bash",
                json!({"command":"nix build","description":"Build","run_in_background":true}),
            ),
            result("b", json!({"stdout":"","backgroundTaskId":"t1"})),
            result(
                "a",
                json!({"status":"completed","agentId":"x1","handbackReport":"Found it",
                "totalTokens":1200,"totalDurationMs":3000,"totalToolUseCount":4}),
            ),
            json!({"type":"user","message":{"content":
                "<task-notification>\n<task-id>t1</task-id>\n<output-file>/tmp/t1.output</output-file>\n<status>completed</status>\n<summary>Build done (exit code 0)</summary>\n</task-notification>"}}),
            json!({"type":"user","message":{"content":
                "<task-notification><task-id>m9</task-id><status>failed</status><summary>MCP task m9 failed</summary></task-notification>"}}),
        ]);
        let j: Vec<_> = s
            .jobs
            .iter()
            .map(|j| (j.kind.as_str(), j.title.as_str(), j.status.as_str()))
            .collect();
        assert_eq!(
            j,
            [
                ("agent", "Look around", "completed"),
                ("background", "Build", "completed"),
                ("task", "MCP task m9 failed", "failed"),
            ]
        );
        assert_eq!(
            (s.jobs[0].agent.as_str(), s.jobs[0].report.as_str()),
            ("x1", "Found it")
        );
        assert_eq!(s.jobs[0].tool_uses, 4);
        assert_eq!(s.jobs[1].output_file, "/tmp/t1.output");
    }

    #[test]
    fn the_last_cost_state_gives_the_session_cost() {
        let s = build(&[
            json!({"type":"cost-state","totalCostUSD":1.0,"modelUsage":{}}),
            json!({"type":"cost-state","totalCostUSD":6.72,"totalLinesAdded":10,"totalLinesRemoved":3,
                "modelUsage":{"claude-haiku-5-5":{"costUSD":0.02},"claude-opus-5-5":{"costUSD":6.7}}}),
        ]);
        assert_eq!(s.context.cost, 6.72);
        assert_eq!((s.context.lines_added, s.context.lines_removed), (10, 3));
        assert_eq!(s.context.cost_models[0].model, "claude-opus-5-5");
    }

    #[test]
    fn the_task_list_follows_creates_and_updates() {
        let s = build(&[
            call("c1", "TaskCreate", json!({"subject":"One"})),
            result("c1", json!({"task":{"id":"1","subject":"One"}})),
            call("c2", "TaskCreate", json!({"subject":"Two"})),
            result("c2", json!({"task":{"id":"2","subject":"Two"}})),
            call(
                "u1",
                "TaskUpdate",
                json!({"taskId":"1","status":"completed"}),
            ),
            call(
                "u2",
                "TaskUpdate",
                json!({"taskId":"2","status":"in_progress"}),
            ),
        ]);
        let t: Vec<_> = s
            .todos
            .iter()
            .map(|t| (t.subject.as_str(), t.status.as_str()))
            .collect();
        assert_eq!(t, [("One", "completed"), ("Two", "in_progress")]);
    }

    #[test]
    fn windows_follow_the_model() {
        assert_eq!(window_of("claude-opus-5-5"), 1_000_000);
        assert_eq!(window_of("claude-sonnet-4-5"), 200_000);
        assert_eq!(window_of("claude-sonnet-4-5[1m]"), 1_000_000);
        assert_eq!(window_of("claude-3-5-sonnet-20241022"), 200_000);
        assert_eq!(window_of("claude-fable-5-2"), 1_000_000);
    }

    #[test]
    fn connectors_are_named_as_people_know_them() {
        assert_eq!(connector("plugin_hm_codegraph"), "codegraph");
        assert_eq!(connector("claude_ai_Claude_Docs"), "claude.ai Claude Docs");
        assert_eq!(connector("blender"), "blender");
    }

    /// The summary of a real transcript, printed:
    /// `ANNA_TRANSCRIPT=~/.claude/projects/…/<id>.jsonl cargo test --
    /// --ignored --nocapture summary_of_a_real_transcript`.
    #[test]
    #[ignore]
    fn summary_of_a_real_transcript() {
        let path = std::env::var("ANNA_TRANSCRIPT").expect("ANNA_TRANSCRIPT");
        let t = std::time::Instant::now();
        let s = summary(Path::new(&path));
        let first = t.elapsed();
        let t = std::time::Instant::now();
        summary(Path::new(&path));
        eprintln!("read in {first:?}, again in {:?}", t.elapsed());
        eprintln!("{}", serde_json::to_string_pretty(&s).unwrap());
    }
}
