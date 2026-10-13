//! What every Hyprshell Rust app shares: the shell's palette, read from its
//! theme.json and followed live; its glyphs, drawn as SVG and cached; the
//! frameless window's moves; and small helpers for running work off the UI
//! thread.
//!
//! The Slint side is `ui/kit.slint`, imported as `@kit`. Its globals are
//! generated into each app, so the kit hands values over through the
//! [`setup!`] macro, which runs in the app's own scope.

pub mod icons;
pub mod portal;
pub mod mpris;
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
/// back on the UI thread. `done` stays on the UI thread the whole time, so
/// it may hold the app's own state (an Rc, a window handle); only the
/// result crosses over.
pub fn spawn<T, W, D>(work: W, done: D)
where
    T: Send + 'static,
    W: FnOnce() -> T + Send + 'static,
    D: FnOnce(T) + 'static,
{
    use std::any::Any;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(1);
    thread_local! {
        static PENDING: std::cell::RefCell<std::collections::HashMap<u64, Box<dyn FnOnce(Box<dyn Any>)>>> =
            std::cell::RefCell::new(std::collections::HashMap::new());
    }
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    PENDING.with(|p| {
        p.borrow_mut().insert(id, Box::new(move |out: Box<dyn Any>| {
            if let Ok(v) = out.downcast::<T>() {
                done(*v);
            }
        }))
    });
    std::thread::spawn(move || {
        let out = work();
        let _ = slint::invoke_from_event_loop(move || {
            let f = PENDING.with(|p| p.borrow_mut().remove(&id));
            if let Some(f) = f {
                f(Box::new(out));
            }
        });
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

/// Local time, broken down: (year, month 1–12, day, hour, minute, weekday
/// 0 = Sunday). Through libc's localtime_r, without a date crate.
pub fn local(epoch: i64) -> (i32, u32, u32, u32, u32, u32) {
    #[repr(C)]
    struct Tm {
        sec: i32, min: i32, hour: i32, mday: i32, mon: i32, year: i32, wday: i32, yday: i32, isdst: i32,
        gmtoff: i64, zone: *const i8,
    }
    extern "C" {
        fn localtime_r(t: *const i64, out: *mut Tm) -> *mut Tm;
    }
    let mut tm: Tm = unsafe { std::mem::zeroed() };
    unsafe { localtime_r(&epoch, &mut tm) };
    (tm.year + 1900, (tm.mon + 1) as u32, tm.mday as u32, tm.hour as u32, tm.min as u32, tm.wday as u32)
}

pub fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DAYS: [&str; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/// A moment the way a list says it: 14:05 today, Yesterday, Tuesday this
/// week, 12 Oct this year, 12 Oct 2024 before that.
pub fn when(epoch: i64) -> String {
    let (y, m, d, hh, mm, wd) = local(epoch);
    let (ny, nm, nd, _, _, _) = local(now());
    let days_ago = {
        let day = |e: i64| { let (y, m, d, ..) = local(e); (y, m, d) };
        let mut n = 0;
        let mut t = now();
        while n < 7 && day(t) != (y, m, d) {
            t -= 86400;
            n += 1;
        }
        n
    };
    if (y, m, d) == (ny, nm, nd) {
        format!("{hh:02}:{mm:02}")
    } else if days_ago == 1 {
        "Yesterday".into()
    } else if days_ago < 7 {
        DAYS[wd as usize % 7].into()
    } else if y == ny {
        format!("{d} {}", MONTHS[(m as usize + 11) % 12])
    } else {
        format!("{d} {} {y}", MONTHS[(m as usize + 11) % 12])
    }
}

/// Move a file or folder to the desktop's Trash (the freedesktop.org
/// spec: the Files app and every file manager can put it back).
pub fn trash(path: &std::path::Path) -> std::io::Result<()> {
    let base = data_dir().join("Trash");
    let files = base.join("files");
    let info = base.join("info");
    std::fs::create_dir_all(&files)?;
    std::fs::create_dir_all(&info)?;
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| "item".into());
    let mut pick = name.clone();
    let mut n = 1;
    while files.join(&pick).exists() || info.join(format!("{pick}.trashinfo")).exists() {
        n += 1;
        pick = match name.rsplit_once('.') {
            Some((stem, ext)) if !stem.is_empty() => format!("{stem} {n}.{ext}"),
            _ => format!("{name} {n}"),
        };
    }
    let abs = std::fs::canonicalize(path)?;
    let enc: String = abs
        .to_string_lossy()
        .bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b"/-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect();
    let (y, mo, d, h, mi, _) = local(now());
    let s = now() % 60;
    std::fs::write(
        info.join(format!("{pick}.trashinfo")),
        format!("[Trash Info]\nPath={enc}\nDeletionDate={y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}\n"),
    )?;
    if std::fs::rename(&abs, files.join(&pick)).is_err() {
        // Another file system: copy, then remove.
        if abs.is_dir() {
            copy_dir(&abs, &files.join(&pick))?;
            std::fs::remove_dir_all(&abs)?;
        } else {
            std::fs::copy(&abs, files.join(&pick))?;
            std::fs::remove_file(&abs)?;
        }
    }
    Ok(())
}

fn copy_dir(from: &std::path::Path, to: &std::path::Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for e in std::fs::read_dir(from)? {
        let e = e?;
        let p = e.path();
        if p.is_dir() { copy_dir(&p, &to.join(e.file_name()))?; } else { std::fs::copy(&p, to.join(e.file_name()))?; }
    }
    Ok(())
}

/// Write a file whole or not at all: to a sibling first, then renamed over.
pub fn write_atomic(path: &std::path::Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension(format!("{}.tmp", path.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default()));
    std::fs::write(&tmp, data)?;
    std::fs::rename(&tmp, path)
}
