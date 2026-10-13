//! Videos: mpv's playback (found at run time) in a window of the shell's
//! own. With a GPU, mpv decodes on it and draws straight into a texture
//! the window shows — no copies through memory; without one it draws into
//! a buffer instead. Films pick up where they were left; MPRIS lets the
//! media keys and the shell's media pill drive it, and keeps the screen on
//! while it plays.
//!
//!   hyprshell-video [FILE|URL]...

slint::include_modules!();

mod mpv;

use hyprshell_kit as kit;
use kit::mpris;
use mpv::{Event, Mpv, Render, Value};
use slint::{ComponentHandle, GraphicsAPI, ModelRc, RenderingState, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::Duration;

const BUS: mpris::Info = mpris::Info {
    name: "hyprshell_video",
    identity: "Videos",
    desktop_entry: "hyprshell-video",
    mime_types: &[
        "video/mp4", "video/x-matroska", "video/webm", "video/quicktime", "video/x-msvideo", "video/mpeg", "video/ogg", "video/x-flv",
        "video/3gpp", "video/mp2t", "video/x-ms-wmv",
    ],
};

const SPEEDS: [f64; 6] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

// ── recents ─────────────────────────────────────────────────────────────

#[derive(Clone, Default, serde::Serialize, serde::Deserialize)]
struct Seen {
    path: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    pos: f64,
    #[serde(default)]
    dur: f64,
    #[serde(default)]
    opened: i64,
}

fn recent_file() -> PathBuf {
    kit::config_dir().join("hyprshell-video/recent.json")
}

fn state_dir() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| kit::home().join(".local/state"))
        .join("hyprshell-video")
}

fn name_of(path: &str) -> String {
    if path.contains("://") && !path.starts_with("file://") {
        return path.to_string();
    }
    Path::new(path).file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| path.to_string())
}

// ── the picture, by GPU ─────────────────────────────────────────────────

struct Gl {
    gl: glow::Context,
    render: Render,
    tex: Option<glow::NativeTexture>,
    fbo: Option<glow::NativeFramebuffer>,
    size: (i32, i32),
}

impl Gl {
    unsafe fn resize(&mut self, w: i32, h: i32) {
        use glow::HasContext;
        let gl = &self.gl;
        // The new texture is made before the old one goes, so it never
        // takes the old one's name while the window still knows that name.
        let (gone_tex, gone_fbo) = (self.tex.take(), self.fbo.take());
        let old_tex = gl.get_parameter_texture(glow::TEXTURE_BINDING_2D);
        let old_fbo = gl.get_parameter_framebuffer(glow::FRAMEBUFFER_BINDING);
        let tex = gl.create_texture().expect("texture");
        gl.bind_texture(glow::TEXTURE_2D, Some(tex));
        gl.tex_image_2d(glow::TEXTURE_2D, 0, glow::RGBA8 as i32, w, h, 0, glow::RGBA, glow::UNSIGNED_BYTE, glow::PixelUnpackData::Slice(None));
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_MIN_FILTER, glow::LINEAR as i32);
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_MAG_FILTER, glow::LINEAR as i32);
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_WRAP_S, glow::CLAMP_TO_EDGE as i32);
        gl.tex_parameter_i32(glow::TEXTURE_2D, glow::TEXTURE_WRAP_T, glow::CLAMP_TO_EDGE as i32);
        let fbo = gl.create_framebuffer().expect("framebuffer");
        gl.bind_framebuffer(glow::FRAMEBUFFER, Some(fbo));
        gl.framebuffer_texture_2d(glow::FRAMEBUFFER, glow::COLOR_ATTACHMENT0, glow::TEXTURE_2D, Some(tex), 0);
        gl.clear_color(0.0, 0.0, 0.0, 1.0);
        gl.clear(glow::COLOR_BUFFER_BIT);
        gl.bind_framebuffer(glow::FRAMEBUFFER, old_fbo);
        gl.bind_texture(glow::TEXTURE_2D, old_tex);
        if let Some(t) = gone_tex {
            gl.delete_texture(t);
        }
        if let Some(f) = gone_fbo {
            gl.delete_framebuffer(f);
        }
        self.tex = Some(tex);
        self.fbo = Some(fbo);
        self.size = (w, h);
    }

    /// mpv draws into our texture, from GL's default state (the window's
    /// renderer leaves its own behind: scissors, stencils, unpack row
    /// lengths); then the renderer's state is put back as it was.
    unsafe fn draw(&self) {
        use glow::HasContext;
        let gl = &self.gl;
        let Some(fbo) = self.fbo else { return };
        let old_fbo = gl.get_parameter_framebuffer(glow::FRAMEBUFFER_BINDING);
        let old_prog = gl.get_parameter_program(glow::CURRENT_PROGRAM);
        let old_vao = gl.get_parameter_vertex_array(glow::VERTEX_ARRAY_BINDING);
        let old_buf = gl.get_parameter_buffer(glow::ARRAY_BUFFER_BINDING);
        let old_unpack_buf = gl.get_parameter_buffer(glow::PIXEL_UNPACK_BUFFER_BINDING);
        let old_pack_buf = gl.get_parameter_buffer(glow::PIXEL_PACK_BUFFER_BINDING);
        let old_active = gl.get_parameter_i32(glow::ACTIVE_TEXTURE) as u32;
        gl.active_texture(glow::TEXTURE0);
        let old_tex = gl.get_parameter_texture(glow::TEXTURE_BINDING_2D);
        let mut vp = [0i32; 4];
        gl.get_parameter_i32_slice(glow::VIEWPORT, &mut vp);
        let mut sc = [0i32; 4];
        gl.get_parameter_i32_slice(glow::SCISSOR_BOX, &mut sc);
        let caps = [glow::BLEND, glow::SCISSOR_TEST, glow::STENCIL_TEST, glow::DEPTH_TEST, glow::CULL_FACE, glow::DITHER];
        let was: Vec<bool> = caps.iter().map(|&c| gl.is_enabled(c)).collect();
        let pixel = [glow::UNPACK_ALIGNMENT, glow::UNPACK_ROW_LENGTH, glow::UNPACK_SKIP_ROWS, glow::UNPACK_SKIP_PIXELS, glow::PACK_ALIGNMENT];
        let px: Vec<i32> = pixel.iter().map(|&p| gl.get_parameter_i32(p)).collect();
        let mut mask = [false; 4];
        mask.copy_from_slice(&gl.get_parameter_bool_array::<4>(glow::COLOR_WRITEMASK));

        for &c in &caps {
            gl.disable(c);
        }
        gl.bind_buffer(glow::PIXEL_UNPACK_BUFFER, None);
        gl.bind_buffer(glow::PIXEL_PACK_BUFFER, None);
        gl.pixel_store_i32(glow::UNPACK_ALIGNMENT, 4);
        gl.pixel_store_i32(glow::UNPACK_ROW_LENGTH, 0);
        gl.pixel_store_i32(glow::UNPACK_SKIP_ROWS, 0);
        gl.pixel_store_i32(glow::UNPACK_SKIP_PIXELS, 0);
        gl.pixel_store_i32(glow::PACK_ALIGNMENT, 4);
        gl.color_mask(true, true, true, true);
        gl.bind_vertex_array(None);
        gl.use_program(None);

        self.render.draw_gl(fbo.0.get(), self.size.0, self.size.1, false);
        // mpv leaves alpha as it found it (nothing); the window would blend
        // the picture away. Make it opaque without touching the colour.
        gl.bind_framebuffer(glow::FRAMEBUFFER, Some(fbo));
        gl.disable(glow::SCISSOR_TEST);
        gl.color_mask(false, false, false, true);
        gl.clear_color(0.0, 0.0, 0.0, 1.0);
        gl.clear(glow::COLOR_BUFFER_BIT);

        gl.bind_framebuffer(glow::FRAMEBUFFER, old_fbo);
        gl.use_program(old_prog);
        gl.bind_vertex_array(old_vao);
        gl.bind_buffer(glow::ARRAY_BUFFER, old_buf);
        gl.bind_buffer(glow::PIXEL_UNPACK_BUFFER, old_unpack_buf);
        gl.bind_buffer(glow::PIXEL_PACK_BUFFER, old_pack_buf);
        gl.active_texture(glow::TEXTURE0);
        gl.bind_texture(glow::TEXTURE_2D, old_tex);
        gl.active_texture(old_active);
        gl.viewport(vp[0], vp[1], vp[2], vp[3]);
        gl.scissor(sc[0], sc[1], sc[2], sc[3]);
        for (&c, &on) in caps.iter().zip(&was) {
            if on {
                gl.enable(c)
            } else {
                gl.disable(c)
            }
        }
        for (&p, &v) in pixel.iter().zip(&px) {
            gl.pixel_store_i32(p, v);
        }
        gl.color_mask(mask[0], mask[1], mask[2], mask[3]);
    }
}

impl Drop for Gl {
    fn drop(&mut self) {
        use glow::HasContext;
        unsafe {
            if let Some(t) = self.tex.take() {
                self.gl.delete_texture(t);
            }
            if let Some(f) = self.fbo.take() {
                self.gl.delete_framebuffer(f);
            }
        }
    }
}

// ── the app ─────────────────────────────────────────────────────────────

struct App {
    win: AppWindow,
    mpv: Option<Arc<Mpv>>,
    /// Drawing on the CPU (no GL in this window).
    sw: RefCell<Option<Render>>,
    recents: RefCell<Vec<Seen>>,
    current: RefCell<Option<String>>,
    pos: Cell<f64>,
    dur: Cell<f64>,
    eof: Cell<bool>,
    speed: Cell<f64>,
    over_controls: Cell<bool>,
    subs: RefCell<Vec<i64>>,
    audios: RefCell<Vec<i64>>,
    mpris: RefCell<Option<Sender<mpris::Update>>>,
    track_id: Cell<u64>,
    /// mpv has somewhere to draw; until then, what to open waits here.
    ready: Cell<bool>,
    waiting: RefCell<Vec<String>>,
    hide_timer: slint::Timer,
    toast_timer: slint::Timer,
    keep_timer: slint::Timer,
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

impl App {
    fn g(&self) -> Video<'_> {
        self.win.global::<Video>()
    }

    fn toast(&self, t: &str) {
        self.g().set_toast(t.into());
        let w = self.win.as_weak();
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(2400), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Video>().set_toast(SharedString::new());
            }
        });
    }

    fn show_recents(&self) {
        let rows: Vec<Recent> = self
            .recents
            .borrow()
            .iter()
            .take(12)
            .map(|r| {
                let progress = if r.dur > 0.0 { (r.pos / r.dur).clamp(0.0, 1.0) } else { 0.0 };
                let sub = if r.dur > 0.0 && r.pos >= r.dur - 10.0 {
                    format!("Watched · {}", kit::clock(r.dur))
                } else if r.pos > 5.0 && r.dur > 0.0 {
                    format!("{} of {} · {}", kit::clock(r.pos), kit::clock(r.dur), kit::when(r.opened))
                } else if r.dur > 0.0 {
                    format!("{} · {}", kit::clock(r.dur), kit::when(r.opened))
                } else {
                    kit::when(r.opened)
                };
                Recent {
                    path: r.path.clone().into(),
                    name: if r.title.is_empty() { name_of(&r.path) } else { r.title.clone() }.into(),
                    sub: sub.into(),
                    progress: if r.dur > 0.0 && r.pos >= r.dur - 10.0 { 1.0 } else { progress as f32 },
                }
            })
            .collect();
        self.g().set_recents(ModelRc::new(VecModel::from(rows)));
    }

    fn save_recents(&self) {
        let p = recent_file();
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        let r = self.recents.borrow();
        let keep: Vec<&Seen> = r.iter().take(40).collect();
        let _ = kit::write_atomic(&p, serde_json::to_string_pretty(&keep).unwrap_or_default().as_bytes());
    }

    /// Note where we are in what's playing (and tell mpv, which resumes it).
    fn remember(&self) {
        let Some(m) = self.mpv.as_ref() else { return };
        let Some(path) = self.current.borrow().clone() else { return };
        let (pos, dur) = (self.pos.get(), self.dur.get());
        let done = self.eof.get() || (dur > 0.0 && pos >= dur - 10.0);
        let _ = m.command(&[if done { "delete-watch-later-config" } else { "write-watch-later-config" }]);
        let mut r = self.recents.borrow_mut();
        if let Some(s) = r.iter_mut().find(|s| s.path == path) {
            s.pos = if done { dur } else { pos };
            if dur > 0.0 {
                s.dur = dur;
            }
        }
        drop(r);
        self.save_recents();
    }

    fn open(&self, path: String) {
        let Some(m) = self.mpv.as_ref() else { return };
        if !self.ready.get() {
            self.waiting.borrow_mut().push(path);
            return;
        }
        self.remember();
        let path = path.strip_prefix("file://").map(|p| p.to_string()).unwrap_or(path);
        if let Err(e) = m.command(&["loadfile", &path, "replace"]) {
            self.fail(&e);
            return;
        }
        self.begin(&path);
    }

    fn begin(&self, path: &str) {
        *self.current.borrow_mut() = Some(path.to_string());
        self.eof.set(false);
        self.pos.set(0.0);
        self.dur.set(0.0);
        let mut r = self.recents.borrow_mut();
        let mut s = r.iter().position(|s| s.path == path).map(|i| r.remove(i)).unwrap_or_else(|| Seen { path: path.to_string(), ..Default::default() });
        s.opened = kit::now();
        r.insert(0, s);
        drop(r);
        self.save_recents();
        let g = self.g();
        g.set_mode("video".into());
        g.set_title(name_of(path).into());
        g.set_pos(0.0);
        g.set_dur(0.0);
        g.set_pos_text("0:00".into());
        g.set_dur_text("0:00".into());
        self.track_id.set(self.track_id.get() + 1);
        self.poke();
        let _ = self.win.window().show();
    }

    fn fail(&self, why: &str) {
        // What never played isn't worth remembering.
        if let Some(p) = self.current.borrow().clone() {
            self.recents.borrow_mut().retain(|s| s.path != p || s.dur > 0.0);
            self.save_recents();
            self.show_recents();
        }
        let g = self.g();
        g.set_mode("error".into());
        g.set_error(why.into());
        *self.current.borrow_mut() = None;
        self.tell_bus();
    }

    fn close_video(&self) {
        self.remember();
        if let Some(m) = self.mpv.as_ref() {
            let _ = m.command(&["stop"]);
        }
        *self.current.borrow_mut() = None;
        let g = self.g();
        g.set_mode("start".into());
        g.set_title(SharedString::new());
        if g.get_fullscreen() {
            self.fullscreen(false);
        }
        self.show_recents();
        self.tell_bus();
    }

    fn fullscreen(&self, on: bool) {
        self.win.window().set_fullscreen(on);
        self.g().set_fullscreen(on);
        self.poke();
    }

    /// The pointer moved: show the controls, and hide them again soon.
    fn poke(&self) {
        let g = self.g();
        g.set_controls(true);
        self.hide_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(2600), || {
            with_app(|a| {
                if !a.over_controls.get() {
                    a.g().set_controls(false);
                }
            })
        });
    }

    fn mpv_events(&self) {
        let Some(m) = self.mpv.clone() else { return };
        while let Some(e) = m.next_event() {
            self.on_event(&m, e);
        }
    }

    fn on_event(&self, m: &Mpv, e: Event) {
        let g = self.g();
        match e {
            Event::Property(name, v) => match (name.as_str(), v) {
                ("pause", Value::Flag(p)) => {
                    g.set_paused(p);
                    if p {
                        self.poke();
                    }
                    self.tell_bus();
                }
                ("time-pos", Value::Double(t)) => {
                    let old = self.pos.get();
                    self.pos.set(t);
                    g.set_pos(t as f32);
                    if old.floor() != t.floor() {
                        g.set_pos_text(kit::clock(t).into());
                    }
                }
                ("duration", Value::Double(d)) => {
                    self.dur.set(d);
                    g.set_dur(d as f32);
                    g.set_dur_text(kit::clock(d).into());
                    self.tell_bus();
                }
                ("volume", Value::Double(v)) => {
                    g.set_volume(v as f32);
                    self.tell_bus();
                }
                ("mute", Value::Flag(mu)) => g.set_muted(mu),
                ("media-title", Value::Str(t)) => {
                    if !t.is_empty() {
                        g.set_title(t.clone().into());
                        if let Some(p) = self.current.borrow().clone() {
                            if let Some(s) = self.recents.borrow_mut().iter_mut().find(|s| s.path == p) {
                                s.title = if t == name_of(&p) { String::new() } else { t };
                            }
                        }
                        self.tell_bus();
                    }
                }
                ("paused-for-cache", Value::Flag(b)) => g.set_buffering(b),
                ("eof-reached", Value::Flag(b)) => {
                    self.eof.set(b);
                    if b {
                        g.set_controls(true);
                    }
                }
                ("speed", Value::Double(s)) => {
                    self.speed.set(s);
                    let t = if (s - s.round()).abs() < 0.01 { format!("{}×", s.round() as i64) } else { format!("{}×", (s * 100.0).round() / 100.0) };
                    g.set_speed_text(t.into());
                }
                ("playlist-count", Value::Int(n)) => g.set_playlist(n > 1),
                ("track-list", _) | ("sid", _) | ("aid", _) => self.tracks(m),
                _ => {}
            },
            Event::StartFile => g.set_buffering(true),
            Event::FileLoaded => {
                g.set_buffering(false);
                // A file mpv moved on to by itself (the next in a playlist).
                if let Some(p) = m.get_str("path") {
                    if self.current.borrow().as_deref() != Some(p.as_str()) {
                        self.remember();
                        self.begin(&p);
                    }
                }
                self.tracks(m);
                self.tell_bus();
            }
            Event::PlaybackRestart => g.set_buffering(false),
            Event::EndFile(reason, err) => {
                // 4: it couldn't be played.
                if reason == 4 {
                    // mpv's error codes (client.h).
                    let why = match err {
                        -13 => "It couldn't be opened: it may have moved, or be unreadable".to_string(),
                        -16 => "There's no picture or sound in it that Videos can play".to_string(),
                        -17 => "It isn't a kind of video Videos can play".to_string(),
                        -14 => "The sound couldn't start".to_string(),
                        -15 => "The picture couldn't be shown".to_string(),
                        _ => "It couldn't be played".to_string(),
                    };
                    self.fail(&why);
                }
            }
            Event::Shutdown => {
                let _ = slint::quit_event_loop();
            }
            _ => {}
        }
    }

    /// Subtitle and audio choices, from mpv's track list.
    fn tracks(&self, m: &Mpv) {
        let n = m.get_int("track-list/count").unwrap_or(0);
        let mut subs: Vec<(i64, String, bool)> = Vec::new();
        let mut audios: Vec<(i64, String, bool)> = Vec::new();
        let mut video = false;
        for i in 0..n {
            let p = |k: &str| m.get_str(&format!("track-list/{i}/{k}"));
            let kind = p("type").unwrap_or_default();
            let id = m.get_int(&format!("track-list/{i}/id")).unwrap_or(0);
            let sel = m.get_flag(&format!("track-list/{i}/selected")).unwrap_or(false);
            let title = p("title").unwrap_or_default();
            let lang = p("lang").unwrap_or_default();
            let label = match (title.is_empty(), lang.is_empty()) {
                (false, false) => format!("{title} ({lang})"),
                (false, true) => title,
                (true, false) => lang.to_uppercase(),
                (true, true) => format!("Track {id}"),
            };
            match kind.as_str() {
                "sub" => subs.push((id, label, sel)),
                "audio" => audios.push((id, label, sel)),
                "video" if !m.get_flag(&format!("track-list/{i}/albumart")).unwrap_or(false) => video = true,
                _ => {}
            }
        }
        let g = self.g();
        g.set_audio_only(!video && n > 0);
        let none_sel = !subs.iter().any(|s| s.2);
        let mut sub_rows = vec![MenuEntry { text: "Off".into(), checked: none_sel, ..Default::default() }];
        sub_rows.extend(subs.iter().map(|(_, l, s)| MenuEntry { text: l.clone().into(), checked: *s, ..Default::default() }));
        let audio_rows: Vec<MenuEntry> = audios.iter().map(|(_, l, s)| MenuEntry { text: l.clone().into(), checked: *s, ..Default::default() }).collect();
        *self.subs.borrow_mut() = subs.iter().map(|s| s.0).collect();
        *self.audios.borrow_mut() = audios.iter().map(|s| s.0).collect();
        g.set_subs(ModelRc::new(VecModel::from(if subs.is_empty() { Vec::new() } else { sub_rows })));
        g.set_audios(ModelRc::new(VecModel::from(audio_rows)));
    }

    fn toggle(&self) {
        let Some(m) = self.mpv.as_ref() else { return };
        if self.current.borrow().is_none() {
            return;
        }
        if self.eof.get() {
            // At the end: from the start.
            let _ = m.command(&["seek", "0", "absolute"]);
            m.set_flag("pause", false);
            return;
        }
        let p = m.get_flag("pause").unwrap_or(false);
        m.set_flag("pause", !p);
    }

    fn seek(&self, t: f64) {
        if let Some(m) = self.mpv.as_ref() {
            let _ = m.command(&["seek", &format!("{:.3}", t.max(0.0)), "absolute+keyframes"]);
            self.pos.set(t);
            let g = self.g();
            g.set_pos(t as f32);
            g.set_pos_text(kit::clock(t).into());
            if let Some(tx) = self.mpris.borrow().as_ref() {
                let _ = tx.send(mpris::Update::Seeked(t));
            }
            self.poke();
        }
    }

    fn set_volume(&self, v: f32) {
        if let Some(m) = self.mpv.as_ref() {
            m.set_double("volume", v.clamp(0.0, 130.0) as f64);
            if v > 0.0 {
                m.set_flag("mute", false);
            }
        }
    }

    fn tell_bus(&self) {
        let Some(tx) = self.mpris.borrow().as_ref().cloned() else { return };
        let g = self.g();
        let has = self.current.borrow().is_some();
        let st = mpris::State {
            status: if !has {
                "Stopped".into()
            } else if g.get_paused() {
                "Paused".into()
            } else {
                "Playing".into()
            },
            loop_status: "None".into(),
            volume: (g.get_volume() as f64 / 100.0).min(1.0),
            id: self.track_id.get(),
            title: g.get_title().to_string(),
            length: self.dur.get(),
            can_next: g.get_playlist(),
            can_prev: g.get_playlist(),
            has_track: has,
            ..Default::default()
        };
        let _ = tx.send(mpris::Update::State(st));
    }

    /// The software path: draw mpv's frame into a buffer the size of the window.
    fn sw_frame(&self) {
        let sw = self.sw.borrow();
        let Some(r) = sw.as_ref() else { return };
        if !r.wants_frame() {
            return;
        }
        let scale = self.win.window().scale_factor();
        // Rows 64 bytes apart, as mpv likes them.
        let w = (((self.win.get_area_width() * scale) as i32) & !15).max(16);
        let h = ((self.win.get_area_height() * scale) as i32).max(16);
        let mut buf = SharedPixelBuffer::<Rgba8Pixel>::new(w as u32, h as u32);
        let bytes = buf.make_mut_bytes();
        r.draw_sw(w, h, w as usize * 4, bytes);
        for px in bytes.chunks_exact_mut(4) {
            px[3] = 255;
        }
        self.g().set_frame(slint::Image::from_rgba8(buf));
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).filter(|a| !a.starts_with("--")).collect();
    let targets: Vec<String> = args
        .iter()
        .map(|a| if a.contains("://") { a.clone() } else { std::fs::canonicalize(a).map(|p| p.to_string_lossy().to_string()).unwrap_or_else(|_| a.clone()) })
        .collect();
    let uris: Vec<String> = targets.iter().map(|t| if t.contains("://") { t.clone() } else { format!("file://{t}") }).collect();
    if mpris::hand_over(BUS, &uris) {
        return;
    }

    kit::init("hyprshell-video");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-video");

    let watch = state_dir().join("watch_later");
    let _ = std::fs::create_dir_all(&watch);
    let watch_s = watch.to_string_lossy().to_string();
    // HYPRSHELL_VIDEO_LOG=FILE: mpv's own account of what it did.
    let log = std::env::var("HYPRSHELL_VIDEO_LOG").unwrap_or_default();
    let mpv = Mpv::new(&[
        ("log-file", &log),
        ("vo", "libmpv"),
        ("hwdec", "auto-safe"),
        ("keep-open", "yes"),
        ("idle", "yes"),
        ("terminal", "no"),
        ("input-default-bindings", "no"),
        ("input-vo-keyboard", "no"),
        ("osc", "no"),
        // mpv's own overlays and scripts: ours are drawn by the app.
        ("load-scripts", "no"),
        ("load-stats-overlay", "no"),
        ("load-osd-console", "no"),
        ("load-auto-profiles", "no"),
        ("osd-level", "0"),
        ("audio-client-name", "Videos"),
        ("title", "Videos"),
        ("resume-playback", "yes"),
        ("watch-later-directory", &watch_s),
        ("watch-later-options", "start,volume,mute,sid,aid,speed"),
        ("sub-auto", "fuzzy"),
        ("ytdl", "no"),
        ("screenshot-directory", &kit::home().join("Pictures").to_string_lossy()),
    ]);

    // HYPRSHELL_VIDEO_MPV="name=value;name=value": more of mpv's options,
    // for whoever wants them (scalers, a different hwdec, debugging).
    if let Ok(m) = mpv.as_ref() {
        for kv in std::env::var("HYPRSHELL_VIDEO_MPV").unwrap_or_default().split(';') {
            if let Some((k, v)) = kv.split_once('=') {
                m.set_str(k.trim(), v.trim());
            }
        }
    }

    let recents: Vec<Seen> = std::fs::read_to_string(recent_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
    let (mpv, err) = match mpv {
        Ok(m) => (Some(m), None),
        Err(e) => (None, Some(e)),
    };

    let app = Rc::new(App {
        win: ui.clone_strong(),
        mpv: mpv.clone(),
        sw: RefCell::new(None),
        recents: RefCell::new(recents),
        current: RefCell::new(None),
        pos: Cell::new(0.0),
        dur: Cell::new(0.0),
        eof: Cell::new(false),
        speed: Cell::new(1.0),
        over_controls: Cell::new(false),
        subs: RefCell::new(Vec::new()),
        audios: RefCell::new(Vec::new()),
        mpris: RefCell::new(None),
        track_id: Cell::new(0),
        ready: Cell::new(false),
        waiting: RefCell::new(Vec::new()),
        hide_timer: slint::Timer::default(),
        toast_timer: slint::Timer::default(),
        keep_timer: slint::Timer::default(),
    });
    APP.with(|a| *a.borrow_mut() = Some(app.clone()));
    app.show_recents();
    if let Some(e) = err {
        app.fail(&e);
    }

    if let Some(m) = mpv.clone() {
        for (p, k) in [
            ("pause", "flag"),
            ("time-pos", "double"),
            ("duration", "double"),
            ("volume", "double"),
            ("mute", "flag"),
            ("media-title", "string"),
            ("paused-for-cache", "flag"),
            ("eof-reached", "flag"),
            ("speed", "double"),
            ("playlist-count", "int"),
            ("track-list", "none"),
            ("sid", "none"),
            ("aid", "none"),
        ] {
            m.observe(p, k);
        }
        // Events: taken on the UI thread, a batch per wake.
        let pending = Arc::new(AtomicBool::new(false));
        m.on_wakeup(move || {
            if !pending.swap(true, Ordering::AcqRel) {
                let pending = pending.clone();
                let _ = slint::invoke_from_event_loop(move || {
                    pending.store(false, Ordering::Release);
                    with_app(|a| a.mpv_events());
                });
            }
        });

        // The picture: by GPU when the window renders with GL, else by CPU.
        let gl: Rc<RefCell<Option<Gl>>> = Rc::new(RefCell::new(None));
        let weak = ui.as_weak();
        let mpv_gl = m.clone();
        let gl2 = gl.clone();
        let notified = ui.window().set_rendering_notifier(move |state, api| {
            let Some(ui) = weak.upgrade() else { return };
            match state {
                RenderingState::RenderingSetup => {
                    let GraphicsAPI::NativeOpenGL { get_proc_address } = api else { return };
                    // No Wayland display for mpv: its VA-API interop then opens the
                    // GPU's render node itself, which is the sturdier way (libva's
                    // Wayland path has been seen to crash on a borrowed display).
                    let display = std::ptr::null_mut();
                    let glc = unsafe { glow::Context::from_loader_function_cstr(|s| get_proc_address(s)) };
                    // On a software rasteriser (no GPU driver), mpv's full pipeline
                    // of half-float passes is slow and has drawn black frames;
                    // its plain one is right for it.
                    let renderer = unsafe { glow::HasContext::get_parameter_string(&glc, glow::RENDERER) }.to_lowercase();
                    if ["llvmpipe", "softpipe", "swrast", "software"].iter().any(|n| renderer.contains(n)) {
                        mpv_gl.set_str("gpu-dumb-mode", "yes");
                    }
                    match Render::gl(&mpv_gl, *get_proc_address, display) {
                        Ok(mut r) => {
                            let w = ui.as_weak();
                            r.on_update(move || {
                                let w = w.clone();
                                let _ = slint::invoke_from_event_loop(move || {
                                    if let Some(ui) = w.upgrade() {
                                        ui.window().request_redraw();
                                    }
                                });
                            });
                            *gl2.borrow_mut() = Some(Gl { gl: glc, render: r, tex: None, fbo: None, size: (0, 0) });
                            let _ = slint::invoke_from_event_loop(|| with_app(|a| a.drawable()));
                        }
                        Err(e) => eprintln!("video: no GL drawing ({e})"),
                    }
                }
                RenderingState::BeforeRendering => {
                    let mut st = gl2.borrow_mut();
                    let Some(st) = st.as_mut() else { return };
                    let scale = ui.window().scale_factor();
                    let w = (ui.get_area_width() * scale).round() as i32;
                    let h = (ui.get_area_height() * scale).round() as i32;
                    if w < 2 || h < 2 {
                        return;
                    }
                    let mut force = false;
                    if st.size != (w, h) {
                        unsafe { st.resize(w, h) };
                        let tex = st.tex.unwrap();
                        let img = unsafe {
                            slint::BorrowedOpenGLTextureBuilder::new_gl_2d_rgba_texture(tex.0, [w as u32, h as u32].into())
                        }
                        .origin(slint::BorrowedOpenGLTextureOrigin::TopLeft)
                        .build();
                        ui.global::<Video>().set_frame(img);
                        force = true;
                    }
                    if st.render.wants_frame() || force {
                        unsafe { st.draw() };
                    }
                }
                RenderingState::AfterRendering => {
                    if let Some(st) = gl2.borrow().as_ref() {
                        st.render.report_swap();
                    }
                }
                RenderingState::RenderingTeardown => {
                    *gl2.borrow_mut() = None;
                }
                _ => {}
            }
        });
        if notified.is_err() {
            // The software renderer: mpv draws on the CPU too, and copies
            // what the GPU decoded back to memory.
            m.set_str("hwdec", "auto-copy-safe");
            match Render::sw(&m) {
                Ok(mut r) => {
                    r.on_update(|| {
                        let _ = slint::invoke_from_event_loop(|| with_app(|a| a.sw_frame()));
                    });
                    *app.sw.borrow_mut() = Some(r);
                    app.drawable();
                }
                Err(e) => app.fail(&format!("mpv couldn't draw here ({e})")),
            }
        }
        // Keep `gl` (and the notifier's share of it) alive with the window.
        std::mem::forget(gl);

        let tx = mpris::serve(
            BUS,
            |r| {
                let _ = slint::invoke_from_event_loop(move || with_app(|a| remote(a, r)));
            },
            {
                let m = m.clone();
                move || m.get_double("time-pos").unwrap_or(0.0)
            },
        );
        *app.mpris.borrow_mut() = tx;
        app.tell_bus();
    }

    let g = ui.global::<Video>();
    let a = app.clone();
    g.on_open_dialog(move || {
        let b = a.clone();
        kit::spawn(
            || {
                kit::portal::open_files(
                    "Open a video",
                    &[
                        ("Videos", &["*.mp4", "*.mkv", "*.webm", "*.mov", "*.avi", "*.m4v", "*.mpg", "*.mpeg", "*.ts", "*.wmv", "*.flv", "*.ogv", "*.3gp"][..]),
                        ("All files", &["*"][..]),
                    ],
                )
            },
            move |files| b.open_many(files.into_iter().map(|p| p.to_string_lossy().to_string()).collect()),
        );
    });
    let a = app.clone();
    g.on_open_recent(move |p| {
        if p.contains("://") || Path::new(p.as_str()).exists() {
            a.open(p.to_string());
        } else {
            a.toast("That file has moved or gone");
        }
    });
    let a = app.clone();
    g.on_forget_recent(move |p| {
        a.recents.borrow_mut().retain(|r| r.path != p.as_str());
        a.save_recents();
        a.show_recents();
    });
    let a = app.clone();
    g.on_toggle(move || a.toggle());
    let a = app.clone();
    g.on_seek(move |t| a.seek(t as f64));
    let a = app.clone();
    g.on_seek_by(move |d| {
        let t = (a.pos.get() + d as f64).clamp(0.0, a.dur.get().max(0.0));
        a.seek(t);
    });
    let a = app.clone();
    g.on_set_volume(move |v| a.set_volume(v));
    let a = app.clone();
    g.on_toggle_mute(move || {
        if let Some(m) = a.mpv.as_ref() {
            let mu = m.get_flag("mute").unwrap_or(false);
            m.set_flag("mute", !mu);
        }
    });
    let a = app.clone();
    g.on_toggle_fullscreen(move || {
        let on = !a.g().get_fullscreen();
        a.fullscreen(on);
    });
    let a = app.clone();
    g.on_poke(move || a.poke());
    let a = app.clone();
    g.on_over_controls(move |on| {
        a.over_controls.set(on);
        if !on {
            a.poke();
        }
    });
    let a = app.clone();
    g.on_pick_sub(move |i| {
        let Some(m) = a.mpv.as_ref() else { return };
        let subs = a.subs.borrow().clone();
        if i == -2 {
            // The next one, round to off.
            let _ = m.command(&["cycle", "sub"]);
            let s = m.get_str("sid").unwrap_or_default();
            a.toast(&if s == "no" || s.is_empty() { "Subtitles off".to_string() } else { format!("Subtitles: {s}") });
        } else if i == 0 {
            m.set_str("sid", "no");
        } else if let Some(id) = subs.get(i as usize - 1) {
            m.set_str("sid", &id.to_string());
        }
    });
    let a = app.clone();
    g.on_pick_audio(move |i| {
        let Some(m) = a.mpv.as_ref() else { return };
        if let Some(id) = a.audios.borrow().get(i.max(0) as usize) {
            m.set_str("aid", &id.to_string());
        }
    });
    let a = app.clone();
    g.on_pick_speed(move |i| {
        let Some(m) = a.mpv.as_ref() else { return };
        let cur = a.speed.get();
        let s = match i {
            -2 => SPEEDS.iter().copied().find(|&s| s > cur + 0.01).unwrap_or(2.0),
            -3 => SPEEDS.iter().rev().copied().find(|&s| s < cur - 0.01).unwrap_or(0.5),
            i => SPEEDS.get(i.max(0) as usize).copied().unwrap_or(1.0),
        };
        m.set_double("speed", s);
        if i < 0 {
            a.toast(&format!("Speed {}×", s));
        }
    });
    let a = app.clone();
    g.on_next(move || {
        if let Some(m) = a.mpv.as_ref() {
            let _ = m.command(&["playlist-next"]);
        }
    });
    let a = app.clone();
    g.on_prev(move || {
        if let Some(m) = a.mpv.as_ref() {
            let _ = m.command(&["playlist-prev"]);
        }
    });
    let a = app.clone();
    g.on_close_video(move || a.close_video());

    // Keep the place every little while, in case of a crash or a power cut.
    let a = app.clone();
    app.keep_timer.start(slint::TimerMode::Repeated, Duration::from_secs(15), move || {
        if a.current.borrow().is_some() && !a.g().get_paused() {
            a.remember();
        }
    });

    if !targets.is_empty() {
        let a = app.clone();
        slint::Timer::single_shot(Duration::from_millis(80), move || a.open_many(targets));
    }

    ui.run().expect("run");
    app.remember();
    *app.sw.borrow_mut() = None;
}

impl App {
    /// One or more: the first plays, the rest follow it.
    fn open_many(&self, paths: Vec<String>) {
        let Some(m) = self.mpv.as_ref() else { return };
        if !self.ready.get() {
            // A video opened before mpv can draw gets no picture at all.
            self.waiting.borrow_mut().extend(paths);
            return;
        }
        let mut it = paths.into_iter();
        let Some(first) = it.next() else { return };
        self.open(first);
        for p in it {
            let _ = m.command(&["loadfile", &p, "append"]);
        }
    }
}

impl App {
    /// mpv can draw now: open what was waiting.
    fn drawable(&self) {
        self.ready.set(true);
        let w: Vec<String> = std::mem::take(&mut *self.waiting.borrow_mut());
        if !w.is_empty() {
            self.open_many(w);
        }
    }
}

fn remote(a: &Rc<App>, r: mpris::Remote) {
    use mpris::Remote as R;
    let Some(m) = a.mpv.clone() else { return };
    match r {
        R::Raise => {
            let _ = a.win.show();
        }
        R::Quit => {
            a.remember();
            let _ = slint::quit_event_loop();
        }
        R::Play => m.set_flag("pause", false),
        R::Pause => m.set_flag("pause", true),
        R::PlayPause => a.toggle(),
        R::Stop => a.close_video(),
        R::Next => {
            let _ = m.command(&["playlist-next"]);
        }
        R::Previous => {
            let _ = m.command(&["playlist-prev"]);
        }
        R::Seek(d) => a.seek(a.pos.get() + d),
        R::SetPosition(p) => a.seek(p),
        R::Open(uri) => {
            let (uri, queue) = match uri.strip_suffix("#queue") {
                Some(u) => (u.to_string(), true),
                None => (uri, false),
            };
            let target = kit::portal::uri_to_path(&uri).map(|p| p.to_string_lossy().to_string()).unwrap_or(uri);
            if queue && a.current.borrow().is_some() {
                let _ = m.command(&["loadfile", &target, "append"]);
            } else {
                a.open(target);
            }
        }
        R::Volume(v) => a.set_volume((v * 100.0) as f32),
        R::Shuffle(_) | R::Loop(_) => {}
    }
}
