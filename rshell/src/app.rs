//! The shell itself: a bar on every monitor, the panels that drop from it
//! (one overlay surface per monitor, there only while a panel is open), the
//! notification banners, and everything they do.
//!
//! Slint callbacks only queue an `Action`; the main loop carries them out
//! here with the whole shell in hand, so no callback has to borrow it.

use crate::art::Pixels;
use crate::{daemon, extras, hypr, mpris, notify, sys, theme, tray, wl};
use crate::{Bar, DayCell, DriveRow, MediaInfo, MenuEntry, Note, NoteAction, Panels, PrivacyRow, Theme, Tile, TimerRow, Toasts, TrayItem, Workspace};
use serde_json::json;
use slint::platform::software_renderer::MinimalSoftwareWindow;
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use smithay_client_toolkit::shell::wlr_layer::{Anchor, KeyboardInteractivity, Layer};
use std::cell::RefCell;
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
    /// When the open panel was closed: the surface goes once it has faded.
    closing: Option<Instant>,
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
    last_tick: Instant,
    wake: UnixStream,
}

impl App {
    pub fn new(shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, wake: UnixStream) -> App {
        let w = || wake.try_clone().expect("wake");
        let (hypr_tx, hypr_rx) = channel();
        hypr::listen(hypr_tx, w());
        let (daemon_tx, daemon_rx) = channel();
        let mut daemon = daemon::start(daemon_tx, w());
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

        // A bar, and a panel layer, on every monitor.
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
            bars.push(BarOn { bar, monitor, output: output.clone(), height, panels, panel_window, panel_surface: None, closing: None });
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

        let mut app = App {
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
        for b in &self.bars {
            if let Some(c) = b.closing {
                d = d.min(Duration::from_millis(230).saturating_sub(c.elapsed()));
            }
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
        while let Ok(ev) = self.daemon_rx.try_recv() {
            if ev["ev"] == "cmd" {
                if let Some(line) = ev["line"].as_str() {
                    self.command(shell, qh, line);
                }
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
        if changed {
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

        // Panel surfaces that have finished fading.
        for b in &mut self.bars {
            if b.closing.is_some_and(|c| c.elapsed() >= Duration::from_millis(220)) {
                b.closing = None;
                if let Some(id) = b.panel_surface.take() {
                    shell.remove(id);
                }
            }
        }

        if self.last_tick.elapsed() >= Duration::from_secs(1) {
            self.last_tick = Instant::now();
            let stamp = theme::modified();
            if stamp != self.look_stamp {
                self.look_stamp = stamp;
                self.look = theme::load();
                self.refresh_look();
                self.refresh_extras();
            }
            self.refresh_second();
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
    }

    fn refresh_look(&mut self) {
        for b in &self.bars {
            let us = self.look.screen_scale(&b.monitor);
            theme_into!(b.bar, &self.look, us);
            theme_into!(b.panels, &self.look, us);
            b.bar.set_quiet(self.look.dnd);
            b.bar.set_show_tray(self.look.show_tray);
            b.bar.set_tray_open(self.look.tray_open);
            b.panels.set_quiet(self.look.dnd);
            b.panels.set_theme_mode(self.look.mode.clone().into());
        }
        theme_into!(self.toasts, &self.look, 1.0);
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
        let Some(host) = self.bars.get_mut(bar) else { return };
        host.panels.set_anchor(x);
        host.panels.set_top(host.height + 10.0);
        host.panels.set_which(which.into());
        host.bar.set_open_panel(which.into());
        host.closing = None;
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
        }
        if which == "tray" {
            self.menu_at = None;
            self.menu_stack.clear();
        }
        if let Some(host) = self.bars.get_mut(bar) {
            host.panels.set_which("".into());
            host.bar.set_open_panel("".into());
            host.closing = Some(Instant::now());
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
            Action::VolumeStep(d) => self.set_volume(self.sound.volume + 0.05 * d as f64),
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

    /// A line from hyprshell.cmd: what the keybinds send the shell.
    fn command(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, line: &str) {
        let line = line.trim();
        let (name, arg) = line.split_once(' ').map(|(a, b)| (a, b.trim())).unwrap_or((line, ""));
        match name {
            "toggleControlCenter" => self.toggle_from_key(shell, qh, "control"),
            "toggleNotifications" => self.toggle_from_key(shell, qh, "notifications"),
            "toggleCalendar" => self.toggle_from_key(shell, qh, "calendar"),
            "togglePower" => self.toggle_from_key(shell, qh, "power"),
            "toggleTimers" => self.toggle_from_key(shell, qh, "timers"),
            "toggleUpdates" => self.toggle_from_key(shell, qh, "updates"),
            "closePanels" => self.close_panel(),
            "toggleDnd" => self.act(shell, qh, Action::ToggleDnd),
            "volumeUp" => self.set_volume(self.sound.volume + 0.05),
            "volumeDown" => self.set_volume(self.sound.volume - 0.05),
            "volumeMute" => self.act(shell, qh, Action::ToggleMute),
            "micMute" => self.act(shell, qh, Action::ToggleMic),
            "brightnessUp" => self.set_brightness(self.sound.brightness.unwrap_or(0.5) + 0.05),
            "brightnessDown" => self.set_brightness(self.sound.brightness.unwrap_or(0.5) - 0.05),
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
}
