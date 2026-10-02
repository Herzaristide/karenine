//! Hand tracking: MediaPipe's two-stage pipeline, ported from the OpenCV
//! model zoo (`palm_detection_mediapipe`, `handpose_estimation_mediapipe`,
//! Apache-2.0) and MediaPipe's own graph calculators.
//!
//!   1. The palm detector (192×192, SSD with 2016 anchors) finds a hand in the
//!      whole frame. It only runs while no hand is tracked.
//!   2. The landmark model (224×224) sees a square crop rotated so the fingers
//!      point up, and returns 21 landmarks plus a presence score.
//!   3. The next frame's crop is derived from those landmarks, so as long as
//!      the hand stays in view the detector never runs again.
//!
//! Rotations follow MediaPipe's convention: a crop of angle θ maps its local
//! point (lx, ly) to the image as (lx·cosθ − ly·sinθ, lx·sinθ + ly·cosθ), with
//! y pointing down. θ = 0 is an upright hand.

use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use ort::value::TensorRef;
use std::f32::consts::{FRAC_PI_2, PI};
use std::path::Path;

use super::camera::{HEIGHT, WIDTH};

pub type Landmarks = [[f32; 2]; 21];

/// A rotated square region of the frame, in pixels.
#[derive(Clone, Copy, Debug)]
pub struct Roi {
    pub cx: f32,
    pub cy: f32,
    pub size: f32,
    pub angle: f32,
}

pub struct Hand {
    /// Landmarks in frame pixels (MediaPipe numbering: 0 wrist, 4 thumb tip,
    /// 8 index tip, 12 middle tip, 16 ring tip, 20 pinky tip).
    pub lm: Landmarks,
    pub score: f32,
}

fn load(path: &Path) -> Result<Session, String> {
    let err = |e: &dyn std::fmt::Display| format!("{}: {e}", path.display());
    Session::builder()
        .map_err(|e| err(&e))?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        .map_err(|e| err(&e))?
        // One thread, no spinning: each inference is a few ms, and ONNX
        // Runtime's default pool busy-waits between runs — 1.6 cores burnt at
        // 30 fps for ~0.15 of actual work.
        .with_intra_threads(1)
        .map_err(|e| err(&e))?
        .with_intra_op_spinning(false)
        .map_err(|e| err(&e))?
        .with_inter_op_spinning(false)
        .map_err(|e| err(&e))?
        .commit_from_file(path)
        .map_err(|e| err(&e))
}

fn normalize_angle(a: f32) -> f32 {
    a - 2.0 * PI * ((a + PI) / (2.0 * PI)).floor()
}

/// MediaPipe's hand orientation: 0 when `to` sits straight above `from`.
fn orientation(from: [f32; 2], to: [f32; 2]) -> f32 {
    normalize_angle(FRAC_PI_2 - (-(to[1] - from[1])).atan2(to[0] - from[0]))
}

/// Bilinear RGB sample, black outside the frame, written as floats in [0, 1].
#[inline]
fn sample(img: &[u8], x: f32, y: f32, out: &mut [f32]) {
    let x0 = x.floor();
    let y0 = y.floor();
    let fx = x - x0;
    let fy = y - y0;
    let (x0, y0) = (x0 as i32, y0 as i32);
    let px = |xi: i32, yi: i32, c: usize| -> f32 {
        if xi < 0 || yi < 0 || xi >= WIDTH as i32 || yi >= HEIGHT as i32 {
            0.0
        } else {
            img[(yi as usize * WIDTH + xi as usize) * 3 + c] as f32
        }
    };
    for (c, o) in out.iter_mut().enumerate().take(3) {
        let top = px(x0, y0, c) * (1.0 - fx) + px(x0 + 1, y0, c) * fx;
        let bot = px(x0, y0 + 1, c) * (1.0 - fx) + px(x0 + 1, y0 + 1, c) * fx;
        *o = (top * (1.0 - fy) + bot * fy) / 255.0;
    }
}

// ── Palm detector ───────────────────────────────────────────────────────────

const PALM_IN: usize = 192;

pub struct PalmDetector {
    session: Session,
    anchors: Vec<[f32; 2]>,
    input: Vec<f32>,
}

struct Palm {
    cx: f32,
    cy: f32,
    w: f32,
    h: f32,
    /// 7 keypoints: 0 wrist, 2 middle finger base (the two used for rotation).
    kp: [[f32; 2]; 7],
}

impl PalmDetector {
    pub fn new(path: &Path) -> Result<Self, String> {
        // MediaPipe SSD anchors: a 24×24 grid (stride 8) with 2 anchors per
        // cell, then a 12×12 grid (strides 16 ×3, merged) with 6 per cell.
        let mut anchors = Vec::with_capacity(2016);
        for (grid, per_cell) in [(24usize, 2usize), (12, 6)] {
            for y in 0..grid {
                for x in 0..grid {
                    for _ in 0..per_cell {
                        anchors.push([
                            (x as f32 + 0.5) / grid as f32,
                            (y as f32 + 0.5) / grid as f32,
                        ]);
                    }
                }
            }
        }
        Ok(Self {
            session: load(path)?,
            anchors,
            input: vec![0.0; PALM_IN * PALM_IN * 3],
        })
    }

    fn detect(&mut self, frame: &[u8], threshold: f32) -> Result<Option<Palm>, String> {
        // Letterbox the frame into the square input, keeping its aspect.
        let long = WIDTH.max(HEIGHT) as f32;
        let scale = PALM_IN as f32 / long;
        let nw = (WIDTH as f32 * scale) as usize;
        let nh = (HEIGHT as f32 * scale) as usize;
        let pad_x = (PALM_IN - nw) / 2;
        let pad_y = (PALM_IN - nh) / 2;
        self.input.fill(0.0);
        for oy in pad_y..pad_y + nh {
            for ox in pad_x..pad_x + nw {
                let sx = (ox - pad_x) as f32 / scale + 0.5 / scale - 0.5;
                let sy = (oy - pad_y) as f32 / scale + 0.5 / scale - 0.5;
                let i = (oy * PALM_IN + ox) * 3;
                sample(frame, sx, sy, &mut self.input[i..i + 3]);
            }
        }

        let input = TensorRef::from_array_view(([1usize, PALM_IN, PALM_IN, 3], &self.input[..]))
            .map_err(|e| e.to_string())?;
        let outputs = self
            .session
            .run(ort::inputs![input])
            .map_err(|e| e.to_string())?;

        // Two outputs: regressors [1, 2016, 18] and logits [1, 2016, 1].
        let mut regs: Option<&[f32]> = None;
        let mut logits: Option<&[f32]> = None;
        for i in 0..outputs.len() {
            let (shape, data) = outputs[i]
                .try_extract_tensor::<f32>()
                .map_err(|e| e.to_string())?;
            match shape.last() {
                Some(18) => regs = Some(data),
                Some(1) => logits = Some(data),
                _ => {}
            }
        }
        let (regs, logits) = match (regs, logits) {
            (Some(r), Some(l)) => (r, l),
            _ => return Err("palm detector: unexpected outputs".into()),
        };

        // One hand is all we track: keep the best-scoring anchor, no NMS.
        let mut best = None;
        let mut best_logit = f32::MIN;
        for (i, &l) in logits.iter().enumerate() {
            if l > best_logit {
                best_logit = l;
                best = Some(i);
            }
        }
        let i = match best {
            Some(i) if 1.0 / (1.0 + (-best_logit).exp()) >= threshold => i,
            _ => return Ok(None),
        };

        // Back from the letterboxed square to frame pixels.
        let r = &regs[i * 18..i * 18 + 18];
        let a = self.anchors[i];
        let bias_x = pad_x as f32 / scale;
        let bias_y = pad_y as f32 / scale;
        let to_px = |dx: f32, dy: f32| -> [f32; 2] {
            [
                (dx / PALM_IN as f32 + a[0]) * long - bias_x,
                (dy / PALM_IN as f32 + a[1]) * long - bias_y,
            ]
        };
        let c = to_px(r[0], r[1]);
        let mut kp = [[0.0; 2]; 7];
        for (j, k) in kp.iter_mut().enumerate() {
            *k = to_px(r[4 + 2 * j], r[5 + 2 * j]);
        }
        Ok(Some(Palm {
            cx: c[0],
            cy: c[1],
            w: r[2] / PALM_IN as f32 * long,
            h: r[3] / PALM_IN as f32 * long,
            kp,
        }))
    }
}

// ── Landmark model ──────────────────────────────────────────────────────────

const LM_IN: usize = 224;

pub struct LandmarkModel {
    session: Session,
    input: Vec<f32>,
}

impl LandmarkModel {
    pub fn new(path: &Path) -> Result<Self, String> {
        Ok(Self {
            session: load(path)?,
            input: vec![0.0; LM_IN * LM_IN * 3],
        })
    }

    fn infer(&mut self, frame: &[u8], roi: Roi) -> Result<Hand, String> {
        let (sin, cos) = roi.angle.sin_cos();
        let step = roi.size / LM_IN as f32;
        for v in 0..LM_IN {
            let ly = (v as f32 + 0.5) * step - roi.size / 2.0;
            for u in 0..LM_IN {
                let lx = (u as f32 + 0.5) * step - roi.size / 2.0;
                let x = roi.cx + lx * cos - ly * sin;
                let y = roi.cy + lx * sin + ly * cos;
                let i = (v * LM_IN + u) * 3;
                sample(frame, x, y, &mut self.input[i..i + 3]);
            }
        }

        let input = TensorRef::from_array_view(([1usize, LM_IN, LM_IN, 3], &self.input[..]))
            .map_err(|e| e.to_string())?;
        let outputs = self
            .session
            .run(ort::inputs![input])
            .map_err(|e| e.to_string())?;

        // Outputs, in order: screen landmarks [1, 63], presence [1, 1],
        // handedness [1, 1], world landmarks [1, 63].
        let mut screen: Option<&[f32]> = None;
        let mut presence: Option<f32> = None;
        for i in 0..outputs.len() {
            let (_, data) = outputs[i]
                .try_extract_tensor::<f32>()
                .map_err(|e| e.to_string())?;
            if data.len() == 63 && screen.is_none() {
                screen = Some(data);
            } else if data.len() == 1 && presence.is_none() {
                presence = Some(data[0]);
            }
        }
        let (screen, score) = match (screen, presence) {
            (Some(s), Some(p)) => (s, p),
            _ => return Err("landmark model: unexpected outputs".into()),
        };

        let mut lm = [[0.0; 2]; 21];
        for (j, p) in lm.iter_mut().enumerate() {
            let lx = (screen[j * 3] / LM_IN as f32 - 0.5) * roi.size;
            let ly = (screen[j * 3 + 1] / LM_IN as f32 - 0.5) * roi.size;
            *p = [roi.cx + lx * cos - ly * sin, roi.cy + lx * sin + ly * cos];
        }
        Ok(Hand { lm, score })
    }
}

// ── Regions of interest ─────────────────────────────────────────────────────

/// MediaPipe's RectTransformation: shift along the rect's own axes, then make
/// it square on its long side and scale it.
fn transform(cx: f32, cy: f32, w: f32, h: f32, angle: f32, shift_y: f32, scale: f32) -> Roi {
    let (sin, cos) = angle.sin_cos();
    Roi {
        cx: cx - h * shift_y * sin,
        cy: cy + h * shift_y * cos,
        size: w.max(h) * scale,
        angle,
    }
}

fn roi_from_palm(p: &Palm) -> Roi {
    let angle = orientation(p.kp[0], p.kp[2]);
    transform(p.cx, p.cy, p.w, p.h, angle, -0.5, 2.6)
}

/// MediaPipe's HandLandmarksToRect, on the palm-ish subset of landmarks.
fn roi_from_landmarks(lm: &Landmarks) -> Roi {
    const SUBSET: [usize; 12] = [0, 1, 2, 3, 5, 6, 9, 10, 13, 14, 17, 18];
    let mid = [
        ((lm[5][0] + lm[13][0]) / 2.0 + lm[9][0]) / 2.0,
        ((lm[5][1] + lm[13][1]) / 2.0 + lm[9][1]) / 2.0,
    ];
    let angle = orientation(lm[0], mid);

    let (mut min_x, mut min_y, mut max_x, mut max_y) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for &i in &SUBSET {
        min_x = min_x.min(lm[i][0]);
        max_x = max_x.max(lm[i][0]);
        min_y = min_y.min(lm[i][1]);
        max_y = max_y.max(lm[i][1]);
    }
    let (acx, acy) = ((min_x + max_x) / 2.0, (min_y + max_y) / 2.0);

    // Bounds in the hand's own frame.
    let (rs, rc) = (-angle).sin_cos();
    let (mut pmin_x, mut pmin_y, mut pmax_x, mut pmax_y) = (f32::MAX, f32::MAX, f32::MIN, f32::MIN);
    for &i in &SUBSET {
        let (ox, oy) = (lm[i][0] - acx, lm[i][1] - acy);
        let px = ox * rc - oy * rs;
        let py = ox * rs + oy * rc;
        pmin_x = pmin_x.min(px);
        pmax_x = pmax_x.max(px);
        pmin_y = pmin_y.min(py);
        pmax_y = pmax_y.max(py);
    }
    let (pcx, pcy) = ((pmin_x + pmax_x) / 2.0, (pmin_y + pmax_y) / 2.0);
    let (s, c) = angle.sin_cos();
    let cx = pcx * c - pcy * s + acx;
    let cy = pcx * s + pcy * c + acy;
    transform(cx, cy, pmax_x - pmin_x, pmax_y - pmin_y, angle, -0.1, 2.0)
}

// ── Tracker ─────────────────────────────────────────────────────────────────

/// Presence score under which a tracked hand is considered lost.
const PRESENCE_MIN: f32 = 0.5;
/// Palm detector confidence needed to (re)acquire a hand.
const DETECT_MIN: f32 = 0.6;

pub struct Tracker {
    palm: PalmDetector,
    landmarks: LandmarkModel,
    roi: Option<Roi>,
}

impl Tracker {
    pub fn new(models: &Path) -> Result<Self, String> {
        Ok(Self {
            palm: PalmDetector::new(&models.join("palm_detection_mediapipe_2023feb.onnx"))?,
            landmarks: LandmarkModel::new(
                &models.join("handpose_estimation_mediapipe_2023feb.onnx"),
            )?,
            roi: None,
        })
    }

    pub fn tracking(&self) -> bool {
        self.roi.is_some()
    }

    /// Process one frame. `allow_detect` lets the caller throttle the (more
    /// expensive) palm detector while no hand is in view.
    pub fn process(&mut self, frame: &[u8], allow_detect: bool) -> Result<Option<Hand>, String> {
        if let Some(roi) = self.roi {
            let hand = self.landmarks.infer(frame, roi)?;
            if hand.score >= PRESENCE_MIN {
                self.roi = Some(roi_from_landmarks(&hand.lm));
                return Ok(Some(hand));
            }
            self.roi = None;
        }
        if !allow_detect {
            return Ok(None);
        }
        let palm = match self.palm.detect(frame, DETECT_MIN)? {
            Some(p) => p,
            None => return Ok(None),
        };
        let hand = self.landmarks.infer(frame, roi_from_palm(&palm))?;
        if hand.score >= PRESENCE_MIN {
            self.roi = Some(roi_from_landmarks(&hand.lm));
            Ok(Some(hand))
        } else {
            Ok(None)
        }
    }
}
