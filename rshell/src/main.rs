//! hyprshell-rs: Hyprshell's shell in Rust, on Hyprland.
//!
//! Step one of the port (see rshell/README.md): the platform that puts Slint
//! on layer-shell surfaces (platform.rs, wl.rs), Hyprland read straight from
//! its sockets (hypr.rs), and the top bar on every monitor.
//!
//! One thread runs everything that touches Slint or Wayland. It sleeps in
//! poll() on three things at once: the Wayland connection, a pipe that the
//! Hyprland event thread writes to, and the time until Slint's next timer
//! or animation frame.

mod hypr;
mod platform;
mod sys;
mod wl;

use slint::{ModelRc, SharedString, VecModel};
use smithay_client_toolkit::shell::wlr_layer::{Anchor, KeyboardInteractivity, Layer};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use wayland_client::{globals::registry_queue_init, Connection};

slint::include_modules!();

const BAR_HEIGHT: u32 = 40;

/// The local time as the bar shows it: "2:27 AM", "Thu 5 Nov".
fn clock() -> (String, String) {
    // SAFETY: localtime_r fills the tm it is given and keeps nothing.
    let tm = unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm
    };
    const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let h12 = match tm.tm_hour % 12 { 0 => 12, h => h };
    let time = format!("{}:{:02} {}", h12, tm.tm_min, if tm.tm_hour < 12 { "AM" } else { "PM" });
    let date = format!("{} {} {}", DAYS[tm.tm_wday as usize % 7], tm.tm_mday, MONTHS[tm.tm_mon as usize % 12]);
    (time, date)
}

/// Workspaces for one monitor's bar: 1 to 5 always, more when in use; the
/// one that monitor shows is active.
fn workspaces_for(monitor: &str) -> (Vec<Workspace>, String) {
    let all = hypr::json("j/workspaces");
    let monitors = hypr::json("j/monitors");
    let active = monitors
        .as_array()
        .and_then(|ms| ms.iter().find(|m| m["name"] == monitor).or(ms.first()))
        .and_then(|m| m["activeWorkspace"]["id"].as_i64())
        .unwrap_or(1);
    let mut occupied = std::collections::HashSet::new();
    let mut highest = 5;
    for w in all.as_array().into_iter().flatten() {
        let id = w["id"].as_i64().unwrap_or(0);
        if id > 0 {
            highest = highest.max(id);
            if w["windows"].as_i64().unwrap_or(0) > 0 {
                occupied.insert(id);
            }
        }
    }
    let list = (1..=highest)
        .map(|id| Workspace { id: id as i32, occupied: occupied.contains(&id), active: id == active })
        .collect();
    let title = hypr::json("j/activewindow")["title"].as_str().unwrap_or("").to_string();
    (list, title)
}

struct BarOn {
    bar: Bar,
    monitor: String,
}

fn refresh(bars: &[BarOn]) {
    let (time, date) = clock();
    let battery = sys::battery();
    for b in bars {
        let (ws, title) = workspaces_for(&b.monitor);
        b.bar.set_workspaces(ModelRc::from(Rc::new(VecModel::from(ws))));
        b.bar.set_focused_title(SharedString::from(title));
        b.bar.set_time(time.clone().into());
        b.bar.set_date(date.clone().into());
        b.bar.set_battery(battery.as_ref().map(|x| x.percent).unwrap_or(-1));
        b.bar.set_charging(battery.as_ref().is_some_and(|x| x.charging));
        b.bar.set_network(sys::network().into());
    }
}

fn main() {
    slint::platform::set_platform(Box::new(platform::ShellPlatform)).expect("the platform is set once");

    let conn = Connection::connect_to_env().unwrap_or_else(|e| {
        eprintln!("hyprshell-rs: no Wayland display ({e})");
        std::process::exit(1);
    });
    let (globals, mut queue) = registry_queue_init::<wl::Shell>(&conn).expect("the registry");
    let qh = queue.handle();
    let mut shell = wl::Shell::new(&globals, &qh).unwrap_or_else(|e| {
        eprintln!("hyprshell-rs: {e}");
        std::process::exit(1);
    });
    // Twice: once for the globals, once for what the outputs say about
    // themselves (their names and scales).
    queue.roundtrip(&mut shell).expect("roundtrip");
    queue.roundtrip(&mut shell).expect("roundtrip");

    // A bar on every monitor.
    let mut bars: Vec<BarOn> = Vec::new();
    let outputs: Vec<_> = shell.outputs.outputs().collect();
    for output in &outputs {
        let monitor = shell.outputs.info(output).and_then(|i| i.name).unwrap_or_default();
        let bar = Bar::new().expect("the bar");
        bar.on_workspace_clicked(|id| {
            hypr::ask(&format!("dispatch workspace {id}"));
        });
        bar.on_workspace_scrolled(|dy| {
            hypr::ask(if dy > 0.0 { "dispatch workspace m-1" } else { "dispatch workspace m+1" });
        });
        shell.add(&qh, Some(output), &wl::Placement {
            namespace: "hyprshell-rs:bar",
            layer: Layer::Top,
            anchor: Anchor::TOP | Anchor::LEFT | Anchor::RIGHT,
            width: 0,
            height: BAR_HEIGHT,
            exclusive: BAR_HEIGHT as i32,
            keyboard: KeyboardInteractivity::None,
        });
        bars.push(BarOn { bar, monitor });
    }
    refresh(&bars);

    // Hyprland's events, through a pipe the loop polls.
    let (tx, rx) = mpsc::channel::<String>();
    let (mut wake_rx, wake_tx) = UnixStream::pair().expect("a socket pair");
    wake_rx.set_nonblocking(true).ok();
    hypr::listen(tx, wake_tx);

    let mut last_tick = Instant::now();
    loop {
        let _ = conn.flush();
        let timeout = if shell.animating() {
            Duration::from_millis(8)
        } else {
            slint::platform::duration_until_next_timer_update()
                .unwrap_or(Duration::from_secs(1))
                .min(Duration::from_secs(1))
        };
        if let Some(guard) = queue.prepare_read() {
            let mut fds = [
                libc::pollfd { fd: guard.connection_fd().as_raw_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: wake_rx.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            ];
            // SAFETY: two valid pollfds, for the length of the call.
            unsafe { libc::poll(fds.as_mut_ptr(), 2, timeout.as_millis() as i32) };
            if fds[0].revents & libc::POLLIN != 0 {
                let _ = guard.read();
            }
        }
        if queue.dispatch_pending(&mut shell).is_err() {
            eprintln!("hyprshell-rs: the Wayland connection went away");
            break;
        }

        // Anything from Hyprland means the workspaces or the focus changed.
        let mut sink = [0u8; 256];
        while wake_rx.read(&mut sink).map(|n| n > 0).unwrap_or(false) {}
        let mut changed = false;
        while rx.try_recv().is_ok() {
            changed = true;
        }
        // And the clock and the battery, every second.
        if changed || last_tick.elapsed() >= Duration::from_secs(1) {
            last_tick = Instant::now();
            refresh(&bars);
        }

        slint::platform::update_timers_and_animations();
        shell.draw();
        if shell.closed {
            break;
        }
    }
}
