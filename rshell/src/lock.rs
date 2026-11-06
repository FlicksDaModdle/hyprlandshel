//! The lock screen (modules/lock/Lock.qml, LockAuth.qml, Arrival.qml).
//!
//! A Wayland session lock: while it's up the compositor shows nothing
//! behind it and lets nothing else take input, and the only way past it is
//! your password, checked by PAM (`login`, there on every distribution), or
//! your face, when face unlock is set up (/etc/pam.d/hyprshell-lock, which
//! Settings → Login screen writes).
//!
//! Every output gets its own surface (ui/lock.slint's LockView), all
//! sharing one password: what's typed lands in whichever surface has the
//! keyboard and every screen's field shows it.
//!
//! The face is looked for the moment the screen locks, beside the password:
//! pressing Enter calls it off and checks what was typed; Enter on an empty
//! field looks again; and coming back to the machine (the pointer moving) a
//! while after the last look ended looks again by itself.
//!
//! A lock asked for just as the last one is let go can be turned down by
//! the compositor: it's then let go and asked for again until it takes.

use crate::pam::{Attempt, PAM_MAXTRIES};
use crate::spring::{Motion, Spring};
use crate::wl::{self, LockState};
use crate::{LockGlyphs, LockView};
use slint::{Image, Rgba8Pixel, SharedPixelBuffer, SharedString};
use std::time::{Duration, Instant};
use wayland_client::protocol::wl_output::WlOutput;
use wayland_client::QueueHandle;

/// One output's lock surface.
struct Screen {
    output: WlOutput,
    name: String,
    view: LockView,
    id: usize,
    /// The wallpaper drawn for it, at its pixel size (being drawn: None).
    ground_for: Option<(u32, u32)>,
}

/// What the lock screen needs to know of the rest of the shell, each frame.
pub struct World<'a> {
    pub look: &'a crate::theme::Theme,
    pub ground: &'a crate::ground::Spec,
    pub battery: Option<(i32, bool)>,
    pub net_label: String,
    pub net_icon: &'static str,
    pub notes: usize,
}

pub struct Lock {
    /// Locked, as far as the shell is concerned (UiState.locked).
    pub active: bool,
    screens: Vec<Screen>,
    /// Asked of the compositor, and when: it's asked again if it hasn't
    /// said yes in a while, or said no.
    asked: Option<Instant>,
    retry_at: Option<Instant>,

    user: String,
    display: String,
    picture: Option<Image>,

    entered: String,
    status: String,
    failed: bool,
    pam: Option<Attempt>,
    pam_since: Option<Instant>,

    face_enabled: bool,
    face: Option<Attempt>,
    face_state: String,
    info: String,
    face_ended: Option<Instant>,
    /// Found: the tick is drawn, and then the screen goes.
    unlock_at: Option<Instant>,

    /// Let in: the view fades for this long, then the lock goes.
    leaving: Option<Instant>,
    /// After: the wallpaper over the desktop, fading (Arrival.qml).
    arrival: Vec<(crate::Arrival, usize)>,
    arrival_until: Option<Instant>,

    shake: Spring,
    // The face glyph: in and out, the lens closing, the tick, the dimming,
    // its shake; the sweep and turn go by the clock.
    face_show: Spring,
    face_close: Spring,
    face_tick: Spring,
    face_dim: Spring,
    face_shake: Spring,
    started: Instant,

    /// Wallpaper pictures being drawn: (output name, w, h, normal, frost).
    ground_tx: std::sync::mpsc::Sender<(String, u32, u32, Px, Px, bool)>,
    ground_rx: std::sync::mpsc::Receiver<(String, u32, u32, Px, Px, bool)>,
    grounds: Vec<(String, u32, u32, Image, Image, bool)>,
    wake: std::os::unix::net::UnixStream,
    last_clock: String,
    /// The keyboard hasn't reached any screen for a while.
    keyboard_missing: bool,
    /// What a screen's buttons asked for, carried out in step().
    pub actions: std::rc::Rc<std::cell::RefCell<Vec<Act>>>,
}

pub type Px = SharedPixelBuffer<Rgba8Pixel>;

pub enum Act {
    Typed(String),
    Submit,
    Escape,
    Power(String),
    RetryFace,
    Woke,
}

fn user() -> String {
    std::env::var("USER").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| {
        // SAFETY: getpwuid's static record, read at once.
        unsafe {
            let p = libc::getpwuid(libc::getuid());
            if p.is_null() { String::new() } else { std::ffi::CStr::from_ptr((*p).pw_name).to_string_lossy().into_owned() }
        }
    })
}

/// Your name as the greeter shows it: the full name from /etc/passwd, the
/// login name when there is none.
fn full_name(user: &str) -> String {
    std::fs::read_to_string("/etc/passwd")
        .ok()
        .and_then(|t| {
            t.lines().find_map(|l| {
                let f: Vec<&str> = l.split(':').collect();
                (f.first() == Some(&user)).then(|| f.get(4).map(|g| g.split(',').next().unwrap_or("").trim().to_string()).unwrap_or_default())
            })
        })
        .filter(|n| !n.is_empty())
        .unwrap_or_else(|| user.to_string())
}

/// Face unlock is set up: the face-only service is there and readable.
fn face_enabled() -> bool {
    std::fs::read_to_string("/etc/pam.d/hyprshell-lock").map(|t| t.contains("pam_howdy") || t.contains("pam_hyprshell_face")).unwrap_or(false)
}

/// BGRX, as the wallpaper is drawn, into an image; and a blurred, smaller
/// copy for what's frosted (the card, the pills).
pub fn images(bgrx: &[u8], w: u32, h: u32) -> (Px, Px) {
    let mut full = SharedPixelBuffer::<Rgba8Pixel>::new(w, h);
    for (d, s) in full.make_mut_slice().iter_mut().zip(bgrx.chunks_exact(4)) {
        *d = Rgba8Pixel { r: s[2], g: s[1], b: s[0], a: 255 };
    }
    // An eighth of the size, box-blurred three times: about Hyprland's blur
    // behind a panel, once drawn back at full size.
    let (sw, sh) = ((w / 8).max(1), (h / 8).max(1));
    let mut small = vec![[0f32; 3]; (sw * sh) as usize];
    for y in 0..sh {
        for x in 0..sw {
            let mut acc = [0f32; 3];
            let mut n = 0.0;
            for yy in (y * 8)..((y * 8 + 8).min(h)) {
                for xx in (x * 8)..((x * 8 + 8).min(w)) {
                    let i = ((yy * w + xx) * 4) as usize;
                    acc[0] += bgrx[i + 2] as f32;
                    acc[1] += bgrx[i + 1] as f32;
                    acc[2] += bgrx[i] as f32;
                    n += 1.0;
                }
            }
            small[(y * sw + x) as usize] = [acc[0] / n, acc[1] / n, acc[2] / n];
        }
    }
    let r = 3i64;
    for _ in 0..3 {
        let src = small.clone();
        for y in 0..sh as i64 {
            for x in 0..sw as i64 {
                let mut acc = [0f32; 3];
                let mut n = 0.0;
                for dx in -r..=r {
                    let xx = (x + dx).clamp(0, sw as i64 - 1);
                    let p = src[(y * sw as i64 + xx) as usize];
                    acc[0] += p[0];
                    acc[1] += p[1];
                    acc[2] += p[2];
                    n += 1.0;
                }
                small[(y * sw as i64 + x) as usize] = [acc[0] / n, acc[1] / n, acc[2] / n];
            }
        }
        let src = small.clone();
        for y in 0..sh as i64 {
            for x in 0..sw as i64 {
                let mut acc = [0f32; 3];
                let mut n = 0.0;
                for dy in -r..=r {
                    let yy = (y + dy).clamp(0, sh as i64 - 1);
                    let p = src[(yy * sw as i64 + x) as usize];
                    acc[0] += p[0];
                    acc[1] += p[1];
                    acc[2] += p[2];
                    n += 1.0;
                }
                small[(y * sw as i64 + x) as usize] = [acc[0] / n, acc[1] / n, acc[2] / n];
            }
        }
    }
    let mut frost = SharedPixelBuffer::<Rgba8Pixel>::new(sw, sh);
    for (d, s) in frost.make_mut_slice().iter_mut().zip(small.iter()) {
        *d = Rgba8Pixel { r: s[0] as u8, g: s[1] as u8, b: s[2] as u8, a: 255 };
    }
    (full, frost)
}

/// FaceScan.qml's glyph, drawn: a lens of three arcs around a face in dots,
/// the lens turning and a band of light sweeping down while it looks; the
/// lens closing into a ring and a tick when it finds you; dimmed and red
/// when it doesn't.
#[allow(clippy::too_many_arguments)]
pub fn face_glyph(px: u32, state: &str, ink: (u8, u8, u8), accent: (u8, u8, u8), sweep: f64, turn: f64, close: f64, tick: f64, dim: f64) -> Image {
    let s = 100.0;
    let col = match state {
        "found" => accent,
        "failed" => (255, 107, 97),
        _ => ink,
    };
    let c = format!("rgb({},{},{})", col.0, col.1, col.2);
    let lw = 4.5;
    let r = s / 2.0 - lw;
    let gap = (1.0 - close.clamp(0.0, 1.0)) * 0.55;
    let mut svg = format!("<svg xmlns='http://www.w3.org/2000/svg' width='{s}' height='{s}' viewBox='0 0 {s} {s}'>");
    for i in 0..3 {
        let a0 = turn + i as f64 * 2.0 * std::f64::consts::PI / 3.0 + gap / 2.0;
        let a1 = turn + (i + 1) as f64 * 2.0 * std::f64::consts::PI / 3.0 - gap / 2.0;
        let (x0, y0) = (50.0 + r * a0.cos(), 50.0 + r * a0.sin());
        let (x1, y1) = (50.0 + r * a1.cos(), 50.0 + r * a1.sin());
        let large = if a1 - a0 > std::f64::consts::PI { 1 } else { 0 };
        svg += &format!("<path d='M {x0:.2} {y0:.2} A {r} {r} 0 {large} 1 {x1:.2} {y1:.2}' fill='none' stroke='{c}' stroke-width='{lw}' stroke-linecap='round'/>");
    }
    // The lens's glass.
    svg += &format!(
        "<circle cx='50' cy='50' r='{:.2}' fill='none' stroke='{c}' stroke-width='{:.2}' opacity='{:.3}'/>",
        r - lw * 1.6,
        lw * 0.5,
        0.22 * (1.0 - tick)
    );
    // The face, in dots: lit where the sweep passes, dim on a failure,
    // fading as the tick comes.
    let fade = 1.0 - tick;
    if fade > 0.01 {
        let step = 0.075;
        let mut y = 0.2;
        while y <= 0.86 {
            let mut x = 0.2;
            while x <= 0.8 {
                let (hx, hy) = ((x - 0.5) / 0.17, (y - 0.42) / 0.2);
                let head = hx * hx + hy * hy <= 1.0;
                let (sx, sy) = ((x - 0.5) / 0.31, (y - 0.92) / 0.22);
                let shoulders = y > 0.68 && sx * sx + sy * sy <= 1.0;
                if (head || shoulders) && ((x - 0.5f64).hypot(y - 0.5) < 0.36) {
                    let mut a = 0.35;
                    if sweep > -0.5 {
                        let t = (y - sweep) / 0.09;
                        a = 0.28 + 0.72 * (-t * t).exp();
                    } else if dim < 0.01 {
                        a = 0.75;
                    }
                    a *= (1.0 - 0.6 * dim) * fade;
                    svg += &format!("<circle cx='{:.2}' cy='{:.2}' r='2.2' fill='{c}' opacity='{a:.3}'/>", x * s, y * s);
                }
                x += step;
            }
            y += step;
        }
    }
    if tick > 0.01 {
        let (p0, p1, p2) = ((33.0, 52.0), (45.0, 64.0), (68.0, 39.0));
        let l1 = ((p1.0 - p0.0) as f64).hypot(p1.1 - p0.1);
        let l2 = ((p2.0 - p1.0) as f64).hypot(p2.1 - p1.1);
        let mut d = tick.min(1.0) * (l1 + l2);
        let mut path = format!("M {} {} ", p0.0, p0.1);
        if d <= l1 {
            path += &format!("L {:.2} {:.2}", p0.0 + (p1.0 - p0.0) * d / l1, p0.1 + (p1.1 - p0.1) * d / l1);
        } else {
            d -= l1;
            path += &format!("L {} {} L {:.2} {:.2}", p1.0, p1.1, p1.0 + (p2.0 - p1.0) * d / l2, p1.1 + (p2.1 - p1.1) * d / l2);
        }
        svg += &format!("<path d='{path}' fill='none' stroke='{c}' stroke-width='{:.2}' stroke-linecap='round' stroke-linejoin='round'/>", lw * 1.3);
    }
    svg += "</svg>";
    crate::art::bytes(svg.as_bytes(), px).map(Image::from_rgba8).unwrap_or_default()
}

/// LoginView's scrim: a little darker at the top behind the clock, more at
/// the bottom behind the corner line, clear between; stronger over a
/// picture. One pixel wide, to be stretched over the screen.
pub fn scrim(vivid: bool) -> Image {
    let stops: [(f64, f64); 4] = if vivid { [(0.0, 0.34), (0.38, 0.10), (0.72, 0.16), (1.0, 0.52)] } else { [(0.0, 0.04), (0.38, 0.0), (0.72, 0.0), (1.0, 0.07)] };
    let n = 512u32;
    let mut px = SharedPixelBuffer::<Rgba8Pixel>::new(1, n);
    for (i, p) in px.make_mut_slice().iter_mut().enumerate() {
        let t = i as f64 / (n - 1) as f64;
        let k = stops.windows(2).find(|w| t <= w[1].0).unwrap_or(&stops[2..4]);
        let f = ((t - k[0].0) / (k[1].0 - k[0].0)).clamp(0.0, 1.0);
        let a = k[0].1 + (k[1].1 - k[0].1) * f;
        *p = Rgba8Pixel { r: 0, g: 0, b: 0, a: (a * 255.0).round() as u8 };
    }
    Image::from_rgba8(px)
}

/// The view's glyphs.
pub fn glyph_set() -> LockGlyphs {
    let g = crate::glyphs::glyph;
    LockGlyphs {
        lock: g("lock"),
        eye: g("eye"),
        go: g("chevron-right"),
        moon: g("moon"),
        restart: g("rotate-cw"),
        power: g("power"),
        battery: g("battery"),
        bell: g("bell"),
        net: g("wifi"),
        left: g("chevron-left"),
        right: g("chevron-right"),
        monitor: g("monitor"),
        down: g("chevron-down"),
    }
}

pub fn rgb(c: crate::theme::Rgba) -> (u8, u8, u8) {
    (c.0, c.1, c.2)
}

impl Lock {
    pub fn new(wake: &std::os::unix::net::UnixStream) -> Lock {
        let user = user();
        let display = full_name(&user);
        // Your ~/.face, then the picture the greeter shows.
        let home = std::env::var("HOME").unwrap_or_default();
        let picture = [format!("{home}/.face"), format!("/var/lib/AccountsService/icons/{user}")]
            .iter()
            .find_map(|p| crate::art::file(std::path::Path::new(p), 160))
            .map(Image::from_rgba8);
        let (ground_tx, ground_rx) = std::sync::mpsc::channel();
        Lock {
            active: false,
            screens: vec![],
            asked: None,
            retry_at: None,
            user,
            display,
            picture,
            entered: String::new(),
            status: String::new(),
            failed: false,
            pam: None,
            pam_since: None,
            face_enabled: false,
            face: None,
            face_state: String::new(),
            info: String::new(),
            face_ended: None,
            unlock_at: None,
            leaving: None,
            arrival: vec![],
            arrival_until: None,
            shake: Spring::new(0.0),
            face_show: Spring::new(0.0),
            face_close: Spring::new(0.0),
            face_tick: Spring::new(0.0),
            face_dim: Spring::new(0.0),
            face_shake: Spring::new(0.0),
            started: Instant::now(),
            ground_tx,
            ground_rx,
            grounds: vec![],
            wake: wake.try_clone().expect("wake"),
            last_clock: String::new(),
            keyboard_missing: false,
            actions: Default::default(),
        }
    }

    pub fn has_actions(&self) -> bool {
        !self.actions.borrow().is_empty()
    }

    /// Something to draw soon: a frame's time.
    pub fn busy(&self) -> bool {
        self.active
            && (self.shake.moving
                || self.face_show.moving
                || self.face_close.moving
                || self.face_tick.moving
                || self.face_dim.moving
                || self.face_shake.moving
                || self.face_state == "looking"
                || self.leaving.is_some()
                || self.unlock_at.is_some()
                || self.pam.is_some())
            || self.arrival_until.is_some()
    }

    /// Lock, now (the keybind, the power menu, logind's Lock).
    /// False when there's no session lock to be had here (then the caller
    /// locks some other way).
    pub fn lock(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) -> bool {
        if self.active {
            return true;
        }
        if !shell.lock_session(qh) {
            return false;
        }
        self.asked = Some(Instant::now());
        locked_hint(true);
        self.active = true;
        self.leaving = None;
        self.face_enabled = face_enabled();
        self.reset();
        self.retry_face();
        true
    }

    /// The machine going to sleep (true) or back: a look started as it went
    /// has timed out by the time it wakes, so it's let go, and started again
    /// the moment it's back.
    pub fn sleep(&mut self, going: bool) {
        if !self.active {
            return;
        }
        self.stop_face();
        if !going && self.entered.is_empty() && self.pam.is_none() {
            self.face_state.clear();
            self.retry_face();
        }
    }

    /// logind's Unlock: let in, as a password would.
    pub fn release(&mut self, m: &Motion) {
        if self.active && self.leaving.is_none() {
            self.unlock(m);
        }
    }

    fn ask(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>) {
        if shell.lock_session(qh) {
            self.asked = Some(Instant::now());
        } else {
            self.retry_at = Some(Instant::now() + Duration::from_millis(600));
        }
    }

    fn reset(&mut self) {
        self.entered.clear();
        self.status.clear();
        self.failed = false;
    }

    // ── your face ───────────────────────────────────────────────────────
    fn can_retry_face(&self) -> bool {
        self.face_enabled && self.face.is_none() && self.pam.is_none()
    }
    fn retry_face(&mut self) {
        if !self.can_retry_face() {
            return;
        }
        match Attempt::start("hyprshell-lock", &self.user, &self.wake) {
            Some(a) => {
                self.face = Some(a);
                self.info = "Looking for you…".into();
                self.face_state = "looking".into();
            }
            None => {
                self.info.clear();
                self.face_state.clear();
            }
        }
    }
    fn stop_face(&mut self) {
        if let Some(mut f) = self.face.take() {
            f.abort();
        }
    }

    // ── the password ────────────────────────────────────────────────────
    fn submit(&mut self) {
        if self.leaving.is_some() {
            return;
        }
        // Enter on an empty field tries your face again.
        if self.entered.is_empty() {
            self.retry_face();
            return;
        }
        if self.pam.is_some() {
            return;
        }
        if self.face.is_some() {
            self.stop_face();
            self.face_ended = Some(Instant::now());
        }
        self.info.clear();
        if self.face_state == "looking" {
            self.face_state = "failed".into();
        }
        self.status = "Checking…".into();
        self.failed = false;
        match Attempt::start("login", &self.user, &self.wake) {
            Some(a) => {
                self.pam = Some(a);
                self.pam_since = Some(Instant::now());
            }
            None => {
                self.failed = true;
                self.status = "Could not start authentication".into();
            }
        }
    }

    fn rejected(&mut self, m: &Motion) {
        self.shake.kick(480.0, 0.0, 300.0, 2.2, m);
    }

    /// In: the view fades (unless motion is off), then the lock goes.
    fn unlock(&mut self, m: &Motion) {
        self.stop_face();
        self.pam = None;
        self.unlock_at = None;
        self.leaving = Some(Instant::now() + if m.speed <= 0.0 { Duration::ZERO } else { Duration::from_millis(440) });
    }

    /// The whole frame: the compositor's word, PAM's, the screens.
    pub fn step(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, w: &World, dt: f64, new_view: &dyn Fn(f32) -> Option<LockView>, new_arrival: &dyn Fn() -> Option<crate::Arrival>) {
        let m = w.look.motion;
        self.step_arrival(shell);
        if !self.active {
            return;
        }
        let now = Instant::now();

        // The compositor: refused, or ended, while it should be up: let go
        // and ask again a moment later, until it takes.
        if shell.lock_state == LockState::Finished && self.leaving.is_none() {
            for s in self.screens.drain(..) {
                shell.remove(s.id);
            }
            shell.unlock_session();
            self.retry_at.get_or_insert(now + Duration::from_millis(120));
        }
        if shell.lock_state == LockState::Asking && self.asked.is_some_and(|t| now - t > Duration::from_millis(600)) {
            for s in self.screens.drain(..) {
                shell.remove(s.id);
            }
            shell.unlock_session();
            self.retry_at = Some(now + Duration::from_millis(120));
            self.asked = None;
        }
        if self.retry_at.is_some_and(|t| now >= t) && shell.lock_state == LockState::Off {
            self.retry_at = None;
            self.ask(shell, qh);
        }

        // A surface on every output there is.
        if matches!(shell.lock_state, LockState::Asking | LockState::Locked) {
            let outs = shell.all_outputs();
            self.screens.retain(|s| {
                let keep = outs.contains(&s.output);
                if !keep {
                    shell.remove(s.id);
                }
                keep
            });
            for o in outs {
                if self.screens.iter().any(|s| s.output == o) {
                    continue;
                }
                let name = shell.output_name(&o);
                let us = w.look.screen_scale(&name);
                let Some(view) = new_view(us) else { continue };
                let Some(adapter) = crate::platform::take_adapter() else { continue };
                let Some(id) = shell.add_lock_window(qh, adapter, &o) else { continue };
                self.wire(&view);
                self.screens.push(Screen { output: o, name, view, id, ground_for: None });
            }
        }

        // What the screens' buttons asked for.
        let acts: Vec<Act> = std::mem::take(&mut *self.actions.borrow_mut());
        for a in acts {
            match a {
                Act::Typed(t) => {
                    self.entered = t;
                    self.failed = false;
                    self.status.clear();
                    self.keyboard_missing = false;
                }
                Act::Submit => self.submit(),
                Act::Escape => {
                    self.entered.clear();
                    self.status.clear();
                }
                Act::RetryFace => self.retry_face(),
                Act::Woke => {
                    // Back after a while away: look again, straight away.
                    if self.can_retry_face() && self.entered.is_empty() && self.face_state != "found" && self.face_ended.is_some_and(|t| now - t > Duration::from_secs(15)) {
                        self.retry_face();
                    }
                }
                Act::Power(p) => {
                    let cmd = match p.as_str() {
                        "suspend" => "systemctl suspend",
                        "reboot" => "loginctl reboot 2>/dev/null || systemctl reboot",
                        _ => "loginctl poweroff 2>/dev/null || systemctl poweroff",
                    };
                    let _ = std::process::Command::new("sh").args(["-c", cmd]).spawn();
                }
            }
        }

        // PAM: the password.
        let mut events = vec![];
        if let Some(a) = &self.pam {
            events.extend(a.rx.try_iter());
        }
        for ev in events {
            match ev["ev"].as_str() {
                Some("prompt") => {
                    let e = self.entered.clone();
                    if let Some(a) = self.pam.as_mut() {
                        a.answer(&e);
                    }
                }
                Some("info") if ev["error"] == true => self.status = ev["msg"].as_str().unwrap_or("").to_string(),
                Some("done") => {
                    self.pam = None;
                    self.pam_since = None;
                    if ev["ok"] == true {
                        self.reset();
                        self.unlock(&m);
                    } else {
                        self.failed = true;
                        self.entered.clear();
                        self.status = if ev["code"].as_i64() == Some(PAM_MAXTRIES) {
                            "Too many attempts".into()
                        } else if ev["gone"] == true {
                            "Authentication unavailable".into()
                        } else {
                            "Wrong password".into()
                        };
                        self.rejected(&m);
                    }
                }
                _ => {}
            }
        }
        // Never stuck checking: a module that stops answering (a fingerprint
        // reader waiting for a finger) is called off after twenty seconds.
        if self.pam_since.is_some_and(|t| now - t > Duration::from_secs(20)) {
            self.pam = None;
            self.pam_since = None;
            self.failed = true;
            self.entered.clear();
            self.status = "That took too long. Try again.".into();
            self.rejected(&m);
        }

        // PAM: the face.
        let mut events = vec![];
        if let Some(a) = &self.face {
            events.extend(a.rx.try_iter());
        }
        for ev in events {
            match ev["ev"].as_str() {
                // A face-only service asks nothing; anything it asks isn't
                // for us to answer.
                Some("prompt") => self.stop_face(),
                // What the camera sees ("Come a little closer"), marked with
                // a zero-width space by pam_hyprshell_face.
                Some("info") => {
                    if let Some(hint) = ev["msg"].as_str().and_then(|m| m.strip_prefix('\u{200b}')) {
                        self.info = if hint.is_empty() { "Looking for you…".into() } else { hint.to_string() };
                    }
                }
                Some("done") => {
                    self.face = None;
                    self.face_ended = Some(now);
                    if ev["ok"] == true {
                        self.info.clear();
                        self.face_state = "found".into();
                        // The keyring too, if it was locked meanwhile.
                        let _ = std::process::Command::new("sh")
                            .args(["-c", "command -v hyprshell-face-keyring >/dev/null && hyprshell-face-keyring unlock"])
                            .stdout(std::process::Stdio::null())
                            .stderr(std::process::Stdio::null())
                            .spawn();
                        self.unlock_at = Some(now + if m.speed <= 0.0 { Duration::ZERO } else { Duration::from_millis(480) });
                    } else if self.pam.is_none() {
                        self.info = "Face not recognised · type your password".into();
                        self.face_state = "failed".into();
                        self.face_shake.kick(900.0, 0.0, 300.0, 2.2, &m);
                    }
                }
                _ => {}
            }
        }
        if self.unlock_at.is_some_and(|t| now >= t) {
            self.unlock(&m);
        }

        // Going: the view has faded; the desktop's wallpaper goes up over
        // it, and the lock is let go.
        if self.leaving.is_some_and(|t| now >= t) {
            self.leaving = None;
            self.arrive(shell, qh, new_arrival);
            for s in self.screens.drain(..) {
                shell.remove(s.id);
            }
            shell.unlock_session();
            locked_hint(false);
            self.active = false;
            self.face_state.clear();
            self.info.clear();
            return;
        }

        // The springs.
        self.shake.step(dt, &m);
        let fs = &self.face_state;
        self.face_show.go(if fs.is_empty() { 0.0 } else { 1.0 }, 420.0, 0.5, &m);
        self.face_close.go(if fs == "found" { 1.0 } else { 0.0 }, 460.0, 0.4, &m);
        self.face_tick.go(if fs == "found" { 1.0 } else { 0.0 }, 560.0, 0.0, &m);
        self.face_dim.go(if fs == "failed" { 1.0 } else { 0.0 }, 360.0, 0.0, &m);
        for s in [&mut self.face_show, &mut self.face_close, &mut self.face_tick, &mut self.face_dim, &mut self.face_shake] {
            s.step(dt, &m);
        }

        // The wallpaper, for each screen at its own size.
        while let Ok((name, w, h, full, frost, vivid)) = self.ground_rx.try_recv() {
            self.grounds.retain(|x| x.0 != name);
            self.grounds.push((name, w, h, Image::from_rgba8(full), Image::from_rgba8(frost), vivid));
        }
        self.publish(shell, w);
    }

    fn wire(&self, v: &LockView) {
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
    }

    fn publish(&mut self, shell: &wl::Shell, w: &World) {
        let look = w.look;
        let now = chrono_now();
        let clock = if look.clock24 { format!("{:02}:{:02}", now.hour, now.min) } else { format!("{}:{:02}", if now.hour % 12 == 0 { 12 } else { now.hour % 12 }, now.min) };
        let date = format!("{}, {} {}", now.weekday, now.day, now.month).to_uppercase();
        let ampm = if look.clock24 { String::new() } else if now.hour < 12 { "AM".into() } else { "PM".into() };
        let t = self.started.elapsed().as_secs_f64();
        let looking = self.face_state == "looking" && look.motion.speed > 0.0;
        let sweep = if looking { (t % 1.6) / 1.6 * 1.4 - 0.2 } else { -1.0 };
        let turn = if looking { (t % 9.0) / 9.0 * std::f64::consts::TAU } else { 0.0 };
        let glyphs = LockGlyphs {
            lock: crate::glyphs::glyph("lock"),
            eye: crate::glyphs::glyph("eye"),
            go: crate::glyphs::glyph("chevron-right"),
            moon: crate::glyphs::glyph("moon"),
            restart: crate::glyphs::glyph("rotate-cw"),
            power: crate::glyphs::glyph("power"),
            battery: crate::glyphs::glyph(if w.battery.is_some_and(|b| b.1) { "battery-charging" } else { "battery" }),
            bell: crate::glyphs::glyph("bell"),
            net: crate::glyphs::glyph(w.net_icon),
            ..glyph_set()
        };
        let status = if !self.status.is_empty() { self.status.clone() } else if self.face_state.is_empty() { self.info.clone() } else { String::new() };
        let face_first = matches!(self.face_state.as_str(), "looking" | "found");
        let can_retry = self.face_state == "failed" && self.can_retry_face();
        // Wanted for each screen: its wallpaper, being drawn.
        let mut todo = vec![];
        for s in &mut self.screens {
            let v = &s.view;
            let sf = shell.surfaces.get(s.id).and_then(|x| x.as_ref());
            if let Some(sf) = sf {
                let (pw, ph) = ((sf.width as f64 * sf.scale).round() as u32, (sf.height as f64 * sf.scale).round() as u32);
                if pw > 0 && ph > 0 && s.ground_for != Some((pw, ph)) {
                    s.ground_for = Some((pw, ph));
                    todo.push((s.name.clone(), pw, ph));
                }
                let face_px = (58.0 * look.screen_scale(&s.name) as f64 * sf.scale).round().max(16.0) as u32;
                if self.face_show.value > 0.01 {
                    // White over a picture; the theme's ink over its gradient.
                    let vivid = self.grounds.iter().find(|g| g.0 == s.name).is_some_and(|g| g.5);
                    let ink = if vivid { (255, 255, 255) } else { rgb(look.ink) };
                    v.set_face(face_glyph(face_px, &self.face_state, ink, rgb(look.accent), sweep, turn, self.face_close.value, self.face_tick.value, self.face_dim.value));
                }
            }
            if let Some(g) = self.grounds.iter().find(|g| g.0 == s.name) {
                v.set_ground(g.3.clone());
                v.set_frost(g.4.clone());
                if v.get_vivid() != g.5 || v.get_scrim().size().height == 0 {
                    v.set_scrim(scrim(g.5));
                }
                v.set_vivid(g.5);
            }
            v.set_ground_colour(look.panel.slint().with_alpha(1.0));
            v.set_date(date.clone().into());
            v.set_time(clock.clone().into());
            v.set_ampm(ampm.clone().into());
            v.set_user_name(self.display.clone().into());
            v.set_initial(self.display.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default().into());
            if let Some(p) = &self.picture {
                v.set_picture(p.clone());
                v.set_has_picture(true);
            }
            if v.get_entered().as_str() != self.entered {
                v.set_entered(SharedString::from(self.entered.as_str()));
            }
            v.set_status_text(status.clone().into());
            v.set_failed(self.failed);
            v.set_busy(self.pam.is_some());
            v.set_leaving(self.leaving.is_some());
            v.set_face_first(face_first);
            v.set_face_state(if self.face_show.value > 0.01 || !self.face_state.is_empty() { self.face_state.clone().into() } else { SharedString::new() });
            v.set_can_retry_face(can_retry);
            v.set_keyboard_missing(self.keyboard_missing);
            v.set_shake(self.shake.value as f32 * 0.04 * 26.0);
            v.set_has_battery(w.battery.is_some());
            v.set_battery_text(w.battery.map(|b| format!("{}%", b.0)).unwrap_or_default().into());
            v.set_net_label(w.net_label.clone().into());
            v.set_notes(w.notes as i32);
            v.set_glyphs(glyphs.clone());
        }
        for (name, pw, ph) in todo {
            let (tx, spec) = (self.ground_tx.clone(), w.ground.clone());
            let mut wake = self.wake.try_clone().expect("wake");
            let mut raw = crate::theme::raw();
            raw["wallpaper"] = serde_json::Value::String(String::new());
            let fallback = crate::ground::spec(&raw, look.dark);
            std::thread::spawn(move || {
                // A picture that won't open falls back to the gradient.
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
        self.last_clock = clock;
    }

    /// The wallpaper over the desktop on every screen, fading: the windows
    /// come up through it.
    fn arrive(&mut self, shell: &mut wl::Shell, qh: &QueueHandle<wl::Shell>, new_arrival: &dyn Fn() -> Option<crate::Arrival>) {
        for s in &self.screens {
            let Some(a) = new_arrival() else { continue };
            let Some(adapter) = crate::platform::take_adapter() else { continue };
            if let Some(g) = self.grounds.iter().find(|g| g.0 == s.name) {
                a.set_ground(g.3.clone());
            }
            a.set_ground_colour(s.view.get_ground_colour());
            let id = shell.add_window(qh, adapter, Some(&s.output), &wl::Placement {
                namespace: "quickshell:arrival",
                layer: smithay_client_toolkit::shell::wlr_layer::Layer::Overlay,
                anchor: smithay_client_toolkit::shell::wlr_layer::Anchor::all(),
                width: 0,
                height: 0,
                exclusive: -1,
                keyboard: smithay_client_toolkit::shell::wlr_layer::KeyboardInteractivity::None,
            });
            shell.set_input_rect(id, None);
            self.arrival.push((a, id));
        }
        self.arrival_until = Some(Instant::now() + Duration::from_millis(80));
    }

    fn step_arrival(&mut self, shell: &mut wl::Shell) {
        let Some(t) = self.arrival_until else { return };
        if Instant::now() < t {
            return;
        }
        // Up a moment while the lock goes, then faded, then gone.
        if self.arrival.iter().any(|(a, _)| !a.get_fading()) {
            for (a, _) in &self.arrival {
                a.set_fading(true);
            }
            self.arrival_until = Some(Instant::now() + Duration::from_millis(600));
            return;
        }
        for (_, id) in self.arrival.drain(..) {
            shell.remove(id);
        }
        self.arrival_until = None;
    }
}

/// The time, broken up, in local time.
pub struct Now {
    pub hour: u32,
    pub min: u32,
    pub day: u32,
    pub weekday: &'static str,
    pub month: &'static str,
}
pub fn chrono_now() -> Now {
    // SAFETY: localtime_r into our own struct.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let t = unsafe { libc::time(std::ptr::null_mut()) };
    unsafe { libc::localtime_r(&t, &mut tm) };
    const DAYS: [&str; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    const MONTHS: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
    Now {
        hour: tm.tm_hour as u32,
        min: tm.tm_min as u32,
        day: tm.tm_mday as u32,
        weekday: DAYS[(tm.tm_wday as usize) % 7],
        month: MONTHS[(tm.tm_mon as usize) % 12],
    }
}

/// logind's word: the session to be locked or let go (loginctl
/// lock-session, an idle daemon), and the machine going to sleep and
/// waking. As "lock", "unlock", "sleep", "wake".
pub fn watch_logind(wake: &std::os::unix::net::UnixStream) -> std::sync::mpsc::Receiver<&'static str> {
    let (tx, rx) = std::sync::mpsc::channel();
    let Ok(conn) = zbus::blocking::Connection::system() else { return rx };
    // This session's object: the one this process belongs to.
    let path = zbus::blocking::Proxy::new(&conn, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager")
        .ok()
        .and_then(|m| m.call::<_, _, zbus::zvariant::OwnedObjectPath>("GetSessionByPID", &(std::process::id())).ok())
        .map(|p| p.to_string())
        .or_else(|| std::env::var("XDG_SESSION_ID").ok().map(|id| format!("/org/freedesktop/login1/session/{}", escape_id(&id))));
    let watch = |iface: &'static str, path: String, member: &'static str, f: fn(&zbus::message::Message) -> Option<&'static str>| {
        let (conn, tx) = (conn.clone(), tx.clone());
        let Ok(mut wake) = wake.try_clone() else { return };
        std::thread::spawn(move || {
            let Ok(p) = zbus::blocking::Proxy::new(&conn, "org.freedesktop.login1", path, iface) else { return };
            let Ok(sigs) = p.receive_signal(member) else { return };
            for m in sigs {
                if let Some(e) = f(&m) {
                    if tx.send(e).is_err() {
                        return;
                    }
                    let _ = std::io::Write::write_all(&mut wake, b"!");
                }
            }
        });
    };
    if let Some(path) = path {
        watch("org.freedesktop.login1.Session", path.clone(), "Lock", |_| Some("lock"));
        watch("org.freedesktop.login1.Session", path, "Unlock", |_| Some("unlock"));
    }
    watch("org.freedesktop.login1.Manager", "/org/freedesktop/login1".into(), "PrepareForSleep", |m| {
        m.body().deserialize::<bool>().ok().map(|s| if s { "sleep" } else { "wake" })
    });
    rx
}

/// A session id as it appears in an object path (_3 for "3", and so on).
fn escape_id(id: &str) -> String {
    // A leading digit is escaped too.
    id.chars()
        .enumerate()
        .map(|(i, c)| if c.is_ascii_alphanumeric() && !(i == 0 && c.is_ascii_digit()) { c.to_string() } else { format!("_{:02x}", c as u32) })
        .collect()
}

/// Tells logind whether the session is locked (LockedHint), as a locker
/// should, for what else watches it.
pub fn locked_hint(on: bool) {
    std::thread::spawn(move || {
        let Ok(conn) = zbus::blocking::Connection::system() else { return };
        let _ = conn.call_method(Some("org.freedesktop.login1"), "/org/freedesktop/login1/session/auto", Some("org.freedesktop.login1.Session"), "SetLockedHint", &(on));
    });
}
