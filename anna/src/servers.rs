//! The devices of the tailnet, and their stats, for the « Système » tab.
//!
//! The list is Tailscale's (`tailscale status --json`): every other device of
//! the tailnet, phones included, re-read on every sample — a device that
//! joins shows up on the next tick. Only the Linux ones are asked for stats;
//! the others show their state, system and address.
//!
//! Stats: node_exporter on the device's Tailscale address, read over HTTP
//! (`metrics`), with what its textfile collector adds: the GPU (read by
//! each machine's own script, never waking a sleeping card), the disks, the
//! AI services and Wake-on-LAN. Nothing is read over ssh: a device without
//! node_exporter shows its Tailscale state and the error.
//!
//! Power (`power`), the only use of ssh here: off and reboot (`sudo -n
//! systemctl poweroff`, then plain `systemctl poweroff` for polkit), through
//! the device's `~/.ssh/config` alias when one names it (same name, or its
//! Tailscale address), else its MagicDNS name. On by Wake-on-LAN: a sleeping
//! machine cannot tell its MAC, so every sample of an online one records the
//! MAC and LAN broadcast of its default interface in
//! `~/.local/state/anna/servers-wake.json`; the magic packet goes there and
//! to 255.255.255.255. It only reaches a machine on the same LAN as this one,
//! with WoL enabled in its firmware and NIC.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

mod metrics;
use std::time::Duration;

#[derive(Serialize, Clone, Debug, PartialEq, Default)]
pub struct Server {
    /// Its Tailscale name, shown in the shell.
    pub name: String,
    /// The ssh destination; "" for a device that does not run ssh (a phone).
    pub host: String,
    /// `linux`, `android`, `windows`, `macOS`, `iOS`…
    pub os: String,
    /// Its Tailscale IPv4.
    pub ip: String,
    pub online: bool,
    /// RFC 3339, "" while online.
    pub last_seen: String,
}

#[derive(Serialize, Default, Clone)]
pub struct RemoteDisk {
    pub source: String,
    pub mount: String,
    /// Bytes.
    pub size: u64,
    pub used: u64,
}

#[derive(Serialize, Default, Clone)]
pub struct ServerStats {
    pub name: String,
    pub host: String,
    pub os: String,
    pub ip: String,
    pub last_seen: String,
    pub online: bool,
    /// Its stats were asked of node_exporter (the fields below are filled,
    /// unless `error` says why not).
    pub measured: bool,
    /// Why node_exporter did not answer, "" otherwise.
    pub error: String,
    /// Its MAC is known: Wake-on-LAN can be tried.
    pub can_wake: bool,
    pub hostname: String,
    pub cpu_usage: u8,
    pub cores: u32,
    pub load1: f32,
    /// Bytes.
    pub ram_total: u64,
    pub ram_used: u64,
    pub uptime_s: u64,
    /// °C, 0 when unknown.
    pub temp: u32,
    /// One per filesystem (btrfs subvolumes of one volume count once).
    pub disks: Vec<RemoteDisk>,
    /// Its main GPU (NVIDIA, else the AMD card with the most VRAM).
    pub gpu: Option<RemoteGpu>,
    /// Its physical disks, each with what its filesystems hold.
    pub drives: Vec<Drive>,
    /// The AI services it runs (ComfyUI, Ollama), when installed.
    pub services: Vec<Service>,
}

/// A physical disk: what `lsblk` calls a `disk`, with the space its
/// filesystems take and hold, whatever lies between (partitions, LUKS, LVM).
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Drive {
    /// `nvme0n1`, `sda`.
    pub name: String,
    /// Its model, or its name when it has none.
    pub model: String,
    /// `NVMe`, `SSD`, `HDD` or `USB`.
    pub kind: String,
    /// Bytes: the disk, then the filesystems on it (size and used).
    pub size: u64,
    pub fs_size: u64,
    pub fs_used: u64,
    /// Where it is mounted (`/`, `/data`…), the main mount first.
    pub mounts: Vec<String>,
}

/// A systemd service (`comfyui`, `ollama`) and what it is doing.
#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Service {
    pub name: String,
    /// systemd's ActiveState: `active`, `inactive`, `failed`, `activating`…
    pub state: String,
    /// ComfyUI: prompts running or waiting, -1 when unknown.
    pub queue: i32,
    /// Ollama: the models loaded in memory.
    pub models: Vec<String>,
}

#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct RemoteGpu {
    pub name: String,
    /// Runtime-suspended: nothing was read, so as not to wake it.
    pub asleep: bool,
    /// %, -1 when not measured yet.
    pub usage: i32,
    /// Bytes, 0 when unknown.
    pub mem_used: u64,
    pub mem_total: u64,
    /// °C, 0 when unknown.
    pub temp: u32,
}

// ── The list ────────────────────────────────────────────────────────────────

/// What `tailscale status --json` says, as far as it matters here.
#[derive(Deserialize, Default)]
struct Status {
    #[serde(rename = "Peer", default)]
    peers: HashMap<String, StatusPeer>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct StatusPeer {
    #[serde(rename = "HostName")]
    host_name: String,
    #[serde(rename = "DNSName")]
    dns_name: String,
    #[serde(rename = "OS")]
    os: String,
    #[serde(rename = "Online")]
    online: bool,
    #[serde(rename = "LastSeen")]
    last_seen: String,
    #[serde(rename = "TailscaleIPs")]
    ips: Vec<String>,
}

/// The other devices of the tailnet; none when Tailscale is missing or down.
/// The `tailscale` CLI comes from the system PATH, to match its daemon.
pub async fn load() -> Vec<Server> {
    let child = tokio::process::Command::new("tailscale")
        .args(["status", "--json"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let Ok(Ok(out)) = tokio::time::timeout(Duration::from_secs(4), child).await else {
        return vec![];
    };
    let ssh_config = tokio::fs::read_to_string(crate::paths::home_dir().join(".ssh/config"))
        .await
        .unwrap_or_default();
    parse_status(
        &String::from_utf8_lossy(&out.stdout),
        &parse_ssh_config(&ssh_config),
    )
}

fn parse_status(json: &str, aliases: &[(String, String)]) -> Vec<Server> {
    let status: Status = serde_json::from_str(json).unwrap_or_default();
    let mut out: Vec<Server> = status
        .peers
        .into_values()
        .filter(|p| !p.host_name.is_empty())
        .map(|p| {
            let dns = p.dns_name.trim_end_matches('.');
            let short = dns.split('.').next().unwrap_or("");
            // Its ssh config alias: same name, or its Tailscale address.
            let alias = aliases.iter().find(|(alias, hostname)| {
                alias.eq_ignore_ascii_case(&p.host_name)
                    || alias.eq_ignore_ascii_case(short)
                    || p.ips.iter().any(|ip| ip == hostname)
            });
            let host = match alias {
                _ if p.os != "linux" => String::new(),
                Some((alias, _)) => alias.clone(),
                None if dns.is_empty() => p.ips.first().cloned().unwrap_or_default(),
                None => dns.to_string(),
            };
            Server {
                name: p.host_name,
                host,
                // IPv4 first.
                ip: p
                    .ips
                    .iter()
                    .find(|ip| !ip.contains(':'))
                    .or(p.ips.first())
                    .cloned()
                    .unwrap_or_default(),
                last_seen: if p.online { String::new() } else { p.last_seen },
                online: p.online,
                os: p.os,
            }
        })
        .collect();
    out.sort_by_key(|s| s.name.to_lowercase());
    out
}

/// `(alias, HostName)` for each concrete `Host` alias of an ssh config.
fn parse_ssh_config(text: &str) -> Vec<(String, String)> {
    let mut blocks: Vec<(Vec<String>, String)> = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // `Key value` or `Key=value`; keywords ignore case.
        let (key, value) = match line.find(|c: char| c.is_whitespace() || c == '=') {
            Some(i) => (
                &line[..i],
                line[i..]
                    .trim_start_matches(|c: char| c.is_whitespace() || c == '=')
                    .trim(),
            ),
            None => (line, ""),
        };
        match key.to_ascii_lowercase().as_str() {
            "host" => blocks.push((
                value.split_whitespace().map(str::to_string).collect(),
                String::new(),
            )),
            // A `Match` block belongs to no host.
            "match" => blocks.push((vec![], String::new())),
            "hostname" => {
                if let Some(b) = blocks.last_mut() {
                    b.1 = value.to_string();
                }
            }
            _ => {}
        }
    }
    blocks
        .into_iter()
        .flat_map(|(aliases, hostname)| aliases.into_iter().map(move |a| (a, hostname.clone())))
        .filter(|(a, _)| !a.contains(['*', '?', '!']))
        .collect()
}

// ── Sampling ────────────────────────────────────────────────────────────────

/// This machine's disks, AI services and what they do (`sample_local`).
/// Plain commands only; each may be missing, its section then stays empty.
const EXTRA: &str = "echo @@; \
lsblk -b -P -o NAME,PKNAME,TYPE,SIZE,FSSIZE,FSUSED,MODEL,ROTA,TRAN,MOUNTPOINT 2>/dev/null; echo @@; \
systemctl show -p Id,LoadState,ActiveState comfyui.service ollama.service 2>/dev/null; echo @@; \
curl -s -m 1 http://127.0.0.1:8188/queue 2>/dev/null; echo; echo @@; \
curl -s -m 1 http://127.0.0.1:11434/api/ps 2>/dev/null; echo";

/// The services worth showing, as systemd names them.
const SERVICES: [&str; 2] = ["comfyui", "ollama"];

/// What a sample remembers for the next ones, per server (by name).
#[derive(Default)]
pub struct Memory {
    /// node_exporter's CPU seconds (all, busy) last time, for the delta.
    cpu_seconds: HashMap<String, (f64, f64)>,
}

/// Sample every device at once: node_exporter on those that are Linux and
/// online, Tailscale alone for the others. With `only`, that device alone is
/// asked (the one shown): the others need no request every second.
pub async fn sample_all(memory: &mut Memory, only: Option<&str>) -> Vec<ServerStats> {
    let mut wake = load_wake();
    let known = wake.clone();
    let tasks: Vec<_> = load()
        .await
        .into_iter()
        .map(|s| {
            let asked = only.is_none_or(|n| n == s.name);
            tokio::spawn(async move {
                let result = if asked && s.online && s.os == "linux" {
                    Some(metrics::fetch(&s.ip).await)
                } else {
                    None
                };
                (s, result)
            })
        })
        .collect();

    let mut out = Vec::new();
    for t in tasks {
        let Ok((server, result)) = t.await else {
            continue;
        };
        let mut stats = match result {
            None => base(&server),
            Some(Ok(text)) => {
                let (stats, w) = metrics::stats(&server, &metrics::parse(&text), memory);
                if let Some(w) = w {
                    wake.insert(server.name.clone(), w);
                }
                stats
            }
            Some(Err(error)) => ServerStats {
                measured: true,
                error: format!("node_exporter : {error}"),
                ..base(&server)
            },
        };
        stats.can_wake = wake.contains_key(&server.name);
        out.push(stats);
    }
    if wake != known {
        save_wake(&wake);
    }
    out
}

// ── Power ───────────────────────────────────────────────────────────────────

/// How to wake a machine: its MAC, and the broadcast of its LAN ("" unknown).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Default)]
pub struct Wake {
    pub mac: String,
    #[serde(default)]
    pub broadcast: String,
}

fn wake_path() -> std::path::PathBuf {
    crate::paths::home_dir().join(".local/state/anna/servers-wake.json")
}

fn load_wake() -> HashMap<String, Wake> {
    std::fs::read_to_string(wake_path())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save_wake(wake: &HashMap<String, Wake>) {
    let path = wake_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(json) = serde_json::to_string_pretty(wake) {
        let _ = std::fs::write(path, json);
    }
}

/// The magic packet: six 0xff, then the MAC sixteen times.
fn magic_packet(mac: &str) -> Option<Vec<u8>> {
    let bytes: Vec<u8> = mac
        .split([':', '-'])
        .map(|b| u8::from_str_radix(b, 16))
        .collect::<Result<_, _>>()
        .ok()?;
    if bytes.len() != 6 {
        return None;
    }
    let mut p = vec![0xff; 6];
    for _ in 0..16 {
        p.extend_from_slice(&bytes);
    }
    Some(p)
}

/// `on` (Wake-on-LAN), `off` or `reboot` (ssh) for the device named `name`.
pub async fn power(name: &str, action: &str) -> Result<(), String> {
    match action {
        "on" => {
            let w = load_wake()
                .remove(name)
                .ok_or_else(|| crate::i18n::tr("servers.unknown_mac"))?;
            let packet = magic_packet(&w.mac).ok_or_else(|| crate::i18n::tr("servers.bad_mac"))?;
            let sock = std::net::UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
            sock.set_broadcast(true).map_err(|e| e.to_string())?;
            let mut sent = false;
            for to in [w.broadcast.as_str(), "255.255.255.255"] {
                if !to.is_empty() {
                    sent |= sock.send_to(&packet, (to, 9)).is_ok();
                }
            }
            if sent {
                Ok(())
            } else {
                Err(crate::i18n::tr("servers.send_failed"))
            }
        }
        "off" | "reboot" => {
            let server = load()
                .await
                .into_iter()
                .find(|s| s.name == name)
                .ok_or("Appareil inconnu.")?;
            if server.host.is_empty() {
                return Err("Pas de ssh vers cet appareil.".into());
            }
            systemctl(
                &server.host,
                if action == "off" {
                    "poweroff"
                } else {
                    "reboot"
                },
            )
            .await
        }
        _ => Err(format!("action inconnue : {action}")),
    }
}

/// Without a password: sudo if it lets us, else polkit. The connection dies
/// with the machine, so only an explicit refusal counts as a failure.
async fn systemctl(host: &str, verb: &str) -> Result<(), String> {
    let script = format!("sudo -n systemctl {verb} 2>/dev/null || systemctl {verb}");
    let child = tokio::process::Command::new("ssh")
        .args([
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=4",
            "--",
            host,
            // `||` : sh and fish alike.
            script.as_str(),
        ])
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = match tokio::time::timeout(Duration::from_secs(10), child).await {
        Err(_) => return Ok(()),
        Ok(Err(e)) => return Err(format!("ssh : {e}")),
        Ok(Ok(o)) => o,
    };
    if out.status.success() {
        return Ok(());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    if ["authentication required", "Access denied"]
        .iter()
        .any(|r| err.contains(r))
    {
        return Err(crate::i18n::tr("servers.sudo_password"));
    }
    // ssh itself failed (key, name, route); otherwise the link just dropped.
    let unreachable = [
        "Permission denied",
        "Could not resolve",
        "timed out",
        "No route",
        "refused",
    ];
    match err
        .lines()
        .rev()
        .find(|l| unreachable.iter().any(|u| l.contains(u)))
    {
        Some(line) => Err(line.trim().to_string()),
        None => Ok(()),
    }
}

/// What Tailscale says of a device, before node_exporter.
fn base(server: &Server) -> ServerStats {
    ServerStats {
        name: server.name.clone(),
        host: server.host.clone(),
        os: server.os.clone(),
        ip: server.ip.clone(),
        last_seen: server.last_seen.clone(),
        online: server.online,
        ..Default::default()
    }
}

/// What this machine says of its own disks and services, with the same
/// commands as a server (Tailscale lists only the others).
#[derive(Serialize, Default)]
pub struct Local {
    pub hostname: String,
    pub drives: Vec<Drive>,
    pub services: Vec<Service>,
}

pub async fn sample_local() -> Local {
    let script = format!("hostname; {EXTRA}");
    let child = tokio::process::Command::new("sh")
        .args(["-c", &script])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let Ok(Ok(out)) = tokio::time::timeout(Duration::from_secs(4), child).await else {
        return Local::default();
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let parts: Vec<&str> = text.split("@@").map(str::trim).collect();
    let part = |i: usize| parts.get(i).copied().unwrap_or("");
    Local {
        hostname: part(0).to_string(),
        drives: parse_lsblk(part(1)),
        services: parse_services(part(2), part(3), part(4)),
    }
}

/// `KEY="value" KEY="value"…`, as `lsblk -P` prints a device.
fn pairs(line: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    let mut rest = line.trim();
    while let Some(eq) = rest.find("=\"") {
        let key = rest[..eq].trim().to_string();
        let after = &rest[eq + 2..];
        let Some(end) = after.find('"') else {
            break;
        };
        out.insert(key, after[..end].to_string());
        rest = &after[end + 1..];
    }
    out
}

/// The physical disks of `lsblk -b -P`, each with the filesystems found
/// under it (through partitions, LUKS, LVM). Swap in RAM, loops and optical
/// drives are left out.
fn parse_lsblk(text: &str) -> Vec<Drive> {
    let nodes: Vec<HashMap<String, String>> = text
        .lines()
        .map(pairs)
        .filter(|n| n.contains_key("NAME"))
        .collect();
    let get = |n: &HashMap<String, String>, k: &str| n.get(k).cloned().unwrap_or_default();
    let num = |n: &HashMap<String, String>, k: &str| get(n, k).parse::<u64>().unwrap_or(0);
    let by_name: HashMap<String, &HashMap<String, String>> =
        nodes.iter().map(|n| (get(n, "NAME"), n)).collect();

    let mut drives: Vec<Drive> = nodes
        .iter()
        .filter(|n| get(n, "TYPE") == "disk")
        .filter(|n| {
            let name = get(n, "NAME");
            !["zram", "loop", "ram", "sr"]
                .iter()
                .any(|p| name.starts_with(p))
        })
        .map(|n| {
            let name = get(n, "NAME");
            let tran = get(n, "TRAN");
            Drive {
                kind: if tran == "nvme" || name.starts_with("nvme") {
                    "NVMe"
                } else if tran == "usb" {
                    "USB"
                } else if get(n, "ROTA") == "1" {
                    "HDD"
                } else {
                    "SSD"
                }
                .to_string(),
                model: match get(n, "MODEL").replace('_', " ").trim() {
                    "" => name.clone(),
                    m => m.to_string(),
                },
                size: num(n, "SIZE"),
                name,
                ..Default::default()
            }
        })
        .collect();

    // Each filesystem counts once, on the disk it sits on.
    for n in &nodes {
        let fs_size = num(n, "FSSIZE");
        if fs_size == 0 {
            continue;
        }
        let mut cur = get(n, "PKNAME");
        let mut root = if get(n, "TYPE") == "disk" {
            get(n, "NAME")
        } else {
            String::new()
        };
        for _ in 0..16 {
            if cur.is_empty() {
                break;
            }
            match by_name.get(&cur) {
                Some(p) if get(p, "TYPE") == "disk" => {
                    root = cur.clone();
                    break;
                }
                Some(p) => cur = get(p, "PKNAME"),
                None => break,
            }
        }
        if let Some(d) = drives.iter_mut().find(|d| d.name == root) {
            d.fs_size += fs_size;
            d.fs_used += num(n, "FSUSED");
            let mount = get(n, "MOUNTPOINT");
            if !mount.is_empty() && mount != "[SWAP]" && !d.mounts.contains(&mount) {
                d.mounts.push(mount);
            }
        }
    }
    for d in &mut drives {
        // The shortest mount (`/` before `/boot`, `/data` before
        // `/data/models`) names the disk best.
        d.mounts.sort_by_key(|m| (m.len(), m.clone()));
    }
    drives
}

/// The services of `systemctl show` (blank-line separated blocks) that are
/// installed, with ComfyUI's queue and Ollama's loaded models when their
/// API answered.
fn parse_services(show: &str, comfy_queue: &str, ollama_ps: &str) -> Vec<Service> {
    let mut out = Vec::new();
    for block in show.split("\n\n") {
        let field = |k: &str| {
            block
                .lines()
                .find_map(|l| l.strip_prefix(&format!("{k}=")))
                .unwrap_or_default()
                .to_string()
        };
        let name = field("Id").trim_end_matches(".service").to_string();
        if !SERVICES.contains(&name.as_str()) || field("LoadState") != "loaded" {
            continue;
        }
        let mut svc = Service {
            state: field("ActiveState"),
            queue: -1,
            ..Default::default()
        };
        if name == "comfyui" {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(comfy_queue.trim()) {
                let len = |k: &str| v.get(k).and_then(|a| a.as_array()).map_or(0, Vec::len);
                svc.queue = (len("queue_running") + len("queue_pending")) as i32;
            }
        } else if let Ok(v) = serde_json::from_str::<serde_json::Value>(ollama_ps.trim()) {
            svc.models = v
                .get("models")
                .and_then(|m| m.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|m| m.get("name").and_then(|n| n.as_str()))
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();
        }
        svc.name = name;
        out.push(svc);
    }
    out
}

/// « 03:00.0 VGA compatible controller: Advanced Micro Devices, Inc.
/// [AMD/ATI] Navi 33 [Radeon RX 7600/7600 XT/…] (rev c0) » → « Radeon RX
/// 7600 » ; « … [AMD/ATI] Raphael (rev c7) » → « Raphael ».
fn short_gpu_name(lspci: &str) -> String {
    let full = lspci.split_once(": ").map_or(lspci, |(_, d)| d);
    let full = full.split(" (").next().unwrap_or(full).trim();
    let name = match full.strip_suffix(']').and_then(|f| f.rsplit_once('[')) {
        Some((_, inner)) => inner.split('/').next().unwrap_or(inner),
        None => full.rsplit_once("] ").map_or(full, |(_, n)| n),
    };
    name.trim().to_string()
}

#[cfg(test)]
mod fleet_tests {
    use super::*;

    #[test]
    fn filesystems_count_on_the_disk_under_luks_and_lvm() {
        let text = r#"NAME="zram0" PKNAME="" TYPE="disk" SIZE="8225554432" FSSIZE="" FSUSED="" MODEL="" ROTA="0" TRAN="" MOUNTPOINT="[SWAP]"
NAME="nvme0n1" PKNAME="" TYPE="disk" SIZE="1024209543168" FSSIZE="" FSUSED="" MODEL="Micron_3400_MTFDKBA1T0TFH" ROTA="0" TRAN="nvme" MOUNTPOINT=""
NAME="nvme0n1p1" PKNAME="nvme0n1" TYPE="part" SIZE="1073741824" FSSIZE="1000" FSUSED="200" MODEL="" ROTA="0" TRAN="nvme" MOUNTPOINT="/boot"
NAME="nvme0n1p2" PKNAME="nvme0n1" TYPE="part" SIZE="1023134400512" FSSIZE="" FSUSED="" MODEL="" ROTA="0" TRAN="nvme" MOUNTPOINT=""
NAME="crypt" PKNAME="nvme0n1p2" TYPE="crypt" SIZE="1023134400512" FSSIZE="9000" FSUSED="3000" MODEL="" ROTA="0" TRAN="" MOUNTPOINT="/"
NAME="sda" PKNAME="" TYPE="disk" SIZE="4000000000000" FSSIZE="" FSUSED="" MODEL="WDC WD40EFRX" ROTA="1" TRAN="sata" MOUNTPOINT=""
NAME="sda1" PKNAME="sda" TYPE="part" SIZE="4000000000000" FSSIZE="4000" FSUSED="3100" MODEL="" ROTA="1" TRAN="sata" MOUNTPOINT="/data""#;
        let d = parse_lsblk(text);
        assert_eq!(d.len(), 2, "zram is no disk");
        assert_eq!(d[0].model, "Micron 3400 MTFDKBA1T0TFH");
        assert_eq!(
            (d[0].kind.as_str(), d[0].fs_size, d[0].fs_used),
            ("NVMe", 10000, 3200)
        );
        assert_eq!(d[0].mounts, vec!["/".to_string(), "/boot".to_string()]);
        assert_eq!((d[1].kind.as_str(), d[1].fs_used), ("HDD", 3100));
        assert_eq!(d[1].mounts, vec!["/data".to_string()]);
    }

    #[test]
    fn services_keep_the_installed_ones_and_what_they_do() {
        let show = "Id=comfyui.service\nLoadState=loaded\nActiveState=active\n\n\
                    Id=ollama.service\nLoadState=not-found\nActiveState=inactive";
        let s = parse_services(show, r#"{"queue_running":[1],"queue_pending":[2,3]}"#, "");
        assert_eq!(s.len(), 1);
        assert_eq!(
            (s[0].name.as_str(), s[0].state.as_str(), s[0].queue),
            ("comfyui", "active", 3)
        );

        let show = "Id=ollama.service\nLoadState=loaded\nActiveState=active";
        let s = parse_services(show, "", r#"{"models":[{"name":"qwen3:8b"}]}"#);
        assert_eq!(s[0].models, vec!["qwen3:8b".to_string()]);
        assert_eq!(s[0].queue, -1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_config_gives_concrete_aliases() {
        let config = "Host gary\n  HostName 100.90.139.70\n  User aristide\n\n\
                      host kafka nas\n  hostname=192.168.1.143\n\n\
                      Host *.lan !x\n  User root\n\n\
                      Match host foo\n  User git\n";
        let aliases = parse_ssh_config(config);
        let names: Vec<&str> = aliases.iter().map(|(a, _)| a.as_str()).collect();
        assert_eq!(names, ["gary", "kafka", "nas"]);
        assert_eq!(aliases[2].1, "192.168.1.143");
    }

    #[test]
    fn tailscale_status_gives_devices() {
        let json = r#"{"Self":{"HostName":"zola"},"Peer":{
            "k1":{"HostName":"Pixel 9a","DNSName":"pixel-9a.tail.ts.net.","OS":"android","Online":false,
                  "LastSeen":"2026-10-16T10:01:58Z","TailscaleIPs":["fd7a::1","100.71.19.96"]},
            "k2":{"HostName":"gary","DNSName":"gary.tail.ts.net.","OS":"linux","Online":true,
                  "LastSeen":"0001-01-01T00:00:00Z","TailscaleIPs":["100.90.139.70"]},
            "k3":{"HostName":"box","DNSName":"box.tail.ts.net.","OS":"linux","Online":true,
                  "TailscaleIPs":["100.1.2.3"]}}}"#;
        let aliases = vec![("g".to_string(), "100.90.139.70".to_string())];
        let d = parse_status(json, &aliases);
        let names: Vec<&str> = d.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["box", "gary", "Pixel 9a"]);
        // No alias: its MagicDNS name.
        assert_eq!(d[0].host, "box.tail.ts.net");
        // Its ssh config alias, found by address.
        assert_eq!(d[1].host, "g");
        assert_eq!(d[1].last_seen, "");
        // A phone: no ssh, its IPv4 first.
        assert_eq!(d[2].host, "");
        assert_eq!(d[2].ip, "100.71.19.96");
        assert_eq!(d[2].last_seen, "2026-10-16T10:01:58Z");
    }

    #[test]
    fn magic_packet_repeats_the_mac() {
        let p = magic_packet("aa:bb:cc:dd:ee:ff").unwrap();
        assert_eq!(p.len(), 6 + 16 * 6);
        assert_eq!(&p[..6], &[0xff; 6]);
        assert_eq!(&p[6..12], &[0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
        assert!(magic_packet("aa:bb").is_none());
    }

    #[test]
    fn gpu_names_are_shortened() {
        assert_eq!(
            short_gpu_name("03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 33 \
                            [Radeon RX 7600/7600 XT/7600M XT/7600S/7700S / PRO W7600] (rev c0)"),
            "Radeon RX 7600"
        );
        assert_eq!(
            short_gpu_name("13:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Raphael (rev c7)"),
            "Raphael"
        );
    }

}
