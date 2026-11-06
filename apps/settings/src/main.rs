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

mod bt;
mod daemon;
mod display;
mod net;
mod hypr;
mod prefs;
mod rows;
mod sound;
mod system;

use hyprshell_kit as kit;
use rows::{Ctx, Entry, Spec, Ui, Val};
use slint::platform::Key;
use slint::{ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

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
    g.set_rows(ModelRc::new(VecModel::from(specs.iter().map(|r| r.row.clone()).collect::<Vec<_>>())));
    st.specs = specs;
    // The live panels: what they show, kept up only while they're up.
    let (on_net, on_bt, on_snd) = (pane == "Network", pane == "Bluetooth", pane == "Sound");
    if on_net || on_bt || on_snd || st.daemon.is_some() {
        let (mut net, mut bt, mut snd) = (std::mem::take(&mut st.net), std::mem::take(&mut st.bt), std::mem::take(&mut st.snd));
        net.watch(st.daemon(), on_net);
        bt.watch(st.daemon(), on_bt);
        snd.watch(st.daemon(), on_snd);
        if on_snd {
            snd.publish(ui, &st.c.p);
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
            let (toast, tell, pick) = {
                let mut s = st.borrow_mut();
                (s.c.ui.toast.take(), std::mem::take(&mut s.c.ui.tell), s.c.ui.pick.take())
            };
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
                    ui.global::<Prefs>().set_rows(ModelRc::new(VecModel::from(rows)));
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
            if evs.iter().fold(false, |a, ev| s.snd.event(ev) || a) && s.c.ui.pane == "Sound" {
                s.snd.publish(&ui, &s.c.p);
            }
            s.net = net;
            s.bt = bt;
        });
    }
    wire_wifi(&ui, &st);
    wire_bt(&ui, &st);
    wire_sound(&ui, &st);

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
            m.publish(&ui, &s.c.p);
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
    on!(on_use, [n: SharedString], |m, _p| m.set_default(&n));
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
