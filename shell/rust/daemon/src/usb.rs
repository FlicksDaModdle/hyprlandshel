//! USB drives and SD cards, through UDisks2: what is plugged in, mounted
//! when it arrives (if chosen), a notification with Open and Eject, and
//! ejecting safely — every filesystem on the drive unmounted first, then
//! the drive powered off so it can be pulled out.
//!
//! Commands:  usb-config {automount, notify}
//!            usb-mount {path}       a filesystem's UDisks2 object
//!            usb-unmount {path}
//!            usb-eject {drive}      a drive's UDisks2 object
//! Events:    usb {available, drives: [{path, name, size, removable,
//!                 parts: [{path, label, fs, size, mount, device, locked}]}]}
//!            usb-open {mount}       a notification's Open was pressed
//!            usb-error {op, message}
//!
//! HYPRSHELL_USB_BUS=session talks to a stand-in on the session bus.

use crate::out;
use serde_json::{json, Value as Json};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

const UDISKS: &str = "org.freedesktop.UDisks2";
const ROOT: &str = "/org/freedesktop/UDisks2";
const BLOCK: &str = "org.freedesktop.UDisks2.Block";
const FS: &str = "org.freedesktop.UDisks2.Filesystem";
const DRIVE: &str = "org.freedesktop.UDisks2.Drive";

type Props = HashMap<String, OwnedValue>;
type Objects = HashMap<OwnedObjectPath, HashMap<String, Props>>;

fn s(p: &Props, k: &str) -> String {
    match p.get(k).map(|v| &**v) {
        Some(Value::Str(x)) => x.to_string(),
        Some(Value::ObjectPath(x)) => x.to_string(),
        _ => String::new(),
    }
}
fn b(p: &Props, k: &str) -> bool {
    matches!(p.get(k).map(|v| &**v), Some(Value::Bool(true)))
}
fn n(p: &Props, k: &str) -> u64 {
    match p.get(k).map(|v| &**v) {
        Some(Value::U64(x)) => *x,
        Some(Value::U32(x)) => *x as u64,
        _ => 0,
    }
}
/// A byte string (UDisks' "ay" paths), without its trailing NUL.
fn bytes_str(v: &Value) -> String {
    match v {
        Value::Array(a) => {
            let b: Vec<u8> = a.iter().filter_map(|x| if let Value::U8(c) = x { Some(*c) } else { None }).take_while(|c| *c != 0).collect();
            String::from_utf8_lossy(&b).to_string()
        }
        _ => String::new(),
    }
}
fn mounts(p: &Props) -> Vec<String> {
    match p.get("MountPoints").map(|v| &**v) {
        Some(Value::Array(a)) => a.iter().map(|m| bytes_str(m)).filter(|m| !m.is_empty()).collect(),
        _ => Vec::new(),
    }
}

fn human(bytes: u64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1000.0 && i < units.len() - 1 {
        v /= 1000.0;
        i += 1;
    }
    if i == 0 { format!("{bytes} B") } else if v >= 100.0 { format!("{:.0} {}", v, units[i]) } else { format!("{:.1} {}", v, units[i]) }
}

/// The removable drives and their filesystems.
fn snapshot(conn: &Connection) -> zbus::Result<Vec<Json>> {
    let m = conn.call_method(Some(UDISKS), ROOT, Some("org.freedesktop.DBus.ObjectManager"), "GetManagedObjects", &())?;
    let objs: Objects = m.body().deserialize()?;
    let mut drives: BTreeMap<String, Json> = BTreeMap::new();
    for (path, ifaces) in &objs {
        let Some(blk) = ifaces.get(BLOCK) else { continue };
        if b(blk, "HintIgnore") || b(blk, "HintSystem") {
            continue;
        }
        let drive_path = s(blk, "Drive");
        let Some(drv) = objs.iter().find(|(p, _)| p.as_str() == drive_path).and_then(|(_, i)| i.get(DRIVE)) else { continue };
        let bus = s(drv, "ConnectionBus");
        let removable = b(drv, "Removable") || b(drv, "MediaRemovable") || bus == "usb" || bus == "sdio";
        if !removable {
            continue;
        }
        let fs_type = s(blk, "IdType");
        let has_fs = ifaces.contains_key(FS);
        let locked = fs_type == "crypto_LUKS";
        if !has_fs && !locked {
            continue;
        }
        let entry = drives.entry(drive_path.clone()).or_insert_with(|| {
            let name = [s(drv, "Vendor"), s(drv, "Model")].iter().filter(|x| !x.trim().is_empty()).map(|x| x.trim().to_string()).collect::<Vec<_>>().join(" ");
            json!({
                "path": drive_path, "name": if name.is_empty() { "Removable drive".to_string() } else { name },
                "size": human(n(drv, "Size")), "bytes": n(drv, "Size"),
                "canPowerOff": b(drv, "CanPowerOff"), "ejectable": b(drv, "Ejectable"),
                "parts": []
            })
        });
        let mount = ifaces.get(FS).map(mounts).unwrap_or_default();
        let device = blk.get("PreferredDevice").map(|v| bytes_str(v)).filter(|d| !d.is_empty()).or_else(|| blk.get("Device").map(|v| bytes_str(v))).unwrap_or_default();
        entry["parts"].as_array_mut().unwrap().push(json!({
            "path": path.as_str(), "label": s(blk, "IdLabel"), "fs": fs_type,
            "size": human(n(blk, "Size")), "mount": mount.first().cloned().unwrap_or_default(),
            "device": device, "locked": locked
        }));
    }
    Ok(drives.into_values().collect())
}

fn err_text(e: &zbus::Error) -> String {
    let raw = match e {
        zbus::Error::MethodError(name, desc, _) => format!("{} {}", name, desc.clone().unwrap_or_default()),
        other => other.to_string(),
    };
    if raw.contains("DeviceBusy") || raw.contains("target is busy") || raw.contains("busy") {
        "something is still using it — close the files and windows on the drive, then try again".into()
    } else if raw.contains("NotAuthorized") {
        "not allowed (polkit said no)".into()
    } else {
        raw
    }
}

fn opts() -> HashMap<&'static str, Value<'static>> {
    HashMap::new()
}

struct Usb {
    sys: Connection,
    last: Vec<Json>,
}

impl Usb {
    fn mount(&self, path: &str) -> Result<String, String> {
        let r = self.sys.call_method(Some(UDISKS), path, Some(FS), "Mount", &(opts(),)).map_err(|e| err_text(&e))?;
        r.body().deserialize::<String>().map_err(|e| e.to_string())
    }
    fn unmount(&self, path: &str) -> Result<(), String> {
        self.sys.call_method(Some(UDISKS), path, Some(FS), "Unmount", &(opts(),)).map(|_| ()).map_err(|e| err_text(&e))
    }
    fn eject(&self, drive: &str) -> Result<(), String> {
        let d = self.last.iter().find(|d| d["path"] == drive).cloned().ok_or("that drive is gone")?;
        for p in d["parts"].as_array().into_iter().flatten() {
            if p["mount"].as_str().map(|m| !m.is_empty()).unwrap_or(false) {
                self.unmount(p["path"].as_str().unwrap_or(""))?;
            }
        }
        // Powered off where it can be (USB sticks and disks: the light goes
        // out and it is safe to pull); ejected where that is the thing (a
        // card reader, an optical drive).
        if d["canPowerOff"].as_bool().unwrap_or(false) {
            self.sys.call_method(Some(UDISKS), drive, Some(DRIVE), "PowerOff", &(opts(),)).map(|_| ()).map_err(|e| err_text(&e))
        } else if d["ejectable"].as_bool().unwrap_or(false) {
            self.sys.call_method(Some(UDISKS), drive, Some(DRIVE), "Eject", &(opts(),)).map(|_| ()).map_err(|e| err_text(&e))
        } else {
            Ok(())
        }
    }
}

/// A desktop notification, through whichever server the session has (the
/// shell's own); its buttons come back as ActionInvoked.
fn notify(session: &Connection, summary: &str, body: &str, actions: &[&str]) -> Option<u32> {
    let hints: HashMap<&str, Value> = [("desktop-entry", Value::from("hyprshell-files")), ("category", Value::from("device.added"))].into_iter().collect();
    let r = session
        .call_method(Some("org.freedesktop.Notifications"), "/org/freedesktop/Notifications", Some("org.freedesktop.Notifications"), "Notify",
                     &("Drives", 0u32, "drive-removable-media", summary, body, actions.to_vec(), hints, 8000i32))
        .ok()?;
    r.body().deserialize::<u32>().ok()
}

fn listen(conn: &Connection, rule: zbus::Result<zbus::MatchRule<'static>>, tag: &'static str, tx: Sender<Json>) {
    let Ok(rule) = rule else { return };
    let conn = conn.clone();
    std::thread::spawn(move || {
        let Ok(iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(64)) else { return };
        for m in iter.flatten() {
            let mut ev = json!({ "cmd": tag });
            if tag == "_usb-action" {
                if let Ok((id, key)) = m.body().deserialize::<(u32, String)>() {
                    ev["id"] = json!(id);
                    ev["key"] = json!(key);
                }
            }
            if tx.send(ev).is_err() {
                return;
            }
        }
    });
}

pub fn start() -> Sender<Json> {
    let (tx, rx) = channel::<Json>();
    let me = tx.clone();
    std::thread::spawn(move || {
        let sys = if std::env::var("HYPRSHELL_USB_BUS").map(|v| v == "session").unwrap_or(false) { Connection::session() } else { Connection::system() };
        let Ok(sys) = sys else {
            out::emit(json!({ "ev": "usb", "available": false, "drives": [] }));
            return;
        };
        let session = Connection::session().ok();
        listen(&sys, zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).sender(UDISKS).map(|b| b.build()), "_usb-changed", me.clone());
        if let Some(ses) = &session {
            listen(
                ses,
                zbus::MatchRule::builder()
                    .msg_type(zbus::message::Type::Signal)
                    .interface("org.freedesktop.Notifications")
                    .and_then(|b| b.member("ActionInvoked"))
                    .map(|b| b.build()),
                "_usb-action",
                me.clone(),
            );
        }
        let mut usb = Usb { sys, last: Vec::new() };
        let (mut automount, mut notify_on) = (false, true);
        let mut configured = false;
        // Drives seen, so a new one is told apart from one already there.
        let mut known: HashSet<String> = HashSet::new();
        let mut first = true;
        // Notification id → (drive, filesystem).
        let mut notes: HashMap<u32, (String, String)> = HashMap::new();
        let mut dirty: Option<Instant> = Some(Instant::now() - Duration::from_secs(1));
        loop {
            let wait = match dirty {
                Some(t) => Duration::from_millis(250).saturating_sub(t.elapsed()),
                None => Duration::from_secs(3600),
            };
            match rx.recv_timeout(wait) {
                Ok(c) => {
                    let cmd = c["cmd"].as_str().unwrap_or("").to_string();
                    let path = c["path"].as_str().unwrap_or("").to_string();
                    let r: Result<(), String> = match cmd.as_str() {
                        "_usb-changed" => {
                            dirty.get_or_insert(Instant::now());
                            Ok(())
                        }
                        "usb-config" => {
                            automount = c["automount"].as_bool().unwrap_or(false);
                            notify_on = c["notify"].as_bool().unwrap_or(true);
                            configured = true;
                            Ok(())
                        }
                        "usb-mount" => usb.mount(&path).map(|_| ()),
                        "usb-unmount" => usb.unmount(&path),
                        "usb-eject" => usb.eject(c["drive"].as_str().unwrap_or("")),
                        "_usb-action" => {
                            let id = c["id"].as_u64().unwrap_or(0) as u32;
                            match (notes.get(&id).cloned(), c["key"].as_str()) {
                                (Some((_, fs)), Some("open")) => {
                                    // Mounted already, or now.
                                    let mount = usb.last.iter().flat_map(|d| d["parts"].as_array().cloned().unwrap_or_default())
                                        .find(|p| p["path"] == fs.as_str()).and_then(|p| p["mount"].as_str().map(|s| s.to_string())).unwrap_or_default();
                                    let mount = if mount.is_empty() { usb.mount(&fs).unwrap_or_default() } else { mount };
                                    if !mount.is_empty() {
                                        out::emit(json!({ "ev": "usb-open", "mount": mount }));
                                    }
                                    Ok(())
                                }
                                (Some((drive, _)), Some("eject")) => usb.eject(&drive),
                                _ => Ok(()),
                            }
                        }
                        _ => Ok(()),
                    };
                    if let Err(e) = r {
                        out::emit(json!({ "ev": "usb-error", "op": cmd, "message": e }));
                    }
                    if cmd.starts_with("usb-") {
                        dirty.get_or_insert(Instant::now());
                    }
                }
                Err(RecvTimeoutError::Timeout) => {
                    if dirty.take().is_none() {
                        continue;
                    }
                    let Ok(drives) = snapshot(&usb.sys) else {
                        if !usb.last.is_empty() || first {
                            out::emit(json!({ "ev": "usb", "available": false, "drives": [] }));
                        }
                        usb.last.clear();
                        first = false;
                        continue;
                    };
                    // Arrivals: mounted if chosen, and announced.
                    if configured {
                        for d in &drives {
                            let dp = d["path"].as_str().unwrap_or("").to_string();
                            if known.contains(&dp) || first {
                                continue;
                            }
                            let part = d["parts"].as_array().and_then(|p| p.iter().find(|p| !p["locked"].as_bool().unwrap_or(false)).cloned());
                            let mut mount = part.as_ref().and_then(|p| p["mount"].as_str().map(|s| s.to_string())).unwrap_or_default();
                            if automount && mount.is_empty() {
                                if let Some(p) = &part {
                                    match usb.mount(p["path"].as_str().unwrap_or("")) {
                                        Ok(m) => mount = m,
                                        Err(e) => out::emit(json!({ "ev": "usb-error", "op": "automount", "message": e })),
                                    }
                                }
                            }
                            if notify_on {
                                if let Some(ses) = &session {
                                    let label = part.as_ref().and_then(|p| p["label"].as_str()).filter(|l| !l.is_empty()).unwrap_or(d["name"].as_str().unwrap_or("Drive"));
                                    let body = format!("{} · {}{}", d["name"].as_str().unwrap_or(""), d["size"].as_str().unwrap_or(""),
                                                       if mount.is_empty() { String::new() } else { format!(" · {mount}") });
                                    if let Some(id) = notify(ses, &format!("{label} connected"), &body, &["open", "Open", "eject", "Eject"]) {
                                        let fs = part.as_ref().and_then(|p| p["path"].as_str()).unwrap_or("").to_string();
                                        notes.insert(id, (dp.clone(), fs));
                                    }
                                }
                            }
                        }
                    }
                    if configured {
                        known = drives.iter().filter_map(|d| d["path"].as_str().map(|s| s.to_string())).collect();
                        first = false;
                    }
                    if drives != usb.last || first {
                        out::emit(json!({ "ev": "usb", "available": true, "drives": drives }));
                    }
                    usb.last = drives;
                }
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
    });
    tx
}
