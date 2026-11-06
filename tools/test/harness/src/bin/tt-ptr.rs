//! tt-ptr X Y [left|right|middle|move|up|down|drag X2 Y2]: a virtual pointer
//! moved to X,Y (logical pixels on the test's output, TT_W×TT_H) and what it
//! does there: a click (left by default), a move, a scroll, or a drag.
use wayland_client::protocol::wl_pointer::{Axis, ButtonState};
use wayland_client::{globals::{registry_queue_init, GlobalListContents}, protocol::{wl_registry, wl_seat}, Connection, Dispatch, QueueHandle};
use wayland_protocols_wlr::virtual_pointer::v1::client::{zwlr_virtual_pointer_manager_v1 as m, zwlr_virtual_pointer_v1 as p};
use std::time::Duration;

struct S;
impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for S { fn event(_: &mut S, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<S>) {} }
impl Dispatch<wl_seat::WlSeat, ()> for S { fn event(_: &mut S, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<S>) {} }
impl Dispatch<m::ZwlrVirtualPointerManagerV1, ()> for S { fn event(_: &mut S, _: &m::ZwlrVirtualPointerManagerV1, _: m::Event, _: &(), _: &Connection, _: &QueueHandle<S>) {} }
impl Dispatch<p::ZwlrVirtualPointerV1, ()> for S { fn event(_: &mut S, _: &p::ZwlrVirtualPointerV1, _: p::Event, _: &(), _: &Connection, _: &QueueHandle<S>) {} }

fn env(k: &str, d: u32) -> u32 {
    std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 {
        eprintln!("tt-ptr X Y [left|right|middle|move|up|down|drag X2 Y2]");
        std::process::exit(2);
    }
    let (x, y): (u32, u32) = (a[1].parse().expect("X"), a[2].parse().expect("Y"));
    let what = a.get(3).cloned().unwrap_or_default();
    let (w, h) = (env("TT_W", 1536), env("TT_H", 960));
    let conn = Connection::connect_to_env().expect("a Wayland display");
    let (g, mut q) = registry_queue_init::<S>(&conn).expect("registry");
    let qh = q.handle();
    let seat: wl_seat::WlSeat = g.bind(&qh, 1..=7, ()).expect("a seat");
    let mgr: m::ZwlrVirtualPointerManagerV1 = g.bind(&qh, 1..=2, ()).expect("virtual pointers");
    let ptr = mgr.create_virtual_pointer(Some(&seat), &qh, ());
    let mut t = 1u32;
    let mut sync = |ms: u64| {
        q.roundtrip(&mut S).expect("roundtrip");
        std::thread::sleep(Duration::from_millis(ms));
    };
    sync(100);
    ptr.motion_absolute(t, x, y, w, h);
    ptr.frame();
    sync(100);
    t += 1;
    match what.as_str() {
        "drag" => {
            let (x2, y2): (u32, u32) = (a[4].parse().expect("X2"), a[5].parse().expect("Y2"));
            ptr.button(t, 0x110, ButtonState::Pressed);
            ptr.frame();
            sync(80);
            for i in 1..=20i64 {
                t += 1;
                let xi = (x as i64 + (x2 as i64 - x as i64) * i / 20) as u32;
                let yi = (y as i64 + (y2 as i64 - y as i64) * i / 20) as u32;
                ptr.motion_absolute(t, xi, yi, w, h);
                ptr.frame();
                sync(30);
            }
            sync(150);
            ptr.button(t + 1, 0x110, ButtonState::Released);
            ptr.frame();
        }
        "up" | "down" => {
            ptr.axis(t, Axis::VerticalScroll, if what == "up" { -10.0 } else { 10.0 });
            ptr.frame();
        }
        "move" => {}
        _ => {
            let b = match what.as_str() { "right" => 0x111, "middle" => 0x112, _ => 0x110 };
            ptr.button(t, b, ButtonState::Pressed);
            ptr.frame();
            sync(60);
            ptr.button(t + 1, b, ButtonState::Released);
            ptr.frame();
        }
    }
    sync(250);
}
