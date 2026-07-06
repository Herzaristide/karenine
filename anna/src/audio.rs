//! Native audio helpers shared by the tuner, chroma and metronome services.
//!
//! `cpal::Stream` is `!Send`, so a stream must be built and kept alive on a
//! single dedicated OS thread. `start_capture` does exactly that: it opens the
//! default input device, converts every callback buffer to mono `f32`, and
//! forwards it over a channel. Each audio service opens its own capture — the
//! system's audio server (PipeWire) multiplexes capture clients, exactly like
//! the several concurrent `parec` processes the old shell backends used.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;

/// A live microphone capture. Dropping it stops the underlying cpal stream.
pub struct Capture {
    /// Actual capture sample rate reported by the device (e.g. 48000). The DSP
    /// services derive all their frequency math from this, so no resampling is
    /// needed regardless of what the hardware runs at.
    pub sample_rate: u32,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(h) = self.thread.take() {
            let _ = h.join();
        }
    }
}

/// Open the default input device and start streaming mono `f32` samples.
///
/// Returns the `Capture` handle (keep it alive to keep recording) and the
/// receiver end of the mono sample stream. Each callback pushes one `Vec<f32>`
/// chunk; when the capture is dropped the sender closes and the receiver's
/// `recv()` returns `Err`, which the DSP loops use as their stop signal.
pub fn start_capture() -> Result<(Capture, Receiver<Vec<f32>>), String> {
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = Arc::clone(&stop);
    let (sample_tx, sample_rx) = std::sync::mpsc::channel::<Vec<f32>>();
    // Report the negotiated sample rate (or an init error) back to this call.
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<u32, String>>();

    let thread = std::thread::spawn(move || {
        let stream = match build_input_stream(sample_tx) {
            Ok((stream, sr)) => {
                let _ = ready_tx.send(Ok(sr));
                stream
            }
            Err(e) => {
                let _ = ready_tx.send(Err(e));
                return;
            }
        };
        if let Err(e) = stream.play() {
            eprintln!("anna: audio: stream.play failed: {e}");
            return;
        }
        // Keep the stream alive until the Capture handle is dropped.
        while !stop_thread.load(Ordering::SeqCst) {
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        // `stream` drops here, closing the device and the sample channel.
    });

    match ready_rx.recv() {
        Ok(Ok(sample_rate)) => Ok((
            Capture {
                sample_rate,
                stop,
                thread: Some(thread),
            },
            sample_rx,
        )),
        Ok(Err(e)) => Err(e),
        Err(_) => Err("audio capture thread died during init".into()),
    }
}

/// Build (but do not start) an input stream on the default device, downmixing
/// to mono `f32`. Returns the stream and its sample rate.
fn build_input_stream(tx: Sender<Vec<f32>>) -> Result<(cpal::Stream, u32), String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "no default input device".to_string())?;
    let config = device
        .default_input_config()
        .map_err(|e| format!("default_input_config: {e}"))?;

    let sample_rate = config.sample_rate().0;
    let channels = config.channels() as usize;
    let sample_format = config.sample_format();
    let stream_config: cpal::StreamConfig = config.into();
    let err_fn = |e| eprintln!("anna: audio: input stream error: {e}");

    // Sum channels to mono (matches the old backends: summing keeps the full
    // level of whichever hardware channel the mic is on, no attenuation).
    let stream = match sample_format {
        cpal::SampleFormat::F32 => device.build_input_stream(
            &stream_config,
            move |data: &[f32], _: &_| {
                let _ = tx.send(downmix(data, channels, |s| s));
            },
            err_fn,
            None,
        ),
        cpal::SampleFormat::I16 => device.build_input_stream(
            &stream_config,
            move |data: &[i16], _: &_| {
                let _ = tx.send(downmix(data, channels, |s| s as f32 / 32768.0));
            },
            err_fn,
            None,
        ),
        cpal::SampleFormat::U16 => device.build_input_stream(
            &stream_config,
            move |data: &[u16], _: &_| {
                let _ = tx.send(downmix(data, channels, |s| (s as f32 - 32768.0) / 32768.0));
            },
            err_fn,
            None,
        ),
        other => return Err(format!("unsupported input sample format: {other:?}")),
    }
    .map_err(|e| format!("build_input_stream: {e}"))?;

    Ok((stream, sample_rate))
}

/// Downmix an interleaved multi-channel buffer to mono by summing channels,
/// converting each sample to `f32` with `conv`.
fn downmix<T: Copy>(data: &[T], channels: usize, conv: impl Fn(T) -> f32) -> Vec<f32> {
    if channels <= 1 {
        return data.iter().map(|&s| conv(s)).collect();
    }
    data.chunks(channels)
        .map(|frame| frame.iter().map(|&s| conv(s)).sum())
        .collect()
}

/// Smallest power of two `>= n` (used to size FFT windows from a duration).
pub fn next_pow2(n: usize) -> usize {
    let mut p = 1;
    while p < n {
        p <<= 1;
    }
    p
}

/// Hann window of length `n` (matches NumPy's `np.hanning`).
pub fn hann(n: usize) -> Vec<f32> {
    if n <= 1 {
        return vec![1.0; n];
    }
    (0..n)
        .map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / (n as f32 - 1.0)).cos())
        .collect()
}
