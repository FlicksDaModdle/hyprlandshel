//! theme.json as Settings reads and writes it: Config.Appearance's keys,
//! their defaults (src/prefs.json, from Appearance.qml by
//! tools/gen-prefs.py) and the names Settings.qml uses for them.

use hyprshell_kit as kit;
use serde_json::{json, Map, Value};
use std::sync::OnceLock;

struct Table {
    defaults: Map<String, Value>,
    aliases: Map<String, Value>,
}

fn table() -> &'static Table {
    static T: OnceLock<Table> = OnceLock::new();
    T.get_or_init(|| {
        let v: Value = serde_json::from_str(include_str!("prefs.json")).unwrap_or(Value::Null);
        Table {
            defaults: v["defaults"].as_object().cloned().unwrap_or_default(),
            aliases: v["aliases"].as_object().cloned().unwrap_or_default(),
        }
    })
}

/// The key in theme.json for a name Settings.qml uses (its alias, or the
/// key itself).
pub fn key(name: &str) -> String {
    table().aliases.get(name).and_then(|v| v.as_str()).unwrap_or(name).to_string()
}

pub struct Prefs {
    pub v: Value,
}

impl Prefs {
    pub fn read() -> Prefs {
        let v = std::fs::read_to_string(kit::theme::theme_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null);
        Prefs { v: if v.is_object() { v } else { json!({}) } }
    }

    pub fn raw(&self, name: &str) -> Value {
        let k = key(name);
        match self.v.get(&k) {
            Some(v) if !v.is_null() => v.clone(),
            _ => table().defaults.get(&k).cloned().unwrap_or(Value::Null),
        }
    }
    pub fn b(&self, name: &str) -> bool {
        match self.raw(name) {
            Value::Bool(b) => b,
            Value::Number(n) => n.as_f64().unwrap_or(0.0) != 0.0,
            Value::String(s) => s == "true",
            _ => false,
        }
    }
    pub fn f(&self, name: &str) -> f64 {
        match self.raw(name) {
            Value::Number(n) => n.as_f64().unwrap_or(0.0),
            Value::Bool(b) => b as i32 as f64,
            Value::String(s) => s.parse().unwrap_or(0.0),
            _ => 0.0,
        }
    }
    pub fn i(&self, name: &str) -> i64 {
        self.f(name).round() as i64
    }
    pub fn s(&self, name: &str) -> String {
        match self.raw(name) {
            Value::String(s) => s,
            Value::Null => String::new(),
            v => v.to_string(),
        }
    }

    /// One key changed, the rest of the file as it was (read again first,
    /// so a change made elsewhere meanwhile is kept).
    pub fn set(&mut self, name: &str, value: Value) -> std::io::Result<()> {
        let p = kit::theme::theme_path();
        let mut now = Prefs::read().v;
        now[key(name)] = value;
        if let Some(dir) = p.parent() {
            std::fs::create_dir_all(dir)?;
        }
        kit::write_atomic(&p, serde_json::to_string_pretty(&now).unwrap_or_default().as_bytes())?;
        self.v = now;
        Ok(())
    }

    // ── derived, as Appearance.qml works them out ───────────────────────
    pub fn dark(&self) -> bool {
        kit::theme::Palette::from_json(&self.v).dark
    }
    pub fn springy(&self) -> bool {
        self.s("motionStyle") != "smooth"
    }
    pub fn taskbar(&self) -> bool {
        self.s("dockStyle") == "taskbar"
    }
    pub fn dock_left(&self) -> bool {
        self.s("dockPosition") == "Left" && !self.taskbar()
    }
    pub fn pad_sensitivity_now(&self) -> f64 {
        let p = self.f("padSensitivity");
        if p < -1.0 {
            self.f("sensitivity")
        } else {
            p
        }
    }
    pub fn pad_accel_now(&self) -> String {
        let p = self.s("padAccelProfile");
        if p.is_empty() {
            self.s("accelProfile")
        } else {
            p
        }
    }
    pub fn follow_mouse_now(&self) -> i64 {
        if self.s("windowMode") == "windows" && self.i("followMouse") == 1 {
            2
        } else {
            self.i("followMouse")
        }
    }
    pub fn rf(&self) -> f64 {
        self.f("rounding") / 100.0
    }
    pub fn font_factor(&self) -> f64 {
        self.f("fontScale").clamp(75.0, 150.0) / 100.0
    }
    pub fn fs(&self, px: f64) -> i64 {
        (px * self.font_factor()).round() as i64
    }
    fn launcher_scaled(&self, px: f64) -> f64 {
        (px * self.f("launcherSize").max(40.0) / 100.0).round()
    }
    fn launcher_stretch(n: f64) -> f64 {
        n.clamp(50.0, 220.0) / 100.0
    }
    pub fn launcher_width(&self) -> i64 {
        (self.launcher_scaled(420.0) * Self::launcher_stretch(self.f("launcherWide"))).round() as i64
    }
    pub fn launcher_height(&self) -> i64 {
        (self.launcher_scaled(720.0) * Self::launcher_stretch(self.f("launcherTall"))).round() as i64
    }
    pub fn launcher_height_stretch(&self) -> f64 {
        Self::launcher_stretch(self.f("launcherTall"))
    }
    pub fn launcher_icon_size(&self) -> i64 {
        (self.launcher_scaled(22.0) * Self::launcher_stretch(self.f("launcherIconScale"))).round() as i64
    }
    pub fn launcher_columns(&self) -> i64 {
        ((3.0 * Self::launcher_stretch(self.f("launcherWide"))).round() as i64).clamp(3, 10)
    }

    /// The accent in use: a preset, the custom one, or the wallpaper's.
    pub fn accent(&self) -> [f64; 3] {
        let p = kit::theme::Palette::from_json(&self.v);
        let c = p.accent;
        [c.red() as f64 / 255.0, c.green() as f64 / 255.0, c.blue() as f64 / 255.0]
    }
    /// Appearance.div: the divider ink.
    pub fn div(&self) -> [f64; 3] {
        if self.dark() {
            [0.973, 0.957, 0.957]
        } else {
            [0.125, 0.118, 0.114]
        }
    }
    pub fn wall_accent_on(&self) -> bool {
        self.b("accentFromWallpaper") && !self.s("wallAccentLight").is_empty() && !self.s("wallAccentDark").is_empty()
    }
}

/// Appearance.shade: darker under 100 %, towards white over it.
pub fn shade(c: [f64; 3], pct: f64) -> [f64; 3] {
    let k = pct.max(0.0) / 100.0;
    if k <= 1.0 {
        return c.map(|x| x * k);
    }
    let t = (k - 1.0).min(1.0);
    c.map(|x| x + (1.0 - x) * t)
}

/// Appearance.hyprColor: "rgba(rrggbbaa)".
pub fn hypr_color(c: [f64; 3], alpha: &str) -> String {
    let h = |x: f64| format!("{:02x}", (x.clamp(0.0, 1.0) * 255.0).round() as u8);
    format!("rgba({}{}{}{})", h(c[0]), h(c[1]), h(c[2]), alpha)
}

pub fn hex(c: [f64; 3]) -> String {
    format!("#{:02X}{:02X}{:02X}", (c[0] * 255.0).round() as u8, (c[1] * 255.0).round() as u8, (c[2] * 255.0).round() as u8)
}

/// Appearance.qml's accentPresets: (light, dark).
pub const ACCENTS: &[(&str, &str)] = &[("#ec3013", "#ff563c"), ("#ae1800", "#e8452b"), ("#2d2b2b", "#d7d3d3"), ("#7c1405", "#c94b39")];
