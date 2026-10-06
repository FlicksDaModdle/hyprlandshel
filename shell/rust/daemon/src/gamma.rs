//! Night light, built in: the screens' colour temperature set through the
//! compositor's gamma control (wlr-gamma-control, which Hyprland, sway and
//! the other wlroots compositors speak) — in place of starting hyprsunset
//! or wlsunset.
//!
//!   on / off           at a chosen temperature
//!   sunset → sunrise   worked out here, offline, for where you are: the
//!                      coordinates you give, or those of your time zone's
//!                      city (zone1970.tab)
//!   custom times       e.g. 20:00 → 07:00
//!
//! Changes fade (a second or two when switched, half an hour around sunset
//! and sunrise). A display plugged in later is warmed too. While another
//! program holds the gamma (hyprsunset, wlsunset), the compositor says so
//! and that is reported rather than fought.
//!
//! Commands:  gamma-config {mode: "off"|"on"|"sun"|"times", temp,
//!                          from: "HH:MM", to: "HH:MM", lat?, lon?}
//!            gamma-override {on}     the tile: until the next scheduled change
//! Events:    gamma {available, active, temp, target, mode, sunrise?,
//!                   sunset?, place?, next?, error?}

use crate::out;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::{wl_output, wl_registry};
use wayland_client::{Connection, Dispatch, EventQueue, Proxy, QueueHandle};
use wayland_protocols_wlr::gamma_control::v1::client::{
    zwlr_gamma_control_manager_v1::ZwlrGammaControlManagerV1,
    zwlr_gamma_control_v1::{self, ZwlrGammaControlV1},
};

const NEUTRAL: f64 = 6500.0;

// ══ colour ══════════════════════════════════════════════════════════════

/// The white point of a black body at `k` kelvin, as red/green/blue
/// multipliers with 6500 K as (1, 1, 1). Tanner Helland's fit, which the
/// usual tools use; good from 1000 K to 40000 K.
pub fn whitepoint(k: f64) -> [f64; 3] {
    let f = |k: f64| -> [f64; 3] {
        let t = k / 100.0;
        let r = if t <= 66.0 { 255.0 } else { 329.698727446 * (t - 60.0).powf(-0.1332047592) };
        let g = if t <= 66.0 { 99.4708025861 * t.ln() - 161.1195681661 } else { 288.1221695283 * (t - 60.0).powf(-0.0755148492) };
        let b = if t >= 66.0 { 255.0 } else if t <= 19.0 { 0.0 } else { 138.5177312231 * (t - 10.0).ln() - 305.0447927307 };
        [r.clamp(0.0, 255.0) / 255.0, g.clamp(0.0, 255.0) / 255.0, b.clamp(0.0, 255.0) / 255.0]
    };
    let (w, n) = (f(k.clamp(1000.0, 40000.0)), f(NEUTRAL));
    [(w[0] / n[0]).min(1.0), (w[1] / n[1]).min(1.0), (w[2] / n[2]).min(1.0)]
}

/// The three ramps, red then green then blue, as the protocol wants them.
fn ramps(size: usize, k: f64) -> Vec<u8> {
    let wp = whitepoint(k);
    let mut out = Vec::with_capacity(size * 6);
    for c in wp {
        for i in 0..size {
            let v = if size > 1 { i as f64 / (size - 1) as f64 } else { 1.0 };
            let x = (v * c * 65535.0).round().clamp(0.0, 65535.0) as u16;
            out.extend_from_slice(&x.to_ne_bytes());
        }
    }
    out
}

// ══ the sun ═════════════════════════════════════════════════════════════

/// Sunrise and sunset (UTC, hours) for a day, by NOAA's simplified
/// algorithm; None at the poles' all-day or all-night seasons.
pub fn sun_times(days_since_epoch: i64, lat: f64, lon: f64) -> Option<(f64, f64)> {
    let jd = days_since_epoch as f64 + 2440587.5 + 0.5;
    let n = jd - 2451545.0 + 0.0008;
    let j_star = n - lon / 360.0;
    let m = (357.5291 + 0.98560028 * j_star).rem_euclid(360.0).to_radians();
    let c = 1.9148 * m.sin() + 0.02 * (2.0 * m).sin() + 0.0003 * (3.0 * m).sin();
    let lambda = (m.to_degrees() + c + 180.0 + 102.9372).rem_euclid(360.0).to_radians();
    let j_transit = 2451545.0 + j_star + 0.0053 * m.sin() - 0.0069 * (2.0 * lambda).sin();
    let decl = (lambda.sin() * 23.4397_f64.to_radians().sin()).asin();
    let latr = lat.to_radians();
    let cos_w = ((-0.833_f64).to_radians().sin() - latr.sin() * decl.sin()) / (latr.cos() * decl.cos());
    if !(-1.0..=1.0).contains(&cos_w) {
        return None;
    }
    let w = cos_w.acos().to_degrees();
    let rise = j_transit - w / 360.0;
    let set = j_transit + w / 360.0;
    let to_hours = |j: f64| ((j - 2440587.5) - days_since_epoch as f64) * 24.0;
    Some((to_hours(rise), to_hours(set)))
}

/// The time zone's name and offset now, from /etc/localtime.
fn local_zone() -> (String, i64) {
    let name = std::fs::read_link("/etc/localtime")
        .ok()
        .and_then(|p| p.to_str().and_then(|s| s.split("zoneinfo/").nth(1)).map(|s| s.to_string()))
        .or_else(|| std::env::var("TZ").ok().map(|s| s.trim_start_matches(':').to_string()))
        .unwrap_or_default();
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let now = unsafe { libc::time(std::ptr::null_mut()) };
    unsafe { libc::localtime_r(&now, &mut tm) };
    (name, tm.tm_gmtoff as i64)
}

/// The coordinates of a time zone's city, from tzdata's zone1970.tab
/// ("+4030-07400" style, degrees and minutes).
fn zone_coords(zone: &str) -> Option<(f64, f64)> {
    let text = ["/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab"]
        .iter()
        .find_map(|p| std::fs::read_to_string(p).ok())?;
    let line = text.lines().find(|l| !l.starts_with('#') && l.split('\t').nth(2) == Some(zone))?;
    let c = line.split('\t').nth(1)?;
    let split = c[1..].find(['+', '-'])? + 1;
    let part = |s: &str, deg_len: usize| -> Option<f64> {
        let sign = if s.starts_with('-') { -1.0 } else { 1.0 };
        let d: f64 = s.get(1..1 + deg_len)?.parse().ok()?;
        let m: f64 = s.get(1 + deg_len..3 + deg_len)?.parse().ok()?;
        Some(sign * (d + m / 60.0))
    };
    Some((part(&c[..split], 2)?, part(&c[split..], 3)?))
}

fn hm(s: &str) -> Option<f64> {
    let (h, m) = s.split_once(':')?;
    Some(h.trim().parse::<f64>().ok()? + m.trim().parse::<f64>().ok()? / 60.0)
}
fn fmt_hm(h: f64) -> String {
    let m = (h.rem_euclid(24.0) * 60.0).round() as i64 % 1440;
    format!("{:02}:{:02}", m / 60, m % 60)
}

// ══ the schedule ════════════════════════════════════════════════════════

#[derive(Clone)]
struct Config {
    mode: String,
    temp: f64,
    from: f64,
    to: f64,
    lat: Option<f64>,
    lon: Option<f64>,
}

struct Plan {
    /// Sunset to sunrise without a place to work them out for.
    no_place: bool,
    /// 0 (day) .. 1 (night), now.
    night: f64,
    /// Local hours of the next change.
    next: Option<f64>,
    sun: Option<(f64, f64)>,
    place: String,
}

/// How far into night it is (0..1, with `fade` hours of ramp either side
/// of `start` and `end`), and when the next edge is. Local hours.
fn window(now: f64, start: f64, end: f64, fade: f64) -> (f64, f64) {
    let inside = |t: f64| if start <= end { t >= start && t < end } else { t >= start || t < end };
    let dist = |a: f64, b: f64| (b - a).rem_euclid(24.0);
    let f = fade.max(1e-6);
    let v = if inside(now) {
        // Ramping up after the start, down before the end.
        let into = dist(start, now);
        let left = dist(now, end);
        (into / f).min(left / f).min(1.0)
    } else {
        0.0
    };
    let next = if inside(now) { end } else { start };
    (v.clamp(0.0, 1.0), next)
}

fn plan(cfg: &Config) -> Plan {
    let (zone, offset) = local_zone();
    let now_s = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let local_h = ((now_s + offset).rem_euclid(86400)) as f64 / 3600.0;
    match cfg.mode.as_str() {
        "on" => Plan { no_place: false, night: 1.0, next: None, sun: None, place: String::new() },
        "times" => {
            let (n, next) = window(local_h, cfg.from, cfg.to, 0.25);
            Plan { no_place: false, night: n, next: Some(next), sun: None, place: String::new() }
        }
        "sun" => {
            let coords = match (cfg.lat, cfg.lon) {
                (Some(a), Some(b)) => Some((a, b)),
                _ => zone_coords(&zone),
            };
            let Some((lat, lon)) = coords else {
                return Plan { no_place: true, night: 0.0, next: None, sun: None, place: zone };
            };
            let day = (now_s + offset).div_euclid(86400);
            match sun_times(day, lat, lon) {
                Some((rise, set)) => {
                    let (rise_l, set_l) = (rise + offset as f64 / 3600.0, set + offset as f64 / 3600.0);
                    // Half an hour of fade either side, centred on the event.
                    let (n, next) = window(local_h, set_l - 0.25, rise_l + 0.25, 0.5);
                    let place = if cfg.lat.is_some() { format!("{lat:.2}, {lon:.2}") } else { zone.replace('_', " ") };
                    Plan { no_place: false, night: n, next: Some(next), sun: Some((rise_l, set_l)), place }
                }
                // Polar day or night: whichever it is, all day.
                None => {
                    let summer = (lat > 0.0) == (((day % 365) as f64 - 172.0).abs() < 91.0);
                    Plan { no_place: false, night: if summer { 0.0 } else { 1.0 }, next: None, sun: None, place: zone }
                }
            }
        }
        _ => Plan { no_place: false, night: 0.0, next: None, sun: None, place: String::new() },
    }
}

// ══ Wayland ═════════════════════════════════════════════════════════════

struct Out {
    output: wl_output::WlOutput,
    control: Option<ZwlrGammaControlV1>,
    size: usize,
    failed: bool,
}

struct State {
    outputs: HashMap<u32, Out>,
    manager: Option<ZwlrGammaControlManagerV1>,
    /// What is on the screens now, in kelvin.
    applied: f64,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(st: &mut Self, reg: &wl_registry::WlRegistry, ev: wl_registry::Event, _: &GlobalListContents, _: &Connection, qh: &QueueHandle<Self>) {
        match ev {
            // A display plugged in.
            wl_registry::Event::Global { name, interface, version } if interface == "wl_output" => {
                let output = reg.bind::<wl_output::WlOutput, _, _>(name, version.min(4), qh, ());
                st.outputs.insert(name, Out { output, control: None, size: 0, failed: false });
            }
            wl_registry::Event::GlobalRemove { name } => {
                if let Some(o) = st.outputs.remove(&name) {
                    if let Some(c) = o.control {
                        c.destroy();
                    }
                }
            }
            _ => {}
        }
    }
}
impl Dispatch<wl_output::WlOutput, ()> for State {
    fn event(_: &mut Self, _: &wl_output::WlOutput, _: wl_output::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ZwlrGammaControlManagerV1, ()> for State {
    fn event(_: &mut Self, _: &ZwlrGammaControlManagerV1, _: <ZwlrGammaControlManagerV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ZwlrGammaControlV1, u32> for State {
    fn event(st: &mut Self, _: &ZwlrGammaControlV1, ev: zwlr_gamma_control_v1::Event, name: &u32, _: &Connection, _: &QueueHandle<Self>) {
        let Some(o) = st.outputs.get_mut(name) else { return };
        match ev {
            zwlr_gamma_control_v1::Event::GammaSize { size } => {
                o.size = size as usize;
                // Applied on the next step; force it.
                st.applied = -1.0;
            }
            zwlr_gamma_control_v1::Event::Failed => {
                o.failed = true;
                if let Some(c) = o.control.take() {
                    c.destroy();
                }
            }
            _ => {}
        }
    }
}

struct Wl {
    conn: Connection,
    queue: EventQueue<State>,
    qh: QueueHandle<State>,
    st: State,
}

impl Wl {
    fn connect() -> Result<Wl, String> {
        let conn = Connection::connect_to_env().map_err(|e| format!("no Wayland display: {e}"))?;
        let (globals, queue) = registry_queue_init::<State>(&conn).map_err(|e| e.to_string())?;
        let qh = queue.handle();
        let manager: Option<ZwlrGammaControlManagerV1> = globals.bind(&qh, 1..=1, ()).ok();
        if manager.is_none() {
            return Err("the compositor has no gamma control (wlr-gamma-control)".into());
        }
        let mut st = State { outputs: HashMap::new(), manager, applied: NEUTRAL };
        for g in globals.contents().clone_list() {
            if g.interface == "wl_output" {
                let output = globals.registry().bind::<wl_output::WlOutput, _, _>(g.name, g.version.min(4), &qh, ());
                st.outputs.insert(g.name, Out { output, control: None, size: 0, failed: false });
            }
        }
        let mut wl = Wl { conn, queue, qh, st };
        wl.pump();
        Ok(wl)
    }
    /// Everything the compositor has to say, up to now: a sync round trip,
    /// which returns once the compositor has answered everything before it.
    fn pump(&mut self) {
        let _ = self.queue.roundtrip(&mut self.st);
    }
    /// The temperature on every display; at 6500 K the controls are let go,
    /// which gives the compositor's own ramps back.
    fn apply(&mut self, k: f64) -> Option<String> {
        self.pump();
        if (k - NEUTRAL).abs() < 1.0 {
            for o in self.st.outputs.values_mut() {
                if let Some(c) = o.control.take() {
                    c.destroy();
                }
                o.size = 0;
                o.failed = false;
            }
            self.st.applied = NEUTRAL;
            let _ = self.conn.flush();
            return None;
        }
        let mut busy = false;
        let names: Vec<u32> = self.st.outputs.keys().copied().collect();
        for name in names {
            let o = self.st.outputs.get_mut(&name).unwrap();
            if o.control.is_none() && !o.failed {
                if let Some(m) = &self.st.manager {
                    o.control = Some(m.get_gamma_control(&o.output, &self.qh, name));
                }
            }
        }
        // The sizes arrive in reply to get_gamma_control.
        self.pump();
        for o in self.st.outputs.values_mut() {
            if o.failed {
                busy = true;
                continue;
            }
            let (Some(c), size) = (&o.control, o.size) else { continue };
            if size == 0 {
                continue;
            }
            let bytes = ramps(size, k);
            let fd = unsafe { libc::memfd_create(c"hyprshell-gamma".as_ptr(), libc::MFD_CLOEXEC) };
            if fd < 0 {
                continue;
            }
            let fd = unsafe { OwnedFd::from_raw_fd(fd) };
            let mut f = std::fs::File::from(fd);
            use std::io::{Seek, Write};
            if f.write_all(&bytes).is_err() || f.seek(std::io::SeekFrom::Start(0)).is_err() {
                continue;
            }
            c.set_gamma(f.as_fd());
        }
        let _ = self.conn.flush();
        self.st.applied = k;
        busy.then(|| match rival() {
            Some(name) => format!("{name} is already setting the screen colours — stop it to use this"),
            None => "the compositor would not hand over this display's colours (no gamma support?)".to_string(),
        })
    }
}

/// Another night-light program running, by name, from /proc.
fn rival() -> Option<String> {
    for e in std::fs::read_dir("/proc").ok()?.flatten() {
        let comm = std::fs::read_to_string(e.path().join("comm")).unwrap_or_default();
        let comm = comm.trim();
        if ["hyprsunset", "wlsunset", "gammastep", "redshift"].contains(&comm) {
            return Some(comm.to_string());
        }
    }
    None
}

// ══ the thread ══════════════════════════════════════════════════════════

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    std::thread::spawn(move || run(rx));
    tx
}

fn run(rx: Receiver<Value>) {
    let mut cfg = Config { mode: "off".into(), temp: 4000.0, from: 20.0, to: 7.0, lat: None, lon: None };
    let mut wl: Option<Wl> = None;
    let mut error: Option<String> = None;
    // The tile's on/off, until the schedule's next change.
    let mut override_on: Option<(bool, Option<f64>)> = None;
    // A fade in progress: from, to, started, length.
    let mut fade: Option<(f64, f64, Instant, Duration)> = None;
    let mut current = NEUTRAL;
    let mut last_emit = Value::Null;
    let mut configured = false;
    loop {
        let tick = if fade.is_some() { Duration::from_millis(40) } else { Duration::from_secs(30) };
        let mut quick = false;
        match rx.recv_timeout(tick) {
            Ok(c) => {
                match c["cmd"].as_str().unwrap_or("") {
                    "gamma-config" => {
                        cfg.mode = c["mode"].as_str().unwrap_or("off").to_string();
                        cfg.temp = c["temp"].as_f64().unwrap_or(4000.0).clamp(1900.0, 6500.0);
                        cfg.from = c["from"].as_str().and_then(hm).unwrap_or(20.0);
                        cfg.to = c["to"].as_str().and_then(hm).unwrap_or(7.0);
                        cfg.lat = c["lat"].as_f64();
                        cfg.lon = c["lon"].as_f64();
                        override_on = None;
                        configured = true;
                    }
                    "gamma-override" => {
                        let p = plan(&cfg);
                        override_on = Some((c["on"].as_bool().unwrap_or(false), p.next));
                    }
                    _ => {}
                }
                quick = true;
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        if !configured {
            continue;
        }

        let p = plan(&cfg);
        // An override lasts until the schedule's next change.
        if let Some((_, until)) = override_on {
            if until != p.next {
                override_on = None;
            }
        }
        let night = match override_on {
            Some((on, _)) => if on { 1.0 } else { 0.0 },
            None => p.night,
        };
        let target = NEUTRAL + (cfg.temp - NEUTRAL) * night;

        // Only hold a Wayland connection while there is something to warm.
        if (target - NEUTRAL).abs() >= 1.0 || (current - NEUTRAL).abs() >= 1.0 {
            if wl.is_none() {
                match Wl::connect() {
                    Ok(w) => {
                        wl = Some(w);
                        error = None;
                    }
                    Err(e) => error = Some(e),
                }
            }
        }

        if (target - fade.map(|f| f.1).unwrap_or(current)).abs() >= 1.0 {
            // A switch fades in a second and a half; the schedule's own
            // half-hour ramp is already in `night`.
            let len = if quick { Duration::from_millis(1500) } else { Duration::from_millis(600) };
            fade = Some((current, target, Instant::now(), len));
        }
        if let Some((from, to, t0, len)) = fade {
            let x = (t0.elapsed().as_secs_f64() / len.as_secs_f64()).min(1.0);
            // Eased, so it settles rather than stops.
            let e = x * x * (3.0 - 2.0 * x);
            current = from + (to - from) * e;
            if x >= 1.0 {
                current = to;
                fade = None;
            }
        }
        if let Some(w) = &mut wl {
            if (w.st.applied - current).abs() >= 1.0 {
                error = w.apply(current);
            }
            if fade.is_none() && (current - NEUTRAL).abs() < 1.0 {
                // Nothing to hold: let the connection go.
                wl = None;
            }
        }

        let mut ev = json!({
            "ev": "gamma", "available": error.as_deref().map(|e| !e.starts_with("the compositor") && !e.starts_with("no Wayland")).unwrap_or(true),
            "active": (target - NEUTRAL).abs() >= 1.0, "temp": current.round(), "target": target.round(),
            "mode": cfg.mode, "override": override_on.map(|o| o.0),
        });
        if let Some((rise, set)) = p.sun {
            ev["sunrise"] = json!(fmt_hm(rise));
            ev["sunset"] = json!(fmt_hm(set));
        }
        if !p.place.is_empty() {
            ev["place"] = json!(p.place);
        }
        if let Some(n) = p.next {
            ev["next"] = json!(fmt_hm(n));
        }
        if let Some(e) = &error {
            ev["error"] = json!(e);
        } else if p.no_place {
            ev["error"] = json!(format!("no location for the time zone \"{}\" — set one to follow sunset and sunrise", p.place));
        }
        // Said when what it is doing changes, not at each step of a fade.
        let summary = { let mut s = ev.clone(); s["temp"] = Value::Null; s };
        if summary != last_emit {
            out::emit(ev);
            last_emit = summary;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn white() {
        let n = whitepoint(6500.0);
        assert!((n[0] - 1.0).abs() < 1e-9 && (n[1] - 1.0).abs() < 1e-9 && (n[2] - 1.0).abs() < 1e-9);
        let w = whitepoint(3400.0);
        assert!(w[0] > 0.99 && w[1] > 0.7 && w[1] < 0.85 && w[2] > 0.45 && w[2] < 0.65, "{w:?}");
        let r = ramps(4, 3400.0);
        assert_eq!(r.len(), 4 * 2 * 3);
    }
    #[test]
    fn sun() {
        // London, 2026-06-21: rise ~03:43 UTC, set ~20:21 UTC.
        let day = 20625; // days since 1970-01-01 for 2026-06-21
        let (r, s) = sun_times(day, 51.5074, -0.1278).unwrap();
        assert!((r - 3.72).abs() < 0.15 && (s - 20.36).abs() < 0.15, "{r} {s}");
        // Tromsø midsummer: no sunset.
        assert!(sun_times(day, 69.65, 18.96).is_none());
    }
    #[test]
    fn windows() {
        // 20:00 → 07:00, quarter-hour ramps.
        assert_eq!(window(12.0, 20.0, 7.0, 0.25).0, 0.0);
        assert_eq!(window(23.0, 20.0, 7.0, 0.25).0, 1.0);
        assert!((window(20.125, 20.0, 7.0, 0.25).0 - 0.5).abs() < 1e-6);
        assert_eq!(window(23.0, 20.0, 7.0, 0.25).1, 7.0);
        assert_eq!(window(12.0, 20.0, 7.0, 0.25).1, 20.0);
    }
    #[test]
    fn zone() {
        if std::path::Path::new("/usr/share/zoneinfo/zone1970.tab").exists() {
            let (lat, lon) = zone_coords("Europe/London").unwrap();
            assert!((lat - 51.5).abs() < 0.2 && (lon + 0.12).abs() < 0.2, "{lat} {lon}");
            let (lat, lon) = zone_coords("America/New_York").unwrap();
            assert!((lat - 40.7).abs() < 0.2 && (lon + 74.0).abs() < 0.2, "{lat} {lon}");
        }
    }
}
