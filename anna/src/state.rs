use crate::color::Color;
use crate::protocol::PaletteState;
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Base16 palette keys, lowercase.
pub const PALETTE_KEYS: [&str; 16] = [
    "base00", "base01", "base02", "base03", "base04", "base05", "base06", "base07", "base08",
    "base09", "base0a", "base0b", "base0c", "base0d", "base0e", "base0f",
];

pub const MODES: [&str; 2] = ["dark", "light"];

/// NixOS blue.
pub const DEFAULT_ACCENT: &str = "#5277c3";

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
            // Skip non-base16 keys (e.g. ICONS_THEME) and malformed colors.
            if !PALETTE_KEYS.contains(&key.as_str()) {
                continue;
            }
            if let Some(c) = Color::from_hex(v) {
                map.insert(key, c.to_hex());
            }
        }
    }
    if map.is_empty() {
        None
    } else {
        Some(map)
    }
}

// ── AppState ──────────────────────────────────────────────────────────────

#[derive(Clone)]
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
        let accent = Color::from_hex(&accent_str)
            .unwrap_or_else(|| Color::from_hex(DEFAULT_ACCENT).unwrap());

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

        // Palettes — embedded constants, overridden entry by entry by the
        // runtime env files (a partial file must not leave holes).
        let mut palette_dark = fallback_palette_dark();
        palette_dark.extend(load_palette_env("dark", &accent_dir).unwrap_or_default());
        let mut palette_light = fallback_palette_light();
        palette_light.extend(load_palette_env("light", &accent_dir).unwrap_or_default());

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

    /// Validate and set the accent color (`#rrggbb` or `rrggbb`).
    pub fn set_accent(&mut self, color: &str) -> Result<(), String> {
        self.accent =
            Color::from_hex(color).ok_or_else(|| format!("invalid hex color: {color}"))?;
        Ok(())
    }

    /// Back to the default accent and the default palette of the active mode
    /// (the other mode's palette is left alone).
    pub fn reset(&mut self) {
        self.accent = Color::from_hex(DEFAULT_ACCENT).expect("valid default accent");
        if self.mode == "light" {
            self.palette_light = fallback_palette_light();
        } else {
            self.palette_dark = fallback_palette_dark();
        }
    }

    /// Validate and set the palette mode.
    pub fn set_mode(&mut self, mode: &str) -> Result<(), String> {
        if !MODES.contains(&mode) {
            return Err(format!("invalid mode: {mode} (expected dark or light)"));
        }
        self.mode = mode.to_string();
        Ok(())
    }

    /// Validate and set one base16 entry of the `mode` palette (the active
    /// one when `None`).
    pub fn set_palette_color(
        &mut self,
        key: &str,
        color: &str,
        mode: Option<&str>,
    ) -> Result<(), String> {
        if !PALETTE_KEYS.contains(&key) {
            return Err(format!("invalid palette key: {key}"));
        }
        let c = Color::from_hex(color).ok_or_else(|| format!("invalid hex color: {color}"))?;
        let palette = match mode.unwrap_or(&self.mode) {
            "light" => &mut self.palette_light,
            "dark" => &mut self.palette_dark,
            other => return Err(format!("invalid mode: {other} (expected dark or light)")),
        };
        palette.insert(key.to_string(), c.to_hex());
        Ok(())
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

        let json = serde_json::to_string_pretty(&state).map_err(std::io::Error::other)?;
        fs::write(self.accent_dir.join("state.json"), json)?;

        Ok(())
    }
}

// ── Palette env persistence ───────────────────────────────────────────────

fn save_palette_env(palette: &HashMap<String, String>, path: &Path) -> io::Result<()> {
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh, empty accent dir under the system temp dir.
    fn temp_dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("anna-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn load_falls_back_to_defaults() {
        let dir = temp_dir("defaults");
        let s = AppState::load(dir.clone());
        assert_eq!(s.accent.to_hex(), "#5277c3");
        assert_eq!(s.mode, "dark");
        assert_eq!(s.palette_dark, fallback_palette_dark());
        assert_eq!(s.icons_theme, "Arcanum-Accent");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn save_then_load_round_trips() {
        let dir = temp_dir("roundtrip");
        let mut s = AppState::load(dir.clone());
        s.set_accent("#aa3366").unwrap();
        s.set_mode("light").unwrap();
        s.set_palette_color("base08", "#123456", Some("dark"))
            .unwrap();
        s.save().unwrap();

        let back = AppState::load(dir.clone());
        assert_eq!(back.accent.to_hex(), "#aa3366");
        assert_eq!(back.mode, "light");
        assert_eq!(back.palette_dark["base08"], "#123456");
        assert_eq!(back.palette_light, s.palette_light);
        assert!(dir.join("state.json").exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn palette_env_skips_foreign_keys_and_bad_colors() {
        let dir = temp_dir("env");
        fs::write(
            dir.join("palette-dark.env"),
            "# comment\n\nBASE00=0d0d0d\nbase0D=#5277C3\nICONS_THEME=foo\nBASE0Z=ffffff\nBASE01=nothex\n",
        )
        .unwrap();
        let p = load_palette_env("dark", &dir).unwrap();
        assert_eq!(p.len(), 2);
        assert_eq!(p["base00"], "#0d0d0d");
        assert_eq!(p["base0d"], "#5277c3");
        assert!(load_palette_env("light", &dir).is_none());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn setters_validate_input() {
        let mut s = AppState::load(temp_dir("setters"));
        assert!(s.set_accent("#12345").is_err());
        assert!(s.set_mode("sepia").is_err());
        assert!(s.set_palette_color("base10", "#000000", None).is_err());
        assert!(s.set_palette_color("base00", "black", None).is_err());
        assert!(s
            .set_palette_color("base00", "#000000", Some("sepia"))
            .is_err());
        // Nothing was changed by the rejected calls.
        assert_eq!(s.accent.to_hex(), "#5277c3");
        assert_eq!(s.mode, "dark");
        assert_eq!(s.palette_dark, fallback_palette_dark());
    }

    #[test]
    fn palette_color_targets_active_mode_by_default() {
        let mut s = AppState::load(temp_dir("active"));
        s.set_mode("light").unwrap();
        s.set_palette_color("base05", "#ABCDEF", None).unwrap();
        assert_eq!(s.palette_light["base05"], "#abcdef");
        assert_eq!(s.palette_dark["base05"], fallback_palette_dark()["base05"]);
        assert_eq!(s.active_palette()["base05"], "#abcdef");
    }

    #[test]
    fn partial_env_file_keeps_other_defaults() {
        let dir = temp_dir("partial");
        fs::write(dir.join("palette-dark.env"), "BASE08=ff0000\n").unwrap();
        let s = AppState::load(dir.clone());
        assert_eq!(s.palette_dark["base08"], "#ff0000");
        assert_eq!(s.palette_dark.len(), PALETTE_KEYS.len());
        assert_eq!(s.palette_dark["base00"], fallback_palette_dark()["base00"]);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn reset_restores_only_the_active_palette() {
        let mut s = AppState::load(temp_dir("reset"));
        s.set_accent("#ff0000").unwrap();
        s.set_palette_color("base00", "#111111", Some("dark"))
            .unwrap();
        s.set_palette_color("base00", "#eeeeee", Some("light"))
            .unwrap();
        s.set_mode("light").unwrap();
        s.reset();
        assert_eq!(s.accent.to_hex(), DEFAULT_ACCENT);
        assert_eq!(s.palette_light, fallback_palette_light());
        assert_eq!(s.palette_dark["base00"], "#111111");
        assert_eq!(s.mode, "light");
    }

    #[test]
    fn fallback_palettes_are_complete_and_valid() {
        for p in [fallback_palette_dark(), fallback_palette_light()] {
            for k in PALETTE_KEYS {
                assert!(Color::from_hex(&p[k]).is_some(), "{k} = {}", p[k]);
            }
            assert_eq!(p.len(), PALETTE_KEYS.len());
        }
    }
}
