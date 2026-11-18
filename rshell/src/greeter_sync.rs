//! Keeps the login screen dressed like the desktop (what the Quickshell
//! shell's GreeterSync.qml does).
//!
//! The greeter runs as greetd's own user, who cannot read your home folder,
//! so it cannot read your theme or see your screens as you set them. The
//! greeter's installer gives each person a folder it can read and they can
//! write, /var/lib/hyprshell-greeter/users/<you>; this keeps a copy of what
//! the greeter needs in it:
//!
//!   screens.json   each screen's mode, position and scale, as Hyprland has
//!                  them (so the login screen is the size the desktop is, not
//!                  at Hyprland's automatic scale)
//!   theme.json     your theme, with the picture it names copied beside it
//!                  and what is only yours (video folders) left out
//!   face           your picture
//!
//! Each is written only when it changed. With no folder (the greeter not
//! installed), it does nothing.

use crate::{hypr, theme};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub struct GreeterSync {
    dir: Option<PathBuf>,
    probed: Option<Instant>,
    done: Option<Instant>,
    written: HashMap<String, String>,
}

fn user() -> String {
    std::env::var("USER").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| {
        std::process::Command::new("id").arg("-un").output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
    })
}

fn writable(dir: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;
    dir.is_dir() && std::ffi::CString::new(dir.as_os_str().as_bytes()).is_ok_and(|c| unsafe { libc::access(c.as_ptr(), libc::W_OK) } == 0)
}

/// The screens as the greeter wants them: what Hyprland says of each, the
/// main one marked, and for a laptop panel the other name such a panel is
/// sometimes given (eDP-1 and eDP-2 swap between boots on some machines), so
/// the scale still finds it.
pub fn screens(monitors: &Value, main: &str) -> Value {
    let mut out: Vec<Value> = Vec::new();
    let list: Vec<&Value> = monitors.as_array().into_iter().flatten().collect();
    let main = if list.iter().any(|m| m["name"] == main) {
        main.to_string()
    } else {
        // Else the focused one, or the first.
        list.iter().find(|m| m["focused"] == true).or(list.first()).and_then(|m| m["name"].as_str()).unwrap_or("").to_string()
    };
    // Positions as the greeter's own layout, which starts at 0,0: a screen at
    // an offset because of one that is not there now stays where it is
    // relative to the others.
    let (ox, oy) = (
        list.iter().filter_map(|m| m["x"].as_f64()).fold(f64::INFINITY, f64::min),
        list.iter().filter_map(|m| m["y"].as_f64()).fold(f64::INFINITY, f64::min),
    );
    let (ox, oy) = (if ox.is_finite() { ox } else { 0.0 }, if oy.is_finite() { oy } else { 0.0 });
    for m in &list {
        let Some(name) = m["name"].as_str().filter(|n| !n.is_empty()) else { continue };
        let (Some(w), Some(h)) = (m["width"].as_f64(), m["height"].as_f64()) else { continue };
        let entry = |name: &str, real: bool| {
            json!({
                "name": name,
                "width": w, "height": h,
                "refreshRate": m["refreshRate"].as_f64().unwrap_or(60.0),
                "x": m["x"].as_f64().unwrap_or(0.0) - ox, "y": m["y"].as_f64().unwrap_or(0.0) - oy,
                "scale": m["scale"].as_f64().unwrap_or(1.0),
                "main": real && name == main,
            })
        };
        out.push(entry(name, true));
        if let Some(n) = name.strip_prefix("eDP-").and_then(|n| n.parse::<u8>().ok()) {
            let other = format!("eDP-{}", if n == 1 { 2 } else { 1 });
            if !list.iter().any(|x| x["name"] == other.as_str()) {
                out.push(entry(&other, false));
            }
        }
    }
    Value::Array(out)
}

/// theme.json as the greeter can use it: pictures it names are pointed at
/// the copies (`wallpaper`, the file the caller copies), and what is only
/// yours, or no use on a login screen, is left out.
pub fn greeter_theme(raw: &Value, wallpaper_copy: Option<&str>) -> Value {
    let mut t = raw.clone();
    let Some(o) = t.as_object_mut() else { return Value::Null };
    match wallpaper_copy {
        Some(p) => {
            o.insert("wallpaper".into(), json!(p));
        }
        None => {
            o.remove("wallpaper");
        }
    }
    // Videos are big and the greeter draws its own background without them.
    for k in ["liveWallpaper", "liveScreens", "liveFolders", "liveFiles", "liveLast"] {
        o.insert(k.into(), json!(""));
    }
    t
}

fn ext(p: &str) -> String {
    Path::new(p).extension().and_then(|e| e.to_str()).filter(|e| e.len() <= 5 && e.chars().all(|c| c.is_ascii_alphanumeric())).map(|e| format!(".{}", e.to_lowercase())).unwrap_or_default()
}

impl GreeterSync {
    pub fn new() -> Self {
        GreeterSync { dir: None, probed: None, done: None, written: HashMap::new() }
    }

    fn write(&mut self, name: &str, text: String) {
        let Some(dir) = &self.dir else { return };
        if self.written.get(name) == Some(&text) && dir.join(name).is_file() {
            return;
        }
        let tmp = dir.join(format!(".{name}.tmp"));
        if std::fs::write(&tmp, &text).is_ok() {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644));
            if std::fs::rename(&tmp, dir.join(name)).is_ok() {
                self.written.insert(name.to_string(), text);
            }
        }
    }

    /// A file copied beside the rest when it is new or has changed (size and time).
    fn copy(&self, from: &Path, to: &str, limit: u64) -> bool {
        let Some(dir) = &self.dir else { return false };
        let dest = dir.join(to);
        let (Ok(src), true) = (std::fs::metadata(from), from.is_file()) else { return false };
        if src.len() > limit {
            return false;
        }
        let fresh = std::fs::metadata(&dest).is_ok_and(|d| d.len() == src.len() && d.modified().ok() >= src.modified().ok());
        if !fresh {
            let tmp = dir.join(format!(".{to}.tmp"));
            if std::fs::copy(from, &tmp).is_err() {
                return false;
            }
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644));
            return std::fs::rename(&tmp, &dest).is_ok();
        }
        true
    }

    /// Called often; works every few seconds, and only on what changed.
    pub fn tick(&mut self) {
        if self.dir.is_none() {
            // Installed while the shell runs: noticed within a minute.
            if self.probed.is_some_and(|t| t.elapsed() < Duration::from_secs(60)) {
                return;
            }
            self.probed = Some(Instant::now());
            let d = PathBuf::from("/var/lib/hyprshell-greeter/users").join(user());
            if !writable(&d) {
                return;
            }
            self.dir = Some(d);
        }
        if self.done.is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
            return;
        }
        self.done = Some(Instant::now());
        let raw = theme::raw();
        let main = raw["mainDisplay"].as_str().unwrap_or("").to_string();
        let monitors = hypr::json("j/monitors");
        if monitors.as_array().is_some_and(|m| !m.is_empty()) {
            self.write("screens.json", serde_json::to_string_pretty(&screens(&monitors, &main)).unwrap_or_default());
        }
        if raw.is_object() {
            let copy = raw["wallpaper"].as_str().filter(|p| !p.is_empty()).and_then(|p| {
                let to = format!("wallpaper{}", ext(p));
                self.copy(Path::new(p), &to, 60 << 20).then(|| self.dir.as_ref().map(|d| d.join(&to).display().to_string())).flatten()
            });
            self.write("theme.json", serde_json::to_string_pretty(&greeter_theme(&raw, copy.as_deref())).unwrap_or_default());
        }
        if let Some(home) = std::env::var_os("HOME") {
            self.copy(&Path::new(&home).join(".face"), "face", 8 << 20);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screens_carry_the_scale_and_both_names_of_a_laptop_panel() {
        let m = json!([{ "name": "eDP-2", "width": 2880, "height": 1800, "refreshRate": 120.0, "x": 0, "y": 619, "scale": 1.6666666, "focused": true }]);
        let s = screens(&m, "");
        let l = s.as_array().unwrap();
        assert_eq!(l.len(), 2);
        assert_eq!((l[0]["name"].as_str(), l[0]["main"].as_bool()), (Some("eDP-2"), Some(true)));
        assert_eq!((l[1]["name"].as_str(), l[1]["main"].as_bool()), (Some("eDP-1"), Some(false)));
        assert_eq!(l[1]["scale"].as_f64(), Some(1.6666666));
        // Positions start at 0,0 whatever offset a screen has.
        assert_eq!((l[0]["x"].as_f64(), l[0]["y"].as_f64()), (Some(0.0), Some(0.0)));
        // A screen of that name that is really there is not doubled.
        let two = json!([{ "name": "eDP-1", "width": 1, "height": 1, "scale": 1 }, { "name": "eDP-2", "width": 1, "height": 1, "scale": 1 }]);
        assert_eq!(screens(&two, "eDP-2").as_array().unwrap().len(), 2);
    }

    #[test]
    fn the_greeters_theme_points_at_the_copy_and_drops_what_is_only_yours() {
        let raw = json!({ "accent": 3, "wallpaper": "/home/x/pic.png", "liveWallpaper": "/home/x/v.mp4", "liveFolders": "/home/x/vids" });
        let t = greeter_theme(&raw, Some("/var/lib/g/wallpaper.png"));
        assert_eq!(t["wallpaper"], "/var/lib/g/wallpaper.png");
        assert_eq!(t["liveWallpaper"], "");
        assert_eq!(t["liveFolders"], "");
        assert_eq!(t["accent"], 3);
        assert!(greeter_theme(&raw, None).get("wallpaper").is_none());
        assert_eq!(ext("/a/b/Pic.JPG"), ".jpg");
    }
}
