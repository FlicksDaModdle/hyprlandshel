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

    for stream in listener.incoming().flatten() {
        let engine = engine.clone();
        std::thread::spawn(move || {
            if let Err(e) = serve(stream, &engine) {
                eprintln!("hyprshell-faced: {e}");
            }
        });
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
        Ok(request) => handle(&request, uid, engine),
        Err(_) => json!({ "result": "error", "message": "not a request" }),
    };
    let mut out = stream;
    out.write_all(format!("{reply}\n").as_bytes())
}

fn unavailable(message: &str) -> Value {
    json!({ "result": "unavailable", "message": message })
}

fn handle(request: &Value, uid: u32, engine: &Mutex<Option<Engine>>) -> Value {
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
                    "timeout": r(config.timeout), "min_light": r(config.min_light), "dark_frame": r(config.dark_frame) })
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
            let mut guard = engine.lock().unwrap_or_else(|e| e.into_inner());
            let Some(engine) = guard.as_mut() else { return unavailable("the face models aren't installed") };
            let t = Instant::now();
            let reply = verify(engine, &config, &faces);
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
    det.threshold = score;
    let faces = det.detect(picture).ok()?;
    // The biggest, so a face in the background doesn't decide.
    let face = faces.first()?;
    rec.describe(picture, face).ok()
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

fn verify(engine: &mut Engine, config: &Config, faces: &Faces) -> Value {
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

        let mut camera = match Camera::open(&config.ir_device, &Want { mjpeg: None }) {
            Ok(c) => c,
            Err(e) => {
                stop.store(true, Ordering::Relaxed);
                return unavailable(&format!("the infrared camera: {e}"));
            }
        };
        let mut best = -1.0f32;
        let mut ir_match = None;
        while Instant::now() < deadline {
            let Ok(Some(picture)) = camera.frame(Duration::from_millis(200)) else { continue };
            if picture.light() < config.dark_frame {
                continue;
            }
            if let Some(face) = one_face(ir, recognizer, &picture, config.detect_score) {
                let s = models::best(&face, &ir_known);
                best = best.max(s);
                if s >= config.threshold {
                    ir_match = Some(s);
                    break;
                }
            }
        }
        drop(camera);
        let Some(ir_score) = ir_match else {
            stop.store(true, Ordering::Relaxed);
            return json!({ "result": "nomatch", "message": format!("not recognised (best {best:.2}, {:.2} needed)", config.threshold) });
        };
        match web.map(|h| h.join().unwrap_or(Webcam::Aside("webcam: failed".into()))) {
            None => json!({ "result": "match", "message": format!("infrared {ir_score:.2}") }),
            Some(Webcam::Match(w)) => json!({ "result": "match", "message": format!("infrared {ir_score:.2}, webcam {w:.2}") }),
            Some(Webcam::Aside(why)) => json!({ "result": "match", "message": format!("infrared {ir_score:.2}; {why}: infrared alone") }),
            Some(Webcam::NoMatch(w)) => json!({ "result": "nomatch",
                "message": format!("infrared knew you ({ir_score:.2}), the webcam didn't (best {w:.2}, {:.2} needed)", config.webcam_threshold) }),
        }
    })
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
