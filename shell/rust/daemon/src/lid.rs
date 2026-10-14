//! The laptop's lid: open or closed. The shell turns the built-in screen
//! off while it is closed and another monitor is plugged in — the way a
//! docked laptop works everywhere else — and back on when it opens, or
//! when the last other monitor goes.
//!
//! Read from ACPI (/proc/acpi/button/lid/*/state), else from logind's
//! LidClosed; looked at once a second (a file read), and told only when it
//! changes. Not Hyprland's lid-switch bind: that is lost on every config
//! reload, and doesn't say what state the lid is in when the shell starts.
//!
//! Commands:  lid-refresh
//! Events:    lid {present, closed}

use crate::out;
use serde_json::json;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::Duration;

fn sysroot() -> String {
    std::env::var("HYPRSHELL_SYSROOT").unwrap_or_default()
}

/// Whether there is a lid at all: an ACPI lid, or an input device called
/// "Lid Switch" (non-ACPI laptops).
fn present() -> bool {
    let root = sysroot();
    if std::fs::read_dir(format!("{root}/proc/acpi/button/lid")).map(|mut d| d.next().is_some()).unwrap_or(false) {
        return true;
    }
    std::fs::read_dir(format!("{root}/sys/class/input"))
        .map(|d| {
            d.flatten().any(|e| {
                std::fs::read_to_string(e.path().join("name")).map(|n| n.trim() == "Lid Switch").unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

fn acpi_closed() -> Option<bool> {
    let root = sysroot();
    let dir = std::fs::read_dir(format!("{root}/proc/acpi/button/lid")).ok()?;
    for e in dir.flatten() {
        if let Ok(t) = std::fs::read_to_string(e.path().join("state")) {
            // "state:      open" / "state:      closed"
            if t.contains("closed") {
                return Some(true);
            }
            if t.contains("open") {
                return Some(false);
            }
        }
    }
    None
}

fn logind_closed(conn: &Option<zbus::blocking::Connection>) -> Option<bool> {
    let c = conn.as_ref()?;
    let p = zbus::blocking::fdo::PropertiesProxy::builder(c)
        .destination("org.freedesktop.login1")
        .ok()?
        .path("/org/freedesktop/login1")
        .ok()?
        .build()
        .ok()?;
    let iface = zbus::names::InterfaceName::try_from("org.freedesktop.login1.Manager").ok()?;
    let v = p.get(iface, "LidClosed").ok()?;
    bool::try_from(v).ok()
}

pub fn start() -> Sender<serde_json::Value> {
    let (tx, rx) = channel::<serde_json::Value>();
    std::thread::Builder::new()
        .name("lid".into())
        .spawn(move || {
            let has = present();
            let conn = if has && sysroot().is_empty() { zbus::blocking::Connection::system().ok() } else { None };
            let read = || acpi_closed().or_else(|| logind_closed(&conn)).unwrap_or(false);
            let mut closed = has && read();
            out::emit(json!({ "ev": "lid", "present": has, "closed": closed }));
            loop {
                match rx.recv_timeout(Duration::from_secs(1)) {
                    Ok(c) => {
                        if c["cmd"].as_str() == Some("lid-refresh") {
                            closed = has && read();
                            out::emit(json!({ "ev": "lid", "present": has, "closed": closed }));
                        }
                    }
                    Err(RecvTimeoutError::Timeout) => {
                        if !has {
                            continue;
                        }
                        let now = read();
                        if now != closed {
                            closed = now;
                            out::emit(json!({ "ev": "lid", "present": true, "closed": closed }));
                        }
                    }
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
        })
        .expect("lid thread");
    tx
}
