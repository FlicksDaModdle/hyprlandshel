//! hyprshell-rs: Hyprshell's shell in Rust, on Hyprland.
//!
//! The platform that puts Slint on layer-shell surfaces (platform.rs,
//! wl.rs), Hyprland read straight from its sockets (hypr.rs), the shell's
//! look from its theme.json (theme.rs), the network and sound from
//! hyprshell-daemon (daemon.rs), what's playing from MPRIS (mpris.rs), and
//! the top bar on every monitor, laid out as modules/bar/Bar.qml has it.
//!
//! One thread runs everything that touches Slint or Wayland, asleep in
//! poll() on the Wayland connection, a wake pipe the helper threads write
//! to, and the time until Slint's next timer or animation frame.

mod daemon;
mod hypr;
mod mpris;
mod platform;
mod sys;
mod theme;
mod wl;

use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use smithay_client_toolkit::shell::wlr_layer::{Anchor, KeyboardInteractivity, Layer};
use std::cell::RefCell;
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::{Duration, Instant};
use wayland_client::{globals::registry_queue_init, Connection};

slint::include_modules!();

/// The local time as the bar shows it: "14:27" or "2:27 PM", "Thu 5 Nov".
fn clock(h24: bool) -> (String, String) {
    // SAFETY: localtime_r fills the tm it is given and keeps nothing.
    let tm = unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        tm
    };
    const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    let time = if h24 {
        format!("{:02}:{:02}", tm.tm_hour, tm.tm_min)
    } else {
        let h = match tm.tm_hour % 12 { 0 => 12, h => h };
        format!("{}:{:02} {}", h, tm.tm_min, if tm.tm_hour < 12 { "AM" } else { "PM" })
    };
    let date = format!("{} {} {}", DAYS[tm.tm_wday as usize % 7], tm.tm_mday, MONTHS[tm.tm_mon as usize % 12]);
    (time, date)
}

/// Workspace slots for one monitor's bar, as Compositor.workspaceSlots:
/// every workspace that exists, padded to five with the lowest free
/// numbers; the one that monitor shows is focused.
fn slots_for(monitor: &str) -> (Vec<Workspace>, String, String, bool) {
    let all = hypr::json("j/workspaces");
    let monitors = hypr::json("j/monitors");
    let clients = hypr::json("j/clients");
    let focused = monitors
        .as_array()
        .and_then(|ms| ms.iter().find(|m| m["name"] == monitor).or(ms.first()))
        .and_then(|m| m["activeWorkspace"]["id"].as_i64())
        .unwrap_or(1);
    let urgent: std::collections::HashSet<i64> = clients
        .as_array()
        .into_iter()
        .flatten()
        .filter(|c| c["urgent"] == true)
        .filter_map(|c| c["workspace"]["id"].as_i64())
        .collect();
    let mut ids: Vec<(i64, i64)> = Vec::new();
    for w in all.as_array().into_iter().flatten() {
        let id = w["id"].as_i64().unwrap_or(0);
        // Show desktop's stash (99) only when something landed on it.
        if id > 0 && (id != 99 || w["windows"].as_i64().unwrap_or(0) > 0) {
            ids.push((id, w["windows"].as_i64().unwrap_or(0)));
        }
    }
    if !ids.iter().any(|(i, _)| *i == focused) && focused > 0 && focused != 99 {
        ids.push((focused, 0));
    }
    let mut i = 1;
    while ids.len() < 5 && i <= 5 {
        if !ids.iter().any(|(x, _)| *x == i) {
            ids.push((i, 0));
        }
        i += 1;
    }
    ids.sort();
    let list = ids
        .into_iter()
        .map(|(id, n)| Workspace { id: id as i32, focused: id == focused, occupied: n > 0, urgent: urgent.contains(&id) })
        .collect();
    let active = hypr::json("j/activewindow");
    let class = active["class"].as_str().unwrap_or("").to_string();
    let title = active["title"].as_str().unwrap_or("").to_string();
    let has = active["address"].as_str().is_some_and(|a| !a.is_empty());
    (list, class, title, has)
}

struct BarOn {
    bar: Bar,
    monitor: String,
}

fn apply_theme(bar: &Bar, t: &theme::Theme, monitor: &str) {
    let g = bar.global::<Theme>();
    g.set_panel(t.panel.slint());
    g.set_ink(t.ink.slint());
    g.set_ink2(t.ink2.slint());
    g.set_ink3(t.ink3.slint());
    g.set_accent(t.accent.slint());
    g.set_ink_on_accent(t.ink_on_accent.slint());
    g.set_hover(t.hover.slint());
    g.set_sel(t.sel.slint());
    g.set_edge(t.edge.slint());
    g.set_rule(t.rule.slint());
    g.set_div(t.div.slint());
    g.set_r_cap(t.r);
    g.set_r_sm(t.r_sm);
    let us = t.screen_scale(monitor);
    g.set_us(us);
    g.set_ff(t.font_factor);
    g.set_ws(us * t.workspace_scale);
    g.set_bar_height(t.bar_height);
    g.set_bar_font(t.bar_font);
    g.set_bar_title(t.bar_title);
    g.set_bar_app(t.bar_app);
    g.set_bar_menu(t.bar_menu);
    g.set_bar_clock(t.bar_clock);
    g.set_bar_badge(t.bar_badge);
    g.set_bar_icon(t.bar_icon);
    g.set_badges(t.badges);
}

fn media_info(m: &mpris::Media) -> MediaInfo {
    // Album art comes with the media panel's art cache (it needs decoding
    // and, for Spotify, fetching); until then the pill shows the glyph.
    let art: Option<slint::Image> = None;
    MediaInfo {
        available: m.available,
        playing: m.playing,
        title: m.title.clone().into(),
        artist: m.artist.clone().into(),
        has_art: art.is_some(),
        art: art.unwrap_or_default(),
        progress: if m.length_us > 0 { (m.position_us as f32 / m.length_us as f32).clamp(0.0, 1.0) } else { 0.0 },
        has_length: m.length_us > 0,
        can_prev: m.can_prev,
        can_next: m.can_next,
        can_toggle: m.can_toggle,
        can_seek: m.can_seek,
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

    // Helper threads wake the loop through this.
    let (mut wake_rx, wake_tx) = UnixStream::pair().expect("a socket pair");
    wake_rx.set_nonblocking(true).ok();
    let (hypr_tx, hypr_rx) = mpsc::channel::<String>();
    hypr::listen(hypr_tx, wake_tx.try_clone().expect("wake"));
    let (daemon_tx, daemon_rx) = mpsc::channel();
    let daemon = Rc::new(RefCell::new(daemon::start(daemon_tx, wake_tx.try_clone().expect("wake"))));
    let mut sound = daemon::State::default();
    let (media_tx, media_rx) = mpsc::channel();
    let (media_cmd_tx, media_cmd_rx) = mpsc::channel();
    mpris::start(media_tx, media_cmd_rx, wake_tx.try_clone().expect("wake"));
    let mut media = mpris::Media::default();

    let mut look = theme::load();
    let mut look_stamp = theme::modified();

    // Where scrolling the status capsule sets the volume: the default
    // output and its level, from the daemon's last snapshot.
    let volume_target: Rc<RefCell<Option<(String, f64)>>> = Rc::new(RefCell::new(None));

    // A bar on every monitor.
    let mut bars: Vec<BarOn> = Vec::new();
    let outputs: Vec<_> = shell.outputs.outputs().collect();
    for output in &outputs {
        let monitor = shell.outputs.info(output).and_then(|i| i.name).unwrap_or_default();
        let bar = Bar::new().expect("the bar");
        apply_theme(&bar, &look, &monitor);
        bar.on_workspace_go(|id| {
            hypr::ask(&format!("dispatch workspace {id}"));
        });
        bar.on_workspace_step(|d| {
            hypr::ask(if d < 0 { "dispatch workspace m-1" } else { "dispatch workspace m+1" });
        });
        {
            let target = volume_target.clone();
            let daemon = daemon.clone();
            bar.on_volume_step(move |d| {
                let mut t = target.borrow_mut();
                if let Some((sink, vol)) = t.as_mut() {
                    *vol = (*vol + 0.05 * d as f64).clamp(0.0, 1.0);
                    daemon.borrow_mut().send(serde_json::json!({ "cmd": "pa-volume", "name": sink, "volume": *vol }));
                }
            });
        }
        {
            let tx = media_cmd_tx.clone();
            bar.on_media_prev(move || { let _ = tx.send(mpris::Cmd::Prev); });
            let tx = media_cmd_tx.clone();
            bar.on_media_toggle(move || { let _ = tx.send(mpris::Cmd::Toggle); });
            let tx = media_cmd_tx.clone();
            bar.on_media_next(move || { let _ = tx.send(mpris::Cmd::Next); });
            let tx = media_cmd_tx.clone();
            bar.on_media_seek(move |f| { let _ = tx.send(mpris::Cmd::Seek(f as f64)); });
        }
        let us = look.screen_scale(&monitor);
        let height = (look.bar_height * us).round().max(1.0) as u32;
        shell.add(&qh, Some(output), &wl::Placement {
            // The Quickshell bar's namespace, so hyprland.lua's layer rules
            // (the blur behind it) apply to this one as they do to that.
            namespace: "quickshell:bar",
            layer: Layer::Top,
            anchor: Anchor::TOP | Anchor::LEFT | Anchor::RIGHT,
            width: 0,
            height,
            exclusive: height as i32,
            keyboard: KeyboardInteractivity::None,
        });
        bars.push(BarOn { bar, monitor });
    }

    // The equaliser's clock, only while something plays (12 frames a second,
    // as MediaPill's eqClock).
    let eq = slint::Timer::default();
    let eq_tick = Rc::new(RefCell::new(0i32));

    let refresh_hypr = |bars: &[BarOn]| {
        for b in bars {
            let (ws, class, title, has) = slots_for(&b.monitor);
            b.bar.set_workspaces(ModelRc::from(Rc::new(VecModel::from(ws))));
            b.bar.set_app_class(SharedString::from(class));
            b.bar.set_window_title(SharedString::from(title));
            b.bar.set_has_client(has);
        }
    };
    let refresh_clock = |bars: &[BarOn], look: &theme::Theme| {
        let (time, date) = clock(look.clock24);
        let battery = sys::battery();
        for b in bars {
            b.bar.set_time(time.clone().into());
            b.bar.set_date(date.clone().into());
            b.bar.set_battery(battery.as_ref().map(|x| x.percent).unwrap_or(-1));
            b.bar.set_charging(battery.as_ref().is_some_and(|x| x.charging));
        }
    };
    refresh_hypr(&bars);
    refresh_clock(&bars, &look);

    let mut last_tick = Instant::now();
    loop {
        let _ = conn.flush();
        let timeout = if shell.animating() {
            Duration::from_millis(8)
        } else {
            slint::platform::duration_until_next_timer_update().unwrap_or(Duration::from_secs(1)).min(Duration::from_secs(1))
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

        // Hyprland: workspaces and focus.
        let mut hypr_changed = false;
        while hypr_rx.try_recv().is_ok() {
            hypr_changed = true;
        }
        if hypr_changed {
            refresh_hypr(&bars);
        }

        // The daemon: network and sound.
        let mut sound_changed = false;
        while let Ok(ev) = daemon_rx.try_recv() {
            sound_changed |= daemon::apply(&mut sound, &ev);
        }
        if sound_changed {
            *volume_target.borrow_mut() = sound.have_audio.then(|| (sound.sink.clone(), sound.volume));
            let pct = (sound.volume * 100.0).round() as i32;
            let vol_label = if !sound.have_audio { String::new() } else if sound.muted { "muted".into() } else { format!("{pct}%") };
            let vol_icon = if sound.muted || sound.volume <= 0.001 { "volume-x" } else if sound.volume < 0.5 { "volume-low" } else { "volume" };
            for b in &bars {
                b.bar.set_net_label(sound.net_label.clone().into());
                b.bar.set_net_icon(sound.net_icon.into());
                b.bar.set_volume_label(vol_label.clone().into());
                b.bar.set_volume_icon(vol_icon.into());
            }
        }

        // What's playing.
        let mut media_changed = false;
        while let Ok(m) = media_rx.try_recv() {
            media = m;
            media_changed = true;
        }
        if media_changed {
            let info = media_info(&media);
            for b in &bars {
                b.bar.set_media(info.clone());
            }
            if media.playing && !eq.running() {
                let tick = eq_tick.clone();
                let handles: Vec<slint::Weak<Bar>> = bars.iter().map(|b| b.bar.as_weak()).collect();
                eq.start(slint::TimerMode::Repeated, Duration::from_millis(83), move || {
                    let mut t = tick.borrow_mut();
                    *t = t.wrapping_add(1);
                    for h in &handles {
                        if let Some(b) = h.upgrade() {
                            b.set_eq_tick(*t);
                        }
                    }
                });
            } else if !media.playing {
                eq.stop();
            }
        }

        // Every second: the clock, the battery, and theme.json.
        if last_tick.elapsed() >= Duration::from_secs(1) {
            last_tick = Instant::now();
            let stamp = theme::modified();
            if stamp != look_stamp {
                look_stamp = stamp;
                look = theme::load();
                for b in &bars {
                    apply_theme(&b.bar, &look, &b.monitor);
                }
            }
            refresh_clock(&bars, &look);
        }

        slint::platform::update_timers_and_animations();
        shell.draw();
        if shell.closed {
            break;
        }
    }
}
