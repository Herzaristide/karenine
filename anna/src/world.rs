//! What the globe of the empty desktop tells about a country (the shell's
//! panels/Globe.qml, through services/World.qml):
//!
//!   anna world apple <CC>        → {"ok":true,"charts":{"paid":[…],"free":[…],
//!                                   "music":[…]}}, each entry
//!                                   {"id","title","artist","url","artwork",
//!                                   "genre"} and, for a book, "cover"
//!   anna world item <CC> <id>    → {"ok":true,"item":{"kind","title","author",
//!                                   "description","price","rating","ratings",
//!                                   "genres","date","publisher","album",
//!                                   "duration","url","cover","artwork",
//!                                   "preview"}}
//!   anna world prefetch [items]  → every country's charts, their covers and
//!                                   their entries' details, into the cache
//!                                   (`items`: the details alone)
//!
//! `apple`: the country's charts on Apple's stores, which Apple publishes
//! without a key (`rss.marketingtools.apple.com`): paid and free ebooks on
//! Apple Books, the most played songs on Apple Music. They are
//! Apple's customers only — on Books, ebook readers — not the whole market.
//! A store missing from the country gives an empty list, not an error.
//!
//! Apple's service is slow and unsteady: a chart it hasn't served lately
//! takes more than the 30 s its gateway waits (a 504, while it goes on being
//! built), and any call may fail with a 502 or 503, the more so the busier
//! it is. `prefetch`, run each morning, goes over every country in waves,
//! each taking again what the one before missed. The books' covers are
//! downloaded with them. A chart is kept a day and a bit, so the globe
//! reads the cache all day; past that, or never fetched, `apple` asks for
//! it the slow way.
//!
//! `item`: the details of an entry of these charts, on demand
//! (`itunes.apple.com/lookup`, the country's store). A book: its summary as
//! plain text, price, readers' rating. A song: also its
//! extract, 30 s of AAC that Apple serves (`preview`). Kept a week; the
//! prefetch takes those it doesn't have, a call per country.
//!
//! The cache is `~/.cache/karenine/world/`, the covers in its `covers/`.

use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const APPLE: &str = "https://rss.marketingtools.apple.com/api/v2";
const LOOKUP: &str = "https://itunes.apple.com/lookup";

/// Says which client asks; nothing personal.
const USER_AGENT: &str = "karenine-globe/0.1 (desktop shell)";

/// A day and a bit: the morning's prefetch, plus room for a late one.
const APPLE_KEEP: u64 = 26 * 3600;
const ITEM_KEEP: u64 = 7 * 24 * 3600;
/// Covers no chart has used for that long are removed.
const COVER_KEEP: u64 = 14 * 24 * 3600;
/// The entries kept of each chart: all of a list of 10 (see `CHARTS`).
const APPLE_COUNT: usize = 10;

/// Each chart's key in the answer and its feed. Apple serves lists of 10,
/// 25, 50 or 100 only; another size may be refused.
const CHARTS: &[(&str, &str)] = &[
    ("paid", "books/top-paid/10/books"),
    ("free", "books/top-free/10/books"),
    ("music", "music/most-played/10/songs"),
];
/// The charts whose entries are books, with a cover.
const BOOK_CHARTS: &[&str] = &["paid", "free"];

/// The globe's countries: the two-letter codes of
/// assets/globe/countries.json.
const COUNTRIES: &str = "\
    AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI \
    BJ BL BM BN BO BR BS BT BW BY BZ CA CD CF CG CH CI CK CL CM CN CO CR CU \
    CV CW CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA \
    GB GD GE GG GH GL GM GN GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL \
    IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB \
    LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MR MS \
    MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG \
    PH PK PL PM PN PR PS PT PW PY QA RO RS RU RW SA SB SC SD SE SG SH SI SK \
    SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TL TM TN TO TR TT TV \
    TW TZ UA UG US UY UZ VA VC VE VG VI VN VU WF WS XK YE ZA ZM ZW";

/// Requests at once during the prefetch. Apple answers 503 to many more,
/// once it has had a few thousand in a few minutes.
const WORKERS: usize = 12;
/// The prefetch's waves, a pause before each after the first. Apple's
/// service is unsteady: a chart that came in may fail a minute later, one
/// that failed comes in the next time, and fewer fail the lighter the load.
/// Each wave takes again the charts the one before missed; the waves stop
/// when one brings nothing more.
const WAVES: usize = 12;
const PAUSE: Duration = Duration::from_secs(30);
/// Between two Lookup calls of the prefetch.
const LOOKUP_PAUSE: Duration = Duration::from_secs(3);

// ── Plumbing ────────────────────────────────────────────────────────────────

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
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

fn agent(timeout: u64) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(8))
        .timeout(Duration::from_secs(timeout))
        .user_agent(USER_AGENT)
        .build()
}

/// `f` over `items`, `workers` at a time; the results in order.
fn pool<T: Sync, R: Send>(items: &[T], workers: usize, f: impl Fn(&T) -> R + Sync) -> Vec<R> {
    let next = AtomicUsize::new(0);
    let mut out: Vec<(usize, R)> = std::thread::scope(|s| {
        let jobs: Vec<_> = (0..workers.min(items.len()))
            .map(|_| {
                s.spawn(|| {
                    let mut done = Vec::new();
                    loop {
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        let Some(item) = items.get(i) else { break };
                        done.push((i, f(item)));
                    }
                    done
                })
            })
            .collect();
        jobs.into_iter()
            .flat_map(|j| j.join().unwrap_or_default())
            .collect()
    });
    out.sort_by_key(|(i, _)| *i);
    out.into_iter().map(|(_, r)| r).collect()
}

// ── Apple ───────────────────────────────────────────────────────────────────

fn text(v: &Value) -> String {
    v.as_str().unwrap_or("").to_string()
}

/// One try at one chart. A store Apple doesn't run there answers at once
/// with a 4xx, a 500 or a body that isn't JSON: an empty list. A 502, 503
/// or 504 — a chart still being built — or the network is an error.
fn fetch_chart(agent: &ureq::Agent, cc: &str, path: &str) -> Result<Vec<Value>, String> {
    let url = format!("{APPLE}/{}/{path}.json", cc.to_ascii_lowercase());
    let body = match agent.get(&url).call() {
        Ok(r) => json_of(r).unwrap_or(Value::Null),
        Err(ureq::Error::Status(code, _)) if code <= 500 => Value::Null,
        Err(e) => return Err(format!("apple : {e}")),
    };
    Ok(body["feed"]["results"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
        .iter()
        .take(APPLE_COUNT)
        .map(|r| {
            json!({
                "id": text(&r["id"]),
                "title": text(&r["name"]),
                "artist": text(&r["artistName"]),
                "url": text(&r["url"]),
                "artwork": text(&r["artworkUrl100"]),
                "genre": text(&r["genres"][0]["name"]),
            })
        })
        .collect())
}

/// The artwork at three times its size, as JPEG (a fifth of the PNG's
/// weight): `…/100x150bb.png` → `…/300x450bb.jpg`. Apple's image server
/// takes any size in the name.
fn cover_url(artwork: &str) -> Option<String> {
    let (base, last) = artwork.rsplit_once('/')?;
    let (w, h) = last.split_once("bb.")?.0.split_once('x')?;
    let (w, h): (u32, u32) = (w.parse().ok()?, h.parse().ok()?);
    Some(format!("{base}/{}x{}bb.jpg", w * 3, h * 3))
}

fn cover_path(id: &str) -> PathBuf {
    cache_path("covers").join(format!("{id}.jpg"))
}

/// The book's cover on disk, downloaded if it isn't yet; `None` when it
/// can't be.
fn fetch_cover(agent: &ureq::Agent, id: &str, artwork: &str) -> Option<PathBuf> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let path = cover_path(id);
    if path.exists() {
        return Some(path);
    }
    let r = agent.get(&cover_url(artwork)?).call().ok()?;
    let mut bytes = Vec::new();
    r.into_reader().take(8 << 20).read_to_end(&mut bytes).ok()?;
    std::fs::create_dir_all(path.parent()?).ok()?;
    // Whole or not at all: written aside, then renamed.
    let part = path.with_extension("part");
    std::fs::write(&part, &bytes).ok()?;
    std::fs::rename(&part, &path).ok()?;
    Some(path)
}

/// Each book of `charts` gets `cover`, its file, where there is one.
fn mark_covers(charts: &mut Value) {
    for key in BOOK_CHARTS {
        for e in charts[*key].as_array_mut().into_iter().flatten() {
            let path = cover_path(&text(&e["id"]));
            if !text(&e["id"]).is_empty() && path.exists() {
                e["cover"] = json!(path.to_string_lossy());
            }
        }
    }
}

/// The books of `charts` as `(id, artwork)`.
fn books_of(charts: &Value) -> Vec<(String, String)> {
    BOOK_CHARTS
        .iter()
        .flat_map(|key| charts[*key].as_array().cloned().unwrap_or_default())
        .map(|e| (text(&e["id"]), text(&e["artwork"])))
        .filter(|(id, _)| !id.is_empty())
        .collect()
}

/// The answer for `cc` from what was fetched: a chart that failed keeps
/// the last list known, however old; none, and it is empty.
fn assemble(cc: &str, fetched: &[Option<Vec<Value>>]) -> Value {
    let stale = cached(&format!("apple-{cc}.json"), u64::MAX);
    let mut charts = json!({});
    for ((key, _), got) in CHARTS.iter().zip(fetched) {
        charts[*key] = match got {
            Some(list) => json!(list),
            None => stale
                .as_ref()
                .map(|v| v["charts"][*key].clone())
                .filter(Value::is_array)
                .unwrap_or_else(|| json!([])),
        };
    }
    charts
}

/// The country's charts, from the cache, or else fetched now: all at
/// once, each tried twice, the second time once Apple had time to build it.
fn apple(cc: &str) -> Result<Value, String> {
    let file = format!("apple-{cc}.json");
    // Charts cached with another length are asked again.
    if let Some(v) = cached(&file, APPLE_KEEP).filter(|v| v["count"] == APPLE_COUNT) {
        return Ok(v);
    }
    let agent = agent(40);
    let results = pool(CHARTS, CHARTS.len(), |(_, path)| {
        fetch_chart(&agent, cc, path).or_else(|_| {
            std::thread::sleep(Duration::from_secs(15));
            fetch_chart(&agent, cc, path)
        })
    });
    let reached = results.iter().any(Result::is_ok);
    if !reached && cached(&file, u64::MAX).is_none() {
        return Err(results
            .into_iter()
            .find_map(Result::err)
            .unwrap_or_default());
    }
    let complete = results.iter().all(Result::is_ok);
    let fetched: Vec<Option<Vec<Value>>> = results.into_iter().map(Result::ok).collect();
    let mut charts = assemble(cc, &fetched);
    let books = books_of(&charts);
    pool(&books, books.len().max(1), |(id, art)| {
        fetch_cover(&agent, id, art)
    });
    mark_covers(&mut charts);
    let v = json!({ "ok": true, "count": APPLE_COUNT, "charts": charts });
    // A chart that failed is asked again next time.
    if complete {
        cache(&file, &v);
    }
    Ok(v)
}

/// Every country's charts and books' covers into the cache, in waves (see
/// the top of the file). Progress goes to stderr.
fn prefetch() -> Result<Value, String> {
    let start = Instant::now();
    let ccs: Vec<&str> = COUNTRIES.split_whitespace().collect();
    let agent = agent(40);
    let mut got: HashMap<(usize, usize), Vec<Value>> = HashMap::new();
    let mut pending: Vec<(usize, usize)> = (0..ccs.len())
        .flat_map(|c| (0..CHARTS.len()).map(move |k| (c, k)))
        .collect();
    let mut error = String::new();
    for wave in 0..WAVES {
        if pending.is_empty() {
            break;
        }
        if wave > 0 {
            std::thread::sleep(PAUSE);
        }
        let results = pool(&pending, WORKERS, |&(c, k)| {
            fetch_chart(&agent, ccs[c], CHARTS[k].1)
        });
        let before = got.len();
        let mut again = Vec::new();
        let mut kinds: HashMap<String, usize> = HashMap::new();
        for (job, r) in pending.iter().zip(results) {
            match r {
                Ok(list) => {
                    got.insert(*job, list);
                }
                Err(e) => {
                    *kinds.entry(error_kind(&e)).or_default() += 1;
                    error = e;
                    again.push(*job);
                }
            }
        }
        let mut kinds: Vec<String> = kinds.iter().map(|(k, n)| format!("{k} ×{n}")).collect();
        kinds.sort();
        eprintln!(
            "world : vague {} — {} classements reçus, {} à reprendre [{}] ({} s)",
            wave + 1,
            got.len(),
            again.len(),
            kinds.join(", "),
            start.elapsed().as_secs()
        );
        let stuck = wave > 0 && got.len() == before;
        pending = again;
        if stuck {
            break;
        }
    }
    if got.is_empty() {
        return Err(error);
    }

    // Each country's answer, then the covers of all their books.
    let mut answers: Vec<(&str, Value)> = ccs
        .iter()
        .enumerate()
        .map(|(c, cc)| {
            let fetched: Vec<Option<Vec<Value>>> =
                (0..CHARTS.len()).map(|k| got.remove(&(c, k))).collect();
            (*cc, assemble(cc, &fetched))
        })
        .collect();
    let mut seen = HashSet::new();
    let books: Vec<(String, String)> = answers
        .iter()
        .flat_map(|(_, charts)| books_of(charts))
        .filter(|(id, _)| seen.insert(id.clone()))
        .collect();
    let covers = pool(&books, WORKERS, |(id, art)| fetch_cover(&agent, id, art));
    let cover_count = covers.iter().flatten().count();
    for (cc, charts) in answers.iter_mut() {
        mark_covers(charts);
        cache(
            &format!("apple-{cc}.json"),
            &json!({ "ok": true, "count": APPLE_COUNT, "charts": charts }),
        );
    }
    prune_covers(&seen);
    eprintln!(
        "world : {cover_count} couvertures sur {} ({} s)",
        books.len(),
        start.elapsed().as_secs()
    );
    let items = prefetch_items(&agent, &answers);
    eprintln!("world : {items} fiches ({} s)", start.elapsed().as_secs());
    Ok(json!({
        "ok": true,
        "countries": ccs.len(),
        "missing": pending.len(),
        "covers": cover_count,
        "items": items,
        "seconds": start.elapsed().as_secs(),
    }))
}

/// The prefetch's last step alone, over the charts already in the cache.
fn prefetch_items_only() -> Result<Value, String> {
    let start = Instant::now();
    let answers: Vec<(&str, Value)> = COUNTRIES
        .split_whitespace()
        .filter_map(|cc| {
            Some((
                cc,
                cached(&format!("apple-{cc}.json"), u64::MAX)?["charts"].clone(),
            ))
        })
        .collect();
    let items = prefetch_items(&agent(40), &answers);
    Ok(json!({ "ok": true, "items": items, "seconds": start.elapsed().as_secs() }))
}

/// An error in a word, for the prefetch's log: the status, or the kind of
/// network failure.
fn error_kind(e: &str) -> String {
    if let Some(code) = e.split("status code ").nth(1) {
        return code.chars().take(3).collect();
    }
    if e.contains("timed out") {
        "délai".into()
    } else {
        "réseau".into()
    }
}

/// Removes the covers no chart uses that are older than `COVER_KEEP`.
fn prune_covers(used: &HashSet<String>) {
    let Ok(dir) = std::fs::read_dir(cache_path("covers")) else {
        return;
    };
    for f in dir.flatten() {
        let path = f.path();
        let id = path
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        let old = f
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.elapsed().ok())
            .is_some_and(|age| age.as_secs() > COVER_KEEP);
        if old && !used.contains(&id) {
            let _ = std::fs::remove_file(path);
        }
    }
}

// ── Book ────────────────────────────────────────────────────────────────────

/// Apple's HTML summaries as plain text: line breaks for `<br>` and the
/// ends of paragraphs, the other tags dropped, entities decoded, at most
/// one blank line in a row.
fn plain(html: &str) -> String {
    let mut out = String::new();
    let mut rest = html;
    while let Some(i) = rest.find('<') {
        out.push_str(&rest[..i]);
        let Some(j) = rest[i..].find('>') else {
            rest = &rest[i..];
            break;
        };
        let tag = rest[i + 1..i + j]
            .trim_start_matches('/')
            .to_ascii_lowercase();
        let name = tag
            .split(|c: char| c.is_whitespace() || c == '/')
            .next()
            .unwrap_or("");
        if matches!(name, "br" | "p" | "div" | "li") {
            out.push('\n');
        }
        rest = &rest[i + j + 1..];
    }
    out.push_str(rest);
    let out = decode_entities(&out);
    let mut text = String::new();
    let mut blank = 0;
    for line in out.lines().map(str::trim) {
        if line.is_empty() {
            blank += 1;
            continue;
        }
        if !text.is_empty() {
            text.push_str(if blank > 0 { "\n\n" } else { "\n" });
        }
        text.push_str(line);
        blank = 0;
    }
    text
}

fn decode_entities(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        let after = &rest[i + 1..];
        let end = after.find(';').filter(|&e| e <= 8);
        let decoded = end.and_then(|e| {
            let name = &after[..e];
            let c = match name {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some('\u{a0}'),
                _ => name
                    .strip_prefix("#x")
                    .and_then(|h| u32::from_str_radix(h, 16).ok())
                    .or_else(|| name.strip_prefix('#').and_then(|d| d.parse().ok()))
                    .and_then(char::from_u32),
            }?;
            Some((c, e))
        });
        match decoded {
            Some((c, e)) => {
                out.push(c);
                rest = &after[e + 1..];
            }
            None => {
                out.push('&');
                rest = after;
            }
        }
    }
    out.push_str(rest);
    out
}

/// A price as the store writes it, where Lookup gives only the number
/// (songs): the common currencies by their sign, the others by code.
fn money(p: f64, currency: &str) -> String {
    let n = format!("{p:.2}");
    match currency {
        "EUR" => format!("{} €", n.replace('.', ",")),
        "USD" => format!("${n}"),
        "GBP" => format!("£{n}"),
        "JPY" => format!("¥{p:.0}"),
        _ => format!("{n} {currency}"),
    }
}

/// A store link without its tracking parameter.
fn clean_url(url: &str) -> String {
    url.split_once('?').map_or(url, |(u, _)| u).to_string()
}

/// Lookup in the country's store; its results as they come.
fn lookup(agent: &ureq::Agent, cc: &str, ids: &[String]) -> Result<Vec<Value>, String> {
    let url = format!(
        "{LOOKUP}?id={}&country={}",
        ids.join(","),
        cc.to_ascii_lowercase()
    );
    let body = agent
        .get(&url)
        .call()
        .map_err(|e| format!("itunes : {e}"))
        .and_then(|r| json_of(r).map_err(|e| format!("itunes : {e}")))?;
    Ok(body["results"].as_array().cloned().unwrap_or_default())
}

/// The Apple identifier of a Lookup result.
fn result_id(r: &Value) -> String {
    r["trackId"]
        .as_u64()
        .map(|n| n.to_string())
        .unwrap_or_default()
}

/// An entry's details from its Lookup result, as `item` answers them. A
/// book's cover is downloaded if it isn't yet.
fn item_of(agent: &ureq::Agent, r: &Value) -> Value {
    let id = result_id(r);
    let song = r["kind"] == "song";
    let price = match r["formattedPrice"].as_str() {
        Some(p) => p.to_string(),
        None => match r[if song { "trackPrice" } else { "price" }].as_f64() {
            Some(0.0) => "Gratuit".to_string(),
            Some(p) if p > 0.0 => money(p, &text(&r["currency"])),
            _ => String::new(),
        },
    };
    let genres: Vec<Value> = match r["genres"].as_array() {
        // « Livres » is the store itself, not a genre.
        Some(g) => g
            .iter()
            .filter(|g| *g != "Books" && *g != "Livres")
            .cloned()
            .collect(),
        None => vec![r["primaryGenreName"].clone()],
    };
    let art = text(&r["artworkUrl100"]);
    // A book's cover is kept on disk, like the charts'; a song's artwork is
    // only shown, from Apple.
    let cover = if song {
        String::new()
    } else {
        fetch_cover(agent, &id, &art)
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_default()
    };
    json!({
        "ok": true,
        "item": {
            "id": id,
            "kind": if song { "song" } else { "ebook" },
            "title": text(&r["trackName"]),
            "author": text(&r["artistName"]),
            "description": plain(&text(&r["description"])),
            "price": price,
            "rating": r["averageUserRating"].as_f64().unwrap_or(0.0),
            "ratings": r["userRatingCount"].as_u64().unwrap_or(0),
            "genres": genres,
            "date": text(&r["releaseDate"]).chars().take(10).collect::<String>(),
            "publisher": text(&r["copyright"]),
            "album": if song { text(&r["collectionName"]) } else { String::new() },
            "duration": r["trackTimeMillis"].as_u64().unwrap_or(0) / 1000,
            "url": clean_url(&text(&r["trackViewUrl"])),
            "cover": cover,
            "artwork": cover_url(&art).unwrap_or(art),
            "preview": text(&r["previewUrl"]),
        }
    })
}

fn item_file(cc: &str, id: &str) -> String {
    format!("item-{cc}-{id}.json")
}

fn item(cc: &str, id: &str) -> Result<Value, String> {
    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
        return Err(format!("world : identifiant invalide « {id} »"));
    }
    let file = item_file(cc, id);
    if let Some(v) = cached(&file, ITEM_KEEP) {
        return Ok(v);
    }
    let agent = agent(20);
    let results = lookup(&agent, cc, &[id.to_string()])?;
    let r = results.first().ok_or("itunes : introuvable")?;
    let v = item_of(&agent, r);
    cache(&file, &v);
    Ok(v)
}

/// The details of every entry of the charts not known for a week, a Lookup
/// call per country, a little apart: Lookup is said to take some twenty
/// calls a minute. One refused is tried again a minute later; a country
/// that fails keeps its details for the click. Returns how many were taken.
fn prefetch_items(agent: &ureq::Agent, answers: &[(&str, Value)]) -> usize {
    let mut taken = 0;
    let mut first = true;
    for (cc, charts) in answers {
        let ids: Vec<String> = CHARTS
            .iter()
            .flat_map(|(key, _)| charts[*key].as_array().cloned().unwrap_or_default())
            .map(|e| text(&e["id"]))
            .filter(|id| !id.is_empty() && cached(&item_file(cc, id), ITEM_KEEP).is_none())
            .collect();
        if ids.is_empty() {
            continue;
        }
        if !first {
            std::thread::sleep(LOOKUP_PAUSE);
        }
        first = false;
        let results = lookup(agent, cc, &ids).or_else(|_| {
            std::thread::sleep(Duration::from_secs(60));
            lookup(agent, cc, &ids)
        });
        let Ok(results) = results else {
            eprintln!("world : fiches de {cc} refusées");
            continue;
        };
        for r in &results {
            let id = result_id(r);
            if ids.contains(&id) {
                cache(&item_file(cc, &id), &item_of(agent, r));
                taken += 1;
            }
        }
    }
    taken
}

// ── Entry ───────────────────────────────────────────────────────────────────

pub fn run(args: &[String]) {
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    let result = match arg(2) {
        "apple" => country_code(arg(3)).and_then(|cc| apple(&cc)),
        "item" => country_code(arg(3)).and_then(|cc| item(&cc, arg(4).trim())),
        "prefetch" if arg(3) == "items" => prefetch_items_only(),
        "prefetch" => prefetch(),
        other => Err(format!("world : action inconnue « {other} »")),
    };
    let line = result.unwrap_or_else(|e| json!({ "ok": false, "error": e }));
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes() {
        assert_eq!(country_code("fr").unwrap(), "FR");
        assert!(country_code("FRA").is_err());
        assert!(country_code("").is_err());
    }

    #[test]
    fn covers() {
        assert_eq!(
            cover_url("https://x/a/0004.jpg/100x150bb.png").as_deref(),
            Some("https://x/a/0004.jpg/300x450bb.jpg")
        );
        assert_eq!(
            cover_url("https://x/b/9782.jpg/100x100bb.png").as_deref(),
            Some("https://x/b/9782.jpg/300x300bb.jpg")
        );
        assert!(cover_url("").is_none());
    }

    #[test]
    fn summaries() {
        assert_eq!(
            plain("<b>Une nuit.</b><br /><br />À vingt-quatre ans, l&#39;été &amp; <i>lui</i>."),
            "Une nuit.\n\nÀ vingt-quatre ans, l'été & lui."
        );
        assert_eq!(plain("a<br>b<p>c</p>"), "a\nb\nc");
        assert_eq!(plain("R&D &unknown; 5 &lt; 6"), "R&D &unknown; 5 < 6");
        assert_eq!(money(18.99, "EUR"), "18,99 €");
        assert_eq!(money(4.5, "USD"), "$4.50");
    }

    #[test]
    fn the_countries_are_codes() {
        let ccs: Vec<&str> = COUNTRIES.split_whitespace().collect();
        assert!(ccs.len() > 200);
        assert!(ccs.iter().all(|c| country_code(c).as_deref() == Ok(*c)));
        assert!(ccs.contains(&"FR") && ccs.contains(&"JP"));
    }
}
