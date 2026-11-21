//! The pilot: the assistant of the conversation bar, to which the user says
//! what they want of the desktop — "turn the sound down", "open Zed on
//! karenine" — or asks anything.
//!
//! anna runs the conversation itself: it speaks the Anthropic Messages API
//! (`POST /v1/messages`, streamed) to a model it is configured for — a local
//! one through Ollama (which serves that API), or a remote one with an API
//! key — and carries out the tools the model asks for. No agent runs beside
//! it: the tools are the desk tools (desk.rs), run by the daemon exactly as
//! `anna mcp` has them run (`desk` command), and nothing else.
//!
//! Each request carries a short context block (time, active window,
//! projects), built here at send time. The conversation is kept across
//! requests, then forgotten after a while (idle or many requests) to keep
//! it small. Nothing is written to disk but the configuration
//! (`~/.config/anna/pilot.json`, and the key in `pilot.key`).
//!
//! What the bar shows — the user's requests, the tool calls, the answers —
//! is kept here as a short log, pushed to `pilot_watch` subscribers whole on
//! every change.

use super::desk;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::broadcast;

/// Forget the conversation after this many requests, or this long without one.
const MAX_TURNS: u32 = 20;
const MAX_IDLE: Duration = Duration::from_secs(20 * 60);
/// Requests are commands, each on its own: the conversation is kept only
/// while the pilot waits for an answer to its question, or for a command
/// said this soon after the last one (« encore », « non, l'autre »).
const FOLLOW_UP: Duration = Duration::from_secs(45);
/// Model calls for one request at most (each tool round is one more).
const MAX_STEPS: usize = 16;
/// Messages kept in the conversation; older requests are dropped whole.
const MAX_MESSAGES: usize = 40;
/// A context block built ahead (`prepare`) is used if this recent.
const CONTEXT_FRESH: Duration = Duration::from_secs(5);
/// Entries kept in the log the bar shows.
const LOG_MAX: usize = 60;
/// Longest wait for the model's next words (a local model loading counts).
const READ_TIMEOUT: Duration = Duration::from_secs(300);
/// The Messages API revision spoken.
const API_VERSION: &str = "2023-06-01";
/// Tokens for one answer; with thinking, its budget comes on top.
const MAX_TOKENS: u32 = 4096;
const THINKING_BUDGET: u32 = 2048;

const PROMPT: &str = r#"Tu es {nom}, l'assistant intégré à l'interface de l'utilisateur (Hyprland sur NixOS). Il te parle depuis la barre de conversation en bas de l'écran (au clavier, ou à la voix en disant « {nom} »), souvent en quelques mots. Ta réponse s'affiche juste au-dessus de la barre.

Ce que tu fais :
- Tu agis sur le bureau avec tes outils : fenêtres et workspaces, son, luminosité, lecture média, applications, URL, projets, captures, couleur d'accent, notes du coffre Obsidian, l'agenda et les tâches Google, le métronome (`metronome` : lancer, arrêter, tempo et mesure, sans ouvrir de widget), les onglets du panneau de droite et les volets de la barre (`widget` : explorer, stats, agenda, lecteur, musique, claude, reglages ; son, micro, wifi, bluetooth, telephone, notifications, energie, alimentation, taches), et les réglages (`reglage` : thème, langue, voix, micro, sortie et entrée du son, Wi-Fi, Bluetooth, verrouiller, veille).
- L'agenda Google : `agenda` le lit (événements et tâches, avec leurs id) ; `evenement_creer`, `evenement_modifier`, `evenement_supprimer`, `tache_creer`, `tache_modifier`, `tache_supprimer` y écrivent. Pour modifier, déplacer ou supprimer, lis d'abord l'agenda pour trouver l'id ; pour déplacer un événement, donne seulement son nouveau `debut` (il garde sa durée). Écris les heures en heure locale (« 2026-11-20T14:00 »), en t'appuyant sur la date du [contexte]. Ne supprime que sur une demande claire, et dis ce que tu as supprimé.
- Tu réponds aussi à toutes ses questions, comme un assistant généraliste : culture, sciences, histoire, langue, définitions, explications, calculs et conversions, conseils, recettes… Réponds de ce que tu sais, sans le renvoyer ailleurs.
- Tu n'as pas de moteur de recherche. Pour lire une page dont tu as l'adresse, utilise `lire_page`. Pour ce qui change ou est récent (actualité, météo, horaires, prix, versions) et que tu ne sais pas avec certitude, dis-le franchement plutôt que d'inventer, et propose d'ouvrir une recherche dans le navigateur (`ouvrir_url`).
- Pour une question sur ce qui est affiché (« c'est quoi ça ? », « explique-moi cette erreur », « que dit cette page ? », « ici », « à l'écran »), regarde l'écran (`voir_ecran`) puis réponds à sa question à partir de ce que tu y vois. S'il parle d'une fenêtre précise (« regarde mon Firefox », « qu'est-ce qu'il y a dans Zed ? »), donne-la en `cible` : tu ne verras qu'elle. S'il te demande de décrire ce qui est affiché, décris-le : l'essentiel d'abord (quelle application, quel contenu), puis les détails utiles. Sinon, ne décris pas tout : réponds à ce qu'il demande. Ne dis que ce que tu vois vraiment sur l'image.
- Pour une question sur ce que l'utilisateur a déjà noté ou décidé, cherche d'abord dans ses notes (`chercher_notes`).
- Tu ne fais pas de travail de code sur ses projets : pour ça, propose d'ouvrir le projet (`ouvrir_projet`, dans Zed ou un terminal) et laisse l'utilisateur s'en charger. Expliquer une notion de programmation reste une question comme une autre.

Comment :
- Une demande d'action passe toujours par l'outil qui la fait : ne dis jamais qu'une chose est faite sans avoir appelé cet outil.
- Agis d'abord, puis confirme en une phrase courte (« Volume à 30 %. », « Zed ouvert sur karenine. »). Pas de préambule, pas de « bien sûr ».
- Une réponse à une question : directe, la réponse d'abord, puis l'essentiel ; quelques lignes suffisent le plus souvent, une quinzaine au plus si le sujet l'exige. Markdown si utile (listes, gras), pas de titres.
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

// ── Configuration ───────────────────────────────────────────────────────────

/// Which model the pilot talks to. Both providers speak the Messages API;
/// they differ in their defaults, how their models are listed, and the key.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(default)]
pub struct Config {
    /// "ollama" (a local model, no key) or "anthropic" (an API with a key).
    pub provider: String,
    /// The API's base address, without `/v1`.
    pub url: String,
    pub model: String,
    /// Let the model think before answering (slower, sometimes better).
    pub think: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            provider: "ollama".into(),
            url: OLLAMA_URL.into(),
            // Measured on the 32 tools (21/11/2026, RTX 3070): without
            // thinking, qwen3.5:9b called the tool asked for 5 times in 18
            // and claimed the rest done; qwen3.5:4b, 36 in 36, in 0.6 s.
            model: "qwen3.5:4b".into(),
            think: false,
        }
    }
}

pub const OLLAMA_URL: &str = "http://localhost:11434";
pub const ANTHROPIC_URL: &str = "https://api.anthropic.com";

fn config_path() -> PathBuf {
    crate::paths::home_dir().join(".config/anna/pilot.json")
}
fn key_path() -> PathBuf {
    crate::paths::home_dir().join(".config/anna/pilot.key")
}

impl Config {
    pub fn load() -> Config {
        let mut c: Config = std::fs::read_to_string(config_path())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        c.normalize();
        c
    }

    /// An unknown provider falls back on Ollama; an empty address on the
    /// provider's own.
    fn normalize(&mut self) {
        if self.provider != "anthropic" {
            self.provider = "ollama".into();
        }
        self.url = self.url.trim().trim_end_matches('/').to_string();
        if let Some(stripped) = self.url.strip_suffix("/v1") {
            self.url = stripped.to_string();
        }
        if self.url.is_empty() {
            self.url = if self.provider == "anthropic" { ANTHROPIC_URL } else { OLLAMA_URL }.into();
        }
        self.model = self.model.trim().to_string();
    }

    fn save(&self) -> Result<(), String> {
        let p = config_path();
        if let Some(dir) = p.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        std::fs::write(&p, text + "\n").map_err(|e| format!("{} : {e}", p.display()))
    }
}

/// The API key: `ANNA_PILOT_API_KEY`, or the file written from the settings
/// (readable by the user alone).
fn api_key() -> Option<String> {
    std::env::var("ANNA_PILOT_API_KEY")
        .ok()
        .or_else(|| std::fs::read_to_string(key_path()).ok())
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
}

fn save_key(key: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let p = key_path();
    if key.trim().is_empty() {
        return match std::fs::remove_file(&p) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
            _ => Ok(()),
        };
    }
    if let Some(dir) = p.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&p)
        .map_err(|e| format!("{} : {e}", p.display()))?;
    // An existing file keeps its mode: made private here too.
    use std::os::unix::fs::PermissionsExt;
    let _ = f.set_permissions(std::fs::Permissions::from_mode(0o600));
    f.write_all(key.trim().as_bytes()).map_err(|e| e.to_string())
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(5))
        .timeout_read(READ_TIMEOUT)
        .build()
}

/// The error an API sent back, in its words when it gave some.
fn http_error(e: ureq::Error) -> String {
    match e {
        ureq::Error::Status(code, resp) => {
            let body = resp.into_string().unwrap_or_default();
            let msg = serde_json::from_str::<Value>(&body)
                .ok()
                .and_then(|v| {
                    v.pointer("/error/message")
                        .or_else(|| v.get("error"))
                        .and_then(Value::as_str)
                        .map(str::to_string)
                })
                .unwrap_or_else(|| body.chars().take(200).collect());
            format!("{code} : {msg}")
        }
        ureq::Error::Transport(t) => t.to_string(),
    }
}

/// The models the configured provider offers: Ollama's installed models, or
/// the API's list (with the key).
pub fn list_models(c: &Config) -> Result<Vec<String>, String> {
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(6))
        .build();
    let text = if c.provider == "ollama" {
        agent.get(&format!("{}/api/tags", c.url)).call()
    } else {
        let mut req = agent
            .get(&format!("{}/v1/models?limit=100", c.url))
            .set("anthropic-version", API_VERSION);
        if let Some(k) = api_key() {
            req = req.set("x-api-key", &k);
        }
        req.call()
    }
    .map_err(http_error)?
    .into_string()
    .map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let (list, field) = if c.provider == "ollama" { ("models", "name") } else { ("data", "id") };
    Ok(v.get(list)
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|m| m.get(field).and_then(Value::as_str).map(str::to_string))
                .collect()
        })
        .unwrap_or_default())
}

/// The configuration as the settings show it (never the key itself).
pub fn config_line() -> Value {
    let c = Config::load();
    let models = list_models(&c);
    json!({
        "ok": true,
        "config": c,
        "has_key": api_key().is_some(),
        "models": models.as_ref().cloned().unwrap_or_default(),
        "error": models.err(),
    })
}

// ── The streamed answer ─────────────────────────────────────────────────────

/// What a streamed event changes for the bar.
#[derive(Debug, PartialEq)]
enum Update {
    /// More words of the answer (the first ones start a new entry).
    Text(String),
    /// The answer's text block is over.
    TextEnd,
    /// A tool call, its arguments complete.
    Tool(String, Value),
}

/// One answer, assembled from its stream of events (`content_block_*`): the
/// content blocks as they are to be sent back, and why it stopped.
#[derive(Default)]
struct Message {
    blocks: Vec<Value>,
    /// A tool call's arguments, as their JSON comes in pieces.
    partial_json: String,
    stop_reason: String,
    error: Option<String>,
}

impl Message {
    fn feed(&mut self, event: &Value) -> Vec<Update> {
        let mut out = Vec::new();
        match event.get("type").and_then(Value::as_str) {
            Some("content_block_start") => {
                let mut block = event.get("content_block").cloned().unwrap_or(Value::Null);
                if block.get("type").and_then(Value::as_str) == Some("text") {
                    // Its text comes in the deltas.
                    block["text"] = json!("");
                }
                self.partial_json.clear();
                self.blocks.push(block);
            }
            Some("content_block_delta") => {
                let Some(block) = self.blocks.last_mut() else {
                    return out;
                };
                let delta = event.get("delta").cloned().unwrap_or(Value::Null);
                let piece = |k: &str| delta.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                match delta.get("type").and_then(Value::as_str) {
                    Some("text_delta") => {
                        let p = piece("text");
                        if let Some(Value::String(t)) = block.get_mut("text") {
                            t.push_str(&p);
                        }
                        out.push(Update::Text(p));
                    }
                    Some("input_json_delta") => self.partial_json.push_str(&piece("partial_json")),
                    Some("thinking_delta") => {
                        let p = piece("thinking");
                        match block.get_mut("thinking") {
                            Some(Value::String(t)) => t.push_str(&p),
                            _ => block["thinking"] = json!(p),
                        }
                    }
                    Some("signature_delta") => block["signature"] = json!(piece("signature")),
                    _ => {}
                }
            }
            Some("content_block_stop") => {
                let Some(block) = self.blocks.last_mut() else {
                    return out;
                };
                match block.get("type").and_then(Value::as_str) {
                    Some("text") => out.push(Update::TextEnd),
                    Some("tool_use") => {
                        if !self.partial_json.trim().is_empty() {
                            block["input"] = serde_json::from_str(&self.partial_json)
                                .unwrap_or_else(|_| json!({}));
                        }
                        if !block.get("input").is_some_and(Value::is_object) {
                            block["input"] = json!({});
                        }
                        let name = block.get("name").and_then(Value::as_str).unwrap_or("");
                        out.push(Update::Tool(name.to_string(), block["input"].clone()));
                    }
                    _ => {}
                }
                self.partial_json.clear();
            }
            Some("message_delta") => {
                if let Some(r) = event.pointer("/delta/stop_reason").and_then(Value::as_str) {
                    self.stop_reason = r.to_string();
                }
            }
            Some("error") => {
                self.error = Some(
                    event
                        .pointer("/error/message")
                        .and_then(Value::as_str)
                        .unwrap_or("erreur")
                        .to_string(),
                );
            }
            _ => {}
        }
        out
    }

    /// The blocks to keep in the conversation: empty texts and unsigned
    /// thinking (a local model's, which no API wants back) are left out.
    fn kept(&self) -> Vec<Value> {
        self.blocks
            .iter()
            .filter(|b| match b.get("type").and_then(Value::as_str) {
                Some("text") => b
                    .get("text")
                    .and_then(Value::as_str)
                    .is_some_and(|t| !t.trim().is_empty()),
                Some("thinking") => b
                    .get("signature")
                    .and_then(Value::as_str)
                    .is_some_and(|s| !s.is_empty()),
                Some("tool_use") => true,
                _ => false,
            })
            .cloned()
            .collect()
    }

    fn tool_calls(&self) -> Vec<(String, String, Value)> {
        self.blocks
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_use"))
            .map(|b| {
                let s = |k: &str| b.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                (s("id"), s("name"), b.get("input").cloned().unwrap_or(json!({})))
            })
            .collect()
    }
}

/// The desk tools, as the Messages API takes them.
fn api_tools() -> Vec<Value> {
    desk::tools()
        .as_array()
        .map(|a| {
            a.iter()
                .map(|t| {
                    json!({
                        "name": t["name"],
                        "description": t["description"],
                        "input_schema": t["inputSchema"],
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Once a request is answered, the screenshots it took leave the
/// conversation (each costs a thousand tokens or more, and a local model's
/// context is small): their line of text stays, saying what was seen.
fn drop_images(history: &mut [Value]) {
    for m in history.iter_mut() {
        let Some(blocks) = m.get_mut("content").and_then(Value::as_array_mut) else {
            continue;
        };
        for b in blocks.iter_mut() {
            if let Some(inner) = b.get_mut("content").and_then(Value::as_array_mut) {
                inner.retain(|c| c.get("type").and_then(Value::as_str) != Some("image"));
            }
        }
    }
}

/// Drop the oldest requests, whole, until the conversation fits: it always
/// starts on a request (a user message with text, not tool results).
fn trim_history(history: &mut Vec<Value>) {
    while history.len() > MAX_MESSAGES {
        history.remove(0);
        while history
            .first()
            .is_some_and(|m| !(m["role"] == "user" && m["content"].is_string()))
        {
            history.remove(0);
        }
    }
}

// ── The pilot ───────────────────────────────────────────────────────────────

pub struct Pilot {
    /// Bumped on every reset: a request still running for an older one
    /// ends without a word.
    generation: AtomicU32,
    busy: AtomicBool,
    /// The last answer was a question: the next request answers it.
    asking: AtomicBool,
    /// A text block is streaming into the log's last entry.
    in_text: AtomicBool,
    turns: AtomicU32,
    last: Mutex<Instant>,
    /// The conversation, as the Messages API takes it.
    history: Mutex<Vec<Value>>,
    /// The context block built ahead (`prepare`), and when.
    context: Mutex<Option<(Instant, tokio::task::JoinHandle<String>)>>,
    /// When a local model was last asked to load (`prewarm`).
    warmed: Mutex<Option<Instant>>,
    log: Mutex<VecDeque<Value>>,
    tx: broadcast::Sender<String>,
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
    pub fn new() -> Arc<Self> {
        let (tx, _) = broadcast::channel(32);
        Arc::new(Pilot {
            generation: AtomicU32::new(0),
            busy: AtomicBool::new(false),
            asking: AtomicBool::new(false),
            in_text: AtomicBool::new(false),
            turns: AtomicU32::new(0),
            last: Mutex::new(Instant::now()),
            history: Mutex::new(Vec::new()),
            context: Mutex::new(None),
            warmed: Mutex::new(None),
            log: Mutex::new(VecDeque::new()),
            tx,
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

    /// Forget the conversation; a request still running is dropped.
    pub async fn reset(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.forget();
        lock(&self.log).clear();
        self.in_text.store(false, Ordering::SeqCst);
        self.busy.store(false, Ordering::SeqCst);
        self.publish();
    }

    fn forget(&self) {
        lock(&self.history).clear();
        self.turns.store(0, Ordering::SeqCst);
    }

    /// The conversation starts over: a new command (no question pending,
    /// not a quick follow-up), or too many requests.
    fn stale(&self) -> bool {
        let idle = lock(&self.last).elapsed();
        let asking = self.asking.swap(false, Ordering::SeqCst);
        idle > MAX_IDLE
            || (!asking && idle > FOLLOW_UP)
            || self.turns.load(Ordering::SeqCst) >= MAX_TURNS
    }

    /// A request is about to come (the user starts speaking): a local model
    /// is asked to load now, so that it doesn't wait for it. At most every
    /// few minutes; an API has nothing to load.
    pub async fn prewarm(self: &Arc<Self>) {
        if self.busy.load(Ordering::SeqCst) {
            return;
        }
        let c = Config::load();
        if c.provider != "ollama" || c.model.is_empty() {
            return;
        }
        {
            let mut warmed = lock(&self.warmed);
            if warmed.is_some_and(|t| t.elapsed() < Duration::from_secs(240)) {
                return;
            }
            *warmed = Some(Instant::now());
        }
        // An empty prompt only loads the model (Ollama's own API).
        tokio::task::spawn_blocking(move || {
            let _ = agent()
                .post(&format!("{}/api/generate", c.url))
                .set("content-type", "application/json")
                .send_string(&json!({ "model": c.model, "keep_alive": "30m" }).to_string());
        });
    }

    /// Build the context block now, for a request about to come (the voice,
    /// once the user goes quiet). Must run inside the runtime.
    pub fn prepare(&self) {
        let job = tokio::task::spawn_blocking(|| context_block(false));
        *lock(&self.context) = Some((Instant::now(), job));
    }

    /// Send one request. Its answer arrives through the log.
    pub async fn ask(self: &Arc<Self>, text: &str, clipboard: bool) -> Result<(), String> {
        if self.busy.swap(true, Ordering::SeqCst) {
            return Err(crate::i18n::tr("pilot.busy"));
        }
        if self.stale() {
            self.forget();
            // The shell shows the log as the conversation: it starts over too.
            lock(&self.log).clear();
        }

        // Built ahead a moment ago, or now.
        let prepared = lock(&self.context)
            .take()
            .filter(|(at, _)| !clipboard && at.elapsed() < CONTEXT_FRESH)
            .map(|(_, job)| job);
        let job = prepared
            .unwrap_or_else(|| tokio::task::spawn_blocking(move || context_block(clipboard)));
        let context = job.await.unwrap_or_default();
        let message = format!("{context}\n[demande]\n{text}");

        self.push("user", text);
        self.in_text.store(false, Ordering::SeqCst);
        self.publish();
        self.turns.fetch_add(1, Ordering::SeqCst);
        *lock(&self.last) = Instant::now();

        let generation = self.generation.load(Ordering::SeqCst);
        let me = Arc::clone(self);
        let started = Instant::now();
        // The HTTP client and the desk calls block: a thread of its own.
        std::thread::spawn(move || {
            let result = me.converse(generation, message);
            if me.generation.load(Ordering::SeqCst) != generation {
                return;
            }
            eprintln!("anna: pilote : {:.1} s", started.elapsed().as_secs_f32());
            if let Err(e) = result {
                me.close_text();
                me.push("error", &e);
            }
            // Ended on a question: the next request is its answer.
            let asked = lock(&me.log).back().is_some_and(|e| {
                e["kind"] == "reply"
                    && e["text"]
                        .as_str()
                        .is_some_and(|t| t.trim_end().ends_with('?'))
            });
            me.asking.store(asked, Ordering::SeqCst);
            me.busy.store(false, Ordering::SeqCst);
            me.publish();
        });
        Ok(())
    }

    /// The answer's text entry, if one is growing, is over.
    fn close_text(&self) {
        if self.in_text.swap(false, Ordering::SeqCst) {
            let mut log = lock(&self.log);
            if let Some(Value::String(text)) = log.back_mut().and_then(|e| e.get_mut("text")) {
                let end = text.trim_end().len();
                text.truncate(end);
            }
        }
    }

    fn show(&self, update: Update) {
        match update {
            Update::Text(piece) => {
                if self.in_text.load(Ordering::SeqCst) {
                    let mut log = lock(&self.log);
                    if let Some(Value::String(text)) = log.back_mut().and_then(|e| e.get_mut("text"))
                    {
                        text.push_str(&piece);
                    }
                } else {
                    // Nothing shown before the first words.
                    let piece = piece.trim_start();
                    if piece.is_empty() {
                        return;
                    }
                    self.push("reply", piece);
                    self.in_text.store(true, Ordering::SeqCst);
                }
            }
            Update::TextEnd => self.close_text(),
            Update::Tool(name, input) => {
                self.close_text();
                self.push("action", &action_line(&name, &input));
            }
        }
        self.publish();
    }

    /// One request, to its answer: the model is called again with the
    /// results of the tools it asked for, until it answers in words.
    fn converse(&self, generation: u32, message: String) -> Result<(), String> {
        let c = Config::load();
        if c.model.is_empty() {
            return Err(crate::i18n::tr("pilot.no_model"));
        }
        let key = api_key();
        if c.provider == "anthropic" && key.is_none() {
            return Err(crate::i18n::tr("pilot.no_key"));
        }

        let mut system = PROMPT.replace("{nom}", super::wake::WakeWord::current().display.as_str());
        if let Some(p) = preferences() {
            system.push_str("\n\nPréférences de l'utilisateur :\n");
            system.push_str(&p);
        }
        let tools = api_tools();
        let agent = agent();
        let current = || self.generation.load(Ordering::SeqCst) == generation;

        let mut messages = {
            let mut h = lock(&self.history);
            h.push(json!({ "role": "user", "content": message }));
            trim_history(&mut h);
            h.clone()
        };

        for _ in 0..MAX_STEPS {
            let mut body = json!({
                "model": c.model,
                "max_tokens": MAX_TOKENS,
                "system": system,
                "messages": messages,
                "tools": tools,
                "stream": true,
            });
            if c.think {
                body["max_tokens"] = json!(MAX_TOKENS + THINKING_BUDGET);
                body["thinking"] = json!({ "type": "enabled", "budget_tokens": THINKING_BUDGET });
            } else {
                body["thinking"] = json!({ "type": "disabled" });
            }
            let mut req = agent
                .post(&format!("{}/v1/messages", c.url))
                .set("anthropic-version", API_VERSION)
                .set("content-type", "application/json");
            if let Some(k) = &key {
                req = req.set("x-api-key", k);
            }
            let resp = req.send_string(&body.to_string()).map_err(|e| {
                crate::i18n::tr_args("pilot.api_error", &[("error", &http_error(e))])
            })?;

            // Server-sent events: the JSON of each event on its `data:` line.
            let mut answer = Message::default();
            for line in BufReader::new(resp.into_reader()).lines() {
                let line = line.map_err(|e| e.to_string())?;
                if !current() {
                    return Ok(());
                }
                let Some(data) = line.strip_prefix("data:") else {
                    continue;
                };
                let Ok(event) = serde_json::from_str::<Value>(data.trim()) else {
                    continue;
                };
                for u in answer.feed(&event) {
                    self.show(u);
                }
                if event.get("type").and_then(Value::as_str) == Some("message_stop") {
                    break;
                }
            }
            self.close_text();
            if let Some(e) = answer.error {
                return Err(crate::i18n::tr_args("pilot.api_error", &[("error", &e)]));
            }

            let kept = answer.kept();
            if !kept.is_empty() {
                messages.push(json!({ "role": "assistant", "content": kept }));
            }
            let calls = answer.tool_calls();
            if answer.stop_reason != "tool_use" || calls.is_empty() {
                if answer.stop_reason == "max_tokens" {
                    self.push("error", &crate::i18n::tr("pilot.truncated"));
                }
                drop_images(&mut messages);
                *lock(&self.history) = messages;
                return Ok(());
            }

            // The tools asked for, one after the other, through the daemon
            // (as `anna mcp` has them run).
            let mut results = Vec::new();
            for (id, name, input) in calls {
                if !current() {
                    return Ok(());
                }
                let (ok, text, image) = super::mcp::call_daemon(&name, &input);
                let mut content = vec![json!({ "type": "text", "text": if text.is_empty() { "ok".into() } else { text } })];
                if let Some(data) = image {
                    content.push(json!({ "type": "image", "source": {
                        "type": "base64", "media_type": "image/jpeg", "data": data } }));
                }
                results.push(json!({
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": content,
                    "is_error": !ok,
                }));
            }
            messages.push(json!({ "role": "user", "content": results }));
        }
        drop_images(&mut messages);
        *lock(&self.history) = messages;
        Err(crate::i18n::tr("pilot.too_many_steps"))
    }

    /// New settings: saved, and the conversation starts over with them.
    /// `key`: None keeps it, "" removes it.
    pub async fn configure(&self, mut c: Config, key: Option<String>) -> Result<(), String> {
        c.normalize();
        c.save()?;
        if let Some(k) = key {
            save_key(&k)?;
        }
        *lock(&self.warmed) = None;
        self.reset().await;
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

    fn ev(s: &str) -> Value {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn a_streamed_answer_is_assembled() {
        let mut m = Message::default();
        let mut shown = Vec::new();
        for e in [
            r#"{"type":"message_start","message":{"content":[]}}"#,
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Je baisse"}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" le son."}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"volume","input":{}}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"pourcen"}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"tage\": 30}"}}"#,
            r#"{"type":"content_block_stop","index":1}"#,
            r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            r#"{"type":"message_stop"}"#,
        ] {
            shown.extend(m.feed(&ev(e)));
        }
        assert_eq!(
            shown,
            vec![
                Update::Text("Je baisse".into()),
                Update::Text(" le son.".into()),
                Update::TextEnd,
                Update::Tool("volume".into(), json!({"pourcentage": 30})),
            ]
        );
        assert_eq!(m.stop_reason, "tool_use");
        assert_eq!(
            m.tool_calls(),
            vec![("t1".into(), "volume".into(), json!({"pourcentage": 30}))]
        );
        assert_eq!(
            m.kept(),
            vec![
                json!({"type": "text", "text": "Je baisse le son."}),
                json!({"type": "tool_use", "id": "t1", "name": "volume", "input": {"pourcentage": 30}}),
            ]
        );
    }

    #[test]
    fn a_tool_without_arguments_gets_an_empty_object() {
        let mut m = Message::default();
        m.feed(&ev(r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t","name":"etat_bureau"}}"#));
        let shown = m.feed(&ev(r#"{"type":"content_block_stop","index":0}"#));
        assert_eq!(shown, vec![Update::Tool("etat_bureau".into(), json!({}))]);
    }

    #[test]
    fn unsigned_thinking_is_not_sent_back() {
        let mut m = Message::default();
        for e in [
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            r#"{"type":"content_block_stop","index":0}"#,
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"thinking","thinking":""}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"thinking_delta","thinking":"ok"}}"#,
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            r#"{"type":"content_block_stop","index":1}"#,
        ] {
            assert!(m.feed(&ev(e)).is_empty());
        }
        assert_eq!(
            m.kept(),
            vec![json!({"type": "thinking", "thinking": "ok", "signature": "sig"})]
        );
    }

    #[test]
    fn an_error_event_is_kept() {
        let mut m = Message::default();
        m.feed(&ev(r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#));
        assert_eq!(m.error.as_deref(), Some("Overloaded"));
    }

    #[test]
    fn the_history_is_trimmed_by_whole_requests() {
        let mut h = Vec::new();
        for i in 0..30 {
            h.push(json!({ "role": "user", "content": format!("demande {i}") }));
            h.push(json!({ "role": "assistant", "content": [{"type": "tool_use", "id": "x", "name": "n", "input": {}}] }));
            h.push(json!({ "role": "user", "content": [{"type": "tool_result", "tool_use_id": "x", "content": "ok"}] }));
        }
        trim_history(&mut h);
        assert!(h.len() <= MAX_MESSAGES);
        assert!(h[0]["content"].is_string());
    }

    #[test]
    fn answered_screenshots_leave_the_conversation() {
        let mut h = vec![
            json!({ "role": "user", "content": "regarde" }),
            json!({ "role": "user", "content": [{ "type": "tool_result", "tool_use_id": "c",
                "content": [{ "type": "text", "text": "fenêtre firefox" },
                            { "type": "image", "source": { "type": "base64", "data": "AA" } }] }] }),
        ];
        drop_images(&mut h);
        assert_eq!(h[1]["content"][0]["content"], json!([{ "type": "text", "text": "fenêtre firefox" }]));
        assert_eq!(h[0]["content"], "regarde");
    }

    #[test]
    fn tools_take_the_api_shape_and_legal_names() {
        let tools = api_tools();
        assert!(tools.len() > 10);
        for t in &tools {
            let name = t["name"].as_str().unwrap();
            assert!(
                !name.is_empty()
                    && name.len() <= 64
                    && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-'),
                "{name}"
            );
            assert_eq!(t["input_schema"]["type"], "object");
        }
    }

    #[test]
    fn the_configuration_falls_back_on_sane_defaults() {
        let mut c = Config { provider: "x".into(), url: " http://h:1/v1/ ".into(), model: " m ".into(), think: false };
        c.normalize();
        assert_eq!((c.provider.as_str(), c.url.as_str(), c.model.as_str()), ("ollama", "http://h:1", "m"));
        let mut c = Config { provider: "anthropic".into(), url: "".into(), ..Config::default() };
        c.normalize();
        assert_eq!(c.url, ANTHROPIC_URL);
    }

    #[test]
    fn action_lines_name_the_tool_and_its_arguments() {
        assert_eq!(action_line("volume", &json!({"pourcentage": 30})), "volume · 30");
        assert_eq!(action_line("etat_bureau", &json!({})), "etat_bureau");
        assert_eq!(
            action_line("ouvrir_projet", &json!({"projet": "karenine"})),
            "ouvrir_projet · karenine"
        );
    }
}
