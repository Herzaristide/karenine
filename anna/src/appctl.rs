/// Live-reload signals sent to running apps after a color change.
/// Sends reload signals to all theme-aware tools after an accent/palette change.
use crate::state::AppState;
use std::fs;
use std::io;
use std::path::Path;
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
    reload_kde(state);
    reload_icons(state);
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
    // re-read kdeglobals without needing a restart.
    //   4 = IconChanged
    //   7 = PaletteChanged
    for int_val in ["4", "7"] {
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

// ── Folder icon recoloring ────────────────────────────────────────────────
//
// ── Arcanum-Accent ────────────────────────────────────────────────────────
// Builds ~/.local/share/icons/Arcanum-Accent/ by walking all SVGs from the
// base "Arcanum - Red" theme and replacing the two red accent stop-colors:
//   #ff6666 → accent.arcanum_bright()   (bright highlight, HSL H:accent S:100% L:70%)
//   #5a0d0d → accent.arcanum_dark()     (dark shadow,     HSL H:accent S:75%  L:20%)
// An index.theme is written that inherits "Arcanum - Red" so any icons not
// yet copied fall back to the red originals.
//
// ── Slot-Gray-Accent-Icons (legacy) ──────────────────────────────────────
// Builds ~/.local/share/icons/Slot-Gray-Accent-Icons/ by copying only the
// places/ subdirs from Slot-Gray-Dark-Icons and recoloring folder SVGs.

fn reload_icons(state: &AppState) {
    let home = crate::paths::home_dir();

    // Arcanum accent recoloring
    let arcanum_base = home.join(".local/share/icons/Arcanum - Red");
    let arcanum_accent = home.join(".local/share/icons/Arcanum-Accent");
    if arcanum_base.exists() {
        if let Err(e) = recolor_arcanum_icons(state, &arcanum_base, &arcanum_accent) {
            eprintln!("anna: arcanum icon recolor warning: {e}");
        } else {
            let _ = Command::new("gtk-update-icon-cache")
                .args(["-f", "-t", arcanum_accent.to_str().unwrap_or("")])
                .output();
        }
    }

    // Slot-Gray legacy recoloring
    let slot_base = home.join(".local/share/icons/Slot-Gray-Dark-Icons");
    let slot_accent = home.join(".local/share/icons/Slot-Gray-Accent-Icons");
    if slot_base.exists() {
        if let Err(e) = recolor_icons(state, &slot_base, &slot_accent) {
            eprintln!("anna: icon recolor warning: {e}");
        } else {
            let _ = Command::new("gtk-update-icon-cache")
                .args(["-f", "-t", slot_accent.to_str().unwrap_or("")])
                .output();
        }
    }
}

fn recolor_arcanum_icons(
    state: &AppState,
    arcanum_base: &Path,
    arcanum_accent: &Path,
) -> io::Result<()> {
    let bright = state.accent.arcanum_bright().hex_no_hash();
    let dark = state.accent.arcanum_dark().hex_no_hash();

    fs::create_dir_all(arcanum_accent)?;
    write_arcanum_accent_index(arcanum_accent)?;

    // Structure: <context>/<type>/*.svg  (e.g. apps/scalable/folder.svg)
    for ctx_entry in fs::read_dir(arcanum_base)?.flatten() {
        let ctx_path = ctx_entry.path();
        if !ctx_path.is_dir() {
            continue;
        }
        let ctx_name = ctx_path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        for type_entry in fs::read_dir(&ctx_path)?.flatten() {
            let type_path = type_entry.path();
            if !type_path.is_dir() {
                continue;
            }
            let type_name = type_path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let out_dir = arcanum_accent.join(&ctx_name).join(&type_name);
            fs::create_dir_all(&out_dir)?;

            for file_entry in fs::read_dir(&type_path)?.flatten() {
                let file_path = file_entry.path();
                if file_path.extension().and_then(|e| e.to_str()) != Some("svg") {
                    continue;
                }
                let fname = file_path
                    .file_name()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string();
                let content = fs::read_to_string(&file_path)?;
                let recolored = content
                    .replace("#ff6666", &format!("#{bright}"))
                    .replace("#5a0d0d", &format!("#{dark}"));
                fs::write(out_dir.join(&fname), recolored)?;
            }
        }
    }

    Ok(())
}

fn write_arcanum_accent_index(dir: &Path) -> io::Result<()> {
    let index = "[Icon Theme]\n\
Name=Arcanum-Accent\n\
Comment=Arcanum icon theme with accent-colored highlights (generated by anna)\n\
Inherits=Arcanum - Red,Adwaita,hicolor\n\
Example=x-directory-normal\n\
\n\
Directories=apps/scalable,categories/scalable,devices/scalable,places/scalable,places/symbolic,mimetypes/scalable,status/scalable\n\
\n\
[apps/scalable]\n\
Size=128\n\
Context=Applications\n\
Type=Scalable\n\
MinSize=16\n\
MaxSize=512\n\
\n\
[categories/scalable]\n\
Context=Categories\n\
Size=16\n\
MinSize=16\n\
MaxSize=512\n\
Type=Scalable\n\
\n\
[devices/scalable]\n\
Size=128\n\
Context=Actions\n\
Type=Scalable\n\
MinSize=22\n\
MaxSize=128\n\
\n\
[places/scalable]\n\
Context=Places\n\
Size=64\n\
MinSize=22\n\
MaxSize=512\n\
Type=Scalable\n\
\n\
[places/symbolic]\n\
Context=Places\n\
Size=16\n\
MinSize=16\n\
MaxSize=512\n\
Type=Scalable\n\
\n\
[mimetypes/scalable]\n\
Size=512\n\
Context=MimeTypes\n\
Type=Scalable\n\
MinSize=16\n\
MaxSize=512\n\
\n\
[status/scalable]\n\
Context=Status\n\
Size=64\n\
MinSize=8\n\
MaxSize=512\n\
Type=Scalable\n";
    fs::write(dir.join("index.theme"), index)
}

// ── Slot-Gray legacy icon recoloring ─────────────────────────────────────
//
// Builds ~/.local/share/icons/Slot-Gray-Accent-Icons/ by copying the places/
// subdirs from Slot-Gray-Dark-Icons and recoloring folder SVGs to the
// current accent, then refreshes the icon cache.

fn recolor_icons(state: &AppState, slot_base: &Path, slot_accent: &Path) -> io::Result<()> {
    let hex = state.accent.hex_no_hash();

    fs::create_dir_all(slot_accent)?;

    // Write index.theme
    write_icon_theme_index(slot_accent)?;

    // Walk size dirs
    let read_dir = fs::read_dir(slot_base)?;
    for entry in read_dir.flatten() {
        let size_dir = entry.path();
        if !size_dir.is_dir() {
            continue;
        }
        let places_dir = size_dir.join("places");
        if !places_dir.is_dir() {
            continue;
        }

        let sname = size_dir.file_name().unwrap_or_default().to_string_lossy();
        let out_places = slot_accent.join(sname.as_ref()).join("places");
        fs::create_dir_all(&out_places)?;

        for svg_entry in fs::read_dir(&places_dir)?.flatten() {
            let svg_path = svg_entry.path();
            if svg_path.extension().and_then(|e| e.to_str()) != Some("svg") {
                continue;
            }

            let bname = svg_path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let content = fs::read_to_string(&svg_path)?;

            let recolored = if is_default_folder(&bname) {
                // Large sizes: replace the original gold tone #5b72f6 + CSS
                // fallback colours used by symbolic icons
                content
                    .replace("#5b72f6", &format!("#{hex}"))
                    .replace("fill:currentColor", &format!("fill:#{hex}"))
                    .replace("color:#eff0f1", &format!("color:#{hex}"))
                    // Strip KDE ColorScheme class attributes — not needed outside KDE
                    .replace(r#"class="ColorScheme-Text""#, "")
                    .replace(r#"class="ColorScheme-Highlight""#, "")
                    .replace(r#"class="ColorScheme-ButtonBackground""#, "")
                    .replace("id=\"current-color-scheme\"", "id=\"static-color\"")
            } else {
                // Non-folder icons: only swap the accent color if present
                content.replace("#5b72f6", &format!("#{hex}"))
            };

            fs::write(out_places.join(&bname), recolored)?;
        }
    }

    Ok(())
}

/// Returns true for SVG filenames that represent the "default folder" set
/// (the ones that should be recolored to the accent).
fn is_default_folder(name: &str) -> bool {
    matches!(
        name,
        "folder.svg"
            | "folder-open.svg"
            | "user-home.svg"
            | "user-desktop.svg"
            | "stock_folder.svg"
            | "user-trash.svg"
            | "user-trash-full.svg"
    ) || name.starts_with("folder-")
}

fn write_icon_theme_index(slot_accent: &Path) -> io::Result<()> {
    let index = "[Icon Theme]\n\
Name=Slot-Gray-Accent-Icons\n\
Comment=Slot Gray Dark with accent-colored default folders\n\
Inherits=Slot-Gray-Dark-Icons,breeze-dark,Adwaita,hicolor\n\
FollowsColorScheme=true\n\
Example=folder\n\
Directories=16/places,16@2x/places,16@3x/places,22/places,22@2x/places,22@3x/places,\
24/places,24@2x/places,24@3x/places,scalable/places,symbolic/places\n\
\n\
[16/places]\nSize=16\nContext=Places\nType=Fixed\n\n\
[16@2x/places]\nSize=16\nScale=2\nContext=Places\nType=Fixed\n\n\
[16@3x/places]\nSize=16\nScale=3\nContext=Places\nType=Fixed\n\n\
[22/places]\nSize=22\nContext=Places\nType=Fixed\n\n\
[22@2x/places]\nSize=22\nScale=2\nContext=Places\nType=Fixed\n\n\
[22@3x/places]\nSize=22\nScale=3\nContext=Places\nType=Fixed\n\n\
[24/places]\nSize=24\nContext=Places\nType=Fixed\n\n\
[24@2x/places]\nSize=24\nScale=2\nContext=Places\nType=Fixed\n\n\
[24@3x/places]\nSize=24\nScale=3\nContext=Places\nType=Fixed\n\n\
[scalable/places]\nSize=64\nMinSize=22\nMaxSize=512\nContext=Places\nType=Scalable\n\n\
[symbolic/places]\nContext=Places\nSize=16\nMinSize=8\nMaxSize=512\nType=Scalable\n";

    fs::write(slot_accent.join("index.theme"), index)
}
