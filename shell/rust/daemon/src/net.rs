//! NetworkManager, over D-Bus.
//!
//! The shell used to learn about the network by running `nmcli` — three of
//! them every few seconds, later on every `nmcli monitor` event. This reads
//! the same facts from NetworkManager's own objects, in-process, when
//! NetworkManager says something changed.
//!
//! Commands:  net-watch {on}    a Wi-Fi list is on screen: read every
//!                              access point (otherwise only the one in
//!                              use) and the saved profiles
//!            net-scan          ask the card to scan
//!            net-wifi {on}     the Wi-Fi radio
//!            net-refresh
//! Events:    net {available, wifiEnabled, full, active[], wifi{}, aps[],
//!                 saved[] (when read)}
//!
//! Joining, forgetting and the rest are netact.rs, on a thread of their
//! own; passwords NetworkManager asks for are the agent's (agent.rs).

use crate::out;
use serde_json::{json, Value as Json};
use std::collections::HashMap;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

const NM: &str = "org.freedesktop.NetworkManager";
const NM_PATH: &str = "/org/freedesktop/NetworkManager";
type Props = HashMap<String, OwnedValue>;

fn get_all(c: &Connection, path: &str, iface: &str) -> zbus::Result<Props> {
    let m = c.call_method(Some(NM), path, Some("org.freedesktop.DBus.Properties"), "GetAll", &(iface,))?;
    m.body().deserialize::<Props>()
}

fn s(p: &Props, k: &str) -> String {
    match p.get(k).map(|v| &**v) {
        Some(Value::Str(x)) => x.to_string(),
        Some(Value::ObjectPath(x)) => x.to_string(),
        _ => String::new(),
    }
}
fn u(p: &Props, k: &str) -> u64 {
    match p.get(k).map(|v| &**v) {
        Some(Value::U8(x)) => *x as u64,
        Some(Value::U16(x)) => *x as u64,
        Some(Value::U32(x)) => *x as u64,
        Some(Value::U64(x)) => *x,
        Some(Value::I32(x)) => *x as u64,
        _ => 0,
    }
}
fn b(p: &Props, k: &str) -> bool {
    matches!(p.get(k).map(|v| &**v), Some(Value::Bool(true)))
}
fn paths(p: &Props, k: &str) -> Vec<String> {
    match p.get(k).map(|v| &**v) {
        Some(Value::Array(a)) => a
            .iter()
            .filter_map(|v| match v {
                Value::ObjectPath(o) => Some(o.to_string()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}
fn bytes(v: Option<&Value>) -> Vec<u8> {
    match v {
        Some(Value::Array(a)) => a
            .iter()
            .filter_map(|v| match v {
                Value::U8(b) => Some(*b),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}
fn dicts(p: &Props, k: &str) -> Vec<HashMap<String, OwnedValue>> {
    p.get(k)
        .and_then(|v| v.try_clone().ok())
        .and_then(|v| Vec::<HashMap<String, OwnedValue>>::try_from(v).ok())
        .unwrap_or_default()
}

/// The security column as nmcli prints it — the shell's labels and its
/// open/secured/enterprise tests were written against that text.
fn security(flags: u64, wpa: u64, rsn: u64) -> String {
    const PRIVACY: u64 = 0x1;
    const PSK: u64 = 0x100;
    const X8021: u64 = 0x200;
    const SAE: u64 = 0x400;
    const OWE: u64 = 0x800;
    const OWE_TM: u64 = 0x1000;
    const SUITE_B: u64 = 0x2000;
    let mut out: Vec<&str> = Vec::new();
    if flags & PRIVACY != 0 && wpa == 0 && rsn == 0 {
        out.push("WEP");
    }
    if wpa != 0 {
        out.push("WPA1");
    }
    if rsn & (PSK | X8021) != 0 {
        out.push("WPA2");
    }
    if rsn & (SAE | SUITE_B) != 0 {
        out.push("WPA3");
    }
    if rsn & (OWE | OWE_TM) != 0 {
        out.push("OWE");
    }
    if (wpa | rsn) & X8021 != 0 {
        out.push("802.1X");
    }
    out.join(" ")
}

fn state_name(n: u64) -> &'static str {
    match n {
        1 => "activating",
        2 => "activated",
        3 => "deactivating",
        4 => "deactivated",
        _ => "unknown",
    }
}

struct Net {
    conn: Connection,
    full: bool,
    wifi_dev: Option<String>,
    active_ap: String,
}

impl Net {
    fn wifi_device(&mut self) -> zbus::Result<Option<String>> {
        if let Some(d) = &self.wifi_dev {
            return Ok(Some(d.clone()));
        }
        let m = self.conn.call_method(Some(NM), NM_PATH, Some(NM), "GetDevices", &())?;
        let devs: Vec<OwnedObjectPath> = m.body().deserialize()?;
        for d in devs {
            let p = get_all(&self.conn, d.as_str(), "org.freedesktop.NetworkManager.Device")?;
            if u(&p, "DeviceType") == 2 {
                self.wifi_dev = Some(d.to_string());
                return Ok(self.wifi_dev.clone());
            }
        }
        Ok(None)
    }

    fn ap(&self, path: &str, in_use: bool) -> Option<Json> {
        let p = get_all(&self.conn, path, "org.freedesktop.NetworkManager.AccessPoint").ok()?;
        let ssid = String::from_utf8_lossy(&bytes(p.get("Ssid").map(|v| &**v))).to_string();
        if ssid.is_empty() {
            return None; // hidden networks have no name to list
        }
        Some(json!({
            "ssid": ssid,
            "signal": u(&p, "Strength"),
            "security": security(u(&p, "Flags"), u(&p, "WpaFlags"), u(&p, "RsnFlags")),
            "freq": u(&p, "Frequency"),
            "rate": format!("{} Mbit/s", u(&p, "MaxBitrate") / 1000),
            "inUse": in_use
        }))
    }

    fn saved(&self) -> zbus::Result<Json> {
        let m = self.conn.call_method(Some(NM), "/org/freedesktop/NetworkManager/Settings", Some("org.freedesktop.NetworkManager.Settings"), "ListConnections", &())?;
        let list: Vec<OwnedObjectPath> = m.body().deserialize()?;
        let mut out = Vec::new();
        for c in list {
            let Ok(m) = self.conn.call_method(Some(NM), c.as_str(), Some("org.freedesktop.NetworkManager.Settings.Connection"), "GetSettings", &()) else { continue };
            let Ok(set) = m.body().deserialize::<HashMap<String, HashMap<String, OwnedValue>>>() else { continue };
            let empty = HashMap::new();
            let conn = set.get("connection").unwrap_or(&empty);
            if s(conn, "type") != "802-11-wireless" {
                continue;
            }
            let wl = set.get("802-11-wireless").unwrap_or(&empty);
            let sec = set.get("802-11-wireless-security").unwrap_or(&empty);
            let x = set.get("802-1x").unwrap_or(&empty);
            let eap: Vec<String> = match x.get("eap").map(|v| &**v) {
                Some(Value::Array(a)) => a.iter().filter_map(|v| if let Value::Str(s) = v { Some(s.to_string()) } else { None }).collect(),
                _ => Vec::new(),
            };
            out.push(json!({
                "uuid": s(conn, "uuid"),
                "name": s(conn, "id"),
                // Absent means the default, which is yes.
                "autoconnect": !matches!(conn.get("autoconnect").map(|v| &**v), Some(Value::Bool(false))),
                "ssid": String::from_utf8_lossy(&bytes(wl.get("ssid").map(|v| &**v))).to_string(),
                "keyMgmt": s(sec, "key-mgmt"),
                "eap": eap.join(",")
            }));
        }
        Ok(Json::Array(out))
    }

    fn snapshot(&mut self, with_saved: bool) -> zbus::Result<Json> {
        let nm = get_all(&self.conn, NM_PATH, NM)?;
        let mut active = Vec::new();
        let mut wifi_conn_dev: Option<String> = None;
        for path in paths(&nm, "ActiveConnections") {
            let Ok(a) = get_all(&self.conn, &path, "org.freedesktop.NetworkManager.Connection.Active") else { continue };
            let devs = paths(&a, "Devices");
            let mut ifname = String::new();
            if let Some(d) = devs.first() {
                if let Ok(dp) = get_all(&self.conn, d, "org.freedesktop.NetworkManager.Device") {
                    ifname = s(&dp, "Interface");
                }
            }
            let kind = s(&a, "Type");
            if kind == "802-11-wireless" && wifi_conn_dev.is_none() {
                wifi_conn_dev = devs.first().cloned();
            }
            active.push(json!({
                "type": kind, "state": state_name(u(&a, "State")),
                "uuid": s(&a, "Uuid"), "name": s(&a, "Id"), "device": ifname
            }));
        }

        let dev = match wifi_conn_dev {
            Some(d) => Some(d),
            None => self.wifi_device()?,
        };
        let mut wifi = Json::Null;
        let mut aps = Vec::new();
        if let Some(d) = &dev {
            let dp = get_all(&self.conn, d, "org.freedesktop.NetworkManager.Device")?;
            let wl = get_all(&self.conn, d, "org.freedesktop.NetworkManager.Device.Wireless").unwrap_or_default();
            self.active_ap = s(&wl, "ActiveAccessPoint");
            let mut ip4 = String::new();
            let mut gateway = String::new();
            let mut dns: Vec<String> = Vec::new();
            let mut ip6 = String::new();
            let c4 = s(&dp, "Ip4Config");
            if !c4.is_empty() && c4 != "/" {
                if let Ok(p) = get_all(&self.conn, &c4, "org.freedesktop.NetworkManager.IP4Config") {
                    if let Some(a) = dicts(&p, "AddressData").first() {
                        ip4 = format!("{}/{}", s(a, "address"), u(a, "prefix"));
                    }
                    gateway = s(&p, "Gateway");
                    dns = dicts(&p, "NameserverData").iter().map(|d| s(d, "address")).filter(|a| !a.is_empty()).collect();
                }
            }
            let c6 = s(&dp, "Ip6Config");
            if !c6.is_empty() && c6 != "/" {
                if let Ok(p) = get_all(&self.conn, &c6, "org.freedesktop.NetworkManager.IP6Config") {
                    if let Some(a) = dicts(&p, "AddressData").first() {
                        ip6 = format!("{}/{}", s(a, "address"), u(a, "prefix"));
                    }
                }
            }
            let hw = { let h = s(&wl, "HwAddress"); if h.is_empty() { s(&dp, "HwAddress") } else { h } };
            wifi = json!({
                "device": s(&dp, "Interface"), "hw": hw, "ip4": ip4, "gateway": gateway,
                "dns": dns, "ip6": ip6, "bitrate": u(&wl, "Bitrate")
            });
            // Every access point only while a list is on screen; the one in
            // use always, for the bar's name and signal.
            let list = if self.full { paths(&wl, "AccessPoints") } else { vec![self.active_ap.clone()] };
            for ap in list {
                if ap.is_empty() || ap == "/" {
                    continue;
                }
                let in_use = ap == self.active_ap;
                if let Some(j) = self.ap(&ap, in_use) {
                    aps.push(j);
                }
            }
        }

        let mut ev = json!({
            "ev": "net", "available": true,
            "wifiEnabled": b(&nm, "WirelessEnabled"),
            "full": self.full,
            "active": active, "wifi": wifi, "aps": aps
        });
        if with_saved {
            ev["saved"] = self.saved().unwrap_or(Json::Null);
        }
        Ok(ev)
    }

    fn act(&mut self, cmd: &Json) -> zbus::Result<()> {
        match cmd["cmd"].as_str() {
            Some("net-scan") => {
                if let Some(d) = self.wifi_device()? {
                    let opts: HashMap<&str, Value> = HashMap::new();
                    self.conn.call_method(Some(NM), d.as_str(), Some("org.freedesktop.NetworkManager.Device.Wireless"), "RequestScan", &(opts,))?;
                }
            }
            Some("net-wifi") => {
                let on = cmd["on"].as_bool().unwrap_or(true);
                self.conn.call_method(Some(NM), NM_PATH, Some("org.freedesktop.DBus.Properties"), "Set", &(NM, "WirelessEnabled", Value::from(on)))?;
            }
            _ => {}
        }
        Ok(())
    }
}

/// NetworkManager's signals, as wake-ups on the command channel.
fn listen(conn: Connection, tx: Sender<Json>) {
    std::thread::spawn(move || {
        let Ok(rule) = zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).sender(NM).map(|b| b.build()) else { return };
        let Ok(iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(256)) else { return };
        for msg in iter.flatten() {
            let h = msg.header();
            let path = h.path().map(|p| p.to_string()).unwrap_or_default();
            let member = h.member().map(|m| m.to_string()).unwrap_or_default();
            if tx.send(json!({ "cmd": "_signal", "path": path, "member": member })).is_err() {
                return;
            }
        }
    });
}

fn run(rx: &Receiver<Json>, tx: &Sender<Json>, full: &mut bool) -> zbus::Result<()> {
    let conn = Connection::system()?;
    // Fails here, before anything is listened to, if NetworkManager isn't
    // running.
    get_all(&conn, NM_PATH, NM)?;
    listen(conn.clone(), tx.clone());
    let mut net = Net { conn, full: *full, wifi_dev: None, active_ap: String::new() };
    out::emit(net.snapshot(true)?);
    let mut last_read = Instant::now();

    loop {
        let first = match rx.recv() {
            Ok(c) => c,
            Err(_) => return Ok(()),
        };
        // Gather the burst that came with it — a connection coming up is a
        // dozen signals — into one read.
        let mut batch = vec![first];
        let settle = Instant::now() + Duration::from_millis(250);
        loop {
            let now = Instant::now();
            if now >= settle {
                break;
            }
            match rx.recv_timeout(settle - now) {
                Ok(c) => batch.push(c),
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => return Ok(()),
            }
        }

        let mut read = false;
        let mut saved = false;
        for cmd in &batch {
            match cmd["cmd"].as_str() {
                Some("net-watch") => {
                    net.full = cmd["on"].as_bool().unwrap_or(false);
                    *full = net.full;
                    read = true;
                    saved = net.full;
                }
                Some("net-refresh") => {
                    read = true;
                    saved = true;
                }
                Some("_signal") => {
                    let path = cmd["path"].as_str().unwrap_or("");
                    // Signal strength drifting on networks nobody is looking
                    // at is not worth a read.
                    if path.contains("/AccessPoint/") && !net.full && path != net.active_ap {
                        continue;
                    }
                    if path.starts_with("/org/freedesktop/NetworkManager/Settings") {
                        saved = true;
                    }
                    // A device appearing or going: look for the Wi-Fi one again.
                    if cmd["member"] == "DeviceAdded" || cmd["member"] == "DeviceRemoved" {
                        net.wifi_dev = None;
                    }
                    read = true;
                }
                Some(_) => {
                    if let Err(e) = net.act(cmd) {
                        out::emit(json!({ "ev": "net-error", "cmd": cmd["cmd"], "message": e.to_string() }));
                    }
                    read = true;
                }
                None => {}
            }
        }
        if !read {
            continue;
        }
        // Access points report their strength every few seconds each; with
        // a list open that is plenty, so at most a read a second.
        let since = last_read.elapsed();
        if since < Duration::from_secs(1) {
            std::thread::sleep(Duration::from_secs(1) - since);
        }
        out::emit(net.snapshot(saved)?);
        last_read = Instant::now();
    }
}

pub fn start() -> Sender<Json> {
    let (tx, rx) = channel::<Json>();
    let tx2 = tx.clone();
    // Actions to their own thread, everything else to the reader.
    let (atx, arx) = channel::<Json>();
    crate::netact::worker(arx);
    let (ptx, prx) = channel::<Json>();
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            for c in prx {
                let to = if crate::netact::is_action(c["cmd"].as_str().unwrap_or("")) { &atx } else { &tx };
                if to.send(c).is_err() {
                    return;
                }
            }
        });
    }
    std::thread::spawn(move || {
        let mut full = false;
        loop {
            if let Err(e) = run(&rx, &tx2, &mut full) {
                out::emit(json!({ "ev": "net", "available": false, "message": e.to_string() }));
            } else {
                return;
            }
            // NetworkManager not running, or restarted under us: try again,
            // unhurried, still answering net-watch so the setting is kept.
            let deadline = Instant::now() + Duration::from_secs(15);
            while let Some(left) = deadline.checked_duration_since(Instant::now()) {
                match rx.recv_timeout(left) {
                    Ok(c) if c["cmd"] == "net-watch" => full = c["on"].as_bool().unwrap_or(false),
                    Ok(_) => {}
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
        }
    });
    ptx
}
