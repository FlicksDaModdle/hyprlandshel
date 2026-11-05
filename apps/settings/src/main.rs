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

mod hypr;
mod prefs;
mod rows;
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
                        s.c.set(&key, serde_json::json!(path.display().to_string()));
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

    // Edits made elsewhere: shown within a second.
    let poll = slint::Timer::default();
    {
        let weak = ui.as_weak();
        let st = st.clone();
        poll.start(slint::TimerMode::Repeated, Duration::from_millis(1000), move || {
            let Some(ui) = weak.upgrade() else { return };
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
