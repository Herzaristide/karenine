//! The Claude Code sessions, for the shell's « Claude » tab: those running
//! now — which one waits for the user, which one works and at what — and
//! every one that ended, to resume them.
//!
//! Three sources, none of them an API:
//!
//!   1. `~/.claude/sessions/<pid>.json`, written by each running Claude
//!      Code: its id, folder, name and `busy` / `idle` state.
//!   2. `~/.claude/projects/<folder>/<id>.jsonl`, its transcript: the title
//!      Claude Code gives it (`ai-title`) and the git branch.
//!   3. The hooks: `anna claude-event`, run by Claude Code on each event,
//!      tells the daemon what a session does (`PreToolUse`) and when it
//!      waits for the user (`Notification`) — the one thing the files do
//!      not say.
//!
//! None of these formats is documented: every field is read leniently, and a
//! session missing one still shows, with less detail.

use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// How much of a transcript's end is read for its title and branch.
const TAIL: u64 = 256 * 1024;
/// The ended sessions are looked up again at most this often.
const RECENT_EVERY: Duration = Duration::from_secs(30);

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Session {
    pub id: String,
    /// The folder's last component (« karenine »).
    pub project: String,
    pub cwd: String,
    pub branch: String,
    /// The title Claude Code gave it, else its derived name.
    pub title: String,
    /// `waiting` (for the user), `busy`, `idle` or `ended`.
    pub state: String,
    /// What it does now (« Edit widgets/Bar.qml »), "" when nothing.
    pub activity: String,
    /// What it asks while waiting (« Claude needs your permission… »).
    pub ask: String,
    /// The Claude Code process, 0 once ended.
    pub pid: u32,
    /// Milliseconds since the epoch.
    pub updated: i64,
}

#[derive(Serialize, Default)]
pub struct Snapshot {
    pub live: Vec<Session>,
    pub recent: Vec<Session>,
}

/// What the hooks said of a session.
#[derive(Default, Clone)]
struct Heard {
    activity: String,
    ask: String,
    waiting: bool,
}

static HEARD: LazyLock<Mutex<HashMap<String, Heard>>> = LazyLock::new(Default::default);
/// The ended sessions, and when they were looked up.
type Recent = Option<(Instant, Vec<Session>)>;
static RECENT_CACHE: LazyLock<Mutex<Recent>> = LazyLock::new(Default::default);
/// What each transcript said, with the modification time and size it had:
/// only the transcripts that changed are read again.
type Transcripts = HashMap<PathBuf, (SystemTime, u64, Transcript)>;
static TRANSCRIPTS: LazyLock<Mutex<Transcripts>> = LazyLock::new(Default::default);

fn claude_dir() -> PathBuf {
    crate::paths::home_dir().join(".claude")
}

fn s(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn base(path: &str) -> String {
    Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

// ── The hooks ───────────────────────────────────────────────────────────────

/// Keep what a hook says (the JSON Claude Code hands its hooks on stdin).
pub fn record(event: &Value) {
    let id = s(event, "session_id");
    if id.is_empty() {
        return;
    }
    let mut heard = HEARD.lock().unwrap();
    match event
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
    {
        "SessionEnd" => {
            heard.remove(&id);
        }
        "Notification" => {
            let h = heard.entry(id).or_default();
            h.waiting = true;
            h.ask = s(event, "message");
        }
        "PreToolUse" => {
            let h = heard.entry(id).or_default();
            h.waiting = false;
            h.ask.clear();
            h.activity = activity(event);
        }
        "UserPromptSubmit" | "PostToolUse" => {
            let h = heard.entry(id).or_default();
            h.waiting = false;
            h.ask.clear();
        }
        "Stop" => {
            let h = heard.entry(id).or_default();
            h.waiting = false;
            h.ask.clear();
            h.activity.clear();
        }
        _ => {}
    }
}

/// « Edit widgets/Bar.qml », « Bash cargo test » : the tool, and what it
/// works on, short.
fn activity(event: &Value) -> String {
    let tool = s(event, "tool_name");
    let input = event.get("tool_input").cloned().unwrap_or(Value::Null);
    let cwd = s(event, "cwd");
    let target = ["file_path", "notebook_path", "path"]
        .iter()
        .find_map(|k| input.get(*k).and_then(Value::as_str))
        .map(|p| p.strip_prefix(&format!("{cwd}/")).unwrap_or(p).to_string())
        .or_else(|| {
            [
                "command",
                "pattern",
                "url",
                "query",
                "description",
                "prompt",
            ]
            .iter()
            .find_map(|k| input.get(*k).and_then(Value::as_str))
            .map(str::to_string)
        })
        .unwrap_or_default();
    let target: String = target
        .lines()
        .next()
        .unwrap_or_default()
        .chars()
        .take(80)
        .collect();
    if target.is_empty() {
        tool
    } else {
        format!("{tool} {target}")
    }
}

/// `anna claude-event`, run by a Claude Code hook: hands what it reads on
/// stdin to the daemon. Never fails the hook: without the daemon, nothing
/// happens.
pub fn hook() {
    use std::io::Write;
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return;
    }
    let Ok(event) = serde_json::from_str::<Value>(&input) else {
        return;
    };
    let line = serde_json::json!({ "cmd": "claude_event", "event": event }).to_string();
    if let Ok(mut stream) = std::os::unix::net::UnixStream::connect(crate::paths::socket_path()) {
        let _ = writeln!(stream, "{line}");
    }
}

// ── The files ───────────────────────────────────────────────────────────────

/// What a transcript says of its session: its latest title and branch, and
/// the folder it started in (a `cd` along the way does not move the
/// project). Its beginning is read for the folder, its end for the rest; the
/// beginning gives the title too if the end has none.
#[derive(Default, Clone)]
struct Transcript {
    title: String,
    branch: String,
    cwd: String,
    /// The first thing the user asked: the title of a session Claude Code
    /// gave none (a short one).
    prompt: String,
}

/// The text of a user's message, unless it is one Claude Code wrote itself
/// (a command, a caveat, a tool result).
fn prompt_of(v: &Value) -> Option<String> {
    if v.get("type").and_then(Value::as_str) != Some("user")
        || v.get("isMeta").and_then(Value::as_bool) == Some(true)
    {
        return None;
    }
    let content = v.pointer("/message/content")?;
    let text = match content {
        Value::String(t) => t.clone(),
        Value::Array(parts) => parts
            .iter()
            .find(|p| p.get("type").and_then(Value::as_str) == Some("text"))
            .and_then(|p| p.get("text").and_then(Value::as_str))?
            .to_string(),
        _ => return None,
    };
    let text = text.trim();
    if text.is_empty() || text.starts_with('<') {
        return None;
    }
    Some(text.lines().next()?.chars().take(80).collect())
}

fn scan(text: &str, into: &mut Transcript) {
    for line in text.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue; // a line cut by the tail
        };
        if let Some(t) = v.get("aiTitle").and_then(Value::as_str) {
            into.title = t.to_string();
        }
        if let Some(b) = v
            .get("gitBranch")
            .and_then(Value::as_str)
            .filter(|b| !b.is_empty())
        {
            into.branch = b.to_string();
        }
        if let Some(c) = v
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|c| !c.is_empty())
        {
            if into.cwd.is_empty() {
                into.cwd = c.to_string();
            }
        }
        if into.prompt.is_empty() {
            if let Some(p) = prompt_of(&v) {
                into.prompt = p;
            }
        }
    }
}

fn read_transcript(path: &Path) -> Transcript {
    let mut t = Transcript::default();
    let Ok(mut file) = std::fs::File::open(path) else {
        return t;
    };
    let len = file.metadata().map(|m| m.len()).unwrap_or(0);

    // The beginning: the folder it started in.
    let mut head = vec![0; TAIL.min(len) as usize];
    let n = file.read(&mut head).unwrap_or(0);
    let mut first = Transcript::default();
    scan(&String::from_utf8_lossy(&head[..n]), &mut first);
    if len <= TAIL {
        return first;
    }

    // The end: the latest title and branch.
    let mut buf = Vec::new();
    if file.seek(SeekFrom::Start(len - TAIL)).is_ok() {
        let _ = file.read_to_end(&mut buf);
    }
    scan(&String::from_utf8_lossy(&buf), &mut t);
    t.cwd = if first.cwd.is_empty() {
        t.cwd
    } else {
        first.cwd
    };
    if t.title.is_empty() {
        t.title = first.title;
    }
    if t.branch.is_empty() {
        t.branch = first.branch;
    }
    t.prompt = first.prompt;
    t
}

/// `read_transcript`, from the cache while the file has not changed.
fn transcript(path: &Path) -> Transcript {
    let meta = std::fs::metadata(path).ok();
    let stamp = meta
        .as_ref()
        .map(|m| (m.modified().unwrap_or(UNIX_EPOCH), m.len()));
    let mut cache = TRANSCRIPTS.lock().unwrap();
    if let (Some((m, len)), Some((cm, clen, t))) = (stamp, cache.get(path)) {
        if m == *cm && len == *clen {
            return t.clone();
        }
    }
    let t = read_transcript(path);
    if let Some((m, len)) = stamp {
        cache.insert(path.to_path_buf(), (m, len, t.clone()));
    }
    t
}

/// The title to show: Claude Code's, else the first request.
fn title_of(t: &Transcript) -> String {
    if t.title.is_empty() {
        t.prompt.clone()
    } else {
        t.title.clone()
    }
}

/// The transcript of session `id`, in whichever project folder it is.
fn transcript_of(id: &str) -> Option<PathBuf> {
    let name = format!("{id}.jsonl");
    std::fs::read_dir(claude_dir().join("projects"))
        .ok()?
        .flatten()
        .map(|d| d.path().join(&name))
        .find(|p| p.exists())
}

fn alive(pid: u32) -> bool {
    pid > 0 && Path::new(&format!("/proc/{pid}")).exists()
}

/// The sessions running now: the waiting ones first, then the busy ones,
/// then the most recently active.
fn live() -> Vec<Session> {
    let heard = HEARD.lock().unwrap().clone();
    let mut out = Vec::new();
    let Ok(dir) = std::fs::read_dir(claude_dir().join("sessions")) else {
        return out;
    };
    for entry in dir.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let Ok(v) = std::fs::read_to_string(&path)
            .map_err(|_| ())
            .and_then(|t| serde_json::from_str::<Value>(&t).map_err(|_| ()))
        else {
            continue;
        };
        let pid = v.get("pid").and_then(Value::as_u64).unwrap_or(0) as u32;
        let cwd = s(&v, "cwd");
        if !alive(pid) {
            continue;
        }
        let id = s(&v, "sessionId");
        let t = transcript_of(&id)
            .map(|p| transcript(&p))
            .unwrap_or_default();
        let h = heard.get(&id).cloned().unwrap_or_default();
        let state = if h.waiting {
            "waiting".to_string()
        } else {
            match s(&v, "status").as_str() {
                "busy" => "busy".to_string(),
                _ => "idle".to_string(),
            }
        };
        out.push(Session {
            project: base(&cwd),
            title: match title_of(&t) {
                t if t.is_empty() => s(&v, "name"),
                t => t,
            },
            branch: t.branch,
            activity: if state == "busy" {
                h.activity
            } else {
                String::new()
            },
            ask: h.ask,
            state,
            pid,
            updated: v
                .get("statusUpdatedAt")
                .or_else(|| v.get("updatedAt"))
                .and_then(Value::as_i64)
                .unwrap_or(0),
            cwd,
            id,
        });
    }
    out.sort_by(|a, b| {
        rank(&a.state)
            .cmp(&rank(&b.state))
            .then(b.updated.cmp(&a.updated))
    });
    out
}

fn rank(state: &str) -> u8 {
    match state {
        "waiting" => 0,
        "busy" => 1,
        _ => 2,
    }
}

/// Every session that ended, newest first: the transcripts no running
/// session owns.
fn recent(live: &[Session]) -> Vec<Session> {
    let mut cache = RECENT_CACHE.lock().unwrap();
    if let Some((at, list)) = cache.as_ref() {
        if at.elapsed() < RECENT_EVERY {
            return list
                .iter()
                .filter(|r| !live.iter().any(|l| l.id == r.id))
                .cloned()
                .collect();
        }
    }
    let mut files: Vec<(SystemTime, PathBuf)> = Vec::new();
    if let Ok(projects) = std::fs::read_dir(claude_dir().join("projects")) {
        for project in projects.flatten() {
            let Ok(entries) = std::fs::read_dir(project.path()) else {
                continue;
            };
            for e in entries.flatten() {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) != Some("jsonl") {
                    continue;
                }
                if let Ok(m) = e.metadata().and_then(|m| m.modified()) {
                    files.push((m, p));
                }
            }
        }
    }
    files.sort_by_key(|f| std::cmp::Reverse(f.0));
    let mut list = Vec::new();
    for (modified, path) in files {
        let id = path
            .file_stem()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let t = transcript(&path);
        let title = title_of(&t);
        // A transcript with neither request nor folder is no session to
        // resume (one that never started).
        if title.is_empty() || t.cwd.is_empty() {
            continue;
        }
        list.push(Session {
            id,
            project: base(&t.cwd),
            cwd: t.cwd,
            branch: t.branch,
            title,
            state: "ended".into(),
            updated: modified
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0),
            ..Default::default()
        });
    }
    *cache = Some((Instant::now(), list.clone()));
    list.into_iter()
        .filter(|r| !live.iter().any(|l| l.id == r.id))
        .collect()
}

pub fn sample() -> Snapshot {
    let live = live();
    let recent = recent(&live);
    Snapshot { live, recent }
}

// ── Going to a session ──────────────────────────────────────────────────────

/// The parent of process `pid`, from /proc.
fn parent(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // « 123 (name) S 45 … » : the name may hold spaces and parentheses.
    let after = &stat[stat.rfind(')')? + 2..];
    after.split_whitespace().nth(1)?.parse().ok()
}

/// Bring the terminal that runs session process `pid` to the front: the
/// Hyprland window whose process is one of its ancestors.
pub fn focus(pid: u32) -> Result<(), String> {
    let out = std::process::Command::new("hyprctl")
        .args(["clients", "-j"])
        .output()
        .map_err(|e| e.to_string())?;
    let clients: Value = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    let pids: Vec<u64> = clients
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|c| c.get("pid").and_then(Value::as_u64))
                .collect()
        })
        .unwrap_or_default();
    let mut p = pid;
    for _ in 0..32 {
        if pids.contains(&(p as u64)) {
            let lua = format!("hl.dsp.focus({{ window = \"pid:{p}\" }})");
            let out = std::process::Command::new("hyprctl")
                .args(["dispatch", &lua])
                .output()
                .map_err(|e| e.to_string())?;
            let text = String::from_utf8_lossy(&out.stdout);
            return if text.contains("error") {
                Err(text.into_owned())
            } else {
                Ok(())
            };
        }
        match parent(p) {
            Some(pp) if pp > 1 => p = pp,
            _ => break,
        }
    }
    Err("aucune fenêtre ne porte cette session".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn activity_names_the_tool_and_its_file_relative_to_the_folder() {
        let e = json!({
            "tool_name": "Edit",
            "cwd": "/home/a/karenine",
            "tool_input": { "file_path": "/home/a/karenine/panels/Bar.qml" }
        });
        assert_eq!(activity(&e), "Edit panels/Bar.qml");
    }

    #[test]
    fn activity_keeps_the_first_line_of_a_command_short() {
        let long = "x".repeat(200);
        let e =
            json!({ "tool_name": "Bash", "tool_input": { "command": format!("{long}\nsecond") } });
        assert_eq!(activity(&e), format!("Bash {}", "x".repeat(80)));
        assert_eq!(activity(&json!({ "tool_name": "TodoWrite" })), "TodoWrite");
    }

    #[test]
    fn hooks_mark_a_session_waiting_then_working_again() {
        let id = "test-session-hooks";
        record(
            &json!({ "session_id": id, "hook_event_name": "Notification", "message": "Permission ?" }),
        );
        {
            let h = HEARD.lock().unwrap();
            assert!(h[id].waiting);
            assert_eq!(h[id].ask, "Permission ?");
        }
        record(
            &json!({ "session_id": id, "hook_event_name": "PreToolUse", "tool_name": "Read",
                        "tool_input": { "file_path": "a.rs" } }),
        );
        {
            let h = HEARD.lock().unwrap();
            assert!(!h[id].waiting);
            assert_eq!(h[id].activity, "Read a.rs");
        }
        record(&json!({ "session_id": id, "hook_event_name": "SessionEnd" }));
        assert!(!HEARD.lock().unwrap().contains_key(id));
    }

    #[test]
    fn scan_keeps_the_latest_title_and_skips_cut_lines() {
        let mut t = Transcript::default();
        scan(
            "{\"broken\n{\"type\":\"ai-title\",\"aiTitle\":\"Old\"}\n\
             {\"type\":\"user\",\"cwd\":\"/x/proj\",\"gitBranch\":\"main\"}\n\
             {\"type\":\"user\",\"cwd\":\"/x/proj/sub\"}\n\
             {\"type\":\"ai-title\",\"aiTitle\":\"New\"}\n",
            &mut t,
        );
        assert_eq!(
            (t.title.as_str(), t.branch.as_str(), t.cwd.as_str()),
            ("New", "main", "/x/proj")
        );
    }

    #[test]
    fn an_untitled_session_is_named_by_its_first_request() {
        let mut t = Transcript::default();
        scan(
            "{\"type\":\"user\",\"isMeta\":true,\"message\":{\"content\":\"caveat\"}}\n\
             {\"type\":\"user\",\"message\":{\"content\":\"<command-name>/clear</command-name>\"}}\n\
             {\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Fix the bar\\nplease\"}]}}\n\
             {\"type\":\"user\",\"message\":{\"content\":\"Later\"}}\n",
            &mut t,
        );
        assert_eq!(title_of(&t), "Fix the bar");
    }

    #[test]
    fn parent_reads_through_names_with_spaces() {
        // Our own parent is alive and known.
        assert!(parent(std::process::id()).is_some());
    }
}
