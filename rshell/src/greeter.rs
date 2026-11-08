//! The login screen (greeter/: shell.qml, GreeterState.qml, GreeterLook.qml,
//! Surface.qml), run by greetd as `hyprshell-rs --greeter` inside the
//! greeter's own Hyprland (greeter/hyprland.lua).
//!
//! The lock screen's view (ui/lock.slint), with the greeter's people,
//! sessions and power: the person picked's own theme and wallpaper, as
//! their shell keeps a copy in /var/lib/hyprshell-greeter/users/<name>; the
//! card on the main screen of their Settings (else an external monitor over
//! the laptop's panel), coming to whichever screen the pointer is moved on.
//!
//! greetd does the part that matters: the greeter runs as greetd's own
//! unprivileged user, and what is typed goes straight to greetd (greetd.rs),
//! which checks it with PAM and starts the chosen session as you. With face
//! unlock in greetd's PAM file the session is opened as soon as a person is
//! picked, so the face is being looked for before anything is typed.
//!
//! Outside greetd it's a preview: everything works but logging in, and
//! Escape on an empty field leaves.

use crate::greetd::{Event, Greetd, Req};
use crate::lock::{chrono_now, face_glyph, glyph_set, images, rgb, scrim, Px};
use crate::spring::Spring;
use crate::wl::{self, Placement};
use crate::{theme, LockView, Theme};
use serde_json::{json, Value};
use slint::{ComponentHandle, Image, SharedString};
use smithay_client_toolkit::shell::wlr_layer::{Anchor, KeyboardInteractivity, Layer};
use std::cell::RefCell;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};
use wayland_client::protocol::wl_output::WlOutput;
use wayland_client::QueueHandle;

fn env_or(k: &str, d: &str) -> String {
    std::env::var(k).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| d.to_string())
}

#[derive(Clone)]
struct User {
    name: String,
    display: String,
    uid: u32,
}

#[derive(Clone)]
struct Session {
    id: String,
    name: String,
    command: Vec<String>,
    desktop_names: String,
}

/// People, not system accounts: a uid from 1000, and a shell you can log in
/// with — the rule every display manager uses.
fn read_users(path: &str) -> Vec<User> {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let mut out: Vec<User> = text
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split(':').collect();
            if f.len() < 7 {
                return None;
            }
            let uid: u32 = f[2].parse().ok()?;
            if !(1000..60000).contains(&uid) || f[6].ends_with("nologin") || f[6].ends_with("false") {
                return None;
            }
            let full = f[4].split(',').next().unwrap_or("").trim();
            Some(User { name: f[0].into(), display: if full.is_empty() { f[0].into() } else { full.into() }, uid })
        })
        .collect();
    out.sort_by_key(|u| u.uid);
    out
}

/// An Exec= line into argv: double quotes group, field codes (%f, %U …) go.
fn split_exec(line: &str) -> Vec<String> {
    let mut out = vec![];
    let (mut cur, mut quoted, mut any) = (String::new(), false, false);
    let mut chars = line.chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            if c == '\\' {
                if let Some(n) = chars.next() {
                    cur.push(n);
                }
                continue;
            }
            if c == '"' {
                quoted = false;
                continue;
            }
            cur.push(c);
        } else if c == '"' {
            quoted = true;
            any = true;
        } else if c == ' ' || c == '\t' {
            if !cur.is_empty() || any {
                out.push(std::mem::take(&mut cur));
            }
            any = false;
        } else {
            cur.push(c);
        }
    }
    if !cur.is_empty() || any {
        out.push(cur);
    }
    out.retain(|a| !(a.len() == 2 && a.starts_with('%') && a.as_bytes()[1].is_ascii_alphabetic()));
    out
}

/// Every Wayland session installed, from the [Desktop Entry] of its file.
fn read_sessions(dirs: &str) -> Vec<Session> {
    let mut out: Vec<Session> = vec![];
    for d in dirs.split(':') {
        let Ok(rd) = std::fs::read_dir(d) else { continue };
        let mut files: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "desktop")).collect();
        files.sort();
        for f in files {
            let id = f.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            if out.iter().any(|s| s.id == id) {
                continue;
            }
            let text = std::fs::read_to_string(&f).unwrap_or_default();
            let (mut main, mut name, mut exec, mut dn, mut hidden) = (false, String::new(), String::new(), String::new(), false);
            for l in text.lines() {
                if l.starts_with('[') {
                    main = l.trim() == "[Desktop Entry]";
                    continue;
                }
                if !main {
                    continue;
                }
                if let Some(v) = l.strip_prefix("Name=") {
                    if name.is_empty() {
                        name = v.into();
                    }
                } else if let Some(v) = l.strip_prefix("Exec=") {
                    if exec.is_empty() {
                        exec = v.into();
                    }
                } else if let Some(v) = l.strip_prefix("DesktopNames=") {
                    if dn.is_empty() {
                        dn = v.into();
                    }
                } else if l.trim() == "Hidden=true" || l.trim() == "NoDisplay=true" {
                    hidden = true;
                }
            }
            if exec.is_empty() || hidden {
                continue;
            }
            out.push(Session { name: if name.is_empty() { id.clone() } else { name }, command: split_exec(&exec), desktop_names: dn, id });
        }
    }
    out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    out
}

/// A number from a person's own file, if it is one, and in range.
fn num(v: &Value, lo: f64, hi: f64) -> Option<f64> {
    v.as_f64().filter(|n| n.is_finite() && *n >= lo && *n <= hi)
}

/// GreeterLook.monitorLua: hl.monitor for each screen of the person's
/// screens.json, every value checked before it goes near a command.
fn monitor_lua(screens: &Value) -> String {
    let mut lua = String::new();
    for m in screens.as_array().into_iter().flatten() {
        let name = m["name"].as_str().unwrap_or("");
        if name.is_empty() || name.len() > 64 || !name.chars().all(|c| c.is_ascii_alphanumeric() || "_.:-".contains(c)) {
            continue;
        }
        let (Some(w), Some(h), Some(hz), Some(sc)) = (num(&m["width"], 1.0, 16384.0), num(&m["height"], 1.0, 16384.0), num(&m["refreshRate"], 1.0, 1000.0), num(&m["scale"], 0.25, 8.0)) else {
            continue;
        };
        let pos = match (num(&m["x"], -65536.0, 65536.0), num(&m["y"], -65536.0, 65536.0)) {
            (Some(x), Some(y)) => format!("{}x{}", x.round(), y.round()),
            _ => "auto".into(),
        };
        lua += &format!(
            "hl.monitor({{ output = \"{name}\", mode = \"{}x{}@{}\", position = \"{pos}\", scale = {} }}) ",
            w.round(),
            h.round(),
            (hz * 1000.0).round() / 1000.0,
            (sc * 1e6).round() / 1e6
        );
    }
    lua
}

struct Screen {
    output: WlOutput,
    name: String,
    view: LockView,
    id: usize,
    ground_for: Option<(u32, u32)>,
    primary: bool,
    /// Wearing the theme of the person picked.
    themed: bool,
}

pub enum Act {
    Typed(String),
    Submit,
    Escape,
    Power(String),
    RetryFace,
    Woke,
    StepUser(i32),
    StepSession(i32),
    Claim(String),
}

struct Greeter {
    greetd: Option<Greetd>,
    preview: bool,
    hostname: String,
    users: Vec<User>,
    user_ix: usize,
    sessions: Vec<Session>,
    session_ix: usize,
    users_dir: String,
    state_file: String,
    icon_dir: String,
    session_wrap: Option<String>,

    look: theme::Theme,
    ground: crate::ground::Spec,
    picture: Option<Image>,
    screens_json: Value,
    pointer_screen: String,

    entered: String,
    status: String,
    failed: bool,
    busy: bool,
    busy_since: Option<Instant>,
    prompt: String,
    prompt_echo: bool,
    password_sent: bool,

    face_enabled: bool,
    info: String,
    face_started: bool,
    awaiting_password: bool,
    pending: bool,
    face_found: bool,
    face_missed: bool,
    face_missed_at: Option<Instant>,
    let_go: bool,
    after_cancel: Option<Instant>,
    face_soon: Option<Instant>,

    launch_at: Option<Instant>,
    leaving: Option<Instant>,
    starting: bool,

    shake: Spring,
    face_show: Spring,
    face_close: Spring,
    face_tick: Spring,
    face_dim: Spring,
    started: Instant,

    screens: Vec<Screen>,
    grounds: Vec<(String, u32, u32, Image, Image, bool)>,
    ground_tx: std::sync::mpsc::Sender<(String, u32, u32, Px, Px, bool)>,
    ground_rx: std::sync::mpsc::Receiver<(String, u32, u32, Px, Px, bool)>,
    wake: UnixStream,
    actions: Rc<RefCell<Vec<Act>>>,
    quit: bool,
}

impl Greeter {
    fn new(wake: &UnixStream) -> Greeter {
        let greetd = Greetd::connect(wake);
        let (ground_tx, ground_rx) = std::sync::mpsc::channel();
        let wrap = "/etc/hyprshell-greeter/session.sh";
        let mut g = Greeter {
            preview: greetd.is_none(),
            greetd,
            hostname: std::fs::read_to_string("/etc/hostname").unwrap_or_default().trim().to_string(),
            users: read_users(&env_or("HYPRSHELL_GREETER_PASSWD", "/etc/passwd")),
            user_ix: 0,
            sessions: read_sessions(&env_or("HYPRSHELL_GREETER_SESSIONS", "/usr/share/wayland-sessions:/usr/local/share/wayland-sessions")),
            session_ix: 0,
            users_dir: env_or("HYPRSHELL_GREETER_USERS", "/var/lib/hyprshell-greeter/users"),
            state_file: env_or("HYPRSHELL_GREETER_STATE", "/var/cache/hyprshell-greeter/state.json"),
            icon_dir: env_or("HYPRSHELL_GREETER_ICONS", "/var/lib/AccountsService/icons"),
            // Through session.sh when it's there and is the one install.sh
            // writes: a clean console between the greeter and the session.
            session_wrap: std::fs::read_to_string(wrap).ok().filter(|t| t.contains("exec \"$@\"")).map(|_| wrap.to_string()),
            look: theme::load(),
            ground: crate::ground::spec(&theme::raw(), false),
            picture: None,
            screens_json: Value::Null,
            pointer_screen: String::new(),
            entered: String::new(),
            status: String::new(),
            failed: false,
            busy: false,
            busy_since: None,
            prompt: String::new(),
            prompt_echo: false,
            password_sent: false,
            face_enabled: crate::testhooks::face().unwrap_or_else(|| std::fs::read_to_string("/etc/pam.d/greetd").map(|t| t.contains("pam_howdy") || t.contains("pam_hyprshell_face")).unwrap_or(false)),
            info: String::new(),
            face_started: false,
            awaiting_password: false,
            pending: false,
            face_found: false,
            face_missed: false,
            face_missed_at: None,
            let_go: false,
            after_cancel: None,
            face_soon: None,
            launch_at: None,
            leaving: None,
            starting: false,
            shake: Spring::new(0.0),
            face_show: Spring::new(0.0),
            face_close: Spring::new(0.0),
            face_tick: Spring::new(0.0),
            face_dim: Spring::new(0.0),
            started: Instant::now(),
            screens: vec![],
            grounds: vec![],
            ground_tx,
            ground_rx,
            wake: wake.try_clone().expect("wake"),
            actions: Default::default(),
            quit: false,
        };
        g.restore();
        g.dress();
        g.face_soon = Some(Instant::now());
        g
    }

    fn user(&self) -> Option<&User> {
        self.users.get(self.user_ix.min(self.users.len().saturating_sub(1)))
    }
    fn session(&self) -> Option<&Session> {
        self.sessions.get(self.session_ix.min(self.sessions.len().saturating_sub(1)))
    }
    fn user_dir(&self) -> String {
        self.user().map(|u| format!("{}/{}", self.users_dir, u.name)).unwrap_or_default()
    }

    /// The user and session from last time if they still exist; else the
    /// first person, and Hyprland if it's installed.
    fn restore(&mut self) {
        let r: Value = std::fs::read_to_string(&self.state_file).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null);
        if let Some(i) = self.users.iter().position(|u| r["user"] == u.name.as_str()) {
            self.user_ix = i;
        }
        let si = self
            .sessions
            .iter()
            .position(|s| r["session"] == s.id.as_str())
            .or_else(|| self.sessions.iter().position(|s| s.id == "hyprland"))
            .or_else(|| self.sessions.iter().position(|s| s.id.to_lowercase().contains("hyprland")));
        if let Some(i) = si {
            self.session_ix = i;
        }
    }
    fn remember(&self) {
        let (Some(u), Some(s)) = (self.user(), self.session()) else { return };
        let _ = std::fs::write(&self.state_file, format!("{}\n", json!({ "user": u.name, "session": s.id })));
    }

    /// Dressed as the person picked: their theme, wallpaper, picture and
    /// screens as their shell last saved them; without a copy, the
    /// greeter's own look (install.sh --theme).
    fn dress(&mut self) {
        let dir = self.user_dir();
        let mine = Path::new(&dir).join("theme.json");
        theme::set_path(if !dir.is_empty() && mine.is_file() { Some(mine) } else { None });
        self.look = theme::load();
        self.ground = crate::ground::spec(&theme::raw(), self.look.dark);
        // Their picture as their shell keeps it, then the system's.
        self.picture = self.user().and_then(|u| {
            [format!("{dir}/face"), format!("{}/{}", self.icon_dir, u.name)].iter().find_map(|p| crate::art::file(Path::new(p), 160)).map(Image::from_rgba8)
        });
        self.screens_json = std::fs::read_to_string(format!("{dir}/screens.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null);
        self.grounds.clear();
        for s in &mut self.screens {
            s.ground_for = None;
            s.themed = false;
        }
        self.apply_look(&dir);
    }

    /// GreeterLook.apply: the person's screens and pointer, handed to the
    /// greeter's Hyprland, and kept as look.lua for its next start.
    fn apply_look(&self, dir: &str) {
        let lua = monitor_lua(&self.screens_json);
        let cursor: Value = std::fs::read_to_string(format!("{dir}/cursor.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null);
        let name = cursor["theme"].as_str().unwrap_or("");
        let theme = if !name.is_empty() && name.len() <= 64 && name.chars().all(|c| c.is_ascii_alphanumeric() || " _.+-".contains(c)) { name.to_string() } else { String::new() };
        let size = num(&cursor["size"], 8.0, 256.0).unwrap_or(24.0).round() as i64;
        if (lua.is_empty() && theme.is_empty()) || self.preview {
            return;
        }
        let cache = Path::new(&self.state_file).parent().map(|p| p.display().to_string()).unwrap_or_default();
        let mut boot = lua.replace(") hl.monitor", ")\nhl.monitor");
        if !theme.is_empty() {
            for v in ["XCURSOR_THEME", "HYPRCURSOR_THEME"] {
                boot += &format!("\nhl.env(\"{v}\", \"{theme}\")");
            }
        }
        for v in ["XCURSOR_SIZE", "HYPRCURSOR_SIZE"] {
            boot += &format!("\nhl.env(\"{v}\", \"{size}\")");
        }
        let script = r#"
            icons=$1 theme=$2 size=$3 src=$4 lua=$5 boot=$6 bootlua=$7
            [ -n "$lua" ] && hyprctl eval "$lua" >/dev/null 2>&1
            printf '%s' "$bootlua" > "$boot.tmp" && mv -f "$boot.tmp" "$boot"
            if [ -n "$theme" ]; then
                mkdir -p "$icons"
                if [ -d "$src" ]; then ln -sfn "$src" "$icons/$theme"
                elif [ -L "$icons/$theme" ]; then rm -f "$icons/$theme"; fi
                hyprctl setcursor "$theme" "$size" >/dev/null 2>&1
            fi
            exit 0"#;
        let _ = std::process::Command::new("sh")
            .args([
                "-c",
                script,
                "greeter-look",
                &format!("{cache}/home/.local/share/icons"),
                &theme,
                &size.to_string(),
                &format!("{dir}/cursor"),
                &lua,
                &format!("{cache}/look.lua"),
                &format!("-- Written by the greeter for its next start.\n{boot}\n"),
            ])
            .spawn();
    }

    // ── greetd ──────────────────────────────────────────────────────────
    fn tell(&self, r: Req) {
        if let Some(g) = &self.greetd {
            g.send(r);
        }
    }

    fn can_retry_face(&self) -> bool {
        self.face_enabled && !self.preview && !self.busy && !self.pending && !self.password_sent && (!self.face_started || self.awaiting_password)
    }
    fn face_state(&self) -> &'static str {
        if !self.face_enabled || self.preview {
            ""
        } else if self.face_found {
            "found"
        } else if self.face_started && !self.awaiting_password && !self.password_sent && !self.pending {
            "looking"
        } else if self.face_missed || self.awaiting_password {
            "failed"
        } else {
            ""
        }
    }
    fn begin_face(&mut self) {
        if !self.face_enabled || self.preview || self.face_started || self.busy {
            return;
        }
        let Some(name) = self.user().map(|u| u.name.clone()) else { return };
        if self.session().is_none() {
            return;
        }
        self.face_started = true;
        self.face_found = false;
        self.face_missed = false;
        self.awaiting_password = false;
        self.pending = false;
        self.password_sent = false;
        self.info = "Looking for you…".into();
        self.tell(Req::Create(name));
    }
    fn retry_face(&mut self) {
        if !self.can_retry_face() {
            return;
        }
        if self.face_started {
            // The waiting attempt goes first; a new one a moment later.
            self.let_go = true;
            self.tell(Req::Cancel);
            self.face_done();
            self.face_missed = false;
            self.after_cancel = Some(Instant::now() + Duration::from_millis(250));
            return;
        }
        self.begin_face();
    }
    fn face_done(&mut self) {
        self.face_started = false;
        self.awaiting_password = false;
        self.pending = false;
    }

    fn reset(&mut self) {
        if self.face_started || self.busy || self.password_sent {
            self.tell(Req::Cancel);
        }
        self.entered.clear();
        self.status.clear();
        self.failed = false;
        self.busy = false;
        self.prompt.clear();
        self.password_sent = false;
        self.face_done();
        self.info.clear();
        self.face_found = false;
        self.face_missed = false;
    }

    fn pick_user(&mut self, i: usize) {
        if i == self.user_ix {
            return;
        }
        self.reset();
        self.user_ix = i;
        self.dress();
        self.face_soon = Some(Instant::now());
    }

    fn rejected(&mut self) {
        self.shake.kick(480.0, 0.0, 300.0, 2.2, &self.look.motion);
    }

    fn submit(&mut self) {
        if self.busy || self.user().is_none() || self.session().is_none() || self.leaving.is_some() {
            return;
        }
        if !self.prompt.is_empty() {
            // Answering the second question.
            let answer = std::mem::take(&mut self.entered);
            self.prompt.clear();
            self.busy = true;
            self.tell(Req::Respond(Some(answer)));
            return;
        }
        // Enter on an empty field looks for your face again.
        if self.entered.is_empty() {
            self.retry_face();
            return;
        }
        if self.preview {
            self.failed = true;
            self.status = "Preview — greetd isn't running, so nothing can log in".into();
            self.rejected();
            return;
        }
        self.failed = false;
        self.status.clear();
        self.busy = true;
        // The face attempt's session is already open: answer PAM now if it
        // has asked, or as soon as it does.
        if self.face_started {
            if self.awaiting_password {
                self.awaiting_password = false;
                self.password_sent = true;
                self.info.clear();
                let e = self.entered.clone();
                self.tell(Req::Respond(Some(e)));
            } else {
                self.pending = true;
                self.info = "Trying your face first…".into();
            }
            return;
        }
        self.password_sent = false;
        let name = self.user().map(|u| u.name.clone()).unwrap_or_default();
        self.tell(Req::Create(name));
    }

    fn event(&mut self, e: Event) {
        match e {
            Event::Ask { msg, echo } => {
                // The first hidden question is the password already typed.
                if !self.password_sent && !echo {
                    if self.face_started {
                        self.face_missed = true;
                        self.face_missed_at = Some(Instant::now());
                    }
                    if self.face_started && !self.pending {
                        self.awaiting_password = true;
                        self.info = "Face not recognised · type your password".into();
                        return;
                    }
                    self.pending = false;
                    self.password_sent = true;
                    self.info.clear();
                    let e = self.entered.clone();
                    self.tell(Req::Respond(Some(e)));
                    return;
                }
                self.prompt = if msg.trim().is_empty() { "Answer".into() } else { msg.trim().to_string() };
                self.prompt_echo = echo;
                self.entered.clear();
                self.busy = false;
            }
            Event::Info { msg, error } => {
                // What the camera sees, from pam_hyprshell_face.
                if let Some(hint) = msg.strip_prefix('\u{200b}') {
                    if self.face_started && !self.password_sent {
                        self.info = if hint.is_empty() { "Looking for you…".into() } else { hint.to_string() };
                    }
                    return;
                }
                let facey = ["face", "howdy", "timeout", "camera", "recogni", "frame", "infrared"].iter().any(|k| msg.to_lowercase().contains(k));
                if self.face_started && !self.password_sent && (!error || facey) {
                    return;
                }
                self.status = msg.trim().to_string();
                self.failed = error;
            }
            Event::Failed => {
                if self.let_go {
                    return;
                }
                let facing = self.face_started;
                self.face_done();
                self.info.clear();
                self.busy = false;
                self.failed = true;
                self.entered.clear();
                self.prompt.clear();
                self.status = "Wrong password".into();
                self.password_sent = false;
                self.rejected();
                // Look again while the password is typed again.
                if facing {
                    self.face_soon = Some(Instant::now() + Duration::from_millis(50));
                }
            }
            Event::Error(m) => {
                // A session that wouldn't start: the card comes back to say so.
                self.leaving = None;
                self.starting = false;
                if self.let_go {
                    return;
                }
                self.face_done();
                self.info.clear();
                self.busy = false;
                self.failed = true;
                self.prompt.clear();
                self.password_sent = false;
                self.status = if m.is_empty() { "Login failed".into() } else { m };
                self.rejected();
            }
            Event::Ready => {
                // In by face (no password sent): the tick is drawn first.
                let by_face = self.face_started && !self.password_sent;
                self.face_done();
                self.info.clear();
                if by_face {
                    self.face_found = true;
                    self.launch_at = Some(Instant::now() + Duration::from_millis(480));
                } else {
                    self.launch_now();
                }
            }
            Event::Started => self.quit = true,
        }
    }

    /// In: the card and clock lift away and the dim clears, so the last
    /// thing shown is the bare wallpaper; then the session is started.
    fn launch_now(&mut self) {
        self.remember();
        self.failed = false;
        self.leaving = Some(Instant::now() + Duration::from_millis(440));
    }

    fn start_session(&mut self) {
        let Some(s) = self.session().cloned() else { return };
        let names = {
            let d = if s.desktop_names.is_empty() { s.id.clone() } else { s.desktop_names.clone() };
            d.trim_end_matches(';').replace(';', ":")
        };
        let env = vec!["XDG_SESSION_TYPE=wayland".to_string(), format!("XDG_SESSION_DESKTOP={}", s.id), format!("XDG_CURRENT_DESKTOP={names}")];
        // Plain words only: greetd joins them with spaces for /bin/sh.
        let cmd = match &self.session_wrap {
            Some(w) => [vec!["/bin/sh".to_string(), w.clone()], s.command.clone()].concat(),
            None => s.command.clone(),
        };
        self.starting = true;
        self.tell(Req::Start(cmd, env));
    }

    fn power(&mut self, action: &str) {
        if self.preview {
            self.status = format!("Preview — {action} is not run");
            return;
        }
        let _ = std::process::Command::new("systemctl").arg(action).spawn();
    }

    // ── each frame ──────────────────────────────────────────────────────
    /// The animated wallpaper behind the login screen: a surface behind each of its surfaces, drawn
    /// on by the card, and the screen's own picture put away. Where there is no card to be had the
    /// still wallpaper stays, as it was.
    fn sync_wall(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, gpu: &mut Option<crate::gpuwall::Gpu>, off: &mut bool, display: usize) {
        let raw = theme::raw();
        if !crate::anim::wanted(&raw) || *off || display == 0 {
            return;
        }
        if gpu.is_none() {
            match crate::gpuwall::Gpu::new(display as *mut std::ffi::c_void) {
                Ok(g) => *gpu = Some(g),
                Err(e) => {
                    eprintln!("hyprshell-greeter: the animated wallpaper isn't available here ({e})");
                    *off = true;
                    return;
                }
            }
        }
        let Some(g) = gpu.as_mut() else { return };
        let mons = crate::hypr::json("j/monitors");
        let tint = crate::anim::tint(&raw, self.look.dark);
        let v3 = |c: &theme::Rgba| [c.0 as f32 / 255.0, c.1 as f32 / 255.0, c.2 as f32 / 255.0];
        let mut list = Vec::new();
        for s in &self.screens {
            let Some((oid, (w, h))) = shell.backdrop_for(qh, s.id) else { continue };
            let scale = shell.surfaces.get(s.id).and_then(|x| x.as_ref()).map(|x| x.scale as f32).unwrap_or(1.0);
            let m = mons.as_array().and_then(|a| a.iter().find(|m| m["name"] == s.name.as_str()));
            let origin = m.map(|m| (m["x"].as_f64().unwrap_or(0.0) as f32, m["y"].as_f64().unwrap_or(0.0) as f32)).unwrap_or((0.0, 0.0));
            list.push((crate::anim::screen_for(&raw, self.look.dark, tint, v3(&self.look.accent), v3(&self.look.ink), (s.id, w, h, scale, origin)), oid));
        }
        let live = !list.is_empty();
        g.set_outputs(1, list);
        for s in &self.screens {
            s.view.set_live(live);
        }
    }

    fn step(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, dt: f64) {
        let now = Instant::now();
        let m = self.look.motion;

        // A window on every screen; the card on one.
        let outs = shell.all_outputs();
        self.screens.retain(|s| {
            let keep = outs.contains(&s.output);
            if !keep {
                shell.remove(s.id);
            }
            keep
        });
        for o in &outs {
            if self.screens.iter().any(|s| &s.output == o) {
                continue;
            }
            let name = shell.output_name(o);
            let Ok(view) = LockView::new() else { continue };
            let Some(adapter) = crate::platform::take_adapter() else { continue };
            let id = shell.add_window(qh, adapter, Some(o), &Placement {
                namespace: "hyprshell-greeter",
                layer: Layer::Overlay,
                anchor: Anchor::all(),
                width: 0,
                height: 0,
                exclusive: -1,
                keyboard: KeyboardInteractivity::None,
            });
            self.wire(&view, &name);
            self.screens.push(Screen { output: o.clone(), name, view, id, ground_for: None, primary: false, themed: false });
        }
        let primary = self.primary_name(shell);
        for s in &mut self.screens {
            let want = s.name == primary;
            if want != s.primary {
                s.primary = want;
                // The keyboard goes with the card: one surface can hold it.
                shell.set_keyboard(s.id, if want { KeyboardInteractivity::Exclusive } else { KeyboardInteractivity::None });
            }
        }

        // What the screens asked for.
        let acts: Vec<Act> = std::mem::take(&mut *self.actions.borrow_mut());
        for a in acts {
            match a {
                Act::Typed(t) => {
                    self.entered = t;
                    self.failed = false;
                    self.status.clear();
                }
                Act::Submit => self.submit(),
                Act::Escape => {
                    if self.entered.is_empty() && self.preview {
                        self.quit = true;
                    }
                    self.entered.clear();
                    self.status.clear();
                }
                Act::Power(p) => self.power(&p),
                Act::RetryFace => self.retry_face(),
                Act::Woke => {
                    if self.can_retry_face() && self.entered.is_empty() && !self.face_found && self.face_missed && self.face_missed_at.is_some_and(|t| now - t > Duration::from_secs(4)) {
                        self.retry_face();
                    }
                }
                Act::StepUser(d) => {
                    let n = self.users.len() as i32;
                    if n > 1 {
                        self.pick_user(((self.user_ix as i32 + d).rem_euclid(n)) as usize);
                    }
                }
                Act::StepSession(d) => {
                    let n = self.sessions.len() as i32;
                    if n > 1 {
                        self.session_ix = ((self.session_ix as i32 + d).rem_euclid(n)) as usize;
                    }
                }
                Act::Claim(name) => self.pointer_screen = name,
            }
        }

        // greetd.
        let evs: Vec<Event> = self.greetd.as_ref().map(|g| g.rx.try_iter().collect()).unwrap_or_default();
        for e in evs {
            self.event(e);
        }
        if self.after_cancel.is_some_and(|t| now >= t) {
            self.after_cancel = None;
            self.let_go = false;
            self.begin_face();
        }
        if self.face_soon.is_some_and(|t| now >= t) {
            self.face_soon = None;
            self.begin_face();
        }
        // Never stuck checking: after twenty seconds the attempt is called
        // off and the field takes keys again.
        match (self.busy, self.busy_since) {
            (true, None) => self.busy_since = Some(now),
            (false, Some(_)) => self.busy_since = None,
            (true, Some(t)) if now - t > Duration::from_secs(20) => {
                self.tell(Req::Cancel);
                self.busy = false;
                self.busy_since = None;
                self.failed = true;
                self.prompt.clear();
                self.password_sent = false;
                self.face_done();
                self.info.clear();
                self.entered.clear();
                self.status = "That took too long. Try again.".into();
                self.rejected();
            }
            _ => {}
        }
        if self.launch_at.is_some_and(|t| now >= t) {
            self.launch_at = None;
            self.launch_now();
        }
        if self.leaving.is_some_and(|t| now >= t) && !self.starting {
            self.start_session();
        }

        // The springs.
        let fs = self.face_state();
        self.shake.step(dt, &m);
        self.face_show.go(if fs.is_empty() { 0.0 } else { 1.0 }, 420.0, 0.5, &m);
        self.face_close.go(if fs == "found" { 1.0 } else { 0.0 }, 460.0, 0.4, &m);
        self.face_tick.go(if fs == "found" { 1.0 } else { 0.0 }, 560.0, 0.0, &m);
        self.face_dim.go(if fs == "failed" { 1.0 } else { 0.0 }, 360.0, 0.0, &m);
        for s in [&mut self.face_show, &mut self.face_close, &mut self.face_tick, &mut self.face_dim] {
            s.step(dt, &m);
        }
        while let Ok((name, w, h, full, frost, vivid)) = self.ground_rx.try_recv() {
            self.grounds.retain(|x| x.0 != name);
            self.grounds.push((name, w, h, Image::from_rgba8(full), Image::from_rgba8(frost), vivid));
        }
        self.publish(shell);
    }

    /// Which screen has the card: wherever the pointer was last moved or
    /// clicked; else the main display of the person's Settings; else an
    /// external monitor over the laptop's own panel, the biggest.
    fn primary_name(&self, shell: &wl::Shell) -> String {
        let names: Vec<String> = self.screens.iter().map(|s| s.name.clone()).collect();
        if names.contains(&self.pointer_screen) {
            return self.pointer_screen.clone();
        }
        let saved = self.screens_json.as_array().into_iter().flatten().find(|x| x["main"] == true).and_then(|x| x["name"].as_str()).unwrap_or("");
        if names.iter().any(|n| n == saved) {
            return saved.to_string();
        }
        let internal = |n: &str| ["eDP", "LVDS", "DSI"].iter().any(|p| n.to_uppercase().starts_with(&p.to_uppercase()));
        let outside: Vec<&Screen> = self.screens.iter().filter(|s| !internal(&s.name)).collect();
        let pool: Vec<&Screen> = if outside.is_empty() { self.screens.iter().collect() } else { outside };
        pool.into_iter()
            .max_by_key(|s| {
                let (w, h) = shell.output_logical(&s.output);
                w as i64 * h as i64
            })
            .map(|s| s.name.clone())
            .unwrap_or_default()
    }

    fn wire(&self, v: &LockView, name: &str) {
        let a = self.actions.clone();
        v.on_edited(move |t| a.borrow_mut().push(Act::Typed(t.to_string())));
        let a = self.actions.clone();
        v.on_submit(move || a.borrow_mut().push(Act::Submit));
        let a = self.actions.clone();
        v.on_escape(move || a.borrow_mut().push(Act::Escape));
        let a = self.actions.clone();
        v.on_power(move |p| a.borrow_mut().push(Act::Power(p.to_string())));
        let a = self.actions.clone();
        v.on_retry_face(move || a.borrow_mut().push(Act::RetryFace));
        let a = self.actions.clone();
        v.on_woke(move || a.borrow_mut().push(Act::Woke));
        let a = self.actions.clone();
        v.on_step_user(move |d| a.borrow_mut().push(Act::StepUser(d)));
        let a = self.actions.clone();
        v.on_step_session(move |d| a.borrow_mut().push(Act::StepSession(d)));
        let (a, n) = (self.actions.clone(), name.to_string());
        v.on_claimed(move || a.borrow_mut().push(Act::Claim(n.clone())));
    }

    fn publish(&mut self, shell: &wl::Shell) {
        let look = &self.look;
        let now = chrono_now();
        let clock = if look.clock24 { format!("{:02}:{:02}", now.hour, now.min) } else { format!("{}:{:02}", if now.hour % 12 == 0 { 12 } else { now.hour % 12 }, now.min) };
        let date = format!("{}, {} {}", now.weekday, now.day, now.month).to_uppercase();
        let ampm = if look.clock24 { String::new() } else if now.hour < 12 { "AM".into() } else { "PM".into() };
        let fs = self.face_state();
        let t = self.started.elapsed().as_secs_f64();
        let looking = fs == "looking" && look.motion.speed > 0.0;
        let sweep = if looking { (t % 1.6) / 1.6 * 1.4 - 0.2 } else { -1.0 };
        let turn = if looking { (t % 9.0) / 9.0 * std::f64::consts::TAU } else { 0.0 };
        let status = if !self.status.is_empty() { self.status.clone() } else if fs.is_empty() { self.info.clone() } else { String::new() };
        let user = self.user().cloned();
        let display = user.as_ref().map(|u| u.display.clone()).unwrap_or_else(|| if self.users.is_empty() { "No users found".into() } else { String::new() });
        let session = self.session().map(|s| s.name.clone()).unwrap_or_default();
        let corner = format!("{}{}", self.hostname, if self.preview { "  ·  preview" } else { "" });
        let face_first = matches!(fs, "looking" | "found") && self.prompt.is_empty();
        let can_retry = fs == "failed" && self.can_retry_face();
        let mut todo = vec![];
        for s in &mut self.screens {
            let v = &s.view;
            let us = look.screen_scale(&s.name);
            if !s.themed {
                s.themed = true;
                theme_into!(v, look, us);
            }
            if let Some(sf) = shell.surfaces.get(s.id).and_then(|x| x.as_ref()) {
                let (pw, ph) = ((sf.width as f64 * sf.scale).round() as u32, (sf.height as f64 * sf.scale).round() as u32);
                if pw > 0 && ph > 0 && s.ground_for != Some((pw, ph)) {
                    s.ground_for = Some((pw, ph));
                    todo.push((s.name.clone(), pw, ph));
                }
                if s.primary && self.face_show.value > 0.01 {
                    let vivid = self.grounds.iter().find(|g| g.0 == s.name).is_some_and(|g| g.5);
                    let ink = if vivid { (255, 255, 255) } else { rgb(look.ink) };
                    let px = (58.0 * us as f64 * sf.scale).round().max(16.0) as u32;
                    v.set_face(face_glyph(px, fs, ink, rgb(look.accent), sweep, turn, self.face_close.value, self.face_tick.value, self.face_dim.value));
                }
            }
            if let Some(g) = self.grounds.iter().find(|g| g.0 == s.name) {
                if v.get_vivid() != g.5 || v.get_scrim().size().height == 0 {
                    v.set_scrim(scrim(g.5));
                }
                v.set_ground(g.3.clone());
                v.set_frost(g.4.clone());
                v.set_vivid(g.5);
            }
            v.set_primary(s.primary);
            v.set_greeter(true);
            v.set_corner_text(corner.clone().into());
            v.set_subtitle(SharedString::new());
            v.set_ground_colour(look.panel.slint().with_alpha(1.0));
            v.set_date(date.clone().into());
            v.set_time(clock.clone().into());
            v.set_ampm(ampm.clone().into());
            v.set_user_name(display.clone().into());
            v.set_initial(display.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default().into());
            v.set_has_picture(self.picture.is_some());
            if let Some(p) = &self.picture {
                v.set_picture(p.clone());
            }
            v.set_can_step_user(self.users.len() > 1);
            v.set_session_name(session.clone().into());
            v.set_can_step_session(self.sessions.len() > 1);
            v.set_prompt(self.prompt.clone().into());
            v.set_prompt_echo(self.prompt_echo);
            if v.get_entered().as_str() != self.entered {
                v.set_entered(SharedString::from(self.entered.as_str()));
            }
            v.set_status_text(status.clone().into());
            v.set_failed(self.failed);
            v.set_busy(self.busy);
            v.set_leaving(self.leaving.is_some());
            v.set_face_first(face_first);
            v.set_face_state(if self.face_show.value > 0.01 || !fs.is_empty() { fs.into() } else { SharedString::new() });
            v.set_can_retry_face(can_retry);
            v.set_shake(if s.primary { self.shake.value as f32 * 0.04 * 26.0 } else { 0.0 });
            v.set_glyphs(glyph_set());
        }
        for (name, pw, ph) in todo {
            let (tx, spec) = (self.ground_tx.clone(), self.ground.clone());
            let mut wake = self.wake.try_clone().expect("wake");
            let mut raw = theme::raw();
            raw["wallpaper"] = Value::String(String::new());
            let fallback = crate::ground::spec(&raw, look.dark);
            std::thread::spawn(move || {
                let (px, vivid) = match crate::ground::draw(&spec, pw, ph) {
                    Some(px) => (px, matches!(spec, crate::ground::Spec::Picture(_))),
                    None => (crate::ground::draw(&fallback, pw, ph).unwrap_or_default(), false),
                };
                if px.len() >= (pw * ph * 4) as usize {
                    let (full, frost) = images(&px, pw, ph);
                    let _ = tx.send((name, pw, ph, full, frost, vivid));
                    let _ = std::io::Write::write_all(&mut wake, b"!");
                }
            });
        }
    }

    fn busy(&self) -> bool {
        self.shake.moving
            || self.face_show.moving
            || self.face_close.moving
            || self.face_tick.moving
            || self.face_dim.moving
            || self.face_state() == "looking"
            || self.leaving.is_some()
            || self.launch_at.is_some()
            || self.after_cancel.is_some()
            || self.face_soon.is_some()
            || self.busy
    }
}

/// `hyprshell-rs --greeter`: the login screen, until a session is started
/// (or, in a preview, Escape).
pub fn run() {
    use std::io::Read;
    use std::os::fd::AsRawFd;
    use wayland_client::globals::registry_queue_init;
    use wayland_client::Connection;

    slint::platform::set_platform(Box::new(crate::platform::ShellPlatform)).expect("the platform is set once");
    let conn = Connection::connect_to_env().unwrap_or_else(|e| {
        eprintln!("hyprshell-greeter: no Wayland display ({e})");
        std::process::exit(1);
    });
    let (globals, mut queue) = registry_queue_init::<wl::Shell>(&conn).expect("the registry");
    let qh = queue.handle();
    let mut shell = wl::Shell::new(&globals, &qh).unwrap_or_else(|e| {
        eprintln!("hyprshell-greeter: {e}");
        std::process::exit(1);
    });
    queue.roundtrip(&mut shell).expect("roundtrip");
    queue.roundtrip(&mut shell).expect("roundtrip");
    let (mut wake_rx, wake_tx) = UnixStream::pair().expect("a socket pair");
    wake_rx.set_nonblocking(true).ok();

    let mut g = Greeter::new(&wake_tx);
    // The card, for the animated wallpaper, if the theme has one and there is a card.
    let display = conn.backend().display_ptr() as usize;
    let mut gpu: Option<crate::gpuwall::Gpu> = None;
    let mut gpu_off = false;
    if g.preview {
        eprintln!("hyprshell-greeter: no GREETD_SOCK — a preview; Escape on an empty field leaves");
    }
    let mut last = Instant::now();
    loop {
        let _ = conn.flush();
        let repeat = shell.repeat_keys();
        let mut timeout = if shell.animating() || g.busy() {
            Duration::from_millis(16)
        } else {
            slint::platform::duration_until_next_timer_update().unwrap_or(Duration::from_secs(1)).min(Duration::from_secs(1))
        };
        if let Some(r) = repeat {
            timeout = timeout.min(r);
        }
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
            break;
        }
        let mut sink = [0u8; 256];
        while wake_rx.read(&mut sink).map(|n| n > 0).unwrap_or(false) {}
        let dt = last.elapsed().as_secs_f64();
        last = Instant::now();
        g.step(&mut shell, &qh, dt);
        g.sync_wall(&mut shell, &qh, &mut gpu, &mut gpu_off, display);
        if let Some(card) = gpu.as_mut() {
            if !card.frame(&|group, key, child| shell.draws_on(group, key, child)).is_empty() {
                eprintln!("hyprshell-greeter: the card couldn't draw the wallpaper");
                gpu_off = true;
                card.set_outputs(1, Vec::new());
                for s in &g.screens {
                    s.view.set_live(false);
                }
            }
        }
        slint::platform::update_timers_and_animations();
        // What a key or click asked for just now, not at the next wake.
        if !g.actions.borrow().is_empty() {
            g.step(&mut shell, &qh, 0.0);
        }
        shell.draw();
        if g.quit || shell.closed {
            break;
        }
    }
    let _ = conn.flush();
    // Out at once: greetd's Hyprland ends as soon as this does, and the
    // session waits on it; there's nothing here to tidy.
    std::process::exit(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exec_lines() {
        assert_eq!(split_exec("Hyprland"), vec!["Hyprland"]);
        assert_eq!(split_exec("/usr/bin/startplasma-wayland %U --x"), vec!["/usr/bin/startplasma-wayland", "--x"]);
        assert_eq!(split_exec(r#"sh -c "a b" "" end"#), vec!["sh", "-c", "a b", "", "end"]);
        assert_eq!(split_exec(r#""quoted \" mark""#), vec![r#"quoted " mark"#]);
    }

    #[test]
    fn sessions_and_users() {
        let d = std::env::temp_dir().join(format!("hyprshell-greeter-test-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("b.desktop"), "[Desktop Entry]\nName=Zed\nName[de]=Zett\nExec=zed %f\n\n[Desktop Action X]\nName=No\nExec=no\n").unwrap();
        std::fs::write(d.join("a.desktop"), "[Desktop Entry]\nName=Alpha\nExec=alpha\nDesktopNames=A;B;\n").unwrap();
        std::fs::write(d.join("h.desktop"), "[Desktop Entry]\nName=Hidden\nExec=h\nNoDisplay=true\n").unwrap();
        std::fs::write(d.join("noexec.desktop"), "[Desktop Entry]\nName=Nothing\n").unwrap();
        let s = read_sessions(d.to_str().unwrap());
        assert_eq!(s.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), vec!["Alpha", "Zed"]);
        assert_eq!(s[1].command, vec!["zed"]);
        assert_eq!(s[0].desktop_names, "A;B;");
        let p = d.join("passwd");
        std::fs::write(&p, "root:x:0:0::/root:/bin/bash\nb:x:1001:1::/h:/bin/zsh\na:x:1000:1:Full Name,room:/h:/bin/bash\nn:x:1002:1::/:/usr/sbin/nologin\nbig:x:65534:1::/:/bin/sh\n").unwrap();
        let u = read_users(p.to_str().unwrap());
        assert_eq!(u.iter().map(|u| (u.name.as_str(), u.display.as_str())).collect::<Vec<_>>(), vec![("a", "Full Name"), ("b", "b")]);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn screens_checked_before_use() {
        let v: Value = serde_json::from_str(
            r#"[{"name":"eDP-1","width":2560,"height":1600,"refreshRate":120,"x":0,"y":0,"scale":1.6667},
                {"name":"DP-1\"; os.execute('x')","width":1920,"height":1080,"refreshRate":60,"scale":1},
                {"name":"HDMI-A-1","width":1920,"height":1080,"refreshRate":60,"scale":99}]"#,
        )
        .unwrap();
        let lua = monitor_lua(&v);
        assert!(lua.contains(r#"output = "eDP-1", mode = "2560x1600@120", position = "0x0", scale = 1.6667"#));
        assert!(!lua.contains("os.execute"));
        assert!(!lua.contains("HDMI-A-1"));
    }
}
