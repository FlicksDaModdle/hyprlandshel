//! hyprshell-faced: face unlock as a service.
//!
//! Started at boot (hyprshell-faced.service), it loads the two face models
//! once and keeps them, so recognising you starts at the camera, not at
//! loading Python and a model from disk as Howdy does each time. The
//! cameras are opened only while a request needs them.
//!
//! One request a line on /run/hyprshell-face/socket, JSON, answered with
//! one line. Who's asking comes from the socket itself (SO_PEERCRED):
//!
//!   verify {user}            is USER at the camera? Asked by the PAM
//!                            module, as USER (the lock screen) or as root
//!                            (greetd, sudo): nobody else may ask
//!   enrol {user,label,stills}  add a look: root only, which is Settings'
//!                            password-checked helper, never a program
//!                            that just happens to run as you
//!   list / remove / clear {user}  your own, or anyone's for root
//!   status                   anyone
//!
//! Requests that use a camera take turns.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{json, Value};

use hyprshell_faced::camera::{Camera, Want};
use hyprshell_faced::image::Rgb;
use hyprshell_faced::models::{self, Detector, Recognizer};
use hyprshell_faced::store::{self, Config, Faces, Look};

const SOCKET_DIR: &str = "/run/hyprshell-face";

struct Engine {
    ir: Detector,
    webcam: Detector,
    recognizer: Recognizer,
}

impl Engine {
    fn load(config: &Config) -> Result<Engine, String> {
        let t = Instant::now();
        let load = |name: &str| config.models.join(name);
        let mut ir = Detector::load(&load("yunet.onnx")).map_err(|e| format!("YuNet: {e}"))?;
        let mut webcam = Detector::load(&load("yunet.onnx")).map_err(|e| format!("YuNet: {e}"))?;
        let recognizer = Recognizer::load(&load("sface.onnx")).map_err(|e| format!("SFace: {e}"))?;
        // The plans for the usual shapes, made now rather than at the
        // first unlock: 16:9 (the infrared camera) and 4:3 (webcams).
        let blank = |w: usize, h: usize| Rgb { w, h, px: vec![0; w * h * 3] };
        let _ = ir.detect(&blank(640, 360));
        let _ = ir.detect(&blank(640, 480));
        let _ = webcam.detect(&blank(640, 480));
        let face = models::Face { x: 0.0, y: 0.0, w: 10.0, h: 10.0, points: [[38.0, 52.0], [74.0, 52.0], [56.0, 72.0], [42.0, 92.0], [71.0, 92.0]], score: 1.0 };
        let _ = recognizer.describe(&Rgb { w: 112, h: 112, px: vec![0; 112 * 112 * 3] }, &face);
        eprintln!("hyprshell-faced: models ready in {:?}", t.elapsed());
        Ok(Engine { ir, webcam, recognizer })
    }
}

fn main() {
    let config = Config::load();
    let engine = match Engine::load(&config) {
        Ok(e) => Some(e),
        Err(e) => {
            // Still answers, with "unavailable": Howdy takes over.
            eprintln!("hyprshell-faced: no models ({e}); every request is answered \"unavailable\"");
            None
        }
    };
    let engine = Arc::new(Mutex::new(engine));

    let _ = std::fs::create_dir_all(SOCKET_DIR);
    let path = format!("{SOCKET_DIR}/socket");
    let _ = std::fs::remove_file(&path);
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("hyprshell-faced: can't listen on {path}: {e}");
            std::process::exit(1);
        }
    };
    // Anyone may connect; what each may ask is checked per request.
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666));
    eprintln!("hyprshell-faced: listening on {path}");
    // Ready, with the models loaded and the socket there (Type=notify):
    // the login screen, ordered after this, can ask at once.
    notify_ready();

    for stream in listener.incoming().flatten() {
        let engine = engine.clone();
        std::thread::spawn(move || {
            if let Err(e) = serve(stream, &engine) {
                eprintln!("hyprshell-faced: {e}");
            }
        });
    }
}

/// sd_notify(READY=1), without libsystemd: a datagram to $NOTIFY_SOCKET.
fn notify_ready() {
    use std::os::linux::net::SocketAddrExt;
    use std::os::unix::net::{SocketAddr, UnixDatagram};
    let Some(target) = std::env::var_os("NOTIFY_SOCKET") else { return };
    let target = target.to_string_lossy().into_owned();
    let Ok(socket) = UnixDatagram::unbound() else { return };
    let addr = match target.strip_prefix('@') {
        Some(name) => SocketAddr::from_abstract_name(name.as_bytes()),
        None => SocketAddr::from_pathname(&target),
    };
    if let Ok(addr) = addr {
        let _ = socket.send_to_addr(b"READY=1", &addr);
    }
}

fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: reading SO_PEERCRED into a ucred of the right size.
    let r = unsafe {
        libc::getsockopt(stream.as_raw_fd(), libc::SOL_SOCKET, libc::SO_PEERCRED, &mut cred as *mut _ as *mut libc::c_void, &mut len)
    };
    (r == 0).then_some(cred.uid)
}

fn uid_of(user: &str) -> Option<u32> {
    let name = std::ffi::CString::new(user).ok()?;
    // SAFETY: getpwnam's result is read at once, before any other call.
    let pw = unsafe { libc::getpwnam(name.as_ptr()) };
    (!pw.is_null()).then(|| unsafe { (*pw).pw_uid })
}

fn name_of(uid: u32) -> Option<String> {
    // SAFETY: as above.
    let pw = unsafe { libc::getpwuid(uid) };
    if pw.is_null() {
        return None;
    }
    Some(unsafe { std::ffi::CStr::from_ptr((*pw).pw_name) }.to_string_lossy().into_owned())
}

fn serve(stream: UnixStream, engine: &Mutex<Option<Engine>>) -> std::io::Result<()> {
    let uid = peer_uid(&stream).ok_or_else(|| std::io::Error::other("no peer credentials"))?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    // A request is small; a line is enough (stills are a few hundred kB).
    reader.by_ref().take(16 << 20).read_line(&mut line)?;
    let reply = match serde_json::from_str::<Value>(&line) {
        Ok(request) => {
            // Asked for (the PAM module, for the lock and login screens):
            // what it sees while it looks, a line each, before the answer.
            let wanted = request["hints"].as_bool() == Some(true);
            let hints = Hints { out: Mutex::new(if wanted { stream.try_clone().ok().map(|s| (s, String::new())) } else { None }) };
            handle(&request, uid, engine, &hints)
        }
        Err(_) => json!({ "result": "error", "message": "not a request" }),
    };
    let mut out = stream;
    out.write_all(format!("{reply}\n").as_bytes())
}

/// Hints while it looks: `{"hint": "Come a little closer"}`, a line each,
/// only when it changes; an empty one when there's nothing to say.
struct Hints {
    out: Mutex<Option<(UnixStream, String)>>,
}

impl Hints {
    fn say(&self, text: &str) {
        let mut out = self.out.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((stream, last)) = out.as_mut() {
            if last != text {
                *last = text.to_string();
                let _ = stream.write_all(format!("{}\n", json!({ "hint": text })).as_bytes());
            }
        }
    }
}

/// What to tell you, for what the camera sees.
fn hint_text(kind: &str) -> &'static str {
    match kind {
        "dark" => "It's too dark to see you. Is something covering the camera?",
        "none" => "Your face isn't in view of the camera",
        "far" => "Come a little closer",
        "near" => "Move back a little",
        "edge" => "Move your face to the middle of the camera's view",
        "turned" => "Turn to face the screen",
        "attention" => "Look straight at the screen",
        _ => "",
    }
}

fn unavailable(message: &str) -> Value {
    json!({ "result": "unavailable", "message": message })
}

fn handle(request: &Value, uid: u32, engine: &Mutex<Option<Engine>>, hints: &Hints) -> Value {
    let op = request["op"].as_str().unwrap_or("");
    // Whose faces: the one named, else the asker's own.
    let user = match request["user"].as_str() {
        Some(u) => u.to_string(),
        None => name_of(uid).unwrap_or_default(),
    };
    if op != "status" {
        if !store::plain_user(&user) {
            return json!({ "result": "error", "message": "not a user name" });
        }
        // Only yourself, unless you're root.
        if uid != 0 && uid_of(&user) != Some(uid) {
            return json!({ "result": "denied", "message": "only your own face" });
        }
    }
    let config = Config::load();
    match op {
        "status" => {
            let ready = engine.lock().map(|e| e.is_some()).unwrap_or(false);
            // Rounded: f32 settings come out as 0.44999998 otherwise.
            let r = |v: f32| (v as f64 * 100.0).round() / 100.0;
            json!({ "result": "ok", "models": ready, "ir_device": config.ir_device, "webcam_device": config.webcam_device,
                    "webcam_check": config.webcam_check, "threshold": r(config.threshold), "webcam_threshold": r(config.webcam_threshold),
                    "timeout": r(config.timeout), "min_light": r(config.min_light), "dark_frame": r(config.dark_frame),
                    "confirm_frames": config.confirm_frames, "require_facing": config.require_facing,
                    "require_attention": config.require_attention,
                    "lockout_after": config.lockout_after, "lockout_minutes": config.lockout_minutes })
        }
        "list" => {
            let faces = Faces::load(&user);
            let looks: Vec<Value> = faces.looks.iter().map(|l| json!({ "id": l.id, "label": l.label, "time": l.time,
                "ir": l.ir.len(), "webcam": l.webcam.len() })).collect();
            json!({ "result": "ok", "looks": looks })
        }
        "remove" => {
            let Some(id) = request["id"].as_u64() else { return json!({ "result": "error", "message": "no id" }) };
            let mut faces = Faces::load(&user);
            let before = faces.looks.len();
            faces.looks.retain(|l| u64::from(l.id) != id);
            if faces.looks.len() == before {
                return json!({ "result": "error", "message": "no such look" });
            }
            saved(faces.save(&user))
        }
        "clear" => saved(Faces::default().save(&user)),
        "enrol" => {
            if uid != 0 {
                return json!({ "result": "denied", "message": "adding a face needs your password (Settings asks for it)" });
            }
            let mut guard = engine.lock().unwrap_or_else(|e| e.into_inner());
            let Some(engine) = guard.as_mut() else { return unavailable("the face models aren't installed") };
            enrol(engine, &config, &user, request)
        }
        "verify" => {
            if store::lid_closed() {
                return unavailable("the lid is closed");
            }
            let faces = Faces::load(&user);
            if faces.looks.is_empty() {
                return unavailable("no face of yours is added here yet");
            }
            if config.lockout_after > 0 {
                let mut list = strangers().lock().unwrap_or_else(|e| e.into_inner());
                if let Some(&(n, last)) = list.get(&user) {
                    let window = Duration::from_secs(u64::from(config.lockout_minutes) * 60);
                    if last.elapsed() >= window {
                        list.remove(&user);
                    } else if n >= config.lockout_after {
                        let left = (window - last.elapsed()).as_secs().div_ceil(60);
                        return json!({ "result": "nomatch", "message": format!("too many faces that weren't yours: the password, for {left} more min") });
                    }
                }
            }
            let mut guard = engine.lock().unwrap_or_else(|e| e.into_inner());
            let Some(engine) = guard.as_mut() else { return unavailable("the face models aren't installed") };
            let t = Instant::now();
            let reply = verify(engine, &config, &faces, hints);
            {
                let mut list = strangers().lock().unwrap_or_else(|e| e.into_inner());
                if reply["result"] == "match" {
                    list.remove(&user);
                } else if reply["stranger"] == true {
                    let entry = list.entry(user.clone()).or_insert((0, Instant::now()));
                    *entry = (entry.0 + 1, Instant::now());
                    eprintln!("hyprshell-faced: {user}: a face that wasn't theirs ({} in a row)", entry.0);
                }
            }
            eprintln!("hyprshell-faced: {user}: {} in {} ms ({})", reply["result"].as_str().unwrap_or("?"), t.elapsed().as_millis(),
                      reply["message"].as_str().unwrap_or(""));
            let mut reply = reply;
            reply["ms"] = json!(t.elapsed().as_millis() as u64);
            reply
        }
        _ => json!({ "result": "error", "message": "unknown request" }),
    }
}

fn saved(r: std::io::Result<()>) -> Value {
    match r {
        Ok(()) => json!({ "result": "ok" }),
        Err(e) => json!({ "result": "error", "message": e.to_string() }),
    }
}

/// The face in a picture, if there's exactly one sure face.
fn one_face(det: &mut Detector, rec: &Recognizer, picture: &Rgb, score: f32) -> Option<Vec<f32>> {
    found_face(det, rec, picture, score).map(|(_, v)| v)
}

/// The biggest face, so one in the background doesn't decide, and its
/// 128 numbers.
fn found_face(det: &mut Detector, rec: &Recognizer, picture: &Rgb, score: f32) -> Option<(models::Face, Vec<f32>)> {
    det.threshold = score;
    let faces = det.detect(picture).ok()?;
    let face = faces.into_iter().next()?;
    let v = rec.describe(picture, &face).ok()?;
    Some((face, v))
}

/// Facing the camera: the nose about halfway along the line between the
/// eyes, not off towards one of them (a head turned away). Measured along
/// that line, so a tilted head (lying down, say) still counts. From the
/// five points: no extra model, nothing to slow it.
fn facing(face: &models::Face) -> bool {
    let [right_eye, left_eye, nose, _, _] = face.points;
    let (ex, ey) = (left_eye[0] - right_eye[0], left_eye[1] - right_eye[1]);
    let span = ex * ex + ey * ey;
    if span < 1.0 {
        return false;
    }
    let along = ((nose[0] - right_eye[0]) * ex + (nose[1] - right_eye[1]) * ey) / span;
    (0.25..=0.75).contains(&along)
}

/// Looking at the screen, not just turned towards it: the head square on
/// to the camera both ways — the nose near the middle between the eyes,
/// and as far from them towards the mouth as it is when you look straight
/// ahead, not up past the screen or down at the keyboard. It's where the
/// head points; the face finder's five points don't say where the eyes do.
fn attentive(face: &models::Face) -> bool {
    let [right_eye, left_eye, nose, right_mouth, left_mouth] = face.points;
    let (ex, ey) = (left_eye[0] - right_eye[0], left_eye[1] - right_eye[1]);
    let span = ex * ex + ey * ey;
    if span < 1.0 {
        return false;
    }
    let along = ((nose[0] - right_eye[0]) * ex + (nose[1] - right_eye[1]) * ey) / span;
    let eyes = (right_eye[1] + left_eye[1]) / 2.0;
    let mouth = (right_mouth[1] + left_mouth[1]) / 2.0;
    if mouth - eyes < 1.0 {
        return false;
    }
    let down = (nose[1] - eyes) / (mouth - eyes);
    (0.36..=0.64).contains(&along) && (0.35..=0.78).contains(&down)
}

/// Where a face is in the picture, as something to tell you: too far, too
/// near, off the edge, or "" when it's fine.
fn placement(face: &models::Face, w: f32, h: f32) -> &'static str {
    if face.w > w * 0.55 || face.h > h * 0.8 {
        "near"
    } else if face.x < w * 0.02 || face.y < h * 0.02 || face.x + face.w > w * 0.98 || face.y + face.h > h * 0.98 {
        "edge"
    } else if face.w < w * 0.13 {
        "far"
    } else {
        ""
    }
}

/// Repeated strangers: after `lockout_after` faces that weren't yours in a
/// row, face unlock steps aside for `lockout_minutes`, and the password is
/// what's left. A face that is yours starts the count again. Not seeing
/// anyone doesn't count: walking away isn't an attempt.
fn strangers() -> &'static Mutex<std::collections::HashMap<String, (u32, Instant)>> {
    static STRANGERS: std::sync::OnceLock<Mutex<std::collections::HashMap<String, (u32, Instant)>>> = std::sync::OnceLock::new();
    STRANGERS.get_or_init(Default::default)
}

enum Webcam {
    Match(f32),
    NoMatch(f32),
    /// Too dark, can't be opened, in use: the infrared camera decides.
    Aside(String),
}

/// The webcam's half: until it knows you, the time is up, or it's told
/// to stop.
fn watch_webcam(det: &mut Detector, rec: &Recognizer, config: &Config, known: &[Vec<f32>], deadline: Instant, stop: &AtomicBool) -> Webcam {
    let mut camera = match Camera::open(&config.webcam_device, &Want { mjpeg: Some((640, 480)) }) {
        Ok(c) => c,
        Err(e) => return Webcam::Aside(format!("webcam: {e}")),
    };
    let (mut frames, mut brightest, mut best) = (0, 0.0f32, -1.0f32);
    while Instant::now() < deadline && !stop.load(Ordering::Relaxed) {
        let Ok(Some(picture)) = camera.frame(Duration::from_millis(200)) else { continue };
        frames += 1;
        // While it finds its exposure.
        if frames <= 3 {
            continue;
        }
        let light = picture.light();
        brightest = brightest.max(light);
        if light < config.min_light {
            if frames >= 10 && brightest < config.min_light {
                return Webcam::Aside(format!("too dark for the webcam ({brightest:.0})"));
            }
            continue;
        }
        if let Some(face) = one_face(det, rec, &picture, config.detect_score) {
            let s = models::best(&face, known);
            best = best.max(s);
            if s >= config.webcam_threshold {
                return Webcam::Match(s);
            }
        }
    }
    if brightest < config.min_light {
        Webcam::Aside(format!("too dark for the webcam ({brightest:.0})"))
    } else {
        Webcam::NoMatch(best)
    }
}

fn verify(engine: &mut Engine, config: &Config, faces: &Faces, hints: &Hints) -> Value {
    let ir_known = faces.ir();
    let web_known = faces.webcam();
    let use_webcam = config.webcam_check && !web_known.is_empty() && !config.webcam_device.is_empty() && config.webcam_device != config.ir_device;
    let deadline = Instant::now() + Duration::from_secs_f32(config.timeout);
    let stop = AtomicBool::new(false);
    let Engine { ir, webcam, recognizer } = engine;
    let recognizer = &*recognizer;

    std::thread::scope(|scope| {
        // The webcam alongside, not after.
        let web = use_webcam.then(|| scope.spawn(|| watch_webcam(webcam, recognizer, config, &web_known, deadline, &stop)));

        let mut camera = match open_patiently(&config.ir_device, &Want { mjpeg: None }, Duration::from_millis(1500)) {
            Ok(c) => c,
            Err(e) => {
                stop.store(true, Ordering::Relaxed);
                return unavailable(&format!("the infrared camera: {e}"));
            }
        };
        let mut best = -1.0f32;
        let mut ir_match = None;
        // Lit frames in a row that knew you: `confirm` of them, not one
        // lucky frame.
        let mut in_a_row = 0;
        let mut lowest = f32::MAX;
        let mut turned_away = false;
        let mut stranger = false;
        // What's wrong with the picture, if anything, and since when: said
        // once it has lasted a moment, so a frame or two doesn't flicker.
        let mut seen: (&str, Instant) = ("", Instant::now());
        let mut said = "";
        let mut note = |kind: &'static str| {
            if seen.0 != kind {
                seen = (kind, Instant::now());
            }
            let wait = match kind {
                "" => 0,
                "none" => 800,
                _ => 400,
            };
            if kind != said && seen.1.elapsed() >= Duration::from_millis(wait) {
                said = kind;
                hints.say(hint_text(kind));
            }
        };
        // The emitter flashes, so every other frame can be unlit: dark is
        // only dark when it lasts.
        let mut dark_since: Option<Instant> = None;
        while Instant::now() < deadline {
            let Ok(Some(picture)) = camera.frame(Duration::from_millis(200)) else { continue };
            if picture.light() < config.dark_frame {
                let since = *dark_since.get_or_insert_with(Instant::now);
                if since.elapsed() >= Duration::from_millis(900) {
                    note("dark");
                }
                continue;
            }
            dark_since = None;
            let Some((face, v)) = found_face(ir, recognizer, &picture, config.detect_score) else {
                note("none");
                continue;
            };
            if config.require_facing && !facing(&face) {
                turned_away = true;
                note("turned");
                continue;
            }
            if config.require_attention && !attentive(&face) {
                turned_away = true;
                note("attention");
                continue;
            }
            note(placement(&face, picture.w as f32, picture.h as f32));
            let s = models::best(&v, &ir_known);
            best = best.max(s);
            if s >= config.threshold {
                in_a_row += 1;
                lowest = lowest.min(s);
                if in_a_row >= config.confirm_frames {
                    ir_match = Some(lowest);
                    break;
                }
            } else {
                in_a_row = 0;
                lowest = f32::MAX;
                // Clearly someone else (strangers score near 0), not you
                // at a bad angle or in odd light (around 0.3).
                if s < (config.threshold - 0.15).min(0.2) {
                    stranger = true;
                }
            }
        }
        drop(camera);
        let Some(ir_score) = ir_match else {
            stop.store(true, Ordering::Relaxed);
            let why = if best < -0.5 && turned_away && config.require_attention { "you weren't looking at the screen".to_string() }
                      else if best < -0.5 && turned_away { "you weren't facing the camera".to_string() }
                      else if best < -0.5 { "no face seen".to_string() }
                      else { format!("not recognised (best {best:.2}, {:.2} needed)", config.threshold) };
            return json!({ "result": "nomatch", "message": why, "stranger": stranger });
        };
        match web.map(|h| h.join().unwrap_or(Webcam::Aside("webcam: failed".into()))) {
            None => json!({ "result": "match", "message": format!("infrared {ir_score:.2}") }),
            Some(Webcam::Match(w)) => json!({ "result": "match", "message": format!("infrared {ir_score:.2}, webcam {w:.2}") }),
            Some(Webcam::Aside(why)) => json!({ "result": "match", "message": format!("infrared {ir_score:.2}; {why}: infrared alone") }),
            Some(Webcam::NoMatch(w)) => json!({ "result": "nomatch", "stranger": true,
                "message": format!("infrared knew you ({ir_score:.2}), the webcam didn't (best {w:.2}, {:.2} needed)", config.webcam_threshold) }),
        }
    })
}

/// A camera, tried again for a moment if it's busy (Settings' picture, a
/// Howdy test letting go of it) or not there yet (just after boot or
/// resume, while the kernel brings it back).
fn open_patiently(device: &str, want: &Want, patience: Duration) -> std::io::Result<Camera> {
    let until = Instant::now() + patience;
    loop {
        match Camera::open(device, want) {
            Ok(c) => return Ok(c),
            Err(e) if Instant::now() < until
                && matches!(e.raw_os_error(), Some(libc::EBUSY) | Some(libc::ENOENT) | Some(libc::ENODEV) | Some(libc::EIO)) => {
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => return Err(e),
        }
    }
}

/// A new look: the infrared camera's faces of you over a few seconds,
/// and the webcam stills Settings took as you lined up, if any.
fn enrol(engine: &mut Engine, config: &Config, user: &str, request: &Value) -> Value {
    let label: String = request["label"].as_str().unwrap_or("Face").chars().filter(|c| !c.is_control()).take(40).collect();
    let Engine { ir, webcam, recognizer } = engine;

    let mut webcam_faces = Vec::new();
    for still in request["stills"].as_array().into_iter().flatten() {
        let Some(bytes) = still.as_str().and_then(|s| base64::engine::general_purpose::STANDARD.decode(s).ok()) else { continue };
        let Some(picture) = Rgb::from_jpeg(&bytes) else { continue };
        if picture.light() < config.min_light {
            continue;
        }
        if let Some(face) = one_face(webcam, recognizer, &picture, 0.9) {
            webcam_faces.push(face);
        }
    }

    let mut camera = match Camera::open(&config.ir_device, &Want { mjpeg: None }) {
        Ok(c) => c,
        Err(e) => return unavailable(&format!("the infrared camera: {e}")),
    };
    // Five sure faces, a little apart in time, in at most six seconds.
    let deadline = Instant::now() + Duration::from_secs(6);
    let mut ir_faces: Vec<Vec<f32>> = Vec::new();
    let mut last = Instant::now() - Duration::from_secs(1);
    while ir_faces.len() < 5 && Instant::now() < deadline {
        let Ok(Some(picture)) = camera.frame(Duration::from_millis(200)) else { continue };
        if picture.light() < config.dark_frame || last.elapsed() < Duration::from_millis(150) {
            continue;
        }
        if let Some(face) = one_face(ir, recognizer, &picture, 0.9) {
            ir_faces.push(face);
            last = Instant::now();
        }
    }
    drop(camera);
    if ir_faces.len() < 3 {
        return json!({ "result": "error", "message": "the infrared camera didn't see your face clearly enough: look straight at it, an arm's length away" });
    }

    let mut faces = Faces::load(user);
    let id = faces.next_id();
    let time = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let (n_ir, n_web) = (ir_faces.len(), webcam_faces.len());
    faces.looks.push(Look { id, label, time, ir: ir_faces, webcam: webcam_faces });
    match faces.save(user) {
        Ok(()) => json!({ "result": "ok", "id": id, "ir": n_ir, "webcam": n_web }),
        Err(e) => json!({ "result": "error", "message": e.to_string() }),
    }
}
