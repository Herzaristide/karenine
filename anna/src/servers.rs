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

/// What runs on the server: one section per measure, split by `@@`.
const SCRIPT: &str = "head -1 /proc/stat; echo @@; \
grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; echo @@; \
cut -d' ' -f1 /proc/uptime; echo @@; \
cut -d' ' -f1 /proc/loadavg; nproc 2>/dev/null; echo @@; \
cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1; echo @@; \
df -P -B1 2>/dev/null | tail -n +2; echo @@; \
hostname";

/// The previous /proc/stat totals of each server, for the CPU delta.
pub type CpuMemory = HashMap<String, (u64, u64)>;

/// Sample every device at once: over ssh those that run it and are online,
/// from Tailscale alone the others.
pub async fn sample_all(memory: &mut CpuMemory) -> Vec<ServerStats> {
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
        out.push(match result {
            None => base(&server),
            Some(Ok(text)) => parse(&server, &text, memory),
            Some(Err(error)) => ServerStats { ssh: true, error, ..base(&server) },
        });
    }
    out
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
