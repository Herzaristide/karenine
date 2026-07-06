use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ── Commands (client → daemon) ────────────────────────────────────────────

/// All commands are JSON objects with a `"cmd"` discriminant field.
/// Example: `{"cmd":"set_accent","color":"#5277c3"}`
#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    SetAccent {
        color: String,
    },
    SetMode {
        mode: String,
    },
    /// Set a single base16 palette entry.
    /// `key` must be one of "base00"–"base0f" (lowercase).
    /// `mode` defaults to the currently active mode when omitted.
    SetPaletteColor {
        key: String,
        color: String,
        mode: Option<String>,
    },
    GetState,
    /// Keep connection open; daemon pushes `Event` messages on every state change.
    Watch,

    // ── hwstats service ───────────────────────────────────────────────────
    /// One hardware-stats snapshot, then close.
    HwstatsGet,
    /// Keep connection open; daemon pushes a `HwStats` JSON line every second.
    HwstatsWatch,
}

// ── Shared state payload ──────────────────────────────────────────────────

/// Full color state serialized to JSON.  Written to `state.json` and sent
/// over the socket on every `get_state` / `watch` event.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct PaletteState {
    pub accent: String,
    pub accent_dark: String,
    pub accent_muted: String,
    pub accent_rgb: String,
    pub accent_ansi: String,
    pub mode: String,
    /// Base16 palette for the active mode.  Keys are lowercase "base00"–"base0f".
    /// Values are `#rrggbb`.
    pub palette: HashMap<String, String>,
}

// ── Responses (daemon → client) ───────────────────────────────────────────

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum Response {
    Ok {
        ok: bool,
        state: PaletteState,
    },
    /// Pushed to all `Watch` subscribers when state changes.
    Event {
        event: String,
        state: PaletteState,
    },
    Error {
        ok: bool,
        error: String,
    },
}

impl Response {
    pub fn ok(state: PaletteState) -> Self {
        Self::Ok { ok: true, state }
    }

    pub fn err(msg: impl Into<String>) -> Self {
        Self::Error {
            ok: false,
            error: msg.into(),
        }
    }

    pub fn changed(state: PaletteState) -> Self {
        Self::Event {
            event: "changed".into(),
            state,
        }
    }
}
