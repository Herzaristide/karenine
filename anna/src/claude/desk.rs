//! What the pilot can do on the desktop: its tools, as the pilot hands them
//! to its model (pilot.rs) and `anna mcp` serves them to any MCP client, and
//! how anna carries each one out.
//!
//! Every call lands in the daemon (`desk` command), never in the MCP process:
//! the daemon owns the theme and the bar.
//!
//! Hyprland is driven through its Lua dispatchers — the only syntax its Lua
//! configuration accepts (see gesture/output.rs). Only forms whose arguments
//! are known are used: some dispatchers ignore unknown arguments and run
//! anyway.

use serde_json::{json, Value};
use std::process::{Command, Stdio};
use std::time::Duration;

/// Longest output handed back to the model (characters).
const OUTPUT_MAX: usize = 4000;

/// The tabs of the shell's right panel (services/Widgets.qml), plus
/// « tout ».
/// The side panel's tabs, then the bottom bar's panels (Widgets.qml).
const WIDGETS: [&str; 17] = [
    "explorer",
    "stats",
    "agenda",
    "lecteur",
    "musique",
    "claude",
    "reglages",
    "son",
    "micro",
    "wifi",
    "bluetooth",
    "telephone",
    "notifications",
    "energie",
    "alimentation",
    "taches",
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
            "L'état du bureau : fenêtre active, fenêtres ouvertes par workspace, volume.",
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
            "Ferme une fenêtre : `cible` si donnée, sinon la fenêtre active.",
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
        tool("lire_page",
            "Lit une page web (http ou https) et en rend le texte, sans la mise en page : pour \
             répondre sur une page dont on a l'adresse.",
            json!({ "url": s("URL complète (https://…)") }), &["url"]),
        tool("montrer_dossier",
            "Montre un dossier (ou un fichier, sélectionné dans son dossier) dans l'Explorer du panneau de \
             droite. C'est l'outil de « montre-moi », « ouvre », « va dans », « cherche-moi » un dossier : \
             « mes téléchargements », « le projet karenine », « ~/code », « mes images ». Le dossier \
             s'affiche dans l'interface, aucune application ne s'ouvre.",
            json!({ "chemin": s("chemin absolu ou en ~/… ; ou un dossier connu : maison, telechargements, \
                                documents, images, musique, videos, bureau ; ou le nom d'un projet \
                                (ex. karenine) ; ou un chemin relatif au dossier personnel (ex. code/lab)") }),
            &["chemin"]),
        tool("ouvrir_projet", "Ouvre un projet de ~/code dans Zed ou dans un terminal (pour seulement le \
             montrer, `montrer_dossier`).",
            json!({ "projet": s("nom du projet, ex. karenine"),
                    "outil": json!({ "type": "string", "enum": ["zed", "terminal"] }) }),
            &["projet", "outil"]),
        tool("voir_ecran",
            "Te montre en image l'écran que regarde l'utilisateur (le moniteur actif), ou une seule \
             fenêtre (`cible`), pour répondre à une question sur ce qui y est affiché ou le décrire : \
             « c'est quoi cette erreur ? », « explique-moi ce schéma », « résume cette page », \
             « décris ce qu'il y a dans Firefox ». Une fenêtre doit être affichée (sur un workspace \
             visible) pour être vue. Rien n'est enregistré.",
            json!({ "cible": s("classe ou morceau de titre de la fenêtre à voir, ex. « firefox », \
                               « zed », « youtube » ; vide : tout l'écran actif") }), &[]),
        tool("capture_ecran", "Fait une capture (copiée et enregistrée).",
            json!({ "zone": json!({ "type": "string", "enum": ["ecran", "selection", "fenetre"] }) }),
            &["zone"]),
        tool("enregistrer",
            "Enregistre le son (fichier FLAC dans le dossier Musique) ou l'écran avec le son de \
             l'ordinateur (MP4 dans le dossier Vidéos), ou arrête l'enregistrement en cours. \
             L'enregistrement continue après la réponse, jusqu'à ce qu'on l'arrête.",
            json!({ "action": json!({ "type": "string", "enum": ["demarrer", "arreter"],
                                      "description": "défaut : demarrer" }),
                    "quoi": json!({ "type": "string", "enum": ["son", "ecran"],
                                    "description": "requis pour demarrer ; pour arreter, vide = tout arrêter" }),
                    "mode": json!({ "type": "string", "enum": ["micro", "micro_ordi", "selection", "ecran"],
                                    "description": "son : micro (défaut) ou micro_ordi (micro + ce que joue \
                                                    l'ordinateur) ; ecran : selection (défaut, l'utilisateur \
                                                    trace la zone) ou ecran (l'écran entier)" }) }),
            &[]),
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
        tool("agenda",
            "Les événements de l'agenda de l'utilisateur (son compte Google, le même que l'onglet Agenda), \
             à l'heure locale, avec leur calendrier, puis les tâches Google à faire qui tombent dans ces jours. Pour « qu'est-ce que j'ai demain », « suis-je libre jeudi ».",
            json!({ "debut": s("premier jour, AAAA-MM-JJ ; défaut : aujourd'hui"),
                    "fin": s("lendemain du dernier jour, AAAA-MM-JJ (exclu) ; défaut : début + 7 jours") }),
            &[]),
        tool("evenement_creer",
            "Crée un événement dans l'agenda Google de l'utilisateur. Heures locales (« 2026-11-20T14:00 ») ; \
             un jour seul (« 2026-11-20 ») fait un événement sur toute la journée. Sans fin : une heure (un jour \
             pour une journée entière).",
            json!({ "titre": s("titre de l'événement"),
                    "debut": s("début : AAAA-MM-JJTHH:MM (heure locale) ou AAAA-MM-JJ (toute la journée)"),
                    "fin": s("fin, même forme (exclue pour une journée entière) ; défaut : une heure après"),
                    "lieu": s("lieu (facultatif)"),
                    "notes": s("description (facultatif)"),
                    "calendrier": s("nom ou id de l'agenda ; défaut : l'agenda principal") }),
            &["titre", "debut"]),
        tool("evenement_modifier",
            "Modifie ou déplace un événement de l'agenda Google : seuls les champs donnés changent. Un nouveau \
             `debut` sans `fin` le déplace en gardant sa durée. L'id et le calendrier viennent de l'outil `agenda`.",
            json!({ "id": s("id de l'événement (donné par `agenda`)"),
                    "calendrier": s("id de son calendrier (donné par `agenda`)"),
                    "titre": s("nouveau titre"),
                    "debut": s("nouveau début : AAAA-MM-JJTHH:MM (heure locale) ou AAAA-MM-JJ"),
                    "fin": s("nouvelle fin, même forme"),
                    "lieu": s("nouveau lieu"),
                    "notes": s("nouvelle description") }),
            &["id", "calendrier"]),
        tool("evenement_supprimer",
            "Supprime un événement de l'agenda Google. Seulement si l'utilisateur le demande clairement.",
            json!({ "id": s("id de l'événement (donné par `agenda`)"),
                    "calendrier": s("id de son calendrier (donné par `agenda`)") }),
            &["id", "calendrier"]),
        tool("tache_creer",
            "Crée une tâche Google (Google Tasks). Google ne garde que le jour d'échéance, jamais l'heure.",
            json!({ "titre": s("titre de la tâche"),
                    "echeance": s("jour d'échéance, AAAA-MM-JJ (facultatif)"),
                    "notes": s("notes (facultatif)"),
                    "liste": s("nom ou id de la liste ; défaut : la liste principale") }),
            &["titre"]),
        tool("tache_modifier",
            "Modifie, déplace (nouvelle échéance), coche ou décoche une tâche Google : seuls les champs donnés \
             changent. L'id et la liste viennent de l'outil `agenda`.",
            json!({ "id": s("id de la tâche (donné par `agenda`)"),
                    "liste": s("id de sa liste (donné par `agenda`)"),
                    "titre": s("nouveau titre"),
                    "echeance": s("nouveau jour d'échéance, AAAA-MM-JJ ; chaîne vide pour l'enlever"),
                    "notes": s("nouvelles notes"),
                    "faite": json!({ "type": "boolean", "description": "true : cochée ; false : à refaire" }) }),
            &["id", "liste"]),
        tool("tache_supprimer",
            "Supprime une tâche Google. Seulement si l'utilisateur le demande clairement.",
            json!({ "id": s("id de la tâche (donné par `agenda`)"),
                    "liste": s("id de sa liste (donné par `agenda`)") }),
            &["id", "liste"]),
        tool("widget",
            "Ouvre, ferme ou bascule une partie de l'interface. Les onglets du panneau de droite : « explorer » (les \
             fichiers de ce PC ou d'un serveur du réseau Tailscale), « stats » (toute la flotte : processeur, mémoire, \
             carte graphique, disques et services ComfyUI et Ollama de chaque machine), « agenda » (le calendrier Google \
             et les tâches), « lecteur » et « musique » (le lecteur en cours, puis le métronome, l'accordeur et les \
             prises), « claude » (les sessions Claude Code), « reglages » (thème, accent, écran, langue, voix, modèle de \
             l'assistant, webcam). Les volets de la barre du bas : « son » (volume et sortie), « micro » (entrée), \
             « wifi », « bluetooth », « telephone », « notifications », « energie » (batterie et luminosité), \
             « alimentation » (verrouiller, veille, redémarrer, éteindre), « taches ». « tout » avec « fermer » referme \
             le panneau. Pour changer un réglage, `reglage` le fait directement, sans rien ouvrir.",
            json!({ "nom": json!({ "type": "string", "enum": WIDGETS }),
                    "action": json!({ "type": "string", "enum": ["ouvrir", "fermer", "basculer"],
                                      "description": "défaut : ouvrir" }) }),
            &["nom"]),
        tool("metronome",
            "Lance, arrête ou bascule le métronome, sans ouvrir son widget (il bat même onglet Musique fermé). \
             « lancer » prend un tempo et une mesure facultatifs ; sans eux, il garde les derniers.",
            json!({ "action": json!({ "type": "string", "enum": ["lancer", "arreter", "basculer"] }),
                    "bpm": i("tempo, 20 à 300 battements par minute"),
                    "temps": i("temps par mesure, 1 à 16 (4 pour du 4/4, 3 pour une valse)") }),
            &["action"]),
        tool("couleur_accent",
            "Change la couleur d'accent de tout le bureau. Donne un nom de la palette, \
             accordée au thème : cuivre (par défaut), sable, ambre, terre cuite, rose, \
             prune, bleu, ardoise, vert-de-gris, sauge, taupe. « rouge », « vert », \
             « violet »… y mènent aussi. Un #rrggbb n'est à donner que si on le demande \
             précisément : il est adouci pour rester dans le ton.",
            json!({ "couleur": s("nom de la palette, ou #rrggbb") }), &["couleur"]),
        tool("reglage",
            "Change un réglage, comme dans les volets ou l'onglet Réglages. `nom` et sa `valeur` : \
             « theme » sombre ou clair ; « mot_activation » oui ou non (l'écoute du mot d'activation) ; « langue » \
             fr ou en (l'interface) ; « langue_voix » interface, auto, fr ou en ; « micro » muet ou actif ; \
             « sortie_son » et « entree_son » : le nom de l'appareil (casque, haut-parleurs, UR242…) ; « wifi » oui, \
             non, ou le nom d'un réseau connu à rejoindre ; « bluetooth » oui ou non ; « bluetooth_connecter » et \
             « bluetooth_deconnecter » : le nom de l'appareil ; « bluetooth_profil » musique ou appel ; \
             « alimentation » verrouiller, veille, redemarrer ou eteindre (ces deux derniers ouvrent le volet, à \
             confirmer d'un clic). La couleur d'accent a son outil, `couleur_accent` ; le volume, `volume`.",
            json!({ "nom": json!({ "type": "string", "enum": super::reglages::NAMES }),
                    "valeur": s("la valeur, voir la description") }),
            &["nom", "valeur"]),
        tool("presse_papiers", "Lit le texte du presse-papiers.", json!({}), &[]),
        tool("commande",
            "Exécute une commande shell et renvoie sa sortie (30 s maximum). \
             À réserver à ce qu'aucun autre outil ne fait.",
            json!({ "commande": s("ligne de commande") }), &["commande"]),
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

/// The folders `montrer_dossier` knows by name: what is said (without
/// accents), then the `XDG_<key>_DIR` and its fallback under ~.
const KNOWN_DIRS: [(&[&str], &str, &str); 7] = [
    (&["maison", "home", "dossier personnel", "perso", "accueil"], "", ""),
    (&["telechargements", "telechargement", "downloads", "download"], "DOWNLOAD", "Downloads"),
    (&["documents", "document", "docs"], "DOCUMENTS", "Documents"),
    (&["images", "image", "photos", "pictures"], "PICTURES", "Pictures"),
    (&["musique", "musiques", "music"], "MUSIC", "Music"),
    (&["videos", "video"], "VIDEOS", "Videos"),
    (&["bureau", "desktop"], "DESKTOP", "Desktop"),
];

/// Lowercase, without accents, without « mon », « le dossier »… : how a
/// spoken folder name is matched.
fn folder_words(text: &str) -> String {
    let folded: String = text
        .to_lowercase()
        .chars()
        .map(|c| match c {
            'é' | 'è' | 'ê' | 'ë' => 'e',
            'à' | 'â' | 'ä' => 'a',
            'î' | 'ï' => 'i',
            'ô' | 'ö' => 'o',
            'ù' | 'û' | 'ü' => 'u',
            'ç' => 'c',
            '\'' | '’' => ' ',
            c => c,
        })
        .collect();
    const FILLER: [&str; 12] = [
        "mon", "ma", "mes", "le", "la", "les", "l", "de", "du", "des", "dossier", "projet",
    ];
    folded
        .split_whitespace()
        .filter(|w| !FILLER.contains(w))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Where `montrer_dossier`'s `chemin` leads, which must exist: an absolute
/// or ~ path, a known folder, a project, or a path under ~.
fn resolve_folder(said: &str) -> Result<std::path::PathBuf, String> {
    use std::path::PathBuf;
    let home = crate::paths::home_dir();
    let said = said.trim();
    let said = match said.trim_end_matches('/') {
        "" if said.starts_with('/') => "/",
        "" => "~",
        s => s,
    };
    let found: Option<PathBuf> = if said.starts_with('/') {
        Some(PathBuf::from(said))
    } else if said == "~" {
        Some(home.clone())
    } else if let Some(rest) = said.strip_prefix("~/") {
        Some(home.join(rest))
    } else {
        let words = folder_words(said);
        KNOWN_DIRS
            .iter()
            .find(|(names, _, _)| names.contains(&words.as_str()))
            .map(|(_, key, fallback)| {
                if key.is_empty() {
                    home.clone()
                } else {
                    crate::paths::user_dir(key, fallback)
                }
            })
            .or_else(|| project_dir(&words).ok().or_else(|| project_dir(said).ok()).map(PathBuf::from))
            .or_else(|| Some(home.join(said)))
    };
    match found {
        Some(p) if p.exists() => Ok(p),
        _ => {
            let names: Vec<String> = projects().into_iter().map(|p| p.name).collect();
            Err(format!(
                "« {said} » introuvable (dossiers connus : maison, telechargements, documents, images, \
                 musique, videos, bureau ; projets : {})",
                names.join(", ")
            ))
        }
    }
}

/// The FIFO line that shows a path in the Explorer (shell.qml): a folder is
/// opened, a file selected in its own.
fn explorer_line(path: &std::path::Path) -> String {
    let kind = if path.is_dir() { "dossier" } else { "fichier" };
    format!("explorer:{kind}:{}\n", path.display())
}

/// The FIFO line that starts, stops or toggles the metronome
/// (services/Tempo.qml), and what to tell the pilot.
fn metronome_line(
    action: &str,
    bpm: Option<i64>,
    beats: Option<i64>,
) -> Result<(String, String), String> {
    if let Some(b) = bpm.filter(|b| !(20..=300).contains(b)) {
        return Err(format!("tempo hors limites : {b} (20 à 300)"));
    }
    if let Some(t) = beats.filter(|t| !(1..=16).contains(t)) {
        return Err(format!("mesure hors limites : {t} temps (1 à 16)"));
    }
    let said = match action {
        "lancer" => match bpm {
            Some(b) => format!("métronome lancé à {b} bpm"),
            None => "métronome lancé".into(),
        },
        "arreter" => "métronome arrêté".into(),
        "basculer" => "métronome basculé".into(),
        a => return Err(format!("action inconnue : « {a} »")),
    };
    let n = |v: Option<i64>| v.map(|v| v.to_string()).unwrap_or_default();
    let line = format!("metronome:{action}:{}:{}", n(bpm), n(beats));
    Ok((line.trim_end_matches(':').to_string() + "\n", said))
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

// ── Helpers ───────────────────────────────────────────────────────────────

/// Longest page read (bytes), and the text handed back from it (characters).
const PAGE_MAX: u64 = 2 * 1024 * 1024;
const PAGE_TEXT_MAX: usize = 12_000;

/// A web page, as text: scripts, styles and tags out, entities decoded,
/// blank runs folded.
fn read_page(url: &str) -> Result<String, String> {
    use std::io::Read;
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return Err("seules les URL http(s) se lisent".into());
    }
    let resp = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .user_agent("Mozilla/5.0 (X11; Linux x86_64) anna")
        .build()
        .get(url)
        .call()
        .map_err(|e| e.to_string())?;
    let mut body = String::new();
    resp.into_reader()
        .take(PAGE_MAX)
        .read_to_string(&mut body)
        .map_err(|e| e.to_string())?;
    let text: String = html_text(&body).chars().take(PAGE_TEXT_MAX).collect();
    Ok(if text.trim().is_empty() { "(page sans texte)".into() } else { text })
}

fn html_text(html: &str) -> String {
    // ASCII only: the byte offsets stay those of `html`.
    let lower = html.to_ascii_lowercase();
    let lb = lower.as_bytes();
    let mut out = String::with_capacity(html.len() / 3);
    let mut i = 0;
    let bytes = html.as_bytes();
    while i < html.len() {
        if bytes[i] == b'<' {
            // Whole elements whose content is no text.
            let skip = ["script", "style", "noscript", "svg", "head"]
                .iter()
                .find(|t| lb[i + 1..].starts_with(t.as_bytes()));
            let end = match skip {
                Some(t) => lower[i..]
                    .find(&format!("</{t}"))
                    .and_then(|k| lower[i + k..].find('>').map(|m| i + k + m + 1)),
                None => lower[i..].find('>').map(|k| i + k + 1),
            };
            let Some(end) = end else { break };
            // Blocks end lines.
            let tag = &lb[i + 1..end];
            if ["p>", "p ", "br", "div", "li", "h1", "h2", "h3", "h4", "tr", "/p", "/div", "/li", "/h"]
                .iter()
                .any(|b| tag.starts_with(b.as_bytes()))
            {
                out.push('\n');
            } else {
                out.push(' ');
            }
            i = end;
        } else {
            let next = html[i..].find('<').map_or(html.len(), |k| i + k);
            out.push_str(&html[i..next]);
            i = next;
        }
    }
    let decoded = out
        .replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&amp;", "&");
    decoded
        .lines()
        .map(|l| l.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

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

pub struct Project {
    pub name: String,
    pub path: String,
}

/// The projects `ouvrir_projet` knows: the vault (« recherche »), every git
/// repository under ~/code (or the older ~/ciph3r), then the NixOS
/// configuration.
pub fn projects() -> Vec<Project> {
    let home = crate::paths::home_dir();
    let mut out = Vec::new();
    let vault = vault();
    if vault.is_dir() {
        out.push(Project {
            name: "recherche".into(),
            path: vault.to_string_lossy().into(),
        });
    }
    let mut repos: Vec<Project> = ["code", "ciph3r"]
        .iter()
        .filter_map(|d| std::fs::read_dir(home.join(d)).ok())
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
        })
        .collect();
    repos.sort_by_key(|p| p.name.to_lowercase());
    out.extend(repos);
    if std::path::Path::new("/etc/nixos/.git").exists() {
        out.push(Project {
            name: "nixos".into(),
            path: "/etc/nixos".into(),
        });
    }
    out
}

pub fn project_dir(name: &str) -> Result<String, String> {
    projects()
        .into_iter()
        .find(|p| p.name.eq_ignore_ascii_case(name))
        .map(|p| p.path)
        .ok_or_else(|| {
            let names: Vec<String> = projects().into_iter().map(|p| p.name).collect();
            format!("projet inconnu « {name} » (connus : {})", names.join(", "))
        })
}

/// Longest side of the image `voir_ecran` hands the model (pixels): what it
/// reads best, larger is scaled down on its side anyway.
const SCREEN_MAX: f64 = 1568.0;

/// What `voir_ecran` captures: grim's arguments (`-o <output>` or
/// `-g "<x>,<y> <w>x<h>"`, then `-s <scale>`), and the line saying what it
/// is. `target` empty: the focused monitor; else the window whose class, then
/// title, contains it — if it is on a workspace shown on some monitor.
fn capture_area(monitors: &Value, clients: &Value, active: &Value, target: &str)
    -> Result<(Vec<String>, String), String> {
    let mons = monitors.as_array().cloned().unwrap_or_default();
    let num = |v: &Value, k: &str| v.get(k).and_then(Value::as_f64).unwrap_or(0.0);
    let text = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    // Scale the image down so its long side (in logical pixels) is at most
    // SCREEN_MAX, never above the monitor's own pixels.
    let factor = |logical: f64, scale: f64| {
        if logical > 0.0 { (SCREEN_MAX / logical).min(scale.max(1e-3)) } else { 1.0 }
    };

    let target = target.trim().to_lowercase();
    if target.is_empty() {
        let mon = mons
            .iter()
            .find(|m| m.get("focused").and_then(Value::as_bool) == Some(true))
            .ok_or("aucun écran actif")?;
        let (w, h, scale) = (num(mon, "width"), num(mon, "height"), num(mon, "scale").max(1e-3));
        let args = vec![
            "-o".into(), text(mon, "name"),
            "-s".into(), format!("{:.3}", factor(w.max(h) / scale, scale)),
        ];
        let line = format!(
            "écran {} ({w}×{h}) ; fenêtre active : {} — {}. La barre de conversation est en bas.",
            text(mon, "name"), text(active, "class"), text(active, "title")
        );
        return Ok((args, line));
    }

    let all = clients.as_array().cloned().unwrap_or_default();
    let has = |c: &Value, k: &str| text(c, k).to_lowercase().contains(&target);
    // Shown windows first: a matching one on screen beats one elsewhere.
    let shown_ws: Vec<i64> = mons
        .iter()
        .flat_map(|m| {
            [m.pointer("/activeWorkspace/id"), m.pointer("/specialWorkspace/id")]
                .into_iter()
                .flatten()
                .filter_map(Value::as_i64)
                .collect::<Vec<_>>()
        })
        .collect();
    let ws_of = |c: &Value| c.pointer("/workspace/id").and_then(Value::as_i64).unwrap_or(i64::MIN);
    let visible = |c: &Value| shown_ws.contains(&ws_of(c)) && c.get("hidden").and_then(Value::as_bool) != Some(true);
    let win = all.iter().find(|c| visible(c) && has(c, "class"))
        .or_else(|| all.iter().find(|c| visible(c) && has(c, "title")))
        .or_else(|| all.iter().find(|c| has(c, "class") || has(c, "title")))
        .ok_or_else(|| format!("aucune fenêtre ne correspond à « {target} »"))?;
    let label = format!("{} — {}", text(win, "class"), text(win, "title"));
    if !visible(win) {
        let ws = win.pointer("/workspace/name").and_then(Value::as_str).unwrap_or("?");
        return Err(format!(
            "la fenêtre {label} est sur le workspace {ws}, qui n'est pas affiché : elle ne peut pas \
             être vue sans l'afficher (afficher_fenetre change ce que voit l'utilisateur ; ne le fais \
             que s'il le veut)"
        ));
    }
    let at = |i: usize| win.pointer(&format!("/at/{i}")).and_then(Value::as_f64).unwrap_or(0.0);
    let size = |i: usize| win.pointer(&format!("/size/{i}")).and_then(Value::as_f64).unwrap_or(0.0);
    let (w, h) = (size(0), size(1));
    if w < 1.0 || h < 1.0 {
        return Err(format!("la fenêtre {label} n'a pas de taille à l'écran"));
    }
    let scale = mons
        .iter()
        .find(|m| m.get("id").and_then(Value::as_i64) == win.get("monitor").and_then(Value::as_i64))
        .map(|m| num(m, "scale"))
        .unwrap_or(1.0);
    let args = vec![
        "-g".into(), format!("{},{} {}x{}", at(0), at(1), w, h),
        "-s".into(), format!("{:.3}", factor(w.max(h), scale)),
    ];
    Ok((args, format!("fenêtre {label} ({w}×{h})")))
}

/// What `voir_ecran` shows: the focused monitor, or one window (`target`).
/// A line saying what it is, and the JPEG in base64. Nothing is written to
/// disk.
pub fn screen_image(target: &str) -> Result<(String, String), String> {
    use base64::Engine;
    let (area, line) = capture_area(
        &hypr_json("monitors"),
        &hypr_json("clients"),
        &hypr_json("activewindow"),
        target,
    )?;
    let out = Command::new("grim")
        .args(&area)
        .args(["-t", "jpeg", "-q", "80", "-"])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("grim : {e}"))?;
    if !out.status.success() || out.stdout.is_empty() {
        return Err(format!(
            "capture impossible : {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok((
        line,
        base64::engine::general_purpose::STANDARD.encode(&out.stdout),
    ))
}

/// The desktop state, as `etat_bureau` reports it.
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
/// (theme).
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
        "lire_page" => read_page(&s("url")),
        "ouvrir_projet" => {
            let dir = project_dir(&s("projet"))?;
            match s("outil").as_str() {
                "terminal" => launch(&["alacritty", "--working-directory", &dir])?,
                _ => launch(&["zeditor", &dir])?,
            }
            Ok(format!("{dir} ouvert"))
        }
        "montrer_dossier" => {
            let path = resolve_folder(&s("chemin"))?;
            shell_send(&explorer_line(&path))?;
            Ok(format!("{} montré dans l'Explorer", path.display()))
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
        "reglage" => super::reglages::apply(&s("nom"), &s("valeur"), shell_send),
        "widget" => {
            let (name, action) = (s("nom"), s("action"));
            shell_send(&widget_line(&name, &action)?)?;
            Ok(match action.as_str() {
                "fermer" => format!("{name} fermé"),
                "basculer" => format!("{name} basculé"),
                _ => format!("{name} ouvert"),
            })
        }
        "metronome" => {
            let (line, said) = metronome_line(&s("action"), n("bpm"), n("temps"))?;
            shell_send(&line)?;
            Ok(said)
        }
        "chercher_notes" => Ok(search_notes(&s("requete"))),
        "creer_note" => crate::notes::pilot_create(
            &s("texte"),
            args.get("epingler")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        ),
        "lire_notes" => Ok(cut(&crate::notes::pilot_read(&s("recherche")))),
        "agenda" => crate::google::calendar::pilot_read(&s("debut"), &s("fin")).map(|t| cut(&t)),
        "evenement_creer" | "evenement_modifier" => {
            use crate::google::calendar::{create_event, update_event, EventInput};
            let opt = |k: &str| args.get(k).and_then(Value::as_str).map(str::to_string);
            let input = EventInput {
                title: opt("titre"),
                location: opt("lieu"),
                notes: opt("notes"),
                start: opt("debut"),
                end: opt("fin"),
            };
            let event = if tool == "evenement_creer" {
                create_event(&s("calendrier"), &input)?
            } else {
                update_event(&s("calendrier"), &s("id"), &input)?
            };
            let verb = if tool == "evenement_creer" {
                "créé"
            } else {
                "modifié"
            };
            Ok(format!(
                "événement « {} » {verb} : {} → {} (UTC pour les heures ; id {}, calendrier {})",
                event.title, event.start, event.end, event.uid, event.calendar
            ))
        }
        "evenement_supprimer" => crate::google::calendar::delete_event(&s("calendrier"), &s("id"))
            .map(|()| "événement supprimé".to_string()),
        "tache_creer" | "tache_modifier" => {
            use crate::google::tasks::{create_task, update_task, TaskInput};
            let opt = |k: &str| args.get(k).and_then(Value::as_str).map(str::to_string);
            let input = TaskInput {
                title: opt("titre"),
                notes: opt("notes"),
                due: opt("echeance"),
                done: args.get("faite").and_then(Value::as_bool),
            };
            let task = if tool == "tache_creer" {
                create_task(&s("liste"), &input)?
            } else {
                update_task(&s("liste"), &s("id"), &input)?
            };
            let verb = if tool == "tache_creer" {
                "créée"
            } else {
                "modifiée"
            };
            let due = if task.due.is_empty() {
                "sans échéance".to_string()
            } else {
                format!("pour le {}", task.due)
            };
            Ok(format!(
                "tâche « {} » {verb}, {due}{} (id {}, liste {})",
                task.title,
                if task.done { ", cochée" } else { "" },
                task.id,
                task.list
            ))
        }
        "tache_supprimer" => crate::google::tasks::delete_task(&s("liste"), &s("id"))
            .map(|()| "tâche supprimée".to_string()),
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
        other => Err(format!("outil inconnu : {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hypr() -> (Value, Value) {
        let monitors = json!([
            { "id": 0, "name": "eDP-1", "width": 1920, "height": 1080, "scale": 1.25, "focused": true,
              "activeWorkspace": { "id": 7 }, "specialWorkspace": { "id": 0 } },
            { "id": 1, "name": "HDMI-A-1", "width": 1920, "height": 1080, "scale": 1.0, "focused": false,
              "activeWorkspace": { "id": 1 }, "specialWorkspace": { "id": 0 } }
        ]);
        let clients = json!([
            { "class": "firefox", "title": "Docs", "at": [10, 20], "size": [800, 600],
              "workspace": { "id": 3, "name": "3" }, "monitor": 1 },
            { "class": "firefox", "title": "YouTube", "at": [0, 900], "size": [1920, 1050],
              "workspace": { "id": 1, "name": "1" }, "monitor": 1 },
            { "class": "dev.zed.Zed", "title": "karenine", "at": [1536, 900], "size": [1536, 864],
              "workspace": { "id": 7, "name": "7" }, "monitor": 0 }
        ]);
        (monitors, clients)
    }

    #[test]
    fn the_whole_screen_is_the_focused_monitor() {
        let (m, c) = hypr();
        let (args, line) = capture_area(&m, &c, &json!({"class": "zed", "title": "t"}), "").unwrap();
        // 1920 px at scale 1.25: 1536 logical, brought up to 1568.
        assert_eq!(args, vec!["-o", "eDP-1", "-s", "1.021"]);
        assert!(line.starts_with("écran eDP-1 (1920×1080)"));
    }

    #[test]
    fn a_window_is_its_region_and_the_shown_one_wins() {
        let (m, c) = hypr();
        // Two Firefox windows: the one on a shown workspace is captured.
        let (args, line) = capture_area(&m, &c, &json!({}), "Firefox").unwrap();
        assert_eq!(args, vec!["-g", "0,900 1920x1050", "-s", "0.817"]);
        assert_eq!(line, "fenêtre firefox — YouTube (1920×1050)");
        // By title, scaled to its monitor (1.25): never above its pixels.
        let (args, _) = capture_area(&m, &c, &json!({}), "karen").unwrap();
        assert_eq!(args[1], "1536,900 1536x864");
    }

    #[test]
    fn a_window_out_of_sight_is_not_captured() {
        let (m, c) = hypr();
        let err = capture_area(&m, &c, &json!({}), "docs").unwrap_err();
        assert!(err.contains("workspace 3"), "{err}");
        assert!(capture_area(&m, &c, &json!({}), "gimp").unwrap_err().contains("aucune fenêtre"));
    }

    #[test]
    fn a_page_reads_as_text() {
        let html = "<html><head><title>T</title><style>a{}</style></head><body>\
                    <h1>Météo</h1><p>Il fait&nbsp;12&deg; à <b>Paris</b>.</p>\
                    <script>var x = '<p>';</script><div>İstanbul &amp; co</div></body></html>";
        assert_eq!(html_text(html), "Météo\nIl fait 12&deg; à Paris .\nİstanbul & co");
    }

    #[test]
    fn every_tool_has_a_schema() {
        let list = tools();
        let names: Vec<&str> = list
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"volume") && names.contains(&"commande"));
        assert!(names.contains(&"creer_note") && names.contains(&"lire_notes"));
        assert!(names.contains(&"agenda"));
        assert!(names.contains(&"enregistrer"));
        assert!(names.contains(&"montrer_dossier"));
        assert!(!names.contains(&"lancer_session"), "the pilot only acts");
        for t in list.as_array().unwrap() {
            assert_eq!(t["inputSchema"]["type"], "object", "{}", t["name"]);
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
    fn folders_are_found_by_what_is_said() {
        let home = crate::paths::home_dir();
        assert_eq!(folder_words("mon dossier de Téléchargements"), "telechargements");
        assert_eq!(folder_words("le projet karenine"), "karenine");
        // In the Nix build sandbox HOME is /homeless-shelter, which does
        // not exist: resolve_folder rightly refuses it there.
        if home.exists() {
            assert_eq!(resolve_folder("~").unwrap(), home);
            assert_eq!(resolve_folder("ma maison").unwrap(), home);
        }
        assert_eq!(resolve_folder("/").unwrap(), std::path::PathBuf::from("/"));
        assert!(resolve_folder("/nulle/part/ici").is_err());
    }

    #[test]
    fn explorer_lines_match_the_shell() {
        assert_eq!(explorer_line(std::path::Path::new("/")), "explorer:dossier:/\n");
        assert_eq!(
            explorer_line(std::path::Path::new("/nulle/part.txt")),
            "explorer:fichier:/nulle/part.txt\n"
        );
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
    fn metronome_lines_match_the_shell() {
        let line = |a, b, t| metronome_line(a, b, t).map(|(l, _)| l);
        assert_eq!(
            line("lancer", Some(120), None).unwrap(),
            "metronome:lancer:120\n"
        );
        assert_eq!(
            line("lancer", None, Some(3)).unwrap(),
            "metronome:lancer::3\n"
        );
        assert_eq!(
            line("lancer", Some(90), Some(3)).unwrap(),
            "metronome:lancer:90:3\n"
        );
        assert_eq!(line("arreter", None, None).unwrap(), "metronome:arreter\n");
        assert!(line("lancer", Some(500), None).is_err());
        assert!(line("lancer", None, Some(0)).is_err());
        assert!(line("jouer", None, None).is_err());
    }
}
