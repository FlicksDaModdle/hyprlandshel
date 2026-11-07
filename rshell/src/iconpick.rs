//! Every glyph the pack has, in the pack's order (IconPaths.names()), and
//! the ones drawn in the icon maker (icons.json), which glyphs::glyph falls
//! back to for a name the pack hasn't got.

use crate::GlyphData;
use serde_json::Value;

pub const NAMES: &[&str] = &[
    "terminal", "folder", "globe", "code", "stickyNote", "music", "settings", "monitor",
    "camera", "palette", "keyboard", "package", "mouse", "touchpad", "cpu", "download",
    "upload", "bluetooth", "image", "folderOpen", "file", "refresh", "trash", "drive",
    "calculator", "timer", "alarm", "pomodoro", "arrowTool", "highlighter", "crop", "focus",
    "clipboard", "star", "home", "film", "lock", "panelsTopLeft", "moon", "user",
    "grid", "layoutDashboard", "dock", "search", "bell", "bellOff", "power", "logOut",
    "rotateCw", "cornerDownLeft", "check", "x", "minus", "plus", "square", "chevronLeft",
    "chevronRight", "chevronDown", "chevronUp", "moreHorizontal", "wifi", "wifiOff", "plane", "gamepad",
    "shield", "volume", "volumeLow", "volumeX", "mic", "micOff", "headphones", "speaker",
    "play", "pause", "skipBack", "skipForward", "shuffle", "repeat", "repeatOne", "battery",
    "batteryCharging", "sun", "sunMoon", "zap", "info", "sliders", "eye", "list",
    "font", "cursor", "circle", "ellipse", "arc", "poly", "dot", "lasso",
    "pen", "chat", "mail", "calendar",
];

pub fn path() -> std::path::PathBuf {
    let cfg = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config"));
    cfg.join("quickshell/hyprshell/icons.json")
}

thread_local! {
    static CACHE: std::cell::RefCell<Option<(Option<std::time::SystemTime>, serde_json::Map<String, Value>)>> = const { std::cell::RefCell::new(None) };
}

/// The icons.json table: name → spec. Read again when the file changes.
pub fn user_icons() -> serde_json::Map<String, Value> {
    let stamp = std::fs::metadata(path()).and_then(|m| m.modified()).ok();
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        if c.as_ref().is_none_or(|(t, _)| *t != stamp) {
            let table = std::fs::read_to_string(path())
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
                .and_then(|v| v["icons"].as_object().cloned())
                .unwrap_or_default();
            *c = Some((stamp, table));
        }
        c.as_ref().map(|(_, t)| t.clone()).unwrap_or_default()
    })
}

/// A glyph drawn in the icon maker, by name; empty if there is none.
pub fn user_glyph(name: &str) -> GlyphData {
    let icons = user_icons();
    let s = |v: &Value, k: &str| v[k].as_str().unwrap_or("").to_string();
    let Some(v) = icons.get(name) else {
        return GlyphData { ink: "".into(), acc: "".into(), ink_w: "".into(), acc_w: "".into(), fill: "".into(), fill_ink: "".into(), dot_x: 12.0, dot_y: 12.0, dot_r: 2.0, dot_acc: false };
    };
    let d = v["dots"].as_array().and_then(|a| a.first()).cloned().unwrap_or(Value::Null);
    let f = |k: &str| d[k].as_f64().unwrap_or(0.0) as f32;
    GlyphData {
        ink: s(v, "ink").into(),
        acc: s(v, "acc").into(),
        ink_w: s(v, "inkW").into(),
        acc_w: s(v, "accW").into(),
        fill: s(v, "fill").into(),
        fill_ink: s(v, "fillInk").into(),
        dot_x: f("cx"),
        dot_y: f("cy"),
        dot_r: f("r"),
        dot_acc: d["c"] == "acc",
    }
}

/// Built-in first, then yours in the order they are in the file (the picker's list).
pub fn all_names() -> Vec<String> {
    let mut out: Vec<String> = NAMES.iter().map(|s| s.to_string()).collect();
    for n in user_icons().keys() {
        if !NAMES.contains(&n.as_str()) {
            out.push(n.clone());
        }
    }
    out
}
