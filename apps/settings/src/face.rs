//! Settings → Login screen: face unlock with Howdy and Hyprshell's own face
//! service (services/FaceUnlock.qml).
//!
//! What is there is read without asking anyone for anything: Howdy and its
//! PAM module, the lock screen's face service (/etc/pam.d/hyprshell-lock),
//! greetd's PAM file, the cameras, the one Howdy is told to use and how many
//! faces are enrolled. What changes anything goes through
//! scripts/howdy-setup.sh under pkexec, which asks for your password: it
//! writes PAM files and Howdy's config, and enrols faces (always yours). The
//! password is asked once, by pkexec, for the helper (`--serve`); changes
//! after it go straight through until five minutes pass without one or it is
//! locked again.
//!
//! The webcam picture while a face is added comes from ffmpeg, as raw frames
//! on a pipe (nothing written to disk), and ends with this program.

use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};

#[derive(Clone, Default, Debug, PartialEq)]
pub struct Camera {
    pub path: String,
    pub name: String,
    pub ir: bool,
}

impl Camera {
    pub fn label(&self) -> String {
        format!("{}{} · {}", self.name, if self.ir { " (IR)" } else { "" }, self.path.trim_start_matches("/dev/"))
    }
}

#[derive(Clone, Default, Debug, PartialEq)]
pub struct Look {
    pub id: i64,
    pub label: String,
    /// Epoch seconds.
    pub time: i64,
    /// Has webcam pictures (the webcam check).
    pub webcam: bool,
}

/// What the rows and the panel read: plain data, cloned out of `Face`.
#[derive(Clone, Default, Debug)]
pub struct Snap {
    pub probed: bool,
    pub howdy: bool,
    pub pam_module: bool,
    pub greeter_installed: bool,
    pub lock_on: bool,
    pub greeter_on: bool,
    pub howdy_off: bool,
    pub cameras: Vec<Camera>,
    pub camera: String,
    /// The face service's status, when it answers.
    pub service: Option<Value>,
    /// Its looks, or Howdy's; None when they can't be read.
    pub looks: Option<Vec<Look>>,
    pub listed_faces: i64,
    pub webcam_check: bool,
    /// Howdy's settings as they are, with what is waiting to go in laid over.
    pub config: BTreeMap<String, String>,
    pub unlocked: bool,
    pub busy: bool,
    pub status: String,
    pub failed: bool,
    pub adding: bool,
    pub recording: bool,
    pub adding_alone: bool,
    pub just_added: bool,
    pub add_failed: bool,
    pub testing: bool,
    pub has_webcam: bool,
    pub previewing: bool,
    pub preview_error: String,
}

impl Snap {
    pub fn engine_is_service(&self) -> bool {
        self.service.as_ref().is_some_and(|s| s["result"] == "ok" && !s["models"].is_null())
    }

    pub fn installed(&self) -> bool {
        (self.howdy && self.pam_module) || self.engine_is_service()
    }

    pub fn on(&self) -> bool {
        self.lock_on || self.greeter_on
    }

    /// How many looks you're known by; -1 while unknown.
    pub fn faces(&self) -> i64 {
        self.looks.as_ref().map(|l| l.len() as i64).unwrap_or(self.listed_faces)
    }

    pub fn cfg(&self, name: &str, fallback: &str) -> String {
        self.config.get(name).cloned().unwrap_or_else(|| fallback.to_string())
    }

    pub fn cfg_num(&self, name: &str, fallback: f64) -> f64 {
        self.cfg(name, "").parse().unwrap_or(fallback)
    }

    pub fn cfg_bool(&self, name: &str, fallback: bool) -> bool {
        self.config.get(name).map(|v| v.eq_ignore_ascii_case("true")).unwrap_or(fallback)
    }

    pub fn service_str(&self, key: &str) -> Option<f64> {
        self.service.as_ref().and_then(|s| s[key].as_f64())
    }
}

/// What a row asks for; `Face::command` does it.
#[derive(Clone, Debug)]
pub enum Cmd {
    Refresh,
    Enable,
    Disable,
    SetHowdy(bool),
    SetCamera(String),
    SetWebcamCheck(bool),
    AddFace(bool),
    ClearFaces,
    RemoveLook(i64),
    SetService(String, String),
    SetCfg(String, String),
    Lock,
    Test,
    ApplyConfig,
    DiscardConfig,
}

// ── reading what is there ────────────────────────────────────────────────

/// The probe: the same shell script the Quickshell version runs, whose output
/// is tab-separated lines. Nothing in it needs a password.
const PROBE: &str = r#"
command -v howdy >/dev/null 2>&1 && echo howdy
for d in /usr/lib/security /lib/security /usr/lib64/security /lib64/security /usr/lib/x86_64-linux-gnu/security; do
    [ -f "$d/pam_howdy.so" ] && { echo pam; break; }
done
[ -d /usr/share/hyprshell-greeter ] && echo greeter
for v in /sys/class/video4linux/video*; do
    [ -e "$v/name" ] || continue
    [ "$(cat "$v/index" 2>/dev/null || echo 0)" = 0 ] || continue
    ir=0
    if command -v v4l2-ctl >/dev/null 2>&1; then
        f=$(v4l2-ctl -d "/dev/${v##*/}" --list-formats 2>/dev/null)
        printf '%s' "$f" | grep -q "'GREY'" && ! printf '%s' "$f" | grep -qE "'(YUYV|MJPG|NV12|RGB3)'" && ir=1
    fi
    printf 'cam\t/dev/%s\t%s\t%s\n' "${v##*/}" "$(cat "$v/name")" "$ir"
done
for c in /etc/howdy/config.ini /usr/lib/security/howdy/config.ini /lib/security/howdy/config.ini; do
    [ -r "$c" ] || continue
    printf 'config\t%s\n' "$c"
    sed -n -E 's/^[[:space:]]*device_path[[:space:]]*=[[:space:]]*(.*)$/device\t\1/p' "$c" | head -n1
    r=$(sed -n '/^\[rubberstamps\]/,/^\[/p' "$c")
    printf '%s\n' "$r" | grep -Eq '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true' \
        && printf '%s\n' "$r" | grep -Eq '^[[:space:]]+hyprshell_webcam' && echo webcamcheck
    break
done
for m in /etc/howdy/models /usr/lib/security/howdy/models /lib/security/howdy/models; do
    [ -d "$m" ] || continue
    printf 'models\t%s\n' "$m/$USER.dat"
    break
done
if command -v hyprshell-face >/dev/null 2>&1; then
    printf 'service\t%s\n' "$(hyprshell-face status 2>/dev/null | tr -d '\n')"
    printf 'servicelooks\t%s\n' "$(hyprshell-face list 2>/dev/null | tr -d '\n')"
fi
if command -v howdy >/dev/null 2>&1; then
    out=$(howdy -U "$USER" list 2>/dev/null) && printf 'faces\t%s\n' "$(printf '%s\n' "$out" | grep -cE '^[[:space:]]*[0-9]+')"
fi
true
"#;

/// What the probe found, before the files are read.
#[derive(Default, Debug)]
pub struct Probed {
    pub howdy: bool,
    pub pam_module: bool,
    pub greeter_installed: bool,
    pub cameras: Vec<Camera>,
    pub camera: String,
    pub listed_faces: i64,
    pub models_path: String,
    pub webcam_check: bool,
    pub config_path: String,
    pub service: Option<Value>,
    pub service_looks: Option<Vec<Look>>,
    // Read from files by the thread that probes:
    pub lock_on: bool,
    pub greeter_on: bool,
    pub howdy_off: bool,
    pub config_text: String,
    pub models_text: Option<String>,
}

pub fn parse_probe(text: &str) -> Probed {
    let mut p = Probed { listed_faces: -1, ..Default::default() };
    let (mut service_text, mut looks_text) = (String::new(), String::new());
    for line in text.lines() {
        let t: Vec<&str> = line.split('\t').collect();
        match t[0] {
            "howdy" => p.howdy = true,
            "pam" => p.pam_module = true,
            "greeter" => p.greeter_installed = true,
            "cam" if t.len() >= 3 => {
                let name = t[2].trim().to_string();
                let lower = name.to_lowercase();
                p.cameras.push(Camera {
                    path: t[1].to_string(),
                    ir: t.get(3) == Some(&"1") || lower.contains("infrared") || lower.split(|c: char| !c.is_alphanumeric()).any(|w| w == "ir"),
                    name,
                });
            }
            "device" => p.camera = t.get(1).unwrap_or(&"").trim().to_string(),
            "faces" => p.listed_faces = t.get(1).and_then(|n| n.trim().parse().ok()).unwrap_or(-1),
            "models" => p.models_path = t.get(1).unwrap_or(&"").trim().to_string(),
            "webcamcheck" => p.webcam_check = true,
            "config" => p.config_path = t.get(1).unwrap_or(&"").trim().to_string(),
            "service" => service_text = t[1..].join("\t").trim().to_string(),
            "servicelooks" => looks_text = t[1..].join("\t").trim().to_string(),
            _ => {}
        }
    }
    p.service = serde_json::from_str(&service_text).ok();
    if let Ok(v) = serde_json::from_str::<Value>(&looks_text) {
        if v["result"] == "ok" {
            p.service_looks = Some(
                v["looks"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|m| Look {
                        id: m["id"].as_i64().unwrap_or(0),
                        label: m["label"].as_str().filter(|s| !s.is_empty()).unwrap_or("Face").to_string(),
                        time: m["time"].as_i64().unwrap_or(0),
                        webcam: m["webcam"].as_i64().unwrap_or(0) > 0,
                    })
                    .collect(),
            );
        }
    }
    p
}

/// Howdy's config.ini as `section.key` → value, with the webcam check's
/// options out of its rubberstamps rule.
pub fn parse_config(text: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let mut section = String::new();
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') || t.starts_with(';') {
            continue;
        }
        if let Some(head) = t.strip_prefix('[').and_then(|h| h.strip_suffix(']')) {
            section = head.to_string();
            continue;
        }
        if section == "rubberstamps" && t.starts_with("hyprshell_webcam") {
            for opt in t.split_whitespace().skip(1) {
                if let Some((k, v)) = opt.split_once('=') {
                    out.insert(format!("webcam.{k}"), v.to_string());
                }
            }
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let k = k.trim();
            if !section.is_empty() && !k.is_empty() && k.chars().all(|c| c.is_alphanumeric() || c == '_') {
                out.insert(format!("{section}.{k}"), v.trim().to_string());
            }
        }
    }
    out
}

/// Howdy's own list of looks, from its models file.
pub fn parse_howdy_looks(text: &str) -> Option<Vec<Look>> {
    let all: Vec<Value> = serde_json::from_str(if text.trim().is_empty() { "[]" } else { text }).ok()?;
    Some(
        all.iter()
            .map(|m| Look {
                id: m["id"].as_i64().unwrap_or(0),
                label: m["label"].as_str().filter(|s| !s.is_empty()).unwrap_or("Face").to_string(),
                time: m["time"].as_i64().or_else(|| m["time"].as_f64().map(|f| f as i64)).unwrap_or(0),
                webcam: false,
            })
            .collect(),
    )
}

// ── the helper, through pkexec ───────────────────────────────────────────

pub fn script_dir() -> PathBuf {
    hyprshell_kit::config_dir().join("quickshell/hyprshell/scripts")
}

pub fn script() -> PathBuf {
    script_dir().join("howdy-setup.sh")
}

/// What the helper's output stream says, line by line.
#[derive(Debug, PartialEq)]
pub enum Line {
    Ready,
    Exit(i32),
    Recording,
    Text(String),
}

pub fn parse_line(l: &str) -> Line {
    if l == "\u{1f}READY" {
        return Line::Ready;
    }
    if let Some(n) = l.strip_prefix("\u{1f}EXIT ") {
        return Line::Exit(n.trim().parse().unwrap_or(1));
    }
    if l.trim() == "recording" {
        return Line::Recording;
    }
    Line::Text(l.to_string())
}

pub struct Helper {
    stdin: ChildStdin,
    pub ready: bool,
}

impl Helper {
    /// Starts it: `pkexec bash howdy-setup.sh --serve`, which asks for the
    /// password. Lines it prints go to `on_line` on a thread of their own.
    pub fn start(command: &[String], on_line: impl Fn(String) + Send + Sync + 'static, on_exit: impl FnOnce(i32) + Send + 'static) -> std::io::Result<Helper> {
        let mut child = Command::new(&command[0]).args(&command[1..]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
        let stdin = child.stdin.take().ok_or_else(|| std::io::Error::other("no stdin"))?;
        let out = child.stdout.take().ok_or_else(|| std::io::Error::other("no stdout"))?;
        let err = child.stderr.take();
        let on_line = std::sync::Arc::new(on_line);
        let a = on_line.clone();
        let reader = std::thread::spawn(move || {
            for l in BufReader::new(out).lines().map_while(Result::ok) {
                a(l);
            }
        });
        // pkexec's own words, before it's running.
        if let Some(err) = err {
            let b = on_line.clone();
            std::thread::spawn(move || {
                for l in BufReader::new(err).lines().map_while(Result::ok) {
                    b(l);
                }
            });
        }
        // The exit code is the child's, found by a thread that waits for it
        // after the output has been read.
        let pid = child.id();
        // The child is waited for by the thread below, by its pid.
        drop(child);
        std::thread::spawn(move || {
            let _ = reader.join();
            on_exit(wait_code(pid));
        });
        Ok(Helper { stdin, ready: false })
    }

    /// One request: its arguments, tab-separated, as the helper reads them.
    pub fn send(&mut self, args: &[String]) -> std::io::Result<()> {
        self.stdin.write_all(format!("{}\n", args.join("\t")).as_bytes())?;
        self.stdin.flush()
    }

    /// Its end of the pipe closes, and it's done (the thread that waits for it
    /// reports how it ended).
    pub fn close(self) {
        drop(self.stdin);
    }
}

/// The exit code of a child that is being waited for elsewhere: -1 if it
/// can't be told. (pkexec's: 126 a dismissed or wrong password, 127 not allowed.)
fn wait_code(pid: u32) -> i32 {
    // The reader ends when the pipe does, which is when the child has gone;
    // its status is then what /proc no longer says, so ask waitpid.
    let mut status: i32 = 0;
    // SAFETY: waitpid on a pid this program started.
    let r = unsafe { libc_waitpid(pid as i32, &mut status, 0) };
    let _ = r;
    if status & 0x7f == 0 { (status >> 8) & 0xff } else { 128 + (status & 0x7f) }
}

extern "C" {
    #[link_name = "waitpid"]
    fn libc_waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
}

// ── the picture ──────────────────────────────────────────────────────────

pub const FRAME_W: usize = 640;
pub const FRAME_H: usize = 480;

/// The webcam as raw frames: ffmpeg, mirrored for you, ends with this
/// program (setpriv --pdeathsig) so it can't be left holding the camera.
pub struct Preview {
    child: Child,
}

impl Preview {
    pub fn start(device: &str, small: bool, on_frame: impl Fn(Vec<u8>) + Send + 'static, on_end: impl FnOnce(i32, String) + Send + 'static) -> std::io::Result<Preview> {
        let script = r#"
            dev=$1 small=$2
            set -- -nostdin -loglevel error -f v4l2 ${small:+-input_format mjpeg -video_size 640x480} -i "$dev" \
                -vf fps=10,scale=640:480,hflip -f rawvideo -pix_fmt rgb24 -
            command -v setpriv >/dev/null 2>&1 && exec setpriv --pdeathsig TERM -- ffmpeg "$@"
            exec ffmpeg "$@""#;
        let mut child = Command::new("sh")
            .args(["-c", script, "face-preview", device, if small { "1" } else { "" }])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let mut out = child.stdout.take().ok_or_else(|| std::io::Error::other("no pipe"))?;
        let err = child.stderr.take();
        let said = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        if let Some(err) = err {
            let said = said.clone();
            std::thread::spawn(move || {
                for l in BufReader::new(err).lines().map_while(Result::ok) {
                    if !l.trim().is_empty() {
                        if let Ok(mut s) = said.lock() {
                            *s = l.trim().to_string();
                        }
                    }
                }
            });
        }
        let pid = child.id();
        std::thread::spawn(move || {
            let mut frame = vec![0u8; FRAME_W * FRAME_H * 3];
            while out.read_exact(&mut frame).is_ok() {
                on_frame(frame.clone());
            }
            let code = wait_code(pid);
            let s = said.lock().map(|s| s.clone()).unwrap_or_default();
            on_end(code, s);
        });
        Ok(Preview { child })
    }

    pub fn stop(&mut self) {
        // SAFETY: a signal to a child this program started.
        unsafe { libc_kill(self.child.id() as i32, 15) };
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for Preview {
    fn drop(&mut self) {
        self.stop();
    }
}

extern "C" {
    #[link_name = "kill"]
    fn libc_kill(pid: i32, sig: i32) -> i32;
}

/// A device for the picture: a webcam beside Howdy's camera when there is
/// one (an infrared picture is a grey ghost, and Howdy needs its camera to
/// itself while it records), else Howdy's.
pub fn preview_device(cameras: &[Camera], howdy_camera: &str) -> String {
    let howdy = if !howdy_camera.is_empty() {
        howdy_camera.to_string()
    } else {
        cameras.iter().find(|c| c.ir).or(cameras.first()).map(|c| c.path.clone()).unwrap_or_default()
    };
    cameras.iter().find(|c| !c.ir && c.path != howdy).map(|c| c.path.clone()).unwrap_or(howdy)
}

pub fn preview_shared(cameras: &[Camera], howdy_camera: &str) -> bool {
    let dev = preview_device(cameras, howdy_camera);
    dev == howdy_camera || cameras.iter().any(|c| c.ir && c.path == dev)
}

// ── the controller ───────────────────────────────────────────────────────

use std::sync::Arc;
use std::time::{Duration, Instant};

/// What threads tell the window: delivered on its own thread, to `Face::on_msg`.
pub enum Msg {
    Probed(Probed),
    Line(String),
    HelperExit(i32),
    Frame(u64, Vec<u8>),
    PreviewEnded(u64, i32, String),
    Settled,
    Waited,
    Still,
    StillsDone(bool),
    RetryAlone,
    ApplySoon,
    ClearAdded,
    PreviewIdle,
    TestDone(bool, String),
    RemoveDone(i32, String),
}

pub type Notify = Arc<dyn Fn(Msg) + Send + Sync>;

#[derive(Default)]
struct Run {
    done: String,
    adding: bool,
    waiting: bool,
    recording_at: Option<Instant>,
    out: String,
}

pub struct Face {
    pub snap: Snap,
    notify: Option<Notify>,
    probed: Probed,
    config: BTreeMap<String, String>,
    pending: BTreeMap<String, String>,
    applying: Vec<String>,
    helper: Option<Helper>,
    queued: Option<Vec<String>>,
    run: Run,
    preview: Option<Preview>,
    preview_gen: u64,
    preview_small: bool,
    preview_ready: bool,
    pub frame: Option<Vec<u8>>,
    pub frame_new: bool,
    preparing: bool,
    add_alt: bool,
    retried_alone: bool,
    stills: Vec<Vec<u8>>,
    apply_gen: u64,
    /// Overridable for tests.
    pub helper_command: Option<Vec<String>>,
}

impl Default for Face {
    fn default() -> Face {
        Face {
            snap: Snap { listed_faces: -1, ..Default::default() },
            notify: None,
            probed: Probed::default(),
            config: BTreeMap::new(),
            pending: BTreeMap::new(),
            applying: Vec::new(),
            helper: None,
            queued: None,
            run: Run::default(),
            preview: None,
            preview_gen: 0,
            preview_small: true,
            preview_ready: false,
            frame: None,
            frame_new: false,
            preparing: false,
            add_alt: false,
            retried_alone: false,
            stills: Vec::new(),
            apply_gen: 0,
            helper_command: None,
        }
    }
}

fn runtime_dir() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"))
}

pub fn stills_dir() -> PathBuf {
    runtime_dir().join("hyprshell-face-stills")
}

fn user() -> String {
    std::env::var("USER").unwrap_or_default()
}

impl Face {
    pub fn start(&mut self, notify: Notify) {
        self.notify = Some(notify);
        self.refresh();
    }

    fn tell(&self, m: Msg) {
        if let Some(n) = &self.notify {
            n(m);
        }
    }

    fn later(&self, ms: u64, f: impl Fn() -> Msg + Send + 'static) {
        let Some(n) = self.notify.clone() else { return };
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(ms));
            n(f());
        });
    }

    /// Looks at what's there again: on a thread, as it runs programs.
    pub fn refresh(&mut self) {
        let Some(n) = self.notify.clone() else { return };
        std::thread::spawn(move || {
            // The tests' own world: a folder standing in for the machine
            // (HYPRSHELL_FACE_FIXTURE: probe.txt, pam-lock, greetd, no-howdy).
            let fixture = std::env::var_os("HYPRSHELL_FACE_FIXTURE").map(PathBuf::from);
            let text = match &fixture {
                Some(d) => std::fs::read_to_string(d.join("probe.txt")).unwrap_or_default(),
                None => {
                    let out = Command::new("sh").args(["-c", PROBE]).stdout(Stdio::piped()).stderr(Stdio::null()).output();
                    out.map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default()
                }
            };
            let mut p = parse_probe(&text);
            let at = |real: &str, name: &str| match &fixture {
                Some(d) => d.join(name),
                None => PathBuf::from(real),
            };
            let read = |f: PathBuf| std::fs::read_to_string(f).ok();
            p.lock_on = read(at("/etc/pam.d/hyprshell-lock", "pam-lock")).is_some_and(|t| t.contains("pam_howdy") || t.contains("pam_hyprshell_face"));
            p.greeter_on = read(at("/etc/pam.d/greetd", "greetd")).is_some_and(|t| t.contains("hyprshell-face"));
            p.howdy_off = at("/etc/hyprshell-face/no-howdy", "no-howdy").exists();
            p.config_text = if p.config_path.is_empty() { String::new() } else { read(PathBuf::from(&p.config_path)).unwrap_or_default() };
            p.models_text = if p.models_path.is_empty() { None } else { std::fs::read_to_string(&p.models_path).ok().or_else(|| if std::path::Path::new(&p.models_path).exists() { None } else { Some(String::new()) }) };
            n(Msg::Probed(p));
        });
    }

    fn rebuild(&mut self) {
        let p = &self.probed;
        let s = &mut self.snap;
        s.probed = true;
        s.howdy = p.howdy;
        s.pam_module = p.pam_module;
        s.greeter_installed = p.greeter_installed;
        s.lock_on = p.lock_on;
        s.greeter_on = p.greeter_on;
        s.howdy_off = p.howdy_off;
        s.cameras = p.cameras.clone();
        s.camera = p.camera.clone();
        s.service = p.service.clone();
        s.listed_faces = p.listed_faces;
        s.webcam_check = if s.engine_is_service() { p.service.as_ref().is_some_and(|v| v["webcam_check"] == true) } else { p.webcam_check };
        s.looks = if s.engine_is_service() { p.service_looks.clone() } else { p.models_text.as_deref().and_then(parse_howdy_looks) };
        let mut c = self.config.clone();
        for (k, v) in &self.pending {
            c.insert(k.clone(), v.clone());
        }
        s.config = c;
        s.unlocked = self.helper.as_ref().is_some_and(|h| h.ready);
        // Adding a face: recording now, or the webcam first (a moment to see yourself).
        s.adding = (s.busy && self.run.adding) || self.preparing;
        s.recording = s.busy && self.run.adding && self.run.recording_at.is_some();
        s.has_webcam = {
            let dev = preview_device(&p.cameras, &p.camera);
            !dev.is_empty() && !preview_shared(&p.cameras, &p.camera)
        };
        s.previewing = self.preview.is_some();
    }

    pub fn snapshot(&mut self) -> Snap {
        self.rebuild();
        self.snap.clone()
    }

    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// Whether to look at the camera now (the panel is up and it's being used).
    pub fn picture(&self) -> bool {
        self.preview_ready && self.frame.is_some()
    }

    // ── what a row asks for ──────────────────────────────────────────────

    pub fn command(&mut self, c: Cmd) {
        match c {
            Cmd::Refresh => self.refresh(),
            Cmd::Enable => self.run(&[], "Setting up face unlock…", "Face unlock is on: lock the screen to try it"),
            Cmd::Disable => self.run(&["--remove"], "Turning face unlock off…", "Face unlock is off"),
            Cmd::SetHowdy(on) => self.run(
                &["--howdy", if on { "on" } else { "off" }],
                if on { "Bringing Howdy back…" } else { "Leaving Howdy out…" },
                if on { "Howdy is the fallback again" } else { "Hyprshell's own face recognition alone: Howdy is left out" },
            ),
            Cmd::SetCamera(path) => {
                let done = format!("Howdy uses {path}");
                self.run(&["--camera", &path], "Switching camera…", &done);
            }
            Cmd::SetWebcamCheck(on) => {
                if on {
                    let dev = preview_device(&self.probed.cameras, &self.probed.camera);
                    self.run(&["--webcam-check", "on", &dev], "Turning the webcam check on…", "The webcam has to recognise you too; in low light the infrared camera decides alone");
                } else {
                    self.run(&["--webcam-check", "off"], "Turning the webcam check off…", "The infrared camera decides alone");
                }
            }
            Cmd::AddFace(alt) => self.add_face(alt),
            Cmd::ClearFaces => self.run(&["--clear-faces"], "Removing your faces…", "Your faces are removed"),
            Cmd::RemoveLook(id) => self.remove_look(id),
            Cmd::SetService(k, v) => {
                let kv = format!("{k}={v}");
                self.run(&["--face-set", &kv], "Changing the face service's settings…", "Changed");
            }
            Cmd::SetCfg(k, v) => self.set_cfg(k, v),
            Cmd::Lock => {
                if !self.snap.busy {
                    if let Some(h) = self.helper.take() {
                        h.close();
                    }
                }
            }
            Cmd::Test => self.test(),
            Cmd::ApplyConfig => self.apply_config(),
            Cmd::DiscardConfig => self.discard_config(),
        }
    }

    pub fn discard_config(&mut self) {
        self.pending.clear();
    }

    pub fn apply_config(&mut self) {
        if self.pending.is_empty() {
            return;
        }
        let args: Vec<String> = self.pending.iter().map(|(k, v)| format!("{k}={v}")).collect();
        self.applying = args.clone();
        let mut full = vec!["--set".to_string()];
        full.extend(args);
        self.run_vec(full, "Changing Howdy's settings…", "Howdy's settings are changed");
    }

    fn set_cfg(&mut self, name: String, value: String) {
        if self.config.get(&name) == Some(&value) {
            self.pending.remove(&name);
        } else {
            self.pending.insert(name, value);
        }
        // Made straight away (a moment later, so a few changes in a row go in together).
        self.apply_gen += 1;
        let g = self.apply_gen;
        let _ = g;
        self.later(400, || Msg::ApplySoon);
    }

    // ── changes, through pkexec ──────────────────────────────────────────

    fn run(&mut self, args: &[&str], working: &str, done: &str) {
        self.run_vec(args.iter().map(|a| a.to_string()).collect(), working, done);
    }

    fn run_vec(&mut self, args: Vec<String>, working: &str, done: &str) {
        if self.snap.busy {
            return;
        }
        // A tab or a newline would be two requests.
        if args.iter().any(|a| a.contains('\t') || a.contains('\n')) {
            return;
        }
        self.snap.busy = true;
        self.snap.failed = false;
        self.snap.status = working.to_string();
        self.run.done = done.to_string();
        self.run.out.clear();
        self.run.waiting = true;
        if self.helper.as_ref().is_some_and(|h| h.ready) {
            if let Some(h) = self.helper.as_mut() {
                if h.send(&args).is_err() {
                    self.helper = None;
                    self.run.waiting = false;
                    self.finish(1);
                }
            }
        } else {
            self.queued = Some(args);
            if self.helper.is_none() {
                self.start_helper();
            }
        }
    }

    fn start_helper(&mut self) {
        let command = self.helper_command.clone().unwrap_or_else(|| vec!["pkexec".into(), "bash".into(), script().to_string_lossy().into_owned(), "--serve".into()]);
        let (a, b) = (self.notify.clone(), self.notify.clone());
        let started = Helper::start(
            &command,
            move |l| {
                if let Some(n) = &a {
                    n(Msg::Line(l));
                }
            },
            move |code| {
                if let Some(n) = b {
                    n(Msg::HelperExit(code));
                }
            },
        );
        match started {
            Ok(h) => self.helper = Some(h),
            Err(_) => {
                self.run.waiting = false;
                self.snap.busy = false;
                self.snap.failed = true;
                self.snap.status = "Couldn't ask for your password: is polkit's pkexec installed?".into();
            }
        }
    }

    fn finish(&mut self, code: i32) {
        self.snap.busy = false;
        self.refresh();
        let adding = std::mem::take(&mut self.run.adding);
        let said: Vec<String> = self.run.out.lines().filter(|l| !l.trim().is_empty()).map(|l| l.trim().to_string()).collect();
        // The webcam in Howdy's way (the camera busy, or no USB bandwidth left
        // for it): again, with the webcam off. Not for anything else Howdy says
        // — too dark, no face — which the webcam has nothing to do with.
        let joined = said.join(" ").to_lowercase();
        let camera_trouble = ["no space left on device", "device or resource busy", "failed to read camera", "failed to open camera", "failed to read the camera", "failed to open the camera"].iter().any(|m| joined.contains(m));
        if adding && code != 0 && code != 126 && code != 127 && !self.snap.adding_alone && !self.retried_alone && camera_trouble {
            self.retried_alone = true;
            self.snap.adding_alone = true;
            self.stop_preview();
            self.snap.busy = true;
            self.run.adding = true;
            self.snap.status = "Trying again with the webcam off…".into();
            self.later(500, || Msg::RetryAlone);
            return;
        }
        if adding {
            self.retried_alone = false;
            if code != 0 {
                self.snap.add_failed = true;
                self.later(4000, || Msg::ClearAdded);
            }
        }
        if code == 0 {
            self.snap.status = self.run.done.clone();
            if adding {
                self.snap.just_added = true;
                self.later(2500, || Msg::ClearAdded);
            }
        } else {
            self.snap.failed = true;
            // pkexec: 126 a dismissed or wrong password, 127 not allowed.
            self.snap.status = if code == 126 || code == 127 {
                "Not changed: the password wasn't given".to_string()
            } else {
                said.last().cloned().unwrap_or_else(|| "That didn't work".into()).replace("howdy-setup.sh: ", "").replace("howdy-config: ", "")
            };
        }
        // What went in leaves what's waiting; anything changed meanwhile goes next.
        if !self.applying.is_empty() {
            if code == 0 {
                for kv in std::mem::take(&mut self.applying) {
                    if let Some((k, v)) = kv.split_once('=') {
                        if self.pending.get(k).map(|x| x.as_str()) == Some(v) {
                            self.pending.remove(k);
                        }
                    }
                }
                if !self.pending.is_empty() {
                    self.later(400, || Msg::ApplySoon);
                }
            }
            self.applying.clear();
        }
    }

    // ── faces ────────────────────────────────────────────────────────────

    fn add_face(&mut self, alt: bool) {
        if self.snap.busy {
            return;
        }
        self.add_alt = alt;
        self.snap.adding_alone = preview_shared(&self.probed.cameras, &self.probed.camera) || preview_device(&self.probed.cameras, &self.probed.camera).is_empty();
        self.snap.add_failed = false;
        self.snap.just_added = false;
        self.start_adding();
    }

    /// The webcam first, as Windows Hello does: Howdy starts recording once
    /// you can see yourself in the circle (or after five seconds without a
    /// picture), not before.
    fn start_adding(&mut self) {
        if self.snap.adding_alone {
            self.stop_preview();
            self.launch_adding(None);
            return;
        }
        self.start_preview();
        self.preparing = true;
        if self.preview_ready {
            self.later(700, || Msg::Settled);
        } else {
            self.later(5000, || Msg::Waited);
        }
    }

    fn take_stills(&mut self) {
        if !self.preview_ready {
            self.launch_adding(None);
            return;
        }
        // Webcam pictures for the webcam check, from the picture you've just
        // lined up in: five, a third of a second apart.
        self.stills.clear();
        for i in 1..=5u64 {
            self.later(330 * i, || Msg::Still);
        }
    }

    fn launch_adding(&mut self, stills: Option<PathBuf>) {
        self.preparing = false;
        self.run.adding = true;
        self.run.recording_at = None;
        let mut args = vec!["--add-face".to_string()];
        if self.add_alt {
            args.push("--alt".into());
        }
        if let Some(d) = stills {
            args.push("--stills".into());
            args.push(d.to_string_lossy().into_owned());
        }
        let done = if self.add_alt { "Your alternative look is added" } else { "Your face is added" };
        self.run_vec(args, "Hold still and look at the camera…", done);
    }

    fn remove_look(&mut self, id: i64) {
        if self.snap.busy {
            return;
        }
        if !self.snap.engine_is_service() {
            self.run(&["--remove-face", &id.to_string()], "Removing that look…", "That look is removed");
            return;
        }
        // The service's own looks are yours to remove without a password (it
        // checks it's you asking).
        let Some(n) = self.notify.clone() else { return };
        self.snap.busy = true;
        std::thread::spawn(move || {
            let out = Command::new("hyprshell-face").args(["remove", &id.to_string()]).stderr(Stdio::null()).output();
            let (code, said) = match out {
                Ok(o) => {
                    let said = serde_json::from_slice::<Value>(&o.stdout).ok().and_then(|v| v["message"].as_str().map(|s| s.to_string())).unwrap_or_default();
                    (o.status.code().unwrap_or(1), said)
                }
                Err(_) => (127, String::new()),
            };
            n(Msg::RemoveDone(code, said));
        });
    }

    // ── the camera, seen ─────────────────────────────────────────────────

    pub fn start_preview(&mut self) {
        if self.preview.is_some() {
            return;
        }
        let dev = preview_device(&self.probed.cameras, &self.probed.camera);
        if dev.is_empty() || (self.snap.busy && preview_shared(&self.probed.cameras, &self.probed.camera)) {
            return;
        }
        self.snap.preview_error.clear();
        self.preview_ready = false;
        self.preview_gen += 1;
        let gen = self.preview_gen;
        let (a, b) = (self.notify.clone(), self.notify.clone());
        let started = Preview::start(
            &dev,
            self.preview_small,
            move |f| {
                if let Some(n) = &a {
                    n(Msg::Frame(gen, f));
                }
            },
            move |code, said| {
                if let Some(n) = b {
                    n(Msg::PreviewEnded(gen, code, said));
                }
            },
        );
        match started {
            Ok(p) => {
                self.preview = Some(p);
                self.later(180_000, || Msg::PreviewIdle);
            }
            Err(_) => self.snap.preview_error = "The webcam picture needs ffmpeg".into(),
        }
    }

    pub fn stop_preview(&mut self) {
        self.preview_gen += 1;
        self.preview_ready = false;
        self.frame = None;
        self.frame_new = true;
        if let Some(mut p) = self.preview.take() {
            p.stop();
        }
    }

    // ── trying it ────────────────────────────────────────────────────────

    /// The lock screen's own face check, run here through the shell's PAM
    /// helper (the same one the lock screen uses).
    fn test(&mut self) {
        if self.snap.busy || self.snap.testing || !self.snap.lock_on {
            return;
        }
        let helper = hyprshell_kit::home().join(".local/share/hyprshell/rust/bin/hyprshell-rs");
        let Some(n) = self.notify.clone() else { return };
        if !helper.exists() {
            self.snap.failed = true;
            self.snap.status = "Trying it needs the Rust shell (hyprshell-rs)".into();
            return;
        }
        self.stop_preview();
        self.snap.failed = false;
        self.snap.testing = true;
        self.snap.status = "Look at the camera…".into();
        let user = user();
        std::thread::spawn(move || {
            let started = Instant::now();
            let child = Command::new(&helper).args(["--pam-helper", "hyprshell-lock", &user]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn();
            let Ok(mut child) = child else {
                n(Msg::TestDone(false, "The face check couldn't run".into()));
                return;
            };
            let mut said = String::new();
            let mut ok = false;
            if let Some(out) = child.stdout.take() {
                for l in BufReader::new(out).lines().map_while(Result::ok) {
                    let Ok(v) = serde_json::from_str::<Value>(&l) else { continue };
                    match v["ev"].as_str() {
                        Some("info") => {
                            if let Some(m) = v["msg"].as_str().filter(|m| !m.trim().is_empty()) {
                                said = m.trim().to_string();
                            }
                        }
                        // It wants a password: that is the face not being enough.
                        Some("prompt") => {
                            let _ = child.kill();
                            break;
                        }
                        Some("done") => {
                            ok = v["ok"] == true;
                            break;
                        }
                        _ => {}
                    }
                }
            }
            let _ = child.kill();
            let _ = child.wait();
            let took = format!("{:.1} s", started.elapsed().as_secs_f64());
            n(Msg::TestDone(
                ok,
                if ok { format!("Recognised you in {took}") } else { format!("Didn't recognise you ({took}){}", if said.is_empty() { String::new() } else { format!(" · Howdy says: {said}") }) },
            ));
        });
    }

    // ── what threads said ────────────────────────────────────────────────

    /// True when the page should be drawn again.
    pub fn on_msg(&mut self, m: Msg) -> bool {
        match m {
            Msg::Probed(p) => {
                self.config = parse_config(&p.config_text);
                self.probed = p;
                true
            }
            Msg::Line(l) => {
                match parse_line(&l) {
                    Line::Ready => {
                        if let Some(h) = self.helper.as_mut() {
                            h.ready = true;
                            if let Some(q) = self.queued.take() {
                                if h.send(&q).is_err() {
                                    self.helper = None;
                                }
                            }
                        }
                    }
                    Line::Exit(code) => {
                        self.run.waiting = false;
                        self.finish(code);
                    }
                    Line::Recording => self.run.recording_at = Some(Instant::now()),
                    Line::Text(t) => {
                        self.run.out.push_str(&t);
                        self.run.out.push('\n');
                    }
                }
                true
            }
            Msg::HelperExit(code) => {
                self.helper = None;
                self.queued = None;
                // Gone with a change still waiting: the password wasn't given
                // (pkexec 126, 127), or it ended some other way.
                if self.run.waiting {
                    self.run.waiting = false;
                    self.finish(if code == 126 || code == 127 { code } else if code == 0 { 1 } else { code });
                }
                true
            }
            Msg::Frame(gen, f) => {
                if gen != self.preview_gen {
                    return false;
                }
                self.frame = Some(f);
                self.frame_new = true;
                if !self.preview_ready {
                    self.preview_ready = true;
                    if self.preparing {
                        self.later(700, || Msg::Settled);
                    }
                    return true;
                }
                false
            }
            Msg::PreviewEnded(gen, code, said) => {
                if gen != self.preview_gen {
                    return false;
                }
                self.preview = None;
                self.preview_ready = false;
                if code == 127 {
                    self.snap.preview_error = "The webcam picture needs ffmpeg".into();
                } else if self.preview_small && code != 0 {
                    // The camera's own format, if it can't do MJPEG.
                    self.preview_small = false;
                    self.start_preview();
                    return true;
                } else {
                    self.snap.preview_error = if said.is_empty() { "The webcam stopped".into() } else { format!("The webcam: {said}") };
                }
                true
            }
            Msg::Settled => {
                if self.preparing {
                    self.take_stills();
                }
                true
            }
            Msg::Waited => {
                if self.preparing && !self.preview_ready {
                    self.launch_adding(None);
                }
                true
            }
            Msg::Still => {
                if let Some(f) = self.frame.clone() {
                    self.stills.push(f);
                }
                if self.stills.len() == 5 {
                    let frames = std::mem::take(&mut self.stills);
                    let Some(n) = self.notify.clone() else { return false };
                    std::thread::spawn(move || n(Msg::StillsDone(write_stills(&frames))));
                }
                false
            }
            Msg::StillsDone(ok) => {
                self.launch_adding(if ok { Some(stills_dir()) } else { None });
                true
            }
            Msg::RetryAlone => {
                self.snap.busy = false;
                self.start_adding();
                true
            }
            Msg::ApplySoon => {
                if self.snap.busy {
                    self.later(400, || Msg::ApplySoon);
                } else {
                    self.apply_config();
                }
                true
            }
            Msg::ClearAdded => {
                self.snap.just_added = false;
                self.snap.add_failed = false;
                if !self.snap.busy {
                    self.stop_preview();
                }
                true
            }
            Msg::PreviewIdle => {
                if !self.snap.busy && !self.preparing {
                    self.stop_preview();
                }
                true
            }
            Msg::TestDone(ok, text) => {
                self.snap.testing = false;
                self.snap.failed = !ok;
                self.snap.status = text;
                true
            }
            Msg::RemoveDone(code, said) => {
                self.snap.busy = false;
                self.snap.failed = code != 0;
                self.snap.status = if code == 0 { "That look is removed".into() } else if said.is_empty() { "That look couldn't be removed".into() } else { said };
                self.refresh();
                true
            }
        }
    }
}

/// The five webcam pictures, as JPEG files for howdy-setup.sh, which takes
/// them from nowhere but the user's own runtime folder.
fn write_stills(frames: &[Vec<u8>]) -> bool {
    let dir = stills_dir();
    if std::fs::create_dir_all(&dir).is_err() {
        return false;
    }
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    for i in 1..=5 {
        let _ = std::fs::remove_file(dir.join(format!("{i}.jpg")));
    }
    for (i, f) in frames.iter().enumerate() {
        let out = dir.join(format!("{}.jpg", i + 1));
        let child = Command::new("ffmpeg")
            .args(["-nostdin", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", &format!("{FRAME_W}x{FRAME_H}"), "-i", "-", "-frames:v", "1", "-y"])
            .arg(&out)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        let Ok(mut c) = child else { return false };
        if let Some(mut si) = c.stdin.take() {
            if si.write_all(f).is_err() {
                return false;
            }
        }
        if !c.wait().map(|s| s.success()).unwrap_or(false) {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_probe_is_read_as_the_script_writes_it() {
        let text = "howdy\npam\ngreeter\ncam\t/dev/video0\tIntegrated Camera\t0\ncam\t/dev/video2\tIntegrated IR Camera\t1\nconfig\t/etc/howdy/config.ini\ndevice\t/dev/video2\nwebcamcheck\nmodels\t/etc/howdy/models/me.dat\nfaces\t2\nservice\t{\"result\":\"ok\",\"models\":3,\"threshold\":0.45}\nservicelooks\t{\"result\":\"ok\",\"looks\":[{\"id\":1,\"label\":\"Face 2026-01-01\",\"time\":1700000000,\"webcam\":5}]}\n";
        let p = parse_probe(text);
        assert!(p.howdy && p.pam_module && p.greeter_installed && p.webcam_check);
        assert_eq!(p.cameras.len(), 2);
        assert!(!p.cameras[0].ir && p.cameras[1].ir);
        assert_eq!(p.camera, "/dev/video2");
        assert_eq!(p.listed_faces, 2);
        assert_eq!(p.service.as_ref().and_then(|s| s["threshold"].as_f64()), Some(0.45));
        let looks = p.service_looks.expect("the service's looks");
        assert_eq!(looks.len(), 1);
        assert!(looks[0].webcam);
    }

    #[test]
    fn an_empty_probe_finds_nothing() {
        let p = parse_probe("");
        assert!(!p.howdy && p.cameras.is_empty() && p.service.is_none() && p.listed_faces == -1);
    }

    #[test]
    fn howdys_config_is_read_with_the_webcam_rule() {
        let c = parse_config("[core]\nabort_if_ssh = true\n\n[video]\n certainty = 3.5\ndevice_path = /dev/video2\n[rubberstamps]\nenabled = true\n  hyprshell_webcam min_light=45 timeout=3\n# a comment\n");
        assert_eq!(c.get("video.certainty").map(|s| s.as_str()), Some("3.5"));
        assert_eq!(c.get("core.abort_if_ssh").map(|s| s.as_str()), Some("true"));
        assert_eq!(c.get("webcam.min_light").map(|s| s.as_str()), Some("45"));
        assert_eq!(c.get("rubberstamps.enabled").map(|s| s.as_str()), Some("true"));
    }

    #[test]
    fn the_helpers_lines_are_told_apart() {
        assert_eq!(parse_line("\u{1f}READY"), Line::Ready);
        assert_eq!(parse_line("\u{1f}EXIT 126"), Line::Exit(126));
        assert_eq!(parse_line("recording"), Line::Recording);
        assert_eq!(parse_line("  Face unlock is on"), Line::Text("  Face unlock is on".into()));
    }

    #[test]
    fn the_picture_is_taken_from_the_webcam_not_the_infrared_camera() {
        let cams = vec![
            Camera { path: "/dev/video0".into(), name: "Integrated Camera".into(), ir: false },
            Camera { path: "/dev/video2".into(), name: "Integrated IR Camera".into(), ir: true },
        ];
        assert_eq!(preview_device(&cams, "/dev/video2"), "/dev/video0");
        assert!(!preview_shared(&cams, "/dev/video2"));
        // With one camera, Howdy's own.
        assert_eq!(preview_device(&cams[1..], "/dev/video2"), "/dev/video2");
        assert!(preview_shared(&cams[1..], "/dev/video2"));
    }

    #[test]
    fn a_helper_answers_a_change_and_ends_when_closed() {
        // A stand-in for `pkexec bash howdy-setup.sh --serve`: the same words.
        let script = "printf '\\037READY\\n'; while IFS=$'\\t' read -r -a a; do echo \"did ${a[0]}\"; printf '\\037EXIT 0\\n'; done";
        let got = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let (g, ended) = (got.clone(), std::sync::Arc::new(std::sync::Mutex::new(None::<i32>)));
        let e = ended.clone();
        let mut h = Helper::start(&["bash".into(), "-c".into(), script.into()], move |l| g.lock().unwrap().push(l), move |c| *e.lock().unwrap() = Some(c)).expect("a helper");
        for _ in 0..50 {
            if got.lock().unwrap().iter().any(|l| parse_line(l) == Line::Ready) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        h.send(&["--camera".into(), "/dev/video2".into()]).expect("sent");
        for _ in 0..50 {
            if got.lock().unwrap().iter().any(|l| matches!(parse_line(l), Line::Exit(_))) {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        h.close();
        for _ in 0..50 {
            if ended.lock().unwrap().is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let lines = got.lock().unwrap().clone();
        assert!(lines.contains(&"did --camera".to_string()), "{lines:?}");
        assert_eq!(*ended.lock().unwrap(), Some(0));
    }
}
