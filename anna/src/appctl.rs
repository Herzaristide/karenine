/// Live-reload signals sent to running apps after a color change.
/// Sends reload signals to all theme-aware tools after an accent/palette change.
use crate::icons;
use crate::state::AppState;
use std::collections::BTreeSet;
use std::fs;
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::process::Command;

#[derive(Clone, Copy, Default)]
pub struct AppCtlOptions {
    pub no_hyprctl: bool,
}

/// Run all live-reload steps. Errors in individual steps are logged but do
/// not abort the others — same behaviour as the `|| true` guards in bash.
pub fn reload_all(state: &AppState, opts: &AppCtlOptions) {
    // The terminals first: they only need their rendered fragments, and
    // every step below blocks (icons above all), which made kitty and foot
    // trail Alacritty, which reloads on the file write itself.
    reload_kitty();
    reload_foot(state);
    if !opts.no_hyprctl {
        reload_hyprland(state);
    }
    // Icons first: the IconChanged signal sent by reload_kde must find them
    // regenerated.
    reload_icons(state);
    reload_kde(state);
    reload_color_scheme(state);
    // Alacritty: auto-reloads via `general.import` file watch.
    // Starship / fish: picks up on next prompt (STARSHIP_CONFIG env var).
    // Vesktop: Vencord watches quickCss.css and re-injects it live.
    // GTK4 / Micro / Fastfetch: next launch.
}

// ── Hyprland ──────────────────────────────────────────────────────────────

fn reload_hyprland(_state: &AppState) {
    // `hyprctl keyword general:col.active_border` does not work reliably in
    // Hyprland's Lua config mode.  Instead, trigger a full config reload:
    // the fragment at ~/.config/accent/fragments/hyprland-colors.lua has
    // already been re-rendered by render_all() before this is called, so
    // the top-level `hl.config()` in hyprland.lua will pick up the new color.
    let _ = Command::new("hyprctl").arg("reload").output();
}

// ── kitty ─────────────────────────────────────────────────────────────────

fn reload_kitty() {
    // kitty watches kitty.conf itself (auto_reload_config), but the docs do
    // not say the watch covers an `include`d file: SIGUSR1 makes every kitty
    // process re-read its whole config, colours included, either way.
    for pid in processes_named("kitty") {
        let _ = Command::new("kill")
            .args(["-USR1", &pid.to_string()])
            .output();
    }
}

// ── foot ──────────────────────────────────────────────────────────────────

/// foot reads its colours once, when a window opens, and has no reload. The
/// windows already open are recoloured the way pywal does it: the colours,
/// as OSC escape sequences, are written to the pty of the program each
/// window runs, which foot then interprets as if that program printed them.
/// The sequences come from the rendered fragment, so the template stays the
/// only place the colours are chosen.
fn reload_foot(state: &AppState) {
    let fragment = state.accent_dir.join("fragments/foot-colors.ini");
    let Ok(text) = fs::read_to_string(&fragment) else {
        return;
    };
    let seq = foot_osc(&text);
    if seq.is_empty() {
        return;
    }
    for pty in foot_ptys() {
        // O_NOCTTY: anna runs as a session leader without a terminal, and
        // opening a tty would otherwise make it anna's controlling terminal.
        // O_NONBLOCK: a frozen window must not hang the daemon.
        const O_NOCTTY: i32 = 0o400;
        const O_NONBLOCK: i32 = 0o4000;
        let file = fs::OpenOptions::new()
            .write(true)
            .custom_flags(O_NOCTTY | O_NONBLOCK)
            .open(&pty);
        if let Ok(mut file) = file {
            let _ = file.write_all(seq.as_bytes());
        }
    }
}

/// The OSC sequences for the `key=RRGGBB` lines of a foot colour section:
/// the 16 ANSI colours (OSC 4), foreground and background (10, 11), cursor
/// (12, its second value) and selection background and foreground (17, 19).
fn foot_osc(ini: &str) -> String {
    let rgb = |v: &str| -> Option<String> {
        let v = v.trim();
        (v.len() == 6 && v.chars().all(|c| c.is_ascii_hexdigit()))
            .then(|| format!("rgb:{}/{}/{}", &v[0..2], &v[2..4], &v[4..6]))
    };
    let mut out = String::new();
    for line in ini.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        let osc = if let Some(n) = key.strip_prefix("regular") {
            n.parse::<u8>()
                .ok()
                .filter(|n| *n < 8)
                .map(|n| format!("4;{n}"))
        } else if let Some(n) = key.strip_prefix("bright") {
            n.parse::<u8>()
                .ok()
                .filter(|n| *n < 8)
                .map(|n| format!("4;{}", n + 8))
        } else {
            match key {
                "foreground" => Some("10".into()),
                "background" => Some("11".into()),
                "selection-background" => Some("17".into()),
                "selection-foreground" => Some("19".into()),
                _ => None,
            }
        };
        let (osc, value) = match (osc, key) {
            (Some(osc), _) => (osc, value),
            // "TEXT CURSOR": the cursor's own colour is the second value.
            (None, "cursor") => ("12".into(), value.split_whitespace().nth(1).unwrap_or("")),
            _ => continue,
        };
        if let Some(color) = rgb(value) {
            out.push_str(&format!("\x1b]{osc};{color}\x1b\\"));
        }
    }
    out
}

/// The ptys of the programs foot windows run: the children of every `foot`
/// process (one per window, or the single `foot --server` for all of them),
/// found through their standard input.
fn foot_ptys() -> BTreeSet<String> {
    let foot: BTreeSet<u32> = processes_named("foot").into_iter().collect();
    let mut ptys = BTreeSet::new();
    if foot.is_empty() {
        return ptys;
    }
    for (pid, _, ppid) in processes() {
        if !foot.contains(&ppid) {
            continue;
        }
        if let Ok(target) = fs::read_link(format!("/proc/{pid}/fd/0")) {
            let target = target.to_string_lossy().into_owned();
            if target.starts_with("/dev/pts/") {
                ptys.insert(target);
            }
        }
    }
    ptys
}

/// Nix wraps most programs: the real process then runs as `.<name>-wrapped`
/// (kitty, for one), so both names count.
fn processes_named(name: &str) -> Vec<u32> {
    let wrapped = format!(".{name}-wrapped");
    processes()
        .into_iter()
        .filter(|(_, comm, _)| comm == name || *comm == wrapped)
        .map(|(pid, _, _)| pid)
        .collect()
}

/// (pid, command name, parent pid) of every process, from /proc/<pid>/stat.
fn processes() -> Vec<(u32, String, u32)> {
    let Ok(dir) = fs::read_dir("/proc") else {
        return Vec::new();
    };
    dir.flatten()
        .filter_map(|e| e.file_name().to_str()?.parse::<u32>().ok())
        .filter_map(|pid| {
            let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            let (comm, ppid) = parse_stat(&stat)?;
            Some((pid, comm, ppid))
        })
        .collect()
}

/// `pid (comm) state ppid …`: the name sits between the first `(` and the
/// last `)`, since it may itself hold spaces or parentheses.
fn parse_stat(stat: &str) -> Option<(String, u32)> {
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let comm = stat.get(open + 1..close)?.to_string();
    let ppid = stat
        .get(close + 1..)?
        .split_whitespace()
        .nth(1)?
        .parse()
        .ok()?;
    Some((comm, ppid))
}

// ── KDE / Qt app reload ───────────────────────────────────────────────────

fn reload_kde(_state: &AppState) {
    // Broadcast KGlobalSettings signals so running Qt/KDE apps (Dolphin, Ark…)
    // re-read kdeglobals without needing a restart (KGlobalSettings::ChangeType):
    //   0 = PaletteChanged
    //   4 = IconChanged
    // PaletteChanged also reaches xdg-desktop-portal-kde: its color-scheme is
    // its own palette's, so it then tells every portal client (Chromium,
    // Electron, GTK4) that dark or light changed, live. Without it they kept
    // the mode the portal started with until the next login.
    for int_val in ["0", "4"] {
        let _ = Command::new("dbus-send")
            .args([
                "--session",
                "--type=signal",
                "/KGlobalSettings",
                "org.kde.KGlobalSettings.notifyChange",
                &format!("int32:{int_val}"),
                "int32:0",
            ])
            .output();
    }
}

// ── GSettings color-scheme ────────────────────────────────────────────────

fn reload_color_scheme(state: &AppState) {
    // The GNOME key GTK apps and the gtk portal read; home-manager only seeds
    // it (dconf.settings), the mode switch is anna's.
    let scheme = if state.mode == "light" {
        "'prefer-light'"
    } else {
        "'prefer-dark'"
    };
    let _ = Command::new("dconf")
        .args(["write", "/org/gnome/desktop/interface/color-scheme", scheme])
        .output();
}

// ── Icon theme ────────────────────────────────────────────────────────────

fn reload_icons(state: &AppState) {
    match icons::refresh(state) {
        // GTK: bounce the icon-theme key so running apps drop their cached
        // icons. Qt is told by reload_kde's IconChanged, which runs after.
        Ok(true) => {
            let key = "/org/gnome/desktop/interface/icon-theme";
            let variant = if state.mode == "light" {
                "Reversal"
            } else {
                "Reversal-dark"
            };
            for value in [variant, icons::THEME_NAME] {
                let _ = Command::new("dconf")
                    .args(["write", key, &format!("'{value}'")])
                    .output();
            }
        }
        Ok(false) => {}
        Err(e) => eprintln!("anna: icon theme warning: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foot_colours_become_osc_sequences() {
        let ini = "# comment\n[colors-dark]\nbackground=1b1a18\nforeground=d5c4a1\n\
                   cursor=1b1a18 5277c3\nselection-background=d5c4a1\nurls=5277c3\n\
                   regular1=5277c3\nbright7=ffffff\nregular9=000000\n";
        assert_eq!(
            foot_osc(ini),
            "\x1b]11;rgb:1b/1a/18\x1b\\\x1b]10;rgb:d5/c4/a1\x1b\\\x1b]12;rgb:52/77/c3\x1b\\\
             \x1b]17;rgb:d5/c4/a1\x1b\\\x1b]4;1;rgb:52/77/c3\x1b\\\x1b]4;15;rgb:ff/ff/ff\x1b\\"
        );
    }

    #[test]
    fn every_foot_template_colour_is_sent() {
        let tmpl = include_str!("../templates/foot-colors.ini.tmpl").replace('@', "");
        // Tokens left as-is are not hex: substitute a colour for each one.
        let ini: String = tmpl
            .lines()
            .map(|l| match l.split_once('=') {
                Some((k, v)) => {
                    let v = v
                        .split_whitespace()
                        .map(|_| "112233")
                        .collect::<Vec<_>>()
                        .join(" ");
                    format!("{k}={v}\n")
                }
                None => format!("{l}\n"),
            })
            .collect();
        // 16 ANSI colours, foreground, background, cursor, selection ×2.
        assert_eq!(foot_osc(&ini).matches("\x1b]").count(), 21);
    }

    #[test]
    fn stat_name_may_hold_spaces_and_parentheses() {
        assert_eq!(
            parse_stat("4242 (foot) S 1200 4242 4242 0 -1"),
            Some(("foot".into(), 1200))
        );
        assert_eq!(
            parse_stat("7 (a (b) c) R 3 7 7"),
            Some(("a (b) c".into(), 3))
        );
    }
}
