/// Live-reload signals sent to running apps after a color change.
/// Sends reload signals to all theme-aware tools after an accent/palette change.
use crate::icons;
use crate::state::AppState;
use std::process::Command;

#[derive(Clone, Copy, Default)]
pub struct AppCtlOptions {
    pub no_hyprctl: bool,
}

/// Run all live-reload steps. Errors in individual steps are logged but do
/// not abort the others — same behaviour as the `|| true` guards in bash.
pub fn reload_all(state: &AppState, opts: &AppCtlOptions) {
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
    // GTK4 / Vesktop / Micro / Fastfetch: next launch.
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
