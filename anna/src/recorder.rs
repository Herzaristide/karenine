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
//! Track|null,"error":"…","last":"<path>","takes":[Take…],"live":[…],
//! "playing":Playing|null}}`, a `Track` being `{"mode","since":<unix ms>,
//! "path"}`.
//!
//! The sound recordings are « takes », played back from the Music tab: the
//! last few are listed (`takes`, newest first), and each has a waveform, its
//! peaks (`record_peaks`). While the microphone records, ffmpeg also hands
//! anna the sound, mono and at a low rate, on its standard output: the peaks
//! of the last seconds go out live (`live`), and those of the whole take are
//! cached when it ends — no decoding again. An older take is decoded once.
//!
//! anna plays the takes too (`record_play`, `record_pause`): ffmpeg again, from
//! a given second, to the default output at the pace of the sound. The shell
//! needs no media module, and pausing is stopping, then playing from there.

use crate::paths;
use serde::Serialize;
use std::path::{Path, PathBuf};
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
    /// The latest sound takes, newest first.
    pub takes: Vec<Take>,
    /// While the microphone records: the peaks of the last seconds (0–1,
    /// `PEAK_RATE` per second), oldest first.
    pub live: Vec<f32>,
    /// The take being played, if any.
    pub playing: Option<Playing>,
}

/// A take being played: the shell follows the position from `from` and
/// `since`.
#[derive(Clone, Debug, Default, Serialize)]
pub struct Playing {
    pub path: String,
    /// Where it started, in seconds into the take.
    pub from: f64,
    /// When, in Unix milliseconds.
    pub since: u64,
}

/// The ffmpeg playing a take: its pid, and a number telling one playback from
/// the next (the end of a stopped one must not clear its successor).
#[derive(Default)]
struct Player {
    pid: Option<u32>,
    turn: u64,
}

/// A sound take, in the Music folder.
#[derive(Clone, Debug, Default, Serialize)]
pub struct Take {
    pub path: String,
    /// When it was recorded, from its name: `20261020_165927`.
    pub at: String,
    /// In seconds, from the FLAC header; 0 when unreadable.
    pub duration: f64,
}

/// The takes' names: `enregistrement-<stamp>.flac`.
const TAKE_PREFIX: &str = "enregistrement-";
const TAKE_EXT: &str = ".flac";
/// How many takes are listed.
const TAKES_SHOWN: usize = 8;
/// The sound anna reads to draw the waveform: mono, 8 kHz, 16 bits.
const WAVE_RATE: usize = 8000;
/// Peaks per second: one per 50 ms.
const PEAK_RATE: usize = 20;
/// The live waveform: the last ten seconds.
const LIVE_PEAKS: usize = 10 * PEAK_RATE;
/// A take's waveform, whatever its length.
const TAKE_PEAKS: usize = 200;
/// The bytes of sound behind one peak.
const PEAK_BYTES: usize = 2 * WAVE_RATE / PEAK_RATE;

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
    player: Mutex<Player>,
    status: watch::Sender<Status>,
}

impl Recorder {
    pub fn new() -> Arc<Recorder> {
        let me = Arc::new(Recorder {
            slots: Mutex::new(Slots::default()),
            player: Mutex::new(Player::default()),
            status: watch::channel(Status::default()).0,
        });
        me.refresh_takes();
        me
    }

    /// Read the takes again from the Music folder: a new one, one deleted,
    /// or files moved by hand meanwhile.
    pub fn refresh_takes(&self) {
        let takes = list_takes(&takes_dir());
        self.publish(|st| st.takes = takes);
    }

    pub fn subscribe(&self) -> watch::Receiver<Status> {
        self.status.subscribe()
    }

    fn slots(&self) -> std::sync::MutexGuard<'_, Slots> {
        self.slots
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
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
        // The microphone alone: the take being played back would go into
        // it. With the computer's sound, playing over it is the point.
        if kind == Kind::Audio && mode == "mic" {
            self.pause();
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
        let _ = tokio::fs::create_dir_all(&dir).await;
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
            // The sound's peaks, for the waveform (`audio_args`).
            .stdout(if kind == Kind::Audio {
                std::process::Stdio::piped()
            } else {
                std::process::Stdio::null()
            })
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
        let stdout = child.stdout.take();
        tokio::spawn(async move {
            let err = async {
                let mut text = String::new();
                if let Some(mut e) = stderr {
                    use tokio::io::AsyncReadExt;
                    let _ = e.read_to_string(&mut text).await;
                }
                text
            };
            let peaks = me.follow_peaks(stdout);
            let (err, peaks, _) = tokio::join!(err, peaks, child.wait());
            if !peaks.is_empty() {
                save_peaks(&path, &bins(&peaks, TAKE_PEAKS));
            }
            me.finished(kind, &path, &err);
        });
        Ok(())
    }

    /// Read ffmpeg's sound (mono, `WAVE_RATE`, s16le) until it ends: its
    /// peaks, published live as they come, then all of them.
    async fn follow_peaks(&self, out: Option<tokio::process::ChildStdout>) -> Vec<f32> {
        use tokio::io::AsyncReadExt;
        let Some(mut out) = out else {
            return Vec::new();
        };
        let mut peaks = Vec::new();
        let mut buf = vec![0u8; PEAK_BYTES];
        while out.read_exact(&mut buf).await.is_ok() {
            peaks.push(peak(&buf));
            // Ten times a second is enough for the eye.
            if peaks.len() % 2 == 0 {
                let live = peaks[peaks.len().saturating_sub(LIVE_PEAKS)..].to_vec();
                self.publish(|st| st.live = live);
            }
        }
        self.publish(|st| st.live.clear());
        peaks
    }

    /// A take's waveform: `TAKE_PEAKS` peaks (fewer for a short take), from
    /// the cache, or decoded once and cached.
    pub async fn peaks(&self, path: &str) -> Result<Vec<f32>, String> {
        let path = take_path(path).ok_or_else(|| crate::i18n::tr("record.not_a_take"))?;
        if let Some(p) = std::fs::read_to_string(peaks_path(&path))
            .ok()
            .and_then(|t| serde_json::from_str::<Vec<f32>>(&t).ok())
        {
            return Ok(p);
        }
        let out = Command::new("ffmpeg")
            .args(["-hide_banner", "-loglevel", "error", "-nostdin", "-i"])
            .arg(&path)
            .args([
                "-ac",
                "1",
                "-ar",
                &WAVE_RATE.to_string(),
                "-f",
                "s16le",
                "pipe:1",
            ])
            .stdin(std::process::Stdio::null())
            .output()
            .await
            .map_err(|e| format!("ffmpeg: {e}"))?;
        if !out.status.success() {
            return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
        }
        let all: Vec<f32> = out.stdout.chunks(PEAK_BYTES).map(peak).collect();
        let p = bins(&all, TAKE_PEAKS);
        save_peaks(&path, &p);
        Ok(p)
    }

    fn player(&self) -> std::sync::MutexGuard<'_, Player> {
        self.player
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Play a take from `from` seconds, in place of what was playing.
    pub fn play(self: &Arc<Self>, path: &str, from: f64) -> Result<(), String> {
        let path = take_path(path).ok_or_else(|| crate::i18n::tr("record.not_a_take"))?;
        let from = from.max(0.0);
        self.pause();
        let mut child = Command::new("ffmpeg")
            .args(play_args(&path, from))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(false)
            .spawn()
            .map_err(|e| format!("ffmpeg: {e}"))?;
        // Published under the player's lock, here and at the end: the end of
        // a stopped playback can't overwrite the one that follows it.
        let turn = {
            let mut p = self.player();
            p.turn += 1;
            p.pid = child.id();
            self.publish(|st| {
                st.playing = Some(Playing {
                    path: path.to_string_lossy().into_owned(),
                    from,
                    since: now_ms(),
                })
            });
            p.turn
        };
        // The end of the take, or a pause: nothing plays any more, unless
        // another playback has begun meanwhile.
        let me = Arc::clone(self);
        tokio::spawn(async move {
            let _ = child.wait().await;
            let mut p = me.player();
            if p.turn == turn {
                p.pid = None;
                me.publish(|st| st.playing = None);
            }
        });
        Ok(())
    }

    /// Stop the playback; the shell keeps where it was, to go on from there.
    pub fn pause(&self) {
        let mut p = self.player();
        if let Some(pid) = p.pid.take() {
            let _ = std::process::Command::new("kill")
                .arg(pid.to_string())
                .status();
            self.publish(|st| st.playing = None);
        }
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
        let takes = list_takes(&takes_dir());
        if stopping && saved {
            self.publish(|st| {
                st.last = shown.clone();
                st.takes = takes;
            });
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
                st.takes = takes;
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
/// its level instead of being halved. The same sound also goes, mono and at
/// `WAVE_RATE`, to the standard output: anna draws the waveform from it.
fn audio_args(mode: &str, path: &Path) -> Vec<String> {
    let mut a: Vec<String> = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
        .map(String::from)
        .into();
    a.extend(["-f", "pulse", "-i", "default"].map(String::from));
    let (wave, file) = if mode == "mix" {
        a.extend(["-f", "pulse", "-i", "@DEFAULT_MONITOR@"].map(String::from));
        a.extend(
            [
                "-filter_complex",
                "amix=inputs=2:duration=longest:normalize=0,asplit=2[wave][file]",
            ]
            .map(String::from),
        );
        ("[wave]", "[file]")
    } else {
        ("0:a", "0:a")
    };
    a.extend(["-map", wave, "-ac", "1", "-ar"].map(String::from));
    a.push(WAVE_RATE.to_string());
    a.extend(["-f", "s16le", "pipe:1"].map(String::from));
    a.extend(["-map", file, "-c:a", "flac"].map(String::from));
    a.push(path.to_string_lossy().into_owned());
    a
}

/// ffmpeg's command line to play a take from `from` seconds: read at the
/// pace of the sound (`-re`), to the default output.
fn play_args(path: &Path, from: f64) -> Vec<String> {
    let mut a: Vec<String> = [
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-re",
        "-ss",
    ]
    .map(String::from)
    .into();
    a.push(format!("{from:.3}"));
    a.push("-i".into());
    a.push(path.to_string_lossy().into_owned());
    a.extend(["-f", "pulse", "karenine"].map(String::from));
    a
}

/// Where the takes go: the Music folder.
fn takes_dir() -> PathBuf {
    paths::user_dir("MUSIC", "Music")
}

/// The latest takes in `dir`, newest first: their names hold the date, so
/// sorting them sorts the takes.
fn list_takes(dir: &Path) -> Vec<Take> {
    let mut takes: Vec<Take> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            let at = name.strip_prefix(TAKE_PREFIX)?.strip_suffix(TAKE_EXT)?;
            Some(Take {
                path: e.path().to_string_lossy().into_owned(),
                at: at.to_string(),
                duration: 0.0,
            })
        })
        .collect();
    takes.sort_by(|a, b| b.at.cmp(&a.at));
    takes.truncate(TAKES_SHOWN);
    for t in &mut takes {
        t.duration = flac_duration(Path::new(&t.path)).unwrap_or(0.0);
    }
    takes
}

/// `path` when it names a take in the Music folder, else `None`: the
/// commands that read or delete a file reach nothing else.
fn take_path(path: &str) -> Option<PathBuf> {
    let p = std::fs::canonicalize(path).ok()?;
    let name = p.file_name()?.to_str()?;
    let is_take = name.starts_with(TAKE_PREFIX) && name.ends_with(TAKE_EXT);
    let dir = std::fs::canonicalize(takes_dir()).ok()?;
    (is_take && p.parent() == Some(dir.as_path()) && p.is_file()).then_some(p)
}

/// A take's duration, from the STREAMINFO block that opens a FLAC file.
fn flac_duration(path: &Path) -> Option<f64> {
    use std::io::Read;
    let mut head = [0u8; 26];
    std::fs::File::open(path).ok()?.read_exact(&mut head).ok()?;
    flac_head_duration(&head)
}

/// `fLaC`, the block header (type 0: STREAMINFO), then, further on, the
/// sample rate on 20 bits and the total of samples on 36.
fn flac_head_duration(h: &[u8; 26]) -> Option<f64> {
    if &h[..4] != b"fLaC" || h[4] & 0x7f != 0 {
        return None;
    }
    let rate = (u32::from(h[18]) << 12) | (u32::from(h[19]) << 4) | (u32::from(h[20]) >> 4);
    let total = (u64::from(h[21] & 0x0f) << 32)
        | (u64::from(h[22]) << 24)
        | (u64::from(h[23]) << 16)
        | (u64::from(h[24]) << 8)
        | u64::from(h[25]);
    (rate > 0).then(|| total as f64 / f64::from(rate))
}

/// The loudest sample of a chunk of s16le sound, 0–1, to the hundredth.
fn peak(chunk: &[u8]) -> f32 {
    let max = chunk
        .as_chunks::<2>()
        .0
        .iter()
        .map(|s| i16::from_le_bytes(*s).unsigned_abs())
        .max()
        .unwrap_or(0);
    (f32::from(max) / 32768.0 * 100.0).round() / 100.0
}

/// `peaks` brought down to `n`, each the loudest of its share.
fn bins(peaks: &[f32], n: usize) -> Vec<f32> {
    if peaks.len() <= n {
        return peaks.to_vec();
    }
    (0..n)
        .map(|i| {
            peaks[i * peaks.len() / n..(i + 1) * peaks.len() / n]
                .iter()
                .copied()
                .fold(0.0, f32::max)
        })
        .collect()
}

/// A take's cached waveform: `~/.cache/karenine/peaks/<name>.json`.
fn peaks_path(take: &Path) -> PathBuf {
    let name = take.file_name().unwrap_or_default().to_string_lossy();
    paths::cache_dir()
        .join("peaks")
        .join(format!("{name}.json"))
}

fn save_peaks(take: &Path, peaks: &[f32]) {
    let file = peaks_path(take);
    if let Some(dir) = file.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(json) = serde_json::to_string(peaks) {
        let _ = std::fs::write(file, json);
    }
}

/// gpu-screen-recorder's command line: `target` (`-w …`) at 60 images per
/// second, with the computer's sound. The processor encodes when the card
/// can't: a monitor on the NVIDIA card whose driver is older than the NVENC
/// API FFmpeg was built for gets no codec at all otherwise.
fn screen_args(target: Vec<String>, path: &Path) -> Vec<String> {
    let mut a = vec!["gpu-screen-recorder".to_string()];
    a.extend(target);
    a.extend(["-f", "60", "-a", "default_output", "-c", "mp4"].map(String::from));
    a.extend(["-fallback-cpu-encoding", "yes", "-o"].map(String::from));
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
    fn the_sound_also_goes_to_the_waveform() {
        for mode in ["mic", "mix"] {
            let a = audio_args(mode, Path::new("/tmp/x.flac"));
            let pipe = a.iter().position(|x| x == "pipe:1").unwrap();
            // Each output takes its own stream, the waveform's first.
            let maps: Vec<usize> = (0..a.len()).filter(|&i| a[i] == "-map").collect();
            assert_eq!(maps.len(), 2, "{mode}");
            assert!(maps[0] < pipe && pipe < maps[1], "{mode}");
            assert!(a[maps[0]..pipe].windows(2).any(|w| w == ["-ar", "8000"]));
        }
    }

    #[test]
    fn a_take_plays_from_where_it_was() {
        let a = play_args(Path::new("/tmp/x.flac"), 42.5);
        assert!(a.windows(2).any(|w| w == ["-ss", "42.500"]));
        // The seek comes before the input: ffmpeg jumps instead of decoding.
        let ss = a.iter().position(|x| x == "-ss").unwrap();
        let input = a.iter().position(|x| x == "-i").unwrap();
        assert!(a.contains(&"-re".to_string()) && ss < input);
        assert!(a.windows(2).any(|w| w == ["-f", "pulse"]));
    }

    #[test]
    fn the_flac_header_gives_the_duration() {
        // 44 100 Hz, 88 200 samples: two seconds of sine, written by ffmpeg.
        let h: [u8; 26] = [
            0x66, 0x4c, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22, 0x04, 0x00, 0x04, 0x00, 0x00, 0x00,
            0x6e, 0x00, 0x01, 0x87, 0x0a, 0xc4, 0x40, 0xf0, 0x00, 0x01, 0x58, 0x88,
        ];
        assert_eq!(flac_head_duration(&h), Some(2.0));
        let mut not_flac = h;
        not_flac[0] = b'X';
        assert_eq!(flac_head_duration(&not_flac), None);
    }

    #[test]
    fn peaks_are_the_loudest_samples() {
        let chunk: Vec<u8> = [0i16, -16384, 8192, i16::MIN]
            .iter()
            .flat_map(|s| s.to_le_bytes())
            .collect();
        assert_eq!(peak(&chunk), 1.0);
        assert_eq!(peak(&chunk[..4]), 0.5);
        assert_eq!(bins(&[0.1, 0.9, 0.2, 0.3], 2), vec![0.9, 0.3]);
        assert_eq!(bins(&[0.1, 0.2], 200), vec![0.1, 0.2]);
    }

    #[test]
    fn takes_are_listed_newest_first() {
        let dir = std::env::temp_dir().join(format!("anna-takes-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for i in 0..10 {
            let name = format!("enregistrement-2026102{i}_120000.flac");
            std::fs::write(dir.join(name), b"").unwrap();
        }
        std::fs::write(dir.join("morceau.flac"), b"").unwrap();
        let takes = list_takes(&dir);
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(takes.len(), TAKES_SHOWN);
        assert_eq!(takes[0].at, "20261029_120000");
        assert_eq!(takes[0].duration, 0.0);
    }

    #[test]
    fn the_screen_keeps_the_computers_sound() {
        let a = screen_args(vec!["-w".into(), "DP-1".into()], Path::new("/tmp/x.mp4"));
        assert_eq!(&a[..3], ["gpu-screen-recorder", "-w", "DP-1"]);
        assert!(a.windows(2).any(|w| w == ["-a", "default_output"]));
        assert!(a.windows(2).any(|w| w == ["-fallback-cpu-encoding", "yes"]));
        assert_eq!(a.last().unwrap(), "/tmp/x.mp4");
    }
}
