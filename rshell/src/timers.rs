//! Timers, the pomodoro and alarms (services/Timers.qml).
//!
//! Kept in ~/.local/state/hyprshell/timers.json with absolute end times, in
//! the file the Quickshell shell keeps too, so a timer set in either runs in
//! both and survives a restart; one that ran out while the shell was down
//! rings as soon as it is back. The file is the state: every change reads
//! it, changes it and writes it back, so nothing here can fall out of step
//! with what the other shell wrote.

use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Mutex;

static LOCK: Mutex<()> = Mutex::new(());

fn path() -> PathBuf {
    let base = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
        .unwrap_or_else(|| "/tmp".into());
    base.join("hyprshell/timers.json")
}

pub fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn blank() -> Value {
    json!({
        "timers": [],
        "pomo": { "phase": "idle", "endsAt": 0, "left": 0, "running": false, "done": 0, "day": "" },
        "alarms": [], "sound": true, "nextId": 1,
        "pomoWork": 25, "pomoShort": 5, "pomoLong": 15, "pomoEvery": 4
    })
}

fn load() -> Value {
    let mut v = std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()).unwrap_or_else(blank);
    if !v.is_object() {
        v = blank();
    }
    let b = blank();
    for (k, d) in b.as_object().unwrap() {
        if v.get(k).is_none() || v[k].is_null() {
            v[k] = d.clone();
        }
    }
    v
}

fn save(v: &Value) {
    let p = path();
    if let Some(d) = p.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    let tmp = p.with_extension("json.tmp");
    if std::fs::write(&tmp, serde_json::to_string_pretty(v).unwrap_or_default()).is_ok() {
        let _ = std::fs::rename(&tmp, &p);
    }
}

/// Reads the file, changes it, writes it back.
fn edit<R>(f: impl FnOnce(&mut Value) -> R) -> R {
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut v = load();
    let r = f(&mut v);
    save(&v);
    r
}

fn today() -> String {
    // The date, as "YYYY-MM-DD", from the shell's own clock formatting.
    let (y, m, d) = crate::timers::ymd(now_ms() / 1000);
    format!("{y:04}-{m:02}-{d:02}")
}

/// Local calendar date of a Unix time.
pub fn ymd(secs: i64) -> (i64, i64, i64) {
    let t = local_tm(secs);
    (t.tm_year as i64 + 1900, t.tm_mon as i64 + 1, t.tm_mday as i64)
}

fn local_tm(secs: i64) -> libc::tm {
    unsafe {
        let t: libc::time_t = secs as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm
    }
}

/// The Unix time of a local date and time (tm_isdst worked out).
fn mk_local(y: i64, mo: i64, d: i64, h: i64, mi: i64) -> i64 {
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        tm.tm_year = (y - 1900) as i32;
        tm.tm_mon = (mo - 1) as i32;
        tm.tm_mday = d as i32;
        tm.tm_hour = h as i32;
        tm.tm_min = mi as i32;
        tm.tm_isdst = -1;
        libc::mktime(&mut tm) as i64
    }
}

// ── reading ──────────────────────────────────────────────────────────────

/// "4:05", or "1:02:09" past the hour.
pub fn clock(secs: i64) -> String {
    let s = secs.max(0);
    let (h, m, s) = (s / 3600, s / 60 % 60, s % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

pub fn phase_name(p: &str) -> &'static str {
    match p {
        "work" => "Focus",
        "short" => "Short break",
        "long" => "Long break",
        _ => "",
    }
}

fn left_of(t: &Value, now: i64) -> i64 {
    if t["running"].as_bool().unwrap_or(false) {
        ((t["endsAt"].as_f64().unwrap_or(0.0) as i64 - now) as f64 / 1000.0).round().max(0.0) as i64
    } else {
        t["left"].as_f64().unwrap_or(0.0).max(0.0) as i64
    }
}

pub struct TimerView {
    pub id: i64,
    pub label: String,
    pub left: i64,
    pub total: i64,
    pub running: bool,
}

pub struct PomoView {
    pub active: bool,
    pub running: bool,
    pub left: i64,
    pub phase: String,
    pub done: i64,
    pub work: i64,
    pub short: i64,
    pub long: i64,
    pub every: i64,
}

pub struct AlarmView {
    pub id: i64,
    pub h: i64,
    pub m: i64,
    pub days: Vec<i64>,
    pub label: String,
    pub on: bool,
}

pub struct View {
    pub timers: Vec<TimerView>,
    pub pomo: PomoView,
    pub alarms: Vec<AlarmView>,
    pub sound: bool,
    /// When the next alarm rings, in ms since the epoch.
    pub next_alarm: Option<i64>,
}

pub fn view() -> View {
    let v = load();
    let now = now_ms();
    let timers = v["timers"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|t| TimerView {
            id: t["id"].as_i64().unwrap_or(0),
            label: t["label"].as_str().filter(|s| !s.is_empty()).unwrap_or("Timer").to_string(),
            left: left_of(t, now),
            total: t["total"].as_i64().unwrap_or(1).max(1),
            running: t["running"].as_bool().unwrap_or(false),
        })
        .collect();
    let p = &v["pomo"];
    let phase = p["phase"].as_str().unwrap_or("idle").to_string();
    let day_ok = p["day"].as_str() == Some(today().as_str());
    let pomo = PomoView {
        active: phase != "idle" && !phase.is_empty(),
        running: p["running"].as_bool().unwrap_or(false),
        left: left_of(p, now),
        phase,
        done: if day_ok { p["done"].as_i64().unwrap_or(0) } else { 0 },
        work: v["pomoWork"].as_i64().unwrap_or(25),
        short: v["pomoShort"].as_i64().unwrap_or(5),
        long: v["pomoLong"].as_i64().unwrap_or(15),
        every: v["pomoEvery"].as_i64().unwrap_or(4),
    };
    let alarms: Vec<AlarmView> = v["alarms"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|a| AlarmView {
            id: a["id"].as_i64().unwrap_or(0),
            h: a["h"].as_i64().unwrap_or(0),
            m: a["m"].as_i64().unwrap_or(0),
            days: a["days"].as_array().into_iter().flatten().filter_map(Value::as_i64).collect(),
            label: a["label"].as_str().unwrap_or("Alarm").to_string(),
            on: a["on"].as_bool().unwrap_or(true),
        })
        .collect();
    let next_alarm = alarms.iter().filter(|a| a.on).filter_map(|a| next_ring(a.h, a.m, &a.days, now)).min();
    View { timers, pomo, alarms, sound: v["sound"].as_bool().unwrap_or(true), next_alarm }
}

/// "07:00", or "7:00 AM".
pub fn alarm_time(h: i64, m: i64, clock24: bool) -> String {
    if clock24 {
        format!("{h:02}:{m:02}")
    } else {
        format!("{}:{m:02} {}", (h + 11) % 12 + 1, if h < 12 { "AM" } else { "PM" })
    }
}

const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

pub fn day_name(d: i64) -> &'static str {
    DAYS[d.rem_euclid(7) as usize]
}

pub fn days_text(days: &[i64]) -> String {
    if days.is_empty() {
        return "Once".into();
    }
    if days.len() == 7 {
        return "Every day".into();
    }
    let mut d = days.to_vec();
    d.sort_unstable();
    if d == [1, 2, 3, 4, 5] {
        return "Weekdays".into();
    }
    if d == [0, 6] {
        return "Weekends".into();
    }
    d.iter().map(|i| day_name(*i)).collect::<Vec<_>>().join(" ")
}

/// When an alarm next rings after `from` (ms), in ms.
pub fn next_ring(h: i64, m: i64, days: &[i64], from: i64) -> Option<i64> {
    let (y, mo, d) = ymd(from / 1000);
    for add in 0..8 {
        let at = mk_local(y, mo, d + add, h, m) * 1000;
        if at <= from {
            continue;
        }
        if !days.is_empty() && !days.contains(&(local_tm(at / 1000).tm_wday as i64)) {
            continue;
        }
        return Some(at);
    }
    None
}

/// "in 20 min", "in 2 h 5 min".
pub fn until_text(at: i64) -> String {
    let mins = ((at - now_ms()) as f64 / 60000.0).round().max(0.0) as i64;
    if mins < 60 {
        return format!("in {mins} min");
    }
    let (h, m) = (mins / 60, mins % 60);
    format!("in {h} h{}", if m > 0 { format!(" {m} min") } else { String::new() })
}

/// "10", "10m", "1h30", "90s", "1:30", "2 min" → seconds; 0 if unreadable.
pub fn parse_duration(text: &str) -> i64 {
    let s = text.trim().to_lowercase().replace(" and ", " ");
    if s.is_empty() {
        return 0;
    }
    if let Some((a, rest)) = s.split_once(':') {
        let nums: Vec<&str> = std::iter::once(a).chain(rest.split(':')).collect();
        let digits = |n: &str, max: usize| !n.is_empty() && n.len() <= max && n.chars().all(|c| c.is_ascii_digit());
        if nums.len() <= 3 && digits(nums[0], 9) && nums[1..].iter().all(|n| digits(n, 2)) {
            let v: Vec<i64> = nums.iter().map(|n| n.parse().unwrap_or(0)).collect();
            return if v.len() == 3 { v[0] * 3600 + v[1] * 60 + v[2] } else { v[0] * 60 + v[1] };
        }
    }
    if let Ok(f) = s.parse::<f64>() {
        return (f * 60.0).round() as i64;
    }
    let mut total = 0.0;
    let mut any = false;
    let b: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c.is_ascii_digit() {
            let st = i;
            while i < b.len() && (b[i].is_ascii_digit() || b[i] == '.') {
                i += 1;
            }
            let n: f64 = b[st..i].iter().collect::<String>().parse().unwrap_or(0.0);
            while i < b.len() && b[i] == ' ' {
                i += 1;
            }
            let us = i;
            while i < b.len() && b[i].is_ascii_alphabetic() {
                i += 1;
            }
            let unit: String = b[us..i].iter().collect();
            let mult = match unit.as_str() {
                "" | "m" | "min" | "mins" | "minute" | "minutes" => 60.0,
                "h" | "hr" | "hrs" | "hour" | "hours" => 3600.0,
                "s" | "sec" | "secs" | "second" | "seconds" => 1.0,
                _ => return 0,
            };
            total += n * mult;
            any = true;
        } else if c == ' ' || c == ',' {
            i += 1;
        } else {
            return 0;
        }
    }
    if any {
        total.round() as i64
    } else {
        0
    }
}

// ── changing ─────────────────────────────────────────────────────────────

fn next_id(v: &mut Value) -> i64 {
    let id = v["nextId"].as_i64().unwrap_or(1).max(1);
    v["nextId"] = json!(id + 1);
    id
}

fn default_label(secs: i64) -> String {
    if secs % 3600 == 0 {
        format!("{} h timer", secs / 3600)
    } else if secs % 60 == 0 {
        format!("{} min timer", secs / 60)
    } else {
        format!("{} timer", clock(secs))
    }
}

pub fn add_timer(secs: i64, label: &str) {
    if secs <= 0 {
        return;
    }
    edit(|v| {
        let id = next_id(v);
        let label = if label.is_empty() { default_label(secs) } else { label.to_string() };
        v["timers"].as_array_mut().unwrap().push(json!({ "id": id, "label": label, "total": secs, "endsAt": now_ms() + secs * 1000, "left": secs, "running": true }));
    });
}

fn each_timer(id: i64, f: impl Fn(&mut Value, i64)) {
    edit(|v| {
        let now = now_ms();
        for t in v["timers"].as_array_mut().unwrap() {
            if t["id"].as_i64() == Some(id) {
                f(t, now);
            }
        }
    });
}

pub fn pause_timer(id: i64) {
    each_timer(id, |t, now| {
        if t["running"].as_bool() == Some(true) {
            t["left"] = json!(left_of(t, now));
            t["running"] = json!(false);
        }
    });
}

pub fn resume_timer(id: i64) {
    each_timer(id, |t, now| {
        if t["running"].as_bool() != Some(true) {
            t["endsAt"] = json!(now + t["left"].as_i64().unwrap_or(0) * 1000);
            t["running"] = json!(true);
        }
    });
}

pub fn cancel_timer(id: i64) {
    edit(|v| v["timers"].as_array_mut().unwrap().retain(|t| t["id"].as_i64() != Some(id)));
}

fn set_phase(v: &mut Value, phase: &str, done: i64) {
    let mins = match phase {
        "work" => v["pomoWork"].as_i64().unwrap_or(25),
        "short" => v["pomoShort"].as_i64().unwrap_or(5),
        _ => v["pomoLong"].as_i64().unwrap_or(15),
    };
    v["pomo"] = json!({ "phase": phase, "endsAt": now_ms() + mins * 60000, "left": mins * 60, "running": true, "done": done, "day": today() });
}

pub fn pomo_start() {
    edit(|v| {
        let done = if v["pomo"]["day"].as_str() == Some(today().as_str()) { v["pomo"]["done"].as_i64().unwrap_or(0) } else { 0 };
        set_phase(v, "work", done);
    });
}

pub fn pomo_pause() {
    edit(|v| {
        if v["pomo"]["running"].as_bool() == Some(true) {
            let l = left_of(&v["pomo"], now_ms());
            v["pomo"]["left"] = json!(l);
            v["pomo"]["running"] = json!(false);
        }
    });
}

pub fn pomo_resume() {
    edit(|v| {
        let idle = v["pomo"]["phase"].as_str().unwrap_or("idle") == "idle";
        if v["pomo"]["running"].as_bool() != Some(true) && !idle {
            let l = v["pomo"]["left"].as_i64().unwrap_or(0);
            v["pomo"]["endsAt"] = json!(now_ms() + l * 1000);
            v["pomo"]["running"] = json!(true);
        }
    });
}

pub fn pomo_stop() {
    edit(|v| {
        v["pomo"]["phase"] = json!("idle");
        v["pomo"]["running"] = json!(false);
        v["pomo"]["endsAt"] = json!(0);
        v["pomo"]["left"] = json!(0);
    });
}

/// The pomodoro on to its next phase; the words to say if it rang.
fn advance(v: &mut Value, ring: bool) -> Option<(String, String)> {
    let was = v["pomo"]["phase"].as_str().unwrap_or("idle").to_string();
    let mut done = if v["pomo"]["day"].as_str() == Some(today().as_str()) { v["pomo"]["done"].as_i64().unwrap_or(0) } else { 0 };
    let every = v["pomoEvery"].as_i64().unwrap_or(4).max(1);
    let next = if was == "work" {
        done += 1;
        if done % every == 0 { "long" } else { "short" }
    } else {
        "work"
    };
    let said = ring.then(|| {
        let (work, short, long) = (v["pomoWork"].as_i64().unwrap_or(25), v["pomoShort"].as_i64().unwrap_or(5), v["pomoLong"].as_i64().unwrap_or(15));
        let body = if was == "work" {
            format!("Session {done} done. {}, {} min.", phase_name(next), if next == "long" { long } else { short })
        } else {
            format!("Break's over — {work} min of focus.")
        };
        (format!("{} finished", phase_name(&was)), body)
    });
    set_phase(v, next, done);
    said
}

pub fn pomo_skip() {
    edit(|v| {
        advance(v, false);
    });
}

pub fn set_lengths(work: i64, short: i64, long: i64, every: i64) {
    edit(|v| {
        v["pomoWork"] = json!(work.max(1));
        v["pomoShort"] = json!(short.max(1));
        v["pomoLong"] = json!(long.max(1));
        v["pomoEvery"] = json!(every.max(1));
    });
}

pub fn add_alarm(h: i64, m: i64, days: &[i64], label: &str) {
    edit(|v| {
        let id = next_id(v);
        let label = if label.is_empty() { "Alarm" } else { label };
        v["alarms"].as_array_mut().unwrap().push(json!({ "id": id, "h": h, "m": m, "days": days, "label": label, "on": true, "last": "" }));
    });
}

pub fn alarm_on(id: i64, on: bool) {
    edit(|v| {
        for a in v["alarms"].as_array_mut().unwrap() {
            if a["id"].as_i64() == Some(id) {
                a["on"] = json!(on);
            }
        }
    });
}

pub fn remove_alarm(id: i64) {
    edit(|v| v["alarms"].as_array_mut().unwrap().retain(|a| a["id"].as_i64() != Some(id)));
}

pub fn set_sound(on: bool) {
    edit(|v| v["sound"] = json!(on));
}

// ── ringing ──────────────────────────────────────────────────────────────

/// What a tick found to say.
struct Ring {
    title: String,
    body: String,
    urgency: &'static str,
    /// (key, label)
    actions: Vec<(&'static str, &'static str)>,
    total: i64,
    alarm: i64,
    times: u32,
}

/// Rings what is due: timers that ran out, the pomodoro's phase, alarms.
/// Called every second while anything counts down, and now and then
/// otherwise.
pub fn tick(clock24: bool) {
    let mut rings: Vec<Ring> = Vec::new();
    let sound = edit(|v| {
        let now = now_ms();
        // Timers that ran out.
        let mut out = Vec::new();
        v["timers"].as_array_mut().unwrap().retain(|t| {
            let up = t["running"].as_bool() == Some(true) && t["endsAt"].as_f64().unwrap_or(f64::MAX) as i64 <= now;
            if up {
                out.push((t["label"].as_str().unwrap_or("Timer").to_string(), t["total"].as_i64().unwrap_or(0), now - t["endsAt"].as_f64().unwrap_or(0.0) as i64));
            }
            !up
        });
        if !out.is_empty() {
            for (label, total, late) in &out {
                let late = if *late > 60000 { " (while the shell was not running)" } else { "" };
                rings.push(Ring { title: label.clone(), body: format!("Time's up{late}."), urgency: "normal", actions: vec![("again", "Again")], total: *total, alarm: 0, times: 0 });
            }
            rings.push(Ring { title: String::new(), body: String::new(), urgency: "", actions: vec![], total: 0, alarm: 0, times: 2 });
        }
        // The pomodoro's phase.
        let p = &v["pomo"];
        if p["phase"].as_str().unwrap_or("idle") != "idle" && p["running"].as_bool() == Some(true) && p["endsAt"].as_f64().unwrap_or(f64::MAX) as i64 <= now {
            if let Some((title, body)) = advance(v, true) {
                rings.push(Ring { title, body, urgency: "normal", actions: vec![], total: 0, alarm: 0, times: 0 });
                rings.push(Ring { title: String::new(), body: String::new(), urgency: "", actions: vec![], total: 0, alarm: 0, times: 1 });
            }
        }
        // Alarms: one that fell in the minute just gone (or that was missed
        // by under ten minutes, as across a suspend) rings once.
        let (y, mo, d) = ymd(now / 1000);
        let mut fired: Vec<(i64, i64, i64, String)> = Vec::new();
        for a in v["alarms"].as_array_mut().unwrap() {
            if a["on"].as_bool() != Some(true) {
                continue;
            }
            let (h, m) = (a["h"].as_i64().unwrap_or(0), a["m"].as_i64().unwrap_or(0));
            let at = mk_local(y, mo, d, h, m) * 1000;
            let late = now - at;
            if !(0..=600_000).contains(&late) {
                continue;
            }
            let days: Vec<i64> = a["days"].as_array().into_iter().flatten().filter_map(Value::as_i64).collect();
            if !days.is_empty() && !days.contains(&(local_tm(at / 1000).tm_wday as i64)) {
                continue;
            }
            let key = format!("{y:04}-{mo:02}-{d:02} {h:02}:{m:02}");
            if a["last"].as_str() == Some(key.as_str()) {
                continue;
            }
            a["last"] = json!(key);
            if days.is_empty() {
                a["on"] = json!(false);
            }
            fired.push((a["id"].as_i64().unwrap_or(0), h, m, a["label"].as_str().unwrap_or("Alarm").to_string()));
        }
        for (id, h, m, label) in fired {
            rings.push(Ring { title: label, body: alarm_time(h, m, clock24), urgency: "critical", actions: vec![("snooze", "Snooze 5 min"), ("stop", "Stop")], total: 0, alarm: id, times: 0 });
            rings.push(Ring { title: String::new(), body: String::new(), urgency: "", actions: vec![], total: 0, alarm: 0, times: 4 });
        }
        v["sound"].as_bool().unwrap_or(true)
    });
    for r in rings {
        if r.times > 0 {
            if sound {
                chime(r.times);
            }
        } else {
            notify(r);
        }
    }
}

/// Whether anything is counting down (a once-a-second tick is wanted).
pub fn counting() -> bool {
    let v = load();
    v["timers"].as_array().into_iter().flatten().any(|t| t["running"].as_bool() == Some(true))
        || (v["pomo"]["phase"].as_str().unwrap_or("idle") != "idle" && v["pomo"]["running"].as_bool() == Some(true))
}

/// As a notification from the shell's own server, so it is in the center
/// and the history too, with the actions answered here.
fn notify(r: Ring) {
    std::thread::spawn(move || {
        let mut c = std::process::Command::new("notify-send");
        c.args(["-a", "Timers", "-i", "alarm-clock", "-u", r.urgency]);
        for (k, l) in &r.actions {
            c.args(["-A", &format!("{k}={l}")]);
        }
        if !r.actions.is_empty() {
            c.arg("--wait");
        }
        c.arg(&r.title).arg(&r.body).stdin(std::process::Stdio::null()).stderr(std::process::Stdio::null());
        let Ok(out) = c.output() else { return };
        match String::from_utf8_lossy(&out.stdout).trim() {
            "again" if r.total > 0 => add_timer(r.total, ""),
            "snooze" => {
                let label = edit(|v| v["alarms"].as_array().into_iter().flatten().find(|a| a["id"].as_i64() == Some(r.alarm)).and_then(|a| a["label"].as_str().map(str::to_string)));
                add_timer(300, &format!("{} · snoozed", label.unwrap_or_else(|| "Alarm".into())));
            }
            _ => {}
        }
    });
}

/// The desktop's own sounds, through PipeWire or Pulse, whichever is there.
fn chime(times: u32) {
    crate::extras::spawn(&[
        "sh",
        "-c",
        "f=\"\"; for c in /usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga \
         /usr/share/sounds/freedesktop/stereo/complete.oga /usr/share/sounds/freedesktop/stereo/bell.oga; \
         do [ -f \"$c\" ] && { f=$c; break; }; done; \
         i=0; while [ $i -lt \"$1\" ]; do i=$((i+1)); \
         if [ -n \"$f\" ]; then pw-play \"$f\" 2>/dev/null || paplay \"$f\" 2>/dev/null; \
         else canberra-gtk-play -i alarm-clock-elapsed 2>/dev/null || printf '\\a'; sleep 0.6; fi; done",
        "chime",
        &times.to_string(),
    ]);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        assert_eq!(parse_duration("10"), 600);
        assert_eq!(parse_duration("10m"), 600);
        assert_eq!(parse_duration("1h30"), 5400);
        assert_eq!(parse_duration("90s"), 90);
        assert_eq!(parse_duration("1:30"), 90);
        assert_eq!(parse_duration("1:02:03"), 3723);
        assert_eq!(parse_duration("2 min"), 120);
        assert_eq!(parse_duration("1 hour 5 minutes"), 3900);
        assert_eq!(parse_duration("tea"), 0);
        assert_eq!(parse_duration(""), 0);
    }

    #[test]
    fn clocks_and_days() {
        assert_eq!(clock(65), "1:05");
        assert_eq!(clock(3723), "1:02:03");
        assert_eq!(days_text(&[]), "Once");
        assert_eq!(days_text(&[1, 2, 3, 4, 5]), "Weekdays");
        assert_eq!(days_text(&[6, 0]), "Weekends");
        assert_eq!(alarm_time(0, 5, false), "12:05 AM");
        assert_eq!(alarm_time(13, 5, false), "1:05 PM");
        assert_eq!(alarm_time(7, 0, true), "07:00");
    }
}
