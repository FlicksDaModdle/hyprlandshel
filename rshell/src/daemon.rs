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
pub struct Drive {
    pub path: String,
    pub name: String,
    pub detail: String,
    /// The first filesystem: what clicking the row mounts or opens.
    pub part: String,
    pub mount: String,
}

/// A Wi-Fi network in reach, with what's saved for it.
#[derive(Clone, Default)]
pub struct Ap {
    pub ssid: String,
    pub signal: i64,
    pub secure: bool,
    pub active: bool,
    /// The saved profile's uuid, when there is one.
    pub saved: Option<String>,
}

#[derive(Clone, Default)]
pub struct BtDevice {
    pub mac: String,
    pub name: String,
    pub icon: String,
    pub paired: bool,
    pub connected: bool,
    pub battery: i64,
}

#[derive(Clone, Default)]
pub struct State {
    pub aps: Vec<Ap>,
    pub bt_devices: Vec<BtDevice>,
    pub bt_scanning: bool,
    pub wifi_on: bool,
    pub net_available: bool,
    pub wired: bool,
    /// Backlight, 0..1; None without one.
    pub brightness: Option<f64>,
    pub bl_max: u64,
    /// The default source (microphone): name, level, mute.
    pub mic: Option<(String, f64, bool)>,
    /// Apps recording from a microphone, and with the camera open.
    pub mic_apps: Vec<String>,
    pub camera_apps: Vec<String>,
    pub drives: Vec<Drive>,
    /// Bluetooth: there is an adapter; it is on; what is connected.
    pub bt_available: bool,
    pub bt_on: bool,
    pub bt_label: String,
    /// asusd: the platform profile now and those there are; the keyboard
    /// light's level (-1 without one).
    pub rog_profile: i64,
    pub rog_profiles: Vec<i64>,
    pub kbd_level: i64,
    /// What the bar says about the network: the Wi-Fi's name, "Wi-Fi off",
    /// "not connected", or "" until the daemon has spoken.
    pub net_label: String,
    pub net_icon: &'static str,
    pub volume: f64,
    pub muted: bool,
    pub sink: String,
    /// The output's own name, and the apps playing (the volume mixer's rows).
    pub sink_desc: String,
    pub streams: Vec<Stream>,
    /// The outputs a stream can be moved to: (index, name, description), not the shell's own.
    pub outputs: Vec<(i64, String, String)>,
    pub have_audio: bool,
}

#[derive(Clone, Default)]
pub struct Stream {
    pub index: i64,
    pub app: String,
    pub media: String,
    pub volume: f64,
    pub mute: bool,
    /// The output it plays to (a sink's index), and the key apps are kept in the
    /// equalizer's list by (AudioFx.appKey).
    pub sink: i64,
    pub key: String,
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
    // The keybinds' commands (hyprshell.cmd), read for this shell now.
    d.send(json!({ "cmd": "cmd-watch", "shellPid": std::process::id(), "socket": "" }));
    d
}

/// Folds one event into the state; true if the bar should change.
pub fn apply(s: &mut State, ev: &Value) -> bool {
    match ev["ev"].as_str() {
        Some("net") => {
            s.net_available = ev["available"] == true;
            if ev["available"] != true {
                s.net_label = "no network".into();
                s.net_icon = "wifi-off";
                return true;
            }
            let wifi_on = ev["wifiEnabled"].as_bool().unwrap_or(true);
            s.wifi_on = wifi_on;
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
            s.wired = wired.is_some_and(|a| a["state"] == "activated");
            // The networks in reach (only while a list is on screen), each
            // once, strongest first, the one in use at the top.
            if let Some(aps) = ev["aps"].as_array() {
                let saved: Vec<(String, String)> = ev["saved"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|p| (p["ssid"].as_str().unwrap_or("").to_string(), p["uuid"].as_str().unwrap_or("").to_string()))
                    .collect();
                let mut list: Vec<Ap> = Vec::new();
                for a in aps {
                    let ssid = a["ssid"].as_str().unwrap_or("").to_string();
                    let signal = a["signal"].as_i64().unwrap_or(0);
                    let active = a["inUse"] == true;
                    match list.iter_mut().find(|x| x.ssid == ssid) {
                        Some(x) => {
                            x.signal = x.signal.max(signal);
                            x.active |= active;
                        }
                        None => list.push(Ap {
                            saved: saved.iter().find(|(n, _)| *n == ssid).map(|(_, u)| u.clone()),
                            secure: a["security"].as_str().is_some_and(|x| !x.is_empty() && x != "none" && x != "--"),
                            ssid,
                            signal,
                            active,
                        }),
                    }
                }
                list.sort_by(|a, b| b.active.cmp(&a.active).then(b.signal.cmp(&a.signal)));
                s.aps = list;
            }
            true
        }
        Some("pa") if ev["available"] == true => {
            let sink = ev["defaultSink"].as_str().unwrap_or("").to_string();
            let sinks = ev["sinks"].as_array().cloned().unwrap_or_default();
            let ours = |x: &Value| x["name"].as_str().unwrap_or("").starts_with("hyprshell_");
            let raw = crate::theme::raw();
            // With the equalizer in the way (it is the default), the level that
            // is shown and set is the device behind it (Audio.qml's `sink`): the
            // equalizer's own stays where it is.
            let chosen = if sink == crate::audiofx::EQ_SINK {
                let target = raw["eqTarget"].as_str().unwrap_or("");
                sinks.iter().find(|x| x["name"] == target && !ours(x)).or_else(|| sinks.iter().find(|x| !ours(x)))
            } else {
                None
            };
            if let Some(d) = chosen.or_else(|| sinks.iter().find(|x| x["name"] == sink.as_str())).or(sinks.first()) {
                s.volume = d["volume"].as_f64().unwrap_or(0.0);
                s.muted = d["mute"].as_bool().unwrap_or(false);
                s.sink = d["name"].as_str().unwrap_or("").to_string();
                s.sink_desc = d["description"].as_str().unwrap_or("").to_string();
                s.have_audio = true;
            }
            // Apps playing: not the shell's own, nor a monitor (Audio.qml's streams).
            s.streams = ev["sinkInputs"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|v| {
                    let p = &v["properties"];
                    p["stream.monitor"] != "true"
                        && p["media.category"] != "Monitor"
                        && p["application.name"] != "Quickshell Peak Detect"
                        && !p["application.name"].as_str().unwrap_or("").starts_with("hyprshell-")
                })
                .map(|v| {
                    let p = &v["properties"];
                    Stream {
                        index: v["index"].as_i64().unwrap_or(-1),
                        app: p["application.name"].as_str().filter(|x| !x.is_empty()).or(p["application.process.binary"].as_str()).unwrap_or("App").to_string(),
                        media: p["media.name"].as_str().unwrap_or("").to_string(),
                        volume: v["volume"].as_f64().unwrap_or(1.0),
                        mute: v["mute"] == true,
                        sink: v["sink"].as_i64().unwrap_or(-1),
                        key: p["application.process.binary"].as_str().filter(|x| !x.is_empty()).or(p["application.name"].as_str()).unwrap_or("").to_string(),
                    }
                })
                .collect();
            s.outputs = sinks
                .iter()
                .filter(|x| !ours(x))
                .map(|x| (x["index"].as_i64().unwrap_or(-1), x["name"].as_str().unwrap_or("").to_string(), x["description"].as_str().unwrap_or("").to_string()))
                .collect();
            let source = ev["defaultSource"].as_str().unwrap_or("");
            let sources = ev["sources"].as_array().cloned().unwrap_or_default();
            // Likewise the noise suppression's source and the microphone behind it.
            let mic_pick = if source == crate::audiofx::NS_SOURCE {
                let target = raw["nsTarget"].as_str().unwrap_or("");
                sources.iter().find(|x| x["name"] == target && !ours(x) && x["monitor"] != true).or_else(|| sources.iter().find(|x| !ours(x) && x["monitor"] != true))
            } else {
                None
            };
            s.mic = mic_pick
                .or_else(|| sources.iter().find(|x| x["name"] == source))
                .or_else(|| sources.iter().find(|x| x["monitor"] != true))
                .filter(|x| x["monitor"] != true)
                .map(|x| (x["name"].as_str().unwrap_or("").to_string(), x["volume"].as_f64().unwrap_or(0.0), x["mute"].as_bool().unwrap_or(false)));
            // Who is recording from a microphone (Privacy.qml's micApps):
            // not the system's own, and not a speaker's monitor.
            let monitors: Vec<i64> = sources.iter().filter(|x| x["monitor"] == true).filter_map(|x| x["index"].as_i64()).collect();
            let mut apps: Vec<String> = Vec::new();
            for o in ev["sourceOutputs"].as_array().into_iter().flatten() {
                if o["source"].as_i64().is_some_and(|i| monitors.contains(&i)) {
                    continue;
                }
                let p = &o["properties"];
                let bin = p["application.process.binary"].as_str().unwrap_or("").to_lowercase();
                if ["pipewire", "wireplumber", "quickshell", "qs", "hyprshell-daemon", "hyprshell-rs", "pavucontrol"].contains(&bin.as_str())
                    || p["stream.monitor"] == "true"
                {
                    continue;
                }
                let name = p["application.name"].as_str().filter(|x| !x.is_empty()).map(str::to_string).unwrap_or(bin);
                if !name.is_empty() && !apps.contains(&name) {
                    apps.push(name);
                }
            }
            s.mic_apps = apps;
            true
        }
        Some("backlight") => {
            if ev["available"] == true && ev["max"].as_u64().unwrap_or(0) > 0 {
                s.bl_max = ev["max"].as_u64().unwrap_or(0);
                s.brightness = Some(ev["value"].as_f64().unwrap_or(0.0) / s.bl_max as f64);
            } else {
                s.brightness = None;
            }
            true
        }
        Some("camera") => {
            s.camera_apps = ev["apps"].as_array().into_iter().flatten().filter_map(|a| a["name"].as_str().map(str::to_string)).collect();
            true
        }
        Some("usb") => {
            s.drives = ev["drives"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|d| {
                    let parts = d["parts"].as_array().cloned().unwrap_or_default();
                    let first = parts.iter().find(|p| p["mount"].as_str().is_some_and(|m| !m.is_empty())).or(parts.first());
                    let label = first.and_then(|p| p["label"].as_str()).filter(|l| !l.is_empty());
                    let size = d["size"].as_f64().unwrap_or(0.0);
                    let mount = first.and_then(|p| p["mount"].as_str()).unwrap_or("").to_string();
                    Drive {
                        path: d["path"].as_str().unwrap_or("").to_string(),
                        name: label.or(d["name"].as_str()).unwrap_or("Drive").to_string(),
                        detail: format!("{}{}", human(size), if mount.is_empty() { " · not mounted".to_string() } else { format!(" · {mount}") }),
                        part: first.and_then(|p| p["path"].as_str()).unwrap_or("").to_string(),
                        mount,
                    }
                })
                .collect();
            true
        }
        Some("bt") => {
            s.bt_available = ev["available"] == true;
            s.bt_on = ev["adapter"]["powered"] == true;
            let connected: Vec<&str> = ev["devices"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|d| d["connected"] == true)
                .filter_map(|d| d["name"].as_str())
                .collect();
            s.bt_scanning = ev["adapter"]["discovering"] == true;
            let mut devs: Vec<BtDevice> = ev["devices"]
                .as_array()
                .into_iter()
                .flatten()
                .filter(|d| d["paired"] == true || d["named"] == true)
                .map(|d| BtDevice {
                    mac: d["mac"].as_str().unwrap_or("").to_string(),
                    name: d["name"].as_str().unwrap_or("").to_string(),
                    icon: d["icon"].as_str().unwrap_or("").to_string(),
                    paired: d["paired"] == true,
                    connected: d["connected"] == true,
                    battery: d["battery"].as_i64().unwrap_or(-1),
                })
                .collect();
            devs.sort_by(|a, b| b.connected.cmp(&a.connected).then(b.paired.cmp(&a.paired)).then(a.name.to_lowercase().cmp(&b.name.to_lowercase())));
            let paired = devs.iter().filter(|d| d.paired).count();
            s.bt_devices = devs;
            // Bluetooth.qml's label: the first connected device, else how many are paired.
            s.bt_label = if !s.bt_available {
                "no adapter".into()
            } else if !s.bt_on {
                "off".into()
            } else if let Some(c) = connected.first() {
                c.to_string()
            } else {
                format!("{paired} paired")
            };
            true
        }
        Some("rog") => {
            if ev["available"] != true {
                s.rog_profiles.clear();
                s.kbd_level = -1;
                return true;
            }
            s.rog_profile = ev["platform"]["profile"].as_i64().unwrap_or(-1);
            let have: Vec<i64> = ev["platform"]["choices"].as_array().into_iter().flatten().filter_map(|x| x.as_i64()).collect();
            // Quiet, Balanced, Performance: the order people think in.
            s.rog_profiles = [3, 2, 0, 1, 4].into_iter().filter(|p| have.contains(p)).collect();
            s.kbd_level = ev["aura"][0]["brightness"].as_i64().unwrap_or(-1);
            true
        }
        _ => false,
    }
}

fn human(bytes: f64) -> String {
    if bytes <= 0.0 {
        return String::new();
    }
    let gb = bytes / 1e9;
    if gb >= 1.0 {
        format!("{gb:.0} GB")
    } else {
        format!("{:.0} MB", bytes / 1e6)
    }
}

pub fn profile_name(p: i64) -> &'static str {
    match p {
        0 => "Balanced",
        1 => "Performance",
        2 => "Quiet",
        3 => "Low power",
        4 => "Custom",
        _ => "Profile",
    }
}
