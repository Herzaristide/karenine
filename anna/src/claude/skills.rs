//! The vault's skills, kept active for Claude Code.
//!
//! The Obsidian vault (`~/v4ult`) holds the user's skills as
//! `Skills/<nom>/SKILL.md` (see the NixOS config,
//! home/modules/code/ia/savoir.nix). Claude Code only sees a skill linked at
//! the first level of `~/.claude/skills`, so every one gets a link there, and
//! links whose target left the vault are removed. Nothing else in
//! `~/.claude/skills` is touched.

use std::path::{Path, PathBuf};

pub fn vault() -> PathBuf {
    std::env::var_os("ANNA_VAULT")
        .map(PathBuf::from)
        .unwrap_or_else(|| crate::paths::home_dir().join("v4ult"))
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

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("anna-kn-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
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
}
