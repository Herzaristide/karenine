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
    /// Restore the default accent and the active mode's default palette.
    ResetTheme,
    GetState,
    /// Keep connection open; daemon pushes `Event` messages on every state change.
    Watch,

    // ── hwstats service ───────────────────────────────────────────────────
    /// One hardware-stats snapshot, then close.
    HwstatsGet,
    /// Keep connection open; daemon pushes a `HwStats` JSON line every
    /// `interval_ms` (default 1000, clamped to 250–5000).
    HwstatsWatch {
        #[serde(default)]
        interval_ms: Option<u64>,
    },

    // ── tailnet devices (tailscale + ssh) ─────────────────────────────────
    /// Keep connection open; daemon pushes `{"servers":[ServerStats…]}` every
    /// few seconds, re-reading the list each time. With `name`, only that
    /// device is asked over ssh (the one the shell shows); the others report
    /// what Tailscale says of them.
    ServersWatch {
        #[serde(default)]
        name: Option<String>,
    },
    /// Print the devices of the tailnet: `[{"name","host","os",…}, …]`.
    ServersList,
    /// Turn a device `on` (Wake-on-LAN), `off` or `reboot` (ssh), see
    /// servers.rs::power: `{"ok":true}` or `{"ok":false,"error":"…"}`.
    ServersPower {
        name: String,
        action: String,
    },

    // ── phones (KDE Connect, see phone.rs) ────────────────────────────────
    /// Keep connection open; daemon pushes `{"phone":{"running",
    /// "phones":[Phone…]}}` every 2 s.
    PhoneWatch,
    /// Act on a device (phone.rs::act): `{"ok":true}` or
    /// `{"ok":false,"error":"…"}`.
    PhoneAction {
        device: String,
        action: String,
        #[serde(default)]
        arg: String,
    },
    /// How to show phone `name`'s screen (phone.rs::screen):
    /// `{"ok":true,"command":["scrcpy",…]}`, for the shell to launch in the
    /// session, or `{"ok":false,"error":"…"}`.
    PhoneScreen {
        name: String,
    },

    // ── audio services (native cpal + rustfft) ────────────────────────────
    /// Keep connection open; daemon captures the mic and pushes one
    /// `{"pitch":<hz>}` line per analysis frame (0.0 when unvoiced).
    TunerWatch,
    /// Keep connection open; daemon captures the mic and pushes one
    /// `{"chroma":[12 floats],"top":["C","E","G"]}` line per analysis frame.
    ChromaWatch,
    /// Long-lived metronome session. After this command the connection stays
    /// open: the client sends control lines (`{"action":"start","bpm":120}`,
    /// `{"action":"stop"}`, `{"action":"bpm","value":130}`,
    /// `{"action":"beats","value":4}`) and the daemon pushes `{"beat":<n>}`
    /// events, driving a sample-accurate cpal output stream.
    Metronome,

    // ── gesture control (webcam) ──────────────────────────────────────────
    /// Print the gesture status once: `{"enabled","active","mode","fps","error"}`.
    GestureGet,
    /// Enable/disable the camera (persisted), then print the status.
    GestureSet {
        enabled: bool,
    },
    /// Flip the enabled flag, then print the status.
    GestureToggle,
    /// List capture devices: `[{"path":"/dev/video0","name":"HD Webcam"}, …]`.
    GestureCameras,
    /// Switch capture device (persisted, applied live), then print the status.
    GestureSetCamera {
        device: String,
    },
    /// Keep connection open; daemon pushes the status on every change
    /// (mode, fps once per second, enable/disable, errors).
    GestureWatch,

    // ── Claude Code sessions (see claude/mod.rs) ──────────────────────────
    /// Sent by `anna hook`: one trimmed lifecycle event of a `claude`
    /// process. Answered with `{"ok":true}`.
    ClaudeHook {
        pid: Option<u32>,
        event: crate::claude::HookEvent,
    },
    /// The live sessions, once: `[{id, project, cwd, state, since, …}, …]`.
    ClaudeList,
    /// Keep connection open; daemon pushes `{"sessions":[…]}` on every
    /// change.
    ClaudeWatch,
    /// Focus the window hosting a session: `{"ok":true}` or
    /// `{"ok":false,"error":"…"}`.
    ClaudeFocus {
        id: String,
    },
    /// Answer an open permission request of the pilot, from the dock
    /// (see claude/permission.rs). `decision` is
    /// "allow", "always", "deny" or "terminal". `{"ok":true}`, or
    /// `{"ok":false}` when the request is already over.
    ClaudeDecide {
        request: u64,
        decision: String,
    },

    // ── AI dock: sessions run by anna (claude/runner.rs) ─────────────────
    /// Start a session in `cwd` — in its own worktree when `worktree` — or
    /// `resume` one there; `prompt` is its first message.
    /// `{"ok":true,"id":"…"}` or `{"ok":false,"error":"…"}`.
    ClaudeStart {
        cwd: String,
        prompt: String,
        #[serde(default)]
        worktree: bool,
        #[serde(default)]
        resume: Option<String>,
    },
    /// Send a message to a session: written to it if anna runs it, otherwise
    /// it is resumed in `cwd` with that message.
    ClaudeSend {
        id: String,
        text: String,
        #[serde(default)]
        cwd: String,
    },
    /// Stop a session anna runs.
    ClaudeStop {
        id: String,
    },
    /// Keep connection open; daemon pushes `{"reset":[messages]}` with the
    /// end of the transcript, then `{"append":[messages]}` as it grows.
    /// A message is `{"role":"user"|"assistant"|"tool","text":"…"}`.
    ClaudeTranscript {
        path: String,
    },
    /// Where a new session can start: `[{name, path, kind}, …]`.
    ClaudeProjects,
    /// What a worktree session changed (claude/worktree.rs).
    ClaudeReview {
        cwd: String,
    },
    /// Act on a worktree session's work: `action` is "commit" (with
    /// `message`), "merge" or "discard". Refused while session `id` runs.
    ClaudeWorktree {
        cwd: String,
        action: String,
        #[serde(default)]
        message: String,
        #[serde(default)]
        id: String,
    },
    /// Open a session in "zed" or in a "terminal" (`claude --resume`).
    ClaudeOpen {
        cwd: String,
        app: String,
        #[serde(default)]
        id: String,
    },

    // ── Knowledge: the Obsidian vault (claude/knowledge.rs) ───────────────
    /// Every note, newest first: `[{path, title, kind, sujets, statut, date,
    /// revu, projet, session, excerpt, mtime}, …]`. Also (re)links the
    /// vault's skills into ~/.claude/skills.
    KnowledgeList,
    /// A note's body (front matter stripped): `{"ok":true,"text":"…"}`.
    KnowledgeRead {
        path: String,
    },
    /// Mark a note as read: `statut: relu`, `revu: <today>`.
    KnowledgeReviewed {
        path: String,
    },

    // ── Pilot (claude/pilot.rs, claude/desk.rs) ───────────────────────────
    /// Send a request to the pilot; `clipboard` joins the clipboard's text.
    /// `{"ok":true}` once sent — the answer arrives on `pilot_watch`.
    PilotAsk {
        text: String,
        #[serde(default)]
        clipboard: bool,
    },
    /// Keep connection open; daemon pushes
    /// `{"pilot":{"busy":bool,"items":[{kind,text}…]}}` on every change.
    /// `kind` is "user", "action", "reply" or "error".
    PilotWatch,
    /// Forget the pilot's conversation.
    PilotReset,
    // ── Voice (claude/voice.rs) ───────────────────────────────────────────
    /// Start listening, or end the recording now if already listening.
    /// `send` (default true): hand the transcript to the pilot; false only
    /// shows it (the dock puts it in its input field).
    VoiceToggle {
        #[serde(default = "yes")]
        send: bool,
    },
    /// Push-to-talk: record until `voice_release`, silences included; the
    /// transcript is only shown (the dock's held Space).
    VoiceHold,
    /// End a push-to-talk recording.
    VoiceRelease,
    /// The wake word « Karénine » (claude/wake.rs): `on` turns it on or
    /// off, absent toggles it. Remembered across restarts.
    VoiceWake {
        #[serde(default)]
        on: Option<bool>,
    },
    /// Keep connection open; daemon pushes `{"voice":{"phase":"idle"|
    /// "listening"|"transcribing","level":0–1,"text":"…","partial":bool,
    /// "send":bool,"error":"…"}}` — `text` follows the voice while
    /// `partial`.
    VoiceWatch,
    /// Play a 16-bit WAV through the listening loop as if said into the
    /// microphone (live transcript, end of speech, outcome).
    VoiceSimulate {
        path: String,
        #[serde(default)]
        send: bool,
        /// Played as push-to-talk: ends on `voice_release`.
        #[serde(default)]
        hold: bool,
    },
    /// Transcribe a WAV file (16 kHz mono): `{"ok":true,"text":"…"}`.
    VoiceTranscribe {
        path: String,
    },
    /// Sent by `anna mcp`: run one desk tool for the pilot.
    /// `{"ok":bool,"text":"…"}`.
    Desk {
        tool: String,
        #[serde(default)]
        args: serde_json::Value,
    },
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

fn yes() -> bool {
    true
}
