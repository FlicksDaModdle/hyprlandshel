//! The system tray: status notifier items (org.kde.StatusNotifierItem),
//! with this shell as the watcher they register with and the host that
//! shows them, and their menus over com.canonical.dbusmenu. What Quickshell's
//! SystemTray service did for TrayRow.qml and TrayMenu.qml.
//!
//! One thread owns the bus. It keeps the items, re-reads one when it says
//! it changed, drops it when its owner leaves the bus, and runs the bar's
//! clicks. Pictures are decoded here, off the main loop.

use crate::art::{self, Pixels};
use std::collections::HashMap;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use zbus::blocking::Connection;
use zbus::zvariant::{OwnedValue, Value};

const ITEM: &str = "org.kde.StatusNotifierItem";
const WATCHER: &str = "org.kde.StatusNotifierWatcher";
const MENU: &str = "com.canonical.dbusmenu";

#[derive(Clone)]
pub struct Item {
    /// "bus|path": how the bar names it back.
    pub key: String,
    pub title: String,
    pub passive: bool,
    pub icon: Option<Pixels>,
}

#[derive(Clone)]
pub struct Entry {
    pub id: i32,
    pub label: String,
    pub enabled: bool,
    pub separator: bool,
    /// 0 none, 1 check, 2 radio.
    pub toggle: i32,
    pub checked: bool,
    pub submenu: bool,
}

pub enum Event {
    Items(Vec<Item>),
    Menu { key: String, heading: String, nested: bool, entries: Vec<Entry> },
}

pub enum Cmd {
    Activate(String, i32, i32),
    Secondary(String, i32, i32),
    Scroll(String, i32),
    /// The item's menu, or one of its submenus (0 is the top).
    Menu(String, i32, String),
    Click(String, i32),
}

enum Inner {
    Registered,
    Changed,
    OwnerGone(String),
    Cmd(Cmd),
}

struct Watcher {
    items: Arc<Mutex<Vec<String>>>,
    tx: Mutex<Sender<Inner>>,
}

impl Watcher {
    fn poke(&self, m: Inner) {
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(m);
        }
    }
}

#[zbus::interface(name = "org.kde.StatusNotifierWatcher")]
impl Watcher {
    async fn register_status_notifier_item(
        &self,
        service: &str,
        #[zbus(header)] hdr: zbus::message::Header<'_>,
        #[zbus(signal_emitter)] emitter: zbus::object_server::SignalEmitter<'_>,
    ) {
        // Either a bus name (its object at /StatusNotifierItem) or an
        // object path on the caller's own connection (Ayatana's way).
        let sender = hdr.sender().map(|s| s.to_string()).unwrap_or_default();
        let full = if service.starts_with('/') { format!("{sender}{service}") } else if service.contains('/') { service.to_string() } else { format!("{service}/StatusNotifierItem") };
        let added = {
            let mut items = self.items.lock().unwrap();
            if items.contains(&full) {
                false
            } else {
                items.push(full.clone());
                true
            }
        };
        if added {
            let _ = Self::status_notifier_item_registered(&emitter, &full).await;
        }
        self.poke(Inner::Registered);
    }

    fn register_status_notifier_host(&self, _service: &str) {}

    #[zbus(property)]
    fn registered_status_notifier_items(&self) -> Vec<String> {
        self.items.lock().unwrap().clone()
    }

    #[zbus(property)]
    fn is_status_notifier_host_registered(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn protocol_version(&self) -> i32 {
        0
    }

    #[zbus(signal)]
    async fn status_notifier_item_registered(emitter: &zbus::object_server::SignalEmitter<'_>, service: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn status_notifier_item_unregistered(emitter: &zbus::object_server::SignalEmitter<'_>, service: &str) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn status_notifier_host_registered(emitter: &zbus::object_server::SignalEmitter<'_>) -> zbus::Result<()>;
}

fn split(full: &str) -> (String, String) {
    match full.find('/') {
        Some(i) => (full[..i].to_string(), full[i..].to_string()),
        None => (full.to_string(), "/StatusNotifierItem".into()),
    }
}

struct Known {
    full: String,
    bus: String,
    path: String,
    menu: String,
    item_is_menu: bool,
    item: Item,
}

fn text(p: &HashMap<String, OwnedValue>, k: &str) -> String {
    p.get(k).and_then(|v| String::try_from(v.try_clone().ok()?).ok()).unwrap_or_default()
}

/// The pixmap nearest 48 px from an a(iiay).
fn pixmap(v: Option<&OwnedValue>) -> Option<Pixels> {
    let list: Vec<(i32, i32, Vec<u8>)> = v?.try_clone().ok()?.try_into().ok()?;
    let best = list.iter().filter(|(w, h, _)| *w > 0 && *h > 0).min_by_key(|(w, _, _)| (48 - *w).abs() + if *w < 32 { 100 } else { 0 })?;
    art::argb(best.0, best.1, &best.2, 48)
}

fn read(c: &Connection, full: &str) -> Option<Known> {
    let (bus, path) = split(full);
    let props = zbus::blocking::fdo::PropertiesProxy::builder(c).destination(bus.as_str()).ok()?.path(path.as_str()).ok()?.build().ok()?;
    let p: HashMap<String, OwnedValue> = props.get_all(ITEM.try_into().ok()?).ok()?;
    let status = text(&p, "Status");
    let theme_path = text(&p, "IconThemePath");
    let extra = (!theme_path.is_empty()).then(|| std::path::PathBuf::from(&theme_path));
    let named = |k: &str| {
        let n = text(&p, k);
        crate::icons::find(&n, 48, extra.as_deref()).and_then(|f| art::file(&f, 48))
    };
    let icon = if status == "NeedsAttention" {
        named("AttentionIconName").or_else(|| pixmap(p.get("AttentionIconPixmap")))
    } else {
        None
    }
    .or_else(|| named("IconName"))
    .or_else(|| pixmap(p.get("IconPixmap")));
    // The tooltip's title, then the item's, then its id.
    let tip = p
        .get("ToolTip")
        .and_then(|v| <(String, Vec<(i32, i32, Vec<u8>)>, String, String)>::try_from(v.try_clone().ok()?).ok())
        .map(|t| t.2)
        .unwrap_or_default();
    let title = [tip, text(&p, "Title"), text(&p, "Id")].into_iter().find(|s| !s.is_empty()).unwrap_or_default();
    let menu = p
        .get("Menu")
        .and_then(|v| zbus::zvariant::OwnedObjectPath::try_from(v.try_clone().ok()?).ok())
        .map(|o| o.to_string())
        .unwrap_or_default();
    let item_is_menu = p.get("ItemIsMenu").and_then(|v| bool::try_from(v).ok()).unwrap_or(false);
    Some(Known {
        full: full.to_string(),
        bus: bus.clone(),
        path: path.clone(),
        menu,
        item_is_menu,
        item: Item { key: format!("{bus}|{path}"), title, passive: status == "Passive", icon },
    })
}

struct Node {
    id: i32,
    props: HashMap<String, OwnedValue>,
    kids: Vec<Node>,
}

fn node(v: &Value) -> Option<Node> {
    let v = if let Value::Value(b) = v { &**b } else { v };
    let Value::Structure(s) = v else { return None };
    let f = s.fields();
    if f.len() < 3 {
        return None;
    }
    let id = i32::try_from(&f[0]).ok()?;
    let props: HashMap<String, OwnedValue> = match &f[1] {
        Value::Dict(d) => d.try_clone().ok()?.try_into().ok().unwrap_or_default(),
        _ => HashMap::new(),
    };
    let kids = match &f[2] {
        Value::Array(a) => a.iter().filter_map(node).collect(),
        _ => Vec::new(),
    };
    Some(Node { id, props, kids })
}

fn mnemonic(s: &str) -> String {
    // "_File" is "File" with F underlined; "__" is a real underscore.
    let mut out = String::new();
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c == '_' {
            if it.peek() == Some(&'_') {
                out.push('_');
                it.next();
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn menu(c: &Connection, k: &Known, parent: i32) -> Vec<Entry> {
    if k.menu.is_empty() {
        return Vec::new();
    }
    let _ = c.call_method(Some(k.bus.as_str()), k.menu.as_str(), Some(MENU), "AboutToShow", &(parent,));
    let props: Vec<&str> = Vec::new();
    let Ok(reply) = c.call_method(Some(k.bus.as_str()), k.menu.as_str(), Some(MENU), "GetLayout", &(parent, 1i32, props)) else {
        return Vec::new();
    };
    let Ok((_rev, (_, _, kids))) = reply.body().deserialize::<(u32, (i32, HashMap<String, OwnedValue>, Vec<OwnedValue>))>() else {
        return Vec::new();
    };
    let s = |n: &Node, key: &str| n.props.get(key).and_then(|v| String::try_from(v.try_clone().ok()?).ok()).unwrap_or_default();
    let b = |n: &Node, key: &str, d: bool| n.props.get(key).and_then(|v| bool::try_from(v).ok()).unwrap_or(d);
    kids.iter()
        .filter_map(|v| node(v))
        .filter(|n| b(n, "visible", true))
        .map(|n| {
            let toggle = match s(&n, "toggle-type").as_str() {
                "checkmark" => 1,
                "radio" => 2,
                _ => 0,
            };
            Entry {
                id: n.id,
                label: mnemonic(&s(&n, "label")),
                enabled: b(&n, "enabled", true),
                separator: s(&n, "type") == "separator",
                toggle,
                checked: n.props.get("toggle-state").and_then(|v| i32::try_from(v).ok()).unwrap_or(0) == 1,
                submenu: s(&n, "children-display") == "submenu" || !n.kids.is_empty(),
            }
        })
        .collect()
}

pub fn start(tx: Sender<Event>, cmds: Receiver<Cmd>, wake: UnixStream) {
    let (itx, irx) = channel::<Inner>();
    // The bar's clicks join the same queue as the bus's news.
    {
        let itx = itx.clone();
        std::thread::spawn(move || {
            for c in cmds {
                if itx.send(Inner::Cmd(c)).is_err() {
                    return;
                }
            }
        });
    }
    std::thread::spawn(move || {
        let registry = Arc::new(Mutex::new(Vec::<String>::new()));
        let watcher = Watcher { items: registry.clone(), tx: Mutex::new(itx.clone()) };
        let built = zbus::blocking::connection::Builder::session()
            .and_then(|b| b.name(WATCHER))
            .and_then(|b| b.serve_at("/StatusNotifierWatcher", watcher))
            .and_then(|b| b.build());
        let (conn, own) = match built {
            Ok(c) => (c, true),
            Err(e) => {
                eprintln!("hyprshell-rs: another tray watcher is running ({e}); showing its items");
                let Ok(c) = Connection::session() else { return };
                (c, false)
            }
        };
        if own {
            // Items already on the bus register again when a watcher appears.
            let _ = conn.emit_signal(None::<&str>, "/StatusNotifierWatcher", WATCHER, "StatusNotifierHostRegistered", &());
        } else if let Some(name) = conn.unique_name() {
            let _ = conn.call_method(Some(WATCHER), "/StatusNotifierWatcher", Some(WATCHER), "RegisterStatusNotifierHost", &(name.as_str(),));
        }
        // Items changing, and owners leaving the bus.
        for rule in [
            format!("type='signal',interface='{ITEM}'"),
            "type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'".to_string(),
            format!("type='signal',interface='{WATCHER}'"),
        ] {
            let Ok(r) = zbus::MatchRule::try_from(rule.as_str()) else { continue };
            let Ok(it) = zbus::blocking::MessageIterator::for_match_rule(r, &conn, Some(64)) else { continue };
            let itx = itx.clone();
            std::thread::spawn(move || {
                for m in it.flatten() {
                    let h = m.header();
                    let member = h.member().map(|x| x.to_string()).unwrap_or_default();
                    let msg = if member == "NameOwnerChanged" {
                        match m.body().deserialize::<(String, String, String)>() {
                            Ok((name, _, new)) if new.is_empty() => Inner::OwnerGone(name),
                            _ => continue,
                        }
                    } else {
                        Inner::Changed
                    };
                    if itx.send(msg).is_err() {
                        return;
                    }
                }
            });
        }

        let mut known: Vec<Known> = Vec::new();
        let mut wake = wake;
        let mut send = |ev: Event| {
            if tx.send(ev).is_ok() {
                let _ = wake.write_all(b"!");
            }
        };
        let mut dirty = true;
        let mut menu_heading: HashMap<(String, i32), String> = HashMap::new();
        loop {
            if dirty {
                // Debounced: items change several properties at once.
                while let Ok(m) = irx.recv_timeout(Duration::from_millis(60)) {
                    if let Inner::Cmd(c) = m {
                        // Commands can't wait for a quiet bus.
                        run(&conn, &known, c, &mut send, &mut menu_heading);
                    }
                }
                let list: Vec<String> = if own {
                    registry.lock().unwrap().clone()
                } else {
                    zbus::blocking::fdo::PropertiesProxy::builder(&conn)
                        .destination(WATCHER)
                        .ok()
                        .and_then(|b| b.path("/StatusNotifierWatcher").ok())
                        .and_then(|b| b.build().ok())
                        .and_then(|p| p.get(WATCHER.try_into().ok()?, "RegisteredStatusNotifierItems").ok())
                        .and_then(|v| Vec::<String>::try_from(v).ok())
                        .unwrap_or_default()
                };
                known = list.iter().filter_map(|f| read(&conn, f)).collect();
                // What can't be read is gone.
                if own {
                    let alive: Vec<String> = known.iter().map(|k| k.full.clone()).collect();
                    registry.lock().unwrap().retain(|f| alive.contains(f));
                }
                send(Event::Items(known.iter().map(|k| k.item.clone()).collect()));
                dirty = false;
            }
            let m = match irx.recv_timeout(Duration::from_secs(if own { 3600 } else { 3 })) {
                Ok(m) => m,
                Err(RecvTimeoutError::Timeout) => {
                    dirty = !own;
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => return,
            };
            match m {
                Inner::Registered | Inner::Changed => dirty = true,
                Inner::OwnerGone(name) => {
                    if own {
                        let mut r = registry.lock().unwrap();
                        let before = r.len();
                        r.retain(|f| split(f).0 != name);
                        dirty |= r.len() != before;
                    } else {
                        dirty = true;
                    }
                }
                Inner::Cmd(c) => run(&conn, &known, c, &mut send, &mut menu_heading),
            }
        }
    });
}

fn run(conn: &Connection, known: &[Known], c: Cmd, send: &mut impl FnMut(Event), headings: &mut HashMap<(String, i32), String>) {
    let find = |key: &str| known.iter().find(|k| k.item.key == key);
    match c {
        Cmd::Activate(key, x, y) => {
            let Some(k) = find(&key) else { return };
            let failed = k.item_is_menu
                || conn.call_method(Some(k.bus.as_str()), k.path.as_str(), Some(ITEM), "Activate", &(x, y)).is_err();
            // An item that is only a menu, or that has no Activate, shows
            // its menu instead.
            if failed && !k.menu.is_empty() {
                send(Event::Menu { key, heading: k.item.title.clone(), nested: false, entries: menu(conn, k, 0) });
            }
        }
        Cmd::Secondary(key, x, y) => {
            if let Some(k) = find(&key) {
                let _ = conn.call_method(Some(k.bus.as_str()), k.path.as_str(), Some(ITEM), "SecondaryActivate", &(x, y));
            }
        }
        Cmd::Scroll(key, d) => {
            if let Some(k) = find(&key) {
                let _ = conn.call_method(Some(k.bus.as_str()), k.path.as_str(), Some(ITEM), "Scroll", &(d * 120, "vertical"));
            }
        }
        Cmd::Menu(key, parent, label) => {
            let Some(k) = find(&key) else { return };
            if k.menu.is_empty() {
                let _ = conn.call_method(Some(k.bus.as_str()), k.path.as_str(), Some(ITEM), "ContextMenu", &(0i32, 0i32));
                return;
            }
            let heading = if parent == 0 { k.item.title.clone() } else { label };
            headings.insert((key.clone(), parent), heading.clone());
            send(Event::Menu { key, heading, nested: parent != 0, entries: menu(conn, k, parent) });
        }
        Cmd::Click(key, id) => {
            if let Some(k) = find(&key) {
                let ts = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as u32).unwrap_or(0);
                let _ = conn.call_method(Some(k.bus.as_str()), k.menu.as_str(), Some(MENU), "Event", &(id, "clicked", Value::from(""), ts));
            }
        }
    }
}
