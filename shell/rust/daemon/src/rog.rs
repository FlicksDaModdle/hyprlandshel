//! ASUS ROG laptops (the G14 this was written on, and the rest asusd
//! supports): what asusd (asusctl's service, xyz.ljones.Asusd) offers,
//! read over D-Bus and set from the shell.
//!
//!   platform    performance profile (Quiet / Balanced / Performance …),
//!               battery charge limit and a one-off full charge
//!   keyboard    backlight brightness, and the lighting mode and colour
//!               (xyz.ljones.Aura)
//!   firmware    the "armoury" attributes asusd exposes one object each:
//!               GPU mode (dgpu_disable + gpu_mux_mode, applied by asusd at
//!               the next boot), panel overdrive, boot sound, MiniLED …
//!
//! Everything is found through asusd's ObjectManager rather than assumed,
//! so a model without a part simply has no such entry.
//!
//! Commands:  rog-refresh
//!            rog-profile {profile}            0 Balanced, 1 Performance,
//!                                             2 Quiet, 3 LowPower
//!            rog-charge {limit}               20..100
//!            rog-full-charge                  once, to 100%
//!            rog-kbd-brightness {level}       0..3
//!            rog-kbd-mode {mode, colour, colour2?, speed?, direction?}
//!            rog-attr {name, value}
//!            rog-gpu {mode}                   "integrated" | "hybrid" | "ultimate"
//! Events:    rog {available, …}, rog-error {op, message}
//!
//! HYPRSHELL_ROG_BUS=session talks to a stand-in on the session bus.

use crate::out;
use serde_json::{json, Map, Value as Json};
use std::collections::HashMap;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Structure, Value};

const ASUSD: &str = "xyz.ljones.Asusd";
const PLATFORM: &str = "xyz.ljones.Platform";
const AURA: &str = "xyz.ljones.Aura";
const ARMOURY: &str = "xyz.ljones.AsusArmoury";

type Props = HashMap<String, OwnedValue>;
type Objects = HashMap<OwnedObjectPath, HashMap<String, Props>>;

fn num(v: &Value) -> Option<i64> {
    Some(match v {
        Value::U8(x) => *x as i64,
        Value::U16(x) => *x as i64,
        Value::I16(x) => *x as i64,
        Value::U32(x) => *x as i64,
        Value::I32(x) => *x as i64,
        Value::U64(x) => *x as i64,
        Value::I64(x) => *x,
        Value::Bool(b) => *b as i64,
        Value::Value(inner) => return num(inner),
        _ => return None,
    })
}
fn p_num(p: &Props, k: &str) -> Option<i64> {
    p.get(k).and_then(|v| num(v))
}
fn p_bool(p: &Props, k: &str) -> Option<bool> {
    match p.get(k).map(|v| &**v) {
        Some(Value::Bool(b)) => Some(*b),
        _ => None,
    }
}
fn p_str(p: &Props, k: &str) -> Option<String> {
    match p.get(k).map(|v| &**v) {
        Some(Value::Str(s)) => Some(s.to_string()),
        _ => None,
    }
}
fn p_nums(p: &Props, k: &str) -> Vec<i64> {
    match p.get(k).map(|v| &**v) {
        Some(Value::Array(a)) => a.iter().filter_map(num).collect(),
        _ => Vec::new(),
    }
}

fn hex(c: &Value) -> Option<String> {
    let Value::Structure(s) = c else { return None };
    let f = s.fields();
    if f.len() != 3 {
        return None;
    }
    Some(format!("#{:02x}{:02x}{:02x}", num(&f[0])?, num(&f[1])?, num(&f[2])?))
}
fn rgb(s: &str) -> (u8, u8, u8) {
    let v = u32::from_str_radix(s.trim_start_matches('#'), 16).unwrap_or(0xffffff);
    ((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

/// AuraEffect: (mode u, zone u, colour1 (yyy), colour2 (yyy), speed s,
/// direction s).
fn effect_json(v: &Value) -> Json {
    let Value::Structure(s) = v else { return Json::Null };
    let f = s.fields();
    if f.len() < 6 {
        return Json::Null;
    }
    let st = |v: &Value| if let Value::Str(s) = v { s.to_string() } else { String::new() };
    json!({
        "mode": num(&f[0]), "zone": num(&f[1]),
        "colour": hex(&f[2]), "colour2": hex(&f[3]),
        "speed": st(&f[4]), "direction": st(&f[5])
    })
}

/// The three GPU modes from the two firmware switches, as asusd's own
/// control centre reads them.
fn gpu_mode(dgpu_disable: Option<i64>, mux: Option<i64>) -> &'static str {
    match (dgpu_disable, mux) {
        (_, Some(0)) => "ultimate",
        (Some(1), _) => "integrated",
        (Some(_), _) => "hybrid",
        _ => "",
    }
}

fn snapshot(conn: &Connection) -> zbus::Result<Json> {
    let m = conn.call_method(Some(ASUSD), "/", Some("org.freedesktop.DBus.ObjectManager"), "GetManagedObjects", &())?;
    let objs: Objects = m.body().deserialize()?;
    let mut platform = Json::Null;
    let mut aura: Vec<Json> = Vec::new();
    let mut attrs = Map::new();
    for (path, ifaces) in &objs {
        if let Some(p) = ifaces.get(PLATFORM) {
            platform = json!({
                "path": path.as_str(),
                "version": p_str(p, "Version"),
                "profile": p_num(p, "PlatformProfile"),
                "choices": p_nums(p, "PlatformProfileChoices"),
                "chargeLimit": p_num(p, "ChargeControlEndThreshold"),
                "profileOnAc": p_num(p, "PlatformProfileOnAc"),
                "profileOnBattery": p_num(p, "PlatformProfileOnBattery"),
                "changeOnAc": p_bool(p, "ChangePlatformProfileOnAc"),
                "changeOnBattery": p_bool(p, "ChangePlatformProfileOnBattery"),
            });
        }
        if let Some(a) = ifaces.get(AURA) {
            aura.push(json!({
                "path": path.as_str(),
                "brightness": p_num(a, "Brightness"),
                "brightnessLevels": p_nums(a, "SupportedBrightness"),
                "mode": p_num(a, "LedMode"),
                "modes": p_nums(a, "SupportedBasicModes"),
                "effect": a.get("LedModeData").map(|v| effect_json(v)).unwrap_or(Json::Null),
            }));
        }
        if let Some(a) = ifaces.get(ARMOURY) {
            let name = path.as_str().rsplit('/').next().unwrap_or("").to_string();
            attrs.insert(name, json!({
                "path": path.as_str(),
                "value": p_num(a, "CurrentValue"),
                "default": p_num(a, "DefaultValue"),
                "min": p_num(a, "MinValue"),
                "max": p_num(a, "MaxValue"),
                "step": p_num(a, "ScalarIncrement"),
                "possible": p_nums(a, "PossibleValues"),
                // A GPU switch waiting for the next boot.
                "queued": p_num(a, "QueuedGpuValue").filter(|v| *v >= 0),
            }));
        }
    }
    let val = |n: &str, queued: bool| -> Option<i64> {
        let a = attrs.get(n)?;
        if queued {
            if let Some(q) = a["queued"].as_i64() {
                return Some(q);
            }
        }
        a["value"].as_i64()
    };
    let has_gpu = attrs.contains_key("dgpu_disable") || attrs.contains_key("gpu_mux_mode");
    let gpu = if has_gpu {
        let now = gpu_mode(val("dgpu_disable", false), val("gpu_mux_mode", false));
        let next = gpu_mode(val("dgpu_disable", true), val("gpu_mux_mode", true));
        let mut choices = vec!["integrated", "hybrid"];
        if attrs.contains_key("gpu_mux_mode") {
            choices.push("ultimate");
        }
        json!({ "mode": now, "pending": if next != now { next } else { "" }, "choices": choices })
    } else {
        Json::Null
    };
    Ok(json!({
        "ev": "rog", "available": true,
        "platform": platform, "aura": aura, "attrs": attrs, "gpu": gpu
    }))
}

fn set_prop(conn: &Connection, path: &str, iface: &str, prop: &str, v: Value) -> zbus::Result<()> {
    conn.call_method(Some(ASUSD), path, Some("org.freedesktop.DBus.Properties"), "Set", &(iface, prop, v)).map(|_| ())
}

fn err_text(e: &zbus::Error) -> String {
    match e {
        zbus::Error::MethodError(name, desc, _) => desc.clone().unwrap_or_else(|| name.to_string()),
        zbus::Error::FDO(f) => f.to_string(),
        other => other.to_string(),
    }
}

struct Rog {
    conn: Connection,
    last: Json,
}

impl Rog {
    fn platform_path(&self) -> &str {
        self.last["platform"]["path"].as_str().unwrap_or("/xyz/ljones")
    }
    fn aura_path(&self, c: &Json) -> Option<String> {
        if let Some(p) = c["path"].as_str() {
            return Some(p.to_string());
        }
        self.last["aura"].as_array().and_then(|a| a.first()).and_then(|a| a["path"].as_str()).map(|s| s.to_string())
    }
    fn attr_path(&self, name: &str) -> String {
        self.last["attrs"][name]["path"].as_str().map(|s| s.to_string()).unwrap_or_else(|| format!("/xyz/ljones/asus_armoury/{name}"))
    }
    fn set_attr(&self, name: &str, value: i32) -> zbus::Result<()> {
        set_prop(&self.conn, &self.attr_path(name), ARMOURY, "CurrentValue", Value::from(value))
    }

    fn command(&self, c: &Json) -> Result<(), String> {
        let cmd = c["cmd"].as_str().unwrap_or("");
        let r = match cmd {
            "rog-profile" => {
                let p = c["profile"].as_u64().ok_or("no profile")? as u32;
                set_prop(&self.conn, self.platform_path(), PLATFORM, "PlatformProfile", Value::from(p))
            }
            "rog-charge" => {
                let l = c["limit"].as_u64().ok_or("no limit")?.clamp(20, 100) as u8;
                set_prop(&self.conn, self.platform_path(), PLATFORM, "ChargeControlEndThreshold", Value::from(l))
            }
            "rog-full-charge" => self.conn.call_method(Some(ASUSD), self.platform_path(), Some(PLATFORM), "OneShotFullCharge", &()).map(|_| ()),
            "rog-kbd-brightness" => {
                let path = self.aura_path(c).ok_or("no keyboard lighting")?;
                let l = c["level"].as_u64().ok_or("no level")?.min(3) as u32;
                set_prop(&self.conn, &path, AURA, "Brightness", Value::from(l))
            }
            "rog-kbd-mode" => {
                let path = self.aura_path(c).ok_or("no keyboard lighting")?;
                let mode = c["mode"].as_u64().unwrap_or(0) as u32;
                let (r1, g1, b1) = rgb(c["colour"].as_str().unwrap_or("#ffffff"));
                let (r2, g2, b2) = rgb(c["colour2"].as_str().unwrap_or("#000000"));
                let speed = c["speed"].as_str().unwrap_or("Med").to_string();
                let dir = c["direction"].as_str().unwrap_or("Right").to_string();
                let effect = Structure::from((mode, 0u32, (r1, g1, b1), (r2, g2, b2), speed, dir));
                set_prop(&self.conn, &path, AURA, "LedModeData", Value::from(effect))
            }
            "rog-attr" => {
                let name = c["name"].as_str().ok_or("no name")?;
                let v = c["value"].as_i64().ok_or("no value")? as i32;
                self.set_attr(name, v)
            }
            "rog-gpu" => {
                let has_mux = self.last["attrs"].get("gpu_mux_mode").is_some();
                let (dgpu, mux) = match c["mode"].as_str().unwrap_or("") {
                    "integrated" => (1, Some(1)),
                    "hybrid" => (0, Some(1)),
                    "ultimate" if has_mux => (0, Some(0)),
                    m => return Err(format!("no GPU mode \"{m}\" here")),
                };
                // The MUX first: Ultimate wants the dGPU on, and the
                // firmware refuses to disable a dGPU the MUX is wired to.
                let mut r = Ok(());
                if has_mux {
                    if let Some(m) = mux {
                        r = self.set_attr("gpu_mux_mode", m);
                    }
                }
                r.and_then(|_| self.set_attr("dgpu_disable", dgpu))
            }
            _ => return Ok(()),
        };
        r.map_err(|e| err_text(&e))
    }
}

fn connect() -> zbus::Result<Connection> {
    if std::env::var("HYPRSHELL_ROG_BUS").map(|v| v == "session").unwrap_or(false) {
        Connection::session()
    } else {
        Connection::system()
    }
}

/// asusd's signals (properties changing, objects appearing) and its name
/// coming and going, as wake-ups.
fn listen(conn: &Connection, tx: Sender<Json>) {
    let rules = [
        zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).sender(ASUSD).map(|b| b.build()),
        zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender("org.freedesktop.DBus")
            .and_then(|b| b.member("NameOwnerChanged"))
            .and_then(|b| b.arg(0, ASUSD))
            .map(|b| b.build()),
    ];
    for rule in rules.into_iter().flatten() {
        let (conn, tx) = (conn.clone(), tx.clone());
        std::thread::spawn(move || {
            let Ok(iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(64)) else { return };
            for _ in iter.flatten() {
                if tx.send(json!({ "cmd": "_rog-changed" })).is_err() {
                    return;
                }
            }
        });
    }
}

pub fn start() -> Sender<Json> {
    let (tx, rx) = channel::<Json>();
    let me = tx.clone();
    std::thread::spawn(move || {
        let conn = match connect() {
            Ok(c) => c,
            Err(_) => {
                out::emit(json!({ "ev": "rog", "available": false }));
                return;
            }
        };
        listen(&conn, me.clone());
        let mut rog = Rog { conn, last: Json::Null };
        let mut dirty: Option<Instant> = Some(Instant::now() - Duration::from_secs(1));
        loop {
            let wait = match dirty {
                Some(t) => Duration::from_millis(120).saturating_sub(t.elapsed()),
                None => Duration::from_secs(3600),
            };
            match rx.recv_timeout(wait) {
                Ok(c) => match c["cmd"].as_str().unwrap_or("") {
                    "_rog-changed" | "rog-refresh" => {
                        dirty.get_or_insert(Instant::now());
                    }
                    cmd => {
                        if let Err(e) = rog.command(&c) {
                            out::emit(json!({ "ev": "rog-error", "op": cmd, "message": e }));
                        }
                        // asusd does not announce every change it makes.
                        dirty.get_or_insert(Instant::now());
                    }
                },
                Err(RecvTimeoutError::Timeout) => {
                    if dirty.take().is_some() {
                        let snap = snapshot(&rog.conn).unwrap_or_else(|_| json!({ "ev": "rog", "available": false }));
                        if snap != rog.last {
                            out::emit(snap.clone());
                            rog.last = snap;
                        }
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
    });
    tx
}
