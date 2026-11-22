//! What the globe of the empty desktop tells about a country (the shell's
//! panels/Globe.qml, through services/World.qml):
//!
//!   anna world trends <CC>           → {"ok":true,"date":"2026-11-20",
//!                                       "articles":[{"title","url","lang","views"}…]}
//!   anna world music <CC> <name>     → {"ok":true,"tracks":[{"title","artist","url",
//!                                       "listeners"}…]}
//!   anna world lastfm [<key>|clear]  → {"ok":true,"configured":…}
//!
//! `trends`: the Wikipedia articles most read *from* the country, every
//! language together (Wikimedia's « top per country » pageviews: a day's
//! counts, published the next day). The project's pages — main pages,
//! search, namespaces — are left out. Kept a day in the cache.
//!
//! `music`: the country's most played tracks on Last.fm (`geo.getTopTracks`).
//! Last.fm wants an API key, which the user creates (free) and gives once:
//! it lives in the Secret Service, through `secret-tool`, like the Google
//! token. Last.fm names countries in English, ISO 3166 style, not always as
//! Natural Earth does: a few known names are tried first, then `<name>`.
//! Kept three hours in the cache.
//!
//! The cache is `~/.cache/karenine/world/`.

use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const WIKIMEDIA: &str = "https://wikimedia.org/api/rest_v1/metrics/pageviews/top-per-country";
const LASTFM: &str = "https://ws.audioscrobbler.com/2.0/";

/// Wikimedia asks automated clients to say who they are; nothing personal.
const USER_AGENT: &str = "karenine-globe/0.1 (desktop shell)";

/// How the Last.fm key is filed in the keyring.
const SECRET_SERVICE: &str = "karenine-lastfm";

const TRENDS_KEEP: u64 = 24 * 3600;
const MUSIC_KEEP: u64 = 3 * 3600;
const COUNT: usize = 5;

// ── Plumbing ────────────────────────────────────────────────────────────────

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(8))
        .timeout(Duration::from_secs(20))
        .user_agent(USER_AGENT)
        .build()
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// A day since 1970-01-01 as (year, month, day), proleptic Gregorian
/// (Howard Hinnant's `civil_from_days`).
fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (yoe + era * 400 + i64::from(m <= 2), m, d)
}

fn cache_path(name: &str) -> PathBuf {
    crate::paths::cache_dir().join("world").join(name)
}

/// The cached answer, if younger than `keep` seconds.
fn cached(name: &str, keep: u64) -> Option<Value> {
    let text = std::fs::read_to_string(cache_path(name)).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let at = v["cachedAt"].as_u64()?;
    (now().saturating_sub(at) < keep).then_some(v)
}

fn cache(name: &str, v: &Value) {
    let path = cache_path(name);
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let mut v = v.clone();
    v["cachedAt"] = json!(now());
    let _ = std::fs::write(path, v.to_string());
}

/// An ISO 3166 alpha-2 code, upper case; anything else is refused.
fn country_code(arg: &str) -> Result<String, String> {
    let cc = arg.trim().to_ascii_uppercase();
    if cc.len() == 2 && cc.chars().all(|c| c.is_ascii_uppercase()) {
        Ok(cc)
    } else {
        Err(format!("world : code de pays invalide « {arg} »"))
    }
}

/// A response's body as JSON (anna's ureq is built without its `json`
/// feature).
fn json_of(r: ureq::Response) -> Result<Value, String> {
    let text = r.into_string().map_err(|e| e.to_string())?;
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

// ── Trends ──────────────────────────────────────────────────────────────────

/// The main pages, under the names the big Wikipedias give them outside a
/// namespace (most keep theirs in the project's namespace, left out anyway).
const MAIN_PAGES: &[&str] = &[
    "Main_Page",
    "Hauptseite",
    "Pagina_principale",
    "Página_principal",
    "Strona_główna",
    "Заглавная_страница",
    "Головна_сторінка",
    "Hoofdpagina",
    "メインページ",
    "Wikipedia:首页",
    "-",
];

/// A page of the project rather than an article: a main page, or a title in
/// a namespace (`Spécial:Recherche`, `Wikipedia:…`, `File:…`) — a prefix of
/// one word before the colon. `Star_Wars:_Episode_IV` keeps its place: its
/// prefix has a space.
fn is_project_page(title: &str) -> bool {
    if MAIN_PAGES.contains(&title) {
        return true;
    }
    match title.split_once(':') {
        Some((prefix, rest)) => {
            !prefix.is_empty() && !prefix.contains('_') && !rest.starts_with('_')
        }
        None => false,
    }
}

fn trends(cc: &str) -> Result<Value, String> {
    let name = format!("trends-{cc}.json");
    if let Some(v) = cached(&name, TRENDS_KEEP) {
        return Ok(v);
    }
    // Yesterday's counts are published during the day: before they are,
    // the day before.
    let today = (now() / 86_400) as i64;
    let agent = agent();
    for back in 1..=3 {
        let (y, m, d) = civil(today - back);
        let url = format!("{WIKIMEDIA}/{cc}/all-access/{y}/{m:02}/{d:02}");
        match agent.get(&url).call() {
            Ok(r) => {
                let body = json_of(r).map_err(|e| format!("wikimedia : {e}"))?;
                let articles: Vec<Value> = body["items"][0]["articles"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter_map(|a| {
                        let title = a["article"].as_str()?;
                        let project = a["project"].as_str()?;
                        if is_project_page(title) || !project.ends_with(".wikipedia") {
                            return None;
                        }
                        let lang = project.trim_end_matches(".wikipedia");
                        Some(json!({
                            "title": title.replace('_', " "),
                            "url": format!("https://{project}.org/wiki/{}", encode(title)),
                            "lang": lang,
                            "views": a["views_ceil"].as_u64().unwrap_or(0),
                        }))
                    })
                    .take(COUNT)
                    .collect();
                let v = json!({
                    "ok": true,
                    "date": format!("{y}-{m:02}-{d:02}"),
                    "articles": articles,
                });
                cache(&name, &v);
                return Ok(v);
            }
            // Not published yet, or no data for so small an audience.
            Err(ureq::Error::Status(404, _)) => {}
            Err(e) => return Err(format!("wikimedia : {e}")),
        }
    }
    // Nothing for three days: a country too small for Wikimedia to publish
    // its counts. Not an error, an empty list.
    let v = json!({ "ok": true, "date": "", "articles": [] });
    cache(&name, &v);
    Ok(v)
}

// ── Music ───────────────────────────────────────────────────────────────────

/// Last.fm's names where they differ from Natural Earth's English ones.
fn lastfm_names(cc: &str) -> &'static [&'static str] {
    match cc {
        "US" => &["United States"],
        "GB" => &["United Kingdom"],
        "RU" => &["Russian Federation"],
        "KR" => &["Korea, Republic of"],
        "IR" => &["Iran, Islamic Republic of"],
        "VN" => &["Viet Nam"],
        "SY" => &["Syrian Arab Republic"],
        "TZ" => &["Tanzania, United Republic of"],
        "BO" => &["Bolivia, Plurinational State of", "Bolivia"],
        "VE" => &["Venezuela, Bolivarian Republic of", "Venezuela"],
        "LA" => &["Lao People's Democratic Republic"],
        "MD" => &["Moldova, Republic of", "Moldova"],
        "CZ" => &["Czech Republic", "Czechia"],
        "CD" => &["Congo, The Democratic Republic of the"],
        "CG" => &["Congo"],
        "CI" => &["Cote D'Ivoire"],
        "MK" => &["Macedonia", "North Macedonia"],
        "TW" => &["Taiwan"],
        "CN" => &["China"],
        "BA" => &["Bosnia and Herzegovina"],
        _ => &[],
    }
}

fn secret_attrs() -> [&'static str; 4] {
    ["service", SECRET_SERVICE, "user", "api-key"]
}

fn lastfm_key() -> Option<String> {
    let out = Command::new("secret-tool")
        .arg("lookup")
        .args(secret_attrs())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let key = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !key.is_empty()).then_some(key)
}

fn set_lastfm_key(key: &str) -> Result<(), String> {
    let mut child = Command::new("secret-tool")
        .arg("store")
        .arg("--label=karenine · Last.fm")
        .args(secret_attrs())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("secret-tool : {e}"))?;
    child
        .stdin
        .take()
        .ok_or("secret-tool")?
        .write_all(key.trim().as_bytes())
        .map_err(|e| e.to_string())?;
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(format!(
            "secret-tool : {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

fn clear_lastfm_key() {
    let _ = Command::new("secret-tool")
        .arg("clear")
        .args(secret_attrs())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

fn music(cc: &str, name: &str) -> Result<Value, String> {
    let file = format!("music-{cc}.json");
    if let Some(v) = cached(&file, MUSIC_KEEP) {
        return Ok(v);
    }
    let Some(key) = lastfm_key() else {
        return Ok(json!({ "ok": false, "error": "no-key" }));
    };
    let agent = agent();
    let mut names: Vec<&str> = lastfm_names(cc).to_vec();
    if !name.trim().is_empty() && !names.contains(&name.trim()) {
        names.push(name.trim());
    }
    let mut last = String::from("world : pays inconnu de Last.fm");
    for country in names {
        let url = format!(
            "{LASTFM}?method=geo.gettoptracks&country={}&limit={COUNT}&api_key={}&format=json",
            encode(country),
            encode(&key)
        );
        let body: Value = match agent.get(&url).call() {
            Ok(r) => json_of(r).map_err(|e| format!("last.fm : {e}"))?,
            // Last.fm answers its errors with a JSON body and a 4xx.
            Err(ureq::Error::Status(_, r)) => json_of(r).unwrap_or(Value::Null),
            Err(e) => return Err(format!("last.fm : {e}")),
        };
        if let Some(code) = body["error"].as_u64() {
            // 6: the country is not one Last.fm knows by that name; try the
            // next. 10/26: the key is wrong or suspended.
            if code == 10 || code == 26 {
                return Ok(json!({ "ok": false, "error": "bad-key" }));
            }
            last = format!(
                "last.fm : {}",
                body["message"].as_str().unwrap_or("erreur")
            );
            continue;
        }
        let tracks: Vec<Value> = body["tracks"]["track"]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .take(COUNT)
            .map(|t| {
                json!({
                    "title": t["name"].as_str().unwrap_or(""),
                    "artist": t["artist"]["name"].as_str().unwrap_or(""),
                    "url": t["url"].as_str().unwrap_or(""),
                    "listeners": t["listeners"]
                        .as_str()
                        .and_then(|s| s.parse::<u64>().ok())
                        .unwrap_or(0),
                })
            })
            .collect();
        let v = json!({ "ok": true, "country": country, "tracks": tracks });
        cache(&file, &v);
        return Ok(v);
    }
    Err(last)
}

// ── Entry ───────────────────────────────────────────────────────────────────

pub fn run(args: &[String]) {
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    let result = match arg(2) {
        "trends" => country_code(arg(3)).and_then(|cc| trends(&cc)),
        "music" => country_code(arg(3)).and_then(|cc| music(&cc, arg(4))),
        "lastfm" => match arg(3) {
            "" => Ok(json!({ "ok": true, "configured": lastfm_key().is_some() })),
            "clear" => {
                clear_lastfm_key();
                Ok(json!({ "ok": true, "configured": false }))
            }
            key => set_lastfm_key(key).map(|()| json!({ "ok": true, "configured": true })),
        },
        other => Err(format!("world : action inconnue « {other} »")),
    };
    let line = result.unwrap_or_else(|e| json!({ "ok": false, "error": e }));
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_dates() {
        assert_eq!(civil(0), (1970, 1, 1));
        assert_eq!(civil(19_723), (2024, 1, 1));
        assert_eq!(civil(20_779), (2026, 11, 22));
        assert_eq!(civil(11_016), (2000, 2, 29));
    }

    #[test]
    fn project_pages() {
        assert!(is_project_page("Main_Page"));
        assert!(is_project_page("Spécial:Recherche"));
        assert!(is_project_page("Wikipédia:Accueil_principal"));
        assert!(is_project_page("Special:Search"));
        assert!(!is_project_page("Dominique_de_Villepin"));
        assert!(!is_project_page("Star_Wars:_Episode_IV"));
        assert!(!is_project_page("Hypothèse_de_Riemann"));
    }

    #[test]
    fn codes() {
        assert_eq!(country_code("fr").unwrap(), "FR");
        assert!(country_code("FRA").is_err());
        assert!(country_code("").is_err());
    }
}
