//! hyprshell-daemon, the Rust service the Quickshell shell already runs:
//! the network from NetworkManager and the sound from PulseAudio, pushed as
//! JSON lines when they change. Started the same way (a line of JSON each
//! way, stdin closing ends it) so both shells read the same thing.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{ChildStdin, Command, Stdio};
use std::sync::mpsc::Sender;

#[derive(Clone, Default)]
pub struct State {
    /// What the bar says about the network: the Wi-Fi's name, "Wi-Fi off",
    /// "not connected", or "" until the daemon has spoken.
    pub net_label: String,
    pub net_icon: &'static str,
    pub volume: f64,
    pub muted: bool,
    pub sink: String,
    pub have_audio: bool,
}

fn find() -> Option<std::path::PathBuf> {
    // try.sh builds this branch's own and says where.
    if let Some(p) = std::env::var_os("HYPRSHELL_DAEMON").map(std::path::PathBuf::from).filter(|p| p.exists()) {
        return Some(p);
    }
    let cfg = std::env::var_os("XDG_CONFIG_HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config"));
    let local = cfg.join("quickshell/hyprshell/bin/hyprshell-daemon");
    if local.exists() {
        return Some(local);
    }
    std::env::var_os("PATH")?
        .to_str()?
        .split(':')
        .map(|d| std::path::Path::new(d).join("hyprshell-daemon"))
        .find(|p| p.exists())
}

pub struct Daemon {
    stdin: Option<ChildStdin>,
}

impl Daemon {
    pub fn send(&mut self, v: Value) {
        if let Some(i) = self.stdin.as_mut() {
            let _ = writeln!(i, "{v}");
        }
    }
}

/// Starts it, and sends every event to `tx` with a wake byte.
pub fn start(tx: Sender<Value>, mut wake: UnixStream) -> Daemon {
    let Some(bin) = find() else {
        eprintln!("hyprshell-rs: hyprshell-daemon isn't installed; no network name or volume");
        return Daemon { stdin: None };
    };
    let Ok(mut child) = Command::new(bin).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn() else {
        return Daemon { stdin: None };
    };
    let out = child.stdout.take().expect("piped");
    let stdin = child.stdin.take();
    std::thread::spawn(move || {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if tx.send(v).is_err() {
                    return;
                }
                let _ = wake.write_all(b"!");
            }
        }
        let _ = child.wait();
    });
    let mut d = Daemon { stdin };
    d.send(json!({ "cmd": "pa-watch", "on": true }));
    d
}

/// Folds one event into the state; true if the bar should change.
pub fn apply(s: &mut State, ev: &Value) -> bool {
    match ev["ev"].as_str() {
        Some("net") => {
            if ev["available"] != true {
                s.net_label = "no network".into();
                s.net_icon = "wifi-off";
                return true;
            }
            let wifi_on = ev["wifiEnabled"].as_bool().unwrap_or(true);
            let active = ev["active"].as_array().cloned().unwrap_or_default();
            let wifi = active.iter().find(|a| a["type"] == "802-11-wireless");
            let wired = active.iter().find(|a| a["type"] == "802-3-ethernet");
            let connecting = active.iter().any(|a| a["state"] == "activating");
            let connected = wifi.or(wired).is_some_and(|a| a["state"] == "activated");
            s.net_label = if !wifi_on && wired.is_none() {
                "Wi-Fi off".into()
            } else if connecting && !connected {
                "connecting…".into()
            } else if let Some(a) = wifi.or(wired).filter(|_| connected) {
                ev["wifi"]["ssid"].as_str().filter(|x| !x.is_empty()).or(a["name"].as_str()).unwrap_or("").to_string()
            } else {
                "not connected".into()
            };
            s.net_icon = if !wifi_on && wired.is_none() || !connected { "wifi-off" } else { "wifi" };
            true
        }
        Some("pa") if ev["available"] == true => {
            let sink = ev["defaultSink"].as_str().unwrap_or("").to_string();
            let sinks = ev["sinks"].as_array().cloned().unwrap_or_default();
            if let Some(d) = sinks.iter().find(|x| x["name"] == sink.as_str()).or(sinks.first()) {
                s.volume = d["volume"].as_f64().unwrap_or(0.0);
                s.muted = d["mute"].as_bool().unwrap_or(false);
                s.sink = d["name"].as_str().unwrap_or("").to_string();
                s.have_audio = true;
            }
            true
        }
        _ => false,
    }
}
