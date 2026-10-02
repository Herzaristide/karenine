//! From landmarks to intent: hand pose, the pointer state machine, pinches and
//! wide horizontal swipes.
//!
//! Two poses drive everything, chosen so that they can't be mistaken for each
//! other mid-gesture:
//!   • index pointed (the other three fingers curled) → the fingertip steers
//!     the cursor, a thumb–index pinch grabs the window under it;
//!   • open palm (all four fingers out) → the cursor lets go and stays put,
//!     and a wide sideways sweep switches workspace.
//!
//! Coordinates here are normalised to the frame and mirrored, so that moving
//! the hand to the user's right increases x — the camera sees it the other
//! way round.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::camera::{HEIGHT, WIDTH};
use super::vision::Landmarks;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pose {
    Open,
    Point,
    Other,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// No hand in view.
    Idle,
    /// A hand, but no gesture engaged.
    Hand,
    /// The index steers the cursor.
    Pointer,
    /// Open palm: cursor released, swipes armed.
    Palm,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Idle => "idle",
            Mode::Hand => "hand",
            Mode::Pointer => "pointer",
            Mode::Palm => "palm",
        }
    }
}

#[derive(Default)]
pub struct Output {
    /// Cursor target in [0, 1]², within the active zone of the frame.
    pub cursor: Option<[f32; 2]>,
    /// Pinch closed: grab the window under the cursor.
    pub grab: bool,
    /// Pinch opened (or hand lost): drop it.
    pub drop: bool,
    /// −1 = hand swept to the user's left, +1 = to the right.
    pub swipe: Option<i32>,
}

// ── Tunables ────────────────────────────────────────────────────────────────

/// A finger is out when its tip is this much farther from the wrist than its
/// middle joint. Curled, the tip folds back and ends up closer.
const EXTENDED_RATIO: f32 = 1.15;
/// Consecutive frames a pose must hold before it changes mode — one frame of
/// misread landmarks must not start or stop the pointer.
const POSE_FRAMES: u32 = 3;
/// Pinch hysteresis, as thumb–index distance over hand size (wrist → middle
/// knuckle): closing under ON grabs, opening past OFF drops.
const PINCH_ON: f32 = 0.30;
const PINCH_OFF: f32 = 0.45;
/// The part of the frame mapped onto the screen. The edges are hard to reach
/// with the fingertip (the hand leaves the frame first), and the bottom is
/// where the arm rests.
const ZONE_X: (f32, f32) = (0.20, 0.80);
const ZONE_Y: (f32, f32) = (0.12, 0.68);
/// A swipe: the palm travels this many palm lengths (wrist → middle knuckle)
/// sideways within SWIPE_WINDOW. Measured in palms, not in frame widths, so
/// the same gesture counts the same whether the hand is near the camera or
/// far from it — a fixed fraction of the frame missed every sweep made from
/// a step back. SWIPE_MIN_DIST keeps a hand held very far (tiny in the frame)
/// from firing on a twitch.
const SWIPE_PALMS: f32 = 1.0;
const SWIPE_MIN_DIST: f32 = 0.07;
/// Horizontal travel must exceed vertical travel by this factor, both in
/// pixels. An arm sweeping sideways pivots at the elbow, so the palm draws an
/// arc: some vertical drift is part of the gesture.
const SWIPE_HORIZONTAL: f32 = 1.2;
const SWIPE_WINDOW: Duration = Duration::from_millis(600);
const SWIPE_COOLDOWN: Duration = Duration::from_millis(700);
/// After a swipe, the hand comes back to the middle — and that return stroke
/// looks exactly like a swipe the other way, which undid every switch. The
/// opposite direction stays disarmed this long; the same direction re-arms
/// after SWIPE_COOLDOWN, so 1 → 3 is still two quick sweeps.
const SWIPE_RETURN_BLOCK: Duration = Duration::from_millis(1200);
/// Share of the swipe's frames that must read as an open palm: blur misreads
/// some of them, but a moving fist — or a relaxed hand drifting back — must
/// not switch workspace.
const SWIPE_OPEN_SHARE: f32 = 0.5;
/// How long a lost hand keeps its mode. Moving fast blurs the frames and the
/// tracker drops the hand for a few of them: that gap must not reset a swipe
/// in progress, nor drop a window mid-drag.
const LOST_GRACE: Duration = Duration::from_millis(500);

fn dist(a: [f32; 2], b: [f32; 2]) -> f32 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2)).sqrt()
}

fn extended(lm: &Landmarks, tip: usize, pip: usize) -> bool {
    dist(lm[0], lm[tip]) > dist(lm[0], lm[pip]) * EXTENDED_RATIO
}

pub fn pose(lm: &Landmarks) -> Pose {
    let index = extended(lm, 8, 6);
    let middle = extended(lm, 12, 10);
    let ring = extended(lm, 16, 14);
    let pinky = extended(lm, 20, 18);
    match (index, middle, ring, pinky) {
        (true, true, true, true) => Pose::Open,
        (true, false, false, false) => Pose::Point,
        _ => Pose::Other,
    }
}

pub fn pinch_ratio(lm: &Landmarks) -> f32 {
    dist(lm[4], lm[8]) / dist(lm[0], lm[9]).max(1.0)
}

/// Mirrored, normalised frame coordinates.
fn norm(p: [f32; 2]) -> [f32; 2] {
    [1.0 - p[0] / WIDTH as f32, p[1] / HEIGHT as f32]
}

fn zone(v: f32, (lo, hi): (f32, f32)) -> f32 {
    ((v - lo) / (hi - lo)).clamp(0.0, 1.0)
}

pub struct Recognizer {
    mode: Mode,
    candidate: Pose,
    candidate_frames: u32,
    grabbing: bool,
    lost_since: Option<Instant>,
    /// Palm centre over the last SWIPE_WINDOW, and whether it read as open.
    palm_track: VecDeque<(Instant, [f32; 2], bool)>,
    last_swipe: Option<(Instant, i32)>,
    /// Palm length in frame widths, smoothed: the swipe's unit of distance.
    palm_len: f32,
    /// Print swipe candidates (`anna gesture debug`).
    pub debug: bool,
}

impl Recognizer {
    pub fn new() -> Self {
        Self {
            mode: Mode::Idle,
            candidate: Pose::Other,
            candidate_frames: 0,
            grabbing: false,
            lost_since: None,
            palm_track: VecDeque::new(),
            last_swipe: None,
            palm_len: 0.0,
            debug: false,
        }
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn update(&mut self, lm: Option<&Landmarks>, now: Instant) -> Output {
        let mut out = Output::default();

        let lm = match lm {
            Some(lm) => {
                self.lost_since = None;
                lm
            }
            None => {
                let since = *self.lost_since.get_or_insert(now);
                if self.mode != Mode::Idle && now.duration_since(since) < LOST_GRACE {
                    return out;
                }
                // Hand gone for good: never leave a window held.
                out.drop = std::mem::take(&mut self.grabbing);
                self.mode = Mode::Idle;
                self.candidate_frames = 0;
                self.palm_track.clear();
                return out;
            }
        };

        let p = pose(lm);
        if p == self.candidate {
            self.candidate_frames += 1;
        } else {
            self.candidate = p;
            self.candidate_frames = 1;
        }
        let settled = self.candidate_frames >= POSE_FRAMES;

        self.mode = match (self.mode, p) {
            // Once pointing, stay so through anything but an open palm: the
            // index bends while pinching, and that must not drop the cursor.
            (Mode::Pointer, Pose::Open) if settled => Mode::Palm,
            (Mode::Pointer, _) => Mode::Pointer,
            (_, Pose::Point) if settled => Mode::Pointer,
            (_, Pose::Open) if settled => Mode::Palm,
            (Mode::Idle, _) => Mode::Hand,
            (Mode::Palm, Pose::Other) if settled => Mode::Hand,
            (m, _) => m,
        };

        if self.mode != Mode::Pointer {
            out.drop = std::mem::take(&mut self.grabbing);
            // Tracked whatever this frame's pose — blur mid-sweep misreads
            // the fingers, and a fast sweep may start before Palm has
            // settled. track_swipe checks instead that the hand was mostly
            // open.
            out.swipe = self.track_swipe(lm, p == Pose::Open, now);
            return out;
        }
        self.palm_track.clear();

        let tip = norm(lm[8]);
        out.cursor = Some([zone(tip[0], ZONE_X), zone(tip[1], ZONE_Y)]);
        let r = pinch_ratio(lm);
        if !self.grabbing && r < PINCH_ON {
            self.grabbing = true;
            out.grab = true;
        } else if self.grabbing && r > PINCH_OFF {
            self.grabbing = false;
            out.drop = true;
        }
        out
    }

    fn track_swipe(&mut self, lm: &Landmarks, open: bool, now: Instant) -> Option<i32> {
        // Palm centre: the wrist and the four knuckles, steadier than any tip.
        let mut c = [0.0f32; 2];
        for i in [0, 5, 9, 13, 17] {
            let n = norm(lm[i]);
            c[0] += n[0] / 5.0;
            c[1] += n[1] / 5.0;
        }
        self.palm_track.push_back((now, c, open));
        while let Some(&(t, _, _)) = self.palm_track.front() {
            if now.duration_since(t) > SWIPE_WINDOW {
                self.palm_track.pop_front();
            } else {
                break;
            }
        }

        // Palm length, in frame widths like dx. Smoothed: a blurred frame
        // misplaces the knuckles and must not shrink the unit mid-sweep.
        let len = dist(lm[0], lm[9]) / WIDTH as f32;
        self.palm_len = if self.palm_len == 0.0 {
            len
        } else {
            0.8 * self.palm_len + 0.2 * len
        };

        let (last_at, last_dir) = match self.last_swipe {
            Some((t, d)) => (Some(now.duration_since(t)), d),
            None => (None, 0),
        };
        if last_at.is_some_and(|d| d < SWIPE_COOLDOWN) {
            return None;
        }

        // Measure from the far end of the window, not its start: a sweep that
        // began with a small backswing still counts in full.
        let (mut lo, mut hi) = (c, c);
        let mut opens = 0;
        for &(_, p, o) in &self.palm_track {
            if p[0] < lo[0] {
                lo = p;
            }
            if p[0] > hi[0] {
                hi = p;
            }
            opens += o as usize;
        }
        let (dx, from) = if c[0] - lo[0] >= hi[0] - c[0] {
            (c[0] - lo[0], lo)
        } else {
            (c[0] - hi[0], hi)
        };
        // In units of frame *width*, like dx: the frame is 16:9, so a
        // fraction of its height is 0.56 of the same fraction of its width.
        let dy = (c[1] - from[1]) * HEIGHT as f32 / WIDTH as f32;
        let open_share = opens as f32 / self.palm_track.len() as f32;

        let threshold = (SWIPE_PALMS * self.palm_len).max(SWIPE_MIN_DIST);
        let dir = if dx > 0.0 { 1 } else { -1 };
        // The return stroke of the previous swipe, not a swipe of its own.
        let returning = dir == -last_dir && last_at.is_some_and(|d| d < SWIPE_RETURN_BLOCK);

        if self.debug && dx.abs() >= threshold / 2.0 {
            eprintln!(
                "gesture: sweep dx {dx:+.2} / {threshold:.2} (palm {:.2}) dy {dy:+.2} open {:.0}% over {} frames{}",
                self.palm_len,
                open_share * 100.0,
                self.palm_track.len(),
                if returning { " [return, ignored]" } else { "" }
            );
        }
        if dx.abs() >= threshold
            && dx.abs() > SWIPE_HORIZONTAL * dy.abs()
            && open_share >= SWIPE_OPEN_SHARE
            && !returning
        {
            self.last_swipe = Some((now, dir));
            self.palm_track.clear();
            return Some(dir);
        }
        None
    }
}

// ── One Euro filter ─────────────────────────────────────────────────────────

/// Casiez et al.'s 1€ filter: a low-pass whose cutoff rises with speed. Slow,
/// deliberate moves are smoothed hard (no jitter while aiming), fast ones
/// barely at all (no lag while travelling).
pub struct OneEuro {
    min_cutoff: f32,
    beta: f32,
    d_cutoff: f32,
    prev: Option<(Instant, [f32; 2], [f32; 2])>,
}

impl OneEuro {
    pub fn new(min_cutoff: f32, beta: f32) -> Self {
        Self {
            min_cutoff,
            beta,
            d_cutoff: 1.0,
            prev: None,
        }
    }

    pub fn reset(&mut self) {
        self.prev = None;
    }

    fn alpha(cutoff: f32, dt: f32) -> f32 {
        let tau = 1.0 / (2.0 * std::f32::consts::PI * cutoff);
        1.0 / (1.0 + tau / dt)
    }

    pub fn filter(&mut self, x: [f32; 2], now: Instant) -> [f32; 2] {
        let (t0, x0, dx0) = match self.prev {
            Some(p) => p,
            None => {
                self.prev = Some((now, x, [0.0; 2]));
                return x;
            }
        };
        let dt = now.duration_since(t0).as_secs_f32().max(1e-3);
        let a_d = Self::alpha(self.d_cutoff, dt);
        let mut out = [0.0; 2];
        let mut dx = [0.0; 2];
        for k in 0..2 {
            let raw_d = (x[k] - x0[k]) / dt;
            dx[k] = a_d * raw_d + (1.0 - a_d) * dx0[k];
        }
        let speed = (dx[0] * dx[0] + dx[1] * dx[1]).sqrt();
        let a = Self::alpha(self.min_cutoff + self.beta * speed, dt);
        for k in 0..2 {
            out[k] = a * x[k] + (1.0 - a) * x0[k];
        }
        self.prev = Some((now, out, dx));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: f32 = 80.0; // palm length in pixels (wrist → middle knuckle)
    const FRAME: Duration = Duration::from_millis(33);

    /// A synthetic upright hand, wrist at (x, y) in camera pixels. `fingers`
    /// says which of index/middle/ring/pinky are out; `pinch` puts the thumb
    /// tip on the index tip.
    fn hand(x: f32, y: f32, fingers: [bool; 4], pinch: bool) -> Landmarks {
        let mut lm = [[0.0f32; 2]; 21];
        lm[0] = [x, y];
        for (i, &out) in fingers.iter().enumerate() {
            let base = 5 + 4 * i;
            let mx = x + (i as f32 - 1.5) * 0.25 * S;
            let my = y - S;
            lm[base] = [mx, my];
            lm[base + 1] = [mx, my - 0.4 * S];
            if out {
                lm[base + 2] = [mx, my - 0.65 * S];
                lm[base + 3] = [mx, my - 0.9 * S];
            } else {
                // Curled: the tip folds back towards the palm.
                lm[base + 2] = [mx, my - 0.3 * S];
                lm[base + 3] = [mx, my - 0.1 * S];
            }
        }
        lm[1] = [x - 0.3 * S, y - 0.3 * S];
        lm[2] = [x - 0.5 * S, y - 0.5 * S];
        lm[3] = [x - 0.6 * S, y - 0.7 * S];
        lm[4] = if pinch {
            lm[8]
        } else {
            [x - 0.7 * S, y - 0.9 * S]
        };
        lm
    }

    const OPEN: [bool; 4] = [true; 4];
    const POINT: [bool; 4] = [true, false, false, false];
    const FIST: [bool; 4] = [false; 4];

    struct Clock(Instant);
    impl Clock {
        fn tick(&mut self) -> Instant {
            self.0 += FRAME;
            self.0
        }
        fn wait(&mut self, d: Duration) {
            self.0 += d;
        }
    }

    fn feed(r: &mut Recognizer, clock: &mut Clock, lm: Landmarks, frames: usize) -> Vec<Output> {
        (0..frames)
            .map(|_| r.update(Some(&lm), clock.tick()))
            .collect()
    }

    #[test]
    fn poses() {
        assert_eq!(pose(&hand(320.0, 300.0, OPEN, false)), Pose::Open);
        assert_eq!(pose(&hand(320.0, 300.0, POINT, false)), Pose::Point);
        assert_eq!(pose(&hand(320.0, 300.0, FIST, false)), Pose::Other);
        assert_eq!(
            pose(&hand(320.0, 300.0, [true, true, false, false], false)),
            Pose::Other
        );
    }

    #[test]
    fn pinch_ratio_is_scale_free() {
        let open = pinch_ratio(&hand(320.0, 300.0, POINT, false));
        assert!(open > PINCH_OFF, "{open}");
        assert!(pinch_ratio(&hand(320.0, 300.0, POINT, true)) < PINCH_ON);
    }

    #[test]
    fn pose_must_settle_before_pointing() {
        let mut r = Recognizer::new();
        let mut c = Clock(Instant::now());
        let lm = hand(320.0, 300.0, POINT, false);
        let outs = feed(&mut r, &mut c, lm, POSE_FRAMES as usize);
        assert!(outs[..POSE_FRAMES as usize - 1]
            .iter()
            .all(|o| o.cursor.is_none()));
        assert_eq!(r.mode(), Mode::Pointer);
        let cur = outs.last().unwrap().cursor.unwrap();
        assert!((0.0..=1.0).contains(&cur[0]) && (0.0..=1.0).contains(&cur[1]));
    }

    #[test]
    fn cursor_is_mirrored() {
        let mut r = Recognizer::new();
        let mut c = Clock(Instant::now());
        let left = feed(&mut r, &mut c, hand(250.0, 300.0, POINT, false), 4);
        let right = feed(&mut r, &mut c, hand(390.0, 300.0, POINT, false), 1);
        // The hand moves right in the camera image → left for the user.
        assert!(right[0].cursor.unwrap()[0] < left[3].cursor.unwrap()[0]);
    }

    #[test]
    fn pinch_grabs_then_drops_once() {
        let mut r = Recognizer::new();
        let mut c = Clock(Instant::now());
        feed(&mut r, &mut c, hand(320.0, 300.0, POINT, false), 4);
        let g = feed(&mut r, &mut c, hand(320.0, 300.0, POINT, true), 3);
        assert_eq!(g.iter().filter(|o| o.grab).count(), 1);
        let d = feed(&mut r, &mut c, hand(320.0, 300.0, POINT, false), 3);
        assert_eq!(d.iter().filter(|o| o.drop).count(), 1);
        assert!(d.iter().all(|o| !o.grab));
    }

    #[test]
    fn short_loss_keeps_mode_long_loss_drops_window() {
        let mut r = Recognizer::new();
        let mut c = Clock(Instant::now());
        feed(&mut r, &mut c, hand(320.0, 300.0, POINT, false), 4);
        feed(&mut r, &mut c, hand(320.0, 300.0, POINT, true), 1);
        // A blurred frame or two: nothing happens.
        let out = r.update(None, c.tick());
        assert!(!out.drop);
        assert_eq!(r.mode(), Mode::Pointer);
        // Gone past the grace period: the held window is released.
        c.wait(LOST_GRACE);
        let out = r.update(None, c.tick());
        assert!(out.drop);
        assert_eq!(r.mode(), Mode::Idle);
    }

    /// Sweep an open palm from x0 to x1 (camera pixels) over `frames` frames.
    fn sweep(r: &mut Recognizer, c: &mut Clock, x0: f32, x1: f32, frames: usize) -> Vec<i32> {
        (0..=frames)
            .filter_map(|i| {
                let x = x0 + (x1 - x0) * i as f32 / frames as f32;
                r.update(Some(&hand(x, 300.0, OPEN, false)), c.tick()).swipe
            })
            .collect()
    }

    #[test]
    fn wide_open_palm_sweep_swipes_once() {
        let mut r = Recognizer::new();
        let mut c = Clock(Instant::now());
        feed(&mut r, &mut c, hand(200.0, 300.0, OPEN, false), 4);
        assert_eq!(r.mode(), Mode::Palm);
        // Camera-right is the user's left: −1.
        assert_eq!(sweep(&mut r, &mut c, 200.0, 440.0, 10), vec![-1]);
    }

    #[test]
    fn small_drift_is_not_a_swipe() {
        let mut r = Recognizer::new();
        let mut c = Clock(Instant::now());
        feed(&mut r, &mut c, hand(300.0, 300.0, OPEN, false), 4);
        assert!(sweep(&mut r, &mut c, 300.0, 340.0, 10).is_empty());
    }

    #[test]
    fn fist_sweep_is_not_a_swipe() {
        let mut r = Recognizer::new();
        let mut c = Clock(Instant::now());
        let swipes: Vec<_> = (0..=10)
            .filter_map(|i| {
                let x = 200.0 + 24.0 * i as f32;
                r.update(Some(&hand(x, 300.0, FIST, false)), c.tick()).swipe
            })
            .collect();
        assert!(swipes.is_empty());
    }

    #[test]
    fn return_stroke_is_ignored_but_same_direction_rearms() {
        let mut r = Recognizer::new();
        let mut c = Clock(Instant::now());
        feed(&mut r, &mut c, hand(200.0, 300.0, OPEN, false), 4);
        assert_eq!(sweep(&mut r, &mut c, 200.0, 440.0, 10), vec![-1]);
        // Bringing the hand back, after the cooldown but within the block.
        c.wait(SWIPE_COOLDOWN);
        assert!(sweep(&mut r, &mut c, 440.0, 200.0, 6).is_empty());
        // A second sweep the same way still counts.
        c.wait(SWIPE_COOLDOWN);
        assert_eq!(sweep(&mut r, &mut c, 200.0, 440.0, 10), vec![-1]);
    }

    #[test]
    fn one_euro_passes_first_sample_and_smooths_jitter() {
        let mut f = OneEuro::new(1.0, 0.0);
        let t = Instant::now();
        assert_eq!(f.filter([0.5, 0.5], t), [0.5, 0.5]);
        let out = f.filter([0.6, 0.5], t + FRAME);
        assert!(out[0] > 0.5 && out[0] < 0.6, "{out:?}");
        f.reset();
        assert_eq!(f.filter([0.1, 0.2], t + FRAME * 2), [0.1, 0.2]);
    }
}
