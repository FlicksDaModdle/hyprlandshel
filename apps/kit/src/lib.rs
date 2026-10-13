//! What every Hyprshell Rust app shares: the shell's palette, read from its
//! theme.json and followed live; its glyphs, drawn as SVG and cached; the
//! frameless window's moves; and small helpers for running work off the UI
//! thread.
//!
//! The Slint side is `ui/kit.slint`, imported as `@kit`. Its globals are
//! generated into each app, so the kit hands values over through the
//! [`setup!`] macro, which runs in the app's own scope.

pub mod icons;
pub mod theme;

pub use slint;

use std::path::PathBuf;

/// Where `ui/kit.slint` is, for an app's build script.
pub fn ui_library() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("ui").join("kit.slint")
}

/// `$XDG_CONFIG_HOME`, or `~/.config`.
pub fn config_dir() -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home().join(".config"))
}

/// `$XDG_DATA_HOME`, or `~/.local/share`.
pub fn data_dir() -> PathBuf {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home().join(".local/share"))
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

/// Run `work` on a thread of its own and hand what it returns to `done`
/// back on the UI thread.
pub fn spawn<T, W, D>(work: W, done: D)
where
    T: Send + 'static,
    W: FnOnce() -> T + Send + 'static,
    D: FnOnce(T) + Send + 'static,
{
    std::thread::spawn(move || {
        let out = work();
        let _ = slint::invoke_from_event_loop(move || done(out));
    });
}

/// Bytes as the shell writes them: binary units, one decimal under 100.
pub fn bytes(n: u64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < units.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 || v >= 100.0 { format!("{:.0} {}", v, units[i]) } else { format!("{:.1} {}", v, units[i]) }
}

/// Seconds as m:ss, or h:mm:ss past the hour.
pub fn clock(secs: f64) -> String {
    let s = secs.max(0.0) as u64;
    if s >= 3600 { format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60) } else { format!("{}:{:02}", s / 60, s % 60) }
}

/// Wire an app's window to the kit: palette (now and whenever the shell's
/// theme changes), glyphs, and the frame's moves. Call once, after the
/// window is created and before it runs. Expects the app's generated
/// `Theme`, `Icons` and `Win` globals in scope (`slint::include_modules!()`).
#[macro_export]
macro_rules! setup {
    ($ui:expr, $app_id:expr) => {{
        use $crate::slint::ComponentHandle as _;
        use $crate::slint::winit_030::WinitWindowAccessor as _;
        let ui = &$ui;
        let weak = ui.as_weak();
        $crate::theme::follow(move |p: &$crate::theme::Palette| {
            let Some(ui) = weak.upgrade() else { return };
            let t = ui.global::<Theme>();
            t.set_dark(p.dark);
            t.set_accent(p.accent);
            t.set_ink_on_accent(p.ink_on_accent);
            t.set_ground(p.ground);
            t.set_surface(p.surface);
            t.set_ink(p.ink);
            t.set_ink2(p.ink2);
            t.set_ink3(p.ink3);
            t.set_edge(p.edge);
            t.set_rule(p.rule);
            t.set_hover(p.hover);
            t.set_sel(p.sel);
            t.set_sheet(p.sheet);
            t.set_dialog(p.dialog);
            t.set_danger(p.danger);
            t.set_ok(p.ok);
            t.set_warn(p.warn);
            t.set_r(p.r);
            t.set_r_sm(p.r_sm);
            t.set_font_factor(p.font_factor);
            t.set_font_family(p.font_family.clone().into());
            t.set_speed(p.speed);
            t.set_bounce(p.bounce);
        });
        ui.global::<Icons>().on_get(|name, ink, acc, size| $crate::icons::image(&name, ink, acc, size));
        let win = ui.global::<Win>();
        let w = ui.as_weak();
        win.on_move(move || {
            if let Some(ui) = w.upgrade() {
                ui.window().with_winit_window(|ww| { let _ = ww.drag_window(); });
            }
        });
        let w = ui.as_weak();
        win.on_resize(move |dir| {
            if let Some(ui) = w.upgrade() {
                ui.window().with_winit_window(|ww| { let _ = ww.drag_resize_window($crate::resize_direction(dir)); });
            }
        });
        let w = ui.as_weak();
        win.on_minimize(move || { if let Some(ui) = w.upgrade() { ui.window().set_minimized(true); } });
        let w = ui.as_weak();
        win.on_toggle_maximize(move || {
            if let Some(ui) = w.upgrade() {
                let on = !ui.window().is_maximized();
                ui.window().set_maximized(on);
                ui.global::<Win>().set_maximized(on);
            }
        });
        let w = ui.as_weak();
        win.on_close(move || { if let Some(ui) = w.upgrade() { let _ = ui.hide(); } let _ = $crate::slint::quit_event_loop(); });
        let _ = $app_id;
    }};
}

/// Set the Wayland app id (what Hyprland's window rules and the dock match)
/// before the first window is made.
pub fn init(app_id: &str) {
    let _ = slint::set_xdg_app_id(app_id);
}

#[doc(hidden)]
pub fn resize_direction(dir: i32) -> slint::winit_030::winit::window::ResizeDirection {
    use slint::winit_030::winit::window::ResizeDirection as R;
    match dir {
        0 => R::North,
        1 => R::NorthEast,
        2 => R::East,
        3 => R::SouthEast,
        4 => R::South,
        5 => R::SouthWest,
        6 => R::West,
        _ => R::NorthWest,
    }
}
