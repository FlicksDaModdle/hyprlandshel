//! Whether a night-light program runs, and which one could: hyprsunset or
//! wlsunset. Read from /proc in-process — the shell used to start
//! `sh` and `pgrep` for it.
//!
//! Starting and stopping them stays the shell's (they are its children or
//! its commands); after doing so it sends nl-refresh and hears at once.

use crate::out;
use serde_json::{json, Value};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::Duration;

const NAMES: [&str; 2] = ["hyprsunset", "wlsunset"];

fn running() -> String {
    let Ok(dir) = std::fs::read_dir("/proc") else { return String::new() };
    for e in dir.flatten() {
        let name = e.file_name();
        let Some(pid) = name.to_str() else { continue };
        if !pid.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        if let Ok(comm) = std::fs::read_to_string(e.path().join("comm")) {
            let comm = comm.trim();
            if let Some(n) = NAMES.iter().find(|n| **n == comm) {
                return n.to_string();
            }
        }
    }
    String::new()
}

fn installed() -> String {
    let path = std::env::var("PATH").unwrap_or_default();
    for n in NAMES {
        for dir in path.split(':').chain(["/usr/bin", "/usr/local/bin"]) {
            if !dir.is_empty() && std::path::Path::new(dir).join(n).is_file() {
                return n.to_string();
            }
        }
    }
    String::new()
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    std::thread::spawn(move || {
        let mut last = (String::from("?"), String::from("?"));
        loop {
            let now = (running(), installed());
            if now != last {
                out::emit(json!({ "ev": "nightlight", "running": now.0, "installed": now.1 }));
                last = now;
            }
            // Something changing outside the shell is only noticed on this
            // timer; the shell's own changes ask straight away.
            match rx.recv_timeout(Duration::from_secs(30)) {
                Ok(_) | Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            // A burst of refreshes is one read.
            while rx.try_recv().is_ok() {}
            std::thread::sleep(Duration::from_millis(400));
        }
    });
    tx
}
