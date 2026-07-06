//! Native hardware-stats collector — replaces the per-widget shell-outs that
//! `widgets/HardwareStats.qml` used to spawn every second (cpuinfo, /proc/stat,
//! meminfo, dmidecode, nvidia-smi/amdgpu sysfs, hwmon temps, df).
//!
//! A `Collector` keeps the small amount of state needed across samples (the
//! previous /proc/stat totals for the CPU-usage delta, plus one-shot caches for
//! values that never change: CPU model name and RAM brand). `sample()` returns
//! a fully-populated `HwStats` snapshot, serialized as one JSON line by the
//! daemon's `hwstats_watch` handler.

use serde::Serialize;
use std::fs;
use std::process::Command;

// ── Snapshot payload (JSON sent to Quickshell) ──────────────────────────────

#[derive(Serialize, Default, Clone)]
pub struct DiskInfo {
    pub source: String,
    pub mount: String,
    /// Whole gibibytes, matching the old `df -BG` output the QML parsed.
    pub size_gb: u64,
    pub used_gb: u64,
    pub avail_gb: u64,
}

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
    pub gpu_usage: u8,
    pub gpu_mem_used_mib: u64,
    pub gpu_mem_total_mib: u64,
    pub gpu_temp: u32,

    pub disks: Vec<DiskInfo>,
}

// ── Collector ───────────────────────────────────────────────────────────────

pub struct Collector {
    prev_cpu_total: u64,
    prev_cpu_active: u64,
    cpu_name: Option<String>,
    ram_brand: Option<String>, // Some("") once attempted with no result
    gpu_name: Option<String>,
}

impl Collector {
    pub fn new() -> Self {
        Self {
            prev_cpu_total: 0,
            prev_cpu_active: 0,
            cpu_name: None,
            ram_brand: None,
            gpu_name: None,
        }
    }

    pub fn sample(&mut self) -> HwStats {
        let cpu_usage = self.cpu_usage();
        let (ram_total, ram_used) = read_ram();
        let (gpu_present, gpu_usage, gpu_mem_used, gpu_mem_total, gpu_temp_smi) = self.read_gpu();
        let (cpu_temp, gpu_temp_hwmon) = read_temps();

        HwStats {
            cpu_name: self.cpu_name().to_string(),
            cpu_usage,
            cpu_temp,
            ram_total,
            ram_used,
            ram_brand: self.ram_brand().to_string(),
            gpu_name: self.gpu_name().to_string(),
            gpu_present,
            gpu_usage,
            gpu_mem_used_mib: gpu_mem_used,
            gpu_mem_total_mib: gpu_mem_total,
            // Prefer the amdgpu hwmon reading; fall back to nvidia-smi's value.
            gpu_temp: if gpu_temp_hwmon > 0 {
                gpu_temp_hwmon
            } else {
                gpu_temp_smi
            },
            disks: read_disks(),
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

    fn cpu_name(&mut self) -> &str {
        if self.cpu_name.is_none() {
            let name = fs::read_to_string("/proc/cpuinfo")
                .ok()
                .and_then(|c| {
                    c.lines()
                        .find(|l| l.starts_with("model name"))
                        .and_then(|l| l.split(':').nth(1))
                        .map(|s| s.trim().to_string())
                })
                .unwrap_or_default();
            self.cpu_name = Some(name);
        }
        self.cpu_name.as_deref().unwrap_or("")
    }

    // ── RAM brand (dmidecode, once) ─────────────────────────────────────────

    fn ram_brand(&mut self) -> &str {
        if self.ram_brand.is_none() {
            self.ram_brand = Some(read_ram_brand());
        }
        self.ram_brand.as_deref().unwrap_or("")
    }

    // ── GPU ──────────────────────────────────────────────────────────────────

    /// Returns (present, usage%, mem_used_mib, mem_total_mib, temp_from_smi).
    fn read_gpu(&mut self) -> (bool, u8, u64, u64, u32) {
        // 1) NVIDIA via nvidia-smi.
        if let Some(out) = run_stdout(
            "nvidia-smi",
            &[
                "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
                "--format=csv,noheader,nounits",
            ],
        ) {
            let line = out.lines().next().unwrap_or("").trim();
            if !line.is_empty() {
                let parts: Vec<&str> = line.split(',').map(|s| s.trim()).collect();
                if parts.len() >= 5 {
                    if self.gpu_name.is_none() {
                        self.gpu_name = Some(parts[0].to_string());
                    }
                    let usage = parts[1].parse::<u8>().unwrap_or(0);
                    let mem_used = parts[2].parse::<u64>().unwrap_or(0);
                    let mem_total = parts[3].parse::<u64>().unwrap_or(0);
                    let temp = parts[4].parse::<u32>().unwrap_or(0);
                    return (true, usage.min(100), mem_used, mem_total, temp);
                }
            }
        }

        // 2) AMD via amdgpu sysfs.
        if let Some(dev) = amdgpu_device_dir() {
            let usage = read_num(&format!("{dev}/gpu_busy_percent")).unwrap_or(0) as u8;
            let vram_used = read_num(&format!("{dev}/mem_info_vram_used")).unwrap_or(0) / 1_048_576;
            let vram_total =
                read_num(&format!("{dev}/mem_info_vram_total")).unwrap_or(0) / 1_048_576;
            if self.gpu_name.is_none() {
                self.gpu_name = Some(gpu_name_from_lspci());
            }
            return (true, usage.min(100), vram_used, vram_total, 0);
        }

        // 3) No live data — just a name (if any).
        if self.gpu_name.is_none() {
            self.gpu_name = Some(gpu_name_from_lspci());
        }
        (false, 0, 0, 0, 0)
    }

    fn gpu_name(&mut self) -> &str {
        if self.gpu_name.is_none() {
            self.gpu_name = Some(gpu_name_from_lspci());
        }
        self.gpu_name.as_deref().unwrap_or("")
    }
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
    let mut gpu_temp = 0u32;

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
            "amdgpu" if gpu_temp == 0 => gpu_temp = temp(),
            _ => {}
        }
    }
    (cpu_temp, gpu_temp)
}

/// Enumerate mounted filesystems via `df`, mirroring the old QML pipeline:
/// `df -BG --output=source,size,used,avail,target` minus pseudo filesystems,
/// dropping /boot.
fn read_disks() -> Vec<DiskInfo> {
    let out = match run_stdout(
        "df",
        &[
            "-BG",
            "--output=source,size,used,avail,target",
            "-x",
            "tmpfs",
            "-x",
            "devtmpfs",
            "-x",
            "efivarfs",
            "-x",
            "overlay",
        ],
    ) {
        Some(o) => o,
        None => return Vec::new(),
    };

    let mut disks = Vec::new();
    for line in out.lines().skip(1) {
        let p: Vec<&str> = line.split_whitespace().collect();
        if p.len() < 5 {
            continue;
        }
        let mount = p[4].to_string();
        if mount == "/boot" || mount.starts_with("/boot/") {
            continue;
        }
        let size = parse_leading_u64(p[1]);
        if size == 0 {
            continue;
        }
        disks.push(DiskInfo {
            source: p[0].to_string(),
            mount,
            size_gb: size,
            used_gb: parse_leading_u64(p[2]),
            avail_gb: parse_leading_u64(p[3]),
        });
    }
    disks
}

// ── Small helpers ────────────────────────────────────────────────────────────

/// Find the amdgpu card's `device` directory (the one exposing
/// gpu_busy_percent / mem_info_vram_*), via /sys/class/hwmon/*/name == amdgpu.
fn amdgpu_device_dir() -> Option<String> {
    for entry in fs::read_dir("/sys/class/hwmon").ok()?.flatten() {
        let dir = entry.path();
        let name = fs::read_to_string(dir.join("name")).unwrap_or_default();
        if name.trim() == "amdgpu" {
            let dev = dir.join("device");
            if dev.join("gpu_busy_percent").exists() {
                return dev.to_str().map(str::to_string);
            }
        }
    }
    None
}

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
    let digits: String = s.trim().chars().take_while(|c| c.is_ascii_digit()).collect();
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
