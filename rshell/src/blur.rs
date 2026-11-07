//! The compositor's blur for the shell's own surfaces (Devices.qml's
//! applyShellBlur). Hyprland blurs a layer surface by namespace, and a rule is
//! read when a surface maps. `xray` blurs the wallpaper, which Hyprland blurs
//! once and keeps; without it a surface blurs whatever is behind it, again
//! whenever that changes.
//!
//! In auto the bar and dock (thin strips, cheap) always blur what is behind
//! them, and the menus blur live only while there are windows on the screen
//! they open on: xray there would show the wallpaper through a menu instead
//! of the window under it, which is what made translucent panels look wrong.

use crate::hypr;
use std::time::{Duration, Instant};

pub struct Blur {
    sent: String,
    at: Option<Instant>,
}

/// Are there windows on the focused monitor's visible workspace?
fn windows_under_menus() -> bool {
    let monitors = hypr::json("j/monitors");
    let Some(mon) = monitors.as_array().and_then(|m| m.iter().find(|m| m["focused"] == true).or(m.first())) else { return false };
    let (id, ws) = (mon["id"].as_i64(), mon["activeWorkspace"]["id"].as_i64());
    hypr::json("j/clients")
        .as_array()
        .is_some_and(|cs| cs.iter().any(|c| c["mapped"] != false && c["hidden"] != true && c["monitor"].as_i64() == id && c["workspace"]["id"].as_i64() == ws))
}

/// The rules for a mode ("auto", "live" or "wallpaper"), as Lua.
fn rules(mode: &str, windows: bool) -> String {
    let mut lua = String::new();
    for n in ["bar", "dock", "panel", "launcher", "overview"] {
        let live = match mode {
            "live" => true,
            "wallpaper" => false,
            _ => n == "bar" || n == "dock" || windows,
        };
        lua += &format!(
            "hl.layer_rule({{ name = \"blur-quickshell-{n}\", match = {{ namespace = \"^quickshell:{n}$\" }}, blur = true, ignore_alpha = 0.15, xray = {} }}) ",
            !live
        );
    }
    // The password prompt's card: blurred behind it only; the dimming round
    // it is drawn under this cut-off.
    lua += "hl.layer_rule({ name = \"blur-quickshell-polkit\", match = { namespace = \"^quickshell:polkit$\" }, blur = true, ignore_alpha = 0.38 }) ";
    lua
}

impl Blur {
    pub fn new() -> Self {
        Blur { sent: String::new(), at: None }
    }

    /// Forget what was sent: something else (Settings) may have changed the rules.
    pub fn stale(&mut self) {
        self.sent.clear();
    }

    /// Sends the rules if they differ from the last ones, or have not been
    /// sent for a while (another program may have set its own meanwhile).
    pub fn sync(&mut self, mode: &str) {
        if hypr::ask("j/monitors").is_none() {
            return;
        }
        let lua = rules(if ["live", "wallpaper"].contains(&mode) { mode } else { "auto" }, windows_under_menus());
        let old = self.at.is_some_and(|t| t.elapsed() > Duration::from_secs(20));
        if lua == self.sent && !old {
            return;
        }
        self.sent = lua.clone();
        self.at = Some(Instant::now());
        // Off the loop: hyprctl is a process.
        std::thread::spawn(move || {
            let _ = std::process::Command::new("hyprctl")
                .args(["eval", &lua])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn menus_blur_live_only_with_windows_under_them() {
        assert!(rules("auto", false).contains("quickshell:panel$\" }, blur = true, ignore_alpha = 0.15, xray = true"));
        assert!(rules("auto", true).contains("quickshell:panel$\" }, blur = true, ignore_alpha = 0.15, xray = false"));
        // The bar and dock are always live in auto.
        assert!(rules("auto", false).contains("quickshell:bar$\" }, blur = true, ignore_alpha = 0.15, xray = false"));
        assert!(rules("wallpaper", true).contains("quickshell:bar$\" }, blur = true, ignore_alpha = 0.15, xray = true"));
        assert!(rules("live", false).contains("quickshell:launcher$\" }, blur = true, ignore_alpha = 0.15, xray = false"));
    }
}
