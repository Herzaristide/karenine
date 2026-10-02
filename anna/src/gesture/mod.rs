//! Gesture control: the webcam drives the cursor and moves windows.
//!
//! Runs on its own thread inside the daemon, for as long as it is enabled:
//!
//!   camera ─► Tracker (palm detector + landmarks) ─► Recognizer ─► actions
//!
//! • index pointed → the fingertip moves the cursor over the whole desktop,
//!   every monitor at once (1€-filtered);
//! • thumb–index pinch → grabs the window under the cursor (focus + move,
//!   Hyprland's own interactive drag), released when the pinch opens;
//! • open palm → the cursor lets go and stays put; swept wide sideways, it
//!   switches to the previous/next workspace of the focused monitor.
//!
//! State lives in `~/.config/accent/gesture.json` (`enabled`, `camera`,
//! `invert_swipe`), toggled through the socket (`anna gesture on|off|toggle`).
//! Disabling stops ffmpeg, which frees the camera and turns its LED off.

mod camera;
mod output;
mod recognize;
mod vision;

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::watch;

use output::{Layout, Pointer};
use recognize::{Mode, OneEuro, Recognizer};

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub enabled: bool,
    pub camera: String,
    /// false: sweeping the hand to the left goes to the next workspace, like
    /// pushing the current one out of the way (touchpad "natural" direction).
    pub invert_swipe: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            // Off until the user turns it on: a webcam must never light up unasked.
            enabled: false,
            camera: "/dev/video0".into(),
            invert_swipe: false,
        }
    }
}

#[derive(Clone, Serialize, PartialEq, Default)]
pub struct Status {
    pub enabled: bool,
    /// The camera is open (LED on).
    pub active: bool,
    pub mode: &'static str,
    pub fps: u32,
    pub error: Option<String>,
    /// The V4L2 device in use (or to be used once enabled).
    pub camera: String,
}

/// A V4L2 capture device, as offered to the user.
#[derive(Serialize)]
pub struct CameraInfo {
    pub path: String,
    pub name: String,
}

/// Capture devices, from sysfs. A webcam usually exposes two nodes, the
/// second one (index 1) carrying only metadata: keep index 0.
pub fn cameras() -> Vec<CameraInfo> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir("/sys/class/video4linux") else {
        return out;
    };
    for e in entries.flatten() {
        let node = e.file_name().to_string_lossy().into_owned();
        let read = |f: &str| std::fs::read_to_string(e.path().join(f)).unwrap_or_default();
        if !node.starts_with("video") || read("index").trim() != "0" {
            continue;
        }
        out.push(CameraInfo {
            path: format!("/dev/{node}"),
            name: read("name").trim().to_string(),
        });
    }
    out.sort_by_key(|c| c.path[10..].parse::<u32>().unwrap_or(u32::MAX));
    out
}

pub struct Gesture {
    cfg: Mutex<Config>,
    wake: Condvar,
    cfg_path: PathBuf,
    status: watch::Sender<Status>,
}

/// Where the ONNX models live: the package's share dir, set by the wrapper.
fn models_dir() -> PathBuf {
    std::env::var_os("ANNA_GESTURE_MODELS")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/run/current-system/sw/share/anna/models"))
}

impl Gesture {
    /// Load the config and start the engine thread. `verbose` prints per-second
    /// diagnostics (fps, timings, pose) — that's `anna gesture debug`.
    pub fn start(dir: &Path, verbose: bool, dry_run: bool) -> Arc<Self> {
        let cfg_path = dir.join("gesture.json");
        let cfg: Config = std::fs::read_to_string(&cfg_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let (status, _) = watch::channel(Status {
            enabled: cfg.enabled,
            camera: cfg.camera.clone(),
            mode: Mode::Idle.as_str(),
            ..Default::default()
        });
        let g = Arc::new(Self {
            cfg: Mutex::new(cfg),
            wake: Condvar::new(),
            cfg_path,
            status,
        });
        let engine = Arc::clone(&g);
        std::thread::Builder::new()
            .name("gesture".into())
            .spawn(move || engine.run(verbose, dry_run))
            .expect("spawn gesture thread");
        g
    }

    fn save(&self, cfg: &Config) {
        if let Ok(json) = serde_json::to_string_pretty(cfg) {
            let _ = std::fs::write(&self.cfg_path, json + "\n");
        }
    }

    pub fn set_enabled(&self, on: bool) {
        let mut cfg = self.cfg.lock().unwrap();
        cfg.enabled = on;
        self.save(&cfg);
        drop(cfg);
        self.status.send_modify(|s| s.enabled = on);
        self.wake.notify_all();
    }

    /// Switch to another capture device. A running session notices the
    /// change on its next frame and reopens on the new one.
    pub fn set_camera(&self, device: &str) {
        let mut cfg = self.cfg.lock().unwrap();
        cfg.camera = device.to_string();
        self.save(&cfg);
        drop(cfg);
        self.status.send_modify(|s| {
            s.camera = device.to_string();
            s.error = None;
        });
        self.wake.notify_all();
    }

    fn camera(&self) -> String {
        self.cfg.lock().unwrap().camera.clone()
    }

    pub fn enabled(&self) -> bool {
        self.cfg.lock().unwrap().enabled
    }

    pub fn subscribe(&self) -> watch::Receiver<Status> {
        self.status.subscribe()
    }

    pub fn status(&self) -> Status {
        self.status.borrow().clone()
    }

    fn publish(&self, f: impl FnOnce(&mut Status)) {
        self.status.send_if_modified(|s| {
            let before = s.clone();
            f(s);
            *s != before
        });
    }

    /// Sleep until enabled, or for `timeout` at most. Returns whether enabled.
    fn wait_enabled(&self, timeout: Option<Duration>) -> bool {
        let cfg = self.cfg.lock().unwrap();
        let cfg = match timeout {
            Some(t) => {
                self.wake
                    .wait_timeout_while(cfg, t, |c| !c.enabled)
                    .unwrap()
                    .0
            }
            None => self.wake.wait_while(cfg, |c| !c.enabled).unwrap(),
        };
        cfg.enabled
    }

    fn run(self: Arc<Self>, verbose: bool, dry_run: bool) {
        // Models are loaded once, on first enable, and kept across toggles.
        let mut tracker: Option<vision::Tracker> = None;

        loop {
            self.publish(|s| {
                s.active = false;
                s.mode = Mode::Idle.as_str();
                s.fps = 0;
            });
            self.wait_enabled(None);

            if tracker.is_none() {
                match vision::Tracker::new(&models_dir()) {
                    Ok(t) => tracker = Some(t),
                    Err(e) => {
                        eprintln!("anna: gesture: cannot load models: {e}");
                        self.publish(|s| s.error = Some(format!("models: {e}")));
                        std::thread::sleep(Duration::from_secs(30));
                        continue;
                    }
                }
            }

            let device = self.camera();
            let cam = match camera::Camera::open(&device) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("anna: gesture: cannot start camera {device}: {e}");
                    self.publish(|s| s.error = Some(format!("camera: {e}")));
                    self.wait_for_change(&device, Duration::from_secs(5));
                    continue;
                }
            };

            let err = self.session(&cam, tracker.as_mut().unwrap(), verbose, dry_run);
            drop(cam);
            if let Some(e) = err {
                eprintln!("anna: gesture: {e}");
                self.publish(|s| {
                    s.error = Some(e);
                    s.active = false;
                    s.fps = 0;
                });
                // Device gone or busy: retry, but don't spin.
                self.wait_for_change(&device, Duration::from_secs(5));
            }
        }
    }

    /// Back off after a camera error: `t` at most, less if the user disables
    /// gestures or picks another camera meanwhile.
    fn wait_for_change(&self, device: &str, t: Duration) {
        let cfg = self.cfg.lock().unwrap();
        let _ = self
            .wake
            .wait_timeout_while(cfg, t, |c| c.enabled && c.camera == device);
    }

    /// One camera session, until disabled (None) or a camera error (Some).
    fn session(
        &self,
        cam: &camera::Camera,
        tracker: &mut vision::Tracker,
        verbose: bool,
        dry_run: bool,
    ) -> Option<String> {
        let mut recognizer = Recognizer::new();
        recognizer.debug = verbose;
        let invert = self.cfg.lock().unwrap().invert_swipe;
        // Tuned in logical pixels: ~1 Hz cutoff at rest kills the tremor,
        // beta opens it up as soon as the finger travels.
        let mut filter = OneEuro::new(1.0, 0.01);
        let mut pointer: Option<Pointer> = None;
        let mut pointer_error = false;
        let mut layout = Layout::query();
        let mut layout_at = Instant::now();
        // Recent cursor positions: a pinch pulls the fingertip toward the
        // thumb, so the grab lands where the finger was just *before* it.
        let mut trail: VecDeque<(Instant, [f32; 2])> = VecDeque::new();
        let mut frozen_until: Option<Instant> = None;
        let mut frame_no: u64 = 0;
        let mut last_seen: Option<Instant> = None;

        let mut stats = Stats::default();

        self.publish(|s| {
            s.active = true;
            s.error = None;
        });

        let device = self.camera();
        while self.enabled() && self.camera() == device {
            let frame = match cam.next_frame() {
                Ok(f) => f,
                Err(e) => return Some(format!("camera: {e}")),
            };
            let now = Instant::now();
            frame_no += 1;

            // Without a hand, look for one on every third frame only: the
            // palm detector is the expensive half and nobody notices 100 ms.
            // Right after losing one, though — typically blurred by a fast
            // move, maybe mid-drag — every frame counts to pick it back up.
            let just_lost =
                last_seen.is_some_and(|t| now.duration_since(t) < Duration::from_secs(1));
            let allow_detect = tracker.tracking() || just_lost || frame_no.is_multiple_of(3);
            let t0 = Instant::now();
            let hand = match tracker.process(&frame, allow_detect) {
                Ok(h) => h,
                Err(e) => return Some(format!("inference: {e}")),
            };
            if hand.is_some() {
                last_seen = Some(now);
            }
            stats.infer += t0.elapsed();
            stats.frames += 1;

            let out = recognizer.update(hand.as_ref().map(|h| &h.lm), now);

            if now.duration_since(layout_at) > Duration::from_millis(500) {
                layout = Layout::query().or(layout);
                layout_at = now;
            }

            if !dry_run && pointer.is_none() && !pointer_error && recognizer.mode() == Mode::Pointer
            {
                match Pointer::new() {
                    Ok(p) => pointer = Some(p),
                    Err(e) => {
                        pointer_error = true;
                        let msg = format!("uinput: {e} (is the user in the uinput group?)");
                        eprintln!("anna: gesture: {msg}");
                        self.publish(|s| s.error = Some(msg));
                    }
                }
            }

            if let (Some(c), Some(l)) = (out.cursor, layout.as_ref()) {
                // The active zone spans the whole desktop, every monitor at
                // once — no focus to follow, so no cursor hopping between them.
                let target = filter.filter(
                    [l.min_x + c[0] * l.width(), l.min_y + c[1] * l.height()],
                    now,
                );
                trail.push_back((now, target));
                while trail.len() > 1 && now.duration_since(trail[0].0) > Duration::from_millis(250)
                {
                    trail.pop_front();
                }
                let aim = if out.grab {
                    // Where the finger was ~120 ms ago, before the pinch began.
                    trail
                        .iter()
                        .find(|(t, _)| now.duration_since(*t) <= Duration::from_millis(120))
                        .map(|&(_, p)| p)
                        .unwrap_or(target)
                } else {
                    target
                };
                let frozen = frozen_until.is_some_and(|t| now < t);
                if let Some(p) = pointer.as_mut() {
                    if out.grab || !frozen {
                        let _ = p.move_to(l, aim[0], aim[1]);
                    }
                }
            } else {
                filter.reset();
                trail.clear();
            }

            if let Some(p) = pointer.as_mut() {
                if out.grab {
                    let _ = p.grab(true);
                }
                if out.drop {
                    let _ = p.grab(false);
                    // Opening the pinch drags the fingertip too.
                    frozen_until = Some(now + Duration::from_millis(150));
                }
            }
            if verbose && (out.grab || out.drop) {
                eprintln!("gesture: {}", if out.grab { "grab" } else { "drop" });
            }

            if let Some(dir) = out.swipe {
                let step = if invert { dir } else { -dir };
                if verbose {
                    let side = if dir > 0 { "right" } else { "left" };
                    eprintln!("gesture: swipe {side} → workspace {step:+}");
                }
                if !dry_run {
                    std::thread::spawn(move || output::switch_workspace(step));
                }
            }

            let mode = recognizer.mode();
            self.publish(|s| s.mode = mode.as_str());

            if stats.since.elapsed() >= Duration::from_secs(1) {
                let fps = stats.frames;
                self.publish(|s| s.fps = fps);
                if verbose {
                    let pose = hand.as_ref().map(|h| recognize::pose(&h.lm));
                    let pinch = hand.as_ref().map(|h| recognize::pinch_ratio(&h.lm));
                    eprintln!(
                        "gesture: {fps:>2} fps, {:>5.1} ms/frame, mode {:<7} pose {:<5} pinch {} score {}",
                        stats.infer.as_secs_f64() * 1000.0 / fps.max(1) as f64,
                        mode.as_str(),
                        pose.map(|p| format!("{p:?}")).unwrap_or_else(|| "-".into()),
                        pinch.map(|r| format!("{r:.2}")).unwrap_or_else(|| "-".into()),
                        hand.as_ref().map(|h| format!("{:.2}", h.score)).unwrap_or_else(|| "-".into()),
                    );
                }
                if verbose {
                    if let Some(path) = std::env::var_os("ANNA_GESTURE_SNAPSHOT") {
                        let _ = snapshot(Path::new(&path), &frame, hand.as_ref().map(|h| &h.lm));
                    }
                }
                stats = Stats::default();
            }
        }

        if let Some(p) = pointer.as_mut() {
            let _ = p.grab(false);
        }
        None
    }
}

/// Debug aid: the current frame as a PPM, landmarks drawn as 5×5 squares
/// (fingertips red, the rest green). `ANNA_GESTURE_SNAPSHOT=/tmp/hand.ppm`.
fn snapshot(path: &Path, frame: &[u8], lm: Option<&vision::Landmarks>) -> std::io::Result<()> {
    let mut img = frame.to_vec();
    if let Some(lm) = lm {
        for (i, p) in lm.iter().enumerate() {
            let color = if [4, 8, 12, 16, 20].contains(&i) {
                [255, 0, 0]
            } else {
                [0, 255, 0]
            };
            for dy in -2..=2 {
                for dx in -2..=2 {
                    let (x, y) = (p[0] as i32 + dx, p[1] as i32 + dy);
                    if x >= 0
                        && y >= 0
                        && (x as usize) < camera::WIDTH
                        && (y as usize) < camera::HEIGHT
                    {
                        let o = (y as usize * camera::WIDTH + x as usize) * 3;
                        img[o..o + 3].copy_from_slice(&color);
                    }
                }
            }
        }
    }
    let mut out = format!("P6\n{} {}\n255\n", camera::WIDTH, camera::HEIGHT).into_bytes();
    out.extend_from_slice(&img);
    std::fs::write(path, out)
}

struct Stats {
    since: Instant,
    frames: u32,
    infer: Duration,
}

impl Default for Stats {
    fn default() -> Self {
        Self {
            since: Instant::now(),
            frames: 0,
            infer: Duration::ZERO,
        }
    }
}
