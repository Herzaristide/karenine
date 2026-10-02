//! Webcam capture through an `ffmpeg` subprocess.
//!
//! ffmpeg does the V4L2 negotiation and the MJPEG decode and hands us packed
//! RGB24 frames on stdout — no bindgen'd V4L2 bindings, no JPEG decoder in the
//! binary. Killing the process is also what releases the device, so the
//! camera LED goes off the moment gestures are disabled.
//!
//! A reader thread drains the pipe continuously and keeps only the newest
//! frame. Without it, any frame the vision loop is too slow to consume would
//! queue up in the pipe and the cursor would lag further behind the hand
//! with every dropped beat.

use std::io::{self, Read};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

pub const WIDTH: usize = 640;
pub const HEIGHT: usize = 360;
const FRAME_BYTES: usize = WIDTH * HEIGHT * 3;

struct Slot {
    frame: Option<Vec<u8>>,
    closed: bool,
}

pub struct Camera {
    child: Child,
    slot: Arc<(Mutex<Slot>, Condvar)>,
}

impl Camera {
    pub fn open(device: &str) -> io::Result<Self> {
        let ffmpeg = std::env::var("FFMPEG").unwrap_or_else(|_| "ffmpeg".into());
        let mut child = Command::new(ffmpeg)
            .args(["-hide_banner", "-loglevel", "error", "-nostdin"])
            .args(["-f", "v4l2", "-input_format", "mjpeg", "-framerate", "30"])
            .args(["-video_size", &format!("{WIDTH}x{HEIGHT}"), "-i", device])
            .args(["-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;

        let mut stdout = child.stdout.take().expect("piped stdout");
        let slot = Arc::new((
            Mutex::new(Slot {
                frame: None,
                closed: false,
            }),
            Condvar::new(),
        ));

        let reader_slot = Arc::clone(&slot);
        std::thread::spawn(move || {
            let (lock, cvar) = &*reader_slot;
            loop {
                let mut buf = vec![0u8; FRAME_BYTES];
                if stdout.read_exact(&mut buf).is_err() {
                    lock.lock().unwrap().closed = true;
                    cvar.notify_all();
                    return;
                }
                lock.lock().unwrap().frame = Some(buf);
                cvar.notify_all();
            }
        });

        Ok(Self { child, slot })
    }

    /// Block until a frame newer than the last one returned is available.
    /// Errors once ffmpeg has exited (device unplugged, busy, wrong format…).
    pub fn next_frame(&self) -> io::Result<Vec<u8>> {
        let (lock, cvar) = &*self.slot;
        let mut slot = lock.lock().unwrap();
        loop {
            if let Some(frame) = slot.frame.take() {
                return Ok(frame);
            }
            if slot.closed {
                return Err(io::Error::new(
                    io::ErrorKind::BrokenPipe,
                    "camera stream ended (see ffmpeg error above)",
                ));
            }
            let (s, timeout) = cvar.wait_timeout(slot, Duration::from_secs(3)).unwrap();
            slot = s;
            if timeout.timed_out() && slot.frame.is_none() {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "no frame for 3 s"));
            }
        }
    }
}

impl Drop for Camera {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
