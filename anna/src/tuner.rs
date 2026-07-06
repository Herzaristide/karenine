//! Real-time monophonic pitch detector — native port of `backend/tuner.py`.
//!
//! Consumes the shared mono capture and emits one `{"pitch":<hz>}` JSON line
//! per analysis frame (`pitch` is 0.0 when the input is silent or unvoiced).
//! The fundamental is estimated by FFT-based autocorrelation (Wiener–Khinchin)
//! with parabolic peak interpolation and light EMA smoothing, exactly like the
//! original NumPy implementation. All frequency math is derived from the real
//! capture sample rate, so it stays correct whatever the device runs at.

use rustfft::{num_complex::Complex, FftPlanner};
use std::sync::mpsc::Receiver;
use tokio::sync::mpsc::Sender;

const FMIN: f32 = 55.0; // A1
const FMAX: f32 = 1500.0; // ~F#6
const GATE: f32 = 0.002; // RMS gate below which we report silence
const CONF: f32 = 0.25; // min normalized autocorrelation peak to accept a pitch
const ALPHA: f32 = 0.4; // EMA smoothing factor on the emitted frequency

/// Run the pitch-detection loop. Reads mono samples from `audio_rx` and pushes
/// JSON lines into `out`. Returns when either channel closes (mic stopped or
/// socket disconnected).
pub fn run(sample_rate: u32, audio_rx: Receiver<Vec<f32>>, out: Sender<String>) {
    let sr = sample_rate as f32;
    // ~93 ms window and ~11 ms hop, matching the Python timing, rounded to a
    // power of two for the FFT.
    let n = crate::audio::next_pow2((sr * 0.093) as usize).max(2048);
    let hop = ((sr * 0.011) as usize).max(256);
    let lag_min = ((sr / FMAX) as usize).max(1);
    let lag_max = (sr / FMIN) as usize;
    let nfft = crate::audio::next_pow2(2 * n);

    let window: Vec<f32> = crate::audio::hann(n);
    let mut planner = FftPlanner::<f32>::new();
    let fft_fwd = planner.plan_fft_forward(nfft);
    let fft_inv = planner.plan_fft_inverse(nfft);
    let mut scratch = vec![Complex::new(0.0, 0.0); nfft];

    let mut buf: Vec<f32> = Vec::with_capacity(n * 2);
    let mut hop_count = 0usize;
    let mut ema_f = 0.0f32;

    loop {
        let chunk = match audio_rx.recv() {
            Ok(c) => c,
            Err(_) => return, // capture stopped
        };
        hop_count += chunk.len();
        buf.extend_from_slice(&chunk);
        if buf.len() > n {
            let excess = buf.len() - n;
            buf.drain(0..excess); // keep only the most recent window
        }
        if hop_count < hop || buf.len() < n {
            continue;
        }
        hop_count = 0;

        let freq = detect_pitch(
            &buf, &window, n, lag_min, lag_max, sr, &fft_fwd, &fft_inv, &mut scratch,
        );

        let emitted = if freq > 0.0 {
            ema_f = if ema_f == 0.0 {
                freq
            } else {
                ALPHA * freq + (1.0 - ALPHA) * ema_f
            };
            ema_f
        } else {
            ema_f = 0.0;
            0.0
        };

        if out.blocking_send(format!("{{\"pitch\":{emitted:.2}}}")).is_err() {
            return; // socket closed
        }
    }
}

/// One autocorrelation pass over the most recent window. Returns the detected
/// fundamental in Hz, or 0.0 when silent / aperiodic / out of range.
#[allow(clippy::too_many_arguments)]
fn detect_pitch(
    frame: &[f32],
    window: &[f32],
    n: usize,
    lag_min: usize,
    lag_max: usize,
    sr: f32,
    fft_fwd: &std::sync::Arc<dyn rustfft::Fft<f32>>,
    fft_inv: &std::sync::Arc<dyn rustfft::Fft<f32>>,
    scratch: &mut [Complex<f32>],
) -> f32 {
    let mean = frame.iter().sum::<f32>() / n as f32;
    let rms = (frame.iter().map(|&s| (s - mean) * (s - mean)).sum::<f32>() / n as f32).sqrt();
    if rms < GATE {
        return 0.0;
    }

    // Zero-padded windowed frame → forward FFT.
    for (i, slot) in scratch.iter_mut().enumerate() {
        *slot = if i < n {
            Complex::new((frame[i] - mean) * window[i], 0.0)
        } else {
            Complex::new(0.0, 0.0)
        };
    }
    fft_fwd.process(scratch);
    // Power spectrum |X|² (real), then inverse FFT → autocorrelation.
    for c in scratch.iter_mut() {
        let p = c.re * c.re + c.im * c.im;
        *c = Complex::new(p, 0.0);
    }
    fft_inv.process(scratch);

    let acf0 = scratch[0].re;
    if acf0 <= 0.0 {
        return 0.0;
    }

    let hi = lag_max.min(n - 1);
    if lag_min >= hi {
        return 0.0;
    }
    // Peak of the autocorrelation within the plausible lag range.
    let mut peak = lag_min;
    let mut best = scratch[lag_min].re;
    for lag in (lag_min + 1)..hi {
        let v = scratch[lag].re;
        if v > best {
            best = v;
            peak = lag;
        }
    }
    if best / acf0 < CONF {
        return 0.0; // not periodic enough → unvoiced
    }

    // Parabolic interpolation around the peak for sub-sample precision.
    let shift = if peak >= 1 && peak < n - 1 {
        let a = scratch[peak - 1].re;
        let b = scratch[peak].re;
        let c = scratch[peak + 1].re;
        let denom = a - 2.0 * b + c;
        if denom != 0.0 {
            0.5 * (a - c) / denom
        } else {
            0.0
        }
    } else {
        0.0
    };
    let period = peak as f32 + shift;
    let freq = if period > 0.0 { sr / period } else { 0.0 };

    if (FMIN..=FMAX).contains(&freq) {
        freq
    } else {
        0.0
    }
}
