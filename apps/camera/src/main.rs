//! Camera: the webcam, photos and videos.
//!
//! ffmpeg does the capturing: it reads the camera (V4L2) and hands this
//! raw frames to show, and while a video is recording it writes that too
//! (H.264, with the microphone's sound if asked), from the same reading of
//! the camera — one program has it at a time. It dies with this app, so
//! the camera's light never stays on behind it. Photos are the frame on
//! screen, saved as JPEG (unmirrored), in Pictures/Camera; videos go in
//! Videos/Camera.

slint::include_modules!();

use hyprshell_kit as kit;
use slint::{ComponentHandle, Image, ModelRc, Rgb8Pixel, SharedPixelBuffer, SharedString, VecModel};
use std::cell::RefCell;
use std::io::{BufRead, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

// ── cameras ──────────────────────────────────────────────────────────────

#[derive(Clone, Debug)]
struct Camera {
    name: String,
    /// ffmpeg's input arguments, best first: 720p MJPEG, then whatever the
    /// camera gives by default.
    inputs: Vec<Vec<String>>,
}

fn strings(a: &[&str]) -> Vec<String> {
    a.iter().map(|s| s.to_string()).collect()
}

/// The capture devices: each camera's first node (the others are its
/// metadata). Infrared ones last: they're for face unlock.
fn cameras() -> Vec<Camera> {
    let mut found = Vec::new();
    if let Ok(rd) = std::fs::read_dir("/sys/class/video4linux") {
        for e in rd.flatten() {
            let node = e.file_name().to_string_lossy().to_string();
            let Some(n) = node.strip_prefix("video").and_then(|n| n.parse::<u32>().ok()) else { continue };
            let index = std::fs::read_to_string(e.path().join("index")).ok().and_then(|s| s.trim().parse::<u32>().ok()).unwrap_or(0);
            if index != 0 {
                continue;
            }
            let name = std::fs::read_to_string(e.path().join("name")).map(|s| s.trim().to_string()).unwrap_or_else(|_| node.clone());
            found.push((n, name));
        }
    }
    found.sort_by_key(|(n, name)| (is_ir(name), *n));
    let mut out: Vec<Camera> = found
        .into_iter()
        .map(|(n, name)| {
            let dev = format!("/dev/video{n}");
            Camera {
                name: short_name(&name),
                inputs: vec![
                    strings(&["-f", "v4l2", "-input_format", "mjpeg", "-video_size", "1280x720", "-framerate", "30", "-i", &dev]),
                    strings(&["-f", "v4l2", "-i", &dev]),
                ],
            }
        })
        .collect();
    // For trying it out without a camera.
    if std::env::var_os("HYPRSHELL_CAMERA_TEST").is_some() {
        out.push(Camera { name: "Test".into(), inputs: vec![strings(&["-re", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30"])] });
    }
    out
}

fn is_ir(name: &str) -> bool {
    let n = name.to_lowercase();
    n.contains(" ir") || n.contains("infrared") || n.contains("ir camera")
}

/// "USB2.0 HD UVC WebCam: USB2.0 HD" → "USB2.0 HD UVC WebCam".
fn short_name(name: &str) -> String {
    let base = name.split(':').next().unwrap_or(name).trim();
    if is_ir(name) { format!("{base} (infrared)") } else { base.to_string() }
}

// ── capturing ────────────────────────────────────────────────────────────

/// The newest frame, shared with the thread reading them.
#[derive(Default)]
struct Latest {
    data: Vec<u8>,
    w: u32,
    h: u32,
    seq: u64,
    /// The window hasn't taken the last one yet: don't ask it again.
    waiting: bool,
}

struct Capture {
    child: Child,
    stdin: Option<ChildStdin>,
    /// Ended on purpose: not a failure to report.
    stopping: Arc<AtomicBool>,
    recording: Option<PathBuf>,
}

/// The size of the raw frames ffmpeg will send, from what it says about its
/// first output: "Stream #0:0: Video: rawvideo (RGB[24] …), rgb24, 1280x720".
fn frame_size(line: &str) -> Option<(u32, u32)> {
    if !line.contains("Video: rawvideo") {
        return None;
    }
    line.split(|c: char| c == ',' || c == ' ').find_map(|tok| {
        let (w, h) = tok.split_once('x')?;
        let (w, h) = (w.parse().ok()?, h.parse().ok()?);
        (w >= 16 && h >= 16).then_some((w, h))
    })
}

/// What ffmpeg's complaint means for someone holding the laptop.
fn explain(err: &str) -> String {
    let e = err.to_lowercase();
    if e.contains("busy") {
        "Another app is using the camera.".into()
    } else if e.contains("permission denied") {
        "Not allowed to use the camera — is your user in the video group?".into()
    } else if e.contains("no such file") || e.contains("no such device") {
        "The camera isn't there any more.".into()
    } else if e.contains("unknown encoder") {
        "ffmpeg here can't encode H.264 (libx264).".into()
    } else if err.trim().is_empty() {
        "The camera stopped.".into()
    } else {
        format!("The camera stopped: {}", err.trim())
    }
}

fn die_with_parent(cmd: &mut Command) {
    // SAFETY: prctl is async-signal-safe; nothing else runs between fork
    // and exec here.
    unsafe {
        cmd.pre_exec(|| {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
            Ok(())
        });
    }
}

thread_local! {
    static APP: RefCell<Option<Shared>> = const { RefCell::new(None) };
}

fn with_app(f: impl FnOnce(&Shared)) {
    let app = APP.with(|a| a.borrow().clone());
    if let Some(app) = app {
        f(&app);
    }
}

// ── the app ──────────────────────────────────────────────────────────────

#[derive(serde::Serialize, serde::Deserialize)]
struct Settings {
    #[serde(default)]
    camera: String,
    #[serde(default = "yes")]
    mirror: bool,
    #[serde(default = "yes")]
    sound: bool,
    #[serde(default)]
    timer: i32,
    #[serde(default)]
    mode: i32,
}

fn yes() -> bool {
    true
}

impl Default for Settings {
    fn default() -> Self {
        Settings { camera: String::new(), mirror: true, sound: true, timer: 0, mode: 0 }
    }
}

fn settings_file() -> PathBuf {
    kit::config_dir().join("hyprshell-camera/settings.json")
}

struct App {
    ui: slint::Weak<AppWindow>,
    cameras: Vec<Camera>,
    camera: usize,
    /// Which of the camera's input arguments is being tried.
    attempt: usize,
    capture: Option<Capture>,
    latest: Arc<Mutex<Latest>>,
    /// A frame came: the inputs work.
    got_frame: Arc<AtomicBool>,
    record_started: Option<Instant>,
    /// Recording with sound didn't start: try once without.
    sound_failed: bool,
    last_saved: Option<PathBuf>,
    countdown: Option<slint::Timer>,
    toast_seq: u64,
}

type Shared = Rc<RefCell<App>>;

fn user_dir(kind: &str, fallback: &str) -> PathBuf {
    let out = Command::new("xdg-user-dir").arg(kind).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    match out {
        Some(p) if !p.is_empty() && PathBuf::from(&p) != kit::home() => PathBuf::from(p),
        _ => kit::home().join(fallback),
    }
}

fn stamp() -> String {
    // kit::local's last field is the weekday; the seconds are the epoch's.
    let now = kit::now();
    let (y, mo, d, h, mi, _) = kit::local(now);
    format!("{y:04}-{mo:02}-{d:02} {h:02}.{mi:02}.{:02}", now.rem_euclid(60))
}

/// `base`, or `base 2`, … — whichever isn't taken.
fn free_name(dir: &Path, base: &str, ext: &str) -> PathBuf {
    let mut p = dir.join(format!("{base}.{ext}"));
    let mut n = 1;
    while p.exists() {
        n += 1;
        p = dir.join(format!("{base} {n}.{ext}"));
    }
    p
}

impl App {
    fn ui(&self) -> Option<AppWindow> {
        self.ui.upgrade()
    }

    fn save_settings(&self) {
        let Some(ui) = self.ui() else { return };
        let c = ui.global::<Cam>();
        let s = Settings {
            camera: self.cameras.get(self.camera).map(|c| c.name.clone()).unwrap_or_default(),
            mirror: c.get_mirror(),
            sound: c.get_sound(),
            timer: c.get_timer(),
            mode: c.get_mode(),
        };
        let _ = std::fs::create_dir_all(settings_file().parent().unwrap());
        if let Ok(j) = serde_json::to_string_pretty(&s) {
            let _ = kit::write_atomic(&settings_file(), j.as_bytes());
        }
    }

    fn toast(app: &Shared, text: &str) {
        let seq = {
            let mut a = app.borrow_mut();
            a.toast_seq += 1;
            a.toast_seq
        };
        if let Some(ui) = app.borrow().ui() {
            ui.global::<Cam>().set_toast(text.into());
        }
        let app = app.clone();
        slint::Timer::single_shot(Duration::from_millis(3000), move || {
            if app.borrow().toast_seq == seq {
                if let Some(ui) = app.borrow().ui() {
                    ui.global::<Cam>().set_toast("".into());
                }
            }
        });
    }

    /// Stop ffmpeg: a recording is asked to finish its file (q), and waited
    /// for a moment; just showing, it's simply ended.
    fn stop(&mut self) {
        let Some(mut cap) = self.capture.take() else { return };
        cap.stopping.store(true, Ordering::SeqCst);
        if cap.recording.is_some() {
            if let Some(mut stdin) = cap.stdin.take() {
                let _ = stdin.write_all(b"q");
            }
            let until = Instant::now() + Duration::from_secs(5);
            while Instant::now() < until {
                if let Ok(Some(_)) = cap.child.try_wait() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        let _ = cap.child.kill();
        let _ = cap.child.wait();
    }
}

/// Start ffmpeg on the chosen camera: showing, and recording into `record`.
fn start(app: &Shared, record: Option<PathBuf>) {
    let (args, sound) = {
        let mut a = app.borrow_mut();
        a.stop();
        let Some(cam) = a.cameras.get(a.camera) else {
            if let Some(ui) = a.ui() {
                let c = ui.global::<Cam>();
                c.set_live(false);
                c.set_state("No camera found.".into());
            }
            return;
        };
        let input = cam.inputs[a.attempt.min(cam.inputs.len() - 1)].clone();
        let sound = record.is_some() && !a.sound_failed && a.ui().is_some_and(|ui| ui.global::<Cam>().get_sound());
        let mut args = strings(&["-hide_banner", "-nostdin", "-loglevel", "info", "-thread_queue_size", "64"]);
        // -nostdin, except while recording: then q on stdin ends it cleanly.
        if record.is_some() {
            args.retain(|a| a != "-nostdin");
        }
        args.extend(input);
        if sound {
            args.extend(strings(&["-thread_queue_size", "64", "-f", "pulse", "-i", "default"]));
        }
        args.extend(strings(&["-map", "0:v", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"]));
        if let Some(path) = &record {
            args.extend(strings(&["-map", "0:v"]));
            if sound {
                args.extend(strings(&["-map", "1:a", "-c:a", "aac", "-b:a", "128k"]));
            }
            args.extend(strings(&["-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-y"]));
            args.push(path.display().to_string());
        }
        (args, sound)
    };

    let mut cmd = Command::new("ffmpeg");
    cmd.args(&args).stdin(if record.is_some() { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped());
    die_with_parent(&mut cmd);
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            if let Some(ui) = app.borrow().ui() {
                let c = ui.global::<Cam>();
                c.set_live(false);
                c.set_state(if e.kind() == std::io::ErrorKind::NotFound { "Camera needs ffmpeg — sudo pacman -S --needed ffmpeg".into() } else { e.to_string().into() });
            }
            return;
        }
    };
    let stopping = Arc::new(AtomicBool::new(false));
    let (latest, got_frame, weak) = {
        let a = app.borrow();
        (a.latest.clone(), a.got_frame.clone(), a.ui.clone())
    };
    got_frame.store(false, Ordering::SeqCst);

    // What it says: the frames' size, and its last complaint.
    let (size_tx, size_rx) = std::sync::mpsc::channel::<(u32, u32)>();
    let last_err = Arc::new(Mutex::new(String::new()));
    if let Some(err) = child.stderr.take() {
        let last_err = last_err.clone();
        std::thread::spawn(move || {
            let mut sent = false;
            for line in std::io::BufReader::new(err).lines().map_while(Result::ok) {
                if !sent {
                    if let Some(s) = frame_size(&line) {
                        let _ = size_tx.send(s);
                        sent = true;
                        continue;
                    }
                }
                let l = line.trim();
                if !l.is_empty() && !l.starts_with("Stream") && !l.starts_with("Input") && !l.starts_with("Output") && !l.starts_with(' ') && !l.contains("Press [q]") {
                    *last_err.lock().unwrap() = l.to_string();
                }
            }
        });
    }
    if let Some(mut out) = child.stdout.take() {
        let stopping = stopping.clone();
        let recording = record.is_some();
        std::thread::spawn(move || {
            let size = size_rx.recv_timeout(Duration::from_secs(15)).ok();
            if let Some((w, h)) = size {
                let mut buf = vec![0u8; (w * h * 3) as usize];
                while out.read_exact(&mut buf).is_ok() {
                    got_frame.store(true, Ordering::SeqCst);
                    let ask = {
                        let mut l = latest.lock().unwrap();
                        std::mem::swap(&mut l.data, &mut buf);
                        if buf.len() != (w * h * 3) as usize {
                            buf = vec![0u8; (w * h * 3) as usize];
                        }
                        l.w = w;
                        l.h = h;
                        l.seq += 1;
                        !std::mem::replace(&mut l.waiting, true)
                    };
                    if ask {
                        let weak = weak.clone();
                        let latest = latest.clone();
                        let _ = slint::invoke_from_event_loop(move || show_frame(&weak, &latest));
                    }
                }
            }
            // Ended: on purpose, or not.
            if stopping.load(Ordering::SeqCst) {
                return;
            }
            let err = last_err.lock().unwrap().clone();
            let _ = slint::invoke_from_event_loop(move || with_app(|app| ended(app, &err, recording)));
        });
    }

    let _ = sound;
    let mut a = app.borrow_mut();
    let stdin = child.stdin.take();
    a.capture = Some(Capture { child, stdin, stopping, recording: record.clone() });
    a.record_started = record.as_ref().map(|_| Instant::now());
    if let Some(ui) = a.ui() {
        let c = ui.global::<Cam>();
        c.set_recording(record.is_some());
        c.set_elapsed("0:00".into());
        c.set_state("".into());
    }
}

/// The newest frame into the window, mirrored if asked.
fn show_frame(weak: &slint::Weak<AppWindow>, latest: &Arc<Mutex<Latest>>) {
    let Some(ui) = weak.upgrade() else { return };
    let c = ui.global::<Cam>();
    let mirror = c.get_mirror();
    let px = {
        let mut l = latest.lock().unwrap();
        l.waiting = false;
        if l.w == 0 {
            return;
        }
        let (w, h) = (l.w, l.h);
        let mut px = SharedPixelBuffer::<Rgb8Pixel>::new(w, h);
        let dst = px.make_mut_bytes();
        if mirror {
            let row = (w * 3) as usize;
            for y in 0..h as usize {
                let src = &l.data[y * row..(y + 1) * row];
                let out = &mut dst[y * row..(y + 1) * row];
                for x in 0..w as usize {
                    let s = (w as usize - 1 - x) * 3;
                    out[x * 3..x * 3 + 3].copy_from_slice(&src[s..s + 3]);
                }
            }
        } else {
            dst.copy_from_slice(&l.data);
        }
        px
    };
    c.set_frame(Image::from_rgb8(px));
    if !c.get_live() {
        c.set_live(true);
    }
}

/// ffmpeg ended by itself.
fn ended(app: &Shared, err: &str, recording: bool) {
    let (got, more, sound_tried) = {
        let mut a = app.borrow_mut();
        if let Some(mut cap) = a.capture.take() {
            let _ = cap.child.wait();
        }
        let got = a.got_frame.load(Ordering::SeqCst);
        let more = a.cameras.get(a.camera).is_some_and(|c| a.attempt + 1 < c.inputs.len());
        let sound_tried = recording && !a.sound_failed && a.ui().is_some_and(|ui| ui.global::<Cam>().get_sound());
        (got, more, sound_tried)
    };
    if recording {
        let path = app.borrow().last_saved.clone();
        if !got && sound_tried {
            // Perhaps the microphone: once more without it.
            app.borrow_mut().sound_failed = true;
            App::toast(app, "Recording without sound — the microphone couldn't be opened");
            start(app, path);
            return;
        }
        App::toast(app, &explain(err));
        start(app, None);
        return;
    }
    if !got && more {
        app.borrow_mut().attempt += 1;
        start(app, None);
        return;
    }
    if let Some(ui) = app.borrow().ui() {
        let c = ui.global::<Cam>();
        c.set_live(false);
        c.set_recording(false);
        c.set_state(explain(err).into());
    }
}

/// The frame on screen, as it came (not mirrored), saved as a photo.
fn take_photo(app: &Shared) {
    let (data, w, h) = {
        let a = app.borrow();
        let l = a.latest.lock().unwrap();
        (l.data.clone(), l.w, l.h)
    };
    if w == 0 {
        return;
    }
    if let Some(ui) = app.borrow().ui() {
        let c = ui.global::<Cam>();
        c.set_flash(c.get_flash() + 1);
        let mut px = SharedPixelBuffer::<Rgb8Pixel>::new(w, h);
        px.make_mut_bytes().copy_from_slice(&data);
        c.set_last(Image::from_rgb8(px));
        c.set_has_last(true);
    }
    let dir = user_dir("PICTURES", "Pictures").join("Camera");
    let app = app.clone();
    kit::spawn(
        move || -> Result<PathBuf, String> {
            std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            let path = free_name(&dir, &format!("Photo {}", stamp()), "jpg");
            let mut cmd = Command::new("ffmpeg");
            cmd.args(["-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", &format!("{w}x{h}"), "-i", "pipe:0", "-frames:v", "1", "-q:v", "2", "-y"])
                .arg(&path)
                .stdin(Stdio::piped())
                .stdout(Stdio::null())
                .stderr(Stdio::piped());
            let mut child = cmd.spawn().map_err(|e| e.to_string())?;
            child.stdin.take().map(|mut s| s.write_all(&data)).transpose().map_err(|e| e.to_string())?;
            let out = child.wait_with_output().map_err(|e| e.to_string())?;
            if out.status.success() {
                Ok(path)
            } else {
                Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
            }
        },
        move |r| match r {
            Ok(p) => app.borrow_mut().last_saved = Some(p),
            Err(e) => App::toast(&app, &format!("Couldn't save the photo: {e}")),
        },
    );
}

fn shutter(app: &Shared) {
    let Some(ui) = app.borrow().ui() else { return };
    let c = ui.global::<Cam>();
    if c.get_mode() == 1 {
        let recording = app.borrow().capture.as_ref().is_some_and(|c| c.recording.is_some());
        if recording {
            // Finish the file, then show again.
            app.borrow_mut().stop();
            c.set_recording(false);
            let saved = app.borrow().last_saved.clone();
            start(app, None);
            if let Some(p) = saved {
                App::toast(app, &format!("Saved {}", p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()));
            }
        } else {
            let dir = user_dir("VIDEOS", "Videos").join("Camera");
            if let Err(e) = std::fs::create_dir_all(&dir) {
                App::toast(app, &format!("Couldn't make {}: {e}", dir.display()));
                return;
            }
            let path = free_name(&dir, &format!("Video {}", stamp()), "mp4");
            // The first frame stands for it until the next.
            {
                let a = app.borrow();
                let l = a.latest.lock().unwrap();
                if l.w > 0 {
                    let mut px = SharedPixelBuffer::<Rgb8Pixel>::new(l.w, l.h);
                    px.make_mut_bytes().copy_from_slice(&l.data);
                    c.set_last(Image::from_rgb8(px));
                    c.set_has_last(true);
                }
            }
            {
                let mut a = app.borrow_mut();
                a.last_saved = Some(path.clone());
                a.sound_failed = false;
            }
            start(app, Some(path));
        }
        return;
    }
    let secs = c.get_timer();
    if secs <= 0 {
        take_photo(app);
        return;
    }
    if app.borrow().countdown.is_some() {
        return;
    }
    c.set_countdown(secs);
    let timer = slint::Timer::default();
    let a2 = app.clone();
    timer.start(slint::TimerMode::Repeated, Duration::from_secs(1), move || {
        let Some(ui) = a2.borrow().ui() else { return };
        let c = ui.global::<Cam>();
        let left = c.get_countdown() - 1;
        c.set_countdown(left.max(0));
        if left <= 0 {
            a2.borrow_mut().countdown = None;
            take_photo(&a2);
        }
    });
    app.borrow_mut().countdown = Some(timer);
}

fn open(path: &Path) {
    let mut cmd = Command::new("xdg-open");
    cmd.arg(path).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    if let Ok(mut c) = cmd.spawn() {
        std::thread::spawn(move || {
            let _ = c.wait();
        });
    }
}

fn main() {
    kit::init("hyprshell-camera");
    let settings: Settings = std::fs::read_to_string(settings_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();

    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-camera");
    let cams = cameras();
    let c = ui.global::<Cam>();
    c.set_cameras(ModelRc::new(VecModel::from(cams.iter().map(|c| SharedString::from(c.name.as_str())).collect::<Vec<_>>())));
    let chosen = cams.iter().position(|c| c.name == settings.camera).unwrap_or(0);
    c.set_camera(chosen as i32);
    c.set_mirror(settings.mirror);
    c.set_sound(settings.sound);
    c.set_timer(if [0, 3, 10].contains(&settings.timer) { settings.timer } else { 0 });
    c.set_mode(settings.mode.clamp(0, 1));

    let app: Shared = Rc::new(RefCell::new(App {
        ui: ui.as_weak(),
        cameras: cams,
        camera: chosen,
        attempt: 0,
        capture: None,
        latest: Arc::new(Mutex::new(Latest::default())),
        got_frame: Arc::new(AtomicBool::new(false)),
        record_started: None,
        sound_failed: false,
        last_saved: None,
        countdown: None,
        toast_seq: 0,
    }));
    APP.with(|a| *a.borrow_mut() = Some(app.clone()));

    {
        let app = app.clone();
        c.on_shutter(move || shutter(&app));
    }
    {
        let app = app.clone();
        c.on_pick_camera(move |i| {
            {
                let mut a = app.borrow_mut();
                if a.capture.as_ref().is_some_and(|c| c.recording.is_some()) {
                    return;
                }
                a.camera = i.max(0) as usize;
                a.attempt = 0;
                a.save_settings();
                if let Some(ui) = a.ui() {
                    ui.global::<Cam>().set_live(false);
                }
            }
            start(&app, None);
        });
    }
    {
        let app = app.clone();
        c.on_open_last(move || {
            if let Some(p) = app.borrow().last_saved.clone() {
                open(&p);
            }
        });
    }
    c.on_open_folder(|| {
        let ui_mode_video = APP.with(|a| a.borrow().as_ref().and_then(|a| a.borrow().ui()).map(|ui| ui.global::<Cam>().get_mode() == 1)).unwrap_or(false);
        let dir = if ui_mode_video { user_dir("VIDEOS", "Videos") } else { user_dir("PICTURES", "Pictures") }.join("Camera");
        let _ = std::fs::create_dir_all(&dir);
        open(&dir);
    });
    {
        let app = app.clone();
        c.on_settings_changed(move || app.borrow().save_settings());
    }

    // The recording's length.
    let clock = slint::Timer::default();
    {
        let app = app.clone();
        clock.start(slint::TimerMode::Repeated, Duration::from_millis(500), move || {
            let a = app.borrow();
            let (Some(t), Some(ui)) = (a.record_started, a.ui()) else { return };
            let s = t.elapsed().as_secs();
            ui.global::<Cam>().set_elapsed(format!("{}:{:02}", s / 60, s % 60).into());
        });
    }

    start(&app, None);
    ui.run().expect("run");
    // A recording is finished properly before going.
    app.borrow_mut().stop();
    app.borrow().save_settings();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_frame_size() {
        assert_eq!(frame_size("  Stream #0:0: Video: rawvideo (RGB[24] / 0x18424752), rgb24(pc, gbr/unknown/unknown, progressive), 1280x720, q=2-31, 663552 kb/s, 30 fps"), Some((1280, 720)));
        assert_eq!(frame_size("  Stream #0:0: Video: mjpeg (Baseline), yuvj422p(pc), 1280x720"), None);
    }

    #[test]
    fn names() {
        assert_eq!(short_name("USB2.0 HD UVC WebCam: USB2.0 HD"), "USB2.0 HD UVC WebCam");
        assert_eq!(short_name("USB2.0 HD UVC WebCam: USB2.0 IR"), "USB2.0 HD UVC WebCam (infrared)");
    }
}
