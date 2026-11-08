//! Every pane's rows: Settings.qml's rowsFor, row for row. A row is what
//! the window draws (`Row`, from app.slint) and what happens when it is
//! used (`set`, a closure over the setting it owns).

use crate::hypr;
use crate::prefs::{self, Prefs};
use crate::system;
use crate::{Btn, Row};
use serde_json::{json, Value};
use slint::{Color, ModelRc, SharedString, VecModel};
use std::rc::Rc;

/// What a control hands back.
#[derive(Clone, Debug)]
pub enum Val {
    B(bool),
    N(f64),
    S(String),
    Unit,
}

impl Val {
    pub fn b(&self) -> bool {
        matches!(self, Val::B(true))
    }
    pub fn n(&self) -> f64 {
        match self {
            Val::N(n) => *n,
            Val::S(s) => s.parse().unwrap_or(0.0),
            Val::B(b) => *b as i32 as f64,
            Val::Unit => 0.0,
        }
    }
    pub fn s(&self) -> String {
        match self {
            Val::S(s) => s.clone(),
            Val::N(n) => n.to_string(),
            Val::B(b) => b.to_string(),
            Val::Unit => String::new(),
        }
    }
}

/// The window's own state the rows read and change: which pane, which
/// display is picked, and so on (the properties of Settings.qml's root).
#[derive(Default)]
pub struct Ui {
    pub pane: String,
    pub display_pick: String,
    pub mod_probe: String,
    pub wallpaper_mode: String,
    /// Settings → Wallpaper → Live, each screen its own: the screen being
    /// picked for ("" for all).
    pub live_pick: String,
    pub adv_open: std::collections::HashSet<String>,
    /// Settings → Login screen: what face unlock is, as last looked at, and
    /// what the rows asked of it.
    pub face: crate::face::Snap,
    pub face_cmds: Vec<crate::face::Cmd>,
    /// The keyring section (keyring.rs): how it stands, and what its rows asked.
    pub keyring: crate::keyring::Snap,
    pub keyring_cmds: Vec<crate::keyring::Cmd>,
    /// Howdy's settings waiting for the password.
    pub face_pending: usize,
    /// A message for the toast.
    pub toast: Option<String>,
    /// A line for the shell's hyprshell.cmd.
    pub tell: Vec<String>,
    /// Pick a file: (folder?, title, the key to set).
    pub pick: Option<(bool, String, String)>,
    /// A display change on trial (Settings → Display).
    pub trial: Option<crate::display::Trial>,
    /// HDR calibration's full-screen windows to open: (output, the test
    /// pattern rather than Calibrate).
    pub hdr: Option<(String, bool)>,
    /// Settings → Laptop: asusd's state as the daemon last sent it (its
    /// "rog" event), what went wrong last, and commands for the daemon.
    pub rog: Value,
    pub rog_error: String,
    pub daemon: Vec<Value>,
}

pub struct Ctx {
    pub p: Prefs,
    pub ui: Ui,
}

impl Ctx {
    pub fn set(&mut self, name: &str, v: Value) {
        if let Err(e) = self.p.set(name, v) {
            self.ui.toast = Some(format!("Couldn't save: {e}"));
        }
    }
}

pub type SetFn = Rc<dyn Fn(&mut Ctx, Val)>;

pub struct Spec {
    pub row: Row,
    /// The stored value of each option (seg, menu), by index.
    pub values: Vec<String>,
    pub set: Option<SetFn>,
    /// One per button of a "buttons" row.
    pub presses: Vec<SetFn>,
    pub adv: bool,
}

pub(crate) fn base(kind: &str, n: &str, s: &str) -> Spec {
    Spec {
        row: Row { kind: kind.into(), n: n.into(), s: s.into(), step: 1.0, pick: -1, ..Default::default() },
        values: vec![],
        set: None,
        presses: vec![],
        adv: false,
    }
}

impl Spec {
    pub fn adv(mut self) -> Spec {
        self.adv = true;
        self
    }
    fn on(mut self, f: impl Fn(&mut Ctx, Val) + 'static) -> Spec {
        self.set = Some(Rc::new(f));
        self
    }
    fn value(mut self, v: impl Into<String>) -> Spec {
        self.row.value = SharedString::from(v.into());
        self
    }
}

fn strings(v: &[String]) -> ModelRc<SharedString> {
    ModelRc::new(VecModel::from(v.iter().map(|s| SharedString::from(s.as_str())).collect::<Vec<_>>()))
}

// ── row builders ─────────────────────────────────────────────────────────
pub fn header(n: &str, s: &str) -> Spec {
    base("header", n, s)
}
pub fn info(n: &str, s: &str, v: impl ToString) -> Spec {
    base("info", n, s).value(v.to_string())
}
pub fn panel(name: &str) -> Spec {
    let mut r = base("panel", "", "");
    r.row.panel = name.into();
    r
}
pub(crate) fn toggle_with(n: &str, s: &str, on: bool, f: impl Fn(&mut Ctx, bool) + 'static) -> Spec {
    let mut r = base("toggle", n, s).on(move |c, v| f(c, v.b()));
    r.row.on = on;
    r
}
/// A switch on a theme.json key.
pub(crate) fn toggle(p: &Prefs, n: &str, s: &str, key: &'static str) -> Spec {
    toggle_with(n, s, p.b(key), move |c, v| c.set(key, json!(v)))
}
#[allow(clippy::too_many_arguments)]
pub(crate) fn slider_with(n: &str, s: &str, min: f64, max: f64, step: f64, unit: &str, v: f64, f: impl Fn(&mut Ctx, f64) + 'static) -> Spec {
    let mut r = base("slider", n, s).on(move |c, v| f(c, v.n()));
    r.row.min = min as f32;
    r.row.max = max as f32;
    r.row.step = step as f32;
    r.row.unit = unit.into();
    r.row.num = v.clamp(min, max) as f32;
    r
}
/// A slider on a theme.json key, whole numbers.
pub(crate) fn slider(p: &Prefs, n: &str, s: &str, min: f64, max: f64, unit: &str, key: &'static str) -> Spec {
    slider_with(n, s, min, max, 1.0, unit, p.f(key), move |c, v| c.set(key, json!(v.round() as i64)))
}
pub(crate) fn seg_with(n: &str, s: &str, opts: &[(&str, &str)], cur: &str, f: impl Fn(&mut Ctx, String) + 'static) -> Spec {
    let mut r = base("seg", n, s).on(move |c, v| f(c, v.s()));
    r.row.options = strings(&opts.iter().map(|o| o.0.to_string()).collect::<Vec<_>>());
    r.values = opts.iter().map(|o| o.1.to_string()).collect();
    r.row.pick = opts.iter().position(|o| o.1 == cur).map(|i| i as i32).unwrap_or(-1);
    r
}
/// Segments on a theme.json string key.
pub(crate) fn seg(p: &Prefs, n: &str, s: &str, opts: &[(&str, &str)], key: &'static str) -> Spec {
    seg_with(n, s, opts, &p.s(key), move |c, v| c.set(key, json!(v)))
}
pub(crate) fn menu_with(n: &str, s: &str, opts: Vec<String>, cur: &str, f: impl Fn(&mut Ctx, String) + 'static) -> Spec {
    let mut r = base("menu", n, s).on(move |c, v| f(c, v.s()));
    r.row.options = strings(&opts);
    r.row.pick = opts.iter().position(|o| o == cur).map(|i| i as i32).unwrap_or(-1);
    r.row.value = cur.into();
    r.values = opts;
    r
}
pub(crate) fn action(n: &str, s: &str, label: &str, f: impl Fn(&mut Ctx) + 'static) -> Spec {
    let mut r = base("action", n, s).on(move |c, _| f(c));
    r.row.label = label.into();
    r
}
pub(crate) type Press = (String, bool, bool, SetFn);
pub(crate) fn btn(label: &str, quiet: bool, enabled: bool, f: impl Fn(&mut Ctx) + 'static) -> Press {
    (label.to_string(), quiet, enabled, Rc::new(move |c: &mut Ctx, _| f(c)))
}
pub(crate) fn buttons(n: &str, s: &str, list: Vec<Press>) -> Spec {
    let mut r = base("buttons", n, s);
    r.row.buttons = ModelRc::new(VecModel::from(
        list.iter().map(|b| Btn { label: b.0.clone().into(), quiet: b.1, enabled: b.2 }).collect::<Vec<_>>(),
    ));
    r.presses = list.into_iter().map(|b| b.3).collect();
    r
}
pub(crate) fn meter(n: &str, s: &str, v: f64, label: &str, ink: bool) -> Spec {
    let mut r = base("meter", n, s);
    r.row.num = v.clamp(0.0, 1.0) as f32;
    r.row.label = label.into();
    r.row.on = ink;
    r
}
pub(crate) fn text(n: &str, s: &str, v: &str, placeholder: &str, label: &str, f: impl Fn(&mut Ctx, String) + 'static) -> Spec {
    let mut r = base("text", n, s).on(move |c, v| f(c, v.s())).value(v);
    r.row.placeholder = placeholder.into();
    r.row.label = label.into();
    r
}
pub(crate) fn color_row(n: &str, s: &str, hex: &str, f: impl Fn(&mut Ctx, String) + 'static) -> Spec {
    let mut r = base("color", n, s).on(move |c, v| f(c, v.s())).value(hex);
    r.row.colour = parse_hex(hex).unwrap_or(Color::from_rgb_u8(0, 0, 0));
    r
}
pub(crate) fn keybind(n: &str, s: &str, v: &str, probe: bool, f: impl Fn(&mut Ctx, String) + 'static) -> Spec {
    let mut r = base("keybind", n, s).on(move |c, v| f(c, v.s())).value(v);
    r.row.on = probe;
    r
}
pub(crate) fn nav(n: &str, s: &str, icon: &str, target: String) -> Spec {
    let mut r = base("nav", n, s).on(move |c, _| c.ui.pane = target.clone());
    r.row.icon = icon.into();
    r
}

pub fn parse_hex(s: &str) -> Option<Color> {
    let h = s.trim().strip_prefix('#')?;
    let v = u32::from_str_radix(h.get(..6)?, 16).ok()?;
    Some(Color::from_rgb_u8((v >> 16) as u8, (v >> 8) as u8, v as u8))
}

// ── the panes ────────────────────────────────────────────────────────────

/// (name, icon, title, note) — Settings.qml's paneMeta.
pub const PANES: &[(&str, &str, &str, &str)] = &[
    ("Display", "monitor", "", "Every connected display, with its own resolution, refresh rate, scale and colour."),
    ("Keyboard", "keyboard", "", "Layout, key repeat and the modifier behaviour libinput exposes."),
    ("Mouse", "mouse", "", "Pointer speed, acceleration profile, buttons and wheel."),
    ("Touchpad", "touchpad", "", "Tapping, scrolling, palm rejection and click behaviour."),
    ("Network", "wifi", "Wi-Fi & network", "Wi-Fi networks — joining, university sign-in, saved networks and connection details."),
    ("Bluetooth", "bluetooth", "", "Your devices, and adding new ones."),
    ("Sound", "volume", "", "Devices, levels, balance, connectors and modes, each app\u{2019}s volume and output."),
    ("Power", "battery", "Power & battery", "Power profile, idle timing and battery care."),
    ("Laptop", "zap", "", "This ASUS laptop's own controls, through asusd: performance, charge limit, keyboard light, graphics and panel."),
    ("Hyprland", "grid", "Windows & workspaces", "The compositor itself — gaps, borders, blur, animations and layout, applied live."),
    ("Login screen", "lock", "", "Unlocking with your face, at the lock screen and when you log in."),
    ("Updates", "download", "", "New versions of the shell, its login screen and its apps, from GitHub — installed when you say."),
    ("About", "cpu", "", "This machine and the shell running on it."),
    ("Appearance", "palette", "", "How the shell looks and moves. Every change shows at once — in the preview, and everywhere else."),
    ("Wallpaper", "image", "", "The desktop's ground — a tint, an image, or a live wallpaper."),
    ("Icons", "package", "", "Every place an app icon appears, sized in one list."),
    ("App theming", "sunMoon", "", "Handing this theme to applications that are not part of the shell."),
    ("Bar", "layout", "", "The top bar: height, clock, tray and the task list."),
    ("Dock", "dock", "", "The dock: position, size, labels and auto-hide."),
    ("Alt+Tab", "layoutDashboard", "", "The window switcher: its shortcut, which windows it offers, and how it looks."),
    ("Notifications", "bell", "", "Banner behaviour, badge counts and how the center stacks items."),
    ("Launcher", "search", "", "Size of the start menu, its grid, and its text."),
    ("Fonts", "font", "", "Every typeface the shell uses, and one scale over all of them."),
    ("Keybinds", "keyboard", "Keyboard shortcuts", "Hyprland bindings this shell listens for."),
    ("Clipboard", "clipboard", "", "What you copied, kept to paste again — Super+Shift+V."),
    ("Screenshots", "camera", "", "Print and Super+Shift+S: the pointer, freezing the screen, the timer and the editor."),
];

pub struct Category {
    pub id: &'static str,
    pub icon: &'static str,
    pub note: &'static str,
    pub items: Vec<&'static str>,
}

/// Settings.qml's categories. Laptop only where asusd answers.
pub fn categories() -> Vec<Category> {
    let rog = asusd_available();
    vec![
        Category {
            id: "System",
            icon: "monitor",
            note: "Displays, sound, notifications and power.",
            items: [&["Display", "Sound", "Notifications", "Power"][..], if rog { &["Laptop"] } else { &[] }].concat(),
        },
        Category { id: "Connections", icon: "wifi", note: "Wi-Fi and Bluetooth.", items: vec!["Network", "Bluetooth"] },
        Category { id: "Input", icon: "keyboard", note: "Keyboard, shortcuts, mouse and touchpad.", items: vec!["Keyboard", "Keybinds", "Mouse", "Touchpad"] },
        Category {
            id: "Personalization",
            icon: "palette",
            note: "How the shell looks: colours, wallpaper, fonts and icons, and theming other apps.",
            items: vec!["Appearance", "Wallpaper", "Fonts", "Icons", "App theming"],
        },
        Category { id: "Taskbar & menus", icon: "dock", note: "The bar, the dock, the launcher and Alt+Tab.", items: vec!["Bar", "Dock", "Launcher", "Alt+Tab"] },
        Category { id: "Windows", icon: "grid", note: "", items: vec!["Hyprland"] },
        Category { id: "Apps & tools", icon: "package", note: "The clipboard history and screenshots.", items: vec!["Clipboard", "Screenshots"] },
        Category { id: "Privacy & security", icon: "lock", note: "", items: vec!["Login screen"] },
        Category { id: "About", icon: "cpu", note: "This machine, the shell, and updates to it.", items: vec!["About", "Updates"] },
    ]
}

fn asusd_available() -> bool {
    std::path::Path::new("/usr/share/dbus-1/system-services/xyz.ljones.Asusd.service").exists() || system::have("asusctl")
}

pub fn category_of(pane: &str) -> Option<Category> {
    let cats = categories();
    if let Some(id) = pane.strip_prefix("cat:") {
        return cats.into_iter().find(|c| c.id == id);
    }
    cats.into_iter().find(|c| c.items.contains(&pane))
}

pub fn pane_title(p: &str) -> String {
    if let Some(c) = p.strip_prefix("cat:") {
        return c.to_string();
    }
    PANES.iter().find(|m| m.0 == p).map(|m| if m.2.is_empty() { m.0 } else { m.2 }).unwrap_or(p).to_string()
}
pub fn pane_note(p: &str) -> String {
    if p.starts_with("cat:") {
        return category_of(p).map(|c| c.note.to_string()).unwrap_or_default();
    }
    PANES.iter().find(|m| m.0 == p).map(|m| m.3).unwrap_or("").to_string()
}
pub fn pane_icon(p: &str) -> &'static str {
    PANES.iter().find(|m| m.0 == p).map(|m| m.1).unwrap_or("settings")
}

pub fn rows_for(pane: &str, c: &Ctx) -> Vec<Spec> {
    let p = &c.p;
    if pane.starts_with("cat:") {
        return category_of(pane)
            .map(|cat| cat.items.iter().map(|it| nav(&pane_title(it), &pane_note(it), pane_icon(it), it.to_string())).collect())
            .unwrap_or_default();
    }
    match pane {
        "Appearance" => appearance(p),
        "Wallpaper" => wallpaper(c),
        "Login screen" => login(c),
        "Icons" => icons(p),
        "App theming" => app_theming(p),
        "Bar" => bar(p),
        "Alt+Tab" => alt_tab(p),
        "Dock" => dock(p),
        "Launcher" => launcher(p),
        "Keybinds" => keybinds(c),
        "Fonts" => fonts(p),
        "Clipboard" => clipboard(p),
        "Screenshots" => screenshots(p),
        "Notifications" => notifications(p),
        "Display" => crate::display::rows(c),
        "Network" => network(),
        "Bluetooth" => vec![panel("bluetooth")],
        "Sound" => vec![panel("sound")],
        "Laptop" => laptop(c),
        "Power" => power(p),
        "Hyprland" => hyprland(p),
        "Keyboard" => keyboard(p),
        "Mouse" => mouse(p),
        "Touchpad" => touchpad(p),
        "Updates" => vec![panel("shellUpdates")],
        "About" => about(p),
        _ => vec![],
    }
}

// Applied to Hyprland after the write, as Devices does.
fn input(c: &mut Ctx) {
    hypr::apply_input(&c.p);
}
fn frame(c: &mut Ctx) {
    hypr::apply_frame(&c.p);
}

fn appearance(p: &Prefs) -> Vec<Spec> {
    let mut r = vec![
        panel("preview"),
        header("Colour", ""),
        {
            let mut t = base("themes", "Theme", "Light, dark, or dark from sunset to sunrise").on(|c, v| c.set("theme", json!(v.s())));
            t.row.value = p.s("theme").into();
            t
        },
        {
            let accent_s = if p.wall_accent_on() {
                format!("From the wallpaper · {}", prefs::hex(p.accent()))
            } else if p.i("accentIndex") == -1 {
                format!("Custom · {}", p.s("customAccent").to_uppercase())
            } else {
                "The one colour everything picks up".into()
            };
            let mut s = base("swatch", "Accent", &accent_s);
            let dark = p.dark();
            let mut cols: Vec<Color> = prefs::ACCENTS.iter().filter_map(|(l, d)| parse_hex(if dark { d } else { l })).collect();
            cols.push(parse_hex(&p.s("customAccent")).unwrap_or(Color::from_rgb_u8(0x3b, 0x6e, 0xf5)));
            s.row.colours = ModelRc::new(VecModel::from(cols));
            s.row.pick = p.i("accentIndex") as i32;
            s.row.on = p.wall_accent_on();
            s.row.value = p.s("customAccent").into();
            s.on(|c, v| {
                // Choosing a colour is choosing not to take it from the
                // wallpaper. A number picks a preset (-1 the custom one);
                // a #hex is the custom colour.
                c.set("accentFromWallpaper", json!(false));
                match v {
                    Val::N(i) => c.set("accentIndex", json!(i as i64)),
                    Val::S(h) => {
                        c.set("customAccent", json!(h));
                        c.set("accentIndex", json!(-1));
                    }
                    _ => {}
                }
            })
        },
        toggle(p, "Accent from wallpaper", "Follow the most vivid colour in the wallpaper", "accentFromWallpaper"),
        header("Surfaces", ""),
        slider(p, "Translucency", "How much of the desktop shows through the bar, dock and panels", 0.0, 100.0, "%", "translucency"),
        toggle(p, "Frosted menus", "Blur what is behind a dropdown inside a window", "menuBlur"),
        slider(
            p,
            "Menu translucency",
            if p.b("menuBlur") { "How strong the frost reads" } else { "How much shows through a dropdown" },
            0.0,
            60.0,
            "%",
            "menuTranslucency",
        ),
        header("Shape", ""),
        slider(p, "Corner rounding", "Every radius at once — the shell, its apps, the browser and windows. 0% is square", 0.0, 160.0, "%", "roundingPct")
            .on(|c, v| {
                c.set("roundingPct", json!(v.n().round() as i64));
                frame(c);
            }),
    ];
    r.extend(corner_rows(p));
    r.push(header("Animation", ""));
    r.push(seg_with(
        "Style",
        if p.springy() {
            "Everything moves on springs that settle with a touch of give — windows too"
        } else {
            "The same springs, damped so they land without swinging past"
        },
        &[("Liquid", "springy"), ("Calm", "smooth")],
        &p.s("motionStyle"),
        |c, v| {
            c.set("motionStyle", json!(v));
            frame(c);
        },
    ));
    r.push(slider(
        p,
        "Speed",
        if p.f("animSpeed") <= 0.0 { "Off: everything changes at once" } else { "Every animation in the shell. Higher is faster" },
        0.0,
        300.0,
        "%",
        "animSpeed",
    ));
    if p.springy() {
        r.push(
            slider(
                p,
                "Bounce",
                if p.f("motionBounce") <= 0.0 { "Lands without swinging past" } else { "How much give the springs have as they settle" },
                0.0,
                200.0,
                "%",
                "motionBounce",
            )
            .on(|c, v| {
                c.set("motionBounce", json!(v.n().round() as i64));
                frame(c);
            }),
        );
        r.push(toggle(p, "Panels grow from their button", "Menus and panels swell out of the control that opened them", "panelsGrow"));
    }
    r.push(slider_with(
        "Window speed",
        "Hyprland's own: windows opening, closing and moving, and workspaces",
        25.0,
        300.0,
        1.0,
        "%",
        p.f("hyprAnimSpeed"),
        |c, v| {
            c.set("hyprAnimSpeed", json!(v.round() as i64));
            frame(c);
        },
    ));
    r.push(header("Scrolling", "").adv());
    r.push(toggle(p, "Trackpad momentum", "A flick keeps scrolling after you lift, and slows to a stop", "scrollMomentum").adv());
    if p.b("scrollMomentum") {
        r.push(slider(p, "Glide", "How far a flick carries", 50.0, 200.0, "%", "scrollGlide").adv());
    }
    r.push(toggle(p, "Smooth mouse wheel", if p.b("smoothWheel") { "Each notch glides" } else { "Each notch jumps" }, "smoothWheel").adv());
    r.extend(cursor_rows(p));
    r
}

fn corner_rows(p: &Prefs) -> Vec<Spec> {
    let mut r = vec![toggle(p, "Round the screen's corners", "Black corners drawn over everything, games and video included, never in the way of a click", "screenCorners")];
    if !p.b("screenCorners") {
        return r;
    }
    r.extend([
        slider(p, "Corner radius", "How far the black curve reaches into the screen", 2.0, 64.0, "px", "screenCornerRadius"),
        seg(p, "Displays", "Built-in is the laptop's own panel; All covers external monitors too", &[("Built-in", "builtin"), ("All", "all")], "screenCornerScreens"),
        toggle(
            p,
            "Over fullscreen apps",
            if p.b("screenCornersFullscreen") {
                "The screen keeps its shape for games and video too"
            } else {
                "Gone while an app is fullscreen, so Hyprland can send it straight to the display"
            },
            "screenCornersFullscreen",
        ),
        toggle(p, "Top left", "", "screenCornerTL"),
        toggle(p, "Top right", "", "screenCornerTR"),
        toggle(p, "Bottom left", "", "screenCornerBL"),
        toggle(p, "Bottom right", "", "screenCornerBR"),
    ]);
    r
}

fn cursor_rows(p: &Prefs) -> Vec<Spec> {
    let accent = p.s("cursorTheme") == "accent";
    let mut r = vec![
        header("Pointer", ""),
        seg(
            p,
            "Cursor",
            &if accent { "The shell's own, in the accent colour".to_string() } else { format!("The system theme: {}", p.s("cursorSystemTheme")) },
            &[("Accent", "accent"), ("System", "system")],
            "cursorTheme",
        ),
        slider(p, "Size", "", 16.0, 64.0, "px", "cursorSize"),
    ];
    if accent {
        r.push(action("Rebuild", "Draw it again and put it in use — if the pointer didn't change", "Rebuild", |c| {
            if system::have("hyprshell-cursors") {
                let _ = std::process::Command::new("hyprshell-cursors").spawn();
            } else {
                c.ui.toast = Some("hyprshell-cursors is missing — run shell/install.sh again".into());
            }
        }));
        let fill = p.s("cursorFill");
        r.push(seg_with(
            "Style",
            "Light on dark or the reverse, with one part in the accent",
            &[("Auto", "auto"), ("Dark", "dark"), ("Light", "light")],
            if fill == "dark" || fill == "light" { &fill } else { "auto" },
            |c, v| c.set("cursorFill", json!(v)),
        ));
    } else {
        r.push(text(
            "System theme",
            "Any cursor theme installed in ~/.local/share/icons or /usr/share/icons",
            &p.s("cursorSystemTheme"),
            "Adwaita",
            "Use",
            |c, v| {
                let t = if v.trim().is_empty() { "Adwaita".to_string() } else { v.trim().to_string() };
                let _ =std::process::Command::new("hyprctl").args(["setcursor", &t, &c.p.i("cursorSize").to_string()]).status();
                c.set("cursorSystemTheme", json!(t));
            },
        ));
    }
    r
}

fn wallpaper(c: &Ctx) -> Vec<Spec> {
    let p = &c.p;
    let mode = if !c.ui.wallpaper_mode.is_empty() {
        c.ui.wallpaper_mode.clone()
    } else if !p.s("liveWallpaper").is_empty() {
        "live".into()
    } else if !p.s("wallpaper").is_empty() {
        "image".into()
    } else if p.s("wallpaperStyle") != "gradient" {
        "animated".into()
    } else {
        "gradient".into()
    };
    let mut r = vec![seg_with(
        "Desktop",
        match mode.as_str() {
            "gradient" => "The shell's tinted gradient",
            "animated" => "Drawn and animated by the shell, in colours you choose",
            "image" => "A picture of your own",
            _ => "A video, played by mpvpaper",
        },
        &[("Gradient", "gradient"), ("Animated", "animated"), ("Image", "image"), ("Live", "live")],
        &mode,
        |c, v| set_wallpaper_mode(c, &v),
    )];
    match mode.as_str() {
        "gradient" => r.push(seg(p, "Tint", "Its temperature", &[("Warm", "Warm"), ("Neutral", "Neutral"), ("Cool", "Cool")], "tint")),
        "animated" => {
            r.push(panel("animated"));
            r.extend(if p.s("wallpaperStyle") == "topo" { topo_rows(p) } else { anim_rows(p) });
            r.extend(motion_rows(p));
        }
        "image" => {
            let w = p.s("wallpaper");
            r.push(buttons(
                "Image",
                &if w.is_empty() { "None picked yet".to_string() } else { w.rsplit('/').next().unwrap_or(&w).to_string() },
                vec![btn(if w.is_empty() { "Choose…" } else { "Change…" }, !w.is_empty(), true, |c| {
                    c.ui.pick = Some((false, "Choose wallpaper".into(), "wallpaper".into()))
                })],
            ));
        }
        _ => r.extend(live_rows(c)),
    }
    r.extend(boot_rows(p));
    r
}

/// Settings.bootRows: the wallpaper in Limine's boot menu, through the
/// root helper shell/limine/install.sh puts in place.
const BOOT_HELPER: &str = "/usr/local/libexec/hyprshell-limine-theme";
fn boot_rows(p: &Prefs) -> Vec<Spec> {
    let mut r = vec![header("Boot menu", "")];
    if !std::path::Path::new(BOOT_HELPER).exists() {
        r.push(info("Limine", "To use this wallpaper in the Limine boot menu, run once: sudo shell/limine/install.sh", "Not set up"));
        return r;
    }
    let _ = p;
    r.push(buttons(
        "Use this wallpaper in the boot menu",
        "A still of it, with your accent, in Limine. Asks for your password.",
        vec![btn("Update", false, true, boot_update), btn("Remove", true, true, |c| {
            let ok = std::process::Command::new("pkexec").args([BOOT_HELPER, "--remove"]).status().is_ok_and(|s| s.success());
            c.ui.toast = Some(if ok { "Taken out; the boot menu is Limine's own again".into() } else { "Not changed".into() });
        })],
    ));
    r
}

/// BootTheme.update: a still of the wallpaper (a frame of the video, or
/// the picture), handed to the helper with the accent.
fn boot_update(c: &mut Ctx) {
    let src = if !c.p.s("liveWallpaper").is_empty() { c.p.s("liveWallpaper") } else { c.p.s("wallpaper") };
    if src.is_empty() {
        c.ui.toast = Some("Pick an image or a live wallpaper first".into());
        return;
    }
    let dir = hyprshell_kit::config_dir().join("hyprshell");
    let _ = std::fs::create_dir_all(&dir);
    let still = dir.join("boot-still.png");
    let made = std::process::Command::new("ffmpeg")
        .args(["-nostdin", "-loglevel", "error", "-y", "-ss", "2", "-i", &src, "-frames:v", "1"])
        .arg(&still)
        .status()
        .is_ok_and(|s| s.success())
        || std::process::Command::new("ffmpeg").args(["-nostdin", "-loglevel", "error", "-y", "-i", &src, "-frames:v", "1"]).arg(&still).status().is_ok_and(|s| s.success());
    if !made {
        c.ui.toast = Some("Couldn't make a still of it (ffmpeg)".into());
        return;
    }
    let ok = std::process::Command::new("sh")
        .args([
            "-c",
            "exec pkexec \"$1\" --accent \"$2\" --background \"$3\" --foreground \"$4\" < \"$5\"",
            "boot-theme",
            BOOT_HELPER,
            &prefs::hex(c.p.accent()),
            "#161514",
            "#f8f4f4",
        ])
        .arg(&still)
        .status()
        .is_ok_and(|s| s.success());
    c.ui.toast = Some(if ok { "In the boot menu from the next start".into() } else { "Not changed".into() });
}

fn topo_rows(p: &Prefs) -> Vec<Spec> {
    let seed = p.i("topoSeed");
    let shade = p.s("topoShade");
    let motion = p.s("topoMotion");
    let mut r = vec![
        buttons(
            "Terrain",
            &format!("Map {seed}"),
            vec![
                btn("Previous", true, seed > 1, move |c| c.set("topoSeed", json!((seed - 1).max(1)))),
                btn("Next", true, true, move |c| c.set("topoSeed", json!(seed + 1))),
            ],
        ),
        slider(p, "Size", "How big the hills are", 25.0, 300.0, "%", "topoScale"),
        slider(p, "Roughness", "Smooth hills to broken ground", 1.0, 6.0, "", "topoDetail"),
        slider(p, "Flow", "How much the ridges wander", 0.0, 100.0, "%", "topoFlow"),
        header("Lines", ""),
        slider(p, "Contours", "Lines from the lowest ground to the highest", 4.0, 60.0, "", "topoLevels"),
        slider_with("Width", "", 0.5, 4.0, 0.1, "px", p.f("topoWidth"), |c, v| c.set("topoWidth", json!((v * 10.0).round() / 10.0))),
        seg_with(
            "Index lines",
            "Every so many drawn heavier, as on a survey map",
            &[("Off", "0"), ("4th", "4"), ("5th", "5"), ("10th", "10")],
            &p.i("topoMajor").to_string(),
            |c, v| c.set("topoMajor", json!(v.parse::<i64>().unwrap_or(0))),
        ),
        seg(p, "Colour", "", &[("Ink", "ink"), ("Accent", "accent"), ("Custom", "custom")], "topoLine"),
    ];
    if p.s("topoLine") == "custom" {
        r.push(color_row("Line colour", &p.s("topoLineCustom").to_uppercase(), &p.s("topoLineCustom"), |c, v| c.set("topoLineCustom", json!(v))));
    }
    r.extend([
        slider(p, "Strength", "", 5.0, 100.0, "%", "topoStrength"),
        slider(p, "Glow", "A soft light either side of each line", 0.0, 100.0, "%", "topoGlow"),
        header("Ground", ""),
        seg(
            p,
            "Shading",
            match shade.as_str() {
                "flat" => "One wash, top to bottom",
                "bands" => "A step of colour between each pair of lines",
                _ => "Darker low, lighter high",
            },
            &[("Flat", "flat"), ("Smooth", "smooth"), ("Bands", "bands")],
            "topoShade",
        ),
        seg(p, "Colours", if p.s("topoGround") == "theme" { "The theme's, light or dark with it" } else { "" }, &[("Theme", "theme"), ("Custom", "custom")], "topoGround"),
    ]);
    if p.s("topoGround") == "custom" {
        r.push(color_row("Low ground", &p.s("topoLow").to_uppercase(), &p.s("topoLow"), |c, v| c.set("topoLow", json!(v))));
        r.push(color_row("High ground", &p.s("topoHigh").to_uppercase(), &p.s("topoHigh"), |c, v| c.set("topoHigh", json!(v))));
    }
    r.push(header("Motion", ""));
    r.push(toggle(p, "Animate", "Off, the map is a still picture", "topoDrift"));
    if p.b("topoDrift") {
        r.push(seg(
            p,
            "What moves",
            match motion.as_str() {
                "drift" => "The terrain wanders",
                "flow" => "The contours climb the slopes and the next takes their place",
                _ => "The contours flow over wandering terrain",
            },
            &[("Terrain", "drift"), ("Contours", "flow"), ("Both", "both")],
            "topoMotion",
        ));
        r.push(slider(p, "Speed", "", 5.0, 200.0, "%", "topoSpeed"));
    }
    r
}

/// Settings.setWallpaperMode.
fn set_wallpaper_mode(c: &mut Ctx, v: &str) {
    let (wall, live) = (c.p.s("wallpaper"), c.p.s("liveWallpaper"));
    if !wall.is_empty() {
        c.set("wallpaperLast", json!(wall));
    }
    if !live.is_empty() {
        c.set("liveLast", json!(live));
    }
    match v {
        "gradient" | "animated" => {
            c.set("wallpaper", json!(""));
            let style = if v == "animated" {
                let l = c.p.s("animLastStyle");
                if l.is_empty() {
                    "topo".to_string()
                } else {
                    l
                }
            } else {
                v.to_string()
            };
            c.set("wallpaperStyle", json!(style));
            c.set("liveWallpaper", json!(""));
            c.ui.wallpaper_mode.clear();
        }
        "image" => {
            c.set("liveWallpaper", json!(""));
            let last = c.p.s("wallpaperLast");
            if c.p.s("wallpaper").is_empty() && !last.is_empty() {
                c.set("wallpaper", json!(last));
            }
            c.ui.wallpaper_mode = if c.p.s("wallpaper").is_empty() { "image".into() } else { String::new() };
        }
        _ => {
            let last = c.p.s("liveLast");
            if c.p.s("liveWallpaper").is_empty() && !last.is_empty() && std::path::Path::new(&last).exists() {
                c.set("liveWallpaper", json!(last));
            }
            c.ui.wallpaper_mode = if c.p.s("liveWallpaper").is_empty() { "live".into() } else { String::new() };
        }
    }
}

fn anim_rows(p: &Prefs) -> Vec<Spec> {
    let mut r = vec![];
    if p.s("animPalette") == "custom" {
        r.push(header("Colours", ""));
        for (n, k) in [
            ("Background, top", "animBg1"),
            ("Background, bottom", "animBg2"),
            ("First colour", "animC1"),
            ("Second colour", "animC2"),
            ("Third colour", "animC3"),
        ] {
            r.push(color_row(n, &p.s(k).to_uppercase(), &p.s(k), move |c, v| c.set(k, json!(v))));
        }
    }
    r.push(header("Look", ""));
    r.push(slider(p, "Size", "How big everything is drawn", 25.0, 300.0, "%", "animScale"));
    r.push(slider(p, "Density", "", 0.0, 100.0, "%", "animDensity"));
    r.push(slider(p, "Glow", "", 0.0, 100.0, "%", "animGlow"));
    r.push(slider(p, "Brightness", "How strongly it shows against the background", 0.0, 100.0, "%", "animIntensity"));
    let seed = p.i("animSeed");
    r.push(buttons(
        "Variation",
        &format!("Variation {seed}"),
        vec![
            btn("Previous", true, seed > 1, move |c| c.set("animSeed", json!((seed - 1).max(1)))),
            btn("Next", true, true, move |c| c.set("animSeed", json!(seed + 1))),
        ],
    ));
    r.push(header("Motion", ""));
    r.push(slider(p, "Speed", "", 5.0, 300.0, "%", "animWallSpeed"));
    r
}

/// WallMotion.others: other programs that draw a wallpaper, by the
/// kernel's (15-character) process name.
const OTHER_WALLPAPERS: [(&str, &str); 7] = [
    ("hyprpaper", "hyprpaper"),
    ("swww-daemon", "swww"),
    ("awww-daemon", "awww"),
    ("swaybg", "swaybg"),
    ("wpaperd", "wpaperd"),
    ("linux-wallpaper", "linux-wallpaperengine"),
    ("mpvpaper", "mpvpaper"),
];

/// WallMotion.foreign: those running now (an mpvpaper is the shell's own
/// while a Live wallpaper is on).
fn foreign_wallpapers(p: &Prefs) -> Vec<(&'static str, &'static str)> {
    let out = std::process::Command::new("ps").args(["-eo", "stat=,comm="]).output().map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
    let running: Vec<String> = out
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            (f.len() >= 2 && !f[0].starts_with('Z')).then(|| f[1].to_string())
        })
        .collect();
    let live = !p.s("liveWallpaper").is_empty();
    OTHER_WALLPAPERS.iter().copied().filter(|(c, _)| running.iter().any(|r| r == c) && !(*c == "mpvpaper" && live)).collect()
}

/// WallMotion.anyReason: why the desktop is still while the previews move
/// — "" when it moves on some screen.
fn motion_reason(p: &Prefs) -> &'static str {
    let bat = system::battery();
    let on_battery = bat.as_ref().is_some_and(|b| b.state == "Discharging");
    if on_battery && !p.b("animOnBattery") {
        return "battery";
    }
    // PowerSaver.active.
    let saver = match p.s("saverMode").as_str() {
        "always" => true,
        "never" => false,
        "low" => on_battery && bat.as_ref().is_some_and(|b| b.percent * 100.0 <= p.f("saverBelow")),
        _ => on_battery,
    };
    if saver {
        return "saver";
    }
    // Covered: on every screen a tiled, maximised or fullscreen window
    // fills what it shows.
    if !p.b("animPauseCovered") {
        return "";
    }
    let mons = hypr::json("monitors");
    let clients = hypr::json("clients");
    let mons = mons.as_array().cloned().unwrap_or_default();
    if mons.is_empty() {
        return "";
    }
    let covered = |m: &Value| {
        let ws = m["activeWorkspace"]["id"].as_i64();
        clients.as_array().into_iter().flatten().any(|c| {
            c["workspace"]["id"].as_i64() == ws
                && c["mapped"] != false
                && !c["class"].as_str().unwrap_or("").to_lowercase().contains("quickshell")
                && (c["floating"] != true || c["fullscreen"].as_i64().unwrap_or(0) > 0)
        })
    };
    if mons.iter().all(covered) {
        "covered"
    } else {
        ""
    }
}

fn motion_rows(p: &Prefs) -> Vec<Spec> {
    let mut r = vec![];
    let foreign = foreign_wallpapers(p);
    if !foreign.is_empty() {
        let names = foreign.iter().map(|f| f.1).collect::<Vec<_>>().join(", ");
        let comms: Vec<&'static str> = foreign.iter().map(|f| f.0).collect();
        r.push(buttons(
            &format!("Hidden by {names}"),
            "Another wallpaper program is drawing over this one. Stop it here, and take it out of whatever starts it at login (an exec-once, or a systemd user service).",
            vec![btn("Stop it", false, true, move |_| {
                for c in &comms {
                    let _ = std::process::Command::new("pkill").args(["-x", c]).status();
                }
                std::thread::sleep(std::time::Duration::from_millis(800));
            })],
        ));
    } else {
        match motion_reason(p) {
            "battery" => r.push(buttons("Paused on battery", "It moves again on the charger", vec![btn("Keep moving", false, true, |c| c.set("animOnBattery", json!(true)))])),
            "saver" => r.push(buttons(
                "Paused by Battery saver",
                "Settings → Power decides when that is on",
                vec![btn("Power…", true, true, |c| c.ui.pane = "Power".into())],
            )),
            "covered" => r.push(buttons(
                "Paused behind windows",
                "A window fills the screen; it moves again when you can see it",
                vec![btn("Keep moving", false, true, |c| c.set("animPauseCovered", json!(false)))],
            )),
            _ => {}
        }
    }
    r.extend(vec![
        seg_with("Frame rate", "Smoother costs more power", &[("15", "15"), ("30", "30"), ("60", "60")], &p.i("animFps").to_string(), |c, v| {
            c.set("animFps", json!(v.parse::<i64>().unwrap_or(30)))
        }),
        toggle(p, "Hold still behind windows", "While a tiled, maximised or fullscreen window fills the screen", "animPauseCovered"),
        toggle(p, "Keep moving on battery", "Otherwise it holds still until the charger is in", "animOnBattery"),
    ]);
    r
}

/// LiveWallpaper's folders (JSON list; ~/Videos/Wallpapers by default)
/// and loose files, and the videos in them.
/// LiveWallpaper.screenMap: a video per screen, for "each".
pub fn live_screen_map(p: &Prefs) -> serde_json::Map<String, Value> {
    serde_json::from_str::<Value>(&p.s("liveScreens")).ok().and_then(|v| v.as_object().cloned()).unwrap_or_default()
}

/// The screen being picked for, if the layout is "each" and it's there.
pub fn live_pick_for(c: &Ctx) -> String {
    if c.p.s("liveLayout") != "each" || c.ui.live_pick.is_empty() {
        return String::new();
    }
    let screens: Vec<String> = hypr::json("monitors").as_array().into_iter().flatten().filter_map(|m| m["name"].as_str().map(str::to_string)).collect();
    if screens.len() > 1 && screens.contains(&c.ui.live_pick) {
        c.ui.live_pick.clone()
    } else {
        String::new()
    }
}

/// The video the gallery ticks: the screen's own, or the one on.
pub fn live_current(c: &Ctx) -> String {
    let pick_for = live_pick_for(c);
    if !pick_for.is_empty() {
        return live_screen_map(&c.p).get(&pick_for).and_then(|v| v.as_str()).unwrap_or("").to_string();
    }
    c.p.s("liveWallpaper")
}

/// A video clicked in the gallery (LiveWallpaper.choose / chooseFor).
pub fn live_pick(c: &mut Ctx, dir: &str) {
    let pick_for = live_pick_for(c);
    if pick_for.is_empty() {
        c.set("liveWallpaper", json!(dir));
        return;
    }
    let mut m = live_screen_map(&c.p);
    if m.get(&pick_for).and_then(|v| v.as_str()) == Some(dir) {
        m.remove(&pick_for);
    } else {
        m.insert(pick_for, json!(dir));
    }
    c.set("liveScreens", json!(Value::Object(m).to_string()));
}

pub fn live_sources_pub(p: &Prefs) -> (Vec<String>, Vec<String>) {
    let (f, x, _) = live_sources(p);
    (f, x)
}

fn live_sources(p: &Prefs) -> (Vec<String>, Vec<String>, Vec<String>) {
    let home = hyprshell_kit::home().display().to_string();
    let folders: Vec<String> = serde_json::from_str::<Vec<String>>(&p.s("liveFolders"))
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| vec![format!("{home}/Videos/Wallpapers")]);
    let files: Vec<String> = serde_json::from_str::<Vec<String>>(&p.s("liveFiles")).unwrap_or_default();
    let is_video = |n: &str| {
        let l = n.to_lowercase();
        [".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".ogv", ".gif"].iter().any(|e| l.ends_with(e))
    };
    // As LiveWallpaper's scan: each folder and one level under it, then
    // the files; one of each, by title.
    fn walk(dir: &std::path::Path, depth: u32, out: &mut Vec<String>, ok: &dyn Fn(&str) -> bool) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let p = e.path();
            if p.is_dir() {
                if depth > 1 {
                    walk(&p, depth - 1, out, ok);
                }
            } else if ok(&p.display().to_string()) {
                out.push(p.display().to_string());
            }
        }
    }
    let mut videos: Vec<String> = vec![];
    for f in &folders {
        walk(std::path::Path::new(f), 2, &mut videos, &is_video);
    }
    videos.extend(files.iter().filter(|f| std::path::Path::new(f).is_file()).cloned());
    let mut seen = std::collections::HashSet::new();
    videos.retain(|v| seen.insert(v.clone()));
    let title = |v: &String| v.rsplit('/').next().unwrap_or(v).rsplit_once('.').map(|x| x.0).unwrap_or("").replace('_', " ").to_lowercase();
    videos.sort_by_key(title);
    (folders, files, videos)
}

fn live_rows(c: &Ctx) -> Vec<Spec> {
    let p = &c.p;
    let mut r = vec![];
    if !system::have("mpvpaper") {
        r.push(action(
            "mpvpaper",
            "Not installed — on Arch or CachyOS, paru -S mpvpaper. It plays a video as the wallpaper, with the graphics card's own decoder.",
            "Look again",
            |_| {},
        ));
        return r;
    }
    let home = hyprshell_kit::home().display().to_string();
    let (folders, files, videos) = live_sources(p);
    let live = p.s("liveWallpaper");
    let on = !live.is_empty();
    // The gallery's title for it (underscores as spaces) when it's there.
    let stem = live.rsplit('/').next().unwrap_or(&live).rsplit_once('.').map(|x| x.0).unwrap_or("").to_string();
    let title = if videos.contains(&live) { stem.replace('_', " ") } else { stem };
    let vids = videos.clone();
    r.push(buttons(
        if on { &title } else { "None on" },
        if !on {
            if videos.is_empty() {
                ""
            } else {
                "Pick one below"
            }
        } else {
            "Playing"
        },
        if on {
            vec![
                // LiveWallpaper.next: in order, or shuffled.
                btn("Next", true, videos.len() > 1, move |c| {
                    let now = c.p.s("liveWallpaper");
                    let mut i = vids.iter().position(|v| *v == now).map(|i| (i + 1) % vids.len()).unwrap_or(0);
                    if c.p.s("liveOrder") == "random" && vids.len() > 1 {
                        let seed = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos() as usize).unwrap_or(0);
                        i = seed % vids.len();
                        if vids[i] == now {
                            i = (i + 1) % vids.len();
                        }
                    }
                    if let Some(v) = vids.get(i) {
                        c.set("liveWallpaper", json!(v));
                    }
                }),
                btn("Turn off", true, true, |c| c.set("liveWallpaper", json!(""))),
            ]
        } else {
            vec![]
        },
    ));
    let screens: Vec<String> = hypr::json("monitors").as_array().into_iter().flatten().filter_map(|m| m["name"].as_str().map(str::to_string)).collect();
    if screens.len() > 1 {
        r.push(seg(p, "Screens", "", &[("Same", "same"), ("Each its own", "each")], "liveLayout"));
        // Each its own: which screen is being picked for, as buttons
        // rather than a menu, since there are only a few.
        if p.s("liveLayout") == "each" {
            let pick_for = live_pick_for(c);
            let map = live_screen_map(p);
            let mut opts: Vec<(String, String)> = vec![("All".into(), String::new())];
            opts.extend(screens.iter().map(|n| (n.clone(), n.clone())));
            let o: Vec<(&str, &str)> = opts.iter().map(|(a, b)| (a.as_str(), b.as_str())).collect();
            r.push(seg_with(
                "Picking for",
                if pick_for.is_empty() {
                    "Every screen without its own"
                } else if map.get(&pick_for).is_some_and(|v| v.as_str().is_some_and(|v| !v.is_empty())) {
                    "Click its video again to share the main one"
                } else {
                    ""
                },
                &o,
                &pick_for,
                |c, v| c.ui.live_pick = v,
            ));
        }
    }
    let tidy = |f: &str| f.replace(&home, "~");
    if videos.is_empty() {
        r.push(action(
            "No videos yet",
            &format!("Put some in {}, or add a folder below. mp4, webm, mkv, mov and gif all play.", folders.iter().map(|f| tidy(f)).collect::<Vec<_>>().join(", ")),
            "Look again",
            |_| {},
        ));
    } else {
        let mut g = panel("gallery");
        g.row.value = SharedString::from(format!("{}", videos.len()));
        r.push(g);
        if !system::have("ffmpeg") {
            r.push(info("No thumbnails", "Install ffmpeg for a still of each video here", ""));
        }
    }
    let any_sources = !p.s("liveFolders").is_empty() || !p.s("liveFiles").is_empty();
    r.push(buttons(
        "Folders",
        &format!(
            "{}{}",
            folders.iter().map(|f| tidy(f)).collect::<Vec<_>>().join(", "),
            if files.is_empty() { String::new() } else { format!(" and {} {}", files.len(), if files.len() == 1 { "file" } else { "files" }) }
        ),
        vec![
            btn("Add folder…", true, true, |c| c.ui.pick = Some((true, "Folder of videos".into(), "+liveFolders".into()))),
            btn("Add video…", true, true, |c| c.ui.pick = Some((false, "Video".into(), "+liveFiles".into()))),
            btn("Reset", true, any_sources, |c| {
                c.set("liveFolders", json!(""));
                c.set("liveFiles", json!(""));
            }),
        ],
    ));
    r.push(header("Playback", ""));
    r.push(seg(p, "Scaling", "How a video meets a screen of another shape", &[("Fill", "fill"), ("Fit", "fit"), ("Stretch", "stretch")], "liveScaling"));
    r.push(toggle(p, "Sound", "The video's own audio, if it has any", "liveSound"));
    if p.b("liveSound") {
        r.push(slider(p, "Volume", "", 0.0, 100.0, "%", "liveVolume"));
    }
    r.push(seg(
        p,
        "Pause behind windows",
        "Stops playing while windows cover every screen",
        &[("Covered", "covered"), ("Any window", "windows"), ("Never", "never")],
        "livePauseCovered",
    ));
    r.push(toggle(p, "Pause on battery", "Holds the frame on screen while unplugged", "livePauseOnBattery"));
    let delays: Vec<i64> = {
        let mut d = vec![5, 10, 15, 30, 60, 120, 360, 720, 1440];
        let cur = p.i("liveDelay");
        if !d.contains(&cur) {
            d.push(cur);
            d.sort();
        }
        d
    };
    let label = |m: i64| {
        if m < 60 {
            format!("{m} minutes")
        } else if m == 60 {
            "1 hour".into()
        } else if m < 1440 {
            format!("{} hours", m / 60)
        } else if m == 1440 {
            "1 day".into()
        } else {
            format!("{} days", m / 1440)
        }
    };
    r.push(toggle(
        p,
        "Rotate",
        if videos.len() < 2 { "Needs two or more videos" } else { "Move on to another video every so often" },
        "liveRotate",
    ));
    if p.b("liveRotate") {
        let labels: Vec<String> = delays.iter().map(|m| label(*m)).collect();
        let (ls, ds) = (labels.clone(), delays.clone());
        r.push(menu_with("Every", "", labels, &label(p.i("liveDelay")), move |c, v| {
            if let Some(i) = ls.iter().position(|l| *l == v) {
                c.set("liveDelay", json!(ds[i]));
            }
        }));
        r.push(seg(p, "Order", "", &[("In order", "sequential"), ("Shuffled", "random")], "liveOrder"));
    }
    r
}

fn icons(p: &Prefs) -> Vec<Spec> {
    let sm = p.s("iconSmoothing");
    vec![
        header("Icon sizes", "Every app icon size in one list — the same settings as in each part's own pane"),
        slider(p, "Dock icons", "The glyph inside a dock tile, as a share of the tile. The tile itself is sized under Dock.", 30.0, 72.0, "%", "dockIconPct"),
        slider(p, "Launcher icons", "The glyph inside each app tile in the start menu, without changing how many fit on a row.", 50.0, 200.0, "%", "launcherIconScale"),
        slider(p, "Bar and tray icons", "The bar's own glyphs and the tray's, kept in proportion. 100% is 16 and 14 px", 60.0, 180.0, "%", "barIconPct"),
        seg(
            p,
            "Icon rendering",
            match sm.as_str() {
                "curve" => "Vectors, drawn by the GPU at the screen's own resolution: sharp at any scale. The default. If an icon goes missing, try Image",
                "image" => "Each icon drawn once as an image and shared: light on memory, can look soft at fractional scales",
                "layer" => "Vectors in an offscreen layer per icon: smooth, but costly in memory",
                _ => "Raw vector edges, no smoothing",
            },
            &[("Vector", "curve"), ("Image", "image"), ("Multisampled", "layer"), ("Off", "off")],
            "iconSmoothing",
        ),
        info("File manager icons", "Set in the file manager itself: Ctrl + and Ctrl −, or Ctrl 0 to reset", "Ctrl +  /  Ctrl -"),
    ]
}

fn app_theming(p: &Prefs) -> Vec<Spec> {
    vec![
        header("Other applications", "Colours the shell can hand to things that are not part of it"),
        toggle(p, "Theme KDE applications", "Gives Dolphin, Ark and Okular this palette and accent. Colours only; the rest of kdeglobals is kept", "themeQtApps"),
        toggle(
            p,
            "Kvantum widget theme",
            "Makes and selects a Kvantum theme from this one, so KDE apps get the flat surfaces, radii and accent too. Needs kvantum; apps pick it up on restart",
            "kvantumTheme",
        ),
        info("Theme written to", "Regenerated whenever the theme changes", "Kvantum/Hyprshell/"),
        toggle(p, "Spotify theme", "Set up Spotify with Spicetify (spotify/install.sh in the hyprshell folder) and it follows this theme", "spotifyTheme"),
    ]
}

fn bar(p: &Prefs) -> Vec<Spec> {
    vec![
        slider(p, "Workspace switcher size", "The pills at the bar's left — usually the first thing to feel too big", 60.0, 160.0, "%", "workspaceScale"),
        slider(p, "Bar height", "Top bar thickness", 32.0, 56.0, "px", "barHeight"),
        toggle(p, "Auto-hide", "Slides away until the pointer reaches the top edge; windows get the space back", "barAutoHide"),
        slider_with(
            "Reveal delay",
            "How long the pointer rests on the top edge before the bar comes out. 0 is at once",
            0.0,
            1000.0,
            50.0,
            "ms",
            p.f("barRevealDelay"),
            |c, v| c.set("barRevealDelay", json!(v.round() as i64)),
        ),
        header("Text", "Body size moves everything together; the rest are offsets from it"),
        slider(p, "Body text", "The window title, the date and the status capsule", 8.0, 22.0, "px", "barFontSize"),
        slider(p, "App name", "The focused app's name, beside the workspace pills", 8.0, 28.0, "px", "barAppSize"),
        slider(p, "Window menu", "The \u{201C}Window\u{201D} button beside the app name, which opens the window\u{2019}s own actions", 8.0, 24.0, "px", "barMenuSize"),
        slider(p, "Window title", "The live title after the app name", 8.0, 22.0, "px", "barTitleSize"),
        slider(p, "Clock", "The time; the date follows body text", 8.0, 24.0, "px", "barClockSize"),
        slider(p, "Notification badge", "The count on the bell", 7.0, 16.0, "px", "barBadgeSize"),
        header("Behaviour", ""),
        seg_with("Clock format", "24-hour, or 12-hour with meridiem", &[("24 h", "24"), ("12 h", "12")], if p.b("clock24") { "24" } else { "12" }, |c, v| {
            c.set("clock24", json!(v == "24"))
        }),
        toggle(p, "System tray", "Collapsible group of background app icons", "showTray"),
        toggle(p, "Tray expanded", "Start with the tray group revealed", "trayOpen"),
        toggle(p, "Mail", "Unread mail in every inbox, while Mail is set up", "mailInBar"),
        toggle(p, "Task buttons", "Window list beside the app name", "showTasks"),
    ]
}

fn alt_tab(p: &Prefs) -> Vec<Spec> {
    let on = p.b("altTabEnabled");
    let m = hypr::alt_tab_mod(p);
    let mod_name = match m.as_str() {
        "SUPER" => "Super",
        "CTRL" => "Ctrl",
        _ => "Alt",
    };
    let clash = if on { hypr::alt_tab_clash(p) } else { String::new() };
    let hold = p.b("altTabHold");
    let scope = p.s("altTabScope");
    let style = p.s("altTabStyle");
    // binds.lua carries the chord, so a change to it is written there.
    let rebind = |c: &mut Ctx| hypr::write_binds(&c.p);
    vec![
        toggle_with(
            "Window switcher",
            &if on {
                format!("Hold {mod_name} and tap Tab to walk your windows, most recent first; let go to switch. A quick tap flips straight back to the window you were in before.")
            } else {
                format!("Off — {mod_name} + Tab goes to applications as usual")
            },
            on,
            move |c, v| {
                c.set("altTabEnabled", json!(v));
                rebind(c);
            },
        ),
        seg_with(
            "Shortcut",
            &if !clash.is_empty() {
                format!(
                    "{} — this takes the chord from {clash}, which stops working until you pick another modifier or rebind it in Keybinds",
                    hypr::alt_tab_accel(p, false)
                )
            } else if m == "CTRL" {
                "Ctrl + Tab, with Shift to go back. Browsers and editors use this chord to switch tabs, and will lose it".into()
            } else {
                format!("{}, with Shift to go back", hypr::alt_tab_accel(p, false))
            },
            &[("Alt", "ALT"), ("Super", "SUPER"), ("Ctrl", "CTRL")],
            &m,
            move |c, v| {
                c.set("altTabMod", json!(v));
                rebind(c);
            },
        ),
        seg(
            p,
            "Show windows from",
            match scope.as_str() {
                "all" => "Every workspace on every monitor. Picking a window on another workspace takes you there",
                "monitor" => "Every workspace on the monitor you are on",
                _ => "Only the workspace you are on, like Windows 11's default",
            },
            &[("This workspace", "workspace"), ("This monitor", "monitor"), ("Everywhere", "all")],
            "altTabScope",
        ),
        seg(
            p,
            "Style",
            match style.as_str() {
                "icons" => "Large app icons, and the chosen window's title beneath",
                "list" => "A column of titles — the most windows on screen at once",
                _ => "A picture of each window. Only the selected one moves; the rest are caught once when the switcher opens",
            },
            &[("Thumbnails", "thumbnails"), ("Icons", "icons"), ("List", "list")],
            "altTabStyle",
        ),
        slider(p, "Size", "Of the pictures, icons or rows", 60.0, 160.0, "%", "altTabSize"),
        toggle(p, "One entry per app", "One entry per app, with a count. Off lists every window", "altTabGroup"),
        toggle(p, "Scratchpad windows", "Include windows on a special workspace that is open over the one you are on", "altTabSpecial"),
        toggle(p, "Workspace tags", "Mark each window with its workspace — shown only when the list spans more than one", "altTabWorkspaceTags"),
        seg_with(
            "Switch when",
            &if hold {
                format!("You let go of {mod_name}, as on Windows")
            } else {
                format!("You press Enter or click a window. {mod_name} can be let go of and Tab keeps stepping")
            },
            &[(&format!("{mod_name} is released"), "hold"), ("Enter or a click", "sticky")],
            if hold { "hold" } else { "sticky" },
            |c, v| c.set("altTabHold", json!(v == "hold")),
        ),
        if hold {
            slider(
                p,
                "Appear after",
                &format!("A quick {mod_name}+Tab shorter than this switches without showing anything. Pressing Tab again shows it at once"),
                0.0,
                400.0,
                " ms",
                "altTabDelay",
            )
        } else {
            info("Appear after", "Not used while switching waits for Enter or a click", "")
        },
        info("Keys", "Tab, Shift+Tab or the arrows to move · Enter to switch · Esc to cancel · Delete or middle-click to close a window", ""),
        action("Try it", "Opens the switcher without switching — Esc or a click puts it away", "Show", |c| c.ui.tell.push("altTab next".into())),
    ]
}

fn dock(p: &Prefs) -> Vec<Spec> {
    let tb = p.taskbar();
    let pinned = serde_json::from_str::<Value>(&p.s("dockPinned")).ok().and_then(|v| v.as_array().map(|a| a.len())).unwrap_or(6);
    let mut r = vec![seg(
        p,
        "Style",
        if tb {
            "Windows 11's taskbar: along the bottom edge, with the top bar's status area at its right end and the top bar gone"
        } else {
            "A floating dock under the top bar, or Windows 11's taskbar in place of both"
        },
        &[("Dock", "dock"), ("Windows 11 taskbar", "taskbar")],
        "dockStyle",
    )];
    if tb {
        r.push(seg(p, "Taskbar alignment", "Where Start and the apps sit, as in Windows 11", &[("Center", "center"), ("Left", "left")], "taskbarAlign"));
    } else {
        r.push(seg(p, "Position", "Bottom slab or left column", &[("Bottom", "Bottom"), ("Left", "Left")], "dockPositionName"));
    }
    r.extend([
        slider(p, "Dock size", "Tile edge length — sets the dock's thickness", 34.0, 58.0, "px", "dockTileSize"),
        slider(p, "Icon size", "Glyph scale inside the tile — does not resize the dock", 30.0, 72.0, "%", "dockIconPct"),
        slider(p, "Spacing", "Space between the dock, your windows and the screen edge. 0 is flush", 0.0, 40.0, " px", "dockGapPx"),
        toggle(p, "Label for active app", "Expand the focused app into a labelled pill", "dockLabels"),
        toggle(
            p,
            "Window previews",
            if p.dock_left() {
                "Only with the dock along the bottom edge — on the left there is no room above a tile for the pictures"
            } else {
                "Hover a running app for a live picture of each of its windows, and click one to go to it"
            },
            "dockPreviews",
        ),
        seg(
            p,
            "Show windows from",
            if p.s("dockScope") == "all" {
                "Every workspace. An app running anywhere shows as running here, and clicking it takes you to its window"
            } else {
                "Only the workspace each monitor is showing, like Windows 11's desktops. An app whose windows are all elsewhere looks closed here, and clicking it opens one here"
            },
            &[("This workspace", "workspace"), ("All workspaces", "all")],
            "dockScope",
        ),
        toggle(p, "Settings button", "The gear at the end of the dock", "dockSettingsTile"),
        toggle(p, "Show desktop button", "The last tile: moves your windows out of the way, and back", "dockDesktopTile"),
        toggle(p, "Auto-hide", "Slide off the screen edge until the pointer reaches it", "dockAutoHide"),
        toggle(
            p,
            "Over fullscreen apps",
            if p.b("dockOverFullscreen") {
                "Reach the screen edge to bring the dock out over a fullscreen video, game or browser — it hides again as auto-hide does"
            } else {
                "Stays under fullscreen apps, coming out only with the launcher"
            },
            "dockOverFullscreen",
        ),
        info("Pinned apps", "Right-click a tile to change its app, unpin it, or pin a running one", format!("{pinned} pinned")),
        action("Reset pinned apps", "Back to the set this shell ships with", "Reset", |c| c.set("dockPinned", json!(""))),
    ]);
    r
}

fn launcher(p: &Prefs) -> Vec<Spec> {
    vec![
        header("Size", "Panel, tiles and icons scale together"),
        slider(p, "Overall size", "Everything at once — the panel, the tiles, the icons and the type, in proportion", 70.0, 220.0, "%", "launcherSize"),
        header("Stretch", "Optional, on top of the size above. These change one dimension and leave the content alone.").adv(),
        toggle(p, "Grow out of the dock", "The dock's pill stretches into the start menu, and shrinks back into it", "launcherMorph").adv(),
        slider(p, "Width", "More columns, not more space between them", 50.0, 200.0, "%", "launcherWide").adv(),
        slider(p, "Height", "More rows of apps, not more empty panel", 50.0, 200.0, "%", "launcherTall").adv(),
        slider(p, "Icon size", "The glyph inside each tile, without changing the tile", 50.0, 200.0, "%", "launcherIconScale").adv(),
        info(
            "Opens at",
            "What all of the above comes out to",
            format!(
                "{} × {} px, {} columns, {} rows, {} px icons",
                p.launcher_width(),
                p.launcher_height(),
                p.launcher_columns(),
                ((3.0 * p.launcher_height_stretch()).round() as i64).max(2),
                p.launcher_icon_size()
            ),
        )
        .adv(),
        header("Search", ""),
        toggle(
            p,
            "Search files",
            "Files and folders in your home folder, by name, after the apps and commands. Hidden folders, node_modules and caches are left out. Indexed when the launcher opens; let go after ten idle minutes.",
            "launcherFiles",
        ),
        header("Text", "").adv(),
        slider(p, "Entry names", "App and command names in the grid and results", 8.0, 26.0, "px", "launcherTitleSize").adv(),
        slider(p, "Secondary text", "Categories, hints and the section headings", 7.0, 22.0, "px", "launcherMetaSize").adv(),
    ]
}

fn keybinds(c: &Ctx) -> Vec<Spec> {
    let p = &c.p;
    let mut r = vec![
        header("The modifier key", "Every shortcut below is written with this in place of SUPER"),
        seg_with(
            "Windows key sends",
            "SUPER (Mod4) is what a standard PC keyboard sends. If no Super shortcut fires, a remapped layout, a Mac keyboard or an altwin: option has put it elsewhere",
            &[("Super", "SUPER"), ("Alt", "ALT"), ("Ctrl", "CTRL"), ("Hyper", "HYPER")],
            &p.s("modKey"),
            |c, v| {
                c.set("modKey", json!(v));
                hypr::write_binds(&c.p);
            },
        ),
        keybind(
            "Test it",
            "Press the key you want to use as Super. This reports what the keyboard actually sent, which is the answer to the row above.",
            if c.ui.mod_probe.is_empty() { "press a key" } else { &c.ui.mod_probe },
            true,
            |c, v| c.ui.mod_probe = if v.is_empty() { "—".into() } else { v },
        ),
        header("Shell", "Click a shortcut and press the keys you want. Escape cancels, Backspace restores the default."),
    ];
    for (i, a) in hypr::ACTIONS.iter().enumerate() {
        if i == 10 {
            r.push(header("Applications", ""));
        }
        if i == 13 {
            r.push(header("Windows", ""));
        }
        let key = a.key;
        r.push(keybind(
            a.n,
            &if hypr::is_custom(p, key) { format!("Changed from {}", a.def) } else { "Default".into() },
            &hypr::display_accel(p, key),
            false,
            move |c, v| hypr::set_accel(&mut c.p, key, &v),
        ));
    }
    r.push(header("The generated file", "").adv());
    r.push(info("Where these are written", "Read last by hyprland.lua, so they replace the defaults without touching your config", "hypr/binds.lua").adv());
    r.push(action("Reset all shortcuts", "Back to the defaults this shell ships", "Reset", |c| hypr::reset_binds(&mut c.p)).adv());
    r
}

fn fonts(p: &Prefs) -> Vec<Spec> {
    let sub = p.s("subpixel");
    vec![
        header("Scale", "One multiplier over every text size in the shell"),
        slider(p, "Interface scale", "The bar, dock, launcher, panels and this window. 100% is the design's size", 75.0, 150.0, "%", "fontScale"),
        header("Typefaces", "Edit theme.json to change these — the shell reloads them live"),
        info("Interface", "Everything but the readouts below. Inter, or the system sans without it", "Inter"),
        info("Monospaced", "Clock digits, the hex field in the colour picker, and the terminal's own config", "JetBrains Mono"),
        header("Text rendering", "How glyphs are drawn onto pixels, which is most of what makes text look sharp or soft").adv(),
        seg_with(
            "Rasteriser",
            "Sharp snaps stems to pixels. Smooth looks better at 125% or 150% scaling",
            &[("Sharp", "sharp"), ("Smooth", "smooth")],
            if p.b("textNative") { "sharp" } else { "smooth" },
            |c, v| c.set("textNative", json!(v == "sharp")),
        )
        .adv(),
        seg(
            p,
            "Subpixel order",
            "Your panel's stripe order — Grayscale for most OLEDs. Every app picks it up on restart",
            &[("Leave alone", ""), ("Grayscale", "none"), ("RGB", "rgb"), ("BGR", "bgr")],
            "subpixel",
        )
        .adv(),
        seg_with(
            "Vertical panels",
            "Set the order above for a display whose subpixels stack instead of sitting side by side",
            &[("Horizontal", ""), ("VRGB", "vrgb"), ("VBGR", "vbgr")],
            if sub == "vrgb" || sub == "vbgr" { &sub } else { "" },
            |c, v| {
                if !v.is_empty() {
                    c.set("subpixel", json!(v));
                } else if matches!(c.p.s("subpixel").as_str(), "vrgb" | "vbgr") {
                    c.set("subpixel", json!("rgb"));
                }
            },
        )
        .adv(),
        toggle(p, "Hinting", "Snaps stems to whole pixels. Off is truer to the typeface, slightly softer", "fontHinting").adv(),
        info("Written to", "Delete this file, or set the order back to Leave alone, to hand the decision back to fontconfig", "fontconfig/conf.d/99-hyprshell-text.conf").adv(),
        header("Sizes in use", "What each one comes out at with the scale above applied").adv(),
        info("Bar labels", "Set in Shell → Bar", format!("{} px", p.fs(p.f("barFontSize")))).adv(),
        info("Settings rows", "Row titles in this window", format!("{} px", p.fs(13.0))).adv(),
        info("Row descriptions", "The smaller grey line under each title", format!("{} px", p.fs(12.0))).adv(),
        info("Menus and tooltips", "Dock tooltips, dropdown options, context menus", format!("{} px", p.fs(12.0))).adv(),
    ]
}

fn clipboard(p: &Prefs) -> Vec<Spec> {
    vec![
        toggle(p, "Keep clipboard history", "Everything copied, for Super+Shift+V. In memory for this login only; passwords are never kept", "clipboardHistory"),
        slider(p, "Entries kept", "Older ones drop off the end. Images count too (at most 20 of them).", 10.0, 500.0, "", "clipboardMax"),
        info("In the history now", "Shown with Super+Shift+V", "—"),
        action("Forget everything", "Empties the history now", "Clear", |c| c.ui.tell.push("clearClipboard".into())),
    ]
}

fn screenshots(p: &Prefs) -> Vec<Spec> {
    vec![
        toggle(
            p,
            "Show the pointer",
            if p.b("capturePointer") {
                "The mouse pointer is in the picture"
            } else {
                "Kept out of the picture — hidden for the moment it is taken, even where Hyprland draws it into the screen itself"
            },
            "capturePointer",
        ),
        toggle(p, "Freeze the screen", "Menus, tooltips and video hold still while you choose what to take", "captureFreeze"),
        seg_with("Delay", "How long after asking the picture is taken", &[("Off", "0"), ("3 s", "3"), ("5 s", "5"), ("10 s", "10")], &p.i("captureDelay").to_string(), |c, v| {
            c.set("captureDelay", json!(v.parse::<i64>().unwrap_or(0)))
        }),
        toggle_with(
            "Open the editor afterwards",
            "Straight into marking it up; otherwise it's saved and copied, and a notification offers the editor",
            p.s("captureEdit") == "always",
            |c, v| c.set("captureEdit", json!(if v { "always" } else { "ask" })),
        ),
        info("Saved to", "And copied to the clipboard", "Pictures/Screenshots"),
    ]
}

fn notifications(p: &Prefs) -> Vec<Spec> {
    let days = p.i("notifHistoryDays");
    vec![
        header("Apps", "Everything that has sent a notification. Switch one off to block it: nothing shown, nothing kept"),
        panel("notifApps"),
        header("Do not disturb", ""),
        toggle(p, "Do not disturb", "Silence banners, keep them in the center", "dnd"),
        toggle(p, "Let urgent ones through", "Alarms, a battery about to run out and other critical notifications still show while quiet", "focusUrgent"),
        header("Focus", "Quiet hours, on a schedule"),
        panel("focus"),
        header("The center", ""),
        toggle(p, "Badge counts", "Numeric badge on the bar bell", "badges"),
        seg(p, "Grouping", "Stack by source app, or by arrival time", &[("App", "App"), ("Time", "Time")], "grouping"),
        slider(p, "Banner timeout", "How long a banner stays up before it retires to the center", 2.0, 20.0, "s", "popupTimeout"),
        info("Waiting in the center", "Notifications the shell is currently holding", "—"),
        toggle(
            p,
            "Keep a history",
            "Every notification, kept after it is dismissed, to search from the center's History. Stored for you alone; turning it off forgets everything.",
            "notifHistory",
        ),
        seg_with(
            "Keep for",
            "Older ones are forgotten",
            &[("1 day", "1"), ("7 days", "7"), ("30 days", "30")],
            if days == 1 {
                "1"
            } else if days == 30 {
                "30"
            } else {
                "7"
            },
            |c, v| c.set("notifHistoryDays", json!(v.parse::<i64>().unwrap_or(7))),
        ),
        action("Forget the history", "Everything kept so far", "Clear", |c| c.ui.tell.push("clearHistory".into())),
    ]
}

/// Settings → Network: the Wi-Fi panel, and Wi-Fi performance through
/// scripts/wifi-tune.sh (WifiTune.qml).
fn wifi_tune() -> std::path::PathBuf {
    hyprshell_kit::config_dir().join("quickshell/hyprshell/scripts/wifi-tune.sh")
}
fn network() -> Vec<Spec> {
    let mut r = vec![panel("wifi")];
    let Some(status) = system::run("bash", &[&wifi_tune().display().to_string(), "--status"]) else { return r };
    let field = |k: &str| status.lines().find_map(|l| l.split_once('\t').filter(|(a, _)| *a == k).map(|(_, b)| b.to_string())).unwrap_or_default();
    let (backend, iwd, powersave) = (field("backend"), field("iwd") == "yes", field("powersave"));
    let tune = |args: Vec<&'static str>, done: &'static str| {
        move |c: &mut Ctx, _v: bool| {
            let mut cmd = std::process::Command::new("pkexec");
            cmd.arg("bash").arg(wifi_tune()).args(&args);
            let ok = cmd.status().map(|s| s.code());
            c.ui.toast = Some(match ok {
                Ok(Some(0)) => done.to_string(),
                Ok(Some(126)) | Ok(Some(127)) => "Not changed: the password wasn't given".into(),
                _ => "That didn't work".into(),
            });
        }
    };
    r.push(header("Wi-Fi performance", ""));
    let on_iwd = backend == "iwd";
    r.push(toggle_with(
        "Faster Wi-Fi (iwd)",
        &if on_iwd {
            "On: NetworkManager uses iwd, which finds networks and joins them faster. Your saved networks are kept; a university (802.1X) one may ask for its sign-in again".to_string()
        } else {
            format!("NetworkManager uses wpa_supplicant now. iwd scans and joins faster; Wi-Fi reconnects by itself when it switches{}", if iwd { "" } else { ". It's installed first" })
        },
        on_iwd,
        move |c, v| {
            if v {
                tune(vec!["--iwd", "on"], "Wi-Fi now goes through iwd. Wi-Fi reconnects by itself")(c, v)
            } else {
                tune(vec!["--iwd", "off"], "Wi-Fi goes through wpa_supplicant again")(c, v)
            }
        },
    ));
    r.push(toggle_with(
        "Wi-Fi power saving",
        if powersave == "off" {
            "Off: steadier, quicker to wake, at a little battery"
        } else {
            "Turning it off is the usual cure for dropouts and slow reconnects on this laptop's Wi-Fi"
        },
        powersave != "off",
        move |c, v| {
            if v {
                tune(vec!["--powersave", "on"], "Power saving back on")(c, v)
            } else {
                tune(vec!["--powersave", "off"], "Power saving off: steadier Wi-Fi, a little more battery")(c, v)
            }
        },
    ));
    r
}

fn power(p: &Prefs) -> Vec<Spec> {
    let profiles = system::power_profiles();
    let has_perf = profiles.iter().any(|x| x == "performance");
    let mut r = vec![header(
        "Profile",
        if has_perf { "What the firmware is asked to prioritise" } else { "power-profiles-daemon is not available, so this machine has one profile" },
    )];
    if has_perf {
        r.push(seg_with(
            "Power profile",
            "Balanced suits most work; Performance costs battery and runs hotter",
            &[("Saver", "power-saver"), ("Balanced", "balanced"), ("Performance", "performance")],
            &system::power_profile().unwrap_or_default(),
            |_, v| system::set_power_profile(&v),
        ));
    }
    let mode = p.s("saverMode");
    r.push(header(
        "Battery saver",
        match mode.as_str() {
            "never" => "Off",
            "always" => "Always on",
            "low" => "On below the charge set here",
            _ => "On whenever you're on battery",
        },
    ));
    r.push(seg(
        p,
        "Turn on",
        "When the desktop's costliest effects switch off",
        &[("On battery", "battery"), ("Low battery", "low"), ("Always", "always"), ("Never", "never")],
        "saverMode",
    ));
    if mode == "low" {
        r.push(slider(p, "Below", "The charge at which it comes on", 10.0, 80.0, "%", "saverBelow"));
    }
    if mode != "never" {
        r.extend([
            toggle(p, "Blur", "Off: the costliest thing Hyprland draws, redone whenever anything behind it changes", "saverBlur"),
            toggle(p, "Window shadows", "Off", "saverShadows"),
            toggle(p, "See-through inactive windows", "Off: drawn solid, so nothing behind them has to be blurred", "saverOpacity"),
            toggle(p, "Window animations", "Off: windows open, close and move instantly", "saverAnimations"),
            toggle(p, "Shell motion", "Off: menus and panels appear at once, the music bars stand still", "saverStill"),
            toggle(p, "Power saver profile", "Switch the power profile too, and back afterwards", "saverProfile"),
        ]);
    }
    let bat = system::battery();
    r.push(header("Battery", if bat.is_some() { "" } else { "No battery — this is a desktop" }));
    if let Some(b) = bat {
        r.push(meter(
            "Charge",
            match b.state.as_str() {
                "Charging" => "Charging",
                "Full" => "Full",
                _ => "On battery",
            },
            b.percent,
            &format!("{}%", (b.percent * 100.0).round()),
            false,
        ));
        r.push(info("Health", "Capacity against when it was new", b.health.map(|h| format!("{}%", h.round())).unwrap_or("—".into())));
    }
    r.push(header("Screen", "Backlight and colour temperature"));
    match system::brightness() {
        Some((dev, v)) => r.push(slider_with("Brightness", &dev, 1.0, 100.0, 1.0, "%", (v * 100.0).round(), |_, v| system::set_brightness(v / 100.0))),
        None => r.push(info("Brightness", "No backlight device was found", "—")),
    }
    r.extend(crate::display::night_rows(p));
    r
}

fn hyprland(p: &Prefs) -> Vec<Spec> {
    let windows = p.s("windowMode") == "windows";
    let set_frame = |key: &'static str| move |c: &mut Ctx, v: f64| {
        c.set(key, json!(v.round() as i64));
        frame(c);
    };
    let tog_frame = |key: &'static str| move |c: &mut Ctx, v: bool| {
        c.set(key, json!(v));
        frame(c);
    };
    let blur_mode = p.s("shellBlurMode");
    vec![
        header("Layout", "How new windows are placed. Applied immediately."),
        seg_with(
            "Window behaviour",
            if windows {
                "Like Windows 11: windows float and open centred, snap to edges, and Super + arrows snap them to halves and quarters (Up maximises, Down restores). The taskbar comes with it; Dock → Style changes that on its own"
            } else {
                "Hyprland's tiling: windows share the screen, and Super + arrows move the focus"
            },
            &[("Tiling", "tiling"), ("Windows 11", "windows")],
            &p.s("windowMode"),
            |c, v| {
                c.set("windowMode", json!(v));
                c.set("dockStyle", json!(if v == "windows" { "taskbar" } else { "dock" }));
                input(c);
            },
        ),
        seg_with(
            "Tiling layout",
            "Dwindle splits the focused window; master keeps one large window beside a stack",
            &[("Dwindle", "dwindle"), ("Master", "master")],
            &p.s("hyprLayout"),
            |c, v| {
                c.set("hyprLayout", json!(v));
                frame(c);
            },
        ),
        toggle_with(
            "Focus follows mouse",
            if windows {
                "With Windows 11 behaviour a click focuses a window, as on Windows; scrolling still reaches the one under the pointer"
            } else {
                "Move the pointer onto a window to focus it, without clicking"
            },
            p.i("followMouse") != 0,
            |c, v| {
                c.set("followMouse", json!(if v { 1 } else { 0 }));
                input(c);
            },
        ),
        header("Gaps and borders", ""),
        slider_with("Inner gap", "Between tiled windows", 0.0, 40.0, 1.0, "px", p.f("gapsIn"), set_frame("gapsIn")),
        slider_with("Outer gap", "Between windows and the screen edge", 0.0, 60.0, 1.0, "px", p.f("gapsOut"), set_frame("gapsOut")),
        slider_with("Border width", "0 removes window borders entirely", 0.0, 8.0, 1.0, "px", p.f("borderSize"), set_frame("borderSize")),
        toggle_with("Border follows accent", "The focused window's border takes the shell's accent colour", p.b("borderFollowsAccent"), tog_frame("borderFollowsAccent")),
        slider_with(
            "Active border brightness",
            &format!("A darker or lighter shade of the accent. 100% is the accent{}", if p.b("borderFollowsAccent") { "" } else { ". Only while Border follows accent is on" }),
            20.0,
            160.0,
            1.0,
            "%",
            p.f("activeBorderPct"),
            set_frame("activeBorderPct"),
        ),
        slider_with(
            "Inactive border brightness",
            "Every other window's border. Lower is darker, higher is lighter; 100% is the default",
            0.0,
            200.0,
            1.0,
            "%",
            p.f("inactiveBorderPct"),
            set_frame("inactiveBorderPct"),
        ),
        slider_with("Corner radius", "At 100% Corner rounding; Appearance scales them with everything else", 0.0, 24.0, 1.0, "px", p.f("hyprRounding"), set_frame("hyprRounding")),
        header("Effects", "Blur and shadows are the expensive ones on a weak GPU"),
        toggle_with("Blur behind windows", "Applies to anything translucent", p.b("hyprBlur"), tog_frame("hyprBlur")),
        slider_with("Blur size", "Radius of each pass", 1.0, 20.0, 1.0, "", p.f("hyprBlurSize"), set_frame("hyprBlurSize")),
        slider_with("Blur passes", "More passes look smoother and cost more", 1.0, 5.0, 1.0, "", p.f("hyprBlurPasses"), set_frame("hyprBlurPasses")),
        seg_with(
            "Blur behind the shell",
            match blur_mode.as_str() {
                "live" => "Bar, dock and menus blur whatever is behind them, always — menus may drop frames opening on a high refresh rate",
                "wallpaper" => "Everything blurs the wallpaper, even over a window — the smoothest, but a menu over an app shows the desktop, not the app",
                _ => "Bar and dock blur what is behind them; menus blur the windows under them, or the wallpaper on a bare desktop",
            },
            &[("Auto", "auto"), ("Wallpaper", "wallpaper"), ("Live", "live")],
            &blur_mode,
            |c, v| {
                c.set("shellBlurMode", json!(v));
                hypr::apply_shell_blur(&c.p);
            },
        ),
        toggle_with("Window shadows", "A drop shadow under floating windows", p.b("hyprShadow"), tog_frame("hyprShadow")),
        slider_with("Inactive opacity", "How much unfocused windows fade back. 100% leaves them solid.", 40.0, 100.0, 1.0, "%", p.f("hyprInactiveOpacity"), set_frame("hyprInactiveOpacity")),
        header("Animations", ""),
        toggle_with("Animations", "Off is the fastest the compositor gets", p.b("hyprAnimEnabled"), tog_frame("hyprAnimEnabled")),
        slider_with("Speed", "Higher is quicker. 100% is what this shell ships.", 25.0, 300.0, 1.0, "%", p.f("hyprAnimSpeed"), set_frame("hyprAnimSpeed")),
        header("The config file", "").adv(),
        info("Where these are written", "Applied live, saved to theme.json and re-applied after every reload. hyprland.lua is never rewritten", "hypr/hyprland.lua").adv(),
        action("Reload Hyprland", "Re-read hyprland.lua, then put these back on top of it", "Reload", |c| {
            hypr::reload();
            std::thread::sleep(std::time::Duration::from_millis(600));
            hypr::apply_all(&c.p);
        })
        .adv(),
    ]
}

fn keyboard(p: &Prefs) -> Vec<Spec> {
    let keymap = system::info().keymap;
    let keymap = if keymap.is_empty() { "—".to_string() } else { keymap };
    let set_in = |key: &'static str| move |c: &mut Ctx, v: f64| {
        c.set(key, json!(v.round() as i64));
        input(c);
    };
    vec![
        info("Layout", "xkb layout list, comma-separated — e.g. us,de", &keymap),
        slider_with("Repeat rate", "Repeats per second while a key is held", 10.0, 60.0, 1.0, "/s", p.f("repeatRate"), set_in("repeatRate")),
        slider_with("Repeat delay", "Milliseconds before a held key starts repeating", 150.0, 900.0, 1.0, "ms", p.f("repeatDelay"), set_in("repeatDelay")),
        toggle_with("Num Lock at start-up", "Turn the numeric keypad on when Hyprland starts", p.b("numlock"), |c, v| {
            c.set("numlock", json!(v));
            input(c);
        }),
        seg_with(
            "Focus follows mouse",
            if p.s("windowMode") == "windows" {
                "Whether moving the pointer over a window focuses it. With Windows 11 behaviour, Full works as Loose: a click focuses"
            } else {
                "Whether moving the pointer over a window focuses it"
            },
            &[("Off", "0"), ("Loose", "2"), ("Full", "1")],
            &p.i("followMouse").to_string(),
            |c, v| {
                c.set("followMouse", json!(v.parse::<i64>().unwrap_or(1)));
                input(c);
            },
        ),
        info("Keymap", "What the compositor currently has loaded", &keymap),
    ]
}

fn tog_in(key: &'static str) -> impl Fn(&mut Ctx, bool) {
    move |c: &mut Ctx, v: bool| {
        c.set(key, json!(v));
        input(c);
    }
}

fn mouse(p: &Prefs) -> Vec<Spec> {
    vec![
        slider_with(
            "Pointer speed",
            "For mice, -100 slowest to +100 fastest. The touchpad has its own, under Touchpad",
            -100.0,
            100.0,
            1.0,
            "",
            (p.f("sensitivity") * 100.0).round(),
            |c, v| {
                c.set("sensitivity", json!(v / 100.0));
                input(c);
            },
        ),
        seg_with(
            "Acceleration",
            "Adaptive speeds up with fast movement; flat is 1:1, the choice for games and precise work",
            &[("Adaptive", "adaptive"), ("Flat", "flat")],
            &p.s("accelProfile"),
            |c, v| {
                c.set("accelProfile", json!(v));
                input(c);
            },
        ),
        toggle_with("Left-handed", "Swap the primary and secondary buttons", p.b("leftHanded"), tog_in("leftHanded")),
        toggle_with("Natural scrolling", "Content follows the wheel rather than the view", p.b("mouseNaturalScroll"), tog_in("mouseNaturalScroll")),
        slider_with("Scroll speed", "Multiplier applied to every wheel step", 25.0, 300.0, 1.0, "%", (p.f("mouseScrollFactor") * 100.0).round(), |c, v| {
            c.set("mouseScrollFactor", json!(v / 100.0));
            input(c);
        }),
        toggle_with("Pointer hides while typing", "Hide the cursor on the next key press", p.b("hideCursorOnKey"), tog_in("hideCursorOnKey")),
        slider_with("Hide when idle", "Seconds of stillness before the pointer disappears — 0 never", 0.0, 30.0, 1.0, "s", p.f("cursorTimeout"), |c, v| {
            c.set("cursorTimeout", json!(v.round() as i64));
            input(c);
        }),
    ]
}

fn touchpad(p: &Prefs) -> Vec<Spec> {
    let (pointers, pads) = hypr::pointers();
    vec![
        slider_with(
            "Pointer speed",
            "For the touchpad only, -100 slowest to +100 fastest. The mouse has its own, under Mouse",
            -100.0,
            100.0,
            1.0,
            "",
            (p.pad_sensitivity_now() * 100.0).round(),
            |c, v| {
                c.set("padSensitivity", json!(v / 100.0));
                hypr::apply_touchpads(&c.p);
            },
        ),
        seg_with("Acceleration", "Adaptive speeds up with fast movement; flat is 1:1", &[("Adaptive", "adaptive"), ("Flat", "flat")], &p.pad_accel_now(), |c, v| {
            c.set("padAccelProfile", json!(v));
            hypr::apply_touchpads(&c.p);
        }),
        info(
            "Touchpads found",
            &if !pads.is_empty() {
                "These take the two settings above; every other pointer takes the Mouse ones".to_string()
            } else {
                format!(
                    "None found by name, so every pointer is using the Mouse speed and acceleration. {}",
                    if pointers.is_empty() { String::new() } else { format!("Pointers seen: {}", pointers.join(", ")) }
                )
            },
            if pads.is_empty() { "none".to_string() } else { pads.join(", ") },
        ),
        toggle_with("Tap to click", "A tap counts as a click without pressing down", p.b("tapToClick"), tog_in("tapToClick")),
        toggle_with("Tap and drag", "Tap then hold to drag, without a physical click", p.b("tapAndDrag"), tog_in("tapAndDrag")),
        toggle_with("Drag lock", "Keep dragging through a brief lift of the finger", p.b("dragLock"), tog_in("dragLock")),
        toggle_with("Natural scrolling", "Content follows finger direction", p.b("padNaturalScroll"), tog_in("padNaturalScroll")),
        slider_with("Scroll speed", "Multiplier applied to two-finger scrolling", 25.0, 300.0, 1.0, "%", (p.f("padScrollFactor") * 100.0).round(), |c, v| {
            c.set("padScrollFactor", json!(v / 100.0));
            input(c);
        }),
        toggle_with("Disable while typing", "Ignore the pad briefly after a key press", p.b("disableWhileTyping"), tog_in("disableWhileTyping")),
        seg_with(
            "Right click",
            "Two-finger click, or a press in the bottom-right corner",
            &[("Two fingers", "finger"), ("Corner", "corner")],
            if p.b("clickfinger") { "finger" } else { "corner" },
            |c, v| {
                c.set("clickfinger", json!(v == "finger"));
                input(c);
            },
        ),
        seg_with("Tap button map", "Which button two- and three-finger taps send", &[("L R M", "lrm"), ("L M R", "lmr")], &p.s("tapButtonMap"), |c, v| {
            c.set("tapButtonMap", json!(v));
            input(c);
        }),
        toggle_with("Middle-click emulation", "Left and right together counts as a middle click", p.b("middleEmulation"), tog_in("middleEmulation")),
    ]
}

fn about(p: &Prefs) -> Vec<Spec> {
    let i = system::info();
    let ipc = !hypr::json("version").is_null();
    let spaces = hypr::json("workspaces").as_array().map(|a| a.iter().filter(|w| w["id"].as_i64().unwrap_or(0) > 0).count()).unwrap_or(0);
    let focused = hypr::json("activeworkspace")["id"].as_i64().unwrap_or(0);
    let every = p.i("updatesEvery");
    vec![
        info("Device", &i.distro, if i.host.is_empty() { "—".into() } else { i.host.clone() }),
        info("Processor", &i.cpu_label, if i.cpu_model.is_empty() { "—".into() } else { i.cpu_model.clone() }),
        meter("Memory", &i.mem_label, i.mem_ratio, &format!("{}%", (i.mem_ratio * 100.0).round()), true),
        meter("Storage", &i.disk_label, i.disk_ratio, &format!("{}%", (i.disk_ratio * 100.0).round()), true),
        info("Kernel", "Running kernel release", if i.kernel.is_empty() { "—".into() } else { i.kernel.clone() }),
        info("Compositor", "Wayland session", if i.hyprland.is_empty() { "hyprland".into() } else { format!("hyprland {}", i.hyprland) }),
        info(
            "Compositor link",
            if ipc { "Quickshell's own Hyprland IPC — live events" } else { "No IPC; falling back to polling hyprctl" },
            if ipc { "connected" } else { "degraded" },
        ),
        info("Workspaces seen", &format!("What the bar's pills are drawn from — focused is {focused}"), format!("{spaces} of {} slots", spaces.max(5))),
        info("Uptime", "Since last boot", &i.uptime),
        info("Shell config", &hyprshell_kit::theme::theme_path().display().to_string(), "theme.json"),
        action("Reload shell", "Re-read the QML tree without logging out", "Reload", |c| c.ui.tell.push("reloadShell".into())),
        header("Updates", ""),
        action("Pending updates", "Opens the updates panel", "Show", |c| c.ui.tell.push("toggleUpdates".into())),
        toggle(p, "Check for updates", "In the background, without a password (checkupdates syncs a copy of the databases)", "updatesAuto"),
        seg_with("How often", "Hours between checks", &[("1", "1"), ("3", "3"), ("6", "6"), ("12", "12"), ("24", "24")], &every.to_string(), |c, v| {
            c.set("updatesEvery", json!(v.parse::<i64>().unwrap_or(3)))
        }),
        toggle(p, "Say when there are some", "A notification when updates first appear", "updatesNotify"),
        toggle(p, "Show in the bar", "The package button and its count, while there are updates", "updatesInBar"),
    ]
}

// ── advanced and cards (Settings.shownRows, cardPositions) ───────────────
const ADV_SECTIONS: &[(&str, &[&str])] = &[
    ("Appearance", &["Scrolling"]),
    ("Launcher", &["Stretch", "Text"]),
    ("Keybinds", &["The generated file"]),
    ("Fonts", &["Text rendering", "Sizes in use"]),
    ("Hyprland", &["The config file"]),
    ("Laptop", &["Panel and firmware"]),
];

fn mark_advanced(pane: &str, rows: &mut [Spec]) {
    let secs = ADV_SECTIONS.iter().find(|s| s.0 == pane).map(|s| s.1).unwrap_or(&[]);
    let mut in_adv = false;
    for r in rows.iter_mut() {
        if r.row.kind == "header" {
            in_adv = secs.contains(&r.row.n.as_str());
        }
        if in_adv {
            r.adv = true;
        }
    }
}

/// The basic rows, then "Show advanced settings", then (when open) the
/// advanced ones under their sections.
pub fn shown_rows(pane: &str, mut rows: Vec<Spec>, open: bool) -> Vec<Spec> {
    mark_advanced(pane, &mut rows);
    if !rows.iter().any(|r| r.adv) {
        return rows;
    }
    let mut basic: Vec<Spec> = vec![];
    let mut adv: Vec<Spec> = vec![];
    let mut section: Option<(String, String)> = None;
    let mut adv_section_done: Option<String> = None;
    for r in rows {
        if r.row.kind == "header" {
            section = Some((r.row.n.to_string(), r.row.s.to_string()));
            if r.adv {
                adv_section_done = Some(r.row.n.to_string());
                adv.push(r);
            } else {
                basic.push(r);
            }
            continue;
        }
        if r.adv {
            if let Some((n, s)) = &section {
                if adv_section_done.as_deref() != Some(n.as_str()) {
                    adv.push(header(n, s));
                    adv_section_done = Some(n.clone());
                }
            }
            adv.push(r);
        } else {
            basic.push(r);
        }
    }
    // A section left with only its header goes.
    let mut tidy: Vec<Spec> = vec![];
    let n = basic.len();
    let kinds: Vec<bool> = basic.iter().map(|r| r.row.kind == "header").collect();
    for (i, r) in basic.into_iter().enumerate() {
        if kinds[i] && (i + 1 >= n || kinds[i + 1]) {
            continue;
        }
        tidy.push(r);
    }
    let count = adv.iter().filter(|r| r.row.kind != "header").count();
    tidy.push(header("Advanced", ""));
    let p = pane.to_string();
    tidy.push(toggle_with(
        "Show advanced settings",
        &if count == 1 { "One more setting, for experts and unusual hardware".to_string() } else { format!("{count} more settings, for experts and unusual hardware") },
        open,
        move |c, v| {
            if v {
                c.ui.adv_open.insert(p.clone());
            } else {
                c.ui.adv_open.remove(&p);
            }
        },
    ));
    if open {
        tidy.extend(adv);
    }
    tidy
}

pub fn card_positions(rows: &mut [Spec]) {
    let free = ["preview", "panel", "gallery", "monitors"];
    let n = rows.len();
    let mut i = 0;
    while i < n {
        let k = rows[i].row.kind.to_string();
        if k == "header" {
            rows[i].row.card = "h".into();
            i += 1;
            continue;
        }
        if free.contains(&k.as_str()) {
            rows[i].row.card = "free".into();
            i += 1;
            continue;
        }
        let mut j = i;
        while j < n && rows[j].row.kind != "header" && !free.contains(&rows[j].row.kind.as_str()) {
            j += 1;
        }
        for (k, r) in rows.iter_mut().enumerate().take(j).skip(i) {
            r.row.card = if j - i == 1 {
                "only"
            } else if k == i {
                "first"
            } else if k == j - 1 {
                "last"
            } else {
                "middle"
            }
            .into();
        }
        i = j;
    }
}

// ── search (Settings.searchIndex, rankSettings) ─────────────────────────
pub struct Entry {
    pub pane: String,
    pub n: String,
    pub s: String,
    pub section: String,
    pub is_pane: bool,
}

pub fn search_index(c: &Ctx) -> Vec<Entry> {
    let mut out = vec![];
    for cat in categories() {
        for p in cat.items {
            let title = pane_title(p);
            out.push(Entry {
                pane: p.into(),
                n: title.clone(),
                s: format!("{}{}", pane_note(p), if title != p { format!(" {p}") } else { String::new() }),
                section: String::new(),
                is_pane: true,
            });
            // The live panes (Display, Touchpad, About) ask the machine;
            // they're found by their page.
            if matches!(p, "Display" | "Touchpad" | "About" | "Keyboard" | "Power") {
                continue;
            }
            let mut section = String::new();
            for r in rows_for(p, c) {
                if r.row.n.is_empty() {
                    continue;
                }
                if r.row.kind == "header" {
                    section = r.row.n.to_string();
                    continue;
                }
                out.push(Entry { pane: p.into(), n: r.row.n.to_string(), s: r.row.s.to_string(), section: section.clone(), is_pane: false });
            }
        }
    }
    out
}

pub fn rank<'a>(q: &str, idx: &'a [Entry], limit: usize) -> Vec<&'a Entry> {
    let squash = |t: &str| t.chars().filter(|c| !"-+ _.".contains(*c)).collect::<String>();
    let q = q.trim().to_lowercase();
    let qs = squash(&q);
    let mut seen = std::collections::HashSet::new();
    let mut hits: Vec<(f64, &Entry)> = vec![];
    for e in idx {
        let n = e.n.to_lowercase();
        let score = if n.starts_with(&q) {
            0.0
        } else if n.contains(&format!(" {q}")) {
            1.0
        } else if n.contains(&q) || (qs.len() >= 2 && squash(&n).contains(&qs)) {
            2.0
        } else if q.len() >= 3 && (e.section.to_lowercase().contains(&q) || e.s.to_lowercase().contains(&q)) {
            3.0
        } else {
            continue;
        };
        if !seen.insert(format!("{}/{}", e.pane, e.n)) {
            continue;
        }
        hits.push((score + if e.is_pane { -0.5 } else { 0.0 }, e));
    }
    hits.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal).then(a.1.n.len().cmp(&b.1.n.len())));
    hits.into_iter().take(limit).map(|h| h.1).collect()
}


// ── Laptop (Settings.qml's "Laptop", services/Rog.qml) ──────────────────
const PROFILE_NAMES: [(i64, &str); 5] = [(0, "Balanced"), (1, "Performance"), (2, "Quiet"), (3, "Low power"), (4, "Custom")];
const KBD_MODES: [(i64, &str); 12] = [
    (0, "Static"), (1, "Breathe"), (2, "Rainbow"), (3, "Wave"), (4, "Star"), (5, "Rain"),
    (6, "Highlight"), (7, "Laser"), (8, "Ripple"), (10, "Pulse"), (11, "Comet"), (12, "Flash"),
];
const GPU: [(&str, &str, &str); 3] = [
    ("integrated", "Integrated", "Only the built-in graphics; the NVIDIA GPU is off. Longest battery life."),
    ("hybrid", "Hybrid", "The built-in graphics, with the NVIDIA GPU for what asks for it."),
    ("ultimate", "Ultimate", "The NVIDIA GPU drives the screen directly. Fastest, most power."),
];
/// The firmware switches worth a toggle, with what they are called.
const ATTRS: [(&str, &str, &str); 6] = [
    ("panel_overdrive", "Panel overdrive", "Faster pixel response; can show faint ghosting"),
    ("mini_led_mode", "MiniLED dimming", "Local dimming on a MiniLED panel"),
    ("boot_sound", "Boot sound", "The chime at power on"),
    ("mcu_powersave", "Low-power standby", "Less battery drain while suspended or off"),
    ("screen_auto_brightness", "Automatic panel brightness", "The panel's own ambient adjustment"),
    ("panel_hd_mode", "Panel HD mode", "The panel's high-resolution mode"),
];

/// Rog.setKbdMode: the effect, keeping its other settings.
pub fn kbd_mode_cmd(rog: &Value, mode: i64, colour: &str) -> Value {
    let e = &rog["aura"][0]["effect"];
    let or = |k: &str, d: &str| e[k].as_str().unwrap_or(d).to_string();
    json!({
        "cmd": "rog-kbd-mode", "mode": mode,
        "colour": if colour.is_empty() { or("colour", "#ffffff") } else { colour.to_string() },
        "colour2": or("colour2", "#000000"), "speed": or("speed", "Med"), "direction": or("direction", "Right"),
    })
}

/// The shell's accent, as #rrggbb.
pub fn accent_hex() -> String {
    let a = hyprshell_kit::theme::Palette::load().accent;
    format!("#{:02x}{:02x}{:02x}", a.red(), a.green(), a.blue())
}

fn laptop(c: &Ctx) -> Vec<Spec> {
    let r = &c.ui.rog;
    if r["available"] != true {
        return vec![header(
            if r.is_null() { "Looking for asusd…" } else { "Not available" },
            if r.is_null() {
                "Asking asusd what this laptop has."
            } else {
                "No asusd on this machine. On an ASUS ROG or TUF laptop, install asusctl and start asusd (systemctl enable --now asusd), and this fills in."
            },
        )];
    }
    let mut rows = vec![];
    if !c.ui.rog_error.is_empty() {
        rows.push(info("Couldn't do that", &c.ui.rog_error, ""));
    }
    let pf = &r["platform"];
    let choices: Vec<i64> = pf["choices"].as_array().into_iter().flatten().filter_map(|x| x.as_i64()).collect();
    if !choices.is_empty() {
        rows.push(header("Performance", "The firmware's fan and power limits. Also in the control center."));
        // Quiet, Balanced, Performance — the order people think in, not asusd's.
        let order: Vec<(String, String)> = [3, 2, 0, 1, 4]
            .iter()
            .filter(|p| choices.contains(p))
            .map(|p| (PROFILE_NAMES.iter().find(|x| x.0 == *p).map(|x| x.1.to_string()).unwrap_or(format!("Profile {p}")), p.to_string()))
            .collect();
        let opts: Vec<(&str, &str)> = order.iter().map(|o| (o.0.as_str(), o.1.as_str())).collect();
        let cur = pf["profile"].as_i64().map(|p| p.to_string()).unwrap_or_default();
        rows.push(seg_with("Profile", "Quiet keeps the fans down; Performance lets the CPU and GPU draw the most", &opts, &cur, |c, v| {
            c.ui.daemon.push(json!({ "cmd": "rog-profile", "profile": v.parse::<i64>().unwrap_or(0) }))
        }));
    }
    if let Some(limit) = pf["chargeLimit"].as_f64() {
        rows.push(header("Battery", "A battery kept below full lasts years longer. 80% suits a laptop that is mostly plugged in."));
        rows.push(slider_with("Charge limit", "Charging stops here", 20.0, 100.0, 1.0, "%", limit, |c, v| {
            c.ui.daemon.push(json!({ "cmd": "rog-charge", "limit": v.round() as i64 }))
        }));
        rows.push(action("Charge to full once", "To 100% this time — for a trip — then back to the limit", "Charge", |c| {
            c.ui.daemon.push(json!({ "cmd": "rog-full-charge" }))
        }));
    }
    let kbd = &r["aura"][0];
    if kbd.is_object() {
        rows.push(header("Keyboard light", ""));
        let lvl = kbd["brightness"].as_i64().map(|l| l.to_string()).unwrap_or_default();
        rows.push(seg_with("Brightness", "Also in the control center", &[("Off", "0"), ("Low", "1"), ("Medium", "2"), ("High", "3")], &lvl, |c, v| {
            c.ui.daemon.push(json!({ "cmd": "rog-kbd-brightness", "level": v.parse::<i64>().unwrap_or(0) }))
        }));
        let modes: Vec<i64> = kbd["modes"].as_array().into_iter().flatten().filter_map(|m| m.as_i64()).filter(|m| [0, 1, 2, 3, 10].contains(m)).collect();
        if modes.len() > 1 {
            let names: Vec<(String, String)> = modes.iter().map(|m| (KBD_MODES.iter().find(|x| x.0 == *m).map(|x| x.1.to_string()).unwrap_or(format!("Mode {m}")), m.to_string())).collect();
            let opts: Vec<(&str, &str)> = names.iter().map(|o| (o.0.as_str(), o.1.as_str())).collect();
            let cur = kbd["effect"]["mode"].as_i64().map(|m| m.to_string()).unwrap_or_default();
            let follow = c.p.b("rogKbdAccent");
            rows.push(seg_with("Effect", "Static and Breathe use the colour below", &opts, &cur, move |c, v| {
                let cmd = kbd_mode_cmd(&c.ui.rog, v.parse().unwrap_or(0), &if follow { accent_hex() } else { String::new() });
                c.ui.daemon.push(cmd)
            }));
        }
        let now = kbd["effect"]["colour"].as_str().map(|x| format!(" · now {}", x.to_uppercase())).unwrap_or_default();
        rows.push(toggle_with(
            "In the accent colour",
            &format!("The keyboard follows the shell's accent — a new swatch, the wallpaper's colour, light or dark{now}"),
            c.p.b("rogKbdAccent"),
            |c, v| {
                c.set("rogKbdAccent", json!(v));
                if v {
                    // Breathe kept; otherwise Static.
                    let m = if c.ui.rog["aura"][0]["effect"]["mode"] == 1 { 1 } else { 0 };
                    let cmd = kbd_mode_cmd(&c.ui.rog, m, &accent_hex());
                    c.ui.daemon.push(cmd);
                }
            },
        ));
    }
    let gpu = &r["gpu"];
    let mode = gpu["mode"].as_str().unwrap_or("");
    if !mode.is_empty() {
        let pending = gpu["pending"].as_str().unwrap_or("");
        let name = |k: &str| GPU.iter().find(|g| g.0 == k).map(|g| g.1).unwrap_or(k).to_string();
        rows.push(header(
            "Graphics",
            &if pending.is_empty() { "Takes effect at the next restart".to_string() } else { format!("Switching to {} at the next restart", name(pending)) },
        ));
        let cur = if pending.is_empty() { mode } else { pending };
        let ch: Vec<(String, String)> = gpu["choices"].as_array().into_iter().flatten().filter_map(|x| x.as_str()).map(|k| (name(k), k.to_string())).collect();
        let opts: Vec<(&str, &str)> = ch.iter().map(|o| (o.0.as_str(), o.1.as_str())).collect();
        let note = GPU.iter().find(|g| g.0 == cur).map(|g| g.2).unwrap_or("");
        rows.push(seg_with("GPU mode", note, &opts, cur, |c, v| c.ui.daemon.push(json!({ "cmd": "rog-gpu", "mode": v }))));
    }
    let attrs = &r["attrs"];
    let toggles: Vec<_> = ATTRS
        .iter()
        .filter(|(k, _, _)| {
            let a = &attrs[*k];
            a.is_object() && !a["value"].is_null() && a["possible"].as_array().map(|p| p.iter().map(|x| x.to_string()).collect::<Vec<_>>().join(",")) == Some("0,1".into())
        })
        .collect();
    if !toggles.is_empty() {
        rows.push(header("Panel and firmware", ""));
        for (k, n, s) in toggles {
            let key = k.to_string();
            rows.push(toggle_with(n, s, attrs[*k]["value"] == 1, move |c, v| {
                c.ui.daemon.push(json!({ "cmd": "rog-attr", "name": key, "value": if v { 1 } else { 0 } }))
            }));
        }
    }
    rows
}


// ── Settings → Login screen (Settings.qml's loginRows) ─────────────────────

fn face_cmd(c: &mut Ctx, cmd: crate::face::Cmd) {
    c.ui.face_cmds.push(cmd);
}

fn login(c: &Ctx) -> Vec<Spec> {
    use crate::face::Cmd;
    let f = &c.ui.face;
    let mut r = vec![header(
        "Face unlock",
        &format!(
            "Your face, through the IR camera, at the lock screen and when you log in — {}",
            if f.engine_is_service() {
                if f.howdy_off || !f.howdy { "with Hyprshell's own face recognition" } else { "with Hyprshell's own face recognition, and Howdy as a fallback" }
            } else {
                "with Howdy"
            }
        ),
    )];
    if !f.probed {
        r.push(info("Looking…", "What is there: Howdy, the cameras, the lock screen's PAM file", ""));
        return r;
    }
    if !f.installed() {
        r.push(buttons(
            "Howdy isn't installed",
            "Install it, then check again: paru -S howdy-git — and linux-enable-ir-emitter if the camera's infrared light doesn't come on (sudo linux-enable-ir-emitter configure)",
            vec![btn("Check again", false, true, |c| face_cmd(c, Cmd::Refresh))],
        ));
        return r;
    }
    // One password for a while of changes.
    r.push(if f.unlocked {
        buttons(
            "Unlocked for changes",
            "Changes on this page don't ask for your password again, until you lock it or five minutes pass without one",
            vec![btn("Lock", true, true, |c| face_cmd(c, Cmd::Lock))],
        )
    } else {
        info("Changes ask for your password once", "The first change asks; the ones after it go straight through, for as long as you keep making them", "Locked")
    });
    r.push(toggle_with(
        "Unlock with my face",
        if f.lock_on && f.greeter_on {
            "At the lock screen and when you log in; the password always works too"
        } else if f.lock_on {
            "At the lock screen (the login screen isn't set up: is greetd installed?)"
        } else {
            "Off: your password only. Turning it on asks for your password"
        },
        f.on(),
        |c, v| face_cmd(c, if v { Cmd::Enable } else { Cmd::Disable }),
    ));
    if f.engine_is_service() && f.howdy {
        r.push(toggle_with(
            "Use Howdy as a fallback",
            if f.howdy_off {
                "Off: Hyprshell's own face recognition alone. New faces are added to it only"
            } else {
                "When Hyprshell's face service can't answer (stopped, or no face of yours in it), Howdy looks instead. Off, it's Hyprshell's own recognition alone"
            },
            !f.howdy_off,
            |c, v| face_cmd(c, Cmd::SetHowdy(v)),
        ));
    }
    if !f.cameras.is_empty() {
        let labels: Vec<String> = f.cameras.iter().map(|k| k.label()).collect();
        let cur = f.cameras.iter().find(|k| k.path == f.camera);
        let paths: Vec<String> = f.cameras.iter().map(|k| k.path.clone()).collect();
        let labs = labels.clone();
        r.push(menu_with(
            "Camera",
            match cur {
                Some(k) if k.ir => "The infrared camera: works in the dark, and isn't fooled by a photo",
                Some(_) => "Not an infrared camera: pick the IR one if there is one",
                None => "Which camera Howdy looks through",
            },
            labels,
            &cur.map(|k| k.label()).unwrap_or_default(),
            move |c, v| {
                if let Some(i) = labs.iter().position(|l| *l == v) {
                    face_cmd(c, Cmd::SetCamera(paths[i].clone()));
                }
            },
        ));
    }
    if f.has_webcam {
        let ids = f.looks.as_ref().map(|l| l.iter().filter(|k| k.webcam).count()).unwrap_or(0);
        r.push(toggle_with(
            "Check with the webcam too",
            if !f.webcam_check {
                "Off: the infrared camera decides alone. On, both cameras have to recognise you — a photo that fools one rarely fools the other"
            } else if ids == 0 {
                "On, but the webcam has no pictures of you yet: add your face again below"
            } else {
                "Both cameras have to recognise you. In low light, or with the webcam in use elsewhere, the infrared camera decides alone. The webcam's light comes on as you unlock"
            },
            f.webcam_check,
            |c, v| face_cmd(c, Cmd::SetWebcamCheck(v)),
        ));
    }
    r.push(header("Your face", "Howdy learns your face through the infrared camera while the webcam shows you, and the looks it knows you by"));
    r.push(panel("face"));
    if f.faces() != 0 {
        r.push(buttons("Forget my faces", "Every look Howdy knows you by; your password still works", vec![btn("Remove all", true, !f.busy && !f.adding, |c| face_cmd(c, Cmd::ClearFaces))]));
    }
    if f.lock_on {
        r.push(buttons(
            "Try it",
            if f.testing { "Look at the camera…" } else { "Checks your face the way the lock screen does" },
            vec![btn(if f.testing { "Looking…" } else { "Try it" }, false, !f.testing && !f.busy, |c| face_cmd(c, Cmd::Test))],
        ));
    }
    // Not while a face is being added: the panel says how that's going.
    if !f.adding && !f.just_added && !f.status.is_empty() {
        r.push(info(if f.busy { "Working…" } else if f.failed { "That didn't work" } else { "Done" }, &f.status, ""));
    }
    r.extend(face_service_rows(f));
    r.extend(howdy_rows(c));
    r.extend(keyring_rows(&c.ui.keyring));
    r.push(header("Login screen", ""));
    r.push(info(
        "Hyprshell's login screen",
        if f.greeter_installed { "Installed; it follows your theme, wallpaper, screens and pointer" } else { "Not installed: sudo greeter/install.sh in Hyprshell's folder" },
        if f.greeter_installed { "Installed" } else { "Not installed" },
    ));
    r
}

fn face_service_rows(f: &crate::face::Snap) -> Vec<Spec> {
    use crate::face::Cmd;
    if !f.engine_is_service() {
        return vec![
            header("Faster face unlock", ""),
            info(
                "Hyprshell's face service",
                if f.service.is_some() {
                    "Installed but not answering: sudo systemctl restart hyprshell-faced"
                } else {
                    "Keeps the face models loaded, so unlocking starts at the camera, not at loading them: sudo shell/face/install.sh in Hyprshell's folder. Howdy stays as its fallback"
                },
                if f.service.is_some() { "Not running" } else { "Not installed" },
            ),
        ];
    }
    let s = f.service.clone().unwrap_or_default();
    let num = |k: &str, d: f64| s[k].as_f64().unwrap_or(d);
    let set = |key: &'static str, fmt: fn(f64) -> String| move |c: &mut Ctx, v: f64| face_cmd(c, Cmd::SetService(key.into(), fmt(v)));
    let mut r = vec![
        header("Face service", "Hyprshell's own: the models stay loaded, and it decides first. Changes apply at the next unlock"),
        info(
            "Running",
            &format!(
                "{}Each unlock, and how long it took: journalctl -u hyprshell-faced",
                if f.looks.as_ref().is_some_and(|l| l.is_empty()) { "No face of yours added to it yet: add it below. Until then Howdy answers. " } else { "" }
            ),
            "Ready",
        ),
        slider_with("How alike your face has to be", "Higher is stricter: harder to fool, but it may take a second look. 0.45 suits most people", 0.3, 0.7, 0.01, "", num("threshold", 0.45), set("threshold", |v| format!("{v:.2}"))),
        slider_with("Give up after", "How long it looks for you before the password is asked for", 1.0, 10.0, 0.5, "s", num("timeout", 4.0), set("timeout", |v| format!("{v:.1}"))),
        seg_with(
            "Frames that have to know you",
            "In a row, before it unlocks: more is harder to fool with one lucky frame, a little slower",
            &[("1", "1"), ("2", "2"), ("3", "3")],
            &format!("{}", num("confirm_frames", 2.0) as i64),
            |c, v| face_cmd(c, Cmd::SetService("confirm_frames".into(), v)),
        ),
        toggle_with(
            "Only when you face the camera",
            "A head turned away doesn't unlock it: someone can't hold the laptop up to you while you look elsewhere",
            s["require_facing"] != false,
            |c, v| face_cmd(c, Cmd::SetService("require_facing".into(), v.to_string())),
        ),
        toggle_with(
            "Only when you're looking at the screen",
            "Stricter: your head straight on to the screen, not glancing past it or down. It goes by where your head points, not your eyes",
            s["require_attention"] == true,
            |c, v| face_cmd(c, Cmd::SetService("require_attention".into(), v.to_string())),
        ),
        seg_with(
            "After faces that aren't yours",
            &format!("That many in a row, and face unlock steps aside for {} minutes: the password is needed. Not seeing anyone doesn't count", s["lockout_minutes"].as_i64().unwrap_or(10)),
            &[("Off", "0"), ("3", "3"), ("5", "5"), ("10", "10")],
            &format!("{}", s["lockout_after"].as_i64().unwrap_or(5)),
            |c, v| face_cmd(c, Cmd::SetService("lockout_after".into(), v)),
        ),
    ];
    if f.webcam_check {
        r.push(slider_with("Webcam: how alike", "For the webcam check; colour pictures vary more with the light", 0.3, 0.7, 0.01, "", num("webcam_threshold", 0.4), set("webcam_threshold", |v| format!("{v:.2}"))));
        r.push(slider_with(
            "Webcam: too dark below",
            "Average brightness (0–255) under which the webcam is left out and infrared decides alone",
            5.0,
            150.0,
            1.0,
            "",
            num("min_light", 45.0),
            set("min_light", |v| format!("{}", v.round() as i64)),
        ));
    }
    r
}

fn howdy_rows(c: &Ctx) -> Vec<Spec> {
    use crate::face::Cmd;
    let f = &c.ui.face;
    let mut r = vec![header(
        if f.engine_is_service() { "Howdy (the fallback)" } else { "Howdy" },
        if f.engine_is_service() { "Used only when the face service can't answer: it isn't running, or has no face of yours" } else { "Howdy's own settings, changed as you change them" },
    )];
    if f.config.is_empty() {
        r.push(info("Howdy's settings", "Its config.ini wasn't found, or can't be read: sudo howdy config edits it by hand", "Not readable"));
        return r;
    }
    let n = if f.busy { 0 } else { c.ui.face_pending };
    let waiting = |busy: bool, n: usize| {
        buttons(
            &if n == 1 { "1 change not made yet".to_string() } else { format!("{n} changes not made yet") },
            "Your password is needed for them",
            vec![btn(if busy { "Applying…" } else { "Apply" }, false, !busy, |c| face_cmd(c, Cmd::ApplyConfig)), btn("Discard", true, !busy, |c| face_cmd(c, Cmd::DiscardConfig))],
        )
    };
    if n > 0 {
        r.push(waiting(f.busy, n));
    }
    let cfg = |k: &'static str| move |c: &mut Ctx, v: String| face_cmd(c, Cmd::SetCfg(k.into(), v));
    let numv = |k: &'static str, round: bool| move |c: &mut Ctx, v: f64| face_cmd(c, Cmd::SetCfg(k.into(), if round { format!("{}", v.round() as i64) } else { format!("{v:.1}") }));
    let flag = |k: &'static str| move |c: &mut Ctx, v: bool| face_cmd(c, Cmd::SetCfg(k.into(), v.to_string()));
    r.push(slider_with("How close a match has to be", "Lower is stricter: harder to fool, but it may take you a second try. Howdy's default is 3.5; above 5 isn't recommended", 1.0, 6.0, 0.1, "", f.cfg_num("video.certainty", 3.5), numv("video.certainty", false)));
    r.push(slider_with("Give up after", "How long it looks for you before the password is asked for", 1.0, 15.0, 1.0, "s", f.cfg_num("video.timeout", 4.0), numv("video.timeout", true)));
    r.push(slider_with(
        "Dark frames",
        "How dark a frame can be and still be used (the IR light flashes, so some are black). Raise it if Howdy says all frames were too dark",
        0.0,
        100.0,
        1.0,
        "%",
        f.cfg_num("video.dark_threshold", 60.0),
        numv("video.dark_threshold", true),
    ));
    r.push(seg_with("Picture size for matching", "Smaller is faster; larger can be more precise", &[("240", "240"), ("320", "320"), ("480", "480"), ("720", "720")], &format!("{}", f.cfg_num("video.max_height", 320.0) as i64), cfg("video.max_height")));
    r.push(toggle_with("More accurate face finding (CNN)", "Much slower without a GPU to run it on", f.cfg_bool("core.use_cnn", false), flag("core.use_cnn")));
    r.push(toggle_with("Not with the lid closed", "Skip Howdy when the laptop is shut (an external screen, say)", f.cfg_bool("core.abort_if_lid_closed", true), flag("core.abort_if_lid_closed")));
    r.push(toggle_with("Not over SSH", "Skip Howdy for logins from another computer", f.cfg_bool("core.abort_if_ssh", true), flag("core.abort_if_ssh")));
    if f.webcam_check {
        r.push(slider_with("Webcam: how close a match has to be", "For the webcam check. Lower is stricter; colour pictures vary more with the light than infrared", 2.0, 6.0, 0.1, "", f.cfg_num("webcam.certainty", 4.5), numv("webcam.certainty", false)));
        r.push(slider_with("Webcam: too dark below", "Average brightness (0–255) under which the webcam is left out and infrared decides alone", 5.0, 150.0, 1.0, "", f.cfg_num("webcam.min_light", 45.0), numv("webcam.min_light", true)));
    }
    r.push(header("Howdy's camera and messages", ""));
    r.push(seg_with("Recorder", "How frames are read. FFmpeg can help with grey or garbled pictures", &[("OpenCV", "opencv"), ("FFmpeg", "ffmpeg"), ("pyv4l2", "pyv4l2")], &f.cfg("video.recording_plugin", "opencv"), cfg("video.recording_plugin")));
    r.push(toggle_with("Force Motion JPEG", "OpenCV only: fixes some cameras' broken raw frames", f.cfg_bool("video.force_mjpeg", false), flag("video.force_mjpeg")));
    r.push(slider_with(
        "Frame rate",
        "Some IR emitters only light at one rate. 0 leaves it to the camera",
        0.0,
        60.0,
        1.0,
        "fps",
        f.cfg_num("video.device_fps", -1.0).max(0.0),
        |c, v| face_cmd(c, Cmd::SetCfg("video.device_fps".into(), if v.round() as i64 == 0 { "-1".into() } else { format!("{}", v.round() as i64) })),
    ));
    r.push(seg_with("Orientation", "For a camera mounted sideways", &[("Landscape", "0"), ("Both", "1"), ("Portrait", "2")], &f.cfg("video.rotate", "0"), cfg("video.rotate")));
    r.push(toggle_with("Keep pictures of failed attempts", "In /var/log/howdy/snapshots, to see who tried", f.cfg_bool("snapshots.save_failed", false), flag("snapshots.save_failed")));
    r.push(toggle_with("Keep pictures of successful ones too", "Same folder", f.cfg_bool("snapshots.save_successful", false), flag("snapshots.save_successful")));
    r.push(toggle_with("In the terminal: say when it's looking", "For sudo and other password prompts in a terminal", f.cfg_bool("core.detection_notice", false), flag("core.detection_notice")));
    r.push(toggle_with("In the terminal: say when it gives up", "", f.cfg_bool("core.timeout_notice", true), flag("core.timeout_notice")));
    r.push(toggle_with("In the terminal: say when it recognises you", "", !f.cfg_bool("core.no_confirmation", false), |c, v| face_cmd(c, Cmd::SetCfg("core.no_confirmation".into(), (!v).to_string()))));
    r.push(seg_with(
        "In the terminal: face and password together",
        "Off: press Enter after Howdy gives up. Input: it presses Enter for you. Native: stops the prompt itself (can be unstable)",
        &[("Off", "off"), ("Input", "input"), ("Native", "native")],
        &f.cfg("core.workaround", "off"),
        cfg("core.workaround"),
    ));
    r.push(toggle_with("Timing report", "Howdy prints how long each step took (in a terminal; can upset some apps)", f.cfg_bool("debug.end_report", false), flag("debug.end_report")));
    if n > 0 {
        r.push(waiting(f.busy, n));
    }
    r
}


// Settings → Login screen → Keyring (Settings.qml's keyringRows).
fn keyring_rows(k: &crate::keyring::Snap) -> Vec<Spec> {
    use crate::keyring::Cmd;
    let mut r = vec![header("Keyring", "Your saved passwords. A face login has no password to open them with, unless the laptop keeps it for you, sealed with its TPM")];
    if !k.probed {
        return r;
    }
    if !k.available() {
        r.push(info(
            "Unlock the keyring with my face",
            if !k.keyring_installed {
                "GNOME Keyring isn't installed".to_string()
            } else if !k.tpm {
                "This needs a TPM, and none was found: is it turned on in the firmware?".to_string()
            } else {
                format!("This needs systemd 256 or newer (this is {})", k.creds_version)
            }
            .as_str(),
            "Not available",
        ));
        return r;
    }
    r.push(toggle_with(
        "Unlock the keyring with my face",
        if k.stored {
            "Its password is sealed with this laptop's TPM, and opens it after a face login"
        } else if k.asking {
            "Type the keyring's password below to turn it on"
        } else {
            "Off: after a face login, the first app that needs the keyring asks for your password"
        },
        k.stored || k.asking,
        move |c, v| {
            if v {
                c.ui.keyring_cmds.push(Cmd::Ask(true));
            } else {
                c.ui.keyring_cmds.push(Cmd::Ask(false));
                if c.ui.keyring.stored {
                    c.ui.keyring_cmds.push(Cmd::Forget);
                }
            }
        },
    ));
    if k.asking && !k.stored {
        let mut t = text(
            "Your keyring's password",
            "Usually your login password. The keyring checks it first; then it's sealed with the TPM, never stored readable",
            "",
            "Password",
            if k.busy { "Checking…" } else { "Store" },
            |c, v| c.ui.keyring_cmds.push(Cmd::Store(v)),
        );
        t.row.secret = true;
        r.push(t);
    }
    if !k.status.is_empty() {
        r.push(info(if k.busy { "Working…" } else if k.failed { "That didn't work" } else { "Done" }, &k.status, ""));
    }
    r.push(info(
        "How safe it is",
        "The sealed password opens only on this laptop, never from a copied disk or a backup. Programs running as you could unseal it, but they can already read an open keyring. It makes your saved passwords as safe as Howdy, which is easier to fool than a password",
        "",
    ));
    r
}
