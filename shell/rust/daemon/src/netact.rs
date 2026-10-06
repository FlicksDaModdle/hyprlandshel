//! Wi-Fi actions, over NetworkManager's D-Bus API: joining (a saved network,
//! a new one, a hidden one, a university or office one), forgetting,
//! autoconnect, disconnecting, VPN, keeping a password in a profile, and
//! reading an enterprise profile's sign-in settings.
//!
//! These used to be nmcli, which takes a password only as an argument, so
//! for the moment it ran the password could be read in /proc by anything
//! else of yours. Here it arrives on the daemon's stdin and goes straight to
//! NetworkManager.
//!
//! Each command carries an `id`, and gets one answer when it is over — for
//! a join, once the connection is up or has failed, the way `nmcli
//! connection up` waits:
//!
//! Commands:  net-up {id, uuid, secret?}         a saved network; a secret
//!                                               given replaces its password
//!            net-join {id, ssid, secret?, hidden?}
//!            net-enterprise {id, ssid, uuid?, secret?, hidden?, eap, phase2,
//!                            identity, anonymous, domain, ca}
//!            net-forget {id, uuid}
//!            net-autoconnect {id, uuid, on}
//!            net-disconnect {id}
//!            net-vpn {id, on}
//!            net-secret {id, uuid, key: "psk" | "password", secret}
//!            net-profile {id, uuid}
//! Events:    net-done {id, ok, error}
//!            net-profile {uuid, eap, phase2, identity, anonymous, domain,
//!                         ca, systemCa}
//!
//! A new network that will not come up is removed again, as nmcli does: a
//! profile with a wrong password would otherwise be retried for ever.

use crate::out;
use serde_json::{json, Value as Json};
use std::collections::HashMap;
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use zbus::blocking::Connection;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

const NM: &str = "org.freedesktop.NetworkManager";
const NM_PATH: &str = "/org/freedesktop/NetworkManager";
const SETTINGS: &str = "/org/freedesktop/NetworkManager/Settings";
const S_IFACE: &str = "org.freedesktop.NetworkManager.Settings";
const C_IFACE: &str = "org.freedesktop.NetworkManager.Settings.Connection";
const DEV_IFACE: &str = "org.freedesktop.NetworkManager.Device";
const ACTIVE_IFACE: &str = "org.freedesktop.NetworkManager.Connection.Active";

type Section = HashMap<String, OwnedValue>;
type Settings = HashMap<String, Section>;

fn ov<'a>(v: impl Into<Value<'a>>) -> OwnedValue {
    OwnedValue::try_from(v.into()).expect("no file descriptors here")
}
fn root() -> ObjectPath<'static> {
    ObjectPath::from_static_str_unchecked("/")
}
fn str_of(v: Option<&OwnedValue>) -> String {
    match v.map(|v| &**v) {
        Some(Value::Str(s)) => s.to_string(),
        _ => String::new(),
    }
}
fn bytes_of(v: Option<&OwnedValue>) -> Vec<u8> {
    match v.map(|v| &**v) {
        Some(Value::Array(a)) => a.iter().filter_map(|x| if let Value::U8(b) = x { Some(*b) } else { None }).collect(),
        _ => Vec::new(),
    }
}

/// What nmcli says for a device that failed, so the shell's explanations
/// (Network.qml's explain()) read the same either way.
fn device_reason(r: u32) -> String {
    match r {
        4 => "Configuration failed",
        5 => "IP configuration could not be reserved (no available address, timeout, etc.)",
        6 => "The IP configuration is no longer valid",
        7 => "Secrets were required, but not provided",
        8 => "802.1X supplicant disconnected",
        9 => "802.1X supplicant configuration failed",
        10 => "802.1X supplicant failed",
        11 => "802.1X supplicant took too long to authenticate",
        15 => "DHCP client failed to start",
        16 => "DHCP client error",
        17 => "DHCP client failed",
        36 => "The device was removed",
        53 => "The Wi-Fi network could not be found",
        _ => return format!("Connection activation failed (reason {r})"),
    }
    .to_string()
}
fn active_reason(r: u32) -> String {
    match r {
        2 => "Disconnected by user",
        5 => "IP configuration could not be reserved (no available address, timeout, etc.)",
        6 => "The connection timed out",
        9 => "Secrets were required, but not provided",
        10 => "Login failed",
        11 => "The connection was removed",
        _ => return format!("Connection activation failed (reason {r})"),
    }
    .to_string()
}

/// Why things failed, as NetworkManager announces it: the reason a device
/// went to "failed", and the reason an activation ended. Read by wait().
#[derive(Default)]
struct Reasons {
    device: HashMap<String, u32>,
    active: HashMap<String, u32>,
}

fn listen(conn: Connection, reasons: Arc<Mutex<Reasons>>) {
    std::thread::spawn(move || {
        let Ok(rule) = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender(NM)
            .and_then(|b| b.member("StateChanged"))
            .map(|b| b.build())
        else {
            return;
        };
        let Ok(iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(64)) else { return };
        for msg in iter.flatten() {
            let h = msg.header();
            let path = h.path().map(|p| p.to_string()).unwrap_or_default();
            match h.interface().map(|i| i.to_string()).as_deref() {
                Some(DEV_IFACE) => {
                    if let Ok((new, _old, reason)) = msg.body().deserialize::<(u32, u32, u32)>() {
                        // 120: failed.
                        if new == 120 {
                            reasons.lock().unwrap().device.insert(path, reason);
                        }
                    }
                }
                Some(ACTIVE_IFACE) => {
                    if let Ok((state, reason)) = msg.body().deserialize::<(u32, u32)>() {
                        // 4: deactivated.
                        if state == 4 {
                            reasons.lock().unwrap().active.insert(path, reason);
                        }
                    }
                }
                _ => {}
            }
        }
    });
}

struct Act {
    conn: Connection,
    reasons: Arc<Mutex<Reasons>>,
}

impl Act {
    fn get(&self, path: &str, iface: &str, prop: &str) -> zbus::Result<OwnedValue> {
        let m = self.conn.call_method(Some(NM), path, Some("org.freedesktop.DBus.Properties"), "Get", &(iface, prop))?;
        m.body().deserialize::<OwnedValue>()
    }
    fn paths(&self, path: &str, iface: &str, prop: &str) -> Vec<String> {
        match self.get(path, iface, prop).as_deref() {
            Ok(Value::Array(a)) => a.iter().filter_map(|v| if let Value::ObjectPath(p) = v { Some(p.to_string()) } else { None }).collect(),
            _ => Vec::new(),
        }
    }
    fn u32(&self, path: &str, iface: &str, prop: &str) -> Option<u32> {
        match self.get(path, iface, prop).ok().as_deref() {
            Some(Value::U32(n)) => Some(*n),
            _ => None,
        }
    }

    fn wifi_device(&self) -> zbus::Result<String> {
        let m = self.conn.call_method(Some(NM), NM_PATH, Some(NM), "GetDevices", &())?;
        let devs: Vec<OwnedObjectPath> = m.body().deserialize()?;
        for d in devs {
            if self.u32(d.as_str(), DEV_IFACE, "DeviceType") == Some(2) {
                return Ok(d.to_string());
            }
        }
        Err(zbus::Error::Failure("No Wi-Fi device found".into()))
    }

    /// The strongest access point with this name, if one is in range.
    fn ap_for(&self, dev: &str, ssid: &str) -> Option<String> {
        let mut best: Option<(u8, String)> = None;
        for ap in self.paths(dev, "org.freedesktop.NetworkManager.Device.Wireless", "AccessPoints") {
            let name = match self.get(&ap, "org.freedesktop.NetworkManager.AccessPoint", "Ssid") {
                Ok(v) => bytes_of(Some(&v)),
                Err(_) => continue,
            };
            if name != ssid.as_bytes() {
                continue;
            }
            let strength = match self.get(&ap, "org.freedesktop.NetworkManager.AccessPoint", "Strength").as_deref() {
                Ok(Value::U8(s)) => *s,
                _ => 0,
            };
            if best.as_ref().map(|b| strength > b.0).unwrap_or(true) {
                best = Some((strength, ap));
            }
        }
        best.map(|b| b.1)
    }

    fn connection_for(&self, uuid: &str) -> zbus::Result<String> {
        let m = self.conn.call_method(Some(NM), SETTINGS, Some(S_IFACE), "GetConnectionByUuid", &(uuid,))?;
        Ok(m.body().deserialize::<OwnedObjectPath>()?.to_string())
    }
    fn settings(&self, path: &str) -> zbus::Result<Settings> {
        let m = self.conn.call_method(Some(NM), path, Some(C_IFACE), "GetSettings", &())?;
        m.body().deserialize()
    }
    /// Writes a profile back. GetSettings hands out each IP setting twice,
    /// in the old form and the new; sent back with both, NetworkManager
    /// takes the old one and ignores the new, so the old goes.
    fn update(&self, path: &str, mut s: Settings) -> zbus::Result<()> {
        for ip in ["ipv4", "ipv6"] {
            if let Some(sec) = s.get_mut(ip) {
                if sec.contains_key("address-data") {
                    sec.remove("addresses");
                }
                if sec.contains_key("route-data") {
                    sec.remove("routes");
                }
            }
        }
        self.conn.call_method(Some(NM), path, Some(C_IFACE), "Update", &(s,))?;
        Ok(())
    }

    /// Until the activation is up (Ok) or over (Err, in words). nmcli
    /// waits 90 seconds, which leaves room for the password agent to ask.
    fn wait(&self, active: &str, dev: Option<&str>) -> Result<(), String> {
        let deadline = Instant::now() + Duration::from_secs(90);
        loop {
            if let Some(d) = dev {
                if let Some(r) = self.reasons.lock().unwrap().device.remove(d) {
                    return Err(device_reason(r));
                }
            }
            match self.u32(active, ACTIVE_IFACE, "State") {
                Some(2) => return Ok(()),
                Some(3) | Some(4) | None => {
                    // Over: the device's reason says more than the
                    // activation's, and arrives a moment later.
                    std::thread::sleep(Duration::from_millis(300));
                    let mut r = self.reasons.lock().unwrap();
                    if let Some(d) = dev.and_then(|d| r.device.remove(d)) {
                        return Err(device_reason(d));
                    }
                    if let Some(a) = r.active.remove(active) {
                        return Err(active_reason(a));
                    }
                    return Err("Connection activation failed".into());
                }
                _ => {}
            }
            if Instant::now() > deadline {
                return Err("Timed out waiting for the connection to come up".into());
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }

    fn clear_reasons(&self, dev: &str) {
        self.reasons.lock().unwrap().device.remove(dev);
    }

    fn activate(&self, conn: &str, dev: &str) -> Result<(), String> {
        self.clear_reasons(dev);
        let m = self
            .conn
            .call_method(Some(NM), NM_PATH, Some(NM), "ActivateConnection", &(ObjectPath::try_from(conn).map_err(|e| e.to_string())?, ObjectPath::try_from(dev).map_err(|e| e.to_string())?, root()))
            .map_err(err)?;
        let active: OwnedObjectPath = m.body().deserialize().map_err(err)?;
        self.wait(active.as_str(), Some(dev))
    }

    /// A new profile, brought up; removed again if it does not come up.
    fn add_and_activate(&self, s: Settings, dev: &str, ap: Option<&str>) -> Result<(), String> {
        self.clear_reasons(dev);
        let ap = match ap {
            Some(a) => ObjectPath::try_from(a).map_err(|e| e.to_string())?,
            None => root(),
        };
        let m = self
            .conn
            .call_method(Some(NM), NM_PATH, Some(NM), "AddAndActivateConnection", &(s, ObjectPath::try_from(dev).map_err(|e| e.to_string())?, ap))
            .map_err(err)?;
        let (path, active): (OwnedObjectPath, OwnedObjectPath) = m.body().deserialize().map_err(err)?;
        let r = self.wait(active.as_str(), Some(dev));
        if r.is_err() {
            let _ = self.conn.call_method(Some(NM), path.as_str(), Some(C_IFACE), "Delete", &());
        }
        r
    }

    fn wireless(ssid: &str, hidden: bool) -> Section {
        let mut w = Section::new();
        w.insert("ssid".into(), ov(ssid.as_bytes().to_vec()));
        w.insert("mode".into(), ov("infrastructure"));
        if hidden {
            w.insert("hidden".into(), ov(true));
        }
        w
    }
    fn connection(ssid: &str) -> Section {
        let mut c = Section::new();
        c.insert("id".into(), ov(ssid));
        c.insert("type".into(), ov("802-11-wireless"));
        c
    }

    fn up(&self, c: &Json) -> Result<(), String> {
        let uuid = c["uuid"].as_str().unwrap_or("");
        let path = self.connection_for(uuid).map_err(err)?;
        if let Some(secret) = c["secret"].as_str().filter(|s| !s.is_empty()) {
            let mut s = self.settings(&path).map_err(err)?;
            let enterprise = s.contains_key("802-1x");
            let (sec, key) = if enterprise { ("802-1x", "password") } else { ("802-11-wireless-security", "psk") };
            let e = s.entry(sec.to_string()).or_default();
            e.insert(key.into(), ov(secret));
            e.insert(format!("{key}-flags"), ov(0u32));
            self.update(&path, s).map_err(err)?;
        }
        let dev = self.wifi_device().map_err(err)?;
        self.activate(&path, &dev)
    }

    fn join(&self, c: &Json) -> Result<(), String> {
        let ssid = c["ssid"].as_str().unwrap_or("");
        let hidden = c["hidden"].as_bool().unwrap_or(false);
        let secret = c["secret"].as_str().unwrap_or("");
        let dev = self.wifi_device().map_err(err)?;
        let ap = if hidden { None } else { self.ap_for(&dev, ssid) };
        if !hidden && ap.is_none() {
            return Err(format!("No network with SSID '{ssid}' found"));
        }
        let mut s = Settings::new();
        s.insert("connection".into(), Self::connection(ssid));
        s.insert("802-11-wireless".into(), Self::wireless(ssid, hidden));
        if !secret.is_empty() {
            let mut sec = Section::new();
            // With the network in range NetworkManager works out the kind
            // (WPA2, WPA3) from it, as it does for nmcli; a hidden one is
            // taken to be WPA2/3 personal.
            sec.insert("psk".into(), ov(secret));
            if hidden {
                sec.insert("key-mgmt".into(), ov("wpa-psk"));
            }
            s.insert("802-11-wireless-security".into(), sec);
        }
        self.add_and_activate(s, &dev, ap.as_deref())
    }

    /// The sign-in a university or office network takes: the method, the
    /// inner method, who you are, and how the server is checked.
    fn eap_section(c: &Json, mut x: Section) -> Section {
        let eap = c["eap"].as_str().filter(|s| !s.is_empty()).unwrap_or("peap");
        x.insert("eap".into(), ov(vec![eap.to_string()]));
        let phase2 = c["phase2"].as_str().unwrap_or("");
        x.remove("phase2-autheap");
        if eap == "pwd" || phase2.is_empty() {
            x.remove("phase2-auth");
        } else {
            x.insert("phase2-auth".into(), ov(phase2));
        }
        for (field, key) in [("identity", "identity"), ("anonymous", "anonymous-identity"), ("domain", "domain-suffix-match")] {
            match c[field].as_str().map(str::trim).filter(|v| !v.is_empty()) {
                Some(v) => {
                    x.insert(key.into(), ov(v));
                }
                None => {
                    x.remove(key);
                }
            }
        }
        let ca = c["ca"].as_str().unwrap_or("none");
        x.insert("system-ca-certs".into(), ov(ca == "system"));
        if ca != "none" && ca != "system" && !ca.is_empty() {
            // A file, as NetworkManager spells one: its URI, NUL-ended.
            let mut b = format!("file://{ca}").into_bytes();
            b.push(0);
            x.insert("ca-cert".into(), ov(b));
        } else {
            x.remove("ca-cert");
        }
        if let Some(pw) = c["secret"].as_str().filter(|s| !s.is_empty()) {
            x.insert("password".into(), ov(pw));
        }
        x.insert("password-flags".into(), ov(0u32));
        x
    }

    fn enterprise(&self, c: &Json) -> Result<(), String> {
        let ssid = c["ssid"].as_str().unwrap_or("");
        let hidden = c["hidden"].as_bool().unwrap_or(false);
        let dev = self.wifi_device().map_err(err)?;
        // A saved profile is changed in place, so whatever else was set on
        // it is kept.
        if let Some(uuid) = c["uuid"].as_str().filter(|u| !u.is_empty()) {
            let path = self.connection_for(uuid).map_err(err)?;
            let mut s = self.settings(&path).map_err(err)?;
            let x = s.remove("802-1x").unwrap_or_default();
            s.insert("802-1x".into(), Self::eap_section(c, x));
            s.entry("802-11-wireless-security".into()).or_default().insert("key-mgmt".into(), ov("wpa-eap"));
            if hidden {
                s.entry("802-11-wireless".into()).or_default().insert("hidden".into(), ov(true));
            }
            self.update(&path, s).map_err(err)?;
            return self.activate(&path, &dev);
        }
        let mut s = Settings::new();
        s.insert("connection".into(), Self::connection(ssid));
        s.insert("802-11-wireless".into(), Self::wireless(ssid, hidden));
        let mut sec = Section::new();
        sec.insert("key-mgmt".into(), ov("wpa-eap"));
        s.insert("802-11-wireless-security".into(), sec);
        s.insert("802-1x".into(), Self::eap_section(c, Section::new()));
        let ap = if hidden { None } else { self.ap_for(&dev, ssid) };
        self.add_and_activate(s, &dev, ap.as_deref())
    }

    fn forget(&self, c: &Json) -> Result<(), String> {
        let path = self.connection_for(c["uuid"].as_str().unwrap_or("")).map_err(err)?;
        self.conn.call_method(Some(NM), path.as_str(), Some(C_IFACE), "Delete", &()).map_err(err)?;
        Ok(())
    }

    fn autoconnect(&self, c: &Json) -> Result<(), String> {
        let path = self.connection_for(c["uuid"].as_str().unwrap_or("")).map_err(err)?;
        let mut s = self.settings(&path).map_err(err)?;
        s.entry("connection".into()).or_default().insert("autoconnect".into(), ov(c["on"].as_bool().unwrap_or(true)));
        self.update(&path, s).map_err(err)
    }

    fn disconnect(&self) -> Result<(), String> {
        let dev = self.wifi_device().map_err(err)?;
        self.conn.call_method(Some(NM), dev.as_str(), Some(DEV_IFACE), "Disconnect", &()).map_err(err)?;
        Ok(())
    }

    fn vpn(&self, c: &Json) -> Result<(), String> {
        let is_vpn = |t: &str| t == "vpn" || t == "wireguard";
        if !c["on"].as_bool().unwrap_or(false) {
            for a in self.paths(NM_PATH, NM, "ActiveConnections") {
                let t = self.get(&a, ACTIVE_IFACE, "Type").map(|v| str_of(Some(&v))).unwrap_or_default();
                if is_vpn(&t) {
                    let p = ObjectPath::try_from(a.as_str()).map_err(|e| e.to_string())?;
                    self.conn.call_method(Some(NM), NM_PATH, Some(NM), "DeactivateConnection", &(p,)).map_err(err)?;
                }
            }
            return Ok(());
        }
        // The first VPN profile there is.
        let m = self.conn.call_method(Some(NM), SETTINGS, Some(S_IFACE), "ListConnections", &()).map_err(err)?;
        let list: Vec<OwnedObjectPath> = m.body().deserialize().map_err(err)?;
        for p in list {
            let Ok(s) = self.settings(p.as_str()) else { continue };
            if is_vpn(&str_of(s.get("connection").and_then(|c| c.get("type")))) {
                let m = self
                    .conn
                    .call_method(Some(NM), NM_PATH, Some(NM), "ActivateConnection", &(p.clone(), root(), root()))
                    .map_err(err)?;
                let active: OwnedObjectPath = m.body().deserialize().map_err(err)?;
                return self.wait(active.as_str(), None);
            }
        }
        Err("No VPN is set up".into())
    }

    fn secret(&self, c: &Json) -> Result<(), String> {
        let path = self.connection_for(c["uuid"].as_str().unwrap_or("")).map_err(err)?;
        let mut s = self.settings(&path).map_err(err)?;
        let (sec, key) = if c["key"] == "password" { ("802-1x", "password") } else { ("802-11-wireless-security", "psk") };
        let e = s.entry(sec.to_string()).or_default();
        e.insert(key.into(), ov(c["secret"].as_str().unwrap_or("")));
        e.insert(format!("{key}-flags"), ov(0u32));
        self.update(&path, s).map_err(err)
    }

    fn profile(&self, c: &Json) -> Result<(), String> {
        let uuid = c["uuid"].as_str().unwrap_or("");
        let path = self.connection_for(uuid).map_err(err)?;
        let s = self.settings(&path).map_err(err)?;
        let empty = Section::new();
        let x = s.get("802-1x").unwrap_or(&empty);
        let eap = match x.get("eap").map(|v| &**v) {
            Some(Value::Array(a)) => a.iter().find_map(|v| if let Value::Str(s) = v { Some(s.to_string()) } else { None }).unwrap_or_default(),
            _ => String::new(),
        };
        let phase2 = { let p = str_of(x.get("phase2-auth")); if p.is_empty() { str_of(x.get("phase2-autheap")) } else { p } };
        let mut ca = String::from_utf8_lossy(&bytes_of(x.get("ca-cert"))).trim_end_matches('\0').to_string();
        if let Some(rest) = ca.strip_prefix("file://") {
            ca = rest.to_string();
        }
        out::emit(json!({
            "ev": "net-profile", "uuid": uuid, "eap": eap, "phase2": phase2,
            "identity": str_of(x.get("identity")), "anonymous": str_of(x.get("anonymous-identity")),
            "domain": str_of(x.get("domain-suffix-match")), "ca": ca,
            "systemCa": matches!(x.get("system-ca-certs").map(|v| &**v), Some(Value::Bool(true)))
        }));
        Ok(())
    }

    fn run(&self, c: &Json) -> Result<(), String> {
        match c["cmd"].as_str().unwrap_or("") {
            "net-up" => self.up(c),
            "net-join" => self.join(c),
            "net-enterprise" => self.enterprise(c),
            "net-forget" => self.forget(c),
            "net-autoconnect" => self.autoconnect(c),
            "net-disconnect" => self.disconnect(),
            "net-vpn" => self.vpn(c),
            "net-secret" => self.secret(c),
            "net-profile" => self.profile(c),
            other => Err(format!("unknown command {other}")),
        }
    }
}

/// A D-Bus error as its message: "org.freedesktop.NetworkManager.
/// PermissionDenied: Not authorized…" reads better without the name.
fn err(e: zbus::Error) -> String {
    match e {
        zbus::Error::MethodError(name, Some(desc), _) => {
            let n = name.as_str();
            if n.ends_with("InvalidProperty") || n.ends_with("InvalidSetting") {
                format!("invalid property: {desc}")
            } else {
                desc
            }
        }
        zbus::Error::MethodError(name, None, _) => name.to_string(),
        e => e.to_string(),
    }
}

pub fn is_action(cmd: &str) -> bool {
    matches!(
        cmd,
        "net-up" | "net-join" | "net-enterprise" | "net-forget" | "net-autoconnect" | "net-disconnect" | "net-vpn" | "net-secret" | "net-profile"
    )
}

/// One at a time, in order, on a thread of their own: a join can take a
/// minute, and the network's state keeps being read meanwhile.
pub fn worker(rx: Receiver<Json>) {
    std::thread::spawn(move || {
        let mut act: Option<Act> = None;
        for c in rx {
            if act.is_none() {
                if let Ok(conn) = Connection::system() {
                    let reasons = Arc::new(Mutex::new(Reasons::default()));
                    listen(conn.clone(), reasons.clone());
                    act = Some(Act { conn, reasons });
                }
            }
            let r = match &act {
                Some(a) => a.run(&c),
                None => Err("NetworkManager can't be reached".into()),
            };
            if let Err(e) = &r {
                // A lost bus: connect again next time.
                if e.contains("Connection reset") || e.contains("Broken pipe") || e.contains("ServiceUnknown") {
                    act = None;
                }
            }
            out::emit(json!({ "ev": "net-done", "id": c["id"], "cmd": c["cmd"], "ok": r.is_ok(), "error": r.err().unwrap_or_default() }));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eap() {
        let c = json!({ "eap": "ttls", "phase2": "pap", "identity": " me@uni ", "anonymous": "", "domain": "uni.edu", "ca": "/etc/ssl/uni.pem", "secret": "pw" });
        let mut old = Section::new();
        old.insert("anonymous-identity".into(), ov("old"));
        old.insert("phase2-autheap".into(), ov("mschapv2"));
        let x = Act::eap_section(&c, old);
        assert_eq!(str_of(x.get("identity")), "me@uni");
        assert_eq!(str_of(x.get("phase2-auth")), "pap");
        assert!(!x.contains_key("anonymous-identity"));
        assert!(!x.contains_key("phase2-autheap"));
        assert_eq!(bytes_of(x.get("ca-cert")), b"file:///etc/ssl/uni.pem\0".to_vec());
        assert_eq!(str_of(x.get("password")), "pw");
        let pwd = Act::eap_section(&json!({ "eap": "pwd", "phase2": "mschapv2", "ca": "system" }), Section::new());
        assert!(!pwd.contains_key("phase2-auth"));
        assert!(matches!(pwd.get("system-ca-certs").map(|v| &**v), Some(Value::Bool(true))));
    }
}
