//! What the computer plays, as harmony: notes, chord, key — to improvise
//! over a video or a song without playing out of tune.
//!
//! Reads what goes to the speakers (`audio::start_output_capture`), not the
//! mic, and emits one JSON line per hop (~46 ms):
//!
//! ```json
//! {"chroma":[12],"top":["A","C","E"],
//!  "chord":{"name":"Am","root":9,"tones":[9,0,4]},
//!  "key":{"tonic":9,"minor":true,"flats":false,"scale":[9,11,0,2,4,5,7],"confidence":0.82},
//!  "tuning":-3}
//! ```
//!
//! `chord` and `key` are `null` until they are clear. Three time scales:
//! the bars follow the sound (~0.1 s), the chord the beat (~0.12 s on a 0.37 s window, then an
//! HMM that only changes its mind on evidence), the key the song (~20 s).
//!
//! Each frame: spectral peaks (interpolated, so a semitone is told apart
//! even where the FFT bins are coarse), log-compressed; a peak that is a
//! harmonic of a lower one gives most of its weight to that fundamental —
//! a lone C no longer reads as C-E-G — and the pitch grid follows the
//! measured tuning of the recording (A = 432, a sample pitched down…).

use rustfft::{num_complex::Complex, FftPlanner};
use std::sync::mpsc::Receiver;
use tokio::sync::mpsc::Sender;

/// Capture rate: harmony lives under 5 kHz, and a lower rate gives finer
/// bins for the same window.
pub const RATE: u32 = 22_050;

const GATE: f32 = 0.002; // RMS under which the frame is silence
const F_LO: f32 = 50.0;
const F_HI: f32 = 5000.0;
const BASS_HI: f32 = 250.0; // fundamentals under this form the bass
const MAX_PEAKS: usize = 48;
/// Spectral flatness over which a frame holds no harmony (noise, a cymbal,
/// applause): white noise is ~0.56, music under ~0.2.
const FLAT_MAX: f32 = 0.35;
/// Share of a harmonic's weight given to its fundamental.
const TO_FUNDAMENTAL: f32 = 0.6;

const TAU_BARS: f32 = 0.12;
const TAU_CHORD: f32 = 0.12;
const TAU_KEY: f32 = 20.0;
const TAU_TUNING: f32 = 8.0;
/// Seconds of sound before a key is told.
const KEY_AFTER: f32 = 4.0;
/// A silence this long starts the analysis over (another song).
const RESET_AFTER: f32 = 3.0;

const SHARPS: [&str; 12] = [
    "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B",
];
const FLATS: [&str; 12] = [
    "C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B",
];

/// Chord qualities: suffix, intervals from the root, score handicap (a
/// richer chord must explain the sound better than its triad to win).
const QUALITIES: [(&str, &[usize], f32); 7] = [
    ("", &[0, 4, 7], 0.0),
    ("m", &[0, 3, 7], 0.0),
    ("7", &[0, 4, 7, 10], 0.03),
    ("maj7", &[0, 4, 7, 11], 0.03),
    ("m7", &[0, 3, 7, 10], 0.03),
    ("dim", &[0, 3, 6], 0.04),
    ("sus4", &[0, 5, 7], 0.04),
];
const N_CHORDS: usize = 12 * QUALITIES.len();
/// Score of "no chord" (index `N_CHORDS`): a flat chroma (drums, noise)
/// matches a triad at ~0.5, a played chord at 0.7 and over.
const NO_CHORD: f32 = 0.6;
/// Weight of the bass on the root.
const BASS_BONUS: f32 = 0.15;
/// HMM: sharpness of the evidence, chance per hop of a chord change.
const KAPPA: f64 = 25.0;
const SWITCH: f64 = 0.1;

// Krumhansl–Kessler key profiles, from the tonic.
const MAJOR: [f32; 12] = [
    6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
];
const MINOR: [f32; 12] = [
    6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
];
const MAJOR_SCALE: [usize; 7] = [0, 2, 4, 5, 7, 9, 11];
const MINOR_SCALE: [usize; 7] = [0, 2, 3, 5, 7, 8, 10];
/// A new key must correlate this much better to replace the current one.
const KEY_MARGIN: f32 = 0.05;
const KEY_MIN: f32 = 0.5;

/// Run the analysis loop. Reads mono samples from `audio_rx` and pushes JSON
/// lines into `out`. Returns when either channel closes.
pub fn run(sample_rate: u32, audio_rx: Receiver<Vec<f32>>, out: Sender<String>) {
    let mut a = Analyzer::new(sample_rate as f32);
    let mut buf: Vec<f32> = Vec::with_capacity(a.n * 2);
    let mut pending = 0usize;
    while let Ok(chunk) = audio_rx.recv() {
        pending += chunk.len();
        buf.extend_from_slice(&chunk);
        if buf.len() > a.n {
            buf.drain(0..buf.len() - a.n);
        }
        if buf.len() < a.n {
            continue;
        }
        while pending >= a.hop {
            pending -= a.hop;
            // Several hops in one chunk: analyse the latest window only, but
            // let the smoothing see the time that passed.
            a.elapsed += a.hop as f32 / a.sr;
        }
        if a.elapsed == 0.0 {
            continue;
        }
        let line = a.frame(&buf);
        if out.blocking_send(line).is_err() {
            return;
        }
    }
}

struct Peak {
    freq: f32,
    amp: f32,
    weight: f32,
}

struct Key {
    tonic: usize,
    minor: bool,
    corr: f32,
}

struct Analyzer {
    sr: f32,
    n: usize,
    hop: usize,
    window: Vec<f32>,
    fft: std::sync::Arc<dyn rustfft::Fft<f32>>,
    scratch: Vec<Complex<f32>>,
    mag: Vec<f32>,
    prefix: Vec<f32>,
    /// Time since the last analysed frame, in seconds.
    elapsed: f32,

    bars: [f32; 12],
    level: f32,
    chord_chroma: [f32; 12],
    bass: [f32; 12],
    key_chroma: [f32; 12],
    /// Tuning as a unit vector on the cents circle (one turn = 100 cents).
    tuning: (f32, f32),
    post: Vec<f64>,
    key: Option<Key>,
    sounding: f32,
    silent: f32,
}

impl Analyzer {
    fn new(sr: f32) -> Self {
        // ~0.37 s window: 8192 at 22.05 kHz, 2.7 Hz bins; hop of an eighth.
        let n = crate::audio::next_pow2((sr * 0.37) as usize).max(2048);
        let mut planner = FftPlanner::<f32>::new();
        let mut a = Analyzer {
            sr,
            n,
            hop: n / 8,
            window: crate::audio::hann(n),
            fft: planner.plan_fft_forward(n),
            scratch: vec![Complex::new(0.0, 0.0); n],
            mag: vec![0.0; n / 2 + 1],
            prefix: vec![0.0; n / 2 + 2],
            elapsed: 0.0,
            bars: [0.0; 12],
            level: 0.0,
            chord_chroma: [0.0; 12],
            bass: [0.0; 12],
            key_chroma: [0.0; 12],
            tuning: (0.0, 0.0),
            post: Vec::new(),
            key: None,
            sounding: 0.0,
            silent: 0.0,
        };
        a.reset();
        a
    }

    fn reset(&mut self) {
        self.chord_chroma = [0.0; 12];
        self.bass = [0.0; 12];
        self.key_chroma = [0.0; 12];
        self.tuning = (0.0, 0.0);
        self.post = vec![1.0 / (N_CHORDS + 1) as f64; N_CHORDS + 1];
        self.key = None;
        self.sounding = 0.0;
    }

    /// One analysis of the latest window → its JSON line.
    fn frame(&mut self, buf: &[f32]) -> String {
        let dt = std::mem::take(&mut self.elapsed);
        let rms = (buf.iter().map(|&s| s * s).sum::<f32>() / buf.len() as f32).sqrt();
        if rms < GATE {
            self.silent += dt;
            self.level *= 0.6;
            if self.silent >= RESET_AFTER {
                self.reset();
            } else if self.silent >= 1.0 {
                self.post.fill(1.0 / (N_CHORDS + 1) as f64);
            }
            return self.json(None);
        }
        self.silent = 0.0;
        self.sounding += dt;
        self.level = 1.0;

        let peaks = self.peaks(buf);
        if self.flatness() > FLAT_MAX {
            // Sound without harmony: the bars show it, the chord fades out.
            let flat = [1.0 / 12.0; 12];
            ema(&mut self.bars, &flat, dt, TAU_BARS);
            ema(&mut self.chord_chroma, &flat, dt, TAU_CHORD);
            let chord = self.chord();
            return self.json(chord);
        }
        let owner = owners(&peaks);
        self.track_tuning(&peaks, &owner, dt);
        let (chroma, bass) = self.attribute(&peaks, &owner);

        ema(&mut self.bars, &chroma, dt, TAU_BARS);
        ema(&mut self.chord_chroma, &chroma, dt, TAU_CHORD);
        ema(&mut self.bass, &bass, dt, TAU_CHORD);
        ema(&mut self.key_chroma, &chroma, dt, TAU_KEY);

        let chord = self.chord();
        if self.sounding >= KEY_AFTER {
            self.update_key();
        }
        self.json(chord)
    }

    /// Spectral peaks of the window, frequency and amplitude interpolated on
    /// the log magnitude (exact to a few cents for a Hann window).
    fn peaks(&mut self, buf: &[f32]) -> Vec<Peak> {
        let mean = buf.iter().sum::<f32>() / buf.len() as f32;
        for (i, slot) in self.scratch.iter_mut().enumerate() {
            *slot = Complex::new((buf[i] - mean) * self.window[i], 0.0);
        }
        self.fft.process(&mut self.scratch);
        for (m, c) in self.mag.iter_mut().zip(&self.scratch) {
            *m = (c.re * c.re + c.im * c.im).sqrt();
        }
        for i in 0..self.mag.len() {
            self.prefix[i + 1] = self.prefix[i] + self.mag[i];
        }

        let bin = self.sr / self.n as f32;
        let lo = ((F_LO / bin) as usize).max(2);
        let hi = ((F_HI / bin) as usize).min(self.mag.len() - 2);
        let top = self.mag[lo..=hi].iter().cloned().fold(0.0f32, f32::max);
        if top <= 0.0 {
            return Vec::new();
        }
        let mut peaks = Vec::new();
        for i in lo..=hi {
            let (a, b, c) = (self.mag[i - 1], self.mag[i], self.mag[i + 1]);
            if b <= a || b < c || b < top * 1e-3 {
                continue;
            }
            // Over the local floor (± ~1.5 semitone): a partial, not a hump
            // of noise.
            let w = (i / 8).max(4);
            let (s, e) = (i.saturating_sub(w), (i + w + 1).min(self.mag.len()));
            let floor = (self.prefix[e] - self.prefix[s]) / (e - s) as f32;
            if b < 2.0 * floor {
                continue;
            }
            let (la, lb, lc) = (a.max(1e-12).ln(), b.ln(), c.max(1e-12).ln());
            let denom = la - 2.0 * lb + lc;
            let d = if denom < 0.0 {
                (0.5 * (la - lc) / denom).clamp(-0.5, 0.5)
            } else {
                0.0
            };
            let amp = (lb - 0.25 * (la - lc) * d).exp();
            peaks.push(Peak {
                freq: (i as f32 + d) * bin,
                amp,
                weight: 0.0,
            });
        }
        peaks.sort_by(|a, b| b.amp.total_cmp(&a.amp));
        peaks.truncate(MAX_PEAKS);
        let top = peaks.first().map_or(1.0, |p| p.amp);
        for p in peaks.iter_mut() {
            // Log compression: a quiet inner voice still counts.
            p.weight = (1.0 + 100.0 * p.amp / top).ln();
        }
        peaks.sort_by(|a, b| a.freq.total_cmp(&b.freq));
        peaks
    }

    /// Spectral flatness of the last FFT in the musical band: geometric over
    /// arithmetic mean of the power, 1 for white noise, ~0 for pure tones.
    fn flatness(&self) -> f32 {
        let bin = self.sr / self.n as f32;
        let band = &self.mag[(F_LO / bin) as usize..(F_HI / bin) as usize];
        let (mut log, mut lin) = (0.0f64, 0.0f64);
        for &m in band {
            let p = (m as f64 * m as f64).max(1e-20);
            log += p.ln();
            lin += p;
        }
        let n = band.len() as f64;
        ((log / n).exp() / (lin / n)) as f32
    }

    /// Follow the recording's tuning: the weighted mean of every peak's
    /// offset from the 440 Hz grid, on a circle (+50 and −50 cents meet). A
    /// harmonic counts for its fundamental: the 5th and 7th sit 14 and 31
    /// cents off the tempered grid by nature.
    fn track_tuning(&mut self, peaks: &[Peak], owner: &[usize], dt: f32) {
        let (mut x, mut y) = (0.0f32, 0.0f32);
        for (j, p) in peaks.iter().enumerate().filter(|(_, p)| p.freq < 2000.0) {
            let h = (p.freq / peaks[owner[j]].freq).round().max(1.0);
            let c = 1200.0 * (p.freq / h / 440.0).log2();
            let a = std::f32::consts::TAU * c / 100.0;
            x += p.weight * a.cos();
            y += p.weight * a.sin();
        }
        let norm = (x * x + y * y).sqrt();
        if norm <= 0.0 {
            return;
        }
        let k = 1.0 - (-dt / TAU_TUNING).exp();
        self.tuning.0 += k * (x / norm - self.tuning.0);
        self.tuning.1 += k * (y / norm - self.tuning.1);
    }

    fn tuning_cents(&self) -> f32 {
        self.tuning.1.atan2(self.tuning.0) / std::f32::consts::TAU * 100.0
    }

    fn pitch_class(&self, freq: f32) -> usize {
        let midi = 69.0 + 12.0 * (freq / 440.0).log2() - self.tuning_cents() / 100.0;
        (midi.round() as i64).rem_euclid(12) as usize
    }

    /// The frame's chroma, each harmonic giving most of its weight to the
    /// fundamental it belongs to, and its bass: the lowest note that counts.
    fn attribute(&self, peaks: &[Peak], owner: &[usize]) -> ([f32; 12], [f32; 12]) {
        let mut chroma = [0.0f32; 12];
        // What each fundamental weighs with its harmonics.
        let mut note = vec![0.0f32; peaks.len()];
        for (j, p) in peaks.iter().enumerate() {
            let o = owner[j];
            let (pc, root) = (self.pitch_class(p.freq), self.pitch_class(peaks[o].freq));
            if o == j {
                chroma[pc] += p.weight;
            } else {
                chroma[pc] += p.weight * (1.0 - TO_FUNDAMENTAL);
                chroma[root] += p.weight * TO_FUNDAMENTAL;
            }
            note[o] += p.weight;
        }
        let mut bass = [0.0f32; 12];
        let strongest = note.iter().cloned().fold(0.0f32, f32::max);
        // Peaks are sorted by frequency: the first fundamental that weighs.
        if let Some(j) = (0..peaks.len())
            .find(|&j| owner[j] == j && peaks[j].freq < BASS_HI && note[j] >= 0.3 * strongest)
        {
            bass[self.pitch_class(peaks[j].freq)] = 1.0;
        }
        (normalized(chroma), bass)
    }

    /// The chord under the smoothed chroma, through an HMM forward filter:
    /// each hop weighs the evidence against staying on the current chord.
    fn chord(&mut self) -> Option<usize> {
        let norm = self.chord_chroma.iter().map(|v| v * v).sum::<f32>().sqrt();
        if norm <= 0.0 {
            return None;
        }
        let bass_sum: f32 = self.bass.iter().sum();
        let mut scores = [0.0f32; N_CHORDS + 1];
        for (q, (_, ivs, handicap)) in QUALITIES.iter().enumerate() {
            let tnorm = (ivs.len() as f32).sqrt();
            for root in 0..12 {
                let dot: f32 = ivs.iter().map(|i| self.chord_chroma[(root + i) % 12]).sum();
                let bass = if bass_sum > 0.0 {
                    self.bass[root] / bass_sum
                } else {
                    0.0
                };
                scores[q * 12 + root] = dot / (norm * tnorm) + BASS_BONUS * bass - handicap;
            }
        }
        scores[N_CHORDS] = NO_CHORD;

        let best = scores.iter().cloned().fold(f32::MIN, f32::max) as f64;
        let mut total = 0.0;
        for (p, &s) in self.post.iter_mut().zip(&scores) {
            let prior = (1.0 - SWITCH) * *p + SWITCH / (N_CHORDS + 1) as f64;
            *p = prior * (KAPPA * (s as f64 - best)).exp();
            total += *p;
        }
        for p in self.post.iter_mut() {
            *p /= total;
        }
        let (i, _) = self
            .post
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.total_cmp(b.1))?;
        (i < N_CHORDS).then_some(i)
    }

    /// Best of the 24 keys for the long chroma (Pearson correlation with the
    /// Krumhansl–Kessler profiles), kept until another is clearly better.
    fn update_key(&mut self) {
        let mut best = Key {
            tonic: 0,
            minor: false,
            corr: f32::MIN,
        };
        let mut current = f32::MIN;
        for minor in [false, true] {
            let profile = if minor { &MINOR } else { &MAJOR };
            for tonic in 0..12 {
                let rotated: [f32; 12] = std::array::from_fn(|i| profile[(i + 12 - tonic) % 12]);
                let corr = pearson(&self.key_chroma, &rotated);
                if corr > best.corr {
                    best = Key { tonic, minor, corr };
                }
                if let Some(k) = &self.key {
                    if k.tonic == tonic && k.minor == minor {
                        current = corr;
                    }
                }
            }
        }
        match &mut self.key {
            Some(k) if best.corr < current + KEY_MARGIN => k.corr = current,
            _ if best.corr >= KEY_MIN => self.key = Some(best),
            _ => {}
        }
    }

    fn json(&self, chord: Option<usize>) -> String {
        let max = self.bars.iter().cloned().fold(0.0f32, f32::max);
        let bars: [f32; 12] = std::array::from_fn(|i| {
            if max > 0.0 {
                self.bars[i] / max * self.level
            } else {
                0.0
            }
        });
        let mut order: Vec<usize> = (0..12).collect();
        order.sort_by(|&a, &b| bars[b].total_cmp(&bars[a]));
        let flats = self
            .key
            .as_ref()
            .is_some_and(|k| uses_flats(k.tonic, k.minor));
        let names = if flats { &FLATS } else { &SHARPS };

        let key = self.key.as_ref().map(|k| {
            let scale = if k.minor { &MINOR_SCALE } else { &MAJOR_SCALE };
            serde_json::json!({
                "tonic": k.tonic,
                "minor": k.minor,
                "flats": flats,
                "scale": scale.iter().map(|i| (k.tonic + i) % 12).collect::<Vec<_>>(),
                "confidence": (k.corr * 100.0).round() / 100.0,
            })
        });
        let chord = chord.map(|c| {
            let (root, (suffix, ivs, _)) = (c % 12, QUALITIES[c / 12]);
            let tones: Vec<usize> = ivs.iter().map(|i| (root + i) % 12).collect();
            let mut name = format!("{}{suffix}", names[root]);
            // An inversion, when the bass clearly holds another chord tone.
            let sum: f32 = self.bass.iter().sum();
            let (low, share) = (0..12)
                .map(|i| (i, self.bass[i]))
                .max_by(|a, b| a.1.total_cmp(&b.1))
                .unwrap_or((root, 0.0));
            if sum > 0.0 && low != root && share / sum > 0.4 && tones.contains(&low) {
                name = format!("{name}/{}", names[low]);
            }
            serde_json::json!({ "name": name, "root": root, "tones": tones })
        });
        serde_json::json!({
            "chroma": bars.iter().map(|v| (v * 1000.0).round() / 1000.0).collect::<Vec<_>>(),
            "top": order[..3].iter().map(|&i| names[i]).collect::<Vec<_>>(),
            "chord": chord,
            "key": key,
            "tuning": self.tuning_cents().round() as i32,
        })
        .to_string()
    }
}

/// For each peak (sorted by frequency), the lowest partial it is a harmonic
/// of — itself when none.
fn owners(peaks: &[Peak]) -> Vec<usize> {
    let mut owner: Vec<usize> = (0..peaks.len()).collect();
    for j in 0..peaks.len() {
        'h: for h in 2..=8 {
            for q in 0..j {
                let ratio = peaks[j].freq / (h as f32 * peaks[q].freq);
                if (1200.0 * ratio.log2()).abs() < 25.0 && peaks[q].amp >= 0.1 * peaks[j].amp {
                    owner[j] = owner[q];
                    break 'h;
                }
            }
        }
    }
    owner
}

/// Exponential smoothing with time constant `tau`, for a hop of `dt`.
fn ema(state: &mut [f32; 12], x: &[f32; 12], dt: f32, tau: f32) {
    let k = 1.0 - (-dt / tau).exp();
    for (s, v) in state.iter_mut().zip(x) {
        *s += k * (v - *s);
    }
}

fn normalized(mut v: [f32; 12]) -> [f32; 12] {
    let sum: f32 = v.iter().sum();
    if sum > 0.0 {
        v.iter_mut().for_each(|x| *x /= sum);
    }
    v
}

fn pearson(a: &[f32; 12], b: &[f32; 12]) -> f32 {
    let (ma, mb) = (a.iter().sum::<f32>() / 12.0, b.iter().sum::<f32>() / 12.0);
    let (mut ab, mut aa, mut bb) = (0.0, 0.0, 0.0);
    for i in 0..12 {
        let (x, y) = (a[i] - ma, b[i] - mb);
        ab += x * y;
        aa += x * x;
        bb += y * y;
    }
    if aa <= 0.0 || bb <= 0.0 {
        return 0.0;
    }
    ab / (aa * bb).sqrt()
}

/// Keys written with flats: F, B♭, E♭, A♭, D♭ major and their relative minors.
fn uses_flats(tonic: usize, minor: bool) -> bool {
    let major = if minor { (tonic + 3) % 12 } else { tonic };
    matches!(major, 5 | 10 | 3 | 8 | 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::testbench::run as bench;
    use serde_json::Value;

    const SR: u32 = RATE;

    /// A note with 8 harmonics falling as 1/h — closer to an instrument than
    /// a sine, and the trap of the old analysis (its 3rd and 5th harmonics
    /// are a fifth and a third).
    fn tone(freq: f32, secs: f32) -> Vec<f32> {
        let n = (SR as f32 * secs) as usize;
        (0..n)
            .map(|i| {
                let t = i as f32 / SR as f32;
                (1..=8)
                    .map(|h| (std::f32::consts::TAU * freq * h as f32 * t).sin() / h as f32)
                    .sum::<f32>()
                    * 0.15
            })
            .collect()
    }

    fn mix(notes: &[f32], secs: f32) -> Vec<f32> {
        let voices: Vec<Vec<f32>> = notes.iter().map(|&f| tone(f, secs)).collect();
        (0..voices[0].len())
            .map(|i| voices.iter().map(|v| v[i]).sum::<f32>() / notes.len() as f32)
            .collect()
    }

    /// Frequency of `midi` with A4 at `a4`.
    fn hz(midi: i32, a4: f32) -> f32 {
        a4 * 2f32.powf((midi - 69) as f32 / 12.0)
    }

    fn last(signal: Vec<f32>) -> Value {
        let lines = bench(run, SR, signal);
        serde_json::from_str(lines.last().unwrap()).unwrap()
    }

    fn chord_name(v: &Value) -> String {
        v["chord"]["name"].as_str().unwrap_or("-").to_string()
    }

    #[test]
    fn a_lone_note_is_not_a_chord_of_its_harmonics() {
        let v = last(tone(hz(48, 440.0), 2.0)); // C3
        assert_eq!(v["top"][0], "C");
        let c = v["chroma"].as_array().unwrap();
        let (cc, g, e) = (
            c[0].as_f64().unwrap(),
            c[7].as_f64().unwrap(),
            c[4].as_f64().unwrap(),
        );
        assert!(g < 0.6 * cc && e < 0.6 * cc, "C {cc} G {g} E {e}");
    }

    #[test]
    fn triads_are_named() {
        let a = 440.0;
        for (notes, want) in [
            (vec![48, 52, 55], "C"),      // C E G
            (vec![57, 60, 64], "Am"),     // A C E
            (vec![55, 59, 62, 65], "G7"), // G B D F
            (vec![50, 53, 57], "Dm"),     // D F A
        ] {
            let f: Vec<f32> = notes.iter().map(|&m| hz(m, a)).collect();
            assert_eq!(chord_name(&last(mix(&f, 2.0))), want, "{notes:?}");
        }
    }

    #[test]
    fn a_detuned_recording_is_still_read_right() {
        // A = 432 Hz: 32 cents low, a third of the way to the next semitone.
        let f: Vec<f32> = [57, 60, 64].iter().map(|&m| hz(m, 432.0)).collect();
        let v = last(mix(&f, 4.0));
        assert_eq!(chord_name(&v), "Am");
        let t = v["tuning"].as_i64().unwrap();
        assert!((-40..=-24).contains(&t), "tuning {t}");
    }

    #[test]
    fn the_key_comes_from_the_progression() {
        let a = 440.0;
        let prog = |chords: &[[i32; 3]]| -> Vec<f32> {
            let mut s = Vec::new();
            for _ in 0..2 {
                for c in chords {
                    let f: Vec<f32> = c.iter().map(|&m| hz(m, a)).collect();
                    s.extend(mix(&f, 1.0));
                }
            }
            s
        };
        // C F G C
        let v = last(prog(&[
            [48, 52, 55],
            [53, 57, 60],
            [55, 59, 62],
            [48, 52, 55],
        ]));
        assert_eq!(
            (v["key"]["tonic"].as_u64(), v["key"]["minor"].as_bool()),
            (Some(0), Some(false))
        );
        // Dm Gm A Dm — written with flats.
        let v = last(prog(&[
            [50, 53, 57],
            [55, 58, 62],
            [57, 61, 64],
            [50, 53, 57],
        ]));
        assert_eq!(
            (v["key"]["tonic"].as_u64(), v["key"]["minor"].as_bool()),
            (Some(2), Some(true))
        );
        assert_eq!(v["key"]["flats"], true);
        assert_eq!(v["key"]["scale"], serde_json::json!([2, 4, 5, 7, 9, 10, 0]));
    }

    #[test]
    fn the_chord_follows_a_change_within_half_a_second() {
        let c: Vec<f32> = [48, 52, 55].iter().map(|&m| hz(m, 440.0)).collect();
        let f: Vec<f32> = [53, 57, 60].iter().map(|&m| hz(m, 440.0)).collect();
        let mut s = mix(&c, 2.0);
        s.extend(mix(&f, 0.5));
        assert_eq!(chord_name(&last(s)), "F");
    }

    #[test]
    fn noise_is_no_chord() {
        // A cheap LCG: white noise, no harmony in it.
        let mut x = 12345u32;
        let noise: Vec<f32> = (0..SR * 2)
            .map(|_| {
                x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (x >> 8) as f32 / (1 << 24) as f32 * 0.2 - 0.1
            })
            .collect();
        assert!(last(noise)["chord"].is_null());
    }

    #[test]
    fn silence_reports_and_the_bars_fall() {
        let lines = bench(run, SR, vec![0.0; SR as usize]);
        assert!(!lines.is_empty());
        let v: Value = serde_json::from_str(lines.last().unwrap()).unwrap();
        assert!(v["chroma"].as_array().unwrap().iter().all(|x| x == 0.0));
        assert!(v["chord"].is_null() && v["key"].is_null());
    }

    #[test]
    fn flat_keys() {
        assert!(uses_flats(5, false)); // F
        assert!(uses_flats(2, true)); // D minor
        assert!(!uses_flats(7, false)); // G
        assert!(!uses_flats(9, true)); // A minor
    }
}
