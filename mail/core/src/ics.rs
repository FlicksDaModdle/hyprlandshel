// Calendar invitations (iCalendar, RFC 5545; iTIP, RFC 5546) — enough of
// them to show one and answer it.
//
// Times: UTC ones ("…Z") are exact. Ones with a TZID are taken as local
// time, which is right whenever the organiser is in your time zone and off
// by the difference when not; the card says which zone was given.

use chrono::{Local, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde_json::{json, Value};

struct Line {
    name: String,
    params: Vec<(String, String)>,
    value: String,
    raw: String,
}

fn unfold(ics: &str) -> Vec<String> {
    let mut out: Vec<String> = vec![];
    for l in ics.split('\n') {
        let l = l.strip_suffix('\r').unwrap_or(l);
        if (l.starts_with(' ') || l.starts_with('\t')) && !out.is_empty() {
            out.last_mut().unwrap().push_str(&l[1..]);
        } else {
            out.push(l.to_string());
        }
    }
    out
}

fn split(line: &str) -> Option<Line> {
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
    let head = &line[..at];
    let value = line[at + 1..].to_string();
    let mut parts = head.split(';');
    let name = parts.next()?.to_ascii_uppercase();
    let params = parts
        .filter_map(|p| p.split_once('='))
        .map(|(k, v)| (k.to_ascii_uppercase(), v.trim_matches('"').to_string()))
        .collect();
    Some(Line { name, params, value, raw: line.to_string() })
}

fn unescape(s: &str) -> String {
    s.replace("\\n", "\n").replace("\\N", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")
}

fn param<'a>(l: &'a Line, k: &str) -> Option<&'a str> {
    l.params.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str())
}

/// Seconds since the epoch, and whether it is a whole day.
fn when(l: &Line) -> Option<(i64, bool)> {
    let v = l.value.trim();
    if param(l, "VALUE") == Some("DATE") || v.len() == 8 {
        let d = NaiveDate::parse_from_str(v, "%Y%m%d").ok()?;
        let t = Local.from_local_datetime(&d.and_hms_opt(0, 0, 0)?).earliest()?;
        return Some((t.timestamp(), true));
    }
    if let Some(z) = v.strip_suffix('Z') {
        let t = NaiveDateTime::parse_from_str(z, "%Y%m%dT%H%M%S").ok()?;
        return Some((Utc.from_utc_datetime(&t).timestamp(), false));
    }
    let t = NaiveDateTime::parse_from_str(v, "%Y%m%dT%H%M%S").ok()?;
    Some((Local.from_local_datetime(&t).earliest()?.timestamp(), false))
}

fn mailto(v: &str) -> String {
    let v = v.trim();
    v.strip_prefix("mailto:").or_else(|| v.strip_prefix("MAILTO:")).unwrap_or(v).to_string()
}

pub fn parse(ics: &str) -> Option<Value> {
    let lines: Vec<Line> = unfold(ics).iter().filter_map(|l| split(l)).collect();
    let method = lines.iter().find(|l| l.name == "METHOD").map(|l| l.value.trim().to_ascii_uppercase()).unwrap_or_default();
    let start = lines.iter().position(|l| l.name == "BEGIN" && l.value.trim().eq_ignore_ascii_case("VEVENT"))?;
    let end = lines[start..].iter().position(|l| l.name == "END" && l.value.trim().eq_ignore_ascii_case("VEVENT"))? + start;
    let ev = &lines[start..end];
    let get = |n: &str| ev.iter().find(|l| l.name == n);
    let text = |n: &str| get(n).map(|l| unescape(&l.value)).unwrap_or_default();

    let (dtstart, all_day) = get("DTSTART").and_then(when).unwrap_or((0, false));
    let dtend = get("DTEND").and_then(when).map(|w| w.0).unwrap_or(if all_day { dtstart + 86400 } else { dtstart + 3600 });
    let organizer = get("ORGANIZER").map(|l| json!({ "email": mailto(&l.value), "name": param(l, "CN").unwrap_or("") }));
    let attendees: Vec<Value> = ev
        .iter()
        .filter(|l| l.name == "ATTENDEE")
        .map(|l| json!({
            "email": mailto(&l.value),
            "name": param(l, "CN").unwrap_or(""),
            "status": param(l, "PARTSTAT").unwrap_or("NEEDS-ACTION"),
        }))
        .collect();
    Some(json!({
        "method": method,
        "uid": text("UID"),
        "summary": text("SUMMARY"),
        "location": text("LOCATION"),
        "description": text("DESCRIPTION"),
        "start": dtstart,
        "end": dtend,
        "allDay": all_day,
        "tzid": get("DTSTART").and_then(|l| param(l, "TZID")).unwrap_or(""),
        "organizer": organizer,
        "attendees": attendees,
        "sequence": text("SEQUENCE").parse::<i64>().unwrap_or(0),
        "status": text("STATUS"),
    }))
}

/// An iTIP REPLY saying how `me` answered. `partstat` is ACCEPTED,
/// TENTATIVE or DECLINED.
pub fn reply(ics: &str, me: &str, my_name: &str, partstat: &str) -> Option<String> {
    let lines: Vec<Line> = unfold(ics).iter().filter_map(|l| split(l)).collect();
    let start = lines.iter().position(|l| l.name == "BEGIN" && l.value.trim().eq_ignore_ascii_case("VEVENT"))?;
    let end = lines[start..].iter().position(|l| l.name == "END" && l.value.trim().eq_ignore_ascii_case("VEVENT"))? + start;
    let ev = &lines[start..end];
    let keep = ["UID", "DTSTART", "DTEND", "DURATION", "SEQUENCE", "ORGANIZER", "SUMMARY", "RECURRENCE-ID"];
    let stamp = Utc::now().format("%Y%m%dT%H%M%SZ");
    let mut out = vec![
        "BEGIN:VCALENDAR".to_string(),
        "PRODID:-//Hyprshell//Mail//EN".into(),
        "VERSION:2.0".into(),
        "METHOD:REPLY".into(),
    ];
    // The time zone definitions the event's times refer to.
    let mut in_tz = false;
    for l in &lines {
        if l.name == "BEGIN" && l.value.trim().eq_ignore_ascii_case("VTIMEZONE") {
            in_tz = true;
        }
        if in_tz {
            out.push(l.raw.clone());
        }
        if l.name == "END" && l.value.trim().eq_ignore_ascii_case("VTIMEZONE") {
            in_tz = false;
        }
    }
    out.push("BEGIN:VEVENT".into());
    for l in ev {
        if keep.contains(&l.name.as_str()) {
            out.push(l.raw.clone());
        }
    }
    out.push(format!("DTSTAMP:{}", stamp));
    let cn = if my_name.is_empty() { String::new() } else { format!(";CN=\"{}\"", my_name.replace('"', "")) };
    out.push(format!("ATTENDEE;PARTSTAT={}{}:mailto:{}", partstat, cn, me));
    out.push("END:VEVENT".into());
    out.push("END:VCALENDAR".into());
    Some(out.join("\r\n") + "\r\n")
}
