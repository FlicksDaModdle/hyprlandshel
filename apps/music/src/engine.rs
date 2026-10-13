//! Playback. Symphonia decodes on a thread of its own into a short buffer
//! of stereo floats; PulseAudio (spoken natively by the `pulseaudio` crate,
//! no libpulse) drains it at the sound card's pace. PipeWire's pulse
//! server answers it the same way.
//!
//! The server keeps only a fifth of a second of audio, so pausing, seeking
//! and the volume answer at once, and the position the app shows is what
//! is coming out of the speakers, near enough.

use pulseaudio::{protocol, AsPlaybackSource, Client, PlaybackStream};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::core::units::Time;

/// What the server holds ahead of the speakers.
const LATENCY: f64 = 0.2;
/// What we decode ahead of the server.
const AHEAD: f64 = 0.75;

pub enum Cmd {
    /// `token` comes back with what happens to this track.
    Load { path: PathBuf, play: bool, at: f64, token: u64 },
    Play,
    Pause,
    Seek(f64),
    Stop,
    Volume(f32),
}

pub enum Event {
    /// The track played to its end.
    Ended(u64),
    /// It couldn't be played: the reason, said plainly.
    Failed(u64, String),
}

#[derive(Default)]
struct Shared {
    buf: VecDeque<f32>,
    rate: u32,
    /// Where `played` counts from, in seconds (a load or a seek).
    base: f64,
    played: u64,
    volume: f32,
    eof: bool,
    ended: bool,
    playing: bool,
    dur: f64,
    token: u64,
}

impl Shared {
    fn position(&self) -> f64 {
        if self.rate == 0 {
            return self.base;
        }
        let out = self.played as f64 / self.rate as f64;
        let pos = self.base + (out - if self.ended { 0.0 } else { LATENCY }).max(0.0);
        if self.dur > 0.0 { pos.min(self.dur) } else { pos }
    }
}

pub struct Engine {
    tx: Sender<Cmd>,
    shared: Arc<Mutex<Shared>>,
}

impl Engine {
    pub fn new(notify: impl Fn(Event) + Send + Sync + 'static) -> Engine {
        let shared = Arc::new(Mutex::new(Shared { volume: 1.0, ..Default::default() }));
        let (tx, rx) = channel::<Cmd>();
        let sh = shared.clone();
        let notify: Arc<dyn Fn(Event) + Send + Sync> = Arc::new(notify);
        std::thread::Builder::new()
            .name("music-engine".into())
            .spawn(move || {
                let mut out = Output { client: None, stream: None, shared: sh.clone(), notify: notify.clone() };
                let mut track: Option<Track> = None;
                let mut chunk: Vec<f32> = Vec::new();
                loop {
                    let want = {
                        let s = sh.lock().unwrap();
                        track.is_some() && !s.eof && (s.buf.len() as f64) < s.rate as f64 * 2.0 * AHEAD
                    };
                    let cmd = if want {
                        rx.try_recv().ok()
                    } else {
                        match rx.recv_timeout(Duration::from_millis(25)) {
                            Ok(c) => Some(c),
                            Err(RecvTimeoutError::Timeout) => None,
                            Err(RecvTimeoutError::Disconnected) => break,
                        }
                    };
                    if let Some(cmd) = cmd {
                        match cmd {
                            Cmd::Load { path, play, at, token } => {
                                sh.lock().unwrap().token = token;
                                track = None;
                                out.pause();
                                match Track::open(&path) {
                                    Ok(mut t) => {
                                        if let Err(e) = out.ensure(t.rate) {
                                            notify(Event::Failed(token, e));
                                            continue;
                                        }
                                        let at = if at > 0.5 { t.seek(at) } else { 0.0 };
                                        {
                                            let mut s = sh.lock().unwrap();
                                            s.buf.clear();
                                            s.rate = t.rate;
                                            s.base = at;
                                            s.played = 0;
                                            s.eof = false;
                                            s.ended = false;
                                            s.dur = t.dur;
                                        }
                                        out.flush();
                                        track = Some(t);
                                        if play {
                                            out.play();
                                        }
                                    }
                                    Err(e) => notify(Event::Failed(token, e)),
                                }
                            }
                            Cmd::Play => {
                                if track.is_some() {
                                    out.play();
                                }
                            }
                            Cmd::Pause => out.pause(),
                            Cmd::Seek(at) => {
                                if let Some(t) = track.as_mut() {
                                    {
                                        let mut s = sh.lock().unwrap();
                                        s.buf.clear();
                                        s.eof = false;
                                        s.ended = false;
                                    }
                                    out.flush();
                                    let at = t.seek(at);
                                    let mut s = sh.lock().unwrap();
                                    s.buf.clear();
                                    s.base = at;
                                    s.played = 0;
                                }
                            }
                            Cmd::Stop => {
                                track = None;
                                out.pause();
                                let mut s = sh.lock().unwrap();
                                s.buf.clear();
                                s.base = 0.0;
                                s.played = 0;
                                s.dur = 0.0;
                            }
                            Cmd::Volume(v) => sh.lock().unwrap().volume = v.clamp(0.0, 1.0),
                        }
                        continue;
                    }
                    if !want {
                        continue;
                    }
                    let Some(t) = track.as_mut() else { continue };
                    chunk.clear();
                    let more = t.next(&mut chunk);
                    let mut s = sh.lock().unwrap();
                    s.buf.extend(chunk.iter());
                    if !more {
                        s.eof = true;
                    }
                }
            })
            .expect("engine thread");
        Engine { tx, shared }
    }

    pub fn send(&self, c: Cmd) {
        let _ = self.tx.send(c);
    }

    /// Where the speakers are in the track, in seconds.
    pub fn position(&self) -> f64 {
        self.shared.lock().unwrap().position()
    }

    /// The position, readable from any thread (for the bus).
    pub fn clock(&self) -> impl Fn() -> f64 + Send + Sync + 'static {
        let sh = self.shared.clone();
        move || sh.lock().unwrap().position()
    }

    pub fn duration(&self) -> f64 {
        self.shared.lock().unwrap().dur
    }

}

// ── the sound server ────────────────────────────────────────────────────

struct Output {
    client: Option<Client>,
    stream: Option<(PlaybackStream, u32)>,
    shared: Arc<Mutex<Shared>>,
    notify: Arc<dyn Fn(Event) + Send + Sync>,
}

impl Output {
    /// A stream at this rate, made (or remade) as needed.
    fn ensure(&mut self, rate: u32) -> Result<(), String> {
        if let Some((s, r)) = &self.stream {
            if *r == rate {
                return Ok(());
            }
            let s = s.clone();
            self.stream = None;
            let _ = futures::executor::block_on(s.delete());
        }
        for attempt in 0..2 {
            if self.client.is_none() {
                self.client = Some(connect().ok_or_else(|| "There's no sound server to play to".to_string())?);
            }
            let client = self.client.clone().unwrap();
            match futures::executor::block_on(client.create_playback_stream(self.params(rate), self.source())) {
                Ok(s) => {
                    self.stream = Some((s, rate));
                    return Ok(());
                }
                Err(e) => {
                    // The server went away and came back (PipeWire restarts):
                    // connect afresh, once.
                    self.client = None;
                    if attempt == 1 {
                        return Err(format!("The sound server turned the stream down ({e})"));
                    }
                }
            }
        }
        Err("There's no sound server to play to".into())
    }

    fn params(&self, rate: u32) -> protocol::PlaybackStreamParams {
        let mut props = protocol::Props::new();
        props.set(protocol::Prop::MediaRole, c"music");
        props.set(protocol::Prop::ApplicationIconName, c"hyprshell-music");
        props.set(protocol::Prop::ApplicationId, c"hyprshell-music");
        props.set(protocol::Prop::MediaName, c"Music");
        let bytes_per_sec = rate * 2 * 4;
        protocol::PlaybackStreamParams {
            sample_spec: protocol::SampleSpec { format: protocol::SampleFormat::Float32Le, channels: 2, sample_rate: rate },
            channel_map: protocol::ChannelMap::stereo(),
            cvolume: Some(protocol::ChannelVolume::norm(2)),
            sink_name: Some(protocol::DEFAULT_SINK.to_owned()),
            buffer_attr: protocol::stream::BufferAttr {
                target_length: (bytes_per_sec as f64 * LATENCY) as u32 / 8 * 8,
                ..Default::default()
            },
            flags: protocol::stream::StreamFlags { start_corked: true, ..Default::default() },
            props,
            ..Default::default()
        }
    }

    /// What the server pulls from: the decoded buffer, at the volume, and
    /// silence while it's empty (an empty answer would end the stream).
    fn source(&self) -> impl pulseaudio::PlaybackSource {
        let sh = self.shared.clone();
        let notify = self.notify.clone();
        let cb = move |out: &mut [u8]| {
            let mut s = sh.lock().unwrap();
            let want = out.len() / 8 * 2;
            let take = want.min(s.buf.len() / 2 * 2);
            let v = s.volume * s.volume;
            for (i, x) in s.buf.drain(..take).enumerate() {
                out[i * 4..i * 4 + 4].copy_from_slice(&(x * v).to_le_bytes());
            }
            out[take * 4..].fill(0);
            s.played += take as u64 / 2;
            let done = take == 0 && s.eof && !s.ended && s.playing;
            if done {
                s.ended = true;
            }
            let token = s.token;
            drop(s);
            if done {
                notify(Event::Ended(token));
            }
            out.len()
        };
        cb.as_playback_source()
    }

    fn play(&mut self) {
        if let Some((s, _)) = &self.stream {
            let _ = futures::executor::block_on(s.uncork());
            self.shared.lock().unwrap().playing = true;
        }
    }

    fn pause(&mut self) {
        if let Some((s, _)) = &self.stream {
            let _ = futures::executor::block_on(s.cork());
        }
        self.shared.lock().unwrap().playing = false;
    }

    fn flush(&mut self) {
        if let Some((s, _)) = &self.stream {
            let _ = futures::executor::block_on(s.flush());
        }
    }
}

/// Connect the way libpulse does: the socket from the environment, and the
/// cookie from ~/.config/pulse/cookie — made, as libpulse makes it, when
/// it isn't there yet (a fresh PipeWire system often has none, and the
/// server turns an empty one away).
fn connect() -> Option<Client> {
    let mut socks: Vec<PathBuf> = Vec::new();
    if let Ok(s) = std::env::var("PULSE_SERVER") {
        if let Some(p) = s.strip_prefix("unix:") {
            socks.push(PathBuf::from(p));
        }
    }
    for v in ["PULSE_RUNTIME_PATH", "XDG_RUNTIME_DIR"] {
        if let Some(d) = std::env::var_os(v) {
            let d = PathBuf::from(d);
            socks.push(if v == "XDG_RUNTIME_DIR" { d.join("pulse/native") } else { d.join("native") });
        }
    }
    let sock = socks.into_iter().find(|p| p.exists())?;
    let stream = std::os::unix::net::UnixStream::connect(sock).ok()?;
    Client::new_unix(c"Music", stream, Some(cookie())).ok()
}

fn cookie() -> Vec<u8> {
    let named = std::env::var_os("PULSE_COOKIE").map(PathBuf::from);
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let config = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).unwrap_or_else(|| home.join(".config"));
    let mine = config.join("pulse/cookie");
    for p in named.iter().chain([&mine, &home.join(".pulse-cookie")]) {
        if let Ok(c) = std::fs::read(p) {
            if c.len() == 256 {
                return c;
            }
        }
    }
    let mut c = vec![0u8; 256];
    use std::io::Read;
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut c);
    }
    if std::fs::create_dir_all(mine.parent().unwrap()).is_ok() {
        use std::os::unix::fs::OpenOptionsExt;
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&mine) {
            let _ = f.write_all(&c);
        }
    }
    c
}

// ── decoding ────────────────────────────────────────────────────────────

struct Track {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    id: u32,
    rate: u32,
    dur: f64,
    samples: Option<SampleBuffer<f32>>,
}

impl Track {
    fn open(path: &Path) -> Result<Track, String> {
        let file = std::fs::File::open(path).map_err(|e| format!("Couldn't open it: {e}"))?;
        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let mut hint = Hint::new();
        if let Some(e) = path.extension().and_then(|e| e.to_str()) {
            hint.with_extension(e);
        }
        let probed = symphonia::default::get_probe()
            .format(&hint, mss, &FormatOptions { enable_gapless: true, ..Default::default() }, &MetadataOptions::default())
            .map_err(|_| "It isn't a kind of audio Music can play".to_string())?;
        let format = probed.format;
        let track = format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL && t.codec_params.sample_rate.is_some())
            .ok_or("There's no sound in it")?;
        let params = track.codec_params.clone();
        let decoder = symphonia::default::get_codecs()
            .make(&params, &DecoderOptions::default())
            .map_err(|_| "Its sound is in a format Music can't decode".to_string())?;
        let rate = params.sample_rate.unwrap_or(44100);
        let dur = match (params.n_frames, params.time_base) {
            (Some(n), Some(tb)) => {
                let t = tb.calc_time(n);
                t.seconds as f64 + t.frac
            }
            (Some(n), None) => n as f64 / rate as f64,
            _ => 0.0,
        };
        Ok(Track { id: track.id, format, decoder, rate, dur, samples: None })
    }

    /// Seek near `secs`; where it landed.
    fn seek(&mut self, secs: f64) -> f64 {
        let secs = secs.max(0.0);
        let to = SeekTo::Time { time: Time::from(secs), track_id: Some(self.id) };
        match self.format.seek(SeekMode::Accurate, to) {
            Ok(s) => {
                self.decoder.reset();
                match self.format.tracks().iter().find(|t| t.id == self.id).and_then(|t| t.codec_params.time_base) {
                    Some(tb) => {
                        let t = tb.calc_time(s.actual_ts);
                        t.seconds as f64 + t.frac
                    }
                    None => secs,
                }
            }
            Err(_) => 0.0,
        }
    }

    /// Decode the next packet as stereo into `out`; false at the end.
    fn next(&mut self, out: &mut Vec<f32>) -> bool {
        loop {
            let packet = match self.format.next_packet() {
                Ok(p) => p,
                Err(SymError::ResetRequired) => {
                    self.decoder.reset();
                    continue;
                }
                Err(_) => return false,
            };
            if packet.track_id() != self.id {
                continue;
            }
            match self.decoder.decode(&packet) {
                Ok(buf) => {
                    let spec = *buf.spec();
                    let n = buf.capacity() as u64;
                    if self.samples.as_ref().map_or(true, |s| s.capacity() < (n as usize) * spec.channels.count()) {
                        self.samples = Some(SampleBuffer::new(n, spec));
                    }
                    let sb = self.samples.as_mut().unwrap();
                    sb.copy_interleaved_ref(buf);
                    let ch = spec.channels.count().max(1);
                    let s = sb.samples();
                    out.reserve(s.len() / ch * 2);
                    match ch {
                        1 => {
                            for &x in s {
                                out.push(x);
                                out.push(x);
                            }
                        }
                        2 => out.extend_from_slice(s),
                        _ => {
                            // Front left and right; the rest folded in quietly.
                            for f in s.chunks_exact(ch) {
                                let rest: f32 = f[2..].iter().sum::<f32>() * 0.35 / (ch - 2) as f32;
                                out.push((f[0] + rest).clamp(-1.0, 1.0));
                                out.push((f[1] + rest).clamp(-1.0, 1.0));
                            }
                        }
                    }
                    return true;
                }
                Err(SymError::DecodeError(_)) => continue,
                Err(_) => return false,
            }
        }
    }
}
