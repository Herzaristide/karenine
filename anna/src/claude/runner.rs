//! Sessions started — or resumed — from the AI dock.
//!
//! anna runs them headless (`claude -p`, stream-json both ways) and keeps
//! their stdin, so the dock can send follow-ups. They live here rather than
//! in the QML because a shell reload kills what the QML spawned, and a
//! session may run for an hour.
//!
//! Nothing else is special about them: they report through the same hooks
//! as a terminal session, their transcript is the usual JSONL — `claude
//! --resume` in a terminal picks them up. Without a terminal, they have no
//! permission dialog: what no rule allows is refused.
//! Project sessions run in their own copy of the repository
//! (`--worktree`, see worktree.rs).
//!
//! A managed session dies with anna (restart, rebuild); its transcript stays,
//! and sending to it again resumes it.

use super::{worktree, Sessions};
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStdin, Command};
use tokio::sync::Mutex as AsyncMutex;

struct Proc {
    pid: u32,
    stdin: Arc<AsyncMutex<ChildStdin>>,
}

pub struct Runner {
    procs: std::sync::Mutex<HashMap<String, Proc>>,
    sessions: Arc<Sessions>,
}

/// What to start: a new session in `cwd` (in its own worktree if asked), or
/// `resume` an existing one there.
pub struct Start {
    pub cwd: String,
    pub prompt: String,
    pub worktree: bool,
    pub resume: Option<String>,
}

fn new_uuid() -> Result<String, String> {
    std::fs::read_to_string("/proc/sys/kernel/random/uuid")
        .map(|s| s.trim().to_string())
        .map_err(|e| format!("uuid: {e}"))
}

/// Where Claude Code keeps a session's transcript.
pub fn transcript_path(cwd: &str, id: &str) -> String {
    let slug: String = cwd
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    format!(
        "{}/.claude/projects/{slug}/{id}.jsonl",
        crate::paths::home_dir().display()
    )
}

fn user_line(text: &str) -> String {
    serde_json::json!({
        "type": "user",
        "message": { "role": "user", "content": text },
    })
    .to_string()
        + "\n"
}

/// Start a program detached from anna — in its own systemd scope, so it
/// survives a daemon restart — with the session's environment.
fn launch(args: &[&str]) -> Result<(), String> {
    let status = std::process::Command::new("systemd-run")
        .args([
            "--user",
            "--collect",
            "--quiet",
            "-p",
            "ExitType=cgroup",
            "--",
        ])
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("systemd-run: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(crate::i18n::tr_args(
            "could_not_start",
            &[("what", args[0])],
        ))
    }
}

impl Runner {
    pub fn new(sessions: Arc<Sessions>) -> Arc<Self> {
        Arc::new(Runner {
            procs: std::sync::Mutex::new(HashMap::new()),
            sessions,
        })
    }

    fn procs(&self) -> std::sync::MutexGuard<'_, HashMap<String, Proc>> {
        self.procs.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn running(&self, id: &str) -> bool {
        self.procs().contains_key(id)
    }

    /// Whether the session is still running after giving it a moment to
    /// exit: Claude reports its end (SessionEnd) slightly before its
    /// process is gone, and a click on "merge" can land in between.
    pub async fn still_running(&self, id: &str) -> bool {
        for _ in 0..30 {
            if !self.running(id) {
                return false;
            }
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        }
        true
    }

    /// Start (or resume) a session and hand it its first message. Returns
    /// the session id.
    pub async fn start(self: &Arc<Self>, spec: Start) -> Result<String, String> {
        if !Path::new(&spec.cwd).is_dir() {
            return Err(format!("dossier introuvable : {}", spec.cwd));
        }
        if let Some(id) = &spec.resume {
            if self.running(id) {
                self.send(id, &spec.prompt).await?;
                return Ok(id.clone());
            }
        }
        let id = match &spec.resume {
            Some(id) => id.clone(),
            None => new_uuid()?,
        };

        let mut args: Vec<String> = [
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
        ]
        .map(String::from)
        .to_vec();
        // The cwd the session will actually work in: the new copy, if any.
        let mut work_cwd = spec.cwd.clone();
        match &spec.resume {
            Some(r) => args.extend(["--resume".into(), r.clone()]),
            None => {
                args.extend(["--session-id".into(), id.clone()]);
                if spec.worktree {
                    let name = worktree::name_for(&spec.prompt, &id[..4]);
                    work_cwd = format!("{}/.claude/worktrees/{name}", spec.cwd);
                    args.extend(["--worktree".into(), name]);
                }
            }
        }
        // Development: hooks for a build that the user settings don't name.
        if let Ok(s) = std::env::var("ANNA_CLAUDE_SETTINGS") {
            args.extend(["--settings".into(), s]);
        }

        let mut child = Command::new("claude")
            .args(&args)
            .current_dir(&spec.cwd)
            // `-p` marks the transcript "sdk-cli", which `/resume` hides; any
            // other entrypoint keeps the session in the picker.
            .env("CLAUDE_CODE_ENTRYPOINT", "anna")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("claude: {e}"))?;
        let pid = child.id().unwrap_or(0);
        let stdin = Arc::new(AsyncMutex::new(
            child.stdin.take().ok_or("claude: pas d'entrée standard")?,
        ));

        // The output pipes must be drained or claude blocks on a full pipe.
        // Its stream says nothing the transcript and the hooks don't.
        if let Some(out) = child.stdout.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(out).lines();
                while let Ok(Some(_)) = lines.next_line().await {}
            });
        }
        if let Some(err) = child.stderr.take() {
            let tag = id[..8].to_string();
            tokio::spawn(async move {
                let mut lines = BufReader::new(err).lines();
                while let Ok(Some(l)) = lines.next_line().await {
                    eprintln!("anna: claude {tag}: {l}");
                }
            });
        }

        self.procs().insert(
            id.clone(),
            Proc {
                pid,
                stdin: Arc::clone(&stdin),
            },
        );
        self.sessions.adopt(
            &id,
            &work_cwd,
            pid,
            &spec.prompt,
            &transcript_path(&work_cwd, &id),
        );
        stdin
            .lock()
            .await
            .write_all(user_line(&spec.prompt).as_bytes())
            .await
            .map_err(|e| format!("claude: {e}"))?;

        let me = Arc::clone(self);
        let done_id = id.clone();
        tokio::spawn(async move {
            let _ = child.wait().await;
            me.procs().remove(&done_id);
            me.sessions.release(&done_id);
        });
        Ok(id)
    }

    /// A follow-up message to a running managed session.
    pub async fn send(&self, id: &str, text: &str) -> Result<(), String> {
        let stdin = self
            .procs()
            .get(id)
            .map(|p| Arc::clone(&p.stdin))
            .ok_or_else(|| crate::i18n::tr("session.not_from_dock"))?;
        let mut w = stdin.lock().await;
        w.write_all(user_line(text).as_bytes())
            .await
            .map_err(|e| format!("claude: {e}"))?;
        Ok(())
    }

    /// Stop a managed session now. Its transcript keeps everything up to
    /// the last complete message.
    pub fn stop(&self, id: &str) -> Result<(), String> {
        let pid = self
            .procs()
            .get(id)
            .map(|p| p.pid)
            .ok_or_else(|| crate::i18n::tr("session.not_from_dock"))?;
        let ok = std::process::Command::new("kill")
            .args(["-TERM", &pid.to_string()])
            .status()
            .is_ok_and(|s| s.success());
        if ok {
            Ok(())
        } else {
            Err(crate::i18n::tr("session.cannot_stop"))
        }
    }

    /// Open a session's directory in Zed, or the session itself in a
    /// terminal — stopping it here first, so two processes never write the
    /// same conversation.
    pub async fn open(&self, cwd: &str, app: &str, id: &str) -> Result<(), String> {
        match app {
            "zed" => launch(&["zeditor", cwd]),
            "terminal" => {
                if self.running(id) {
                    self.stop(id)?;
                    for _ in 0..50 {
                        if !self.running(id) {
                            break;
                        }
                        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    }
                }
                let mut args = vec!["alacritty", "--working-directory", cwd, "-e", "claude"];
                if !id.is_empty() {
                    args.extend(["--resume", id]);
                }
                launch(&args)
            }
            other => Err(format!("application inconnue : {other}")),
        }
    }
}

#[derive(Debug, Serialize, PartialEq)]
pub struct Project {
    pub name: String,
    pub path: String,
    /// "projet" (a git repository, worked on in a copy) or "recherche" (the
    /// Obsidian vault, worked on in place).
    pub kind: &'static str,
}

/// Where a new session can start: the vault for research, then every git
/// repository under ~/ciph3r, then the NixOS configuration.
pub fn projects() -> Vec<Project> {
    let home = crate::paths::home_dir();
    let mut out = Vec::new();
    let vault = home.join("v4ult");
    if vault.is_dir() {
        out.push(Project {
            name: "recherche".into(),
            path: vault.to_string_lossy().into(),
            kind: "recherche",
        });
    }
    let mut repos: Vec<Project> = std::fs::read_dir(home.join("ciph3r"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join(".git").exists())
        .map(|p| Project {
            name: p
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            path: p.to_string_lossy().into(),
            kind: "projet",
        })
        .collect();
    repos.sort_by_key(|p| p.name.to_lowercase());
    out.extend(repos);
    if Path::new("/etc/nixos/.git").exists() {
        out.push(Project {
            name: "nixos".into(),
            path: "/etc/nixos".into(),
            kind: "projet",
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcript_path_matches_claude_codes_layout() {
        // Both seen on this machine (~/.claude/projects).
        let p = transcript_path("/home/aristide/ciph3r/karenine", "abc");
        assert!(p.ends_with("/.claude/projects/-home-aristide-ciph3r-karenine/abc.jsonl"));
        let p = transcript_path("/tmp/claude-1000/x/scratchpad", "abc");
        assert!(p.ends_with("/-tmp-claude-1000-x-scratchpad/abc.jsonl"));
    }

    #[test]
    fn user_lines_are_stream_json() {
        let l = user_line("salut \"toi\"");
        assert!(l.ends_with('\n'));
        let v: serde_json::Value = serde_json::from_str(l.trim()).unwrap();
        assert_eq!(v["type"], "user");
        assert_eq!(v["message"]["content"], "salut \"toi\"");
    }
}
