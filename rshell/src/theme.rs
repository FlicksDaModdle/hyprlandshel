//! The shell's look, from the same theme.json the Quickshell shell keeps
//! ($XDG_CONFIG_HOME/quickshell/hyprshell/theme.json), worked out the way
//! config/Appearance.qml does: light, dark or by the hour; the accent
//! preset, a custom one or the wallpaper's; translucency, rounding, the
//! text size and the bar's own sizes. Read again whenever the file changes,
//! so changing them in Settings changes this bar too.

use serde_json::Value;
use std::path::PathBuf;
use std::time::SystemTime;

#[derive(Clone, Copy, PartialEq)]
pub struct Rgba(pub u8, pub u8, pub u8, pub f32);

impl Rgba {
    pub fn slint(self) -> slint::Color {
        slint::Color::from_argb_u8((self.3 * 255.0).round() as u8, self.0, self.1, self.2)
    }
}

fn hex(s: &str) -> Option<Rgba> {
    let h = s.trim().trim_start_matches('#');
    if h.len() < 6 {
        return None;
    }
    let p = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok();
    Some(Rgba(p(0)?, p(2)?, p(4)?, 1.0))
}

const PRESETS: [(&str, &str); 4] =
    [("#ec3013", "#ff563c"), ("#ae1800", "#e8452b"), ("#2d2b2b", "#d7d3d3"), ("#7c1405", "#c94b39")];

#[derive(Clone)]
pub struct Theme {
    pub dark: bool,
    /// "light", "dark" or "auto", as Settings has it.
    pub mode: String,
    pub dnd: bool,
    pub show_tray: bool,
    pub tray_open: bool,
    pub updates_in_bar: bool,
    pub mail_in_bar: bool,
    pub seam: Rgba,
    pub motion: crate::spring::Motion,
    /// Panels grow out of their button (Settings → Motion).
    pub panels_grow: bool,
    pub accent: Rgba,
    pub ink_on_accent: Rgba,
    pub ink: Rgba,
    pub ink2: Rgba,
    pub ink3: Rgba,
    pub edge: Rgba,
    pub rule: Rgba,
    pub div: Rgba,
    pub hover: Rgba,
    pub sel: Rgba,
    pub panel: Rgba,
    pub r: f32,
    pub r_sm: f32,
    pub font_factor: f32,
    pub bar_height: f32,
    pub bar_font: f32,
    pub bar_title: f32,
    pub bar_app: f32,
    pub bar_menu: f32,
    pub bar_clock: f32,
    pub bar_badge: f32,
    pub bar_icon: f32,
    pub workspace_scale: f32,
    pub clock24: bool,
    /// The bar's auto-hide, how long the pointer rests on the edge before it
    /// comes out (ms), and the dock's.
    pub bar_auto_hide: bool,
    pub bar_reveal_delay: u64,
    pub dock_auto_hide: bool,
    /// Screen corners: on, their radius, every screen or the built-in one,
    /// over fullscreen windows too, and which (TL, TR, BR, BL).
    pub corners: bool,
    pub corner_radius: u32,
    pub corners_all: bool,
    pub corners_fullscreen: bool,
    pub corner_on: [bool; 4],
    pub badges: bool,
    screen_scales: Vec<(String, f32)>,
}

impl Theme {
    /// The per-monitor shell scale (Settings → Display → Shell scale).
    pub fn screen_scale(&self, monitor: &str) -> f32 {
        self.screen_scales.iter().find(|(n, _)| n == monitor).map(|(_, s)| *s).unwrap_or(1.0)
    }
}

thread_local! {
    /// The greeter's: the theme of the person picked, in their greeter
    /// folder, in place of the usual one.
    static OVERRIDE: std::cell::RefCell<Option<PathBuf>> = const { std::cell::RefCell::new(None) };
}

/// Reads the theme from `p` from now on (None: the usual place again).
pub fn set_path(p: Option<PathBuf>) {
    OVERRIDE.with(|o| *o.borrow_mut() = p);
}

pub fn path() -> PathBuf {
    if let Some(p) = OVERRIDE.with(|o| o.borrow().clone()) {
        return p;
    }
    let cfg = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config"));
    cfg.join("quickshell/hyprshell/theme.json")
}

/// Watches theme.json (its folder: Settings replaces the file whole, by
/// renaming a new one over it) and wakes the loop the moment it changes,
/// rather than at the next once-a-second look. The flag says it did.
pub fn watch(wake: &std::os::unix::net::UnixStream) -> std::sync::Arc<std::sync::atomic::AtomicBool> {
    use std::sync::atomic::{AtomicBool, Ordering};
    let flag = std::sync::Arc::new(AtomicBool::new(false));
    let Some(dir) = path().parent().map(|d| d.to_path_buf()) else { return flag };
    let _ = std::fs::create_dir_all(&dir);
    let Ok(mut wake) = wake.try_clone() else { return flag };
    let f = flag.clone();
    std::thread::spawn(move || {
        let Ok(cdir) = std::ffi::CString::new(dir.as_os_str().as_encoded_bytes()) else { return };
        // SAFETY: inotify on our own descriptor, read into our own buffer.
        let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
        if fd < 0 {
            return;
        }
        let mask = libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO | libc::IN_CREATE;
        if unsafe { libc::inotify_add_watch(fd, cdir.as_ptr(), mask) } < 0 {
            return;
        }
        let mut buf = [0u8; 4096];
        loop {
            let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if n <= 0 {
                return;
            }
            // Each event: its header, then the name it's about.
            let mut at = 0usize;
            let mut ours = false;
            while at + std::mem::size_of::<libc::inotify_event>() <= n as usize {
                let ev = unsafe { &*(buf.as_ptr().add(at) as *const libc::inotify_event) };
                let start = at + std::mem::size_of::<libc::inotify_event>();
                let name = &buf[start..start + ev.len as usize];
                let name = name.split(|b| *b == 0).next().unwrap_or(&[]);
                ours |= name == b"theme.json";
                at = start + ev.len as usize;
            }
            if ours {
                f.store(true, Ordering::SeqCst);
                let _ = std::io::Write::write_all(&mut wake, b"!");
            }
        }
    });
    flag
}

pub fn modified() -> Option<SystemTime> {
    std::fs::metadata(path()).and_then(|m| m.modified()).ok()
}

fn hour() -> i32 {
    // SAFETY: localtime_r fills the tm it is given.
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm.tm_hour
    }
}

pub fn load() -> Theme {
    let v: Value = std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null);
    let num = |k: &str, d: f64| v[k].as_f64().unwrap_or(d);
    let flag = |k: &str, d: bool| v[k].as_bool().unwrap_or(d);
    let text = |k: &str| v[k].as_str().unwrap_or("").to_string();

    let mode = v["theme"].as_str().unwrap_or("light");
    let dark = match mode {
        "dark" => true,
        "auto" => {
            let h = hour();
            h >= 19 || h < 7
        }
        _ => false,
    };

    let accent = if flag("accentFromWallpaper", false) && !text("wallAccentLight").is_empty() && !text("wallAccentDark").is_empty() {
        hex(&text(if dark { "wallAccentDark" } else { "wallAccentLight" }))
    } else if num("accent", 0.0) as i64 == -1 {
        hex(&text("customAccent"))
    } else {
        let i = (num("accent", 0.0) as i64).clamp(0, PRESETS.len() as i64 - 1) as usize;
        hex(if dark { PRESETS[i].1 } else { PRESETS[i].0 })
    }
    .unwrap_or(Rgba(0xec, 0x30, 0x13, 1.0));
    let lum = (0.299 * accent.0 as f32 + 0.587 * accent.1 as f32 + 0.114 * accent.2 as f32) / 255.0;
    let ink_on_accent = if lum > 0.62 { Rgba(0x20, 0x1e, 0x1d, 1.0) } else { Rgba(0xff, 0xf8, 0xf6, 1.0) };

    // Translucent ink, as Qt.rgba(ink, a) in Appearance.qml.
    let (ir, ig, ib) = if dark { (248, 244, 244) } else { (32, 30, 29) };
    let ink_a = |d: f32, l: f32| Rgba(ir, ig, ib, if dark { d } else { l });
    let t = (num("translucency", 50.0).clamp(0.0, 100.0) / 100.0) as f32;
    let alpha = 1.0 - t * if dark { 0.56 } else { 0.44 };
    let panel = if dark { Rgba(29, 27, 26, alpha) } else { Rgba(248, 247, 247, alpha) };

    let rf = (num("rounding", 100.0) / 100.0) as f32;
    let screen_scales = text("screenScales")
        .lines()
        .filter_map(|l| {
            let (n, s) = l.split_once('=')?;
            let s: f32 = s.trim().parse().ok()?;
            Some((n.trim().to_string(), s.clamp(40.0, 200.0) / 100.0))
        })
        .collect();

    Theme {
        dark,
        mode: mode.to_string(),
        dnd: flag("dnd", false),
        show_tray: flag("showTray", true),
        tray_open: flag("trayOpen", false),
        updates_in_bar: flag("updatesInBar", true),
        mail_in_bar: flag("mailInBar", true),
        motion: crate::spring::Motion {
            springy: v["motionStyle"].as_str().unwrap_or("springy") != "smooth",
            bounce: num("motionBounce", 100.0).clamp(0.0, 200.0),
            speed: num("animSpeed", 100.0).clamp(0.0, 250.0),
        },
        panels_grow: flag("panelsGrow", true),
        seam: Rgba(accent.0, accent.1, accent.2, if dark { 0.24 } else { 0.18 }),
        accent,
        ink_on_accent,
        ink: if dark { Rgba(0xf8, 0xf4, 0xf4, 1.0) } else { Rgba(0x20, 0x1e, 0x1d, 1.0) },
        ink2: if dark { Rgba(0xba, 0xb6, 0xb6, 1.0) } else { Rgba(0x60, 0x5d, 0x5d, 1.0) },
        ink3: if dark { Rgba(0x8a, 0x86, 0x86, 1.0) } else { Rgba(0x6b, 0x68, 0x68, 1.0) },
        edge: ink_a(0.16, 0.14),
        rule: ink_a(0.10, 0.09),
        div: ink_a(0.22, 0.18),
        hover: ink_a(0.09, 0.07),
        sel: ink_a(0.14, 0.10),
        panel,
        r: (14.0 * rf).round(),
        r_sm: (9.0 * rf).round(),
        font_factor: (num("fontScale", 100.0).clamp(75.0, 150.0) / 100.0) as f32,
        bar_height: num("barHeight", 40.0) as f32,
        bar_font: num("barFontSize", 12.0) as f32,
        bar_title: num("barTitleSize", 12.0) as f32,
        bar_app: num("barAppSize", 16.0) as f32,
        bar_menu: num("barMenuSize", 13.0) as f32,
        bar_clock: num("barClockSize", 13.0) as f32,
        bar_badge: num("barBadgeSize", 11.0) as f32,
        bar_icon: (16.0 * num("barIcon", 100.0) as f32 / 100.0).round().max(8.0),
        workspace_scale: (num("workspaceScale", 100.0).clamp(60.0, 160.0) / 100.0) as f32,
        clock24: flag("clock24", true),
        bar_auto_hide: flag("barHide", false),
        bar_reveal_delay: num("barRevealDelay", 350.0).max(0.0) as u64,
        dock_auto_hide: flag("dockHide", false),
        corners: flag("screenCorners", false),
        corner_radius: num("screenCornerRadius", 14.0).clamp(0.0, 256.0) as u32,
        corners_all: text("screenCornerScreens") == "all",
        corners_fullscreen: flag("screenCornersFullscreen", true),
        corner_on: [flag("screenCornerTL", true), flag("screenCornerTR", true), flag("screenCornerBR", true), flag("screenCornerBL", true)],
        badges: flag("badges", true),
        screen_scales,
    }
}

/// Changes one setting in theme.json, keeping the rest as they are: what
/// the theme chip, the bell's right click and the tray's chevron write.
pub fn set(key: &str, value: Value) {
    let p = path();
    let mut v: Value = std::fs::read_to_string(&p).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null);
    if !v.is_object() {
        v = Value::Object(Default::default());
    }
    v[key] = value;
    if let Ok(text) = serde_json::to_string_pretty(&v) {
        // Written beside it and moved into place, so the Quickshell shell
        // (or Settings) never reads half a file.
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = p.with_extension("json.rshell");
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }
}

/// theme.json as it is, for settings this shell passes on without using.
pub fn raw() -> Value {
    std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null)
}
