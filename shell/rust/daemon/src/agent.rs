//! Bluetooth from BlueZ —
//! the adapter, its devices, power, discovery, pair, connect, trust, remove —
//! with a pairing agent BlueZ can ask "does 123456 match?", "what PIN?",
//! "may this phone pair?"; and a NetworkManager secret agent, asked for a
//! password NetworkManager hasn't got.
//!
//! The same JSON as the C++ agent, so services/Bluetooth.qml and
//! Network.qml don't know which one answered (Agent.qml picks): commands
//! bt-* and nm-*, events bt, bt-busy, bt-done, bt-error, bt-request,
//! bt-display, bt-cancel, bt-agent, nm-agent, nm-secrets, nm-cancel.
//!
//! A question is a D-Bus call held open: the agent method awaits a oneshot
//! channel that bt-reply / nm-reply completes, or Cancel drops.
//!
//! HYPRSHELL_AGENT_BUS=session runs it against the session bus, for testing
//! with a stand-in BlueZ and NetworkManager.

use crate::out;
use futures_channel::oneshot;
use serde_json::{json, Value as Json};
use std::collections::{BTreeMap, HashMap};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use zbus::blocking::Connection;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

const BLUEZ: &str = "org.bluez";
const NM: &str = "org.freedesktop.NetworkManager";
const AGENT_PATH: &str = "/org/hyprshell/agent/bluez";
const NM_AGENT_PATH: &str = "/org/freedesktop/NetworkManager/SecretAgent";

type Props = HashMap<String, OwnedValue>;

fn mac_from_path(path: &str) -> String {
    path.rfind("/dev_").map(|i| path[i + 5..].replace('_', ":")).unwrap_or_default()
}
fn s(p: &Props, k: &str) -> Option<String> {
    match p.get(k).map(|v| &**v) {
        Some(Value::Str(x)) => Some(x.to_string()),
        Some(Value::ObjectPath(x)) => Some(x.to_string()),
        _ => None,
    }
}
fn b(p: &Props, k: &str) -> bool {
    matches!(p.get(k).map(|v| &**v), Some(Value::Bool(true)))
}
fn int(p: &Props, k: &str) -> Option<i64> {
    match p.get(k).map(|v| &**v) {
        Some(Value::U8(x)) => Some(*x as i64),
        Some(Value::I16(x)) => Some(*x as i64),
        Some(Value::U16(x)) => Some(*x as i64),
        Some(Value::I32(x)) => Some(*x as i64),
        Some(Value::U32(x)) => Some(*x as i64),
        _ => None,
    }
}

// ══ state ═══════════════════════════════════════════════════════════════

#[derive(Default)]
struct Bt {
    running: bool,
    adapters: BTreeMap<String, Props>,
    devices: BTreeMap<String, Props>,
    battery: BTreeMap<String, i64>,
}

impl Bt {
    fn adapter_path(&self) -> Option<String> {
        if self.adapters.contains_key("/org/bluez/hci0") {
            return Some("/org/bluez/hci0".into());
        }
        self.adapters.keys().next().cloned()
    }
    fn path_for(&self, mac: &str) -> Option<String> {
        self.devices
            .iter()
            .find(|(_, d)| s(d, "Address").map(|a| a.eq_ignore_ascii_case(mac)).unwrap_or(false))
            .map(|(p, _)| p.clone())
    }
    fn name(&self, path: &str) -> String {
        let d = self.devices.get(path);
        d.and_then(|d| s(d, "Alias").or_else(|| s(d, "Name"))).unwrap_or_else(|| mac_from_path(path))
    }
    fn absorb(&mut self, path: &str, ifaces: &HashMap<String, Props>) {
        if let Some(a) = ifaces.get("org.bluez.Adapter1") {
            self.adapters.insert(path.into(), clone_props(a));
        }
        if let Some(d) = ifaces.get("org.bluez.Device1") {
            self.devices.insert(path.into(), clone_props(d));
        }
        if let Some(bat) = ifaces.get("org.bluez.Battery1") {
            self.battery.insert(path.into(), int(bat, "Percentage").unwrap_or(-1));
        }
    }
    fn snapshot(&self) -> Json {
        let ap = self.adapter_path();
        let mut ev = json!({ "ev": "bt", "available": self.running && !self.adapters.is_empty() });
        if let Some(ap) = &ap {
            let a = &self.adapters[ap];
            ev["adapter"] = json!({
                "path": ap,
                "name": s(a, "Alias").or_else(|| s(a, "Name")).unwrap_or_default(),
                "address": s(a, "Address").unwrap_or_default(),
                "powered": b(a, "Powered"), "discoverable": b(a, "Discoverable"),
                "discovering": b(a, "Discovering"), "pairable": b(a, "Pairable")
            });
        }
        let mut devs = Vec::new();
        for (path, d) in &self.devices {
            if let (Some(ap), Some(owner)) = (&ap, s(d, "Adapter")) {
                if &owner != ap {
                    continue;
                }
            }
            let mac = s(d, "Address").unwrap_or_default();
            let mut o = json!({
                "path": path, "mac": mac,
                "name": s(d, "Alias").or_else(|| s(d, "Name")).unwrap_or_else(|| mac.clone()),
                // Said what it is called, as against known only by address.
                "named": d.contains_key("Name"),
                "icon": s(d, "Icon").unwrap_or_default(),
                "paired": b(d, "Paired") || b(d, "Bonded"),
                "trusted": b(d, "Trusted"), "connected": b(d, "Connected"), "blocked": b(d, "Blocked"),
                "battery": self.battery.get(path).copied().unwrap_or(-1)
            });
            if let Some(r) = int(d, "RSSI") {
                o["rssi"] = json!(r);
            }
            devs.push(o);
        }
        ev["devices"] = Json::Array(devs);
        ev
    }
}

fn clone_props(p: &Props) -> Props {
    p.iter().filter_map(|(k, v)| v.try_clone().ok().map(|v| (k.clone(), v))).collect()
}

enum Answer {
    Accept(String),
    Reject,
}

#[derive(Default)]
struct Pending {
    next: u32,
    bt: HashMap<u32, (String, oneshot::Sender<Answer>)>,
    nm: HashMap<u32, (String, String, oneshot::Sender<Option<HashMap<String, String>>>)>,
}

type Shared<T> = Arc<Mutex<T>>;

// ══ org.bluez.Agent1 ═════════════════════════════════════════════════════

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.bluez.Error")]
enum BzError {
    #[zbus(error)]
    ZBus(zbus::Error),
    Rejected(String),
    Canceled(String),
}

struct BtAgent {
    bt: Shared<Bt>,
    pend: Shared<Pending>,
}

impl BtAgent {
    async fn hold(&self, kind: &str, device: &OwnedObjectPath, extra: Json) -> Result<String, BzError> {
        let (tx, rx) = oneshot::channel();
        let id = {
            let mut p = self.pend.lock().unwrap();
            p.next += 1;
            let id = p.next;
            p.bt.insert(id, (kind.to_string(), tx));
            id
        };
        let mut ev = json!({
            "ev": "bt-request", "id": id, "kind": kind,
            "mac": mac_from_path(device.as_str()), "name": self.bt.lock().unwrap().name(device.as_str())
        });
        if let Json::Object(m) = extra {
            for (k, v) in m {
                ev[k] = v;
            }
        }
        out::emit(ev);
        match rx.await {
            Ok(Answer::Accept(v)) => Ok(v),
            Ok(Answer::Reject) => Err(BzError::Rejected("Rejected".into())),
            Err(_) => Err(BzError::Canceled("Canceled".into())),
        }
    }
    fn display(&self, kind: &str, device: &OwnedObjectPath, code: String, entered: Option<u16>) {
        let mut ev = json!({
            "ev": "bt-display", "kind": kind, "code": code,
            "mac": mac_from_path(device.as_str()), "name": self.bt.lock().unwrap().name(device.as_str())
        });
        if let Some(e) = entered {
            ev["entered"] = json!(e);
        }
        out::emit(ev);
    }
}

#[zbus::interface(name = "org.bluez.Agent1")]
impl BtAgent {
    fn release(&self) {}
    async fn request_pin_code(&self, device: OwnedObjectPath) -> Result<String, BzError> {
        self.hold("pin", &device, json!({})).await
    }
    fn display_pin_code(&self, device: OwnedObjectPath, pincode: String) {
        self.display("pin", &device, pincode, None);
    }
    async fn request_passkey(&self, device: OwnedObjectPath) -> Result<u32, BzError> {
        Ok(self.hold("passkey", &device, json!({})).await?.trim().parse().unwrap_or(0))
    }
    fn display_passkey(&self, device: OwnedObjectPath, passkey: u32, entered: u16) {
        self.display("passkey", &device, format!("{passkey:06}"), Some(entered));
    }
    async fn request_confirmation(&self, device: OwnedObjectPath, passkey: u32) -> Result<(), BzError> {
        self.hold("confirm", &device, json!({ "passkey": format!("{passkey:06}") })).await.map(|_| ())
    }
    async fn request_authorization(&self, device: OwnedObjectPath) -> Result<(), BzError> {
        self.hold("authorize", &device, json!({})).await.map(|_| ())
    }
    async fn authorize_service(&self, device: OwnedObjectPath, uuid: String) -> Result<(), BzError> {
        // A device already trusted is allowed its services without asking.
        let trusted = self.bt.lock().unwrap().devices.get(device.as_str()).map(|d| b(d, "Trusted")).unwrap_or(false);
        if trusted {
            return Ok(());
        }
        self.hold("service", &device, json!({ "uuid": uuid })).await.map(|_| ())
    }
    fn cancel(&self) {
        // BlueZ cancels whatever it asked last; dropping the senders makes
        // every held call return Canceled.
        self.pend.lock().unwrap().bt.clear();
        out::emit(json!({ "ev": "bt-cancel" }));
    }
}

// ══ NetworkManager secret agent ═════════════════════════════════════════

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.NetworkManager.SecretAgent")]
enum NmError {
    #[zbus(error)]
    ZBus(zbus::Error),
    UserCanceled(String),
    NoSecrets(String),
    AgentCanceled(String),
}

type Settings = HashMap<String, HashMap<String, OwnedValue>>;

struct SecretAgent {
    pend: Shared<Pending>,
}

fn sv(m: Option<&HashMap<String, OwnedValue>>, k: &str) -> String {
    match m.and_then(|m| m.get(k)).map(|v| &**v) {
        Some(Value::Str(x)) => x.to_string(),
        Some(Value::Array(a)) => {
            // ay (an SSID)
            let bytes: Vec<u8> = a.iter().filter_map(|v| if let Value::U8(b) = v { Some(*b) } else { None }).collect();
            String::from_utf8_lossy(&bytes).to_string()
        }
        _ => String::new(),
    }
}
fn sl(m: Option<&HashMap<String, OwnedValue>>, k: &str) -> Vec<String> {
    match m.and_then(|m| m.get(k)).map(|v| &**v) {
        Some(Value::Array(a)) => a.iter().filter_map(|v| if let Value::Str(s) = v { Some(s.to_string()) } else { None }).collect(),
        _ => Vec::new(),
    }
}

#[zbus::interface(name = "org.freedesktop.NetworkManager.SecretAgent")]
impl SecretAgent {
    async fn get_secrets(
        &self,
        connection: Settings,
        connection_path: OwnedObjectPath,
        setting_name: String,
        hints: Vec<String>,
        flags: u32,
    ) -> Result<Settings, NmError> {
        let con = connection.get("connection");
        let wifi = connection.get("802-11-wireless");
        let sec = connection.get("802-11-wireless-security");
        let x = connection.get("802-1x");
        let key_mgmt = sv(sec, "key-mgmt");
        let eap = sl(x, "eap");

        let mut fields: Vec<&str> = Vec::new();
        if setting_name == "802-11-wireless-security" {
            if key_mgmt == "wpa-psk" || key_mgmt == "sae" {
                fields.push("psk");
            } else if key_mgmt == "none" {
                fields.push("wep-key0");
            }
        } else if setting_name == "802-1x" {
            fields.push(if eap.len() == 1 && eap[0] == "tls" { "private-key-password" } else { "password" });
        }
        // ALLOW_INTERACTION: without it only stored secrets may be given,
        // and this agent stores none.
        if fields.is_empty() || flags & 0x1 == 0 {
            return Err(NmError::NoSecrets("No secrets".into()));
        }

        let (tx, rx) = oneshot::channel();
        let id = {
            let mut p = self.pend.lock().unwrap();
            p.next += 1;
            let id = p.next;
            p.nm.insert(id, (setting_name.clone(), connection_path.to_string(), tx));
            id
        };
        out::emit(json!({
            "ev": "nm-secrets", "id": id,
            "name": sv(con, "id"), "uuid": sv(con, "uuid"), "type": sv(con, "type"),
            "ssid": sv(wifi, "ssid"), "setting": setting_name, "keyMgmt": key_mgmt,
            "eap": eap, "identity": sv(x, "identity"), "fields": fields, "hints": hints,
            // REQUEST_NEW: what was saved did not work.
            "again": flags & 0x2 != 0
        }));
        match rx.await {
            Ok(Some(secrets)) if !secrets.is_empty() => {
                let mut inner: HashMap<String, OwnedValue> = HashMap::new();
                for (k, v) in secrets {
                    if let Ok(v) = OwnedValue::try_from(Value::from(v)) {
                        inner.insert(k, v);
                    }
                }
                let mut outm = Settings::new();
                outm.insert(setting_name, inner);
                Ok(outm)
            }
            Ok(_) => Err(NmError::UserCanceled("Canceled".into())),
            Err(_) => Err(NmError::AgentCanceled("Canceled".into())),
        }
    }

    fn cancel_get_secrets(&self, connection_path: OwnedObjectPath, setting_name: String) {
        let mut p = self.pend.lock().unwrap();
        let ids: Vec<u32> = p.nm.iter().filter(|(_, (st, path, _))| *st == setting_name && *path == connection_path.as_str()).map(|(id, _)| *id).collect();
        for id in ids {
            p.nm.remove(&id); // dropping the sender: AgentCanceled
            out::emit(json!({ "ev": "nm-cancel", "id": id }));
        }
    }

    // NetworkManager keeps the secrets itself; nothing to save or delete.
    fn save_secrets(&self, _connection: Settings, _connection_path: OwnedObjectPath) {}
    fn delete_secrets(&self, _connection: Settings, _connection_path: OwnedObjectPath) {}
}

// ══ the work ════════════════════════════════════════════════════════════

fn err_parts(e: &zbus::Error) -> (String, String) {
    match e {
        zbus::Error::MethodError(name, desc, _) => (name.to_string(), desc.clone().unwrap_or_default()),
        zbus::Error::FDO(f) => (format!("org.freedesktop.DBus.Error.{}", fdo_name(f)), f.to_string()),
        other => ("org.freedesktop.DBus.Error.Failed".into(), other.to_string()),
    }
}
fn fdo_name(e: &zbus::fdo::Error) -> String {
    format!("{e:?}").split('(').next().unwrap_or("Failed").to_string()
}

/// A finished call, reported as the C++ agent did: bt-error + bt-done
/// false on failure, bt-done true (or the next step) on success.
fn report(op: &str, mac: &str, r: zbus::Result<()>) -> bool {
    match r {
        Ok(()) => true,
        Err(e) => {
            let (name, message) = err_parts(&e);
            out::emit(json!({ "ev": "bt-error", "op": op, "mac": mac, "error": name, "message": message }));
            out::emit(json!({ "ev": "bt-done", "op": op, "mac": mac, "ok": false }));
            false
        }
    }
}
fn done(op: &str, mac: &str) {
    out::emit(json!({ "ev": "bt-done", "op": op, "mac": mac, "ok": true }));
}

fn set_prop(conn: &Connection, path: &str, iface: &str, prop: &str, on: bool) -> zbus::Result<()> {
    conn.call_method(Some(BLUEZ), path, Some("org.freedesktop.DBus.Properties"), "Set", &(iface, prop, Value::from(on)))
        .map(|_| ())
}
fn call0(conn: &Connection, path: &str, iface: &str, method: &str) -> zbus::Result<()> {
    conn.call_method(Some(BLUEZ), path, Some(iface), method, &()).map(|_| ())
}

struct Ctx {
    conn: Connection,
    bt: Shared<Bt>,
}

impl Ctx {
    fn adapter(&self) -> Option<String> {
        self.bt.lock().unwrap().adapter_path()
    }
    fn device(&self, mac: &str, op: &str) -> Option<String> {
        let p = self.bt.lock().unwrap().path_for(mac);
        if p.is_none() {
            out::emit(json!({ "ev": "bt-error", "op": op, "mac": mac, "error": "org.bluez.Error.DoesNotExist", "message": "Device is gone" }));
        }
        p
    }
    fn call_device(&self, mac: &str, method: &str, op: &str) -> bool {
        let Some(path) = self.device(mac, op) else { return false };
        out::emit(json!({ "ev": "bt-busy", "op": op, "mac": mac }));
        report(op, mac, call0(&self.conn, &path, "org.bluez.Device1", method))
    }

    fn command(&self, c: &Json) {
        let cmd = c["cmd"].as_str().unwrap_or("");
        let mac = c["mac"].as_str().unwrap_or("").to_string();
        let on = c["on"].as_bool().unwrap_or(false);
        match cmd {
            "bt-power" | "bt-discoverable" => {
                let Some(ap) = self.adapter() else { return };
                let (prop, op) = if cmd == "bt-power" { ("Powered", "power") } else { ("Discoverable", "discoverable") };
                if report(op, "", set_prop(&self.conn, &ap, "org.bluez.Adapter1", prop, on)) {
                    done(op, "");
                }
            }
            "bt-scan" => {
                let Some(ap) = self.adapter() else { return };
                let m = if on { "StartDiscovery" } else { "StopDiscovery" };
                if report("scan", "", call0(&self.conn, &ap, "org.bluez.Adapter1", m)) {
                    done("scan", "");
                }
            }
            "bt-connect" => {
                if self.call_device(&mac, "Connect", "connect") {
                    done("connect", &mac);
                }
            }
            "bt-disconnect" => {
                if self.call_device(&mac, "Disconnect", "disconnect") {
                    done("disconnect", &mac);
                }
            }
            "bt-cancel" => {
                if self.call_device(&mac, "CancelPairing", "cancel") {
                    done("cancel", &mac);
                }
            }
            "bt-trust" => {
                let Some(path) = self.device(&mac, "trust") else { return };
                if report("trust", &mac, set_prop(&self.conn, &path, "org.bluez.Device1", "Trusted", on)) {
                    done("trust", &mac);
                }
            }
            "bt-remove" => {
                let (Some(ap), Some(path)) = (self.adapter(), self.bt.lock().unwrap().path_for(&mac)) else { return };
                let Ok(o) = ObjectPath::try_from(path.as_str()) else { return };
                let r = self.conn.call_method(Some(BLUEZ), ap.as_str(), Some("org.bluez.Adapter1"), "RemoveDevice", &(o,)).map(|_| ());
                if report("remove", &mac, r) {
                    done("remove", &mac);
                }
            }
            "bt-pair" => self.pair(&mac),
            _ => {}
        }
    }

    /// Pair, then trust, then connect: what "pair" means to anyone not
    /// reading BlueZ's documentation. Trusted lets it come back by itself.
    fn pair(&self, mac: &str) {
        let (path, already, discovering, ap) = {
            let bt = self.bt.lock().unwrap();
            let path = bt.path_for(mac);
            let already = path.as_ref().and_then(|p| bt.devices.get(p)).map(|d| b(d, "Paired")).unwrap_or(false);
            let ap = bt.adapter_path();
            let discovering = ap.as_ref().and_then(|a| bt.adapters.get(a)).map(|a| b(a, "Discovering")).unwrap_or(false);
            (path, already, discovering, ap)
        };
        if path.is_none() {
            self.device(mac, "pair");
            return;
        }
        if !already {
            // Discovery competes with pairing for the radio.
            if discovering {
                if let Some(ap) = &ap {
                    let _ = call0(&self.conn, ap, "org.bluez.Adapter1", "StopDiscovery");
                }
            }
            if !self.call_device(mac, "Pair", "pair") {
                return;
            }
        }
        let path = path.unwrap();
        if !report("trust", mac, set_prop(&self.conn, &path, "org.bluez.Device1", "Trusted", true)) {
            return;
        }
        if self.call_device(mac, "Connect", "connect") {
            done("connect", mac);
        }
    }
}

fn load(conn: &Connection, bt: &Shared<Bt>) -> zbus::Result<()> {
    let m = conn.call_method(Some(BLUEZ), "/", Some("org.freedesktop.DBus.ObjectManager"), "GetManagedObjects", &())?;
    let objs: HashMap<OwnedObjectPath, HashMap<String, Props>> = m.body().deserialize()?;
    let mut st = bt.lock().unwrap();
    st.adapters.clear();
    st.devices.clear();
    st.battery.clear();
    for (path, ifaces) in &objs {
        st.absorb(path.as_str(), ifaces);
    }
    st.running = true;
    Ok(())
}

/// KeyboardDisplay: the shell can show a code and take one typed in, so any
/// pairing method a device asks for is on the table.
fn register_bt_agent(conn: &Connection) {
    let me = ObjectPath::try_from(AGENT_PATH).unwrap();
    let r = conn.call_method(Some(BLUEZ), "/org/bluez", Some("org.bluez.AgentManager1"), "RegisterAgent", &(&me, "KeyboardDisplay"));
    if let Err(e) = r {
        let (name, message) = err_parts(&e);
        if name != "org.bluez.Error.AlreadyExists" {
            out::emit(json!({ "ev": "bt-agent", "ok": false, "error": name, "message": message }));
            return;
        }
    }
    // The default agent is the one asked about pairings nobody here started.
    let def = conn.call_method(Some(BLUEZ), "/org/bluez", Some("org.bluez.AgentManager1"), "RequestDefaultAgent", &(&me,));
    out::emit(json!({ "ev": "bt-agent", "ok": true, "default": def.is_ok() }));
}

fn register_nm_agent(conn: &Connection) {
    let r = conn.call_method(Some(NM), "/org/freedesktop/NetworkManager/AgentManager", Some("org.freedesktop.NetworkManager.AgentManager"), "RegisterWithCapabilities", &("org.hyprshell.agent", 0u32));
    let mut ev = json!({ "ev": "nm-agent", "ok": r.is_ok() });
    if let Err(e) = r {
        let (name, message) = err_parts(&e);
        ev["error"] = json!(name);
        ev["message"] = json!(message);
    }
    out::emit(ev);
}

/// BlueZ's signals and the bus's word on services coming and going, as
/// wake-ups.
fn listen(conn: &Connection, rule: zbus::MatchRule<'static>, tag: &'static str, tx: Sender<Json>) {
    let conn = conn.clone();
    std::thread::spawn(move || {
        let Ok(iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(256)) else { return };
        for msg in iter.flatten() {
            if tx.send(json!({ "cmd": tag, "msg": serialize_signal(&msg) })).is_err() {
                return;
            }
        }
    });
}

/// What the state loop needs from a signal, decoded on the listening thread.
fn serialize_signal(msg: &zbus::Message) -> Json {
    let h = msg.header();
    let member = h.member().map(|m| m.to_string()).unwrap_or_default();
    let path = h.path().map(|p| p.to_string()).unwrap_or_default();
    let body = msg.body();
    match member.as_str() {
        "NameOwnerChanged" => {
            let (name, _old, new): (String, String, String) = body.deserialize().unwrap_or_default();
            json!({ "kind": "owner", "name": name, "up": !new.is_empty() })
        }
        _ => json!({ "kind": "bluez", "member": member, "path": path }),
    }
}

pub fn start() -> Sender<Json> {
    let (tx, rx) = channel::<Json>();
    let tx2 = tx.clone();
    std::thread::spawn(move || {
        let session = std::env::var("HYPRSHELL_AGENT_BUS").map(|v| v == "session").unwrap_or(false);
        let built = if session { zbus::blocking::connection::Builder::session() } else { zbus::blocking::connection::Builder::system() };
        let conn = match built.and_then(|b| b.method_timeout(Duration::from_secs(120)).build()) {
            Ok(c) => c,
            Err(e) => {
                out::emit(json!({ "ev": "bt", "available": false }));
                out::emit(json!({ "ev": "agent-fatal", "message": e.to_string() }));
                return;
            }
        };
        let bt: Shared<Bt> = Arc::new(Mutex::new(Bt::default()));
        let pend: Shared<Pending> = Arc::new(Mutex::new(Pending::default()));
        let _ = conn.object_server().at(AGENT_PATH, BtAgent { bt: bt.clone(), pend: pend.clone() });
        let _ = conn.object_server().at(NM_AGENT_PATH, SecretAgent { pend: pend.clone() });

        if let Ok(r) = zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).sender(BLUEZ).map(|b| b.build()) {
            listen(&conn, r, "_bluez", tx2.clone());
        }
        if let Ok(r) = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .sender("org.freedesktop.DBus")
            .and_then(|b| b.member("NameOwnerChanged"))
            .map(|b| b.build())
        {
            listen(&conn, r, "_owner", tx2.clone());
        }

        let ctx = Arc::new(Ctx { conn: conn.clone(), bt: bt.clone() });
        let bluez_up = load(&conn, &bt).is_ok();
        if bluez_up {
            register_bt_agent(&conn);
        }
        register_nm_agent(&conn);
        out::emit(bt.lock().unwrap().snapshot());

        // BlueZ changes come in bursts; one snapshot per 40 ms of them.
        let mut dirty_since: Option<Instant> = None;
        let mut stale = false;
        loop {
            let wait = match dirty_since {
                Some(t) => Duration::from_millis(40).saturating_sub(t.elapsed()),
                None => Duration::from_secs(3600),
            };
            match rx.recv_timeout(wait) {
                Ok(c) => {
                    let cmd = c["cmd"].as_str().unwrap_or("").to_string();
                    match cmd.as_str() {
                        "_bluez" | "_owner" => {
                            let m = &c["msg"];
                            if m["kind"] == "owner" {
                                let up = m["up"].as_bool().unwrap_or(false);
                                match m["name"].as_str() {
                                    Some(BLUEZ) if up => {
                                        if load(&conn, &bt).is_ok() {
                                            register_bt_agent(&conn);
                                        }
                                    }
                                    Some(BLUEZ) => *bt.lock().unwrap() = Bt::default(),
                                    Some(NM) if up => register_nm_agent(&conn),
                                    _ => continue,
                                }
                            } else {
                                // Re-read everything once the burst is over
                                // rather than decode each signal's
                                // dictionaries.
                                stale = true;
                            }
                            dirty_since.get_or_insert(Instant::now());
                        }
                        "bt-reply" => {
                            let id = c["id"].as_u64().unwrap_or(0) as u32;
                            if let Some((_, tx)) = pend.lock().unwrap().bt.remove(&id) {
                                let accept = c["accept"].as_bool().unwrap_or(false);
                                let _ = tx.send(if accept { Answer::Accept(c["value"].as_str().unwrap_or("").to_string()) } else { Answer::Reject });
                            }
                        }
                        "nm-reply" => {
                            let id = c["id"].as_u64().unwrap_or(0) as u32;
                            if let Some((_, _, tx)) = pend.lock().unwrap().nm.remove(&id) {
                                let secrets: HashMap<String, String> = c["secrets"]
                                    .as_object()
                                    .map(|o| o.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string())).collect())
                                    .unwrap_or_default();
                                let _ = tx.send(Some(secrets));
                            }
                        }
                        "bt-hello" => {
                            dirty_since.get_or_insert(Instant::now() - Duration::from_millis(40));
                        }
                        _ if cmd.starts_with("bt-") => {
                            // Calls can take minutes (pairing waits on a
                            // person); each runs on its own thread.
                            let ctx = ctx.clone();
                            std::thread::spawn(move || ctx.command(&c));
                        }
                        _ => {}
                    }
                }
                Err(RecvTimeoutError::Timeout) => {
                    if dirty_since.take().is_some() {
                        if std::mem::take(&mut stale) {
                            let _ = load(&conn, &bt);
                        }
                        out::emit(bt.lock().unwrap().snapshot());
                    }
                }
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
    });
    tx
}
