//! The pilot: a Claude session anna keeps warm, to which the AI dock sends
//! what the user asks of the desktop — "turn the sound down", "open Zed on
//! karenine", "fix the dock in karenine".
//!
//! It acts through the desk tools only (`anna mcp`, see desk.rs): Claude
//! Code's own tools are off, and so are the user's settings — no hooks, no
//! journal, no other MCP server — which keeps it quick to start and its
//! reach exactly what desk.rs allows. Code and research go to full sessions
//! (`lancer_session`), never to the pilot itself.
//!
//! Each request carries a short context block (time, active window,
//! sessions), built here at send time. The process lives across requests so
//! a request costs no start-up; it is restarted after a while (idle or many
//! turns) to keep its context small. Nothing is written to disk.
//!
//! What the dock shows — the user's requests, the tool calls, the answers —
//! is kept here as a short log, pushed to `pilot_watch` subscribers whole on
//! every change.

use super::{desk, Sessions};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{ChildStdin, Command};
use tokio::sync::{broadcast, Mutex as AsyncMutex};

/// Restart after this many requests, or this long without one.
const MAX_TURNS: u32 = 30;
const MAX_IDLE: Duration = Duration::from_secs(20 * 60);
/// Entries kept in the log the dock shows.
const LOG_MAX: usize = 60;

const PROMPT: &str = r#"Tu es le pilote du bureau de l'utilisateur : un assistant intégré à son interface (Hyprland sur NixOS). Il te parle depuis la barre de conversation en bas de l'écran (au clavier, ou à la voix en disant « Karénine »), en français, souvent en quelques mots. Ta réponse s'affiche juste au-dessus de la barre.

Ce que tu fais :
- Tu agis sur le bureau avec tes outils : fenêtres et workspaces, son, luminosité, lecture média, applications, URL, projets, captures, couleur d'accent, notes du coffre Obsidian, et les widgets flottants de l'interface (`widget` : stats, musique, métronome, son, caméra, réglages, sessions).
- Tu confies le travail de fond à une session Claude Code complète avec `lancer_session` : toute tâche de code (corriger, ajouter, expliquer du code d'un projet) ou de recherche approfondie. Tu ne fais jamais ce travail toi-même. Formule la demande pour cette session de façon complète et autonome. Projets : ceux de ~/ciph3r, « nixos » pour la configuration du système, « recherche » pour une recherche (le coffre de notes).
- Tu réponds directement aux questions courtes. Pour une question sur ce que l'utilisateur a déjà noté ou décidé, cherche d'abord dans ses notes (`chercher_notes`).

Comment :
- Agis d'abord, puis confirme en une phrase courte (« Volume à 30 %. », « Session lancée sur karenine. »). Pas de préambule, pas de « bien sûr ».
- Une réponse à une question : six lignes au plus, en markdown si utile.
- Ne change pas la fenêtre ou le workspace affichés sauf si on te le demande : l'utilisateur est peut-être en train de travailler.
- Si la demande est ambiguë (quelle fenêtre ? quel projet ?), pose une seule question courte au lieu de deviner. `etat_bureau` te montre ce qui est ouvert.
- Fermer une fenêtre, lancer une commande shell, reconstruire NixOS : l'utilisateur confirme lui-même dans une bulle ; s'il refuse, n'insiste pas.
- `commande` est un dernier recours, quand aucun autre outil ne convient.

Chaque demande commence par un bloc [contexte] (heure, fenêtre active, sessions en cours) : sers-t'en, ne le recopie pas."#;

/// The user's own instructions for the pilot, if any: appended to the
/// prompt (preferred apps, habits, projects…).
fn preferences() -> Option<String> {
    let p = crate::paths::home_dir().join(".config/anna/pilote.md");
    std::fs::read_to_string(p)
        .ok()
        .filter(|s| !s.trim().is_empty())
}

struct Proc {
    pid: u32,
    stdin: ChildStdin,
}

pub struct Pilot {
    proc: AsyncMutex<Option<Proc>>,
    /// Bumped on every start, so a dying process can tell it was replaced.
    generation: AtomicU32,
    busy: AtomicBool,
    turns: AtomicU32,
    last: Mutex<Instant>,
    log: Mutex<VecDeque<Value>>,
    tx: broadcast::Sender<String>,
    sessions: Arc<Sessions>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// One line saying what a tool call does, for the dock's thread.
fn action_line(name: &str, input: &Value) -> String {
    let tool = name.rsplit("__").next().unwrap_or(name);
    let args: Vec<String> = input
        .as_object()
        .map(|o| {
            o.values()
                .map(|v| match v {
                    Value::String(s) => s.chars().take(80).collect(),
                    other => other.to_string(),
                })
                .collect()
        })
        .unwrap_or_default();
    if args.is_empty() {
        tool.to_string()
    } else {
        format!("{tool} · {}", args.join(" · "))
    }
}

impl Pilot {
    pub fn new(sessions: Arc<Sessions>) -> Arc<Self> {
        let (tx, _) = broadcast::channel(32);
        Arc::new(Pilot {
            proc: AsyncMutex::new(None),
            generation: AtomicU32::new(0),
            busy: AtomicBool::new(false),
            turns: AtomicU32::new(0),
            last: Mutex::new(Instant::now()),
            log: Mutex::new(VecDeque::new()),
            tx,
            sessions,
        })
    }

    pub fn snapshot_line(&self) -> String {
        let log: Vec<Value> = lock(&self.log).iter().cloned().collect();
        json!({ "pilot": { "busy": self.busy.load(Ordering::SeqCst), "items": log } }).to_string()
    }

    fn publish(&self) {
        let _ = self.tx.send(self.snapshot_line());
    }

    pub fn subscribe(&self) -> broadcast::Receiver<String> {
        self.tx.subscribe()
    }

    fn push(&self, kind: &str, text: &str) {
        let mut log = lock(&self.log);
        log.push_back(json!({ "kind": kind, "text": text }));
        while log.len() > LOG_MAX {
            log.pop_front();
        }
    }

    /// Forget the conversation: the next request starts a fresh process.
    pub async fn reset(&self) {
        self.stop().await;
        lock(&self.log).clear();
        self.busy.store(false, Ordering::SeqCst);
        self.publish();
    }

    async fn stop(&self) {
        if let Some(p) = self.proc.lock().await.take() {
            let _ = std::process::Command::new("kill")
                .args(["-TERM", &p.pid.to_string()])
                .status();
        }
        self.turns.store(0, Ordering::SeqCst);
    }

    /// Start the pilot process (the caller holds the slot).
    fn spawn(self: &Arc<Self>, slot: &mut Option<Proc>) -> Result<(), String> {
        let dir = crate::paths::home_dir().join(".local/state/anna/pilot");
        std::fs::create_dir_all(&dir).map_err(|e| format!("pilote : {e}"))?;
        let exe = std::env::current_exe().map_err(|e| format!("pilote : {e}"))?;
        // claude's own wrapper sets LD_LIBRARY_PATH for its audio library;
        // anna, built against its own, must not inherit it.
        let mcp = json!({ "mcpServers": { "anna": {
            "type": "stdio",
            "command": exe.to_string_lossy(),
            "args": ["mcp"],
            "env": { "LD_LIBRARY_PATH": "" },
        }}});
        let mut prompt = PROMPT.to_string();
        if let Some(p) = preferences() {
            prompt.push_str("\n\nPréférences de l'utilisateur :\n");
            prompt.push_str(&p);
        }
        let model = std::env::var("ANNA_PILOT_MODEL").unwrap_or_else(|_| "haiku".into());

        let mut child = Command::new("claude")
            .args([
                "-p",
                "--input-format",
                "stream-json",
                "--output-format",
                "stream-json",
                "--verbose",
                "--model",
                &model,
                "--system-prompt",
                &prompt,
                "--tools",
                "",
                "--mcp-config",
                &mcp.to_string(),
                "--strict-mcp-config",
                "--allowedTools",
                "mcp__anna",
                "--setting-sources",
                "project",
                "--no-session-persistence",
                "--disable-slash-commands",
            ])
            .current_dir(&dir)
            // Not a session of the user's: no dot in the bar.
            .env("ANNA_HOOK_IGNORE", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("pilote : {e}"))?;

        let pid = child.id().unwrap_or(0);
        let stdin = child.stdin.take().ok_or("pilote : pas d'entrée standard")?;
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;

        if let Some(err) = child.stderr.take() {
            tokio::spawn(async move {
                let mut lines = BufReader::new(err).lines();
                while let Ok(Some(l)) = lines.next_line().await {
                    eprintln!("anna: pilote: {l}");
                }
            });
        }
        if let Some(out) = child.stdout.take() {
            let me = Arc::clone(self);
            tokio::spawn(async move {
                let mut lines = BufReader::new(out).lines();
                while let Ok(Some(l)) = lines.next_line().await {
                    me.on_event(&l);
                }
                let _ = child.wait().await;
                me.on_exit(generation).await;
            });
        }
        *slot = Some(Proc { pid, stdin });
        self.turns.store(0, Ordering::SeqCst);
        Ok(())
    }

    fn on_event(&self, line: &str) {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            return;
        };
        match v.get("type").and_then(Value::as_str) {
            Some("assistant") => {
                let Some(blocks) = v.pointer("/message/content").and_then(Value::as_array) else {
                    return;
                };
                for b in blocks {
                    match b.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            let t = b.get("text").and_then(Value::as_str).unwrap_or("").trim();
                            if !t.is_empty() {
                                self.push("reply", t);
                            }
                        }
                        Some("tool_use") => {
                            let name = b.get("name").and_then(Value::as_str).unwrap_or("outil");
                            let input = b.get("input").cloned().unwrap_or(Value::Null);
                            self.push("action", &action_line(name, &input));
                        }
                        _ => {}
                    }
                }
                self.publish();
            }
            Some("result") => {
                if v.get("is_error").and_then(Value::as_bool) == Some(true) {
                    let why = v
                        .get("result")
                        .and_then(Value::as_str)
                        .or_else(|| v.get("subtype").and_then(Value::as_str))
                        .unwrap_or("échec");
                    self.push("error", why);
                }
                self.busy.store(false, Ordering::SeqCst);
                self.publish();
            }
            _ => {}
        }
    }

    async fn on_exit(&self, generation: u32) {
        let mut slot = self.proc.lock().await;
        // A process replaced by a newer one (reset, restart) ends without a
        // word: the request in flight, if any, is the newer one's.
        if self.generation.load(Ordering::SeqCst) != generation {
            return;
        }
        *slot = None;
        drop(slot);
        if self.busy.swap(false, Ordering::SeqCst) {
            self.push(
                "error",
                "le pilote s'est arrêté ; la prochaine demande le relance",
            );
            self.publish();
        }
    }

    /// Send one request. Its answer arrives through the log.
    pub async fn ask(self: &Arc<Self>, text: &str, clipboard: bool) -> Result<(), String> {
        if self.busy.load(Ordering::SeqCst) {
            return Err("le pilote est encore sur la demande précédente".into());
        }
        let stale = {
            let last = *lock(&self.last);
            last.elapsed() > MAX_IDLE || self.turns.load(Ordering::SeqCst) >= MAX_TURNS
        };
        if stale {
            self.stop().await;
        }

        let sessions = self.sessions.list();
        let context = tokio::task::spawn_blocking(move || context_block(&sessions, clipboard))
            .await
            .unwrap_or_default();
        let message = format!("{context}\n[demande]\n{text}");

        let mut slot = self.proc.lock().await;
        if slot.is_none() {
            self.spawn(&mut slot)?;
        }
        self.push("user", text);
        self.busy.store(true, Ordering::SeqCst);
        self.publish();

        let line = json!({
            "type": "user",
            "message": { "role": "user", "content": message },
        })
        .to_string()
            + "\n";
        let p = slot.as_mut().ok_or("pilote absent")?;
        if let Err(e) = p.stdin.write_all(line.as_bytes()).await {
            *slot = None;
            self.busy.store(false, Ordering::SeqCst);
            self.push("error", "le pilote ne répond plus ; réessaie");
            self.publish();
            return Err(format!("pilote : {e}"));
        }
        self.turns.fetch_add(1, Ordering::SeqCst);
        *lock(&self.last) = Instant::now();
        Ok(())
    }
}

/// What the pilot is told with every request.
fn context_block(sessions: &[super::Session], clipboard: bool) -> String {
    let mut out = vec!["[contexte]".to_string()];
    if let Ok(o) = std::process::Command::new("date")
        .arg("+%A %d %B %Y, %H:%M")
        .env("LC_TIME", "fr_FR.UTF-8")
        .output()
    {
        out.push(format!(
            "date : {}",
            String::from_utf8_lossy(&o.stdout).trim()
        ));
    }
    out.push(desk::desktop_state());
    if sessions.is_empty() {
        out.push("sessions Claude : aucune".into());
    } else {
        let list: Vec<String> = sessions
            .iter()
            .map(|s| {
                let state = match s.state {
                    super::State::Working => "travaille",
                    super::State::Waiting => "attend l'utilisateur",
                    super::State::Idle => "au repos",
                };
                format!("{} ({state})", s.project)
            })
            .collect();
        out.push(format!("sessions Claude : {}", list.join(", ")));
    }
    let projects: Vec<String> = super::runner::projects()
        .into_iter()
        .map(|p| p.name)
        .collect();
    out.push(format!("projets : {}", projects.join(", ")));
    if clipboard {
        let clip = std::process::Command::new("wl-paste")
            .args(["--no-newline", "--type", "text"])
            .output()
            .map(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .chars()
                    .take(4000)
                    .collect::<String>()
            })
            .unwrap_or_default();
        out.push(format!("[presse-papiers]\n{clip}"));
    }
    out.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn action_lines_name_the_tool_and_its_arguments() {
        assert_eq!(
            action_line("mcp__anna__volume", &json!({"pourcentage": 30})),
            "volume · 30"
        );
        assert_eq!(
            action_line("mcp__anna__etat_bureau", &json!({})),
            "etat_bureau"
        );
        assert_eq!(
            action_line("mcp__anna__lancer_session", &json!({"projet": "karenine"})),
            "lancer_session · karenine"
        );
    }
}
