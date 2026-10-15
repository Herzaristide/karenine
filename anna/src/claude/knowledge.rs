//! The user's knowledge, as the Obsidian vault holds it (`~/v4ult`), for the
//! AI dock's "savoir" view.
//!
//! The vault is plain Markdown, written by the user and by `/capitaliser`
//! (see the NixOS config, home/modules/code/ia/savoir.nix):
//!
//!   Recherche/  Projets/  Skills/<nom>/SKILL.md  Lab/   — curated knowledge
//!   claude/                                             — the session journal
//!
//! Each note opens with YAML front matter (`type`, `sujets`, `statut`,
//! `revu`, `projet`, `session`…). Only that flat subset is read here — keys
//! with scalar or `[a, b]` values — which is all the templates use.
//!
//! anna also keeps the vault's skills active: Claude Code only sees a skill
//! linked at the first level of `~/.claude/skills`, so every
//! `Skills/<nom>/SKILL.md` gets a link there, and links whose target left the
//! vault are removed. Nothing else in `~/.claude/skills` is touched.

use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// Biggest note read for a preview.
const READ_MAX: u64 = 512 * 1024;
/// Length of a note's excerpt (characters).
const EXCERPT: usize = 220;

pub fn vault() -> PathBuf {
    std::env::var_os("ANNA_VAULT")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::paths::home_dir().join("v4ult"))
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Note {
    /// Path relative to the vault.
    pub path: String,
    pub title: String,
    /// "recherche", "projet", "skill", "lab", "journal" or "note".
    pub kind: String,
    pub sujets: Vec<String>,
    /// "à-relire" for what Claude wrote and the user hasn't read yet.
    pub statut: String,
    pub date: String,
    pub revu: String,
    pub projet: String,
    /// The Claude session it came from (8 first characters), if any.
    pub session: String,
    pub excerpt: String,
    /// Unix seconds of the last change, for sorting.
    pub mtime: u64,
}

/// Front matter of a note (flat keys only) and the body after it.
pub fn front_matter(text: &str) -> (BTreeMap<String, String>, &str) {
    let mut map = BTreeMap::new();
    let Some(rest) = text.strip_prefix("---\n") else {
        return (map, text);
    };
    let Some(end) = rest.find("\n---") else {
        return (map, text);
    };
    for line in rest[..end].lines() {
        if line.starts_with(' ') || line.starts_with('\t') {
            continue; // nested: not ours
        }
        if let Some((k, v)) = line.split_once(':') {
            let v = v.trim();
            let v = v.split(" #").next().unwrap_or(v).trim();
            map.insert(k.trim().to_string(), v.trim_matches('"').to_string());
        }
    }
    let body = rest[end + 4..].trim_start_matches('\n');
    (map, body)
}

/// `[a, b]` or `a, b` as a list.
fn list(v: &str) -> Vec<String> {
    v.trim_matches(['[', ']'])
        .split(',')
        .map(|s| s.trim().trim_matches('"').to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// The note's title (first `# ` heading, else its file name) and the start
/// of its text.
fn title_and_excerpt(body: &str, file: &str) -> (String, String) {
    let mut title = None;
    let mut words = String::new();
    for line in body.lines() {
        let l = line.trim();
        if let Some(h) = l.strip_prefix("# ") {
            title.get_or_insert_with(|| h.trim().to_string());
            continue;
        }
        if l.is_empty() || l.starts_with('#') || l.starts_with("<!--") {
            continue;
        }
        if !words.is_empty() {
            words.push(' ');
        }
        words.push_str(l);
        if words.chars().count() >= EXCERPT {
            break;
        }
    }
    let mut excerpt: String = words.chars().take(EXCERPT).collect();
    if words.chars().count() > EXCERPT {
        excerpt.push('…');
    }
    (title.unwrap_or_else(|| file.to_string()), excerpt)
}

fn kind_of(rel: &str, meta: &BTreeMap<String, String>) -> String {
    let top = rel.split('/').next().unwrap_or("");
    match top {
        "claude" => return "journal".into(),
        "Skills" => return "skill".into(),
        _ => {}
    }
    if let Some(t) = meta.get("type").filter(|t| !t.is_empty()) {
        return t.to_lowercase();
    }
    match top {
        "Recherche" => "recherche",
        "Projets" => "projet",
        "Lab" => "lab",
        _ => "note",
    }
    .into()
}

pub fn parse_note(rel: &str, text: &str, mtime: u64) -> Note {
    let (meta, body) = front_matter(text);
    let file = Path::new(rel)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    // A skill is named by its folder, not "SKILL".
    let file = if file == "SKILL" {
        Path::new(rel)
            .parent()
            .and_then(|p| p.file_name())
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or(file)
    } else {
        file
    };
    let (title, excerpt) = title_and_excerpt(body, &file);
    let g = |k: &str| meta.get(k).cloned().unwrap_or_default();
    Note {
        path: rel.to_string(),
        title,
        kind: kind_of(rel, &meta),
        sujets: list(&g("sujets")),
        statut: g("statut"),
        date: g("date"),
        revu: g("revu"),
        projet: g("projet"),
        session: g("session"),
        excerpt,
        mtime,
    }
}

/// Every note of the vault, most recently changed first. Hidden folders,
/// templates and the vault's own CLAUDE.md are not knowledge.
pub fn index() -> Vec<Note> {
    index_in(&vault())
}

pub fn index_in(root: &Path) -> Vec<Note> {
    let root = root.to_path_buf();
    let mut out = Vec::new();
    let mut stack = vec![root.clone()];
    while let Some(dir) = stack.pop() {
        for e in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') || name == "_templates" {
                continue;
            }
            // Skills are reached through their folder, links included.
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            if p.extension().and_then(|x| x.to_str()) != Some("md")
                || (dir == root && name == "CLAUDE.md")
            {
                continue;
            }
            let Ok(meta) = e.metadata() else { continue };
            if meta.len() > READ_MAX {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&p) else {
                continue;
            };
            let rel = p
                .strip_prefix(&root)
                .map(|r| r.to_string_lossy().to_string())
                .unwrap_or_default();
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);
            out.push(parse_note(&rel, &text, mtime));
        }
    }
    out.sort_by_key(|n| std::cmp::Reverse(n.mtime));
    out
}

/// A note's path inside the vault, refusing anything that would leave it.
fn resolve(rel: &str) -> Result<PathBuf, String> {
    if rel.is_empty() || rel.starts_with('/') || rel.split('/').any(|c| c == "..") {
        return Err(format!("chemin refusé : {rel}"));
    }
    let p = vault().join(rel);
    if p.is_file() {
        Ok(p)
    } else {
        Err(format!("note introuvable : {rel}"))
    }
}

/// The note's body, without its front matter.
pub fn read(rel: &str) -> Result<String, String> {
    let p = resolve(rel)?;
    if std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0) > READ_MAX {
        return Err("note trop grande pour l'aperçu".into());
    }
    let text = std::fs::read_to_string(&p).map_err(|e| e.to_string())?;
    Ok(front_matter(&text).1.to_string())
}

/// Today as YYYY-MM-DD (UTC civil date, no dependency).
pub fn today() -> String {
    let days = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() / 86400)
        .unwrap_or(0) as i64;
    // Howard Hinnant's days-from-civil, inverted.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Set (or add) flat keys of a note's front matter, keeping everything else
/// byte for byte.
pub fn set_keys(text: &str, keys: &[(&str, &str)]) -> String {
    let Some(rest) = text.strip_prefix("---\n") else {
        let head: String = keys.iter().map(|(k, v)| format!("{k}: {v}\n")).collect();
        return format!("---\n{head}---\n\n{text}");
    };
    let Some(end) = rest.find("\n---") else {
        return text.to_string();
    };
    let mut lines: Vec<String> = rest[..end].lines().map(String::from).collect();
    for (k, v) in keys {
        let prefix = format!("{k}:");
        match lines.iter_mut().find(|l| l.starts_with(&prefix)) {
            Some(l) => *l = format!("{k}: {v}"),
            None => lines.push(format!("{k}: {v}")),
        }
    }
    format!("---\n{}{}", lines.join("\n"), &rest[end..])
}

/// The user read the note: `statut: relu`, `revu: <today>`.
pub fn mark_reviewed(rel: &str) -> Result<(), String> {
    let p = resolve(rel)?;
    let text = std::fs::read_to_string(&p).map_err(|e| e.to_string())?;
    let updated = set_keys(&text, &[("statut", "relu"), ("revu", &today())]);
    // Atomic: Obsidian watches the vault and would show a half-written file.
    let tmp = p.with_extension("md.anna-tmp");
    std::fs::write(&tmp, updated).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &p).map_err(|e| e.to_string())
}

/// Link every vault skill into `skills_dir`, and drop links into the vault
/// whose target is gone. Returns how many links were added or removed.
pub fn link_skills(skills_dir: &Path) -> usize {
    link_skills_from(&vault().join("Skills"), skills_dir)
}

pub fn link_skills_from(source: &Path, skills_dir: &Path) -> usize {
    let mut changed = 0;
    for e in std::fs::read_dir(source).into_iter().flatten().flatten() {
        let target = e.path();
        if !target.join("SKILL.md").is_file() {
            continue;
        }
        let link = skills_dir.join(e.file_name());
        // Never replace something that isn't ours.
        if link.symlink_metadata().is_ok() {
            continue;
        }
        let _ = std::fs::create_dir_all(skills_dir);
        if std::os::unix::fs::symlink(&target, &link).is_ok() {
            changed += 1;
        }
    }
    for e in std::fs::read_dir(skills_dir)
        .into_iter()
        .flatten()
        .flatten()
    {
        let link = e.path();
        let Ok(dest) = std::fs::read_link(&link) else {
            continue;
        };
        if dest.starts_with(source)
            && !dest.join("SKILL.md").is_file()
            && std::fs::remove_file(&link).is_ok()
        {
            changed += 1;
        }
    }
    changed
}

pub fn skills_dir() -> PathBuf {
    crate::paths::home_dir().join(".claude/skills")
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOTE: &str = "---\ntype: recherche\nsujets: [audio, rust]\ndate: 2026-10-15\nrevu: 2026-10-15\nstatut: à-relire\nversions: {}\n---\n\n# cpal ou pipewire-rs\n\n## En bref\n\ncpal est portable ; pipewire-rs parle directement à PipeWire.\n";

    #[test]
    fn reads_front_matter_and_body() {
        let n = parse_note("Recherche/cpal.md", NOTE, 5);
        assert_eq!(n.title, "cpal ou pipewire-rs");
        assert_eq!(n.kind, "recherche");
        assert_eq!(n.sujets, ["audio", "rust"]);
        assert_eq!(n.statut, "à-relire");
        assert!(n.excerpt.starts_with("cpal est portable"));
    }

    #[test]
    fn kinds_follow_folders_first() {
        let journal = "---\ndate: 2026-10-15\nprojet: karenine\nsession: 58983bae\ntags: [claude/session]\n---\n\n# karenine — 15/10 16:11\n\n## Objectif\nRefondre.\n";
        let n = parse_note("claude/2026-10-15-karenine-58983bae.md", journal, 1);
        assert_eq!(
            (n.kind.as_str(), n.session.as_str()),
            ("journal", "58983bae")
        );
        assert_eq!(n.projet, "karenine");

        let skill = "---\nname: fft-temps-reel\ndescription: x\n---\n\nCorps sans titre.";
        let n = parse_note("Skills/fft-temps-reel/SKILL.md", skill, 1);
        assert_eq!(
            (n.kind.as_str(), n.title.as_str()),
            ("skill", "fft-temps-reel")
        );

        assert_eq!(parse_note("new.md", "texte", 1).kind, "note");
    }

    #[test]
    fn notes_without_front_matter_still_parse() {
        let (meta, body) = front_matter("# Titre\ntexte");
        assert!(meta.is_empty());
        assert_eq!(body, "# Titre\ntexte");
    }

    #[test]
    fn set_keys_rewrites_only_those_keys() {
        let out = set_keys(NOTE, &[("statut", "relu"), ("revu", "2026-11-01")]);
        assert!(out.contains("statut: relu\n") && out.contains("revu: 2026-11-01\n"));
        assert!(
            out.contains("sujets: [audio, rust]\n")
                && out.ends_with("pipewire-rs parle directement à PipeWire.\n")
        );
        let added = set_keys("---\ntype: lab\n---\nx", &[("statut", "relu")]);
        assert_eq!(added, "---\ntype: lab\nstatut: relu\n---\nx");
        let fresh = set_keys("corps", &[("statut", "relu")]);
        assert_eq!(fresh, "---\nstatut: relu\n---\n\ncorps");
    }

    #[test]
    fn today_is_a_date() {
        let t = today();
        assert_eq!(t.len(), 10);
        assert!(t.starts_with("20"));
    }

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("anna-kn-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn index_skips_templates_hidden_and_vault_rules() {
        let v = temp("index");
        for (rel, text) in [
            ("Recherche/cpal.md", NOTE),
            ("claude/2026-10-15-x-1.md", "---\nsession: 1\n---\n# x"),
            ("_templates/recherche.md", "---\ntype: recherche\n---"),
            (".obsidian/x.md", "x"),
            ("CLAUDE.md", "# règles"),
            ("Skills/fft/SKILL.md", "---\nname: fft\n---\nx"),
        ] {
            let p = v.join(rel);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, text).unwrap();
        }
        let mut kinds: Vec<String> = index_in(&v).into_iter().map(|n| n.kind).collect();
        kinds.sort();
        assert_eq!(kinds, ["journal", "recherche", "skill"]);
        let _ = std::fs::remove_dir_all(&v);
    }

    #[test]
    fn skills_are_linked_and_unlinked_without_touching_the_rest() {
        let v = temp("skills");
        let source = v.join("Skills");
        let dir = v.join("claude-skills");
        std::fs::create_dir_all(source.join("fft")).unwrap();
        std::fs::write(source.join("fft/SKILL.md"), "x").unwrap();
        std::fs::create_dir_all(source.join("brouillon")).unwrap(); // no SKILL.md
        std::fs::create_dir_all(dir.join("synced")).unwrap(); // not ours

        assert_eq!(link_skills_from(&source, &dir), 1);
        assert!(dir.join("fft/SKILL.md").is_file());
        assert!(!dir.join("brouillon").exists());
        assert_eq!(link_skills_from(&source, &dir), 0, "idempotent");

        std::fs::remove_dir_all(source.join("fft")).unwrap();
        assert_eq!(link_skills_from(&source, &dir), 1, "dangling link removed");
        assert!(dir.join("fft").symlink_metadata().is_err());
        assert!(dir.join("synced").is_dir(), "never touched");
        let _ = std::fs::remove_dir_all(&v);
    }

    #[test]
    fn paths_cannot_leave_the_vault() {
        assert!(resolve("../.ssh/id_ed25519").is_err());
        assert!(resolve("/etc/passwd").is_err());
        assert!(resolve("").is_err());
    }
}
