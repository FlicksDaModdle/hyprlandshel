//! The screen's backlight: read from sysfs, kept up to date by the kernel's
//! own change events (a netlink uevent socket, no libudev) and a cheap
//! in-process re-read; set through logind, which lets the session's user
//! do it without root — the way brightnessctl does it, without starting
//! brightnessctl.
//!
//! Commands:  bl-watch {on}   re-read every second while a slider shows
//!            bl-set {value}  raw value, 0..max
//!            bl-refresh
//! Events:    backlight {available, device, value, max}

use crate::out;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::Duration;

/// The panel's backlight. Firmware and platform interfaces are the ones
/// that drive the panel properly; "raw" (the GPU's own) is the usual one on
/// AMD laptops and the fallback elsewhere.
fn find() -> Option<PathBuf> {
    // HYPRSHELL_SYSROOT: a fake /sys for testing, as the task manager has.
    let root = std::env::var("HYPRSHELL_SYSROOT").unwrap_or_default();
    let mut found: Vec<(u8, PathBuf)> = Vec::new();
    for e in std::fs::read_dir(format!("{root}/sys/class/backlight")).ok()?.flatten() {
        let p = e.path();
        let kind = std::fs::read_to_string(p.join("type")).unwrap_or_default();
        let rank = match kind.trim() {
            "firmware" => 0,
            "platform" => 1,
            _ => 2,
        };
        found.push((rank, p));
    }
    found.sort();
    found.into_iter().next().map(|(_, p)| p)
}

fn read_num(p: &Path) -> Option<u64> {
    std::fs::read_to_string(p).ok()?.trim().parse().ok()
}

fn read(dev: &Path) -> Option<(u64, u64)> {
    Some((read_num(&dev.join("brightness"))?, read_num(&dev.join("max_brightness"))?))
}

/// logind's SetBrightness, on the caller's own session. The bus connection
/// is kept: a slider being dragged sets it many times a second.
fn set_logind(bus: &mut Option<zbus::blocking::Connection>, name: &str, value: u32) -> Result<(), String> {
    if bus.is_none() {
        *bus = Some(zbus::blocking::Connection::system().map_err(|e| e.to_string())?);
    }
    let conn = bus.as_ref().unwrap();
    let r = conn.call_method(
        Some("org.freedesktop.login1"),
        "/org/freedesktop/login1/session/auto",
        Some("org.freedesktop.login1.Session"),
        "SetBrightness",
        &("backlight", name, value),
    );
    if r.is_err() {
        *bus = None; // reconnect next time, in case the bus went away
    }
    r.map(|_| ()).map_err(|e| e.to_string())
}

/// Kernel uevents for the backlight subsystem — the brightness keys on
/// most laptops change it in firmware and announce it here. Wakes `tx`.
fn listen_uevents(tx: Sender<Value>) {
    std::thread::spawn(move || unsafe {
        let fd = libc::socket(libc::AF_NETLINK, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, libc::NETLINK_KOBJECT_UEVENT);
        if fd < 0 {
            return;
        }
        let mut addr: libc::sockaddr_nl = std::mem::zeroed();
        addr.nl_family = libc::AF_NETLINK as u16;
        addr.nl_groups = 1; // the kernel's own events
        if libc::bind(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_nl>() as u32) < 0 {
            libc::close(fd);
            return;
        }
        let mut buf = vec![0u8; 8192];
        loop {
            let n = libc::recv(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0);
            if n <= 0 {
                continue;
            }
            let msg = &buf[..n as usize];
            if msg.windows(20).any(|w| w == b"SUBSYSTEM=backlight\0") && tx.send(json!({ "cmd": "bl-refresh" })).is_err() {
                break;
            }
        }
        libc::close(fd);
    });
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    listen_uevents(tx.clone());
    std::thread::spawn(move || {
        let mut dev = find();
        let mut last: Option<(u64, u64)> = None;
        let mut watching = false;
        let mut sent_absent = false;
        let mut bus: Option<zbus::blocking::Connection> = None;
        loop {
            match &dev {
                Some(d) => {
                    let now = read(d);
                    if now.is_some() && now != last {
                        let (v, m) = now.unwrap();
                        out::emit(json!({
                            "ev": "backlight", "available": true,
                            "device": d.file_name().and_then(|n| n.to_str()).unwrap_or(""),
                            "value": v, "max": m
                        }));
                        last = now;
                    }
                }
                None if !sent_absent => {
                    out::emit(json!({ "ev": "backlight", "available": false }));
                    sent_absent = true;
                }
                None => {}
            }

            // Nothing changes it unannounced but other programs writing
            // sysfs (an idle dimmer): worth a quick re-read while a slider
            // is on screen, an occasional one otherwise. A file read, not a
            // process.
            let wait = Duration::from_secs(if watching { 1 } else { 20 });
            let mut set: Option<u32> = None;
            match rx.recv_timeout(wait) {
                Ok(cmd) => {
                    let mut handle = |cmd: Value| match cmd["cmd"].as_str() {
                        Some("bl-watch") => watching = cmd["on"].as_bool().unwrap_or(false),
                        Some("bl-set") => set = cmd["value"].as_u64().map(|v| v as u32),
                        _ => {}
                    };
                    handle(cmd);
                    // A slider being dragged sends a stream; the last one wins.
                    while let Ok(more) = rx.try_recv() {
                        handle(more);
                    }
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            if dev.is_none() {
                dev = find();
            }
            if let (Some(v), Some(d)) = (set, &dev) {
                let name = d.file_name().and_then(|n| n.to_str()).unwrap_or("").to_string();
                let max = last.map(|l| l.1).unwrap_or(u32::MAX as u64) as u32;
                let v = v.min(max);
                if let Err(e) = set_logind(&mut bus, &name, v) {
                    // No logind session (started from a TTY, say): sysfs, if
                    // this user may write it.
                    if std::fs::write(d.join("brightness"), v.to_string()).is_err() {
                        out::emit(json!({ "ev": "backlight-error", "message": e }));
                    }
                }
            }
        }
    });
    tx
}
