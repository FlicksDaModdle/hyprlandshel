//! What the bar reads from the system directly: the battery and the
//! network, from /sys, without a process or a D-Bus round trip.

use std::fs;

pub struct Battery {
    pub percent: i32,
    pub charging: bool,
}

pub fn battery() -> Option<Battery> {
    for e in fs::read_dir("/sys/class/power_supply").ok()?.flatten() {
        let p = e.path();
        if fs::read_to_string(p.join("type")).ok()?.trim() != "Battery" {
            continue;
        }
        let percent = fs::read_to_string(p.join("capacity")).ok()?.trim().parse().ok()?;
        let status = fs::read_to_string(p.join("status")).unwrap_or_default();
        let charging = matches!(status.trim(), "Charging" | "Full");
        return Some(Battery { percent, charging });
    }
    None
}

/// "wifi", "ethernet" or "offline": the first interface that is up.
pub fn network() -> &'static str {
    let Ok(dir) = fs::read_dir("/sys/class/net") else { return "offline" };
    let mut wired = false;
    for e in dir.flatten() {
        let p = e.path();
        if e.file_name() == "lo" || fs::read_to_string(p.join("operstate")).unwrap_or_default().trim() != "up" {
            continue;
        }
        if p.join("wireless").exists() {
            return "wifi";
        }
        wired = true;
    }
    if wired { "ethernet" } else { "offline" }
}
