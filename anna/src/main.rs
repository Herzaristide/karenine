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
//!   anna get             client: print current theme state as JSON
//!   anna watch           client: stream theme changes as JSON lines
//!   anna msi-rgb-watch   reflect the accent color onto the MSI RGB keyboard
//!
//! Services exposed over `$XDG_RUNTIME_DIR/anna.sock`:
//!   - theme    : accent/palette (set/mode/palette-color/get/watch)
//!   - hwstats  : hardware stats (hwstats_get / hwstats_watch)

mod appctl;
mod client;
mod color;
mod hwstats;
mod msi;
mod protocol;
mod state;
mod templates;

use appctl::{reload_all, AppCtlOptions};
use protocol::{Command, Response};
use state::AppState;
use std::path::PathBuf;
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
        Some("set") | Some("mode") | Some("palette-color") | Some("get") | Some("watch") => {
            client::run(&args);
        }
        // Reflect the accent color onto the MSI RGB keyboard (long-lived).
        Some("msi-rgb-watch") => {
            msi::run().await;
        }
        // One-shot render used by the home-manager activation.
        Some("init") => {
            let no_hyprctl = args.iter().any(|a| a == "--no-hyprctl");
            let app_state = AppState::load(accent_dir());
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
                "Usage: anna [daemon|init|set|mode|palette-color|get|watch|msi-rgb-watch]"
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

    let app_state = AppState::load(accent_dir());
    let opts = AppCtlOptions { no_hyprctl };

    let socket = socket_override.unwrap_or_else(socket_path);
    // Remove stale socket from a previous run.
    let _ = std::fs::remove_file(&socket);

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

    // Shared theme state behind a mutex — modified when set_* commands arrive.
    let shared = Arc::new(Mutex::new(app_state));

    // Broadcast channel for theme Watch subscribers.
    let (tx, _) = broadcast::channel::<String>(32);
    let tx = Arc::new(tx);

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let shared = Arc::clone(&shared);
                let tx = Arc::clone(&tx);
                tokio::spawn(async move {
                    handle_connection(stream, shared, tx, no_hyprctl).await;
                });
            }
            Err(e) => eprintln!("anna: accept error: {e}"),
        }
    }
}

// ── Connection handler ──────────────────────────────────────────────────────

async fn handle_connection(
    stream: UnixStream,
    shared: Arc<Mutex<AppState>>,
    tx: Arc<broadcast::Sender<String>>,
    no_hyprctl: bool,
) {
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
            let state_snapshot = shared.lock().unwrap().to_palette_state();
            let resp = Response::ok(state_snapshot);
            let _ = write_response(&mut writer, &resp).await;
        }

        Command::SetAccent { color } => {
            let result = {
                let mut state = shared.lock().unwrap();
                match crate::color::Color::from_hex(&color) {
                    Some(c) => {
                        state.accent = c;
                        apply_change(&state, no_hyprctl)
                    }
                    None => Err(format!("invalid hex color: {color}")),
                }
            };
            respond_theme(&mut writer, &tx, result).await;
        }

        Command::SetMode { mode } => {
            let result = {
                let mut state = shared.lock().unwrap();
                if mode != "dark" && mode != "light" {
                    Err(format!("invalid mode: {mode} (expected dark or light)"))
                } else {
                    state.mode = mode;
                    apply_change(&state, no_hyprctl)
                }
            };
            respond_theme(&mut writer, &tx, result).await;
        }

        Command::SetPaletteColor { key, color, mode } => {
            const VALID_KEYS: &[&str] = &[
                "base00", "base01", "base02", "base03", "base04", "base05", "base06", "base07",
                "base08", "base09", "base0a", "base0b", "base0c", "base0d", "base0e", "base0f",
            ];
            let result = {
                let mut state = shared.lock().unwrap();
                if !VALID_KEYS.contains(&key.as_str()) {
                    Err(format!("invalid palette key: {key}"))
                } else {
                    match crate::color::Color::from_hex(&color) {
                        Some(c) => {
                            let target = mode.as_deref().unwrap_or(&state.mode).to_string();
                            if target == "light" {
                                state.palette_light.insert(key, c.to_hex());
                            } else {
                                state.palette_dark.insert(key, c.to_hex());
                            }
                            apply_change(&state, no_hyprctl)
                        }
                        None => Err(format!("invalid hex color: {color}")),
                    }
                }
            };
            respond_theme(&mut writer, &tx, result).await;
        }

        Command::Watch => {
            // Send current state immediately, then forward broadcasts.
            let state_snapshot = shared.lock().unwrap().to_palette_state();
            let initial = serde_json::to_string(&Response::ok(state_snapshot)).unwrap_or_default();
            if write_line(&mut writer, &initial).await.is_err() {
                return;
            }

            let mut rx = tx.subscribe();
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
            let collector = Arc::new(Mutex::new(hwstats::Collector::new()));
            // Prime once, wait a beat, then sample so the CPU delta is meaningful.
            {
                let c = Arc::clone(&collector);
                let _ = tokio::task::spawn_blocking(move || c.lock().unwrap().sample()).await;
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
            let c = Arc::clone(&collector);
            let snap = tokio::task::spawn_blocking(move || c.lock().unwrap().sample())
                .await
                .ok();
            if let Some(snap) = snap {
                let json = serde_json::to_string(&snap).unwrap_or_default();
                let _ = write_line(&mut writer, &json).await;
            }
        }

        Command::HwstatsWatch => {
            let collector = Arc::new(Mutex::new(hwstats::Collector::new()));
            let mut interval = tokio::time::interval(Duration::from_secs(1));
            loop {
                interval.tick().await;
                let c = Arc::clone(&collector);
                let snap = match tokio::task::spawn_blocking(move || c.lock().unwrap().sample()).await
                {
                    Ok(s) => s,
                    Err(_) => break,
                };
                let json = serde_json::to_string(&snap).unwrap_or_default();
                if write_line(&mut writer, &json).await.is_err() {
                    break; // socket closed
                }
            }
        }
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
fn apply_change(state: &AppState, no_hyprctl: bool) -> Result<protocol::PaletteState, String> {
    state.save().map_err(|e| format!("save failed: {e}"))?;
    templates::render_all(state).map_err(|e| format!("render failed: {e}"))?;
    reload_all(state, &AppCtlOptions { no_hyprctl });
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
    let json = serde_json::to_string(resp)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
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

fn accent_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
    PathBuf::from(home).join(".config/accent")
}

/// Path to the anna control socket. Shared by the daemon, the CLI client, and
/// the MSI RGB watcher so they always agree.
pub(crate) fn socket_path() -> String {
    let runtime_dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".into());
    format!("{runtime_dir}/anna.sock")
}
