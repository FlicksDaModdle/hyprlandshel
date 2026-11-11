//! tt-kbd "text" [keys…]: types the text through a virtual keyboard (a US
//! layout), then the named keys: enter esc tab back up down left right.
use std::io::Write;
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::time::Duration;
use wayland_client::{globals::{registry_queue_init, GlobalListContents}, protocol::{wl_registry, wl_seat}, Connection, Dispatch, QueueHandle};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{zwp_virtual_keyboard_manager_v1 as m, zwp_virtual_keyboard_v1 as k};

struct S;
impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for S { fn event(_: &mut S, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<S>) {} }
impl Dispatch<wl_seat::WlSeat, ()> for S { fn event(_: &mut S, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<S>) {} }
impl Dispatch<m::ZwpVirtualKeyboardManagerV1, ()> for S { fn event(_: &mut S, _: &m::ZwpVirtualKeyboardManagerV1, _: m::Event, _: &(), _: &Connection, _: &QueueHandle<S>) {} }
impl Dispatch<k::ZwpVirtualKeyboardV1, ()> for S { fn event(_: &mut S, _: &k::ZwpVirtualKeyboardV1, _: k::Event, _: &(), _: &Connection, _: &QueueHandle<S>) {} }

/// A character's key (evdev code) and whether it takes Shift.
fn code(c: char) -> Option<(u32, bool)> {
    let row = |s: &str, base: u32| s.find(c.to_ascii_lowercase()).map(|i| base + i as u32);
    if let Some(k) = row("qwertyuiop", 16).or(row("asdfghjkl", 30)).or(row("zxcvbnm", 44)).or(row("1234567890", 2)) {
        return Some((k, c.is_ascii_uppercase()));
    }
    Some(match c {
        ' ' => (57, false),
        '-' => (12, false),
        '_' => (12, true),
        '=' => (13, false),
        '+' => (13, true),
        '/' => (53, false),
        '.' => (52, false),
        ',' => (51, false),
        '!' => (2, true),
        '@' => (3, true),
        '#' => (4, true),
        _ => return None,
    })
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let conn = Connection::connect_to_env().expect("a Wayland display");
    let (g, mut q) = registry_queue_init::<S>(&conn).expect("registry");
    let qh = q.handle();
    let seat: wl_seat::WlSeat = g.bind(&qh, 1..=7, ()).expect("a seat");
    let mgr: m::ZwpVirtualKeyboardManagerV1 = g.bind(&qh, 1..=1, ()).expect("virtual keyboards");
    let kb = mgr.create_virtual_keyboard(&seat, &qh, ());
    let ctx = xkbcommon::xkb::Context::new(0);
    let km = xkbcommon::xkb::Keymap::new_from_names(&ctx, "", "", "us", "", None, 0).expect("a US keymap");
    let text = km.get_as_string(xkbcommon::xkb::KEYMAP_FORMAT_TEXT_V1);
    // SAFETY: a fresh memfd, owned from here on.
    let fd = unsafe { OwnedFd::from_raw_fd(libc::memfd_create(b"km\0".as_ptr() as *const _, 0)) };
    let mut f = std::fs::File::from(fd.try_clone().expect("fd"));
    f.write_all(text.as_bytes()).expect("keymap");
    f.write_all(&[0]).expect("keymap");
    kb.keymap(1, fd.as_fd(), text.len() as u32 + 1);
    q.roundtrip(&mut S).expect("roundtrip");
    std::thread::sleep(Duration::from_millis(100));
    let mut t = 10u32;
    // `mods`: 1 Shift, 4 Control, held as a real keyboard holds them: the key
    // itself goes down first, then the state, then the key typed.
    let mut press = |key: u32, mods: u32| {
        if mods & 4 != 0 {
            kb.key(t, 29, 1);
            t += 5;
        }
        if mods & 1 != 0 {
            kb.key(t, 42, 1);
            t += 5;
        }
        if mods != 0 {
            kb.modifiers(mods, 0, 0, 0);
            q.roundtrip(&mut S).expect("roundtrip");
            std::thread::sleep(Duration::from_millis(20));
        }
        kb.key(t, key, 1);
        t += 5;
        q.roundtrip(&mut S).expect("roundtrip");
        std::thread::sleep(Duration::from_millis(20));
        kb.key(t, key, 0);
        t += 5;
        if mods & 1 != 0 {
            kb.key(t, 42, 0);
            t += 5;
        }
        if mods & 4 != 0 {
            kb.key(t, 29, 0);
            t += 5;
        }
        if mods != 0 {
            kb.modifiers(0, 0, 0, 0);
        }
        q.roundtrip(&mut S).expect("roundtrip");
        std::thread::sleep(Duration::from_millis(20));
    };
    for c in a.get(1).cloned().unwrap_or_default().chars() {
        if let Some((k, sh)) = code(c) {
            press(k, if sh { 1 } else { 0 });
        }
    }
    for n in a.iter().skip(2) {
        // "ctrl-a", "ctrl-left", "ctrl-shift-z": with Control (and Shift) held.
        if let Some(rest) = n.strip_prefix("ctrl-") {
            let (shift, rest) = rest.strip_prefix("shift-").map(|r| (true, r)).unwrap_or((false, rest));
            let k = match rest {
                "left" => Some(105),
                "right" => Some(106),
                "back" => Some(14),
                "home" => Some(102),
                "end" => Some(107),
                c if c.chars().count() == 1 => code(c.chars().next().unwrap()).map(|(k, _)| k),
                _ => None,
            };
            match k {
                Some(k) => press(k, 4 | if shift { 1 } else { 0 }),
                None => eprintln!("tt-kbd: no key called {n}"),
            }
            continue;
        }
        let k = match n.as_str() {
            "down" => 108,
            "up" => 103,
            "enter" => 28,
            "esc" => 1,
            "back" => 14,
            "tab" => 15,
            "right" => 106,
            "left" => 105,
            other => {
                eprintln!("tt-kbd: no key called {other}");
                continue;
            }
        };
        press(k, 0);
    }
    std::thread::sleep(Duration::from_millis(150));
}
