//! A stand-in NetworkManager, for testing the daemon's network module
//! without one: `cargo run --example mock_nm` on a private system bus
//! (DBUS_SYSTEM_BUS_ADDRESS). Answers the calls hyprshell-daemon makes, from
//! a fixed little world — one Wi-Fi card, three networks, one connected,
//! two saved — and every few seconds changes the signal strength of the
//! network in use, the way the real one does.

use std::collections::HashMap;
use std::time::Duration;
use zbus::blocking::{Connection, MessageIterator};
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

const NM: &str = "org.freedesktop.NetworkManager";
const ROOT: &str = "/org/freedesktop/NetworkManager";
const DEV: &str = "/org/freedesktop/NetworkManager/Devices/1";
const AC: &str = "/org/freedesktop/NetworkManager/ActiveConnection/1";
const IP4: &str = "/org/freedesktop/NetworkManager/IP4Config/1";

fn ap_path(i: u32) -> String {
    format!("/org/freedesktop/NetworkManager/AccessPoint/{i}")
}
fn op(p: &str) -> Value<'static> {
    Value::from(ObjectPath::try_from(p.to_string()).unwrap())
}
fn ops(ps: &[String]) -> Value<'static> {
    Value::from(ps.iter().map(|p| ObjectPath::try_from(p.clone()).unwrap()).collect::<Vec<_>>())
}
fn ov(v: Value<'static>) -> OwnedValue {
    OwnedValue::try_from(v).unwrap()
}

fn props(path: &str, iface: &str, strength: u8, wifi_on: bool) -> Option<HashMap<String, OwnedValue>> {
    let mut m: HashMap<String, OwnedValue> = HashMap::new();
    let aps = [(1u32, "Home", 0u32, 0x188u32, 2437u32, 270000u32), (2, "Campus", 0, 0x388, 5180, 866000), (3, "Cafe", 0, 0, 2412, 54000)];
    match (path, iface) {
        (ROOT, NM) => {
            m.insert("WirelessEnabled".into(), ov(Value::from(wifi_on)));
            m.insert("ActiveConnections".into(), ov(ops(&[AC.to_string()])));
        }
        (DEV, "org.freedesktop.NetworkManager.Device") => {
            m.insert("DeviceType".into(), ov(Value::from(2u32)));
            m.insert("Interface".into(), ov(Value::from("wlan0")));
            m.insert("HwAddress".into(), ov(Value::from("AA:BB:CC:DD:EE:FF")));
            m.insert("Ip4Config".into(), ov(op(IP4)));
            m.insert("Ip6Config".into(), ov(op("/")));
        }
        (DEV, "org.freedesktop.NetworkManager.Device.Wireless") => {
            m.insert("AccessPoints".into(), ov(ops(&[ap_path(1), ap_path(2), ap_path(3)])));
            m.insert("ActiveAccessPoint".into(), ov(op(&ap_path(1))));
            m.insert("Bitrate".into(), ov(Value::from(270000u32)));
            m.insert("HwAddress".into(), ov(Value::from("AA:BB:CC:DD:EE:FF")));
        }
        (AC, "org.freedesktop.NetworkManager.Connection.Active") => {
            m.insert("Type".into(), ov(Value::from("802-11-wireless")));
            m.insert("State".into(), ov(Value::from(2u32)));
            m.insert("Uuid".into(), ov(Value::from("1111-home")));
            m.insert("Id".into(), ov(Value::from("Home")));
            m.insert("Devices".into(), ov(ops(&[DEV.to_string()])));
        }
        (IP4, "org.freedesktop.NetworkManager.IP4Config") => {
            let mut a: HashMap<String, Value> = HashMap::new();
            a.insert("address".into(), Value::from("192.168.1.23"));
            a.insert("prefix".into(), Value::from(24u32));
            let mut d: HashMap<String, Value> = HashMap::new();
            d.insert("address".into(), Value::from("192.168.1.1"));
            m.insert("AddressData".into(), ov(Value::from(vec![a])));
            m.insert("Gateway".into(), ov(Value::from("192.168.1.1")));
            m.insert("NameserverData".into(), ov(Value::from(vec![d])));
        }
        (p, "org.freedesktop.NetworkManager.AccessPoint") => {
            let i: u32 = p.rsplit('/').next()?.parse().ok()?;
            let (_, ssid, wpa, rsn, freq, rate) = aps.iter().find(|a| a.0 == i)?;
            m.insert("Ssid".into(), ov(Value::from(ssid.as_bytes().to_vec())));
            m.insert("Strength".into(), ov(Value::from(if i == 1 { strength } else { 40u8 + i as u8 * 7 })));
            m.insert("Flags".into(), ov(Value::from(if *rsn != 0 { 1u32 } else { 0u32 })));
            m.insert("WpaFlags".into(), ov(Value::from(*wpa)));
            m.insert("RsnFlags".into(), ov(Value::from(*rsn)));
            m.insert("Frequency".into(), ov(Value::from(*freq)));
            m.insert("MaxBitrate".into(), ov(Value::from(*rate)));
        }
        _ => return None,
    }
    Some(m)
}

fn settings(i: u32) -> HashMap<String, HashMap<String, OwnedValue>> {
    let mut s = HashMap::new();
    let mut c: HashMap<String, OwnedValue> = HashMap::new();
    let mut w: HashMap<String, OwnedValue> = HashMap::new();
    let mut sec: HashMap<String, OwnedValue> = HashMap::new();
    c.insert("type".into(), ov(Value::from("802-11-wireless")));
    if i == 1 {
        c.insert("id".into(), ov(Value::from("Home")));
        c.insert("uuid".into(), ov(Value::from("1111-home")));
        w.insert("ssid".into(), ov(Value::from(b"Home".to_vec())));
        sec.insert("key-mgmt".into(), ov(Value::from("wpa-psk")));
    } else {
        c.insert("id".into(), ov(Value::from("Campus")));
        c.insert("uuid".into(), ov(Value::from("2222-campus")));
        c.insert("autoconnect".into(), ov(Value::from(false)));
        w.insert("ssid".into(), ov(Value::from(b"Campus".to_vec())));
        sec.insert("key-mgmt".into(), ov(Value::from("wpa-eap")));
        let mut x: HashMap<String, OwnedValue> = HashMap::new();
        x.insert("eap".into(), ov(Value::from(vec!["peap".to_string()])));
        s.insert("802-1x".into(), x);
    }
    s.insert("connection".into(), c);
    s.insert("802-11-wireless".into(), w);
    s.insert("802-11-wireless-security".into(), sec);
    s
}

fn main() -> zbus::Result<()> {
    let conn = Connection::system()?;
    conn.request_name(NM)?;
    eprintln!("mock NetworkManager up");
    let strength = std::sync::Arc::new(std::sync::atomic::AtomicU8::new(70));
    {
        // The connected network's signal drifting, announced as NM does.
        let conn = conn.clone();
        let strength = strength.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_secs(3));
            let s = strength.fetch_add(3, std::sync::atomic::Ordering::SeqCst) + 3;
            let mut changed: HashMap<&str, Value> = HashMap::new();
            changed.insert("Strength", Value::from(s));
            let _ = conn.emit_signal(None::<&str>, ap_path(1).as_str(), "org.freedesktop.DBus.Properties", "PropertiesChanged",
                &("org.freedesktop.NetworkManager.AccessPoint", changed, Vec::<String>::new()));
        });
    }
    let mut wifi_on = true;
    for msg in MessageIterator::from(conn.clone()).flatten() {
        let h = msg.header();
        if h.message_type() != zbus::message::Type::MethodCall {
            continue;
        }
        let path = h.path().map(|p| p.to_string()).unwrap_or_default();
        let member = h.member().map(|m| m.to_string()).unwrap_or_default();
        let iface = h.interface().map(|i| i.to_string()).unwrap_or_default();
        eprintln!("call {iface}.{member} on {path}");
        let s = strength.load(std::sync::atomic::Ordering::SeqCst);
        let r = match member.as_str() {
            "GetAll" => {
                let (want,): (String,) = msg.body().deserialize()?;
                match props(&path, &want, s, wifi_on) {
                    Some(p) => conn.reply(&h, &p),
                    None => conn.reply_error(&h, "org.freedesktop.DBus.Error.UnknownInterface", &"no such interface"),
                }
            }
            "Set" => {
                let (_, prop, v): (String, String, OwnedValue) = msg.body().deserialize()?;
                if prop == "WirelessEnabled" {
                    wifi_on = matches!(&*v, Value::Bool(true));
                    eprintln!("wifi -> {wifi_on}");
                }
                conn.reply(&h, &())
            }
            "GetDevices" => conn.reply(&h, &vec![ObjectPath::try_from(DEV).unwrap()]),
            "ListConnections" => conn.reply(&h, &vec![
                ObjectPath::try_from("/org/freedesktop/NetworkManager/Settings/1").unwrap(),
                ObjectPath::try_from("/org/freedesktop/NetworkManager/Settings/2").unwrap()]),
            "GetSettings" => conn.reply(&h, &settings(if path.ends_with("/1") { 1 } else { 2 })),
            "RequestScan" => { eprintln!("scan requested"); conn.reply(&h, &()) }
            _ => continue,
        };
        if let Err(e) = r {
            eprintln!("reply failed: {e}");
        }
    }
    Ok(())
}
