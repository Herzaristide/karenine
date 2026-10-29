//! The account's calendars, over CalDAV, for the « Agenda » tab and the
//! pilot's `agenda`.
//!
//!   anna agenda <from> <to>   → {"ok":true,"calendars":[Calendar…],"events":[Event…]}
//!
//! `from` and `to` are local days (`2026-10-01`), `to` excluded. The query
//! is widened by a day on each side, since the server counts in UTC; the
//! shell keeps what falls on each local day.
//!
//! The calendars are found once (the user's principal, then its calendar
//! home, kept in cloud.json), then listed on every query. The events come
//! from a `calendar-query` with `expand`: the server unrolls the recurring
//! ones over the range and gives every time in UTC, so no time zone or
//! RRULE is read here.
//!
//! Times go to the shell as text: `2026-10-22T14:00:00Z` (UTC),
//! `2026-10-22T14:00:00` (a server that did not convert: local time),
//! `2026-10-22` (all day, `end` excluded).

use super::xml::{self, Node};
use super::{origin, send, Account, Fail};
use serde::Serialize;
use serde_json::json;

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Calendar {
    /// Its path on the server.
    pub id: String,
    pub name: String,
    /// `#rrggbb`, "" when the server has none.
    pub color: String,
}

#[derive(Serialize, Debug, Clone, PartialEq, Default)]
pub struct Event {
    pub calendar: String,
    pub uid: String,
    pub title: String,
    pub location: String,
    pub start: String,
    pub end: String,
    #[serde(rename = "allDay")]
    pub all_day: bool,
}

// ── Dates ───────────────────────────────────────────────────────────────────

/// A date, with a time unless all day.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stamp {
    pub y: i64,
    pub m: u32,
    pub d: u32,
    /// Seconds since midnight.
    pub time: Option<u32>,
    pub utc: bool,
}

/// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m as i64 + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (
        if m <= 2 {
            yoe + era * 400 + 1
        } else {
            yoe + era * 400
        },
        m,
        d,
    )
}

impl Stamp {
    /// `20261022`, `20261022T140000`, `20261022T140000Z`.
    pub fn parse(value: &str) -> Option<Stamp> {
        let v = value.trim();
        let num = |s: &str| s.parse::<u32>().ok();
        if v.len() < 8 || !v.is_char_boundary(8) {
            return None;
        }
        let (y, m, d) = (v[..4].parse().ok()?, num(&v[4..6])?, num(&v[6..8])?);
        if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
            return None;
        }
        let rest = &v[8..];
        if rest.is_empty() {
            return Some(Stamp {
                y,
                m,
                d,
                time: None,
                utc: false,
            });
        }
        let t = rest.strip_prefix('T')?;
        let (t, utc) = match t.strip_suffix('Z') {
            Some(t) => (t, true),
            None => (t, false),
        };
        if t.len() != 6 {
            return None;
        }
        let (h, mi, s) = (num(&t[..2])?, num(&t[2..4])?, num(&t[4..6])?);
        Some(Stamp {
            y,
            m,
            d,
            time: Some(h * 3600 + mi * 60 + s),
            utc,
        })
    }

    /// `2026-10-01` → that day, all day.
    pub fn day(text: &str) -> Option<Stamp> {
        Stamp::parse(&text.replace('-', ""))
    }

    pub fn plus_seconds(self, secs: i64) -> Stamp {
        let total =
            days_from_civil(self.y, self.m, self.d) * 86400 + self.time.unwrap_or(0) as i64 + secs;
        let (y, m, d) = civil_from_days(total.div_euclid(86400));
        Stamp {
            y,
            m,
            d,
            time: self.time.map(|_| total.rem_euclid(86400) as u32),
            utc: self.utc,
        }
    }

    pub fn plus_days(self, days: i64) -> Stamp {
        self.plus_seconds(days * 86400)
    }

    /// As the shell reads it.
    pub fn iso(&self) -> String {
        let date = format!("{:04}-{:02}-{:02}", self.y, self.m, self.d);
        match self.time {
            None => date,
            Some(t) => format!(
                "{date}T{:02}:{:02}:{:02}{}",
                t / 3600,
                t / 60 % 60,
                t % 60,
                if self.utc { "Z" } else { "" }
            ),
        }
    }

    /// As CalDAV's `time-range` wants it: UTC, basic format.
    pub fn caldav(&self) -> String {
        let t = self.time.unwrap_or(0);
        format!(
            "{:04}{:02}{:02}T{:02}{:02}{:02}Z",
            self.y,
            self.m,
            self.d,
            t / 3600,
            t / 60 % 60,
            t % 60
        )
    }

    /// Seconds since the epoch, reading a time without zone as UTC.
    pub fn epoch(&self) -> i64 {
        days_from_civil(self.y, self.m, self.d) * 86400 + self.time.unwrap_or(0) as i64
    }
}

/// `PT1H30M`, `P1D`, `P2W` in seconds; None for anything else (or negative).
pub fn duration(value: &str) -> Option<i64> {
    let v = value.trim().strip_prefix('+').unwrap_or(value.trim());
    let mut rest = v.strip_prefix('P')?;
    let mut secs = 0i64;
    let mut in_time = false;
    while !rest.is_empty() {
        if let Some(r) = rest.strip_prefix('T') {
            in_time = true;
            rest = r;
            continue;
        }
        let digits = rest.find(|c: char| !c.is_ascii_digit())?;
        let n: i64 = rest[..digits].parse().ok()?;
        let unit = rest[digits..].chars().next()?;
        secs += n * match (unit, in_time) {
            ('W', false) => 7 * 86400,
            ('D', false) => 86400,
            ('H', true) => 3600,
            ('M', true) => 60,
            ('S', true) => 1,
            _ => return None,
        };
        rest = &rest[digits + 1..];
    }
    Some(secs)
}

// ── iCalendar ───────────────────────────────────────────────────────────────

/// One content line: its name, its parameters, its value.
struct Line<'a> {
    name: String,
    params: Vec<(String, String)>,
    value: &'a str,
}

impl Line<'_> {
    fn param(&self, key: &str) -> Option<&str> {
        self.params
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}

/// Folded lines joined back (a line that starts with a space or a tab
/// continues the previous one).
fn unfold(text: &str) -> String {
    text.replace("\r\n", "\n")
        .replace("\n ", "")
        .replace("\n\t", "")
}

fn split_line(line: &str) -> Option<Line<'_>> {
    // The value starts at the first colon outside a quoted parameter.
    let mut quoted = false;
    let colon = line.char_indices().find_map(|(i, c)| match c {
        '"' => {
            quoted = !quoted;
            None
        }
        ':' if !quoted => Some(i),
        _ => None,
    })?;
    let mut parts = line[..colon].split(';');
    let name = parts.next()?.trim().to_ascii_uppercase();
    let params = parts
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| {
            (
                k.trim().to_ascii_uppercase(),
                v.trim_matches('"').to_string(),
            )
        })
        .collect();
    Some(Line {
        name,
        params,
        value: &line[colon + 1..],
    })
}

/// `\n`, `\,`, `\;`, `\\` back to their characters.
fn unescape_text(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    let mut chars = v.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n' | 'N') => out.push('\n'),
            Some(o) => out.push(o),
            None => {}
        }
    }
    out
}

/// The events of one calendar object (several when the server expanded a
/// recurring one). Cancelled ones are left out.
pub fn events(ics: &str, calendar: &str) -> Vec<Event> {
    let mut out = Vec::new();
    let text = unfold(ics);
    // The components open around the line: VCALENDAR, VEVENT, VALARM…
    let mut stack: Vec<String> = Vec::new();
    let mut ev = Event::default();
    let (mut start, mut end, mut dur) = (None, None, None);
    let mut cancelled = false;
    for raw in text.lines() {
        let Some(line) = split_line(raw) else {
            continue;
        };
        match line.name.as_str() {
            "BEGIN" => {
                let comp = line.value.trim().to_ascii_uppercase();
                if comp == "VEVENT" {
                    ev = Event {
                        calendar: calendar.to_string(),
                        ..Default::default()
                    };
                    (start, end, dur, cancelled) = (None, None, None, false);
                }
                stack.push(comp);
                continue;
            }
            "END" => {
                if stack.pop().as_deref() == Some("VEVENT") && !cancelled {
                    if let Some(s) = start {
                        out.push(finish(ev.clone(), s, end, dur));
                    }
                }
                continue;
            }
            _ => {}
        }
        // Only the event's own properties: not those of its alarms.
        if stack.last().map(String::as_str) != Some("VEVENT") {
            continue;
        }
        match line.name.as_str() {
            "UID" => ev.uid = line.value.trim().to_string(),
            "SUMMARY" => ev.title = unescape_text(line.value),
            "LOCATION" => ev.location = unescape_text(line.value),
            "STATUS" => cancelled = line.value.trim().eq_ignore_ascii_case("CANCELLED"),
            "DTSTART" => start = stamp(&line),
            "DTEND" => end = stamp(&line),
            "DURATION" => dur = duration(line.value),
            _ => {}
        }
    }
    out
}

fn stamp(line: &Line) -> Option<Stamp> {
    let mut s = Stamp::parse(line.value)?;
    if line.param("VALUE") == Some("DATE") {
        s.time = None;
    }
    Some(s)
}

/// The event's end: DTEND, else DTSTART plus DURATION, else a day for an
/// all-day event and nothing for the others.
fn finish(mut ev: Event, start: Stamp, end: Option<Stamp>, dur: Option<i64>) -> Event {
    let all_day = start.time.is_none();
    let end = end.unwrap_or_else(|| match (dur, all_day) {
        (Some(secs), _) => start.plus_seconds(secs),
        (None, true) => start.plus_days(1),
        (None, false) => start,
    });
    ev.start = start.iso();
    ev.end = end.iso();
    ev.all_day = all_day;
    ev
}

// ── CalDAV ──────────────────────────────────────────────────────────────────

const PRINCIPAL: &str =
    r#"<d:propfind xmlns:d="DAV:"><d:prop><d:current-user-principal/></d:prop></d:propfind>"#;
const HOME: &str = r#"<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-home-set/></d:prop></d:propfind>"#;
const CALENDARS: &str = r#"<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/"><d:prop><d:resourcetype/><d:displayname/><a:calendar-color/><c:supported-calendar-component-set/></d:prop></d:propfind>"#;

fn query(start: &Stamp, end: &Stamp) -> String {
    let (s, e) = (start.caldav(), end.caldav());
    format!(
        r#"<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><c:calendar-data><c:expand start="{s}" end="{e}"/></c:calendar-data></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:time-range start="{s}" end="{e}"/></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"#
    )
}

fn dav(account: &Account, method: &str, url: &str, depth: &str, body: &str) -> Result<Node, Fail> {
    let req = account.request(method, url).set("Depth", depth);
    let text = send(req, Some(("application/xml; charset=utf-8", body)))?;
    xml::parse(&text).map_err(Fail::Net)
}

/// The `prop` of each `response` whose status is 200, with its `href`.
fn props(root: &Node) -> Vec<(String, &Node)> {
    let mut out = Vec::new();
    for r in root.children.iter().filter(|c| c.name == "response") {
        let href = r
            .child("href")
            .map(|h| h.text.trim().to_string())
            .unwrap_or_default();
        for ps in r.children.iter().filter(|c| c.name == "propstat") {
            let ok = ps.child("status").is_none_or(|s| s.text.contains(" 200"));
            if let (true, Some(p)) = (ok, ps.child("prop")) {
                out.push((href.clone(), p));
            }
        }
    }
    out
}

fn href_in(root: &Node, prop: &str) -> Option<String> {
    props(root)
        .into_iter()
        .find_map(|(_, p)| {
            p.find(prop)?
                .child("href")
                .map(|h| h.text.trim().to_string())
        })
        .filter(|h| !h.is_empty())
}

/// The calendar home: kept in cloud.json once found.
fn home(account: &mut Account) -> Result<String, String> {
    if !account.config.calendar_home.is_empty() {
        return Ok(account.config.calendar_home.clone());
    }
    let root = format!("{}/remote.php/dav/", account.config.server);
    let found = dav(account, "PROPFIND", &root, "0", PRINCIPAL).map_err(|e| e.to_string())?;
    let principal = href_in(&found, "current-user-principal")
        .ok_or_else(|| crate::i18n::tr("cloud.no_calendar"))?;
    let found = dav(account, "PROPFIND", &principal, "0", HOME).map_err(|e| e.to_string())?;
    let home =
        href_in(&found, "calendar-home-set").ok_or_else(|| crate::i18n::tr("cloud.no_calendar"))?;
    account.config.calendar_home = home.clone();
    let _ = account.config.save();
    Ok(home)
}

/// `#RRGGBBAA` → `#rrggbb`.
fn color(text: &str) -> String {
    let t = text.trim();
    if t.len() >= 7 && t.starts_with('#') && t[1..7].chars().all(|c| c.is_ascii_hexdigit()) {
        t[..7].to_ascii_lowercase()
    } else {
        String::new()
    }
}

/// The event calendars of a home's listing.
pub fn calendars(root: &Node) -> Vec<Calendar> {
    props(root)
        .into_iter()
        .filter(|(_, p)| {
            p.child("resourcetype")
                .is_some_and(|r| r.child("calendar").is_some())
        })
        .filter(|(_, p)| {
            // No set given: a calendar of events.
            p.child("supported-calendar-component-set")
                .is_none_or(|set| {
                    set.children.is_empty()
                        || set
                            .children
                            .iter()
                            .any(|c| c.attr("name") == Some("VEVENT"))
                })
        })
        .map(|(href, p)| Calendar {
            name: p
                .child("displayname")
                .map(|d| d.text.trim().to_string())
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| {
                    href.trim_end_matches('/')
                        .rsplit('/')
                        .next()
                        .unwrap_or("")
                        .to_string()
                }),
            color: p
                .child("calendar-color")
                .map(|c| color(&c.text))
                .unwrap_or_default(),
            id: href,
        })
        .collect()
}

/// The calendars, and their events between two local days (`to` excluded).
pub fn agenda(from: &str, to: &str) -> Result<(Vec<Calendar>, Vec<Event>), String> {
    let bad = || crate::i18n::tr("cloud.bad_dates");
    let (from, to) = (
        Stamp::day(from).ok_or_else(bad)?,
        Stamp::day(to).ok_or_else(bad)?,
    );
    let mut account = Account::load()?;
    let home = home(&mut account)?;
    let listing = match dav(&account, "PROPFIND", &home, "1", CALENDARS) {
        // The home moved (another account on the same server…): found again.
        Err(Fail::Status(404)) => {
            account.config.calendar_home.clear();
            let home = self::home(&mut account)?;
            dav(&account, "PROPFIND", &home, "1", CALENDARS)
        }
        other => other,
    }
    .map_err(|e| e.to_string())?;
    let cals = calendars(&listing);

    let (start, end) = (from.plus_days(-1), to.plus_days(1));
    let body = query(&start, &end);
    let mut events = Vec::new();
    for cal in &cals {
        let url = format!("{}{}", origin(&account.config.server), cal.id);
        let found = dav(&account, "REPORT", &url, "1", &body).map_err(|e| e.to_string())?;
        let mut data = Vec::new();
        found.descendants("calendar-data", &mut data);
        for d in data {
            events.extend(self::events(&d.text, &cal.id));
        }
    }
    events.sort_by(|a, b| a.start.cmp(&b.start).then(a.title.cmp(&b.title)));
    Ok((cals, events))
}

// ── The pilot ───────────────────────────────────────────────────────────────

/// Today, in local time (`date`, which knows the zone).
fn today() -> Option<Stamp> {
    let out = std::process::Command::new("date")
        .arg("+%Y-%m-%d")
        .output()
        .ok()?;
    Stamp::day(String::from_utf8_lossy(&out.stdout).trim())
}

/// The UTC times turned into local ones, all at once (`date -f -`): each as
/// its local day, then how the pilot reads it.
fn local_times(stamps: &[i64]) -> Vec<(String, String)> {
    use std::io::Write;
    let child = std::process::Command::new("date")
        .args(["-f", "-", "+%Y-%m-%d|%a %d/%m %H:%M"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        return Vec::new();
    };
    if let Some(mut stdin) = child.stdin.take() {
        let lines: String = stamps.iter().map(|s| format!("@{s}\n")).collect();
        let _ = stdin.write_all(lines.as_bytes());
    }
    child
        .wait_with_output()
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .filter_map(|l| l.split_once('|'))
                .map(|(d, t)| (d.to_string(), t.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

/// The pilot's `agenda`: the events between two days, one per line, in
/// local time. By default, the next seven days.
pub fn pilot_read(from: &str, to: &str) -> Result<String, String> {
    let from = Stamp::day(from)
        .or_else(today)
        .ok_or_else(|| crate::i18n::tr("cloud.bad_dates"))?;
    let to = Stamp::day(to).unwrap_or_else(|| from.plus_days(7));
    let (cals, events) = agenda(&from.iso(), &to.iso())?;
    let name = |id: &str| {
        cals.iter()
            .find(|c| c.id == id)
            .map(|c| c.name.clone())
            .unwrap_or_default()
    };
    // The timed events in UTC, converted in one go.
    let starts: Vec<Option<Stamp>> = events
        .iter()
        .map(|e| Stamp::parse(&e.start.replace(['-', ':'], "")).filter(|s| s.utc))
        .collect();
    let utc: Vec<i64> = starts.iter().flatten().map(Stamp::epoch).collect();
    let mut local = local_times(&utc).into_iter();
    let (first, last) = (from.iso(), to.iso());
    let mut lines = Vec::new();
    for (e, start) in events.iter().zip(&starts) {
        // The local day, and how it reads.
        let (day, when) = match start {
            Some(_) => local
                .next()
                .unwrap_or_else(|| (e.start[..10].to_string(), e.start.clone())),
            None if e.all_day => (e.start.clone(), format!("{} (journée)", e.start)),
            None => (e.start[..10].to_string(), e.start.replace('T', " ")),
        };
        // Widened by a day for the time zones: back to the asked range.
        if day < first || day >= last {
            continue;
        }
        let place = if e.location.is_empty() {
            String::new()
        } else {
            format!(" — {}", e.location)
        };
        lines.push(format!(
            "- {when} : {}{place} [{}]",
            e.title,
            name(&e.calendar)
        ));
    }
    Ok(if lines.is_empty() {
        format!("rien entre le {first} et le {last}")
    } else {
        lines.join("\n")
    })
}

// ── The command line ────────────────────────────────────────────────────────

/// `anna agenda <from> <to>`: one JSON line on stdout.
pub fn run(args: &[String]) {
    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    let line = match agenda(arg(2), arg(3)) {
        Ok((calendars, events)) => json!({ "ok": true, "calendars": calendars, "events": events }),
        Err(e) => json!({ "ok": false, "error": e }),
    };
    println!("{line}");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamps_parse_and_move() {
        let s = Stamp::parse("20261031T233000Z").unwrap();
        assert_eq!(s.iso(), "2026-10-31T23:30:00Z");
        assert_eq!(s.plus_seconds(3600).iso(), "2026-11-01T00:30:00Z");
        assert_eq!(Stamp::parse("20261022").unwrap().iso(), "2026-10-22");
        assert_eq!(
            Stamp::parse("20261022T140000").unwrap().iso(),
            "2026-10-22T14:00:00"
        );
        assert_eq!(
            Stamp::day("2026-03-01").unwrap().plus_days(-1).iso(),
            "2026-02-28"
        );
        assert_eq!(
            Stamp::day("2028-03-01").unwrap().plus_days(-1).iso(),
            "2028-02-29"
        );
        assert_eq!(
            Stamp::day("2026-10-01").unwrap().caldav(),
            "20261001T000000Z"
        );
        assert_eq!(Stamp::day("1970-01-02").unwrap().epoch(), 86400);
        assert!(Stamp::parse("2026").is_none());
        assert!(Stamp::parse("20261322").is_none());
    }

    #[test]
    fn durations_parse() {
        assert_eq!(duration("PT1H30M"), Some(5400));
        assert_eq!(duration("P1D"), Some(86400));
        assert_eq!(duration("P2W"), Some(14 * 86400));
        assert_eq!(duration("P1DT2H"), Some(93600));
        assert_eq!(duration("-PT1H"), None);
        assert_eq!(duration("P1H"), None);
    }

    #[test]
    fn events_are_read_from_an_expanded_object() {
        let ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:a1\r\n\
            RECURRENCE-ID:20261022T120000Z\r\nDTSTART:20261022T120000Z\r\nDTEND:20261022T13\r\n 0000Z\r\n\
            SUMMARY:Dentiste\\, contrôle\r\nLOCATION:12 rue X\\nParis\r\n\
            BEGIN:VALARM\r\nTRIGGER:-PT15M\r\nSUMMARY:rappel\r\nEND:VALARM\r\nEND:VEVENT\r\n\
            BEGIN:VEVENT\r\nUID:a1\r\nDTSTART:20261029T120000Z\r\nDURATION:PT45M\r\nSUMMARY:Dentiste\r\nEND:VEVENT\r\n\
            BEGIN:VEVENT\r\nUID:b2\r\nDTSTART;VALUE=DATE:20261101\r\nSUMMARY:Toussaint\r\nEND:VEVENT\r\n\
            BEGIN:VEVENT\r\nUID:c3\r\nDTSTART;TZID=\"Europe/Paris\":20261023T090000\r\nSUMMARY:Local\r\nEND:VEVENT\r\n\
            BEGIN:VEVENT\r\nUID:d4\r\nSTATUS:CANCELLED\r\nDTSTART:20261024T090000Z\r\nSUMMARY:Annulé\r\nEND:VEVENT\r\n\
            END:VCALENDAR\r\n";
        let evs = events(ics, "/cal/perso/");
        assert_eq!(evs.len(), 4);
        assert_eq!(evs[0].title, "Dentiste, contrôle");
        assert_eq!(evs[0].location, "12 rue X\nParis");
        assert_eq!(evs[0].end, "2026-10-22T13:00:00Z");
        assert_eq!(evs[0].calendar, "/cal/perso/");
        assert_eq!(evs[1].end, "2026-10-29T12:45:00Z");
        assert!(evs[2].all_day);
        assert_eq!(
            (evs[2].start.as_str(), evs[2].end.as_str()),
            ("2026-11-01", "2026-11-02")
        );
        assert_eq!(evs[3].start, "2026-10-23T09:00:00");
        assert_eq!(evs[3].end, "2026-10-23T09:00:00");
    }

    #[test]
    fn the_event_calendars_are_listed() {
        let doc = r##"<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav" xmlns:x1="http://apple.com/ns/ical/">
  <d:response><d:href>/remote.php/dav/calendars/u/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/remote.php/dav/calendars/u/personal/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
      <d:displayname>Personnel</d:displayname><x1:calendar-color>#0082C9FF</x1:calendar-color>
      <cal:supported-calendar-component-set><cal:comp name="VEVENT"/></cal:supported-calendar-component-set>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/remote.php/dav/calendars/u/tasks/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/><cal:calendar/></d:resourcetype>
      <d:displayname>Tâches</d:displayname>
      <cal:supported-calendar-component-set><cal:comp name="VTODO"/></cal:supported-calendar-component-set>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
  <d:response><d:href>/remote.php/dav/calendars/u/inbox/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/><cal:schedule-inbox/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>"##;
        let cals = calendars(&xml::parse(doc).unwrap());
        assert_eq!(
            cals,
            vec![Calendar {
                id: "/remote.php/dav/calendars/u/personal/".into(),
                name: "Personnel".into(),
                color: "#0082c9".into(),
            }]
        );
    }

    #[test]
    fn the_query_names_the_range() {
        let q = query(
            &Stamp::day("2026-09-30").unwrap(),
            &Stamp::day("2026-11-02").unwrap(),
        );
        assert!(q.contains(r#"<c:expand start="20260930T000000Z" end="20261102T000000Z"/>"#));
        assert!(q.contains(r#"<c:time-range start="20260930T000000Z""#));
    }
}
