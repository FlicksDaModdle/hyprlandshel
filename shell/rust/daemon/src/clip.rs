//! Clipboard history: everything copied, as the compositor announces it
//! over the wlroots data-control protocol (which Hyprland speaks), kept so
//! an earlier copy can be put back (services/Clipboard.qml, Super+Shift+V).
//!
//! Commands:  clip-enable {on, max}   start or stop keeping history; off
//!                                    forgets it
//!            clip-copy {id}          put an entry back on the clipboard
//!            clip-delete {id}
//!            clip-clear
//!            clip-list
//! Events:    clip {available, enabled, entries: [{id, kind, preview,
//!                  size, time, path?}]}
//!
//! Kept in $XDG_RUNTIME_DIR (memory, this login only, readable by this
//! user alone), so a shell reload keeps the history and logging out ends
//! it. Not kept: what a password manager marks as secret
//! (x-kde-passwordManagerHint), anything over 4 MB of text or 16 MB of
//! image. Also: when the program that copied something closes, Wayland's
//! clipboard goes empty with it; the newest entry is offered again so a
//! paste still works.

use crate::out;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{event_created_child, Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols_wlr::data_control::v1::client::{
    zwlr_data_control_device_v1::{self, ZwlrDataControlDeviceV1},
    zwlr_data_control_manager_v1::ZwlrDataControlManagerV1,
    zwlr_data_control_offer_v1::{self, ZwlrDataControlOfferV1},
    zwlr_data_control_source_v1::{self, ZwlrDataControlSourceV1},
};

/// Offered alongside our own copies, so they are known when they come
/// back as the selection.
const MARK: &str = "application/x-hyprshell-clipboard";
const SECRET: &str = "x-kde-passwordManagerHint";
const TEXT_TYPES: [&str; 6] = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT", "text/plain;charset=UTF-8"];
const MAX_TEXT: usize = 4 << 20;
const MAX_IMAGE: usize = 16 << 20;
const MAX_IMAGES: usize = 20;
const PREVIEW: usize = 400;

enum Msg {
    Cmd(Value),
    Got { mime: String, bytes: Vec<u8> },
    /// The clipboard went empty (its owner closed).
    Empty,
    Lost(String),
}

// ══ Wayland ═════════════════════════════════════════════════════════════

struct State {
    tx: Sender<Msg>,
}

struct Wl {
    conn: Connection,
    qh: QueueHandle<State>,
    mgr: ZwlrDataControlManagerV1,
    dev: ZwlrDataControlDeviceV1,
}

struct SourceData {
    bytes: Arc<Vec<u8>>,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(_: &mut Self, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(_: &mut Self, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ZwlrDataControlManagerV1, ()> for State {
    fn event(_: &mut Self, _: &ZwlrDataControlManagerV1, _: <ZwlrDataControlManagerV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ZwlrDataControlOfferV1, Mutex<Vec<String>>> for State {
    fn event(_: &mut Self, _: &ZwlrDataControlOfferV1, ev: zwlr_data_control_offer_v1::Event, mimes: &Mutex<Vec<String>>, _: &Connection, _: &QueueHandle<Self>) {
        if let zwlr_data_control_offer_v1::Event::Offer { mime_type } = ev {
            mimes.lock().unwrap().push(mime_type);
        }
    }
}

impl Dispatch<ZwlrDataControlDeviceV1, ()> for State {
    fn event(st: &mut Self, _: &ZwlrDataControlDeviceV1, ev: zwlr_data_control_device_v1::Event, _: &(), conn: &Connection, _: &QueueHandle<Self>) {
        match ev {
            zwlr_data_control_device_v1::Event::Selection { id: Some(offer) } => {
                let mimes = offer.data::<Mutex<Vec<String>>>().map(|m| m.lock().unwrap().clone()).unwrap_or_default();
                if let Some(mime) = pick(&mimes) {
                    receive(conn, &offer, mime, st.tx.clone());
                }
                offer.destroy();
            }
            zwlr_data_control_device_v1::Event::Selection { id: None } => {
                let _ = st.tx.send(Msg::Empty);
            }
            zwlr_data_control_device_v1::Event::PrimarySelection { id: Some(offer) } => offer.destroy(),
            zwlr_data_control_device_v1::Event::Finished => {
                let _ = st.tx.send(Msg::Lost("the compositor stopped the clipboard watch".into()));
            }
            _ => {}
        }
    }
    event_created_child!(State, ZwlrDataControlDeviceV1, [
        zwlr_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ZwlrDataControlOfferV1, Mutex::new(Vec::new())),
    ]);
}

impl Dispatch<ZwlrDataControlSourceV1, SourceData> for State {
    fn event(_: &mut Self, src: &ZwlrDataControlSourceV1, ev: zwlr_data_control_source_v1::Event, data: &SourceData, _: &Connection, _: &QueueHandle<Self>) {
        match ev {
            zwlr_data_control_source_v1::Event::Send { fd, .. } => {
                // A slow reader must not hold up the event loop.
                let bytes = data.bytes.clone();
                std::thread::spawn(move || {
                    let mut f = std::fs::File::from(fd);
                    let _ = f.write_all(&bytes);
                });
            }
            zwlr_data_control_source_v1::Event::Cancelled => src.destroy(),
            _ => {}
        }
    }
}

/// Which of the offered types to keep, or None to keep nothing.
fn pick(mimes: &[String]) -> Option<String> {
    if mimes.iter().any(|m| m == SECRET || m == MARK) {
        return None;
    }
    for t in TEXT_TYPES {
        if mimes.iter().any(|m| m == t) {
            return Some(t.to_string());
        }
    }
    if mimes.iter().any(|m| m == "image/png") {
        return Some("image/png".into());
    }
    mimes.iter().find(|m| m.starts_with("image/")).cloned()
}

/// Ask the owner for the data and read it on a thread of its own: the
/// owner may be slow, or never close the pipe at all.
fn receive(conn: &Connection, offer: &ZwlrDataControlOfferV1, mime: String, tx: Sender<Msg>) {
    let mut fds = [0; 2];
    if unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } != 0 {
        return;
    }
    let (r, w) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    offer.receive(mime.clone(), w.as_fd());
    let _ = conn.flush();
    drop(w);
    let limit = if mime.starts_with("image/") { MAX_IMAGE } else { MAX_TEXT };
    std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut f = std::fs::File::from(r);
        let mut bytes = Vec::new();
        let mut buf = [0u8; 65536];
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            let mut p = libc::pollfd { fd: f.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            if unsafe { libc::poll(&mut p, 1, left.as_millis() as i32) } <= 0 {
                return;
            }
            match f.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    bytes.extend_from_slice(&buf[..n]);
                    if bytes.len() > limit {
                        return;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
                Err(_) => return,
            }
        }
        if !bytes.is_empty() {
            let _ = tx.send(Msg::Got { mime, bytes });
        }
    });
}

fn connect(tx: Sender<Msg>) -> Result<Arc<Wl>, String> {
    let conn = Connection::connect_to_env().map_err(|e| format!("no Wayland display: {e}"))?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn).map_err(|e| e.to_string())?;
    let qh = queue.handle();
    let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=8, ()).map_err(|_| "no seat".to_string())?;
    let mgr: ZwlrDataControlManagerV1 = globals
        .bind(&qh, 1..=2, ())
        .map_err(|_| "the compositor has no clipboard-manager protocol (wlr-data-control)".to_string())?;
    let dev = mgr.get_data_device(&seat, &qh, ());
    let wl = Arc::new(Wl { conn: conn.clone(), qh, mgr, dev });
    let mut st = State { tx: tx.clone() };
    std::thread::spawn(move || loop {
        if let Err(e) = queue.blocking_dispatch(&mut st) {
            let _ = st.tx.send(Msg::Lost(e.to_string()));
            return;
        }
    });
    Ok(wl)
}

// ══ history ═════════════════════════════════════════════════════════════

struct Entry {
    id: u64,
    hash: u64,
    mime: String,
    text: Option<String>,
    path: Option<PathBuf>,
    size: usize,
    time: u64,
}

impl Entry {
    fn summary(&self) -> Value {
        let mut o = json!({
            "id": self.id, "kind": if self.text.is_some() { "text" } else { "image" },
            "size": self.size, "time": self.time, "mime": self.mime
        });
        if let Some(t) = &self.text {
            let p: String = t.chars().take(PREVIEW).collect();
            o["preview"] = json!(p);
            o["lines"] = json!(t.lines().count().max(1));
        }
        if let Some(p) = &self.path {
            o["path"] = json!(p.to_string_lossy());
        }
        o
    }
    fn saved(&self) -> Value {
        json!({ "id": self.id, "hash": self.hash, "mime": self.mime, "text": self.text,
                "path": self.path.as_ref().map(|p| p.to_string_lossy().to_string()),
                "size": self.size, "time": self.time })
    }
    fn bytes(&self) -> Option<Vec<u8>> {
        match (&self.text, &self.path) {
            (Some(t), _) => Some(t.clone().into_bytes()),
            (None, Some(p)) => std::fs::read(p).ok(),
            _ => None,
        }
    }
}

fn dir() -> Option<PathBuf> {
    let rt = std::env::var_os("XDG_RUNTIME_DIR")?;
    let d = PathBuf::from(rt).join("hyprshell-clipboard");
    std::fs::create_dir_all(&d).ok()?;
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(&d, std::fs::Permissions::from_mode(0o700));
    Some(d)
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn hash(b: &[u8]) -> u64 {
    let mut h = std::collections::hash_map::DefaultHasher::new();
    b.hash(&mut h);
    h.finish()
}

struct History {
    entries: VecDeque<Entry>,
    next: u64,
    max: usize,
}

impl History {
    fn load() -> History {
        let mut h = History { entries: VecDeque::new(), next: 1, max: 100 };
        let Some(d) = dir() else { return h };
        let Ok(text) = std::fs::read_to_string(d.join("history.json")) else { return h };
        let Ok(Value::Array(list)) = serde_json::from_str::<Value>(&text) else { return h };
        for e in list {
            let ent = Entry {
                id: e["id"].as_u64().unwrap_or(0),
                hash: e["hash"].as_u64().unwrap_or(0),
                mime: e["mime"].as_str().unwrap_or("").to_string(),
                text: e["text"].as_str().map(|s| s.to_string()),
                path: e["path"].as_str().map(PathBuf::from),
                size: e["size"].as_u64().unwrap_or(0) as usize,
                time: e["time"].as_u64().unwrap_or(0),
            };
            if ent.text.is_none() && !ent.path.as_ref().map(|p| p.exists()).unwrap_or(false) {
                continue;
            }
            h.next = h.next.max(ent.id + 1);
            h.entries.push_back(ent);
        }
        h
    }
    fn save(&self) {
        let Some(d) = dir() else { return };
        let list: Vec<Value> = self.entries.iter().map(|e| e.saved()).collect();
        let tmp = d.join("history.json.tmp");
        use std::os::unix::fs::OpenOptionsExt;
        let ok = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .and_then(|mut f| f.write_all(Value::Array(list).to_string().as_bytes()));
        if ok.is_ok() {
            let _ = std::fs::rename(&tmp, d.join("history.json"));
        }
    }
    fn emit(&self, available: bool, enabled: bool, error: Option<&str>) {
        let list: Vec<Value> = self.entries.iter().map(|e| e.summary()).collect();
        let mut ev = json!({ "ev": "clip", "available": available, "enabled": enabled, "entries": list });
        if let Some(e) = error {
            ev["error"] = json!(e);
        }
        out::emit(ev);
    }
    fn remove_at(&mut self, i: usize) {
        if let Some(e) = self.entries.remove(i) {
            if let Some(p) = e.path {
                let _ = std::fs::remove_file(p);
            }
        }
    }
    fn trim(&mut self) {
        while self.entries.len() > self.max {
            let i = self.entries.len() - 1;
            self.remove_at(i);
        }
        let mut images = 0;
        let mut i = 0;
        while i < self.entries.len() {
            if self.entries[i].path.is_some() {
                images += 1;
                if images > MAX_IMAGES {
                    self.remove_at(i);
                    continue;
                }
            }
            i += 1;
        }
    }
    /// Something copied: to the top, or moved there if it was already in.
    fn add(&mut self, mime: String, bytes: Vec<u8>) -> bool {
        let h = hash(&bytes);
        if let Some(i) = self.entries.iter().position(|e| e.hash == h) {
            if i == 0 {
                return false;
            }
            let mut e = self.entries.remove(i).unwrap();
            e.time = now();
            self.entries.push_front(e);
            return true;
        }
        let id = self.next;
        self.next += 1;
        let size = bytes.len();
        let (text, path) = if mime.starts_with("image/") {
            let ext = mime.trim_start_matches("image/").split(['+', ';']).next().unwrap_or("img").to_string();
            let Some(d) = dir() else { return false };
            let p = d.join(format!("{id}.{ext}"));
            if std::fs::write(&p, &bytes).is_err() {
                return false;
            }
            (None, Some(p))
        } else {
            let t = String::from_utf8_lossy(&bytes).to_string();
            if t.trim().is_empty() {
                return false;
            }
            (Some(t), None)
        };
        self.entries.push_front(Entry { id, hash: h, mime, text, path, size, time: now() });
        self.trim();
        true
    }
    fn clear(&mut self) {
        while !self.entries.is_empty() {
            self.remove_at(0);
        }
    }
}

/// Our own copy of an entry, offered as the clipboard.
fn offer(wl: &Wl, e: &Entry) {
    let Some(bytes) = e.bytes() else { return };
    let src = wl.mgr.create_data_source(&wl.qh, SourceData { bytes: Arc::new(bytes) });
    if e.text.is_some() {
        for t in TEXT_TYPES {
            src.offer(t.to_string());
        }
    } else {
        src.offer(e.mime.clone());
    }
    src.offer(MARK.to_string());
    wl.dev.set_selection(Some(&src));
    let _ = wl.conn.flush();
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    let (mtx, mrx) = channel::<Msg>();
    let fwd = mtx.clone();
    std::thread::spawn(move || {
        for c in rx {
            if fwd.send(Msg::Cmd(c)).is_err() {
                return;
            }
        }
    });
    std::thread::spawn(move || run(mrx, mtx));
    tx
}

fn run(rx: Receiver<Msg>, tx: Sender<Msg>) {
    let mut hist = History::load();
    let mut wl: Option<Arc<Wl>> = None;
    let mut enabled = false;
    let mut error: Option<String> = None;
    // One write per burst of changes, not one per copy.
    let mut dirty = false;
    loop {
        let msg = match rx.recv_timeout(Duration::from_millis(if dirty { 300 } else { 3_600_000 })) {
            Ok(m) => m,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                if dirty {
                    hist.save();
                    dirty = false;
                }
                continue;
            }
            Err(_) => return,
        };
        let mut changed = false;
        // Forgetting is written straight away; a new copy can wait for
        // the burst to end.
        let mut forget = false;
        match msg {
            Msg::Cmd(c) => match c["cmd"].as_str().unwrap_or("") {
                "clip-enable" => {
                    let on = c["on"].as_bool().unwrap_or(false);
                    if let Some(m) = c["max"].as_u64() {
                        hist.max = (m as usize).clamp(5, 1000);
                        hist.trim();
                    }
                    if on && wl.is_none() {
                        match connect(tx.clone()) {
                            Ok(w) => {
                                wl = Some(w);
                                error = None;
                            }
                            Err(e) => error = Some(e),
                        }
                    }
                    if !on && enabled {
                        hist.clear();
                        forget = true;
                    }
                    enabled = on;
                    changed = true;
                }
                "clip-copy" => {
                    let id = c["id"].as_u64().unwrap_or(0);
                    if let (Some(i), Some(w)) = (hist.entries.iter().position(|e| e.id == id), &wl) {
                        let mut e = hist.entries.remove(i).unwrap();
                        e.time = now();
                        offer(w, &e);
                        hist.entries.push_front(e);
                        changed = true;
                    }
                }
                "clip-delete" => {
                    let id = c["id"].as_u64().unwrap_or(0);
                    if let Some(i) = hist.entries.iter().position(|e| e.id == id) {
                        hist.remove_at(i);
                        changed = true;
                        forget = true;
                    }
                }
                "clip-clear" => {
                    hist.clear();
                    changed = true;
                    forget = true;
                }
                "clip-list" => changed = true,
                _ => {}
            },
            Msg::Got { mime, bytes } => {
                if enabled {
                    changed = hist.add(mime, bytes);
                }
            }
            Msg::Empty => {
                // Its owner closed: offer the newest entry instead, so
                // what was copied can still be pasted.
                if let (true, Some(w), Some(e)) = (enabled, &wl, hist.entries.front()) {
                    offer(w, e);
                }
            }
            Msg::Lost(e) => {
                wl = None;
                error = Some(e);
                changed = true;
            }
        }
        if changed {
            hist.emit(wl.is_some(), enabled, error.as_deref());
            dirty = true;
        }
        if forget {
            hist.save();
            dirty = false;
        }
    }
}
