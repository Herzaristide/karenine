//! `anna share-picker` (installed as `anna-share-picker`): what to share
//! of the screen, chosen in karenine (prompts.rs) instead of
//! `hyprland-share-picker`.
//!
//! xdg-desktop-portal-hyprland runs it when an application asks to share the
//! screen (`screencopy:custom_picker_binary`). It gives what can be shared in
//! the environment, and reads the choice on stdout:
//!   XDPH_OUTPUT_SHARING_LIST     `<len>:<name>:<x>:<y>:<w>:<h>;` per screen
//!                                (logical geometry)
//!   XDPH_WINDOW_SHARING_LIST     `<handle>[HC>]<class>[HT>]<title>[HE>]
//!                                <hyprland address>[HA>]` per window
//!   XDPH_WORKSPACE_SHARING_LIST_V2
//!                                `<len>:<name>:<id>;` per workspace
//!   `--allow-token`              the « remember » box ticked by default
//! and the answer is `[SELECTION]<flags>/<what>`, `<what>` being
//! `screen:<name>`, `window:<handle>`, `workspace-id:<id>` or
//! `region:<screen>@<x>,<y>,<w>,<h>` (relative to the screen); the `r` flag
//! lets the application share the same thing again without asking. Printing
//! nothing cancels.
//!
//! Without anna or the shell, the request goes to `ANNA_SHARE_PICKER_FALLBACK`,
//! else to `hyprland-share-picker`.
//!
//! Electron applications (Claude Desktop, Discord…) ask two or three times
//! for one share: once to list the sources, once to start the capture
//! (Chromium does the same: one for the preview, one for the content). Every
//! request within REUSE_MS of a choice gets the same answer without the card,
//! if what was chosen can still be shared. The delay runs from the choice,
//! not from the last reuse, so the window cannot stretch.

use crate::i18n;
use crate::prompts::{Action, Choice, Field};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;

#[derive(Debug, PartialEq, Clone)]
struct Output {
    name: String,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
}

#[derive(Debug, PartialEq)]
struct Window {
    handle: String,
    class: String,
    title: String,
    /// Hyprland's address of the window, hex without `0x`; "0" unknown.
    address: String,
}

#[derive(Debug, PartialEq)]
struct Workspace {
    name: String,
    id: String,
}

/// Read `<len>:<text>` at the start of `s`: the text, and what follows.
fn take_sized(s: &str) -> Option<(&str, &str)> {
    let (len, rest) = s.split_once(':')?;
    let len: usize = len.parse().ok()?;
    let text = rest.get(..len)?;
    Some((text, &rest[len..]))
}

fn parse_outputs(list: &str) -> Vec<Output> {
    let mut out = Vec::new();
    let mut rest = list;
    while !rest.is_empty() {
        let Some((name, after)) = take_sized(rest) else { break };
        let after = after.strip_prefix(':').unwrap_or(after);
        let (geom, next) = after.split_once(';').unwrap_or((after, ""));
        let n: Vec<i64> = geom.split(':').filter_map(|v| v.parse().ok()).collect();
        if let [x, y, w, h] = n[..] {
            out.push(Output { name: name.into(), x, y, w, h });
        }
        rest = next;
    }
    out
}

fn parse_windows(list: &str) -> Vec<Window> {
    list.split("[HA>]")
        .filter_map(|rec| {
            let (handle, rest) = rec.split_once("[HC>]")?;
            let (class, rest) = rest.split_once("[HT>]")?;
            let (title, mapping) = rest.split_once("[HE>]")?;
            let address = mapping
                .trim()
                .parse::<u64>()
                .map(|a| format!("{a:x}"))
                .unwrap_or_else(|_| "0".into());
            Some(Window {
                handle: handle.trim().into(),
                class: class.trim().into(),
                title: title.trim().into(),
                address,
            })
        })
        .collect()
}

fn parse_workspaces(list: &str) -> Vec<Workspace> {
    let mut out = Vec::new();
    let mut rest = list;
    while !rest.is_empty() {
        let Some((name, after)) = take_sized(rest) else { break };
        let after = after.strip_prefix(':').unwrap_or(after);
        let (id, next) = after.split_once(';').unwrap_or((after, ""));
        if id.parse::<u64>().is_ok_and(|i| i != 0) {
            out.push(Workspace { name: name.into(), id: id.into() });
        }
        rest = next;
    }
    out
}

const REGION: &str = "region";

/// How long a choice answers the next request by itself.
const REUSE_MS: u64 = 8000;

fn last_path() -> std::path::PathBuf {
    std::path::PathBuf::from(crate::paths::runtime_dir()).join("anna-share-last")
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// The answer line just given, kept for the request that follows it:
/// `<ms>\n<line>`, readable by us only.
fn remember_last(line: &str) {
    use std::os::unix::fs::OpenOptionsExt;
    let _ = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(last_path())
        .and_then(|mut f| write!(f, "{}\n{line}", now_ms()));
}

/// The answer to give again, if it was chosen less than REUSE_MS ago. An
/// older one is removed.
fn take_last(now: u64) -> Option<String> {
    let text = std::fs::read_to_string(last_path()).ok()?;
    let line = recent(&text, now);
    if line.is_none() {
        let _ = std::fs::remove_file(last_path());
    }
    line
}

fn recent(text: &str, now: u64) -> Option<String> {
    let (at, line) = text.split_once('\n')?;
    let at: u64 = at.trim().parse().ok()?;
    (now >= at && now - at <= REUSE_MS && line.starts_with("[SELECTION]")).then(|| line.trim().to_string())
}

/// Whether the answer line still names something that can be shared.
fn still_there(line: &str, outputs: &[Output], windows: &[Window], workspaces: &[Workspace]) -> bool {
    let Some((_, what)) = line.split_once('/') else { return false };
    if let Some(name) = what.strip_prefix("screen:") {
        outputs.iter().any(|o| o.name == name)
    } else if let Some(handle) = what.strip_prefix("window:") {
        windows.iter().any(|w| w.handle == handle)
    } else if let Some(id) = what.strip_prefix("workspace-id:") {
        workspaces.iter().any(|w| w.id == id)
    } else if let Some(region) = what.strip_prefix("region:") {
        let name = region.split('@').next().unwrap_or("");
        outputs.iter().any(|o| o.name == name)
    } else {
        false
    }
}

/// What anna is sent to show.
fn spec(outputs: &[Output], windows: &[Window], workspaces: &[Workspace], remember: bool) -> Value {
    let mut options = Vec::new();
    let screens = i18n::tr("share.screens");
    for o in outputs {
        options.push(Choice {
            id: format!("screen:{}", o.name),
            label: o.name.clone(),
            sub: format!("{} × {}", o.w, o.h),
            group: screens.clone(),
            preview: Some(json!({ "screen": o.name })),
        });
    }
    let wins = i18n::tr("share.windows");
    for w in windows {
        options.push(Choice {
            id: format!("window:{}", w.handle),
            label: if w.title.is_empty() { w.class.clone() } else { w.title.clone() },
            sub: w.class.clone(),
            group: wins.clone(),
            preview: Some(json!({ "window": w.address })),
        });
    }
    let other = i18n::tr("share.other");
    for ws in workspaces {
        options.push(Choice {
            id: format!("workspace-id:{}", ws.id),
            label: i18n::tr_args("share.workspace", &[("name", &ws.name)]),
            sub: String::new(),
            group: other.clone(),
            preview: None,
        });
    }
    options.push(Choice {
        id: REGION.into(),
        label: i18n::tr("share.region"),
        sub: String::new(),
        group: other,
        preview: None,
    });
    let first = options.first().map(|c| c.id.clone()).unwrap_or_default();
    json!({
        "cmd": "prompt_open",
        "prompt": {
            "kind": "share",
            "title": i18n::tr("share.title"),
            "fields": [
                Field {
                    key: "what".into(),
                    kind: "choice".into(),
                    label: String::new(),
                    value: first,
                    options,
                },
                Field {
                    key: "remember".into(),
                    kind: "check".into(),
                    label: i18n::tr("share.remember"),
                    value: remember.to_string(),
                    options: Vec::new(),
                },
            ],
            "actions": [Action {
                id: "share".into(),
                label: i18n::tr("share.share"),
                primary: true,
                danger: false,
            }],
            "timeout": 180,
        }
    })
}

/// A region picked with slurp, relative to its screen:
/// `region:<screen>@<x>,<y>,<w>,<h>`.
fn pick_region(outputs: &[Output]) -> Option<String> {
    let out = std::process::Command::new("slurp")
        .args(["-f", "%o %x %y %w %h"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    region_from_slurp(&String::from_utf8_lossy(&out.stdout), outputs)
}

fn region_from_slurp(line: &str, outputs: &[Output]) -> Option<String> {
    let mut parts = line.split_whitespace();
    let name = parts.next()?;
    let n: Vec<i64> = parts.filter_map(|v| v.parse().ok()).collect();
    let [x, y, w, h] = n[..] else { return None };
    let o = outputs.iter().find(|o| o.name == name)?;
    if w <= 0 || h <= 0 {
        return None;
    }
    // slurp gives the layout's coordinates; xdph wants the screen's.
    let (rx, ry) = ((x - o.x).max(0), (y - o.y).max(0));
    Some(format!("region:{name}@{rx},{ry},{w},{h}"))
}

fn ask_anna(request: &Value) -> Option<Value> {
    let mut stream = UnixStream::connect(crate::paths::socket_path()).ok()?;
    stream.write_all(format!("{request}\n").as_bytes()).ok()?;
    let mut line = String::new();
    BufReader::new(&stream).read_line(&mut line).ok()?;
    let reply: Value = serde_json::from_str(&line).ok()?;
    if reply["ok"] == json!(false) && reply["error"] == json!("no_shell") {
        return None;
    }
    Some(reply)
}

fn fallback(args: &[String]) -> ! {
    let prog = std::env::var("ANNA_SHARE_PICKER_FALLBACK")
        .ok()
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "hyprland-share-picker".into());
    let err = std::process::Command::new(&prog).args(args).exec();
    eprintln!("anna share-picker: {prog}: {err}");
    std::process::exit(1);
}

pub fn run(args: &[String]) -> ! {
    let rest = &args[2.min(args.len())..];
    let env = |k: &str| std::env::var(k).unwrap_or_default();
    let outputs = parse_outputs(&env("XDPH_OUTPUT_SHARING_LIST"));
    let windows = parse_windows(&env("XDPH_WINDOW_SHARING_LIST"));
    let workspaces = parse_workspaces(&env("XDPH_WORKSPACE_SHARING_LIST_V2"));
    let allow_token = rest.iter().any(|a| a == "--allow-token");

    if let Some(line) = take_last(now_ms()) {
        if still_there(&line, &outputs, &windows, &workspaces) {
            println!("{line}");
            std::process::exit(0);
        }
    }

    let Some(reply) = ask_anna(&spec(&outputs, &windows, &workspaces, allow_token)) else {
        fallback(rest);
    };
    if reply["ok"] != json!(true) || reply["action"] != json!("share") {
        // Nothing printed: the application is told the user cancelled.
        std::process::exit(0);
    }
    let what = reply["values"]["what"].as_str().unwrap_or("").to_string();
    let what = if what == REGION {
        match pick_region(&outputs) {
            Some(r) => r,
            None => std::process::exit(0),
        }
    } else {
        what
    };
    if what.is_empty() {
        std::process::exit(0);
    }
    let flags = if reply["values"]["remember"] == json!("true") { "r" } else { "" };
    let line = format!("[SELECTION]{flags}/{what}");
    println!("{line}");
    remember_last(&line);
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_screens_are_read() {
        let o = parse_outputs("4:DP-1:0:0:2560:1440;5:eDP-1:2560:0:1920:1200;");
        assert_eq!(o.len(), 2);
        assert_eq!(o[1], Output { name: "eDP-1".into(), x: 2560, y: 0, w: 1920, h: 1200 });
        // A name holding the separators is read by its length.
        let o = parse_outputs("7:HDMI:;1:10:20:800:600;");
        assert_eq!(o[0].name, "HDMI:;1");
        assert_eq!(o[0].w, 800);
        assert!(parse_outputs("").is_empty());
    }

    #[test]
    fn the_windows_are_read() {
        let w = parse_windows(
            "123[HC>]zen[HT>]Meet - Zen[HE>]94046876913328[HA>]7[HC>]Alacritty[HT>][HE>]0[HA>]",
        );
        assert_eq!(w.len(), 2);
        assert_eq!(w[0].handle, "123");
        assert_eq!(w[0].title, "Meet - Zen");
        assert_eq!(w[0].address, format!("{:x}", 94046876913328u64));
        assert_eq!(w[1].title, "");
        assert_eq!(w[1].address, "0");
    }

    #[test]
    fn the_workspaces_are_read() {
        let ws = parse_workspaces("1:1:7;3:web:12;1:x:0;");
        assert_eq!(ws, vec![
            Workspace { name: "1".into(), id: "7".into() },
            Workspace { name: "web".into(), id: "12".into() },
        ]);
    }

    #[test]
    fn a_region_is_relative_to_its_screen() {
        let o = parse_outputs("4:DP-1:0:0:2560:1440;5:eDP-1:2560:0:1920:1200;");
        assert_eq!(
            region_from_slurp("eDP-1 2660 100 400 300\n", &o).as_deref(),
            Some("region:eDP-1@100,100,400,300")
        );
        assert_eq!(region_from_slurp("HDMI-9 0 0 4 4", &o), None);
        assert_eq!(region_from_slurp("DP-1 0 0 0 4", &o), None);
    }

    #[test]
    fn a_choice_answers_the_next_request_for_a_while() {
        let line = "[SELECTION]r/screen:DP-1";
        assert_eq!(recent(&format!("1000\n{line}"), 5000).as_deref(), Some(line));
        assert_eq!(recent(&format!("1000\n{line}"), 1000 + REUSE_MS + 1), None);
        assert_eq!(recent("garbage", 5000), None);
        assert_eq!(recent("1000\nscreen:DP-1", 2000), None);
    }

    #[test]
    fn a_reused_choice_must_still_exist() {
        let o = parse_outputs("4:DP-1:0:0:2560:1440;");
        let w = parse_windows("123[HC>]zen[HT>]Meet[HE>]0[HA>]");
        let ws = parse_workspaces("1:1:7;");
        assert!(still_there("[SELECTION]/screen:DP-1", &o, &w, &ws));
        assert!(!still_there("[SELECTION]/screen:HDMI-A-1", &o, &w, &ws));
        assert!(still_there("[SELECTION]r/window:123", &o, &w, &ws));
        assert!(!still_there("[SELECTION]r/window:124", &o, &w, &ws));
        assert!(still_there("[SELECTION]/workspace-id:7", &o, &w, &ws));
        assert!(still_there("[SELECTION]/region:DP-1@0,0,10,10", &o, &w, &ws));
    }

    #[test]
    fn the_prompt_lists_every_choice() {
        let o = parse_outputs("4:DP-1:0:0:2560:1440;");
        let w = parse_windows("123[HC>]zen[HT>]Meet[HE>]0[HA>]");
        let s = spec(&o, &w, &[], true);
        let what = &s["prompt"]["fields"][0];
        assert_eq!(what["value"], "screen:DP-1");
        let ids: Vec<&str> = what["options"].as_array().unwrap().iter()
            .map(|c| c["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["screen:DP-1", "window:123", "region"]);
        assert_eq!(s["prompt"]["fields"][1]["value"], "true");
        let parsed: crate::prompts::Spec = serde_json::from_value(s["prompt"].clone()).unwrap();
        assert_eq!(parsed.fields[0].options[1].preview, Some(json!({ "window": "0" })));
    }
}
