//! Settings for Hyprshell's Rust shell: the Quickshell Settings' pages that
//! the Rust shell reads (appearance, motion, wallpaper, bar, dock, launcher,
//! Alt+Tab, notifications, sound), plus the way to the control center's
//! Wi-Fi and Bluetooth lists and what this computer is.
//!
//! Everything is a key in theme.json, the file both shells and every app
//! follow: a change is written there (the rest of the file left as it is)
//! and shows everywhere at once. Edits made elsewhere (the Quickshell
//! Settings, the control center, by hand) show here within a second.
//!
//!   hyprshell-settings [page]     open on a page: appearance, motion,
//!                                 wallpaper, bar, dock, launcher, alttab,
//!                                 notifications, sound, network, bluetooth,
//!                                 about

use hyprshell_kit as kit;
use serde_json::{json, Value};
use slint::{Color, ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, SystemTime};

slint::include_modules!();

/// How a row of the schema is shown and stored.
enum Kind {
    Section,
    Switch(bool),
    /// Default, minimum, maximum, step, unit.
    Slider(f64, f64, f64, f64, &'static str),
    /// Default, and (label, stored value) for each option.
    Choice(&'static str, &'static [(&'static str, &'static str)]),
    /// Drawn by `custom` below.
    Custom,
}

struct Item {
    key: &'static str,
    label: &'static str,
    help: &'static str,
    kind: Kind,
}

const fn sec(label: &'static str, help: &'static str) -> Item {
    Item { key: "", label, help, kind: Kind::Section }
}
const fn sw(key: &'static str, label: &'static str, help: &'static str, def: bool) -> Item {
    Item { key, label, help, kind: Kind::Switch(def) }
}
#[allow(clippy::too_many_arguments)]
const fn sl(key: &'static str, label: &'static str, help: &'static str, def: f64, min: f64, max: f64, step: f64, unit: &'static str) -> Item {
    Item { key, label, help, kind: Kind::Slider(def, min, max, step, unit) }
}
const fn ch(key: &'static str, label: &'static str, help: &'static str, def: &'static str, opts: &'static [(&'static str, &'static str)]) -> Item {
    Item { key, label, help, kind: Kind::Choice(def, opts) }
}
const fn custom(key: &'static str, label: &'static str, help: &'static str) -> Item {
    Item { key, label, help, kind: Kind::Custom }
}

/// (id, label, icon, group heading on the first of a group, blurb)
const PAGES: &[(&str, &str, &str, &str, &str)] = &[
    ("appearance", "Appearance", "palette", "PERSONALIZATION", "The theme, the accent colour and how the shell's surfaces look."),
    ("motion", "Motion", "sparkle", "", "How fast things move, and how much they bounce."),
    ("wallpaper", "Wallpaper", "image", "", "A picture behind the desktop, a video, or the theme's tinted gradient."),
    ("bar", "Bar", "panelsTopLeft", "TASKBAR & MENUS", "The bar along the top of each screen."),
    ("dock", "Dock", "dock", "", "The dock along the bottom: its size, what it shows and when it hides."),
    ("launcher", "Launcher", "grid", "", "The app launcher (Super)."),
    ("alttab", "Alt+Tab", "layout", "", "Switching windows with the keyboard."),
    ("notifications", "Notifications", "bell", "SYSTEM", "Banners, the list behind the bell, and Do not disturb."),
    ("sound", "Sound", "volume", "", "The volume keys."),
    ("network", "Network", "wifi", "CONNECTIONS", "Wi-Fi networks are joined from the control center's list."),
    ("bluetooth", "Bluetooth", "bluetooth", "", "Devices are paired and connected from the control center's list."),
    ("about", "About", "info", "ABOUT", "This computer and this shell."),
];

const THEME: &[(&str, &str)] = &[("Light", "light"), ("Dark", "dark"), ("Auto", "auto")];
const TINT: &[(&str, &str)] = &[("Warm", "Warm"), ("Neutral", "Neutral"), ("Cool", "Cool")];
const MOTION: &[(&str, &str)] = &[("Springy", "springy"), ("Smooth", "smooth")];
const SCALING: &[(&str, &str)] = &[("Fill", "fill"), ("Fit", "fit"), ("Stretch", "stretch")];
const DOCK_SCOPE: &[(&str, &str)] = &[("This workspace", "workspace"), ("Every window", "all")];
const TAB_MOD: &[(&str, &str)] = &[("Alt", "ALT"), ("Super", "SUPER"), ("Ctrl", "CTRL")];
const TAB_SCOPE: &[(&str, &str)] = &[("Workspace", "workspace"), ("Monitor", "monitor"), ("All", "all")];
const TAB_STYLE: &[(&str, &str)] = &[("Pictures", "thumbnails"), ("Icons", "icons"), ("List", "list")];

/// Appearance.qml's accentPresets: (light, dark).
const ACCENTS: &[(&str, &str)] = &[("#ec3013", "#ff563c"), ("#ae1800", "#e8452b"), ("#2d2b2b", "#d7d3d3"), ("#7c1405", "#c94b39")];

fn schema(page: &str) -> Vec<Item> {
    match page {
        "appearance" => vec![
            sec("THEME", ""),
            ch("theme", "Mode", "Auto follows the time of day", "light", THEME),
            custom("accent", "Accent colour", "Buttons, selections and the bar's highlights"),
            custom("customAccent", "Your own colour", "A colour such as #3b6ef5; press Enter to use it"),
            sw("accentFromWallpaper", "Accent from the wallpaper", "Take the accent from the picture behind the desktop", false),
            sec("SURFACES", ""),
            ch("tint", "Tint", "The tone of the gradient ground and the panels", "Warm", TINT),
            sl("translucency", "Translucency", "How much shows through panels", 50.0, 0.0, 100.0, 5.0, " %"),
            sl("rounding", "Rounding", "How round corners are", 100.0, 0.0, 160.0, 5.0, " %"),
            sl("fontScale", "Text size", "Everywhere in the shell and its apps", 100.0, 75.0, 150.0, 5.0, " %"),
        ],
        "motion" => vec![
            sec("ANIMATION", ""),
            ch("motionStyle", "Style", "Springy overshoots and settles; smooth eases in", "springy", MOTION),
            sl("animSpeed", "Speed", "0 turns animation off", 100.0, 0.0, 250.0, 5.0, " %"),
            sl("motionBounce", "Bounce", "How far springy motion overshoots", 100.0, 0.0, 200.0, 5.0, " %"),
            sw("panelsGrow", "Panels grow from their button", "Rather than only fading in", true),
        ],
        "wallpaper" => vec![
            sec("PICTURE", ""),
            custom("wallpaper", "Picture", ""),
            sec("LIVE WALLPAPER", "A video played behind the desktop with mpvpaper, over the picture."),
            custom("liveWallpaper", "Video", ""),
            ch("liveScaling", "Scaling", "Fill crops to the screen; fit shows it whole", "fill", SCALING),
            sw("liveSound", "Sound", "Play the video's sound", false),
            sl("liveVolume", "Volume", "With sound on", 50.0, 0.0, 100.0, 5.0, " %"),
        ],
        "bar" => vec![
            sec("SIZE", ""),
            sl("barHeight", "Height", "", 40.0, 32.0, 56.0, 1.0, " px"),
            sl("barFontSize", "Text", "", 12.0, 10.0, 18.0, 1.0, " px"),
            sl("barIcon", "Icons", "", 100.0, 60.0, 180.0, 5.0, " %"),
            sl("workspaceScale", "Workspace switcher", "", 100.0, 60.0, 160.0, 5.0, " %"),
            sec("WHAT IT SHOWS", ""),
            sw("clock24", "24-hour clock", "", true),
            sw("showTray", "Tray icons", "Apps running in the background", true),
            sw("badges", "Counts", "Unread notifications on the bell", true),
            sw("updatesInBar", "Updates", "When there are packages to update", true),
            sw("mailInBar", "Mail", "Unread mail, while Mail runs", true),
        ],
        "dock" => vec![
            sec("SIZE", ""),
            sl("dockSize", "Size", "", 42.0, 34.0, 58.0, 1.0, " px"),
            sl("dockIcon", "Icons", "Of the tile", 50.0, 30.0, 72.0, 1.0, " %"),
            sl("dockGap", "Gap", "From the screen's edge", 16.0, 0.0, 40.0, 1.0, " px"),
            sec("WHAT IT SHOWS", ""),
            ch("dockScope", "Windows", "Which running apps get a tile", "workspace", DOCK_SCOPE),
            sw("dockLabels", "Names", "The app's name over its tile", true),
            sw("dockPreviews", "Window previews", "On hover", true),
            sw("dockDesktopTile", "Show desktop", "A tile that hides every window", true),
            sw("dockSettingsTile", "Settings", "A tile for this app", true),
            sec("HIDING", ""),
            sw("dockHide", "Hide the dock", "It comes back when the pointer reaches the bottom edge", false),
            sw("dockOverFullscreen", "Over full-screen windows", "When the pointer reaches the edge", true),
        ],
        "launcher" => vec![
            sec("SIZE", ""),
            sl("launcherSize", "Size", "", 145.0, 70.0, 220.0, 5.0, " %"),
            sl("launcherWide", "Width", "", 100.0, 50.0, 200.0, 5.0, " %"),
            sl("launcherTall", "Height", "", 100.0, 50.0, 200.0, 5.0, " %"),
            sl("launcherIconScale", "Icons", "", 100.0, 50.0, 200.0, 5.0, " %"),
            sec("BEHAVIOUR", ""),
            sw("launcherFiles", "Search files", "Files in your home folder too", true),
            sw("launcherMorph", "Grow out of the dock", "", true),
        ],
        "alttab" => vec![
            sec("SWITCHER", ""),
            sw("altTabEnabled", "Alt+Tab", "The shell's window switcher", true),
            ch("altTabMod", "Key", "Held with Tab", "ALT", TAB_MOD),
            ch("altTabScope", "Windows", "Which windows it lists", "workspace", TAB_SCOPE),
            ch("altTabStyle", "Look", "", "thumbnails", TAB_STYLE),
            sl("altTabSize", "Size", "", 100.0, 50.0, 200.0, 5.0, " %"),
            sl("altTabDelay", "Delay", "Before it appears, for a quick switch", 100.0, 0.0, 500.0, 10.0, " ms"),
            sec("ENTRIES", ""),
            sw("altTabGroup", "One per app", "Rather than one per window", false),
            sw("altTabSpecial", "Scratchpad windows", "", true),
            sw("altTabWorkspaceTags", "Workspace numbers", "On each entry", true),
            sw("altTabHold", "Release to switch", "Off: it stays open until Enter", true),
        ],
        "notifications" => vec![
            sec("NOTIFICATIONS", ""),
            sw("dnd", "Do not disturb", "No banners; they still go to the list", false),
            sw("notifHistory", "Keep a history", "", true),
            sl("notifHistoryDays", "For", "", 7.0, 1.0, 30.0, 1.0, " days"),
        ],
        "sound" => vec![
            sec("VOLUME KEYS", ""),
            sl("volumeStep", "Step", "Per key press", 5.0, 1.0, 20.0, 1.0, " %"),
            sw("volumeBoost", "Above 100 %", "Let the keys go up to 150 %", false),
            sw("volumeFeedback", "Click", "A sound at each step", false),
        ],
        "network" => vec![sec("WI-FI", ""), custom("wifi", "Networks", "Join, disconnect and forget networks")],
        "bluetooth" => vec![sec("BLUETOOTH", ""), custom("bt", "Devices", "Pair, connect and disconnect")],
        "about" => vec![sec("THIS COMPUTER", ""), custom("about", "", "")],
        _ => vec![],
    }
}

fn theme_path() -> PathBuf {
    kit::theme::theme_path()
}

fn read() -> Value {
    let v = std::fs::read_to_string(theme_path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null);
    if v.is_object() {
        v
    } else {
        json!({})
    }
}

/// One key changed, the rest of the file as it was.
fn set(key: &str, value: Value) -> std::io::Result<()> {
    let p = theme_path();
    let mut v = read();
    v[key] = value;
    if let Some(dir) = p.parent() {
        std::fs::create_dir_all(dir)?;
    }
    kit::write_atomic(&p, serde_json::to_string_pretty(&v).unwrap_or_default().as_bytes())
}

fn mtime() -> Option<SystemTime> {
    std::fs::metadata(theme_path()).and_then(|m| m.modified()).ok()
}

fn hex(s: &str) -> Option<Color> {
    let h = s.trim().strip_prefix('#')?;
    if h.len() != 6 {
        return None;
    }
    let v = u32::from_str_radix(h, 16).ok()?;
    Some(Color::from_rgb_u8((v >> 16) as u8, (v >> 8) as u8, v as u8))
}

fn row(kind: &str, key: &str, label: &str, help: &str) -> Row {
    Row {
        kind: kind.into(),
        key: key.into(),
        label: label.into(),
        help: help.into(),
        on: false,
        value: 0.0,
        min: 0.0,
        max: 1.0,
        step: 1.0,
        unit: SharedString::new(),
        options: ModelRc::default(),
        pick: -1,
        colours: ModelRc::default(),
        text: SharedString::new(),
        action: SharedString::new(),
    }
}

fn strings(v: &[&str]) -> ModelRc<SharedString> {
    ModelRc::new(VecModel::from(v.iter().map(|s| SharedString::from(*s)).collect::<Vec<_>>()))
}

fn file_name(p: &str) -> String {
    std::path::Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| p.to_string())
}

fn have(cmd: &str) -> bool {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.join(cmd).is_file()))
        .unwrap_or(false)
}

fn first_line(path: &str) -> String {
    std::fs::read_to_string(path).map(|s| s.trim().to_string()).unwrap_or_default()
}

/// What `about` shows: (label, value).
fn about() -> Vec<(String, String)> {
    let mut out = Vec::new();
    let product = first_line("/sys/class/dmi/id/product_name");
    if !product.is_empty() {
        let vendor = first_line("/sys/class/dmi/id/sys_vendor");
        out.push(("Computer".into(), if vendor.is_empty() { product } else { format!("{vendor} {product}") }));
    }
    let cpu = std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("model name")).and_then(|l| l.split_once(':')).map(|(_, v)| v.trim().to_string()));
    if let Some(cpu) = cpu {
        out.push(("Processor".into(), cpu));
    }
    let mem = std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| s.lines().next().and_then(|l| l.split_whitespace().nth(1)).and_then(|kb| kb.parse::<u64>().ok()));
    if let Some(kb) = mem {
        out.push(("Memory".into(), kit::bytes(kb * 1024)));
    }
    let os = std::fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|s| s.lines().find_map(|l| l.strip_prefix("PRETTY_NAME=").map(|v| v.trim_matches('"').to_string())));
    if let Some(os) = os {
        out.push(("System".into(), os));
    }
    out.push(("Kernel".into(), first_line("/proc/sys/kernel/osrelease")));
    let hypr = std::process::Command::new("hyprctl")
        .args(["version", "-j"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok())
        .and_then(|v| v["tag"].as_str().map(str::to_string));
    if let Some(h) = hypr {
        out.push(("Hyprland".into(), h));
    }
    let rust = std::process::Command::new("pidof").arg("hyprshell-rs").output().map(|o| !o.stdout.is_empty()).unwrap_or(false);
    out.push(("Shell".into(), if rust { "Hyprshell (Rust)".into() } else { "Hyprshell (Quickshell)".into() }));
    out.push(("Settings file".into(), theme_path().display().to_string()));
    out
}

/// The page's rows, with theme.json's values (or the defaults).
fn rows(page: &str, v: &Value) -> Vec<Row> {
    let dark = match v["theme"].as_str() {
        Some("dark") => true,
        Some("auto") => kit::theme::Palette::from_json(v).dark,
        _ => false,
    };
    let mut out = Vec::new();
    for it in schema(page) {
        let val = &v[it.key];
        match it.kind {
            Kind::Section => out.push(row("section", "", it.label, it.help)),
            Kind::Switch(def) => {
                let mut r = row("switch", it.key, it.label, it.help);
                r.on = val.as_bool().unwrap_or(def);
                out.push(r);
            }
            Kind::Slider(def, min, max, step, unit) => {
                let mut r = row("slider", it.key, it.label, it.help);
                r.value = val.as_f64().unwrap_or(def).clamp(min, max) as f32;
                r.min = min as f32;
                r.max = max as f32;
                r.step = step as f32;
                r.unit = unit.into();
                out.push(r);
            }
            Kind::Choice(def, opts) => {
                let mut r = row("choice", it.key, it.label, it.help);
                let now = val.as_str().unwrap_or(def);
                r.options = strings(&opts.iter().map(|o| o.0).collect::<Vec<_>>());
                r.pick = opts.iter().position(|o| o.1 == now).unwrap_or(0) as i32;
                out.push(r);
            }
            Kind::Custom => match it.key {
                "accent" => {
                    let mut r = row("swatches", "accent", it.label, it.help);
                    let mut colours: Vec<Color> = ACCENTS.iter().filter_map(|(l, d)| hex(if dark { d } else { l })).collect();
                    colours.push(hex(v["customAccent"].as_str().unwrap_or("#3b6ef5")).unwrap_or(Color::from_rgb_u8(0x3b, 0x6e, 0xf5)));
                    let i = v["accent"].as_i64().unwrap_or(0);
                    r.pick = if i < 0 { ACCENTS.len() as i32 } else { i.min(ACCENTS.len() as i64 - 1) as i32 };
                    r.colours = ModelRc::new(VecModel::from(colours));
                    out.push(r);
                }
                "customAccent" => {
                    let mut r = row("field", "customAccent", it.label, it.help);
                    r.text = v["customAccent"].as_str().unwrap_or("#3b6ef5").into();
                    out.push(r);
                }
                "wallpaper" | "liveWallpaper" => {
                    let mut r = row("file", it.key, it.label, "");
                    let now = val.as_str().unwrap_or("");
                    let (none, off) = if it.key == "wallpaper" {
                        ("None: the theme's tinted gradient", "Use the gradient")
                    } else {
                        ("None", "Turn off")
                    };
                    r.text = if now.is_empty() { none.into() } else { file_name(now).into() };
                    r.options = if now.is_empty() { strings(&["Choose…"]) } else { strings(&["Choose…", off]) };
                    r.action = it.key.into();
                    out.push(r);
                }
                "wifi" | "bt" => {
                    let mut r = row("buttons", "", it.label, it.help);
                    r.options = strings(&["Open the list"]);
                    r.action = it.key.into();
                    out.push(r);
                    let (tool, label, help) = if it.key == "wifi" {
                        ("nm-connection-editor", "Connections", "VPNs, wired and hidden networks, addresses (NetworkManager)")
                    } else {
                        ("blueman-manager", "More", "Sending files and device settings (Blueman)")
                    };
                    if have(tool) {
                        let mut r = row("buttons", "", label, help);
                        r.options = strings(&["Open"]);
                        r.action = tool.into();
                        out.push(r);
                    }
                }
                "about" => {
                    for (k, val) in about() {
                        let mut r = row("info", "", &k, "");
                        r.text = val.into();
                        out.push(r);
                    }
                }
                _ => {}
            },
        }
    }
    out
}

struct State {
    page: String,
    /// theme.json's time when last shown, to see edits made elsewhere.
    seen: Option<SystemTime>,
}

fn show(ui: &AppWindow, st: &mut State) {
    let v = read();
    st.seen = mtime();
    let p = ui.global::<Prefs>();
    let info = PAGES.iter().find(|p| p.0 == st.page).unwrap_or(&PAGES[0]);
    p.set_page(info.0.into());
    p.set_heading(info.1.into());
    p.set_blurb(info.4.into());
    p.set_rows(ModelRc::new(VecModel::from(rows(info.0, &v))));
}

fn toast(ui: &AppWindow, timer: &slint::Timer, text: &str) {
    ui.global::<Prefs>().set_toast(text.into());
    let weak = ui.as_weak();
    timer.start(slint::TimerMode::SingleShot, Duration::from_millis(3000), move || {
        if let Some(ui) = weak.upgrade() {
            ui.global::<Prefs>().set_toast(SharedString::new());
        }
    });
}

/// A line for the shell, as the keybinds send them.
fn tell_shell(line: &str) -> std::io::Result<()> {
    use std::io::Write;
    let dir = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
    let mut f = std::fs::OpenOptions::new().append(true).create(true).open(dir.join("hyprshell.cmd"))?;
    writeln!(f, "{line}")
}

fn main() {
    kit::init("hyprshell-settings");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-settings");

    let first = std::env::args().nth(1).filter(|a| PAGES.iter().any(|p| p.0 == a)).unwrap_or_else(|| "appearance".into());
    let st = Rc::new(RefCell::new(State { page: first, seen: None }));
    let toast_timer = Rc::new(slint::Timer::default());

    let pages: Vec<Page> = PAGES
        .iter()
        .map(|p| Page { id: p.0.into(), label: p.1.into(), icon: p.2.into(), group: p.3.into() })
        .collect();
    ui.global::<Prefs>().set_pages(ModelRc::new(VecModel::from(pages)));
    show(&ui, &mut st.borrow_mut());

    // Writes a key, then shows the page again with it.
    let write = {
        let weak = ui.as_weak();
        let st = st.clone();
        let tt = toast_timer.clone();
        Rc::new(move |key: &str, value: Value| {
            let Some(ui) = weak.upgrade() else { return };
            if let Err(e) = set(key, value) {
                toast(&ui, &tt, &format!("Couldn't save: {e}"));
            }
            show(&ui, &mut st.borrow_mut());
        })
    };

    let prefs = ui.global::<Prefs>();
    {
        let weak = ui.as_weak();
        let st = st.clone();
        prefs.on_open(move |id| {
            let Some(ui) = weak.upgrade() else { return };
            st.borrow_mut().page = id.to_string();
            show(&ui, &mut st.borrow_mut());
        });
    }
    {
        let w = write.clone();
        prefs.on_toggle(move |key, on| w(&key, json!(on)));
    }
    {
        let w = write.clone();
        prefs.on_slide(move |key, v| w(&key, json!(v.round() as i64)));
    }
    {
        let w = write.clone();
        let st = st.clone();
        prefs.on_choose(move |key, i| {
            if key == "accent" {
                let n = ACCENTS.len() as i32;
                w("accent", json!(if i >= n { -1 } else { i }));
                return;
            }
            let page = st.borrow().page.clone();
            let found = schema(&page).into_iter().find_map(|it| match it.kind {
                Kind::Choice(_, opts) if it.key == key.as_str() => opts.get(i as usize).map(|o| o.1),
                _ => None,
            });
            if let Some(value) = found {
                w(&key, json!(value));
            }
        });
    }
    {
        let w = write.clone();
        let weak = ui.as_weak();
        let tt = toast_timer.clone();
        prefs.on_typed(move |key, text| {
            if key != "customAccent" {
                return;
            }
            let t = text.trim().to_lowercase();
            let t = if t.starts_with('#') { t } else { format!("#{t}") };
            if hex(&t).is_none() {
                if let Some(ui) = weak.upgrade() {
                    toast(&ui, &tt, "Not a colour: write it as #rrggbb");
                }
                return;
            }
            w("customAccent", json!(t));
            w("accent", json!(-1));
        });
    }
    {
        let w = write.clone();
        let weak = ui.as_weak();
        let tt = toast_timer.clone();
        prefs.on_act(move |action, i| {
            let Some(ui) = weak.upgrade() else { return };
            match (action.as_str(), i) {
                ("wallpaper", 0) | ("liveWallpaper", 0) => {
                    let key = action.to_string();
                    let filters: &'static [kit::portal::Filter<'static>] = if key == "wallpaper" {
                        &[("Pictures", &["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp", "*.gif", "*.tif", "*.tiff"])]
                    } else {
                        &[("Videos", &["*.mp4", "*.mkv", "*.webm", "*.mov", "*.avi", "*.m4v", "*.gif"])]
                    };
                    let title = if key == "wallpaper" { "Choose a picture" } else { "Choose a video" };
                    let w = w.clone();
                    kit::spawn(move || kit::portal::open_file(title, filters), move |picked| {
                        if let Some(p) = picked {
                            w(&key, json!(p.display().to_string()));
                        }
                    });
                }
                ("wallpaper", 1) | ("liveWallpaper", 1) => w(&action, json!("")),
                ("wifi", _) | ("bt", _) => {
                    let line = if action == "wifi" { "showWifi" } else { "showBluetooth" };
                    if let Err(e) = tell_shell(line) {
                        toast(&ui, &tt, &format!("Couldn't reach the shell: {e}"));
                    }
                }
                (tool, _) if tool == "nm-connection-editor" || tool == "blueman-manager" => {
                    if let Err(e) = std::process::Command::new(tool).spawn() {
                        toast(&ui, &tt, &format!("Couldn't start {tool}: {e}"));
                    }
                }
                _ => {}
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
                show(&ui, &mut st.borrow_mut());
            }
        });
    }

    ui.run().expect("run");
}
