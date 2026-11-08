//! Settings, for the Rust shell: the Quickshell Settings window
//! (modules/settings/Settings.qml, SettingsFrame.qml, SettingsRow.qml)
//! rewritten in Rust and Slint — the same categories, panes, rows and
//! wording, writing the same theme.json and applying the same Hyprland
//! settings live.
//!
//!   hyprshell-settings [pane]   open on a pane ("Dock", "Alt+Tab", …) or a
//!                               category ("cat:Input")
//!   hyprshell-settings --apply  put Settings' Hyprland settings back
//!                               (input, borders, gaps, motion, displays,
//!                               binds.lua) and exit; the shell runs this at
//!                               login, as Quickshell's Devices.qml did

mod anim;
mod bt;
mod face;
mod keyring;
mod frost;
mod focus;
mod gallery;
mod hdrcal;
mod daemon;
mod display;
mod eq;
mod net;
mod hypr;
mod monmap;
mod prefs;
mod rows;
mod sound;
mod system;
mod updates;

use hyprshell_kit as kit;
use rows::{Ctx, Entry, Spec, Ui, Val};
use slint::platform::Key;
use slint::{ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

use slint::Model;

slint::include_modules!();

struct State {
    c: Ctx,
    specs: Vec<Spec>,
    index: Option<Vec<Entry>>,
    hits: Vec<(String, String)>,
    /// theme.json's time when last shown, to see edits made elsewhere.
    seen: Option<SystemTime>,
    /// A row to flash once the pane is up (the search's pick).
    flash: Option<String>,
    /// Settings' own hyprshell-daemon, started when a panel first needs it.
    daemon: Option<daemon::Daemon>,
    net: net::Net,
    bt: bt::Bt,
    snd: sound::Sound,
    /// The animated styles' live previews, drawn on a thread of their own.
    anim: Option<anim::Gallery>,
    videos: gallery::Videos,
    icons: focus::Icons,
    upd: updates::Updates,
    /// Settings → Login screen: face unlock; looked at when the pane is first opened.
    face: face::Face,
    face_started: bool,
    keyring: keyring::Keyring,
    keyring_started: bool,
    /// The rows as drawn, kept so a change that leaves the page's shape alone is
    /// written into them rather than replacing them (a switch re-made in its new
    /// state has nothing to slide from).
    rows_model: Option<Rc<VecModel<Row>>>,
    rows_shape: Vec<(String, String, String)>,
    /// Updates was on screen at the last draw: it looks again each time
    /// it is opened, not each time it is drawn.
    upd_shown: bool,
    /// Settings → Display → Arrangement: where the screen being dragged
    /// would land.
    landing: Option<(String, f64, f64)>,
    /// The shell's fx.json as last drawn, and the equalizer's live gains.
    fx_seen: String,
    live: eq::Live,
    rog_asked: bool,
    rog_error_at: Option<std::time::Instant>,
    weak: slint::Weak<AppWindow>,
}

impl State {
    fn daemon(&mut self) -> &mut daemon::Daemon {
        self.daemon.get_or_insert_with(daemon::Daemon::start)
    }
}

fn mtime() -> Option<SystemTime> {
    std::fs::metadata(kit::theme::theme_path()).and_then(|m| m.modified()).ok()
}

/// SettingsRow.shortS: a long description's first sentence.
fn short(s: &str) -> String {
    if s.chars().count() <= 110 {
        return s.to_string();
    }
    let chars: Vec<char> = s.chars().collect();
    for i in 30..chars.len().saturating_sub(2) {
        if ".!?".contains(chars[i]) && chars[i + 1] == ' ' && !chars[i + 2].is_whitespace() {
            let head: String = chars[..=i].iter().collect();
            if head.chars().count() < chars.len() - 12 {
                return head;
            }
            break;
        }
    }
    if let Some(at) = s.find(" — ") {
        if s[..at].chars().count() >= 30 && s[..at].chars().count() < chars.len() - 12 {
            return s[..at].to_string();
        }
    }
    s.to_string()
}

fn show(ui: &AppWindow, st: &mut State) {
    st.c.p = prefs::Prefs::read();
    st.seen = mtime();
    let pane = st.c.ui.pane.clone();
    let open = st.c.ui.adv_open.contains(&pane);
    if pane == "Login screen" {
        if !st.face_started {
            st.face_started = true;
            let notify = face_notify(st.weak.clone());
            st.face.start(notify);
        }
        if !st.keyring_started {
            st.keyring_started = true;
            let notify = keyring_notify(st.weak.clone());
            st.keyring.start(notify);
        }
        st.c.ui.keyring = st.keyring.snap.clone();
        st.c.ui.face = st.face.snapshot();
        st.c.ui.face_pending = st.face.pending_count();
    } else if st.face_started && !st.c.ui.face.busy {
        // Not left looking through the camera with nobody on the page.
        st.face.stop_preview();
    }
    let mut specs = rows::shown_rows(&pane, rows::rows_for(&pane, &st.c), open);
    rows::card_positions(&mut specs);
    if let Some(want) = st.flash.take() {
        if let Some(r) = specs.iter_mut().find(|r| r.row.n == want.as_str()) {
            r.row.flash = true;
            if r.adv {
                // Taken to an advanced setting: its section opened.
            }
        }
    }
    let g = ui.global::<Prefs>();
    let cat = rows::category_of(&pane);
    g.set_categories(ModelRc::new(VecModel::from(
        rows::categories()
            .iter()
            .map(|c| Category { id: c.id.into(), icon: c.icon.into(), active: cat.as_ref().is_some_and(|k| k.id == c.id) })
            .collect::<Vec<_>>(),
    )));
    g.set_crumb(match &cat {
        Some(c) if c.items.len() > 1 && !pane.starts_with("cat:") => c.id.into(),
        _ => SharedString::new(),
    });
    g.set_title(rows::pane_title(&pane).into());
    g.set_note(rows::pane_note(&pane).into());
    g.set_shorts(ModelRc::new(VecModel::from(specs.iter().map(|r| SharedString::from(short(&r.row.s))).collect::<Vec<_>>())));
    // The same rows in the same order: written in place, so the ones that
    // changed (a switch, a slider) move from where they were. Anything else
    // is a new page.
    let shape: Vec<(String, String, String)> = specs.iter().map(|r| (r.row.kind.to_string(), r.row.n.to_string(), r.row.panel.to_string())).collect();
    let fresh: Vec<Row> = specs.iter().map(|r| r.row.clone()).collect();
    match (&st.rows_model, shape == st.rows_shape && !shape.is_empty()) {
        (Some(m), true) => {
            for (i, r) in fresh.into_iter().enumerate() {
                m.set_row_data(i, r);
            }
        }
        _ => {
            let m = Rc::new(VecModel::from(fresh));
            g.set_rows(ModelRc::from(m.clone()));
            st.rows_model = Some(m);
            st.rows_shape = shape;
        }
    }
    st.specs = specs;
    if pane == "Login screen" {
        publish_face(ui, st);
    }
    // The galleries, kept up only while they're on screen.
    let has = |k: &str| st.specs.iter().any(|r| r.row.kind == "panel" && r.row.panel == k);
    let (animated, live) = (has("animated"), has("gallery"));
    let (on_updates, on_focus) = (has("shellUpdates"), has("focus") || has("notifApps"));
    if has("monitors") {
        let sel = if st.c.ui.display_pick.is_empty() { monmap::monitors().first().map(|m| m.name.clone()).unwrap_or_default() } else { st.c.ui.display_pick.clone() };
        monmap::publish(ui, &st.c, &sel);
    }
    if animated && st.anim.is_none() {
        st.anim = Some(anim::Gallery::start(st.weak.clone()));
    }
    if let Some(a) = &st.anim {
        a.show(ui, &st.c.p, animated);
    }
    if on_updates && !st.upd_shown {
        check_updates(st);
    }
    st.upd_shown = on_updates;
    if on_updates {
        st.upd.publish(ui);
    }
    if on_focus {
        focus::publish(ui, &st.c.p, &mut st.icons);
    }
    if live {
        if !st.videos.scanned && !st.videos.scanning {
            scan_videos(st);
        }
        let cur = rows::live_current(&st.c);
        st.videos.publish(ui, &cur);
    }
    // The Appearance preview's own two numbers (kit's Theme has the rest).
    let look = ui.global::<Look>();
    look.set_t((st.c.p.f("translucency").clamp(0.0, 100.0) / 100.0) as f32);
    look.set_bar_h(st.c.p.f("barHeight") as f32);
    // The live panels: what they show, kept up only while they're up.
    // Laptop: the daemon asked what asusd has, once.
    if pane == "Laptop" && st.c.ui.rog.is_null() && !st.rog_asked {
        st.rog_asked = true;
        st.daemon().send(serde_json::json!({ "cmd": "rog-refresh" }));
    }
    let (on_net, on_bt, on_snd) = (pane == "Network", pane == "Bluetooth", pane == "Sound");
    if on_net || on_bt || on_snd || st.daemon.is_some() {
        let (mut net, mut bt, mut snd) = (std::mem::take(&mut st.net), std::mem::take(&mut st.bt), std::mem::take(&mut st.snd));
        net.watch(st.daemon(), on_net);
        bt.watch(st.daemon(), on_bt);
        snd.watch(st.daemon(), on_snd);
        if on_snd {
            snd.resolve(&st.c.p);
            snd.publish(ui, &st.c.p);
            // A band picked whenever there are bands, so the strip below
            // the graph always has something to show.
            let g = ui.global::<EqLook>();
            if !eq::bands(&st.c.p).iter().any(|b| b.id as i32 == g.get_selected()) {
                g.set_selected(eq::first_id(&st.c.p));
            }
            eq::publish(ui, &st.c.p, &snd);
            st.fx_seen = eq::status_text();
            let State { daemon, c, .. } = st;
            snd.sync_peaks(daemon.get_or_insert_with(daemon::Daemon::start), &c.p);
        }
        st.snd = snd;
        if on_net {
            net.publish(ui);
        }
        if on_bt {
            bt.publish(ui);
        }
        st.net = net;
        st.bt = bt;
    }
}

fn open_pane(ui: &AppWindow, st: &mut State, pane: &str) {
    if st.c.ui.pane != pane {
        st.c.ui.pane = pane.to_string();
        st.c.ui.wallpaper_mode.clear();
        ui.set_pane_y(0.0);
    }
    show(ui, st);
}

/// A line for the shell, as the keybinds send them.
fn tell_shell(line: &str) -> std::io::Result<()> {
    use std::io::Write;
    let dir = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
    let mut f = std::fs::OpenOptions::new().append(true).create(true).open(dir.join("hyprshell.cmd"))?;
    writeln!(f, "{line}")
}

/// Hyprland's spelling of the key in a Slint key event
/// (SettingsRow.hyprKeyName); "" for one it has no name for.
fn hypr_key(text: &str) -> String {
    let k = |key: Key| SharedString::from(key);
    let named: &[(Key, &str)] = &[
        (Key::Return, "Return"),
        (Key::Tab, "Tab"),
        (Key::LeftArrow, "left"),
        (Key::RightArrow, "right"),
        (Key::UpArrow, "up"),
        (Key::DownArrow, "down"),
        (Key::Home, "Home"),
        (Key::End, "End"),
        (Key::PageUp, "Prior"),
        (Key::PageDown, "Next"),
        (Key::Delete, "Delete"),
        (Key::Insert, "Insert"),
        (Key::F1, "F1"),
        (Key::F2, "F2"),
        (Key::F3, "F3"),
        (Key::F4, "F4"),
        (Key::F5, "F5"),
        (Key::F6, "F6"),
        (Key::F7, "F7"),
        (Key::F8, "F8"),
        (Key::F9, "F9"),
        (Key::F10, "F10"),
        (Key::F11, "F11"),
        (Key::F12, "F12"),
    ];
    for (key, name) in named {
        if text == k(key.clone()).as_str() {
            return name.to_string();
        }
    }
    match text {
        " " => "SPACE".into(),
        "," => "comma".into(),
        "." => "period".into(),
        "/" => "slash".into(),
        ";" => "semicolon".into(),
        "'" => "apostrophe".into(),
        "[" => "bracketleft".into(),
        "]" => "bracketright".into(),
        "-" => "minus".into(),
        "=" => "equal".into(),
        "\\" => "backslash".into(),
        "`" => "grave".into(),
        t => t.to_uppercase(),
    }
}

fn mod_name(text: &str) -> Option<&'static str> {
    let k = |key: Key| SharedString::from(key);
    if text == k(Key::Meta).as_str() || text == k(Key::MetaR).as_str() {
        Some("SUPER")
    } else if text == k(Key::Control).as_str() || text == k(Key::ControlR).as_str() {
        Some("CTRL")
    } else if text == k(Key::Alt).as_str() || text == k(Key::AltGr).as_str() {
        Some("ALT")
    } else if text == k(Key::Shift).as_str() || text == k(Key::ShiftR).as_str() {
        Some("SHIFT")
    } else {
        None
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("--apply") {
        let p = prefs::Prefs::read();
        hypr::apply_all(&p);
        // binds.lua brought up to date once (Keybinds.qml's startup sync).
        hypr::write_binds(&p);
        return;
    }

    // Every pane's rows, advanced ones included: for checking against
    // Settings.qml (tools/parity.py).
    if args.first().map(String::as_str) == Some("--dump") {
        // Each branch a pane can take: the settings that open one, in
        // memory only (nothing is written), and the wallpaper's modes.
        let variants: &[(&str, serde_json::Value)] = &[
            ("", serde_json::json!({})),
            ("", serde_json::json!({ "screenCorners": true, "cursorTheme": "system", "dockStyle": "taskbar", "nightMode": "times",
                                     "saverMode": "low", "scrollMomentum": true, "liveSound": true, "liveRotate": true })),
            ("", serde_json::json!({ "nightMode": "sun", "altTabHold": false, "motionStyle": "springy" })),
            ("animated", serde_json::json!({ "wallpaperStyle": "topo", "topoLine": "custom", "topoGround": "custom", "topoDrift": true })),
            ("animated", serde_json::json!({ "wallpaperStyle": "aurora", "animPalette": "custom" })),
            ("image", serde_json::json!({})),
            ("live", serde_json::json!({ "liveSound": true, "liveRotate": true })),
        ];
        for (mode, over) in variants {
            let mut c = Ctx { p: prefs::Prefs::read(), ui: Ui { wallpaper_mode: mode.to_string(), ..Default::default() } };
            for (k, v) in over.as_object().unwrap() {
                c.p.v[prefs::key(k)] = v.clone();
            }
            for cat in rows::categories() {
                for pane in cat.items.iter().chain(["Laptop"].iter()) {
                    c.ui.pane = pane.to_string();
                    for r in rows::shown_rows(pane, rows::rows_for(pane, &c), true) {
                        println!("{pane}\t{}\t{}\t{}", r.row.kind, r.row.n, r.row.s);
                    }
                }
            }
        }
        return;
    }
    kit::init("hyprshell-settings");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-settings");

    // The pane asked for: a pane's name, a category, or the old lower-case
    // page names.
    let first = args.first().cloned().unwrap_or_default();
    let first = rows::PANES
        .iter()
        .find(|p| p.0.eq_ignore_ascii_case(&first) || p.0.replace('+', "").eq_ignore_ascii_case(&first))
        .map(|p| p.0.to_string())
        .or_else(|| first.starts_with("cat:").then(|| first.clone()))
        .unwrap_or_else(|| "cat:Personalization".into());

    let st = Rc::new(RefCell::new(State {
        c: Ctx { p: prefs::Prefs::read(), ui: Ui { pane: first, ..Default::default() } },
        specs: vec![],
        index: None,
        hits: vec![],
        seen: None,
        flash: None,
        daemon: None,
        net: net::Net::default(),
        bt: bt::Bt::default(),
        snd: sound::Sound::default(),
        anim: None,
        videos: gallery::Videos::default(),
        icons: focus::Icons::default(),
        upd: updates::Updates::default(),
        face: face::Face::default(),
        face_started: false,
        keyring: keyring::Keyring::default(),
        keyring_started: false,
        rows_model: None,
        rows_shape: Vec::new(),
        upd_shown: false,
        landing: None,
        fx_seen: String::new(),
        rog_asked: false,
        rog_error_at: None,
        live: eq::Live::default(),
        weak: ui.as_weak(),
    }));
    show(&ui, &mut st.borrow_mut());

    let toast_timer = Rc::new(slint::Timer::default());
    let flash_timer = Rc::new(slint::Timer::default());

    // After a row is used: what it asked of the window, then the pane again.
    let settle = {
        let weak = ui.as_weak();
        let st = st.clone();
        let tt = toast_timer.clone();
        Rc::new(move || {
            let Some(ui) = weak.upgrade() else { return };
            let (toast, tell, pick, hdr) = {
                let mut s = st.borrow_mut();
                // Commands a row left for the daemon (Settings → Laptop).
                for cmd in std::mem::take(&mut s.c.ui.daemon) {
                    s.daemon().send(cmd);
                }
                // Settings → Login screen: what its rows asked of face unlock.
                for cmd in std::mem::take(&mut s.c.ui.face_cmds) {
                    s.face.command(cmd);
                }
                for cmd in std::mem::take(&mut s.c.ui.keyring_cmds) {
                    s.keyring.command(cmd);
                }
                (s.c.ui.toast.take(), std::mem::take(&mut s.c.ui.tell), s.c.ui.pick.take(), s.c.ui.hdr.take())
            };
            if let Some((output, pattern)) = hdr {
                open_hdr(&st, &output, pattern);
            }
            for line in tell {
                if let Err(e) = tell_shell(&line) {
                    st.borrow_mut().c.ui.toast = Some(format!("Couldn't reach the shell: {e}"));
                }
            }
            if let Some((folder, title, key)) = pick {
                let weak = ui.as_weak();
                let st2 = st.clone();
                kit::spawn(
                    move || if folder { kit::portal::open_folder(&title) } else { kit::portal::open_file(&title, &[]) },
                    move |picked| {
                        let (Some(ui), Some(path)) = (weak.upgrade(), picked) else { return };
                        let mut s = st2.borrow_mut();
                        let path = path.display().to_string();
                        if let Some(list) = key.strip_prefix('+') {
                            // Added to a list (the live wallpaper's folders
                            // and files), not set.
                            let mut v: Vec<String> = serde_json::from_str(&s.c.p.s(list)).unwrap_or_default();
                            if list == "liveFolders" && v.is_empty() {
                                v.push(format!("{}/Videos/Wallpapers", kit::home().display()));
                            }
                            if !v.contains(&path) {
                                v.push(path);
                            }
                            s.c.set(list, serde_json::json!(serde_json::to_string(&v).unwrap_or_default()));
                        } else {
                            s.c.set(&key, serde_json::json!(path));
                        }
                        s.c.ui.wallpaper_mode.clear();
                        show(&ui, &mut s);
                    },
                );
            }
            let toast = toast.or_else(|| st.borrow_mut().c.ui.toast.take());
            if let Some(t) = toast {
                ui.global::<Prefs>().set_toast(t.into());
                let weak = ui.as_weak();
                tt.start(slint::TimerMode::SingleShot, Duration::from_millis(3000), move || {
                    if let Some(ui) = weak.upgrade() {
                        ui.global::<Prefs>().set_toast(SharedString::new());
                    }
                });
            }
            let mut s = st.borrow_mut();
            let pane = s.c.ui.pane.clone();
            open_pane(&ui, &mut s, &pane);
        })
    };

    // A row's own closure, with what it was handed.
    let run = {
        let st = st.clone();
        let settle = settle.clone();
        Rc::new(move |i: i32, v: Val| {
            let f = st.borrow().specs.get(i as usize).and_then(|r| r.set.clone());
            if let Some(f) = f {
                let mut s = st.borrow_mut();
                f(&mut s.c, v);
            }
            settle();
        })
    };

    let g = ui.global::<Prefs>();
    {
        let run = run.clone();
        g.on_set_bool(move |i, v| run(i, Val::B(v)));
    }
    {
        let run = run.clone();
        g.on_set_num(move |i, v| run(i, Val::N(v as f64)));
    }
    {
        let run = run.clone();
        g.on_set_text(move |i, t| run(i, Val::S(t.to_string())));
    }
    {
        let run = run.clone();
        let st = st.clone();
        g.on_set_index(move |i, k| {
            let v = st.borrow().specs.get(i as usize).and_then(|r| r.values.get(k as usize).cloned());
            if let Some(v) = v {
                run(i, Val::S(v));
            }
        });
    }
    {
        let run = run.clone();
        let st = st.clone();
        let settle = settle.clone();
        g.on_press(move |i, k| {
            let (press, panel) = {
                let s = st.borrow();
                let Some(r) = s.specs.get(i as usize) else { return };
                (r.presses.get(k as usize).cloned(), r.row.panel.to_string())
            };
            if let Some(f) = press {
                f(&mut st.borrow_mut().c, Val::Unit);
                settle();
            } else if !panel.is_empty() {
                // The way to what a panel that isn't drawn here holds.
                match panel.as_str() {
                    "wifi" => st.borrow_mut().c.ui.tell.push("showWifi".into()),
                    "bluetooth" => st.borrow_mut().c.ui.tell.push("showBluetooth".into()),
                    "laptop" => {
                        if std::process::Command::new("hyprshell-rog").spawn().is_err() {
                            st.borrow_mut().c.ui.toast = Some("ROG Control Center isn't installed (apps/install.sh)".into());
                        }
                    }
                    _ => {}
                }
                settle();
            } else {
                run(i, Val::Unit);
            }
        });
    }
    {
        let run = run.clone();
        let st = st.clone();
        g.on_accent(move |preset| {
            let i = st.borrow().specs.iter().position(|r| r.row.kind == "swatch");
            if let Some(i) = i {
                run(i as i32, Val::N(preset as f64));
            }
        });
    }
    {
        let run = run.clone();
        let st = st.clone();
        g.on_captured(move |i, text, ctrl, alt, shift, meta| {
            let probe = st.borrow().specs.get(i as usize).is_some_and(|r| r.row.on);
            if probe {
                run(i, Val::S(mod_name(&text).unwrap_or("unknown").to_string()));
                return;
            }
            // Backspace clears back to the default rather than binding it.
            if text == SharedString::from(Key::Backspace) {
                run(i, Val::S(String::new()));
                return;
            }
            let mut parts = vec![];
            if meta {
                parts.push("SUPER".to_string());
            }
            if ctrl {
                parts.push("CTRL".into());
            }
            if alt {
                parts.push("ALT".into());
            }
            if shift {
                parts.push("SHIFT".into());
            }
            let key = hypr_key(&text);
            if key.is_empty() {
                return;
            }
            parts.push(key);
            run(i, Val::S(parts.join(" + ")));
        });
    }
    {
        let weak = ui.as_weak();
        let st = st.clone();
        g.on_open_category(move |id| {
            let Some(ui) = weak.upgrade() else { return };
            let cat = rows::categories().into_iter().find(|c| c.id == id.as_str());
            let Some(cat) = cat else { return };
            // A category of one pane opens it.
            let pane = if cat.items.len() == 1 { cat.items[0].to_string() } else { format!("cat:{}", cat.id) };
            open_pane(&ui, &mut st.borrow_mut(), &pane);
        });
    }
    {
        let weak = ui.as_weak();
        let st = st.clone();
        g.on_back(move || {
            let Some(ui) = weak.upgrade() else { return };
            let pane = st.borrow().c.ui.pane.clone();
            if let Some(c) = rows::category_of(&pane) {
                open_pane(&ui, &mut st.borrow_mut(), &format!("cat:{}", c.id));
            }
        });
    }
    {
        let weak = ui.as_weak();
        let st = st.clone();
        g.on_search(move |q| {
            let Some(ui) = weak.upgrade() else { return };
            let q = q.trim().to_lowercase();
            let g = ui.global::<Prefs>();
            g.set_query(q.clone().into());
            let mut s = st.borrow_mut();
            if q.is_empty() {
                s.hits.clear();
                g.set_hits(ModelRc::default());
                return;
            }
            if s.index.is_none() {
                s.index = Some(rows::search_index(&s.c));
            }
            let idx = s.index.as_ref().unwrap();
            let found: Vec<(String, String, Hit)> = rows::rank(&q, idx, 40)
                .into_iter()
                .map(|e| {
                    let sub = if e.is_pane {
                        "Page".to_string()
                    } else {
                        format!("{}{}", rows::pane_title(&e.pane), if e.section.is_empty() { String::new() } else { format!(" › {}", e.section) })
                    };
                    (
                        e.pane.clone(),
                        if e.is_pane { String::new() } else { e.n.clone() },
                        Hit { n: e.n.clone().into(), sub: sub.into(), icon: rows::pane_icon(&e.pane).into() },
                    )
                })
                .collect();
            s.hits = found.iter().map(|f| (f.0.clone(), f.1.clone())).collect();
            g.set_hits(ModelRc::new(VecModel::from(found.into_iter().map(|f| f.2).collect::<Vec<_>>())));
        });
    }
    {
        let weak = ui.as_weak();
        let st = st.clone();
        let ft = flash_timer.clone();
        g.on_pick_hit(move |i| {
            let Some(ui) = weak.upgrade() else { return };
            let Some((pane, n)) = st.borrow().hits.get(i as usize).cloned() else { return };
            {
                let mut s = st.borrow_mut();
                if !n.is_empty() {
                    // An advanced setting: its section opened first.
                    let open = s.c.ui.adv_open.contains(&pane);
                    let marked = rows::shown_rows(&pane, rows::rows_for(&pane, &s.c), true);
                    if !open && marked.iter().any(|r| r.adv && r.row.n == n.as_str()) {
                        s.c.ui.adv_open.insert(pane.clone());
                    }
                    s.flash = Some(n.clone());
                }
                s.c.ui.pane = String::new();
                open_pane(&ui, &mut s, &pane);
            }
            ui.set_query_text(SharedString::new());
            let g = ui.global::<Prefs>();
            g.set_query(SharedString::new());
            g.set_hits(ModelRc::default());
            // The flash let go of after a moment.
            let weak = ui.as_weak();
            let st = st.clone();
            ft.start(slint::TimerMode::SingleShot, Duration::from_millis(1100), move || {
                if let Some(ui) = weak.upgrade() {
                    let s = st.borrow();
                    let rows: Vec<Row> = s.specs.iter().map(|r| Row { flash: false, ..r.row.clone() }).collect();
                    // Into the model that is on screen, not a new one beside it.
                    match &s.rows_model {
                        Some(m) if m.row_count() == rows.len() => {
                            for (i, r) in rows.into_iter().enumerate() {
                                m.set_row_data(i, r);
                            }
                        }
                        _ => ui.global::<Prefs>().set_rows(ModelRc::new(VecModel::from(rows))),
                    }
                }
            });
        });
    }
    {
        let weak = ui.as_weak();
        g.on_scroll_to(move |y| {
            if let Some(ui) = weak.upgrade() {
                ui.set_pane_y((-(y - 80.0)).min(0.0));
            }
        });
    }

    // The daemon's events, as they come.
    let pump = slint::Timer::default();
    {
        let weak = ui.as_weak();
        let st = st.clone();
        pump.start(slint::TimerMode::Repeated, Duration::from_millis(80), move || {
            let Some(ui) = weak.upgrade() else { return };
            let mut s = st.borrow_mut();
            let Some(d) = s.daemon.as_mut() else { return };
            let evs: Vec<serde_json::Value> = d.rx.try_iter().collect();
            if evs.is_empty() {
                return;
            }
            // Settings → Laptop: asusd's state, and what it refused.
            let mut rog = false;
            for ev in &evs {
                if ev["ev"] == "rog" {
                    s.c.ui.rog = ev.clone();
                    s.c.ui.rog_error.clear();
                    rog = true;
                } else if ev["ev"] == "rog-error" {
                    s.c.ui.rog_error = ev["message"].as_str().unwrap_or("").to_string();
                    s.rog_error_at = Some(std::time::Instant::now());
                    rog = true;
                }
            }
            if rog && s.c.ui.pane == "Laptop" {
                show(&ui, &mut s);
            }
            let (mut net, mut bt) = (std::mem::take(&mut s.net), std::mem::take(&mut s.bt));
            let (mut cn, mut cb) = (false, false);
            for ev in &evs {
                cn |= net.event(s.daemon(), ev);
                cb |= bt.event(s.daemon(), ev);
            }
            if cn && s.c.ui.pane == "Network" {
                net.publish(&ui);
            }
            if cb && s.c.ui.pane == "Bluetooth" {
                bt.publish(&ui);
            }
            // Live levels: many a second, so straight to the meters.
            let mut peaked = false;
            for ev in evs.iter().filter(|e| e["ev"] == "pa-peak") {
                s.snd.peak(ev);
                peaked = true;
            }
            if peaked && s.c.ui.pane == "Sound" {
                s.snd.decay(0.08);
                s.snd.publish_meters(&ui);
            }
            if evs.iter().fold(false, |a, ev| s.snd.event(ev) || a) && s.c.ui.pane == "Sound" {
                let State { snd, c, .. } = &mut *s;
                snd.resolve(&c.p);
                snd.publish(&ui, &c.p);
                eq::publish(&ui, &c.p, snd);
                // The device in use may have changed: its level, then.
                let State { daemon, c, snd, .. } = &mut *s;
                if let Some(d) = daemon.as_mut() {
                    snd.sync_peaks(d, &c.p);
                }
            }
            s.net = net;
            s.bt = bt;
        });
    }
    wire_wifi(&ui, &st);
    wire_bt(&ui, &st);
    wire_face(&ui, &st);
    wire_frost(&ui, &st);
    wire_sound(&ui, &st);
    wire_eq(&ui, &st);
    wire_galleries(&ui, &st, settle.clone());

    // Edits made elsewhere: shown within a second.
    let poll = slint::Timer::default();
    {
        let weak = ui.as_weak();
        let st = st.clone();
        poll.start(slint::TimerMode::Repeated, Duration::from_millis(1000), move || {
            let Some(ui) = weak.upgrade() else { return };
            // A display change on trial: the countdown, and back by itself.
            let trial = st.borrow().c.ui.trial.as_ref().map(|t| t.until <= std::time::Instant::now());
            if let Some(expired) = trial {
                let mut s = st.borrow_mut();
                if expired {
                    display::revert_trial(&mut s.c);
                }
                if s.c.ui.pane == "Display" || expired {
                    show(&ui, &mut s);
                }
                return;
            }
            // An update started from here: its terminal writes a file when
            // it's done, and then it's looked at again (half an hour at most).
            let waiting = st.borrow().upd.waiting.clone();
            if let Some((before, since)) = waiting {
                let mut s = st.borrow_mut();
                if updates::done_text() != before {
                    s.upd.waiting = None;
                    check_updates(&mut s);
                    s.upd.publish(&ui);
                } else if hyprshell_kit::now() - since > 1800 {
                    s.upd.waiting = None;
                }
            }
            // Laptop: what asusd refused, shown for eight seconds.
            let stale = st.borrow().rog_error_at.is_some_and(|t| t.elapsed() > Duration::from_secs(8));
            if stale {
                let mut s = st.borrow_mut();
                s.rog_error_at = None;
                s.c.ui.rog_error.clear();
                if s.c.ui.pane == "Laptop" {
                    show(&ui, &mut s);
                }
            }
            // The shell's word on the equalizer and noise suppression.
            if st.borrow().c.ui.pane == "Sound" {
                let now = eq::status_text();
                let mut s = st.borrow_mut();
                if now != s.fx_seen {
                    s.fx_seen = now;
                    let State { snd, c, .. } = &mut *s;
                    snd.publish(&ui, &c.p);
                    eq::publish(&ui, &c.p, snd);
                }
            }
            let changed = mtime() != st.borrow().seen;
            if changed {
                let mut s = st.borrow_mut();
                s.index = None;
                show(&ui, &mut s);
            }
        });
    }

    ui.run().expect("run");
}

/// Settings → Network's panel: WifiPanel.qml's handlers.
fn wire_wifi(ui: &AppWindow, st: &Rc<RefCell<State>>) {
    let w = ui.global::<Wifi>();
    // Runs `f` on the network model and the daemon, then redraws the panel.
    let with = {
        let weak = ui.as_weak();
        let st = st.clone();
        Rc::new(move |f: &dyn Fn(&mut net::Net, &mut daemon::Daemon, &AppWindow)| {
            let Some(ui) = weak.upgrade() else { return };
            let mut s = st.borrow_mut();
            let mut n = std::mem::take(&mut s.net);
            f(&mut n, s.daemon(), &ui);
            n.publish(&ui);
            s.net = n;
        })
    };
    // on!(callback, [args], |n, d, ui| body): the panel's handler.
    macro_rules! on {
        ($name:ident, [$($a:ident : $t:ty),*], |$n:ident, $d:ident, $ui:ident| $body:expr) => {{
            let with = with.clone();
            w.$name(move |$($a: $t),*| {
                with(&|$n: &mut net::Net, $d: &mut daemon::Daemon, $ui: &AppWindow| {
                    let _ = (&$n, &$d, &$ui);
                    $body;
                })
            });
        }};
    }
    on!(on_set_wifi, [v: bool], |n, d, _ui| n.set_wifi(d, v));
    on!(on_disconnect, [], |n, d, _ui| n.disconnect(d));
    on!(on_toggle_details, [], |n, _d, _ui| n.show_details = !n.show_details);
    on!(on_current_autoconnect, [v: bool], |n, d, _ui| {
        if let Some(u) = n.profile_for(&n.ssid.clone()).map(|p| p.uuid.clone()) {
            n.set_autoconnect(d, &u, v);
        }
    });
    on!(on_forget_current, [], |n, d, _ui| {
        let ssid = n.ssid.clone();
        n.forget(d, &ssid);
        n.show_details = false;
    });
    on!(on_scan, [], |n, d, _ui| n.scan(d));
    on!(on_open_row, [ssid: SharedString], |n, d, ui| {
        net::reset_form(ui);
        n.open_row(d, &ssid);
    });
    on!(on_join, [ssid: SharedString, pw: SharedString], |n, d, _ui| n.join(d, &ssid, &pw));
    on!(on_new_password_mode, [], |n, _d, _ui| n.new_password = true);
    on!(on_change_signin, [ssid: SharedString], |n, _d, ui| {
        n.prefill(ui, &ssid);
        n.edit_signin = true;
    });
    on!(on_cancel_edit, [], |n, _d, _ui| {
        if n.edit_signin || n.edit_general {
            n.edit_signin = false;
            n.edit_general = false;
        } else {
            n.open_ssid.clear();
            n.hidden_open = false;
            n.list = n.networks.iter().filter(|x| !x.in_use).cloned().collect();
        }
    });
    on!(on_forget, [ssid: SharedString], |n, d, _ui| {
        n.forget(d, &ssid);
        n.open_ssid.clear();
    });
    on!(on_row_autoconnect, [ssid: SharedString, v: bool], |n, d, _ui| {
        if let Some(u) = n.profile_for(&ssid).map(|p| p.uuid.clone()) {
            n.set_autoconnect(d, &u, v);
        }
    });
    on!(on_close_row, [], |n, _d, _ui| {
        n.open_ssid.clear();
        n.list = n.networks.iter().filter(|x| !x.in_use).cloned().collect();
    });
    // A saved enterprise network's sign-in, changed: its general settings
    // stay as they are.
    on!(on_join_enterprise, [target: SharedString, hidden: bool], |n, d, ui| {
        let w = ui.global::<Wifi>();
        let (ca, eap, phase2) = enterprise_basics(ui);
        let picked = w.get_f_sec();
        let extra = enterprise_extra(ui, if picked == "wpa-eap-suite-b-192" { "wpa-eap-suite-b-192" } else { "wpa-eap" }, None);
        n.join_enterprise(d, target.trim(), w.get_f_identity().trim(), &w.get_f_password(), &eap, &phase2, &ca, w.get_f_domain().trim(), w.get_f_anon().trim(), hidden, extra);
    });
    on!(on_toggle_all, [], |n, _d, _ui| n.show_all = !n.show_all);
    on!(on_toggle_hidden, [], |n, _d, ui| {
        n.open_ssid.clear();
        net::reset_form(ui);
        n.hidden_open = !n.hidden_open;
    });
    // A new network (or a hidden one): the security picked, or the one
    // worked out, and what it asks for.
    on!(on_connect_new, [target: SharedString, found_key: SharedString, hidden: bool], |n, d, ui| {
        let w = ui.global::<Wifi>();
        let picked = w.get_f_sec().to_string();
        let key = if picked == "auto" { found_key.to_string() } else { picked.clone() };
        let form = if picked == "auto" {
            if hidden { "password" } else { net::form_of(&key) }
        } else {
            net::form_of(&picked)
        };
        // Hidden and Automatic: NetworkManager takes a password as WPA2/3.
        let form = if hidden && picked == "auto" && w.get_f_password().is_empty() { "open" } else { form };
        let general = net::general(ui, hidden);
        if form == "enterprise" {
            let extra = enterprise_extra(ui, &key, Some(general));
            let (ca, eap, phase2) = enterprise_basics(ui);
            n.join_enterprise(d, target.trim(), w.get_f_identity().trim(), &w.get_f_password(), &eap, &phase2, &ca, w.get_f_domain().trim(), w.get_f_anon().trim(), hidden, extra);
            return;
        }
        // Automatic leaves the kind to NetworkManager, as before; picked by
        // hand, it's asked for outright.
        let key = if picked == "auto" { "" } else { picked.as_str() };
        let secret = if form == "open" { String::new() } else { w.get_f_password().to_string() };
        n.join_new(d, target.trim(), key, &secret, &w.get_f_wep_type(), hidden, general);
    });
    on!(on_edit_settings, [ssid: SharedString], |n, _d, ui| {
        if n.prefill_general(ui, &ssid) {
            n.edit_general = true;
        }
    });
    on!(on_save_settings, [ssid: SharedString], |n, d, ui| {
        let g = net::general(ui, false);
        n.save_general(d, &ssid, g);
    });
    on!(on_toggle_saved, [], |n, _d, _ui| n.show_saved = !n.show_saved);
    on!(on_forget_uuid, [uuid: SharedString], |n, d, _ui| n.forget(d, &uuid));
    w.on_open_editor(|| {
        let _ = std::process::Command::new("nm-connection-editor").spawn();
    });
    {
        let weak = ui.as_weak();
        w.on_pick_file(move |which| {
            let weak = weak.clone();
            let which = which.to_string();
            let (title, filters): (&'static str, &'static [(&'static str, &'static [&'static str])]) = match which.as_str() {
                "cert" => ("Your certificate", &[("Certificates", &["*.pem", "*.crt", "*.cer", "*.der", "*.p12", "*.pfx"]), ("All files", &["*"])]),
                "key" => ("Private key", &[("Keys", &["*.pem", "*.key", "*.der", "*.p12", "*.pfx"]), ("All files", &["*"])]),
                "pac" => ("PAC file", &[("PAC files", &["*.pac"]), ("All files", &["*"])]),
                _ => ("CA certificate", &[("Certificates", &["*.pem", "*.crt", "*.cer", "*.der"]), ("All files", &["*"])]),
            };
            kit::spawn(
                move || kit::portal::open_file(title, filters),
                move |f| {
                    if let (Some(ui), Some(f)) = (weak.upgrade(), f) {
                        let w = ui.global::<Wifi>();
                        let path: SharedString = f.display().to_string().into();
                        match which.as_str() {
                            "cert" => {
                                // A .p12 holds the key as well.
                                let p12 = path.ends_with(".p12") || path.ends_with(".pfx");
                                if p12 && w.get_f_private_key().is_empty() {
                                    w.set_f_private_key(path.clone());
                                }
                                w.set_f_client_cert(path);
                            }
                            "key" => w.set_f_private_key(path),
                            "pac" => w.set_f_pac_file(path),
                            _ => {
                                w.set_f_ca_file(path);
                                w.set_f_ca("file".into());
                            }
                        }
                    }
                },
            );
        });
    }
}

/// Settings → Bluetooth's panel: BluetoothPanel.qml's handlers.
fn wire_bt(ui: &AppWindow, st: &Rc<RefCell<State>>) {
    let b = ui.global::<Blue>();
    let with = {
        let weak = ui.as_weak();
        let st = st.clone();
        Rc::new(move |f: &dyn Fn(&mut bt::Bt, &mut daemon::Daemon, &AppWindow)| {
            let Some(ui) = weak.upgrade() else { return };
            let mut s = st.borrow_mut();
            let mut m = std::mem::take(&mut s.bt);
            f(&mut m, s.daemon(), &ui);
            m.publish(&ui);
            s.bt = m;
        })
    };
    macro_rules! on {
        ($name:ident, [$($a:ident : $t:ty),*], |$m:ident, $d:ident, $ui:ident| $body:expr) => {{
            let with = with.clone();
            b.$name(move |$($a: $t),*| {
                with(&|$m: &mut bt::Bt, $d: &mut daemon::Daemon, $ui: &AppWindow| {
                    let _ = (&$m, &$d, &$ui);
                    $body;
                })
            });
        }};
    }
    on!(on_set_powered, [v: bool], |m, d, _ui| m.set_powered(d, v));
    on!(on_set_discoverable, [v: bool], |m, d, _ui| m.set_discoverable(d, v));
    on!(on_answer, [yes: bool], |m, d, ui| {
        let pin = ui.global::<Blue>().get_pin().to_string();
        m.answer(d, yes, &pin);
        ui.global::<Blue>().set_pin(SharedString::new());
    });
    on!(on_cancel_display, [], |m, d, _ui| {
        if let Some(mac) = m.display.as_ref().and_then(|x| x["mac"].as_str()).map(str::to_string) {
            m.cancel_pairing(d, &mac);
        }
        m.display = None;
    });
    on!(on_toggle, [mac: SharedString, connected: bool], |m, d, _ui| if connected { m.disconnect(d, &mac) } else { m.connect(d, &mac) });
    on!(on_menu, [mac: SharedString], |m, _d, _ui| m.menu_mac = if m.menu_mac == mac.as_str() { String::new() } else { mac.to_string() });
    on!(on_remove, [mac: SharedString], |m, d, _ui| {
        m.remove(d, &mac);
        m.menu_mac.clear();
    });
    on!(on_scan, [], |m, d, _ui| m.scan(d));
    on!(on_pair, [mac: SharedString], |m, d, _ui| m.pair(d, &mac));
    on!(on_cancel_pair, [mac: SharedString], |m, d, _ui| m.cancel_pairing(d, &mac));
}

/// Settings → Sound's panel: SoundPanel.qml's handlers.
fn wire_sound(ui: &AppWindow, st: &Rc<RefCell<State>>) {
    let g = ui.global::<Snd>();
    let with = {
        let weak = ui.as_weak();
        let st = st.clone();
        Rc::new(move |f: &dyn Fn(&mut sound::Sound, &mut prefs::Prefs)| {
            let Some(ui) = weak.upgrade() else { return };
            let mut s = st.borrow_mut();
            let mut m = std::mem::take(&mut s.snd);
            f(&mut m, &mut s.c.p);
            m.resolve(&s.c.p);
            m.publish(&ui, &s.c.p);
            // A device picked, meters switched: the levels wanted change.
            let State { daemon, c, .. } = &mut *s;
            m.sync_peaks(daemon.get_or_insert_with(daemon::Daemon::start), &c.p);
            m.publish_meters(&ui);
            s.snd = m;
        })
    };
    macro_rules! on {
        ($name:ident, [$($a:ident : $t:ty),*], |$m:ident, $p:ident| $body:expr) => {{
            let with = with.clone();
            g.$name(move |$($a: $t),*| {
                with(&|$m: &mut sound::Sound, $p: &mut prefs::Prefs| {
                    let _ = (&$m, &$p);
                    $body;
                })
            });
        }};
    }
    // A pref written; a failed write is shown where the panel shows errors.
    fn put(m: &mut sound::Sound, p: &mut prefs::Prefs, k: &str, v: serde_json::Value) {
        if let Err(e) = p.set(k, v) {
            m.last_error = format!("Couldn't save the setting: {e}");
        }
    }
    on!(on_set_tab, [i: i32], |m, p| put(m, p, "soundTab", ["output", "input", "apps", "options"].get(i as usize).copied().unwrap_or("output").into()));
    on!(on_default_volume, [out: bool, v: f32], |m, p| {
        let n = if out { m.default_sink.clone() } else { m.default_source.clone() };
        m.set_volume(p, &n, v as f64)
    });
    on!(on_default_mute, [out: bool], |m, _p| {
        let n = if out { m.default_sink.clone() } else { m.default_source.clone() };
        let on = !m.sinks.iter().chain(m.sources.iter()).find(|x| x.name == n).is_some_and(|x| x.mute);
        m.set_mute(&n, on)
    });
    on!(on_volume, [n: SharedString, v: f32], |m, p| m.set_volume(p, &n, v as f64));
    on!(on_mute, [n: SharedString, v: bool], |m, _p| m.set_mute(&n, v));
    on!(on_use, [n: SharedString], |m, p| {
        // With an effect in the way, the device it feeds is what changes.
        let sink = m.sinks.iter().any(|x| x.name == n.as_str());
        if sink && m.eq_active() {
            put(m, p, "eqTarget", n.as_str().into());
        } else if !sink && m.ns_active() {
            put(m, p, "nsTarget", n.as_str().into());
        }
        m.set_default(&n)
    });
    on!(on_pick, [out: bool, n: SharedString], |m, _p| if out { m.picked_out = n.to_string() } else { m.picked_in = n.to_string() });
    on!(on_toggle_hidden_list, [], |m, _p| m.show_hidden = !m.show_hidden);
    on!(on_set_port, [n: SharedString, port: SharedString], |m, _p| m.set_port(&n, &port));
    on!(on_set_profile, [n: SharedString, prof: SharedString], |m, _p| m.set_profile(&n, &prof));
    on!(on_set_delay, [n: SharedString, ms: f32], |m, _p| m.set_delay(&n, ms as f64));
    on!(on_test, [n: SharedString], |m, _p| m.test(&n));
    on!(on_rename, [n: SharedString, nick: SharedString], |m, p| {
        let mut names: serde_json::Map<String, serde_json::Value> = serde_json::from_str(&p.s("soundNames")).unwrap_or_default();
        let nick = nick.trim();
        if nick.is_empty() {
            names.remove(n.as_str());
        } else {
            names.insert(n.to_string(), nick.into());
        }
        put(m, p, "soundNames", serde_json::Value::Object(names).to_string().into())
    });
    on!(on_hide, [n: SharedString, on: bool], |m, p| {
        let mut list: Vec<String> = serde_json::from_str(&p.s("soundHidden")).unwrap_or_default();
        list.retain(|x| x != n.as_str());
        if on {
            list.push(n.to_string());
        }
        put(m, p, "soundHidden", serde_json::json!(list).to_string().into())
    });
    on!(on_app_volume, [i: i32, playing: bool, v: f32], |m, p| m.stream_volume(p, i, playing, v as f64));
    on!(on_app_mute, [i: i32, playing: bool, v: bool], |m, _p| m.stream_mute(i, playing, v));
    on!(on_app_move, [i: i32, playing: bool, to: i32], |m, _p| m.stream_move(i, playing, to));
    on!(on_app_balance, [i: i32, playing: bool, b: f32], |m, p| m.stream_balance(p, i, playing, b as f64));
    on!(on_balance, [n: SharedString, b: f32], |m, p| m.set_balance(p, &n, b as f64));
    on!(on_fade, [n: SharedString, b: f32], |m, p| m.set_fade(p, &n, b as f64));
    on!(on_channel, [n: SharedString, i: i32, v: f32], |m, p| m.set_channel(p, &n, i.max(0) as usize, v as f64));
    on!(on_set_step, [v: i32], |m, p| put(m, p, "volumeStep", v.into()));
    on!(on_set_limit, [v: i32], |m, p| {
        put(m, p, "volumeMax", v.into());
        put(m, p, "volumeBoost", false.into())
    });
    on!(on_set_feedback, [v: bool], |m, p| put(m, p, "volumeFeedback", v.into()));
    on!(on_set_auto_switch, [v: bool], |m, p| put(m, p, "soundAutoSwitch", v.into()));
    on!(on_set_meters, [v: bool], |m, p| put(m, p, "soundMeters", v.into()));
    on!(on_reset_names, [], |m, p| {
        put(m, p, "soundNames", "{}".into());
        put(m, p, "soundHidden", "[]".into())
    });
    on!(on_restart, [], |m, _p| m.restart());
    on!(on_mixer, [], |m, _p| {
        match ["pavucontrol", "pwvucontrol", "pavucontrol-qt"].into_iter().find(|b| system::have(b)) {
            Some(b) => {
                let _ = std::process::Command::new(b).spawn();
            }
            None => m.last_error = "No mixer app is installed (pavucontrol or pwvucontrol).".into(),
        }
    });
}

/// Settings → Sound's equalizer and microphone effects: SoundEq.qml's
/// and EqGraph.qml's handlers. Each change is written to theme.json (the
/// shell rebuilds the chain from it when its make-up changes) and, when only
/// frequency, gain or Q moved, sent straight to the running filter.
fn wire_eq(ui: &AppWindow, st: &Rc<RefCell<State>>) {
    let g = ui.global::<EqLook>();
    let with = {
        let weak = ui.as_weak();
        let st = st.clone();
        Rc::new(move |f: &dyn Fn(&prefs::Prefs, &EqLook) -> Vec<(&'static str, serde_json::Value)>| {
            let Some(ui) = weak.upgrade() else { return };
            let mut s = st.borrow_mut();
            let g = ui.global::<EqLook>();
            let before = eq::bands(&s.c.p);
            let changes = f(&s.c.p, &g);
            let wrote = !changes.is_empty();
            for (k, v) in changes {
                if let Err(e) = s.c.p.set(k, v) {
                    s.snd.last_error = format!("Couldn't save the setting: {e}");
                }
            }
            // Ours: not an edit from elsewhere to draw the pane again for.
            s.seen = mtime();
            let after = eq::bands(&s.c.p);
            if wrote && hyprshell_kit::eqmath::structure(&before) == hyprshell_kit::eqmath::structure(&after) && !s.snd.eq_node.is_empty() {
                s.live.push(&s.snd.eq_node, eq::gains(&s.c.p));
            }
            if !after.iter().any(|b| b.id as i32 == g.get_selected()) && g.get_selected() >= 0 {
                g.set_selected(eq::first_id(&s.c.p));
            }
            let State { snd, c, .. } = &mut *s;
            snd.publish(&ui, &c.p);
            eq::publish(&ui, &c.p, snd);
        })
    };
    macro_rules! on {
        ($name:ident, [$($a:ident : $t:ty),*], |$p:ident, $g:ident| $body:expr) => {{
            let with = with.clone();
            g.$name(move |$($a: $t),*| {
                with(&|$p: &prefs::Prefs, $g: &EqLook| {
                    let _ = (&$p, &$g);
                    $body
                })
            });
        }};
    }
    let tell = |line: String| {
        let _ = tell_shell(&line);
    };
    use serde_json::json;
    on!(on_set_enabled, [v: bool], |_p, _g| {
        if v {
            tell("fxRetry eq".into());
        }
        vec![("eqEnabled", json!(v))]
    });
    on!(on_retry, [], |_p, _g| {
        tell("fxRetry eq".into());
        vec![]
    });
    on!(on_set_scope, [apps: bool], |_p, _g| vec![("eqScope", json!(if apps { "apps" } else { "all" }))]);
    on!(on_toggle_app, [key: SharedString, on: bool], |p, _g| eq::set_app(p, &key, on));
    on!(on_apply_preset, [name: SharedString, user: bool], |p, g| {
        let out = eq::apply_preset(p, &name, user);
        // The first band of the new set picked.
        let first = out.iter().find(|x| x.0 == "peqBands").map(|x| hyprshell_kit::eqmath::parse(x.1.as_str().unwrap_or("[]"))).and_then(|l| l.first().map(|b| b.id as i32)).unwrap_or(-1);
        g.set_selected(first);
        out
    });
    on!(on_delete_preset, [name: SharedString], |p, _g| eq::delete_preset(p, &name));
    on!(on_save, [], |p, g| {
        let out = eq::save_preset(p, &g.get_save_name());
        if !out.is_empty() {
            g.set_saving(false);
        }
        out
    });
    {
        let st = st.clone();
        g.on_exists(move |name| {
            let Ok(s) = st.try_borrow() else { return false };
            eq::user_names(&s.c.p).iter().any(|n| n == name.trim())
        });
    }
    on!(on_reset, [], |_p, g| {
        g.set_selected(-1);
        eq::reset()
    });
    on!(on_pick, [_id: i32], |_p, _g| vec![]);
    on!(on_resized, [], |_p, _g| vec![]);
    on!(on_drag, [id: i32, x: f32, y: f32], |p, _g| eq::drag(p, id, x as f64, y as f64));
    on!(on_add_at, [x: f32, y: f32], |p, g| {
        let (f, gain) = eq::at(p, x as f64, y as f64);
        let (id, out) = eq::add_band(p, f, gain);
        if let Some(id) = id {
            g.set_selected(id);
        }
        out
    });
    on!(on_add_gap, [], |p, g| {
        let (id, out) = eq::add_in_gap(p);
        if let Some(id) = id {
            g.set_selected(id);
        }
        out
    });
    on!(on_flatten, [id: i32], |p, _g| eq::set_band(p, id, &json!({ "gain": 0 })));
    on!(on_toggle, [id: i32], |p, _g| eq::toggle_band(p, id));
    on!(on_q_steps, [id: i32, n: i32], |p, _g| eq::q_steps(p, id, n));
    on!(on_remove, [], |p, g| eq::remove_band(p, g.get_selected()));
    on!(on_set_type, [i: i32], |p, g| match hyprshell_kit::eqmath::TYPES.get(i.max(0) as usize) {
        Some(t) => eq::set_band(p, g.get_selected(), &json!({ "type": t.0 })),
        None => vec![],
    });
    on!(on_set_on, [v: bool], |p, g| eq::set_band(p, g.get_selected(), &json!({ "on": v })));
    on!(on_set_slope, [i: i32], |p, g| match hyprshell_kit::eqmath::SLOPES.get(i.max(0) as usize) {
        Some(s) => eq::set_band(p, g.get_selected(), &json!({ "slope": s })),
        None => vec![],
    });
    on!(on_nudge, [which: i32, n: i32, fine: bool], |p, g| eq::nudge(p, g.get_selected(), which, n, fine));
    on!(on_typed, [which: i32, text: SharedString], |p, g| eq::typed(p, g.get_selected(), which, &text));
    on!(on_set_preamp, [db: f32], |_p, _g| eq::set_preamp(db as f64));
    on!(on_auto, [], |p, _g| eq::auto_preamp(p));
    on!(on_set_range, [r: i32], |_p, _g| vec![("eqRange", json!(r))]);
    on!(on_set_ns, [v: bool], |_p, _g| {
        if v {
            tell("fxRetry ns".into());
        }
        vec![("nsEnabled", json!(v))]
    });
    {
        let weak = ui.as_weak();
        let st = st.clone();
        g.on_set_ns_threshold(move |v| {
            let Some(ui) = weak.upgrade() else { return };
            let mut s = st.borrow_mut();
            let v = (v as f64).clamp(0.0, 99.0).round();
            if (s.c.p.f("nsThreshold") - v).abs() < 0.5 {
                return;
            }
            let _ = s.c.p.set("nsThreshold", json!(v));
            s.seen = mtime();
            if !s.snd.ns_node.is_empty() {
                s.live.push(&s.snd.ns_node, eq::ns_params(&s.c.p));
            }
            let State { snd, c, .. } = &mut *s;
            eq::publish(&ui, &c.p, snd);
        });
    }
    on!(on_ns_retry, [], |_p, _g| {
        tell("fxRetry ns".into());
        vec![]
    });
    {
        let st = st.clone();
        g.on_listen(move |on| {
            let src = st.borrow().snd.inspected_name(false);
            let _ = tell_shell(&if on && !src.is_empty() { format!("fxListen {src}") } else { "fxListen".into() });
        });
    }
}

/// The enterprise form's server check, method and inner method.
fn enterprise_basics(ui: &AppWindow) -> (String, String, String) {
    let w = ui.global::<Wifi>();
    let ca = if w.get_f_ca() == "file" {
        let f = w.get_f_ca_file();
        if f.is_empty() { "none".to_string() } else { f.to_string() }
    } else {
        w.get_f_ca().to_string()
    };
    (ca, w.get_f_eap().to_string(), w.get_f_phase2().to_string())
}

/// The rest of the enterprise form: certificates, PEAP version, FAST, the
/// key management, and (for a new network) the general settings.
fn enterprise_extra(ui: &AppWindow, key: &str, general: Option<serde_json::Value>) -> serde_json::Value {
    let w = ui.global::<Wifi>();
    let mut x = serde_json::json!({
        "keyMgmt": if key == "wpa-eap-suite-b-192" { "wpa-eap-suite-b-192" } else { "wpa-eap" },
        "clientCert": w.get_f_client_cert().as_str(),
        "privateKey": w.get_f_private_key().as_str(),
        "keySecret": w.get_f_key_pass().as_str(),
        "peapVer": w.get_f_peap_ver().as_str(),
        "pacFile": w.get_f_pac_file().as_str(),
        "fastProv": w.get_f_fast_prov().as_str(),
    });
    if let Some(g) = general {
        x["general"] = g;
    }
    x
}

/// The live wallpapers and their stills, off the window's thread; the
/// stills still to make are made after, and then looked for again.
fn scan_videos(st: &mut State) {
    st.videos.scanning = true;
    let (folders, files) = rows::live_sources_pub(&st.c.p);
    let weak = st.weak.clone();
    std::thread::spawn(move || {
        let (list, todo, ff) = gallery::scan(&folders, &files);
        let made = ff && !todo.is_empty();
        let (f2, x2, w2) = (folders.clone(), files.clone(), weak.clone());
        let _ = weak.upgrade_in_event_loop(move |ui| deliver_videos(&ui, list, ff));
        if made && gallery::make_thumbs(&todo) {
            let (list, _, ff) = gallery::scan(&f2, &x2);
            let _ = w2.upgrade_in_event_loop(move |ui| deliver_videos(&ui, list, ff));
        }
    });
}

thread_local! {
    static STATE: RefCell<Option<std::rc::Weak<RefCell<State>>>> = const { RefCell::new(None) };
}

/// What face unlock's threads say, delivered on the window's own thread.
fn face_notify(weak: slint::Weak<AppWindow>) -> face::Notify {
    std::sync::Arc::new(move |m| {
        let _ = weak.upgrade_in_event_loop(move |ui| {
            STATE.with(|s| {
                let Some(st) = s.borrow().as_ref().and_then(|w| w.upgrade()) else { return };
                let mut st = st.borrow_mut();
                let redraw = st.face.on_msg(m);
                if st.c.ui.pane != "Login screen" {
                    return;
                }
                if redraw {
                    show(&ui, &mut st);
                } else {
                    // Another frame of the webcam: only the picture.
                    publish_face_frame(&ui, &mut st.face);
                }
            });
        });
    })
}

const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

fn publish_face_frame(ui: &AppWindow, face: &mut face::Face) {
    if !face.frame_new {
        return;
    }
    face.frame_new = false;
    let g = ui.global::<FaceUi>();
    match &face.frame {
        Some(f) if f.len() == face::FRAME_W * face::FRAME_H * 3 => {
            let buf = slint::SharedPixelBuffer::<slint::Rgb8Pixel>::clone_from_slice(f, face::FRAME_W as u32, face::FRAME_H as u32);
            g.set_frame(slint::Image::from_rgb8(buf));
            g.set_seeing(true);
        }
        _ => g.set_seeing(false),
    }
}

/// The face panel: what it says and does, from face unlock's state.
fn publish_face(ui: &AppWindow, st: &mut State) {
    let f = st.face.snapshot();
    let g = ui.global::<FaceUi>();
    let faces = f.faces();
    let busy_adding = f.adding || f.just_added;
    g.set_state(if f.just_added { "found" } else if f.add_failed { "failed" } else if f.adding { "looking" } else { "idle" }.into());
    g.set_headline(
        if f.just_added {
            "All set"
        } else if f.add_failed {
            "Howdy didn't get a good look"
        } else if f.adding {
            "Keep looking at the camera"
        } else if faces > 0 {
            "Howdy knows your face"
        } else {
            "Set up your face"
        }
        .into(),
    );
    let seeing = st.face.picture();
    g.set_detail(
        if f.add_failed {
            f.status.clone()
        } else if f.adding {
            if f.adding_alone {
                "The infrared camera is learning your face. The webcam can't run beside it on this laptop".to_string()
            } else if !seeing && !f.preview_error.is_empty() {
                f.preview_error.clone()
            } else if f.recording {
                "The infrared camera is learning your face. Hold still, an arm's length away".to_string()
            } else if seeing {
                "Centre your face in the circle".to_string()
            } else {
                "Starting the webcam…".to_string()
            }
        } else if faces > 0 {
            "It unlocks for you at a glance. Wear glasses sometimes? Add that as an alternative look".to_string()
        } else {
            "Add your face and Howdy unlocks for you at a glance".to_string()
        }
        .into(),
    );
    g.set_add_label(if f.adding { "Adding…" } else if faces > 0 { "Add my face again" } else { "Add my face" }.into());
    let can = !f.busy && !busy_adding;
    g.set_can_add(can);
    g.set_can_alt(can && faces != 0);
    g.set_can_remove(can);
    let looks: Vec<FaceLook> = f
        .looks
        .iter()
        .flatten()
        .map(|l| {
            let (y, mo, d, h, mi, _) = hyprshell_kit::local(l.time);
            let sub = format!(
                "Added {d} {} {y}, {h:02}:{mi:02}{}",
                MONTHS[(mo as usize).saturating_sub(1).min(11)],
                if !f.webcam_check { "" } else if l.webcam { " · infrared and webcam" } else { " · infrared only: add it again for the webcam" }
            );
            FaceLook { id: l.id as i32, label: l.label.clone().into(), sub: sub.into() }
        })
        .collect();
    g.set_looks(ModelRc::new(VecModel::from(looks)));
    g.set_foot(
        format!(
            "{}An alternative look is another set of pictures of you that Howdy checks too, and it unlocks for whichever you match: add one with glasses or without, in a cap, with a beard, in daylight and in lamplight.",
            if f.looks.is_none() && faces != 0 { "Howdy keeps your looks where only root can read them, so they can't be listed here. " } else { "" }
        )
        .into(),
    );
    st.face.frame_new = true;
    publish_face_frame(ui, &mut st.face);
    g.set_seeing(seeing);
}

/// The panel's own buttons.
fn wire_face(ui: &AppWindow, st: &Rc<RefCell<State>>) {
    let g = ui.global::<FaceUi>();
    {
        let (st, weak) = (st.clone(), ui.as_weak());
        g.on_add(move |alt| {
            st.borrow_mut().face.command(face::Cmd::AddFace(alt));
            if let Some(ui) = weak.upgrade() {
                show(&ui, &mut st.borrow_mut());
            }
        });
    }
    {
        let (st, weak) = (st.clone(), ui.as_weak());
        g.on_remove(move |id| {
            st.borrow_mut().face.command(face::Cmd::RemoveLook(id as i64));
            if let Some(ui) = weak.upgrade() {
                show(&ui, &mut st.borrow_mut());
            }
        });
    }
}

fn deliver_videos(ui: &AppWindow, list: Vec<gallery::Video>, ff: bool) {
    STATE.with(|s| {
        let Some(st) = s.borrow().as_ref().and_then(|w| w.upgrade()) else { return };
        let mut st = st.borrow_mut();
        st.videos.list = list;
        st.videos.ffmpeg = ff;
        st.videos.scanned = true;
        st.videos.scanning = false;
        let cur = rows::live_current(&st.c);
        st.videos.publish(ui, &cur);
    });
}

/// Settings → Updates' check, off the window's thread (it fetches).
fn check_updates(st: &mut State) {
    if st.upd.checking {
        return;
    }
    st.upd.checking = true;
    let weak = st.weak.clone();
    std::thread::spawn(move || {
        let r = updates::run_check();
        let _ = weak.upgrade_in_event_loop(move |ui| {
            STATE.with(|s| {
                let Some(st) = s.borrow().as_ref().and_then(|w| w.upgrade()) else { return };
                let mut st = st.borrow_mut();
                st.upd.take(r);
                st.upd.publish(&ui);
            });
        });
    });
}

/// The galleries' own clicks.
fn wire_galleries(ui: &AppWindow, st: &Rc<RefCell<State>>, settle: Rc<dyn Fn()>) {
    STATE.with(|s| *s.borrow_mut() = Some(Rc::downgrade(st)));
    let a = ui.global::<AnimLook>();
    {
        let (st, settle) = (st.clone(), settle.clone());
        a.on_pick_style(move |k| {
            {
                let c = &mut st.borrow_mut().c;
                c.set("wallpaperStyle", serde_json::json!(k.as_str()));
                c.set("animLastStyle", serde_json::json!(k.as_str()));
                if k == "topo" {
                    c.set("topoDrift", serde_json::json!(true));
                }
            }
            settle();
        });
    }
    {
        let (st, settle) = (st.clone(), settle.clone());
        a.on_pick_palette(move |k| {
            {
                let c = &mut st.borrow_mut().c;
                for (key, v) in anim::choose_palette(&c.p, &k) {
                    c.set(key, v);
                }
            }
            settle();
        });
    }
    // Notifications → Focus and Apps.
    let f = ui.global::<FocusLook>();
    let put = {
        let (st, settle) = (st.clone(), settle.clone());
        Rc::new(move |change: &dyn Fn(&rows::Ctx) -> Vec<(&'static str, serde_json::Value)>| {
            {
                let c = &mut st.borrow_mut().c;
                for (k, v) in change(c) {
                    c.set(k, v);
                }
            }
            settle();
        })
    };
    macro_rules! focus_on {
        ($name:ident, [$($a:ident : $t:ty),*], |$c:ident| $body:expr) => {{
            let put = put.clone();
            f.$name(move |$($a: $t),*| put(&|$c: &rows::Ctx| $body));
        }};
    }
    focus_on!(on_add, [], |c| vec![focus::add(&c.p)]);
    focus_on!(on_remove, [id: i32], |c| vec![focus::remove(&c.p, id)]);
    focus_on!(on_rename, [id: i32, name: SharedString], |c| {
        let n = name.trim().to_string();
        vec![focus::update(&c.p, id, |o| {
            o.insert("name".into(), serde_json::json!(if n.is_empty() { "Focus" } else { n.as_str() }));
        })]
    });
    focus_on!(on_set_on, [id: i32, on: bool], |c| vec![focus::update(&c.p, id, |o| {
        o.insert("on".into(), serde_json::json!(on));
    })]);
    focus_on!(on_step, [id: i32, from: bool, d: i32], |c| vec![focus::update(&c.p, id, |o| {
        let k = if from { "from" } else { "to" };
        let now = o.get(k).and_then(|v| v.as_str()).unwrap_or("00:00").to_string();
        o.insert(k.into(), serde_json::json!(focus::bump(&now, d)));
    })]);
    focus_on!(on_day, [id: i32, chip: i32], |c| vec![focus::update(&c.p, id, |o| {
        // Chips are Monday first; the days are 0 = Sunday.
        let day = ((chip + 1) % 7) as i64;
        let mut days: Vec<i64> = o.get("days").and_then(|v| v.as_array()).into_iter().flatten().filter_map(|v| v.as_i64()).collect();
        if days.contains(&day) {
            days.retain(|d| *d != day);
        } else {
            days.push(day);
            days.sort();
        }
        o.insert("days".into(), serde_json::json!(days));
    })]);
    focus_on!(on_set_rule, [app: SharedString, r: SharedString], |c| vec![focus::set_rule(&c.p, &app, &r)]);
    focus_on!(on_forget, [app: SharedString], |c| focus::forget(&c.p, &app));

    // Display → Arrangement.
    let mm = ui.global::<MonMap>();
    {
        let (st, settle) = (st.clone(), settle.clone());
        mm.on_pick(move |n| {
            st.borrow_mut().c.ui.display_pick = n.to_string();
            settle();
        });
    }
    {
        let (st, weak) = (st.clone(), ui.as_weak());
        mm.on_drag(move |n, x, y| {
            let Some(ui) = weak.upgrade() else { return };
            let g = ui.global::<MonMap>();
            if let Some((lx, ly, lw, lh)) = monmap::landing(&monmap::monitors(), &n, x as f64, y as f64) {
                g.set_dragging(n.clone());
                g.set_lx(lx as f32);
                g.set_ly(ly as f32);
                g.set_lw(lw as f32);
                g.set_lh(lh as f32);
                st.borrow_mut().landing = Some((n.to_string(), lx, ly));
            }
        });
    }
    {
        let (st, settle, weak) = (st.clone(), settle.clone(), ui.as_weak());
        mm.on_drop(move |n| {
            if let Some(ui) = weak.upgrade() {
                ui.global::<MonMap>().set_dragging(SharedString::new());
            }
            let land = st.borrow_mut().landing.take();
            if let Some((name, x, y)) = land.filter(|l| l.0 == n.as_str()) {
                let moved = monmap::monitors().iter().find(|m| m.name == name).is_some_and(|m| m.x != x || m.y != y);
                if moved {
                    monmap::place(&mut st.borrow_mut().c, &name, x, y);
                }
            }
            settle();
        });
    }
    {
        let (st, settle, weak) = (st.clone(), settle.clone(), ui.as_weak());
        let timer = Rc::new(slint::Timer::default());
        mm.on_identify(move || {
            let names: Vec<String> = monmap::monitors().into_iter().map(|m| m.name).collect();
            st.borrow_mut().c.ui.tell.push(format!("identify {}", names.join(",")));
            if let Some(ui) = weak.upgrade() {
                ui.global::<MonMap>().set_identifying(true);
            }
            let w2 = weak.clone();
            timer.start(slint::TimerMode::SingleShot, Duration::from_millis(2500), move || {
                if let Some(ui) = w2.upgrade() {
                    ui.global::<MonMap>().set_identifying(false);
                }
            });
            settle();
        });
    }

    // Updates.
    let u = ui.global::<Upd>();
    {
        let (st, weak) = (st.clone(), ui.as_weak());
        u.on_check(move || {
            let mut s = st.borrow_mut();
            check_updates(&mut s);
            if let Some(ui) = weak.upgrade() {
                s.upd.publish(&ui);
            }
        });
    }
    {
        let st = st.clone();
        u.on_update(move |id| st.borrow_mut().upd.update(&id));
    }
    {
        let (st, weak) = (st.clone(), ui.as_weak());
        u.on_toggle(move |id| {
            let mut s = st.borrow_mut();
            if !s.upd.open.remove(id.as_str()) {
                s.upd.open.insert(id.to_string());
            }
            if let Some(ui) = weak.upgrade() {
                s.upd.publish(&ui);
            }
        });
    }

    let g = ui.global::<Gal>();
    {
        let (st, settle) = (st.clone(), settle.clone());
        g.on_pick(move |dir| {
            rows::live_pick(&mut st.borrow_mut().c, &dir);
            settle();
        });
    }
    {
        let (st, weak) = (st.clone(), ui.as_weak());
        g.on_search(move || {
            let Some(ui) = weak.upgrade() else { return };
            let mut s = st.borrow_mut();
            let cur = rows::live_current(&s.c);
            s.videos.publish(&ui, &cur);
        });
    }
}

// ── HDR calibration's full-screen windows ──────────────────────────────
/// Full screen, asked again once the window is up: winit makes the window
/// on the event loop's next turn, and a request before that is lost.
fn fullscreen_soon(w: slint::Weak<impl slint::ComponentHandle + 'static>) {
    slint::Timer::single_shot(Duration::from_millis(120), move || {
        if let Some(w) = w.upgrade() {
            w.window().set_fullscreen(true);
        }
    });
}

thread_local! {
    static HDR: RefCell<(Option<(HdrCal, hdrcal::Cal)>, Option<HdrPat>)> = const { RefCell::new((None, None)) };
    static HDR_SHOW: slint::Timer = slint::Timer::default();
}

/// The calibration's state into its window.
fn hdr_publish(w: &HdrCal, c: &hdrcal::Cal) {
    w.set_output(c.output.clone().into());
    w.set_step(c.step);
    w.set_last(hdrcal::LAST);
    w.set_heading(hdrcal::TITLES[c.step as usize].into());
    w.set_body(c.body().into());
    w.set_grey(c.grey() as f32);
    w.set_frac(c.frac() as f32);
    w.set_value_text(c.value_text().into());
    w.set_summary(c.summary().into());
    w.set_show_before(c.show_before);
}

/// What the display is told, once the slider settles (200 ms).
fn hdr_show_soon(st: &Rc<RefCell<State>>) {
    let st = Rc::downgrade(st);
    HDR_SHOW.with(|t| {
        t.start(slint::TimerMode::SingleShot, Duration::from_millis(200), move || {
            let Some(st) = st.upgrade() else { return };
            HDR.with(|h| {
                if let Some((_, c)) = h.borrow().0.as_ref() {
                    c.show(&st.borrow().c.p);
                }
            });
        })
    });
}

fn hdr_close() {
    HDR_SHOW.with(|t| t.stop());
    HDR.with(|h| {
        if let Some((w, _)) = h.borrow_mut().0.take() {
            let _ = w.hide();
        }
    });
}

/// Opens Calibrate or the test pattern on `output`: Hyprland is asked to
/// focus that screen, so the window opens there, full screen.
fn open_hdr(st: &Rc<RefCell<State>>, output: &str, pattern: bool) {
    hypr::focus_monitor(output);
    if pattern {
        let Ok(w) = HdrPat::new() else { return };
        w.on_done(|| {
            HDR.with(|h| {
                if let Some(p) = h.borrow_mut().1.take() {
                    let _ = p.hide();
                }
            })
        });
        let _ = w.show();
        fullscreen_soon(w.as_weak());
        HDR.with(|h| h.borrow_mut().1 = Some(w));
        return;
    }
    hdr_close();
    let Ok(w) = HdrCal::new() else { return };
    let cal = hdrcal::Cal::new(&st.borrow().c.p, output);
    hdr_publish(&w, &cal);
    // with(f): the calibration and its window, changed, drawn again.
    let with = {
        let st = st.clone();
        move |f: &dyn Fn(&mut hdrcal::Cal, &mut State) -> bool| {
            let close = HDR.with(|h| {
                let mut h = h.borrow_mut();
                let Some((w, c)) = h.0.as_mut() else { return false };
                let close = f(c, &mut st.borrow_mut());
                hdr_publish(w, c);
                close
            });
            if close {
                hdr_close();
            }
        }
    };
    let with = Rc::new(with);
    {
        let (with, st) = (with.clone(), st.clone());
        w.on_next(move || {
            let st2 = st.clone();
            with(&|c, s| {
                if c.step < hdrcal::LAST {
                    c.step += 1;
                    c.show_before = false;
                    hdr_show_soon(&st2);
                    false
                } else {
                    c.save(&mut s.c.p);
                    true
                }
            })
        });
    }
    {
        let (with, st) = (with.clone(), st.clone());
        w.on_back(move || {
            let st2 = st.clone();
            with(&|c, _| {
                if c.step > 0 {
                    c.step -= 1;
                    c.show_before = false;
                    hdr_show_soon(&st2);
                }
                false
            })
        });
    }
    {
        let with = with.clone();
        w.on_cancel(move || {
            with(&|c, s| {
                c.cancel(&s.c.p);
                true
            })
        });
    }
    {
        let (with, st) = (with.clone(), st.clone());
        w.on_set_frac(move |f| {
            let st2 = st.clone();
            with(&|c, _| {
                c.set_frac(f as f64);
                // Saturation is a setting of the display, not of the
                // pattern: sent once the slider settles.
                if c.step == 4 {
                    hdr_show_soon(&st2);
                }
                false
            })
        });
    }
    {
        let (with, st) = (with.clone(), st.clone());
        w.on_nudge(move |d| {
            let st2 = st.clone();
            with(&|c, _| {
                c.nudge(d);
                if c.step == 4 {
                    hdr_show_soon(&st2);
                }
                false
            })
        });
    }
    {
        let (with, st) = (with.clone(), st.clone());
        w.on_before(move |b| {
            let st2 = st.clone();
            with(&|c, _| {
                c.show_before = b;
                hdr_show_soon(&st2);
                false
            })
        });
    }
    // Closed some other way: as Cancel.
    {
        let with = with.clone();
        w.window().on_close_requested(move || {
            with(&|c, s| {
                c.cancel(&s.c.p);
                true
            });
            slint::CloseRequestResponse::HideWindow
        });
    }
    let _ = w.show();
    fullscreen_soon(w.as_weak());
    HDR.with(|h| h.borrow_mut().0 = Some((w, cal)));
}


/// Frosted menus: when one opens, the window is looked at and the part under
/// it blurred (frost.rs); what the menu draws behind its tint.
fn wire_frost(ui: &AppWindow, st: &Rc<RefCell<State>>) {
    let (weak, st) = (ui.as_weak(), st.clone());
    ui.global::<Frost>().on_request(move |x, y, w, h| {
        let Some(ui) = weak.upgrade() else { return };
        let (blurred, translucency) = {
            let s = st.borrow();
            (s.c.p.b("menuBlur"), s.c.p.f("menuTranslucency").clamp(0.0, 60.0))
        };
        let g = ui.global::<Frost>();
        g.set_alpha((1.0 - translucency / 100.0) as f32);
        if !blurred {
            g.set_blurred(false);
            return;
        }
        let scale = ui.window().scale_factor();
        match ui.window().take_snapshot() {
            Ok(snap) => match frost::behind(&snap, scale, x, y, w, h, 7.0 * scale) {
                Some(img) => {
                    g.set_image(img);
                    g.set_blurred(true);
                }
                None => g.set_blurred(false),
            },
            Err(_) => g.set_blurred(false),
        }
    });
}


/// What the keyring script's threads say, delivered on the window's own thread.
fn keyring_notify(weak: slint::Weak<AppWindow>) -> keyring::Notify {
    std::sync::Arc::new(move |m| {
        let _ = weak.upgrade_in_event_loop(move |ui| {
            STATE.with(|s| {
                let Some(st) = s.borrow().as_ref().and_then(|w| w.upgrade()) else { return };
                let mut st = st.borrow_mut();
                st.keyring.on_msg(m);
                if st.c.ui.pane == "Login screen" {
                    show(&ui, &mut st);
                }
            });
        });
    })
}
