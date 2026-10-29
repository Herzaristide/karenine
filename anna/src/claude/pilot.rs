//! The pilot: a Claude session anna keeps warm, to which the conversation
//! bar sends what the user asks of the desktop — "turn the sound down",
//! "open Zed on karenine".
//!
//! It acts through the desk tools only (`anna mcp`, see desk.rs): Claude
//! Code's own tools are off, and so are the user's settings — no hooks, no
//! journal, no other MCP server — which keeps it quick to start and its
//! reach exactly what desk.rs allows. It never starts a Claude Code session:
//! code and research stay with the user.
//!
//! Each request carries a short context block (time, active window,
//! projects), built here at send time. The process lives across requests so
//! a request costs no start-up; it is restarted after a while (idle or many
//! turns) to keep its context small. Nothing is written to disk.
//!
//! What the bar shows — the user's requests, the tool calls, the answers —
//! is kept here as a short log, pushed to `pilot_watch` subscribers whole on
//! every change. The answers are also handed to the speech as they stream
//! (speech.rs), which reads them aloud or not.

use super::desk;
use super::speech::Speech;
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
/// Entries kept in the log the bar shows.
const LOG_MAX: usize = 60;

const PROMPT: &str = r#"Tu es le pilote du bureau de l'utilisateur : un assistant intégré à son interface (Hyprland sur NixOS). Il te parle depuis la barre de conversation en bas de l'écran (au clavier, ou à la voix en disant « Karénine »), souvent en quelques mots. Ta réponse s'affiche juste au-dessus de la barre.

Ce que tu fais :
- Tu agis sur le bureau avec tes outils : fenêtres et workspaces, son, luminosité, lecture média, applications, URL, projets, captures, couleur d'accent, notes du coffre Obsidian et notes rapides, agenda (`agenda`, en lecture), et les widgets de l'interface (`widget` : stats, notes, agenda, lecteur, musique (métronome et accordeur), son, caméra, réglages).
- Tu ne fais pas de travail de code ni de recherche approfondie, et tu ne lances pas de session Claude Code : pour ça, propose d'ouvrir le projet (`ouvrir_projet`, dans Zed ou un terminal) et laisse l'utilisateur s'en charger.
- Tu réponds directement aux questions courtes. Pour une question sur ce que l'utilisateur a déjà noté ou décidé, cherche d'abord dans ses notes (`chercher_notes`).

Comment :
- Agis d'abord, puis confirme en une phrase courte (« Volume à 30 %. », « Zed ouvert sur karenine. »). Pas de préambule, pas de « bien sûr ».
- Une réponse à une question : six lignes au plus, en markdown si utile.
- Ne change pas la fenêtre ou le workspace affichés sauf si on te le demande : l'utilisateur est peut-être en train de travailler.
- Si la demande est ambiguë (quelle fenêtre ? quel projet ?), pose une seule question courte au lieu de deviner. `etat_bureau` te montre ce qui est ouvert.
- Fermer une fenêtre et lancer une commande shell s'exécutent sans confirmation : ne le fais que si la demande est claire. Tu ne reconstruis jamais le système NixOS : c'est à l'utilisateur de le faire.
- `commande` est un dernier recours, quand aucun autre outil ne convient.

Chaque demande commence par un bloc [contexte] (heure, fenêtre active, projets) : sers-t'en, ne le recopie pas."#;

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
    /// A text block is streaming into the log's last entry.
    in_text: AtomicBool,
    /// The current message's text came streamed: its final copy is skipped.
    streamed: AtomicBool,
    turns: AtomicU32,
    last: Mutex<Instant>,
    log: Mutex<VecDeque<Value>>,
    tx: broadcast::Sender<String>,
    speech: Arc<Speech>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// One line saying what a tool call does, for the bar.
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
    pub fn new(speech: Arc<Speech>) -> Arc<Self> {
        let (tx, _) = broadcast::channel(32);
        Arc::new(Pilot {
            proc: AsyncMutex::new(None),
            generation: AtomicU32::new(0),
            busy: AtomicBool::new(false),
            in_text: AtomicBool::new(false),
            streamed: AtomicBool::new(false),
            turns: AtomicU32::new(0),
            last: Mutex::new(Instant::now()),
            log: Mutex::new(VecDeque::new()),
            tx,
            speech,
        })
    }

    pub fn speech(&self) -> &Arc<Speech> {
        &self.speech
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
        self.speech.stop();
        self.stop().await;
        lock(&self.log).clear();
        self.in_text.store(false, Ordering::SeqCst);
        self.busy.store(false, Ordering::SeqCst);
        self.publish();
    }

    async fn stop(&self) {
        if let Some(p) = self.proc.lock().await.take() {
            let _ = tokio::process::Command::new("kill")
                .args(["-TERM", &p.pid.to_string()])
                .status()
                .await;
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
                // The reply shows up word by word, not once it is whole.
                "--include-partial-messages",
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
                        // Already in the log, streamed piece by piece.
                        Some("text") if self.streamed.load(Ordering::SeqCst) => {}
                        Some("text") => {
                            let t = b.get("text").and_then(Value::as_str).unwrap_or("").trim();
                            if !t.is_empty() {
                                self.push("reply", t);
                                self.speech.feed(t);
                                self.speech.flush();
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
                        .map(str::to_string)
                        .unwrap_or_else(|| crate::i18n::tr("failed"));
                    self.push("error", &why);
                }
                self.speech.end();
                self.busy.store(false, Ordering::SeqCst);
                self.publish();
            }
            Some("stream_event") => {
                if let Some(event) = v.get("event") {
                    self.on_stream(event);
                }
            }
            _ => {}
        }
    }

    /// A piece of the message being written (`--include-partial-messages`):
    /// the reply grows in the log's last entry as the text comes.
    fn on_stream(&self, event: &Value) {
        match event.get("type").and_then(Value::as_str) {
            Some("message_start") => {
                self.streamed.store(false, Ordering::SeqCst);
                self.in_text.store(false, Ordering::SeqCst);
            }
            Some("content_block_delta") => {
                if event.pointer("/delta/type").and_then(Value::as_str) != Some("text_delta") {
                    return;
                }
                let piece = event
                    .pointer("/delta/text")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if self.in_text.load(Ordering::SeqCst) {
                    let mut log = lock(&self.log);
                    if let Some(Value::String(text)) =
                        log.back_mut().and_then(|e| e.get_mut("text"))
                    {
                        text.push_str(piece);
                    }
                    drop(log);
                    self.speech.feed(piece);
                } else {
                    // Nothing shown before the first words.
                    let piece = piece.trim_start();
                    if piece.is_empty() {
                        return;
                    }
                    self.push("reply", piece);
                    self.in_text.store(true, Ordering::SeqCst);
                    self.streamed.store(true, Ordering::SeqCst);
                    self.speech.feed(piece);
                }
                self.publish();
            }
            Some("content_block_stop") if self.in_text.swap(false, Ordering::SeqCst) => {
                let mut log = lock(&self.log);
                if let Some(Value::String(text)) = log.back_mut().and_then(|e| e.get_mut("text")) {
                    let end = text.trim_end().len();
                    text.truncate(end);
                }
                drop(log);
                self.speech.flush();
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
            self.speech.end();
            self.push("error", &crate::i18n::tr("pilot.stopped"));
            self.publish();
        }
    }

    /// Send one request. Its answer arrives through the log. `spoken`: it
    /// was said, not typed (the answer may then be read aloud).
    pub async fn ask(
        self: &Arc<Self>,
        text: &str,
        clipboard: bool,
        spoken: bool,
    ) -> Result<(), String> {
        if self.busy.load(Ordering::SeqCst) {
            return Err(crate::i18n::tr("pilot.busy"));
        }
        // A new request silences the last answer.
        let aloud = self.speech.begin(spoken);
        let stale = {
            let last = *lock(&self.last);
            last.elapsed() > MAX_IDLE || self.turns.load(Ordering::SeqCst) >= MAX_TURNS
        };
        if stale {
            self.stop().await;
        }

        let context = tokio::task::spawn_blocking(move || context_block(clipboard))
            .await
            .unwrap_or_default();
        let aloud = if aloud {
            "\nréponse lue à voix haute : phrases courtes, sans markdown, sans liste ni code\n"
        } else {
            "\n"
        };
        let message = format!("{context}{aloud}[demande]\n{text}");

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
            self.push("error", &crate::i18n::tr("pilot.no_answer"));
            self.publish();
            return Err(format!("pilote : {e}"));
        }
        self.turns.fetch_add(1, Ordering::SeqCst);
        *lock(&self.last) = Instant::now();
        Ok(())
    }
}

/// What the pilot is told with every request.
fn context_block(clipboard: bool) -> String {
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
    out.push(crate::i18n::pilot_language_line());
    out.push(desk::desktop_state());
    let projects: Vec<String> = super::desk::projects()
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

    #[tokio::test]
    async fn a_streamed_reply_grows_in_one_entry() {
        let pilot = Pilot::new(Speech::new());
        let delta = |t: &str| {
            json!({ "type": "stream_event", "event": { "type": "content_block_delta",
                "delta": { "type": "text_delta", "text": t } } })
            .to_string()
        };
        pilot.on_event(r#"{"type":"stream_event","event":{"type":"message_start"}}"#);
        pilot.on_event(&delta(" Volume"));
        pilot.on_event(&delta(" à 30 %. "));
        // The whole message, as the CLI sends it before the block's end.
        pilot.on_event(
            r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Volume à 30 %."}]}}"#,
        );
        pilot.on_event(r#"{"type":"stream_event","event":{"type":"content_block_stop"}}"#);
        let log: Vec<Value> = lock(&pilot.log).iter().cloned().collect();
        assert_eq!(
            log,
            vec![json!({ "kind": "reply", "text": "Volume à 30 %." })]
        );
    }

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
            action_line("mcp__anna__ouvrir_projet", &json!({"projet": "karenine"})),
            "ouvrir_projet · karenine"
        );
    }
}
