//! Remote servers: their stats over SSH, for the « Serveurs » tab.
//!
//! The servers come from two places, merged on every sample:
//! - `~/.ssh/config`: each concrete `Host` alias is a server, without any
//!   setup. Skipped: patterns (`*`, `?`, `!`), git forges (`User git`) and
//!   this machine itself.
//! - `~/.config/anna/servers.json`, for the rest — `{"servers":[{"name",
//!   "host"}], "hidden":[…]}`, where `host` is anything `ssh` accepts
//!   (`user@1.2.3.4`…). Removing a server that comes from the ssh config
//!   hides it (`hidden`) rather than touching that file.
//!
//! Both are re-read on every sample, so a server added from the shell, with
//! `anna servers add` or in the ssh config shows up on the next tick.
//!
//! Nothing runs on the servers but `ssh` and a few reads of `/proc`, `df` and
//! sysfs: no agent to install. One master connection per server stays open
//! (`ControlMaster`, socket in `$XDG_RUNTIME_DIR`), so a sample costs a new
//! channel, not a new handshake. `BatchMode` keeps a server that would ask
//! for a password from hanging the loop: it reports an error instead.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Server {
    /// Shown in the shell; also the key for add/remove.
    pub name: String,
    /// The ssh destination.
    pub host: String,
    /// Found in `~/.ssh/config` rather than added by hand.
    #[serde(default, skip_deserializing)]
    pub from_ssh: bool,
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
    pub online: bool,
    /// Why it is offline (ssh's last line), "" when online.
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

/// What `servers.json` holds.
#[derive(Serialize, Deserialize, Default)]
struct ListFile {
    /// Added by hand.
    #[serde(default)]
    servers: Vec<Server>,
    /// Names from the ssh config not to show.
    #[serde(default)]
    hidden: Vec<String>,
}

pub fn list_file() -> PathBuf {
    crate::paths::home_dir().join(".config/anna/servers.json")
}

/// The file; empty when missing or unreadable. The first version was a bare
/// array of servers: still read.
fn read_list() -> ListFile {
    let Ok(text) = std::fs::read_to_string(list_file()) else {
        return ListFile::default();
    };
    serde_json::from_str::<ListFile>(&text)
        .or_else(|_| serde_json::from_str::<Vec<Server>>(&text).map(|servers| ListFile { servers, hidden: vec![] }))
        .unwrap_or_default()
}

fn write_list(list: &ListFile) -> Result<(), String> {
    let f = list_file();
    if let Some(d) = f.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let json = serde_json::to_string_pretty(list).map_err(|e| e.to_string())?;
    std::fs::write(&f, json + "\n").map_err(|e| e.to_string())
}

/// The concrete hosts of `~/.ssh/config`, minus git forges and this machine.
fn ssh_config_servers() -> Vec<Server> {
    let text = std::fs::read_to_string(crate::paths::home_dir().join(".ssh/config")).unwrap_or_default();
    let me = std::fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default();
    parse_ssh_config(&text, me.trim())
}

fn parse_ssh_config(text: &str, me: &str) -> Vec<Server> {
    // One block per `Host` line: its aliases, and what decides whether it is
    // a server (its user, its address).
    struct Block {
        aliases: Vec<String>,
        user: String,
        hostname: String,
    }
    let mut blocks: Vec<Block> = Vec::new();
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
            "host" => blocks.push(Block {
                aliases: value.split_whitespace().map(str::to_string).collect(),
                user: String::new(),
                hostname: String::new(),
            }),
            // A `Match` block belongs to no host.
            "match" => blocks.push(Block { aliases: vec![], user: String::new(), hostname: String::new() }),
            "user" => {
                if let Some(b) = blocks.last_mut() {
                    b.user = value.to_string();
                }
            }
            "hostname" => {
                if let Some(b) = blocks.last_mut() {
                    b.hostname = value.to_string();
                }
            }
            _ => {}
        }
    }

    let mut out: Vec<Server> = Vec::new();
    for b in blocks {
        if b.user == "git" || (!me.is_empty() && b.hostname.eq_ignore_ascii_case(me)) {
            continue;
        }
        for alias in b.aliases {
            let pattern = alias.contains(['*', '?', '!']);
            if pattern || alias.eq_ignore_ascii_case(me) || out.iter().any(|s| s.name == alias) {
                continue;
            }
            out.push(Server { host: alias.clone(), name: alias, from_ssh: true });
        }
    }
    out
}

/// Every server to show: the ssh config ones not hidden, then those added by
/// hand (which win over an ssh alias of the same name).
pub fn load() -> Vec<Server> {
    let list = read_list();
    let mut out: Vec<Server> = ssh_config_servers()
        .into_iter()
        .filter(|s| !list.hidden.contains(&s.name) && !list.servers.iter().any(|m| m.name == s.name))
        .collect();
    out.extend(list.servers);
    out
}

/// Add a server, or change the host of one with the same name. An ssh config
/// server that was hidden comes back.
pub fn add(name: &str, host: &str) -> Result<Vec<Server>, String> {
    let (name, host) = (name.trim(), host.trim());
    if name.is_empty() || host.is_empty() {
        return Err("nom et hôte requis".into());
    }
    // ssh would read a leading dash as an option.
    if host.starts_with('-') || host.chars().any(char::is_whitespace) {
        return Err(format!("hôte invalide : {host}"));
    }
    let mut list = read_list();
    list.hidden.retain(|h| h != name);
    // Already in the ssh config as such: showing it again is enough.
    let from_ssh = ssh_config_servers().iter().any(|s| s.name == name && s.host == host);
    if from_ssh {
        list.servers.retain(|s| s.name != name);
    } else {
        match list.servers.iter_mut().find(|s| s.name == name) {
            Some(s) => s.host = host.to_string(),
            None => list.servers.push(Server { name: name.to_string(), host: host.to_string(), from_ssh: false }),
        }
    }
    write_list(&list)?;
    Ok(load())
}

/// Forget a server added by hand; hide one from the ssh config.
pub fn remove(name: &str) -> Result<Vec<Server>, String> {
    let mut list = read_list();
    list.servers.retain(|s| s.name != name);
    if ssh_config_servers().iter().any(|s| s.name == name) && !list.hidden.iter().any(|h| h == name) {
        list.hidden.push(name.to_string());
    }
    write_list(&list)?;
    Ok(load())
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

/// Sample every configured server at once.
pub async fn sample_all(memory: &mut CpuMemory) -> Vec<ServerStats> {
    let servers = load();
    let tasks: Vec<_> = servers
        .into_iter()
        .map(|s| tokio::spawn(async move { (s.clone(), run_script(&s.host).await) }))
        .collect();

    let mut out = Vec::new();
    for t in tasks {
        let Ok((server, result)) = t.await else { continue };
        let stats = match result {
            Ok(text) => parse(&server, &text, memory),
            Err(error) => ServerStats {
                name: server.name.clone(),
                host: server.host.clone(),
                error,
                ..Default::default()
            },
        };
        out.push(stats);
    }
    out
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

    let mut s = ServerStats {
        name: server.name.clone(),
        host: server.host.clone(),
        online: true,
        ..Default::default()
    };

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
    fn ssh_config_gives_concrete_hosts() {
        let config = "Host gary\n  HostName 100.90.139.70\n  User aristide\n\n\
                      Host github.com\n  User git\n\n\
                      Host zola\n  HostName 100.67.220.15\n\n\
                      host kafka nas\n  hostname=192.168.1.143\n\n\
                      Host *.lan !x\n  User root\n\n\
                      Match host foo\n  User git\n";
        let names: Vec<String> = parse_ssh_config(config, "zola").into_iter().map(|s| s.name).collect();
        assert_eq!(names, ["gary", "kafka", "nas"]);
    }

    #[test]
    fn script_output_parses() {
        let server = Server { name: "gary".into(), host: "gary".into(), from_ssh: false };
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
