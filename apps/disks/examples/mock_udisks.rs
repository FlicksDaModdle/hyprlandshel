//! A stand-in UDisks2 on the session bus for trying Disks without real
//! drives (HYPRSHELL_DISKS_BUS=session): an NVMe drive with the system on
//! it, and a USB stick with a volume and free space.
//!
//!   cargo run --example mock_udisks

use std::collections::HashMap;
use zbus::interface;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

fn ay(s: &str) -> Vec<u8> {
    let mut v = s.as_bytes().to_vec();
    v.push(0);
    v
}
fn op(s: &str) -> OwnedObjectPath {
    ObjectPath::try_from(s).unwrap().into()
}

struct Drive { model: String, vendor: String, size: u64, bus: String, removable: bool, rot: i32, serial: String }
#[interface(name = "org.freedesktop.UDisks2.Drive")]
impl Drive {
    #[zbus(property)] fn model(&self) -> String { self.model.clone() }
    #[zbus(property)] fn vendor(&self) -> String { self.vendor.clone() }
    #[zbus(property)] fn size(&self) -> u64 { self.size }
    #[zbus(property)] fn connection_bus(&self) -> String { self.bus.clone() }
    #[zbus(property)] fn removable(&self) -> bool { self.removable }
    #[zbus(property)] fn media_removable(&self) -> bool { self.removable }
    #[zbus(property)] fn ejectable(&self) -> bool { self.removable }
    #[zbus(property)] fn can_power_off(&self) -> bool { self.removable }
    #[zbus(property)] fn rotation_rate(&self) -> i32 { self.rot }
    #[zbus(property)] fn serial(&self) -> String { self.serial.clone() }
    #[zbus(property)] fn revision(&self) -> String { "3B4QFXO7".into() }
    #[zbus(property)] fn media(&self) -> String { String::new() }
    fn power_off(&self, _o: HashMap<String, OwnedValue>) {}
    fn eject(&self, _o: HashMap<String, OwnedValue>) {}
}

struct Nvme;
#[interface(name = "org.freedesktop.UDisks2.NVMe.Controller")]
impl Nvme {
    #[zbus(property)] fn smart_critical_warning(&self) -> Vec<String> { vec![] }
    #[zbus(property)] fn smart_power_on_hours(&self) -> u64 { 2140 }
    #[zbus(property)] fn smart_temperature(&self) -> u16 { 311 }
    fn smart_get_attributes(&self, _o: HashMap<String, OwnedValue>) -> HashMap<String, OwnedValue> {
        let mut m = HashMap::new();
        m.insert("percent_used".to_string(), OwnedValue::from(3u8));
        m.insert("avail_spare".to_string(), OwnedValue::from(100u8));
        m.insert("total_data_written".to_string(), OwnedValue::from(18_400_000_000_000u64));
        m.insert("media_errors".to_string(), OwnedValue::from(0u64));
        m
    }
}

struct Block { drive: String, dev: String, size: u64, idtype: String, label: String }
#[interface(name = "org.freedesktop.UDisks2.Block")]
impl Block {
    #[zbus(property)] fn drive(&self) -> OwnedObjectPath { op(&self.drive) }
    #[zbus(property)] fn device(&self) -> Vec<u8> { ay(&self.dev) }
    #[zbus(property)] fn preferred_device(&self) -> Vec<u8> { ay(&self.dev) }
    #[zbus(property)] fn size(&self) -> u64 { self.size }
    #[zbus(property)] fn id_type(&self) -> String { self.idtype.clone() }
    #[zbus(property)] fn id_label(&self) -> String { self.label.clone() }
    #[zbus(property)] fn crypto_backing_device(&self) -> OwnedObjectPath { op("/") }
    fn format(&self, _t: String, _o: HashMap<String, OwnedValue>) {}
}

struct Table;
#[interface(name = "org.freedesktop.UDisks2.PartitionTable")]
impl Table {
    #[zbus(property)] fn r#type(&self) -> String { "gpt".into() }
}

struct Part { table: String, offset: u64, size: u64, number: u32, name: String }
#[interface(name = "org.freedesktop.UDisks2.Partition")]
impl Part {
    #[zbus(property)] fn table(&self) -> OwnedObjectPath { op(&self.table) }
    #[zbus(property)] fn offset(&self) -> u64 { self.offset }
    #[zbus(property)] fn size(&self) -> u64 { self.size }
    #[zbus(property)] fn number(&self) -> u32 { self.number }
    #[zbus(property)] fn name(&self) -> String { self.name.clone() }
    fn delete(&self, _o: HashMap<String, OwnedValue>) {}
}

struct Fs { mounts: Vec<String> }
#[interface(name = "org.freedesktop.UDisks2.Filesystem")]
impl Fs {
    #[zbus(property)] fn mount_points(&self) -> Vec<Vec<u8>> { self.mounts.iter().map(|m| ay(m)).collect() }
    fn mount(&mut self, _o: HashMap<String, OwnedValue>) -> String { "/run/media/user/STICK".into() }
    fn unmount(&self, _o: HashMap<String, OwnedValue>) {}
    fn check(&self, _o: HashMap<String, OwnedValue>) -> bool { true }
}

fn main() -> zbus::Result<()> {
    let d1 = "/org/freedesktop/UDisks2/drives/Samsung_SSD_980";
    let d2 = "/org/freedesktop/UDisks2/drives/SanDisk_Ultra";
    let nv = "/org/freedesktop/UDisks2/block_devices/nvme0n1";
    let sd = "/org/freedesktop/UDisks2/block_devices/sda";
    let gb = 1_000_000_000u64;
    let mib = 1u64 << 20;
    let c = zbus::blocking::connection::Builder::session()?
        .name("org.freedesktop.UDisks2")?
        .serve_at("/org/freedesktop/UDisks2", zbus::fdo::ObjectManager)?
        .serve_at(d1, Drive { model: "Samsung SSD 980 PRO 1TB".into(), vendor: "".into(), size: 1000 * gb, bus: "".into(), removable: false, rot: 0, serial: "S5GXNX0T123456".into() })?
        .serve_at(d1, Nvme)?
        .serve_at(d2, Drive { model: "Ultra".into(), vendor: "SanDisk".into(), size: 64 * gb, bus: "usb".into(), removable: true, rot: -1, serial: "".into() })?
        .serve_at(nv, Block { drive: d1.into(), dev: "/dev/nvme0n1".into(), size: 1000 * gb, idtype: "".into(), label: "".into() })?
        .serve_at(nv, Table)?
        .serve_at(format!("{nv}p1"), Block { drive: d1.into(), dev: "/dev/nvme0n1p1".into(), size: 1 * gb, idtype: "vfat".into(), label: "".into() })?
        .serve_at(format!("{nv}p1"), Part { table: nv.into(), offset: mib, size: 1 * gb, number: 1, name: "".into() })?
        .serve_at(format!("{nv}p1"), Fs { mounts: vec!["/boot".into()] })?
        .serve_at(format!("{nv}p2"), Block { drive: d1.into(), dev: "/dev/nvme0n1p2".into(), size: 900 * gb, idtype: "btrfs".into(), label: "".into() })?
        .serve_at(format!("{nv}p2"), Part { table: nv.into(), offset: mib + gb, size: 900 * gb, number: 2, name: "".into() })?
        .serve_at(format!("{nv}p2"), Fs { mounts: vec!["/".into(), "/home".into()] })?
        .serve_at(format!("{nv}p3"), Block { drive: d1.into(), dev: "/dev/nvme0n1p3".into(), size: 32 * gb, idtype: "swap".into(), label: "".into() })?
        .serve_at(format!("{nv}p3"), Part { table: nv.into(), offset: mib + 901 * gb, size: 32 * gb, number: 3, name: "".into() })?
        .serve_at(sd, Block { drive: d2.into(), dev: "/dev/sda".into(), size: 64 * gb, idtype: "".into(), label: "".into() })?
        .serve_at(sd, Table)?
        .serve_at(format!("{sd}1"), Block { drive: d2.into(), dev: "/dev/sda1".into(), size: 32 * gb, idtype: "exfat".into(), label: "STICK".into() })?
        .serve_at(format!("{sd}1"), Part { table: sd.into(), offset: mib, size: 32 * gb, number: 1, name: "".into() })?
        .serve_at(format!("{sd}1"), Fs { mounts: vec![] })?
        .build()?;
    // Held for as long as this runs: dropping it would leave the bus.
    let _conn = c;
    let _ = Value::from(0u8);
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
