//! The shell's palette, from `~/.config/quickshell/hyprshell/theme.json` —
//! the same file and the same rules as the Qt apps' Appearance.qml, so a
//! Rust app and a Qt one side by side are the same colours.

use slint::Color;
use std::cell::RefCell;
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

#[derive(Clone, Debug)]
pub struct Palette {
    pub dark: bool,
    pub accent: Color,
    pub ink_on_accent: Color,
    pub ground: Color,
    pub surface: Color,
    pub ink: Color,
    pub ink2: Color,
    pub ink3: Color,
    pub edge: Color,
    pub rule: Color,
    pub hover: Color,
    pub sel: Color,
    pub sheet: Color,
    pub dialog: Color,
    pub danger: Color,
    pub ok: Color,
    pub warn: Color,
    pub r: f32,
    pub r_sm: f32,
    pub font_factor: f32,
    pub font_family: String,
    pub speed: f32,
    pub bounce: f32,
}

pub fn theme_path() -> PathBuf {
    crate::config_dir().join("quickshell/hyprshell/theme.json")
}

fn hex(s: &str) -> Option<Color> {
    let s = s.trim().strip_prefix('#')?;
    let v = u32::from_str_radix(s, 16).ok()?;
    Some(match s.len() {
        3 => {
            let (r, g, b) = ((v >> 8) & 0xf, (v >> 4) & 0xf, v & 0xf);
            Color::from_rgb_u8((r * 17) as u8, (g * 17) as u8, (b * 17) as u8)
        }
        6 => Color::from_rgb_u8((v >> 16) as u8, (v >> 8) as u8, v as u8),
        8 => Color::from_argb_u8(v as u8, (v >> 24) as u8, (v >> 16) as u8, (v >> 8) as u8),
        _ => return None,
    })
}

fn rgba(r: f32, g: f32, b: f32, a: f32) -> Color {
    Color::from_argb_f32(a, r, g, b)
}

impl Palette {
    pub fn from_json(v: &serde_json::Value) -> Palette {
        let mode = v.get("theme").and_then(|m| m.as_str()).unwrap_or("dark");
        let dark = match mode {
            "light" => false,
            "dark" => true,
            // "auto": dark from 19:00 to 07:00, the shell's own rule.
            _ => {
                let h = local_hour();
                !(7..19).contains(&h)
            }
        };
        const PRESETS: [(&str, &str); 4] =
            [("#ec3013", "#ff563c"), ("#ae1800", "#e8452b"), ("#2d2b2b", "#d7d3d3"), ("#7c1405", "#c94b39")];
        let accent = match v.get("accent").and_then(|a| a.as_i64()) {
            Some(-1) => v.get("customAccent").and_then(|c| c.as_str()).and_then(hex).unwrap_or(hex("#ec3013").unwrap()),
            idx => {
                let n = idx.unwrap_or(0).clamp(0, PRESETS.len() as i64 - 1) as usize;
                hex(if dark { PRESETS[n].1 } else { PRESETS[n].0 }).unwrap()
            }
        };
        let lum = 0.2126 * accent.red() as f32 / 255.0 + 0.7152 * accent.green() as f32 / 255.0 + 0.0722 * accent.blue() as f32 / 255.0;
        let num = |k: &str, d: f64| v.get(k).and_then(|x| x.as_f64()).unwrap_or(d);
        let translucency = num("translucency", 50.0).clamp(0.0, 100.0) as f32 / 100.0;
        let sheet_alpha = 1.0 - translucency * if dark { 0.24 } else { 0.20 };
        let rounding = num("rounding", 100.0) as f32 / 100.0;
        let font_scale = num("fontScale", 100.0).clamp(75.0, 150.0) as f32 / 100.0;
        let anim = num("animSpeed", 100.0).max(0.0) as f32 / 100.0;
        let springy = v.get("motionStyle").and_then(|m| m.as_str()).unwrap_or("springy") != "smooth";
        let bounce = if springy { (num("motionBounce", 100.0) as f32 / 100.0 * 0.2).clamp(0.0, 0.5) } else { 0.0 };
        let (ink, ink_r, ink_g, ink_b) = if dark { ("#f8f4f4", 0.973, 0.957, 0.957) } else { ("#201e1d", 0.125, 0.118, 0.114) };
        Palette {
            dark,
            accent,
            ink_on_accent: if lum > 0.6 { hex("#201e1d").unwrap() } else { Color::from_rgb_u8(255, 255, 255) },
            ground: hex(if dark { "#201e1d" } else { "#f3f2f2" }).unwrap(),
            surface: hex(if dark { "#2d2b2b" } else { "#eae9e9" }).unwrap(),
            ink: hex(ink).unwrap(),
            ink2: hex(if dark { "#bab6b6" } else { "#605d5d" }).unwrap(),
            ink3: hex(if dark { "#8a8686" } else { "#6b6868" }).unwrap(),
            edge: rgba(ink_r, ink_g, ink_b, if dark { 0.16 } else { 0.14 }),
            rule: rgba(ink_r, ink_g, ink_b, if dark { 0.10 } else { 0.09 }),
            hover: rgba(ink_r, ink_g, ink_b, if dark { 0.09 } else { 0.07 }),
            sel: rgba(ink_r, ink_g, ink_b, if dark { 0.14 } else { 0.10 }),
            sheet: if dark { rgba(0.137, 0.129, 0.125, sheet_alpha) } else { rgba(0.980, 0.976, 0.976, sheet_alpha) },
            dialog: hex(if dark { "#252322" } else { "#faf9f9" }).unwrap(),
            danger: hex(if dark { "#ff6b61" } else { "#d42c1f" }).unwrap(),
            ok: hex(if dark { "#4cc38a" } else { "#1f8a57" }).unwrap(),
            warn: hex(if dark { "#f0b429" } else { "#a86b00" }).unwrap(),
            r: (14.0 * rounding).round(),
            r_sm: (9.0 * rounding).round(),
            font_factor: font_scale,
            font_family: "Inter".into(),
            speed: anim,
            bounce,
        }
    }

    pub fn load() -> Palette {
        let v = std::fs::read_to_string(theme_path())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or(serde_json::Value::Null);
        Palette::from_json(&v)
    }
}

fn local_hour() -> u32 {
    // Local time without a date crate: localtime_r through libc's symbol.
    #[repr(C)]
    struct Tm {
        sec: i32, min: i32, hour: i32, mday: i32, mon: i32, year: i32, wday: i32, yday: i32, isdst: i32,
        gmtoff: i64, zone: *const i8,
    }
    extern "C" {
        fn localtime_r(t: *const i64, out: *mut Tm) -> *mut Tm;
    }
    let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let mut tm: Tm = unsafe { std::mem::zeroed() };
    unsafe { localtime_r(&now, &mut tm) };
    tm.hour.clamp(0, 23) as u32
}

thread_local! {
    static FOLLOW: RefCell<Option<slint::Timer>> = const { RefCell::new(None) };
}

/// Apply the palette now, and again whenever the theme file changes (or
/// the hour turns, for "auto"). A stat every second and a half: cheaper than
/// it sounds, and no watcher thread.
pub fn follow(apply: impl Fn(&Palette) + 'static) {
    apply(&Palette::load());
    let stamp = |_: ()| {
        let m = std::fs::metadata(theme_path()).and_then(|m| m.modified()).ok();
        (m, local_hour())
    };
    let last = RefCell::new(stamp(()));
    let timer = slint::Timer::default();
    timer.start(slint::TimerMode::Repeated, Duration::from_millis(1500), move || {
        let now = stamp(());
        if now != *last.borrow() {
            *last.borrow_mut() = now;
            apply(&Palette::load());
        }
    });
    FOLLOW.with(|f| *f.borrow_mut() = Some(timer));
}
