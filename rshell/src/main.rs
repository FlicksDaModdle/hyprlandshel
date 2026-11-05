//! hyprshell-rs: Hyprshell's shell in Rust, on Hyprland.
//!
//! The platform that puts Slint on layer-shell surfaces (platform.rs,
//! wl.rs), Hyprland read straight from its sockets (hypr.rs), the shell's
//! look from its theme.json (theme.rs), the network, sound, backlight,
//! Bluetooth, drives and the keybinds' commands from hyprshell-daemon
//! (daemon.rs), what's playing from MPRIS (mpris.rs), the tray (tray.rs),
//! notifications (notify.rs) and the bar's smaller indicators (extras.rs).
//! app.rs holds it together: the bar on every monitor, the panels that
//! drop from it, and the notification banners.
//!
//! One thread runs everything that touches Slint or Wayland, asleep in
//! poll() on the Wayland connection, a wake pipe the helper threads write
//! to, and the time until Slint's next timer or animation frame.

mod app;
mod art;
mod daemon;
mod dock;
mod extras;
mod glyphs;
mod hypr;
mod icons;
mod launch_ui;
mod launcher;
mod mpris;
mod notify;
mod platform;
mod spring;
mod sys;
mod theme;
mod tray;
mod wl;

use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::Duration;
use wayland_client::{globals::registry_queue_init, Connection};

slint::include_modules!();

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

    // Helper threads wake the loop through this.
    let (mut wake_rx, wake_tx) = UnixStream::pair().expect("a socket pair");
    wake_rx.set_nonblocking(true).ok();

    let mut app = app::App::new(&mut shell, &qh, wake_tx);

    loop {
        let _ = conn.flush();
        let repeat = shell.repeat_keys();
        let timeout = if shell.animating() {
            Duration::from_millis(8)
        } else {
            slint::platform::duration_until_next_timer_update().unwrap_or(Duration::from_secs(1)).min(app.next_tick())
                .min(repeat.unwrap_or(Duration::from_secs(1)))
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
        let mut sink = [0u8; 256];
        while wake_rx.read(&mut sink).map(|n| n > 0).unwrap_or(false) {}

        app.step(&mut shell, &qh);
        slint::platform::update_timers_and_animations();
        // What the pointer did on the way in (clicks run callbacks, and
        // those only queue actions; this is where they are carried out).
        app.run_actions(&mut shell, &qh);
        shell.draw();
        if shell.closed {
            break;
        }
    }
}
