//! What the machine says, for About and Power (services/SysInfo.qml and
//! friends): read when a pane is shown, never polled in the background.

use std::process::{Command, Stdio};

fn first_line(path: &str) -> String {
    std::fs::read_to_string(path).map(|s| s.trim().to_string()).unwrap_or_default()
}

pub fn run(cmd: &str, args: &[&str]) -> Option<String> {
    let o = Command::new(cmd).args(args).stderr(Stdio::null()).output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

pub fn have(cmd: &str) -> bool {
    std::env::var_os("PATH").map(|p| std::env::split_paths(&p).any(|d| d.join(cmd).is_file())).unwrap_or(false)
}

pub struct Info {
    pub distro: String,
    pub host: String,
    pub cpu_model: String,
    pub cpu_label: String,
    pub mem_ratio: f64,
    pub mem_label: String,
    pub disk_ratio: f64,
    pub disk_label: String,
    pub kernel: String,
    pub hyprland: String,
    pub uptime: String,
    pub keymap: String,
}

fn gib(kb: f64) -> String {
    format!("{:.1} GB", kb / 1024.0 / 1024.0)
}

pub fn info() -> Info {
    let distro = std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|s| s.lines().find_map(|l| l.strip_prefix("PRETTY_NAME=").map(|v| v.trim_matches('"').to_string())))
        .unwrap_or_else(|| "Linux".into());
    let host = {
        let product = first_line("/sys/class/dmi/id/product_name");
        let vendor = first_line("/sys/class/dmi/id/sys_vendor");
        if product.is_empty() {
            first_line("/proc/sys/kernel/hostname")
        } else if vendor.is_empty() {
            product
        } else {
            format!("{vendor} {product}")
        }
    };
    let cpuinfo = std::fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let cpu_model = cpuinfo.lines().find(|l| l.starts_with("model name")).and_then(|l| l.split_once(':')).map(|(_, v)| v.trim().to_string()).unwrap_or_default();
    let threads = cpuinfo.lines().filter(|l| l.starts_with("processor")).count();
    let mem = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let kb = |k: &str| mem.lines().find(|l| l.starts_with(k)).and_then(|l| l.split_whitespace().nth(1)).and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0);
    let (total, avail) = (kb("MemTotal:"), kb("MemAvailable:"));
    let used = (total - avail).max(0.0);
    let (disk_ratio, disk_label) = run("df", &["-k", "--output=size,used", "/"])
        .and_then(|o| {
            let l = o.lines().nth(1)?.split_whitespace().map(|v| v.parse::<f64>().ok()).collect::<Option<Vec<_>>>()?;
            Some((l[1] / l[0].max(1.0), format!("{} of {} used", gib(l[1]), gib(l[0]))))
        })
        .unwrap_or((0.0, String::new()));
    let up = first_line("/proc/uptime").split_whitespace().next().and_then(|v| v.parse::<f64>().ok()).unwrap_or(0.0) as u64;
    let uptime = if up >= 86400 {
        format!("{} d {} h", up / 86400, up % 86400 / 3600)
    } else {
        format!("{} h {} min", up / 3600, up % 3600 / 60)
    };
    let hyprland = super::hypr::json("version")["tag"].as_str().unwrap_or("").trim_start_matches('v').to_string();
    let keymap = super::hypr::json("devices")["keyboards"]
        .as_array()
        .and_then(|k| k.iter().find(|k| k["main"] == true).or(k.first()).and_then(|k| k["active_keymap"].as_str().map(str::to_string)))
        .unwrap_or_default();
    Info {
        distro,
        host,
        cpu_model,
        cpu_label: if threads > 0 { format!("{threads} threads") } else { String::new() },
        mem_ratio: if total > 0.0 { used / total } else { 0.0 },
        mem_label: format!("{} of {} in use", gib(used), gib(total)),
        disk_ratio,
        disk_label,
        kernel: first_line("/proc/sys/kernel/osrelease"),
        hyprland,
        uptime,
        keymap,
    }
}

pub struct Battery {
    pub percent: f64,
    pub state: String,
    pub health: Option<f64>,
}

pub fn battery() -> Option<Battery> {
    let dir = std::fs::read_dir("/sys/class/power_supply").ok()?.flatten().map(|e| e.path()).find(|p| {
        std::fs::read_to_string(p.join("type")).map(|t| t.trim() == "Battery").unwrap_or(false)
            && std::fs::read_to_string(p.join("scope")).map(|s| s.trim() != "Device").unwrap_or(true)
    })?;
    let r = |f: &str| std::fs::read_to_string(dir.join(f)).ok().map(|s| s.trim().to_string());
    let n = |f: &str| r(f).and_then(|s| s.parse::<f64>().ok());
    let percent = n("capacity").unwrap_or(0.0) / 100.0;
    let health = match (n("energy_full"), n("energy_full_design")) {
        (Some(a), Some(b)) if b > 0.0 => Some(a / b * 100.0),
        _ => match (n("charge_full"), n("charge_full_design")) {
            (Some(a), Some(b)) if b > 0.0 => Some(a / b * 100.0),
            _ => None,
        },
    };
    Some(Battery { percent, state: r("status").unwrap_or_default(), health })
}

/// brightnessctl's backlight: (device, 0..1).
pub fn brightness() -> Option<(String, f64)> {
    let o = run("brightnessctl", &["-m", "-c", "backlight"])?;
    let f: Vec<&str> = o.lines().next()?.split(',').collect();
    let pct = f.get(3)?.trim_end_matches('%').parse::<f64>().ok()?;
    Some((f.first()?.to_string(), pct / 100.0))
}
pub fn set_brightness(v: f64) {
    let _ = Command::new("brightnessctl").args(["-c", "backlight", "set", &format!("{}%", (v * 100.0).round().max(1.0))]).stdout(Stdio::null()).status();
}

pub fn power_profile() -> Option<String> {
    run("powerprofilesctl", &["get"])
}
pub fn power_profiles() -> Vec<String> {
    run("powerprofilesctl", &["list"])
        .map(|o| o.lines().filter_map(|l| l.trim().trim_start_matches('*').trim().strip_suffix(':').map(str::to_string)).collect())
        .unwrap_or_default()
}
pub fn set_power_profile(name: &str) {
    let _ = Command::new("powerprofilesctl").args(["set", name]).status();
}
