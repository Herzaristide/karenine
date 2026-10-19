#![recursion_limit = "256"]

//! anna — unified engine daemon for the karenine Quickshell interface.
//!
//! A single binary that dispatches on its first argument:
//!   anna                 run the socket server (daemon)
//!   anna daemon          same as above
//!   anna init [--no-hyprctl]
//!                        one-shot: render theme templates + fire reloads, exit
//!   anna set "#rrggbb"   client: change accent color
//!   anna mode dark|light client: switch palette mode
//!   anna palette-color <key> "#rrggbb" [mode]
//!                        client: set a base16 palette entry
//!   anna reset           client: default accent + active mode's default palette
//!   anna get             client: print current theme state as JSON
//!   anna watch           client: stream theme changes as JSON lines
//!   anna msi-rgb-watch   reflect the accent color onto the MSI RGB keyboard
//!   anna gesture on|off|toggle|status|watch|cameras|camera /dev/videoN
//!                        client: webcam gesture control
//!   anna gesture debug [--dry]
//!                        run the gesture engine in the foreground with
//!                        per-second diagnostics (disable the daemon's first:
//!                        the camera is exclusive); --dry performs no action
//!   anna mcp             MCP server (stdio) of the pilot's desk tools
//!   anna hook            Claude Code hook: forward one event (stdin) to the
//!                        daemon; silent, always exits 0
//!   anna claude [watch|focus <id>]
//!                        client: live Claude Code sessions
//!
//! Services exposed over `$XDG_RUNTIME_DIR/anna.sock`:
//!   - theme    : accent/palette (set/mode/palette-color/get/watch)
//!   - hwstats  : hardware stats (hwstats_get / hwstats_watch)
//!   - servers  : tailnet devices, stats over ssh (servers_watch / servers_list)
//!   - phone    : KDE Connect phones (phone_watch / phone_action)
//!   - gesture  : webcam control (gesture_get/set/toggle/watch)
//!   - claude   : live Claude Code sessions (claude_hook/list/watch/focus)

mod appctl;
mod audio;
mod chroma;
mod claude;
mod client;
mod color;
mod gesture;
mod hwstats;
mod i18n;
mod icons;
mod metronome;
mod msi;
mod notes;
mod paths;
mod phone;
mod protocol;
mod servers;
mod state;
mod templates;
mod tuner;

use appctl::{reload_all, AppCtlOptions};
use protocol::{Command, Response};
use state::AppState;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::broadcast;

// ── Entry point / dispatch ──────────────────────────────────────────────────

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();

    match args.get(1).map(String::as_str) {
        // Client subcommands: connect to the running daemon and print the reply.
        Some("set" | "mode" | "palette-color" | "reset" | "get" | "watch") => {
            client::run(&args);
        }
        Some("gesture") if args.get(2).map(String::as_str) == Some("debug") => {
            // Foreground engine, forced on, with diagnostics on stderr.
            let dry = args.iter().any(|a| a == "--dry");
            let dir = std::env::temp_dir().join("anna-gesture-debug");
            let _ = tokio::fs::create_dir_all(&dir).await;
            // Same camera/direction settings as the daemon, without touching its file.
            let _ = tokio::fs::copy(
                paths::accent_dir().join("gesture.json"),
                dir.join("gesture.json"),
            )
            .await;
            let g = gesture::Gesture::start(&dir, true, dry);
            g.set_enabled(true);
            loop {
                tokio::time::sleep(Duration::from_secs(3600)).await;
            }
        }
        Some("gesture" | "claude" | "pilot" | "voice" | "servers" | "phone") => {
            client::run(&args);
        }
        // The « Notes » tab: works on its files directly, no daemon needed.
        Some("notes") => {
            notes::run(&args);
        }
        // Claude Code hook: must stay silent and exit 0 whatever happens.
        // MCP server of the pilot's desk tools (started by Claude Code).
        Some("mcp") => {
            claude::mcp::run();
        }
        // Scores of the wake word over a WAV, 80 ms apart (claude/wake.rs).
        Some("wake-score") => {
            claude::wake::score_file(args.get(2).map(String::as_str));
        }
        Some("hook") => {
            claude::hook::run();
        }
        // Reflect the accent color onto the MSI RGB keyboard (long-lived).
        Some("msi-rgb-watch") => {
            msi::run().await;
        }
        // One-shot render used by the home-manager activation.
        Some("init") => {
            let no_hyprctl = args.iter().any(|a| a == "--no-hyprctl");
            let app_state = AppState::load(paths::accent_dir());
            run_init(&app_state, &AppCtlOptions { no_hyprctl });
        }
        // Default: run the daemon. A bare leading flag (e.g. `--no-hyprctl`,
        // `--socket …`) also means daemon mode — run_daemon parses the flags.
        None | Some("daemon") => {
            run_daemon(&args).await;
        }
        Some(flag) if flag.starts_with('-') => {
            run_daemon(&args).await;
        }
        Some(other) => {
            eprintln!("anna: unknown command '{other}'");
            eprintln!(
                "Usage: anna [daemon|init|set|mode|palette-color|reset|get|watch|gesture|claude|hook|mcp|notes|msi-rgb-watch]"
            );
            std::process::exit(2);
        }
    }
}

// ── Daemon ──────────────────────────────────────────────────────────────────

async fn run_daemon(args: &[String]) {
    let mut no_hyprctl = false;
    let mut socket_override: Option<String> = None;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--no-hyprctl" => no_hyprctl = true,
            "--socket" => {
                i += 1;
                socket_override = args.get(i).cloned();
            }
            _ => {}
        }
        i += 1;
    }

    let app_state = AppState::load(paths::accent_dir());
    let opts = AppCtlOptions { no_hyprctl };

    let socket = socket_override.unwrap_or_else(paths::socket_path);
    // A socket that still accepts connections belongs to a live daemon: taking
    // it over would silently orphan that one. Otherwise it is stale — remove it.
    if std::os::unix::net::UnixStream::connect(&socket).is_ok() {
        eprintln!("anna: another daemon is already listening on {socket}");
        std::process::exit(1);
    }
    let _ = tokio::fs::remove_file(&socket).await;

    let listener = match UnixListener::bind(&socket) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("anna: cannot bind socket {socket}: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("anna: listening on {socket}");

    // Initial render so all config files are up to date on daemon start.
    run_init(&app_state, &opts);

    // Broadcast channel for theme Watch subscribers.
    let (tx, _) = broadcast::channel::<String>(32);

    // Webcam gesture engine: its own thread, idle while disabled.
    // ANNA_GESTURE_DEBUG=1 logs the same diagnostics as `anna gesture debug`.
    let verbose = std::env::var_os("ANNA_GESTURE_DEBUG").is_some();
    let gesture = gesture::Gesture::start(&paths::accent_dir(), verbose, false);

    // Live Claude Code sessions, fed by `anna hook`.
    let claude = claude::Sessions::new();
    // The pilot: the conversation bar's requests for the desktop.
    let pilot = claude::pilot::Pilot::new(Arc::clone(&claude));
    // Speaking to the pilot (whisper.cpp, local).
    let voice = claude::voice::Voice::new(Arc::clone(&pilot));
    // The vault's skills, linked where Claude Code looks for them.
    tokio::task::spawn_blocking(|| claude::skills::link_skills(&claude::skills::skills_dir()));

    // Every screenshot also lands in the « Notes » tab.
    tokio::spawn(notes::watch_screenshots());

    let ctx = Arc::new(Ctx {
        theme: Mutex::new(Versioned {
            state: app_state,
            version: 0,
        }),
        applied: tokio::sync::Mutex::new(0),
        tx,
        gesture,
        claude,
        pilot,
        voice,
        opts,
    });

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let ctx = Arc::clone(&ctx);
                tokio::spawn(async move {
                    handle_connection(stream, ctx).await;
                });
            }
            Err(e) => eprintln!("anna: accept error: {e}"),
        }
    }
}

/// State shared by every connection.
struct Ctx {
    /// Theme state + its version. Only held for in-memory reads/updates —
    /// never across I/O.
    theme: Mutex<Versioned>,
    /// Serializes applies end to end (save + render + reload), so files never
    /// land out of order; holds the version last written to disk.
    applied: tokio::sync::Mutex<u64>,
    /// Theme Watch subscribers.
    tx: broadcast::Sender<String>,
    gesture: Arc<gesture::Gesture>,
    claude: Arc<claude::Sessions>,
    pilot: Arc<claude::pilot::Pilot>,
    voice: Arc<claude::voice::Voice>,
    opts: AppCtlOptions,
}

struct Versioned {
    state: AppState,
    /// Bumped on every accepted change.
    version: u64,
}

impl Ctx {
    /// Lock the theme state. A panic while it was held can't leave it half
    /// written (updates are single assignments), so poisoning is ignored
    /// rather than taking every later request down with it.
    fn theme(&self) -> std::sync::MutexGuard<'_, Versioned> {
        self.theme.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Apply `update` to the theme, then persist, render and live-reload it on
    /// a blocking thread (file writes, icon recoloring, `hyprctl reload`…)
    /// without holding the state lock, so reads stay instant meanwhile.
    ///
    /// Bursts coalesce: a color-picker drag or the rainbow mode send several
    /// changes per second, while one apply takes about as long. A change that
    /// waited for the previous apply finds that the next one (which includes
    /// it) already went through, and returns without redoing the work.
    async fn change_theme(
        &self,
        update: impl FnOnce(&mut AppState) -> Result<(), String>,
    ) -> Result<protocol::PaletteState, String> {
        let mine = {
            let mut t = self.theme();
            update(&mut t.state)?;
            t.version += 1;
            t.version
        };
        let mut applied = self.applied.lock().await;
        let (snapshot, version) = {
            let t = self.theme();
            (t.state.clone(), t.version)
        };
        if *applied >= mine {
            return Ok(snapshot.to_palette_state());
        }
        let opts = self.opts;
        let result = tokio::task::spawn_blocking(move || apply_change(&snapshot, &opts))
            .await
            .map_err(|e| format!("apply task failed: {e}"))?;
        if result.is_ok() {
            *applied = version;
        }
        result
    }
}

// ── Connection handler ──────────────────────────────────────────────────────

async fn handle_connection(stream: UnixStream, ctx: Arc<Ctx>) {
    let gesture = &ctx.gesture;
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    let line = match lines.next_line().await {
        Ok(Some(l)) => l,
        _ => return,
    };

    let cmd: Command = match serde_json::from_str(&line) {
        Ok(c) => c,
        Err(e) => {
            let resp = Response::err(format!("parse error: {e}"));
            let _ = write_response(&mut writer, &resp).await;
            return;
        }
    };

    match cmd {
        Command::GetState => {
            let state_snapshot = ctx.theme().state.to_palette_state();
            let resp = Response::ok(state_snapshot);
            let _ = write_response(&mut writer, &resp).await;
        }

        Command::SetAccent { color } => {
            let result = ctx.change_theme(|state| state.set_accent(&color)).await;
            respond_theme(&mut writer, &ctx.tx, result).await;
        }

        Command::SetMode { mode } => {
            let result = ctx.change_theme(|state| state.set_mode(&mode)).await;
            respond_theme(&mut writer, &ctx.tx, result).await;
        }

        Command::ResetTheme => {
            let result = ctx
                .change_theme(|state| {
                    state.reset();
                    Ok(())
                })
                .await;
            respond_theme(&mut writer, &ctx.tx, result).await;
        }

        Command::SetPaletteColor { key, color, mode } => {
            let result = ctx
                .change_theme(|state| state.set_palette_color(&key, &color, mode.as_deref()))
                .await;
            respond_theme(&mut writer, &ctx.tx, result).await;
        }

        Command::Watch => {
            // Subscribe first so a change racing the snapshot isn't lost.
            let mut rx = ctx.tx.subscribe();
            let state_snapshot = ctx.theme().state.to_palette_state();
            let initial = serde_json::to_string(&Response::ok(state_snapshot)).unwrap_or_default();
            if write_line(&mut writer, &initial).await.is_err() {
                return;
            }

            loop {
                match rx.recv().await {
                    Ok(msg) => {
                        if write_line(&mut writer, &msg).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                }
            }
        }

        // ── hwstats service ──────────────────────────────────────────────
        Command::HwstatsGet => {
            // Prime once, wait a beat, then sample so the CPU delta is meaningful.
            let Some((collector, _)) = sample_hwstats(hwstats::Collector::new()).await else {
                return;
            };
            tokio::time::sleep(Duration::from_millis(250)).await;
            if let Some((_, snap)) = sample_hwstats(collector).await {
                let json = serde_json::to_string(&snap).unwrap_or_default();
                let _ = write_line(&mut writer, &json).await;
            }
        }

        Command::HwstatsWatch { interval_ms } => {
            let mut collector = hwstats::Collector::new();
            let period = interval_ms.unwrap_or(1000).clamp(250, 5000);
            let mut interval = tokio::time::interval(Duration::from_millis(period));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                let Some((c, snap)) = sample_hwstats(collector).await else {
                    break;
                };
                collector = c;
                let json = serde_json::to_string(&snap).unwrap_or_default();
                if write_line(&mut writer, &json).await.is_err() {
                    break; // socket closed
                }
            }
        }

        // ── tailnet devices ──────────────────────────────────────────────
        Command::ServersWatch { name } => {
            let mut memory = servers::Memory::default();
            let mut interval = tokio::time::interval(Duration::from_secs(3));
            // A slow server delays the next round rather than stacking them.
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                let stats = servers::sample_all(&mut memory, name.as_deref()).await;
                let json = serde_json::json!({ "servers": stats }).to_string();
                if write_line(&mut writer, &json).await.is_err() {
                    break; // socket closed
                }
            }
        }

        Command::ServersList => {
            let json = serde_json::to_string(&servers::load().await).unwrap_or_default();
            let _ = write_line(&mut writer, &json).await;
        }

        Command::ServersPower { name, action } => {
            let reply = match servers::power(&name, &action).await {
                Ok(()) => serde_json::json!({ "ok": true }),
                Err(e) => serde_json::json!({ "ok": false, "error": e }),
            };
            let _ = write_line(&mut writer, &reply.to_string()).await;
        }

        // ── phones (KDE Connect) ─────────────────────────────────────────
        Command::PhoneWatch => {
            let mut interval = tokio::time::interval(Duration::from_secs(2));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                let json = serde_json::json!({ "phone": phone::sample().await }).to_string();
                if write_line(&mut writer, &json).await.is_err() {
                    break; // socket closed
                }
            }
        }

        Command::PhoneAction {
            device,
            action,
            arg,
        } => {
            let reply = match phone::act(&device, &action, &arg).await {
                Ok(()) => serde_json::json!({ "ok": true }),
                Err(e) => serde_json::json!({ "ok": false, "error": e }),
            };
            let _ = write_line(&mut writer, &reply.to_string()).await;
        }

        Command::PhoneScreen { name } => {
            let reply = match phone::screen(&name).await {
                Ok(command) => serde_json::json!({ "ok": true, "command": command }),
                Err(e) => serde_json::json!({ "ok": false, "error": e }),
            };
            let _ = write_line(&mut writer, &reply.to_string()).await;
        }

        // ── audio services ───────────────────────────────────────────────
        Command::TunerWatch => {
            stream_audio_service(&mut writer, tuner::run).await;
        }

        Command::ChromaWatch => {
            stream_audio_service(&mut writer, chroma::run).await;
        }

        Command::Metronome => {
            run_metronome(&mut writer, &mut lines).await;
        }

        // ── gesture control ──────────────────────────────────────────────
        Command::GestureGet => {
            write_gesture_status(&mut writer, &gesture.status()).await;
        }

        Command::GestureSet { enabled } => {
            gesture.set_enabled(enabled);
            write_gesture_status(&mut writer, &gesture.status()).await;
        }

        Command::GestureToggle => {
            gesture.set_enabled(!gesture.enabled());
            write_gesture_status(&mut writer, &gesture.status()).await;
        }

        Command::GestureCameras => {
            let json = serde_json::to_string(&gesture::cameras()).unwrap_or_default();
            let _ = write_line(&mut writer, &json).await;
        }

        Command::GestureSetCamera { device } => {
            if device.starts_with("/dev/video") {
                gesture.set_camera(&device);
                write_gesture_status(&mut writer, &gesture.status()).await;
            } else {
                let resp = Response::err(format!("not a V4L2 device: {device}"));
                let _ = write_response(&mut writer, &resp).await;
            }
        }

        Command::GestureWatch => {
            let mut rx = gesture.subscribe();
            loop {
                let status = rx.borrow_and_update().clone();
                let json = serde_json::to_string(&status).unwrap_or_default();
                if write_line(&mut writer, &json).await.is_err() || rx.changed().await.is_err() {
                    break;
                }
            }
        }

        // ── Claude Code sessions ─────────────────────────────────────────
        Command::ClaudeHook { pid, event } => {
            ctx.claude.apply(&event, pid);
            let _ = write_line(&mut writer, "{\"ok\":true}").await;
        }

        Command::ClaudeList => {
            let json = serde_json::to_string(&ctx.claude.list()).unwrap_or_default();
            let _ = write_line(&mut writer, &json).await;
        }

        Command::ClaudeWatch => {
            // Subscribe first so a change racing the snapshot isn't lost.
            let mut rx = ctx.claude.subscribe();
            if write_line(&mut writer, &ctx.claude.snapshot_line())
                .await
                .is_err()
            {
                return;
            }
            loop {
                match rx.recv().await {
                    Ok(msg) => {
                        if write_line(&mut writer, &msg).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                    // Each line carries the whole list: lagging loses at most
                    // an alert, never the state.
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                }
            }
        }

        Command::ClaudeFocus { id } => {
            let result = match ctx.claude.pid_of(&id) {
                Some(pid) => tokio::task::spawn_blocking(move || claude::focus::focus(pid))
                    .await
                    .unwrap_or_else(|e| Err(format!("focus task failed: {e}"))),
                None => Err("session inconnue ou sans processus".into()),
            };
            let reply = match result {
                Ok(()) => serde_json::json!({ "ok": true }),
                Err(e) => serde_json::json!({ "ok": false, "error": e }),
            };
            let _ = write_line(&mut writer, &reply.to_string()).await;
        }

        // ── Pilot ────────────────────────────────────────────────────────
        Command::PilotAsk { text, clipboard } => {
            write_result(&mut writer, ctx.pilot.ask(&text, clipboard).await).await;
        }

        Command::PilotWatch => {
            let mut rx = ctx.pilot.subscribe();
            if write_line(&mut writer, &ctx.pilot.snapshot_line())
                .await
                .is_err()
            {
                return;
            }
            loop {
                match rx.recv().await {
                    Ok(msg) => {
                        if write_line(&mut writer, &msg).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                }
            }
        }

        // ── Voice ────────────────────────────────────────────────────────
        Command::VoiceToggle { send } => {
            ctx.voice.toggle(send);
            write_result(&mut writer, Ok(())).await;
        }

        Command::VoiceWatch => {
            let mut rx = ctx.voice.subscribe();
            if write_line(&mut writer, &ctx.voice.snapshot_line())
                .await
                .is_err()
            {
                return;
            }
            loop {
                match rx.recv().await {
                    Ok(msg) => {
                        if write_line(&mut writer, &msg).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                }
            }
        }

        Command::VoiceWake { on } => {
            let on = on.unwrap_or(!ctx.voice.wake_on());
            ctx.voice.set_wake(on);
            write_result(&mut writer, Ok(())).await;
        }

        Command::VoiceSimulate { path, send } => {
            let result = match tokio::fs::read(&path)
                .await
                .ok()
                .and_then(|b| claude::voice::read_wav(&b))
            {
                Some((samples, rate)) => {
                    ctx.voice.simulate(samples, rate, send);
                    Ok(())
                }
                None => Err(format!("WAV 16 bits illisible : {path}")),
            };
            write_result(&mut writer, result).await;
        }

        Command::VoiceTranscribe { path } => {
            let reply = match tokio::task::spawn_blocking(move || {
                claude::voice::transcribe(std::path::Path::new(&path))
            })
            .await
            {
                Ok(Ok(text)) => serde_json::json!({ "ok": true, "text": text }),
                Ok(Err(e)) => serde_json::json!({ "ok": false, "error": e }),
                Err(e) => serde_json::json!({ "ok": false, "error": e.to_string() }),
            };
            let _ = write_line(&mut writer, &reply.to_string()).await;
        }

        Command::PilotReset => {
            ctx.pilot.reset().await;
            write_result(&mut writer, Ok(())).await;
        }

        Command::Desk { tool, args } => {
            let result = run_desk(&ctx, &tool, &args).await;
            let reply = match result {
                Ok(text) => serde_json::json!({ "ok": true, "text": text }),
                Err(text) => serde_json::json!({ "ok": false, "text": text }),
            };
            let _ = write_line(&mut writer, &reply.to_string()).await;
        }
    }
}

/// One desk tool for the pilot (claude/desk.rs). The tools that touch the
/// daemon's own state run here; the rest run on a blocking thread.
async fn run_desk(ctx: &Arc<Ctx>, tool: &str, args: &serde_json::Value) -> Result<String, String> {
    use claude::desk;

    let s = |k: &str| {
        args.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .trim()
            .to_string()
    };
    let sessions_text = || {
        let list = ctx.claude.list();
        if list.is_empty() {
            return "aucune session Claude en cours".to_string();
        }
        list.iter()
            .map(|s| {
                let state = match s.state {
                    claude::State::Working => "travaille",
                    claude::State::Waiting => "attend l'utilisateur",
                    claude::State::Idle => "au repos",
                };
                let what = if s.prompt.is_empty() {
                    String::new()
                } else {
                    format!(" — « {} »", s.prompt)
                };
                format!("- {} ({state}){what}", s.project)
            })
            .collect::<Vec<_>>()
            .join("\n")
    };

    match tool {
        "sessions" => Ok(sessions_text()),
        "etat_bureau" => {
            let desk_state = tokio::task::spawn_blocking(desk::desktop_state)
                .await
                .unwrap_or_default();
            Ok(format!("{desk_state}\nsessions :\n{}", sessions_text()))
        }
        "couleur_accent" => {
            let color = s("couleur");
            let result = ctx
                .change_theme(|state| state.set_accent(&color))
                .await
                .map(|snapshot| {
                    let event =
                        serde_json::to_string(&Response::changed(snapshot)).unwrap_or_default();
                    let _ = ctx.tx.send(event);
                });
            result.map(|()| format!("accent {color}"))
        }
        _ => {
            let (tool, args) = (tool.to_string(), args.clone());
            tokio::task::spawn_blocking(move || desk::run_tool(&tool, &args))
                .await
                .unwrap_or_else(|e| Err(e.to_string()))
        }
    }
}

/// `{"ok":true}`, or `{"ok":false,"error":"…"}`.
async fn write_result(writer: &mut tokio::net::unix::OwnedWriteHalf, result: Result<(), String>) {
    let reply = match result {
        Ok(()) => serde_json::json!({ "ok": true }),
        Err(e) => serde_json::json!({ "ok": false, "error": e }),
    };
    let _ = write_line(writer, &reply.to_string()).await;
}

// ── Audio service plumbing ────────────────────────────────────────────────────

/// Drive a mic-based DSP service: open the shared capture, run `dsp` on a
/// dedicated blocking thread (cpal streams and blocking recvs don't belong on
/// the async runtime), and forward each JSON line it produces to the socket.
/// Dropping the capture when the socket closes stops the mic stream.
async fn stream_audio_service<F>(writer: &mut tokio::net::unix::OwnedWriteHalf, dsp: F)
where
    F: FnOnce(u32, std::sync::mpsc::Receiver<Vec<f32>>, tokio::sync::mpsc::Sender<String>)
        + Send
        + 'static,
{
    let (capture, audio_rx) = match audio::start_capture() {
        Ok(c) => c,
        Err(e) => {
            let _ = write_response(writer, &Response::err(format!("audio: {e}"))).await;
            return;
        }
    };
    let sample_rate = capture.sample_rate;

    let (line_tx, mut line_rx) = tokio::sync::mpsc::channel::<String>(32);
    // The DSP owns the audio receiver; it exits when either channel closes.
    std::thread::spawn(move || dsp(sample_rate, audio_rx, line_tx));

    while let Some(line) = line_rx.recv().await {
        if write_line(writer, &line).await.is_err() {
            break; // socket closed
        }
    }
    // `capture` drops here → mic stream stops.
}

/// Long-lived metronome session: build the output stream, then service control
/// lines (`{"action":…}`) from the client while forwarding `{"beat":<n>}`
/// events. Dropping the handle when the socket closes stops the audio stream.
async fn run_metronome(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    lines: &mut tokio::io::Lines<BufReader<tokio::net::unix::OwnedReadHalf>>,
) {
    let mut handle = match metronome::start() {
        Ok(h) => h,
        Err(e) => {
            let _ = write_response(writer, &Response::err(format!("metronome: {e}"))).await;
            return;
        }
    };
    if write_line(writer, "{\"ready\":true}").await.is_err() {
        return;
    }

    // Bridge the realtime beat channel (std mpsc) to async.
    let beats_rx = handle.take_beats();
    let (btx, mut brx) = tokio::sync::mpsc::channel::<i32>(64);
    if let Some(beats_rx) = beats_rx {
        std::thread::spawn(move || {
            while let Ok(beat) = beats_rx.recv() {
                if btx.blocking_send(beat).is_err() {
                    break;
                }
            }
        });
    }

    loop {
        tokio::select! {
            line = lines.next_line() => {
                match line {
                    Ok(Some(l)) => apply_metro_control(&handle, &l),
                    _ => break, // socket closed
                }
            }
            beat = brx.recv() => {
                match beat {
                    Some(b) => {
                        if write_line(writer, &format!("{{\"beat\":{b}}}")).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
        }
    }
    // `handle` drops here → output stream stops.
}

/// One metronome control line, already range-checked.
#[derive(Debug, PartialEq)]
enum MetroAction {
    Start(u32),
    Stop,
    Bpm(u32),
    Beats(u32),
}

/// Same tempo range as the UI (widgets/Metronome.qml).
const BPM_RANGE: (u64, u64) = (20, 300);
const BEATS_RANGE: (u64, u64) = (1, 16);

fn clamp_u32(v: u64, (lo, hi): (u64, u64)) -> u32 {
    v.clamp(lo, hi) as u32
}

/// Parse a control line: `{"action":"start","bpm":120}`, `{"action":"stop"}`,
/// `{"action":"bpm","value":130}`, `{"action":"beats","value":4}`. Values are
/// clamped (a huge number must not wrap around when narrowed to u32); anything
/// malformed or unknown yields `None` and is ignored.
fn parse_metro_control(line: &str) -> Option<MetroAction> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let value = || v.get("value").and_then(|b| b.as_u64());
    match v.get("action")?.as_str()? {
        "start" => {
            let bpm = v.get("bpm").and_then(|b| b.as_u64()).unwrap_or(120);
            Some(MetroAction::Start(clamp_u32(bpm, BPM_RANGE)))
        }
        "stop" => Some(MetroAction::Stop),
        "bpm" => Some(MetroAction::Bpm(clamp_u32(value()?, BPM_RANGE))),
        "beats" => Some(MetroAction::Beats(clamp_u32(value()?, BEATS_RANGE))),
        _ => None,
    }
}

fn apply_metro_control(handle: &metronome::MetroHandle, line: &str) {
    match parse_metro_control(line) {
        Some(MetroAction::Start(bpm)) => handle.start(bpm),
        Some(MetroAction::Stop) => handle.stop_playing(),
        Some(MetroAction::Bpm(bpm)) => handle.set_bpm(bpm),
        Some(MetroAction::Beats(n)) => handle.set_beats(n),
        None => {}
    }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Send the theme response and broadcast to Watch subscribers on success.
async fn respond_theme(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    tx: &broadcast::Sender<String>,
    result: Result<protocol::PaletteState, String>,
) {
    match result {
        Ok(snapshot) => {
            let event_json =
                serde_json::to_string(&Response::changed(snapshot.clone())).unwrap_or_default();
            let _ = tx.send(event_json);
            let resp = Response::ok(snapshot);
            let _ = write_response(writer, &resp).await;
        }
        Err(e) => {
            let resp = Response::err(e);
            let _ = write_response(writer, &resp).await;
        }
    }
}

/// Save state to disk, render all templates, and fire live-reload signals.
/// Returns the serializable state snapshot on success.
fn apply_change(state: &AppState, opts: &AppCtlOptions) -> Result<protocol::PaletteState, String> {
    state.save().map_err(|e| format!("save failed: {e}"))?;
    templates::render_all(state).map_err(|e| format!("render failed: {e}"))?;
    reload_all(state, opts);
    Ok(state.to_palette_state())
}

fn run_init(state: &AppState, opts: &AppCtlOptions) {
    if let Err(e) = state.save() {
        eprintln!("anna: init save failed: {e}");
    }
    if let Err(e) = templates::render_all(state) {
        eprintln!("anna: init render failed: {e}");
    }
    reload_all(state, opts);
}

async fn write_response(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    resp: &Response,
) -> std::io::Result<()> {
    let json = serde_json::to_string(resp).map_err(std::io::Error::other)?;
    write_line(writer, &json).await
}

/// Write one newline-terminated line to the socket.
async fn write_line(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    line: &str,
) -> std::io::Result<()> {
    writer.write_all(line.as_bytes()).await?;
    writer.write_all(b"\n").await
}

async fn write_gesture_status(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    status: &gesture::Status,
) {
    let json = serde_json::to_string(status).unwrap_or_default();
    let _ = write_line(writer, &json).await;
}

/// Take one hardware sample on a blocking thread (it reads sysfs and may spawn
/// `lspci`), handing the collector back for the next delta-based sample.
async fn sample_hwstats(
    mut collector: hwstats::Collector,
) -> Option<(hwstats::Collector, hwstats::HwStats)> {
    tokio::task::spawn_blocking(move || {
        let snap = collector.sample();
        (collector, snap)
    })
    .await
    .ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn metro_parses_every_action() {
        assert_eq!(
            parse_metro_control(r#"{"action":"start","bpm":90}"#),
            Some(MetroAction::Start(90))
        );
        assert_eq!(
            parse_metro_control(r#"{"action":"stop"}"#),
            Some(MetroAction::Stop)
        );
        assert_eq!(
            parse_metro_control(r#"{"action":"bpm","value":130}"#),
            Some(MetroAction::Bpm(130))
        );
        assert_eq!(
            parse_metro_control(r#"{"action":"beats","value":3}"#),
            Some(MetroAction::Beats(3))
        );
    }

    #[test]
    fn metro_start_defaults_to_120() {
        assert_eq!(
            parse_metro_control(r#"{"action":"start"}"#),
            Some(MetroAction::Start(120))
        );
    }

    #[test]
    fn metro_clamps_instead_of_wrapping() {
        // 2^32 + 5 used to wrap to 5 when narrowed with `as u32`.
        assert_eq!(
            parse_metro_control(r#"{"action":"bpm","value":4294967301}"#),
            Some(MetroAction::Bpm(300))
        );
        assert_eq!(
            parse_metro_control(r#"{"action":"bpm","value":0}"#),
            Some(MetroAction::Bpm(20))
        );
        assert_eq!(
            parse_metro_control(r#"{"action":"beats","value":0}"#),
            Some(MetroAction::Beats(1))
        );
    }

    #[test]
    fn metro_ignores_garbage() {
        assert_eq!(parse_metro_control("not json"), None);
        assert_eq!(parse_metro_control(r#"{"action":"dance"}"#), None);
        assert_eq!(parse_metro_control(r#"{"action":"bpm"}"#), None);
        assert_eq!(parse_metro_control(r#"{"action":"bpm","value":-4}"#), None);
        assert_eq!(parse_metro_control(r#"{"bpm":120}"#), None);
    }
}
