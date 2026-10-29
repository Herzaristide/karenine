//! The Nextcloud account (Murena, or any other server): where the notes are
//! kept (notes.rs, synced by cloud/notes.rs) and where the « Agenda » tab
//! reads its events (caldav.rs).
//!
//!   anna cloud status              → {"ok":true,"connected":…,"server":…,"user":…,
//!                                     "login":{…}|null,"notes":{"last":…,"error":…}}
//!   anna cloud connect [<server>]  → Nextcloud's login flow, in the browser
//!   anna cloud cancel              → stops a login that waits
//!   anna cloud disconnect          → the app password revoked and forgotten
//!
//! Connecting goes through Nextcloud's « Login Flow v2 »: the browser opens
//! the server's own login page (its two-factor, its SSO), and the server
//! hands anna an app password of its own, which the user can revoke from the
//! server's security settings. The user's password never reaches anna.
//!
//! The account is `~/.config/anna/cloud.json` (server, login name, where the
//! calendars are); the app password lives in the Secret Service (GNOME
//! Keyring), through `secret-tool`. A login that waits for the browser is
//! `$XDG_RUNTIME_DIR/anna-cloud-login.json`, gone at the next boot: the
//! shell reads it through `anna cloud status`.

pub mod caldav;
pub mod notes;
mod xml;

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

/// The server offered when none is given.
pub const DEFAULT_SERVER: &str = "https://murena.io";

/// How the app password is filed in the keyring.
const SECRET_SERVICE: &str = "karenine-cloud";

/// What the server shows in its list of connected devices.
const USER_AGENT: &str = "karenine (anna)";

/// A login flow token lives 20 minutes on the server.
const LOGIN_WAIT: Duration = Duration::from_secs(20 * 60);

// ── The account ─────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Config {
    /// `https://murena.io`, without a trailing slash.
    pub server: String,
    /// The login name the app password belongs to.
    pub user: String,
    /// The calendars' collection, once found (caldav.rs).
    pub calendar_home: String,
}

pub fn config_path() -> PathBuf {
    crate::paths::home_dir().join(".config/anna/cloud.json")
}

impl Config {
    pub fn load() -> Option<Config> {
        std::fs::read_to_string(config_path())
            .ok()
            .and_then(|t| serde_json::from_str::<Config>(&t).ok())
            .filter(|c| !c.server.is_empty() && !c.user.is_empty())
    }

    pub fn save(&self) -> Result<(), String> {
        let path = config_path();
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let tmp = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
    }

    /// Who the notes were synced for: switching accounts starts afresh.
    pub fn key(&self) -> String {
        format!("{}@{}", self.user, self.server)
    }
}

/// A connected account, ready to make requests.
pub struct Account {
    pub config: Config,
    password: String,
}

impl Account {
    /// The account, with its app password from the keyring.
    pub fn load() -> Result<Account, String> {
        let config = Config::load().ok_or_else(|| crate::i18n::tr("cloud.not_connected"))?;
        let password = secret_lookup(&config)?;
        Ok(Account { config, password })
    }

    fn auth(&self) -> String {
        let pair = format!("{}:{}", self.config.user, self.password);
        format!(
            "Basic {}",
            base64::engine::general_purpose::STANDARD.encode(pair)
        )
    }

    /// A request to `url` (absolute, or a path of the server), signed.
    pub fn request(&self, method: &str, url: &str) -> ureq::Request {
        let url = if url.starts_with("http://") || url.starts_with("https://") {
            url.to_string()
        } else {
            format!("{}{url}", origin(&self.config.server))
        };
        agent()
            .request(method, &url)
            .set("Authorization", &self.auth())
            .set("User-Agent", USER_AGENT)
    }
}

/// The server's scheme and host: where the absolute paths of WebDAV's
/// answers start.
pub fn origin(server: &str) -> String {
    let after = server.find("://").map(|i| i + 3).unwrap_or(0);
    match server[after..].find('/') {
        Some(slash) => server[..after + slash].to_string(),
        None => server.to_string(),
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(8))
        .timeout(Duration::from_secs(30))
        .build()
}

// ── Requests ────────────────────────────────────────────────────────────────

/// Why a request failed: the server's answer, or no answer at all.
#[derive(Debug, PartialEq)]
pub enum Fail {
    Status(u16),
    Net(String),
}

impl std::fmt::Display for Fail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Fail::Status(401) => write!(f, "{}", crate::i18n::tr("cloud.refused")),
            Fail::Status(code) => write!(f, "HTTP {code}"),
            Fail::Net(e) => write!(f, "{e}"),
        }
    }
}

/// Sends a request, with a body of the given type if any, and reads the
/// answer as text.
pub fn send(req: ureq::Request, body: Option<(&str, &str)>) -> Result<String, Fail> {
    let res = match body {
        Some((kind, text)) => req.set("Content-Type", kind).send_string(text),
        None => req.call(),
    };
    match res {
        Ok(r) => r.into_string().map_err(|e| Fail::Net(e.to_string())),
        Err(ureq::Error::Status(code, _)) => Err(Fail::Status(code)),
        Err(ureq::Error::Transport(t)) => Err(Fail::Net(t.to_string())),
    }
}

// ── The keyring ─────────────────────────────────────────────────────────────

fn secret_attrs(config: &Config) -> [String; 6] {
    [
        "service".into(),
        SECRET_SERVICE.into(),
        "server".into(),
        config.server.clone(),
        "user".into(),
        config.user.clone(),
    ]
}

fn secret_lookup(config: &Config) -> Result<String, String> {
    let out = Command::new("secret-tool")
        .arg("lookup")
        .args(secret_attrs(config))
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| format!("secret-tool : {e}"))?;
    let password = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() || password.is_empty() {
        return Err(crate::i18n::tr("cloud.no_secret"));
    }
    Ok(password)
}

fn secret_store(config: &Config, password: &str) -> Result<(), String> {
    let mut child = Command::new("secret-tool")
        .arg("store")
        .arg(format!("--label=karenine · {}", config.key()))
        .args(secret_attrs(config))
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("secret-tool : {e}"))?;
    child
        .stdin
        .take()
        .ok_or("secret-tool")?
        .write_all(password.as_bytes())
        .map_err(|e| e.to_string())?;
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(format!("secret-tool : {err}"));
    }
    Ok(())
}

fn secret_clear(config: &Config) {
    let _ = Command::new("secret-tool")
        .arg("clear")
        .args(secret_attrs(config))
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

// ── The login flow ──────────────────────────────────────────────────────────

/// `murena.io` → `https://murena.io`; a server reached in clear is refused,
/// unless it is this machine.
pub fn normalize(server: &str) -> Result<String, String> {
    let s = server.trim().trim_end_matches('/');
    let s = if s.is_empty() {
        DEFAULT_SERVER.to_string()
    } else if s.contains("://") {
        s.to_string()
    } else {
        format!("https://{s}")
    };
    let local = s.starts_with("http://localhost") || s.starts_with("http://127.0.0.1");
    if !(s.starts_with("https://") || local) {
        return Err(crate::i18n::tr("cloud.https_only"));
    }
    Ok(s)
}

/// A login waiting for the browser, or the last one's failure.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Login {
    /// "pending" or "error".
    pub state: String,
    pub server: String,
    /// The page opened in the browser, to open it again.
    pub url: String,
    pub error: String,
    /// The process that waits: a newer login, or a cancel, ends it.
    pub pid: u32,
}

fn login_path() -> PathBuf {
    PathBuf::from(crate::paths::runtime_dir()).join("anna-cloud-login.json")
}

fn login_read() -> Option<Login> {
    std::fs::read_to_string(login_path())
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
}

fn login_write(login: &Login) {
    let path = login_path();
    let tmp = path.with_extension("json.tmp");
    if let Ok(text) = serde_json::to_string(login) {
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

/// The login flow's two addresses, from the server's first answer.
pub fn flow_urls(answer: &Value) -> Option<(String, String, String)> {
    Some((
        answer.get("login")?.as_str()?.to_string(),
        answer.pointer("/poll/endpoint")?.as_str()?.to_string(),
        answer.pointer("/poll/token")?.as_str()?.to_string(),
    ))
}

/// What the server hands over once the user has said yes.
pub fn flow_result(answer: &Value) -> Option<(String, String, String)> {
    Some((
        answer
            .get("server")?
            .as_str()?
            .trim_end_matches('/')
            .to_string(),
        answer.get("loginName")?.as_str()?.to_string(),
        answer.get("appPassword")?.as_str()?.to_string(),
    ))
}

/// Opens the server's login page and waits (20 minutes at most) for the
/// user to grant access there; then keeps the account.
fn connect(server: &str) -> Result<Config, String> {
    let pid = std::process::id();
    // Pending from the start: any failure, even this one, is shown too.
    let mut login = Login {
        state: "pending".into(),
        server: server.to_string(),
        pid,
        ..Default::default()
    };
    login_write(&login);
    let server = normalize(server)?;
    login.server = server.clone();
    login_write(&login);
    let started = agent()
        .post(&format!("{server}/index.php/login/v2"))
        .set("User-Agent", USER_AGENT);
    let answer = send(started, None).map_err(|e| match e {
        Fail::Status(404) => crate::i18n::tr("cloud.not_nextcloud"),
        e => e.to_string(),
    })?;
    let answer: Value = serde_json::from_str(&answer).map_err(|e| e.to_string())?;
    let (url, endpoint, token) =
        flow_urls(&answer).ok_or_else(|| crate::i18n::tr("cloud.not_nextcloud"))?;
    login_write(&Login {
        state: "pending".into(),
        server: server.clone(),
        url: url.clone(),
        pid,
        ..Default::default()
    });
    let _ = Command::new("xdg-open")
        .arg(&url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    let start = std::time::Instant::now();
    let body = format!("token={}", form_encode(&token));
    loop {
        std::thread::sleep(Duration::from_secs(2));
        // Cancelled, or replaced by a newer login.
        if login_read().map(|l| l.pid) != Some(pid) {
            return Err(crate::i18n::tr("cloud.cancelled"));
        }
        if start.elapsed() > LOGIN_WAIT {
            return Err(crate::i18n::tr("cloud.timeout"));
        }
        let poll = agent().post(&endpoint).set("User-Agent", USER_AGENT);
        match send(poll, Some(("application/x-www-form-urlencoded", &body))) {
            Ok(text) => {
                let answer: Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
                let (server, user, password) =
                    flow_result(&answer).ok_or_else(|| crate::i18n::tr("cloud.not_nextcloud"))?;
                let config = Config {
                    server,
                    user,
                    ..Default::default()
                };
                secret_store(&config, &password)?;
                config.save()?;
                return Ok(config);
            }
            // Not granted yet.
            Err(Fail::Status(404)) => {}
            // The network may come back within the 20 minutes.
            Err(Fail::Net(_)) => {}
            Err(e) => return Err(e.to_string()),
        }
    }
}

fn form_encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The app password revoked on the server (best effort: offline, it stays
/// valid there until removed from its security settings), then forgotten.
fn disconnect() {
    if let Ok(account) = Account::load() {
        let req = account
            .request("DELETE", "/ocs/v2.php/core/apppassword")
            .set("OCS-APIRequest", "true")
            .timeout(Duration::from_secs(8));
        let _ = send(req, None);
        secret_clear(&account.config);
    } else if let Some(config) = Config::load() {
        secret_clear(&config);
    }
    let _ = std::fs::remove_file(config_path());
    let _ = std::fs::remove_file(login_path());
}

fn status() -> Value {
    let config = Config::load();
    let login = login_read();
    let sync = crate::notes::Store::open(&crate::notes::dir()).sync;
    json!({
        "ok": true,
        "connected": config.is_some(),
        "server": config.as_ref().map(|c| c.server.clone()).unwrap_or_default(),
        "user": config.as_ref().map(|c| c.user.clone()).unwrap_or_default(),
        "default_server": DEFAULT_SERVER,
        "login": login,
        "notes": { "last": sync.last, "error": sync.error },
    })
}

// ── The command line ────────────────────────────────────────────────────────

/// `anna cloud …`: one JSON line on stdout.
pub fn run(args: &[String]) {
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    let result = match arg(2) {
        "" | "status" => Ok(status()),
        "connect" => {
            let server = arg(3).to_string();
            connect(&server)
                .map(|c| {
                    let _ = std::fs::remove_file(login_path());
                    json!({ "ok": true, "server": c.server, "user": c.user })
                })
                .inspect_err(|e| {
                    // Only this login's failure: after a cancel, or a newer
                    // login, the file is no longer ours.
                    if login_read().map(|l| l.pid) == Some(std::process::id()) {
                        login_write(&Login {
                            state: "error".into(),
                            server: server.clone(),
                            error: e.clone(),
                            ..Default::default()
                        });
                    }
                })
        }
        "cancel" => {
            let _ = std::fs::remove_file(login_path());
            Ok(json!({ "ok": true }))
        }
        "disconnect" => {
            disconnect();
            Ok(json!({ "ok": true }))
        }
        other => Err(format!("cloud : action inconnue « {other} »")),
    };
    let line = result.unwrap_or_else(|e| json!({ "ok": false, "error": e }));
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn servers_are_normalized() {
        assert_eq!(normalize("").unwrap(), DEFAULT_SERVER);
        assert_eq!(normalize(" murena.io/ ").unwrap(), "https://murena.io");
        assert_eq!(
            normalize("https://cloud.example.org/nextcloud/").unwrap(),
            "https://cloud.example.org/nextcloud"
        );
        assert!(normalize("http://cloud.example.org").is_err());
        assert!(normalize("http://localhost:8080").is_ok());
    }

    #[test]
    fn the_origin_drops_the_path() {
        assert_eq!(origin("https://murena.io"), "https://murena.io");
        assert_eq!(
            origin("https://cloud.example.org/nextcloud"),
            "https://cloud.example.org"
        );
    }

    #[test]
    fn the_login_flow_is_read() {
        let start = json!({
            "poll": { "token": "t0k", "endpoint": "https://murena.io/login/v2/poll" },
            "login": "https://murena.io/login/v2/flow/abc"
        });
        assert_eq!(
            flow_urls(&start).unwrap(),
            (
                "https://murena.io/login/v2/flow/abc".into(),
                "https://murena.io/login/v2/poll".into(),
                "t0k".into()
            )
        );
        let done = json!({ "server": "https://murena.io/", "loginName": "a@murena.io", "appPassword": "p" });
        assert_eq!(
            flow_result(&done).unwrap(),
            ("https://murena.io".into(), "a@murena.io".into(), "p".into())
        );
        assert!(flow_result(&json!({})).is_none());
    }

    #[test]
    fn tokens_are_form_encoded() {
        assert_eq!(form_encode("a+b/c=d"), "a%2Bb%2Fc%3Dd");
        assert_eq!(form_encode("Az09-_.~"), "Az09-_.~");
    }
}
