//! Putting a password on the clipboard without it being remembered.
//!
//! wl-copy offers one type, so a password copied with it lands in every
//! clipboard history — the shell's included. This serves the clipboard
//! itself, through the compositor's data-control protocol, offering the
//! text along with x-kde-passwordManagerHint: secret, the mark password
//! managers use and histories skip. After `ttl` it takes the password back
//! off the clipboard, unless something else has been copied since.

use std::io::Write;
use std::os::fd::{AsFd, AsRawFd};
use std::sync::Arc;
use std::time::{Duration, Instant};
use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols_wlr::data_control::v1::client::{
    zwlr_data_control_device_v1::{self, ZwlrDataControlDeviceV1},
    zwlr_data_control_manager_v1::ZwlrDataControlManagerV1,
    zwlr_data_control_offer_v1::ZwlrDataControlOfferV1,
    zwlr_data_control_source_v1::{self, ZwlrDataControlSourceV1},
};

const HINT: &str = "x-kde-passwordManagerHint";
const TEXT: [&str; 5] = ["text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "TEXT", "STRING"];

struct State {
    replaced: bool,
}
struct Payload {
    bytes: Arc<Vec<u8>>,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(_: &mut Self, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(_: &mut Self, _: &wl_seat::WlSeat, _: wl_seat::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ZwlrDataControlManagerV1, ()> for State {
    fn event(_: &mut Self, _: &ZwlrDataControlManagerV1, _: <ZwlrDataControlManagerV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ZwlrDataControlDeviceV1, ()> for State {
    fn event(_: &mut Self, _: &ZwlrDataControlDeviceV1, ev: zwlr_data_control_device_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        if let zwlr_data_control_device_v1::Event::DataOffer { id } = ev {
            id.destroy();
        }
    }
    wayland_client::event_created_child!(State, ZwlrDataControlDeviceV1, [
        zwlr_data_control_device_v1::EVT_DATA_OFFER_OPCODE => (ZwlrDataControlOfferV1, ()),
    ]);
}
impl Dispatch<ZwlrDataControlOfferV1, ()> for State {
    fn event(_: &mut Self, _: &ZwlrDataControlOfferV1, _: <ZwlrDataControlOfferV1 as Proxy>::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<ZwlrDataControlSourceV1, Payload> for State {
    fn event(st: &mut Self, src: &ZwlrDataControlSourceV1, ev: zwlr_data_control_source_v1::Event, data: &Payload, _: &Connection, _: &QueueHandle<Self>) {
        match ev {
            zwlr_data_control_source_v1::Event::Send { mime_type, fd } => {
                let bytes = if mime_type == HINT { Arc::new(b"secret".to_vec()) } else { data.bytes.clone() };
                std::thread::spawn(move || {
                    let mut f = std::fs::File::from(fd);
                    let _ = f.write_all(&bytes);
                });
            }
            zwlr_data_control_source_v1::Event::Cancelled => {
                // Something else was copied: ours is gone, nothing to clear.
                st.replaced = true;
                src.destroy();
            }
            _ => {}
        }
    }
}

/// Copy `text`; with `secret`, marked so histories skip it and taken back
/// after `ttl`. Runs on a thread of its own until then.
pub fn copy(text: String, secret: bool, ttl: Duration) -> Result<(), String> {
    let conn = Connection::connect_to_env().map_err(|e| format!("no Wayland display: {e}"))?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn).map_err(|e| e.to_string())?;
    let qh = queue.handle();
    let mgr: ZwlrDataControlManagerV1 = globals.bind(&qh, 1..=2, ()).map_err(|_| "the compositor has no clipboard control".to_string())?;
    let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=7, ()).map_err(|_| "no seat".to_string())?;
    let dev = mgr.get_data_device(&seat, &qh, ());
    let src = mgr.create_data_source(&qh, Payload { bytes: Arc::new(text.into_bytes()) });
    for m in TEXT {
        src.offer(m.to_string());
    }
    if secret {
        src.offer(HINT.to_string());
    }
    dev.set_selection(Some(&src));
    let _ = conn.flush();
    std::thread::spawn(move || {
        let mut st = State { replaced: false };
        let start = Instant::now();
        loop {
            let _ = queue.dispatch_pending(&mut st);
            let _ = conn.flush();
            if st.replaced {
                return;
            }
            let left = ttl.saturating_sub(start.elapsed());
            if left.is_zero() {
                // Still ours: take it back off the clipboard.
                dev.set_selection(None);
                let _ = conn.flush();
                let _ = queue.roundtrip(&mut st);
                return;
            }
            let Some(guard) = queue.prepare_read() else { continue };
            let fd = guard.connection_fd();
            let mut p = libc::pollfd { fd: fd.as_fd().as_raw_fd(), events: libc::POLLIN, revents: 0 };
            let wait = left.min(Duration::from_millis(500)).as_millis() as i32;
            if unsafe { libc::poll(&mut p, 1, wait) } > 0 {
                let _ = guard.read();
            } else {
                drop(guard);
            }
        }
    });
    Ok(())
}
