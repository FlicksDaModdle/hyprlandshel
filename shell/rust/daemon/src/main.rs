//! hyprshell-daemon — the system state the shell shows, read straight from
//! the system rather than polled out of command-line tools.
//!
//!   network       NetworkManager over D-Bus: the connection, the networks
//!                 in range, saved profiles — pushed as they change, in place
//!                 of `nmcli` every few seconds and `nmcli monitor`
//!   backlight     sysfs, with the kernel's own change events; set through
//!                 logind — in place of polling `brightnessctl`
//!   audio         PulseAudio (pipewire-pulse) natively: cards, modes,
//!                 connectors, which app plays where — in place of `pactl`
//!   night light   whether hyprsunset or wlsunset runs, from /proc — in
//!                 place of `pgrep`
//!   agent         Bluetooth from BlueZ with a pairing agent, and the
//!                 NetworkManager password agent — what hyprshell-agent
//!                 (C++) did, in this process rather than another one
//!   effects       the equalizer's and noise suppression's PipeWire
//!                 filter-chains, loaded here rather than each run as a
//!                 `pipewire -c` process
//!
//! It speaks to the shell as hyprshell-agent does: commands as JSON lines on
//! stdin, events as JSON lines on stdout (services/Daemon.qml). It exits
//! when stdin closes, so a shell reload takes it with it. Every part runs
//! on its own and fails on its own: a machine without NetworkManager still
//! gets the backlight.

mod agent;
mod backlight;
mod fx;
mod net;
mod nightlight;
mod out;
#[cfg(feature = "pulse")]
mod pulse;

use serde_json::{json, Value};
use std::io::BufRead;
use std::sync::mpsc::Sender;

fn main() {
    let net = net::start();
    let backlight = backlight::start();
    let nightlight = nightlight::start();
    let agent = agent::start();
    let fx = fx::start();
    #[cfg(feature = "pulse")]
    let pulse: Option<Sender<Value>> = Some(pulse::start());
    #[cfg(not(feature = "pulse"))]
    let pulse: Option<Sender<Value>> = None;

    out::emit(json!({
        "ev": "ready",
        "version": env!("CARGO_PKG_VERSION"),
        "modules": { "net": true, "backlight": true, "nightlight": true, "agent": true, "fx": fx::available(), "pulse": pulse.is_some() }
    }));

    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let Ok(cmd) = serde_json::from_str::<Value>(&line) else { continue };
        let name = cmd["cmd"].as_str().unwrap_or("");
        let to = if name.starts_with("net-") {
            Some(&net)
        } else if name.starts_with("bl-") {
            Some(&backlight)
        } else if name.starts_with("nl-") {
            Some(&nightlight)
        } else if name.starts_with("bt-") || name.starts_with("nm-") {
            Some(&agent)
        } else if name.starts_with("fx-") {
            Some(&fx)
        } else if name.starts_with("pa-") {
            pulse.as_ref()
        } else {
            if name == "ping" {
                out::emit(json!({ "ev": "pong" }));
            }
            None
        };
        if let Some(tx) = to {
            let _ = tx.send(cmd);
        }
    }
    // stdin closed: the shell is gone.
    std::process::exit(0);
}
