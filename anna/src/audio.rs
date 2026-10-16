//! Native audio helpers shared by the tuner, chroma and metronome services.
//!
//! `cpal::Stream` is `!Send`, so a stream must be built and kept alive on a
//! single dedicated OS thread. `start_capture` does exactly that: it opens the
//! default input device, converts every callback buffer to mono `f32`, and
//! forwards it over a channel. Each audio service opens its own capture — the
//! system's audio server (PipeWire) multiplexes capture clients, exactly like
//! the several concurrent `parec` processes the old shell backends used.
//! The voice assistant instead reads the echo-cancelled mic through
//! `pw-record` (`start_voice_capture`): cpal cannot pick a PipeWire node.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::Arc;
use std::thread::JoinHandle;

/// A live microphone capture. Dropping it stops the underlying cpal stream
/// (or `pw-record` process).
pub struct Capture {
    /// Actual capture sample rate reported by the device (e.g. 48000). The DSP
    /// services derive all their frequency math from this, so no resampling is
    /// needed regardless of what the hardware runs at.
    pub sample_rate: u32,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    child: Option<Child>,
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Killing pw-record closes its pipe, which ends the reading thread.
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
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
                child: None,
            },
            sample_rx,
        )),
        Ok(Err(e)) => Err(e),
        Err(_) => Err("audio capture thread died during init".into()),
    }
}

/// The microphone the voice assistant listens to (`ANNA_VOICE_NODE`): the
/// echo-cancelled source of `modules/audio.nix`, from which PipeWire removes
/// what the speakers play — « Karénine » is heard over music or a video, and
/// a video saying it does not wake anna. Music services keep the raw mic.
fn voice_node() -> String {
    std::env::var("ANNA_VOICE_NODE").unwrap_or_else(|_| "echo-cancel-source".into())
}

/// Like `start_capture`, but from the voice node, at 16 kHz. PipeWire falls
/// back to the default mic when the node does not exist; without `pw-record`,
/// the default device is opened directly.
pub fn start_voice_capture() -> Result<(Capture, Receiver<Vec<f32>>), String> {
    start_node_capture(&voice_node(), 16000).or_else(|e| {
        eprintln!("anna: audio: {e}, micro par défaut");
        start_capture()
    })
}

/// Mono `f32` samples from a PipeWire node, read from a `pw-record` child.
fn start_node_capture(node: &str, rate: u32) -> Result<(Capture, Receiver<Vec<f32>>), String> {
    let mut child = Command::new("pw-record")
        .args(["--raw", "--target", node, "--format", "f32", "--channels", "1"])
        .args(["--rate", &rate.to_string(), "-"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("pw-record: {e}"))?;
    let mut out = child.stdout.take().ok_or("pw-record: pas de sortie")?;
    let stop = Arc::new(AtomicBool::new(false));
    let stop_thread = Arc::clone(&stop);
    let (sample_tx, sample_rx) = std::sync::mpsc::channel::<Vec<f32>>();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<()>();
    let thread = std::thread::spawn(move || {
        // 100 ms per chunk, like a cpal callback at PipeWire's default quantum.
        let mut buf = vec![0u8; rate as usize / 10 * 4];
        while !stop_thread.load(Ordering::SeqCst) && out.read_exact(&mut buf).is_ok() {
            let _ = ready_tx.send(());
            let chunk = buf
                .chunks_exact(4)
                .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                .collect();
            if sample_tx.send(chunk).is_err() {
                break;
            }
        }
    });
    let capture = Capture {
        sample_rate: rate,
        stop,
        thread: Some(thread),
        child: Some(child),
    };
    // A first chunk proves the stream works; otherwise fall back (dropping
    // `capture` kills the child and joins the thread).
    match ready_rx.recv_timeout(std::time::Duration::from_secs(2)) {
        Ok(()) => Ok((capture, sample_rx)),
        Err(_) => Err(format!("pw-record --target {node} : aucun son")),
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

/// Test bench for the mic DSP loops (`tuner::run`, `chroma::run`): feed them a
/// synthetic signal in capture-sized chunks and collect every line they emit.
#[cfg(test)]
pub mod testbench {
    pub type Dsp = fn(u32, std::sync::mpsc::Receiver<Vec<f32>>, tokio::sync::mpsc::Sender<String>);

    pub fn run(dsp: Dsp, sample_rate: u32, signal: Vec<f32>) -> Vec<String> {
        let (audio_tx, audio_rx) = std::sync::mpsc::channel();
        let (line_tx, mut line_rx) = tokio::sync::mpsc::channel(1024);
        let worker = std::thread::spawn(move || dsp(sample_rate, audio_rx, line_tx));
        for chunk in signal.chunks(480) {
            audio_tx.send(chunk.to_vec()).unwrap();
        }
        drop(audio_tx); // the DSP returns once the capture "stops"
        let mut lines = Vec::new();
        while let Some(l) = line_rx.blocking_recv() {
            lines.push(l);
        }
        worker.join().unwrap();
        lines
    }

    /// `secs` of a sine at `freq` Hz, amplitude 0.5.
    pub fn sine(freq: f32, sample_rate: u32, secs: f32) -> Vec<f32> {
        let n = (sample_rate as f32 * secs) as usize;
        (0..n)
            .map(|i| {
                0.5 * (2.0 * std::f32::consts::PI * freq * i as f32 / sample_rate as f32).sin()
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_pow2_rounds_up() {
        assert_eq!(next_pow2(0), 1);
        assert_eq!(next_pow2(1), 1);
        assert_eq!(next_pow2(1000), 1024);
        assert_eq!(next_pow2(1024), 1024);
        assert_eq!(next_pow2(1025), 2048);
    }

    #[test]
    fn hann_is_symmetric_and_zero_at_edges() {
        let w = hann(64);
        assert_eq!(w.len(), 64);
        assert!(w[0].abs() < 1e-6 && w[63].abs() < 1e-6);
        for i in 0..32 {
            assert!((w[i] - w[63 - i]).abs() < 1e-5);
        }
        assert_eq!(hann(1), vec![1.0]);
        assert!(hann(0).is_empty());
    }
}
