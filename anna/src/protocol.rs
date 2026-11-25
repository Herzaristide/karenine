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

    // ── tailnet devices (tailscale + node_exporter) ───────────────────────
    /// Keep connection open; daemon pushes `{"servers":[ServerStats…],
    /// "local":{hostname, drives, services}}` every second, re-reading the
    /// list each time. With `name`, only that device's node_exporter is
    /// asked (the one the shell shows); the others report what Tailscale
    /// says of them.
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

    // ── Claude Code sessions (see claude/sessions.rs) ─────────────────────
    /// Keep connection open; daemon pushes `{"claude":{"live":[Session…],
    /// "recent":[Session…]}}` every 2 s.
    ClaudeWatch,
    /// What a Claude Code hook saw (the JSON it got on stdin), sent by
    /// `anna claude-event`. No reply.
    ClaudeEvent {
        #[serde(default)]
        event: serde_json::Value,
    },
    /// Bring the terminal running session process `pid` to the front:
    /// `{"ok":true}` or `{"ok":false,"error":"…"}`.
    ClaudeFocus {
        pid: u32,
    },
    /// Keep connection open; daemon pushes session `id`'s conversation
    /// (claude/drive.rs `watch`): `{"chat":Page}` first, then
    /// `{"chat_upsert":[Item…]}` (new items, and tool calls completed by
    /// their result, same key), `{"chat_partial":{kind,text}}` (the text
    /// being written), `{"chat_summary":Summary}` (context, changes,
    /// outputs, jobs, task list — claude/summary.rs — whenever it changes),
    /// `{"chat_state":State}` and `{"chat_elsewhere":pid}` (the `claude`
    /// holding it in a terminal, 0 if none). With `agent`, the conversation
    /// of that subagent of the session instead.
    ClaudeChatWatch {
        id: String,
        #[serde(default)]
        agent: Option<String>,
    },
    /// An earlier page: `{"ok":true,"items":[…],"first":n,"total":n}`.
    ClaudeChatPage {
        id: String,
        #[serde(default)]
        agent: Option<String>,
        before: usize,
        #[serde(default = "default_page")]
        limit: usize,
    },
    /// A long tool output Claude Code kept in a file of its own, or a
    /// background command's output file: `{"ok":true,"text":"…"}`.
    ClaudeChatOutput {
        id: String,
        path: String,
    },
    /// Every change the session (or subagent `agent`) made to `path` (as the
    /// summary names it): `{"ok":true,"hunks":[structuredPatch hunk…]}`.
    ClaudeChatDiff {
        id: String,
        #[serde(default)]
        agent: Option<String>,
        path: String,
    },
    /// The slash commands Claude Code has in folder `cwd`:
    /// `{"ok":true,"commands":[{name,description,argumentHint,aliases}]}`.
    ClaudeCommands {
        cwd: String,
    },
    /// Send a request to session `id` (resumed by anna if needed), or start
    /// a new session in `cwd`: `{"ok":true,"id":"…"}`, or
    /// `{"ok":false,"error":"open_elsewhere"|"…"}`. `model`, `effort` and
    /// `mode` start the `claude` with them when it doesn't run yet. `files`
    /// (absolute paths) are joined to the request, images as such.
    ClaudeSend {
        #[serde(default)]
        id: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        text: String,
        #[serde(default)]
        files: Vec<String>,
        #[serde(default)]
        model: Option<String>,
        #[serde(default)]
        effort: Option<String>,
        #[serde(default)]
        mode: Option<String>,
    },
    /// Interrupt the turn of a driven session.
    ClaudeInterrupt {
        id: String,
    },
    /// Change a driven session's model, effort or permission mode, or turn
    /// its Remote Control on or off.
    ClaudeSet {
        id: String,
        #[serde(default)]
        model: Option<String>,
        #[serde(default)]
        effort: Option<String>,
        #[serde(default)]
        mode: Option<String>,
        #[serde(default)]
        remote: Option<bool>,
    },
    /// What is left of the Claude plan (claude/drive.rs `usage`, asked of
    /// `claude` at most once a minute): `{"ok":true,"usage":{subscription_type,
    /// rate_limits:{five_hour:{utilization,resets_at},seven_day:{…},…}}}`.
    ClaudeUsage,
    /// Answer request `ask` of a driven session (its `chat_state.asks`):
    /// `action` is a button's id (`allow`, `always`, `deny`, `answer`),
    /// `values` the choices made for Claude's questions.
    ClaudeAnswer {
        id: String,
        ask: String,
        action: String,
        #[serde(default)]
        values: HashMap<String, String>,
    },
    /// Stop anna's `claude` on session `id` (the conversation stays).
    ClaudeStop {
        id: String,
    },
    /// End the `claude` holding session `id` in a terminal, so anna can
    /// drive it: `{"ok":false,"error":"busy"}` while it works, unless
    /// `force`.
    ClaudeTakeOver {
        id: String,
        #[serde(default)]
        force: bool,
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

    // ── recording (recorder.rs) ───────────────────────────────────────────
    /// Start a recording, or stop the one of that kind: `kind` "audio"
    /// (`mode` "mic", the default, or "mix": with the computer's sound) or
    /// "screen" (`mode` "area", the default, or "screen": the focused
    /// monitor). `{"ok":true}` once started; picking a region waits for it.
    RecordToggle {
        kind: String,
        #[serde(default)]
        mode: String,
    },
    /// Stop the recording of `kind`, or every one without it.
    RecordStop {
        #[serde(default)]
        kind: Option<String>,
    },
    /// Print the status once (recorder.rs).
    RecordGet,
    /// Keep connection open; daemon pushes the status on every change.
    RecordWatch,
    /// A sound take's waveform: `{"peaks":[0–1…]}`. Only the takes in the
    /// Music folder (`enregistrement-*.flac`).
    RecordPeaks {
        path: String,
    },
    /// Play a sound take (the same files only) from `from` seconds, in place
    /// of what was playing.
    RecordPlay {
        path: String,
        #[serde(default)]
        from: f64,
    },
    /// Stop the playback.
    RecordPause,

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
    /// The pilot's model (claude/pilot.rs): `{"ok":true,"config":{provider,
    /// url,model,think},"has_key":bool,"models":[…],"error":…}` — the models
    /// the provider offers, `error` when it could not be asked.
    PilotConfig,
    /// Change the pilot's model; the conversation starts over. `key`: absent
    /// keeps the API key, "" removes it. `{"ok":true}`.
    PilotConfigure {
        provider: String,
        #[serde(default)]
        url: String,
        #[serde(default)]
        model: String,
        #[serde(default)]
        think: bool,
        #[serde(default)]
        key: Option<String>,
    },
    // ── Voice (claude/voice.rs) ───────────────────────────────────────────
    /// Start listening, or end the recording now if already listening.
    /// `send` (default true): hand the transcript to the pilot; false only
    /// shows it (`anna voice dictate`).
    VoiceToggle {
        #[serde(default = "yes")]
        send: bool,
    },
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
    },
    /// Transcribe a WAV file (16 kHz mono): `{"ok":true,"text":"…"}`.
    VoiceTranscribe {
        path: String,
    },
    // ── prompts (prompts.rs) ──────────────────────────────────────────────
    /// Show a prompt in the shell and wait for its answer (sent by `anna
    /// askpass`…): `{"ok":true,"action":"…","values":{…}}`, or
    /// `{"ok":false,"error":"no_shell"|"timeout"|"gone"}`. Closing the
    /// connection withdraws it.
    PromptOpen {
        prompt: crate::prompts::Spec,
    },
    /// Keep connection open; daemon pushes `{"prompts":[View…]}`, the
    /// pending prompts oldest first, on every change.
    PromptWatch,
    /// The shell's answer to prompt `id`: `action` is a button's id or
    /// "cancel". `{"ok":true}`, or `{"ok":false}` if it no longer waits.
    PromptReply {
        id: String,
        action: String,
        #[serde(default)]
        values: HashMap<String, String>,
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

fn default_page() -> usize {
    150
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn parse(line: &str) -> Result<Command, serde_json::Error> {
        serde_json::from_str(line)
    }

    fn state() -> PaletteState {
        PaletteState {
            accent: "#5277c3".into(),
            accent_dark: "#3a5a9c".into(),
            accent_muted: "#8aa0d0".into(),
            accent_rgb: "82,119,195".into(),
            accent_ansi: "38;2;82;119;195".into(),
            mode: "dark".into(),
            palette: HashMap::new(),
        }
    }

    #[test]
    fn commands_sent_by_the_shell_parse() {
        // Exactly the lines the QML writes on the socket.
        assert!(matches!(
            parse(r##"{"cmd":"set_accent","color":"#5277c3"}"##),
            Ok(Command::SetAccent { color }) if color == "#5277c3"
        ));
        assert!(matches!(
            parse(r#"{"cmd":"hwstats_watch","interval_ms":500}"#),
            Ok(Command::HwstatsWatch {
                interval_ms: Some(500)
            })
        ));
        assert!(matches!(
            parse(r#"{"cmd":"metronome"}"#),
            Ok(Command::Metronome)
        ));
        assert!(matches!(
            parse(r#"{"cmd":"get_state"}"#),
            Ok(Command::GetState)
        ));
    }

    #[test]
    fn optional_fields_may_be_omitted() {
        assert!(matches!(
            parse(r#"{"cmd":"hwstats_watch"}"#),
            Ok(Command::HwstatsWatch { interval_ms: None })
        ));
        assert!(matches!(
            parse(r#"{"cmd":"servers_watch"}"#),
            Ok(Command::ServersWatch { name: None })
        ));
        assert!(matches!(
            parse(r##"{"cmd":"set_palette_color","key":"base00","color":"#000000"}"##),
            Ok(Command::SetPaletteColor { mode: None, .. })
        ));
    }

    #[test]
    fn malformed_commands_are_rejected() {
        assert!(parse(r#"{"cmd":"no_such_command"}"#).is_err());
        assert!(parse(r##"{"color":"#5277c3"}"##).is_err(), "no cmd");
        assert!(parse(r#"{"cmd":"set_accent"}"#).is_err(), "missing color");
        assert!(
            parse(r##"{"cmd":"SetAccent","color":"#fff"}"##).is_err(),
            "not snake_case"
        );
        assert!(parse("not json").is_err());
    }

    #[test]
    fn responses_keep_their_wire_shape() {
        let ok = serde_json::to_value(Response::ok(state())).unwrap();
        assert_eq!(ok["ok"], json!(true));
        assert_eq!(ok["state"]["accent"], json!("#5277c3"));

        let ev = serde_json::to_value(Response::changed(state())).unwrap();
        assert_eq!(ev["event"], json!("changed"));
        assert_eq!(ev.get("ok"), None);

        let err = serde_json::to_value(Response::err("bad color")).unwrap();
        assert_eq!(err, json!({ "ok": false, "error": "bad color" }));
    }

    #[test]
    fn palette_state_round_trips() {
        let mut s = state();
        s.palette.insert("base00".into(), "#1d2021".into());
        let text = serde_json::to_string(&s).unwrap();
        let back: PaletteState = serde_json::from_str(&text).unwrap();
        assert_eq!(back.palette["base00"], "#1d2021");
        assert_eq!(
            serde_json::from_str::<Value>(&text).unwrap()["mode"],
            "dark"
        );
    }
}
