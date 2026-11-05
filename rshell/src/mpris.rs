//! What's playing, from MPRIS over the session bus: the player that is
//! playing (else the last one paused), its title, artist, art, position and
//! what it allows. Read once a second on a thread of its own; the bar's
//! buttons go back the other way as commands.

use std::io::Write;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{Receiver, Sender};
use std::time::Duration;
use zbus::blocking::Connection;
use zbus::zvariant::OwnedValue;

#[derive(Clone, Default, PartialEq)]
pub struct Media {
    pub available: bool,
    pub playing: bool,
    pub title: String,
    pub artist: String,
    pub art: String,
    pub length_us: i64,
    pub position_us: i64,
    pub can_prev: bool,
    pub can_next: bool,
    pub can_toggle: bool,
    pub can_seek: bool,
    pub bus: String,
    pub track: String,
}

pub enum Cmd {
    Prev,
    Toggle,
    Next,
    Seek(f64),
}

const PLAYER: &str = "org.mpris.MediaPlayer2.Player";

fn prop(c: &Connection, bus: &str, name: &str) -> Option<OwnedValue> {
    let p = zbus::blocking::fdo::PropertiesProxy::builder(c).destination(bus).ok()?.path("/org/mpris/MediaPlayer2").ok()?.build().ok()?;
    p.get(PLAYER.try_into().ok()?, name).ok()
}

fn read(c: &Connection) -> Media {
    let names: Vec<String> = zbus::blocking::fdo::DBusProxy::new(c)
        .ok()
        .and_then(|d| d.list_names().ok())
        .map(|n| n.into_iter().map(|x| x.to_string()).filter(|x| x.starts_with("org.mpris.MediaPlayer2.")).collect())
        .unwrap_or_default();
    let status = |b: &str| prop(c, b, "PlaybackStatus").and_then(|v| String::try_from(v).ok()).unwrap_or_default();
    let pick = names.iter().find(|b| status(b) == "Playing").or_else(|| names.iter().find(|b| status(b) == "Paused"));
    let Some(bus) = pick else { return Media::default() };
    let mut m = Media { available: true, playing: status(bus) == "Playing", bus: bus.to_string(), ..Default::default() };
    if let Some(md) = prop(c, bus, "Metadata").and_then(|v| std::collections::HashMap::<String, OwnedValue>::try_from(v).ok()) {
        let s = |k: &str| md.get(k).and_then(|v| String::try_from(v.try_clone().ok()?).ok()).unwrap_or_default();
        m.title = s("xesam:title");
        m.art = s("mpris:artUrl");
        // An object path by the spec; some players send a string.
        m.track = md
            .get("mpris:trackid")
            .and_then(|v| {
                zbus::zvariant::OwnedObjectPath::try_from(v.try_clone().ok()?)
                    .map(|p| p.to_string())
                    .ok()
                    .or_else(|| String::try_from(v.try_clone().ok()?).ok())
            })
            .unwrap_or_default();
        m.artist = md
            .get("xesam:artist")
            .and_then(|v| Vec::<String>::try_from(v.try_clone().ok()?).ok())
            .map(|a| a.join(", "))
            .unwrap_or_default();
        m.length_us = md
            .get("mpris:length")
            .and_then(|v| i64::try_from(v.try_clone().ok()?).ok().or_else(|| u64::try_from(v.try_clone().ok()?).ok().map(|x| x as i64)))
            .unwrap_or(0);
    }
    let b = |k: &str| prop(c, bus, k).and_then(|v| bool::try_from(v).ok()).unwrap_or(false);
    m.can_prev = b("CanGoPrevious");
    m.can_next = b("CanGoNext");
    m.can_toggle = b("CanPause") || b("CanPlay");
    m.can_seek = b("CanSeek");
    m.position_us = prop(c, bus, "Position").and_then(|v| i64::try_from(v).ok()).unwrap_or(0);
    m
}

pub fn start(tx: Sender<Media>, cmds: Receiver<Cmd>, mut wake: UnixStream) {
    std::thread::spawn(move || {
        let Ok(c) = Connection::session() else { return };
        let mut last = Media::default();
        loop {
            let now = read(&c);
            if now != last {
                last = now.clone();
                if tx.send(now).is_err() {
                    return;
                }
                let _ = wake.write_all(b"!");
            }
            // Once a second, or at once when a button is pressed — and read
            // again just after, so the play/pause glyph answers.
            let cmd = match cmds.recv_timeout(Duration::from_secs(1)) {
                Ok(cmd) => cmd,
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return,
            };
            if last.bus.is_empty() {
                continue;
            }
            let path = "/org/mpris/MediaPlayer2";
            let bus = last.bus.as_str();
            let _ = match cmd {
                Cmd::Prev => c.call_method(Some(bus), path, Some(PLAYER), "Previous", &()),
                Cmd::Toggle => c.call_method(Some(bus), path, Some(PLAYER), "PlayPause", &()),
                Cmd::Next => c.call_method(Some(bus), path, Some(PLAYER), "Next", &()),
                Cmd::Seek(f) => {
                    let at = (f.clamp(0.0, 1.0) * last.length_us as f64) as i64;
                    match zbus::zvariant::ObjectPath::try_from(last.track.as_str()) {
                        Ok(track) => c.call_method(Some(bus), path, Some(PLAYER), "SetPosition", &(track, at)),
                        // No track id: the same place, as a step from here.
                        Err(_) => c.call_method(Some(bus), path, Some(PLAYER), "Seek", &(at - last.position_us,)),
                    }
                }
            };
            std::thread::sleep(Duration::from_millis(120));
        }
    });
}
