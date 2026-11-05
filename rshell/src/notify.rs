//! The notification server: org.freedesktop.Notifications on the session
//! bus, as Quickshell's NotificationServer was. What arrives goes to the
//! main loop (banners, the bell's count, the notification center); what the
//! user does goes back out as the spec's signals.

use crate::art::{self, Pixels};
use std::collections::HashMap;
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use zbus::zvariant::OwnedValue;

pub const PATH: &str = "/org/freedesktop/Notifications";
pub const IFACE: &str = "org.freedesktop.Notifications";

pub struct Incoming {
    pub id: u32,
    pub app: String,
    pub summary: String,
    pub body: String,
    pub icon: Option<Pixels>,
    /// 0 low, 1 normal, 2 critical.
    pub urgency: u8,
    /// ms; -1 the server's choice, 0 never.
    pub timeout: i32,
    /// (key, label) pairs, "default" among them when clicking the card should do something.
    pub actions: Vec<(String, String)>,
    pub transient: bool,
    pub icon_name: String,
}

pub enum Event {
    Note(Incoming),
    Close(u32),
}

struct Server {
    next: Arc<AtomicU32>,
    tx: Sender<Event>,
    wake: Mutex<UnixStream>,
}

impl Server {
    fn send(&self, ev: Event) {
        if self.tx.send(ev).is_ok() {
            if let Ok(mut w) = self.wake.lock() {
                let _ = w.write_all(b"!");
            }
        }
    }
}

/// Markup some apps send (<b>, <i>, <a href>, &amp;) as the text it reads as.
pub fn plain(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for ch in s.chars() {
        match ch {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&#39;", "'").replace("&amp;", "&")
}

fn image_hint(v: &OwnedValue) -> Option<Pixels> {
    let s: zbus::zvariant::Structure = v.try_clone().ok()?.try_into().ok()?;
    let f = s.fields();
    if f.len() < 7 {
        return None;
    }
    let i = |n: usize| -> Option<i32> { i32::try_from(&f[n]).ok() };
    let alpha = bool::try_from(&f[3]).ok()?;
    let data: Vec<u8> = f[6].try_clone().ok()?.try_into().ok()?;
    art::raw(i(0)?, i(1)?, i(2)?, alpha, &data, 96)
}

fn icon_for(name: &str) -> Option<Pixels> {
    let path = crate::icons::find(name, 64, None)?;
    art::file(&path, 64)
}

#[zbus::interface(name = "org.freedesktop.Notifications")]
impl Server {
    fn get_capabilities(&self) -> Vec<String> {
        ["body", "actions", "icon-static", "persistence"].iter().map(|s| s.to_string()).collect()
    }

    #[allow(clippy::too_many_arguments)]
    fn notify(
        &self,
        app_name: String,
        replaces_id: u32,
        app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        hints: HashMap<String, OwnedValue>,
        expire_timeout: i32,
    ) -> u32 {
        let id = if replaces_id > 0 { replaces_id } else { self.next.fetch_add(1, Ordering::Relaxed) };
        let s = |k: &str| hints.get(k).and_then(|v| String::try_from(v.try_clone().ok()?).ok()).unwrap_or_default();
        let urgency = hints.get("urgency").and_then(|v| u8::try_from(v).ok()).unwrap_or(1);
        let transient = hints.get("transient").and_then(|v| bool::try_from(v).ok()).unwrap_or(false);
        // The picture: the image the app sends, else its icon, else its
        // desktop entry's icon.
        let icon = hints
            .get("image-data")
            .or_else(|| hints.get("image_data"))
            .or_else(|| hints.get("icon_data"))
            .and_then(image_hint)
            .or_else(|| {
                let p = s("image-path");
                let p = if p.is_empty() { s("image_path") } else { p };
                (!p.is_empty()).then(|| art::file(std::path::Path::new(p.trim_start_matches("file://")), 96)).flatten()
                    .or_else(|| (!p.is_empty()).then(|| icon_for(&p)).flatten())
            })
            .or_else(|| (!app_icon.is_empty()).then(|| icon_for(&app_icon)).flatten())
            .or_else(|| crate::icons::desktop_icon(&s("desktop-entry")).and_then(|n| icon_for(&n)));
        let pairs = actions.chunks(2).filter(|c| c.len() == 2).map(|c| (c[0].clone(), c[1].clone())).collect();
        self.send(Event::Note(Incoming {
            id,
            app: if app_name.is_empty() { "Notification".into() } else { app_name },
            summary: plain(&summary),
            body: plain(&body),
            icon,
            urgency,
            timeout: expire_timeout,
            actions: pairs,
            transient,
            icon_name: app_icon,
        }));
        id
    }

    fn close_notification(&self, id: u32) {
        self.send(Event::Close(id));
    }

    fn get_server_information(&self) -> (String, String, String, String) {
        ("hyprshell".into(), "hyprshell".into(), env!("CARGO_PKG_VERSION").into(), "1.2".into())
    }
}

/// Takes the bus name (waiting for another server, such as the Quickshell
/// shell on its way out, to let go of it) and serves it. The connection
/// comes back over `ready` so the main loop can send the signals.
pub fn start(tx: Sender<Event>, wake: UnixStream, ready: Sender<zbus::blocking::Connection>, mut ready_wake: UnixStream) {
    std::thread::spawn(move || {
        let next = Arc::new(AtomicU32::new(1));
        for attempt in 0u32.. {
            let Ok(w) = wake.try_clone() else { return };
            let server = Server { next: next.clone(), tx: tx.clone(), wake: Mutex::new(w) };
            let built = zbus::blocking::connection::Builder::session()
                .and_then(|b| b.name(IFACE))
                .and_then(|b| b.serve_at(PATH, server))
                .and_then(|b| b.build());
            match built {
                Ok(conn) => {
                    let _ = ready.send(conn);
                    let _ = ready_wake.write_all(b"!");
                    // The connection serves on a thread of its own.
                    return;
                }
                Err(e) => {
                    if attempt == 0 {
                        eprintln!("hyprshell-rs: can't be the notification server yet ({e}); trying again");
                    }
                    std::thread::sleep(std::time::Duration::from_secs(if attempt < 10 { 1 } else { 5 }));
                }
            }
        }
    });
}

pub fn signal_closed(c: &zbus::blocking::Connection, id: u32, reason: u32) {
    let _ = c.emit_signal(None::<&str>, PATH, IFACE, "NotificationClosed", &(id, reason));
}

pub fn signal_action(c: &zbus::blocking::Connection, id: u32, key: &str) {
    let _ = c.emit_signal(None::<&str>, PATH, IFACE, "ActionInvoked", &(id, key));
}
