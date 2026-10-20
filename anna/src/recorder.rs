//! Recording the microphone (the « Music » tab) and the screen (the top bar).
//!
//! anna does no capture nor encoding itself: it runs the tools made for it and
//! keeps hold of them, so that a recording outlives the bar that started it,
//! the tab that was closed and the shell's reloads.
//! - sound: `ffmpeg` over PipeWire's Pulse server — the default microphone
//!   (raw, not the echo-cancelled one of the voice), alone or mixed with what
//!   the computer plays (`@DEFAULT_MONITOR@`), in FLAC;
//! - screen: `gpu-screen-recorder`, encoded by the graphics card, with the
//!   computer's sound; a region picked with `slurp`, or the focused monitor.
//!   It comes from the NixOS configuration (`programs.gpu-screen-recorder`):
//!   capturing the screen needs its `gsr-kms-server`, given a capability.
//!
//! Stopping sends SIGINT, which both tools take as « finish the file ». The
//! status (`record_watch`) is `{"record":{"audio":Track|null,"screen":
//! Track|null,"error":"…","last":"<path>"}}`, a `Track` being
//! `{"mode","since":<unix ms>,"path"}`.

use crate::paths;
use serde::Serialize;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::process::Command;
use tokio::sync::watch;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    Audio,
    Screen,
}

impl Kind {
    pub fn parse(s: &str) -> Option<Kind> {
        match s {
            "audio" => Some(Kind::Audio),
            "screen" => Some(Kind::Screen),
            _ => None,
        }
    }

    /// The modes of a kind, the first being the default.
    fn modes(self) -> &'static [&'static str] {
        match self {
            // The microphone alone, or with what the computer plays.
            Kind::Audio => &["mic", "mix"],
            // A region picked with the mouse, or the whole focused monitor.
            Kind::Screen => &["area", "screen"],
        }
    }

    /// `mode`, or the default one when empty; `None` when unknown.
    pub fn mode(self, mode: &str) -> Option<&'static str> {
        if mode.is_empty() {
            return self.modes().first().copied();
        }
        self.modes().iter().find(|m| **m == mode).copied()
    }
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Track {
    pub mode: String,
    /// When it started, in Unix milliseconds: the shell shows the time elapsed.
    pub since: u64,
    pub path: String,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct Status {
    pub audio: Option<Track>,
    pub screen: Option<Track>,
    /// Why the last recording failed; cleared by the next one.
    pub error: String,
    /// The last file saved.
    pub last: String,
}

/// One kind's slot.
#[derive(Default)]
enum Slot {
    #[default]
    Idle,
    /// Picking the region, or launching: a second start waits for it.
    Starting,
    Running {
        pid: u32,
        track: Track,
        /// SIGINT was sent: the exit that follows is the expected one.
        stopping: bool,
    },
}

#[derive(Default)]
struct Slots {
    audio: Slot,
    screen: Slot,
}

impl Slots {
    fn get(&mut self, kind: Kind) -> &mut Slot {
        match kind {
            Kind::Audio => &mut self.audio,
            Kind::Screen => &mut self.screen,
        }
    }
}

pub struct Recorder {
    slots: Mutex<Slots>,
    status: watch::Sender<Status>,
}

impl Recorder {
    pub fn new() -> Arc<Recorder> {
        Arc::new(Recorder {
            slots: Mutex::new(Slots::default()),
            status: watch::channel(Status::default()).0,
        })
    }

    pub fn subscribe(&self) -> watch::Receiver<Status> {
        self.status.subscribe()
    }

    fn slots(&self) -> std::sync::MutexGuard<'_, Slots> {
        self.slots.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Republish the tracks from the slots, `edit` changing the rest.
    fn publish(&self, edit: impl FnOnce(&mut Status)) {
        let (audio, screen) = {
            let mut s = self.slots();
            let track = |slot: &Slot| match slot {
                Slot::Running { track, .. } => Some(track.clone()),
                _ => None,
            };
            (track(s.get(Kind::Audio)), track(s.get(Kind::Screen)))
        };
        self.status.send_modify(|st| {
            st.audio = audio;
            st.screen = screen;
            edit(st);
        });
    }

    /// Start a recording of `kind`, or stop the one running: what a button
    /// and a shortcut both do.
    pub async fn toggle(self: &Arc<Self>, kind: Kind, mode: &str) -> Result<(), String> {
        if self.is_running(kind) {
            self.stop(kind);
            Ok(())
        } else {
            self.start(kind, mode).await
        }
    }

    fn is_running(&self, kind: Kind) -> bool {
        matches!(self.slots().get(kind), Slot::Running { .. })
    }

    /// Start a recording of `kind`. Nothing happens while one runs or is being
    /// started, nor when the region picking is cancelled.
    pub async fn start(self: &Arc<Self>, kind: Kind, mode: &str) -> Result<(), String> {
        let mode = kind
            .mode(mode)
            .ok_or_else(|| crate::i18n::tr_args("record.bad_mode", &[("mode", mode)]))?;
        {
            let mut s = self.slots();
            let slot = s.get(kind);
            if !matches!(slot, Slot::Idle) {
                return Ok(());
            }
            *slot = Slot::Starting;
        }
        let result = self.launch(kind, mode).await;
        if let Err(e) = &result {
            *self.slots().get(kind) = Slot::Idle;
            self.publish(|st| st.error = e.clone());
            notify(&crate::i18n::tr("record.failed"), e);
        }
        result
    }

    async fn launch(self: &Arc<Self>, kind: Kind, mode: &'static str) -> Result<(), String> {
        let (dir, prefix, ext) = match kind {
            Kind::Audio => (paths::user_dir("MUSIC", "Music"), "enregistrement-", "flac"),
            Kind::Screen => (paths::user_dir("VIDEOS", "Videos"), "ecran-", "mp4"),
        };
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join(format!("{prefix}{}.{ext}", stamp().await));

        let argv = match kind {
            Kind::Audio => audio_args(mode, &path),
            Kind::Screen => {
                let target = match mode {
                    "area" => match pick_region().await {
                        Some(g) => vec!["-w".into(), "region".into(), "-region".into(), g],
                        // Cancelled (Échap): no recording, no error.
                        None => {
                            *self.slots().get(kind) = Slot::Idle;
                            return Ok(());
                        }
                    },
                    _ => vec!["-w".into(), focused_monitor().await],
                };
                screen_args(target, &path)
            }
        };

        let mut child = Command::new(&argv[0])
            .args(&argv[1..])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(false)
            .spawn()
            .map_err(|e| format!("{}: {e}", argv[0]))?;
        let pid = child
            .id()
            .ok_or_else(|| format!("{}: exited at once", argv[0]))?;

        let track = Track {
            mode: mode.into(),
            since: now_ms(),
            path: path.to_string_lossy().into_owned(),
        };
        *self.slots().get(kind) = Slot::Running {
            pid,
            track,
            stopping: false,
        };
        self.publish(|st| st.error.clear());

        // The tool's end, whether asked for or not.
        let me = Arc::clone(self);
        let stderr = child.stderr.take();
        tokio::spawn(async move {
            let err = async {
                let mut text = String::new();
                if let Some(mut e) = stderr {
                    use tokio::io::AsyncReadExt;
                    let _ = e.read_to_string(&mut text).await;
                }
                text
            };
            let (err, _) = tokio::join!(err, child.wait());
            me.finished(kind, &path, &err);
        });
        Ok(())
    }

    /// The tool has exited: the file is kept if it holds something.
    fn finished(&self, kind: Kind, path: &Path, stderr: &str) {
        let stopping = matches!(
            std::mem::take(self.slots().get(kind)),
            Slot::Running { stopping: true, .. }
        );
        let saved = std::fs::metadata(path)
            .map(|m| m.len() > 0)
            .unwrap_or(false);
        let shown = path.to_string_lossy().into_owned();
        if stopping && saved {
            self.publish(|st| st.last = shown.clone());
            notify(&crate::i18n::tr("record.saved"), &shown);
        } else {
            // Stopped by itself: the device went away, the capture was refused…
            let why = stderr
                .lines()
                .rev()
                .find(|l| !l.trim().is_empty())
                .unwrap_or("")
                .trim()
                .to_string();
            let why = if why.is_empty() {
                crate::i18n::tr("record.stopped")
            } else {
                why
            };
            eprintln!("anna: record: {why}");
            self.publish(|st| {
                st.error = why.clone();
                if saved {
                    st.last = shown.clone();
                }
            });
            notify(&crate::i18n::tr("record.failed"), &why);
        }
    }

    /// Ask the recording of `kind` to finish its file.
    pub fn stop(&self, kind: Kind) {
        let pid = match self.slots().get(kind) {
            Slot::Running { pid, stopping, .. } => {
                *stopping = true;
                *pid
            }
            _ => return,
        };
        // SIGINT: both tools write the end of the file, then exit.
        let _ = std::process::Command::new("kill")
            .args(["-INT", &pid.to_string()])
            .status();
    }

    pub fn stop_all(&self) {
        self.stop(Kind::Audio);
        self.stop(Kind::Screen);
    }

    /// The pilot's `enregistrer` tool (claude/desk.rs): start or stop, with
    /// the tool's French words; the answer tells the pilot what happened.
    pub async fn pilot(
        self: &Arc<Self>,
        action: &str,
        what: &str,
        mode: &str,
    ) -> Result<String, String> {
        let kind = match what {
            "son" => Some(Kind::Audio),
            "ecran" => Some(Kind::Screen),
            "" => None,
            other => return Err(format!("« {other} » : son ou ecran")),
        };
        if action == "arreter" {
            match kind {
                Some(k) if !self.is_running(k) => return Ok("rien ne s'enregistrait".into()),
                Some(k) => self.stop(k),
                None => self.stop_all(),
            }
            return Ok("enregistrement arrêté ; une notification donnera le fichier".into());
        }
        let kind = kind.ok_or("quoi enregistrer : son ou ecran")?;
        if self.is_running(kind) {
            return Ok("un enregistrement de ce type tourne déjà".into());
        }
        self.start(kind, pilot_mode(mode)).await?;
        let status = self.subscribe().borrow().clone();
        match if kind == Kind::Audio {
            status.audio
        } else {
            status.screen
        } {
            Some(t) => Ok(format!("enregistrement lancé, vers {}", t.path)),
            None if !status.error.is_empty() => Err(status.error),
            None => Ok("sélection annulée, rien n'est enregistré".into()),
        }
    }
}

/// The tool's modes, in the recorder's words.
fn pilot_mode(mode: &str) -> &str {
    match mode {
        "micro" => "mic",
        "micro_ordi" => "mix",
        "selection" => "area",
        "ecran" => "screen",
        _ => "",
    }
}

/// ffmpeg's command line: the default microphone, alone or mixed with the
/// default output's monitor, to a FLAC file. `normalize=0`: each source keeps
/// its level instead of being halved.
fn audio_args(mode: &str, path: &Path) -> Vec<String> {
    let mut a: Vec<String> = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
        .map(String::from)
        .into();
    a.extend(["-f", "pulse", "-i", "default"].map(String::from));
    if mode == "mix" {
        a.extend(["-f", "pulse", "-i", "@DEFAULT_MONITOR@"].map(String::from));
        a.extend(
            [
                "-filter_complex",
                "amix=inputs=2:duration=longest:normalize=0",
            ]
            .map(String::from),
        );
    }
    a.extend(["-c:a", "flac"].map(String::from));
    a.push(path.to_string_lossy().into_owned());
    a
}

/// gpu-screen-recorder's command line: `target` (`-w …`) at 60 images per
/// second, with the computer's sound.
fn screen_args(target: Vec<String>, path: &Path) -> Vec<String> {
    let mut a = vec!["gpu-screen-recorder".to_string()];
    a.extend(target);
    a.extend(["-f", "60", "-a", "default_output", "-c", "mp4", "-o"].map(String::from));
    a.push(path.to_string_lossy().into_owned());
    a
}

/// A region picked with the mouse, `WxH+X+Y`; `None` when cancelled.
async fn pick_region() -> Option<String> {
    let out = Command::new("slurp")
        .args(["-f", "%wx%h+%x+%y"])
        .output()
        .await
        .ok()?;
    let g = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !g.is_empty()).then_some(g)
}

/// The monitor holding the focus (`DP-1`…), else gpu-screen-recorder's first.
async fn focused_monitor() -> String {
    let out = Command::new("hyprctl")
        .args(["-j", "monitors"])
        .output()
        .await;
    out.ok()
        .and_then(|o| serde_json::from_slice::<serde_json::Value>(&o.stdout).ok())
        .and_then(|v| {
            v.as_array()?
                .iter()
                .find(|m| m["focused"].as_bool() == Some(true))?["name"]
                .as_str()
                .map(str::to_string)
        })
        .unwrap_or_else(|| "screen".into())
}

/// The local date and time, `20261020_143005`, as in the screenshots' names.
async fn stamp() -> String {
    let out = Command::new("date").arg("+%Y%m%d_%H%M%S").output().await;
    out.ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| (now_ms() / 1000).to_string())
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// A desktop notification, received by the shell's notification server.
fn notify(title: &str, body: &str) {
    let _ = std::process::Command::new("notify-send")
        .args(["-a", "karenine", title, body])
        .stdin(std::process::Stdio::null())
        .spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modes_default_and_reject_unknown_ones() {
        assert_eq!(Kind::Audio.mode(""), Some("mic"));
        assert_eq!(Kind::Audio.mode("mix"), Some("mix"));
        assert_eq!(Kind::Screen.mode(""), Some("area"));
        assert_eq!(Kind::Screen.mode("screen"), Some("screen"));
        assert_eq!(Kind::Screen.mode("mix"), None);
    }

    #[test]
    fn the_pilots_modes_are_the_recorders() {
        for (pilot, kind) in [
            ("micro", Kind::Audio),
            ("micro_ordi", Kind::Audio),
            ("selection", Kind::Screen),
            ("ecran", Kind::Screen),
        ] {
            assert!(kind.mode(pilot_mode(pilot)).is_some(), "{pilot}");
        }
        // Absent: the kind's default.
        assert_eq!(Kind::Audio.mode(pilot_mode("")), Some("mic"));
    }

    #[test]
    fn the_mix_reads_both_sources() {
        let p = Path::new("/tmp/x.flac");
        let mic = audio_args("mic", p);
        assert_eq!(mic.iter().filter(|a| *a == "-i").count(), 1);
        let mix = audio_args("mix", p);
        assert!(mix.contains(&"@DEFAULT_MONITOR@".to_string()));
        assert_eq!(mix.last().unwrap(), "/tmp/x.flac");
    }

    #[test]
    fn the_screen_keeps_the_computers_sound() {
        let a = screen_args(vec!["-w".into(), "DP-1".into()], Path::new("/tmp/x.mp4"));
        assert_eq!(&a[..3], ["gpu-screen-recorder", "-w", "DP-1"]);
        assert!(a.windows(2).any(|w| w == ["-a", "default_output"]));
    }
}
