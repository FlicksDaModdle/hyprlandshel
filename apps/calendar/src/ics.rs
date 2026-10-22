//! iCalendar (RFC 5545), as much as a calendar needs: events with a
//! title, place, notes, a start and an end (all day, or at a time in UTC, a
//! named zone or floating), a repeat rule and the dates taken out of it.
//! Read from any calendar's .ics; written for the calendars kept here.
//!
//! Lines this doesn't understand are kept and written back as they were,
//! so a calendar made elsewhere loses nothing by being edited here.

use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Utc, Weekday};

#[derive(Clone, Debug, PartialEq)]
pub enum Time {
    /// A whole day (VALUE=DATE).
    Day(NaiveDate),
    /// A moment.
    At(DateTime<Utc>),
}

impl Time {
    /// As shown here: the local wall clock (an all-day date at midnight).
    pub fn local(&self) -> NaiveDateTime {
        match self {
            Time::Day(d) => d.and_hms_opt(0, 0, 0).unwrap(),
            Time::At(t) => t.with_timezone(&Local).naive_local(),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Freq {
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Rule {
    pub freq: Freq,
    pub interval: u32,
    pub count: Option<u32>,
    pub until: Option<Time>,
    pub by_day: Vec<Weekday>,
}

#[derive(Clone, Debug, Default)]
pub struct Event {
    pub uid: String,
    pub summary: String,
    pub location: String,
    pub notes: String,
    pub start: Option<Time>,
    pub end: Option<Time>,
    pub rule: Option<Rule>,
    pub except: Vec<Time>,
    /// The VEVENT's other lines, written back untouched.
    pub extra: Vec<String>,
}

impl Event {
    pub fn all_day(&self) -> bool {
        matches!(self.start, Some(Time::Day(_)))
    }

    /// How long one occurrence lasts: to DTEND (or DURATION), else a day
    /// for an all-day event and nothing for a moment.
    pub fn length(&self) -> Duration {
        match (&self.start, &self.end) {
            (Some(s), Some(e)) => (e.local() - s.local()).max(Duration::zero()),
            (Some(Time::Day(_)), None) => Duration::days(1),
            _ => Duration::zero(),
        }
    }
}

// ── reading ──────────────────────────────────────────────────────────────

/// Long lines are folded onto the next with a leading space.
fn unfold(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for l in text.split('\n') {
        let l = l.strip_suffix('\r').unwrap_or(l);
        if (l.starts_with(' ') || l.starts_with('\t')) && !out.is_empty() {
            out.last_mut().unwrap().push_str(&l[1..]);
        } else if !l.is_empty() {
            out.push(l.to_string());
        }
    }
    out
}

struct Prop {
    name: String,
    params: Vec<(String, String)>,
    value: String,
}

impl Prop {
    fn param(&self, k: &str) -> Option<&str> {
        self.params.iter().find(|(n, _)| n.eq_ignore_ascii_case(k)).map(|(_, v)| v.as_str())
    }
}

fn split(line: &str) -> Option<Prop> {
    // The value starts at the first colon outside a quoted parameter.
    let mut quoted = false;
    let mut at = None;
    for (i, c) in line.char_indices() {
        match c {
            '"' => quoted = !quoted,
            ':' if !quoted => {
                at = Some(i);
                break;
            }
            _ => {}
        }
    }
    let at = at?;
    let (head, value) = (&line[..at], &line[at + 1..]);
    let mut parts = head.split(';');
    let name = parts.next()?.trim().to_ascii_uppercase();
    let params = parts
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| (k.trim().to_ascii_uppercase(), v.trim().trim_matches('"').to_string()))
        .collect();
    Some(Prop { name, params, value: value.to_string() })
}

pub fn unescape(v: &str) -> String {
    let mut out = String::with_capacity(v.len());
    let mut it = v.chars();
    while let Some(c) = it.next() {
        if c == '\\' {
            match it.next() {
                Some('n') | Some('N') => out.push('\n'),
                Some(o) => out.push(o),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub fn escape(v: &str) -> String {
    v.replace('\\', "\\\\").replace(';', "\\;").replace(',', "\\,").replace('\n', "\\n")
}

fn parse_date(v: &str) -> Option<NaiveDate> {
    NaiveDate::parse_from_str(v.get(..8)?, "%Y%m%d").ok()
}

fn parse_naive(v: &str) -> Option<NaiveDateTime> {
    let v = v.trim_end_matches('Z');
    NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%S")
        .or_else(|_| NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M"))
        .ok()
}

/// A time in a named zone: an IANA name, or the last part of one after a
/// prefix some programs add ("/mozilla.org/…/Europe/London").
fn zoned(naive: NaiveDateTime, tzid: &str) -> Option<DateTime<Utc>> {
    let tz: chrono_tz::Tz = tzid.parse().ok().or_else(|| {
        let parts: Vec<&str> = tzid.trim_matches('/').split('/').collect();
        (1..parts.len()).rev().find_map(|n| parts[parts.len() - n..].join("/").parse().ok())
    })?;
    tz.from_local_datetime(&naive).earliest().map(|t| t.with_timezone(&Utc))
}

fn local_utc(naive: NaiveDateTime) -> Option<DateTime<Utc>> {
    Local.from_local_datetime(&naive).earliest().map(|t| t.with_timezone(&Utc))
}

fn parse_time(p: &Prop) -> Option<Time> {
    let v = p.value.trim();
    if p.param("VALUE").is_some_and(|x| x.eq_ignore_ascii_case("DATE")) || (v.len() == 8 && !v.contains('T')) {
        return parse_date(v).map(Time::Day);
    }
    let naive = parse_naive(v)?;
    if v.ends_with('Z') {
        return Some(Time::At(Utc.from_utc_datetime(&naive)));
    }
    if let Some(tzid) = p.param("TZID") {
        if let Some(t) = zoned(naive, tzid) {
            return Some(Time::At(t));
        }
    }
    // Floating: the same wall-clock time wherever you are.
    local_utc(naive).map(Time::At)
}

/// "P1D", "PT1H30M", "P2W"…
fn parse_duration(v: &str) -> Option<Duration> {
    let v = v.trim();
    let (neg, v) = match v.strip_prefix('-') { Some(r) => (true, r), None => (false, v.trim_start_matches('+')) };
    let v = v.strip_prefix('P')?;
    let mut total = Duration::zero();
    let mut num = String::new();
    let mut in_time = false;
    for c in v.chars() {
        match c {
            'T' => in_time = true,
            '0'..='9' => num.push(c),
            _ => {
                let n: i64 = num.parse().ok()?;
                num.clear();
                total += match (c, in_time) {
                    ('W', _) => Duration::weeks(n),
                    ('D', _) => Duration::days(n),
                    ('H', true) => Duration::hours(n),
                    ('M', true) => Duration::minutes(n),
                    ('S', true) => Duration::seconds(n),
                    _ => return None,
                };
            }
        }
    }
    Some(if neg { -total } else { total })
}

fn weekday(code: &str) -> Option<Weekday> {
    // "MO", or "1MO" / "-1FR" in a monthly rule: the day is what counts here.
    let code = code.trim_start_matches(|c: char| c == '+' || c == '-' || c.is_ascii_digit());
    Some(match code {
        "MO" => Weekday::Mon,
        "TU" => Weekday::Tue,
        "WE" => Weekday::Wed,
        "TH" => Weekday::Thu,
        "FR" => Weekday::Fri,
        "SA" => Weekday::Sat,
        "SU" => Weekday::Sun,
        _ => return None,
    })
}

fn day_code(d: Weekday) -> &'static str {
    match d {
        Weekday::Mon => "MO",
        Weekday::Tue => "TU",
        Weekday::Wed => "WE",
        Weekday::Thu => "TH",
        Weekday::Fri => "FR",
        Weekday::Sat => "SA",
        Weekday::Sun => "SU",
    }
}

pub fn parse_rule(v: &str) -> Option<Rule> {
    let mut rule = Rule { freq: Freq::Daily, interval: 1, count: None, until: None, by_day: Vec::new() };
    let mut freq = None;
    for part in v.split(';') {
        let Some((k, val)) = part.split_once('=') else { continue };
        match k.to_ascii_uppercase().as_str() {
            "FREQ" => {
                freq = Some(match val {
                    "DAILY" => Freq::Daily,
                    "WEEKLY" => Freq::Weekly,
                    "MONTHLY" => Freq::Monthly,
                    "YEARLY" => Freq::Yearly,
                    _ => return None,
                })
            }
            "INTERVAL" => rule.interval = val.parse().unwrap_or(1).max(1),
            "COUNT" => rule.count = val.parse().ok(),
            "UNTIL" => {
                rule.until = if val.len() == 8 {
                    parse_date(val).map(Time::Day)
                } else {
                    parse_naive(val).map(|n| Time::At(if val.ends_with('Z') { Utc.from_utc_datetime(&n) } else { local_utc(n).unwrap_or(Utc.from_utc_datetime(&n)) }))
                }
            }
            "BYDAY" => rule.by_day = val.split(',').filter_map(weekday).collect(),
            _ => {}
        }
    }
    rule.freq = freq?;
    Some(rule)
}

/// The events in a calendar, and its name if it gives one.
pub fn parse(text: &str) -> (Option<String>, Vec<Event>) {
    let mut name = None;
    let mut events = Vec::new();
    let mut cur: Option<Event> = None;
    let mut duration = None;
    // Inside something within the event (an alarm): kept whole, not read.
    let mut nested: Vec<String> = Vec::new();
    let mut depth = 0;
    for line in unfold(text) {
        let Some(p) = split(&line) else { continue };
        match (p.name.as_str(), p.value.trim().to_ascii_uppercase().as_str()) {
            ("BEGIN", "VEVENT") if cur.is_none() => {
                cur = Some(Event::default());
                duration = None;
                continue;
            }
            ("END", "VEVENT") if depth == 0 => {
                if let Some(mut ev) = cur.take() {
                    if ev.end.is_none() {
                        if let (Some(start), Some(d)) = (&ev.start, duration) {
                            ev.end = Some(match start {
                                Time::Day(day) => Time::Day(*day + d),
                                Time::At(t) => Time::At(*t + d),
                            });
                        }
                    }
                    if ev.start.is_some() {
                        events.push(ev);
                    }
                }
                continue;
            }
            _ => {}
        }
        let Some(ev) = cur.as_mut() else {
            if p.name == "X-WR-CALNAME" {
                name = Some(unescape(&p.value));
            }
            continue;
        };
        if p.name == "BEGIN" {
            depth += 1;
        }
        if depth > 0 {
            nested.push(line.clone());
            if p.name == "END" {
                depth -= 1;
                if depth == 0 {
                    ev.extra.append(&mut nested);
                }
            }
            continue;
        }
        match p.name.as_str() {
            "UID" => ev.uid = p.value.clone(),
            "SUMMARY" => ev.summary = unescape(&p.value),
            "LOCATION" => ev.location = unescape(&p.value),
            "DESCRIPTION" => ev.notes = unescape(&p.value),
            "DTSTART" => ev.start = parse_time(&p),
            "DTEND" => ev.end = parse_time(&p),
            "DURATION" => duration = parse_duration(&p.value),
            "RRULE" => ev.rule = parse_rule(&p.value),
            "EXDATE" => {
                for v in p.value.split(',') {
                    let one = Prop { name: p.name.clone(), params: p.params.clone(), value: v.to_string() };
                    if let Some(t) = parse_time(&one) {
                        ev.except.push(t);
                    }
                }
            }
            "DTSTAMP" | "LAST-MODIFIED" | "CREATED" => {}
            _ => ev.extra.push(line.clone()),
        }
    }
    (name, events)
}

// ── writing ──────────────────────────────────────────────────────────────

fn time_value(t: &Time) -> String {
    match t {
        Time::Day(d) => format!(";VALUE=DATE:{}", d.format("%Y%m%d")),
        Time::At(t) => format!(":{}", t.format("%Y%m%dT%H%M%SZ")),
    }
}

fn rule_value(r: &Rule) -> String {
    let mut out = format!(
        "FREQ={}",
        match r.freq {
            Freq::Daily => "DAILY",
            Freq::Weekly => "WEEKLY",
            Freq::Monthly => "MONTHLY",
            Freq::Yearly => "YEARLY",
        }
    );
    if r.interval > 1 {
        out += &format!(";INTERVAL={}", r.interval);
    }
    if let Some(c) = r.count {
        out += &format!(";COUNT={c}");
    }
    if let Some(u) = &r.until {
        out += &format!(";UNTIL={}", time_value(u).rsplit(':').next().unwrap_or(""));
    }
    if !r.by_day.is_empty() {
        out += &format!(";BYDAY={}", r.by_day.iter().map(|d| day_code(*d)).collect::<Vec<_>>().join(","));
    }
    out
}

/// Lines longer than 75 octets are folded, as the standard asks.
fn fold(line: &str, out: &mut String) {
    let mut n = 0;
    for c in line.chars() {
        if n + c.len_utf8() > 75 {
            out.push_str("\r\n ");
            n = 1;
        }
        out.push(c);
        n += c.len_utf8();
    }
    out.push_str("\r\n");
}

pub fn write(name: &str, events: &[Event]) -> String {
    let mut out = String::new();
    for l in ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Hyprshell//Calendar//EN", "CALSCALE:GREGORIAN"] {
        fold(l, &mut out);
    }
    fold(&format!("X-WR-CALNAME:{}", escape(name)), &mut out);
    let stamp = Utc::now().format("%Y%m%dT%H%M%SZ");
    for ev in events {
        let Some(start) = &ev.start else { continue };
        fold("BEGIN:VEVENT", &mut out);
        fold(&format!("UID:{}", ev.uid), &mut out);
        fold(&format!("DTSTAMP:{stamp}"), &mut out);
        fold(&format!("DTSTART{}", time_value(start)), &mut out);
        if let Some(end) = &ev.end {
            fold(&format!("DTEND{}", time_value(end)), &mut out);
        }
        fold(&format!("SUMMARY:{}", escape(&ev.summary)), &mut out);
        if !ev.location.is_empty() {
            fold(&format!("LOCATION:{}", escape(&ev.location)), &mut out);
        }
        if !ev.notes.is_empty() {
            fold(&format!("DESCRIPTION:{}", escape(&ev.notes)), &mut out);
        }
        if let Some(r) = &ev.rule {
            fold(&format!("RRULE:{}", rule_value(r)), &mut out);
        }
        for x in &ev.except {
            fold(&format!("EXDATE{}", time_value(x)), &mut out);
        }
        for l in &ev.extra {
            fold(l, &mut out);
        }
        fold("END:VEVENT", &mut out);
    }
    fold("END:VCALENDAR", &mut out);
    out
}

// ── occurrences ──────────────────────────────────────────────────────────

/// One time an event happens, on the local clock.
#[derive(Clone, Debug)]
pub struct Occurrence {
    pub start: NaiveDateTime,
    pub end: NaiveDateTime,
    pub all_day: bool,
}

fn add_months(d: NaiveDate, months: i32) -> Option<NaiveDate> {
    let total = d.year() * 12 + d.month0() as i32 + months;
    NaiveDate::from_ymd_opt(total.div_euclid(12), total.rem_euclid(12) as u32 + 1, d.day())
}

/// The times `ev` happens that overlap [from, to): once, or by its rule,
/// less its exceptions.
pub fn occurrences(ev: &Event, from: NaiveDate, to: NaiveDate) -> Vec<Occurrence> {
    let Some(start) = &ev.start else { return Vec::new() };
    let all_day = ev.all_day();
    let first = start.local();
    let length = ev.length();
    let window_start = from.and_time(NaiveTime::MIN);
    let window_end = to.and_time(NaiveTime::MIN);
    let except: Vec<NaiveDateTime> = ev.except.iter().map(|t| t.local()).collect();
    let mut out = Vec::new();
    let mut push = |s: NaiveDateTime| {
        let e = s + length;
        // A moment (no length) still shows on its day.
        let overlaps = if length.is_zero() { s >= window_start && s < window_end } else { e > window_start && s < window_end };
        if overlaps && !except.iter().any(|x| *x == s || (all_day && x.date() == s.date())) {
            out.push(Occurrence { start: s, end: e, all_day });
        }
    };
    let Some(rule) = &ev.rule else {
        push(first);
        return out;
    };
    let until = rule.until.as_ref().map(|u| match u {
        // An all-day UNTIL includes its day.
        Time::Day(d) => d.and_time(NaiveTime::MIN) + Duration::days(1) - Duration::seconds(1),
        t => t.local(),
    });
    let mut made = 0u32;
    let time = first.time();
    let step = rule.interval as i64;
    // Each candidate in order; COUNT counts them all, before the window too.
    let mut k = 0i64;
    'outer: while k < 20_000 {
        let batch: Vec<NaiveDateTime> = match rule.freq {
            Freq::Daily => vec![first + Duration::days(k * step)],
            Freq::Weekly if rule.by_day.is_empty() => vec![first + Duration::days(7 * k * step)],
            Freq::Weekly => {
                // The week (Monday first) k steps on, at the listed days.
                let monday = first.date() - Duration::days(first.weekday().num_days_from_monday() as i64) + Duration::days(7 * k * step);
                let mut days: Vec<NaiveDateTime> =
                    rule.by_day.iter().map(|d| (monday + Duration::days(d.num_days_from_monday() as i64)).and_time(time)).filter(|t| *t >= first).collect();
                days.sort();
                days
            }
            Freq::Monthly => add_months(first.date(), (k * step) as i32).map(|d| vec![d.and_time(time)]).unwrap_or_default(),
            Freq::Yearly => add_months(first.date(), (12 * k * step) as i32).map(|d| vec![d.and_time(time)]).unwrap_or_default(),
        };
        k += 1;
        for s in batch {
            if until.is_some_and(|u| s > u) || s >= window_end {
                break 'outer;
            }
            if rule.count.is_some_and(|c| made >= c) {
                break 'outer;
            }
            made += 1;
            push(s);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-WR-CALNAME:Home\r\n\
BEGIN:VEVENT\r\nUID:a@x\r\nDTSTART;VALUE=DATE:20261024\r\nDTEND;VALUE=DATE:20261025\r\nSUMMARY:Birthday\\, Sam\r\nRRULE:FREQ=YEARLY\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:b@x\r\nDTSTART:20261020T090000Z\r\nDURATION:PT1H30M\r\nSUMMARY:Stand-up meeting with a long title that has to be fol\r\n ded\r\n\
RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=6\r\nEXDATE:20261023T090000Z\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT10M\r\nEND:VALARM\r\nEND:VEVENT\r\n\
BEGIN:VEVENT\r\nUID:c@x\r\nDTSTART;TZID=Europe/London:20261022T140000\r\nDTEND;TZID=Europe/London:20261022T150000\r\nSUMMARY:Dentist\r\nLOCATION:High St\r\nEND:VEVENT\r\n\
END:VCALENDAR\r\n";

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }

    #[test]
    fn reads_events() {
        let (name, evs) = parse(SAMPLE);
        assert_eq!(name.as_deref(), Some("Home"));
        assert_eq!(evs.len(), 3);
        assert_eq!(evs[0].summary, "Birthday, Sam");
        assert!(evs[0].all_day());
        assert_eq!(evs[1].summary, "Stand-up meeting with a long title that has to be folded");
        assert_eq!(evs[1].length(), Duration::minutes(90));
        assert_eq!(evs[1].extra.len(), 4, "the alarm is kept whole");
        assert_eq!(evs[2].start, Some(Time::At(Utc.with_ymd_and_hms(2026, 10, 22, 13, 0, 0).unwrap())), "London in summer time is UTC+1");
    }

    #[test]
    fn repeats() {
        let (_, evs) = parse(SAMPLE);
        // Mon, Wed, Fri from Tue 20 Oct: Wed 21, (Fri 23 taken out), Mon 26, Wed 28, Fri 30, Mon 2 Nov — six counted.
        let occ = occurrences(&evs[1], d(2026, 10, 1), d(2026, 12, 1));
        let days: Vec<u32> = occ.iter().map(|o| o.start.date().day()).collect();
        assert_eq!(days.len(), 5, "{days:?}");
        // Yearly: next year too, not in between.
        assert_eq!(occurrences(&evs[0], d(2027, 1, 1), d(2028, 1, 1)).len(), 1);
        assert_eq!(occurrences(&evs[0], d(2026, 11, 1), d(2027, 10, 1)).len(), 0);
    }

    #[test]
    fn round_trip() {
        let (_, evs) = parse(SAMPLE);
        let text = write("Home", &evs);
        let (name, again) = parse(&text);
        assert_eq!(name.as_deref(), Some("Home"));
        assert_eq!(again.len(), 3);
        assert_eq!(again[1].summary, evs[1].summary);
        assert_eq!(again[1].rule, evs[1].rule);
        assert_eq!(again[1].except, evs[1].except);
        assert_eq!(again[1].extra, evs[1].extra);
        assert_eq!(again[2].start, evs[2].start);
        assert!(text.lines().all(|l| l.trim_end_matches('\r').len() <= 75));
    }

    #[test]
    fn durations() {
        assert_eq!(parse_duration("P1D"), Some(Duration::days(1)));
        assert_eq!(parse_duration("PT1H30M"), Some(Duration::minutes(90)));
        assert_eq!(parse_duration("P2W"), Some(Duration::weeks(2)));
    }
}
