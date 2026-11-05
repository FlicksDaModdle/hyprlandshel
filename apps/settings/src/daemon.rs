//! Settings' own hyprshell-daemon, as Quickshell's services/Daemon.qml
//! runs one: JSON lines in and out, NetworkManager, BlueZ and PipeWire
//! behind it. Started with HYPRSHELL_AGENT=quiet so it answers only for the
//! Bluetooth pairings Settings starts, and leaves the default agent (and
//! NetworkManager's secret agent) to the shell's own daemon.

use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver};

pub struct Daemon {
    stdin: Option<ChildStdin>,
    pub rx: Receiver<Value>,
}

fn find() -> Option<std::path::PathBuf> {
    if let Some(p) = std::env::var_os("HYPRSHELL_DAEMON").map(std::path::PathBuf::from).filter(|p| p.exists()) {
        return Some(p);
    }
    let local = hyprshell_kit::config_dir().join("quickshell/hyprshell/bin/hyprshell-daemon");
    if local.exists() {
        return Some(local);
    }
    std::env::var_os("PATH").and_then(|p| std::env::split_paths(&p).map(|d| d.join("hyprshell-daemon")).find(|p| p.exists()))
}

impl Daemon {
    pub fn start() -> Daemon {
        let (tx, rx) = channel();
        let Some(bin) = find() else {
            let _ = tx.send(serde_json::json!({ "ev": "missing" }));
            return Daemon { stdin: None, rx };
        };
        let child = Command::new(bin).env("HYPRSHELL_AGENT", "quiet").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn();
        let Ok(mut child) = child else {
            let _ = tx.send(serde_json::json!({ "ev": "missing" }));
            return Daemon { stdin: None, rx };
        };
        let out = child.stdout.take().expect("piped");
        let stdin = child.stdin.take();
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    if tx.send(v).is_err() {
                        return;
                    }
                }
            }
            let _ = tx.send(serde_json::json!({ "ev": "exited" }));
            let _ = child.wait();
        });
        Daemon { stdin, rx }
    }

    pub fn send(&mut self, v: Value) {
        if let Some(s) = &mut self.stdin {
            if writeln!(s, "{v}").is_err() {
                self.stdin = None;
            }
        }
    }
}
