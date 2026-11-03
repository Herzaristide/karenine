//! The account's calendars, for the « Agenda » tab and the pilot's `agenda`.
//!
//!   anna agenda <from> <to>   → {"ok":true,"calendars":[Calendar…],"events":[Event…]}
//!
//! `from` and `to` are local days (`2026-10-01`), `to` excluded. The query
//! is widened by a day on each side, since it is asked in UTC; the shell
//! keeps what falls on each local day.
//!
//! The calendars are those shown in Google Calendar (`calendarList`, the
//! ones ticked); the events come from `events.list` with `singleEvents`:
//! Google unrolls the recurring ones over the range, so no RRULE is read
//! here.
//!
//! Times go to the shell as text: `2026-10-22T12:00:00Z` (Google's
//! `dateTime`, brought back to UTC), `2026-10-22` (all day, `end` excluded).

use super::{encode, Account};
use serde::Serialize;
use serde_json::{json, Value};

const API: &str = "https://www.googleapis.com/calendar/v3";

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Calendar {
    /// Google's id (`primary`'s is the address).
    pub id: String,
    pub name: String,
    /// `#rrggbb`, "" when Google gives none.
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

    /// Seconds since the epoch, reading a time without zone as UTC.
    pub fn epoch(&self) -> i64 {
        days_from_civil(self.y, self.m, self.d) * 86400 + self.time.unwrap_or(0) as i64
    }
}

/// `2026-10-22T14:00:00+02:00`, `…T12:00:00.000Z` → that instant, in UTC.
pub fn rfc3339(text: &str) -> Option<Stamp> {
    let t = text.trim();
    if t.len() < 19 || !t.is_char_boundary(19) {
        return None;
    }
    let (head, mut rest) = t.split_at(19);
    // The fraction of a second, dropped.
    if let Some(r) = rest.strip_prefix('.') {
        rest = r.trim_start_matches(|c: char| c.is_ascii_digit());
    }
    let offset = match rest {
        "Z" | "z" | "" => 0,
        o => {
            let sign = match o.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let (h, m) = o[1..].split_once(':')?;
            sign * (h.parse::<i64>().ok()? * 3600 + m.parse::<i64>().ok()? * 60)
        }
    };
    let mut s = Stamp::parse(&head.replace(['-', ':'], ""))?;
    s.time?;
    s = s.plus_seconds(-offset);
    s.utc = true;
    Some(s)
}

// ── Google ──────────────────────────────────────────────────────────────────

/// `#9FE1E7` → `#9fe1e7`.
fn color(text: &str) -> String {
    let t = text.trim();
    if t.len() == 7 && t.starts_with('#') && t[1..].chars().all(|c| c.is_ascii_hexdigit()) {
        t.to_ascii_lowercase()
    } else {
        String::new()
    }
}

/// The calendars ticked in Google Calendar.
pub fn calendars(items: &[Value]) -> Vec<Calendar> {
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    items
        .iter()
        .filter(|c| c.get("selected").and_then(Value::as_bool) == Some(true))
        .filter(|c| c.get("hidden").and_then(Value::as_bool) != Some(true))
        .map(|c| Calendar {
            id: s(c, "id"),
            name: Some(s(c, "summaryOverride"))
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| s(c, "summary")),
            color: color(&s(c, "backgroundColor")),
        })
        .collect()
}

/// `{"date":…}` or `{"dateTime":…}`.
fn when(v: Option<&Value>) -> Option<Stamp> {
    let v = v?;
    if let Some(d) = v.get("date").and_then(Value::as_str) {
        return Stamp::day(d);
    }
    rfc3339(v.get("dateTime")?.as_str()?)
}

/// One calendar's events, as Google lists them. Cancelled ones are left out.
pub fn events(items: &[Value], calendar: &str) -> Vec<Event> {
    let s = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_string();
    items
        .iter()
        .filter(|e| s(e, "status") != "cancelled")
        .filter_map(|e| {
            let start = when(e.get("start"))?;
            let all_day = start.time.is_none();
            let end =
                when(e.get("end")).unwrap_or_else(
                    || {
                        if all_day {
                            start.plus_days(1)
                        } else {
                            start
                        }
                    },
                );
            Some(Event {
                calendar: calendar.to_string(),
                uid: s(e, "id"),
                title: s(e, "summary"),
                location: s(e, "location"),
                start: start.iso(),
                end: end.iso(),
                all_day,
            })
        })
        .collect()
}

/// `2026-10-01` (local) → `2026-10-01T00:00:00Z`, as `timeMin` wants it.
fn bound(day: &Stamp) -> String {
    format!("{}T00:00:00Z", day.iso())
}

/// The calendars, and their events between two local days (`to` excluded).
pub fn agenda(from: &str, to: &str) -> Result<(Vec<Calendar>, Vec<Event>), String> {
    let bad = || crate::i18n::tr("google.bad_dates");
    let (from, to) = (
        Stamp::day(from).ok_or_else(bad)?,
        Stamp::day(to).ok_or_else(bad)?,
    );
    let mut account = Account::load()?;
    let cals = calendars(&account.list(&format!("{API}/users/me/calendarList?maxResults=250"))?);

    let (start, end) = (bound(&from.plus_days(-1)), bound(&to.plus_days(1)));
    let mut events = Vec::new();
    for cal in &cals {
        let url = format!(
            "{API}/calendars/{}/events?singleEvents=true&maxResults=2500&timeMin={}&timeMax={}",
            encode(&cal.id),
            encode(&start),
            encode(&end)
        );
        events.extend(self::events(&account.list(&url)?, &cal.id));
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
        .ok_or_else(|| crate::i18n::tr("google.bad_dates"))?;
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
    // The tasks due in the range, still to do (best effort: the events
    // already answer).
    if let Ok((lists, tasks)) = super::tasks::all() {
        for t in tasks
            .iter()
            .filter(|t| !t.done && t.due.as_str() >= first.as_str() && t.due < last)
        {
            let list = lists
                .iter()
                .find(|l| l.id == t.list)
                .map(|l| l.title.as_str())
                .unwrap_or("");
            lines.push(format!("- {} (tâche) : {} [{list}]", t.due, t.title));
        }
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
            Stamp::day("2026-03-01").unwrap().plus_days(-1).iso(),
            "2026-02-28"
        );
        assert_eq!(
            Stamp::day("2028-03-01").unwrap().plus_days(-1).iso(),
            "2028-02-29"
        );
        assert_eq!(Stamp::day("1970-01-02").unwrap().epoch(), 86400);
        assert!(Stamp::parse("2026").is_none());
        assert!(Stamp::parse("20261322").is_none());
    }

    #[test]
    fn google_times_come_back_to_utc() {
        assert_eq!(
            rfc3339("2026-10-22T14:00:00+02:00").unwrap().iso(),
            "2026-10-22T12:00:00Z"
        );
        assert_eq!(
            rfc3339("2026-10-22T23:30:00-05:00").unwrap().iso(),
            "2026-10-23T04:30:00Z"
        );
        assert_eq!(
            rfc3339("2026-10-22T12:00:00.000Z").unwrap().iso(),
            "2026-10-22T12:00:00Z"
        );
        assert!(rfc3339("2026-10-22").is_none());
        assert!(rfc3339("2026-10-22T12:00:00+0x:00").is_none());
    }

    #[test]
    fn the_ticked_calendars_are_listed() {
        let items = vec![
            json!({ "id": "a@gmail.com", "summary": "a@gmail.com", "summaryOverride": "Perso",
                    "backgroundColor": "#9FE1E7", "selected": true, "primary": true }),
            json!({ "id": "fr.french#holiday@group.v.calendar.google.com",
                    "summary": "Jours fériés", "backgroundColor": "#16a765", "selected": true }),
            json!({ "id": "x", "summary": "Pas coché", "backgroundColor": "#000000" }),
            json!({ "id": "y", "summary": "Caché", "selected": true, "hidden": true }),
        ];
        let cals = calendars(&items);
        assert_eq!(cals.len(), 2);
        assert_eq!(
            cals[0],
            Calendar {
                id: "a@gmail.com".into(),
                name: "Perso".into(),
                color: "#9fe1e7".into()
            }
        );
        assert_eq!(cals[1].name, "Jours fériés");
    }

    #[test]
    fn events_are_read() {
        let items = vec![
            json!({ "id": "e1", "status": "confirmed", "summary": "Dentiste", "location": "12 rue X",
                    "start": { "dateTime": "2026-10-22T14:00:00+02:00", "timeZone": "Europe/Paris" },
                    "end": { "dateTime": "2026-10-22T15:00:00+02:00" } }),
            json!({ "id": "e2", "status": "confirmed", "summary": "Toussaint",
                    "start": { "date": "2026-11-01" }, "end": { "date": "2026-11-02" } }),
            json!({ "id": "e3", "status": "cancelled",
                    "start": { "date": "2026-11-03" }, "end": { "date": "2026-11-04" } }),
            json!({ "id": "e4", "status": "confirmed", "start": { "dateTime": "2026-11-05T09:00:00Z" } }),
        ];
        let evs = events(&items, "a@gmail.com");
        assert_eq!(evs.len(), 3);
        assert_eq!(evs[0].start, "2026-10-22T12:00:00Z");
        assert_eq!(evs[0].end, "2026-10-22T13:00:00Z");
        assert_eq!(evs[0].location, "12 rue X");
        assert!(evs[1].all_day);
        assert_eq!(
            (evs[1].start.as_str(), evs[1].end.as_str()),
            ("2026-11-01", "2026-11-02")
        );
        assert_eq!(evs[2].title, "");
        assert_eq!(evs[2].end, evs[2].start);
    }
}
