//! Watch the anna daemon and reflect the accent color onto the MSI keyboard.
//!
//! Connects to `$XDG_RUNTIME_DIR/anna.sock`, sends `{"cmd":"watch"}`,
//! and on every state change runs `$MSI_RGB_SET <accent_hex>`.
//!
//! Two layers of rate-limiting protect the SteelSeries KLC controller from
//! getting wedged by bursts of writes:
//!   - DEBOUNCE (200 ms) absorbs color-picker drag bursts: only the last
//!     value of a burst gets sent.
//!   - COOLDOWN (2 s) is the minimum gap between two successful applies,
//!     so even sustained ~Hz changes can't sustain a write loop.
//!
//! Reads the `accent` field (`#rrggbb`), not `accent_rgb` (CSS `r,g,b`).
//!
//! Mirrors the last applied hex to `$MSI_RGB_CACHE` (default
//! `/var/lib/msi-rgb/last-color`) so the system boot service and resume hook
//! can re-apply it without going through the daemon.
use serde::Deserialize;
use std::process::Command;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::time::{Instant, sleep_until};

const DEBOUNCE: Duration = Duration::from_millis(200);
const COOLDOWN: Duration = Duration::from_secs(2);
const RECONNECT_DELAY: Duration = Duration::from_secs(2);

#[derive(Debug, Deserialize)]
struct Envelope {
    state: Option<State>,
}

#[derive(Debug, Deserialize)]
struct State {
    accent: String,
}

pub async fn run() {
    let socket = crate::socket_path();
    let cache = cache_path();
    let setter = std::env::var("MSI_RGB_SET").unwrap_or_else(|_| "msi-rgb-set".into());

    loop {
        let stream = match UnixStream::connect(&socket).await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("msi-rgb-watcher: connect {socket} failed: {e}");
                tokio::time::sleep(RECONNECT_DELAY).await;
                continue;
            }
        };

        let (reader, mut writer) = stream.into_split();
        if writer.write_all(b"{\"cmd\":\"watch\"}\n").await.is_err() {
            tokio::time::sleep(RECONNECT_DELAY).await;
            continue;
        }

        let mut lines = BufReader::new(reader).lines();
        let mut pending: Option<String> = None;
        let mut deadline: Option<Instant> = None;
        let mut last_applied: Option<Instant> = None;

        loop {
            tokio::select! {
                read = lines.next_line() => {
                    match read {
                        Ok(Some(line)) => {
                            if let Some(rgb) = parse_accent(&line) {
                                pending = Some(rgb);
                                deadline = Some(next_deadline(last_applied));
                            }
                        }
                        _ => break, // socket closed → reconnect
                    }
                }
                _ = wait(deadline) => {
                    if let Some(rgb) = pending.take() {
                        apply(&setter, &cache, &rgb);
                        last_applied = Some(Instant::now());
                    }
                    deadline = None;
                }
            }
        }

        eprintln!("msi-rgb-watcher: socket closed, reconnecting");
        tokio::time::sleep(RECONNECT_DELAY).await;
    }
}

async fn wait(deadline: Option<Instant>) {
    match deadline {
        Some(d) => sleep_until(d).await,
        None => std::future::pending::<()>().await,
    }
}

/// Earliest moment at which the next apply may fire.
/// At least DEBOUNCE from now (to coalesce bursts) AND at least COOLDOWN
/// after the previous apply (to rate-limit sustained changes).
fn next_deadline(last_applied: Option<Instant>) -> Instant {
    let now = Instant::now();
    let after_debounce = now + DEBOUNCE;
    match last_applied {
        Some(t) => after_debounce.max(t + COOLDOWN),
        None => after_debounce,
    }
}

fn parse_accent(line: &str) -> Option<String> {
    let env: Envelope = serde_json::from_str(line).ok()?;
    env.state.map(|s| s.accent)
}

fn apply(setter: &str, cache: &str, rgb: &str) {
    let rgb = rgb.trim().trim_start_matches('#').to_lowercase();
    if rgb.len() != 6 || !rgb.chars().all(|c| c.is_ascii_hexdigit()) {
        eprintln!("msi-rgb-watcher: invalid accent '{rgb}', skipping");
        return;
    }

    if let Err(e) = std::fs::write(cache, &rgb) {
        eprintln!("msi-rgb-watcher: cache write {cache} failed: {e}");
    }

    match Command::new(setter).arg(&rgb).status() {
        Ok(s) if s.success() => {}
        Ok(s) => eprintln!("msi-rgb-watcher: {setter} {rgb} exited {s}"),
        Err(e) => eprintln!("msi-rgb-watcher: spawn {setter} failed: {e}"),
    }
}

fn cache_path() -> String {
    std::env::var("MSI_RGB_CACHE").unwrap_or_else(|_| "/var/lib/msi-rgb/last-color".into())
}
