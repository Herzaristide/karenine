//! Thin CLI client for the `anna` daemon.
//!
//! Usage:
//!   anna set "#5277c3"   — change accent color
//!   anna mode dark       — switch to dark palette
//!   anna mode light      — switch to light palette
//!   anna get             — print current state as JSON
//!   anna watch           — stream state changes as JSON lines (Ctrl-C to stop)
use serde_json::json;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;

/// Build the JSON command for a client subcommand, and whether the daemon will
/// keep streaming lines (watch) rather than send a single reply. `None` on a
/// usage error. Arguments go through serde, never string formatting, so a
/// quote or backslash in them can't produce invalid JSON.
fn build_command(args: &[String]) -> Option<(serde_json::Value, bool)> {
    let arg = |i: usize| args.get(i).map(String::as_str);
    Some(match arg(1)? {
        "set" => (json!({"cmd": "set_accent", "color": arg(2)?}), false),
        "mode" => (json!({"cmd": "set_mode", "mode": arg(2)?}), false),
        "palette-color" => {
            let mut cmd = json!({"cmd": "set_palette_color", "key": arg(2)?, "color": arg(3)?});
            if let Some(m) = arg(4) {
                cmd["mode"] = m.into();
            }
            (cmd, false)
        }
        "gesture" => match arg(2) {
            Some("on") => (json!({"cmd": "gesture_set", "enabled": true}), false),
            Some("off") => (json!({"cmd": "gesture_set", "enabled": false}), false),
            Some("toggle") => (json!({"cmd": "gesture_toggle"}), false),
            Some("status") | None => (json!({"cmd": "gesture_get"}), false),
            Some("watch") => (json!({"cmd": "gesture_watch"}), true),
            Some("cameras") => (json!({"cmd": "gesture_cameras"}), false),
            Some("camera") => (
                json!({"cmd": "gesture_set_camera", "device": arg(3)?}),
                false,
            ),
            _ => return None,
        },
        "claude" => match arg(2) {
            None | Some("list") => (json!({"cmd": "claude_list"}), false),
            Some("watch") => (json!({"cmd": "claude_watch"}), true),
            Some("focus") => (json!({"cmd": "claude_focus", "id": arg(3)?}), false),
            _ => return None,
        },
        "servers" => match arg(2) {
            None | Some("list") => (json!({"cmd": "servers_list"}), false),
            Some("watch") => (json!({"cmd": "servers_watch", "name": arg(3)}), true),
            Some(action @ ("on" | "off" | "reboot")) => (
                json!({"cmd": "servers_power", "name": arg(3)?, "action": action}),
                false,
            ),
            _ => return None,
        },
        "phone" => match arg(2) {
            None | Some("watch") => (json!({"cmd": "phone_watch"}), true),
            Some("screen") => (json!({"cmd": "phone_screen", "name": arg(3)?}), false),
            Some(action) => (
                json!({"cmd": "phone_action", "action": action, "device": arg(3)?, "arg": arg(4).unwrap_or("")}),
                false,
            ),
        },
        "voice" => match arg(2) {
            None | Some("toggle") => (json!({"cmd": "voice_toggle"}), false),
            // Dictation only: the transcript is shown, not sent.
            Some("dictate") => (json!({"cmd": "voice_toggle", "send": false}), false),
            Some("simulate") => (
                json!({"cmd": "voice_simulate", "path": arg(3)?, "send": arg(4) == Some("--send")}),
                false,
            ),
            Some("wake") => (
                match arg(3) {
                    Some("on") => json!({"cmd": "voice_wake", "on": true}),
                    Some("off") => json!({"cmd": "voice_wake", "on": false}),
                    _ => json!({"cmd": "voice_wake"}),
                },
                false,
            ),
            Some("watch") => (json!({"cmd": "voice_watch"}), true),
            Some("transcribe") => (json!({"cmd": "voice_transcribe", "path": arg(3)?}), false),
            _ => return None,
        },
        "pilot" => match arg(2)? {
            "watch" => (json!({"cmd": "pilot_watch"}), true),
            "reset" => (json!({"cmd": "pilot_reset"}), false),
            _ => (
                json!({"cmd": "pilot_ask", "text": args[2..].join(" ")}),
                false,
            ),
        },
        "reset" => (json!({"cmd": "reset_theme"}), false),
        "get" => (json!({"cmd": "get_state"}), false),
        "watch" => (json!({"cmd": "watch"}), true),
        _ => return None,
    })
}

/// Handle a client subcommand. `args` is the full process argv
/// (`args[1]` is the subcommand, `args[2..]` its parameters).
pub fn run(args: &[String]) {
    let (cmd_json, is_watch) = build_command(args).unwrap_or_else(|| usage());

    let socket_path = crate::paths::socket_path();
    let mut stream = UnixStream::connect(&socket_path).unwrap_or_else(|e| {
        eprintln!("anna: cannot connect to {socket_path}: {e}");
        eprintln!("anna: is the daemon running?");
        std::process::exit(1);
    });

    writeln!(stream, "{cmd_json}").unwrap_or_else(|e| {
        eprintln!("anna: write error: {e}");
        std::process::exit(1);
    });

    let reader = BufReader::new(stream);
    for line in reader.lines() {
        match line {
            Ok(l) => println!("{l}"),
            Err(_) => break,
        }
        if !is_watch {
            break; // single-response commands read exactly one line
        }
    }
}

fn usage() -> ! {
    eprintln!(
        "Usage: anna <command> [args]\n\
         \n\
         Client commands:\n\
           set \"#rrggbb\"                          Change accent color\n\
           mode dark|light                         Switch dark/light palette\n\
           palette-color <key> \"#rrggbb\" [mode]    Set a base16 palette entry\n\
           reset                                   Default accent + active palette\n\
           get                                     Print current state as JSON\n\
           watch                                   Stream state changes as JSON lines\n\
           gesture on|off|toggle|status|watch      Webcam gesture control\n\
           gesture cameras | camera /dev/videoN   List / pick the capture device\n\
           gesture debug [--dry]                   Foreground engine with diagnostics\n\
           claude [list|watch]                     Live Claude Code sessions\n\
           claude focus <session-id>               Focus the window hosting a session\n\
           pilot <demande…> | watch | reset       Ask the pilot / follow it / forget it\n\
           voice [toggle] | watch                  Speak to the pilot (start / end listening)\n\
           voice dictate                          Same, but only show the transcript\n\
           voice wake [on|off]                    Wake word « Karénine » (toggle)\n\
           voice transcribe <file.wav>            Transcribe a 16 kHz mono WAV\n\
           servers [list] | watch [name]          Tailnet devices / their stats (ssh)\n\
           servers on|off|reboot <name>           Wake-on-LAN / power off, reboot (ssh)\n\
           phone [watch]                          KDE Connect phones: battery, network\n\
           phone ring|ping|browse|clipboard|accept|reject <device>\n\
           phone share <device> <path>\n\
           phone screen <name>                    Its screen: the scrcpy command (USB, else Tailscale)\n\
         \n\
         Claude Code hook (in its settings, not by hand):\n\
           hook                                    Forward one event from stdin"
    );
    std::process::exit(2);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Command;

    fn argv(a: &[&str]) -> Vec<String> {
        std::iter::once("anna")
            .chain(a.iter().copied())
            .map(String::from)
            .collect()
    }

    /// Every command the client builds must be one the daemon accepts.
    fn parses(a: &[&str]) -> Command {
        let (v, _) = build_command(&argv(a)).expect("usage error");
        serde_json::from_value(v).expect("daemon rejects the command")
    }

    #[test]
    fn every_subcommand_round_trips_through_the_protocol() {
        assert!(matches!(
            parses(&["set", "#5277c3"]),
            Command::SetAccent { .. }
        ));
        assert!(matches!(parses(&["mode", "dark"]), Command::SetMode { .. }));
        assert!(matches!(
            parses(&["palette-color", "base08", "#ff0000", "light"]),
            Command::SetPaletteColor { mode: Some(_), .. }
        ));
        assert!(matches!(
            parses(&["palette-color", "base08", "#ff0000"]),
            Command::SetPaletteColor { mode: None, .. }
        ));
        assert!(matches!(parses(&["get"]), Command::GetState));
        assert!(matches!(parses(&["reset"]), Command::ResetTheme));
        assert!(matches!(parses(&["watch"]), Command::Watch));
        assert!(matches!(parses(&["gesture"]), Command::GestureGet));
        assert!(matches!(
            parses(&["gesture", "on"]),
            Command::GestureSet { enabled: true }
        ));
        assert!(matches!(
            parses(&["gesture", "off"]),
            Command::GestureSet { enabled: false }
        ));
        assert!(matches!(
            parses(&["gesture", "toggle"]),
            Command::GestureToggle
        ));
        assert!(matches!(
            parses(&["gesture", "cameras"]),
            Command::GestureCameras
        ));
        assert!(matches!(
            parses(&["gesture", "watch"]),
            Command::GestureWatch
        ));
        assert!(matches!(
            parses(&["gesture", "camera", "/dev/video2"]),
            Command::GestureSetCamera { .. }
        ));
        assert!(matches!(parses(&["claude"]), Command::ClaudeList));
        assert!(matches!(parses(&["claude", "watch"]), Command::ClaudeWatch));
        assert!(matches!(
            parses(&["claude", "focus", "abc"]),
            Command::ClaudeFocus { .. }
        ));
        match parses(&["pilot", "baisse", "le", "son"]) {
            Command::PilotAsk { text, clipboard } => {
                assert_eq!((text.as_str(), clipboard), ("baisse le son", false))
            }
            _ => panic!("wrong command"),
        }
        assert!(matches!(parses(&["pilot", "watch"]), Command::PilotWatch));
        assert!(matches!(
            serde_json::from_value::<Command>(json!({"cmd": "desk", "tool": "volume"})).unwrap(),
            Command::Desk { .. }
        ));
        assert!(matches!(parses(&["phone"]), Command::PhoneWatch));
        assert!(matches!(
            parses(&["phone", "share", "abc_123", "/tmp/x"]),
            Command::PhoneAction { .. }
        ));
        assert!(matches!(
            parses(&["phone", "screen", "Pixel 9a"]),
            Command::PhoneScreen { .. }
        ));
        assert!(matches!(
            parses(&["servers", "watch"]),
            Command::ServersWatch { name: None }
        ));
        assert!(matches!(
            parses(&["servers", "watch", "gary"]),
            Command::ServersWatch { name: Some(n) } if n == "gary"
        ));
        for action in ["on", "off", "reboot"] {
            assert!(matches!(
                parses(&["servers", action, "gary"]),
                Command::ServersPower { .. }
            ));
        }
    }

    /// The hook's message must parse as a daemon command too.
    #[test]
    fn hook_message_round_trips() {
        let v = json!({
            "cmd": "claude_hook",
            "pid": 42,
            "event": {"hook_event_name": "Stop", "session_id": "s"},
        });
        assert!(matches!(
            serde_json::from_value::<Command>(v).unwrap(),
            Command::ClaudeHook { pid: Some(42), .. }
        ));
    }

    #[test]
    fn quotes_in_arguments_stay_valid_json() {
        match parses(&["set", r#"#12"}, "x":"y"#]) {
            Command::SetAccent { color } => assert_eq!(color, r#"#12"}, "x":"y"#),
            _ => panic!("wrong command"),
        }
    }

    #[test]
    fn only_watch_commands_stream() {
        assert!(build_command(&argv(&["watch"])).unwrap().1);
        assert!(build_command(&argv(&["gesture", "watch"])).unwrap().1);
        assert!(!build_command(&argv(&["get"])).unwrap().1);
    }

    #[test]
    fn missing_arguments_are_usage_errors() {
        assert!(build_command(&argv(&[])).is_none());
        assert!(build_command(&argv(&["set"])).is_none());
        assert!(build_command(&argv(&["palette-color", "base08"])).is_none());
        assert!(build_command(&argv(&["gesture", "camera"])).is_none());
        assert!(build_command(&argv(&["gesture", "fly"])).is_none());
        assert!(build_command(&argv(&["claude", "focus"])).is_none());
        assert!(build_command(&argv(&["frobnicate"])).is_none());
    }
}
