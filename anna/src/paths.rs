//! Filesystem locations shared by the daemon, the CLI client and the helpers,
//! so they always agree.

use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;

/// `$HOME`, falling back to `/root` when unset (system services).
pub fn home_dir() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/root".into()))
}

/// Theme state + rendered fragments: `~/.config/accent`.
pub fn accent_dir() -> PathBuf {
    home_dir().join(".config/accent")
}

/// `XDG_<key>_DIR` from `~/.config/user-dirs.dirs` (`PICTURES`, `MUSIC`…),
/// else `~/<fallback>`.
pub fn user_dir(key: &str, fallback: &str) -> PathBuf {
    let home = home_dir();
    let prefix = format!("XDG_{key}_DIR=");
    std::fs::read_to_string(home.join(".config/user-dirs.dirs"))
        .ok()
        .and_then(|text| {
            text.lines()
                .find_map(|l| l.trim().strip_prefix(prefix.as_str()).map(str::to_string))
                .map(|v| {
                    v.trim_matches('"')
                        .replace("$HOME", &home.to_string_lossy())
                })
        })
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(fallback))
}

/// karenine's cache: `$XDG_CACHE_HOME/karenine`, else `~/.cache/karenine`.
pub fn cache_dir() -> PathBuf {
    std::env::var("XDG_CACHE_HOME")
        .ok()
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".cache"))
        .join("karenine")
}

/// Path to the anna control socket: `$XDG_RUNTIME_DIR/anna.sock`.
pub fn socket_path() -> String {
    format!("{}/anna.sock", runtime_dir())
}

/// `$XDG_RUNTIME_DIR`, or `/run/user/<uid>` for the current user when unset.
pub fn runtime_dir() -> String {
    std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .filter(|d| !d.is_empty())
        .unwrap_or_else(|| format!("/run/user/{}", current_uid()))
}

/// The process owns `/proc/self`, so its owner is our uid — no libc needed.
fn current_uid() -> u32 {
    std::fs::metadata("/proc/self")
        .map(|m| m.uid())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_lives_in_runtime_dir() {
        assert!(socket_path().ends_with("/anna.sock"));
        assert!(socket_path().starts_with(&runtime_dir()));
    }

    #[test]
    fn uid_matches_owned_files() {
        // A file we just created is owned by us.
        let p = std::env::temp_dir().join(format!("anna-uid-{}", std::process::id()));
        std::fs::write(&p, b"").unwrap();
        let owner = std::fs::metadata(&p).unwrap().uid();
        std::fs::remove_file(&p).unwrap();
        assert_eq!(owner, current_uid());
    }
}
