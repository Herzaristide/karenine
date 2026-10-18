//! The isolated copies Claude Code works in, and what to do with their work.
//!
//! `claude --worktree <name>` (how the AI dock starts project sessions) makes
//! a git worktree at `<repo>/.claude/worktrees/<name>` on a new branch
//! `worktree-<name>`, and runs the session there. The session's cwd alone thus
//! says everything: which repository, which copy, which branch — even for a
//! session resumed later in a terminal, or after anna restarted.
//!
//! Once the session is done, its work is reviewed from the dock:
//!   review   — which files changed, by how much, and commits ahead of the
//!              repository's current branch;
//!   commit   — record everything in the copy, on its branch;
//!   merge    — bring the branch into the repository's current branch, then
//!              remove the copy and its branch;
//!   discard  — remove the copy and its branch, work included.

use serde::Serialize;
use std::path::Path;
use std::process::Command;

const MARKER: &str = "/.claude/worktrees/";

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Worktree {
    /// The repository the copy belongs to.
    pub repo: String,
    /// The copy's name (its directory).
    pub name: String,
    /// Its branch, as `claude --worktree` names it.
    pub branch: String,
}

/// The worktree a session works in, from its cwd (the copy itself or a
/// directory inside it).
pub fn parse(cwd: &str) -> Option<Worktree> {
    let at = cwd.find(MARKER)?;
    let repo = &cwd[..at];
    let name = cwd[at + MARKER.len()..].split('/').next()?;
    if repo.is_empty() || name.is_empty() {
        return None;
    }
    Some(Worktree {
        repo: repo.to_string(),
        name: name.to_string(),
        branch: format!("worktree-{name}"),
    })
}

impl Worktree {
    pub fn path(&self) -> String {
        format!("{}{MARKER}{}", self.repo, self.name)
    }

    pub fn repo_name(&self) -> String {
        Path::new(&self.repo)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    }
}

/// A name for a new copy: the prompt's first words, then a short suffix so
/// two sessions on the same subject don't collide.
pub fn name_for(prompt: &str, suffix: &str) -> String {
    let words: Vec<String> = prompt
        .split_whitespace()
        .map(|w| {
            w.chars()
                .filter_map(|c| {
                    let c = fold_accent(c.to_ascii_lowercase());
                    c.is_ascii_alphanumeric().then_some(c)
                })
                .collect::<String>()
        })
        .filter(|w| w.len() > 2)
        .take(4)
        .collect();
    let base = if words.is_empty() {
        "session".to_string()
    } else {
        words.join("-")
    };
    format!("{base}-{suffix}")
}

/// The French accents a prompt is likely to carry, folded to ASCII for a
/// branch name.
fn fold_accent(c: char) -> char {
    match c {
        'à' | 'â' | 'ä' => 'a',
        'é' | 'è' | 'ê' | 'ë' => 'e',
        'î' | 'ï' => 'i',
        'ô' | 'ö' => 'o',
        'ù' | 'û' | 'ü' => 'u',
        'ç' => 'c',
        _ => c,
    }
}

fn git(dir: &str, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .map_err(|e| format!("git: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

#[derive(Debug, Serialize, PartialEq)]
pub struct FileChange {
    /// Two-letter porcelain status ("M ", "??", "A "…), trimmed.
    pub status: String,
    pub path: String,
    pub added: u64,
    pub removed: u64,
}

#[derive(Debug, Serialize)]
pub struct Review {
    pub worktree: Worktree,
    /// The repository's current branch, what `merge` targets.
    pub base: String,
    /// Commits on the copy's branch not in `base`.
    pub ahead: u64,
    /// Uncommitted changes in the copy.
    pub files: Vec<FileChange>,
}

/// `git status --porcelain` + `git diff --numstat HEAD`, merged per path.
fn changes(porcelain: &str, numstat: &str) -> Vec<FileChange> {
    let counts: std::collections::HashMap<&str, (u64, u64)> = numstat
        .lines()
        .filter_map(|l| {
            let mut f = l.splitn(3, '\t');
            let add = f.next()?.parse().unwrap_or(0);
            let del = f.next()?.parse().unwrap_or(0);
            Some((f.next()?, (add, del)))
        })
        .collect();
    porcelain
        .lines()
        .filter(|l| l.len() > 3)
        .map(|l| {
            let path = l[3..].rsplit(" -> ").next().unwrap_or(&l[3..]).to_string();
            let (added, removed) = counts.get(path.as_str()).copied().unwrap_or((0, 0));
            FileChange {
                status: l[..2].trim().to_string(),
                path,
                added,
                removed,
            }
        })
        .collect()
}

pub fn review(cwd: &str) -> Result<Review, String> {
    let wt = parse(cwd).ok_or_else(|| crate::i18n::tr("worktree.not_isolated"))?;
    let path = wt.path();
    let base = git(&wt.repo, &["rev-parse", "--abbrev-ref", "HEAD"])?
        .trim()
        .to_string();
    let ahead = git(&path, &["rev-list", "--count", &format!("{base}..HEAD")])
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(0);
    let porcelain = git(&path, &["status", "--porcelain=v1", "-uall"])?;
    let numstat = git(&path, &["diff", "--numstat", "HEAD"]).unwrap_or_default();
    let mut files = changes(&porcelain, &numstat);
    // git counts nothing for a file it doesn't track yet: all its lines are
    // new. Large files are left uncounted.
    for f in files.iter_mut().filter(|f| f.status == "??") {
        let p = Path::new(&path).join(&f.path);
        if std::fs::metadata(&p).is_ok_and(|m| m.len() < 1 << 20) {
            if let Ok(text) = std::fs::read_to_string(&p) {
                f.added = text.lines().count() as u64;
            }
        }
    }
    Ok(Review {
        files,
        worktree: wt,
        base,
        ahead,
    })
}

pub fn commit(cwd: &str, message: &str) -> Result<(), String> {
    let wt = parse(cwd).ok_or_else(|| crate::i18n::tr("worktree.not_isolated"))?;
    let path = wt.path();
    git(&path, &["add", "-A"])?;
    let msg = if message.trim().is_empty() {
        crate::i18n::tr_args("worktree.commit_message", &[("name", &wt.name)])
    } else {
        message.trim().to_string()
    };
    git(&path, &["commit", "-m", &msg])?;
    Ok(())
}

pub fn discard(cwd: &str) -> Result<(), String> {
    let wt = parse(cwd).ok_or_else(|| crate::i18n::tr("worktree.not_isolated"))?;
    // Twice: `claude --worktree` locks the copies it makes.
    git(
        &wt.repo,
        &["worktree", "remove", "--force", "--force", &wt.path()],
    )?;
    git(&wt.repo, &["branch", "-D", &wt.branch])?;
    Ok(())
}

/// Merge the copy's committed work into the repository's current branch.
/// Refuses rather than guesses: uncommitted work in the copy, uncommitted
/// changes in the repository, or a conflicting merge (aborted) all leave
/// everything as it was.
pub fn merge(cwd: &str) -> Result<(), String> {
    let r = review(cwd)?;
    if !r.files.is_empty() {
        return Err(crate::i18n::tr("worktree.uncommitted"));
    }
    if r.ahead == 0 {
        return Err(crate::i18n::tr("worktree.nothing_to_merge"));
    }
    let dirty = git(
        &r.worktree.repo,
        &["status", "--porcelain", "--untracked-files=no"],
    )?;
    if !dirty.trim().is_empty() {
        return Err(crate::i18n::tr_args(
            "worktree.repo_dirty",
            &[("repo", &r.worktree.repo_name())],
        ));
    }
    if let Err(e) = git(
        &r.worktree.repo,
        &["merge", "--no-ff", "--no-edit", &r.worktree.branch],
    ) {
        let _ = git(&r.worktree.repo, &["merge", "--abort"]);
        return Err(crate::i18n::tr_args(
            "worktree.merge_failed",
            &[("error", &e)],
        ));
    }
    discard(cwd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_claude_worktree_paths() {
        let wt = parse("/home/u/ciph3r/karenine/.claude/worktrees/fix-dock/anna").unwrap();
        assert_eq!(wt.repo, "/home/u/ciph3r/karenine");
        assert_eq!(wt.name, "fix-dock");
        assert_eq!(wt.branch, "worktree-fix-dock");
        assert_eq!(
            wt.path(),
            "/home/u/ciph3r/karenine/.claude/worktrees/fix-dock"
        );
        assert_eq!(wt.repo_name(), "karenine");
        assert!(parse("/home/u/ciph3r/karenine").is_none());
        assert!(parse("/home/u/ciph3r/karenine/.claude/worktrees/").is_none());
    }

    #[test]
    fn names_come_from_the_prompt() {
        assert_eq!(
            name_for("Corrige le dock qui s'ouvre tout seul", "a1b2"),
            "corrige-dock-qui-souvre-a1b2"
        );
        assert_eq!(name_for("é à ?", "ff00"), "session-ff00");
        assert_eq!(
            name_for("Améliore la fenêtre", "0001"),
            "ameliore-fenetre-0001"
        );
    }

    #[test]
    fn changes_merge_status_and_counts() {
        let porcelain = " M src/a.rs\n?? notes.md\nR  old.rs -> new.rs\n";
        let numstat = "3\t1\tsrc/a.rs\n0\t0\tnew.rs\n";
        let c = changes(porcelain, numstat);
        assert_eq!(c.len(), 3);
        assert_eq!(
            c[0],
            FileChange {
                status: "M".into(),
                path: "src/a.rs".into(),
                added: 3,
                removed: 1
            }
        );
        assert_eq!((c[1].status.as_str(), c[1].added), ("??", 0));
        assert_eq!(c[2].path, "new.rs");
    }

    /// The whole cycle on a real repository: a copy made the way
    /// `claude --worktree` makes it, reviewed, committed, merged.
    #[test]
    fn review_commit_merge_on_a_real_repo() {
        // The Nix build sandbox has no git: nothing to test there.
        if Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let dir = std::env::temp_dir().join(format!("anna-wt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let repo = dir.to_string_lossy().to_string();
        let g = |d: &str, a: &[&str]| {
            let mut args = vec![
                "-c",
                "user.email=t@t",
                "-c",
                "user.name=t",
                "-c",
                "commit.gpgsign=false",
            ];
            args.extend_from_slice(a);
            git(d, &args).unwrap()
        };
        g(&repo, &["init", "-q", "-b", "main"]);
        // The merge commit is made by anna's own `git`, without -c: the
        // identity has to live in the repository.
        g(&repo, &["config", "user.email", "t@t"]);
        g(&repo, &["config", "user.name", "t"]);
        // The user's own config may sign commits with a locked key.
        g(&repo, &["config", "commit.gpgsign", "false"]);
        std::fs::write(dir.join("a.txt"), "a\n").unwrap();
        g(&repo, &["add", "."]);
        g(&repo, &["commit", "-qm", "init"]);
        let wt_path = format!("{repo}/.claude/worktrees/essai");
        g(
            &repo,
            &["worktree", "add", "-q", "-b", "worktree-essai", &wt_path],
        );
        g(&repo, &["worktree", "lock", &wt_path]);

        std::fs::write(format!("{wt_path}/a.txt"), "a\nb\n").unwrap();
        std::fs::write(format!("{wt_path}/new.md"), "1\n2\n3\n").unwrap();
        let r = review(&wt_path).unwrap();
        assert_eq!((r.base.as_str(), r.ahead), ("main", 0));
        assert_eq!(r.files.len(), 2);
        assert_eq!((r.files[0].added, r.files[0].removed), (1, 0));
        assert_eq!(
            (r.files[1].status.as_str(), r.files[1].added),
            ("??", 3),
            "a new file counts all its lines"
        );
        assert!(merge(&wt_path).is_err(), "uncommitted work is not merged");

        commit(&wt_path, "ajoute b").unwrap();
        let r = review(&wt_path).unwrap();
        assert_eq!((r.ahead, r.files.len()), (1, 0));

        merge(&wt_path).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join("a.txt")).unwrap(),
            "a\nb\n"
        );
        assert!(!Path::new(&wt_path).exists(), "the copy is gone");
        assert!(git(&repo, &["rev-parse", "--verify", "worktree-essai"]).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
