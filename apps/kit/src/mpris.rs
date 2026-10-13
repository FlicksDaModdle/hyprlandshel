//! MPRIS on the session bus, so the shell's media pill, the lock screen and
//! the media keys see an app's playback and can drive it (and the shell
//! keeps the screen awake while it says Playing). Also how a second launch
//! hands its files to the first: OpenUri, then it leaves.

use std::collections::HashMap;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use zbus::interface;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{ObjectPath, OwnedValue, Value};

const PATH: &str = "/org/mpris/MediaPlayer2";

/// Who the player is, on the bus.
#[derive(Clone, Copy)]
pub struct Info {
    /// The bus name, org.mpris.MediaPlayer2.<this>.
    pub name: &'static str,
    pub identity: &'static str,
    pub desktop_entry: &'static str,
    pub mime_types: &'static [&'static str],
}

impl Info {
    fn bus(&self) -> String {
        format!("org.mpris.MediaPlayer2.{}", self.name)
    }
}

/// What the bus asks of the app.
pub enum Remote {
    Raise,
    Quit,
    Play,
    Pause,
    PlayPause,
    Stop,
    Next,
    Previous,
    /// Relative, in seconds.
    Seek(f64),
    SetPosition(f64),
    Open(String),
    Volume(f64),
    Shuffle(bool),
    Loop(String),
}

#[derive(Clone, Default)]
pub struct State {
    pub status: String, // Playing, Paused, Stopped
    pub loop_status: String,
    pub shuffle: bool,
    pub volume: f64,
    pub id: u64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub length: f64,
    pub art: String,
    pub can_next: bool,
    pub can_prev: bool,
    pub has_track: bool,
}

/// What the app tells the bus.
pub enum Update {
    State(State),
    Seeked(f64),
}

type Ask = Arc<dyn Fn(Remote) + Send + Sync>;

struct Root {
    ask: Ask,
    info: Info,
}

#[interface(name = "org.mpris.MediaPlayer2")]
impl Root {
    fn raise(&self) {
        (self.ask)(Remote::Raise)
    }
    fn quit(&self) {
        (self.ask)(Remote::Quit)
    }
    #[zbus(property)]
    fn can_quit(&self) -> bool {
        true
    }
    #[zbus(property)]
    fn can_raise(&self) -> bool {
        true
    }
    #[zbus(property)]
    fn has_track_list(&self) -> bool {
        false
    }
    #[zbus(property)]
    fn identity(&self) -> String {
        self.info.identity.into()
    }
    #[zbus(property)]
    fn desktop_entry(&self) -> String {
        self.info.desktop_entry.into()
    }
    #[zbus(property)]
    fn supported_uri_schemes(&self) -> Vec<String> {
        vec!["file".into()]
    }
    #[zbus(property)]
    fn supported_mime_types(&self) -> Vec<String> {
        self.info.mime_types.iter().map(|s| s.to_string()).collect()
    }
}

struct Player {
    ask: Ask,
    state: State,
    position: Arc<dyn Fn() -> f64 + Send + Sync>,
}

fn us(s: f64) -> i64 {
    (s * 1e6) as i64
}

#[interface(name = "org.mpris.MediaPlayer2.Player")]
impl Player {
    fn next(&self) {
        (self.ask)(Remote::Next)
    }
    fn previous(&self) {
        (self.ask)(Remote::Previous)
    }
    fn pause(&self) {
        (self.ask)(Remote::Pause)
    }
    fn play_pause(&self) {
        (self.ask)(Remote::PlayPause)
    }
    fn stop(&self) {
        (self.ask)(Remote::Stop)
    }
    fn play(&self) {
        (self.ask)(Remote::Play)
    }
    fn seek(&self, offset: i64) {
        (self.ask)(Remote::Seek(offset as f64 / 1e6))
    }
    fn set_position(&self, track: ObjectPath<'_>, position: i64) {
        if track.as_str() == track_path(self.state.id).as_str() {
            (self.ask)(Remote::SetPosition(position as f64 / 1e6))
        }
    }
    fn open_uri(&self, uri: String) {
        (self.ask)(Remote::Open(uri))
    }
    #[zbus(signal)]
    async fn seeked(emitter: &SignalEmitter<'_>, position: i64) -> zbus::Result<()>;

    #[zbus(property)]
    fn playback_status(&self) -> String {
        if self.state.status.is_empty() { "Stopped".into() } else { self.state.status.clone() }
    }
    #[zbus(property)]
    fn loop_status(&self) -> String {
        if self.state.loop_status.is_empty() { "None".into() } else { self.state.loop_status.clone() }
    }
    #[zbus(property)]
    fn set_loop_status(&mut self, v: String) {
        (self.ask)(Remote::Loop(v))
    }
    #[zbus(property)]
    fn rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn set_rate(&mut self, _v: f64) {}
    #[zbus(property)]
    fn minimum_rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn maximum_rate(&self) -> f64 {
        1.0
    }
    #[zbus(property)]
    fn shuffle(&self) -> bool {
        self.state.shuffle
    }
    #[zbus(property)]
    fn set_shuffle(&mut self, v: bool) {
        (self.ask)(Remote::Shuffle(v))
    }
    #[zbus(property)]
    fn volume(&self) -> f64 {
        self.state.volume
    }
    #[zbus(property)]
    fn set_volume(&mut self, v: f64) {
        (self.ask)(Remote::Volume(v.clamp(0.0, 1.0)))
    }
    #[zbus(property(emits_changed_signal = "false"))]
    fn position(&self) -> i64 {
        us((self.position)())
    }
    #[zbus(property)]
    fn metadata(&self) -> HashMap<String, OwnedValue> {
        let s = &self.state;
        let mut m: HashMap<String, OwnedValue> = HashMap::new();
        let mut put = |k: &str, v: Value<'_>| {
            if let Ok(o) = v.try_to_owned() {
                m.insert(k.to_string(), o);
            }
        };
        put("mpris:trackid", Value::from(track_path(if s.has_track { s.id } else { 0 })));
        if s.has_track {
            put("mpris:length", Value::from(us(s.length)));
            put("xesam:title", Value::from(s.title.clone()));
            put("xesam:album", Value::from(s.album.clone()));
            put("xesam:artist", Value::from(vec![s.artist.clone()]));
            if !s.art.is_empty() {
                put("mpris:artUrl", Value::from(s.art.clone()));
            }
        }
        m
    }
    #[zbus(property)]
    fn can_go_next(&self) -> bool {
        self.state.can_next
    }
    #[zbus(property)]
    fn can_go_previous(&self) -> bool {
        self.state.can_prev
    }
    #[zbus(property)]
    fn can_play(&self) -> bool {
        self.state.has_track
    }
    #[zbus(property)]
    fn can_pause(&self) -> bool {
        self.state.has_track
    }
    #[zbus(property)]
    fn can_seek(&self) -> bool {
        self.state.has_track
    }
    #[zbus(property)]
    fn can_control(&self) -> bool {
        true
    }
}

fn track_path(id: u64) -> ObjectPath<'static> {
    if id == 0 {
        ObjectPath::from_static_str_unchecked("/org/mpris/MediaPlayer2/TrackList/NoTrack")
    } else {
        ObjectPath::try_from(format!("/org/hyprshell/track/{id}")).unwrap()
    }
}

/// Another of this app already has the name: hand it these files (or just
/// ask it to come forward) and say so.
pub fn hand_over(info: Info, uris: &[String]) -> bool {
    let bus = info.bus();
    let name_str = bus.as_str();
    let Ok(c) = zbus::blocking::Connection::session() else { return false };
    let Ok(dbus) = zbus::blocking::fdo::DBusProxy::new(&c) else { return false };
    let Ok(name) = zbus::names::BusName::try_from(name_str) else { return false };
    if !dbus.name_has_owner(name.clone()).unwrap_or(false) {
        return false;
    }
    if uris.is_empty() {
        let _ = c.call_method(Some(name_str), PATH, Some("org.mpris.MediaPlayer2"), "Raise", &());
    } else {
        for (i, u) in uris.iter().enumerate() {
            // The first plays; the rest queue after it.
            let u = if i == 0 { u.clone() } else { format!("{u}#queue") };
            let _ = c.call_method(Some(name_str), PATH, Some("org.mpris.MediaPlayer2.Player"), "OpenUri", &(u,));
        }
    }
    true
}

/// Serve the bus on a thread of its own. `ask` is called from that thread;
/// `position` too. Updates go in through the returned sender.
pub fn serve(
    info: Info,
    ask: impl Fn(Remote) + Send + Sync + 'static,
    position: impl Fn() -> f64 + Send + Sync + 'static,
) -> Option<Sender<Update>> {
    let (tx, rx) = channel::<Update>();
    let ask: Ask = Arc::new(ask);
    let position: Arc<dyn Fn() -> f64 + Send + Sync> = Arc::new(position);
    let started = Arc::new(Mutex::new(None::<bool>));
    let st = started.clone();
    std::thread::Builder::new()
        .name("mpris".into())
        .spawn(move || {
            let conn = zbus::blocking::connection::Builder::session()
                .and_then(|b| b.name(info.bus()))
                .and_then(|b| b.serve_at(PATH, Root { ask: ask.clone(), info }))
                .and_then(|b| b.serve_at(PATH, Player { ask, state: State::default(), position }))
                .and_then(|b| b.build());
            let conn = match conn {
                Ok(c) => {
                    *st.lock().unwrap() = Some(true);
                    c
                }
                Err(e) => {
                    eprintln!("{}: no MPRIS ({e})", info.name);
                    *st.lock().unwrap() = Some(false);
                    return;
                }
            };
            let Ok(iface) = conn.object_server().interface::<_, Player>(PATH) else { return };
            for u in rx {
                match u {
                    Update::State(s) => {
                        let (status, meta, other) = {
                            let mut p = iface.get_mut();
                            let old = std::mem::replace(&mut p.state, s);
                            let s = &p.state;
                            (
                                old.status != s.status,
                                old.id != s.id || old.title != s.title || old.art != s.art || old.length != s.length || old.has_track != s.has_track,
                                old.loop_status != s.loop_status || old.shuffle != s.shuffle || old.volume != s.volume || old.can_next != s.can_next || old.can_prev != s.can_prev,
                            )
                        };
                        let p = iface.get();
                        let e = iface.signal_emitter();
                        zbus::block_on(async {
                            if status {
                                let _ = p.playback_status_changed(e).await;
                            }
                            if meta {
                                let _ = p.metadata_changed(e).await;
                                let _ = p.can_play_changed(e).await;
                                let _ = p.can_pause_changed(e).await;
                                let _ = p.can_seek_changed(e).await;
                            }
                            if other {
                                let _ = p.loop_status_changed(e).await;
                                let _ = p.shuffle_changed(e).await;
                                let _ = p.volume_changed(e).await;
                                let _ = p.can_go_next_changed(e).await;
                                let _ = p.can_go_previous_changed(e).await;
                            }
                        });
                    }
                    Update::Seeked(at) => {
                        let _ = zbus::block_on(Player::seeked(iface.signal_emitter(), us(at)));
                    }
                }
            }
        })
        .ok()?;
    // Wait (briefly) to know whether the name was ours.
    for _ in 0..100 {
        if let Some(ok) = *started.lock().unwrap() {
            return ok.then_some(tx);
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    Some(tx)
}
