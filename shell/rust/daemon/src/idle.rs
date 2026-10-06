//! Idle: lock, screen off and sleep after the machine is left alone — in
//! place of hypridle and its configuration file.
//!
//! The timers are the compositor's (ext-idle-notify-v1), so an app that
//! asks to keep the screen on — a video playing, a call — holds them
//! without anything here knowing. On top of that the shell can hold them
//! (media playing, a fullscreen window, "Keep awake"); when a hold ends,
//! the timers start again from nothing.
//!
//! Lock and screen off are the shell's to do (it draws the lock screen and
//! talks to Hyprland), so they are sent as idle-action events; sleep goes
//! to logind. logind is also asked for a delay before any sleep, so the
//! screen locks first whoever started the sleep; and `loginctl
//! lock-session` from anywhere reaches the shell the same way.
//!
//! Commands:  idle-config {lock, off, suspend}   seconds; 0 = never
//!            idle-hold {on, why}                the shell's holds
//!            idle-lock-before-sleep {on}
//!            idle-locked                        the lock screen is up
//! Events:    idle {available, held, error?}
//!            idle-action {action: lock | screen-off | screen-on}

use crate::out;
use serde_json::{json, Value};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};
use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, EventQueue, Proxy, QueueHandle};
use wayland_protocols::ext::idle_notify::v1::client::{
    ext_idle_notification_v1::{self, ExtIdleNotificationV1},
    ext_idle_notifier_v1::ExtIdleNotifierV1,
};

const LOGIN1: &str = "org.freedesktop.login1";

#[derive(Clone, Copy, PartialEq, Debug)]
enum Kind {
    Lock,
    Off,
    Suspend,
}

enum Msg {
    Cmd(Value),
    Idled(Kind),
    Resumed(Kind),
    Sleep(bool),
    LockRequest,
}

// ══ Wayland ═════════════════════════════════════════════════════════════

struct WlState {
    tx: Sender<Msg>,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for WlState {
    fn event(_: &mut Self, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_seat::WlSeat, ()> for WlState {
    fn event(_: &mut Self, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ExtIdleNotifierV1, ()> for WlState {
    fn event(_: &mut Self, _: &ExtIdleNotifierV1, _: <ExtIdleNotifierV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ExtIdleNotificationV1, Kind> for WlState {
    fn event(st: &mut Self, _: &ExtIdleNotificationV1, ev: ext_idle_notification_v1::Event, kind: &Kind, _: &Connection, _: &QueueHandle<Self>) {
        let _ = st.tx.send(match ev {
            ext_idle_notification_v1::Event::Idled => Msg::Idled(*kind),
            ext_idle_notification_v1::Event::Resumed => Msg::Resumed(*kind),
            _ => return,
        });
    }
}

struct Wl {
    conn: Connection,
    qh: QueueHandle<WlState>,
    seat: wl_seat::WlSeat,
    notifier: ExtIdleNotifierV1,
    timers: Vec<ExtIdleNotificationV1>,
}

fn connect(tx: Sender<Msg>) -> Result<Wl, String> {
    let conn = Connection::connect_to_env().map_err(|e| format!("no Wayland display: {e}"))?;
    let (globals, queue): (_, EventQueue<WlState>) = registry_queue_init(&conn).map_err(|e| e.to_string())?;
    let qh = queue.handle();
    let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=8, ()).map_err(|_| "no seat".to_string())?;
    let notifier: ExtIdleNotifierV1 = globals
        .bind(&qh, 1..=1, ())
        .map_err(|_| "the compositor has no idle notifications (ext-idle-notify-v1)".to_string())?;
    let mut queue = queue;
    let mut st = WlState { tx };
    std::thread::spawn(move || loop {
        if queue.blocking_dispatch(&mut st).is_err() {
            return;
        }
    });
    Ok(Wl { conn, qh, seat, notifier, timers: Vec::new() })
}

impl Wl {
    /// The timers as configured, started now.
    fn arm(&mut self, t: &[(Kind, u64)]) {
        self.disarm();
        for (kind, secs) in t {
            if *secs > 0 {
                let ms = (*secs).saturating_mul(1000).min(u32::MAX as u64) as u32;
                self.timers.push(self.notifier.get_idle_notification(ms, &self.seat, &self.qh, *kind));
            }
        }
        let _ = self.conn.flush();
    }
    fn disarm(&mut self) {
        for t in self.timers.drain(..) {
            t.destroy();
        }
        let _ = self.conn.flush();
    }
}

// ══ logind ══════════════════════════════════════════════════════════════

/// Held while awake: logind waits (up to its InhibitDelayMaxSec) for this
/// to be let go before a sleep, which is the time the lock screen has to
/// come up.
fn take_delay(conn: &zbus::blocking::Connection) -> Option<zbus::zvariant::OwnedFd> {
    let r = conn
        .call_method(Some(LOGIN1), "/org/freedesktop/login1", Some("org.freedesktop.login1.Manager"), "Inhibit",
                     &("sleep", "Hyprshell", "Lock the screen before sleeping", "delay"))
        .ok()?;
    r.body().deserialize::<zbus::zvariant::OwnedFd>().ok()
}

fn watch_logind(conn: &zbus::blocking::Connection, tx: Sender<Msg>) {
    // This session's object, for its Lock signal.
    let session: Option<String> = conn
        .call_method(Some(LOGIN1), "/org/freedesktop/login1", Some("org.freedesktop.login1.Manager"), "GetSessionByPID", &(std::process::id(),))
        .ok()
        .and_then(|m| m.body().deserialize::<zbus::zvariant::OwnedObjectPath>().ok())
        .map(|p| p.to_string());
    let mut rules = vec![zbus::MatchRule::builder()
        .msg_type(zbus::message::Type::Signal)
        .sender(LOGIN1)
        .and_then(|b| b.interface("org.freedesktop.login1.Manager"))
        .and_then(|b| b.member("PrepareForSleep"))
        .map(|b| b.build())];
    if let Some(path) = session {
        rules.push(
            zbus::MatchRule::builder()
                .msg_type(zbus::message::Type::Signal)
                .sender(LOGIN1)
                .and_then(|b| b.interface("org.freedesktop.login1.Session"))
                .and_then(|b| b.member("Lock"))
                .and_then(|b| b.path(path))
                .map(|b| b.build()),
        );
    }
    for rule in rules.into_iter().flatten() {
        let (conn, tx) = (conn.clone(), tx.clone());
        std::thread::spawn(move || {
            let Ok(iter) = zbus::blocking::MessageIterator::for_match_rule(rule, &conn, Some(16)) else { return };
            for m in iter.flatten() {
                let member = m.header().member().map(|s| s.to_string()).unwrap_or_default();
                let msg = if member == "PrepareForSleep" {
                    Msg::Sleep(m.body().deserialize::<bool>().unwrap_or(false))
                } else {
                    Msg::LockRequest
                };
                if tx.send(msg).is_err() {
                    return;
                }
            }
        });
    }
}

// ══ the thread ══════════════════════════════════════════════════════════

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

fn action(a: &str) {
    out::emit(json!({ "ev": "idle-action", "action": a }));
}

fn run(rx: Receiver<Msg>, tx: Sender<Msg>) {
    let mut timers: Vec<(Kind, u64)> = Vec::new();
    let mut holds: std::collections::BTreeSet<String> = Default::default();
    let mut wl: Option<Wl> = None;
    let mut error: Option<String> = None;
    let mut configured = false;
    let mut screen_off = false;
    let mut lock_before_sleep = true;

    let system = zbus::blocking::Connection::system().ok();
    let mut delay = None;
    if let Some(sys) = &system {
        watch_logind(sys, tx.clone());
        delay = take_delay(sys);
    }
    // While a sleep waits on the lock screen: when to give up waiting.
    let mut sleeping_since: Option<Instant> = None;

    let emit = |held: &std::collections::BTreeSet<String>, error: &Option<String>, wl: &Option<Wl>| {
        let mut ev = json!({ "ev": "idle", "available": wl.is_some(), "held": held.iter().collect::<Vec<_>>() });
        if let Some(e) = error {
            ev["error"] = json!(e);
        }
        out::emit(ev);
    };

    loop {
        let wait = if sleeping_since.is_some() { Duration::from_millis(100) } else { Duration::from_secs(3600) };
        let msg = match rx.recv_timeout(wait) {
            Ok(m) => Some(m),
            Err(RecvTimeoutError::Timeout) => None,
            Err(RecvTimeoutError::Disconnected) => return,
        };
        let mut rearm = false;
        match msg {
            Some(Msg::Cmd(c)) => match c["cmd"].as_str().unwrap_or("") {
                "idle-config" => {
                    let s = |k: &str| c[k].as_u64().unwrap_or(0);
                    timers = vec![(Kind::Lock, s("lock")), (Kind::Off, s("off")), (Kind::Suspend, s("suspend"))];
                    configured = true;
                    rearm = true;
                }
                "idle-hold" => {
                    let why = c["why"].as_str().unwrap_or("shell").to_string();
                    let changed = if c["on"].as_bool().unwrap_or(false) { holds.insert(why) } else { holds.remove(&why) };
                    rearm = changed;
                }
                "idle-lock-before-sleep" => lock_before_sleep = c["on"].as_bool().unwrap_or(true),
                "idle-locked" => {
                    // The lock screen is up: the sleep may go ahead.
                    if sleeping_since.take().is_some() {
                        delay = None;
                    }
                }
                _ => {}
            },
            Some(Msg::Idled(k)) => match k {
                Kind::Lock => action("lock"),
                Kind::Off => {
                    screen_off = true;
                    action("screen-off");
                }
                Kind::Suspend => {
                    if let Some(sys) = &system {
                        let _ = sys.call_method(Some(LOGIN1), "/org/freedesktop/login1", Some("org.freedesktop.login1.Manager"), "Suspend", &(true,));
                    }
                }
            },
            Some(Msg::Resumed(k)) => {
                if k == Kind::Off && screen_off {
                    screen_off = false;
                    action("screen-on");
                }
            }
            Some(Msg::Sleep(going)) => {
                if going {
                    if lock_before_sleep {
                        action("lock");
                        sleeping_since = Some(Instant::now());
                    } else {
                        delay = None;
                    }
                } else {
                    // Awake again: the screen on, and a delay held for the
                    // next sleep.
                    sleeping_since = None;
                    screen_off = false;
                    action("screen-on");
                    if let Some(sys) = &system {
                        delay = take_delay(sys);
                    }
                    rearm = true;
                }
            }
            Some(Msg::LockRequest) => action("lock"),
            None => {}
        }
        // A lock screen that never said it was up: let the sleep go
        // anyway rather than hold the machine awake.
        if sleeping_since.map(|t| t.elapsed() > Duration::from_millis(1500)).unwrap_or(false) {
            sleeping_since = None;
            delay = None;
        }
        let _ = &delay;

        if rearm && configured {
            if wl.is_none() && timers.iter().any(|t| t.1 > 0) {
                match connect(tx.clone()) {
                    Ok(w) => {
                        wl = Some(w);
                        error = None;
                    }
                    Err(e) => error = Some(e),
                }
            }
            if let Some(w) = &mut wl {
                // Held: no timers; released: all of them again, from now.
                if holds.is_empty() {
                    w.arm(&timers);
                } else {
                    w.disarm();
                }
            }
            emit(&holds, &error, &wl);
        }
    }
}
