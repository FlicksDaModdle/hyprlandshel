//! A stand-in UDisks2 (and a notification server) on the session bus, for
//! testing src/usb.rs without plugging anything in: UDisks2's service
//! name, object layout, interfaces, property names and types, with an
//! internal disk that must be ignored and a USB stick that comes and goes.
//!
//!   cargo run --example mock_udisks      (then HYPRSHELL_USB_BUS=session)
//!
//! org.test on /test: Plug(), Unplug(), Busy(b), Press(u id, s key).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use zbus::object_server::SignalEmitter;
use zbus::zvariant::OwnedObjectPath;

const BASE: &str = "/org/freedesktop/UDisks2";

fn ay(s: &str) -> Vec<u8> {
    let mut v = s.as_bytes().to_vec();
    v.push(0);
    v
}

struct Drive {
    vendor: &'static str,
    model: &'static str,
    removable: bool,
    bus: &'static str,
}

#[zbus::interface(name = "org.freedesktop.UDisks2.Drive")]
impl Drive {
    #[zbus(property)]
    fn vendor(&self) -> String { self.vendor.into() }
    #[zbus(property)]
    fn model(&self) -> String { self.model.into() }
    #[zbus(property)]
    fn size(&self) -> u64 { 32_017_047_552 }
    #[zbus(property)]
    fn removable(&self) -> bool { self.removable }
    #[zbus(property)]
    fn media_removable(&self) -> bool { self.removable }
    #[zbus(property)]
    fn connection_bus(&self) -> String { self.bus.into() }
    #[zbus(property)]
    fn can_power_off(&self) -> bool { self.removable }
    #[zbus(property)]
    fn ejectable(&self) -> bool { false }
    fn power_off(&self, _o: HashMap<String, zbus::zvariant::OwnedValue>) {
        println!("CALL PowerOff {}", self.model);
    }
    fn eject(&self, _o: HashMap<String, zbus::zvariant::OwnedValue>) {
        println!("CALL Eject {}", self.model);
    }
}

struct Block {
    drive: OwnedObjectPath,
    label: &'static str,
    fs: &'static str,
    dev: &'static str,
    system: bool,
}

#[zbus::interface(name = "org.freedesktop.UDisks2.Block")]
impl Block {
    #[zbus(property)]
    fn drive(&self) -> OwnedObjectPath { self.drive.clone() }
    #[zbus(property)]
    fn id_label(&self) -> String { self.label.into() }
    #[zbus(property)]
    fn id_type(&self) -> String { self.fs.into() }
    #[zbus(property)]
    fn size(&self) -> u64 { 32_000_000_000 }
    #[zbus(property)]
    fn hint_ignore(&self) -> bool { false }
    #[zbus(property)]
    fn hint_system(&self) -> bool { self.system }
    #[zbus(property)]
    fn preferred_device(&self) -> Vec<u8> { ay(self.dev) }
    #[zbus(property)]
    fn device(&self) -> Vec<u8> { ay(self.dev) }
}

struct Fs {
    mounts: Arc<Mutex<Vec<Vec<u8>>>>,
    busy: Arc<Mutex<bool>>,
    name: &'static str,
}

#[zbus::interface(name = "org.freedesktop.UDisks2.Filesystem")]
impl Fs {
    #[zbus(property)]
    fn mount_points(&self) -> Vec<Vec<u8>> { self.mounts.lock().unwrap().clone() }
    async fn mount(&self, _o: HashMap<String, zbus::zvariant::OwnedValue>, #[zbus(signal_emitter)] em: SignalEmitter<'_>) -> zbus::fdo::Result<String> {
        let m = format!("/run/media/user/{}", self.name);
        println!("CALL Mount -> {m}");
        *self.mounts.lock().unwrap() = vec![ay(&m)];
        let _ = self.mount_points_changed(&em).await;
        Ok(m)
    }
    async fn unmount(&self, _o: HashMap<String, zbus::zvariant::OwnedValue>, #[zbus(signal_emitter)] em: SignalEmitter<'_>) -> Result<(), UdError> {
        if *self.busy.lock().unwrap() {
            println!("CALL Unmount -> busy");
            return Err(UdError::DeviceBusy("Error unmounting /dev/sdb1: target is busy".into()));
        }
        println!("CALL Unmount");
        self.mounts.lock().unwrap().clear();
        let _ = self.mount_points_changed(&em).await;
        Ok(())
    }
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.UDisks2.Error")]
enum UdError {
    #[zbus(error)]
    ZBus(zbus::Error),
    DeviceBusy(String),
}

struct Notes {
    next: u32,
}

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl Notes {
    #[allow(clippy::too_many_arguments)]
    fn notify(&mut self, app: String, _replaces: u32, _icon: String, summary: String, body: String, actions: Vec<String>,
              _hints: HashMap<String, zbus::zvariant::OwnedValue>, _timeout: i32) -> u32 {
        self.next += 1;
        println!("NOTIFY #{} [{app}] {summary} — {body} {actions:?}", self.next);
        self.next
    }
    #[zbus(signal)]
    async fn action_invoked(em: &SignalEmitter<'_>, id: u32, key: &str) -> zbus::Result<()>;
}

struct Test {
    busy: Arc<Mutex<bool>>,
}

#[zbus::interface(name = "org.test")]
impl Test {
    async fn plug(&self, #[zbus(object_server)] srv: &zbus::ObjectServer) {
        let drive: OwnedObjectPath = OwnedObjectPath::try_from(format!("{BASE}/drives/Kingston_DataTraveler_3_0")).unwrap();
        let _ = srv.at(drive.clone(), Drive { vendor: "Kingston", model: "DataTraveler 3.0", removable: true, bus: "usb" }).await;
        let blk = format!("{BASE}/block_devices/sdb1");
        let _ = srv.at(blk.as_str(), Block { drive, label: "PHOTOS", fs: "vfat", dev: "/dev/sdb1", system: false }).await;
        let _ = srv.at(blk.as_str(), Fs { mounts: Arc::new(Mutex::new(Vec::new())), busy: self.busy.clone(), name: "PHOTOS" }).await;
        println!("PLUGGED");
    }
    async fn unplug(&self, #[zbus(object_server)] srv: &zbus::ObjectServer) {
        let blk = format!("{BASE}/block_devices/sdb1");
        let _ = srv.remove::<Fs, _>(blk.as_str()).await;
        let _ = srv.remove::<Block, _>(blk.as_str()).await;
        let _ = srv.remove::<Drive, _>(format!("{BASE}/drives/Kingston_DataTraveler_3_0").as_str()).await;
        println!("UNPLUGGED");
    }
    fn busy(&self, on: bool) {
        *self.busy.lock().unwrap() = on;
    }
    async fn press(&self, id: u32, key: String, #[zbus(object_server)] srv: &zbus::ObjectServer) {
        if let Ok(iface) = srv.interface::<_, Notes>("/org/freedesktop/Notifications").await {
            let _ = Notes::action_invoked(iface.signal_emitter(), id, &key).await;
        }
    }
}

fn main() -> zbus::Result<()> {
    let busy = Arc::new(Mutex::new(false));
    let internal: OwnedObjectPath = OwnedObjectPath::try_from(format!("{BASE}/drives/Samsung_SSD_980")).unwrap();
    let conn = zbus::blocking::connection::Builder::session()?
        .serve_at(BASE, zbus::fdo::ObjectManager)?
        .serve_at(internal.as_str(), Drive { vendor: "", model: "Samsung SSD 980", removable: false, bus: "" })?
        .serve_at(format!("{BASE}/block_devices/nvme0n1p2").as_str(), Block { drive: internal.clone(), label: "", fs: "ext4", dev: "/dev/nvme0n1p2", system: true })?
        .serve_at(format!("{BASE}/block_devices/nvme0n1p2").as_str(), Fs { mounts: Arc::new(Mutex::new(vec![ay("/")])), busy: busy.clone(), name: "root" })?
        .serve_at("/test", Test { busy })?
        .serve_at("/org/freedesktop/Notifications", Notes { next: 0 })?
        .name("org.freedesktop.UDisks2")?
        .build()?;
    conn.request_name("org.freedesktop.Notifications")?;
    let _keep = conn;
    println!("MOCK UDISKS READY");
    loop {
        std::thread::park();
    }
}
