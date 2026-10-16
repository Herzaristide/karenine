//! The phones paired with KDE Connect, for the « Téléphone » tab.
//!
//! Everything goes through kdeconnectd's D-Bus API on the session bus, with
//! `busctl --json=short` (no D-Bus crate for a handful of calls): the
//! devices, then for each one paired and in reach its battery, its mobile
//! network and its notifications, re-read on every sample.
//!
//! kdeconnectd itself is started with the Hyprland session (NixOS config,
//! `programs.kdeconnect`); when it is not running, the snapshot says so and
//! the shell explains it.
//!
//! The phone's screen is scrcpy's, over adb rather than KDE Connect: anna
//! only picks the connection (`screen`), the shell opens the window.
//!
//! The D-Bus objects, as kdeconnect-kde 26.08 exposes them:
//!   /modules/kdeconnect                    org.kde.kdeconnect.daemon
//!   /modules/kdeconnect/devices/<id>       org.kde.kdeconnect.device
//!     …/battery                            org.kde.kdeconnect.device.battery
//!     …/connectivity_report                org.kde.kdeconnect.device.connectivity_report
//!     …/notifications[/<nid>]              org.kde.kdeconnect.device.notifications[.notification]
//!     …/findmyphone, ping, sftp, clipboard, share

use serde::Serialize;
use serde_json::Value;
use std::time::Duration;

const DEST: &str = "org.kde.kdeconnect";
const ROOT: &str = "/modules/kdeconnect";

#[derive(Serialize, Default, Clone, Debug, PartialEq)]
pub struct Notification {
    /// Its D-Bus name, for `dismiss`.
    pub id: String,
    pub app: String,
    pub title: String,
    pub text: String,
    pub dismissable: bool,
}

#[derive(Serialize, Default, Clone, Debug)]
pub struct Phone {
    pub id: String,
    pub name: String,
    /// "smartphone", "tablet", "desktop"…
    pub kind: String,
    pub reachable: bool,
    pub paired: bool,
    /// The device asks to be paired: the shell offers to accept.
    pub pair_requested: bool,
    /// The key both screens show while pairing.
    pub verification_key: String,
    /// Percent, -1 when unknown.
    pub battery: i32,
    pub charging: bool,
    /// "5G", "4G"… "" when unknown.
    pub network: String,
    /// 0 to 4, -1 when unknown.
    pub signal: i32,
    pub notifications: Vec<Notification>,
}

#[derive(Serialize, Default)]
pub struct Snapshot {
    /// kdeconnectd answers on the bus.
    pub running: bool,
    /// Paired devices, and those asking to be.
    pub phones: Vec<Phone>,
}

// ── busctl ──────────────────────────────────────────────────────────────────

/// `busctl --user --json=short <args>`: the `data` of each line it prints
/// (one per property for `get-property`, the out arguments for `call`).
/// What was read before a failure is kept: a missing last property does not
/// lose the others.
async fn busctl(args: &[&str]) -> Vec<Value> {
    let child = tokio::process::Command::new("busctl")
        .args(["--user", "--json=short"])
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let Ok(Ok(out)) = tokio::time::timeout(Duration::from_secs(3), child).await else {
        return vec![];
    };
    parse_lines(&String::from_utf8_lossy(&out.stdout))
}

fn parse_lines(text: &str) -> Vec<Value> {
    text.lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter_map(|mut v| v.get_mut("data").map(Value::take))
        .collect()
}

async fn properties(path: &str, iface: &str, names: &[&str]) -> Vec<Value> {
    let mut args = vec!["get-property", DEST, path, iface];
    args.extend_from_slice(names);
    busctl(&args).await
}

/// The first out argument of a method call.
async fn call(path: &str, iface: &str, method: &str, sig_args: &[&str]) -> Option<Value> {
    let mut args = vec!["call", DEST, path, iface, method];
    args.extend_from_slice(sig_args);
    busctl(&args).await.into_iter().next().and_then(|v| match v {
        Value::Array(mut a) if !a.is_empty() => Some(a.swap_remove(0)),
        _ => None,
    })
}

fn string(v: Option<&Value>) -> String {
    v.and_then(Value::as_str).unwrap_or_default().to_string()
}

fn boolean(v: Option<&Value>) -> bool {
    v.and_then(Value::as_bool).unwrap_or(false)
}

fn int(v: Option<&Value>) -> i32 {
    v.and_then(Value::as_i64).map(|n| n as i32).unwrap_or(-1)
}

/// D-Bus path elements are `[A-Za-z0-9_]`: anything else from the shell is
/// refused rather than spliced into a path.
fn valid_element(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

// ── Sampling ────────────────────────────────────────────────────────────────

pub async fn sample() -> Snapshot {
    // Every known device; an empty answer means the daemon is not there.
    let reply = call(ROOT, "org.kde.kdeconnect.daemon", "devices", &["bb", "false", "false"]).await;
    let Some(ids) = reply.as_ref().and_then(Value::as_array) else {
        return Snapshot::default();
    };
    let tasks: Vec<_> = ids
        .iter()
        .filter_map(Value::as_str)
        .filter(|id| valid_element(id))
        .map(|id| tokio::spawn(device(id.to_string())))
        .collect();

    let mut phones = Vec::new();
    for t in tasks {
        if let Ok(Some(p)) = t.await {
            phones.push(p);
        }
    }
    // In reach first, then by name.
    phones.sort_by_key(|p| (!p.reachable, p.name.to_lowercase()));
    Snapshot { running: true, phones }
}

/// One device, if it is paired or asks to be.
async fn device(id: String) -> Option<Phone> {
    let path = format!("{ROOT}/devices/{id}");
    let p = properties(
        &path,
        "org.kde.kdeconnect.device",
        &["name", "type", "isReachable", "isPaired", "isPairRequestedByPeer", "verificationKey"],
    )
    .await;
    let mut phone = Phone {
        id,
        name: string(p.first()),
        kind: string(p.get(1)),
        reachable: boolean(p.get(2)),
        paired: boolean(p.get(3)),
        pair_requested: boolean(p.get(4)),
        verification_key: string(p.get(5)),
        battery: -1,
        signal: -1,
        ..Default::default()
    };
    if !phone.paired && !phone.pair_requested {
        return None;
    }
    // The plugins' objects only exist while the device is connected.
    if !(phone.paired && phone.reachable) {
        return Some(phone);
    }

    let (battery_path, network_path) = (format!("{path}/battery"), format!("{path}/connectivity_report"));
    let (battery, network, notifications) = tokio::join!(
        properties(&battery_path, "org.kde.kdeconnect.device.battery", &["charge", "isCharging"]),
        properties(
            &network_path,
            "org.kde.kdeconnect.device.connectivity_report",
            &["cellularNetworkType", "cellularNetworkStrength"],
        ),
        notifications(&path),
    );
    phone.battery = int(battery.first());
    phone.charging = boolean(battery.get(1));
    phone.network = string(network.first());
    phone.signal = int(network.get(1));
    phone.notifications = notifications;
    Some(phone)
}

async fn notifications(device_path: &str) -> Vec<Notification> {
    let base = format!("{device_path}/notifications");
    let ids = call(&base, "org.kde.kdeconnect.device.notifications", "activeNotifications", &[]).await;
    let ids: Vec<String> = ids
        .as_ref()
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).filter(|i| valid_element(i)).map(str::to_string).collect())
        .unwrap_or_default();

    let mut out = Vec::new();
    for id in ids {
        let p = properties(
            &format!("{base}/{id}"),
            "org.kde.kdeconnect.device.notifications.notification",
            &["appName", "title", "text", "dismissable"],
        )
        .await;
        if p.is_empty() {
            continue;
        }
        out.push(Notification {
            id,
            app: string(p.first()),
            title: string(p.get(1)),
            text: string(p.get(2)),
            dismissable: boolean(p.get(3)),
        });
    }
    // Newest last on the phone; newest first here.
    out.reverse();
    out
}

// ── Actions ─────────────────────────────────────────────────────────────────

/// Act on a device: "ring", "ping", "browse" (its files, in the file
/// manager), "clipboard" (send ours), "share" (`arg`: a path or a file://
/// URL), "accept" / "reject" (a pairing request), "dismiss" (`arg`: a
/// notification id).
pub async fn act(device: &str, action: &str, arg: &str) -> Result<(), String> {
    if !valid_element(device) {
        return Err("appareil inconnu".into());
    }
    let path = format!("{ROOT}/devices/{device}");
    let iface = |plugin: &str| format!("org.kde.kdeconnect.device.{plugin}");

    let (obj, interface, method, args): (String, String, &str, Vec<String>) = match action {
        "ring" => (format!("{path}/findmyphone"), iface("findmyphone"), "ring", vec![]),
        "ping" => (format!("{path}/ping"), iface("ping"), "sendPing", vec![]),
        "browse" => (format!("{path}/sftp"), iface("sftp"), "startBrowsing", vec![]),
        "clipboard" => (format!("{path}/clipboard"), iface("clipboard"), "sendClipboard", vec![]),
        "share" => {
            let url = file_url(arg).ok_or("fichier invalide")?;
            (format!("{path}/share"), iface("share"), "shareUrl", vec!["s".into(), url])
        }
        "accept" => (path.clone(), "org.kde.kdeconnect.device".into(), "acceptPairing", vec![]),
        "reject" => (path.clone(), "org.kde.kdeconnect.device".into(), "cancelPairing", vec![]),
        "dismiss" => {
            if !valid_element(arg) {
                return Err("notification inconnue".into());
            }
            (format!("{path}/notifications/{arg}"), iface("notifications.notification"), "dismiss", vec![])
        }
        _ => return Err(format!("action inconnue : {action}")),
    };

    let mut argv: Vec<&str> = vec!["--user", "call", DEST, &obj, &interface, method];
    argv.extend(args.iter().map(String::as_str));
    let child = tokio::process::Command::new("busctl")
        .args(&argv)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(Duration::from_secs(5), child).await {
        Err(_) => Err("délai dépassé".into()),
        Ok(Err(e)) => Err(format!("busctl : {e}")),
        Ok(Ok(o)) if o.status.success() => Ok(()),
        Ok(Ok(o)) => {
            let err = String::from_utf8_lossy(&o.stderr);
            Err(err.lines().last().unwrap_or("échec").trim().to_string())
        }
    }
}

// ── The screen (scrcpy) ─────────────────────────────────────────────────────

/// scrcpy's port when the phone listens for adb over the network
/// (`adb tcpip 5555`, done once over USB, until the phone restarts).
const ADB_PORT: u16 = 5555;

/// The scrcpy command line that shows phone `name`'s screen. The shell
/// launches it: anna, a user service, has no display to open a window on.
///
/// scrcpy goes through adb, not KDE Connect. A phone adb already sees is
/// taken first, USB before network (wireless debugging pairs once, then adb
/// finds the phone on the Wi-Fi by itself). Otherwise the phone is reached
/// through its Tailscale address, if it listens for adb there.
pub async fn screen(name: &str) -> Result<Vec<String>, String> {
    let devices = adb_devices().await?;
    let serial = match pick_device(&devices) {
        Some(serial) => serial,
        None if devices.iter().any(|(_, state)| state == "unauthorized") => {
            return Err("Autorise cet ordinateur sur l'écran du téléphone, puis réessaie.".into());
        }
        None => match tailnet_address(name).await {
            Some(ip) => adb_connect(&ip).await.ok_or(
                "Injoignable par Tailscale : branche-le une fois en USB et lance « adb tcpip 5555 ».",
            )?,
            None => return Err("Branche le téléphone en USB, avec le débogage USB activé.".into()),
        },
    };
    let mut command: Vec<String> = ["scrcpy", "--serial", &serial, "--window-title"].map(String::from).to_vec();
    command.push(if name.is_empty() { "Téléphone".into() } else { name.to_string() });
    Ok(command)
}

/// `adb` from the system PATH, with a timeout; its stdout.
async fn adb(args: &[&str], secs: u64) -> Result<String, String> {
    let child = tokio::process::Command::new("adb")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(Duration::from_secs(secs), child).await {
        Err(_) => Err("adb ne répond pas.".into()),
        Ok(Err(_)) => Err("adb est introuvable (paquet android-tools).".into()),
        Ok(Ok(o)) => Ok(String::from_utf8_lossy(&o.stdout).into_owned()),
    }
}

/// `(serial, state)` of each device `adb devices` lists.
async fn adb_devices() -> Result<Vec<(String, String)>, String> {
    // The first call also starts adb's server, which takes a moment.
    Ok(parse_adb_devices(&adb(&["devices"], 8).await?))
}

fn parse_adb_devices(text: &str) -> Vec<(String, String)> {
    text.lines()
        .skip_while(|l| !l.starts_with("List of devices"))
        .skip(1)
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            Some((it.next()?.to_string(), it.next()?.to_string()))
        })
        .collect()
}

/// A device ready for scrcpy, USB first (a network serial has a port).
fn pick_device(devices: &[(String, String)]) -> Option<String> {
    let ready: Vec<&String> = devices.iter().filter(|(_, s)| s == "device").map(|(d, _)| d).collect();
    ready.iter().find(|d| !d.contains(':') && !d.contains("._adb")).or(ready.first()).map(|d| d.to_string())
}

/// The Tailscale address of the phone: the online Android device of that
/// name, or the only online one.
async fn tailnet_address(name: &str) -> Option<String> {
    let simple = |s: &str| s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect::<String>();
    let phones: Vec<_> = crate::servers::load()
        .await
        .into_iter()
        .filter(|s| s.online && s.os == "android" && !s.ip.is_empty())
        .collect();
    phones
        .iter()
        .find(|s| simple(&s.name) == simple(name))
        .or(if phones.len() == 1 { phones.first() } else { None })
        .map(|s| s.ip.clone())
}

/// `adb connect`: the serial when the phone answered.
async fn adb_connect(ip: &str) -> Option<String> {
    let serial = format!("{ip}:{ADB_PORT}");
    let out = adb(&["connect", &serial], 6).await.ok()?;
    (out.contains("connected to") && !out.contains("cannot")).then_some(serial)
}

/// A file:// URL for what the shell hands over: a dropped URL as is, an
/// absolute path converted.
fn file_url(arg: &str) -> Option<String> {
    let arg = arg.trim();
    if arg.starts_with("file:///") {
        return Some(arg.to_string());
    }
    if !arg.starts_with('/') {
        return None;
    }
    let mut url = String::from("file://");
    for b in arg.bytes() {
        if b.is_ascii_alphanumeric() || b"/-_.~".contains(&b) {
            url.push(b as char);
        } else {
            url.push_str(&format!("%{b:02X}"));
        }
    }
    Some(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_busctl_json_lines() {
        let out = "{\"type\":\"s\",\"data\":\"Pixel 9a\"}\n{\"type\":\"b\",\"data\":true}\n";
        let v = parse_lines(out);
        assert_eq!(string(v.first()), "Pixel 9a");
        assert!(boolean(v.get(1)));
        assert_eq!(int(v.get(2)), -1);
        // A method call: its out arguments, in one array.
        let v = parse_lines("{\"type\":\"as\",\"data\":[[\"a1_b2\",\"c3\"]]}\n");
        assert_eq!(v[0][0][1], "c3");
    }

    #[test]
    fn refuses_what_is_not_a_path_element() {
        assert!(valid_element("0123abcd_ef"));
        assert!(!valid_element(""));
        assert!(!valid_element("../x"));
        assert!(!valid_element("a b"));
    }

    #[test]
    fn picks_the_usb_phone_first() {
        let out = "* daemon started successfully\nList of devices attached\n\
                   100.71.2.3:5555\tdevice\n0A1B2C3D\tdevice\n\n";
        let devices = parse_adb_devices(out);
        assert_eq!(devices.len(), 2);
        assert_eq!(pick_device(&devices).unwrap(), "0A1B2C3D");
        // Only a phone still waiting for the user's yes: none ready.
        assert!(pick_device(&parse_adb_devices("List of devices attached\nXYZ\tunauthorized\n")).is_none());
    }

    #[test]
    fn makes_file_urls() {
        assert_eq!(file_url("/home/a/Photo été.jpg").unwrap(), "file:///home/a/Photo%20%C3%A9t%C3%A9.jpg");
        assert_eq!(file_url("file:///tmp/x").unwrap(), "file:///tmp/x");
        assert!(file_url("relatif.txt").is_none());
    }
}
