//! Real-time 12-bin chromagram — native port of `backend/chroma-analyzer.py`.
//!
//! Consumes the shared mono capture and emits one
//! `{"chroma":[12 floats],"top":["C","E","G"]}` JSON line per analysis frame.
//! Each FFT bin is mapped to a pitch class (C..B); bin magnitudes in the
//! musical band are summed per class, normalized, and EMA-smoothed — matching
//! the original NumPy implementation, with all bin→pitch math derived from the
//! real capture sample rate.

use rustfft::{num_complex::Complex, FftPlanner};
use std::sync::mpsc::Receiver;
use tokio::sync::mpsc::Sender;

const ALPHA: f32 = 0.55; // EMA smoothing factor for output
const GATE: f32 = 0.004; // RMS gate below which we report silence

const NOTE_NAMES: [&str; 12] = [
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
];

/// Run the chromagram loop. Reads mono samples from `audio_rx` and pushes JSON
/// lines into `out`. Returns when either channel closes.
pub fn run(sample_rate: u32, audio_rx: Receiver<Vec<f32>>, out: Sender<String>) {
    let sr = sample_rate as f32;
    // ~186 ms window (like the Python default) rounded to a power of two, with a
    // quarter-window hop (~22 fps at the original rate).
    let n = crate::audio::next_pow2((sr * 0.186) as usize).max(2048);
    let hop = (n / 4).max(256);
    let bins = n / 2 + 1;

    // Pre-compute the pitch class and band mask for every FFT bin.
    let mut pc = vec![0usize; bins];
    let mut in_band = vec![false; bins];
    for (i, (pc_i, band_i)) in pc.iter_mut().zip(in_band.iter_mut()).enumerate() {
        let freq = i as f32 * sr / n as f32;
        let midi = 69.0 + 12.0 * (freq.max(1e-9) / 440.0).log2();
        *pc_i = (midi.round() as i64).rem_euclid(12) as usize;
        *band_i = (60.0..=2100.0).contains(&freq);
    }

    let window = crate::audio::hann(n);
    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(n);
    let mut scratch = vec![Complex::new(0.0, 0.0); n];

    let mut buf: Vec<f32> = Vec::with_capacity(n * 2);
    let mut hop_count = 0usize;
    let mut ema = [0.0f32; 12];

    loop {
        let chunk = match audio_rx.recv() {
            Ok(c) => c,
            Err(_) => return, // capture stopped
        };
        hop_count += chunk.len();
        buf.extend_from_slice(&chunk);
        if buf.len() > n {
            let excess = buf.len() - n;
            buf.drain(0..excess);
        }
        if hop_count < hop || buf.len() < n {
            continue;
        }
        hop_count = 0;

        let rms = (buf.iter().map(|&s| s * s).sum::<f32>() / n as f32).sqrt();
        if rms < GATE {
            // Decay quickly during silence, but still report so bars fall.
            for v in ema.iter_mut() {
                *v *= 0.6;
            }
            if out.blocking_send(chroma_json(&ema)).is_err() {
                return;
            }
            continue;
        }

        for (i, slot) in scratch.iter_mut().enumerate() {
            *slot = Complex::new(buf[i] * window[i], 0.0);
        }
        fft.process(&mut scratch);

        let mut chroma = [0.0f32; 12];
        for i in 0..bins {
            if in_band[i] {
                let mag = (scratch[i].re * scratch[i].re + scratch[i].im * scratch[i].im).sqrt();
                chroma[pc[i]] += mag;
            }
        }
        let sum: f32 = chroma.iter().sum();
        if sum > 0.0 {
            for v in chroma.iter_mut() {
                *v /= sum;
            }
        }
        for k in 0..12 {
            ema[k] = ALPHA * chroma[k] + (1.0 - ALPHA) * ema[k];
        }

        if out.blocking_send(chroma_json(&ema)).is_err() {
            return; // socket closed
        }
    }
}

/// Serialize the 12 chroma values plus the three loudest pitch classes.
fn chroma_json(ema: &[f32; 12]) -> String {
    let values: Vec<String> = ema.iter().map(|v| format!("{v:.3}")).collect();

    let mut order: Vec<usize> = (0..12).collect();
    order.sort_by(|&a, &b| ema[b].partial_cmp(&ema[a]).unwrap_or(std::cmp::Ordering::Equal));
    let top: Vec<String> = order
        .iter()
        .take(3)
        .map(|&i| format!("\"{}\"", NOTE_NAMES[i]))
        .collect();

    format!(
        "{{\"chroma\":[{}],\"top\":[{}]}}",
        values.join(","),
        top.join(",")
    )
}
