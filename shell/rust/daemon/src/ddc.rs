//! External monitors' brightness, over DDC/CI — the monitor's own
//! backlight, set through the display cable the way its on-screen menu
//! sets it. In place of ddcutil, and pure Rust: the i2c-dev interface,
//! one ioctl and plain reads and writes.
//!
//! Only two addresses are ever spoken to — 0x37 (DDC/CI) and 0x50 (the
//! EDID, read to tell which bus is which monitor) — and only on buses that
//! belong to a graphics card, never the motherboard's SMBus (memory
//! modules, sensors).
//!
//! A monitor that does not answer (some don't, and many docks and hubs do
//! not pass DDC through) is reported with method "software": the shell
//! dims it through the gamma ramp instead (gamma-dim).
//!
//! Commands:  ddc-refresh             look for monitors again
//!            ddc-set {output, value} 0..100
//! Events:    ddc {displays: [{output, name, method: "ddc"|"software",
//!                             value, max}], reason?}
//!
//! /dev/i2c-* needs the i2c-dev module and read-write access for the
//! session's user (install.sh sets up both); without them every external
//! monitor comes back as "software", with reason "setup".

use crate::out;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::path::Path;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

const I2C_SLAVE: libc::c_ulong = 0x0703;
const DDC_ADDR: u16 = 0x37;
const EDID_ADDR: u16 = 0x50;
const VCP_BRIGHTNESS: u8 = 0x10;

fn sysroot() -> String {
    std::env::var("HYPRSHELL_SYSROOT").unwrap_or_default()
}

// ── the wire ────────────────────────────────────────────────────────────

struct Bus {
    file: File,
    /// When the monitor last heard from us: DDC/CI wants a rest between
    /// messages, or it drops them.
    last: Instant,
}

impl Bus {
    fn open(n: u32) -> std::io::Result<Bus> {
        let file = OpenOptions::new().read(true).write(true).open(format!("/dev/i2c-{n}"))?;
        Ok(Bus { file, last: Instant::now() - Duration::from_secs(1) })
    }

    fn talk_to(&self, addr: u16) -> std::io::Result<()> {
        let r = unsafe { libc::ioctl(self.file.as_raw_fd(), I2C_SLAVE, addr as libc::c_ulong) };
        if r < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
    }

    fn rest(&mut self, ms: u64) {
        let gap = Duration::from_millis(ms);
        let since = self.last.elapsed();
        if since < gap {
            std::thread::sleep(gap - since);
        }
    }

    /// The first 128 bytes of the monitor's EDID.
    fn edid(&mut self) -> Option<Vec<u8>> {
        self.talk_to(EDID_ADDR).ok()?;
        self.file.write_all(&[0]).ok()?;
        let mut b = vec![0u8; 128];
        self.file.read_exact(&mut b).ok()?;
        (b[0..8] == [0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0]).then_some(b)
    }

    /// One DDC/CI message: source address 0x51, length, the body, and a
    /// checksum seeded with the destination address (0x6e).
    fn send(&mut self, body: &[u8]) -> std::io::Result<()> {
        self.rest(50);
        self.talk_to(DDC_ADDR)?;
        let mut msg = vec![0x51, 0x80 | body.len() as u8];
        msg.extend_from_slice(body);
        let chk = msg.iter().fold(0x6eu8, |a, b| a ^ b);
        msg.push(chk);
        let r = self.file.write_all(&msg);
        self.last = Instant::now();
        r
    }

    /// Get VCP feature: (current, maximum).
    fn get(&mut self, code: u8) -> Option<(u16, u16)> {
        for _ in 0..3 {
            if self.send(&[0x01, code]).is_err() {
                continue;
            }
            std::thread::sleep(Duration::from_millis(45));
            let mut r = [0u8; 11];
            let ok = self.file.read_exact(&mut r).is_ok();
            self.last = Instant::now();
            if !ok {
                continue;
            }
            // 6e 88 02 rc code type mh ml ch cl chk — rc 0 is "supported".
            let chk = r[..10].iter().fold(0x50u8, |a, b| a ^ b);
            if r[0] != 0x6e || r[2] != 0x02 || r[4] != code || chk != r[10] {
                continue;
            }
            if r[3] != 0 {
                return None;
            }
            let max = u16::from_be_bytes([r[6], r[7]]);
            let cur = u16::from_be_bytes([r[8], r[9]]);
            return (max > 0).then_some((cur.min(max), max));
        }
        None
    }

    fn set(&mut self, code: u8, value: u16) -> std::io::Result<()> {
        let [h, l] = value.to_be_bytes();
        self.send(&[0x03, code, h, l])
    }
}

// ── which bus is which monitor ──────────────────────────────────────────

/// Whether an i2c bus belongs to a graphics card: some device above it in
/// sysfs is PCI class 0x03 (display controller). The motherboard's SMBus,
/// where memory modules sit at the same 0x50, never is.
fn on_graphics_card(n: u32) -> bool {
    let root = sysroot();
    let Ok(mut p) = std::fs::canonicalize(format!("{root}/sys/bus/i2c/devices/i2c-{n}")) else { return false };
    let name = std::fs::read_to_string(p.join("name")).unwrap_or_default();
    if name.contains("SMBus") || name.contains("smbus") {
        return false;
    }
    for _ in 0..8 {
        if let Ok(class) = std::fs::read_to_string(p.join("class")) {
            return class.trim().starts_with("0x03");
        }
        if !p.pop() {
            break;
        }
    }
    false
}

fn bus_number(link: &Path) -> Option<u32> {
    let target = std::fs::read_link(link).ok()?;
    let last = target.file_name()?.to_string_lossy().to_string();
    last.strip_prefix("i2c-")?.parse().ok()
}

/// The monitor's name, from its EDID's name descriptor (0xfc).
fn edid_name(e: &[u8]) -> Option<String> {
    for d in 0..4 {
        let o = 54 + d * 18;
        if e.len() >= o + 18 && e[o] == 0 && e[o + 1] == 0 && e[o + 3] == 0xfc {
            let s: String = e[o + 5..o + 18].iter().take_while(|c| **c != b'\n').map(|c| *c as char).collect();
            let s = s.trim().to_string();
            if !s.is_empty() {
                return Some(s);
            }
        }
    }
    None
}

struct Monitor {
    output: String,
    name: String,
    bus: Option<u32>,
    edid: Vec<u8>,
}

fn internal(output: &str) -> bool {
    output.starts_with("eDP") || output.starts_with("LVDS") || output.starts_with("DSI")
}

/// Connected external outputs, from /sys/class/drm, each with its bus when
/// the driver links one (amdgpu, i915, nouveau do; NVIDIA's own driver
/// does not, and is matched by EDID below).
fn monitors() -> Vec<Monitor> {
    let root = sysroot();
    let mut out = Vec::new();
    let Ok(dir) = std::fs::read_dir(format!("{root}/sys/class/drm")) else { return out };
    for e in dir.flatten() {
        let fname = e.file_name().to_string_lossy().to_string();
        // card1-DP-2 → DP-2
        let Some((card, output)) = fname.split_once('-') else { continue };
        if !card.starts_with("card") || internal(output) {
            continue;
        }
        let p = e.path();
        if std::fs::read_to_string(p.join("status")).map(|s| s.trim() != "connected").unwrap_or(true) {
            continue;
        }
        let edid = std::fs::read(p.join("edid")).unwrap_or_default();
        let name = edid_name(&edid).unwrap_or_else(|| output.to_string());
        let bus = bus_number(&p.join("ddc")).or_else(|| {
            // DisplayPort's AUX channel, as an i2c bus under the connector.
            std::fs::read_dir(&p).ok()?.flatten().find_map(|c| {
                let n = c.file_name().to_string_lossy().to_string();
                n.strip_prefix("i2c-")?.parse().ok()
            })
        });
        out.push(Monitor { output: output.to_string(), name, bus, edid });
    }
    out.sort_by(|a, b| a.output.cmp(&b.output));
    out
}

// ── the thread ──────────────────────────────────────────────────────────

struct Display {
    output: String,
    name: String,
    bus: Option<Bus>,
    value: u16,
    max: u16,
}

fn scan() -> (Vec<Display>, Option<&'static str>) {
    let mut reason = None;
    let have_dev = Path::new("/dev").read_dir().map(|d| d.flatten().any(|e| e.file_name().to_string_lossy().starts_with("i2c-"))).unwrap_or(false);
    if !have_dev {
        reason = Some("setup");
    }
    let mons = monitors();
    // Buses the drivers did not link, keyed by EDID, for the monitors left.
    let mut by_edid: HashMap<Vec<u8>, u32> = HashMap::new();
    if have_dev && mons.iter().any(|m| m.bus.is_none() && !m.edid.is_empty()) {
        let linked: Vec<u32> = mons.iter().filter_map(|m| m.bus).collect();
        if let Ok(dir) = std::fs::read_dir("/dev") {
            for e in dir.flatten() {
                let Some(n) = e.file_name().to_string_lossy().strip_prefix("i2c-").and_then(|s| s.parse::<u32>().ok()) else { continue };
                if linked.contains(&n) || !on_graphics_card(n) {
                    continue;
                }
                if let Ok(mut b) = Bus::open(n) {
                    if let Some(ed) = b.edid() {
                        by_edid.insert(ed, n);
                    }
                }
            }
        }
    }
    let mut out = Vec::new();
    for m in mons {
        let n = m.bus.or_else(|| by_edid.get(m.edid.get(..128).unwrap_or(&[])).copied());
        let mut d = Display { output: m.output, name: m.name, bus: None, value: 0, max: 0 };
        // A bus the driver linked to this connector is its own; any other
        // must be on a graphics card.
        if let Some(n) = n.filter(|n| m.bus == Some(*n) || on_graphics_card(*n)) {
            match Bus::open(n) {
                Ok(mut b) => {
                    if let Some((cur, max)) = b.get(VCP_BRIGHTNESS) {
                        d.value = cur;
                        d.max = max;
                        d.bus = Some(b);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied || e.kind() == std::io::ErrorKind::NotFound => {
                    reason = Some("setup");
                }
                Err(_) => {}
            }
        }
        out.push(d);
    }
    (out, reason)
}

fn emit(ds: &[Display], reason: Option<&str>) {
    let list: Vec<Value> = ds
        .iter()
        .map(|d| {
            json!({
                "output": d.output, "name": d.name,
                "method": if d.bus.is_some() { "ddc" } else { "software" },
                "value": if d.max > 0 { (d.value as f64 * 100.0 / d.max as f64).round() } else { 100.0 },
                "max": d.max,
            })
        })
        .collect();
    let mut ev = json!({ "ev": "ddc", "displays": list });
    if let Some(r) = reason {
        ev["reason"] = json!(r);
    }
    out::emit(ev);
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    std::thread::spawn(move || {
        let (mut ds, mut reason) = scan();
        emit(&ds, reason);
        // The latest value asked for, per output: a slider being dragged
        // asks many times a second, and a monitor takes one every 50 ms
        // at best, so only the newest is sent.
        let mut pending: HashMap<String, f64> = HashMap::new();
        loop {
            let wait = if pending.is_empty() { Duration::from_secs(3600) } else { Duration::from_millis(10) };
            match rx.recv_timeout(wait) {
                Ok(c) => match c["cmd"].as_str().unwrap_or("") {
                    "ddc-refresh" => {
                        (ds, reason) = scan();
                        emit(&ds, reason);
                    }
                    "ddc-set" => {
                        if let (Some(o), Some(v)) = (c["output"].as_str(), c["value"].as_f64()) {
                            pending.insert(o.to_string(), v.clamp(0.0, 100.0));
                        }
                    }
                    _ => {}
                },
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            // Drain what has queued up before writing, so a drag sends its
            // last position rather than its first.
            while let Ok(c) = rx.try_recv() {
                if c["cmd"] == "ddc-set" {
                    if let (Some(o), Some(v)) = (c["output"].as_str(), c["value"].as_f64()) {
                        pending.insert(o.to_string(), v.clamp(0.0, 100.0));
                    }
                } else if c["cmd"] == "ddc-refresh" {
                    (ds, reason) = scan();
                    emit(&ds, reason);
                }
            }
            let mut changed = false;
            for (o, v) in pending.drain() {
                if let Some(d) = ds.iter_mut().find(|d| d.output == o) {
                    if let Some(b) = d.bus.as_mut() {
                        let raw = (v / 100.0 * d.max as f64).round() as u16;
                        if b.set(VCP_BRIGHTNESS, raw).is_ok() {
                            d.value = raw;
                            changed = true;
                        }
                    }
                }
            }
            if changed {
                emit(&ds, reason);
            }
        }
    });
    tx
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn name_from_edid() {
        let mut e = vec![0u8; 128];
        e[..8].copy_from_slice(&[0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0]);
        let o = 54 + 18;
        e[o + 3] = 0xfc;
        e[o + 5..o + 18].copy_from_slice(b"LG ULTRAGEAR\n");
        assert_eq!(edid_name(&e).as_deref(), Some("LG ULTRAGEAR"));
    }
    #[test]
    fn checksum() {
        // Get VCP 0x10: 51 82 01 10, checksum 0x6e^0x51^0x82^0x01^0x10 = 0xac
        let msg = [0x51u8, 0x82, 0x01, 0x10];
        assert_eq!(msg.iter().fold(0x6eu8, |a, b| a ^ b), 0xac);
    }
    #[test]
    fn internal_panels() {
        assert!(internal("eDP-1") && internal("LVDS-1") && !internal("DP-1") && !internal("HDMI-A-1"));
    }
}
