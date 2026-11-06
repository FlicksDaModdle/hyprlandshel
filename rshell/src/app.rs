//! The shell itself: a bar on every monitor, the panels that drop from it
//! (one overlay surface per monitor, there only while a panel is open), the
//! notification banners, and everything they do.
//!
//! Slint callbacks only queue an `Action`; the main loop carries them out
//! here with the whole shell in hand, so no callback has to borrow it.

use crate::art::Pixels;
use crate::spring::{Motion, Spring};
use crate::{daemon, extras, hypr, mpris, notify, sys, theme, tray, wl};
use crate::{Bar, DayCell, DriveRow, MediaInfo, MenuEntry, Note, NoteAction, Panels, PrivacyRow, Theme, Tile, TimerRow, Toasts, TrayItem, Workspace};
use serde_json::json;
use slint::platform::software_renderer::MinimalSoftwareWindow;
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use smithay_client_toolkit::shell::wlr_layer::{Anchor, KeyboardInteractivity, Layer};
use std::cell::RefCell;
use std::collections::HashMap;
use std::os::unix::net::UnixStream;
use std::rc::Rc;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant, SystemTime};
use wayland_client::protocol::wl_output::WlOutput;
use wayland_client::QueueHandle;

pub enum Action {
    TogglePanel(usize, String, f32),
    ClosePanel,
    Workspace(i32),
    WorkspaceStep(i32),
    VolumeStep(i32),
    SetVolume(f32),
    ToggleMute,
    SetBrightness(f32),
    SetMic(f32),
    ToggleMic,
    Media(mpris::Cmd),
    Power(String),
    WindowAct(String),
    WindowSnap(i32),
    MonthStep(i32),
    MonthReset,
    CycleTheme,
    Tile(String),
    NoteDismiss(i32),
    NoteAct(i32, String),
    NotesClear,
    ToggleDnd,
    DriveOpen(String),
    DriveMount(String),
    DriveEject(String),
    RunUpdates,
    OpenMail,
    TrayToggle,
    TrayActivate(usize, String, f32),
    TraySecondary(String),
    TrayMenu(usize, String, f32),
    TrayScroll(String, i32),
    MenuPick(i32, bool),
    MenuBack,
    ToastHover(bool),
    DockActivate(usize, usize),
    DockMenu(usize, usize, f32),
    DockMiddle(usize, usize),
    DockHover(usize, bool),
    AppMenu(String),
    CcPane(String),
    Wifi(bool),
    Bt(bool),
    Join(String),
    JoinSecret(String, String),
    Disconnect,
    Forget(String),
    Device(String),
    PairAnswer(bool),
}

type Queue = Rc<RefCell<Vec<Action>>>;

fn model<T: Clone + 'static>(v: Vec<T>) -> ModelRc<T> {
    ModelRc::from(Rc::new(VecModel::from(v)))
}

macro_rules! theme_into {
    ($c:expr, $t:expr, $us:expr) => {{
        let t: &theme::Theme = $t;
        let g = $c.global::<Theme>();
        g.set_panel(t.panel.slint());
        g.set_ink(t.ink.slint());
        g.set_ink2(t.ink2.slint());
        g.set_ink3(t.ink3.slint());
        g.set_accent(t.accent.slint());
        g.set_ink_on_accent(t.ink_on_accent.slint());
        g.set_hover(t.hover.slint());
        g.set_sel(t.sel.slint());
        g.set_edge(t.edge.slint());
        g.set_rule(t.rule.slint());
        g.set_div(t.div.slint());
        g.set_seam(t.seam.slint());
        g.set_dark(t.dark);
        g.set_r_cap(t.r);
        g.set_r_sm(t.r_sm);
        g.set_us($us);
        g.set_ff(t.font_factor);
        g.set_ws($us * t.workspace_scale);
        g.set_bar_height(t.bar_height);
        g.set_bar_font(t.bar_font);
        g.set_bar_title(t.bar_title);
        g.set_bar_app(t.bar_app);
        g.set_bar_menu(t.bar_menu);
        g.set_bar_clock(t.bar_clock);
        g.set_bar_badge(t.bar_badge);
        g.set_bar_icon(t.bar_icon);
        g.set_badges(t.badges);
    }};
}

/// The local time, broken down.
fn now_tm() -> libc::tm {
    // SAFETY: localtime_r fills the tm it is given and keeps nothing.
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm
    }
}

const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const MONTHS_LONG: [&str; 12] =
    ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

/// The local time as the bar shows it: "14:27" or "2:27 PM", "Thu 5 Nov".
fn clock(h24: bool) -> (String, String) {
    let tm = now_tm();
    let time = if h24 {
        format!("{:02}:{:02}", tm.tm_hour, tm.tm_min)
    } else {
        let h = match tm.tm_hour % 12 {
            0 => 12,
            h => h,
        };
        format!("{}:{:02} {}", h, tm.tm_min, if tm.tm_hour < 12 { "AM" } else { "PM" })
    };
    let date = format!("{} {} {}", DAYS[tm.tm_wday as usize % 7], tm.tm_mday, MONTHS[tm.tm_mon as usize % 12]);
    (time, date)
}

/// A month's grid, Sunday first, as CalendarPanel.qml lays it out.
fn month(offset: i32) -> (String, Vec<DayCell>) {
    let tm = now_tm();
    let total = tm.tm_year * 12 + tm.tm_mon + offset;
    let (y, m) = (total.div_euclid(12), total.rem_euclid(12));
    let days_in = |y: i32, m: i32| -> i32 {
        let year = y + 1900;
        match m {
            1 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
            1 => 28,
            3 | 5 | 8 | 10 => 30,
            _ => 31,
        }
    };
    // Weekday of the 1st (Zeller-free: mktime does it).
    // SAFETY: mktime reads and normalises the tm it is given.
    let first = unsafe {
        let mut t: libc::tm = std::mem::zeroed();
        t.tm_year = y;
        t.tm_mon = m;
        t.tm_mday = 1;
        t.tm_hour = 12;
        libc::mktime(&mut t);
        t.tm_wday
    };
    let mut cells = Vec::new();
    for _ in 0..first {
        cells.push(DayCell { day: 0, today: false });
    }
    for d in 1..=days_in(y, m) {
        cells.push(DayCell { day: d, today: offset == 0 && d == tm.tm_mday });
    }
    while cells.len() % 7 != 0 {
        cells.push(DayCell { day: 0, today: false });
    }
    (format!("{} {}", MONTHS_LONG[m as usize], y + 1900), cells)
}

fn ago(t: SystemTime) -> String {
    let s = t.elapsed().map(|d| d.as_secs()).unwrap_or(0);
    if s < 60 {
        "now".into()
    } else if s < 3600 {
        format!("{} min", s / 60)
    } else {
        let tm = {
            let secs = t.duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs() as libc::time_t).unwrap_or(0);
            // SAFETY: as in now_tm.
            unsafe {
                let mut tm: libc::tm = std::mem::zeroed();
                libc::localtime_r(&secs, &mut tm);
                tm
            }
        };
        format!("{:02}:{:02}", tm.tm_hour, tm.tm_min)
    }
}

fn mmss(us: i64) -> String {
    let s = (us / 1_000_000).max(0);
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
    } else {
        format!("{}:{:02}", s / 60, s % 60)
    }
}

fn uptime() -> String {
    let s = std::fs::read_to_string("/proc/uptime").ok().and_then(|t| t.split_whitespace().next()?.parse::<f64>().ok()).unwrap_or(0.0) as u64;
    let (d, h, m) = (s / 86400, s % 86400 / 3600, s % 3600 / 60);
    if d > 0 {
        format!("{d}d {h}h")
    } else if h > 0 {
        format!("{h}h {m}m")
    } else {
        format!("{m}m")
    }
}

/// The login name: $USER, or the password database when that isn't set.
fn user_name() -> String {
    if let Some(u) = std::env::var("USER").ok().filter(|u| !u.is_empty()) {
        return u;
    }
    // SAFETY: getpwuid returns a pointer into static storage, or null; the
    // name is copied out before anything else could call it.
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() || (*pw).pw_name.is_null() {
            return "user".into();
        }
        std::ffi::CStr::from_ptr((*pw).pw_name).to_string_lossy().into_owned()
    }
}

fn which(prog: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(prog).is_file()))
}

/// Workspace slots for one monitor's bar, as Compositor.workspaceSlots:
/// every workspace that exists, padded to five with the lowest free
/// numbers; the one that monitor shows is focused.
fn slots_for(monitor: &str) -> (Vec<Workspace>, String, String, bool) {
    let all = hypr::json("j/workspaces");
    let monitors = hypr::json("j/monitors");
    let clients = hypr::json("j/clients");
    let focused = monitors
        .as_array()
        .and_then(|ms| ms.iter().find(|m| m["name"] == monitor).or(ms.first()))
        .and_then(|m| m["activeWorkspace"]["id"].as_i64())
        .unwrap_or(1);
    let urgent: std::collections::HashSet<i64> = clients
        .as_array()
        .into_iter()
        .flatten()
        .filter(|c| c["urgent"] == true)
        .filter_map(|c| c["workspace"]["id"].as_i64())
        .collect();
    let mut ids: Vec<(i64, i64)> = Vec::new();
    for w in all.as_array().into_iter().flatten() {
        let id = w["id"].as_i64().unwrap_or(0);
        // Show desktop's stash (99) only when something landed on it.
        if id > 0 && (id != 99 || w["windows"].as_i64().unwrap_or(0) > 0) {
            ids.push((id, w["windows"].as_i64().unwrap_or(0)));
        }
    }
    if !ids.iter().any(|(i, _)| *i == focused) && focused > 0 && focused != 99 {
        ids.push((focused, 0));
    }
    let mut i = 1;
    while ids.len() < 5 && i <= 5 {
        if !ids.iter().any(|(x, _)| *x == i) {
            ids.push((i, 0));
        }
        i += 1;
    }
    ids.sort();
    let list = ids
        .into_iter()
        .map(|(id, n)| Workspace { id: id as i32, focused: id == focused, occupied: n > 0, urgent: urgent.contains(&id) })
        .collect();
    let active = hypr::json("j/activewindow");
    let class = active["class"].as_str().unwrap_or("").to_string();
    let title = active["title"].as_str().unwrap_or("").to_string();
    let has = active["address"].as_str().is_some_and(|a| !a.is_empty());
    (list, class, title, has)
}

struct BarOn {
    bar: Bar,
    monitor: String,
    output: WlOutput,
    /// Logical height of the bar.
    height: f32,
    panels: Panels,
    panel_window: Rc<MinimalSoftwareWindow>,
    panel_surface: Option<usize>,
    /// Entrance.qml's springs for the panel on this monitor.
    anim: PanelAnim,
    /// Closed, and fading: the surface goes once it has.
    closing: bool,
    dock: crate::Dock,
    dock_surface: usize,
    dock_geom: DockGeom,
    /// The pill's place: shown, or tucked under the bottom edge.
    reveal: Spring,
    reveal_to: f64,
    /// The pointer has been on it (and for a moment after it leaves).
    latch: bool,
    hide_at: Option<Instant>,
    dock_tiles: Vec<crate::dock::Tile>,
    dock_input: Option<(i32, i32, i32, i32)>,
    /// Over a fullscreen window: on the overlay layer, keeping no room.
    over: bool,
    fullscreen: bool,
    /// The height and room last given the dock's surface.
    applied: (u32, i32),
    /// The wallpaper's surface, what was last drawn on it, and whether a
    /// drawing is under way.
    ground: usize,
    ground_done: Option<(crate::ground::Spec, u32, u32)>,
    ground_busy: bool,
}

/// The dock's measures on one monitor, logical px (Dock.qml's).
#[derive(Clone, Copy, Default)]
struct DockGeom {
    head: f32,
    breadth: f32,
    edge: f32,
    exclusive: i32,
    hides: bool,
}

fn dock_geom(raw: &serde_json::Value, us: f32) -> (DockGeom, f32, f32, f32, f32, f32, f32) {
    let num = |k: &str, d: f64| raw[k].as_f64().unwrap_or(d) as f32;
    let u = |px: f32| (px * us).round().max(1.0);
    let size = num("dockSize", 42.0);
    let tile = u(size);
    let icon = u((size * num("dockIcon", 50.0) / 100.0).round().max(8.0));
    let breadth = u(size + 10.0);
    let edge = u(num("dockGap", 16.0).clamp(0.0, 40.0));
    let hides = raw["dockHide"].as_bool().unwrap_or(false);
    let gaps_out = num("gapsOut", 8.0).max(0.0);
    let exclusive = if hides { 0 } else { breadth.max(breadth + edge * 2.0 - gaps_out).round() as i32 };
    (DockGeom { head: u(46.0), breadth, edge, exclusive, hides }, tile, icon, u(7.0), u(5.0), u(3.0), num("dockLabelSize", 12.0))
}

fn shell_input_off(id: usize, pending: &mut Vec<usize>) {
    pending.push(id);
}

/// Entrance.qml: the panel grows out of its button (width from 74 %,
/// height from 50 %, a little lift) with some bounce, the sheet fades in
/// quickly and the content after it; going, all of it quickly and without
/// bounce. Without "panels grow", it only rises a little.
struct PanelAnim {
    sx: Spring,
    sy: Spring,
    lift: Spring,
    glass: Spring,
    inner: Spring,
    /// Rising from the dock rather than dropping from the bar.
    up: bool,
}

impl PanelAnim {
    fn new() -> PanelAnim {
        PanelAnim { sx: Spring::new(1.0), sy: Spring::new(1.0), lift: Spring::new(0.0), glass: Spring::new(0.0), inner: Spring::new(0.0), up: false }
    }

    fn from_y(&self) -> f64 {
        if self.up { 10.0 } else { -10.0 }
    }

    fn start(&self, grows: bool) -> (f64, f64, f64) {
        if grows {
            (0.74, 0.5, self.from_y() * 0.4)
        } else {
            (0.97, 0.97, self.from_y() * 1.2)
        }
    }

    fn show(&mut self, fresh: bool, grows: bool, m: &Motion) {
        let grows = grows && m.springy && m.speed > 0.0;
        let (x0, y0, l0) = self.start(grows);
        // From the start unless it is still mostly there (reopened while
        // fading out), as Entrance does.
        if fresh || self.glass.value <= 0.05 {
            self.sx.snap(x0);
            self.sy.snap(y0);
            self.lift.snap(l0);
            self.inner.snap(-0.45);
            if fresh {
                self.glass.snap(0.0);
            }
        }
        self.sx.go(1.0, 340.0, 0.9, m);
        self.sy.go(1.0, 400.0, 0.8, m);
        self.lift.go(0.0, 360.0, 0.8, m);
        self.glass.go(1.0, 150.0, 0.0, m);
        self.inner.go(1.0, 260.0, 0.0, m);
    }

    fn hide(&mut self, grows: bool, m: &Motion) {
        let grows = grows && m.springy && m.speed > 0.0;
        let (x0, y0, l0) = self.start(grows);
        self.sx.go(x0, 230.0, 0.0, m);
        self.sy.go(y0, 210.0, 0.0, m);
        self.lift.go(l0, 210.0, 0.0, m);
        self.glass.go(0.0, 170.0, 0.0, m);
        self.inner.go(0.0, 120.0, 0.0, m);
    }

    fn moving(&self) -> bool {
        self.sx.moving || self.sy.moving || self.lift.moving || self.glass.moving || self.inner.moving
    }

    fn step(&mut self, dt: f64, m: &Motion) {
        for s in [&mut self.sx, &mut self.sy, &mut self.lift, &mut self.glass, &mut self.inner] {
            s.step(dt, m);
        }
    }

    fn apply(&self, p: &Panels) {
        p.set_sx(self.sx.value as f32);
        p.set_sy(self.sy.value as f32);
        p.set_lift(self.lift.value as f32);
        p.set_glass(self.glass.value as f32);
        p.set_inner(self.inner.value as f32);
    }
}

struct Stored {
    id: u32,
    app: String,
    summary: String,
    body: String,
    icon: Option<slint::Image>,
    urgent: bool,
    actions: Vec<(String, String)>,
    at: SystemTime,
}

pub struct App {
    actions: Queue,
    bars: Vec<BarOn>,
    open: Option<(usize, String)>,

    toasts: Toasts,
    toast_window: Rc<MinimalSoftwareWindow>,
    toast_surface: Option<usize>,
    /// Shown as banners: id and when each goes (None: until dismissed).
    toast_list: Vec<(u32, Option<Instant>)>,
    toast_hover: bool,
    notes: Vec<Stored>,
    notify_conn: Option<zbus::blocking::Connection>,

    look: theme::Theme,
    look_stamp: Option<SystemTime>,
    sound: daemon::State,
    daemon: daemon::Daemon,
    /// The equalizer, noise suppression and listening (AudioFx.qml).
    fx: crate::audiofx::Fx,
    media: mpris::Media,
    media_cmd: Sender<mpris::Cmd>,
    art: (String, Option<slint::Image>),
    eq: slint::Timer,
    eq_tick: Rc<RefCell<i32>>,
    sharing: bool,

    hypr_rx: Receiver<String>,
    daemon_rx: Receiver<serde_json::Value>,
    media_rx: Receiver<mpris::Media>,
    art_tx: Sender<(String, Option<Pixels>)>,
    art_rx: Receiver<(String, Option<Pixels>)>,
    notify_rx: Receiver<notify::Event>,
    notify_ready: Receiver<zbus::blocking::Connection>,
    tray_rx: Receiver<tray::Event>,
    tray_cmd: Sender<tray::Cmd>,
    extras_rx: Receiver<extras::Event>,
    updates_now: Sender<()>,

    tray_items: Vec<tray::Item>,
    menu_key: String,
    menu_stack: Vec<(i32, String)>,
    menu_entries: Vec<tray::Entry>,
    menu_at: Option<(usize, f32)>,
    updates: Vec<String>,
    update_helper: String,
    mail: Option<i64>,
    month_offset: i32,
    /// Hyprland's windows, the focused one, the pinned apps: the docks'.
    clients: Vec<crate::dock::Client>,
    active_addr: String,
    active_class: String,
    pinned: Vec<crate::launcher::Pinned>,
    dock_labels: HashMap<String, String>,
    switcher: crate::switch_ui::Host,
    switch_acts: Rc<RefCell<Vec<crate::switch_ui::Act>>>,
    osd: crate::Osd,
    osd_window: Rc<MinimalSoftwareWindow>,
    osd_surface: Option<usize>,
    /// When the popup goes, and its springs: rise, fade, grow.
    osd_until: Option<Instant>,
    osd_springs: [Spring; 3],
    /// Settings → Display's Identify: a number on each screen, until then.
    ident: Vec<(crate::Identify, usize)>,
    ident_until: Option<Instant>,
    /// The control center's list on screen ("", "wifi", "bluetooth"), the
    /// network asking for its password, the one being joined, the device
    /// being worked on, and a pairing question: (id, name, code).
    cc_pane: String,
    asking: String,
    joining: String,
    wifi_note: String,
    bt_busy: String,
    pairing: Option<(u64, String, String)>,
    net_id: u64,
    /// The dock tile a menu is open for: (monitor, tile).
    menu_for: Option<(usize, usize)>,
    /// The polkit agent: its prompt, the request on it and those waiting,
    /// and where it tells the agent how each ended.
    prompt: crate::PolkitPrompt,
    prompt_window: Rc<MinimalSoftwareWindow>,
    prompt_surface: Option<usize>,
    auth: Option<crate::polkit::Request>,
    auth_queue: Vec<crate::polkit::Request>,
    auth_user: usize,
    outcomes: std::sync::Arc<std::sync::Mutex<HashMap<String, bool>>>,
    polkit_rx: Receiver<crate::polkit::Event>,
    said_tx: Sender<crate::polkit::Said>,
    said_rx: Receiver<crate::polkit::Said>,
    prompt_acts: Rc<RefCell<Vec<i32>>>,
    ground_spec: crate::ground::Spec,
    ground_tx: Sender<(usize, crate::ground::Spec, u32, u32, Vec<u8>)>,
    ground_rx: Receiver<(usize, crate::ground::Spec, u32, u32, Vec<u8>)>,
    live: crate::ground::Live,
    /// The monitor in use when last asked (for sizes that follow its scale).
    focused_bar_cached: usize,
    launcher: crate::launch_ui::Host,
    launch_acts: Rc<RefCell<Vec<crate::launch_ui::Act>>>,
    icon_tx: Sender<Vec<(String, Pixels)>>,
    icon_rx: Receiver<Vec<(String, Pixels)>>,
    last_tick: Instant,
    last_frame: Instant,
    /// Panel surfaces to stop taking the pointer, at the next step.
    pending_input: Vec<usize>,
    wake: UnixStream,
}

impl App {
    pub fn new(shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, wake: UnixStream) -> App {
        let w = || wake.try_clone().expect("wake");
        let (hypr_tx, hypr_rx) = channel();
        hypr::listen(hypr_tx, w());
        let (daemon_tx, daemon_rx) = channel();
        let mut daemon = daemon::start(daemon_tx, w());
        // Hyprland forgets what Settings set (input, borders, gaps, motion,
        // displays, binds.lua) every time it starts: put it back, as
        // Quickshell's Devices.qml did. Nothing happens without the app.
        extras::spawn(&["hyprshell-settings", "--apply"]);
        let (media_tx, media_rx) = channel();
        let (media_cmd, media_cmd_rx) = channel();
        mpris::start(media_tx, media_cmd_rx, w());
        let (art_tx, art_rx) = channel();
        let (notify_tx, notify_rx) = channel();
        let (ready_tx, notify_ready) = channel();
        notify::start(notify_tx, w(), ready_tx, w());
        let (tray_tx, tray_rx) = channel();
        let (tray_cmd, tray_cmd_rx) = channel();
        tray::start(tray_tx, tray_cmd_rx, w());
        let (extras_tx, extras_rx) = channel();
        let (updates_now, updates_now_rx) = channel();
        extras::updates(extras_tx.clone(), updates_now_rx, w());
        extras::mail(extras_tx, w());

        let look = theme::load();
        let look_stamp = theme::modified();
        let raw = theme::raw();
        daemon.send(json!({ "cmd": "bt-hello" }));
        daemon.send(json!({
            "cmd": "usb-config",
            "automount": raw["usbAutomount"].as_bool().unwrap_or(true),
            "notify": raw["usbNotify"].as_bool().unwrap_or(true)
        }));

        let actions: Queue = Rc::new(RefCell::new(Vec::new()));

        // A bar, a panel layer and a dock on every monitor.
        let mut bars = Vec::new();
        let outputs: Vec<_> = shell.outputs.outputs().collect();
        for (i, output) in outputs.iter().enumerate() {
            let monitor = shell.outputs.info(output).and_then(|i| i.name).unwrap_or_default();
            let us = look.screen_scale(&monitor);
            let bar = Bar::new().expect("the bar");
            theme_into!(bar, &look, us);
            wire_bar(&bar, i, &actions);
            let height = (look.bar_height * us).round().max(1.0);
            shell.add(qh, Some(output), &wl::Placement {
                // The Quickshell bar's namespace, so hyprland.lua's layer
                // rules (the blur behind it) apply to this one as well.
                namespace: "quickshell:bar",
                layer: Layer::Top,
                anchor: Anchor::TOP | Anchor::LEFT | Anchor::RIGHT,
                width: 0,
                height: height as u32,
                exclusive: height as i32,
                keyboard: KeyboardInteractivity::None,
            });
            let panels = Panels::new().expect("the panels");
            let panel_window = crate::platform::take_adapter().expect("the panels' window");
            theme_into!(panels, &look, us);
            wire_panels(&panels, &actions);
            panels.set_user(user_name().into());
            // The wallpaper, under everything.
            let ground = shell.add_picture(qh, Some(output), &wl::Placement {
                namespace: "quickshell:wallpaper",
                layer: Layer::Background,
                anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                width: 0,
                height: 0,
                exclusive: -1,
                keyboard: KeyboardInteractivity::None,
            });
            // The dock, under everything on this monitor.
            let dock = crate::Dock::new().expect("the dock");
            theme_into!(dock, &look, us);
            {
                let q = actions.clone();
                dock.on_activate(move |t, _| q.borrow_mut().push(Action::DockActivate(i, t as usize)));
                let q = actions.clone();
                dock.on_secondary(move |t, x| q.borrow_mut().push(Action::DockMenu(i, t as usize, x)));
                let q = actions.clone();
                dock.on_middle(move |t| q.borrow_mut().push(Action::DockMiddle(i, t as usize)));
                let q = actions.clone();
                dock.on_hovered(move |h| q.borrow_mut().push(Action::DockHover(i, h)));
            }
            let (geom, tile, icon, pad_h, pad_v, gap, label) = dock_geom(&raw, us);
            dock.set_tile(tile);
            dock.set_icon_size(icon);
            dock.set_pad_h(pad_h);
            dock.set_pad_v(pad_v);
            dock.set_gap(gap);
            dock.set_label_size(label);
            dock.set_pill_y(geom.head);
            let dock_surface = shell.add(qh, Some(output), &wl::Placement {
                namespace: "quickshell:dock",
                layer: Layer::Top,
                anchor: Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                width: 0,
                height: (geom.head + geom.breadth + geom.edge) as u32,
                exclusive: geom.exclusive,
                keyboard: KeyboardInteractivity::None,
            });
            bars.push(BarOn {
                bar,
                monitor,
                output: output.clone(),
                height,
                panels,
                panel_window,
                panel_surface: None,
                anim: PanelAnim::new(),
                closing: false,
                dock,
                dock_surface,
                dock_geom: geom,
                reveal: Spring::new(geom.head as f64),
                reveal_to: geom.head as f64,
                latch: false,
                hide_at: None,
                dock_tiles: Vec::new(),
                dock_input: None,
                over: false,
                fullscreen: false,
                applied: ((geom.head + geom.breadth + geom.edge) as u32, geom.exclusive),
                ground,
                ground_done: None,
                ground_busy: false,
            });
        }

        let toasts = Toasts::new().expect("the banners");
        let toast_window = crate::platform::take_adapter().expect("the banners' window");
        theme_into!(toasts, &look, 1.0);
        {
            let q = actions.clone();
            toasts.on_dismiss(move |id| q.borrow_mut().push(Action::NoteDismiss(id)));
            let q = actions.clone();
            toasts.on_act(move |id, k| q.borrow_mut().push(Action::NoteAct(id, k.to_string())));
            let q = actions.clone();
            toasts.on_hovered(move |h| q.borrow_mut().push(Action::ToastHover(h)));
        }

        let launch_acts = Rc::new(RefCell::new(Vec::new()));
        let launcher = crate::launch_ui::Host::new(launch_acts.clone());
        theme_into!(launcher.ui, &look, 1.0);
        let (icon_tx, icon_rx) = channel();

        let (ground_tx, ground_rx) = channel();
        let outcomes = std::sync::Arc::new(std::sync::Mutex::new(HashMap::new()));
        let (polkit_tx, polkit_rx) = channel();
        crate::polkit::start(polkit_tx, wake.try_clone().expect("wake"), outcomes.clone());
        let (said_tx, said_rx) = channel();
        let prompt = crate::PolkitPrompt::new().expect("the password prompt");
        let prompt_window = crate::platform::take_adapter().expect("the prompt's window");
        theme_into!(prompt, &look, 1.0);
        // -1 submit, -2 cancel, n ≥ 0 that user.
        let prompt_acts: Rc<RefCell<Vec<i32>>> = Rc::new(RefCell::new(Vec::new()));
        {
            let q = prompt_acts.clone();
            prompt.on_submit(move || q.borrow_mut().push(-1));
            let q = prompt_acts.clone();
            prompt.on_cancel(move || q.borrow_mut().push(-2));
            let q = prompt_acts.clone();
            prompt.on_pick_user(move |i| q.borrow_mut().push(i));
        }
        let switch_acts = Rc::new(RefCell::new(Vec::new()));
        let switcher = crate::switch_ui::Host::new(switch_acts.clone());
        theme_into!(switcher.ui, &look, 1.0);
        let osd = crate::Osd::new().expect("the popup");
        let osd_window = crate::platform::take_adapter().expect("the popup's window");
        theme_into!(osd, &look, 1.0);

        let mut app = App {
            switcher,
            switch_acts,
            osd,
            osd_window,
            osd_surface: None,
            osd_until: None,
            osd_springs: [Spring::new(24.0), Spring::new(0.0), Spring::new(0.86)],
            ident: Vec::new(),
            fx: crate::audiofx::Fx::new(),
            ident_until: None,
            launcher,
            prompt,
            prompt_window,
            prompt_surface: None,
            auth: None,
            auth_queue: Vec::new(),
            auth_user: 0,
            outcomes,
            polkit_rx,
            said_tx,
            said_rx,
            prompt_acts,
            ground_spec: crate::ground::spec(&raw, look.dark),
            ground_tx,
            ground_rx,
            live: crate::ground::Live::new(),
            focused_bar_cached: 0,
            clients: Vec::new(),
            active_addr: String::new(),
            active_class: String::new(),
            pinned: Vec::new(),
            dock_labels: HashMap::new(),
            menu_for: None,
            cc_pane: String::new(),
            asking: String::new(),
            joining: String::new(),
            wifi_note: String::new(),
            bt_busy: String::new(),
            pairing: None,
            net_id: 0,
            launch_acts,
            icon_tx,
            icon_rx,
            actions,
            bars,
            open: None,
            toasts,
            toast_window,
            toast_surface: None,
            toast_list: Vec::new(),
            toast_hover: false,
            notes: Vec::new(),
            notify_conn: None,
            look,
            look_stamp,
            sound: daemon::State { kbd_level: -1, ..Default::default() },
            daemon,
            media: mpris::Media::default(),
            media_cmd,
            art: (String::new(), None),
            eq: slint::Timer::default(),
            eq_tick: Rc::new(RefCell::new(0)),
            sharing: false,
            hypr_rx,
            daemon_rx,
            media_rx,
            art_tx,
            art_rx,
            notify_rx,
            notify_ready,
            tray_rx,
            tray_cmd,
            extras_rx,
            updates_now,
            tray_items: Vec::new(),
            menu_key: String::new(),
            menu_stack: Vec::new(),
            menu_entries: Vec::new(),
            menu_at: None,
            updates: Vec::new(),
            update_helper: String::new(),
            mail: None,
            month_offset: 0,
            last_tick: Instant::now() - Duration::from_secs(2),
            last_frame: Instant::now(),
            pending_input: Vec::new(),
            wake,
        };
        app.refresh_hypr();
        app.refresh_look();
        app.refresh_second();
        app.refresh_session();
        app
    }

    /// How long the loop may sleep before something here is due.
    pub fn next_tick(&self) -> Duration {
        let mut d = Duration::from_secs(1).saturating_sub(self.last_tick.elapsed());
        for (_, until) in &self.toast_list {
            if let Some(t) = until {
                d = d.min(t.saturating_duration_since(Instant::now()));
            }
        }
        // A frame's time while a panel moves.
        if self.bars.iter().any(|b| b.anim.moving() || b.reveal.moving || b.hide_at.is_some()) || self.launcher.moving() {
            d = d.min(Duration::from_millis(7));
        }
        if let Some(t) = self.switcher.next_due() {
            d = d.min(t);
        }
        if self.osd_until.is_some() || self.osd_springs.iter().any(|s| s.moving) {
            d = d.min(Duration::from_millis(7));
        }
        if let Some(t) = self.ident_until {
            d = d.min(t.saturating_duration_since(Instant::now()));
        }
        d.max(Duration::from_millis(1))
    }

    // ── what arrived ─────────────────────────────────────────────────────

    pub fn step(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) {
        // Hyprland: workspaces, focus, screen sharing.
        let mut hypr_changed = false;
        while let Ok(line) = self.hypr_rx.try_recv() {
            hypr_changed = true;
            if let Some(d) = line.strip_prefix("screencast>>") {
                self.sharing = d.starts_with('1');
                self.refresh_privacy();
            }
        }
        if hypr_changed {
            self.refresh_hypr();
        }

        // The daemon.
        let mut changed = false;
        let mut fx_due = false;
        while let Ok(ev) = self.daemon_rx.try_recv() {
            fx_due |= self.fx.event(&ev);
            if ev["ev"] == "cmd" {
                if let Some(line) = ev["line"].as_str() {
                    self.command(shell, qh, line);
                }
                continue;
            }
            match ev["ev"].as_str() {
                Some("net-done") => {
                    if ev["ok"] != true {
                        let e = ev["error"].as_str().unwrap_or("");
                        self.wifi_note = if self.joining.is_empty() { e.to_string() } else { format!("Couldn't join {}: {e}", self.joining) };
                    } else {
                        self.wifi_note.clear();
                    }
                    self.joining.clear();
                    self.refresh_lists();
                    continue;
                }
                Some("bt-done") | Some("bt-error") => {
                    self.bt_busy.clear();
                    self.refresh_lists();
                    if ev["ev"] == "bt-done" {
                        continue;
                    }
                }
                Some("bt-request") => {
                    let id = ev["id"].as_u64().unwrap_or(0);
                    let name = ev["name"].as_str().unwrap_or("A device").to_string();
                    match ev["kind"].as_str().unwrap_or("") {
                        "confirm" | "authorize" | "service" => {
                            self.pairing = Some((id, name, ev["passkey"].as_str().unwrap_or("").to_string()));
                        }
                        // Typing a PIN in isn't here yet: turned down, so
                        // the device doesn't wait.
                        _ => {
                            self.daemon.send(json!({ "cmd": "bt-reply", "id": id, "accept": false }));
                            self.wifi_note.clear();
                        }
                    }
                    self.refresh_lists();
                    continue;
                }
                Some("bt-cancel") => {
                    self.pairing = None;
                    self.refresh_lists();
                    continue;
                }
                _ => {}
            }
            if ev["ev"] == "calc" {
                let q = ev["query"].as_str().unwrap_or("").to_string();
                self.launcher.calc_result(&q, ev["result"].as_str().map(str::to_string));
                continue;
            }
            if ev["ev"] == "fs-results" {
                let q = ev["query"].as_str().unwrap_or("").to_string();
                let list = ev["results"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|r| {
                        let s = |k: &str| r[k].as_str().unwrap_or("").to_string();
                        (s("path"), s("name"), s("dir"), r["isDir"] == true)
                    })
                    .collect();
                self.launcher.file_results(&q, list);
                continue;
            }
            if ev["ev"] == "usb-open" {
                if let Some(m) = ev["mount"].as_str() {
                    extras::spawn(&["xdg-open", m]);
                }
                continue;
            }
            changed |= daemon::apply(&mut self.sound, &ev);
        }
        if fx_due {
            self.fx.sync(&theme::raw(), &mut self.daemon);
        }
        if changed {
            self.refresh_lists();
            self.refresh_sound();
            self.refresh_privacy();
            self.refresh_drives();
        }

        // What's playing.
        let mut media_changed = false;
        while let Ok(m) = self.media_rx.try_recv() {
            self.media = m;
            media_changed = true;
        }
        while let Ok((url, px)) = self.art_rx.try_recv() {
            if url == self.media.art {
                self.art = (url, px.map(slint::Image::from_rgba8));
                media_changed = true;
            }
        }
        if media_changed {
            self.refresh_media();
        }

        // Notifications.
        if let Ok(c) = self.notify_ready.try_recv() {
            self.notify_conn = Some(c);
        }
        let mut notes_changed = false;
        while let Ok(ev) = self.notify_rx.try_recv() {
            notes_changed = true;
            match ev {
                notify::Event::Note(n) => self.incoming(n),
                notify::Event::Close(id) => {
                    self.forget(id);
                    if let Some(c) = &self.notify_conn {
                        notify::signal_closed(c, id, 3);
                    }
                }
            }
        }
        if notes_changed {
            self.refresh_notes(shell, qh);
        }

        // The tray.
        while let Ok(ev) = self.tray_rx.try_recv() {
            match ev {
                tray::Event::Items(items) => {
                    self.tray_items = items;
                    self.refresh_tray();
                }
                tray::Event::Menu { key, heading, nested, entries } => {
                    if entries.is_empty() && !nested {
                        continue;
                    }
                    if !nested {
                        self.menu_stack.clear();
                    }
                    self.menu_key = key;
                    self.menu_entries = entries.clone();
                    let rows: Vec<MenuEntry> = entries
                        .iter()
                        .map(|e| MenuEntry {
                            id: e.id,
                            label: e.label.clone().into(),
                            enabled: e.enabled,
                            separator: e.separator,
                            toggle: e.toggle,
                            checked: e.checked,
                            submenu: e.submenu,
                            icon: Default::default(),
                            has_icon: false,
                        })
                        .collect();
                    for b in &self.bars {
                        b.panels.set_menu(model(rows.clone()));
                        b.panels.set_menu_heading(heading.clone().into());
                        b.panels.set_menu_nested(nested);
                        b.panels.set_menu_toggles(entries.iter().any(|e| e.toggle > 0));
                    }
                    if let Some((bar, x)) = self.menu_at {
                        if self.open.as_ref().map(|o| o.1.as_str()) != Some("tray") {
                            self.open_panel(shell, qh, bar, "tray", x);
                        }
                    }
                }
            }
        }

        // Updates, Mail.
        while let Ok(ev) = self.extras_rx.try_recv() {
            match ev {
                extras::Event::Updates { names, helper } => {
                    self.updates = names;
                    self.update_helper = helper;
                }
                extras::Event::Mail(n) => self.mail = n,
            }
            self.refresh_extras();
        }

        // Esc on a panel.
        for (id, _) in std::mem::take(&mut shell.keys) {
            if self.bars.iter().any(|b| b.panel_surface == Some(id)) {
                self.close_panel();
            }
        }

        // The banners' surface follows their height once they are laid out
        // at their real width.
        if let Some(id) = self.toast_surface {
            let h = (self.toasts.get_wanted_height().ceil() as u32).max(1);
            shell.resize(id, 376 + 12, h);
        }

        // Banners that have had their time.
        if !self.toast_hover {
            let now = Instant::now();
            let before = self.toast_list.len();
            self.toast_list.retain(|(_, until)| until.is_none_or(|t| t > now));
            if self.toast_list.len() != before {
                self.refresh_toasts(shell, qh);
            }
        }

        for id in std::mem::take(&mut self.pending_input) {
            shell.set_input(id, false);
        }

        // The panels' springs, a step each frame; a panel surface goes once
        // its panel has faded out.
        let dt = self.last_frame.elapsed().as_secs_f64();
        self.last_frame = Instant::now();
        let m = self.look.motion;
        for b in &mut self.bars {
            if b.anim.moving() {
                b.anim.step(dt, &m);
                b.anim.apply(&b.panels);
            }
            if b.closing && !b.anim.moving() {
                // (panels)
                b.closing = false;
                b.panels.set_which("".into());
                if let Some(id) = b.panel_surface.take() {
                    shell.remove(id);
                }
            }
        }

        self.step_docks(shell, dt);
        self.step_ground(shell);
        self.step_polkit(shell, qh);
        self.step_switcher(shell, qh);
        self.step_osd(shell, dt);
        if self.ident_until.is_some_and(|t| Instant::now() >= t) {
            self.ident_until = None;
            for (_, id) in self.ident.drain(..) {
                shell.remove(id);
            }
        }

        // The launcher: its springs, its icons, and its surface once it has
        // gone.
        if self.launcher.moving() {
            self.launcher.step(dt, &m);
        }
        if self.launcher.closing && !self.launcher.moving() {
            self.launcher.closing = false;
            if let Some(id) = self.launcher.surface.take() {
                shell.remove(id);
            }
        }
        while let Ok(icons) = self.icon_rx.try_recv() {
            self.launcher.add_icons(icons);
        }

        if self.last_tick.elapsed() >= Duration::from_secs(1) {
            self.last_tick = Instant::now();
            self.fx.sync(&theme::raw(), &mut self.daemon);
            let stamp = theme::modified();
            if stamp != self.look_stamp {
                self.look_stamp = stamp;
                self.look = theme::load();
                self.refresh_look();
                self.refresh_extras();
            }
            self.refresh_second();
            self.live.tick();
        }
    }

    // ── refreshing what is shown ─────────────────────────────────────────

    fn refresh_hypr(&mut self) {
        for b in &self.bars {
            let (ws, class, title, has) = slots_for(&b.monitor);
            b.bar.set_workspaces(model(ws));
            b.bar.set_app_class(SharedString::from(class));
            b.bar.set_window_title(SharedString::from(title));
            b.bar.set_has_client(has);
        }
        self.refresh_dock();
    }

    /// The docks' windows and tiles, from Hyprland now.
    fn refresh_dock(&mut self) {
        self.clients = crate::dock::clients();
        let active = hypr::json("j/activewindow");
        self.active_addr = active["address"].as_str().unwrap_or("").to_string();
        self.active_class = active["class"].as_str().unwrap_or("").to_string();
        self.dock_tiles();
    }

    /// The tiles as they stand (Start lit while the launcher is open).
    fn dock_tiles(&mut self) {
        use crate::dock::Tile;
        let raw = theme::raw();
        self.pinned = crate::launcher::pinned(&raw);
        let scope_all = raw["dockScope"].as_str() == Some("all");
        let desktop = raw["dockDesktopTile"].as_bool().unwrap_or(true);
        let labels = raw["dockLabels"].as_bool().unwrap_or(true);
        let launcher_open = self.launcher.is_open();
        for b in &mut self.bars {
            let shown = crate::dock::shown_on(&self.clients, &b.monitor, scope_all);
            b.fullscreen = shown.iter().any(|c| c.fullscreen == 2 && !c.minimised);
            let tiles = crate::dock::tiles(&self.pinned, &shown, desktop);
            let count = |n: usize| match n {
                0 => "not running".to_string(),
                1 => "1 window".to_string(),
                n => format!("{n} windows"),
            };
            let rows: Vec<crate::DockTileData> = tiles
                .iter()
                .map(|t| {
                    let mut d = crate::DockTileData {
                        kind: "app".into(),
                        label: "".into(),
                        sub: "".into(),
                        glyph: crate::glyphs::glyph("square"),
                        windows: 0,
                        active: false,
                        accent: false,
                        named: false,
                    };
                    match t {
                        Tile::Start => {
                            d.kind = "start".into();
                            d.label = "Start".into();
                            d.sub = "super".into();
                            d.glyph = crate::glyphs::glyph("grid");
                            d.accent = launcher_open;
                            d.active = launcher_open;
                        }
                        Tile::Divider => d.kind = "divider".into(),
                        Tile::Pin { index, windows } => {
                            let p = &self.pinned[*index];
                            d.kind = "pin".into();
                            d.label = p.label.clone().into();
                            d.sub = count(windows.len()).into();
                            d.glyph = crate::glyphs::glyph(&p.icon);
                            d.windows = windows.len() as i32;
                            d.active = !self.active_class.is_empty() && windows.contains(&self.active_addr);
                            d.named = d.active && labels;
                        }
                        Tile::App { class, windows } => {
                            let label = self
                                .dock_labels
                                .entry(class.clone())
                                .or_insert_with(|| crate::dock::label_for(class))
                                .clone();
                            d.label = label.into();
                            d.sub = "not pinned".into();
                            d.glyph = crate::glyphs::glyph(crate::launcher::glyph_for_class(class));
                            d.windows = windows.len() as i32;
                            d.active = windows.contains(&self.active_addr);
                            d.named = d.active && labels;
                        }
                        Tile::Desktop => {
                            d.kind = "desktop".into();
                            d.label = "Show desktop".into();
                            d.sub = "toggle".into();
                            d.glyph = crate::glyphs::glyph("minus");
                        }
                    }
                    d
                })
                .collect();
            b.dock.set_tiles(model(rows));
            b.dock_tiles = tiles;
        }
    }

    /// Each frame: where each dock's pill should be, the spring taking it
    /// there, which layer it's on, and where it takes the pointer.
    fn step_docks(&mut self, shell: &mut wl::Shell, dt: f64) {
        let m = self.look.motion;
        let launcher_here = if self.launcher.is_open() { Some(self.focused_bar_cached) } else { None };
        let now = Instant::now();
        for (i, b) in self.bars.iter_mut().enumerate() {
            if b.hide_at.is_some_and(|t| now >= t) {
                b.hide_at = None;
                b.latch = false;
            }
            let g = b.dock_geom;
            let hides = g.hides || b.fullscreen;
            let revealed = !hides || b.latch || launcher_here == Some(i);
            let to = if revealed { g.head as f64 } else { (g.head + g.breadth + 20.0) as f64 };
            if to != b.reveal_to {
                b.reveal_to = to;
                if revealed {
                    b.reveal.go(to, 380.0, 0.7, &m);
                } else {
                    b.reveal.go(to, 260.0, 0.0, &m);
                }
            }
            if b.reveal.moving {
                b.reveal.step(dt, &m);
            }
            b.dock.set_pill_y(b.reveal.value as f32);
            // Over a fullscreen window it takes the overlay layer and keeps
            // no room; otherwise the top layer and its strip.
            let want = ((g.head + g.breadth + g.edge) as u32, g.exclusive);
            if want != b.applied {
                b.applied = want;
                shell.resize(b.dock_surface, 0, want.0);
                if !b.over {
                    shell.set_layer(b.dock_surface, Layer::Top, want.1);
                }
            }
            if b.fullscreen != b.over {
                b.over = b.fullscreen;
                let (layer, ex) = if b.over { (Layer::Overlay, 0) } else { (Layer::Top, g.exclusive) };
                shell.set_layer(b.dock_surface, layer, ex);
            }
            let total = (g.head + g.breadth + g.edge) as i32;
            let input = if revealed {
                let (x, w) = (b.dock.get_pill_x() as i32, b.dock.get_pill_width() as i32);
                let y = b.reveal.value as i32;
                Some((x - 40, y, w + 80, total - y))
            } else {
                Some((0, total - 3, 100_000, 3))
            };
            if input != b.dock_input {
                b.dock_input = input;
                shell.set_input_rect(b.dock_surface, input);
            }
        }
    }

    fn dock_activate(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, bar: usize, t: usize) {
        use crate::dock::Tile;
        let Some(tile) = self.bars.get(bar).and_then(|b| b.dock_tiles.get(t)).cloned() else { return };
        let raw = theme::raw();
        let windows_mode = raw["windowMode"].as_str() == Some("windows");
        let ws = crate::dock::monitor(&self.bars[bar].monitor).1;
        match tile {
            Tile::Start => self.toggle_launcher(shell, qh),
            Tile::Divider => {}
            Tile::Pin { index, windows } => {
                if windows.is_empty() {
                    if let Some(argv) = self.pinned.get(index).and_then(crate::dock::command_for) {
                        crate::launcher::launch(&argv, "");
                    }
                } else {
                    crate::dock::activate(&windows, &self.clients, &self.active_addr, windows_mode, ws);
                }
            }
            Tile::App { windows, .. } => crate::dock::activate(&windows, &self.clients, &self.active_addr, false, ws),
            Tile::Desktop => crate::dock::toggle_desktop(),
        }
    }

    fn dock_menu(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, bar: usize, t: usize, x: f32) {
        use crate::dock::Tile;
        let Some(tile) = self.bars.get(bar).and_then(|b| b.dock_tiles.get(t)).cloned() else { return };
        let row = |key: &str, label: &str, glyph: &str, rule: bool, danger: bool| crate::AppMenuRow {
            key: key.into(),
            label: label.into(),
            glyph: crate::glyphs::glyph(glyph),
            rule,
            danger,
        };
        let (heading, rows) = match &tile {
            Tile::Pin { index, windows } => {
                let p = &self.pinned[*index];
                let mut r = Vec::new();
                if crate::dock::command_for(p).is_some() {
                    r.push(row("open", if windows.is_empty() { "Open" } else { "Open new window" }, "plus", false, false));
                }
                if *index > 0 {
                    r.push(row("left", "Move left", "chevronLeft", !r.is_empty(), false));
                }
                if *index + 1 < self.pinned.len() {
                    r.push(row("right", "Move right", "chevronRight", !r.is_empty() && *index == 0, false));
                }
                r.push(row("unpin", "Unpin from dock", "minus", !r.is_empty(), false));
                if !windows.is_empty() {
                    let n = windows.len();
                    r.push(row("close", if n == 1 { "Close window" } else { "Close all windows" }, "x", true, true));
                }
                (p.label.clone(), r)
            }
            Tile::App { class, windows } => {
                let mut r = vec![row("open", "Open new window", "plus", false, false), row("pin", "Pin to dock", "plus", true, false)];
                if !windows.is_empty() {
                    let n = windows.len();
                    r.push(row("close", if n == 1 { "Close window" } else { "Close all windows" }, "x", true, true));
                }
                (self.dock_labels.get(class).cloned().unwrap_or_else(|| class.clone()), r)
            }
            _ => return,
        };
        let Some(b) = self.bars.get(bar) else { return };
        let g = b.dock_geom;
        b.panels.set_app_menu_heading(heading.into());
        b.panels.set_app_menu(model(rows));
        b.panels.set_dock_gap(g.breadth + g.edge + 10.0);
        self.menu_for = Some((bar, t));
        self.toggle_panel(shell, qh, bar, "appmenu", x);
    }

    fn app_menu(&mut self, key: &str) {
        use crate::dock::Tile;
        self.close_panel();
        let Some((bar, t)) = self.menu_for.take() else { return };
        let Some(tile) = self.bars.get(bar).and_then(|b| b.dock_tiles.get(t)).cloned() else { return };
        let raw = theme::raw();
        match (&tile, key) {
            (Tile::Pin { index, .. }, "open") => {
                if let Some(argv) = self.pinned.get(*index).and_then(crate::dock::command_for) {
                    crate::launcher::launch(&argv, "");
                }
            }
            (Tile::Pin { index, .. }, "left") => crate::dock::move_pin(&raw, &self.pinned[*index].key, -1),
            (Tile::Pin { index, .. }, "right") => crate::dock::move_pin(&raw, &self.pinned[*index].key, 1),
            (Tile::Pin { index, .. }, "unpin") => crate::dock::unpin(&raw, &self.pinned[*index].key),
            (Tile::App { class, .. }, "open") => {
                let argv = crate::launcher::entry_for_class(class).map(|e| e.exec).filter(|e| !e.is_empty()).unwrap_or_else(|| vec![class.clone()]);
                crate::launcher::launch(&argv, "");
            }
            (Tile::App { class, .. }, "pin") => crate::dock::pin_class(&raw, class),
            (Tile::Pin { windows, .. } | Tile::App { windows, .. }, "close") => {
                for w in windows {
                    crate::dock::close(w);
                }
            }
            _ => {}
        }
        // A pin or an unpin changed theme.json: the tiles now.
        self.dock_tiles();
    }

    fn refresh_look(&mut self) {
        let raw = theme::raw();
        for b in &mut self.bars {
            let us = self.look.screen_scale(&b.monitor);
            theme_into!(b.bar, &self.look, us);
            theme_into!(b.panels, &self.look, us);
            theme_into!(b.dock, &self.look, us);
            let (geom, tile, icon, pad_h, pad_v, gap, label) = dock_geom(&raw, us);
            b.dock.set_tile(tile);
            b.dock.set_icon_size(icon);
            b.dock.set_pad_h(pad_h);
            b.dock.set_pad_v(pad_v);
            b.dock.set_gap(gap);
            b.dock.set_label_size(label);
            b.dock_geom = geom;
            b.reveal_to = -1.0;
            b.bar.set_quiet(self.look.dnd);
            b.bar.set_show_tray(self.look.show_tray);
            b.bar.set_tray_open(self.look.tray_open);
            b.panels.set_quiet(self.look.dnd);
            b.panels.set_theme_mode(self.look.mode.clone().into());
        }
        theme_into!(self.toasts, &self.look, 1.0);
        theme_into!(self.switcher.ui, &self.look, 1.0);
        theme_into!(self.osd, &self.look, 1.0);
        theme_into!(self.prompt, &self.look, 1.0);
        let us = self.bars.get(self.focused_bar_cached).map(|b| self.look.screen_scale(&b.monitor)).unwrap_or(1.0);
        theme_into!(self.launcher.ui, &self.look, us);
        self.launcher.configure(&theme::raw(), us, &user_name());
        // Pins and the dock's tile settings may have changed with it.
        self.dock_tiles();
        let raw = theme::raw();
        self.ground_spec = crate::ground::spec(&raw, self.look.dark);
        self.live.follow(&raw);
    }

    fn refresh_second(&mut self) {
        let (time, date) = clock(self.look.clock24);
        let battery = sys::battery();
        let timers = extras::timers();
        let soonest = timers.iter().filter(|t| t.running).min_by_key(|t| t.left);
        let timer_text = soonest.map(|t| extras::clock(t.left)).unwrap_or_else(|| "paused".into());
        let rows: Vec<TimerRow> = timers
            .iter()
            .map(|t| TimerRow { label: t.label.clone().into(), left: extras::clock(t.left).into(), running: t.running, pomodoro: t.pomodoro })
            .collect();
        for b in &self.bars {
            b.bar.set_time(time.clone().into());
            b.bar.set_date(date.clone().into());
            b.bar.set_battery(battery.as_ref().map(|x| x.percent).unwrap_or(-1));
            b.bar.set_charging(battery.as_ref().is_some_and(|x| x.charging));
            b.bar.set_has_timer(!timers.is_empty());
            b.bar.set_timer_text(timer_text.clone().into());
            b.bar.set_timer_running(soonest.is_some());
            b.bar.set_timer_pomodoro(soonest.is_some_and(|t| t.pomodoro));
            b.panels.set_timers(model(rows.clone()));
        }
        // "5 min" on the cards moves on.
        if !self.notes.is_empty() && self.open.as_ref().is_some_and(|o| o.1 == "notifications") {
            self.refresh_note_models();
        }
    }

    fn refresh_session(&mut self) {
        let version = hypr::json("j/version")["tag"].as_str().unwrap_or("").trim_start_matches('v').to_string();
        let monitors = self.bars.len();
        for b in &self.bars {
            b.panels.set_uptime(uptime().into());
            b.panels.set_hyprland(if version.is_empty() { "Hyprland".into() } else { format!("Hyprland {version}").into() });
            b.panels.set_session(format!("Hyprland · {} display{}", monitors, if monitors == 1 { "" } else { "s" }).into());
        }
    }

    fn refresh_sound(&mut self) {
        let s = &self.sound;
        let pct = (s.volume * 100.0).round() as i32;
        let vol_label = if !s.have_audio { String::new() } else if s.muted { "muted".into() } else { format!("{pct}%") };
        let vol_icon = if s.muted || s.volume <= 0.001 { "volume-x" } else if s.volume < 0.5 { "volume-low" } else { "volume" };
        let mut tiles = vec![Tile {
            kind: if s.wifi_on { "wifi".into() } else { "wifi-off".into() },
            name: "Wi-Fi".into(),
            sub: if s.wired && !s.wifi_on { "wired".into() } else { s.net_label.clone().into() },
            on: s.wifi_on,
        }];
        if s.bt_available {
            tiles.push(Tile { kind: "bluetooth".into(), name: "Bluetooth".into(), sub: s.bt_label.clone().into(), on: s.bt_on });
        }
        let airplane = !s.wifi_on && (!s.bt_available || !s.bt_on);
        tiles.push(Tile { kind: "airplane".into(), name: "Airplane".into(), sub: if airplane { "radios off".into() } else { "radios on".into() }, on: airplane });
        tiles.push(Tile {
            kind: "dnd".into(),
            name: "Do not disturb".into(),
            sub: if self.look.dnd { "on".into() } else { "off".into() },
            on: self.look.dnd,
        });
        if !s.rog_profiles.is_empty() {
            tiles.push(Tile {
                kind: "performance".into(),
                name: "Performance".into(),
                sub: daemon::profile_name(s.rog_profile).to_lowercase().into(),
                on: s.rog_profile == 1,
            });
        }
        if s.kbd_level >= 0 {
            let levels = ["off", "low", "medium", "high"];
            tiles.push(Tile {
                kind: "keyboard".into(),
                name: "Keyboard light".into(),
                sub: levels.get(s.kbd_level as usize).copied().unwrap_or("").into(),
                on: s.kbd_level > 0,
            });
        }
        for b in &self.bars {
            b.bar.set_net_label(s.net_label.clone().into());
            b.bar.set_net_icon(s.net_icon.into());
            b.bar.set_volume_label(vol_label.clone().into());
            b.bar.set_volume_icon(vol_icon.into());
            let p = &b.panels;
            p.set_tiles(model(tiles.clone()));
            p.set_volume(s.volume as f32);
            p.set_muted(s.muted);
            p.set_has_brightness(s.brightness.is_some());
            p.set_brightness(s.brightness.unwrap_or(0.0) as f32);
            p.set_has_mic(s.mic.is_some());
            if let Some((_, v, m)) = &s.mic {
                p.set_mic(*v as f32);
                p.set_mic_muted(*m);
            }
        }
    }

    /// The Wi-Fi and Bluetooth lists and the state around them.
    fn refresh_lists(&mut self) {
        let s = &self.sound;
        let nets: Vec<crate::WifiRow> = s
            .aps
            .iter()
            .map(|a| crate::WifiRow {
                ssid: a.ssid.clone().into(),
                bars: ((a.signal + 12) / 25).clamp(1, 4) as i32,
                secure: a.secure,
                saved: a.saved.is_some(),
                active: a.active,
                busy: self.joining == a.ssid,
            })
            .collect();
        let devs: Vec<crate::BtRow> = s
            .bt_devices
            .iter()
            .map(|d| crate::BtRow {
                mac: d.mac.clone().into(),
                name: d.name.clone().into(),
                kind: if d.icon.starts_with("audio") { "audio".into() } else if d.icon.starts_with("input") { "input".into() } else if d.icon.contains("phone") { "phone".into() } else { "other".into() },
                paired: d.paired,
                connected: d.connected,
                battery: d.battery as i32,
                busy: self.bt_busy == d.mac,
            })
            .collect();
        let wifi_sub = if !s.wifi_on {
            "Wi-Fi is off".to_string()
        } else if let Some(a) = s.aps.iter().find(|a| a.active) {
            format!("Connected to {}", a.ssid)
        } else {
            "Not connected".to_string()
        };
        let paired = s.bt_devices.iter().filter(|d| d.paired).count();
        let bt_sub = if !s.bt_on {
            "Bluetooth is off".to_string()
        } else if s.bt_scanning {
            format!("{paired} paired · looking for others")
        } else {
            format!("{paired} paired")
        };
        for b in &self.bars {
            let p = &b.panels;
            p.set_cc_pane(self.cc_pane.clone().into());
            p.set_wifi_on(s.wifi_on);
            p.set_wifi_sub(wifi_sub.clone().into());
            p.set_networks(model(nets.clone()));
            p.set_asking(self.asking.clone().into());
            p.set_wifi_note(self.wifi_note.clone().into());
            p.set_bt_on(s.bt_on);
            p.set_bt_sub(bt_sub.clone().into());
            p.set_devices(model(devs.clone()));
            p.set_pair_name(self.pairing.as_ref().map(|x| x.1.clone()).unwrap_or_default().into());
            p.set_pair_code(self.pairing.as_ref().map(|x| x.2.clone()).unwrap_or_default().into());
        }
    }

    /// Opens or leaves a list: the daemon reads every access point and
    /// scans, or looks for Bluetooth devices, only while one is on screen.
    fn set_cc_pane(&mut self, pane: &str) {
        if self.cc_pane == pane {
            return;
        }
        match self.cc_pane.as_str() {
            "wifi" => self.daemon.send(json!({ "cmd": "net-watch", "on": false })),
            "bluetooth" => self.daemon.send(json!({ "cmd": "bt-scan", "on": false })),
            _ => {}
        }
        self.cc_pane = pane.to_string();
        self.asking.clear();
        self.wifi_note.clear();
        match pane {
            "wifi" => {
                self.daemon.send(json!({ "cmd": "net-watch", "on": true }));
                self.daemon.send(json!({ "cmd": "net-scan" }));
            }
            "bluetooth" => {
                self.daemon.send(json!({ "cmd": "bt-hello" }));
                self.daemon.send(json!({ "cmd": "bt-scan", "on": true }));
            }
            _ => {}
        }
        self.refresh_lists();
    }

    fn net(&mut self, mut cmd: serde_json::Value) {
        self.net_id += 1;
        cmd["id"] = json!(self.net_id);
        self.daemon.send(cmd);
    }

    fn refresh_privacy(&mut self) {
        let s = &self.sound;
        let mut rows: Vec<PrivacyRow> = Vec::new();
        rows.extend(s.mic_apps.iter().map(|a| PrivacyRow { kind: "mic".into(), name: a.clone().into() }));
        rows.extend(s.camera_apps.iter().map(|a| PrivacyRow { kind: "camera".into(), name: a.clone().into() }));
        if self.sharing {
            rows.push(PrivacyRow { kind: "screen".into(), name: "being shared".into() });
        }
        for b in &self.bars {
            b.bar.set_mic_in_use(!s.mic_apps.is_empty());
            b.bar.set_camera_in_use(!s.camera_apps.is_empty());
            b.bar.set_screen_shared(self.sharing);
            b.panels.set_privacy(model(rows.clone()));
        }
    }

    fn refresh_drives(&mut self) {
        let rows: Vec<DriveRow> = self
            .sound
            .drives
            .iter()
            .map(|d| DriveRow {
                drive: d.path.clone().into(),
                name: d.name.clone().into(),
                detail: d.detail.clone().into(),
                part: d.part.clone().into(),
                mount: d.mount.clone().into(),
                mounted: !d.mount.is_empty(),
            })
            .collect();
        for b in &self.bars {
            b.bar.set_has_drives(!rows.is_empty());
            b.panels.set_drives(model(rows.clone()));
        }
    }

    fn refresh_extras(&mut self) {
        let names: Vec<SharedString> = self.updates.iter().take(12).map(|n| n.clone().into()).collect();
        for b in &self.bars {
            b.bar.set_updates(self.updates.len() as i32);
            b.bar.set_show_updates(self.look.updates_in_bar);
            b.bar.set_mail_unread(if self.look.mail_in_bar { self.mail.map(|n| n as i32).unwrap_or(-1) } else { -1 });
            b.panels.set_update_count(self.updates.len() as i32);
            b.panels.set_update_names(model(names.clone()));
        }
    }

    fn refresh_media(&mut self) {
        let m = &self.media;
        if m.art != self.art.0 {
            self.art = (m.art.clone(), None);
            if !m.art.is_empty() {
                let (url, tx) = (m.art.clone(), self.art_tx.clone());
                let mut wake = self.wake.try_clone().expect("wake");
                std::thread::spawn(move || {
                    let px = crate::art::album(&url, 256);
                    let _ = tx.send((url, px));
                    let _ = std::io::Write::write_all(&mut wake, b"!");
                });
            }
        }
        let player = m.bus.trim_start_matches("org.mpris.MediaPlayer2.").split('.').next().unwrap_or("").to_string();
        let player = player.chars().next().map(|c| c.to_uppercase().collect::<String>() + &player[c.len_utf8()..]).unwrap_or_default();
        let info = MediaInfo {
            available: m.available,
            playing: m.playing,
            title: m.title.clone().into(),
            artist: m.artist.clone().into(),
            has_art: self.art.1.is_some(),
            art: self.art.1.clone().unwrap_or_default(),
            progress: if m.length_us > 0 { (m.position_us as f32 / m.length_us as f32).clamp(0.0, 1.0) } else { 0.0 },
            has_length: m.length_us > 0,
            position: mmss(m.position_us).into(),
            length: mmss(m.length_us).into(),
            player: player.into(),
            can_prev: m.can_prev,
            can_next: m.can_next,
            can_toggle: m.can_toggle,
            can_seek: m.can_seek,
        };
        for b in &self.bars {
            b.bar.set_media(info.clone());
            b.panels.set_media(info.clone());
        }
        if m.playing && !self.eq.running() {
            let tick = self.eq_tick.clone();
            let handles: Vec<slint::Weak<Bar>> = self.bars.iter().map(|b| b.bar.as_weak()).collect();
            self.eq.start(slint::TimerMode::Repeated, Duration::from_millis(83), move || {
                let mut t = tick.borrow_mut();
                *t = t.wrapping_add(1);
                for h in &handles {
                    if let Some(b) = h.upgrade() {
                        b.set_eq_tick(*t);
                    }
                }
            });
        } else if !m.playing {
            self.eq.stop();
        }
        if !m.available && self.open.as_ref().is_some_and(|o| o.1 == "media") {
            self.close_panel();
        }
    }

    fn refresh_tray(&mut self) {
        let items: Vec<TrayItem> = self
            .tray_items
            .iter()
            .map(|i| TrayItem {
                key: i.key.clone().into(),
                has_icon: i.icon.is_some(),
                icon: i.icon.clone().map(slint::Image::from_rgba8).unwrap_or_default(),
                letter: i.title.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_else(|| "?".into()).into(),
                tip: i.title.clone().into(),
                passive: i.passive,
            })
            .collect();
        for b in &self.bars {
            b.bar.set_tray(model(items.clone()));
        }
    }

    fn note_row(n: &Stored) -> Note {
        Note {
            id: n.id as i32,
            app: n.app.clone().into(),
            summary: n.summary.clone().into(),
            body: n.body.clone().into(),
            time: ago(n.at).into(),
            has_icon: n.icon.is_some(),
            icon: n.icon.clone().unwrap_or_default(),
            urgent: n.urgent,
            actions: model(
                n.actions
                    .iter()
                    .filter(|(k, l)| k != "default" && !l.is_empty())
                    .map(|(k, l)| NoteAction { key: k.clone().into(), label: l.clone().into() })
                    .collect(),
            ),
        }
    }

    fn refresh_note_models(&mut self) {
        let rows: Vec<Note> = self.notes.iter().map(Self::note_row).collect();
        for b in &self.bars {
            b.bar.set_notifications(rows.len() as i32);
            b.panels.set_notes(model(rows.clone()));
        }
    }

    fn refresh_notes(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) {
        self.refresh_note_models();
        self.refresh_toasts(shell, qh);
    }

    fn refresh_toasts(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) {
        self.toast_list.retain(|(id, _)| self.notes.iter().any(|n| n.id == *id));
        // Newest at the top, three at most, as NotificationToasts.qml.
        let rows: Vec<Note> = self
            .toast_list
            .iter()
            .rev()
            .take(3)
            .filter_map(|(id, _)| self.notes.iter().find(|n| n.id == *id))
            .map(Self::note_row)
            .collect();
        let any = !rows.is_empty();
        self.toasts.set_notes(model(rows));
        if !any {
            self.toast_hover = false;
            if let Some(id) = self.toast_surface.take() {
                shell.remove(id);
            }
            return;
        }
        let width = 376 + 12;
        let height = (self.toasts.get_wanted_height().ceil() as u32).max(1);
        match self.toast_surface {
            Some(id) => shell.resize(id, width, height),
            None => {
                // On the monitor in use.
                let focused = self.focused_bar();
                let output = self.bars.get(focused).map(|b| b.output.clone());
                self.toast_surface = Some(shell.add_window(qh, self.toast_window.clone(), output.as_ref(), &wl::Placement {
                    namespace: "quickshell:panel",
                    layer: Layer::Overlay,
                    anchor: Anchor::TOP | Anchor::RIGHT,
                    width,
                    height,
                    exclusive: 0,
                    keyboard: KeyboardInteractivity::None,
                }));
            }
        }
    }

    fn incoming(&mut self, n: notify::Incoming) {
        let replaced = self.notes.iter().position(|s| s.id == n.id);
        // Kept in the daemon's history, as the Quickshell shell does.
        if !n.transient && replaced.is_none() {
            self.daemon.send(json!({
                "cmd": "nh-add", "app": n.app, "summary": n.summary, "body": n.body,
                "icon": n.icon_name, "urgency": n.urgency
            }));
        }
        let stored = Stored {
            id: n.id,
            app: n.app,
            summary: n.summary,
            body: n.body,
            icon: n.icon.map(slint::Image::from_rgba8),
            urgent: n.urgency >= 2,
            actions: n.actions,
            at: SystemTime::now(),
        };
        let urgent = stored.urgent;
        match replaced {
            Some(i) => self.notes[i] = stored,
            None => self.notes.insert(0, stored),
        }
        // A banner, unless Do not disturb holds it back (urgent ones still
        // show) or the notification center is open to see it in.
        let centre_open = self.open.as_ref().is_some_and(|o| o.1 == "notifications");
        if (!self.look.dnd || urgent) && !centre_open {
            let until = if urgent {
                None
            } else {
                Some(Instant::now() + Duration::from_millis(if n.timeout > 0 { n.timeout.clamp(2000, 30000) as u64 } else { 6000 }))
            };
            self.toast_list.retain(|(id, _)| *id != n.id);
            self.toast_list.push((n.id, until));
        }
        if n.transient {
            // Shown, not kept: gone from the list when the banner goes.
        }
    }

    fn forget(&mut self, id: u32) {
        self.notes.retain(|n| n.id != id);
        self.toast_list.retain(|(i, _)| *i != id);
    }

    fn focused_bar(&self) -> usize {
        let monitors = hypr::json("j/monitors");
        let name = monitors.as_array().and_then(|ms| ms.iter().find(|m| m["focused"] == true)).and_then(|m| m["name"].as_str()).unwrap_or("").to_string();
        self.bars.iter().position(|b| b.monitor == name).unwrap_or(0)
    }

    // ── panels ───────────────────────────────────────────────────────────

    fn open_panel(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, bar: usize, which: &str, x: f32) {
        if let Some((b, _)) = self.open.clone() {
            if b != bar {
                self.close_panel();
            }
        }
        if which == "calendar" && self.open.as_ref().map(|o| o.1.as_str()) != Some("calendar") {
            self.month_offset = 0;
            self.refresh_month();
        }
        if which == "power" {
            self.refresh_session();
        }
        if which == "control" {
            self.daemon.send(json!({ "cmd": "bl-watch", "on": true }));
            self.daemon.send(json!({ "cmd": "bt-hello" }));
        }
        if which == "notifications" {
            // Seen now: the banners for these go.
            self.toast_list.clear();
            self.refresh_toasts(shell, qh);
            self.refresh_note_models();
        }
        let (m, grows) = (self.look.motion, self.look.panels_grow);
        self.last_frame = Instant::now();
        let Some(host) = self.bars.get_mut(bar) else { return };
        host.panels.set_anchor(x);
        host.panels.set_top(host.height + 10.0);
        // Switching from one panel to another starts the new one afresh.
        let fresh = host.panels.get_which().as_str() != which;
        host.panels.set_which(which.into());
        host.bar.set_open_panel(which.into());
        host.closing = false;
        host.anim.up = which == "appmenu";
        host.anim.show(fresh, grows, &m);
        host.anim.apply(&host.panels);
        if let Some(id) = host.panel_surface {
            shell.set_input(id, true);
        }
        if host.panel_surface.is_none() {
            host.panel_surface = Some(shell.add_window(qh, host.panel_window.clone(), Some(&host.output), &wl::Placement {
                namespace: "quickshell:panel",
                layer: Layer::Overlay,
                anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                width: 0,
                height: 0,
                // Over the whole output, the bar included: a click on the
                // bar's empty part closes the panel too.
                exclusive: -1,
                keyboard: KeyboardInteractivity::OnDemand,
            }));
        }
        self.open = Some((bar, which.into()));
    }

    fn close_panel(&mut self) {
        let Some((bar, which)) = self.open.take() else { return };
        if which == "control" {
            self.daemon.send(json!({ "cmd": "bl-watch", "on": false }));
            self.set_cc_pane("");
        }
        if which == "tray" {
            self.menu_at = None;
            self.menu_stack.clear();
        }
        let (m, grows) = (self.look.motion, self.look.panels_grow);
        self.last_frame = Instant::now();
        if let Some(host) = self.bars.get_mut(bar) {
            host.bar.set_open_panel("".into());
            host.closing = true;
            host.anim.hide(grows, &m);
            // Clicks go through to what's under it while it fades.
            if let Some(id) = host.panel_surface {
                shell_input_off(id, &mut self.pending_input);
            }
        }
    }

    fn toggle_panel(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, bar: usize, which: &str, x: f32) {
        if self.open.as_ref().is_some_and(|(b, w)| *b == bar && w == which) {
            self.close_panel();
        } else {
            self.open_panel(shell, qh, bar, which, x);
        }
    }

    /// From a key, with no button to hang under: the focused monitor's,
    /// at the right-hand edge.
    fn toggle_from_key(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, which: &str) {
        let bar = self.focused_bar();
        self.toggle_panel(shell, qh, bar, which, 100000.0);
    }

    fn refresh_month(&mut self) {
        let (title, cells) = month(self.month_offset);
        for b in &self.bars {
            b.panels.set_month(title.clone().into());
            b.panels.set_cells(model(cells.clone()));
            b.panels.set_month_away(self.month_offset != 0);
        }
    }

    // ── doing ────────────────────────────────────────────────────────────

    pub fn run_actions(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) {
        if !self.prompt_acts.borrow().is_empty() {
            self.step_polkit(shell, qh);
        }
        let sw: Vec<crate::switch_ui::Act> = std::mem::take(&mut *self.switch_acts.borrow_mut());
        let any = !sw.is_empty();
        for a in sw {
            self.switcher.act(a);
        }
        if any {
            self.step_switcher(shell, qh);
        }
        let acts: Vec<crate::launch_ui::Act> = std::mem::take(&mut *self.launch_acts.borrow_mut());
        for a in acts {
            let wants = self.launcher.act(a, &mut self.daemon);
            self.launcher_wants(shell, qh, wants);
        }
        loop {
            let batch: Vec<Action> = std::mem::take(&mut *self.actions.borrow_mut());
            if batch.is_empty() {
                return;
            }
            for a in batch {
                self.act(shell, qh, a);
            }
        }
    }

    fn set_volume(&mut self, v: f64) {
        if !self.sound.have_audio {
            return;
        }
        self.sound.volume = v.clamp(0.0, 1.0);
        self.daemon.send(json!({ "cmd": "pa-volume", "name": self.sound.sink, "volume": self.sound.volume }));
        if self.sound.muted {
            self.daemon.send(json!({ "cmd": "pa-mute", "name": self.sound.sink, "mute": false }));
            self.sound.muted = false;
        }
        self.refresh_sound();
    }

    fn set_brightness(&mut self, v: f64) {
        if self.sound.bl_max == 0 {
            return;
        }
        let v = v.clamp(0.01, 1.0);
        self.sound.brightness = Some(v);
        self.daemon.send(json!({ "cmd": "bl-set", "value": ((v * self.sound.bl_max as f64).round() as u64).max(1) }));
        self.refresh_sound();
    }

    fn act(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, a: Action) {
        match a {
            Action::TogglePanel(bar, which, x) => {
                if which == "window" && !self.bars.get(bar).is_some_and(|b| b.bar.get_has_client()) {
                    return;
                }
                self.toggle_panel(shell, qh, bar, &which, x);
            }
            Action::ClosePanel => self.close_panel(),
            Action::Workspace(id) => hypr::dispatch(&format!("hl.dsp.focus({{ workspace = {id} }})"), &format!("workspace {id}")),
            Action::WorkspaceStep(d) => {
                let w = if d < 0 { "m-1" } else { "m+1" };
                hypr::dispatch(&format!("hl.dsp.focus({{ workspace = \"{w}\" }})"), &format!("workspace {w}"));
            }
            Action::VolumeStep(d) => {
                self.set_volume(self.sound.volume + 0.05 * d as f64);
                self.show_osd(shell, qh, "volume");
            }
            Action::SetVolume(v) => self.set_volume(v as f64),
            Action::ToggleMute => {
                if self.sound.have_audio {
                    self.sound.muted = !self.sound.muted;
                    self.daemon.send(json!({ "cmd": "pa-mute", "name": self.sound.sink, "mute": self.sound.muted }));
                    self.refresh_sound();
                }
            }
            Action::SetBrightness(v) => self.set_brightness(v as f64),
            Action::SetMic(v) => {
                if let Some((name, vol, muted)) = self.sound.mic.as_mut() {
                    *vol = (v as f64).clamp(0.0, 1.0);
                    self.daemon.send(json!({ "cmd": "pa-source-volume", "name": name, "volume": *vol }));
                    if *muted {
                        *muted = false;
                        self.daemon.send(json!({ "cmd": "pa-source-mute", "name": name, "mute": false }));
                    }
                    self.refresh_sound();
                }
            }
            Action::ToggleMic => {
                if let Some((name, _, muted)) = self.sound.mic.as_mut() {
                    *muted = !*muted;
                    self.daemon.send(json!({ "cmd": "pa-source-mute", "name": name, "mute": *muted }));
                    self.refresh_sound();
                }
            }
            Action::Media(c) => {
                let _ = self.media_cmd.send(c);
            }
            Action::Power(what) => {
                self.close_panel();
                self.power(&what);
            }
            Action::WindowAct(what) => {
                self.close_panel();
                let (lua, old) = match what.as_str() {
                    "fullscreen" => ("hl.dsp.window.fullscreen({ mode = \"fullscreen\", action = \"toggle\" })", "fullscreen 0"),
                    "maximize" => ("hl.dsp.window.fullscreen({ mode = \"maximized\", action = \"toggle\" })", "fullscreen 1"),
                    "float" => ("hl.dsp.window.float({ action = \"toggle\" })", "togglefloating"),
                    "pin" => ("hl.dsp.window.pin()", "pin"),
                    "center" => ("hl.dsp.window.center()", "centerwindow"),
                    "togglesplit" => ("hl.dsp.layout(\"togglesplit\")", "togglesplit"),
                    "next" => ("hl.dsp.window.move({ workspace = \"+1\" })", "movetoworkspace +1"),
                    "prev" => ("hl.dsp.window.move({ workspace = \"-1\" })", "movetoworkspace -1"),
                    "close" => ("hl.dsp.window.close()", "killactive"),
                    _ => return,
                };
                hypr::dispatch(lua, old);
            }
            Action::WindowSnap(i) => {
                self.close_panel();
                snap(i);
            }
            Action::MonthStep(d) => {
                self.month_offset += d;
                self.refresh_month();
            }
            Action::MonthReset => {
                self.month_offset = 0;
                self.refresh_month();
            }
            Action::CycleTheme => {
                let next = match self.look.mode.as_str() {
                    "light" => "dark",
                    "dark" => "auto",
                    _ => "light",
                };
                theme::set("theme", json!(next));
                self.reload_look();
            }
            Action::Tile(kind) => self.tile(&kind),
            Action::NoteDismiss(id) => {
                let id = id as u32;
                self.forget(id);
                if let Some(c) = &self.notify_conn {
                    notify::signal_closed(c, id, 2);
                }
                self.refresh_notes(shell, qh);
            }
            Action::NoteAct(id, key) => {
                let id = id as u32;
                let has = self.notes.iter().find(|n| n.id == id).is_some_and(|n| n.actions.iter().any(|(k, _)| *k == key));
                if let Some(c) = &self.notify_conn {
                    if has {
                        notify::signal_action(c, id, &key);
                    }
                    notify::signal_closed(c, id, 2);
                }
                self.forget(id);
                self.refresh_notes(shell, qh);
                if has {
                    self.close_panel();
                }
            }
            Action::NotesClear => {
                let ids: Vec<u32> = self.notes.iter().map(|n| n.id).collect();
                self.notes.clear();
                if let Some(c) = &self.notify_conn {
                    for id in ids {
                        notify::signal_closed(c, id, 2);
                    }
                }
                self.refresh_notes(shell, qh);
            }
            Action::ToggleDnd => {
                theme::set("dnd", json!(!self.look.dnd));
                self.reload_look();
            }
            Action::DriveOpen(m) => {
                self.close_panel();
                extras::spawn(&["xdg-open", &m]);
            }
            Action::DriveMount(p) => self.daemon.send(json!({ "cmd": "usb-mount", "path": p })),
            Action::DriveEject(d) => self.daemon.send(json!({ "cmd": "usb-eject", "drive": d })),
            Action::RunUpdates => {
                self.close_panel();
                let step = if self.update_helper.is_empty() { "sudo pacman -Syu".to_string() } else { format!("{} -Syu", self.update_helper) };
                let run = format!("echo; echo \"$ {step}\"; {step}; echo; printf 'Done. Press Enter to close. '; read _");
                let term = extras::terminal();
                extras::spawn(&[&term, "-e", "sh", "-c", &run]);
                // Looked at again once the terminal is done with.
                self.updates.clear();
                self.refresh_extras();
            }
            Action::OpenMail => {
                let w = hypr::json("j/clients");
                let addr = w
                    .as_array()
                    .into_iter()
                    .flatten()
                    .find(|c| c["class"].as_str().is_some_and(|x| x.eq_ignore_ascii_case("hyprshell-mail")))
                    .and_then(|c| c["address"].as_str().map(str::to_string));
                match addr {
                    Some(a) => {
                        let sel = hypr::lua_str(&format!("address:{a}"));
                        hypr::dispatch(&format!("hl.dsp.focus({{ window = {sel} }})"), &format!("focuswindow address:{a}"));
                    }
                    None => extras::spawn(&["hyprshell-mail"]),
                }
            }
            Action::TrayToggle => {
                theme::set("trayOpen", json!(!self.look.tray_open));
                self.reload_look();
            }
            Action::TrayActivate(bar, key, x) => {
                self.menu_at = Some((bar, x));
                let _ = self.tray_cmd.send(tray::Cmd::Activate(key, x as i32, self.bars.get(bar).map(|b| b.height as i32).unwrap_or(0)));
            }
            Action::TraySecondary(key) => {
                let _ = self.tray_cmd.send(tray::Cmd::Secondary(key, 0, 0));
            }
            Action::TrayMenu(bar, key, x) => {
                if self.open.as_ref().is_some_and(|o| o.1 == "tray") && self.menu_key == key {
                    self.close_panel();
                    return;
                }
                self.menu_at = Some((bar, x));
                let _ = self.tray_cmd.send(tray::Cmd::Menu(key, 0, String::new()));
            }
            Action::TrayScroll(key, d) => {
                let _ = self.tray_cmd.send(tray::Cmd::Scroll(key, d));
            }
            Action::MenuPick(id, sub) => {
                if sub {
                    let label = self.menu_entries.iter().find(|e| e.id == id).map(|e| e.label.clone()).unwrap_or_default();
                    self.menu_stack.push((id, label.clone()));
                    let _ = self.tray_cmd.send(tray::Cmd::Menu(self.menu_key.clone(), id, label));
                } else {
                    let _ = self.tray_cmd.send(tray::Cmd::Click(self.menu_key.clone(), id));
                    self.close_panel();
                }
            }
            Action::MenuBack => {
                self.menu_stack.pop();
                let (id, label) = self.menu_stack.last().cloned().unwrap_or((0, String::new()));
                let _ = self.tray_cmd.send(tray::Cmd::Menu(self.menu_key.clone(), id, label));
            }
            Action::DockActivate(bar, t) => self.dock_activate(shell, qh, bar, t),
            Action::DockMenu(bar, t, x) => self.dock_menu(shell, qh, bar, t, x),
            Action::DockMiddle(bar, t) => {
                if let Some(crate::dock::Tile::Pin { windows, .. } | crate::dock::Tile::App { windows, .. }) =
                    self.bars.get(bar).and_then(|b| b.dock_tiles.get(t)).cloned()
                {
                    if let Some(w) = windows.first() {
                        crate::dock::close(w);
                    }
                }
            }
            Action::DockHover(bar, h) => {
                if let Some(b) = self.bars.get_mut(bar) {
                    if h {
                        b.latch = true;
                        b.hide_at = None;
                    } else {
                        b.hide_at = Some(Instant::now() + Duration::from_millis(420));
                    }
                }
            }
            Action::AppMenu(k) => self.app_menu(&k),
            Action::CcPane(p) => self.set_cc_pane(&p),
            Action::Wifi(on) => self.daemon.send(json!({ "cmd": "net-wifi", "on": on })),
            Action::Bt(on) => self.daemon.send(json!({ "cmd": "bt-power", "on": on })),
            Action::Join(ssid) => {
                let Some(a) = self.sound.aps.iter().find(|a| a.ssid == ssid).cloned() else { return };
                self.wifi_note.clear();
                if let Some(uuid) = a.saved {
                    self.joining = ssid;
                    self.net(json!({ "cmd": "net-up", "uuid": uuid }));
                } else if !a.secure {
                    self.joining = ssid.clone();
                    self.net(json!({ "cmd": "net-join", "ssid": ssid }));
                } else {
                    // Its password, in a field under it.
                    self.asking = if self.asking == ssid { String::new() } else { ssid };
                }
                self.refresh_lists();
            }
            Action::JoinSecret(ssid, secret) => {
                if secret.is_empty() {
                    return;
                }
                self.asking.clear();
                self.joining = ssid.clone();
                // The password goes to the daemon's input, and from there
                // straight to NetworkManager: never on a command line.
                self.net(json!({ "cmd": "net-join", "ssid": ssid, "secret": secret }));
                for b in &self.bars {
                    b.panels.set_secret("".into());
                }
                self.refresh_lists();
            }
            Action::Disconnect => self.net(json!({ "cmd": "net-disconnect" })),
            Action::Forget(ssid) => {
                if let Some(uuid) = self.sound.aps.iter().find(|a| a.ssid == ssid).and_then(|a| a.saved.clone()) {
                    self.net(json!({ "cmd": "net-forget", "uuid": uuid }));
                }
            }
            Action::Device(mac) => {
                let Some(d) = self.sound.bt_devices.iter().find(|d| d.mac == mac).cloned() else { return };
                let op = if d.connected { "bt-disconnect" } else if d.paired { "bt-connect" } else { "bt-pair" };
                self.bt_busy = mac.clone();
                self.daemon.send(json!({ "cmd": op, "mac": mac }));
                self.refresh_lists();
            }
            Action::PairAnswer(yes) => {
                if let Some((id, _, _)) = self.pairing.take() {
                    self.daemon.send(json!({ "cmd": "bt-reply", "id": id, "accept": yes }));
                }
                self.refresh_lists();
            }
            Action::ToastHover(h) => {
                self.toast_hover = h;
                if !h {
                    // A moment more to read what the pointer was on.
                    let soon = Instant::now() + Duration::from_secs(2);
                    for (_, until) in &mut self.toast_list {
                        if let Some(t) = until {
                            *t = (*t).max(soon);
                        }
                    }
                }
            }
        }
    }

    fn reload_look(&mut self) {
        self.look = theme::load();
        self.look_stamp = theme::modified();
        self.refresh_look();
        self.refresh_extras();
        self.refresh_sound();
    }

    fn tile(&mut self, kind: &str) {
        let s = &self.sound;
        match kind {
            "wifi" | "wifi-off" => self.daemon.send(json!({ "cmd": "net-wifi", "on": !s.wifi_on })),
            "bluetooth" => self.daemon.send(json!({ "cmd": "bt-power", "on": !s.bt_on })),
            "airplane" => {
                let going_on = s.wifi_on || s.bt_on;
                self.daemon.send(json!({ "cmd": "net-wifi", "on": !going_on }));
                if s.bt_available {
                    self.daemon.send(json!({ "cmd": "bt-power", "on": !going_on }));
                }
            }
            "dnd" => {
                theme::set("dnd", json!(!self.look.dnd));
                self.reload_look();
            }
            "performance" => {
                let list = &s.rog_profiles;
                let at = list.iter().position(|p| *p == s.rog_profile);
                let next = at.map(|i| list[(i + 1) % list.len()]).or(list.first().copied());
                if let Some(p) = next {
                    self.daemon.send(json!({ "cmd": "rog-profile", "profile": p }));
                }
            }
            "keyboard" => self.daemon.send(json!({ "cmd": "rog-kbd-brightness", "level": (s.kbd_level + 1) % 4 })),
            _ => {}
        }
    }

    fn power(&mut self, what: &str) {
        let lock = if which("hyprlock") { "pidof hyprlock >/dev/null || hyprlock" } else { "loginctl lock-session" };
        match what {
            "lock" => extras::sh(lock),
            "suspend" => {
                if which("hyprlock") {
                    extras::sh("pidof hyprlock >/dev/null || hyprlock &");
                } else {
                    extras::sh("loginctl lock-session 2>/dev/null || true");
                }
                extras::sh("sleep 0.5; loginctl suspend 2>/dev/null || systemctl suspend");
            }
            "logout" => hypr::dispatch("hl.dsp.exit()", "exit"),
            "reboot" => extras::sh("loginctl reboot 2>/dev/null || systemctl reboot"),
            "poweroff" => extras::sh("loginctl poweroff 2>/dev/null || systemctl poweroff"),
            _ => {}
        }
    }

    fn toggle_launcher(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) {
        let m = self.look.motion;
        if self.launcher.is_open() {
            self.launcher.close(&m);
            if let Some(id) = self.launcher.surface {
                shell.set_input(id, false);
                shell.set_keyboard(id, KeyboardInteractivity::None);
            }
            self.dock_tiles();
            return;
        }
        self.close_panel();
        let bar = self.focused_bar();
        self.focused_bar_cached = bar;
        let us = self.bars.get(bar).map(|b| self.look.screen_scale(&b.monitor)).unwrap_or(1.0);
        theme_into!(self.launcher.ui, &self.look, us);
        let raw = theme::raw();
        self.launcher.configure(&raw, us, &user_name());
        self.last_frame = Instant::now();
        self.launcher.open(&raw, &m, self.look.panels_grow);
        self.launcher.ui.invoke_focus_field();
        self.dock_tiles();
        self.daemon.send(json!({ "cmd": "fs-warm" }));
        if self.launcher.wants_icons {
            self.launcher.wants_icons = false;
            let list = self.launcher.entries_for_icons();
            let tx = self.icon_tx.clone();
            let mut wake = self.wake.try_clone().expect("wake");
            std::thread::spawn(move || {
                let icons = crate::launcher::entry_icons(&list, 48);
                let _ = tx.send(icons);
                let _ = std::io::Write::write_all(&mut wake, b"!");
            });
        }
        match self.launcher.surface {
            Some(id) => {
                shell.set_input(id, true);
                shell.set_keyboard(id, KeyboardInteractivity::Exclusive);
            }
            None => {
                let output = self.bars.get(bar).map(|b| b.output.clone());
                self.launcher.surface = Some(shell.add_window(qh, self.launcher.window.clone(), output.as_ref(), &wl::Placement {
                    namespace: "quickshell:launcher",
                    layer: Layer::Overlay,
                    anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                    width: 0,
                    height: 0,
                    exclusive: -1,
                    // All typing comes here while it's open.
                    keyboard: KeyboardInteractivity::Exclusive,
                }));
            }
        }
    }

    fn launcher_wants(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, w: crate::launch_ui::Wants) {
        use crate::launch_ui::Wants;
        let close = |app: &mut App, shell: &mut wl::Shell| {
            let m = app.look.motion;
            app.launcher.close(&m);
            if let Some(id) = app.launcher.surface {
                shell.set_input(id, false);
                // The keyboard back to the windows.
                shell.set_keyboard(id, KeyboardInteractivity::None);
            }
        };
        match w {
            Wants::Nothing => {}
            Wants::Close => {
                close(self, shell);
                self.dock_tiles();
            }
            Wants::Power(k) => {
                close(self, shell);
                self.power(&k);
            }
            Wants::Command(k) => {
                close(self, shell);
                match k {
                    "theme" => self.command(shell, qh, "toggleTheme"),
                    "updates" => self.toggle_from_key(shell, qh, "updates"),
                    "timers" => self.toggle_from_key(shell, qh, "timers"),
                    "tasks" => extras::sh(
                        "command -v hyprshell-tasks >/dev/null 2>&1 && exec hyprshell-tasks; \
                         for d in \"$HOME/.local/bin\" /usr/local/bin /usr/bin; do [ -x \"$d/hyprshell-tasks\" ] && exec \"$d/hyprshell-tasks\"; done",
                    ),
                    other => self.power(other),
                }
            }
        }
    }

    /// The polkit prompt: requests in, the user's answers out to polkit's
    /// helper, and what the helper said back.
    fn step_polkit(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) {
        use crate::polkit::{Event, Said};
        while let Ok(ev) = self.polkit_rx.try_recv() {
            match ev {
                Event::Begin(r) => self.auth_queue.push(r),
                Event::Cancelled(cookie) => {
                    self.auth_queue.retain(|r| r.cookie != cookie);
                    if self.auth.as_ref().is_some_and(|r| r.cookie == cookie) {
                        self.end_auth(shell, false);
                    }
                }
            }
        }
        let acts: Vec<i32> = std::mem::take(&mut *self.prompt_acts.borrow_mut());
        for a in acts {
            match a {
                -1 => {
                    let Some(r) = &self.auth else { continue };
                    let pw = self.prompt.get_password().to_string();
                    if pw.is_empty() || self.prompt.get_busy() {
                        continue;
                    }
                    self.prompt.set_password("".into());
                    self.prompt.set_busy(true);
                    self.prompt.set_failed(false);
                    self.prompt.set_note("".into());
                    let user = r.users.get(self.auth_user).map(|u| u.0.clone()).unwrap_or_default();
                    crate::polkit::attempt(user, r.cookie.clone(), pw, self.said_tx.clone(), self.wake.try_clone().expect("wake"));
                }
                -2 => self.end_auth(shell, false),
                i => {
                    self.auth_user = i.max(0) as usize;
                    self.prompt.set_user(i);
                }
            }
        }
        while let Ok(said) = self.said_rx.try_recv() {
            match said {
                Said::Success => self.end_auth(shell, true),
                Said::Failure(m) => {
                    self.prompt.set_busy(false);
                    self.prompt.set_failed(true);
                    self.prompt.set_note(m.into());
                    self.prompt.invoke_take_keys();
                }
                Said::Info(m) | Said::Ask(m) => self.prompt.set_note(m.into()),
            }
        }
        // The next request, when none is showing.
        if self.auth.is_none() && !self.auth_queue.is_empty() {
            let r = self.auth_queue.remove(0);
            let me = user_name();
            self.auth_user = r.users.iter().position(|u| u.0 == me).unwrap_or(0);
            let names: Vec<SharedString> = r.users.iter().map(|u| u.0.clone().into()).collect();
            self.prompt.set_users(model(names));
            self.prompt.set_user(self.auth_user as i32);
            self.prompt.set_message(r.message.clone().into());
            self.prompt.set_action(r.action.clone().into());
            self.prompt.set_password("".into());
            self.prompt.set_busy(false);
            self.prompt.set_failed(false);
            self.prompt.set_note("".into());
            self.auth = Some(r);
            if self.prompt_surface.is_none() {
                let bar = self.focused_bar();
                let output = self.bars.get(bar).map(|b| b.output.clone());
                self.prompt_surface = Some(shell.add_window(qh, self.prompt_window.clone(), output.as_ref(), &wl::Placement {
                    namespace: "quickshell:polkit",
                    layer: Layer::Overlay,
                    anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                    width: 0,
                    height: 0,
                    exclusive: -1,
                    keyboard: KeyboardInteractivity::Exclusive,
                }));
            }
            self.prompt.invoke_take_keys();
        }
    }

    /// Tells polkit how the request on the prompt ended, and takes it down.
    fn end_auth(&mut self, shell: &mut wl::Shell, ok: bool) {
        if let Some(r) = self.auth.take() {
            if let Ok(mut o) = self.outcomes.lock() {
                o.insert(r.cookie, ok);
            }
        }
        self.prompt.set_password("".into());
        self.prompt.set_busy(false);
        if self.auth_queue.is_empty() {
            if let Some(id) = self.prompt_surface.take() {
                shell.remove(id);
            }
        }
    }

    /// Each screen's wallpaper: drawn on a helper thread when the screen's
    /// size or the wallpaper changes, then put on its surface.
    fn step_ground(&mut self, shell: &mut wl::Shell) {
        while let Ok((bar, spec, w, h, px)) = self.ground_rx.try_recv() {
            if let Some(b) = self.bars.get_mut(bar) {
                b.ground_busy = false;
                shell.set_picture(b.ground, w, h, |out| out.copy_from_slice(&px[..out.len()]));
                b.ground_done = Some((spec, w, h));
            }
        }
        for (i, b) in self.bars.iter_mut().enumerate() {
            let Some((w, h)) = shell.pictures.get(b.ground).and_then(|p| p.pixel_size()) else { continue };
            let want = (self.ground_spec.clone(), w, h);
            if b.ground_busy || b.ground_done.as_ref() == Some(&want) {
                continue;
            }
            b.ground_busy = true;
            let (tx, spec) = (self.ground_tx.clone(), self.ground_spec.clone());
            let dark = self.look.dark;
            let raw = theme::raw();
            let mut wake = self.wake.try_clone().expect("wake");
            std::thread::spawn(move || {
                // A picture that won't open falls back to the gradient.
                let px = crate::ground::draw(&spec, w, h).unwrap_or_else(|| {
                    let mut r = raw.clone();
                    r["wallpaper"] = serde_json::Value::String(String::new());
                    crate::ground::draw(&crate::ground::spec(&r, dark), w, h).unwrap_or_default()
                });
                if px.len() >= (w * h * 4) as usize {
                    let _ = tx.send((i, spec, w, h, px));
                    let _ = std::io::Write::write_all(&mut wake, b"!");
                }
            });
        }
    }

    /// Alt+Tab's surface: there while it is shown, holding the keyboard.
    fn step_switcher(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) {
        let (show, commit) = self.switcher.tick();
        if commit {
            self.switcher.commit();
        }
        let want = show && self.switcher.open;
        match (want, self.switcher.surface) {
            (true, None) => {
                let output = self.bars.iter().find(|b| b.monitor == self.switcher.monitor).or(self.bars.first()).map(|b| b.output.clone());
                self.switcher.surface = Some(shell.add_window(qh, self.switcher.window.clone(), output.as_ref(), &wl::Placement {
                    namespace: "quickshell:switcher",
                    layer: Layer::Overlay,
                    anchor: Anchor::TOP | Anchor::BOTTOM | Anchor::LEFT | Anchor::RIGHT,
                    width: 0,
                    height: 0,
                    exclusive: -1,
                    keyboard: KeyboardInteractivity::Exclusive,
                }));
                self.switcher.ui.invoke_take_keys();
            }
            (false, Some(id)) => {
                shell.remove(id);
                self.switcher.surface = None;
            }
            _ => {}
        }
    }

    /// The volume / brightness popup, shown for 1.6 s after a change.
    fn show_osd(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, kind: &str) {
        let s = &self.sound;
        let (value, muted, glyph) = match kind {
            "brightness" => match s.brightness {
                Some(b) => (b, false, "sun"),
                None => return,
            },
            "mic" => match &s.mic {
                Some((_, v, m)) => (*v, *m, if *m { "micOff" } else { "mic" }),
                None => return,
            },
            _ => {
                if !s.have_audio {
                    return;
                }
                let g = if s.muted || s.volume <= 0.001 { "volumeX" } else if s.volume < 0.5 { "volumeLow" } else { "volume" };
                (s.volume, s.muted, g)
            }
        };
        self.osd.set_glyph(crate::glyphs::glyph(glyph));
        self.osd.set_value(value as f32);
        self.osd.set_muted(muted);
        let bar = self.focused_bar();
        let g = self.bars.get(bar).map(|b| b.dock_geom).unwrap_or_default();
        let inset = g.breadth + g.edge + 40.0;
        self.osd.set_inset(inset);
        let m = self.look.motion;
        if self.osd_surface.is_none() {
            let output = self.bars.get(bar).map(|b| b.output.clone());
            let id = shell.add_window(qh, self.osd_window.clone(), output.as_ref(), &wl::Placement {
                namespace: "quickshell:panel",
                layer: Layer::Overlay,
                anchor: Anchor::BOTTOM,
                width: 420,
                height: (54.0 + inset) as u32,
                exclusive: -1,
                keyboard: KeyboardInteractivity::None,
            });
            shell.set_input_rect(id, None);
            self.osd_surface = Some(id);
            self.osd_springs[0].snap(24.0);
            self.osd_springs[1].snap(0.0);
            self.osd_springs[2].snap(0.86);
        }
        self.osd_springs[0].go(0.0, 340.0, 1.0, &m);
        self.osd_springs[1].go(1.0, 160.0, 0.0, &m);
        self.osd_springs[2].go(1.0, 340.0, 1.0, &m);
        self.last_frame = Instant::now();
        self.osd_until = Some(Instant::now() + Duration::from_millis(1600));
    }

    /// Each screen's number on the screen itself for a moment
    /// (MonitorMap.qml's Identify).
    fn identify(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, order: &str) {
        for (_, id) in self.ident.drain(..) {
            shell.remove(id);
        }
        let names: Vec<&str> = order.split(',').map(str::trim).filter(|n| !n.is_empty()).collect();
        let outs: Vec<(String, WlOutput)> = self.bars.iter().map(|b| (b.monitor.clone(), b.output.clone())).collect();
        for (monitor, output) in outs {
            let Ok(w) = crate::Identify::new() else { continue };
            let Some(adapter) = crate::platform::take_adapter() else { continue };
            theme_into!(w, &self.look, 1.0);
            let n = names.iter().position(|x| *x == monitor).map(|i| (i + 1).to_string()).unwrap_or_else(|| "?".into());
            w.set_number(n.into());
            w.set_name(monitor.clone().into());
            let id = shell.add_window(qh, adapter, Some(&output), &wl::Placement {
                namespace: "quickshell:panel",
                layer: Layer::Overlay,
                anchor: Anchor::TOP | Anchor::LEFT,
                width: 220,
                height: 220,
                exclusive: -1,
                keyboard: KeyboardInteractivity::None,
            });
            shell.set_input_rect(id, None);
            self.ident.push((w, id));
        }
        self.ident_until = Some(Instant::now() + Duration::from_millis(2500));
        self.last_frame = Instant::now();
    }

    fn step_osd(&mut self, shell: &mut wl::Shell, dt: f64) {
        let m = self.look.motion;
        if self.osd_until.is_some_and(|t| Instant::now() >= t) {
            self.osd_until = None;
            self.osd_springs[0].go(24.0, 340.0, 1.0, &m);
            self.osd_springs[1].go(0.0, 160.0, 0.0, &m);
            self.osd_springs[2].go(0.86, 340.0, 1.0, &m);
        }
        for s in &mut self.osd_springs {
            s.step(dt, &m);
        }
        self.osd.set_rise(self.osd_springs[0].value as f32);
        self.osd.set_fade(self.osd_springs[1].value as f32);
        self.osd.set_grow(self.osd_springs[2].value as f32);
        if self.osd_until.is_none() && self.osd_springs[1].value <= 0.004 && !self.osd_springs[1].moving {
            if let Some(id) = self.osd_surface.take() {
                shell.remove(id);
            }
        }
    }

    /// A line from hyprshell.cmd: what the keybinds send the shell.
    fn command(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, line: &str) {
        let line = line.trim();
        let (name, arg) = line.split_once(' ').map(|(a, b)| (a, b.trim())).unwrap_or((line, ""));
        match name {
            "toggleLauncher" => self.toggle_launcher(shell, qh),
            "altTab" => {
                match if arg.is_empty() { "next" } else { arg } {
                    "next" | "prev" => {
                        let bar = self.focused_bar();
                        let monitor = self.bars.get(bar).map(|b| b.monitor.clone()).unwrap_or_default();
                        let us = self.look.screen_scale(&monitor);
                        self.switcher.step(if arg == "prev" { -1 } else { 1 }, &theme::raw(), &monitor, us);
                    }
                    "commit" => self.switcher.commit(),
                    "cancel" => self.switcher.close(),
                    "release" => self.switcher.act(crate::switch_ui::Act::Released(SharedString::from(slint::platform::Key::Alt).to_string())),
                    _ => {}
                }
                self.step_switcher(shell, qh);
            }
            "toggleControlCenter" => self.toggle_from_key(shell, qh, "control"),
            "toggleNotifications" => self.toggle_from_key(shell, qh, "notifications"),
            "toggleCalendar" => self.toggle_from_key(shell, qh, "calendar"),
            "togglePower" => self.toggle_from_key(shell, qh, "power"),
            "toggleTimers" => self.toggle_from_key(shell, qh, "timers"),
            "toggleUpdates" => self.toggle_from_key(shell, qh, "updates"),
            "closePanels" => self.close_panel(),
            // The control center open on its Wi-Fi or Bluetooth list
            // (Settings → Network / Bluetooth).
            "showWifi" | "showBluetooth" => {
                if self.open.as_ref().map(|o| o.1.as_str()) != Some("control") {
                    self.toggle_from_key(shell, qh, "control");
                }
                self.set_cc_pane(if name == "showWifi" { "wifi" } else { "bluetooth" });
            }
            // Settings → Display → Identify: "identify DP-1,eDP-1", the
            // screens in the order its map numbers them.
            "identify" => self.identify(shell, qh, arg),
            // Settings → Sound: listening to a microphone, a chain tried again.
            "fxListen" | "fxRetry" => self.fx.command(name, arg),
            // The Settings app, on a page if one is named.
            "openSettings" => {
                let mut argv = vec!["hyprshell-settings"];
                if !arg.is_empty() {
                    argv.push(arg);
                }
                extras::spawn(&argv);
            }
            "toggleDnd" => self.act(shell, qh, Action::ToggleDnd),
            "volumeUp" => {
                self.set_volume(self.sound.volume + 0.05);
                self.show_osd(shell, qh, "volume");
            }
            "volumeDown" => {
                self.set_volume(self.sound.volume - 0.05);
                self.show_osd(shell, qh, "volume");
            }
            "volumeMute" => {
                self.act(shell, qh, Action::ToggleMute);
                self.show_osd(shell, qh, "volume");
            }
            "micMute" => {
                self.act(shell, qh, Action::ToggleMic);
                self.show_osd(shell, qh, "mic");
            }
            "brightnessUp" => {
                self.set_brightness(self.sound.brightness.unwrap_or(0.5) + 0.05);
                self.show_osd(shell, qh, "brightness");
            }
            "brightnessDown" => {
                self.set_brightness(self.sound.brightness.unwrap_or(0.5) - 0.05);
                self.show_osd(shell, qh, "brightness");
            }
            "toggleTheme" => {
                theme::set("theme", json!(if self.look.dark { "light" } else { "dark" }));
                self.reload_look();
            }
            "cycleTheme" => self.act(shell, qh, Action::CycleTheme),
            "setTheme" if ["light", "dark", "auto"].contains(&arg) => {
                theme::set("theme", json!(arg));
                self.reload_look();
            }
            "lock" => self.power("lock"),
            "openMail" => self.act(shell, qh, Action::OpenMail),
            "checkUpdates" => {
                let _ = self.updates_now.send(());
            }
            "openTerminal" => {
                let term = extras::terminal();
                extras::spawn(&[&term]);
            }
            _ => eprintln!("hyprshell-rs: \"{line}\" isn't in the Rust shell yet"),
        }
    }
}

/// Snaps the focused window to one of the six layouts, inside the
/// monitor's free area, as WindowMenuPanel.qml does.
fn snap(i: i32) {
    const SNAPS: [(f64, f64, f64, f64); 6] =
        [(0.0, 0.0, 0.5, 1.0), (0.5, 0.0, 0.5, 1.0), (0.0, 0.0, 1.0, 0.5), (0.0, 0.5, 1.0, 0.5), (0.0, 0.0, 1.0, 1.0), (0.15, 0.12, 0.7, 0.76)];
    let Some(&(fx, fy, fw, fh)) = SNAPS.get(i as usize) else { return };
    let monitors = hypr::json("j/monitors");
    let Some(m) = monitors.as_array().and_then(|ms| ms.iter().find(|m| m["focused"] == true).or(ms.first())).cloned() else { return };
    let scale = m["scale"].as_f64().unwrap_or(1.0).max(0.1);
    let (mx, my) = (m["x"].as_f64().unwrap_or(0.0), m["y"].as_f64().unwrap_or(0.0));
    let (lw, lh) = (m["width"].as_f64().unwrap_or(1920.0) / scale, m["height"].as_f64().unwrap_or(1080.0) / scale);
    // [left, top, right, bottom] kept for the bar and the dock.
    let r: Vec<f64> = m["reserved"].as_array().map(|a| a.iter().map(|v| v.as_f64().unwrap_or(0.0)).collect()).unwrap_or_default();
    let res = |k: usize| r.get(k).copied().unwrap_or(0.0);
    let gap = 8.0;
    let (ux, uy) = (mx + res(0) + gap, my + res(1) + gap);
    let (uw, uh) = ((lw - res(0) - res(2) - gap * 2.0).max(160.0), (lh - res(1) - res(3) - gap * 2.0).max(160.0));
    let (x, y, w, h) = ((ux + uw * fx).round(), (uy + uh * fy).round(), (uw * fw).round(), (uh * fh).round());
    hypr::dispatch("hl.dsp.window.float({ action = \"enable\" })", "setfloating");
    hypr::dispatch(&format!("hl.dsp.window.resize({{ x = {w}, y = {h} }})"), &format!("resizeactive exact {w} {h}"));
    hypr::dispatch(&format!("hl.dsp.window.move({{ x = {x}, y = {y} }})"), &format!("moveactive exact {x} {y}"));
}

fn wire_bar(bar: &Bar, i: usize, q: &Queue) {
    macro_rules! on {
        ($set:ident, |$($a:ident),*| $act:expr) => {{
            let q = q.clone();
            bar.$set(move |$($a),*| q.borrow_mut().push($act));
        }};
    }
    on!(on_workspace_go, |id| Action::Workspace(id));
    on!(on_workspace_step, |d| Action::WorkspaceStep(d));
    on!(on_volume_step, |d| Action::VolumeStep(d));
    on!(on_media_prev, | | Action::Media(mpris::Cmd::Prev));
    on!(on_media_toggle, | | Action::Media(mpris::Cmd::Toggle));
    on!(on_media_next, | | Action::Media(mpris::Cmd::Next));
    on!(on_media_seek, |f| Action::Media(mpris::Cmd::Seek(f as f64)));
    on!(on_toggle_panel, |w, x| Action::TogglePanel(i, w.to_string(), x));
    on!(on_toggle_dnd, | | Action::ToggleDnd);
    on!(on_open_mail, | | Action::OpenMail);
    on!(on_tray_toggle, | | Action::TrayToggle);
    on!(on_tray_activate, |k, x| Action::TrayActivate(i, k.to_string(), x));
    on!(on_tray_secondary, |k| Action::TraySecondary(k.to_string()));
    on!(on_tray_menu, |k, x| Action::TrayMenu(i, k.to_string(), x));
    on!(on_tray_scroll, |k, d| Action::TrayScroll(k.to_string(), d));
}

fn wire_panels(p: &Panels, q: &Queue) {
    macro_rules! on {
        ($set:ident, |$($a:ident),*| $act:expr) => {{
            let q = q.clone();
            p.$set(move |$($a),*| q.borrow_mut().push($act));
        }};
    }
    on!(on_dismiss, | | Action::ClosePanel);
    on!(on_power, |a| Action::Power(a.to_string()));
    on!(on_window_act, |a| Action::WindowAct(a.to_string()));
    on!(on_window_snap, |i| Action::WindowSnap(i));
    on!(on_month_step, |d| Action::MonthStep(d));
    on!(on_month_reset, | | Action::MonthReset);
    on!(on_cycle_theme, | | Action::CycleTheme);
    on!(on_tile, |k| Action::Tile(k.to_string()));
    on!(on_set_volume, |v| Action::SetVolume(v));
    on!(on_toggle_mute, | | Action::ToggleMute);
    on!(on_set_brightness, |v| Action::SetBrightness(v));
    on!(on_set_mic, |v| Action::SetMic(v));
    on!(on_toggle_mic, | | Action::ToggleMic);
    on!(on_note_dismiss, |id| Action::NoteDismiss(id));
    on!(on_note_act, |id, k| Action::NoteAct(id, k.to_string()));
    on!(on_notes_clear, | | Action::NotesClear);
    on!(on_toggle_dnd, | | Action::ToggleDnd);
    on!(on_media_prev, | | Action::Media(mpris::Cmd::Prev));
    on!(on_media_toggle, | | Action::Media(mpris::Cmd::Toggle));
    on!(on_media_next, | | Action::Media(mpris::Cmd::Next));
    on!(on_media_seek, |f| Action::Media(mpris::Cmd::Seek(f as f64)));
    on!(on_drive_open, |m| Action::DriveOpen(m.to_string()));
    on!(on_drive_mount, |p| Action::DriveMount(p.to_string()));
    on!(on_drive_eject, |d| Action::DriveEject(d.to_string()));
    on!(on_run_updates, | | Action::RunUpdates);
    on!(on_menu_pick, |id, sub| Action::MenuPick(id, sub));
    on!(on_menu_back, | | Action::MenuBack);
    on!(on_app_menu_pick, |k| Action::AppMenu(k.to_string()));
    on!(on_show_pane, |k| Action::CcPane(k.to_string()));
    on!(on_wifi, |v| Action::Wifi(v));
    on!(on_bt, |v| Action::Bt(v));
    on!(on_join, |n| Action::Join(n.to_string()));
    on!(on_join_secret, |n, s| Action::JoinSecret(n.to_string(), s.to_string()));
    on!(on_disconnect, | | Action::Disconnect);
    on!(on_forget, |n| Action::Forget(n.to_string()));
    on!(on_device, |m| Action::Device(m.to_string()));
    on!(on_pair_answer, |a| Action::PairAnswer(a));
}
