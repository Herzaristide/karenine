//! A whisper.cpp server kept warm while the user speaks, so the transcript
//! can follow the voice: the recording so far is transcribed again every
//! half second, which only works if each pass is quick. On a discrete GPU
//! (Vulkan) a pass over a sentence takes about a tenth of a second.
//!
//! The server starts with the first word said and stops after a while
//! without use: a GPU context kept open would keep the discrete GPU of a
//! laptop awake. Its first start ever compiles the GPU shaders (~15 s, then
//! cached by the driver); later starts take under a second.
//!
//! Without a discrete GPU it runs on the processor (about 2 s a pass): the
//! transcript then follows the voice less closely, nothing more.

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Stop the server after this long without a request.
pub const IDLE: Duration = Duration::from_secs(10 * 60);
/// How long a start may take (model load, shader compilation).
const START_WITHIN: Duration = Duration::from_secs(45);

/// The ggml Vulkan index of the first discrete GPU, as `vulkaninfo` lists
/// devices (ggml enumerates them in the same order, minus CPU devices).
pub fn discrete_gpu(vulkaninfo_summary: &str) -> Option<usize> {
    let mut index = 0usize;
    let mut in_gpu = false;
    for line in vulkaninfo_summary.lines() {
        let l = line.trim();
        if l.starts_with("GPU") && l.ends_with(':') {
            in_gpu = true;
            continue;
        }
        if in_gpu {
            if let Some(kind) = l
                .strip_prefix("deviceType")
                .map(|r| r.trim_start_matches([' ', '=']))
            {
                in_gpu = false;
                if kind.contains("CPU") {
                    continue;
                }
                if kind.contains("DISCRETE_GPU") {
                    return Some(index);
                }
                index += 1;
            }
        }
    }
    None
}

fn gpu_args() -> Vec<String> {
    let summary = Command::new("vulkaninfo")
        .arg("--summary")
        .stderr(Stdio::null())
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    match discrete_gpu(&summary) {
        Some(i) => vec!["-dev".into(), i.to_string()],
        None => vec!["-ng".into()],
    }
}

/// A multipart POST of a WAV to `/inference`; whisper.cpp's JSON answer.
fn post(port: u16, wav: &[u8]) -> std::io::Result<String> {
    let boundary = "anna-whisper-7f3a9c";
    let mut body = Vec::with_capacity(wav.len() + 512);
    body.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voix.wav\"\r\n\
             Content-Type: audio/wav\r\n\r\n"
        )
        .as_bytes(),
    );
    body.extend_from_slice(wav);
    body.extend_from_slice(
        format!(
            "\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n\
             --{boundary}--\r\n"
        )
        .as_bytes(),
    );
    let mut s = TcpStream::connect(SocketAddr::from(([127, 0, 0, 1], port)))?;
    s.set_read_timeout(Some(Duration::from_secs(60)))?;
    write!(
        s,
        "POST /inference HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: multipart/form-data; boundary={boundary}\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    s.write_all(&body)?;
    let mut resp = Vec::new();
    s.read_to_end(&mut resp)?;
    let resp = String::from_utf8_lossy(&resp);
    let (head, body) = resp
        .split_once("\r\n\r\n")
        .ok_or_else(|| std::io::Error::other("réponse HTTP illisible"))?;
    if !head.starts_with("HTTP/1.1 200") && !head.starts_with("HTTP/1.0 200") {
        return Err(std::io::Error::other(
            head.lines().next().unwrap_or("").to_string(),
        ));
    }
    Ok(body.to_string())
}

pub struct Server {
    child: Child,
    port: u16,
    pub last_use: Instant,
    /// The language it transcribes (`fr`, `auto`…).
    pub lang: String,
}

impl Server {
    /// Start whisper-server on a free local port and wait until it answers.
    pub fn start(model: &std::path::Path, prompt: &str, lang: &str) -> Result<Server, String> {
        let port = TcpListener::bind("127.0.0.1:0")
            .and_then(|l| l.local_addr())
            .map(|a| a.port())
            .map_err(|e| format!("port : {e}"))?;
        let threads = std::thread::available_parallelism()
            .map(|n| n.get().min(8))
            .unwrap_or(4)
            .to_string();
        let mut child = Command::new("whisper-server")
            .arg("-m")
            .arg(model)
            .args(["-l", lang, "--prompt", prompt, "-t", &threads])
            .args(["--host", "127.0.0.1", "--port", &port.to_string()])
            .args(gpu_args())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("whisper-server : {e}"))?;
        let deadline = Instant::now() + START_WITHIN;
        loop {
            if let Ok(Some(status)) = child.try_wait() {
                return Err(crate::i18n::tr_args(
                    "whisper.stopped",
                    &[("status", &status.to_string())],
                ));
            }
            if TcpStream::connect(SocketAddr::from(([127, 0, 0, 1], port))).is_ok() {
                break;
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                return Err(crate::i18n::tr("whisper.no_answer"));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        let mut server = Server {
            child,
            port,
            last_use: Instant::now(),
            lang: lang.to_string(),
        };
        // Warm-up: the first pass compiles the GPU shaders (or loads them
        // from the driver's cache). Better now than on the user's first word.
        let _ = server.transcribe(&super::voice::wav(&vec![0.0; 16_000], 16_000));
        Ok(server)
    }

    pub fn alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    /// Transcribe a 16 kHz mono WAV.
    pub fn transcribe(&mut self, wav: &[u8]) -> Result<String, String> {
        self.last_use = Instant::now();
        let body = post(self.port, wav).map_err(|e| format!("whisper-server : {e}"))?;
        let v: serde_json::Value =
            serde_json::from_str(&body).map_err(|e| format!("whisper-server : {e}"))?;
        let text = v.get("text").and_then(|t| t.as_str()).unwrap_or("");
        Ok(super::voice::clean_transcript(text))
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // `vulkaninfo --summary` on this laptop (2026-10-15).
    const ZOLA: &str = "GPU0:\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n\tdeviceName         = Intel(R) UHD Graphics (TGL GT1)\nGPU1:\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n\tdeviceName         = NVIDIA GeForce RTX 3070 Laptop GPU\nGPU2:\n\tdeviceType         = PHYSICAL_DEVICE_TYPE_CPU\n\tdeviceName         = llvmpipe\n";

    #[test]
    fn picks_the_discrete_gpu() {
        assert_eq!(discrete_gpu(ZOLA), Some(1));
        // A software device listed first doesn't shift ggml's numbering.
        let cpu_first = "GPU0:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_CPU\nGPU1:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n";
        assert_eq!(discrete_gpu(cpu_first), Some(0));
        assert_eq!(
            discrete_gpu("GPU0:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU\n"),
            None
        );
        assert_eq!(discrete_gpu(""), None);
    }
}
