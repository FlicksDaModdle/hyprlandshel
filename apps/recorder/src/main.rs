//! Sound Recorder: voice memos, or what the computer is playing, kept as
//! FLAC (lossless, about half the size) or WAV in ~/Recordings.
//!
//! The sound server's samples go to a thread of their own that writes them
//! to disk as they come — an hour costs no more memory than a minute — and
//! become FLAC (flacenc, in Rust) when the recording is kept. Playback is
//! Music's engine.

slint::include_modules!();

use hyprshell_audio::engine::{Cmd, Engine, Event, Who};
use hyprshell_audio::record::{self, Input, Recording};
use hyprshell_kit as kit;
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const RATE: u32 = 48000;
const EXTS: &[&str] = &["flac", "wav", "ogg", "mp3", "m4a"];

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct Settings {
    #[serde(default)]
    wav: bool,
    #[serde(default)]
    stereo: bool,
    #[serde(default)]
    input: String,
}

fn settings_file() -> PathBuf {
    kit::config_dir().join("hyprshell-recorder/settings.json")
}

fn folder() -> PathBuf {
    std::env::var_os("HYPRSHELL_RECORDINGS_DIR").map(PathBuf::from).unwrap_or_else(|| kit::home().join("Recordings"))
}

fn pretty(p: &Path) -> String {
    p.to_string_lossy().replace(&*kit::home().to_string_lossy(), "~")
}

// ── what's on disk ──────────────────────────────────────────────────────

/// Seconds of sound in a WAV or FLAC file, from its header.
fn length_of(p: &Path) -> Option<f64> {
    match p.extension()?.to_str()?.to_ascii_lowercase().as_str() {
        "wav" => {
            let r = hound::WavReader::open(p).ok()?;
            Some(r.duration() as f64 / r.spec().sample_rate as f64)
        }
        "flac" => {
            // fLaC, then STREAMINFO: rate (20 bits), channels, depth, total samples (36 bits).
            let mut b = [0u8; 42];
            use std::io::Read;
            std::fs::File::open(p).ok()?.read_exact(&mut b).ok()?;
            if &b[0..4] != b"fLaC" {
                return None;
            }
            let si = &b[8..];
            let rate = ((si[10] as u32) << 12) | ((si[11] as u32) << 4) | ((si[12] as u32) >> 4);
            let total = (((si[13] & 0x0f) as u64) << 32) | ((si[14] as u64) << 24) | ((si[15] as u64) << 16) | ((si[16] as u64) << 8) | si[17] as u64;
            (rate > 0).then(|| total as f64 / rate as f64)
        }
        _ => None,
    }
}

fn list(dir: &Path) -> Vec<(PathBuf, i64, u64)> {
    let mut out = Vec::new();
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            let ok = p.extension().and_then(|x| x.to_str()).is_some_and(|x| EXTS.contains(&x.to_ascii_lowercase().as_str()));
            if !ok {
                continue;
            }
            let Ok(m) = e.metadata() else { continue };
            let t = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs() as i64);
            out.push((p, t, m.len()));
        }
    }
    out.sort_by(|a, b| b.1.cmp(&a.1));
    out
}

/// "Recording 2026-10-13 22.41", made unique in `dir`.
fn new_name(dir: &Path, ext: &str) -> PathBuf {
    let (y, mo, d, h, mi, _) = kit::local(kit::now());
    let base = format!("Recording {y}-{mo:02}-{d:02} {h:02}.{mi:02}");
    let mut p = dir.join(format!("{base}.{ext}"));
    let mut n = 2;
    while p.exists() {
        p = dir.join(format!("{base} ({n}).{ext}"));
        n += 1;
    }
    p
}

// ── FLAC, from the WAV written while recording ──────────────────────────

struct WavSource {
    r: hound::WavReader<std::io::BufReader<std::fs::File>>,
    ch: usize,
    rate: usize,
    buf: Vec<i32>,
}

impl flacenc::source::Source for WavSource {
    fn channels(&self) -> usize {
        self.ch
    }
    fn bits_per_sample(&self) -> usize {
        16
    }
    fn sample_rate(&self) -> usize {
        self.rate
    }
    fn read_samples<F: flacenc::source::Fill>(&mut self, block: usize, dest: &mut F) -> Result<usize, flacenc::error::SourceError> {
        self.buf.clear();
        for s in self.r.samples::<i16>().take(block * self.ch) {
            self.buf.push(s.map_err(flacenc::error::SourceError::from_io_error)? as i32);
        }
        dest.fill_interleaved(&self.buf)?;
        Ok(self.buf.len() / self.ch)
    }
    fn len_hint(&self) -> Option<usize> {
        Some(self.r.duration() as usize)
    }
}

fn to_flac(wav: &Path, out: &Path) -> Result<(), String> {
    use flacenc::component::BitRepr;
    use flacenc::error::Verify;
    let r = hound::WavReader::open(wav).map_err(|e| e.to_string())?;
    let spec = r.spec();
    let src = WavSource { ch: spec.channels as usize, rate: spec.sample_rate as usize, r, buf: Vec::new() };
    let cfg = flacenc::config::Encoder::default().into_verified().map_err(|e| format!("{:?}", e.1))?;
    let stream = flacenc::encode_with_fixed_block_size(&cfg, src, cfg.block_size).map_err(|e| format!("{e:?}"))?;
    let mut sink = flacenc::bitsink::ByteSink::new();
    stream.write(&mut sink).map_err(|e| format!("{e:?}"))?;
    kit::write_atomic(out, sink.as_slice()).map_err(|e| e.to_string())
}

// ── a recording in progress ─────────────────────────────────────────────

#[derive(Default)]
struct Meter {
    /// Peaks, a twentieth of a second each, newest last.
    levels: VecDeque<f32>,
    frames: u64,
    acc: f32,
    n: usize,
    error: Option<String>,
}

struct Session {
    rec: Recording,
    tx: Sender<Vec<f32>>,
    writer: std::thread::JoinHandle<Result<(), String>>,
    tmp: PathBuf,
    out: PathBuf,
    flac: bool,
    meter: Arc<Mutex<Meter>>,
}

struct App {
    win: AppWindow,
    session: RefCell<Option<Session>>,
    settings: RefCell<Settings>,
    inputs: RefCell<Vec<Input>>,
    engine: Engine,
    playing: RefCell<Option<PathBuf>>,
    tick: slint::Timer,
    play_tick: slint::Timer,
    toast_timer: slint::Timer,
}

thread_local! {
    static APP: RefCell<Option<Rc<App>>> = const { RefCell::new(None) };
}

fn with_app(f: impl FnOnce(&Rc<App>)) {
    APP.with(|a| {
        if let Some(a) = a.borrow().as_ref().cloned() {
            f(&a)
        }
    })
}

fn clock_tenths(s: f64) -> String {
    let t = (s * 10.0) as u64;
    let (m, sec, d) = (t / 600, t / 10 % 60, t % 10);
    if m >= 60 { format!("{}:{:02}:{:02}.{d}", m / 60, m % 60, sec) } else { format!("{m}:{sec:02}.{d}") }
}

impl App {
    fn g(&self) -> Recorder<'_> {
        self.win.global::<Recorder>()
    }

    fn toast(&self, t: &str) {
        self.g().set_toast(t.into());
        let w = self.win.as_weak();
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(2600), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Recorder>().set_toast(SharedString::new());
            }
        });
    }

    fn save_settings(&self) {
        let p = settings_file();
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        let _ = kit::write_atomic(&p, serde_json::to_string_pretty(&*self.settings.borrow()).unwrap_or_default().as_bytes());
    }

    fn show_list(&self) {
        let rows: Vec<Rec> = list(&folder())
            .into_iter()
            .map(|(p, t, size)| {
                let mut sub = vec![kit::when(t)];
                if let Some(l) = length_of(&p) {
                    sub.push(kit::clock(l));
                }
                sub.push(kit::bytes(size));
                if let Some(x) = p.extension() {
                    sub.push(x.to_string_lossy().to_uppercase());
                }
                Rec {
                    path: p.to_string_lossy().to_string().into(),
                    name: p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default().into(),
                    sub: sub.join(" · ").into(),
                }
            })
            .collect();
        self.g().set_recs(ModelRc::new(VecModel::from(rows)));
    }

    fn show_inputs(&self) {
        let inputs = self.inputs.borrow();
        let cur = self.settings.borrow().input.clone();
        let chosen = inputs.iter().position(|i| i.name == cur).unwrap_or(0);
        let rows: Vec<MenuEntry> = inputs
            .iter()
            .enumerate()
            .map(|(n, i)| MenuEntry {
                text: i.label.clone().into(),
                icon: if i.monitor { "speaker" } else { "mic" }.into(),
                checked: n == chosen,
                rule: i.monitor && (n == 0 || !inputs[n - 1].monitor),
                ..Default::default()
            })
            .collect();
        let g = self.g();
        g.set_inputs(ModelRc::new(VecModel::from(rows)));
        match inputs.get(chosen) {
            Some(i) => {
                g.set_input_label(i.label.clone().into());
                g.set_input_monitor(i.monitor);
            }
            None => g.set_input_label("Default microphone".into()),
        }
    }

    fn refresh_inputs(self: &Rc<Self>) {
        let a = self.clone();
        kit::spawn(record::inputs, move |r| match r {
            Ok((list, _default)) => {
                *a.inputs.borrow_mut() = list;
                a.g().set_error(SharedString::new());
                a.show_inputs();
            }
            Err(e) => a.g().set_error(e.into()),
        });
    }

    fn record(&self) {
        if self.session.borrow().is_some() {
            return;
        }
        // Stop listening before recording.
        self.stop_playing();
        let dir = folder();
        if let Err(e) = std::fs::create_dir_all(&dir) {
            self.toast(&format!("Couldn't make {} ({e})", pretty(&dir)));
            return;
        }
        let (flac, stereo) = {
            let s = self.settings.borrow();
            (!s.wav, s.stereo)
        };
        let ch: u16 = if stereo { 2 } else { 1 };
        let out = new_name(&dir, if flac { "flac" } else { "wav" });
        // WAV is written beside where it ends up (hidden till it's done);
        // the FLAC is made from it after.
        let tmp = dir.join(format!(".{}.part.wav", out.file_stem().unwrap().to_string_lossy()));
        let spec = hound::WavSpec { channels: ch, sample_rate: RATE, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
        let mut w = match hound::WavWriter::create(&tmp, spec) {
            Ok(w) => w,
            Err(e) => {
                self.toast(&format!("Couldn't write to {} ({e})", pretty(&dir)));
                return;
            }
        };
        let meter = Arc::new(Mutex::new(Meter::default()));
        let (tx, rx) = channel::<Vec<f32>>();
        let m2 = meter.clone();
        let writer = std::thread::Builder::new()
            .name("recorder-writer".into())
            .spawn(move || {
                for block in rx {
                    for x in block {
                        let v = (x.clamp(-1.0, 1.0) * 32767.0).round() as i16;
                        if let Err(e) = w.write_sample(v) {
                            m2.lock().unwrap().error = Some(e.to_string());
                            return Err(e.to_string());
                        }
                    }
                }
                w.finalize().map_err(|e| e.to_string())
            })
            .expect("writer");
        let m3 = meter.clone();
        let tx2 = tx.clone();
        let step = (RATE / 20) as usize * ch as usize;
        let sink = move |s: &[f32]| {
            {
                let mut m = m3.lock().unwrap();
                m.frames += (s.len() / ch as usize) as u64;
                for &x in s {
                    m.acc = m.acc.max(x.abs());
                    m.n += 1;
                    if m.n >= step {
                        let v = m.acc;
                        m.levels.push_back(v);
                        if m.levels.len() > 400 {
                            m.levels.pop_front();
                        }
                        m.acc = 0.0;
                        m.n = 0;
                    }
                }
            }
            let _ = tx2.send(s.to_vec());
        };
        let source = self.settings.borrow().input.clone();
        let rec = match Recording::start(Some(&source), ch as u8, RATE, sink) {
            Ok(r) => r,
            Err(e) => {
                drop(tx);
                let _ = writer.join();
                let _ = std::fs::remove_file(&tmp);
                self.g().set_error(e.clone().into());
                self.toast(&e);
                return;
            }
        };
        *self.session.borrow_mut() = Some(Session { rec, tx, writer, tmp, out, flac, meter });
        let g = self.g();
        g.set_state("recording".into());
        g.set_elapsed("0:00.0".into());
        g.set_error(SharedString::new());
        self.tick.start(slint::TimerMode::Repeated, Duration::from_millis(50), || with_app(|a| a.on_tick()));
    }

    fn on_tick(&self) {
        let (v, elapsed, err) = {
            let guard = self.session.borrow();
            let Some(sess) = guard.as_ref() else { return };
            let m = sess.meter.lock().unwrap();
            let fit = self.win.get_meter_bars().max(10) as usize;
            let skip = m.levels.len().saturating_sub(fit);
            let v: Vec<f32> = m.levels.iter().skip(skip).copied().collect();
            (v, m.frames as f64 / RATE as f64, m.error.clone())
        };
        let g = self.g();
        g.set_levels(ModelRc::new(VecModel::from(v)));
        g.set_elapsed(clock_tenths(elapsed).into());
        if let Some(e) = err {
            self.toast(&format!("Couldn't keep writing: {e}"));
            slint::Timer::single_shot(Duration::ZERO, || with_app(|a| a.stop()));
        }
    }

    fn pause(&self) {
        if let Some(s) = self.session.borrow().as_ref() {
            s.rec.pause();
            self.g().set_state("paused".into());
        }
    }

    fn resume(&self) {
        if let Some(s) = self.session.borrow().as_ref() {
            s.rec.resume();
            self.g().set_state("recording".into());
        }
    }

    fn stop(self: &Rc<Self>) {
        let Some(s) = self.session.borrow_mut().take() else { return };
        self.tick.stop();
        let g = self.g();
        g.set_state("saving".into());
        let Session { rec, tx, writer, tmp, out, flac, meter } = s;
        drop(rec);
        drop(tx);
        let frames = meter.lock().unwrap().frames;
        let a = self.clone();
        kit::spawn(
            move || -> Result<PathBuf, String> {
                writer.join().map_err(|_| "The writer stopped".to_string())??;
                if frames == 0 {
                    let _ = std::fs::remove_file(&tmp);
                    return Err("Nothing was heard, so nothing was kept".into());
                }
                if flac {
                    let r = to_flac(&tmp, &out);
                    let _ = std::fs::remove_file(&tmp);
                    r?;
                } else {
                    std::fs::rename(&tmp, &out).map_err(|e| e.to_string())?;
                }
                Ok(out)
            },
            move |r| {
                let g = a.g();
                g.set_state("idle".into());
                g.set_levels(ModelRc::default());
                match r {
                    Ok(p) => a.toast(&format!("Kept as {}", p.file_name().unwrap_or_default().to_string_lossy())),
                    Err(e) => a.toast(&e),
                }
                a.show_list();
            },
        );
    }

    fn cancel(&self) {
        let Some(s) = self.session.borrow_mut().take() else { return };
        self.tick.stop();
        let Session { rec, tx, writer, tmp, .. } = s;
        drop(rec);
        drop(tx);
        std::thread::spawn(move || {
            let _ = writer.join();
            let _ = std::fs::remove_file(&tmp);
        });
        let g = self.g();
        g.set_state("idle".into());
        g.set_levels(ModelRc::default());
        g.set_elapsed("0:00.0".into());
        self.toast("Thrown away");
    }

    // ── listening ──────────────────────────────────────────────────────

    fn play(self: &Rc<Self>, path: &str) {
        if self.session.borrow().is_some() {
            return;
        }
        let g = self.g();
        let p = PathBuf::from(path);
        if self.playing.borrow().as_deref() == Some(p.as_path()) {
            if g.get_playing() {
                self.engine.send(Cmd::Pause);
                g.set_playing(false);
                self.play_tick.stop();
            } else {
                if g.get_play_pos() >= g.get_play_dur() - 0.05 && g.get_play_dur() > 0.0 {
                    self.engine.send(Cmd::Seek(0.0));
                }
                self.engine.send(Cmd::Play);
                g.set_playing(true);
                self.ticking();
            }
            return;
        }
        *self.playing.borrow_mut() = Some(p.clone());
        self.engine.send(Cmd::Load { path: p.clone(), play: true, at: 0.0, token: 1 });
        g.set_playing_path(path.into());
        g.set_playing(true);
        g.set_play_pos(0.0);
        g.set_play_pos_text("0:00".into());
        g.set_wave(ModelRc::new(VecModel::from(vec![0.0f32; 160])));
        let a = self.clone();
        let q = p.clone();
        kit::spawn(
            move || hyprshell_audio::engine::peaks(&q, 160),
            move |r| {
                if a.playing.borrow().as_deref() != Some(p.as_path()) {
                    return;
                }
                if let Some((w, len)) = r {
                    let g = a.g();
                    g.set_wave(ModelRc::new(VecModel::from(w)));
                    g.set_play_dur(len as f32);
                    g.set_play_dur_text(kit::clock(len).into());
                }
            },
        );
        self.ticking();
    }

    fn ticking(&self) {
        self.play_tick.start(slint::TimerMode::Repeated, Duration::from_millis(100), || {
            with_app(|a| {
                let p = a.engine.position();
                let g = a.g();
                g.set_play_pos(p as f32);
                g.set_play_pos_text(kit::clock(p).into());
                let d = a.engine.duration();
                if d > 0.0 && g.get_play_dur() <= 0.0 {
                    g.set_play_dur(d as f32);
                    g.set_play_dur_text(kit::clock(d).into());
                }
            })
        });
    }

    fn stop_playing(&self) {
        if self.playing.borrow_mut().take().is_some() {
            self.engine.send(Cmd::Stop);
            self.play_tick.stop();
            let g = self.g();
            g.set_playing(false);
            g.set_playing_path(SharedString::new());
        }
    }
}

fn main() {
    kit::init("hyprshell-recorder");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-recorder");

    let settings: Settings = std::fs::read_to_string(settings_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    let engine = Engine::new(Who { name: c"Sound Recorder", id: c"hyprshell-recorder", role: c"music" }, |e| {
        let _ = slint::invoke_from_event_loop(move || {
            with_app(|a| match e {
                Event::Ended(_) => {
                    a.play_tick.stop();
                    let g = a.g();
                    g.set_playing(false);
                    g.set_play_pos(g.get_play_dur());
                    g.set_play_pos_text(g.get_play_dur_text());
                }
                Event::Failed(_, why) => {
                    a.toast(&why);
                    a.stop_playing();
                }
            })
        });
    });
    let app = Rc::new(App {
        win: ui.clone_strong(),
        session: RefCell::new(None),
        settings: RefCell::new(settings),
        inputs: RefCell::new(Vec::new()),
        engine,
        playing: RefCell::new(None),
        tick: slint::Timer::default(),
        play_tick: slint::Timer::default(),
        toast_timer: slint::Timer::default(),
    });
    APP.with(|a| *a.borrow_mut() = Some(app.clone()));

    let g = ui.global::<Recorder>();
    g.set_folder(pretty(&folder()).into());
    g.set_format(if app.settings.borrow().wav { 1 } else { 0 });
    g.set_stereo(app.settings.borrow().stereo);
    g.set_input_label("Default microphone".into());
    app.show_list();
    app.refresh_inputs();

    let a = app.clone();
    g.on_record(move || a.record());
    let a = app.clone();
    g.on_pause(move || a.pause());
    let a = app.clone();
    g.on_resume(move || a.resume());
    let a = app.clone();
    g.on_stop(move || a.stop());
    let a = app.clone();
    g.on_cancel(move || a.cancel());
    let a = app.clone();
    g.on_play(move |p| a.play(&p));
    let a = app.clone();
    g.on_seek(move |t| {
        a.engine.send(Cmd::Seek(t as f64));
        if !a.g().get_playing() {
            a.engine.send(Cmd::Play);
            a.g().set_playing(true);
            a.ticking();
        }
    });
    let a = app.clone();
    g.on_refresh_inputs(move || a.refresh_inputs());
    let a = app.clone();
    g.on_pick_input(move |i| {
        let name = a.inputs.borrow().get(i.max(0) as usize).map(|x| x.name.clone());
        if let Some(n) = name {
            a.settings.borrow_mut().input = n;
            a.save_settings();
            a.show_inputs();
        }
    });
    let a = app.clone();
    g.on_set_format(move |i| {
        a.settings.borrow_mut().wav = i == 1;
        a.g().set_format(i);
        a.save_settings();
    });
    let a = app.clone();
    g.on_set_stereo(move |on| {
        a.settings.borrow_mut().stereo = on;
        a.g().set_stereo(on);
        a.save_settings();
    });
    let a = app.clone();
    g.on_rename(move |p, to| {
        let to = to.trim().replace('/', "-");
        if to.is_empty() {
            return;
        }
        let p = PathBuf::from(p.as_str());
        let ext = p.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
        let dest = p.with_file_name(format!("{to}.{ext}"));
        if dest.exists() {
            a.toast("There's already a recording with that name");
            return;
        }
        if a.playing.borrow().as_deref() == Some(p.as_path()) {
            a.stop_playing();
        }
        match std::fs::rename(&p, &dest) {
            Ok(_) => a.show_list(),
            Err(e) => a.toast(&format!("Couldn't rename it ({e})")),
        }
    });
    let a = app.clone();
    g.on_delete(move |p| {
        let p = PathBuf::from(p.as_str());
        if a.playing.borrow().as_deref() == Some(p.as_path()) {
            a.stop_playing();
        }
        match kit::trash(&p) {
            Ok(_) => {
                a.toast("Moved to the Trash");
                a.show_list();
            }
            Err(e) => a.toast(&format!("Couldn't move it to the Trash ({e})")),
        }
    });
    g.on_show(move |p| {
        let dir = Path::new(p.as_str()).parent().map(Path::to_path_buf).unwrap_or_else(folder);
        let _ = std::process::Command::new("xdg-open").arg(dir).spawn();
    });
    g.on_open_folder(move || {
        let dir = folder();
        let _ = std::fs::create_dir_all(&dir);
        let _ = std::process::Command::new("xdg-open").arg(dir).spawn();
    });

    // Refresh the list when something else changes the folder.
    let a = app.clone();
    let seen = Cell::new(0u64);
    let watch = slint::Timer::default();
    watch.start(slint::TimerMode::Repeated, Duration::from_secs(3), move || {
        let stamp = std::fs::metadata(folder()).and_then(|m| m.modified()).ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_millis() as u64);
        if stamp != seen.get() {
            if seen.get() != 0 && a.session.borrow().is_none() {
                a.show_list();
            }
            seen.set(stamp);
        }
    });

    ui.run().expect("run");
    // Closing mid-recording keeps what was recorded.
    if app.session.borrow().is_some() {
        if let Some(s) = app.session.borrow_mut().take() {
            let Session { rec, tx, writer, tmp, out, flac, .. } = s;
            drop(rec);
            drop(tx);
            if writer.join().ok().and_then(|r| r.ok()).is_some() {
                if flac {
                    if to_flac(&tmp, &out).is_ok() {
                        let _ = std::fs::remove_file(&tmp);
                    }
                } else {
                    let _ = std::fs::rename(&tmp, &out);
                }
            }
        }
    }
}
