//! The window that hosts a Claude Code session.
//!
//! The session only gives us its `claude` pid. The window is found by
//! walking up the process tree until a pid that Hyprland knows as a client:
//!
//!   claude → fish → alacritty
//!
//! A multiplexer whose server is daemonized (zellij, tmux) breaks that chain:
//! such a session has no window to find.

use std::collections::HashSet;
use std::process::Command;

/// Parent pid and command name from `/proc/<pid>/stat`. The name sits in
/// parentheses and may itself contain spaces or parentheses, so the fields
/// are read after the *last* `)`.
fn parse_stat(stat: &str) -> Option<(u32, String)> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let comm = stat.get(open + 1..close)?.to_string();
    let mut rest = stat.get(close + 1..)?.split_whitespace();
    let _state = rest.next()?;
    let ppid = rest.next()?.parse().ok()?;
    Some((ppid, comm))
}

pub fn parent_and_comm(pid: u32) -> Option<(u32, String)> {
    parse_stat(&std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?)
}

/// `pid` and its ancestors, nearest first, stopping before pid 1.
fn ancestry(pid: u32) -> Vec<u32> {
    let mut out = Vec::new();
    let mut p = pid;
    while p > 1 && out.len() < 64 {
        out.push(p);
        match parent_and_comm(p) {
            Some((pp, _)) => p = pp,
            None => break,
        }
    }
    out
}

fn hyprctl_json(what: &str) -> serde_json::Value {
    Command::new("hyprctl")
        .args([what, "-j"])
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice(&o.stdout).ok())
        .unwrap_or_default()
}

fn hyprland_client_pids() -> HashSet<u32> {
    hyprctl_json("clients")
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|c| c.get("pid")?.as_u64())
                .map(|p| p as u32)
                .collect()
        })
        .unwrap_or_default()
}

/// The pid of the Hyprland window hosting `pid`, if any.
pub fn window_pid(pid: u32) -> Option<u32> {
    let windows = hyprland_client_pids();
    ancestry(pid).into_iter().find(|p| windows.contains(p))
}

/// Focus the window hosting the `claude` process `pid`.
pub fn focus(pid: u32) -> Result<(), String> {
    let w = window_pid(pid).ok_or_else(|| crate::i18n::tr("window_not_found"))?;
    // Lua dispatcher syntax: Hyprland's Lua config rejects the legacy
    // `focuswindow pid:N` form (see gesture/output.rs).
    let out = Command::new("hyprctl")
        .args([
            "dispatch",
            &format!("hl.dsp.focus({{ window = \"pid:{w}\" }})"),
        ])
        .output()
        .map_err(|e| format!("hyprctl: {e}"))?;
    let text = String::from_utf8_lossy(&out.stdout);
    if text.contains("error") || text.contains("warning") {
        return Err(text.trim().to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stat_with_spaces_and_parens_in_name() {
        let s = "1234 (my (odd) name) S 99 1234 1234 0 -1";
        assert_eq!(parse_stat(s), Some((99, "my (odd) name".into())));
        assert_eq!(
            parse_stat("165532 (.claude-wrapped) S 164789 1 2"),
            Some((164789, ".claude-wrapped".into()))
        );
    }

    #[test]
    fn ancestry_of_self_reaches_up() {
        let me = std::process::id();
        let chain = ancestry(me);
        assert_eq!(chain[0], me);
        assert!(chain.len() >= 2, "a test process has a parent");
    }
}
