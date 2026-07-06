use crate::color::Color;
use crate::protocol::PaletteState;
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

// ── Embedded fallback palettes ───────────────────────────────────────────

pub fn fallback_palette_dark() -> HashMap<String, String> {
    [
        ("base00", "#0d0d0d"),
        ("base01", "#1a1a1a"),
        ("base02", "#2a2a2a"),
        ("base03", "#5a6080"),
        ("base04", "#8a90b0"),
        ("base05", "#e0e0ff"),
        ("base06", "#f0f0ff"),
        ("base07", "#ffffff"),
        ("base08", "#cc4444"),
        ("base09", "#cc8844"),
        ("base0a", "#ccaa44"),
        ("base0b", "#44aa88"),
        ("base0c", "#7ebae4"),
        ("base0d", "#5277c3"),
        ("base0e", "#4488cc"),
        ("base0f", "#cc5566"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

pub fn fallback_palette_light() -> HashMap<String, String> {
    [
        ("base00", "#f5f5ff"),
        ("base01", "#eaeaff"),
        ("base02", "#d8d8f5"),
        ("base03", "#8888aa"),
        ("base04", "#5a5a80"),
        ("base05", "#1a1a3e"),
        ("base06", "#0d0d28"),
        ("base07", "#060610"),
        ("base08", "#cc2222"),
        ("base09", "#b85c00"),
        ("base0a", "#8a7000"),
        ("base0b", "#2a8855"),
        ("base0c", "#1a77bb"),
        ("base0d", "#3355aa"),
        ("base0e", "#2266bb"),
        ("base0f", "#bb2244"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect()
}

// ── palette-{mode}.env loader ─────────────────────────────────────────────

/// Load base16 palette from a shell-sourceable env file written to
/// `~/.config/accent/palette-{mode}.env` (legacy; daemon now uses embedded palettes
/// as primary source and only reads the file as an optional override).
/// Format: `BASE00=0d0d0d` (uppercase keys, hex values without `#`).
pub fn load_palette_env(mode: &str, accent_dir: &Path) -> Option<HashMap<String, String>> {
    let path = accent_dir.join(format!("palette-{mode}.env"));
    let content = fs::read_to_string(&path).ok()?;
    let mut map = HashMap::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let key = k.trim().to_lowercase();
            // Skip non-base16 keys (e.g. ICONS_THEME)
            if !key.starts_with("base0") {
                continue;
            }
            let val = v.trim().trim_start_matches('#');
            map.insert(key, format!("#{val}"));
        }
    }
    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

// ── AppState ──────────────────────────────────────────────────────────────

pub struct AppState {
    pub accent: Color,
    pub mode: String,
    pub palette_dark: HashMap<String, String>,
    pub palette_light: HashMap<String, String>,
    pub accent_dir: PathBuf,
    pub template_dir: PathBuf,
    pub logo_path: String,
    pub icons_theme: String,
}

impl AppState {
    /// Load state from disk. Falls back to embedded palettes + default accent
    /// when files don't exist (first install).
    pub fn load(accent_dir: PathBuf) -> Self {
        let template_dir = accent_dir.join("templates");

        // Accent color — read accent.hex, fall back to NixOS blue
        let accent_str = fs::read_to_string(accent_dir.join("accent.hex"))
            .unwrap_or_default()
            .trim()
            .to_string();
        let accent =
            Color::from_hex(&accent_str).unwrap_or_else(|| Color::from_hex("#5277c3").unwrap());

        // Mode — read mode.txt, fall back to dark
        let mode = fs::read_to_string(accent_dir.join("mode.txt"))
            .unwrap_or_default()
            .trim()
            .to_string();
        let mode = if mode == "light" {
            "light".into()
        } else {
            "dark".into()
        };

        // Palettes — prefer runtime env files, fall back to embedded constants
        let palette_dark =
            load_palette_env("dark", &accent_dir).unwrap_or_else(fallback_palette_dark);
        let palette_light =
            load_palette_env("light", &accent_dir).unwrap_or_else(fallback_palette_light);

        // Logo path — baked in by accent.nix via FASTFETCH_LOGO env var at build
        let logo_path = std::env::var("FASTFETCH_LOGO")
            .unwrap_or_else(|_| "/etc/nixos/src/nixos_logo.txt".into());

        // Icons theme — read icons_theme.txt, fall back to Arcanum-Accent
        let icons_theme = fs::read_to_string(accent_dir.join("icons_theme.txt"))
            .unwrap_or_default()
            .trim()
            .to_string();
        let icons_theme = if icons_theme.is_empty() {
            "Arcanum-Accent".into()
        } else {
            icons_theme
        };

        Self {
            accent,
            mode,
            palette_dark,
            palette_light,
            accent_dir,
            template_dir,
            logo_path,
            icons_theme,
        }
    }

    /// Active palette for the current mode.
    pub fn active_palette(&self) -> &HashMap<String, String> {
        if self.mode == "light" {
            &self.palette_light
        } else {
            &self.palette_dark
        }
    }

    /// Build the serializable state snapshot.
    pub fn to_palette_state(&self) -> PaletteState {
        PaletteState {
            accent: self.accent.to_hex(),
            accent_dark: self.accent.darker().to_hex(),
            accent_muted: self.accent.muted().to_hex(),
            accent_rgb: self.accent.to_rgb_str(),
            accent_ansi: self.accent.to_ansi(),
            mode: self.mode.clone(),
            palette: self.active_palette().clone(),
        }
    }

    /// Persist accent.hex, mode.txt, palette env files, and state.json to disk.
    pub fn save(&self) -> std::io::Result<()> {
        let state = self.to_palette_state();
        fs::create_dir_all(&self.accent_dir)?;

        fs::write(self.accent_dir.join("accent.hex"), &state.accent)?;
        fs::write(self.accent_dir.join("mode.txt"), &state.mode)?;

        save_palette_env(
            &self.palette_dark,
            &self.accent_dir.join("palette-dark.env"),
        )?;
        save_palette_env(
            &self.palette_light,
            &self.accent_dir.join("palette-light.env"),
        )?;

        let json = serde_json::to_string_pretty(&state)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        fs::write(self.accent_dir.join("state.json"), json)?;

        Ok(())
    }
}

// ── Palette env persistence ───────────────────────────────────────────────

fn save_palette_env(palette: &HashMap<String, String>, path: &PathBuf) -> io::Result<()> {
    let mut keys: Vec<&String> = palette.keys().collect();
    keys.sort();
    let mut content = String::new();
    for key in keys {
        if let Some(val) = palette.get(key) {
            let hex = val.trim_start_matches('#');
            content.push_str(&format!("{}={}\n", key.to_uppercase(), hex));
        }
    }
    fs::write(path, content)
}
