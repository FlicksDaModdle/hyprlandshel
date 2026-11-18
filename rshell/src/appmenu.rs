//! The focused app's own menus (File, Edit, View…) on the bar, as a Mac's
//! menu bar has them.
//!
//! An app that has a menu bar can publish it over D-Bus (com.canonical.
//! dbusmenu) and say so to a registrar, com.canonical.AppMenu.Registrar;
//! Qt apps do this by themselves when a registrar is on the bus, and then
//! leave the menu bar out of their own window. This is that registrar. It
//! notes which process each registered menu belongs to, and the bar asks
//! for the menu of whichever window has focus (by its process).
//!
//! What doesn't publish a menu has none here: Firefox and other apps that
//! draw their own, GTK apps on Wayland, Electron.

use crate::tray::{click_at, menu_at, Entry};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use zbus::blocking::Connection;

const REGISTRAR: &str = "com.canonical.AppMenu.Registrar";

pub enum Event {
    /// The focused app's menu bar: its top-level menus (none when it has no menu).
    Tops(Vec<Entry>),
    /// A menu, or one of its submenus, to show (0 is a top-level one's own).
    Menu { heading: String, nested: bool, entries: Vec<Entry> },
}

pub enum Cmd {
    /// Focus moved to a window of this process (0 for none).
    Focus(i32),
    /// The entries under this one (0 for a top-level menu's own, or a
    /// submenu's id), whose label is the heading; `nested` for a submenu.
    Open(i32, String, bool),
    Click(i32),
}

#[derive(Clone)]
struct Reg {
    window: u32,
    bus: String,
    path: String,
}

enum Inner {
    Registered,
    Gone(String),
    Layout(String),
    Cmd(Cmd),
}

struct Registrar {
    regs: Arc<Mutex<Vec<Reg>>>,
    tx: Mutex<Sender<Inner>>,
}

#[zbus::interface(name = "com.canonical.AppMenu.Registrar")]
impl Registrar {
    async fn register_window(&self, window_id: u32, menu_object_path: zbus::zvariant::ObjectPath<'_>, #[zbus(header)] hdr: zbus::message::Header<'_>) {
        let bus = hdr.sender().map(|s| s.to_string()).unwrap_or_default();
        {
            let mut r = self.regs.lock().unwrap();
            r.retain(|x| x.window != window_id);
            r.push(Reg { window: window_id, bus, path: menu_object_path.to_string() });
        }
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(Inner::Registered);
        }
    }

    async fn unregister_window(&self, window_id: u32) {
        self.regs.lock().unwrap().retain(|x| x.window != window_id);
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(Inner::Registered);
        }
    }

    async fn get_menu_for_window(&self, window_id: u32) -> zbus::fdo::Result<(String, zbus::zvariant::OwnedObjectPath)> {
        let r = self.regs.lock().unwrap();
        let reg = r.iter().find(|x| x.window == window_id).ok_or_else(|| zbus::fdo::Error::Failed("no menu for that window".into()))?;
        let path = zbus::zvariant::OwnedObjectPath::try_from(reg.path.as_str()).map_err(|e| zbus::fdo::Error::Failed(e.to_string()))?;
        Ok((reg.bus.clone(), path))
    }
}

/// The process on the other end of a bus name.
fn pid_of(c: &Connection, bus: &str) -> Option<i32> {
    let r = c.call_method(Some("org.freedesktop.DBus"), "/org/freedesktop/DBus", Some("org.freedesktop.DBus"), "GetConnectionUnixProcessID", &(bus,)).ok()?;
    r.body().deserialize::<u32>().ok().map(|p| p as i32)
}

pub fn start(tx: Sender<Event>, cmds: Receiver<Cmd>, wake: UnixStream) {
    let (itx, irx) = channel::<Inner>();
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
        let regs = Arc::new(Mutex::new(Vec::<Reg>::new()));
        let built = zbus::blocking::connection::Builder::session()
            .and_then(|b| b.name(REGISTRAR))
            .and_then(|b| b.serve_at("/com/canonical/AppMenu/Registrar", Registrar { regs: regs.clone(), tx: Mutex::new(itx.clone()) }))
            .and_then(|b| b.build());
        let conn = match built {
            Ok(c) => c,
            Err(e) => {
                // Another registrar (Plasma's, say) has the name: app menus are its.
                eprintln!("hyprshell-rs: app menus off: another registrar is running ({e})");
                return;
            }
        };
        // Apps leaving the bus, and menus that change.
        for (rule, layout) in [("type='signal',sender='org.freedesktop.DBus',member='NameOwnerChanged'", false), ("type='signal',interface='com.canonical.dbusmenu',member='LayoutUpdated'", true)] {
            let Ok(r) = zbus::MatchRule::try_from(rule) else { continue };
            let Ok(it) = zbus::blocking::MessageIterator::for_match_rule(r, &conn, Some(64)) else { continue };
            let itx = itx.clone();
            std::thread::spawn(move || {
                for m in it.flatten() {
                    let msg = if layout {
                        Inner::Layout(m.header().sender().map(|s| s.to_string()).unwrap_or_default())
                    } else {
                        match m.body().deserialize::<(String, String, String)>() {
                            Ok((name, _, new)) if new.is_empty() => Inner::Gone(name),
                            _ => continue,
                        }
                    };
                    if itx.send(msg).is_err() {
                        return;
                    }
                }
            });
        }

        let mut wake = wake;
        let mut send = |ev: Event| {
            if tx.send(ev).is_ok() {
                let _ = wake.write_all(b"!");
            }
        };
        let mut focus = 0i32;
        // The menu on show: whose it is.
        let mut current: Option<Reg> = None;
        loop {
            let m = match irx.recv_timeout(Duration::from_secs(3600)) {
                Ok(m) => m,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => return,
            };
            // Does the focused app have a menu: its most recent window's.
            let mut resolve = |current: &mut Option<Reg>, focus: i32| -> bool {
                let list = regs.lock().unwrap().clone();
                let found = list.iter().rev().find(|r| focus > 0 && pid_of(&conn, &r.bus) == Some(focus)).cloned();
                let changed = found.as_ref().map(|r| (&r.bus, &r.path)) != current.as_ref().map(|r| (&r.bus, &r.path));
                *current = found;
                changed
            };
            match m {
                Inner::Cmd(Cmd::Focus(pid)) => {
                    focus = pid;
                    resolve(&mut current, focus);
                    let tops = current.as_ref().map(|r| menu_at(&conn, &r.bus, &r.path, 0)).unwrap_or_default();
                    send(Event::Tops(tops));
                }
                Inner::Registered => {
                    // A menu came or went: the focused app may be the one.
                    if resolve(&mut current, focus) || current.is_none() {
                        let tops = current.as_ref().map(|r| menu_at(&conn, &r.bus, &r.path, 0)).unwrap_or_default();
                        send(Event::Tops(tops));
                    }
                }
                Inner::Gone(name) => {
                    regs.lock().unwrap().retain(|r| r.bus != name);
                    if current.as_ref().is_some_and(|r| r.bus == name) {
                        current = None;
                        send(Event::Tops(Vec::new()));
                    }
                }
                Inner::Layout(bus) => {
                    if let Some(r) = current.as_ref().filter(|r| r.bus == bus) {
                        // Menus rebuild themselves in bursts: a moment for it to finish.
                        std::thread::sleep(Duration::from_millis(80));
                        while irx.try_recv().is_ok() {}
                        send(Event::Tops(menu_at(&conn, &r.bus, &r.path, 0)));
                    }
                }
                Inner::Cmd(Cmd::Open(id, label, nested)) => {
                    let Some(r) = &current else { continue };
                    let entries = menu_at(&conn, &r.bus, &r.path, id);
                    send(Event::Menu { heading: label, nested, entries });
                }
                Inner::Cmd(Cmd::Click(id)) => {
                    if let Some(r) = &current {
                        click_at(&conn, &r.bus, &r.path, id);
                    }
                }
            }
        }
    });
}
