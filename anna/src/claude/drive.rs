//! Driving Claude Code from the « Claude » tab, as Claude Desktop does: anna
//! runs a `claude` of its own on a conversation and speaks to it in
//! stream-json, the protocol of the Agent SDK.
//!
//! ```text
//! claude -p --input-format stream-json --output-format stream-json --verbose
//!        --include-partial-messages --permission-prompts host
//!        --permission-prompt-tool stdio  (--resume <id> | --session-id <id>)
//! ```
//!
//! What was checked against Claude Code 2.1.329 (by hand, 2026-11-24):
//!
//! - In: `{"type":"control_request","request_id","request":{"subtype":
//!   "initialize"}}` first, then `{"type":"user","message":{"role":"user",
//!   "content":…}}` for each request. `interrupt`, `set_permission_mode`
//!   (`mode`) and `set_model` (`model`) are control requests too.
//! - Out: `system/init` (model, permissionMode, mcp_servers), the messages
//!   (`assistant`, `user` with the tool results — the same uuids as in the
//!   transcript), `stream_event` (the text as it comes), and `result` at the
//!   end of each turn (`total_cost_usd`, `subtype` `success` or
//!   `error_during_execution` after an interrupt).
//! - Permissions: without `--permission-prompt-tool stdio`, whatever would
//!   ask is refused at once. With it, `claude` sends a `control_request`
//!   `can_use_tool` (`tool_name`, `input`, `description`,
//!   `permission_suggestions`, `tool_use_id`) and waits for
//!   `{"type":"control_response","response":{"subtype":"success",
//!   "request_id","response":{"behavior":"allow","updatedInput":…}}}`
//!   (`updatedPermissions` to keep the rule) or `{"behavior":"deny",
//!   "message"}`. `AskUserQuestion` comes the same way: its answers go back
//!   in `updatedInput.answers`, `{question: label}`.
//! - A driven `claude` writes its `~/.claude/sessions/<pid>.json` like any
//!   other (entrypoint `sdk-cli`): sessions.rs lists it, marked `driven`.
//!
//! - `set_model` answers `{model}` (resolved), `set_permission_mode`
//!   `{mode}`; the effort has no request of its own: `apply_flag_settings`
//!   with `{"settings":{"effortLevel":…}}` sets it. `initialize` answers
//!   with the models (`models`: `value`, `displayName`,
//!   `supportedEffortLevels`) and `get_context_usage` with the context's
//!   `categories` (system prompt, tools, MCP, messages…, in tokens).
//!
//! - Remote Control: `initialize` answers `remote_control_auto_enable` (the
//!   user's `remoteControlAtStartup`); `remote_control` (`enabled`) turns it
//!   on or off and answers `session_url`; `system/bridge_state` (`state`:
//!   `ready`, `connected`, `failed`…, `detail`) follows the link. An answer
//!   given from afar withdraws its card with `control_cancel_request`.
//!
//! The project's direnv is loaded before `claude` starts, as a terminal in
//! that folder would; a `.envrc` nobody allowed is never allowed here.
//!
//! The conversation itself is read from the transcript (transcript.rs), as
//! for a session in a terminal: what this module adds is the text being
//! written, the state (working or not, model, effort, mode, cost, context)
//! and the permission requests, which wait in the state (`asks`) until the
//! tab answers them (`answer`) — in the panel, under the conversation, as
//! in Claude Desktop.
//!
//! Only one `claude` may hold a conversation: driving one that runs
//! elsewhere is refused, `take_over` ends the other first.

use crate::i18n;
use crate::prompts::{Action, Choice, Field, Spec};
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin};
use tokio::sync::{broadcast, oneshot};

/// A driver nobody watches stops after this long without a turn.
const IDLE: Duration = Duration::from_secs(20 * 60);
/// How long a folder's direnv may take (a flake's first build).
const ENV_WAIT: Duration = Duration::from_secs(10 * 60);
/// The id of the request that turns Remote Control on.
const REMOTE_ON: &str = "anna-remote-on";
/// What is kept of `claude`'s errors, for the tab.
const STDERR_KEPT: usize = 2_000;

/// The pids of the `claude` anna runs, for sessions.rs.
static OURS: LazyLock<Mutex<HashSet<u32>>> = LazyLock::new(Default::default);
/// What each driven session asks the user, oldest first, for sessions.rs;
/// a session asking nothing has no entry.
static ASKS: LazyLock<Mutex<HashMap<String, Vec<Ask>>>> = LazyLock::new(Default::default);
/// The models `claude` offers, from the last `initialize`.
static MODELS: LazyLock<Mutex<Option<Value>>> = LazyLock::new(Default::default);

pub fn is_ours(pid: u32) -> bool {
    OURS.lock().unwrap().contains(&pid)
}

/// What driven session `id` asks the user (permissions, questions).
pub fn asks(id: &str) -> Vec<Ask> {
    ASKS.lock().unwrap().get(id).cloned().unwrap_or_default()
}

/// How to start a `claude`: the model, effort and permission mode chosen in
/// the tab before the first message (`None`: Claude Code's settings).
#[derive(Default, Clone, Debug)]
pub struct Launch {
    pub model: Option<String>,
    pub effort: Option<String>,
    pub mode: Option<String>,
}

/// A request waiting for the user, as the tab shows it: a tool to allow
/// (`actions`), or Claude's questions (`fields`, one choice each).
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Ask {
    pub id: String,
    pub tool: String,
    pub title: String,
    pub text: String,
    pub detail: String,
    pub fields: Vec<Field>,
    pub actions: Vec<Action>,
}

type Answer = (String, HashMap<String, String>);

/// What the tab shows of a driven session, beside its conversation.
#[derive(Serialize, Clone, Default, Debug)]
pub struct State {
    pub driven: bool,
    /// A turn is under way.
    pub busy: bool,
    pub model: String,
    /// The effort asked for, "" for Claude Code's default.
    pub effort: String,
    pub mode: String,
    /// Dollars, as `claude` counts them for this run.
    pub cost: f64,
    /// The context window (tokens), once a turn has reported it.
    pub window: u64,
    /// What the context holds, by category (`get_context_usage`), after
    /// each turn; `null` before.
    pub context: Value,
    /// The tool waiting for the user's answer, "" if none.
    pub asking: String,
    /// The requests waiting for the user, oldest first.
    pub asks: Vec<Ask>,
    /// The last error: `claude` failing to start, or ending badly.
    pub error: String,
    /// The MCP servers: `[{name, status}]`.
    pub mcp: Value,
    /// The folder's direnv: "" (none), `loaded`, `blocked` (its `.envrc` is
    /// not allowed) or `failed`.
    pub env: String,
    /// Remote Control: "" (off), `connecting`, or the last `bridge_state`
    /// (`ready`, `connected`, `reconnecting`, `failed`…).
    pub remote: String,
    /// The session's page on claude.ai, while Remote Control is on.
    pub remote_url: String,
    /// Why Remote Control failed.
    pub remote_error: String,
}

impl State {
    /// Remote Control holds the session: someone may write from afar.
    fn remote_on(&self) -> bool {
        !self.remote.is_empty() && self.remote != "failed"
    }
}

struct Driver {
    id: String,
    pid: u32,
    stdin: tokio::sync::Mutex<ChildStdin>,
    child: tokio::sync::Mutex<Child>,
    tx: broadcast::Sender<String>,
    state: Mutex<State>,
    /// The text being written: its kind (`text`, `thinking`) and so far.
    partial: Mutex<(String, String)>,
    last: Mutex<Instant>,
    requests: AtomicU64,
    /// Where the answer to each waiting request goes.
    answers: Mutex<HashMap<String, oneshot::Sender<Answer>>>,
}

impl Driver {
    fn state(&self) -> State {
        self.state.lock().unwrap().clone()
    }

    fn state_line(&self) -> String {
        json!({ "chat_state": self.state() }).to_string()
    }

    fn change(&self, f: impl FnOnce(&mut State)) {
        f(&mut self.state.lock().unwrap());
        let _ = self.tx.send(self.state_line());
    }

    fn partial_line(&self) -> String {
        let (kind, text) = self.partial.lock().unwrap().clone();
        json!({ "chat_partial": { "kind": kind, "text": text } }).to_string()
    }

    async fn write(&self, msg: &Value) -> Result<(), String> {
        let mut line = msg.to_string();
        line.push('\n');
        let mut stdin = self.stdin.lock().await;
        stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| e.to_string())?;
        stdin.flush().await.map_err(|e| e.to_string())
    }

    async fn control(&self, request: Value) -> Result<(), String> {
        let n = self.requests.fetch_add(1, Ordering::Relaxed);
        self.control_as(&format!("anna-{n}"), request).await
    }

    async fn control_as(&self, request_id: &str, request: Value) -> Result<(), String> {
        self.write(&json!({
            "type": "control_request",
            "request_id": request_id,
            "request": request,
        }))
        .await
    }

    /// Turn Remote Control on or off.
    async fn set_remote(&self, on: bool) -> Result<(), String> {
        self.change(|s| {
            s.remote = if on { "connecting" } else { "" }.into();
            s.remote_url.clear();
            s.remote_error.clear();
        });
        let request = json!({ "subtype": "remote_control", "enabled": on });
        if on {
            self.control_as(REMOTE_ON, request).await
        } else {
            // Idle from now, not from the last turn.
            *self.last.lock().unwrap() = Instant::now();
            self.control(request).await
        }
    }
}

pub struct Drive {
    drivers: Mutex<HashMap<String, Arc<Driver>>>,
    /// The sessions being started (their direnv loading): never twice.
    starting: Mutex<HashSet<String>>,
}

/// A session being started, until dropped.
struct Starting<'a>(&'a Drive, String);

impl Drop for Starting<'_> {
    fn drop(&mut self) {
        self.0.starting.lock().unwrap().remove(&self.1);
    }
}

/// What direnv changes in folder `cwd` (`null`: unset), and how it went
/// (`State::env`). Without direnv or `.envrc`, nothing.
async fn folder_env(cwd: &str) -> (HashMap<String, Option<String>>, &'static str) {
    let run = tokio::process::Command::new("direnv")
        .args(["export", "json"])
        .current_dir(cwd)
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(ENV_WAIT, run).await {
        Ok(Ok(out)) => read_env(
            out.status.success(),
            &out.stdout,
            &String::from_utf8_lossy(&out.stderr),
        ),
        // No direnv here.
        Ok(Err(_)) => (HashMap::new(), ""),
        Err(_) => (HashMap::new(), "failed"),
    }
}

fn read_env(
    ok: bool,
    stdout: &[u8],
    stderr: &str,
) -> (HashMap<String, Option<String>>, &'static str) {
    if !ok {
        let why = if stderr.contains("is blocked") {
            "blocked"
        } else {
            "failed"
        };
        return (HashMap::new(), why);
    }
    if stdout.trim_ascii().is_empty() {
        return (HashMap::new(), "");
    }
    match serde_json::from_slice(stdout) {
        Ok(vars) => (vars, "loaded"),
        Err(_) => (HashMap::new(), "failed"),
    }
}

impl Drive {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            drivers: Mutex::new(HashMap::new()),
            starting: Mutex::new(HashSet::new()),
        })
    }

    fn get(&self, id: &str) -> Option<Arc<Driver>> {
        self.drivers.lock().unwrap().get(id).cloned()
    }

    /// The state of session `id` (not driven: all false), as a line.
    pub fn state_line(&self, id: &str) -> String {
        match self.get(id) {
            Some(d) => d.state_line(),
            None => json!({ "chat_state": State::default() }).to_string(),
        }
    }

    /// Send `text` to session `id`, starting a `claude` on it if none runs
    /// here; without `id`, start a new session in `cwd`. The session's id.
    pub async fn send(
        self: &Arc<Self>,
        id: Option<String>,
        cwd: Option<String>,
        text: String,
        files: Vec<String>,
        launch: Launch,
    ) -> Result<String, String> {
        let text = text.trim().to_string();
        if text.is_empty() && files.is_empty() {
            return Err(i18n::tr("claude.empty_request"));
        }
        // Read before anything starts: a file that is gone refuses the send.
        let content = tokio::task::spawn_blocking(move || content(&text, &files))
            .await
            .map_err(|e| e.to_string())??;
        let driver = match id.as_deref().and_then(|i| self.get(i)) {
            Some(d) => d,
            None => self.start(id, cwd, launch).await?,
        };
        *driver.last.lock().unwrap() = Instant::now();
        driver.change(|s| {
            s.busy = true;
            s.error.clear();
        });
        driver
            .write(&json!({
                "type": "user",
                "message": { "role": "user", "content": content },
                "parent_tool_use_id": null,
                "session_id": driver.id,
            }))
            .await?;
        Ok(driver.id.clone())
    }

    async fn start(
        self: &Arc<Self>,
        id: Option<String>,
        cwd: Option<String>,
        launch: Launch,
    ) -> Result<Arc<Driver>, String> {
        let (id, cwd, resume) = match id {
            Some(id) => {
                let cwd = tokio::task::spawn_blocking({
                    let id = id.clone();
                    move || super::sessions::cwd_of(&id)
                })
                .await
                .ok()
                .flatten()
                .or(cwd)
                .ok_or_else(|| i18n::tr("claude.unknown_session"))?;
                (id, cwd, true)
            }
            None => (
                new_uuid(),
                cwd.ok_or_else(|| i18n::tr("claude.no_folder"))?,
                false,
            ),
        };
        if !self.starting.lock().unwrap().insert(id.clone()) {
            return Err(i18n::tr("claude.starting"));
        }
        let _starting = Starting(self, id.clone());
        // Started by another request just before this one.
        if let Some(d) = self.get(&id) {
            return Ok(d);
        }
        // Refused before its direnv is loaded, and looked up again after.
        self.free(&id, resume).await?;
        let (vars, env) = folder_env(&cwd).await;
        self.free(&id, resume).await?;

        let mut cmd = tokio::process::Command::new("claude");
        cmd.args([
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompts",
            "host",
            "--permission-prompt-tool",
            "stdio",
        ])
        .args([if resume { "--resume" } else { "--session-id" }, &id]);
        let flag = |v: &Option<String>| v.as_deref().filter(|v| valid_word(v)).map(str::to_string);
        if let Some(m) = flag(&launch.model) {
            cmd.args(["--model", &m]);
        }
        if let Some(e) = flag(&launch.effort) {
            cmd.args(["--effort", &e]);
        }
        if let Some(m) = flag(&launch.mode) {
            cmd.args(["--permission-mode", &m]);
        }
        for (k, v) in &vars {
            match v {
                Some(v) => cmd.env(k, v),
                None => cmd.env_remove(k),
            };
        }
        cmd.current_dir(&cwd)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        let mut child = cmd
            .spawn()
            .map_err(|e| i18n::tr_args("claude.start_failed", &[("error", &e.to_string())]))?;
        let pid = child.id().unwrap_or(0);
        let stdin = child.stdin.take().ok_or("stdin")?;
        let stdout = child.stdout.take().ok_or("stdout")?;
        let stderr = child.stderr.take().ok_or("stderr")?;
        OURS.lock().unwrap().insert(pid);

        let driver = Arc::new(Driver {
            id: id.clone(),
            pid,
            stdin: tokio::sync::Mutex::new(stdin),
            child: tokio::sync::Mutex::new(child),
            tx: broadcast::channel(256).0,
            state: Mutex::new(State {
                driven: true,
                effort: launch.effort.clone().unwrap_or_default(),
                mcp: Value::Array(Vec::new()),
                env: env.into(),
                ..Default::default()
            }),
            partial: Mutex::new(Default::default()),
            last: Mutex::new(Instant::now()),
            requests: AtomicU64::new(0),
            answers: Mutex::new(HashMap::new()),
        });
        self.drivers
            .lock()
            .unwrap()
            .insert(id.clone(), Arc::clone(&driver));

        let errors = Arc::new(Mutex::new(String::new()));
        tokio::spawn({
            let errors = Arc::clone(&errors);
            async move {
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(l)) = lines.next_line().await {
                    let mut e = errors.lock().unwrap();
                    e.push_str(&l);
                    e.push('\n');
                    if e.len() > STDERR_KEPT {
                        let from = e.len() - STDERR_KEPT;
                        let from = (from..e.len())
                            .find(|i| e.is_char_boundary(*i))
                            .unwrap_or(0);
                        *e = e[from..].to_string();
                    }
                }
            }
        });
        tokio::spawn(Arc::clone(self).read(Arc::clone(&driver), stdout, errors));
        tokio::spawn(Arc::clone(self).reap_idle(Arc::clone(&driver)));

        driver.control(json!({ "subtype": "initialize" })).await?;
        Ok(driver)
    }

    /// Refuse a session to resume that another `claude` (a terminal) holds.
    async fn free(&self, id: &str, resume: bool) -> Result<(), String> {
        if !resume {
            return Ok(());
        }
        let id = id.to_string();
        let other = tokio::task::spawn_blocking(move || super::sessions::running(&id))
            .await
            .ok()
            .flatten();
        match other {
            Some(p) if !is_ours(p) => Err("open_elsewhere".into()),
            _ => Ok(()),
        }
    }

    /// Everything `claude` says, until it ends.
    async fn read(
        self: Arc<Self>,
        driver: Arc<Driver>,
        stdout: tokio::process::ChildStdout,
        errors: Arc<Mutex<String>>,
    ) {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(msg) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            self.handle(&driver, msg).await;
        }
        // Ended: by itself, killed, or failed to start.
        let status = driver.child.lock().await.wait().await.ok();
        OURS.lock().unwrap().remove(&driver.pid);
        self.drivers.lock().unwrap().remove(&driver.id);
        let failed = status.is_some_and(|s| !s.success() && s.code().is_some());
        let error = errors.lock().unwrap().trim().to_string();
        // Its requests go with it.
        driver.answers.lock().unwrap().clear();
        ASKS.lock().unwrap().remove(&driver.id);
        driver.change(|s| {
            s.driven = false;
            s.busy = false;
            s.asking.clear();
            s.asks.clear();
            s.remote.clear();
            s.remote_url.clear();
            if failed && !error.is_empty() {
                s.error = error.lines().last().unwrap_or_default().to_string();
            }
        });
    }

    async fn handle(self: &Arc<Self>, driver: &Arc<Driver>, msg: Value) {
        let kind = msg.get("type").and_then(Value::as_str).unwrap_or_default();
        match kind {
            "system" if msg.get("subtype").and_then(Value::as_str) == Some("init") => {
                driver.change(|s| {
                    s.model = str_of(&msg, "model");
                    s.mode = str_of(&msg, "permissionMode");
                    s.mcp = msg
                        .get("mcp_servers")
                        .cloned()
                        .unwrap_or(Value::Array(Vec::new()));
                });
            }
            "system" if msg.get("subtype").and_then(Value::as_str) == Some("bridge_state") => {
                driver.change(|s| {
                    // Turned off here: what was still on its way.
                    if s.remote.is_empty() {
                        return;
                    }
                    s.remote = str_of(&msg, "state");
                    s.remote_error = if s.remote == "failed" {
                        str_of(&msg, "detail")
                    } else {
                        String::new()
                    };
                });
            }
            "control_cancel_request" => {
                // Answered from afar, or the turn was interrupted: the card
                // goes (permit's receiver ends).
                driver
                    .answers
                    .lock()
                    .unwrap()
                    .remove(&str_of(&msg, "request_id"));
            }
            "stream_event" => {
                // A turn may start without us: written from afar.
                let own = msg.get("parent_tool_use_id").is_none_or(Value::is_null);
                if own
                    && msg.pointer("/event/type").and_then(Value::as_str) == Some("message_start")
                    && !driver.state().busy
                {
                    driver.change(|s| s.busy = true);
                }
                let Some(event) = msg.get("event") else {
                    return;
                };
                match event.get("type").and_then(Value::as_str) {
                    Some("content_block_start") => {
                        let block =
                            str_of(event.get("content_block").unwrap_or(&Value::Null), "type");
                        *driver.partial.lock().unwrap() = (block, String::new());
                    }
                    Some("content_block_delta") => {
                        let delta = event.get("delta").unwrap_or(&Value::Null);
                        let piece = delta
                            .get("text")
                            .or_else(|| delta.get("thinking"))
                            .and_then(Value::as_str)
                            .unwrap_or_default();
                        if piece.is_empty() {
                            return;
                        }
                        driver.partial.lock().unwrap().1.push_str(piece);
                        let _ = driver.tx.send(driver.partial_line());
                    }
                    _ => {}
                }
            }
            "assistant" => {
                // The block is whole: the transcript has it.
                *driver.partial.lock().unwrap() = Default::default();
                let _ = driver.tx.send(driver.partial_line());
            }
            "result" => {
                *driver.partial.lock().unwrap() = Default::default();
                *driver.last.lock().unwrap() = Instant::now();
                let _ = driver.tx.send(driver.partial_line());
                let error = msg.get("is_error").and_then(Value::as_bool) == Some(true)
                    && str_of(&msg, "subtype") == "success";
                driver.change(|s| {
                    s.busy = false;
                    if let Some(c) = msg.get("total_cost_usd").and_then(Value::as_f64) {
                        s.cost = c;
                    }
                    // The model's window, as `claude` knows it.
                    if let Some(w) = msg
                        .get("modelUsage")
                        .and_then(Value::as_object)
                        .and_then(|m| m.values().find_map(|u| u.get("contextWindow")?.as_u64()))
                    {
                        s.window = w;
                    }
                    if error {
                        s.error = str_of(&msg, "result");
                    }
                });
                // What the context now holds, by category.
                let _ = driver
                    .control(json!({ "subtype": "get_context_usage" }))
                    .await;
            }
            "control_response" => {
                let r = msg.pointer("/response/response").unwrap_or(&Value::Null);
                if msg.pointer("/response/request_id").and_then(Value::as_str) == Some(REMOTE_ON) {
                    let error = msg.pointer("/response/error").and_then(Value::as_str);
                    driver.change(|s| {
                        if s.remote.is_empty() {
                            return;
                        }
                        match error {
                            Some(e) => {
                                s.remote = "failed".into();
                                s.remote_error = e.to_string();
                            }
                            None => s.remote_url = str_of(r, "session_url"),
                        }
                    });
                }
                // The user's own setting, as in a terminal.
                if r.get("remote_control_auto_enable").and_then(Value::as_bool) == Some(true) {
                    let _ = driver.set_remote(true).await;
                }
                if let Some(mode) = r.get("mode").and_then(Value::as_str) {
                    driver.change(|s| s.mode = mode.to_string());
                }
                if let Some(model) = r.get("model").and_then(Value::as_str) {
                    driver.change(|s| s.model = model.to_string());
                }
                if let Some(models) = r.get("models").filter(|m| m.is_array()) {
                    *MODELS.lock().unwrap() = Some(models.clone());
                }
                if r.get("categories").is_some() {
                    driver.change(|s| s.context = r.clone());
                }
            }
            "control_request" => {
                let request_id = str_of(&msg, "request_id");
                let request = msg.get("request").cloned().unwrap_or(Value::Null);
                if str_of(&request, "subtype") == "can_use_tool" {
                    // Its own task: the card may wait minutes, and `claude`
                    // keeps talking meanwhile.
                    let this = Arc::clone(self);
                    let driver = Arc::clone(driver);
                    tokio::spawn(async move { this.permit(&driver, request_id, request).await });
                } else {
                    let _ = driver
                        .write(&json!({
                            "type": "control_response",
                            "response": {
                                "subtype": "error",
                                "request_id": request_id,
                                "error": "unsupported",
                            },
                        }))
                        .await;
                }
            }
            _ => {}
        }
    }

    /// Ask the user whether `claude` may use a tool (or what they answer
    /// its question), then tell it.
    async fn permit(&self, driver: &Driver, request_id: String, request: Value) {
        let tool = str_of(&request, "tool_name");
        let spec = spec("", &request);
        let ask = Ask {
            id: request_id.clone(),
            tool: tool.clone(),
            title: spec.title,
            text: spec.text,
            detail: spec.detail,
            fields: spec.fields,
            actions: spec.actions,
        };
        let (tx, rx) = oneshot::channel();
        driver
            .answers
            .lock()
            .unwrap()
            .insert(request_id.clone(), tx);
        ASKS.lock()
            .unwrap()
            .entry(driver.id.clone())
            .or_default()
            .push(ask.clone());
        driver.change(|s| {
            s.asks.push(ask);
            s.asking = tool.clone();
        });
        // Until the tab answers, or `claude` goes.
        let answer = rx.await;
        driver.answers.lock().unwrap().remove(&request_id);
        {
            let mut asks = ASKS.lock().unwrap();
            if let Some(list) = asks.get_mut(&driver.id) {
                list.retain(|a| a.id != request_id);
                if list.is_empty() {
                    asks.remove(&driver.id);
                }
            }
        }
        driver.change(|s| {
            s.asks.retain(|a| a.id != request_id);
            s.asking = s.asks.first().map(|a| a.tool.clone()).unwrap_or_default();
        });
        // Withdrawn, or `claude` is gone: nobody waits for an answer.
        let Ok((action, values)) = answer else {
            return;
        };
        let response = decide(&request, &action, &values);
        let _ = driver
            .write(&json!({
                "type": "control_response",
                "response": {
                    "subtype": "success",
                    "request_id": request_id,
                    "response": response,
                },
            }))
            .await;
    }

    /// Stop a driver nobody uses any more; the conversation stays, to be
    /// resumed.
    async fn reap_idle(self: Arc<Self>, driver: Arc<Driver>) {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            if self
                .get(&driver.id)
                .is_none_or(|d| !Arc::ptr_eq(&d, &driver))
            {
                return;
            }
            let s = driver.state();
            if !s.busy
                && s.asks.is_empty()
                && !s.remote_on()
                && driver.tx.receiver_count() == 0
                && driver.last.lock().unwrap().elapsed() > IDLE
            {
                let _ = driver.child.lock().await.start_kill();
                return;
            }
        }
    }

    pub async fn interrupt(&self, id: &str) -> Result<(), String> {
        let d = self.get(id).ok_or_else(|| i18n::tr("claude.not_driven"))?;
        d.control(json!({ "subtype": "interrupt" })).await
    }

    /// Answer request `ask` of driven session `id`: the button pressed
    /// (`allow`, `always`, `deny`, `answer`) and the choices made.
    pub fn answer(
        &self,
        id: &str,
        ask: &str,
        action: String,
        values: HashMap<String, String>,
    ) -> Result<(), String> {
        let d = self.get(id).ok_or_else(|| i18n::tr("claude.not_driven"))?;
        let tx = d.answers.lock().unwrap().remove(ask);
        match tx {
            Some(tx) => tx.send((action, values)).map_err(|_| "gone".to_string()),
            None => Err("gone".into()),
        }
    }

    /// Change the model, effort or permission mode of a driven session.
    pub async fn set(
        &self,
        id: &str,
        model: Option<String>,
        effort: Option<String>,
        mode: Option<String>,
        remote: Option<bool>,
    ) -> Result<(), String> {
        let d = self.get(id).ok_or_else(|| i18n::tr("claude.not_driven"))?;
        if let Some(model) = model {
            d.control(json!({ "subtype": "set_model", "model": model }))
                .await?;
            d.change(|s| s.model = model);
        }
        if let Some(effort) = effort {
            d.control(json!({
                "subtype": "apply_flag_settings",
                "settings": { "effortLevel": effort },
            }))
            .await?;
            d.change(|s| s.effort = effort);
        }
        if let Some(mode) = mode {
            d.control(json!({ "subtype": "set_permission_mode", "mode": mode }))
                .await?;
        }
        if let Some(on) = remote {
            d.set_remote(on).await?;
        }
        Ok(())
    }

    /// The models `claude` offers (`initialize`'s `models`), asked of a
    /// `claude` started for that alone the first time — it calls no model —
    /// then kept; and Claude Code's defaults (its settings): what the tab
    /// offers under the prompt before a session is driven.
    pub async fn models(&self) -> Value {
        let cached = MODELS.lock().unwrap().clone();
        let models = match cached {
            Some(m) => m,
            None => {
                // The same `claude` tells what is left of the plan: kept.
                let (m, u) = probe().await;
                if let Some(u) = u {
                    *USAGE.lock().unwrap() = Some((Instant::now(), u));
                }
                let m = m.unwrap_or(Value::Array(Vec::new()));
                if m.as_array().is_some_and(|a| !a.is_empty()) {
                    *MODELS.lock().unwrap() = Some(m.clone());
                }
                m
            }
        };
        let settings: Value =
            std::fs::read_to_string(crate::paths::home_dir().join(".claude/settings.json"))
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
                .unwrap_or(Value::Null);
        json!({
            "models": models,
            "defaults": {
                "model": str_of(&settings, "model"),
                "effort": str_of(&settings, "effortLevel"),
                "mode": settings.pointer("/permissions/defaultMode").and_then(Value::as_str).unwrap_or("default"),
            },
        })
    }

    pub async fn stop(&self, id: &str) -> Result<(), String> {
        let d = self.get(id).ok_or_else(|| i18n::tr("claude.not_driven"))?;
        let killed = d.child.lock().await.start_kill();
        killed.map_err(|e| e.to_string())
    }

    /// End the `claude` that holds session `id` elsewhere (a terminal), so
    /// that anna can drive it. Refused while it works, unless `force`.
    pub async fn take_over(&self, id: &str, force: bool) -> Result<(), String> {
        let id = id.to_string();
        tokio::task::spawn_blocking(move || {
            let Some(pid) = super::sessions::running(&id).filter(|p| !is_ours(*p)) else {
                return Ok(());
            };
            let busy = super::sessions::sample()
                .live
                .iter()
                .any(|s| s.id == id && s.state == "busy");
            if busy && !force {
                return Err("busy".to_string());
            }
            let _ = std::process::Command::new("kill")
                .args(["-TERM", &pid.to_string()])
                .status();
            for _ in 0..50 {
                if !super::sessions::alive(pid) {
                    return Ok(());
                }
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(i18n::tr("claude.still_running"))
        })
        .await
        .map_err(|e| e.to_string())?
    }

    /// Follow session `id` (or its subagent `agent`) for the tab: a page of
    /// its conversation, then what is added to it, its summary (context,
    /// changes, outputs, jobs) whenever it changes, the text being written
    /// and the state, until the tab closes the connection.
    pub async fn watch(
        self: &Arc<Self>,
        id: String,
        agent: Option<String>,
        w: &mut tokio::net::unix::OwnedWriteHalf,
    ) {
        use super::transcript::{conversation, page, Feed, Tail};
        let mut tail: Option<Tail> = None;
        let mut rx: Option<broadcast::Receiver<String>> = None;
        let mut elsewhere: Option<u32> = None;
        let mut summary = String::new();
        let mut tick = tokio::time::interval(Duration::from_millis(300));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut n: u64 = 0;
        loop {
            // The transcript: a first page, then its new lines. A new
            // session has none until its first message.
            let mut out: Vec<String> = Vec::new();
            let mut grew = false;
            if tail.is_none() {
                let found = tokio::task::spawn_blocking({
                    let id = id.clone();
                    let agent = agent.clone();
                    move || {
                        conversation(&id, agent.as_deref()).map(|p| {
                            let (pg, feed) = page(&p, None, 150);
                            (p, pg, feed)
                        })
                    }
                })
                .await
                .ok()
                .flatten();
                match found {
                    Some((path, pg, feed)) => {
                        let line = pg.total;
                        out.push(json!({ "chat": pg }).to_string());
                        tail = Some(Tail::new(path, line, feed));
                        grew = true;
                    }
                    None if n == 0 => out.push(
                        json!({ "chat": { "items": [], "first": 0, "total": 0 } }).to_string(),
                    ),
                    None => {}
                }
            } else if let Some(t) = tail.take() {
                let (t, items) = tokio::task::spawn_blocking(move || {
                    let mut t = t;
                    let items = t.read();
                    (t, items)
                })
                .await
                .unwrap_or_else(|_| {
                    (
                        Tail::new(Default::default(), 0, Feed::default()),
                        Vec::new(),
                    )
                });
                tail = Some(t);
                if !items.is_empty() {
                    out.push(json!({ "chat_upsert": items }).to_string());
                    grew = true;
                }
            }

            // The summary: when the transcript grew, and every 1.5 s for
            // what changes beside it (subagents starting, files created).
            if let Some(path) = tail.as_ref().map(|t| t.path().to_path_buf()) {
                if grew || n.is_multiple_of(5) {
                    let sum = tokio::task::spawn_blocking(move || super::summary::summary(&path))
                        .await
                        .ok();
                    if let Some(sum) = sum {
                        let line = json!({ "chat_summary": sum }).to_string();
                        if line != summary {
                            summary = line.clone();
                            out.push(line);
                        }
                    }
                }
            }

            // The driver: followed while there is one (a subagent has none).
            if rx.is_none() && agent.is_none() {
                if let Some(d) = self.get(&id) {
                    rx = Some(d.tx.subscribe());
                    out.push(d.state_line());
                    out.push(d.partial_line());
                } else if n == 0 {
                    out.push(self.state_line(&id));
                }
            }

            // The models to choose from, once the first page is shown (the
            // first time, a `claude` is asked: a second or two).
            if n == 1 && agent.is_none() {
                out.push(json!({ "chat_models": self.models().await }).to_string());
            }

            // Held by another `claude` (a terminal)? Looked up every 1.5 s.
            if n.is_multiple_of(5) && agent.is_none() {
                let id2 = id.clone();
                let now = tokio::task::spawn_blocking(move || {
                    super::sessions::running(&id2).filter(|p| !is_ours(*p))
                })
                .await
                .ok()
                .flatten();
                if now != elsewhere || n == 0 {
                    elsewhere = now;
                    out.push(json!({ "chat_elsewhere": elsewhere.unwrap_or(0) }).to_string());
                }
            }
            n += 1;

            for line in out {
                if write(w, &line).await.is_err() {
                    return;
                }
            }

            // Until the next tick, pass on what the driver says.
            let sleep = tick.tick();
            tokio::pin!(sleep);
            loop {
                let Some(r) = rx.as_mut() else {
                    sleep.as_mut().await;
                    break;
                };
                tokio::select! {
                    _ = &mut sleep => break,
                    msg = r.recv() => match msg {
                        Ok(line) => {
                            if write(w, &line).await.is_err() {
                                return;
                            }
                        }
                        Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => {
                            rx = None;
                            if write(w, &self.state_line(&id)).await.is_err() {
                                return;
                            }
                        }
                    }
                }
            }
        }
    }
}

async fn write(w: &mut tokio::net::unix::OwnedWriteHalf, line: &str) -> std::io::Result<()> {
    w.write_all(line.as_bytes()).await?;
    w.write_all(b"\n").await
}

/// The largest image sent as such (the API takes 5 MB of base64).
const IMAGE_MAX: u64 = 3_700_000;

/// The type of an image the API takes, from its first bytes (an extension
/// may lie, and a wrong type refuses the whole request).
fn image_type(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(b"\xff\xd8\xff") {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF8") {
        Some("image/gif")
    } else if bytes.len() > 12 && bytes.starts_with(b"RIFF") && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

/// A request's content: its text alone, or with the files joined to it —
/// images as such, and every file by its path, for Claude to read or edit
/// with its own tools (which ask for the permission they need).
fn content(text: &str, files: &[String]) -> Result<Value, String> {
    use base64::Engine;
    use std::io::Read;
    if files.is_empty() {
        return Ok(json!(text));
    }
    let mut blocks = Vec::new();
    let mut lines = Vec::new();
    for f in files {
        let path = std::path::Path::new(f);
        let missing = || i18n::tr_args("claude.no_file", &[("path", f)]);
        let meta = std::fs::metadata(path).map_err(|_| missing())?;
        // Never a pipe or a device: reading one could wait forever.
        if !path.is_absolute() || !(meta.is_file() || meta.is_dir()) {
            return Err(missing());
        }
        if meta.is_file() && meta.len() <= IMAGE_MAX {
            let mut file = std::fs::File::open(path).map_err(|_| missing())?;
            let mut bytes = Vec::new();
            let _ = file.by_ref().take(16).read_to_end(&mut bytes);
            if let Some(media) = image_type(&bytes) {
                file.take(IMAGE_MAX)
                    .read_to_end(&mut bytes)
                    .map_err(|e| e.to_string())?;
                blocks.push(json!({
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": media,
                        "data": base64::engine::general_purpose::STANDARD.encode(&bytes),
                    },
                }));
            }
        }
        lines.push(i18n::tr_args("claude.joined", &[("path", f)]));
    }
    let joined = lines.join("\n");
    let text = if text.is_empty() {
        joined
    } else {
        format!("{text}\n\n{joined}")
    };
    blocks.push(json!({ "type": "text", "text": text }));
    Ok(Value::Array(blocks))
}

/// A model, effort or mode name as `claude` takes it on its command line:
/// letters, digits, `-`, `_`, `.`, `[`, `]` (`claude-opus-5-5[1m]`).
fn valid_word(v: &str) -> bool {
    !v.is_empty()
        && v.len() < 80
        && v.chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_.[]".contains(c))
}

/// Ask a `claude` started for that alone which models it offers and what is
/// left of the plan (`get_usage`): it is initialized, answers both, and is
/// stopped — no model is called.
async fn probe() -> (Option<Value>, Option<Value>) {
    let (init, usage) = probe_inner(&crate::paths::home_dir(), true)
        .await
        .unwrap_or((None, None));
    let models = init
        .and_then(|i| i.get("models").cloned())
        .filter(|m| m.is_array());
    (models, usage)
}

/// What `initialize` answers in folder `cwd`, and the plan's usage if asked.
async fn probe_inner(
    cwd: &std::path::Path,
    with_usage: bool,
) -> Option<(Option<Value>, Option<Value>)> {
    let mut child = tokio::process::Command::new("claude")
        .args([
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--no-session-persistence",
        ])
        .current_dir(cwd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let mut stdin = child.stdin.take()?;
    let stdout = child.stdout.take()?;
    let ask = |id: &str, subtype: &str| {
        format!(
            "{}\n",
            json!({ "type": "control_request", "request_id": id, "request": { "subtype": subtype } })
        )
    };
    stdin
        .write_all(ask("models", "initialize").as_bytes())
        .await
        .ok()?;
    if with_usage {
        stdin
            .write_all(ask("usage", "get_usage").as_bytes())
            .await
            .ok()?;
    }
    let read = async {
        let (mut init, mut usage) = (None, None);
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if v.get("type").and_then(Value::as_str) != Some("control_response") {
                continue;
            }
            let body = v.pointer("/response/response").cloned();
            match v.pointer("/response/request_id").and_then(Value::as_str) {
                Some("models") => init = Some(body.unwrap_or(Value::Null)),
                Some("usage") => usage = Some(body.unwrap_or(Value::Null)),
                _ => {}
            }
            if init.is_some() && (usage.is_some() || !with_usage) {
                break;
            }
        }
        (
            init.filter(|i| i.is_object()),
            usage.filter(|u| u.is_object()),
        )
    };
    let found = tokio::time::timeout(Duration::from_secs(20), read)
        .await
        .unwrap_or((None, None));
    // Its input closed, it ends by itself and removes its
    // `sessions/<pid>.json`; killed, it would leave it behind.
    drop(stdin);
    tokio::spawn(async move {
        if tokio::time::timeout(Duration::from_secs(5), child.wait())
            .await
            .is_err()
        {
            let _ = child.start_kill();
        }
    });
    Some(found)
}

/// The slash commands of each folder, and when they were asked.
static COMMANDS: LazyLock<Mutex<HashMap<String, (Instant, Value)>>> =
    LazyLock::new(Default::default);
const COMMANDS_EVERY: Duration = Duration::from_secs(10 * 60);

/// The slash commands Claude Code has in folder `cwd` (its own, the skills,
/// the project's): `[{name, description, argumentHint, aliases}]`, as
/// `initialize` gives them. Asked again after ten minutes; `[]` if `claude`
/// does not say.
pub async fn commands(cwd: &str) -> Value {
    let known = COMMANDS.lock().unwrap().get(cwd).cloned();
    if let Some((at, c)) = &known {
        if at.elapsed() < COMMANDS_EVERY {
            return c.clone();
        }
    }
    let found = match probe_inner(std::path::Path::new(cwd), false).await {
        Some((Some(init), _)) => init.get("commands").map(offered),
        _ => None,
    };
    match found {
        Some(c) => {
            COMMANDS
                .lock()
                .unwrap()
                .insert(cwd.to_string(), (Instant::now(), c.clone()));
            c
        }
        None => known.map(|(_, c)| c).unwrap_or(json!([])),
    }
}

/// The commands worth offering: not the internal, removed or renamed ones;
/// their descriptions cut short.
fn offered(commands: &Value) -> Value {
    commands
        .as_array()
        .map(|list| {
            list.iter()
                .filter(|c| {
                    let (name, about) = (str_of(c, "name"), str_of(c, "description"));
                    !name.is_empty()
                        && !name.starts_with("__")
                        && name != "workflow-launch-exec"
                        && !about.starts_with("(removed)")
                        && !about.starts_with("Renamed to")
                })
                .map(|c| {
                    json!({
                        "name": str_of(c, "name"),
                        "description": str_of(c, "description").chars().take(160).collect::<String>(),
                        "argumentHint": str_of(c, "argumentHint"),
                        "aliases": c.get("aliases").cloned().unwrap_or(json!([])),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default()
        .into()
}

/// What is left of the plan, and when it was asked (kept a minute).
static USAGE: LazyLock<Mutex<Option<(Instant, Value)>>> = LazyLock::new(Default::default);
const USAGE_EVERY: Duration = Duration::from_secs(60);

/// The plan's usage, as `claude` reports it (`get_usage`): the subscription,
/// and each window's `utilization` (percent) and `resets_at`
/// (`rate_limits.five_hour`, `seven_day`, per model…). Asked at most once a
/// minute.
pub async fn usage() -> Value {
    if let Some((at, u)) = USAGE.lock().unwrap().clone() {
        if at.elapsed() < USAGE_EVERY {
            return u;
        }
    }
    let (models, usage) = probe().await;
    if let Some(m) = models.filter(|m| m.as_array().is_some_and(|a| !a.is_empty())) {
        *MODELS.lock().unwrap() = Some(m);
    }
    match usage {
        Some(u) => {
            *USAGE.lock().unwrap() = Some((Instant::now(), u.clone()));
            u
        }
        // `claude` didn't say: what was known, if anything.
        None => USAGE
            .lock()
            .unwrap()
            .clone()
            .map(|(_, u)| u)
            .unwrap_or(Value::Null),
    }
}

fn str_of(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

/// A random version-4 UUID, for a new session's id.
fn new_uuid() -> String {
    use std::io::Read;
    let mut b = [0u8; 16];
    if std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut b))
        .is_err()
    {
        let t = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        b = t.to_le_bytes();
    }
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

// ── The permission cards ────────────────────────────────────────────────────

fn action(id: &str, label: String, primary: bool, danger: bool) -> Action {
    Action {
        id: id.into(),
        label,
        primary,
        danger,
    }
}

/// The card for a `can_use_tool` request.
fn spec(project: &str, request: &Value) -> Spec {
    let tool = str_of(request, "tool_name");
    let input = request.get("input").cloned().unwrap_or(Value::Null);
    if tool == "AskUserQuestion" {
        let questions = input
            .get("questions")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let fields = questions
            .iter()
            .enumerate()
            .map(|(i, q)| {
                let options: Vec<Choice> = q
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .map(|o| Choice {
                                id: str_of(o, "label"),
                                label: str_of(o, "label"),
                                sub: str_of(o, "description"),
                                group: String::new(),
                                preview: None,
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                Field {
                    key: format!("q{i}"),
                    kind: "choice".into(),
                    label: str_of(q, "question"),
                    value: options.first().map(|o| o.id.clone()).unwrap_or_default(),
                    options,
                }
            })
            .collect();
        return Spec {
            kind: "claude".into(),
            source: project.into(),
            title: i18n::tr("claude.question"),
            fields,
            actions: vec![action("answer", i18n::tr("claude.answer"), true, false)],
            timeout: None,
            ..Default::default()
        };
    }

    let mut actions = vec![action("deny", i18n::tr("claude.deny"), false, true)];
    let suggestions = request
        .get("permission_suggestions")
        .and_then(Value::as_array)
        .is_some_and(|a| !a.is_empty());
    if suggestions {
        actions.push(action("always", i18n::tr("claude.always"), false, false));
    }
    actions.push(action("allow", i18n::tr("claude.allow"), true, false));
    let shown = match request.get("display_name").and_then(Value::as_str) {
        Some(n) if !n.is_empty() => n.to_string(),
        _ => tool.clone(),
    };
    Spec {
        kind: "claude".into(),
        source: project.into(),
        title: i18n::tr_args("claude.permission", &[("tool", &shown)]),
        text: str_of(request, "description"),
        detail: detail(&tool, &input),
        actions,
        timeout: None,
        ..Default::default()
    }
}

/// What the card shows of the call, in monospace: the command, the file
/// and what changes in it, else the input.
fn detail(tool: &str, input: &Value) -> String {
    let text = match tool {
        "Bash" => str_of(input, "command"),
        "Edit" => {
            let mut out = str_of(input, "file_path");
            for l in str_of(input, "old_string").lines().take(12) {
                out.push_str(&format!("\n- {l}"));
            }
            for l in str_of(input, "new_string").lines().take(12) {
                out.push_str(&format!("\n+ {l}"));
            }
            out
        }
        "Write" => {
            let mut out = str_of(input, "file_path");
            for l in str_of(input, "content").lines().take(16) {
                out.push_str(&format!("\n+ {l}"));
            }
            out
        }
        _ => serde_json::to_string_pretty(input).unwrap_or_default(),
    };
    let mut lines: Vec<&str> = text.lines().take(30).collect();
    if text.lines().count() > 30 {
        lines.push("…");
    }
    lines.join("\n").chars().take(3_000).collect()
}

fn deny(message: &str) -> Value {
    json!({ "behavior": "deny", "message": message })
}

/// What `claude` is told, from the button pressed.
fn decide(request: &Value, action: &str, values: &HashMap<String, String>) -> Value {
    let input = request.get("input").cloned().unwrap_or(json!({}));
    match action {
        "allow" => json!({ "behavior": "allow", "updatedInput": input }),
        "always" => json!({
            "behavior": "allow",
            "updatedInput": input,
            "updatedPermissions": request.get("permission_suggestions").cloned().unwrap_or(json!([])),
        }),
        "answer" => {
            let mut input = input;
            let answers: serde_json::Map<String, Value> = input
                .get("questions")
                .and_then(Value::as_array)
                .map(|qs| {
                    qs.iter()
                        .enumerate()
                        .filter_map(|(i, q)| {
                            let v = values.get(&format!("q{i}"))?;
                            Some((str_of(q, "question"), Value::String(v.clone())))
                        })
                        .collect()
                })
                .unwrap_or_default();
            input["answers"] = Value::Object(answers);
            json!({ "behavior": "allow", "updatedInput": input })
        }
        _ => deny(&i18n::tr("claude.denied")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tool_card_offers_to_keep_the_rule_only_when_claude_suggests_one() {
        let req = json!({"tool_name":"Edit","display_name":"Edit","description":"a.txt",
            "input":{"file_path":"/p/a.txt","old_string":"x","new_string":"y"},
            "permission_suggestions":[{"type":"setMode","mode":"acceptEdits"}]});
        let s = spec("proj", &req);
        let ids: Vec<_> = s.actions.iter().map(|a| a.id.as_str()).collect();
        assert_eq!(ids, ["deny", "always", "allow"]);
        assert_eq!(s.detail, "/p/a.txt\n- x\n+ y");
        assert_eq!((s.kind.as_str(), s.source.as_str()), ("claude", "proj"));
        let bare = spec("p", &json!({"tool_name":"Bash","input":{"command":"ls"}}));
        assert_eq!(bare.actions.len(), 2);
        assert_eq!(bare.detail, "ls");
    }

    #[test]
    fn answers_go_back_as_claude_expects() {
        let req = json!({"tool_name":"Edit","input":{"a":1},
            "permission_suggestions":[{"type":"setMode"}]});
        let none = HashMap::new();
        assert_eq!(
            decide(&req, "allow", &none),
            json!({"behavior":"allow","updatedInput":{"a":1}})
        );
        assert_eq!(
            decide(&req, "always", &none)["updatedPermissions"],
            json!([{"type":"setMode"}])
        );
        assert_eq!(decide(&req, "cancel", &none)["behavior"], "deny");
    }

    #[test]
    fn questions_become_choices_and_their_answers_go_in_the_input() {
        let req = json!({"tool_name":"AskUserQuestion","input":{"questions":[
            {"question":"Thé ou café ?","options":[{"label":"Thé"},{"label":"Café","description":"noir"}]}]}});
        let s = spec("p", &req);
        assert_eq!(s.fields[0].kind, "choice");
        assert_eq!(s.fields[0].options[1].sub, "noir");
        let values = HashMap::from([("q0".to_string(), "Café".to_string())]);
        let r = decide(&req, "answer", &values);
        assert_eq!(
            r["updatedInput"]["answers"],
            json!({"Thé ou café ?":"Café"})
        );
        assert_eq!(
            r["updatedInput"]["questions"][0]["question"],
            "Thé ou café ?"
        );
    }

    #[test]
    fn a_folder_s_direnv_is_read_or_says_why_not() {
        let (vars, how) = read_env(true, br#"{"A":"1","B":null}"#, "");
        assert_eq!(how, "loaded");
        assert_eq!(vars["A"].as_deref(), Some("1"));
        assert_eq!(vars["B"], None);
        assert_eq!(read_env(true, b"\n", "").1, "");
        assert_eq!(
            read_env(false, b"", "/p/.envrc is blocked. Run").1,
            "blocked"
        );
        assert_eq!(read_env(false, b"", "flake error").1, "failed");
    }

    #[test]
    fn new_ids_are_uuids() {
        let id = new_uuid();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        assert_ne!(id, new_uuid());
    }

    #[test]
    fn joined_files_go_by_path_and_images_as_such() {
        let dir = std::env::temp_dir().join(format!("anna-joined-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let png = dir.join("a.png");
        let bytes = b"\x89PNG\r\n\x1a\nthe rest of the image";
        std::fs::write(&png, bytes).unwrap();
        // Named as an image, but none.
        let fake = dir.join("b.png");
        std::fs::write(&fake, "text").unwrap();
        let path = |p: &std::path::Path| p.to_string_lossy().into_owned();

        assert_eq!(content("hi", &[]).unwrap(), json!("hi"));
        let c = content("look", &[path(&png), path(&fake)]).unwrap();
        let blocks = c.as_array().unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0]["source"]["media_type"], "image/png");
        use base64::Engine;
        let sent = base64::engine::general_purpose::STANDARD
            .decode(blocks[0]["source"]["data"].as_str().unwrap())
            .unwrap();
        assert_eq!(sent, bytes);
        assert!(blocks[1]["text"].as_str().unwrap().starts_with("look\n\n"));
        assert!(content("x", &[path(&dir.join("none"))]).is_err());
        assert!(content("x", &["/dev/zero".into()]).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn internal_and_removed_commands_are_not_offered() {
        let list = offered(&json!([
            {"name":"compact","description":"Free up context","aliases":["c"]},
            {"name":"__remote-workflow","description":"x"},
            {"name":"agents","description":"(removed) x"},
            {"name":"extra-usage","description":"Renamed to /usage-credits"},
        ]));
        let names: Vec<_> = list.as_array().unwrap().iter().map(|c| &c["name"]).collect();
        assert_eq!(names, ["compact"]);
        assert_eq!(list[0]["aliases"][0], "c");
        assert_eq!(offered(&Value::Null), json!([]));
    }

    #[test]
    fn launch_words_are_checked() {
        assert!(valid_word("claude-opus-5-5[1m]"));
        assert!(valid_word("acceptEdits"));
        assert!(!valid_word("--dangerously-skip-permissions x"));
        assert!(!valid_word(""));
    }

    /// A real `claude` (a turn costs money): `cargo test -- --ignored
    /// drives_a_real_claude`. Starts a session in an empty folder with
    /// Haiku at low effort, asks for a file to be written and refuses the
    /// request in the panel's place, then resumes it after the driver is
    /// stopped.
    #[tokio::test]
    #[ignore]
    async fn drives_a_real_claude() {
        let dir = std::env::temp_dir().join(format!("anna-drive-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let drive = Drive::new();
        let models = drive.models().await;
        assert!(
            models["models"].as_array().is_some_and(|m| m.len() > 2),
            "{models}"
        );
        let turn = |id: Option<String>, text: &'static str| {
            let drive = Arc::clone(&drive);
            let cwd = dir.to_string_lossy().into_owned();
            async move {
                let launch = Launch {
                    model: Some("haiku".into()),
                    effort: Some("low".into()),
                    mode: None,
                };
                let id = drive
                    .send(id, Some(cwd), text.into(), Vec::new(), launch)
                    .await
                    .unwrap();
                let d = drive.get(&id).unwrap();
                let mut rx = d.tx.subscribe();
                let mut asked = false;
                while d.state().busy {
                    if let Ok(Ok(_)) =
                        tokio::time::timeout(Duration::from_secs(120), rx.recv()).await
                    {
                        let asks = d.state().asks;
                        if let Some(a) = asks.first() {
                            asked |= a.tool == "Write" && !super::asks(&id).is_empty();
                            drive
                                .answer(&id, &a.id, "deny".into(), HashMap::new())
                                .unwrap();
                        }
                    } else {
                        break;
                    }
                }
                // The context, asked for after the turn.
                for _ in 0..30 {
                    if !d.state().context.is_null() {
                        break;
                    }
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                (id, d.state(), asked)
            }
        };
        let (id, s, asked) = turn(
            None,
            "Écris « salut » dans le fichier a.txt avec l'outil Write, puis réponds en un mot.",
        )
        .await;
        eprintln!("state after turn 1: {s:?}");
        assert!(s.driven && !s.busy && s.model.contains("haiku") && s.cost > 0.0);
        assert_eq!(s.effort, "low");
        assert!(s.context["categories"].is_array(), "context by category");
        assert!(asked, "the Write permission waited in the state");
        assert!(asks(&id).is_empty() && s.asks.is_empty());
        assert!(!dir.join("a.txt").exists(), "refused");
        assert!(is_ours(drive.get(&id).unwrap().pid));
        drive.stop(&id).await.unwrap();
        for _ in 0..50 {
            if drive.get(&id).is_none() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        assert!(drive.get(&id).is_none());
        let (id2, s, _) = turn(Some(id.clone()), "Réponds juste : OK").await;
        assert_eq!(id2, id);
        assert!(!s.busy && s.error.is_empty(), "{s:?}");
        let path = super::super::sessions::transcript_of(&id).unwrap();
        let (page, _) = super::super::transcript::page(&path, None, 50);
        let kinds: Vec<_> = page.items.iter().map(|i| i.kind.as_str()).collect();
        eprintln!("items: {kinds:?}");
        assert!(page
            .items
            .iter()
            .any(|i| i.kind == "tool" && i.tool == "Write" && i.done && i.error));
        assert_eq!(page.items.iter().filter(|i| i.kind == "user").count(), 2);
        drive.stop(&id).await.unwrap();
    }
}
