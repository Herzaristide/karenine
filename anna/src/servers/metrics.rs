//! A server's measures over HTTP: node_exporter's `/metrics` on its
//! Tailscale address. Through its textfile collector come two files more:
//! `extras.prom` (anna/metrics/node_extras.py: disks, AI services,
//! Wake-on-LAN, the same on every machine) and `gpu.prom` (`gpu_*` lines,
//! written by each machine's own script in its NixOS configuration: an
//! NVIDIA card in offload and an AMD card are not read alike). No shell and
//! no key: one read on the tailnet.
//!
//! `gpu.prom`, one card per `pci` label; a sleeping card has only its info
//! line (and its VRAM size if known without waking it):
//!
//! ```text
//! gpu_info{pci="0000:01:00.0",vendor="nvidia",name="GA104M [GeForce RTX 3070 Mobile / Max-Q]",state="active"} 1
//! gpu_busy_percent{pci="0000:01:00.0"} 12
//! gpu_vram_used_bytes{pci="0000:01:00.0"} 5.4e+07
//! gpu_vram_total_bytes{pci="0000:01:00.0"} 8.589934592e+09
//! gpu_temp_celsius{pci="0000:01:00.0"} 47
//! ```
//!
//! `state` is the card's `power/runtime_status` (`active`, `suspended`…),
//! `name` a pci.ids name (`short_gpu_name` shortens it), `vendor` picks the
//! main card: NVIDIA first, else the AMD card with the most VRAM.

use super::{base, short_gpu_name, Drive, Memory, RemoteDisk, RemoteGpu, Server, ServerStats};
use super::{Service, Wake};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

/// node_exporter's port.
const PORT: u16 = 9100;

/// The lines of a textfile older than this are left out: its timer has
/// stopped, and stale measures would pass for live ones.
const STALE_S: f64 = 120.0;

/// The hwmon chips that measure the CPU, for a machine without thermal zones
/// (most AMD desktops).
const CPU_CHIPS: [&str; 4] = ["k10temp", "coretemp", "zenpower", "cpu_thermal"];

/// One line of the text format: `name{label="value",…} value`.
#[derive(Debug, PartialEq)]
pub struct Sample {
    pub name: String,
    pub labels: Vec<(String, String)>,
    pub value: f64,
}

impl Sample {
    fn label(&self, key: &str) -> &str {
        self.labels
            .iter()
            .find(|(k, _)| k == key)
            .map_or("", |(_, v)| v.as_str())
    }
}

pub async fn fetch(ip: &str) -> Result<String, String> {
    let host = if ip.contains(':') {
        format!("[{ip}]")
    } else {
        ip.to_string()
    };
    let url = format!("http://{host}:{PORT}/metrics");
    tokio::task::spawn_blocking(move || {
        ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(2))
            .timeout(Duration::from_secs(4))
            .build()
            .get(&url)
            .call()
            .map_err(|e| e.to_string())?
            .into_string()
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// The samples of a `/metrics` page; comments and malformed lines skipped.
pub fn parse(text: &str) -> Vec<Sample> {
    text.lines().filter_map(parse_line).collect()
}

fn parse_line(line: &str) -> Option<Sample> {
    let line = line.trim();
    if line.is_empty() || line.starts_with('#') {
        return None;
    }
    let end = line.find(['{', ' ', '\t']).unwrap_or(line.len());
    let name = line[..end].to_string();
    let mut rest = &line[end..];
    let mut labels = Vec::new();
    if let Some(inner) = rest.strip_prefix('{') {
        let mut chars = inner.char_indices();
        let mut key = String::new();
        let close = loop {
            let (i, c) = chars.next()?;
            match c {
                '}' => break i,
                ',' | ' ' => {}
                '=' => {
                    if chars.next()?.1 != '"' {
                        return None;
                    }
                    let mut value = String::new();
                    loop {
                        match chars.next()?.1 {
                            '"' => break,
                            '\\' => match chars.next()?.1 {
                                'n' => value.push('\n'),
                                c => value.push(c),
                            },
                            c => value.push(c),
                        }
                    }
                    labels.push((std::mem::take(&mut key), value));
                }
                c => key.push(c),
            }
        };
        rest = &inner[close + 1..];
    }
    // A timestamp may follow the value.
    let value = rest.split_whitespace().next()?.parse().ok()?;
    Some(Sample {
        name,
        labels,
        value,
    })
}

fn of<'a>(samples: &'a [Sample], name: &'a str) -> impl Iterator<Item = &'a Sample> + 'a {
    samples.iter().filter(move |s| s.name == name)
}

fn first(samples: &[Sample], name: &str) -> Option<f64> {
    of(samples, name).next().map(|s| s.value)
}

/// The value of `name` whose `key` label is `value`.
fn by(samples: &[Sample], name: &str, key: &str, value: &str) -> Option<f64> {
    of(samples, name)
        .find(|s| s.label(key) == value)
        .map(|s| s.value)
}

/// A server's stats from its samples, and where Wake-on-LAN reaches it.
pub fn stats(
    server: &Server,
    samples: &[Sample],
    memory: &mut Memory,
) -> (ServerStats, Option<Wake>) {
    let mut s = ServerStats {
        measured: true,
        ..base(server)
    };

    // CPU: the delta since the last sample (0 on the first).
    let (mut total, mut idle) = (0.0, 0.0);
    let mut cpus = HashSet::new();
    for m in of(samples, "node_cpu_seconds_total") {
        total += m.value;
        match m.label("mode") {
            "idle" => {
                idle += m.value;
                cpus.insert(m.label("cpu"));
            }
            "iowait" => idle += m.value,
            _ => {}
        }
    }
    s.cores = cpus.len() as u32;
    if total > 0.0 {
        let active = total - idle;
        if let Some(&(pt, pa)) = memory.cpu_seconds.get(&server.name) {
            let dt = total - pt;
            if dt > 0.0 {
                s.cpu_usage = ((active - pa) * 100.0 / dt).round().clamp(0.0, 100.0) as u8;
            }
        }
        memory
            .cpu_seconds
            .insert(server.name.clone(), (total, active));
    }

    let ram_total = first(samples, "node_memory_MemTotal_bytes").unwrap_or(0.0);
    let ram_avail = first(samples, "node_memory_MemAvailable_bytes").unwrap_or(0.0);
    s.ram_total = ram_total as u64;
    s.ram_used = (ram_total - ram_avail).max(0.0) as u64;

    let now = first(samples, "node_time_seconds");
    if let (Some(now), Some(boot)) = (now, first(samples, "node_boot_time_seconds")) {
        s.uptime_s = (now - boot).max(0.0) as u64;
    }
    s.load1 = first(samples, "node_load1").unwrap_or(0.0) as f32;
    s.temp = temperature(samples);
    s.disks = disks(samples);
    s.hostname = of(samples, "node_uname_info")
        .next()
        .map(|m| m.label("nodename").to_string())
        .unwrap_or_default();

    let fresh = |file: &str| {
        of(samples, "node_textfile_mtime_seconds").any(|m| {
            m.label("file").ends_with(&format!("/{file}"))
                && now.is_none_or(|n| n - m.value < STALE_S)
        })
    };
    if fresh("gpu.prom") {
        s.gpu = gpu(samples);
    }
    if !fresh("extras.prom") {
        return (s, None);
    }
    s.drives = drives(samples);
    s.services = services(samples);
    let wake = of(samples, "wake_info").next().map(|m| Wake {
        mac: m.label("mac").to_string(),
        broadcast: m.label("broadcast").to_string(),
    });
    (s, wake)
}

/// °C: the hottest thermal zone, else the hottest sensor of a CPU chip.
fn temperature(samples: &[Sample]) -> u32 {
    let max = |it: &mut dyn Iterator<Item = f64>| {
        it.fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))))
    };
    let zones = max(&mut of(samples, "node_thermal_zone_temp").map(|m| m.value));
    let chips: HashSet<&str> = of(samples, "node_hwmon_chip_names")
        .filter(|m| CPU_CHIPS.contains(&m.label("chip_name")))
        .map(|m| m.label("chip"))
        .collect();
    let cpu = max(&mut of(samples, "node_hwmon_temp_celsius")
        .filter(|m| chips.contains(m.label("chip")))
        .map(|m| m.value));
    zones.or(cpu).map_or(0, |t| t.max(0.0) as u32)
}

/// Real filesystems only (a `/dev/…` device), one per device: on btrfs
/// every subvolume reports the whole volume, so the shortest mount stands
/// for it.
fn disks(samples: &[Sample]) -> Vec<RemoteDisk> {
    let free: HashMap<(&str, &str), f64> = of(samples, "node_filesystem_free_bytes")
        .map(|m| ((m.label("device"), m.label("mountpoint")), m.value))
        .collect();
    let mut by_device: Vec<RemoteDisk> = Vec::new();
    for m in of(samples, "node_filesystem_size_bytes") {
        let (device, mount) = (m.label("device"), m.label("mountpoint"));
        if !device.starts_with("/dev/") || device.starts_with("/dev/loop") {
            continue;
        }
        let size = m.value as u64;
        let disk = RemoteDisk {
            source: device.to_string(),
            size,
            used: size.saturating_sub(free.get(&(device, mount)).copied().unwrap_or(0.0) as u64),
            mount: mount.to_string(),
        };
        match by_device.iter_mut().find(|d| d.source == disk.source) {
            Some(d) if disk.mount.len() < d.mount.len() => *d = disk,
            Some(_) => {}
            None => by_device.push(disk),
        }
    }
    by_device
}

/// Its main GPU: NVIDIA if there is one, else the AMD card with the most
/// VRAM (the discrete one).
fn gpu(samples: &[Sample]) -> Option<RemoteGpu> {
    let cards: Vec<(&str, RemoteGpu)> = of(samples, "gpu_info")
        .map(|m| {
            let pci = m.label("pci");
            let value = |name: &str| by(samples, name, "pci", pci);
            let vendor = m.label("vendor");
            let name = match short_gpu_name(m.label("name")) {
                n if !n.is_empty() => n,
                _ if vendor == "nvidia" => "NVIDIA".into(),
                _ => "Carte graphique".into(),
            };
            let card = RemoteGpu {
                name,
                asleep: m.label("state") != "active",
                usage: value("gpu_busy_percent").map_or(-1, |v| v.round().min(100.0) as i32),
                mem_used: value("gpu_vram_used_bytes").unwrap_or(0.0) as u64,
                mem_total: value("gpu_vram_total_bytes").unwrap_or(0.0) as u64,
                temp: value("gpu_temp_celsius").map_or(0, |v| v.max(0.0) as u32),
            };
            (vendor, card)
        })
        .collect();
    let nvidia = cards.iter().find(|(v, _)| *v == "nvidia");
    nvidia
        .or_else(|| cards.iter().max_by_key(|(_, c)| c.mem_total))
        .map(|(_, c)| c.clone())
}

fn drives(samples: &[Sample]) -> Vec<Drive> {
    of(samples, "drive_info")
        .map(|m| {
            let name = m.label("name");
            let value = |metric: &str| by(samples, metric, "name", name).unwrap_or(0.0) as u64;
            let mut mounts: Vec<String> = of(samples, "drive_mount")
                .filter(|d| d.label("name") == name)
                .map(|d| d.label("mount").to_string())
                .collect();
            // The shortest mount (`/` before `/boot`) names the disk best.
            mounts.sort_by_key(|m| (m.len(), m.clone()));
            Drive {
                name: name.to_string(),
                model: m.label("model").to_string(),
                kind: m.label("kind").to_string(),
                size: value("drive_size_bytes"),
                fs_size: value("drive_fs_size_bytes"),
                fs_used: value("drive_fs_used_bytes"),
                mounts,
            }
        })
        .collect()
}

fn services(samples: &[Sample]) -> Vec<Service> {
    of(samples, "service_info")
        .map(|m| {
            let name = m.label("name");
            Service {
                name: name.to_string(),
                state: m.label("state").to_string(),
                queue: by(samples, "service_queue", "name", name).map_or(-1, |v| v as i32),
                models: of(samples, "service_model")
                    .filter(|s| s.label("name") == name)
                    .map(|s| s.label("model").to_string())
                    .collect(),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = r#"# HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
# TYPE node_cpu_seconds_total counter
node_cpu_seconds_total{cpu="0",mode="idle"} 80
node_cpu_seconds_total{cpu="0",mode="iowait"} 5
node_cpu_seconds_total{cpu="0",mode="user"} 15
node_cpu_seconds_total{cpu="1",mode="idle"} 90
node_cpu_seconds_total{cpu="1",mode="user"} 10
node_memory_MemTotal_bytes 1.6e+10
node_memory_MemAvailable_bytes 1.2e+10
node_boot_time_seconds 1000
node_time_seconds 4600.5
node_load1 0.42
node_thermal_zone_temp{type="x86_pkg_temp",zone="0"} 51
node_thermal_zone_temp{type="acpitz",zone="1"} 38
node_filesystem_size_bytes{device="/dev/mapper/root",fstype="btrfs",mountpoint="/nix"} 1000
node_filesystem_size_bytes{device="/dev/mapper/root",fstype="btrfs",mountpoint="/"} 1000
node_filesystem_free_bytes{device="/dev/mapper/root",fstype="btrfs",mountpoint="/"} 600
node_filesystem_size_bytes{device="tmpfs",fstype="tmpfs",mountpoint="/run"} 10
node_uname_info{machine="x86_64",nodename="gary",sysname="Linux"} 1
node_textfile_mtime_seconds{file="/run/node-exporter/gpu.prom"} 4590
node_textfile_mtime_seconds{file="/run/node-exporter/extras.prom"} 4590
gpu_info{pci="0000:03:00.0",vendor="amd",name="Navi 33 [Radeon RX 7600/7600 XT/7600M XT]",state="active"} 1
gpu_busy_percent{pci="0000:03:00.0"} 42
gpu_vram_total_bytes{pci="0000:03:00.0"} 8.589934592e+09
gpu_temp_celsius{pci="0000:03:00.0"} 55
gpu_info{pci="0000:0e:00.0",vendor="amd",name="Raphael",state="suspended"} 1
gpu_vram_total_bytes{pci="0000:0e:00.0"} 5.36870912e+08
drive_info{name="nvme0n1",model="Micron 3400",kind="NVMe"} 1
drive_size_bytes{name="nvme0n1"} 1e+12
drive_mount{name="nvme0n1",mount="/boot"} 1
drive_mount{name="nvme0n1",mount="/"} 1
service_info{name="comfyui",state="active"} 1
service_queue{name="comfyui"} 3
service_info{name="ollama",state="active"} 1
service_model{name="ollama",model="qwen3:8b"} 1
wake_info{mac="aa:bb:cc:dd:ee:ff",broadcast="192.168.1.255"} 1
"#;

    fn server() -> Server {
        Server {
            name: "gary".into(),
            online: true,
            ..Default::default()
        }
    }

    #[test]
    fn labels_unescape_and_timestamps_are_ignored() {
        let s = parse(r#"m{a="x\"y",b="1\\2\n"} 3 1700000000000"#);
        assert_eq!(s[0].label("a"), "x\"y");
        assert_eq!(s[0].label("b"), "1\\2\n");
        assert_eq!(s[0].value, 3.0);
        assert!(parse("# just a comment\n\nbroken{a=\"x\" 1").is_empty());
    }

    #[test]
    fn a_page_gives_the_stats() {
        let mut memory = Memory::default();
        let (s, wake) = stats(&server(), &parse(PAGE), &mut memory);
        assert!(s.measured && s.error.is_empty());
        assert_eq!((s.cores, s.cpu_usage), (2, 0), "no delta yet");
        assert_eq!((s.ram_total, s.ram_used), (16_000_000_000, 4_000_000_000));
        assert_eq!((s.uptime_s, s.load1, s.temp), (3600, 0.42, 51));
        assert_eq!(s.hostname, "gary");
        assert_eq!(s.disks.len(), 1);
        assert_eq!((s.disks[0].mount.as_str(), s.disks[0].used), ("/", 400));

        let gpu = s.gpu.unwrap();
        assert_eq!(
            (gpu.name.as_str(), gpu.usage, gpu.temp),
            ("Radeon RX 7600", 42, 55)
        );
        assert!(!gpu.asleep);
        assert_eq!(s.drives[0].mounts, ["/", "/boot"]);
        assert_eq!(
            (s.services[0].name.as_str(), s.services[0].queue),
            ("comfyui", 3)
        );
        assert_eq!((s.services[1].queue, s.services[1].models.len()), (-1, 1));
        assert_eq!(wake.unwrap().mac, "aa:bb:cc:dd:ee:ff");

        // The next sample: 20 s more, 10 of them busy.
        let next = PAGE
            .replace(r#"{cpu="0",mode="user"} 15"#, r#"{cpu="0",mode="user"} 25"#)
            .replace(
                r#"{cpu="1",mode="idle"} 90"#,
                r#"{cpu="1",mode="idle"} 100"#,
            );
        let (s, _) = stats(&server(), &parse(&next), &mut memory);
        assert_eq!(s.cpu_usage, 50);
    }

    #[test]
    fn a_stale_textfile_is_left_out() {
        let page = PAGE.replace("extras.prom\"} 4590", "extras.prom\"} 1000");
        let (s, wake) = stats(&server(), &parse(&page), &mut Memory::default());
        assert!(s.drives.is_empty() && wake.is_none());
        assert!(s.gpu.is_some(), "gpu.prom is still fresh");
        let page = PAGE.replace("gpu.prom\"} 4590", "gpu.prom\"} 1000");
        let (s, _) = stats(&server(), &parse(&page), &mut Memory::default());
        assert!(s.gpu.is_none() && !s.drives.is_empty());
        assert_eq!(
            s.ram_total, 16_000_000_000,
            "node_exporter's own still count"
        );
    }

    #[test]
    fn a_sleeping_nvidia_card_wins_unread() {
        let page = "gpu_info{pci=\"0000:01:00.0\",vendor=\"nvidia\",name=\"GA104M [GeForce RTX 3070 Mobile / Max-Q]\",state=\"suspended\"} 1\n\
                    gpu_info{pci=\"0000:05:00.0\",vendor=\"amd\",name=\"Cezanne\",state=\"active\"} 1\n\
                    gpu_vram_total_bytes{pci=\"0000:05:00.0\"} 5e8\n";
        let gpu = gpu(&parse(page)).unwrap();
        assert_eq!(
            (gpu.name.as_str(), gpu.asleep, gpu.usage),
            ("GeForce RTX 3070 Mobile", true, -1)
        );
    }

    #[test]
    fn a_desktop_without_thermal_zones_reads_its_cpu_chip() {
        let page = "node_hwmon_chip_names{chip=\"pci0000:00_0000:00_18_3\",chip_name=\"k10temp\"} 1\n\
                    node_hwmon_chip_names{chip=\"nvme_nvme0\",chip_name=\"nvme\"} 1\n\
                    node_hwmon_temp_celsius{chip=\"pci0000:00_0000:00_18_3\",sensor=\"temp1\"} 62.5\n\
                    node_hwmon_temp_celsius{chip=\"nvme_nvme0\",sensor=\"temp1\"} 70\n";
        assert_eq!(temperature(&parse(page)), 62);
    }
}
