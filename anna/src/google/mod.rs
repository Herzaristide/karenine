//! The Google account: where the « Agenda » tab reads its events
//! (calendar.rs) and its tasks (tasks.rs).
//!
//!   anna google status             → {"ok":true,"configured":…,"connected":…,
//!                                     "email":…,"login":{…}|null}
//!   anna google client <file>      → the OAuth client, from the JSON Google
//!   anna google client <id> <secret>  gives for a « desktop app »
//!   anna google connect            → Google's consent page, in the browser
//!   anna google cancel             → stops a login that waits
//!   anna google disconnect         → the token revoked and forgotten
//!
//! Google only lets an app in through OAuth, with a client of its own: the
//! user creates one (a « desktop app » in the Google Cloud console, with the
//! Calendar and Tasks APIs enabled) and gives it here once. Connecting is
//! the « loopback » flow: the browser opens Google's consent page, which
//! sends the browser back to a port anna listens on, on this machine only,
//! with a code; anna trades it for a refresh token. The user's password
//! never reaches anna.
//!
//! The client and the account's address are `~/.config/anna/google.json`;
//! the refresh token lives in the Secret Service (GNOME Keyring), through
//! `secret-tool`. The access token it gives (an hour) is kept in
//! `$XDG_RUNTIME_DIR/anna-google-token.json`, so that every `anna agenda`
//! does not ask for a new one. A login that waits for the browser is
//! `$XDG_RUNTIME_DIR/anna-google-login.json`: the shell reads it through
//! `anna google status`.

pub mod calendar;
pub mod tasks;

use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const REVOKE_URL: &str = "https://oauth2.googleapis.com/revoke";

/// The events read, the tasks read and checked off, and who the account is.
const SCOPES: &str = "openid email \
    https://www.googleapis.com/auth/calendar.readonly \
    https://www.googleapis.com/auth/tasks";

/// How the refresh token is filed in the keyring.
const SECRET_SERVICE: &str = "karenine-google";

/// How long the browser has to come back.
const LOGIN_WAIT: Duration = Duration::from_secs(10 * 60);

// ── The account ─────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Config {
    /// The OAuth client the user created.
    pub client_id: String,
    pub client_secret: String,
    /// The account's address, once connected; "" otherwise.
    pub email: String,
}

pub fn config_path() -> PathBuf {
    crate::paths::home_dir().join(".config/anna/google.json")
}

impl Config {
    pub fn load() -> Config {
        std::fs::read_to_string(config_path())
            .ok()
            .and_then(|t| serde_json::from_str::<Config>(&t).ok())
            .unwrap_or_default()
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

    pub fn configured(&self) -> bool {
        !self.client_id.is_empty() && !self.client_secret.is_empty()
    }

    pub fn connected(&self) -> bool {
        self.configured() && !self.email.is_empty()
    }
}

/// The client, from what the console gives: the downloaded JSON
/// (`{"installed":{"client_id":…,"client_secret":…}}`), or the two values.
pub fn client_from(args: &[String]) -> Result<(String, String), String> {
    let bad = || crate::i18n::tr("google.bad_client");
    let first = args.first().map(|s| s.trim()).unwrap_or("");
    let second = args.get(1).map(|s| s.trim()).unwrap_or("");
    if !second.is_empty() {
        return Ok((first.to_string(), second.to_string()));
    }
    let text = std::fs::read_to_string(first).map_err(|_| bad())?;
    let v: Value = serde_json::from_str(&text).map_err(|_| bad())?;
    let c = v.get("installed").ok_or_else(bad)?;
    let get = |k: &str| c.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let (id, secret) = (get("client_id"), get("client_secret"));
    if id.is_empty() || secret.is_empty() {
        return Err(bad());
    }
    Ok((id, secret))
}

// ── Requests ────────────────────────────────────────────────────────────────

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(8))
        .timeout(Duration::from_secs(30))
        .build()
}

/// Why a request failed: Google's answer, or no answer at all.
#[derive(Debug, PartialEq)]
pub enum Fail {
    Status(u16),
    Net(String),
}

impl std::fmt::Display for Fail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Fail::Status(401 | 403) => write!(f, "{}", crate::i18n::tr("google.refused")),
            Fail::Status(code) => write!(f, "HTTP {code}"),
            Fail::Net(e) => write!(f, "{e}"),
        }
    }
}

fn send(req: ureq::Request, body: Option<(&str, &str)>) -> Result<String, Fail> {
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

/// A connected account, ready to make requests.
pub struct Account {
    config: Config,
    token: String,
}

impl Account {
    /// The account, with a valid access token (the cached one, or a new one).
    pub fn load() -> Result<Account, String> {
        let config = Config::load();
        if !config.connected() {
            return Err(crate::i18n::tr("google.not_connected"));
        }
        let token = match cached_token() {
            Some(t) => t,
            None => refresh(&config)?,
        };
        Ok(Account { config, token })
    }

    /// A JSON request to one of Google's APIs. An access token refused
    /// (revoked, expired early) is renewed once.
    pub fn call(&mut self, method: &str, url: &str, body: Option<&Value>) -> Result<Value, String> {
        let attempt = |token: &str| {
            let req = agent()
                .request(method, url)
                .set("Authorization", &format!("Bearer {token}"));
            let body = body.map(Value::to_string);
            send(req, body.as_deref().map(|b| ("application/json", b)))
        };
        let text = match attempt(&self.token) {
            Err(Fail::Status(401)) => {
                self.token = refresh(&self.config)?;
                attempt(&self.token)
            }
            other => other,
        }
        .map_err(|e| e.to_string())?;
        if text.trim().is_empty() {
            return Ok(Value::Null);
        }
        serde_json::from_str(&text).map_err(|e| e.to_string())
    }

    /// Every page of a list (`items`, then `nextPageToken`).
    pub fn list(&mut self, url: &str) -> Result<Vec<Value>, String> {
        let mut items = Vec::new();
        let mut page = String::new();
        loop {
            let sep = if url.contains('?') { '&' } else { '?' };
            let paged = if page.is_empty() {
                url.to_string()
            } else {
                format!("{url}{sep}pageToken={}", encode(&page))
            };
            let v = self.call("GET", &paged, None)?;
            if let Some(list) = v.get("items").and_then(Value::as_array) {
                items.extend(list.iter().cloned());
            }
            match v.get("nextPageToken").and_then(Value::as_str) {
                Some(next) if !next.is_empty() => page = next.to_string(),
                _ => return Ok(items),
            }
        }
    }
}

/// Percent-encoding of everything but the unreserved characters: the ids
/// (`…@group.calendar.google.com`, `#holiday@…`) and the form fields.
pub fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn form(fields: &[(&str, &str)]) -> String {
    fields
        .iter()
        .map(|(k, v)| format!("{k}={}", encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

// ── The tokens ──────────────────────────────────────────────────────────────

fn token_path() -> PathBuf {
    PathBuf::from(crate::paths::runtime_dir()).join("anna-google-token.json")
}

/// The access token of the last hour, while it has a minute left.
fn cached_token() -> Option<String> {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(token_path()).ok()?).ok()?;
    let expires = v.get("expires")?.as_u64()?;
    (expires > now() + 60).then(|| v.get("token")?.as_str().map(str::to_string))?
}

fn cache_token(token: &str, lifetime: u64) {
    use std::os::unix::fs::OpenOptionsExt;
    let text = json!({ "token": token, "expires": now() + lifetime }).to_string();
    let path = token_path();
    let tmp = path.with_extension("json.tmp");
    let written = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .and_then(|mut f| f.write_all(text.as_bytes()));
    if written.is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

/// A new access token, from the refresh token in the keyring.
fn refresh(config: &Config) -> Result<String, String> {
    let refresh_token = secret_lookup(config)?;
    let body = form(&[
        ("client_id", &config.client_id),
        ("client_secret", &config.client_secret),
        ("refresh_token", &refresh_token),
        ("grant_type", "refresh_token"),
    ]);
    let answer = send(
        agent().post(TOKEN_URL),
        Some(("application/x-www-form-urlencoded", &body)),
    )
    .map_err(|e| match e {
        // invalid_grant: revoked from the Google account, or expired.
        Fail::Status(400 | 401) => crate::i18n::tr("google.refused"),
        e => e.to_string(),
    })?;
    let v: Value = serde_json::from_str(&answer).map_err(|e| e.to_string())?;
    let token = v
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| crate::i18n::tr("google.refused"))?
        .to_string();
    cache_token(
        &token,
        v.get("expires_in").and_then(Value::as_u64).unwrap_or(3600),
    );
    Ok(token)
}

// ── The keyring ─────────────────────────────────────────────────────────────

fn secret_attrs(config: &Config) -> [String; 4] {
    [
        "service".into(),
        SECRET_SERVICE.into(),
        "user".into(),
        config.email.clone(),
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
    let token = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if !out.status.success() || token.is_empty() {
        return Err(crate::i18n::tr("google.no_secret"));
    }
    Ok(token)
}

fn secret_store(config: &Config, token: &str) -> Result<(), String> {
    let mut child = Command::new("secret-tool")
        .arg("store")
        .arg(format!("--label=karenine · Google · {}", config.email))
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
        .write_all(token.as_bytes())
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

/// A login waiting for the browser, or the last one's failure.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Login {
    /// "pending" or "error".
    pub state: String,
    /// The page opened in the browser, to open it again.
    pub url: String,
    pub error: String,
    /// The process that waits: a newer login, or a cancel, ends it.
    pub pid: u32,
}

fn login_path() -> PathBuf {
    PathBuf::from(crate::paths::runtime_dir()).join("anna-google-login.json")
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

/// Random text for the state and the PKCE verifier (43 characters, as
/// PKCE wants at least).
fn random() -> Result<String, String> {
    let mut bytes = [0u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|e| e.to_string())?;
    Ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
}

/// The consent page's address.
pub fn auth_url(client_id: &str, redirect: &str, state: &str, verifier: &str) -> String {
    format!(
        "{AUTH_URL}?{}",
        form(&[
            ("client_id", client_id),
            ("redirect_uri", redirect),
            ("response_type", "code"),
            ("scope", SCOPES),
            ("state", state),
            // PKCE, « plain »: no hash to compute, and the code is only
            // traded on this machine, with the client's secret.
            ("code_challenge", verifier),
            ("code_challenge_method", "plain"),
            // A refresh token, every time (Google gives one only on consent).
            ("access_type", "offline"),
            ("prompt", "consent"),
        ])
    )
}

/// `GET /?state=…&code=…` (or `&error=…`): the query's fields.
pub fn callback_fields(request_line: &str) -> Vec<(String, String)> {
    let target = request_line.split_whitespace().nth(1).unwrap_or("");
    let query = target.split_once('?').map(|(_, q)| q).unwrap_or("");
    query
        .split('&')
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| (k.to_string(), decode(v)))
        .collect()
}

fn decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                match u8::from_str_radix(hex, 16) {
                    Ok(b) => {
                        out.push(b);
                        i += 2;
                    }
                    Err(_) => out.push(b'%'),
                }
            }
            b => out.push(b),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// The address in the ID token Google gives with the tokens (its payload,
/// read without checking the signature: it comes straight from Google, over
/// TLS).
pub fn email_of(id_token: &str) -> Option<String> {
    let payload = id_token.split('.').nth(1)?;
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload.trim_end_matches('='))
        .ok()?;
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    v.get("email")?.as_str().map(str::to_string)
}

/// The page the browser shows once back.
fn answer_browser(stream: &mut std::net::TcpStream, ok: bool) {
    let text = if ok {
        crate::i18n::tr("google.page_ok")
    } else {
        crate::i18n::tr("google.page_failed")
    };
    let body = format!(
        "<!DOCTYPE html><meta charset=utf-8><title>karenine</title>\
         <body style=\"font:16px sans-serif;display:grid;place-items:center;height:90vh\">\
         <p>{text}</p>"
    );
    let _ = write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}

/// Opens Google's consent page and waits (10 minutes at most) for the
/// browser to come back with a code; then keeps the account.
fn connect() -> Result<Config, String> {
    let pid = std::process::id();
    // Pending from the start: any failure, even this one, is shown too.
    let mut login = Login {
        state: "pending".into(),
        pid,
        ..Default::default()
    };
    login_write(&login);
    let mut config = Config::load();
    if !config.configured() {
        return Err(crate::i18n::tr("google.no_client"));
    }
    let listener = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let redirect = format!("http://127.0.0.1:{port}");
    let (state, verifier) = (random()?, random()?);
    login.url = auth_url(&config.client_id, &redirect, &state, &verifier);
    login_write(&login);
    let _ = Command::new("xdg-open")
        .arg(&login.url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    let start = std::time::Instant::now();
    let code = loop {
        // Cancelled, or replaced by a newer login.
        if login_read().map(|l| l.pid) != Some(pid) {
            return Err(crate::i18n::tr("google.cancelled"));
        }
        if start.elapsed() > LOGIN_WAIT {
            return Err(crate::i18n::tr("google.timeout"));
        }
        let mut stream = match listener.accept() {
            Ok((s, _)) => s,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(250));
                continue;
            }
            Err(e) => return Err(e.to_string()),
        };
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut buf = [0u8; 4096];
        let n = stream.read(&mut buf).unwrap_or(0);
        let head = String::from_utf8_lossy(&buf[..n]);
        let fields = callback_fields(head.lines().next().unwrap_or(""));
        let field = |k: &str| {
            fields
                .iter()
                .find(|(name, _)| name == k)
                .map(|(_, v)| v.clone())
        };
        // Something else knocking (a favicon…): not ours.
        if field("state").as_deref() != Some(state.as_str()) {
            continue;
        }
        let code = field("code");
        answer_browser(&mut stream, code.is_some());
        break code.ok_or_else(|| crate::i18n::tr("google.denied"))?;
    };

    let body = form(&[
        ("client_id", &config.client_id),
        ("client_secret", &config.client_secret),
        ("code", &code),
        ("code_verifier", &verifier),
        ("redirect_uri", &redirect),
        ("grant_type", "authorization_code"),
    ]);
    let answer = send(
        agent().post(TOKEN_URL),
        Some(("application/x-www-form-urlencoded", &body)),
    )
    .map_err(|e| match e {
        Fail::Status(400 | 401) => crate::i18n::tr("google.bad_client"),
        e => e.to_string(),
    })?;
    let v: Value = serde_json::from_str(&answer).map_err(|e| e.to_string())?;
    let field = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    let refresh_token = field("refresh_token");
    let email = email_of(&field("id_token")).unwrap_or_default();
    if refresh_token.is_empty() || email.is_empty() {
        return Err(crate::i18n::tr("google.refused"));
    }
    // Another account before: its token goes.
    if config.connected() && config.email != email {
        secret_clear(&config);
    }
    config.email = email;
    secret_store(&config, &refresh_token)?;
    config.save()?;
    let access = field("access_token");
    if !access.is_empty() {
        cache_token(
            &access,
            v.get("expires_in").and_then(Value::as_u64).unwrap_or(3600),
        );
    }
    Ok(config)
}

/// The token revoked at Google (best effort: offline, it stays valid until
/// removed from the account's security page), then forgotten. The client
/// stays, for the next connection.
fn disconnect() {
    let mut config = Config::load();
    if let Ok(token) = secret_lookup(&config) {
        let req = agent().post(REVOKE_URL).timeout(Duration::from_secs(8));
        let _ = send(
            req,
            Some((
                "application/x-www-form-urlencoded",
                &form(&[("token", &token)]),
            )),
        );
    }
    secret_clear(&config);
    config.email.clear();
    let _ = config.save();
    let _ = std::fs::remove_file(token_path());
    let _ = std::fs::remove_file(login_path());
}

fn status() -> Value {
    let config = Config::load();
    json!({
        "ok": true,
        "configured": config.configured(),
        "connected": config.connected(),
        "email": config.email,
        "login": login_read(),
    })
}

// ── The command line ────────────────────────────────────────────────────────

/// `anna google …`: one JSON line on stdout.
pub fn run(args: &[String]) {
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    let result = match arg(2) {
        "" | "status" => Ok(status()),
        "client" => client_from(&args[3.min(args.len())..]).and_then(|(id, secret)| {
            let mut config = Config::load();
            // Another client: the account it let in no longer counts.
            if config.client_id != id && config.connected() {
                secret_clear(&config);
                config.email.clear();
                let _ = std::fs::remove_file(token_path());
            }
            config.client_id = id;
            config.client_secret = secret;
            // The last login's failure was about the old client.
            let _ = std::fs::remove_file(login_path());
            config.save().map(|_| status())
        }),
        "connect" => connect()
            .map(|c| {
                let _ = std::fs::remove_file(login_path());
                json!({ "ok": true, "email": c.email })
            })
            .inspect_err(|e| {
                // Only this login's failure: after a cancel, or a newer
                // login, the file is no longer ours.
                if login_read().map(|l| l.pid) == Some(std::process::id()) {
                    login_write(&Login {
                        state: "error".into(),
                        error: e.clone(),
                        ..Default::default()
                    });
                }
            }),
        "cancel" => {
            let _ = std::fs::remove_file(login_path());
            Ok(json!({ "ok": true }))
        }
        "disconnect" => {
            disconnect();
            Ok(json!({ "ok": true }))
        }
        other => Err(format!("google : action inconnue « {other} »")),
    };
    let line = result.unwrap_or_else(|e| json!({ "ok": false, "error": e }));
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_client_is_read_from_googles_file() {
        let dir = std::env::temp_dir().join(format!("anna-google-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("client.json");
        std::fs::write(
            &file,
            r#"{"installed":{"client_id":"123.apps.googleusercontent.com","client_secret":"GOCSPX-x","redirect_uris":["http://localhost"]}}"#,
        )
        .unwrap();
        assert_eq!(
            client_from(&[file.to_string_lossy().into_owned()]).unwrap(),
            ("123.apps.googleusercontent.com".into(), "GOCSPX-x".into())
        );
        std::fs::write(&file, r#"{"web":{"client_id":"a"}}"#).unwrap();
        assert!(client_from(&[file.to_string_lossy().into_owned()]).is_err());
        assert_eq!(
            client_from(&["id".into(), " secret ".into()]).unwrap(),
            ("id".into(), "secret".into())
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_consent_page_asks_for_offline_access() {
        let url = auth_url("cid", "http://127.0.0.1:4242", "st", "ver");
        assert!(url.starts_with(AUTH_URL));
        assert!(url.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A4242"));
        assert!(url.contains("access_type=offline"));
        assert!(url.contains("calendar.readonly"));
        assert!(url.contains("auth%2Ftasks"));
        assert!(url.contains("code_challenge=ver"));
    }

    #[test]
    fn the_callback_is_read() {
        let f = callback_fields("GET /?state=a%2Bb&code=4%2F0Ab-c&scope=email+openid HTTP/1.1");
        assert_eq!(
            f,
            vec![
                ("state".into(), "a+b".into()),
                ("code".into(), "4/0Ab-c".into()),
                ("scope".into(), "email openid".into()),
            ]
        );
        assert!(callback_fields("GET /favicon.ico HTTP/1.1").is_empty());
        assert_eq!(decode("100%"), "100%");
    }

    #[test]
    fn the_email_comes_from_the_id_token() {
        let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(r#"{"email":"a@gmail.com","email_verified":true}"#);
        assert_eq!(
            email_of(&format!("h.{payload}.sig")).as_deref(),
            Some("a@gmail.com")
        );
        assert!(email_of("nope").is_none());
    }

    #[test]
    fn ids_are_encoded() {
        assert_eq!(
            encode("fr.french#holiday@group.v.calendar.google.com"),
            "fr.french%23holiday%40group.v.calendar.google.com"
        );
    }
}
