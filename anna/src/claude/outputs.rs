//! What a Claude Code session produced, to look at or reuse: the « Outputs »
//! pane of the « Claude » tab (the source code it wrote is in « Changes »).
//!
//! - every file of `~/lens/<project>`, `~/mesh/<project>` and
//!   `~/tune/<project>` written while the session was active, whatever wrote
//!   it. Two sessions of a project active together both show it: nothing on
//!   disk says which one it came from;
//! - the images, sounds, videos, 3D models and office documents named by a
//!   command, an MCP call or their results, when they were written while
//!   the session was active (naming a file is not enough);
//! - the documents (Markdown, HTML…) and media it created with `Write`,
//!   still shown once deleted;
//! - the artifacts it published on claude.ai.
//!
//! Active: the stretches between its transcript's lines, cut where nothing
//! was written for `GAP`, so that a session resumed a week later does not
//! claim the week.

use serde::Serialize;
use serde_json::Value;
use std::collections::HashSet;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A silence longer than this ends a stretch (a long render fits in it).
const GAP: i64 = 30 * 60;
/// A file may be written this long after a stretch's last line.
const SLACK: i64 = 120;
/// Paths remembered, directory entries looked at, and text searched per
/// call, at most.
const PATHS_MAX: usize = 2_000;
const ENTRIES_MAX: usize = 3_000;
const TEXT_MAX: usize = 200_000;
const DEPTH_MAX: usize = 4;

/// Results by nature, wherever they are written.
const MEDIA: &[&str] = &[
    "png", "jpg", "jpeg", "webp", "gif", "bmp", "tif", "tiff", "exr", "hdr", "avif", "mp4", "webm",
    "mkv", "mov", "avi", "wav", "flac", "mp3", "ogg", "opus", "m4a", "mid", "midi", "glb", "gltf",
    "ply", "obj", "stl", "fbx", "usdz", "usd", "blend", "splat", "spz", "pdf", "docx", "xlsx",
    "pptx", "odt", "ods", "odp", "epub",
];
/// Documents (and SVG, mostly icons): outputs when created with `Write` only,
/// since commands name
/// the project's own all the time.
const DOCUMENTS: &[&str] = &[
    "svg", "md", "html", "htm", "txt", "csv", "tex", "typ", "rtf",
];

#[derive(Serialize, Clone, Default, Debug, PartialEq)]
pub struct Output {
    /// A file, or "" for an artifact.
    pub path: String,
    pub exists: bool,
    pub size: u64,
    /// Seconds since the epoch, 0 once deleted.
    pub modified: i64,
    /// An artifact's address and title.
    pub url: String,
    pub title: String,
}

#[derive(Default)]
pub struct Finder {
    paths: Vec<String>,
    seen: HashSet<String>,
    written: Vec<String>,
    links: Vec<Output>,
    spans: Vec<(i64, i64)>,
}

fn extension(path: &str) -> String {
    Path::new(path)
        .extension()
        .map(|e| e.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default()
}

/// Files nobody calls a result: the tools' own, and the pictures the user
/// takes with the shell.
fn ignored(path: &Path, home: &Path) -> bool {
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    path.starts_with("/nix")
        || path.starts_with("/proc")
        || path.starts_with(home.join(".claude"))
        || path.starts_with(home.join(".cache/karenine"))
        || (path.parent() == Some(&home.join("lens"))
            && (name.starts_with("capture-") || name.starts_with("ecran-")))
        || path.components().any(|c| {
            matches!(c, Component::Normal(n) if n == ".git" || n == "node_modules" || n == "target")
        })
}

/// `path` without its `.` and `..`, so that one file has one name.
fn clean(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            c => out.push(c),
        }
    }
    out
}

fn secs(t: std::io::Result<SystemTime>) -> Option<i64> {
    let d = t.ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some(d.as_secs() as i64)
}

impl Finder {
    /// A line was written at `ts` (ISO 8601).
    pub fn time(&mut self, ts: &str) {
        let Some(t) = crate::google::calendar::rfc3339(ts).map(|s| s.epoch()) else {
            return;
        };
        match self.spans.last_mut() {
            // The lines are not always in order, by a little.
            Some((_, end)) if t <= *end + GAP => *end = (*end).max(t),
            _ => self.spans.push((t, t)),
        }
    }

    fn active(&self, t: i64) -> bool {
        self.spans
            .iter()
            .any(|(from, to)| (*from - 1..=*to + SLACK).contains(&t))
    }

    /// Every string of a call's input.
    pub fn mention_value(&mut self, v: &Value, cwd: &str, home: &Path) {
        match v {
            Value::String(t) => self.mention(t, cwd, home),
            Value::Array(a) => a.iter().for_each(|v| self.mention_value(v, cwd, home)),
            Value::Object(o) => o.values().for_each(|v| self.mention_value(v, cwd, home)),
            _ => {}
        }
    }

    /// The results named in `text`, a command or an output.
    pub fn mention(&mut self, text: &str, cwd: &str, home: &Path) {
        let text: String = text.chars().take(TEXT_MAX).collect();
        let delimiter = |c: char| c.is_whitespace() || "\"'`()<>|;,&=[]{}\\*".contains(c);
        for token in text.split(delimiter) {
            let token = token.trim_end_matches(['.', ':', '!', '?']);
            if token.len() > 1_000 || !MEDIA.contains(&extension(token).as_str()) {
                continue;
            }
            let token = token.strip_prefix("file://").unwrap_or(token);
            if token.contains("://") {
                continue;
            }
            let path = if let Some(rest) = token
                .strip_prefix("~/")
                .or_else(|| token.strip_prefix("$HOME/"))
            {
                home.join(rest)
            } else if token.contains(['$', '~']) || (cwd.is_empty() && !token.starts_with('/')) {
                continue;
            } else {
                Path::new(cwd).join(token)
            };
            let path = clean(&path);
            let name = path.to_string_lossy().into_owned();
            if self.paths.len() < PATHS_MAX
                && !ignored(&path, home)
                && self.seen.insert(name.clone())
            {
                self.paths.push(name);
            }
        }
    }

    /// Created with `Write`.
    pub fn wrote(&mut self, path: &str, home: &Path) {
        let ext = extension(path);
        let result = MEDIA.contains(&ext.as_str()) || DOCUMENTS.contains(&ext.as_str());
        if result && !ignored(Path::new(path), home) && !self.written.iter().any(|p| p == path) {
            self.written.push(path.to_string());
        }
    }

    /// An `Artifact` call and its result: the page published, or deleted.
    pub fn artifact(&mut self, input: &Value, result: &str) {
        let get = |k: &str| input.get(k).and_then(Value::as_str).unwrap_or_default();
        match get("action") {
            "" | "publish" => {}
            "delete" => {
                // With a path, only one of its assets goes.
                if get("path").is_empty() {
                    self.links.retain(|l| l.url != get("url"));
                }
                return;
            }
            _ => return,
        }
        let Some(url) = link(result) else { return };
        let file = Path::new(get("file_path"))
            .file_stem()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let title = match get("title") {
            "" => file,
            t => t.to_string(),
        };
        match self.links.iter_mut().find(|l| l.url == url) {
            Some(l) if l.title.is_empty() => l.title = title,
            Some(_) => {}
            None => self.links.push(Output {
                url,
                title,
                exists: true,
                ..Default::default()
            }),
        }
    }

    /// The outputs, newest first: the artifacts, then the files. `project`
    /// is the session's folder name; `edited`, the files that existed before
    /// the session and that it edited (changes, not outputs).
    pub fn list(&self, project: &str, home: &Path, edited: &HashSet<String>) -> Vec<Output> {
        let mut found = Vec::new();
        let mut have = HashSet::new();
        for p in &self.written {
            let meta = std::fs::metadata(p).ok();
            // A scratch file, gone: nothing left to tell.
            if meta.is_none() && p.starts_with("/tmp/") {
                continue;
            }
            have.insert(p.clone());
            found.push(Output {
                path: p.clone(),
                exists: meta.is_some(),
                size: meta.as_ref().map(|m| m.len()).unwrap_or(0),
                modified: meta.and_then(|m| secs(m.modified())).unwrap_or(0),
                ..Default::default()
            });
        }
        let mut add = |path: &Path| {
            let name = path.to_string_lossy().into_owned();
            let Ok(meta) = std::fs::metadata(path) else {
                return;
            };
            let modified = secs(meta.modified()).unwrap_or(0);
            // A copy may keep its original's date: its birth tells then.
            let fresh =
                self.active(modified) || secs(meta.created()).is_some_and(|t| self.active(t));
            if meta.is_file() && fresh && !edited.contains(&name) && have.insert(name.clone()) {
                found.push(Output {
                    path: name,
                    exists: true,
                    size: meta.len(),
                    modified,
                    ..Default::default()
                });
            }
        };
        for p in &self.paths {
            add(Path::new(p));
        }
        if !project.is_empty() && !self.spans.is_empty() {
            let mut left = ENTRIES_MAX;
            for dir in ["lens", "mesh", "tune"] {
                walk(
                    &home.join(dir).join(project),
                    DEPTH_MAX,
                    &mut left,
                    &mut add,
                );
            }
        }
        found.sort_by(|a, b| b.modified.cmp(&a.modified).then(a.path.cmp(&b.path)));
        let mut out: Vec<Output> = self.links.iter().rev().cloned().collect();
        out.extend(found);
        out
    }
}

/// The files under `dir`, hidden ones and links to folders left out.
fn walk(dir: &Path, depth: usize, left: &mut usize, add: &mut impl FnMut(&Path)) {
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        if *left == 0 {
            return;
        }
        *left -= 1;
        if e.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        match e.file_type() {
            Ok(t) if t.is_dir() && depth > 1 => walk(&e.path(), depth - 1, left, add),
            Ok(t) if !t.is_dir() => add(&e.path()),
            _ => {}
        }
    }
}

/// The first artifact address of `text`.
fn link(text: &str) -> Option<String> {
    [
        "https://claude.ai/artifact/",
        "https://claude.ai/code/artifact/",
    ]
    .iter()
    .filter_map(|prefix| {
        let at = text.find(prefix)?;
        let id: String = text[at + prefix.len()..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '-')
            .collect();
        (!id.is_empty()).then(|| (at, format!("{prefix}{id}")))
    })
    .min()
    .map(|(_, url)| url)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn home(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("anna-outputs-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("lens/proj/sub")).unwrap();
        std::fs::create_dir_all(dir.join("code/proj")).unwrap();
        dir
    }

    fn now() -> i64 {
        secs(Ok(SystemTime::now())).unwrap()
    }

    fn paths(out: &[Output], home: &Path) -> Vec<String> {
        let mut p: Vec<String> = out
            .iter()
            .map(|o| o.path.replace(&format!("{}/", home.display()), ""))
            .collect();
        p.sort();
        p
    }

    #[test]
    fn named_results_and_project_folders_count_when_written_meanwhile() {
        let home = home("fresh");
        let cwd = home.join("code/proj").to_string_lossy().into_owned();
        for f in [
            "code/proj/out.png",
            "code/proj/main.rs",
            "code/proj/logo.png",
            "lens/proj/sub/shot.png",
            "lens/proj/.hidden",
            "lens/capture-1.png",
        ] {
            std::fs::write(home.join(f), "x").unwrap();
        }
        let mut f = Finder::default();
        f.mention("grim -g 1 ./out.png && cat main.rs logo.png", &cwd, &home);
        f.mention(
            "~/lens/capture-1.png https://x.org/a.png none.png $D/b.png",
            &cwd,
            &home,
        );
        let edited = HashSet::from([home
            .join("code/proj/logo.png")
            .to_string_lossy()
            .into_owned()]);
        // Not active when they were written: nothing.
        f.spans = vec![(1_000, 2_000)];
        assert!(f.list("proj", &home, &edited).is_empty());
        f.spans.push((now() - 60, now()));
        let out = f.list("proj", &home, &edited);
        assert_eq!(
            paths(&out, &home),
            ["code/proj/out.png", "lens/proj/sub/shot.png"]
        );
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn documents_written_count_and_code_does_not() {
        let home = PathBuf::from("/nonexistent/home");
        let mut f = Finder::default();
        for p in ["a.md", "b.rs", "c.svg", ".claude/plans/p.md"] {
            f.wrote(&home.join(p).to_string_lossy(), &home);
        }
        let out = f.list("", &home, &HashSet::new());
        assert_eq!(paths(&out, &home), ["a.md", "c.svg"]);
        assert!(out.iter().all(|o| !o.exists));
    }

    #[test]
    fn a_long_silence_cuts_the_activity() {
        let mut f = Finder::default();
        f.time("2026-11-01T10:00:00.000Z");
        f.time("2026-11-01T10:20:00.000Z");
        f.time("2026-11-08T10:00:00.000Z");
        f.time("bad");
        assert_eq!(f.spans.len(), 2);
        let first = f.spans[0];
        assert_eq!(first.1 - first.0, 1200);
        assert!(f.active(first.0 + 600) && !f.active(first.1 + 86_400));
    }

    #[test]
    fn published_artifacts_are_listed_once_until_deleted() {
        let mut f = Finder::default();
        let url = "https://claude.ai/artifact/5JGByCo";
        let said = format!("Published at {url}. Watching.");
        f.artifact(&json!({"file_path":"/t/plan.html"}), &said);
        f.artifact(&json!({"file_path":"/t/plan.html"}), &said);
        f.artifact(
            &json!({"action":"list"}),
            "https://claude.ai/artifact/other",
        );
        let out = f.list("", Path::new("/h"), &HashSet::new());
        assert_eq!(out.len(), 1);
        assert_eq!((out[0].url.as_str(), out[0].title.as_str()), (url, "plan"));
        f.artifact(&json!({"action":"delete","url":url}), "Deleted");
        assert!(f.list("", Path::new("/h"), &HashSet::new()).is_empty());
    }
}
