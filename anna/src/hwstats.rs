//! Native hardware-stats collector — replaces the per-widget shell-outs that
//! `widgets/HardwareStats.qml` used to spawn every second (cpuinfo, /proc/stat,
//! meminfo, dmidecode, nvidia-smi/amdgpu sysfs, hwmon temps).
//!
//! A `Collector` keeps the previous /proc/stat totals for the CPU-usage
//! delta. What never changes (CPU model, RAM brand, GPU name) is read once
//! for the daemon's lifetime, and the GPU reading is shared by every
//! collector: the widget and the lock screen watching at once cost one
//! `nvidia-smi`, not two. `sample()` returns a fully-populated `HwStats`
//! snapshot, serialized as one JSON line by the daemon's `hwstats_watch`
//! handler.
//!
//! GPU: a laptop's NVIDIA card sleeps (runtime D3) when unused, and
//! `nvidia-smi` wakes it — 1.8 s for the call, then ~22 s awake. Read every
//! second, it would never sleep again. So a suspended card is only reported
//! asleep (one sysfs read), and an idle one is read again only after
//! `GPU_IDLE_EVERY`, long enough for it to suspend in between; a busy one
//! (in use anyway) is read every `GPU_BUSY_EVERY`.

use serde::Serialize;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

const GPU_BUSY_EVERY: Duration = Duration::from_secs(1);
/// Longer than the driver's ~22 s before it suspends an unused card.
const GPU_IDLE_EVERY: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Default)]
struct GpuReading {
    /// Live utilization/memory data is available (not just a name).
    present: bool,
    /// The card is suspended: nothing was read, so as not to wake it.
    asleep: bool,
    usage: u8,
    mem_used: u64,
    mem_total: u64,
    temp: u32,
}

// ── Snapshot payload (JSON sent to Quickshell) ──────────────────────────────

#[derive(Serialize, Default, Clone)]
pub struct HwStats {
    pub cpu_name: String,
    pub cpu_usage: u8,
    /// °C, 0 when unknown.
    pub cpu_temp: u32,

    /// Bytes.
    pub ram_total: u64,
    pub ram_used: u64,
    pub ram_brand: String,

    pub gpu_name: String,
    /// True when live utilization/memory data is available (not just a name).
    pub gpu_present: bool,
    /// The card sleeps (left alone so that it keeps sleeping).
    pub gpu_asleep: bool,
    pub gpu_usage: u8,
    pub gpu_mem_used_mib: u64,
    pub gpu_mem_total_mib: u64,
    pub gpu_temp: u32,
}

// ── Collector ───────────────────────────────────────────────────────────────

pub struct Collector {
    prev_cpu_total: u64,
    prev_cpu_active: u64,
}

impl Collector {
    pub fn new() -> Self {
        Self {
            prev_cpu_total: 0,
            prev_cpu_active: 0,
        }
    }

    pub fn sample(&mut self) -> HwStats {
        let cpu_usage = self.cpu_usage();
        let (ram_total, ram_used) = read_ram();
        let gpu = gpu_cached();
        let (cpu_temp, gpu_temp_hwmon) = read_temps();

        HwStats {
            cpu_name: cpu_name().to_string(),
            cpu_usage,
            cpu_temp,
            ram_total,
            ram_used,
            ram_brand: ram_brand().to_string(),
            gpu_name: gpu_name().to_string(),
            gpu_present: gpu.present,
            gpu_asleep: gpu.asleep,
            gpu_usage: gpu.usage,
            gpu_mem_used_mib: gpu.mem_used,
            gpu_mem_total_mib: gpu.mem_total,
            // Prefer the amdgpu hwmon reading; fall back to nvidia-smi's value.
            gpu_temp: if gpu_temp_hwmon > 0 {
                gpu_temp_hwmon
            } else {
                gpu.temp
            },
        }
    }

    // ── CPU ────────────────────────────────────────────────────────────────

    /// Instantaneous CPU usage in percent, from the delta of /proc/stat between
    /// this call and the previous one. Returns 0 on the first sample.
    fn cpu_usage(&mut self) -> u8 {
        let stat = match fs::read_to_string("/proc/stat") {
            Ok(s) => s,
            Err(_) => return 0,
        };
        let line = stat.lines().next().unwrap_or("");
        let vals: Vec<u64> = line
            .split_whitespace()
            .skip(1) // "cpu"
            .filter_map(|v| v.parse::<u64>().ok())
            .collect();
        if vals.len() < 5 {
            return 0;
        }
        let user = vals[0];
        let nice = vals[1];
        let system = vals[2];
        let idle = vals[3];
        let iowait = vals[4];
        let irq = vals.get(5).copied().unwrap_or(0);
        let softirq = vals.get(6).copied().unwrap_or(0);
        let total = user + nice + system + idle + iowait + irq + softirq;
        let active = total.saturating_sub(idle).saturating_sub(iowait);

        let usage = if self.prev_cpu_total > 0 {
            let d_total = total.saturating_sub(self.prev_cpu_total);
            let d_active = active.saturating_sub(self.prev_cpu_active);
            if d_total > 0 {
                ((d_active as f64 / d_total as f64) * 100.0).round() as u8
            } else {
                0
            }
        } else {
            0
        };
        self.prev_cpu_total = total;
        self.prev_cpu_active = active;
        usage.min(100)
    }
}

// ── Read once ───────────────────────────────────────────────────────────────

fn cpu_name() -> &'static str {
    static NAME: OnceLock<String> = OnceLock::new();
    NAME.get_or_init(|| {
        fs::read_to_string("/proc/cpuinfo")
            .ok()
            .and_then(|c| {
                c.lines()
                    .find(|l| l.starts_with("model name"))
                    .and_then(|l| l.split(':').nth(1))
                    .map(|s| s.trim().to_string())
            })
            .unwrap_or_default()
    })
}

/// `sudo dmidecode`, once.
fn ram_brand() -> &'static str {
    static BRAND: OnceLock<String> = OnceLock::new();
    BRAND.get_or_init(read_ram_brand)
}

/// From `nvidia-smi` when it answered once, else `lspci` (once).
fn gpu_name() -> &'static str {
    if let Some(name) = NVIDIA_NAME.get() {
        return name;
    }
    static LSPCI: OnceLock<String> = OnceLock::new();
    LSPCI.get_or_init(gpu_name_from_lspci)
}

static NVIDIA_NAME: OnceLock<String> = OnceLock::new();

/// The NVIDIA display controller's sysfs directory, if there is one.
fn nvidia_device() -> Option<&'static PathBuf> {
    static DEV: OnceLock<Option<PathBuf>> = OnceLock::new();
    DEV.get_or_init(|| {
        fs::read_dir("/sys/bus/pci/devices")
            .ok()?
            .flatten()
            .map(|e| e.path())
            .find(|d| {
                let read = |f: &str| fs::read_to_string(d.join(f)).unwrap_or_default();
                read("vendor").trim() == "0x10de" && read("class").trim().starts_with("0x03")
            })
    })
    .as_ref()
}

// ── GPU ─────────────────────────────────────────────────────────────────────

/// The last live reading, shared by every collector, and how long it holds.
static GPU_CACHE: Mutex<Option<(Instant, Duration, GpuReading)>> = Mutex::new(None);

fn gpu_cached() -> GpuReading {
    // A sleeping card is left alone — checked on every tick, it costs one
    // sysfs read and never wakes it.
    if let Some(dev) = nvidia_device() {
        let status = fs::read_to_string(dev.join("power/runtime_status")).unwrap_or_default();
        if status.trim() == "suspended" {
            return GpuReading {
                asleep: true,
                ..Default::default()
            };
        }
    }
    let mut cache = GPU_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, ttl, reading)) = *cache {
        if at.elapsed() < ttl {
            return reading;
        }
    }
    let reading = read_gpu();
    // Idle: give the card the time to suspend before asking again.
    let ttl = if reading.present && reading.usage == 0 {
        GPU_IDLE_EVERY
    } else {
        GPU_BUSY_EVERY
    };
    *cache = Some((Instant::now(), ttl, reading));
    reading
}

fn read_gpu() -> GpuReading {
    // 1) NVIDIA via nvidia-smi (only if there is such a card: a failing
    //    nvidia-smi still costs a process every second).
    if nvidia_device().is_some() {
        if let Some(out) = run_stdout(
            "nvidia-smi",
            &[
                "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
                "--format=csv,noheader,nounits",
            ],
        ) {
            let line = out.lines().next().unwrap_or("").trim();
            let parts: Vec<&str> = line.split(',').map(|s| s.trim()).collect();
            if parts.len() >= 5 {
                let _ = NVIDIA_NAME.set(parts[0].to_string());
                return GpuReading {
                    present: true,
                    asleep: false,
                    usage: parts[1].parse::<u8>().unwrap_or(0).min(100),
                    mem_used: parts[2].parse().unwrap_or(0),
                    mem_total: parts[3].parse().unwrap_or(0),
                    temp: parts[4].parse().unwrap_or(0),
                };
            }
        }
    }

    // 2) AMD via amdgpu sysfs — live polling TEMPORARILY DISABLED.
    // Reading gpu_busy_percent (and the amdgpu hwmon temp in read_temps)
    // every second re-arms the driver's runtime-PM autosuspend timer, which
    // pins a *headless* discrete card (display driven by the iGPU) at boost
    // clocks (~115 W) instead of letting it BACO-suspend. Unlike NVML,
    // rocm-smi/sysfs offer no way to query without re-arming PM, so until a
    // proper idle back-off lands we only detect the card (a wake-safe stat)
    // and report its name — never touch the SMU — so it can sleep.
    //
    // 3) No live data — just a name (gpu_name()).
    GpuReading::default()
}

// ── Free functions ───────────────────────────────────────────────────────────

fn read_ram() -> (u64, u64) {
    let meminfo = match fs::read_to_string("/proc/meminfo") {
        Ok(m) => m,
        Err(_) => return (0, 0),
    };
    let mut total = 0u64;
    let mut available = 0u64;
    for line in meminfo.lines() {
        if let Some(rest) = line.strip_prefix("MemTotal:") {
            total = parse_leading_u64(rest) * 1024;
        } else if let Some(rest) = line.strip_prefix("MemAvailable:") {
            available = parse_leading_u64(rest) * 1024;
        }
    }
    (total, total.saturating_sub(available))
}

/// Parse `sudo dmidecode -t memory` and return "PART TYPE SPEED" for the first
/// populated module, or an empty string. dmidecode is in the sudo NOPASSWD
/// allowlist, so this works non-interactively from the user service.
fn read_ram_brand() -> String {
    let out = match run_stdout("sudo", &["dmidecode", "-t", "memory"]) {
        Some(o) => o,
        None => return String::new(),
    };

    let mut in_device = false;
    let mut has_module = false;
    let mut part = String::new();
    let mut typ = String::new();
    let mut speed = String::new();

    for raw in out.lines() {
        let line = raw.trim();
        if line == "Memory Device" {
            in_device = true;
            has_module = false;
            part.clear();
            typ.clear();
            speed.clear();
            continue;
        }
        if !in_device {
            continue;
        }
        if line.is_empty() {
            // End of a device block.
            if has_module && !part.is_empty() {
                return join_brand(&part, &typ, &speed);
            }
            in_device = false;
            continue;
        }
        if let Some(v) = line.strip_prefix("Size:") {
            let v = v.trim();
            if !v.contains("No Module") {
                has_module = true;
            }
        } else if let Some(v) = line.strip_prefix("Part Number:") {
            let v = v.trim();
            if v != "Not Specified" && !v.is_empty() {
                part = v.to_string();
            }
        } else if let Some(v) = line.strip_prefix("Type:") {
            let v = v.trim();
            if v != "Unknown" && !v.is_empty() {
                typ = v.to_string();
            }
        } else if let Some(v) = line.strip_prefix("Configured Memory Speed:") {
            let v = v.trim();
            if v != "Unknown" && !v.is_empty() {
                speed = v.to_string();
            }
        }
    }
    if has_module && !part.is_empty() {
        return join_brand(&part, &typ, &speed);
    }
    String::new()
}

fn join_brand(part: &str, typ: &str, speed: &str) -> String {
    [part, typ, speed]
        .iter()
        .filter(|s| !s.is_empty())
        .cloned()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Returns (cpu_temp, gpu_temp) in °C from /sys/class/hwmon, 0 when not found.
fn read_temps() -> (u32, u32) {
    let mut cpu_temp = 0u32;
    // gpu_temp stays 0: amdgpu temp polling is disabled (see the match below).
    let gpu_temp = 0u32;

    let entries = match fs::read_dir("/sys/class/hwmon") {
        Ok(e) => e,
        Err(_) => return (0, 0),
    };
    for entry in entries.flatten() {
        let dir = entry.path();
        let name = fs::read_to_string(dir.join("name"))
            .unwrap_or_default()
            .trim()
            .to_string();
        let temp = || -> u32 {
            let raw = read_num(dir.join("temp2_input").to_str().unwrap_or(""))
                .or_else(|| read_num(dir.join("temp1_input").to_str().unwrap_or("")))
                .unwrap_or(0);
            (raw / 1000) as u32
        };
        match name.as_str() {
            "k10temp" | "coretemp" if cpu_temp == 0 => cpu_temp = temp(),
            // amdgpu GPU temp reading TEMPORARILY DISABLED — see read_gpu:
            // polling it re-arms runtime PM and keeps a headless discrete card
            // pinned awake. Re-enable together with the idle back-off.
            _ => {}
        }
    }
    (cpu_temp, gpu_temp)
}
// ── Small helpers ────────────────────────────────────────────────────────────

fn gpu_name_from_lspci() -> String {
    let out = match run_stdout("lspci", &[]) {
        Some(o) => o,
        None => return "Non détecté".into(),
    };
    for line in out.lines() {
        if line.contains("VGA") || line.contains("3D") || line.contains("Display") {
            // "01:00.0 VGA compatible controller: Vendor Device (rev ..)"
            if let Some(after) = line.split(": ").nth(1) {
                // Drop a trailing " (rev ..)" / " (prog-if ..)" parenthetical.
                let name = after.split(" (").next().unwrap_or(after).trim();
                if !name.is_empty() {
                    return name.to_string();
                }
            }
        }
    }
    "Non détecté".into()
}

/// Read a file and parse its leading integer (sysfs single-value files).
fn read_num(path: &str) -> Option<u64> {
    fs::read_to_string(path).ok()?.trim().parse::<u64>().ok()
}

/// Parse the leading run of ASCII digits (e.g. "100G" → 100).
fn parse_leading_u64(s: &str) -> u64 {
    let digits: String = s
        .trim()
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    digits.parse().unwrap_or(0)
}

/// Run a command and capture stdout as a String; None on spawn failure or
/// non-zero exit.
fn run_stdout(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).into_owned())
}
