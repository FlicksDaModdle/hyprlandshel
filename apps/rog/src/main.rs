//! ROG Control Center: asusd (asusctl) and supergfxd over D-Bus, and the
//! laptop's own sensors from sysfs, in the shell's look.
//!
//! One thread owns the system-bus connection. The window sends it commands;
//! it answers with a fresh snapshot after each, and again whenever asusd
//! says something changed. Sensors are read every two seconds.
//!
//! HYPRSHELL_ROG_BUS=session talks to a stand-in on the session bus.

#![windows_subsystem = "windows"]

slint::include_modules!();

use hyprshell_kit as kit;
use slint::{Color, ModelRc, SharedString, VecModel};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Structure, Value};

const ASUSD: &str = "xyz.ljones.Asusd";
const PLATFORM: &str = "xyz.ljones.Platform";
const AURA: &str = "xyz.ljones.Aura";
const ARMOURY: &str = "xyz.ljones.AsusArmoury";
const FANS: &str = "xyz.ljones.FanCurves";
const GFX: &str = "org.supergfxctl.Daemon";
const GFX_PATH: &str = "/org/supergfxctl/Gfx";

type Props = HashMap<String, OwnedValue>;
type Objects = HashMap<OwnedObjectPath, HashMap<String, Props>>;
type CurveData = (String, [u8; 8], [u8; 8], bool);

// ── what the backend knows ──────────────────────────────────────────────

#[derive(Default, Clone)]
struct AttrInfo {
    path: String,
    value: i64,
    min: Option<i64>,
    max: Option<i64>,
    step: Option<i64>,
    possible: Vec<i64>,
    queued: Option<i64>,
}

#[derive(Default, Clone)]
struct Snap {
    available: bool,
    reason: String,
    version: String,
    platform_path: String,
    profile: Option<i64>,
    choices: Vec<i64>,
    charge: Option<i64>,
    on_ac: Option<i64>,
    on_battery: Option<i64>,
    change_ac: Option<bool>,
    change_battery: Option<bool>,
    aura_path: String,
    kbd_brightness: Option<i64>,
    kbd_levels: usize,
    kbd_mode: i64,
    kbd_modes: Vec<i64>,
    kbd_c1: (u8, u8, u8),
    kbd_c2: (u8, u8, u8),
    kbd_speed: String,
    kbd_dir: String,
    attrs: Vec<(String, AttrInfo)>,
    has_fans: bool,
    fan_profile: i64,
    curves: Vec<CurveData>,
    gfx: Option<Gfx>,
}

#[derive(Default, Clone)]
struct Gfx {
    mode: u32,
    supported: Vec<u32>,
    power: u32,
    pending_mode: u32,
    action: u32,
}

enum Cmd {
    Refresh,
    Profile(u32),
    Auto(bool, bool),
    AutoProfile(bool, u32),
    Charge(u8),
    FullCharge,
    KbdBrightness(u32),
    KbdEffect(u32, (u8, u8, u8), (u8, u8, u8), String, String),
    Gpu(i32),
    FanProfile(i64),
    Curve(CurveData),
    CurveEnabled(String, bool),
    ResetCurves,
    Attr(String, i32),
}

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
fn rgb_of(v: &Value) -> Option<(u8, u8, u8)> {
    let Value::Structure(s) = v else { return None };
    let f = s.fields();
    if f.len() != 3 {
        return None;
    }
    Some((num(&f[0])? as u8, num(&f[1])? as u8, num(&f[2])? as u8))
}

fn err_text(e: &zbus::Error) -> String {
    match e {
        zbus::Error::MethodError(name, desc, _) => desc.clone().unwrap_or_else(|| name.to_string()),
        zbus::Error::FDO(f) => f.to_string(),
        other => other.to_string(),
    }
}

struct Backend {
    conn: Connection,
    last: Snap,
    fan_profile: Option<i64>,
}

impl Backend {
    fn set_prop(&self, path: &str, iface: &str, prop: &str, v: Value) -> zbus::Result<()> {
        self.conn
            .call_method(Some(ASUSD), path, Some("org.freedesktop.DBus.Properties"), "Set", &(iface, prop, v))
            .map(|_| ())
    }

    fn gfx<R: serde::de::DeserializeOwned + zbus::zvariant::Type>(&self, method: &str) -> zbus::Result<R> {
        let m = self.conn.call_method(Some(GFX), GFX_PATH, Some(GFX), method, &())?;
        m.body().deserialize()
    }

    fn snapshot(&mut self) -> Snap {
        let mut s = Snap::default();
        let m = match self.conn.call_method(Some(ASUSD), "/", Some("org.freedesktop.DBus.ObjectManager"), "GetManagedObjects", &()) {
            Ok(m) => m,
            Err(e) => {
                s.reason = match &e {
                    zbus::Error::MethodError(n, _, _) if n.as_str().contains("ServiceUnknown") => String::new(),
                    other => err_text(other),
                };
                // supergfxd alone is still worth showing.
                s.gfx = self.read_gfx();
                s.available = s.gfx.is_some();
                return s;
            }
        };
        let objs: Objects = match m.body().deserialize() {
            Ok(o) => o,
            Err(e) => {
                s.reason = e.to_string();
                return s;
            }
        };
        s.available = true;
        for (path, ifaces) in &objs {
            if let Some(p) = ifaces.get(PLATFORM) {
                s.platform_path = path.as_str().to_string();
                s.version = p_str(p, "Version").unwrap_or_default();
                s.profile = p_num(p, "PlatformProfile");
                s.choices = p_nums(p, "PlatformProfileChoices");
                s.charge = p_num(p, "ChargeControlEndThreshold");
                s.on_ac = p_num(p, "PlatformProfileOnAc");
                s.on_battery = p_num(p, "PlatformProfileOnBattery");
                s.change_ac = p_bool(p, "ChangePlatformProfileOnAc");
                s.change_battery = p_bool(p, "ChangePlatformProfileOnBattery");
            }
            if let Some(a) = ifaces.get(AURA) {
                if s.aura_path.is_empty() {
                    s.aura_path = path.as_str().to_string();
                    s.kbd_brightness = p_num(a, "Brightness");
                    s.kbd_levels = p_nums(a, "SupportedBrightness").len().max(2);
                    s.kbd_mode = p_num(a, "LedMode").unwrap_or(0);
                    s.kbd_modes = p_nums(a, "SupportedBasicModes");
                    if let Some(Value::Structure(st)) = a.get("LedModeData").map(|v| &**v) {
                        let f = st.fields();
                        if f.len() >= 6 {
                            s.kbd_c1 = rgb_of(&f[2]).unwrap_or((255, 0, 0));
                            s.kbd_c2 = rgb_of(&f[3]).unwrap_or((0, 0, 255));
                            if let Value::Str(x) = &f[4] {
                                s.kbd_speed = x.to_string();
                            }
                            if let Value::Str(x) = &f[5] {
                                s.kbd_dir = x.to_string();
                            }
                        }
                    }
                }
            }
            if let Some(a) = ifaces.get(ARMOURY) {
                let name = path.as_str().rsplit('/').next().unwrap_or("").to_string();
                s.attrs.push((
                    name,
                    AttrInfo {
                        path: path.as_str().to_string(),
                        value: p_num(a, "CurrentValue").unwrap_or(0),
                        min: p_num(a, "MinValue").filter(|v| *v >= 0),
                        max: p_num(a, "MaxValue").filter(|v| *v > 0),
                        step: p_num(a, "ScalarIncrement").filter(|v| *v > 0),
                        possible: p_nums(a, "PossibleValues"),
                        queued: p_num(a, "QueuedGpuValue").filter(|v| *v >= 0),
                    },
                ));
            }
            if ifaces.contains_key(FANS) {
                s.has_fans = true;
            }
        }
        s.attrs.sort_by(|a, b| attr_order(&a.0).cmp(&attr_order(&b.0)).then(a.0.cmp(&b.0)));
        if s.has_fans {
            let fp = self.fan_profile.or(s.profile).unwrap_or(0);
            s.fan_profile = fp;
            s.curves = self.read_curves(fp as u32).unwrap_or_default();
        }
        s.gfx = self.read_gfx();
        s
    }

    fn read_curves(&self, profile: u32) -> zbus::Result<Vec<CurveData>> {
        let m = self.conn.call_method(Some(ASUSD), "/xyz/ljones", Some(FANS), "FanCurveData", &(profile,))?;
        m.body().deserialize::<Vec<CurveData>>()
    }

    fn read_gfx(&self) -> Option<Gfx> {
        let mode: u32 = self.gfx("Mode").ok()?;
        Some(Gfx {
            mode,
            supported: self.gfx("Supported").unwrap_or_default(),
            power: self.gfx("Power").unwrap_or(5),
            pending_mode: self.gfx("PendingMode").unwrap_or(6),
            action: self.gfx("PendingUserAction").unwrap_or(4),
        })
    }

    fn attr(&self, name: &str) -> Option<&AttrInfo> {
        self.last.attrs.iter().find(|(n, _)| n == name).map(|(_, a)| a)
    }

    fn set_attr(&self, name: &str, v: i32) -> zbus::Result<()> {
        let path = self.attr(name).map(|a| a.path.clone()).unwrap_or_else(|| format!("/xyz/ljones/asus_armoury/{name}"));
        self.set_prop(&path, ARMOURY, "CurrentValue", Value::from(v))
    }

    fn run(&mut self, c: Cmd) -> Result<Option<String>, String> {
        let pp = if self.last.platform_path.is_empty() { "/xyz/ljones".to_string() } else { self.last.platform_path.clone() };
        let r: zbus::Result<Option<String>> = match c {
            Cmd::Refresh => Ok(None),
            Cmd::Profile(p) => self.set_prop(&pp, PLATFORM, "PlatformProfile", Value::from(p)).map(|_| None),
            Cmd::Auto(ac, on) => self
                .set_prop(&pp, PLATFORM, if ac { "ChangePlatformProfileOnAc" } else { "ChangePlatformProfileOnBattery" }, Value::from(on))
                .map(|_| None),
            Cmd::AutoProfile(ac, p) => self
                .set_prop(&pp, PLATFORM, if ac { "PlatformProfileOnAc" } else { "PlatformProfileOnBattery" }, Value::from(p))
                .map(|_| None),
            Cmd::Charge(l) => self.set_prop(&pp, PLATFORM, "ChargeControlEndThreshold", Value::from(l.clamp(20, 100))).map(|_| None),
            Cmd::FullCharge => self
                .conn
                .call_method(Some(ASUSD), pp.as_str(), Some(PLATFORM), "OneShotFullCharge", &())
                .map(|_| Some("Charging to 100% this once".to_string())),
            Cmd::KbdBrightness(l) => self.set_prop(&self.last.aura_path, AURA, "Brightness", Value::from(l)).map(|_| None),
            Cmd::KbdEffect(mode, c1, c2, speed, dir) => {
                let effect = Structure::from((mode, 0u32, c1, c2, speed, dir));
                self.set_prop(&self.last.aura_path, AURA, "LedModeData", Value::from(effect)).map(|_| None)
            }
            Cmd::Gpu(mode) => self.set_gpu(mode),
            Cmd::FanProfile(p) => {
                self.fan_profile = Some(p);
                Ok(None)
            }
            Cmd::Curve(c) => {
                let p = self.last.fan_profile as u32;
                self.conn.call_method(Some(ASUSD), "/xyz/ljones", Some(FANS), "SetFanCurve", &(p, c)).map(|_| None)
            }
            Cmd::CurveEnabled(fan, on) => {
                let p = self.last.fan_profile as u32;
                self.conn
                    .call_method(Some(ASUSD), "/xyz/ljones", Some(FANS), "SetProfileFanCurveEnabled", &(p, fan, on))
                    .map(|_| None)
            }
            Cmd::ResetCurves => {
                let p = self.last.fan_profile as u32;
                self.conn
                    .call_method(Some(ASUSD), "/xyz/ljones", Some(FANS), "SetCurvesToDefaults", &(p,))
                    .map(|_| Some("Fan curves back to the defaults".to_string()))
            }
            Cmd::Attr(name, v) => self.set_attr(&name, v).map(|_| None),
        };
        r.map_err(|e| err_text(&e))
    }

    fn set_gpu(&self, mode: i32) -> zbus::Result<Option<String>> {
        if self.last.gfx.is_some() {
            let m = self.conn.call_method(Some(GFX), GFX_PATH, Some(GFX), "SetMode", &(mode as u32,))?;
            let action: u32 = m.body().deserialize().unwrap_or(4);
            return Ok(Some(action_text(action).unwrap_or("Graphics mode changed").to_string()));
        }
        let has_mux = self.attr("gpu_mux_mode").is_some();
        let (dgpu, mux) = match mode {
            0 => (1, 1),
            1 => (0, 1),
            _ => (0, 0),
        };
        // The MUX first: Ultimate wants the dGPU on, and the firmware will
        // not disable a dGPU the MUX is wired to.
        if has_mux {
            self.set_attr("gpu_mux_mode", mux)?;
        }
        self.set_attr("dgpu_disable", dgpu)?;
        Ok(Some("Takes effect after a restart".to_string()))
    }
}

fn action_text(a: u32) -> Option<&'static str> {
    match a {
        0 => Some("Log out to finish switching"),
        1 => Some("Restart to finish switching"),
        2 => Some("Switch to Integrated first"),
        3 => Some("Turn the eGPU off first"),
        _ => None,
    }
}

fn attr_order(name: &str) -> u32 {
    match name {
        "panel_overdrive" => 0,
        "mini_led_mode" => 1,
        "panel_hd_mode" => 2,
        "screen_auto_brightness" => 3,
        "boot_sound" => 10,
        "mcu_powersave" => 11,
        "charge_mode" => 12,
        n if n.starts_with("ppt_") => 20,
        n if n.starts_with("nv_") => 30,
        _ => 40,
    }
}

/// The friendly name, a line of help and a unit for each firmware attribute
/// asusd may offer. Unknown ones are shown by their own name.
fn attr_label(name: &str) -> (&'static str, &'static str, &'static str) {
    match name {
        "panel_overdrive" => ("Panel overdrive", "Faster pixel response, less ghosting in fast games.", ""),
        "mini_led_mode" => ("MiniLED mode", "Local dimming for the MiniLED panel.", ""),
        "panel_hd_mode" => ("Panel resolution mode", "", ""),
        "screen_auto_brightness" => ("Automatic brightness", "", ""),
        "boot_sound" => ("Boot sound", "The chime when the laptop starts.", ""),
        "mcu_powersave" => ("MCU power saving", "Lower power for the embedded controller while asleep.", ""),
        "charge_mode" => ("Charge mode", "", ""),
        "ppt_pl1_spl" => ("Sustained power limit (SPL)", "The CPU's long-term power budget.", " W"),
        "ppt_pl2_sppt" => ("Short boost limit (SPPT)", "Power the CPU may draw for a few minutes.", " W"),
        "ppt_pl3_fppt" | "ppt_fppt" => ("Fast boost limit (FPPT)", "Power the CPU may draw for a few seconds.", " W"),
        "ppt_apu_sppt" => ("APU boost limit", "", " W"),
        "ppt_platform_sppt" => ("Platform boost limit", "", " W"),
        "ppt_enabled" => ("Custom power limits", "Use the limits below instead of the profile's.", ""),
        "nv_dynamic_boost" => ("GPU dynamic boost", "Extra power the GPU may borrow from the CPU.", " W"),
        "nv_temp_target" => ("GPU temperature target", "", " °C"),
        "nv_tgp" => ("GPU power (TGP)", "", " W"),
        "nv_base_tgp" => ("GPU base power", "", " W"),
        "apu_mem" => ("Memory for the integrated GPU", "", ""),
        "cores_performance" => ("Performance cores", "", ""),
        "cores_efficiency" => ("Efficiency cores", "", ""),
        "egpu_enable" => ("External GPU", "The XG Mobile dock's GPU.", ""),
        _ => ("", "", ""),
    }
}

fn profile_name(p: i64) -> &'static str {
    match p {
        0 => "Balanced",
        1 => "Performance",
        2 => "Quiet",
        3 => "Low power",
        4 => "Custom",
        _ => "Profile",
    }
}

fn aura_name(m: i64) -> &'static str {
    match m {
        0 => "Static",
        1 => "Breathe",
        2 => "Rainbow cycle",
        3 => "Rainbow wave",
        4 => "Star",
        5 => "Rain",
        6 => "Highlight",
        7 => "Laser",
        8 => "Ripple",
        10 => "Pulse",
        11 => "Comet",
        12 => "Flash",
        _ => "Effect",
    }
}

fn gfx_name(m: u32) -> &'static str {
    match m {
        0 => "Hybrid",
        1 => "Integrated",
        2 => "NVIDIA (no modeset)",
        3 => "VFIO",
        4 => "eGPU",
        5 => "Ultimate",
        _ => "",
    }
}

fn gfx_power(p: u32) -> &'static str {
    match p {
        0 => "Active",
        1 => "Suspended (asleep)",
        2 => "Off",
        3 => "Disabled by the firmware",
        4 => "Driving the display (MUX)",
        _ => "",
    }
}

fn connect() -> zbus::Result<Connection> {
    if std::env::var("HYPRSHELL_ROG_BUS").map(|v| v == "session").unwrap_or(false) {
        Connection::session()
    } else {
        Connection::system()
    }
}

/// asusd's and supergfxd's signals, as wake-ups.
fn listen(conn: &Connection, tx: Sender<Option<Cmd>>) {
    let rules = [
        zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).sender(ASUSD).map(|b| b.build()),
        zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).sender(GFX).map(|b| b.build()),
        zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender("org.freedesktop.DBus")
            .and_then(|b| b.member("NameOwnerChanged"))
            .map(|b| b.build()),
    ];
    for rule in rules.into_iter().flatten() {
        let (conn, tx) = (conn.clone(), tx.clone());
        std::thread::spawn(move || {
            let Ok(iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(64)) else { return };
            for _ in iter.flatten() {
                if tx.send(None).is_err() {
                    return;
                }
            }
        });
    }
}

// ── sensors ─────────────────────────────────────────────────────────────

struct Sensors {
    cpu_temp: Option<f64>,
    gpu_temp: Option<f64>,
    fans: Vec<(String, u64)>,
    battery: Option<Battery>,
}

struct Battery {
    level: f64,
    status: String,
    watts: Option<f64>,
    health: Option<f64>,
    cycles: Option<u64>,
    design_wh: Option<f64>,
}

fn read(p: &std::path::Path) -> Option<String> {
    std::fs::read_to_string(p).ok().map(|s| s.trim().to_string())
}
fn read_num(p: &std::path::Path) -> Option<f64> {
    read(p)?.parse().ok()
}

fn sensors() -> Sensors {
    let mut s = Sensors { cpu_temp: None, gpu_temp: None, fans: Vec::new(), battery: None };
    if let Ok(dir) = std::fs::read_dir("/sys/class/hwmon") {
        for e in dir.flatten() {
            let p = e.path();
            let name = read(&p.join("name")).unwrap_or_default();
            match name.as_str() {
                "k10temp" | "coretemp" | "zenpower" => {
                    if s.cpu_temp.is_none() {
                        s.cpu_temp = read_num(&p.join("temp1_input")).map(|v| v / 1000.0);
                    }
                }
                "amdgpu" | "nouveau" | "radeon" => {
                    // The dGPU when there is one, else the iGPU.
                    if let Some(t) = read_num(&p.join("temp1_input")).map(|v| v / 1000.0) {
                        s.gpu_temp = Some(s.gpu_temp.map_or(t, |o: f64| o.max(t)));
                    }
                }
                "asus" | "asus_custom_fan_curve" => {
                    for i in 1..=3 {
                        if let Some(rpm) = read_num(&p.join(format!("fan{i}_input"))) {
                            let label = read(&p.join(format!("fan{i}_label")))
                                .unwrap_or_else(|| ["CPU fan", "GPU fan", "Mid fan"][i - 1].to_string());
                            if !s.fans.iter().any(|(l, _)| *l == label) {
                                s.fans.push((label, rpm as u64));
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    if let Ok(dir) = std::fs::read_dir("/sys/class/power_supply") {
        for e in dir.flatten() {
            let p = e.path();
            if read(&p.join("type")).as_deref() != Some("Battery") {
                continue;
            }
            let level = read_num(&p.join("capacity")).unwrap_or(0.0);
            let status = read(&p.join("status")).unwrap_or_default();
            let (full, design) = match (read_num(&p.join("energy_full")), read_num(&p.join("energy_full_design"))) {
                (Some(f), Some(d)) => (Some(f), Some(d)),
                _ => (read_num(&p.join("charge_full")), read_num(&p.join("charge_full_design"))),
            };
            let watts = read_num(&p.join("power_now")).map(|w| w / 1e6).or_else(|| {
                Some(read_num(&p.join("current_now"))? * read_num(&p.join("voltage_now"))? / 1e12)
            });
            let volts = read_num(&p.join("voltage_min_design")).map(|v| v / 1e6);
            let design_wh = if read_num(&p.join("energy_full_design")).is_some() {
                design.map(|d| d / 1e6)
            } else {
                design.zip(volts).map(|(d, v)| d / 1e6 * v)
            };
            s.battery = Some(Battery {
                level,
                status,
                watts: watts.filter(|w| *w > 0.05),
                health: full.zip(design).filter(|(_, d)| *d > 0.0).map(|(f, d)| (f / d * 100.0).min(100.0)),
                cycles: read_num(&p.join("cycle_count")).map(|c| c as u64).filter(|c| *c > 0),
                design_wh,
            });
            break;
        }
    }
    s
}

fn model_name() -> String {
    let p = std::path::Path::new("/sys/class/dmi/id");
    let name = read(&p.join("product_name")).unwrap_or_default();
    let family = read(&p.join("product_family")).unwrap_or_default();
    if !family.is_empty() && !name.contains(&family) && family.len() < 40 {
        format!("{family} · {name}")
    } else {
        name
    }
}

// ── into the window ─────────────────────────────────────────────────────

fn rgb(c: (u8, u8, u8)) -> Color {
    Color::from_rgb_u8(c.0, c.1, c.2)
}
fn from_color(c: Color) -> (u8, u8, u8) {
    (c.red(), c.green(), c.blue())
}

fn opts(v: Vec<(i32, String)>) -> ModelRc<Opt> {
    ModelRc::new(VecModel::from(v.into_iter().map(|(id, name)| Opt { id, name: name.into() }).collect::<Vec<_>>()))
}

/// The line through a curve's points, in a 100×100 view box (temperature
/// 20–100 °C across, fan 0–100 % up), with a flat lead-in and tail so it
/// spans the chart.
fn curve_path(temps: &[u8; 8], pwm: &[u8; 8]) -> String {
    let pt = |i: usize| ((temps[i] as f64 - 20.0) / 80.0 * 100.0, 100.0 - pwm[i] as f64 / 255.0 * 100.0);
    let (x0, y0) = pt(0);
    let mut d = format!("M 0 {y0:.2} L {:.2} {y0:.2}", x0.max(0.0));
    for i in 1..8 {
        let (x, y) = pt(i);
        d += &format!(" L {:.2} {y:.2}", x.clamp(0.0, 100.0));
    }
    let (_, yl) = pt(7);
    d += &format!(" L 100 {yl:.2}");
    d
}

fn fan_label(f: &str) -> String {
    match f {
        "CPU" | "cpu" => "CPU fan".into(),
        "GPU" | "gpu" => "GPU fan".into(),
        "MID" | "mid" => "Middle fan".into(),
        o => format!("{o} fan"),
    }
}

fn to_curve(c: &CurveData) -> Curve {
    Curve {
        fan: c.0.clone().into(),
        label: fan_label(&c.0).into(),
        enabled: c.3,
        temps: ModelRc::new(VecModel::from(c.2.iter().map(|v| *v as i32).collect::<Vec<_>>())),
        pwm: ModelRc::new(VecModel::from(c.1.iter().map(|v| *v as i32).collect::<Vec<_>>())),
        path: curve_path(&c.2, &c.1).into(),
    }
}

const SPEEDS: [&str; 3] = ["Low", "Med", "High"];
const DIRECTIONS: [&str; 4] = ["Right", "Left", "Up", "Down"];

fn apply(ui: &AppWindow, s: &Snap) {
    let r = ui.global::<Rog>();
    r.set_ready(true);
    r.set_available(s.available);
    r.set_reason(s.reason.clone().into());
    r.set_version(s.version.clone().into());

    let profiles: Vec<(i32, String)> = s.choices.iter().map(|p| (*p as i32, profile_name(*p).to_string())).collect();
    // Quiet, Balanced, Performance — left to right as they feel.
    let mut profiles = profiles;
    profiles.sort_by_key(|(id, _)| match id {
        3 => 0,
        2 => 1,
        0 => 2,
        1 => 3,
        _ => 4,
    });
    r.set_profiles(opts(profiles));
    r.set_profile(s.profile.unwrap_or(-1) as i32);
    r.set_has_auto_profile(s.change_ac.is_some());
    r.set_change_on_ac(s.change_ac.unwrap_or(false));
    r.set_change_on_battery(s.change_battery.unwrap_or(false));
    r.set_profile_on_ac(s.on_ac.unwrap_or(-1) as i32);
    r.set_profile_on_battery(s.on_battery.unwrap_or(-1) as i32);

    r.set_has_charge_limit(s.charge.is_some());
    r.set_charge_limit(s.charge.unwrap_or(100) as i32);

    r.set_has_keyboard(!s.aura_path.is_empty());
    r.set_kbd_brightness(s.kbd_brightness.unwrap_or(0) as i32);
    r.set_kbd_levels(s.kbd_levels as i32);
    r.set_kbd_modes(opts(s.kbd_modes.iter().map(|m| (*m as i32, aura_name(*m).to_string())).collect()));
    r.set_kbd_mode(s.kbd_mode as i32);
    r.set_kbd_colour(rgb(s.kbd_c1));
    r.set_kbd_colour2(rgb(s.kbd_c2));
    r.set_kbd_speed(SPEEDS.iter().position(|x| *x == s.kbd_speed).unwrap_or(1) as i32);
    r.set_kbd_direction(DIRECTIONS.iter().position(|x| *x == s.kbd_dir).unwrap_or(0) as i32);

    // Graphics: supergfxd when it runs (it does the switching properly,
    // driver and all), else the firmware switches through asusd.
    if let Some(g) = &s.gfx {
        let mut modes: Vec<(i32, String)> = g
            .supported
            .iter()
            .filter(|m| matches!(**m, 0 | 1 | 4 | 5))
            .map(|m| (*m as i32, gfx_name(*m).to_string()))
            .collect();
        modes.sort_by_key(|(id, _)| match id {
            1 => 0,
            0 => 1,
            5 => 2,
            _ => 3,
        });
        r.set_has_gpu(!modes.is_empty());
        r.set_gpu_modes(opts(modes));
        r.set_gpu_mode(g.mode as i32);
        r.set_gpu_pending(if g.pending_mode != g.mode && g.pending_mode < 6 { g.pending_mode as i32 } else { -1 });
        r.set_gpu_source("supergfxd".into());
        r.set_gpu_power(gfx_power(g.power).into());
        r.set_gpu_action(action_text(g.action).unwrap_or("").into());
    } else {
        let get = |n: &str, queued: bool| {
            s.attrs.iter().find(|(k, _)| k == n).map(|(_, a)| if queued { a.queued.unwrap_or(a.value) } else { a.value })
        };
        let has_mux = get("gpu_mux_mode", false).is_some();
        let mode_of = |q: bool| match (get("dgpu_disable", q), get("gpu_mux_mode", q)) {
            (_, Some(0)) => 2,
            (Some(1), _) => 0,
            (Some(_), _) => 1,
            _ => -1,
        };
        let now = mode_of(false);
        let next = mode_of(true);
        r.set_has_gpu(now >= 0);
        let mut modes = vec![(0, "Integrated".to_string()), (1, "Hybrid".to_string())];
        if has_mux {
            modes.push((2, "Ultimate".to_string()));
        }
        r.set_gpu_modes(opts(modes));
        r.set_gpu_mode(now);
        r.set_gpu_pending(if next != now { next } else { -1 });
        r.set_gpu_source("asusd".into());
        r.set_gpu_power("".into());
        r.set_gpu_action(if next != now { "Restart to finish switching".into() } else { "".into() });
    }

    r.set_has_fans(s.has_fans);
    r.set_fan_profile(s.fan_profile as i32);
    r.set_curves(ModelRc::new(VecModel::from(s.curves.iter().map(to_curve).collect::<Vec<_>>())));

    let attrs: Vec<Attr> = s
        .attrs
        .iter()
        .filter(|(n, _)| !matches!(n.as_str(), "dgpu_disable" | "gpu_mux_mode"))
        .map(|(n, a)| {
            let (label, help, unit) = attr_label(n);
            let label = if label.is_empty() { n.replace('_', " ") } else { label.to_string() };
            let binary = a.possible == [0, 1] || (a.min == Some(0) && a.max == Some(1));
            let kind = if binary {
                "switch"
            } else if !a.possible.is_empty() && a.possible.len() <= 6 {
                "choice"
            } else {
                "slider"
            };
            Attr {
                name: n.clone().into(),
                label: label.into(),
                help: help.into(),
                kind: kind.into(),
                value: a.value as i32,
                min: a.min.or(a.possible.iter().min().copied()).unwrap_or(0) as i32,
                max: a.max.or(a.possible.iter().max().copied()).unwrap_or(100) as i32,
                step: a.step.unwrap_or(1) as i32,
                unit: unit.into(),
                choices: opts(a.possible.iter().map(|v| (*v as i32, v.to_string())).collect()),
            }
        })
        .collect();
    r.set_attrs(ModelRc::new(VecModel::from(attrs)));
}

fn reading(label: &str, value: String, icon: &str, frac: f32, tint: Color) -> Reading {
    Reading { label: label.into(), value: value.into(), icon: icon.into(), frac, tint }
}

fn apply_sensors(ui: &AppWindow, s: &Sensors) {
    let r = ui.global::<Rog>();
    let t = ui.global::<Theme>();
    let heat = |c: f64| if c >= 90.0 { t.get_danger() } else if c >= 75.0 { t.get_warn() } else { t.get_accent() };
    let mut out = Vec::new();
    if let Some(c) = s.cpu_temp {
        out.push(reading("CPU", format!("{c:.0} °C"), "thermometer", (c / 100.0) as f32, heat(c)));
    }
    if let Some(c) = s.gpu_temp {
        out.push(reading("GPU", format!("{c:.0} °C"), "thermometer", (c / 100.0) as f32, heat(c)));
    }
    for (label, rpm) in &s.fans {
        out.push(reading(label, if *rpm == 0 { "Stopped".into() } else { format!("{rpm} rpm") }, "fan", (*rpm as f32 / 7000.0).min(1.0), t.get_accent()));
    }
    if let Some(b) = &s.battery {
        out.push(reading(
            "Battery",
            format!("{:.0}%", b.level),
            "battery",
            (b.level / 100.0) as f32,
            if b.level < 15.0 { t.get_danger() } else { t.get_ok() },
        ));
    }
    r.set_sensors(ModelRc::new(VecModel::from(out)));

    let mut bat = Vec::new();
    if let Some(b) = &s.battery {
        r.set_battery_level(b.level as f32);
        r.set_battery_state(b.status.clone().into());
        bat.push(reading("Charge", format!("{:.0}%", b.level), "battery", (b.level / 100.0) as f32, t.get_ok()));
        bat.push(reading("State", b.status.clone(), "plugZap", -1.0, t.get_accent()));
        if let Some(w) = b.watts {
            bat.push(reading(if b.status == "Charging" { "Charging at" } else { "Drawing" }, format!("{w:.1} W"), "zap", -1.0, t.get_accent()));
        }
        if let Some(h) = b.health {
            bat.push(reading("Health", format!("{h:.0}%"), "pulse", (h / 100.0) as f32, if h < 70.0 { t.get_warn() } else { t.get_ok() }));
        }
        if let Some(c) = b.cycles {
            bat.push(reading("Cycles", c.to_string(), "rotateCw", -1.0, t.get_accent()));
        }
        if let Some(d) = b.design_wh {
            bat.push(reading("Design capacity", format!("{d:.0} Wh"), "battery100", -1.0, t.get_accent()));
        }
    }
    r.set_battery(ModelRc::new(VecModel::from(bat)));
}

fn main() {
    kit::init("hyprshell-rog");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-rog");
    let model = model_name();
    ui.global::<Rog>().set_model(model.into());

    let (tx, rx) = channel::<Option<Cmd>>();
    let weak = ui.as_weak();

    // Toasts: shown for three seconds.
    let toast_timer = Rc::new(slint::Timer::default());
    let show_toast = {
        let weak = ui.as_weak();
        let timer = toast_timer.clone();
        move |text: String, bad: bool| {
            let Some(ui) = weak.upgrade() else { return };
            ui.global::<Rog>().set_toast(text.into());
            ui.global::<Rog>().set_toast_bad(bad);
            let weak = weak.clone();
            timer.start(slint::TimerMode::SingleShot, Duration::from_millis(3000), move || {
                if let Some(ui) = weak.upgrade() {
                    ui.global::<Rog>().set_toast(SharedString::new());
                }
            });
        }
    };

    // The backend.
    let me = tx.clone();
    std::thread::spawn(move || {
        let conn = match connect() {
            Ok(c) => c,
            Err(e) => {
                let reason = format!("Couldn't reach the system bus: {e}");
                let _ = weak.upgrade_in_event_loop(move |ui| {
                    let s = Snap { reason, ..Default::default() };
                    apply(&ui, &s);
                });
                return;
            }
        };
        listen(&conn, me);
        let mut b = Backend { conn, last: Snap::default(), fan_profile: None };
        let mut dirty: Option<Instant> = Some(Instant::now() - Duration::from_secs(1));
        loop {
            let wait = match dirty {
                Some(t) => Duration::from_millis(120).saturating_sub(t.elapsed()),
                None => Duration::from_secs(30),
            };
            match rx.recv_timeout(wait) {
                Ok(None) => {
                    dirty.get_or_insert(Instant::now());
                }
                Ok(Some(c)) => {
                    let msg = b.run(c);
                    let weak = weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        let Some(ui) = weak.upgrade() else { return };
                        match msg {
                            Ok(Some(m)) => ui.invoke_toast(m.into(), false),
                            Err(e) => ui.invoke_toast(e.into(), true),
                            Ok(None) => {}
                        }
                    });
                    // asusd does not announce every change it makes.
                    dirty.get_or_insert(Instant::now());
                }
                Err(RecvTimeoutError::Timeout) => {
                    // Also a slow heartbeat, for changes made behind its
                    // back (Fn+F5 on some firmware).
                    dirty = None;
                    let snap = b.snapshot();
                    b.last = snap.clone();
                    let _ = weak.upgrade_in_event_loop(move |ui| apply(&ui, &snap));
                }
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
    });

    ui.on_toast(move |text, bad| show_toast(text.to_string(), bad));

    let r = ui.global::<Rog>();
    let send = {
        let tx = tx.clone();
        move |c: Cmd| {
            let _ = tx.send(Some(c));
        }
    };
    let s = send.clone();
    r.on_set_profile(move |p| s(Cmd::Profile(p as u32)));
    let s = send.clone();
    r.on_set_auto(move |ac, on| s(Cmd::Auto(ac, on)));
    let s = send.clone();
    r.on_set_auto_profile(move |ac, p| s(Cmd::AutoProfile(ac, p as u32)));
    let s = send.clone();
    r.on_set_charge_limit(move |l| s(Cmd::Charge(l.clamp(20, 100) as u8)));
    let s = send.clone();
    r.on_full_charge(move || s(Cmd::FullCharge));
    let s = send.clone();
    r.on_set_kbd_brightness(move |l| s(Cmd::KbdBrightness(l.max(0) as u32)));
    let s = send.clone();
    r.on_set_kbd_effect(move |mode, c1, c2, speed, dir| {
        s(Cmd::KbdEffect(
            mode.max(0) as u32,
            from_color(c1),
            from_color(c2),
            SPEEDS[speed.clamp(0, 2) as usize].to_string(),
            DIRECTIONS[dir.clamp(0, 3) as usize].to_string(),
        ))
    });
    let s = send.clone();
    r.on_set_gpu_mode(move |m| s(Cmd::Gpu(m)));
    let s = send.clone();
    r.on_pick_fan_profile(move |p| {
        s(Cmd::FanProfile(p as i64));
    });
    let s = send.clone();
    r.on_reset_curves(move || s(Cmd::ResetCurves));
    let s = send.clone();
    r.on_set_attr(move |n, v| s(Cmd::Attr(n.to_string(), v)));

    // Dragging a point moves it in the window at once; letting go sends the
    // whole curve. Points stay in order: one cannot be dragged past its
    // neighbours, and a fan never slows as it gets hotter.
    let weak = ui.as_weak();
    r.on_move_point(move |ci, pi, temp, pwm| {
        let Some(ui) = weak.upgrade() else { return };
        let r = ui.global::<Rog>();
        let curves = r.get_curves();
        let Some(c) = slint::Model::row_data(&curves, ci as usize) else { return };
        let mut temps: Vec<i32> = slint::Model::iter(&c.temps).collect();
        let mut pwms: Vec<i32> = slint::Model::iter(&c.pwm).collect();
        let i = pi as usize;
        if i >= temps.len() {
            return;
        }
        let lo_t = if i > 0 { temps[i - 1] + 1 } else { 20 };
        let hi_t = if i + 1 < temps.len() { temps[i + 1] - 1 } else { 100 };
        temps[i] = temp.clamp(lo_t, hi_t.max(lo_t));
        let lo_p = if i > 0 { pwms[i - 1] } else { 0 };
        let hi_p = if i + 1 < pwms.len() { pwms[i + 1] } else { 255 };
        pwms[i] = pwm.clamp(lo_p, hi_p.max(lo_p));
        let mut t8 = [0u8; 8];
        let mut p8 = [0u8; 8];
        for k in 0..8.min(temps.len()) {
            t8[k] = temps[k].clamp(0, 255) as u8;
            p8[k] = pwms[k].clamp(0, 255) as u8;
        }
        let next = Curve {
            temps: ModelRc::new(VecModel::from(temps)),
            pwm: ModelRc::new(VecModel::from(pwms)),
            path: curve_path(&t8, &p8).into(),
            ..c
        };
        slint::Model::set_row_data(&curves, ci as usize, next);
    });
    let weak = ui.as_weak();
    let s = send.clone();
    r.on_apply_curve(move |ci| {
        let Some(ui) = weak.upgrade() else { return };
        let curves = ui.global::<Rog>().get_curves();
        let Some(c) = slint::Model::row_data(&curves, ci as usize) else { return };
        let mut t8 = [0u8; 8];
        let mut p8 = [0u8; 8];
        for (k, v) in slint::Model::iter(&c.temps).take(8).enumerate() {
            t8[k] = v.clamp(0, 255) as u8;
        }
        for (k, v) in slint::Model::iter(&c.pwm).take(8).enumerate() {
            p8[k] = v.clamp(0, 255) as u8;
        }
        // Moving a point turns its curve on: a custom curve that is off
        // would do nothing, which is not what dragging it means.
        s(Cmd::Curve((c.fan.to_string(), p8, t8, true)));
    });
    let weak = ui.as_weak();
    let s = send.clone();
    r.on_set_curve_enabled(move |ci, on| {
        let Some(ui) = weak.upgrade() else { return };
        let curves = ui.global::<Rog>().get_curves();
        if let Some(c) = slint::Model::row_data(&curves, ci as usize) {
            s(Cmd::CurveEnabled(c.fan.to_string(), on));
        }
    });

    // Sensors, every two seconds while the window is open.
    let weak = ui.as_weak();
    let sensor_timer = slint::Timer::default();
    let tick = move || {
        let weak = weak.clone();
        kit::spawn(sensors, move |s| {
            if let Some(ui) = weak.upgrade() {
                apply_sensors(&ui, &s);
            }
        });
    };
    tick();
    sensor_timer.start(slint::TimerMode::Repeated, Duration::from_secs(2), tick);

    let _ = tx.send(Some(Cmd::Refresh));
    ui.run().expect("run");
}
