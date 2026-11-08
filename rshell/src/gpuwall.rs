//! The animated wallpapers on the graphics card, for the wallpaper surface alone: an EGL surface
//! on its Wayland surface and the styles' own fragment shaders (shaders/*.frag, the ones
//! modules/background/shaders has, with their uniform block turned into plain uniforms for
//! OpenGL ES 3). The rest of the shell draws into shared memory as before.
//!
//! Frames are drawn at the screen's own pixels at the chosen rate, and while the picture can't
//! be seen nothing is drawn at all: the compositor keeps showing the last frame, so a held
//! wallpaper costs neither the processor nor the card.

use crate::anim::Screen;
use glow::HasContext;
use khronos_egl as egl;
use std::collections::HashMap;
use std::time::{Duration, Instant};
use wayland_backend::client::ObjectId;

const VERT: &str = "#version 300 es
out vec2 qt_TexCoord0;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    qt_TexCoord0 = vec2(p.x, 1.0 - p.y);
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
";

fn source(style: &str) -> Option<&'static str> {
    Some(match style {
        "topo" => include_str!("../shaders/topo.frag"),
        "aurora" => include_str!("../shaders/aurora.frag"),
        "blobs" => include_str!("../shaders/blobs.frag"),
        "cells" => include_str!("../shaders/cells.frag"),
        "stars" => include_str!("../shaders/stars.frag"),
        "synth" => include_str!("../shaders/synth.frag"),
        "waves" => include_str!("../shaders/waves.frag"),
        _ => return None,
    })
}

/// A Vulkan-style GLSL 4.40 fragment shader as OpenGL ES 3.00: the version line, the uniform
/// block as loose uniforms, the two Qt names gone.
fn es(src: &str) -> String {
    let mut out = String::from("#version 300 es\nprecision highp float;\nprecision highp int;\nconst float qt_Opacity = 1.0;\n");
    let mut in_block = false;
    for line in src.lines() {
        let t = line.trim();
        if t.starts_with("#version") {
            continue;
        }
        if t.starts_with("layout(std140") {
            in_block = true;
            continue;
        }
        if in_block {
            if t.starts_with('}') {
                in_block = false;
                continue;
            }
            let decl = t.split("//").next().unwrap_or("").trim();
            if decl.is_empty() || decl.contains("qt_Matrix") || decl.contains("qt_Opacity") {
                continue;
            }
            out += &format!("uniform {decl}\n");
            continue;
        }
        if t.starts_with("layout(location = 0) in vec2 qt_TexCoord0") {
            out += "in vec2 qt_TexCoord0;\n";
            continue;
        }
        out += line;
        out.push('\n');
    }
    out
}

struct Prog {
    p: glow::Program,
    loc: HashMap<String, glow::UniformLocation>,
}

struct Out {
    /// 0: the desktop's wallpaper, 1: behind the lock screen or the login screen.
    group: u8,
    bar: usize,
    /// The surface drawn on, to tell whether it is still there.
    child: ObjectId,
    win: wayland_egl::WlEglSurface,
    surf: egl::Surface,
    size: (u32, u32),
    s: Screen,
    time: f32,
    rise: f32,
    last: Instant,
    drawn: bool,
}

/// What the card asks of the shell about a surface.
pub enum Ask {
    /// Is it still there?
    Alive,
    /// May the next frame be drawn on it?
    Begin,
}

pub struct Gpu {
    egl: egl::DynamicInstance<egl::EGL1_4>,
    display: egl::Display,
    config: egl::Config,
    ctx: egl::Context,
    gl: Option<glow::Context>,
    vao: Option<glow::VertexArray>,
    progs: HashMap<String, Option<Prog>>,
    outs: Vec<Out>,
    still: Vec<usize>,
}

impl Gpu {
    /// EGL on the shell's own Wayland connection. None where there is no usable card or driver.
    pub fn new(display_ptr: *mut std::ffi::c_void) -> Result<Gpu, String> {
        // SAFETY: loading libEGL, as the crate documents.
        let egl = unsafe { egl::DynamicInstance::<egl::EGL1_4>::load_required() }.map_err(|e| format!("no libEGL ({e})"))?;
        // SAFETY: the pointer is the live wl_display of the connection the shell holds.
        let display = unsafe { egl.get_display(display_ptr) }.ok_or("no EGL display")?;
        egl.initialize(display).map_err(|e| format!("EGL won't start ({e})"))?;
        egl.bind_api(egl::OPENGL_ES_API).map_err(|e| format!("no OpenGL ES ({e})"))?;
        let attribs = [egl::SURFACE_TYPE, egl::WINDOW_BIT, egl::RENDERABLE_TYPE, egl::OPENGL_ES3_BIT, egl::RED_SIZE, 8, egl::GREEN_SIZE, 8, egl::BLUE_SIZE, 8, egl::NONE];
        let config = egl.choose_first_config(display, &attribs).map_err(|e| format!("EGL config ({e})"))?.ok_or("no EGL config for OpenGL ES 3")?;
        let ctx = egl.create_context(display, config, None, &[egl::CONTEXT_CLIENT_VERSION, 3, egl::NONE]).map_err(|e| format!("no OpenGL ES 3 context ({e})"))?;
        Ok(Gpu { egl, display, config, ctx, gl: None, vao: None, progs: HashMap::new(), outs: Vec::new(), still: Vec::new() })
    }

    /// The screens of one group drawn on the card now, each with the surface it draws on and that
    /// surface's size in device pixels. A screen no longer listed lets go of its surface.
    pub fn set_outputs(&mut self, group: u8, list: Vec<(Screen, ObjectId)>) {
        let wanted: Vec<usize> = list.iter().map(|l| l.0.bar).collect();
        let (keep, gone): (Vec<Out>, Vec<Out>) = std::mem::take(&mut self.outs).into_iter().partition(|o| o.group != group || wanted.contains(&o.bar));
        self.outs = keep;
        for o in gone {
            self.release(o);
        }
        for (s, id) in list {
            let size = (s.w, s.h);
            if let Some(o) = self.outs.iter_mut().find(|o| o.group == group && o.bar == s.bar) {
                if o.size != size {
                    o.win.resize(size.0 as i32, size.1 as i32, 0, 0);
                    o.size = size;
                }
                if o.s.style != s.style {
                    o.time = 0.0;
                    o.rise = 0.0;
                }
                if o.s != s {
                    o.s = s;
                    o.drawn = false;
                }
                continue;
            }
            let child = id.clone();
            let Ok(win) = wayland_egl::WlEglSurface::new(id, size.0 as i32, size.1 as i32) else { continue };
            // SAFETY: the window pointer lives as long as `win`, which the output keeps.
            let surf = unsafe { self.egl.create_window_surface(self.display, self.config, win.ptr() as egl::NativeWindowType, None) };
            let Ok(surf) = surf else { continue };
            self.outs.push(Out { group, bar: s.bar, child, win, surf, size, s, time: 0.0, rise: 0.0, last: Instant::now(), drawn: false });
        }
    }

    /// The card given up on: every output let go of, and the library left loaded (unloading it
    /// while Mesa still holds callbacks into it is what would bring the process down).
    pub fn retire(mut self) {
        for o in std::mem::take(&mut self.outs) {
            self.release(o);
        }
        std::mem::forget(self);
    }

    /// An output's EGL surface, then its window, are let go.
    fn release(&mut self, o: Out) {
        let _ = self.egl.make_current(self.display, None, None, None);
        let _ = self.egl.destroy_surface(self.display, o.surf);
        drop(o.win);
    }

    pub fn holds(&self, group: u8, bar: usize) -> bool {
        self.outs.iter().any(|o| o.group == group && o.bar == bar)
    }

    /// Which screens can't be seen now (nothing is drawn on them).
    pub fn set_still(&mut self, still: Vec<usize>) {
        self.still = still;
    }

    /// How long until the next frame is due, if anything is moving.
    pub fn next_due(&self) -> Option<Duration> {
        let now = Instant::now();
        self.outs
            .iter()
            .filter(|o| self.moves(o))
            .map(|o| (o.last + Duration::from_micros(1_000_000 / o.s.fps.max(1) as u64)).saturating_duration_since(now))
            .min()
    }

    fn moves(&self, o: &Out) -> bool {
        (o.group != 0 || !self.still.contains(&o.bar)) && (o.s.style != "topo" || o.s.topo.drift)
    }

    fn prog(&mut self, style: &str) -> Option<&Prog> {
        if !self.progs.contains_key(style) {
            let made = self.compile(style);
            self.progs.insert(style.to_string(), made);
        }
        self.progs.get(style).and_then(|p| p.as_ref())
    }

    fn compile(&self, style: &str) -> Option<Prog> {
        let gl = self.gl.as_ref()?;
        let src = es(source(style)?);
        // SAFETY: plain OpenGL calls with the context current.
        unsafe {
            let p = gl.create_program().ok()?;
            let mut shaders = Vec::new();
            for (kind, text) in [(glow::VERTEX_SHADER, VERT.to_string()), (glow::FRAGMENT_SHADER, src.clone())] {
                let sh = gl.create_shader(kind).ok()?;
                gl.shader_source(sh, &text);
                gl.compile_shader(sh);
                if !gl.get_shader_compile_status(sh) {
                    eprintln!("hyprshell-rs: the {style} wallpaper's shader: {}", gl.get_shader_info_log(sh));
                    return None;
                }
                gl.attach_shader(p, sh);
                shaders.push(sh);
            }
            gl.link_program(p);
            if !gl.get_program_link_status(p) {
                eprintln!("hyprshell-rs: the {style} wallpaper's program: {}", gl.get_program_info_log(p));
                return None;
            }
            for sh in shaders {
                gl.detach_shader(p, sh);
                gl.delete_shader(sh);
            }
            let mut loc = HashMap::new();
            for line in src.lines().filter(|l| l.starts_with("uniform ")) {
                let name = line.trim_end_matches(';').split_whitespace().last().unwrap_or("");
                if let Some(l) = gl.get_uniform_location(p, name) {
                    loc.insert(name.to_string(), l);
                }
            }
            Some(Prog { p, loc })
        }
    }

    /// Draws what is due. The screens whose style the card couldn't compile are returned, to be
    /// drawn the other way.
    pub fn frame(&mut self, env: &mut dyn FnMut(u8, usize, &ObjectId, Ask) -> bool) -> Vec<(u8, usize)> {
        // What has lost its surface (a lock screen gone, a screen unplugged) is let go before
        // anything is drawn: swapping buffers on a surface that is gone brings the process down.
        let (keep, gone): (Vec<Out>, Vec<Out>) = std::mem::take(&mut self.outs).into_iter().partition(|o| env(o.group, o.bar, &o.child, Ask::Alive));
        self.outs = keep;
        for o in gone {
            self.release(o);
        }
        let mut failed = Vec::new();
        let now = Instant::now();
        for i in 0..self.outs.len() {
            let (key, due) = {
                let o = &self.outs[i];
                let interval = Duration::from_micros(1_000_000 / o.s.fps.max(1) as u64);
                ((o.group, o.bar), !o.drawn || (self.moves(o) && now.duration_since(o.last) >= interval))
            };
            if !due {
                continue;
            }
            // Only when the compositor has shown the last frame: with the screen off it never
            // does, and a swap would wait for it for good.
            let (g, b, c) = (self.outs[i].group, self.outs[i].bar, self.outs[i].child.clone());
            if !env(g, b, &c, Ask::Begin) {
                continue;
            }
            if self.draw(i, now).is_none() {
                failed.push(key);
            }
        }
        failed.sort_unstable();
        failed.dedup();
        let (keep, gone): (Vec<Out>, Vec<Out>) = std::mem::take(&mut self.outs).into_iter().partition(|o| !failed.contains(&(o.group, o.bar)));
        self.outs = keep;
        for o in gone {
            self.release(o);
        }
        failed
    }

    fn draw(&mut self, i: usize, now: Instant) -> Option<()> {
        let surf = self.outs[i].surf;
        self.egl.make_current(self.display, Some(surf), Some(surf), Some(self.ctx)).ok()?;
        if self.gl.is_none() {
            let egl = &self.egl;
            // SAFETY: the loader asks EGL for OpenGL ES entry points, with the context current.
            let gl = unsafe { glow::Context::from_loader_function_cstr(|name| egl.get_proc_address(name.to_str().unwrap_or("")).map_or(std::ptr::null(), |f| f as *const _)) };
            // SAFETY: as above.
            let vao = unsafe { gl.create_vertex_array().ok() };
            self.vao = vao;
            self.gl = Some(gl);
            let _ = self.egl.swap_interval(self.display, 0);
        }
        let style = self.outs[i].s.style.clone();
        self.prog(&style)?;
        // Time moves by what has passed since the last frame, at the style's own speed.
        let o = &mut self.outs[i];
        let dt = now.duration_since(o.last).as_secs_f32().min(0.25);
        if o.drawn {
            if style == "topo" {
                let d = dt * o.s.topo.speed;
                if o.s.topo.move_terrain {
                    o.time += d;
                }
                if o.s.topo.move_lines {
                    o.rise += d * 0.35;
                }
            } else {
                o.time += dt * o.s.speed;
            }
        }
        o.last = now;
        o.drawn = true;
        let (s, time, rise, size) = (o.s.clone(), o.time, o.rise, o.size);
        let gl = self.gl.as_ref()?;
        let prog = self.progs.get(&style)?.as_ref()?;
        let logical = (s.w as f32 / s.scale, s.h as f32 / s.scale);
        // SAFETY: plain OpenGL calls with the context current and the program built for it.
        unsafe {
            gl.viewport(0, 0, size.0 as i32, size.1 as i32);
            gl.use_program(Some(prog.p));
            let f1 = |n: &str, v: f32| {
                if let Some(l) = prog.loc.get(n) {
                    gl.uniform_1_f32(Some(l), v);
                }
            };
            let f2 = |n: &str, v: (f32, f32)| {
                if let Some(l) = prog.loc.get(n) {
                    gl.uniform_2_f32(Some(l), v.0, v.1);
                }
            };
            let f4 = |n: &str, v: [f32; 3]| {
                if let Some(l) = prog.loc.get(n) {
                    gl.uniform_4_f32(Some(l), v[0], v[1], v[2], 1.0);
                }
            };
            f2("origin", s.origin);
            f2("size", logical);
            f2("seedOffset", s.seed);
            f1("time", time);
            f1("rise", rise);
            f1("unit", s.unit);
            f1("dpr", s.scale);
            f1("density", s.density);
            f1("glow", s.glow);
            f1("intensity", s.intensity);
            f4("bg1", s.pal.bg1);
            f4("bg2", s.pal.bg2);
            f4("c1", s.pal.c1);
            f4("c2", s.pal.c2);
            f4("c3", s.pal.c3);
            let t = &s.topo;
            f1("detail", t.detail);
            f1("warp", t.warp);
            f1("levels", t.levels);
            f1("lineWidth", t.line_width);
            f1("majorEvery", t.major_every);
            f1("lineAlpha", t.line_alpha);
            f1("shade", t.shade);
            f1("glowAmt", t.glow);
            f4("lineColor", t.line);
            f4("bgLow", t.low);
            f4("bgHigh", t.high);
            if let Some(v) = self.vao {
                gl.bind_vertex_array(Some(v));
            }
            gl.draw_arrays(glow::TRIANGLES, 0, 3);
        }
        self.egl.swap_buffers(self.display, surf).ok()?;
        Some(())
    }
}
