//! Sample-accurate metronome — native port of `backend/metronome.sh`.
//!
//! A single cpal output stream owns both timing and audio: its callback fills
//! every frame from a sample counter, so beat spacing is exact (paced by the
//! hardware sample clock, no wall-clock sleep, no scheduler jitter). Clicks are
//! synthesized once (a bright accent on beat 0, a softer tick otherwise) and
//! mixed in at the start of each beat. BPM / beats-per-bar are read from atomics
//! on every beat boundary, so control changes take effect on the next beat.
//!
//! Control is driven by the daemon's `metronome` handler: `start(bpm)`,
//! `stop_playing()`, `set_bpm()`, `set_beats()`. Beat indices are pushed back
//! over a channel and forwarded to the client as `{"beat":<n>}` lines.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::f32::consts::PI;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;

/// Handle to a running metronome. Dropping it stops the output stream.
pub struct MetroHandle {
    bpm: Arc<AtomicU32>,
    beats: Arc<AtomicU32>,
    running: Arc<AtomicBool>,
    start_flag: Arc<AtomicBool>,
    beats_rx: Option<Receiver<i32>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for MetroHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }
}

impl MetroHandle {
    /// (Re)start ticking at `bpm`, firing beat 0 immediately.
    pub fn start(&self, bpm: u32) {
        self.bpm.store(bpm.max(20), Ordering::Relaxed);
        self.running.store(true, Ordering::Relaxed);
        self.start_flag.store(true, Ordering::Relaxed);
    }
    pub fn stop_playing(&self) {
        self.running.store(false, Ordering::Relaxed);
    }
    pub fn set_bpm(&self, v: u32) {
        self.bpm.store(v.max(20), Ordering::Relaxed);
    }
    pub fn set_beats(&self, v: u32) {
        self.beats.store(v.max(1), Ordering::Relaxed);
    }
    /// Take the beat-event receiver (once), to bridge it to the socket writer.
    pub fn take_beats(&mut self) -> Option<Receiver<i32>> {
        self.beats_rx.take()
    }
}

/// Open the default output device and start a (silent, not yet ticking) stream.
pub fn start() -> Result<MetroHandle, String> {
    let bpm = Arc::new(AtomicU32::new(120));
    let beats = Arc::new(AtomicU32::new(4));
    let running = Arc::new(AtomicBool::new(false));
    let start_flag = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));
    let (beat_tx, beats_rx) = std::sync::mpsc::channel::<i32>();

    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();

    let thread = {
        let bpm = Arc::clone(&bpm);
        let beats = Arc::clone(&beats);
        let running = Arc::clone(&running);
        let start_flag = Arc::clone(&start_flag);
        let stop = Arc::clone(&stop);
        std::thread::spawn(move || {
            let stream = match build_output_stream(bpm, beats, running, start_flag, beat_tx) {
                Ok(s) => {
                    let _ = ready_tx.send(Ok(()));
                    s
                }
                Err(e) => {
                    let _ = ready_tx.send(Err(e));
                    return;
                }
            };
            if let Err(e) = stream.play() {
                eprintln!("anna: metronome: stream.play failed: {e}");
                return;
            }
            while !stop.load(Ordering::SeqCst) {
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
        })
    };

    match ready_rx.recv() {
        Ok(Ok(())) => Ok(MetroHandle {
            bpm,
            beats,
            running,
            start_flag,
            beats_rx: Some(beats_rx),
            stop,
            thread: Some(thread),
        }),
        Ok(Err(e)) => Err(e),
        Err(_) => Err("metronome thread died during init".into()),
    }
}

/// Per-callback beat generator. Owns the mutable playback cursor; the atomics
/// carry live control from the socket handler.
struct Gen {
    accent: Vec<f32>,
    normal: Vec<f32>,
    sample_rate: u32,
    bpm: Arc<AtomicU32>,
    beats: Arc<AtomicU32>,
    running: Arc<AtomicBool>,
    start_flag: Arc<AtomicBool>,
    beat_tx: Sender<i32>,
    pos: usize,           // samples elapsed in the current beat
    spb: usize,           // samples per beat (recomputed each boundary)
    beat_index: i32,      // current beat within the bar
    click_is_accent: bool,
    click_cursor: usize,  // index into the active click buffer
}

impl Gen {
    fn samples_per_beat(&self) -> usize {
        (self.sample_rate as usize * 60 / self.bpm.load(Ordering::Relaxed).max(1) as usize).max(1)
    }

    /// Produce the next mono sample and advance state.
    fn next_sample(&mut self) -> f32 {
        // A start request resets to beat 0 and fires it immediately.
        if self.start_flag.swap(false, Ordering::Relaxed) {
            self.pos = 0;
            self.beat_index = 0;
            self.spb = self.samples_per_beat();
            self.click_is_accent = true;
            self.click_cursor = 0;
            let _ = self.beat_tx.send(0);
        }

        if !self.running.load(Ordering::Relaxed) {
            return 0.0;
        }

        // Beat boundary: advance the index and re-arm the click.
        if self.pos >= self.spb {
            self.pos = 0;
            let nb = self.beats.load(Ordering::Relaxed).max(1) as i32;
            self.beat_index = (self.beat_index + 1) % nb;
            self.spb = self.samples_per_beat();
            self.click_is_accent = self.beat_index == 0;
            self.click_cursor = 0;
            let _ = self.beat_tx.send(self.beat_index);
        }

        let buf = if self.click_is_accent {
            &self.accent
        } else {
            &self.normal
        };
        let s = buf.get(self.click_cursor).copied().unwrap_or(0.0);
        self.click_cursor = self.click_cursor.saturating_add(1);
        self.pos += 1;
        s
    }
}

fn build_output_stream(
    bpm: Arc<AtomicU32>,
    beats: Arc<AtomicU32>,
    running: Arc<AtomicBool>,
    start_flag: Arc<AtomicBool>,
    beat_tx: Sender<i32>,
) -> Result<cpal::Stream, String> {
    let host = cpal::default_host();
    let device = host
        .default_output_device()
        .ok_or_else(|| "no default output device".to_string())?;
    let config = device
        .default_output_config()
        .map_err(|e| format!("default_output_config: {e}"))?;

    let sample_rate = config.sample_rate().0;
    let channels = config.channels() as usize;
    let sample_format = config.sample_format();
    let stream_config: cpal::StreamConfig = config.into();
    let err_fn = |e| eprintln!("anna: metronome: output stream error: {e}");

    let mut metro = Gen {
        accent: synth_click(sample_rate, 1760.0, 0.045, 0.001, 0.030, 0.708),
        normal: synth_click(sample_rate, 880.0, 0.035, 0.001, 0.025, 0.501),
        sample_rate,
        bpm,
        beats,
        running,
        start_flag,
        beat_tx,
        pos: 0,
        spb: sample_rate as usize / 2,
        beat_index: 0,
        click_is_accent: true,
        click_cursor: usize::MAX, // start finished (silent) until first beat
    };

    let stream = match sample_format {
        cpal::SampleFormat::F32 => device.build_output_stream(
            &stream_config,
            move |data: &mut [f32], _: &_| {
                for frame in data.chunks_mut(channels) {
                    let s = metro.next_sample();
                    for out in frame.iter_mut() {
                        *out = s;
                    }
                }
            },
            err_fn,
            None,
        ),
        cpal::SampleFormat::I16 => device.build_output_stream(
            &stream_config,
            move |data: &mut [i16], _: &_| {
                for frame in data.chunks_mut(channels) {
                    let s = (metro.next_sample().clamp(-1.0, 1.0) * 32767.0) as i16;
                    for out in frame.iter_mut() {
                        *out = s;
                    }
                }
            },
            err_fn,
            None,
        ),
        cpal::SampleFormat::U16 => device.build_output_stream(
            &stream_config,
            move |data: &mut [u16], _: &_| {
                for frame in data.chunks_mut(channels) {
                    let v = ((metro.next_sample().clamp(-1.0, 1.0) * 0.5 + 0.5) * 65535.0) as u16;
                    for out in frame.iter_mut() {
                        *out = v;
                    }
                }
            },
            err_fn,
            None,
        ),
        other => return Err(format!("unsupported output sample format: {other:?}")),
    }
    .map_err(|e| format!("build_output_stream: {e}"))?;

    Ok(stream)
}

/// Synthesize a click: a sine at `freq` over `dur_s` with linear attack/release
/// ramps, scaled by `gain` (linear amplitude). Mirrors the sox-generated clicks
/// the shell backend used (1760 Hz accent, 880 Hz tick).
fn synth_click(sample_rate: u32, freq: f32, dur_s: f32, attack_s: f32, release_s: f32, gain: f32) -> Vec<f32> {
    let n = (sample_rate as f32 * dur_s) as usize;
    let atk = (sample_rate as f32 * attack_s).max(1.0);
    let rel = (sample_rate as f32 * release_s).max(1.0);
    (0..n)
        .map(|i| {
            let t = i as f32 / sample_rate as f32;
            let mut env = 1.0f32;
            if (i as f32) < atk {
                env = i as f32 / atk;
            }
            let from_end = (n - i) as f32;
            if from_end < rel {
                env = env.min(from_end / rel);
            }
            gain * env * (2.0 * PI * freq * t).sin()
        })
        .collect()
}
