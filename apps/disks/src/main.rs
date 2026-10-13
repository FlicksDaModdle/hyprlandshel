//! Disks: drives and what is on them, through UDisks2 on the system bus —
//! the same service the Files app and the shell's USB menu use, which
//! checks with polkit (and asks for a password) wherever an action needs
//! one, so this never runs as root.
//!
//! The whole picture is read with one GetManagedObjects and turned into
//! rows; UDisks' signals (a drive plugged in, a volume mounted elsewhere)
//! read it again. Actions run on threads of their own.
//!
//! HYPRSHELL_DISKS_BUS=session talks to a stand-in on the session bus.

slint::include_modules!();

use hyprshell_kit as kit;
use slint::{Color, ComponentHandle, ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::{Duration, Instant};
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

const UDISKS: &str = "org.freedesktop.UDisks2";
const ROOT: &str = "/org/freedesktop/UDisks2";
const BLOCK: &str = "org.freedesktop.UDisks2.Block";
const FS: &str = "org.freedesktop.UDisks2.Filesystem";
const DRIVE: &str = "org.freedesktop.UDisks2.Drive";
const ATA: &str = "org.freedesktop.UDisks2.Drive.Ata";
const NVME: &str = "org.freedesktop.UDisks2.NVMe.Controller";
const PART: &str = "org.freedesktop.UDisks2.Partition";
const TABLE: &str = "org.freedesktop.UDisks2.PartitionTable";
const CRYPT: &str = "org.freedesktop.UDisks2.Encrypted";
const SWAP: &str = "org.freedesktop.UDisks2.Swapspace";

type Props = HashMap<String, OwnedValue>;
type Objects = HashMap<OwnedObjectPath, HashMap<String, Props>>;
type Opts = HashMap<&'static str, Value<'static>>;

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
        Some(Value::I64(x)) => (*x).max(0) as u64,
        Some(Value::I32(x)) => (*x).max(0) as u64,
        Some(Value::U16(x)) => *x as u64,
        Some(Value::U8(x)) => *x as u64,
        Some(Value::F64(x)) => *x as u64,
        Some(Value::Value(inner)) => match &**inner {
            Value::U8(x) => *x as u64,
            Value::U16(x) => *x as u64,
            Value::U32(x) => *x as u64,
            Value::U64(x) => *x,
            Value::I64(x) => (*x).max(0) as u64,
            Value::I32(x) => (*x).max(0) as u64,
            _ => 0,
        },
        _ => 0,
    }
}
fn f(p: &Props, k: &str) -> f64 {
    match p.get(k).map(|v| &**v) {
        Some(Value::F64(x)) => *x,
        Some(Value::U16(x)) => *x as f64,
        Some(Value::U64(x)) => *x as f64,
        _ => 0.0,
    }
}
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
fn device(p: &Props) -> String {
    p.get("PreferredDevice").map(|v| bytes_str(v)).filter(|d| !d.is_empty()).or_else(|| p.get("Device").map(|v| bytes_str(v))).unwrap_or_default()
}

/// Sizes the way drives are sold: decimal units.
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

fn err_text(e: &zbus::Error) -> String {
    let raw = match e {
        zbus::Error::MethodError(name, desc, _) => desc.clone().unwrap_or_else(|| name.to_string()),
        other => other.to_string(),
    };
    if raw.contains("busy") || raw.contains("Busy") {
        "Something is still using it — close the files and windows on it, then try again".into()
    } else if raw.contains("NotAuthorized") || raw.contains("not authorized") {
        "Not allowed".into()
    } else if raw.contains("Cancelled") || raw.contains("dismissed") {
        "Cancelled".into()
    } else {
        raw
    }
}

fn fs_tint(fs: &str) -> Color {
    let hex = match fs {
        "ext4" | "ext3" | "ext2" => 0x4c8dff,
        "btrfs" => 0x2fb67c,
        "xfs" | "f2fs" => 0x36b3c9,
        "vfat" | "exfat" => 0xe0a526,
        "ntfs" => 0x9466e8,
        "swap" => 0x8a8686,
        "crypto_LUKS" => 0xe8702b,
        _ => 0xd0566b,
    };
    Color::from_rgb_u8((hex >> 16) as u8, (hex >> 8) as u8, hex as u8)
}

const SYSTEM_MOUNTS: [&str; 7] = ["/", "/boot", "/boot/efi", "/efi", "/home", "/usr", "/var"];

fn statvfs(path: &str) -> Option<(u64, u64)> {
    let c = std::ffi::CString::new(path).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return None;
    }
    let total = st.f_blocks as u64 * st.f_frsize as u64;
    let free = st.f_bavail as u64 * st.f_frsize as u64;
    Some((total, total.saturating_sub(free)))
}

fn active_swaps() -> Vec<String> {
    std::fs::read_to_string("/proc/swaps")
        .unwrap_or_default()
        .lines()
        .skip(1)
        .filter_map(|l| l.split_whitespace().next().map(|s| s.to_string()))
        .collect()
}

#[derive(Clone)]
struct DriveInfo {
    path: String,
    whole: String,
    name: String,
    size: u64,
    kind: String,
    icon: String,
    removable: bool,
    can_eject: bool,
    can_power_off: bool,
    summary: String,
    info: Vec<(String, String)>,
}

#[derive(Clone)]
struct PartInfo {
    path: String,
    action_path: String,
    device: String,
    title: String,
    fs: String,
    size: u64,
    offset: u64,
    mount: String,
    can_mount: bool,
    locked: bool,
    unlocked: bool,
    system: bool,
    free: bool,
    used: Option<(u64, u64)>,
}

struct Picture {
    objs: Objects,
    drives: Vec<DriveInfo>,
}

fn read(conn: &Connection) -> zbus::Result<Picture> {
    let m = conn.call_method(Some(UDISKS), ROOT, Some("org.freedesktop.DBus.ObjectManager"), "GetManagedObjects", &())?;
    let objs: Objects = m.body().deserialize()?;
    let mut drives = Vec::new();
    for (path, ifaces) in &objs {
        let Some(d) = ifaces.get(DRIVE) else { continue };
        // The drive's whole-disk block: one naming this drive and not a
        // partition of something else.
        let whole = objs
            .iter()
            .find(|(_, i)| i.get(BLOCK).map(|bk| s(bk, "Drive") == path.as_str()).unwrap_or(false) && !i.contains_key(PART))
            .map(|(p, _)| p.to_string())
            .unwrap_or_default();
        if whole.is_empty() {
            continue;
        }
        let bus = s(d, "ConnectionBus");
        let rot = match d.get("RotationRate").map(|v| &**v) {
            Some(Value::I32(x)) => *x,
            _ => -1,
        };
        let removable = b(d, "Removable") || b(d, "MediaRemovable") || bus == "usb" || bus == "sdio";
        let is_nvme = ifaces.contains_key(NVME) || whole.contains("nvme");
        let media = s(d, "Media");
        let (kind, icon) = if bus == "sdio" || media.starts_with("flash_sd") {
            ("SD card", "drive")
        } else if removable {
            ("USB drive", "drive")
        } else if is_nvme {
            ("NVMe SSD", "chip")
        } else if rot == 0 {
            ("SSD", "disk")
        } else if rot > 0 {
            ("Hard disk", "harddrive")
        } else {
            ("Drive", "disk")
        };
        let vendor = s(d, "Vendor");
        let model = s(d, "Model");
        let name = [vendor.trim(), model.trim()].iter().filter(|x| !x.is_empty()).cloned().collect::<Vec<_>>().join(" ");
        let size = n(d, "Size");
        let mut info = vec![("Model".to_string(), if model.is_empty() { "—".into() } else { model.clone() })];
        let serial = s(d, "Serial");
        if !serial.is_empty() {
            info.push(("Serial".into(), serial));
        }
        let rev = s(d, "Revision");
        if !rev.is_empty() {
            info.push(("Firmware".into(), rev));
        }
        info.push(("Device".into(), objs.get(&OwnedObjectPath::try_from(whole.clone()).unwrap()).and_then(|i| i.get(BLOCK)).map(device).unwrap_or_default()));
        let conn_name = match bus.as_str() {
            "usb" => "USB",
            "sdio" => "SD",
            "ieee1394" => "FireWire",
            _ if is_nvme => "NVMe",
            _ => "SATA",
        };
        drives.push(DriveInfo {
            path: path.to_string(),
            whole,
            name: if name.is_empty() { kind.to_string() } else { name },
            size,
            kind: kind.into(),
            icon: icon.into(),
            removable,
            can_eject: b(d, "Ejectable") && removable,
            can_power_off: b(d, "CanPowerOff") && removable,
            summary: format!("{}  ·  {kind}  ·  {conn_name}", human(size)),
            info,
        });
    }
    // The machine's own drives first, then the plugged-in ones.
    drives.sort_by(|a, b| (a.removable, a.name.clone()).cmp(&(b.removable, b.name.clone())));
    Ok(Picture { objs, drives })
}

/// The drive's volumes in order across it, with the gaps between them.
fn parts_of(pic: &Picture, d: &DriveInfo) -> Vec<PartInfo> {
    let swaps = active_swaps();
    let mut out = Vec::new();
    let whole_ifaces = pic.objs.iter().find(|(p, _)| p.as_str() == d.whole).map(|(_, i)| i);
    let describe = |path: &str, ifaces: &HashMap<String, Props>, offset: u64, size: u64| -> PartInfo {
        let blk = ifaces.get(BLOCK).unwrap();
        let fs_type = s(blk, "IdType");
        // An unlocked volume's own filesystem sits on its cleartext device.
        let clear = pic.objs.iter().find(|(_, i)| i.get(BLOCK).map(|cb| s(cb, "CryptoBackingDevice") == path).unwrap_or(false));
        let (fs_props, fs_path, inner_type, inner_label) = match clear {
            Some((cp, ci)) => (ci.get(FS), cp.to_string(), s(ci.get(BLOCK).unwrap(), "IdType"), s(ci.get(BLOCK).unwrap(), "IdLabel")),
            None => (ifaces.get(FS), path.to_string(), fs_type.clone(), s(blk, "IdLabel")),
        };
        let mounts = fs_props.map(mounts).unwrap_or_default();
        let mount = mounts.first().cloned().unwrap_or_default();
        let dev = device(blk);
        let is_swap = fs_type == "swap" || ifaces.contains_key(SWAP);
        let system = mounts.iter().any(|m| SYSTEM_MOUNTS.contains(&m.as_str())) || (is_swap && swaps.iter().any(|s| *s == dev));
        let pname = ifaces.get(PART).map(|p| s(p, "Name")).unwrap_or_default();
        let label = if !inner_label.is_empty() { inner_label } else { pname };
        let title = if !label.is_empty() {
            label
        } else if mount == "/" {
            "System".into()
        } else if mount == "/home" {
            "Home".into()
        } else if mount.starts_with("/boot") || mount == "/efi" {
            "Boot".into()
        } else if is_swap {
            "Swap".into()
        } else if fs_type == "crypto_LUKS" {
            "Encrypted volume".into()
        } else {
            format!("{} volume", human(size))
        };
        PartInfo {
            path: path.to_string(),
            action_path: fs_path,
            device: dev,
            title,
            fs: if clear.is_some() { format!("{inner_type} (encrypted)") } else { fs_type.clone() },
            size,
            offset,
            used: if mount.is_empty() { None } else { statvfs(&mount) },
            mount,
            can_mount: fs_props.is_some(),
            locked: fs_type == "crypto_LUKS" && clear.is_none(),
            unlocked: clear.is_some(),
            system,
            free: false,
        }
    };
    let has_table = whole_ifaces.map(|i| i.contains_key(TABLE)).unwrap_or(false);
    if !has_table {
        if let Some(i) = whole_ifaces {
            if i.get(BLOCK).map(|bk| !s(bk, "IdType").is_empty()).unwrap_or(false) {
                out.push(describe(&d.whole, i, 0, d.size));
            }
        }
        return out;
    }
    let mut parts: Vec<(u64, u64, String)> = pic
        .objs
        .iter()
        .filter_map(|(p, i)| {
            let pt = i.get(PART)?;
            (s(pt, "Table") == d.whole).then(|| (n(pt, "Offset"), n(pt, "Size"), p.to_string()))
        })
        .collect();
    parts.sort();
    let mut at: u64 = 1 << 20;
    let gap = |from: u64, to: u64, out: &mut Vec<PartInfo>| {
        // Under 16 MB is alignment, not space anyone can use.
        if to > from + (16 << 20) {
            out.push(PartInfo {
                path: String::new(),
                action_path: String::new(),
                device: String::new(),
                title: "Free space".into(),
                fs: String::new(),
                size: to - from,
                offset: from,
                mount: String::new(),
                can_mount: false,
                locked: false,
                unlocked: false,
                system: false,
                free: true,
                used: None,
            });
        }
    };
    for (off, size, p) in &parts {
        gap(at, *off, &mut out);
        let ifaces = pic.objs.iter().find(|(op, _)| op.as_str() == p).map(|(_, i)| i).unwrap();
        out.push(describe(p, ifaces, *off, *size));
        at = off + size;
    }
    gap(at, d.size.saturating_sub(1 << 20), &mut out);
    out
}

/// What the drive says about its own health.
fn health(conn: &Connection, pic: &Picture, d: &DriveInfo) -> (bool, bool, String, Vec<(String, String)>) {
    let Some(ifaces) = pic.objs.iter().find(|(p, _)| p.as_str() == d.path).map(|(_, i)| i) else {
        return (false, false, String::new(), Vec::new());
    };
    let mut rows = Vec::new();
    if let Some(c) = ifaces.get(NVME) {
        let attrs: HashMap<String, OwnedValue> = conn
            .call_method(Some(UDISKS), d.path.as_str(), Some(NVME), "SmartGetAttributes", &(Opts::new(),))
            .ok()
            .and_then(|m| m.body().deserialize().ok())
            .unwrap_or_default();
        let warn = match c.get("SmartCriticalWarning").map(|v| &**v) {
            Some(Value::Array(a)) => a.iter().filter_map(|x| if let Value::Str(s) = x { Some(s.to_string()) } else { None }).collect::<Vec<_>>(),
            _ => Vec::new(),
        };
        let used = n(&attrs, "percent_used");
        let spare = n(&attrs, "avail_spare");
        let temp = n(c, "SmartTemperature");
        let hours = n(c, "SmartPowerOnHours");
        rows.push(("Wear".to_string(), format!("{used}% of its rated life used")));
        if spare > 0 {
            rows.push(("Spare blocks".into(), format!("{spare}% left")));
        }
        if temp > 0 {
            rows.push(("Temperature".into(), format!("{} °C", temp as i64 - 273)));
        }
        if hours > 0 {
            rows.push(("Powered on".into(), format!("{} hours", hours)));
        }
        let written = n(&attrs, "total_data_written");
        if written > 0 {
            rows.push(("Written".into(), human(written)));
        }
        let media = n(&attrs, "media_errors");
        rows.push(("Media errors".into(), media.to_string()));
        let good = warn.is_empty() && used < 90 && media == 0;
        let title = if !warn.is_empty() {
            format!("The drive reports a problem: {}", warn.join(", "))
        } else if used >= 90 {
            "Near the end of its rated life: keep backups".into()
        } else {
            "No problems reported".into()
        };
        return (true, good, title, rows);
    }
    if let Some(a) = ifaces.get(ATA) {
        if !b(a, "SmartSupported") {
            return (false, false, "This drive doesn't report its health".into(), rows);
        }
        if !b(a, "SmartEnabled") {
            return (false, false, "Health reporting is off on this drive".into(), rows);
        }
        let failing = b(a, "SmartFailing");
        let bad = n(a, "SmartNumBadSectors");
        let failing_attrs = n(a, "SmartNumAttributesFailing");
        let temp = f(a, "SmartTemperature");
        let secs = n(a, "SmartPowerOnSeconds");
        if temp > 0.0 {
            rows.push(("Temperature".into(), format!("{:.0} °C", temp - 273.15)));
        }
        if secs > 0 {
            rows.push(("Powered on".into(), format!("{} hours", secs / 3600)));
        }
        rows.push(("Bad sectors".into(), bad.to_string()));
        let selftest = s(a, "SmartSelftestStatus");
        if !selftest.is_empty() {
            rows.push(("Last self-test".into(), selftest.replace('_', " ")));
        }
        let good = !failing && bad == 0 && failing_attrs == 0;
        let title = if failing {
            "The drive expects to fail soon: back it up now".into()
        } else if bad > 0 {
            format!("{bad} bad sectors: keep backups")
        } else {
            "No problems reported".into()
        };
        return (true, good, title, rows);
    }
    (false, false, if d.removable { "Removable drives don't report their health".into() } else { "This drive doesn't report its health".into() }, rows)
}

// ── the speed test ──────────────────────────────────────────────────────

/// Read speed and the time to find data, through a descriptor UDisks
/// opens for exactly this (OpenForBenchmark, with polkit's say-so).
/// Reads only.
fn benchmark(fd: std::os::fd::OwnedFd, size: u64, progress: impl Fn(f32)) -> Result<(f64, f64), String> {
    use std::os::fd::AsRawFd;
    let raw = fd.as_raw_fd();
    let chunk: usize = 4 << 20;
    let layout = std::alloc::Layout::from_size_align(chunk, 4096).unwrap();
    let buf = unsafe { std::alloc::alloc(layout) };
    if buf.is_null() {
        return Err("out of memory".into());
    }
    let read_at = |off: u64, len: usize| -> bool {
        let r = unsafe { libc::pread(raw, buf as *mut libc::c_void, len, off as libc::off_t) };
        r > 0
    };
    unsafe { libc::posix_fadvise(raw, 0, 0, libc::POSIX_FADV_DONTNEED) };
    // Sequential: 48 runs of 4 MB × 4, spread across the drive.
    let samples = 48u64;
    let span = size.saturating_sub(16 << 20);
    let mut bytes = 0u64;
    let t0 = Instant::now();
    for i in 0..samples {
        let base = (span / samples * i) & !4095;
        for k in 0..4u64 {
            if read_at(base + k * chunk as u64, chunk) {
                bytes += chunk as u64;
            }
        }
        progress(i as f32 / samples as f32 * 0.8);
    }
    let secs = t0.elapsed().as_secs_f64().max(1e-6);
    let mbps = bytes as f64 / secs / 1e6;
    // Seeking: 200 small reads at scattered places.
    let mut seed: u64 = 0x2545F4914F6CDD1D;
    let t1 = Instant::now();
    let tries = 200;
    for i in 0..tries {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let off = (seed % span.max(1)) & !4095;
        read_at(off, 4096);
        if i % 20 == 0 {
            progress(0.8 + i as f32 / tries as f32 * 0.2);
        }
    }
    let access_ms = t1.elapsed().as_secs_f64() * 1000.0 / tries as f64;
    unsafe { std::alloc::dealloc(buf, layout) };
    drop(fd);
    if bytes == 0 {
        return Err("Nothing could be read".into());
    }
    Ok((mbps, access_ms))
}

// ── the window ──────────────────────────────────────────────────────────

struct App {
    ui: slint::Weak<AppWindow>,
    conn: Connection,
    pic: RefCell<Option<Picture>>,
    parts: RefCell<Vec<PartInfo>>,
    toast_timer: slint::Timer,
}

impl App {
    fn ui(&self) -> AppWindow {
        self.ui.upgrade().unwrap()
    }
    fn toast(&self, t: &str, bad: bool) {
        let ui = self.ui();
        ui.global::<Disks>().set_toast(t.into());
        ui.global::<Disks>().set_toast_bad(bad);
        let w = self.ui.clone();
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(3200), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Disks>().set_toast(SharedString::new());
            }
        });
    }
    fn drive(&self) -> Option<DriveInfo> {
        let i = self.ui().global::<Disks>().get_drive().max(0) as usize;
        self.pic.borrow().as_ref().and_then(|p| p.drives.get(i).cloned())
    }

    fn reload(self: &Rc<Self>) {
        let conn = self.conn.clone();
        let a = self.clone();
        kit::spawn(
            move || read(&conn).map_err(|e| err_text(&e)),
            move |r| {
                let ui = a.ui();
                let g = ui.global::<Disks>();
                g.set_ready(true);
                match r {
                    Err(e) => {
                        g.set_problem(e.into());
                        // UDisks may still be starting: look again shortly.
                        let b = a.clone();
                        slint::Timer::single_shot(Duration::from_secs(5), move || b.reload());
                    }
                    Ok(pic) => {
                        g.set_problem("".into());
                        let rows: Vec<Drive> = pic
                            .drives
                            .iter()
                            .map(|d| Drive {
                                path: d.path.clone().into(),
                                name: d.name.clone().into(),
                                size: human(d.size).into(),
                                kind: d.kind.clone().into(),
                                icon: d.icon.clone().into(),
                                removable: d.removable,
                                can_eject: d.can_eject,
                                can_power_off: d.can_power_off,
                            })
                            .collect();
                        let count = rows.len() as i32;
                        g.set_drives(ModelRc::new(VecModel::from(rows)));
                        if g.get_drive() >= count {
                            g.set_drive(0);
                        }
                        *a.pic.borrow_mut() = Some(pic);
                        a.show_drive();
                    }
                }
            },
        );
    }

    fn show_drive(self: &Rc<Self>) {
        let ui = self.ui();
        let g = ui.global::<Disks>();
        let Some(d) = self.drive() else { return };
        let parts = {
            let pic = self.pic.borrow();
            parts_of(pic.as_ref().unwrap(), &d)
        };
        g.set_drive_summary(d.summary.clone().into());
        g.set_drive_info(ModelRc::new(VecModel::from(d.info.iter().map(|(k, v)| KV { key: k.into(), value: v.into() }).collect::<Vec<_>>())));
        let total = d.size.max(1) as f32;
        let rows: Vec<Part> = parts
            .iter()
            .map(|p| Part {
                path: p.path.clone().into(),
                device: p.device.clone().into(),
                title: p.title.clone().into(),
                fs: p.fs.clone().into(),
                size: human(p.size).into(),
                offset_frac: p.offset as f32 / total,
                size_frac: p.size as f32 / total,
                used_frac: p.used.map(|(t, u)| if t > 0 { u as f32 / t as f32 } else { 0.0 }).unwrap_or(-1.0),
                used: p.used.map(|(t, u)| format!("{} of {} used", human(u), human(t))).unwrap_or_default().into(),
                mount: p.mount.clone().into(),
                mounted: !p.mount.is_empty(),
                can_mount: p.can_mount,
                locked: p.locked,
                unlocked: p.unlocked,
                system: p.system,
                free: p.free,
                tint: fs_tint(p.fs.split(' ').next().unwrap_or("")),
                offset: p.offset.to_string().into(),
                free_bytes: p.size.to_string().into(),
            })
            .collect();
        let keep = g.get_part();
        let n = rows.len() as i32;
        g.set_parts(ModelRc::new(VecModel::from(rows)));
        g.set_part(if keep >= 0 && keep < n { keep } else { -1 });
        *self.parts.borrow_mut() = parts;
        // Health is a call or two to the drive: off the UI thread.
        let conn = self.conn.clone();
        let a = self.clone();
        let pic_drives = d.clone();
        let objs = self.pic.borrow().as_ref().map(|p| p.objs.clone()).unwrap_or_default();
        kit::spawn(
            move || {
                let pic = Picture { objs, drives: vec![] };
                health(&conn, &pic, &pic_drives)
            },
            move |(known, good, title, rows)| {
                let ui = a.ui();
                let g = ui.global::<Disks>();
                g.set_health_known(known);
                g.set_health_good(good);
                g.set_health_title(title.into());
                g.set_health(ModelRc::new(VecModel::from(rows.into_iter().map(|(k, v)| KV { key: k.into(), value: v.into() }).collect::<Vec<_>>())));
            },
        );
    }

    fn part_by_path(&self, path: &str) -> Option<PartInfo> {
        self.parts.borrow().iter().find(|p| p.path == path).cloned()
    }

    /// One UDisks method on one object, off the UI thread.
    fn call<B>(self: &Rc<Self>, path: String, iface: &'static str, method: &'static str, body: B, done: &'static str)
    where
        B: serde::Serialize + zbus::zvariant::DynamicType + Send + 'static,
    {
        self.ui().global::<Disks>().set_busy(true);
        let conn = self.conn.clone();
        let a = self.clone();
        kit::spawn(
            move || conn.call_method(Some(UDISKS), path.as_str(), Some(iface), method, &body).map(|_| ()).map_err(|e| err_text(&e)),
            move |r| {
                a.ui().global::<Disks>().set_busy(false);
                match r {
                    Ok(_) => {
                        if !done.is_empty() {
                            a.toast(done, false);
                        }
                    }
                    Err(e) => a.toast(&e, true),
                }
                a.reload();
            },
        );
    }
}

fn opts() -> Opts {
    Opts::new()
}

fn main() {
    kit::init("hyprshell-disks");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-disks");

    let conn = if std::env::var("HYPRSHELL_DISKS_BUS").map(|v| v == "session").unwrap_or(false) {
        Connection::session()
    } else {
        Connection::system()
    };
    let conn = match conn {
        Ok(c) => c,
        Err(e) => {
            ui.global::<Disks>().set_ready(true);
            ui.global::<Disks>().set_problem(format!("Couldn't reach the system bus: {e}").into());
            ui.run().expect("run");
            return;
        }
    };
    let app = Rc::new(App { ui: ui.as_weak(), conn: conn.clone(), pic: RefCell::new(None), parts: RefCell::new(Vec::new()), toast_timer: slint::Timer::default() });
    app.reload();

    // UDisks' own signals: a drive plugged in, a volume mounted elsewhere.
    {
        let w = ui.as_weak();
        let conn = conn.clone();
        std::thread::spawn(move || {
            let Ok(rule) = zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).sender(UDISKS).map(|b| b.build()) else { return };
            let Ok(iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(64)) else { return };
            for _ in iter.flatten() {
                let w = w.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(ui) = w.upgrade() {
                        ui.invoke_changed();
                    }
                });
            }
        });
    }
    let a = app.clone();
    let debounce = Rc::new(slint::Timer::default());
    let d2 = debounce.clone();
    ui.on_changed(move || {
        let a = a.clone();
        d2.start(slint::TimerMode::SingleShot, Duration::from_millis(400), move || a.reload());
    });

    let g = ui.global::<Disks>();
    let a = app.clone();
    g.on_pick_drive(move |i| {
        let ui = a.ui();
        let g = ui.global::<Disks>();
        g.set_drive(i);
        g.set_part(-1);
        g.set_bench_read("".into());
        g.set_bench_access("".into());
        g.set_bench_note("".into());
        a.show_drive();
    });
    let a = app.clone();
    g.on_mount(move |p| {
        let Some(part) = a.part_by_path(&p) else { return };
        a.call(part.action_path, FS, "Mount", (opts(),), "Mounted");
    });
    let a = app.clone();
    g.on_unmount(move |p| {
        let Some(part) = a.part_by_path(&p) else { return };
        a.call(part.action_path, FS, "Unmount", (opts(),), "Unmounted");
    });
    let a = app.clone();
    g.on_unlock(move |p, pass| {
        // Straight to UDisks over D-Bus, never on a command line.
        a.call(p.to_string(), CRYPT, "Unlock", (pass.to_string(), opts()), "Unlocked");
    });
    let a = app.clone();
    g.on_lock(move |p| a.call(p.to_string(), CRYPT, "Lock", (opts(),), "Locked"));
    let a = app.clone();
    g.on_rename(move |p, label| {
        let Some(part) = a.part_by_path(&p) else { return };
        a.call(part.action_path, FS, "SetLabel", (label.to_string(), opts()), "Renamed");
    });
    let a = app.clone();
    g.on_check(move |p| {
        let Some(part) = a.part_by_path(&p) else { return };
        a.ui().global::<Disks>().set_busy(true);
        let conn = a.conn.clone();
        let b2 = a.clone();
        kit::spawn(
            move || {
                conn.call_method(Some(UDISKS), part.action_path.as_str(), Some(FS), "Check", &(opts(),))
                    .and_then(|m| m.body().deserialize::<bool>())
                    .map_err(|e| err_text(&e))
            },
            move |r| {
                b2.ui().global::<Disks>().set_busy(false);
                match r {
                    Ok(true) => b2.toast("No problems found", false),
                    Ok(false) => b2.toast("Problems found: repair it from a terminal with fsck", true),
                    Err(e) => b2.toast(&e, true),
                }
            },
        );
    });
    let a = app.clone();
    g.on_format(move |p, fstype, label| {
        let mut o = opts();
        if !label.is_empty() {
            o.insert("label", Value::from(label.to_string()));
        }
        o.insert("update-partition-type", Value::from(true));
        a.call(p.to_string(), BLOCK, "Format", (fstype.to_string(), o), "Formatted");
    });
    let a = app.clone();
    g.on_delete(move |p| a.call(p.to_string(), PART, "Delete", (opts(),), "Deleted"));
    let a = app.clone();
    g.on_create(move |_drive, offset, frac, fstype, label| {
        let Some(d) = a.drive() else { return };
        let offset: u64 = offset.parse().unwrap_or(0);
        let free = a.parts.borrow().iter().find(|p| p.free && p.offset == offset).map(|p| p.size).unwrap_or(0);
        // Whole megabytes, as partitioning tools align them.
        let size = ((free as f64 * frac.clamp(0.01, 1.0) as f64) as u64) & !((1u64 << 20) - 1);
        let mut fo = opts();
        if !label.is_empty() {
            fo.insert("label", Value::from(label.to_string()));
        }
        a.call(d.whole, TABLE, "CreatePartitionAndFormat", (offset, size, String::new(), String::new(), opts(), fstype.to_string(), fo), "Created");
    });
    let a = app.clone();
    g.on_eject(move |p| a.call(p.to_string(), DRIVE, "Eject", (opts(),), "Ejected — it can be pulled out"));
    let a = app.clone();
    g.on_power_off(move |p| {
        // Every filesystem off it first, then the power.
        let parts = a.parts.borrow().clone();
        let conn = a.conn.clone();
        a.ui().global::<Disks>().set_busy(true);
        let b2 = a.clone();
        let p = p.to_string();
        kit::spawn(
            move || {
                for part in parts.iter().filter(|x| !x.mount.is_empty()) {
                    conn.call_method(Some(UDISKS), part.action_path.as_str(), Some(FS), "Unmount", &(opts(),)).map_err(|e| err_text(&e))?;
                }
                conn.call_method(Some(UDISKS), p.as_str(), Some(DRIVE), "PowerOff", &(opts(),)).map(|_| ()).map_err(|e| err_text(&e))
            },
            move |r| {
                b2.ui().global::<Disks>().set_busy(false);
                match r {
                    Ok(_) => b2.toast("Powered off — it can be pulled out", false),
                    Err(e) => b2.toast(&e, true),
                }
                b2.reload();
            },
        );
    });
    g.on_open(move |m| {
        let _ = std::process::Command::new("xdg-open").arg(m.as_str()).spawn();
    });
    let a2 = app.clone();
    g.on_benchmark(move |_| {
        let Some(d) = a2.drive() else { return };
        let ui = a2.ui();
        let g = ui.global::<Disks>();
        g.set_bench_running(true);
        g.set_bench_progress(0.0);
        g.set_bench_note("Reading only: nothing on the drive is changed.".into());
        let conn = a2.conn.clone();
        let w = ui.as_weak();
        let a = a2.clone();
        kit::spawn(
            move || {
                let m = conn
                    .call_method(Some(UDISKS), d.whole.as_str(), Some(BLOCK), "OpenForBenchmark", &(opts(),))
                    .map_err(|e| err_text(&e))?;
                let fd: zbus::zvariant::OwnedFd = m.body().deserialize().map_err(|e| e.to_string())?;
                let fd: std::os::fd::OwnedFd = fd.into();
                benchmark(fd, d.size, |p| {
                    let w = w.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(ui) = w.upgrade() {
                            ui.global::<Disks>().set_bench_progress(p);
                        }
                    });
                })
            },
            move |r| {
                let ui = a.ui();
                let g = ui.global::<Disks>();
                g.set_bench_running(false);
                match r {
                    Ok((mbps, ms)) => {
                        g.set_bench_read(if mbps >= 1000.0 { format!("{:.2} GB/s", mbps / 1000.0) } else { format!("{mbps:.0} MB/s") }.into());
                        g.set_bench_access(if ms < 1.0 { format!("{:.2} ms", ms) } else { format!("{ms:.1} ms") }.into());
                        g.set_bench_note("Reading only: nothing on the drive was changed.".into());
                    }
                    Err(e) => {
                        g.set_bench_note(e.clone().into());
                        a.toast(&e, true);
                    }
                }
            },
        );
    });

    ui.run().expect("run");
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sizes() {
        assert_eq!(human(1_000_204_886_016), "1.0 TB");
        assert_eq!(human(512_110_190_592), "512 GB");
    }
}
