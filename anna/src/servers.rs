//! The devices of the tailnet, and their stats over SSH, for the « Network »
//! tab.
//!
//! The list is Tailscale's (`tailscale status --json`): every other device of
//! the tailnet, phones included, re-read on every sample — a device that
//! joins shows up on the next tick. Only the Linux ones are asked for stats;
//! the others show their state, system and address.
//!
//! A device is reached through its `~/.ssh/config` alias when one names it
//! (same name, or its Tailscale address), for the user and key set there;
//! otherwise through its MagicDNS name.
//!
//! Nothing runs on the devices but `ssh` and a few reads of `/proc`, `df` and
//! sysfs: no agent to install. One master connection per device stays open
//! (`ControlMaster`, socket in `$XDG_RUNTIME_DIR`), so a sample costs a new
//! channel, not a new handshake. `BatchMode` keeps a device that would ask
//! for a password from hanging the loop: it reports an error instead. A
//! device Tailscale knows to be offline is not tried at all.
//!
//! Power (`power`): off and reboot over ssh (`sudo -n systemctl poweroff`,
//! then plain `systemctl poweroff` for polkit); on by Wake-on-LAN. A
//! sleeping machine cannot tell its MAC, so every sample of an online one
//! records the MAC and LAN broadcast of its default interface in
//! `~/.local/state/anna/servers-wake.json`; the magic packet goes there and
//! to 255.255.255.255. It only reaches a machine on the same LAN as this one,
//! with WoL enabled in its firmware and NIC.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
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
    /// Its stats were asked over ssh (the fields below are filled).
    pub ssh: bool,
    /// Why ssh failed (its last line), "" otherwise.
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
    let ssh_config = std::fs::read_to_string(crate::paths::home_dir().join(".ssh/config")).unwrap_or_default();
    parse_status(&String::from_utf8_lossy(&out.stdout), &parse_ssh_config(&ssh_config))
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
                ip: p.ips.iter().find(|ip| !ip.contains(':')).or(p.ips.first()).cloned().unwrap_or_default(),
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
            Some(i) => (&line[..i], line[i..].trim_start_matches(|c: char| c.is_whitespace() || c == '=').trim()),
            None => (line, ""),
        };
        match key.to_ascii_lowercase().as_str() {
            "host" => blocks.push((value.split_whitespace().map(str::to_string).collect(), String::new())),
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

/// What runs on the server: one section per measure, split by `@@`. Plain
/// commands only, no variables: the login shell may be fish.
const SCRIPT: &str = "head -1 /proc/stat; echo @@; \
grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; echo @@; \
cut -d' ' -f1 /proc/uptime; echo @@; \
cut -d' ' -f1 /proc/loadavg; nproc 2>/dev/null; echo @@; \
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1; echo @@; \
df -P -B1 2>/dev/null | tail -n +2; echo @@; \
hostname; echo @@; \
ip -o -4 route get 1.1.1.1 2>/dev/null; echo @@; \
ip -o link 2>/dev/null; echo @@; \
ip -o -4 addr 2>/dev/null";

/// The previous /proc/stat totals of each server, for the CPU delta.
pub type CpuMemory = HashMap<String, (u64, u64)>;

/// Sample every device at once: over ssh those that run it and are online,
/// from Tailscale alone the others.
pub async fn sample_all(memory: &mut CpuMemory) -> Vec<ServerStats> {
    let mut wake = load_wake();
    let known = wake.clone();
    let tasks: Vec<_> = load()
        .await
        .into_iter()
        .map(|s| {
            tokio::spawn(async move {
                let result = if s.online && !s.host.is_empty() { Some(run_script(&s.host).await) } else { None };
                (s, result)
            })
        })
        .collect();

    let mut out = Vec::new();
    for t in tasks {
        let Ok((server, result)) = t.await else { continue };
        let mut stats = match result {
            None => base(&server),
            Some(Ok(text)) => {
                if let Some(w) = parse_wake(&text) {
                    wake.insert(server.name.clone(), w);
                }
                parse(&server, &text, memory)
            }
            Some(Err(error)) => ServerStats { ssh: true, error, ..base(&server) },
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

/// The MAC and broadcast of the interface that holds the default route, from
/// the last three sections of the script (`ip route get`, `ip link`,
/// `ip addr`).
fn parse_wake(text: &str) -> Option<Wake> {
    let parts: Vec<&str> = text.split("@@").map(str::trim).collect();
    let part = |i: usize| parts.get(i).copied().unwrap_or("");
    // Value after `key` in a whitespace-split line.
    let after = |line: &str, key: &str| {
        let mut it = line.split_whitespace();
        it.position(|w| w == key)?;
        it.next().map(str::to_string)
    };

    let dev = after(part(7), "dev")?;
    // `2: enp3s0: <…> … link/ether aa:bb:… brd ff:…` (`enp3s0@if5:` for a veth).
    let mac = part(8).lines().find_map(|l| {
        let name = l.split_whitespace().nth(1)?.trim_end_matches(':');
        if name.split('@').next()? != dev {
            return None;
        }
        after(l, "link/ether")
    })?;
    // `2: enp3s0    inet 192.168.1.10/24 brd 192.168.1.255 scope global …`
    let broadcast = part(9)
        .lines()
        .find(|l| l.split_whitespace().nth(1) == Some(dev.as_str()))
        .and_then(|l| after(l, "brd"))
        .unwrap_or_default();
    Some(Wake { mac, broadcast })
}

/// The magic packet: six 0xff, then the MAC sixteen times.
fn magic_packet(mac: &str) -> Option<Vec<u8>> {
    let bytes: Vec<u8> = mac.split([':', '-']).map(|b| u8::from_str_radix(b, 16)).collect::<Result<_, _>>().ok()?;
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
            let w = load_wake().remove(name).ok_or("Adresse MAC inconnue : il faut l'avoir vu en ligne une fois.")?;
            let packet = magic_packet(&w.mac).ok_or("Adresse MAC illisible.")?;
            let sock = std::net::UdpSocket::bind("0.0.0.0:0").map_err(|e| e.to_string())?;
            sock.set_broadcast(true).map_err(|e| e.to_string())?;
            let mut sent = false;
            for to in [w.broadcast.as_str(), "255.255.255.255"] {
                if !to.is_empty() {
                    sent |= sock.send_to(&packet, (to, 9)).is_ok();
                }
            }
            if sent { Ok(()) } else { Err("Envoi impossible sur le réseau local.".into()) }
        }
        "off" | "reboot" => {
            let server = load().await.into_iter().find(|s| s.name == name).ok_or("Appareil inconnu.")?;
            if server.host.is_empty() {
                return Err("Pas de ssh vers cet appareil.".into());
            }
            systemctl(&server.host, if action == "off" { "poweroff" } else { "reboot" }).await
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
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=4",
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
    if ["authentication required", "Access denied"].iter().any(|r| err.contains(r)) {
        return Err("Refusé : sudo demande un mot de passe.".into());
    }
    // ssh itself failed (key, name, route); otherwise the link just dropped.
    let unreachable = ["Permission denied", "Could not resolve", "timed out", "No route", "refused"];
    match err.lines().rev().find(|l| unreachable.iter().any(|u| l.contains(u))) {
        Some(line) => Err(line.trim().to_string()),
        None => Ok(()),
    }
}

/// What Tailscale says of a device, before any ssh.
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

async fn run_script(host: &str) -> Result<String, String> {
    let control = format!("{}/anna-ssh-%C", crate::paths::runtime_dir());
    let child = tokio::process::Command::new("ssh")
        .args([
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=4",
            "-o", "ServerAliveInterval=5",
            "-o", "ControlMaster=auto",
            "-o", &format!("ControlPath={control}"),
            "-o", "ControlPersist=120",
            "--",
            host,
            SCRIPT,
        ])
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = match tokio::time::timeout(Duration::from_secs(8), child).await {
        Err(_) => return Err("délai dépassé".into()),
        Ok(Err(e)) => return Err(format!("ssh : {e}")),
        Ok(Ok(o)) => o,
    };
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        let last = err.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("injoignable");
        return Err(last.trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn parse(server: &Server, text: &str, memory: &mut CpuMemory) -> ServerStats {
    let parts: Vec<&str> = text.split("@@").map(str::trim).collect();
    let part = |i: usize| parts.get(i).copied().unwrap_or("");

    let mut s = ServerStats { ssh: true, ..base(server) };

    // CPU: the delta since the last sample (0 on the first).
    if let Some((total, active)) = cpu_totals(part(0)) {
        if let Some(&(pt, pa)) = memory.get(&server.name) {
            let dt = total.saturating_sub(pt);
            if dt > 0 {
                s.cpu_usage = ((active.saturating_sub(pa)) * 100 / dt).min(100) as u8;
            }
        }
        memory.insert(server.name.clone(), (total, active));
    }

    let mut total_kb = 0;
    let mut avail_kb = 0;
    for line in part(1).lines() {
        let kb = line.split_whitespace().nth(1).and_then(|v| v.parse::<u64>().ok()).unwrap_or(0);
        if line.starts_with("MemTotal:") {
            total_kb = kb;
        } else if line.starts_with("MemAvailable:") {
            avail_kb = kb;
        }
    }
    s.ram_total = total_kb * 1024;
    s.ram_used = total_kb.saturating_sub(avail_kb) * 1024;

    s.uptime_s = part(2).parse::<f64>().map(|v| v as u64).unwrap_or(0);

    let mut load = part(3).lines();
    s.load1 = load.next().and_then(|v| v.trim().parse().ok()).unwrap_or(0.0);
    s.cores = load.next().and_then(|v| v.trim().parse().ok()).unwrap_or(0);

    // Millidegrees.
    s.temp = part(4).parse::<u64>().map(|v| (v / 1000) as u32).unwrap_or(0);

    s.disks = parse_df(part(5));
    s.hostname = part(6).to_string();
    s
}

/// `(total, active)` jiffies from the aggregate `cpu` line of /proc/stat.
fn cpu_totals(line: &str) -> Option<(u64, u64)> {
    let mut it = line.split_whitespace();
    if it.next()? != "cpu" {
        return None;
    }
    let v: Vec<u64> = it.filter_map(|x| x.parse().ok()).collect();
    if v.len() < 4 {
        return None;
    }
    let total: u64 = v.iter().sum();
    // idle + iowait
    let idle = v[3] + v.get(4).copied().unwrap_or(0);
    Some((total, total - idle))
}

/// Real filesystems only (a `/dev/…` source), one per source: on btrfs every
/// subvolume reports the whole volume, so the shortest mount stands for it.
fn parse_df(text: &str) -> Vec<RemoteDisk> {
    let mut by_source: Vec<RemoteDisk> = Vec::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 6 || !f[0].starts_with("/dev/") || f[0].starts_with("/dev/loop") {
            continue;
        }
        let disk = RemoteDisk {
            source: f[0].to_string(),
            size: f[1].parse().unwrap_or(0),
            used: f[2].parse().unwrap_or(0),
            mount: f[5..].join(" "),
        };
        match by_source.iter_mut().find(|d| d.source == disk.source) {
            Some(d) if disk.mount.len() < d.mount.len() => *d = disk,
            Some(_) => {}
            None => by_source.push(disk),
        }
    }
    by_source
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cpu_line_gives_total_and_active() {
        let (total, active) = cpu_totals("cpu  100 0 50 800 50 0 0 0 0 0").unwrap();
        assert_eq!(total, 1000);
        assert_eq!(active, 150);
    }

    #[test]
    fn df_keeps_one_entry_per_source() {
        let df = "/dev/mapper/root 1000 400 600 40% /nix\n\
                  /dev/mapper/root 1000 400 600 40% /\n\
                  tmpfs 10 1 9 10% /run\n\
                  /dev/sda1 500 100 400 20% /data";
        let d = parse_df(df);
        assert_eq!(d.len(), 2);
        assert_eq!(d[0].mount, "/");
        assert_eq!(d[1].source, "/dev/sda1");
    }

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
    fn wake_comes_from_the_default_interface() {
        let text = "@@@@@@@@@@@@@@\n\
            1.1.1.1 via 192.168.1.1 dev enp3s0 src 192.168.1.10 uid 1000 \\    cache\n@@\n\
            1: lo: <LOOPBACK,UP> mtu 65536 \\    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00\n\
            2: enp3s0: <BROADCAST,UP> mtu 1500 \\    link/ether aa:bb:cc:dd:ee:ff brd ff:ff:ff:ff:ff:ff\n\
            3: tailscale0: <POINTOPOINT> mtu 1280 \\    link/none\n@@\n\
            1: lo    inet 127.0.0.1/8 scope host lo\n\
            2: enp3s0    inet 192.168.1.10/24 brd 192.168.1.255 scope global enp3s0\n";
        let w = parse_wake(text).unwrap();
        assert_eq!(w.mac, "aa:bb:cc:dd:ee:ff");
        assert_eq!(w.broadcast, "192.168.1.255");
        // No default route: nothing to learn.
        assert!(parse_wake("@@@@@@@@@@@@@@\n@@\n@@\n").is_none());
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
    fn script_output_parses() {
        let server = Server { name: "gary".into(), host: "gary".into(), online: true, ..Default::default() };
        let text = "cpu  100 0 50 800 50 0 0 0\n@@\nMemTotal: 1000 kB\nMemAvailable: 400 kB\n@@\n\
                    3600.5\n@@\n0.42\n8\n@@\n45000\n@@\n/dev/sda1 500 100 400 20% /\n@@\ngary";
        let mut mem = CpuMemory::new();
        let s = parse(&server, text, &mut mem);
        assert!(s.online);
        assert_eq!(s.ram_total, 1000 * 1024);
        assert_eq!(s.ram_used, 600 * 1024);
        assert_eq!(s.uptime_s, 3600);
        assert_eq!(s.cores, 8);
        assert_eq!(s.temp, 45);
        assert_eq!(s.disks.len(), 1);
        assert_eq!(s.hostname, "gary");
    }
}
