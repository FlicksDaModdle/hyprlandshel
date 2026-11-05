//! Settings → Bluetooth: services/Bluetooth.qml (the adapter, its devices
//! and pairing, through the daemon's agent) and BluetoothPanel.qml's own
//! state. Pairing questions this Settings starts come to its own daemon's
//! agent, and are asked at the top of the pane.

use crate::daemon::Daemon;
use crate::{AppWindow, BtDev, Blue};
use serde_json::{json, Value};
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use std::collections::HashMap;

#[derive(Clone, Default)]
pub struct Dev {
    pub mac: String,
    pub name: String,
    pub named: bool,
    pub kind: String,
    pub connected: bool,
    pub paired: bool,
    pub battery: i64,
}

#[derive(Default)]
pub struct Bt {
    pub available: bool,
    pub live: bool,
    pub powered: bool,
    pub discoverable: bool,
    pub discovering: bool,
    pub controller: String,
    pub devices: Vec<Dev>,
    pub errors: HashMap<String, String>,
    pub busy: HashMap<String, String>,
    /// The agent's question: { id, kind, mac, name, passkey }.
    pub request: Option<Value>,
    /// A code to show while a keyboard is typed on.
    pub display: Option<Value>,
    pub menu_mac: String,
    pub watching: bool,
}

/// Bluetooth.kindLabel.
pub fn kind_label(k: &str) -> &'static str {
    if k.contains("headset") || k.contains("headphone") {
        "Headphones"
    } else if k.contains("audio") {
        "Speaker"
    } else if k.contains("keyboard") {
        "Keyboard"
    } else if k.contains("mouse") {
        "Mouse"
    } else if k.contains("gaming") || k.contains("joystick") {
        "Controller"
    } else if k.contains("phone") {
        "Phone"
    } else if k.contains("computer") {
        "Computer"
    } else if k.contains("tablet") {
        "Tablet"
    } else {
        ""
    }
}

/// Bluetooth.glyph.
pub fn glyph(k: &str) -> &'static str {
    if k.contains("headset") || k.contains("headphone") {
        "headphones"
    } else if k.contains("audio") {
        "speaker"
    } else if k.contains("keyboard") {
        "keyboard"
    } else if k.contains("mouse") {
        "mouse"
    } else if k.contains("gaming") || k.contains("joystick") {
        "gamepad"
    } else if k.contains("computer") {
        "monitor"
    } else {
        "bluetooth"
    }
}

/// Bluetooth.explain: BlueZ's errors as something to do about them.
pub fn explain(name: &str, message: &str) -> String {
    let both = format!("{name}{message}");
    if name.contains("AuthenticationFailed") {
        return "The device refused to pair. Put it in pairing mode and try again — and if it was paired with another computer (or with Windows on this one), remove that pairing on the device first.".into();
    }
    if name.contains("AuthenticationCanceled") {
        return "Pairing was cancelled on the device, or nobody answered in time.".into();
    }
    if name.contains("AuthenticationRejected") {
        return "The pairing was declined.".into();
    }
    if name.contains("AuthenticationTimeout") {
        return "The device didn't answer in time. Put it in pairing mode and try again.".into();
    }
    if name.contains("ConnectionAttemptFailed") || ["page-timeout", "Host is down", "le-connection-abort"].iter().any(|m| message.contains(m)) {
        return "Couldn't reach it. Make sure it's switched on and nearby.".into();
    }
    if message.contains("profile-unavailable") {
        return "It paired, but nothing here can use it. For headphones and speakers, PipeWire's Bluetooth support has to be installed (wireplumber with libspa-bluetooth).".into();
    }
    if ["rfkill", "Not Powered", "NotReady"].iter().any(|m| both.contains(m)) {
        return "Bluetooth is switched off or blocked — airplane mode, or the laptop's radio key.".into();
    }
    if name.contains("InProgress") {
        return "Already working on it.".into();
    }
    if name.contains("DoesNotExist") {
        return "That device is gone — scan again.".into();
    }
    if message.is_empty() {
        name.into()
    } else {
        message.into()
    }
}

impl Bt {
    /// While the Bluetooth pane is up: the state, and looking for devices.
    pub fn watch(&mut self, d: &mut Daemon, on: bool) {
        if self.watching == on {
            return;
        }
        self.watching = on;
        if on {
            d.send(json!({ "cmd": "bt-hello" }));
        }
        self.sync_scan(d);
    }

    fn sync_scan(&mut self, d: &mut Daemon) {
        if !self.powered {
            return;
        }
        if self.watching != self.discovering {
            d.send(json!({ "cmd": "bt-scan", "on": self.watching }));
        }
    }

    pub fn event(&mut self, d: &mut Daemon, ev: &Value) -> bool {
        match ev["ev"].as_str() {
            Some("ready") => {
                self.live = ev["modules"]["agent"] == true;
                true
            }
            Some("bt") => {
                self.live = true;
                self.available = ev["available"] == true;
                let a = &ev["adapter"];
                let was_powered = self.powered;
                self.powered = a["powered"] == true;
                self.discoverable = a["discoverable"] == true;
                self.discovering = a["discovering"] == true;
                self.controller = a["name"].as_str().unwrap_or("").to_string();
                let mut out: Vec<Dev> = ev["devices"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|v| {
                        let mac = v["mac"].as_str().unwrap_or("").to_string();
                        Dev {
                            name: v["name"].as_str().filter(|s| !s.is_empty()).unwrap_or(&mac).to_string(),
                            mac,
                            named: v["named"] == true,
                            kind: v["icon"].as_str().unwrap_or("").to_string(),
                            connected: v["connected"] == true,
                            paired: v["paired"] == true,
                            battery: v["battery"].as_i64().unwrap_or(-1),
                        }
                    })
                    .collect();
                out.sort_by(|x, y| (y.connected, y.paired).cmp(&(x.connected, x.paired)).then(x.name.cmp(&y.name)));
                self.devices = out;
                if self.powered && !was_powered {
                    self.sync_scan(d);
                }
                true
            }
            Some("bt-busy") => {
                let mac = ev["mac"].as_str().unwrap_or("").to_string();
                if !mac.is_empty() {
                    self.busy.insert(mac.clone(), ev["op"].as_str().unwrap_or("").to_string());
                    self.errors.remove(&mac);
                }
                true
            }
            Some("bt-done") => {
                let mac = ev["mac"].as_str().unwrap_or("").to_string();
                self.busy.remove(&mac);
                // Pairing stops the search; with the pane open, it picks up again.
                if self.busy.is_empty() {
                    self.discovering = false;
                    self.sync_scan(d);
                }
                if self.display.as_ref().is_some_and(|x| x["mac"] == mac.as_str()) {
                    self.display = None;
                }
                if self.request.as_ref().is_some_and(|x| x["mac"] == mac.as_str()) {
                    self.request = None;
                }
                true
            }
            Some("bt-error") => {
                let e = ev["error"].as_str().unwrap_or("");
                if e.contains("AlreadyExists") || e.contains("AlreadyConnected") {
                    return false;
                }
                if let Some(mac) = ev["mac"].as_str() {
                    self.errors.insert(mac.to_string(), explain(e, ev["message"].as_str().unwrap_or("")));
                }
                true
            }
            Some("bt-request") => {
                self.request = Some(ev.clone());
                true
            }
            Some("bt-display") => {
                self.display = Some(ev.clone());
                true
            }
            Some("bt-cancel") => {
                self.request = None;
                self.display = None;
                true
            }
            Some("exited") => {
                self.request = None;
                self.display = None;
                self.busy.clear();
                self.live = false;
                true
            }
            _ => false,
        }
    }

    pub fn answer(&mut self, d: &mut Daemon, accept: bool, value: &str) {
        let Some(r) = self.request.take() else { return };
        d.send(json!({ "cmd": "bt-reply", "id": r["id"], "accept": accept, "value": value }));
    }
    pub fn set_powered(&mut self, d: &mut Daemon, on: bool) {
        self.powered = on;
        d.send(json!({ "cmd": "bt-power", "on": on }));
    }
    pub fn set_discoverable(&mut self, d: &mut Daemon, on: bool) {
        self.discoverable = on;
        d.send(json!({ "cmd": "bt-discoverable", "on": on }));
    }
    pub fn scan(&mut self, d: &mut Daemon) {
        if self.powered {
            d.send(json!({ "cmd": "bt-scan", "on": true }));
        }
    }
    pub fn pair(&mut self, d: &mut Daemon, mac: &str) {
        self.errors.remove(mac);
        d.send(json!({ "cmd": "bt-pair", "mac": mac }));
    }
    pub fn cancel_pairing(&mut self, d: &mut Daemon, mac: &str) {
        if self.request.as_ref().is_some_and(|r| r["mac"] == mac) {
            self.answer(d, false, "");
        }
        d.send(json!({ "cmd": "bt-cancel", "mac": mac }));
    }
    pub fn remove(&mut self, d: &mut Daemon, mac: &str) {
        self.errors.remove(mac);
        d.send(json!({ "cmd": "bt-remove", "mac": mac }));
    }
    pub fn connect(&mut self, d: &mut Daemon, mac: &str) {
        self.errors.remove(mac);
        d.send(json!({ "cmd": "bt-connect", "mac": mac }));
    }
    pub fn disconnect(&mut self, d: &mut Daemon, mac: &str) {
        self.errors.remove(mac);
        d.send(json!({ "cmd": "bt-disconnect", "mac": mac }));
    }

    pub fn publish(&self, ui: &AppWindow) {
        let b = ui.global::<Blue>();
        b.set_available(self.available);
        b.set_live(self.live);
        b.set_powered(self.powered);
        b.set_discoverable(self.discoverable);
        b.set_discovering(self.discovering);
        let connected: Vec<&str> = self.devices.iter().filter(|d| d.connected).map(|d| d.name.as_str()).collect();
        b.set_sub(
            if !self.powered {
                "Turn it on to use or add devices".to_string()
            } else if !connected.is_empty() {
                format!("Connected to {}", connected.join(", "))
            } else if !self.controller.is_empty() {
                format!("Shows up as \u{201c}{}\u{201d}", self.controller)
            } else {
                String::new()
            }
            .into(),
        );
        let row = |d: &Dev, paired: bool| {
            let op = self.busy.get(&d.mac).cloned().unwrap_or_default();
            let err = self.errors.get(&d.mac).cloned().unwrap_or_default();
            let sub = if paired {
                match op.as_str() {
                    "connect" => "Connecting…".to_string(),
                    "disconnect" => "Disconnecting…".into(),
                    "pair" => "Pairing…".into(),
                    _ if !err.is_empty() => "Didn't connect — see below".into(),
                    _ => [
                        if d.connected { "Connected".to_string() } else { "Not connected".into() },
                        if d.battery >= 0 { format!("Battery {}%", d.battery) } else { String::new() },
                        kind_label(&d.kind).to_string(),
                    ]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" · "),
                }
            } else if !op.is_empty() {
                "Pairing…".into()
            } else if !err.is_empty() {
                "Didn't pair — see below".into()
            } else {
                kind_label(&d.kind).into()
            };
            BtDev {
                mac: d.mac.clone().into(),
                name: d.name.clone().into(),
                glyph: glyph(&d.kind).into(),
                connected: d.connected,
                sub: sub.into(),
                busy: !op.is_empty(),
                err: if op.is_empty() { err.into() } else { SharedString::new() },
                menu: self.menu_mac == d.mac,
            }
        };
        let paired: Vec<BtDev> = self.devices.iter().filter(|d| d.paired).map(|d| row(d, true)).collect();
        let nearby: Vec<BtDev> = self.devices.iter().filter(|d| !d.paired && d.named).map(|d| row(d, false)).collect();
        b.set_paired(ModelRc::new(VecModel::from(paired)));
        b.set_nearby(ModelRc::new(VecModel::from(nearby)));
        b.set_unnamed(self.devices.iter().filter(|d| !d.paired && !d.named).count() as i32);
        // The question at the top.
        let (title, line, code, kind, ask) = match (&self.request, &self.display) {
            (Some(r), _) => {
                let name = r["name"].as_str().unwrap_or("");
                let k = r["kind"].as_str().unwrap_or("");
                (
                    match k {
                        "confirm" => format!("Pair with {name}?"),
                        "pin" => format!("Enter the PIN for {name}"),
                        "passkey" => format!("Enter the code shown on {name}"),
                        "authorize" => format!("{name} wants to pair with this computer"),
                        "service" => format!("{name} wants to connect"),
                        _ => String::new(),
                    },
                    match k {
                        "confirm" => "Make sure the device shows the same code, then pair.",
                        "pin" => "Often 0000 or 1234 — or the one in its manual or on its screen.",
                        "passkey" => "Six digits, shown on the device's screen.",
                        "authorize" | "service" => "Allow it only if you started this from the device.",
                        _ => "",
                    }
                    .to_string(),
                    if k == "confirm" { r["passkey"].as_str().map(str::to_string).unwrap_or_else(|| r["passkey"].to_string()) } else { String::new() },
                    k.to_string(),
                    true,
                )
            }
            (None, Some(dp)) => (
                format!("Type this code on {}", dp["name"].as_str().unwrap_or("")),
                format!("Then press Enter on {}.", if dp["kind"] == "pin" { "it" } else { "the keyboard" }),
                dp["code"].as_str().map(str::to_string).unwrap_or_else(|| dp["code"].to_string()),
                "display".to_string(),
                false,
            ),
            _ => (String::new(), String::new(), String::new(), String::new(), false),
        };
        b.set_q_title(title.into());
        b.set_q_line(line.into());
        let code = code.trim_matches('"').to_string();
        b.set_q_len(code.chars().count() as i32);
        b.set_q_code(code.into());
        b.set_q_kind(kind.into());
        b.set_q_ask(ask);
        b.set_q_entered(self.display.as_ref().and_then(|d| d["entered"].as_i64()).map(|v| v as i32).unwrap_or(-1));
    }
}
