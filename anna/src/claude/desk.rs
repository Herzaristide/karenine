//! What the pilot can do on the desktop: its tools, as `anna mcp` serves them
//! to Claude Code, and how anna carries each one out.
//!
//! Every call lands in the daemon (`desk` command), never in the MCP process:
//! the daemon owns the sessions, the theme and the bar, and is the one place
//! that asks the user before anything that can't be undone. The tools that
//! do (`SENSITIVE`) wait for a yes in the dock (see permission.rs).
//!
//! Hyprland is driven through its Lua dispatchers — the only syntax its Lua
//! configuration accepts (see gesture/output.rs). Only forms whose arguments
//! are known are used: some dispatchers ignore unknown arguments and run
//! anyway.

use serde_json::{json, Value};
use std::process::{Command, Stdio};
use std::time::Duration;

/// Tools that need the user's yes, every time.
pub const SENSITIVE: [&str; 3] = ["fermer_fenetre", "commande", "reconstruire_nixos"];

/// Longest output handed back to the model (characters).
const OUTPUT_MAX: usize = 4000;

/// The shell's widgets (services/Widgets.qml), plus « tout ».
const WIDGETS: [&str; 12] = [
    "explorer",
    "stats",
    "telephone",
    "notifications",
    "notes",
    "lecteur",
    "musique",
    "son",
    "camera",
    "reglages",
    "sessions",
    "tout",
];

/// The shell's command FIFO (shell.qml), where widgets are opened.
const SHELL_FIFO: &str = "/tmp/qs-panel.fifo";

/// O_NONBLOCK: opening the FIFO fails at once when the shell isn't reading
/// it, instead of hanging until it is.
const O_NONBLOCK: i32 = 0o4000;

fn tool(name: &str, description: &str, properties: Value, required: &[&str]) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": {
            "type": "object",
            "properties": properties,
            "required": required,
        },
    })
}

/// The tool list, as MCP's `tools/list` returns it.
pub fn tools() -> Value {
    let s = |d: &str| json!({ "type": "string", "description": d });
    let i = |d: &str| json!({ "type": "integer", "description": d });
    json!([
        tool("etat_bureau",
            "L'état du bureau : fenêtre active, fenêtres ouvertes par workspace, volume, sessions Claude en cours.",
            json!({}), &[]),
        tool("aller_workspace", "Affiche le workspace demandé.",
            json!({ "numero": i("numéro du workspace (1 à 10)") }), &["numero"]),
        tool("afficher_fenetre",
            "Met au premier plan la fenêtre dont la classe ou le titre contient `cible` (insensible à la casse).",
            json!({ "cible": s("classe ou morceau de titre, ex. « zed », « chromium », « youtube »") }), &["cible"]),
        tool("deplacer_fenetre",
            "Envoie une fenêtre vers un workspace : la fenêtre `cible` si donnée, sinon la fenêtre active.",
            json!({ "workspace": i("workspace de destination"), "cible": s("classe ou morceau de titre (facultatif)") }),
            &["workspace"]),
        tool("fermer_fenetre",
            "Ferme une fenêtre : `cible` si donnée, sinon la fenêtre active. L'utilisateur confirme dans une bulle.",
            json!({ "cible": s("classe ou morceau de titre (facultatif)") }), &[]),
        tool("plein_ecran", "Bascule le plein écran de la fenêtre active.", json!({}), &[]),
        tool("volume",
            "Règle le son de sortie : `pourcentage` absolu, ou `delta` relatif (+10, -10), et/ou `muet`.",
            json!({ "pourcentage": i("0 à 100"), "delta": i("variation en points, ex. -10"),
                    "muet": json!({ "type": "boolean" }) }), &[]),
        tool("luminosite", "Règle la luminosité de l'écran du portable.",
            json!({ "pourcentage": i("1 à 100") }), &["pourcentage"]),
        tool("media",
            "Contrôle la lecture en cours (navigateur, lecteur…) et dit ce qui joue.",
            json!({ "action": json!({ "type": "string",
                "enum": ["lecture", "pause", "basculer", "suivant", "precedent", "etat"] }) }),
            &["action"]),
        tool("ouvrir_app", "Lance une application par son nom (« zed », « firefox », « obsidian »…).",
            json!({ "nom": s("nom de l'application") }), &["nom"]),
        tool("ouvrir_url", "Ouvre une URL ou une recherche dans le navigateur par défaut.",
            json!({ "url": s("URL complète (https://…)") }), &["url"]),
        tool("ouvrir_projet", "Ouvre un projet de ~/ciph3r dans Zed ou dans un terminal.",
            json!({ "projet": s("nom du projet, ex. karenine"),
                    "outil": json!({ "type": "string", "enum": ["zed", "terminal"] }) }),
            &["projet", "outil"]),
        tool("capture_ecran", "Fait une capture (copiée et enregistrée).",
            json!({ "zone": json!({ "type": "string", "enum": ["ecran", "selection", "fenetre"] }) }),
            &["zone"]),
        tool("lancer_session",
            "Confie une tâche de code ou de recherche à une session Claude Code complète, qui travaille en \
             arrière-plan. `projet` : un dépôt de ~/ciph3r, « nixos », ou « recherche » (le coffre de notes). \
             Dans un dépôt elle travaille dans une copie isolée, que l'utilisateur revoit avant de fusionner.",
            json!({ "projet": s("nom du projet"), "demande": s("la tâche, formulée pour Claude Code"),
                    "copie_isolee": json!({ "type": "boolean", "description": "défaut : vrai pour un dépôt" }) }),
            &["projet", "demande"]),
        tool("sessions", "Les sessions Claude Code en cours et leur état.", json!({}), &[]),
        tool("chercher_notes",
            "Cherche dans les notes de l'utilisateur (coffre Obsidian : recherches, projets, skills, lab).",
            json!({ "requete": s("mots à chercher") }), &["requete"]),
        tool("ouvrir_note", "Ouvre une note du coffre dans Obsidian.",
            json!({ "chemin": s("chemin relatif au coffre, tel que chercher_notes le donne") }), &["chemin"]),
        tool("creer_note",
            "Crée une note dans l'onglet Notes de l'interface (les notes rapides façon Keep, pas le coffre \
             Obsidian) : un pense-bête, une liste, une idée à garder sous la main.",
            json!({ "texte": s("le contenu de la note ; une liste : une ligne par élément"),
                    "epingler": json!({ "type": "boolean", "description": "en tête des notes ; défaut : non" }) }),
            &["texte"]),
        tool("lire_notes",
            "Les notes de l'onglet Notes (notes rapides façon Keep, pas le coffre Obsidian), épinglées d'abord ; \
             les images y figurent par leur chemin.",
            json!({ "recherche": s("mots que la note doit contenir ; vide : toutes") }), &[]),
        tool("widget",
            "Ouvre, ferme ou bascule un widget de l'interface : « explorer » (les dossiers du PC), « stats » (processeur, mémoire et carte graphique, de ce PC ou \
             d'un serveur du réseau Tailscale par ssh, avec terminal, redémarrage, extinction et réveil, et en dessous le téléphone), « telephone » (ouvre « stats », où est la carte du téléphone relié par KDE Connect : batterie, réseau, le faire sonner), « notifications » (les notifications reçues, ne pas déranger), « notes » (les notes façon Keep : texte et images collés), « lecteur » (lecteur en cours, paroles), « musique » (métronome et accordeur), \
             « son » (ouvre les réglages), « camera » (contrôle gestuel), « reglages » \
             (sorties et entrées audio, webcam, luminosité, écran, thème), « sessions » (le dock des sessions Claude et du savoir). « tout » avec \
             « fermer » referme tout.",
            json!({ "nom": json!({ "type": "string", "enum": WIDGETS }),
                    "action": json!({ "type": "string", "enum": ["ouvrir", "fermer", "basculer"],
                                      "description": "défaut : ouvrir" }) }),
            &["nom"]),
        tool("couleur_accent", "Change la couleur d'accent de tout le bureau.",
            json!({ "couleur": s("#rrggbb") }), &["couleur"]),
        tool("presse_papiers", "Lit le texte du presse-papiers.", json!({}), &[]),
        tool("commande",
            "Exécute une commande shell et renvoie sa sortie (30 s maximum). L'utilisateur confirme dans une bulle. \
             À réserver à ce qu'aucun autre outil ne fait.",
            json!({ "commande": s("ligne de commande") }), &["commande"]),
        tool("reconstruire_nixos",
            "Ouvre un terminal qui reconstruit le système NixOS (le mot de passe sudo y est demandé). \
             L'utilisateur confirme dans une bulle.",
            json!({}), &[]),
    ])
}

/// The FIFO line that opens, closes or toggles a widget.
fn widget_line(name: &str, action: &str) -> Result<String, String> {
    if !WIDGETS.contains(&name) {
        return Err(format!("widget inconnu : « {name} »"));
    }
    let action = match action {
        "" => "ouvrir",
        a @ ("ouvrir" | "fermer" | "basculer") => a,
        a => return Err(format!("action inconnue : « {a} »")),
    };
    if name == "tout" && action != "fermer" {
        return Err("« tout » ne fait que se fermer".into());
    }
    Ok(format!("widget:{name}:{action}\n"))
}

fn shell_send(line: &str) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .write(true)
        .custom_flags(O_NONBLOCK)
        .open(SHELL_FIFO)
        .and_then(|mut f| f.write_all(line.as_bytes()))
        .map_err(|e| format!("l'interface (quickshell) ne répond pas : {e}"))
}

/// One line describing a call, for the dock: its request and its thread.
pub fn describe(tool: &str, args: &Value) -> String {
    let s = |k: &str| args.get(k).and_then(Value::as_str).unwrap_or("");
    match tool {
        "commande" => s("commande").to_string(),
        "fermer_fenetre" => {
            let c = s("cible");
            if c.is_empty() {
                "la fenêtre active".into()
            } else {
                c.into()
            }
        }
        "reconstruire_nixos" => "sudo nixos-rebuild switch".into(),
        _ => {
            let a = args.to_string();
            if a == "{}" || a == "null" {
                String::new()
            } else {
                a
            }
        }
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn run(cmd: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("{cmd} : {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
    } else {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        Err(if err.is_empty() {
            format!("{cmd} a échoué")
        } else {
            err
        })
    }
}

/// Start a program detached from anna (it must outlive a daemon restart).
fn launch(args: &[&str]) -> Result<(), String> {
    run(
        "systemd-run",
        &[
            &[
                "--user",
                "--collect",
                "--quiet",
                "-p",
                "ExitType=cgroup",
                "--",
            ],
            args,
        ]
        .concat(),
    )
    .map(|_| ())
}

fn dispatch(lua: &str) -> Result<(), String> {
    let out = run("hyprctl", &["dispatch", lua])?;
    if out.contains("error") || out.contains("warning") {
        Err(out)
    } else {
        Ok(())
    }
}

fn hypr_json(what: &str) -> Value {
    run("hyprctl", &[what, "-j"])
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn cut(s: &str) -> String {
    if s.chars().count() <= OUTPUT_MAX {
        return s.to_string();
    }
    let mut out: String = s.chars().take(OUTPUT_MAX).collect();
    out.push_str("\n… (sortie coupée)");
    out
}

/// The windows Hyprland knows: (pid, class, title, workspace).
fn windows() -> Vec<(u64, String, String, String)> {
    hypr_json("clients")
        .as_array()
        .map(|a| {
            a.iter()
                .map(|c| {
                    let s = |k: &str| c.get(k).and_then(Value::as_str).unwrap_or("").to_string();
                    (
                        c.get("pid").and_then(Value::as_u64).unwrap_or(0),
                        s("class"),
                        s("title"),
                        c.pointer("/workspace/name")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string(),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The window matching `query` by class first, then by title.
fn find_window(query: &str) -> Result<u64, String> {
    let q = query.to_lowercase();
    let all = windows();
    all.iter()
        .find(|w| w.1.to_lowercase().contains(&q))
        .or_else(|| all.iter().find(|w| w.2.to_lowercase().contains(&q)))
        .map(|w| w.0)
        .ok_or_else(|| format!("aucune fenêtre ne correspond à « {query} »"))
}

fn focus_pid(pid: u64) -> Result<(), String> {
    dispatch(&format!("hl.dsp.focus({{ window = \"pid:{pid}\" }})"))
}

/// The value of `Name=` / `Exec=` keys in a .desktop file's main group.
fn desktop_entry(text: &str) -> Option<(String, String)> {
    let mut name = None;
    let mut exec = None;
    let mut in_main = false;
    for line in text.lines() {
        let l = line.trim();
        if l.starts_with('[') {
            in_main = l == "[Desktop Entry]";
            continue;
        }
        if !in_main {
            continue;
        }
        if let Some(v) = l.strip_prefix("Name=") {
            name.get_or_insert_with(|| v.to_string());
        } else if let Some(v) = l.strip_prefix("Exec=") {
            exec.get_or_insert_with(|| v.to_string());
        } else if l == "NoDisplay=true" || l == "Hidden=true" {
            return None;
        }
    }
    Some((name?, exec?))
}

/// An `Exec=` line as arguments, field codes (%U, %f…) dropped.
fn exec_args(exec: &str) -> Vec<String> {
    exec.split_whitespace()
        .filter(|a| !(a.starts_with('%') && a.len() == 2))
        .map(|a| a.trim_matches('"').to_string())
        .collect()
}

fn find_app(name: &str) -> Option<Vec<String>> {
    let home = crate::paths::home_dir();
    let dirs = [
        home.join(".local/share/applications"),
        home.join(".nix-profile/share/applications"),
        std::path::PathBuf::from(format!(
            "/etc/profiles/per-user/{}/share/applications",
            std::env::var("USER").unwrap_or_default()
        )),
        "/run/current-system/sw/share/applications".into(),
    ];
    let q = name.to_lowercase();
    let mut best: Option<(u8, Vec<String>)> = None;
    for dir in dirs {
        for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("desktop") {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            let Some((n, exec)) = desktop_entry(&text) else {
                continue;
            };
            let file = path
                .file_stem()
                .map(|s| s.to_string_lossy().to_lowercase())
                .unwrap_or_default();
            let n = n.to_lowercase();
            let score = if n == q || file == q {
                3
            } else if n.starts_with(&q) || file.contains(&q) {
                2
            } else if n.contains(&q) {
                1
            } else {
                0
            };
            if score > 0 && best.as_ref().is_none_or(|(b, _)| score > *b) {
                best = Some((score, exec_args(&exec)));
            }
        }
    }
    best.map(|(_, a)| a)
}

fn vault() -> std::path::PathBuf {
    crate::paths::home_dir().join("v4ult")
}

/// Notes of the vault matching every word of `query`, best first.
fn search_notes(query: &str) -> String {
    let words: Vec<String> = query
        .split_whitespace()
        .map(str::to_lowercase)
        .filter(|w| w.len() > 1)
        .collect();
    if words.is_empty() {
        return "requête vide".into();
    }
    let root = vault();
    let mut hits: Vec<(usize, String, String)> = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(dir) = stack.pop() {
        for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            // Hidden folders and the session journal are not notes.
            if name.starts_with('.') || (dir == root && name == "claude") {
                continue;
            }
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            if p.extension().and_then(|x| x.to_str()) != Some("md") {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&p) else {
                continue;
            };
            let low = text.to_lowercase();
            let rel = p
                .strip_prefix(&root)
                .map(|r| r.to_string_lossy().to_string())
                .unwrap_or_default();
            let rel_low = rel.to_lowercase();
            if !words.iter().all(|w| low.contains(w) || rel_low.contains(w)) {
                continue;
            }
            let score = words
                .iter()
                .map(|w| low.matches(w.as_str()).count() + 5 * rel_low.matches(w.as_str()).count())
                .sum();
            let snippet = text
                .lines()
                .find(|l| {
                    let ll = l.to_lowercase();
                    !l.starts_with("---") && words.iter().any(|w| ll.contains(w))
                })
                .unwrap_or("")
                .trim()
                .chars()
                .take(160)
                .collect();
            hits.push((score, rel, snippet));
        }
    }
    if hits.is_empty() {
        return format!("aucune note ne contient « {query} »");
    }
    hits.sort_by_key(|h| std::cmp::Reverse(h.0));
    hits.iter()
        .take(8)
        .map(|(_, rel, snip)| format!("- {rel} — {snip}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn url_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

pub fn project_dir(name: &str) -> Result<String, String> {
    super::runner::projects()
        .into_iter()
        .find(|p| p.name.eq_ignore_ascii_case(name))
        .map(|p| p.path)
        .ok_or_else(|| {
            let names: Vec<String> = super::runner::projects()
                .into_iter()
                .map(|p| p.name)
                .collect();
            format!("projet inconnu « {name} » (connus : {})", names.join(", "))
        })
}

/// The desktop state, as `etat_bureau` reports it (without the sessions,
/// which the daemon adds).
pub fn desktop_state() -> String {
    let mut out = Vec::new();
    let active = hypr_json("activewindow");
    let s = |k: &str| {
        active
            .get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    if !s("class").is_empty() {
        out.push(format!(
            "fenêtre active : {} — {} (workspace {})",
            s("class"),
            s("title"),
            active
                .pointer("/workspace/name")
                .and_then(Value::as_str)
                .unwrap_or("?")
        ));
    }
    let mut wins = windows();
    wins.sort_by(|a, b| a.3.cmp(&b.3));
    if !wins.is_empty() {
        out.push("fenêtres :".into());
        for (_, class, title, ws) in wins.iter().take(20) {
            let t: String = title.chars().take(70).collect();
            out.push(format!("  - workspace {ws} : {class} — {t}"));
        }
    }
    if let Ok(v) = run("wpctl", &["get-volume", "@DEFAULT_AUDIO_SINK@"]) {
        out.push(format!("son : {v}"));
    }
    out.join("\n")
}

/// Carry out one of the synchronous tools. The daemon handles the others
/// (sessions, theme) and the confirmation of SENSITIVE ones before calling
/// this.
pub fn run_tool(tool: &str, args: &Value) -> Result<String, String> {
    let s = |k: &str| {
        args.get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string()
    };
    let n = |k: &str| args.get(k).and_then(Value::as_i64);
    match tool {
        "etat_bureau" => Ok(desktop_state()),
        "aller_workspace" => {
            let w = n("numero").ok_or("numéro manquant")?;
            dispatch(&format!("hl.dsp.focus({{ workspace = {w} }})"))?;
            Ok(format!("workspace {w}"))
        }
        "afficher_fenetre" => {
            let pid = find_window(&s("cible"))?;
            focus_pid(pid)?;
            Ok("fenêtre au premier plan".into())
        }
        "deplacer_fenetre" => {
            let w = n("workspace").ok_or("workspace manquant")?;
            let c = s("cible");
            if !c.is_empty() {
                focus_pid(find_window(&c)?)?;
            }
            dispatch(&format!("hl.dsp.window.move({{ workspace = {w} }})"))?;
            Ok(format!("fenêtre envoyée sur le workspace {w}"))
        }
        "fermer_fenetre" => {
            let c = s("cible");
            if !c.is_empty() {
                focus_pid(find_window(&c)?)?;
            }
            dispatch("hl.dsp.window.close()")?;
            Ok("fenêtre fermée".into())
        }
        "plein_ecran" => {
            dispatch("hl.dsp.window.fullscreen()")?;
            Ok("plein écran basculé".into())
        }
        "volume" => {
            let sink = "@DEFAULT_AUDIO_SINK@";
            if let Some(m) = args.get("muet").and_then(Value::as_bool) {
                run("wpctl", &["set-mute", sink, if m { "1" } else { "0" }])?;
            }
            if let Some(p) = n("pourcentage") {
                run(
                    "wpctl",
                    &["set-volume", sink, &format!("{}%", p.clamp(0, 100))],
                )?;
            } else if let Some(d) = n("delta") {
                let arg = if d >= 0 {
                    format!("{d}%+")
                } else {
                    format!("{}%-", -d)
                };
                run("wpctl", &["set-volume", "-l", "1.0", sink, &arg])?;
            }
            run("wpctl", &["get-volume", sink])
        }
        "luminosite" => {
            let p = n("pourcentage")
                .ok_or("pourcentage manquant")?
                .clamp(1, 100);
            run("brightnessctl", &["set", &format!("{p}%")])?;
            Ok(format!("luminosité {p} %"))
        }
        "media" => {
            let verb = match s("action").as_str() {
                "lecture" => Some("play"),
                "pause" => Some("pause"),
                "basculer" => Some("play-pause"),
                "suivant" => Some("next"),
                "precedent" => Some("previous"),
                _ => None,
            };
            if let Some(v) = verb {
                run("playerctl", &[v])?;
            }
            let now = run(
                "playerctl",
                &[
                    "metadata",
                    "--format",
                    "{{status}} : {{artist}} — {{title}}",
                ],
            )
            .unwrap_or_else(|_| "rien ne joue".into());
            Ok(now)
        }
        "ouvrir_app" => {
            let name = s("nom");
            let args =
                find_app(&name).ok_or_else(|| format!("application « {name} » introuvable"))?;
            let refs: Vec<&str> = args.iter().map(String::as_str).collect();
            launch(&refs)?;
            Ok(format!("{name} lancé"))
        }
        "ouvrir_url" => {
            let url = s("url");
            if !(url.starts_with("http://") || url.starts_with("https://")) {
                return Err("seules les URL http(s) s'ouvrent".into());
            }
            launch(&["xdg-open", &url])?;
            Ok("ouvert dans le navigateur".into())
        }
        "ouvrir_projet" => {
            let dir = project_dir(&s("projet"))?;
            match s("outil").as_str() {
                "terminal" => launch(&["alacritty", "--working-directory", &dir])?,
                _ => launch(&["zeditor", &dir])?,
            }
            Ok(format!("{dir} ouvert"))
        }
        "capture_ecran" => {
            let target = match s("zone").as_str() {
                "selection" => "area",
                "fenetre" => "active",
                _ => "output",
            };
            // In /tmp under the shell's name: it lands in the notes too
            // (notes.rs::watch_screenshots).
            let secs = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let path = format!("/tmp/screenshot-{secs}.png");
            launch(&["grimblast", "--notify", "copysave", target, &path])?;
            Ok("capture lancée".into())
        }
        "widget" => {
            let (name, action) = (s("nom"), s("action"));
            shell_send(&widget_line(&name, &action)?)?;
            Ok(match action.as_str() {
                "fermer" => format!("{name} fermé"),
                "basculer" => format!("{name} basculé"),
                _ => format!("{name} ouvert"),
            })
        }
        "chercher_notes" => Ok(search_notes(&s("requete"))),
        "creer_note" => crate::notes::pilot_create(
            &s("texte"),
            args.get("epingler")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        ),
        "lire_notes" => Ok(cut(&crate::notes::pilot_read(&s("recherche")))),
        "ouvrir_note" => {
            let rel = s("chemin");
            let p = vault().join(&rel);
            if rel.contains("..") || !p.is_file() {
                return Err(format!("note introuvable : {rel}"));
            }
            let uri = format!("obsidian://open?path={}", url_encode(&p.to_string_lossy()));
            launch(&["xdg-open", &uri])?;
            Ok(format!("{rel} ouverte dans Obsidian"))
        }
        "presse_papiers" => run("wl-paste", &["--no-newline", "--type", "text"])
            .map(|t| cut(&t))
            .or_else(|_| Ok("presse-papiers vide".into())),
        "commande" => {
            let cmd = s("commande");
            let out = Command::new("timeout")
                .args([
                    &format!("{}", Duration::from_secs(30).as_secs()),
                    "sh",
                    "-c",
                    &cmd,
                ])
                .current_dir(crate::paths::home_dir())
                .stdin(Stdio::null())
                .output()
                .map_err(|e| format!("sh : {e}"))?;
            let mut text = String::from_utf8_lossy(&out.stdout).to_string();
            let err = String::from_utf8_lossy(&out.stderr);
            if !err.trim().is_empty() {
                text.push_str("\n[stderr]\n");
                text.push_str(&err);
            }
            let code = out.status.code().unwrap_or(-1);
            Ok(cut(&format!("code {code}\n{}", text.trim())))
        }
        "reconstruire_nixos" => {
            let host = run("hostname", &[]).unwrap_or_default();
            let script = format!(
                "sudo nixos-rebuild switch --flake /etc/nixos#{host}; echo; read -p 'Entrée pour fermer'"
            );
            launch(&["alacritty", "-e", "sh", "-c", &script])?;
            Ok("reconstruction lancée dans un terminal".into())
        }
        other => Err(format!("outil inconnu : {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_has_a_schema() {
        let list = tools();
        let names: Vec<&str> = list
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"volume") && names.contains(&"lancer_session"));
        assert!(names.contains(&"creer_note") && names.contains(&"lire_notes"));
        for t in list.as_array().unwrap() {
            assert_eq!(t["inputSchema"]["type"], "object", "{}", t["name"]);
        }
        for s in SENSITIVE {
            assert!(names.contains(&s), "{s} is a tool");
        }
    }

    #[test]
    fn desktop_entries_and_exec_lines() {
        let text = "[Desktop Entry]\nName=Zed\nExec=zeditor %U\n[Desktop Action new]\nName=Nouveau\nExec=zeditor --new\n";
        let (n, e) = desktop_entry(text).unwrap();
        assert_eq!((n.as_str(), e.as_str()), ("Zed", "zeditor %U"));
        assert_eq!(exec_args(&e), ["zeditor"]);
        assert!(desktop_entry("[Desktop Entry]\nName=X\nExec=x\nNoDisplay=true\n").is_none());
        assert_eq!(
            exec_args("\"/opt/a b\" --flag %f"),
            ["/opt/a", "b", "--flag"]
        );
    }

    #[test]
    fn urls_are_encoded_for_obsidian() {
        assert_eq!(
            url_encode("/home/u/v4ult/Recherche/Gödel.md"),
            "/home/u/v4ult/Recherche/G%C3%B6del.md"
        );
        assert_eq!(url_encode("a b"), "a%20b");
    }

    #[test]
    fn widget_lines_match_the_shell() {
        assert_eq!(widget_line("stats", "").unwrap(), "widget:stats:ouvrir\n");
        assert_eq!(
            widget_line("son", "basculer").unwrap(),
            "widget:son:basculer\n"
        );
        assert_eq!(
            widget_line("tout", "fermer").unwrap(),
            "widget:tout:fermer\n"
        );
        assert!(widget_line("tout", "ouvrir").is_err());
        assert!(widget_line("console", "").is_err());
        assert!(widget_line("stats", "rm").is_err());
    }

    #[test]
    fn sensitive_calls_are_described() {
        assert_eq!(
            describe("commande", &json!({"commande": "rm -rf x"})),
            "rm -rf x"
        );
        assert_eq!(describe("fermer_fenetre", &json!({})), "la fenêtre active");
        assert_eq!(describe("etat_bureau", &json!({})), "");
    }
}
