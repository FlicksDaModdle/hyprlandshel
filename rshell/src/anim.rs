//! The animated wallpapers (modules/background/AnimatedWallpaper.qml, Topography.qml and their
//! fragment shaders), run on the processor: the shell draws into shared memory with no graphics
//! context of its own, so each style's shader is written out here and evaluated per pixel,
//! across all the cores, on a thread of its own.
//!
//! The picture is rendered at a size that keeps a frame inside its time (the compositor
//! stretches it to the screen, as it does the still wallpaper), and the thread keeps still
//! while the picture can't be seen: covered by windows, on battery, power saver.

use serde_json::Value;
use std::sync::mpsc::{channel, sync_channel, Receiver, RecvTimeoutError, Sender, SyncSender};
use std::time::{Duration, Instant};

type V2 = (f32, f32);
type V3 = [f32; 3];

// ── a little GLSL ─────────────────────────────────────────────────────

fn fract(x: f32) -> f32 {
    x - x.floor()
}
fn mix(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}
fn mix3(a: V3, b: V3, t: f32) -> V3 {
    [mix(a[0], b[0], t), mix(a[1], b[1], t), mix(a[2], b[2], t)]
}
fn smoothstep(e0: f32, e1: f32, x: f32) -> f32 {
    let t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
fn madd(c: V3, k: V3, s: f32) -> V3 {
    [c[0] + k[0] * s, c[1] + k[1] * s, c[2] + k[2] * s]
}

/// Dave Hoskins' hash without sine, as the shaders have it.
fn hash1(p: V2) -> f32 {
    let (mut a, mut b, mut c) = (fract(p.0 * 0.1031), fract(p.1 * 0.1031), fract(p.0 * 0.1031));
    let d = a * (b + 33.33) + b * (c + 33.33) + c * (a + 33.33);
    a += d;
    b += d;
    c += d;
    fract((a + b) * c)
}
fn hash2(p: V2) -> V2 {
    let (mut a, mut b, mut c) = (fract(p.0 * 0.1031), fract(p.1 * 0.1030), fract(p.0 * 0.0973));
    let d = a * (b + 33.33) + b * (c + 33.33) + c * (a + 33.33);
    a += d;
    b += d;
    c += d;
    (fract((a + b) * c), fract((a + c) * b))
}
fn noise(p: V2) -> f32 {
    let (ix, iy) = (p.0.floor(), p.1.floor());
    let (fx, fy) = (p.0 - ix, p.1 - iy);
    let (ux, uy) = (fx * fx * (3.0 - 2.0 * fx), fy * fy * (3.0 - 2.0 * fy));
    let (a, b) = (hash1((ix, iy)), hash1((ix + 1.0, iy)));
    let (c, d) = (hash1((ix, iy + 1.0)), hash1((ix + 1.0, iy + 1.0)));
    mix(mix(a, b, ux), mix(c, d, ux), uy)
}
fn fbm(mut p: V2) -> f32 {
    let (mut s, mut a) = (0.0, 0.5);
    for _ in 0..5 {
        s += a * noise(p);
        p = ((0.8 * p.0 - 0.6 * p.1) * 2.02 + 3.1, (0.6 * p.0 + 0.8 * p.1) * 2.02 + 3.1);
        a *= 0.5;
    }
    s
}

// ── what a style is told ──────────────────────────────────────────────

#[derive(Clone, PartialEq, Debug)]
pub struct Palette {
    pub bg1: V3,
    pub bg2: V3,
    pub c1: V3,
    pub c2: V3,
    pub c3: V3,
}

#[derive(Clone, PartialEq, Debug)]
pub struct Topo {
    pub detail: f32,
    pub warp: f32,
    pub levels: f32,
    pub line_width: f32,
    pub major_every: f32,
    pub line_alpha: f32,
    /// 0 flat, 1 smooth, 2 bands
    pub shade: f32,
    pub glow: f32,
    pub line: V3,
    pub low: V3,
    pub high: V3,
    pub drift: bool,
    pub move_terrain: bool,
    pub move_lines: bool,
    pub speed: f32,
}

/// One screen's wallpaper.
#[derive(Clone, PartialEq, Debug)]
pub struct Screen {
    pub bar: usize,
    /// Device pixels, the screen's scale, and where it is in the layout (logical px).
    pub w: u32,
    pub h: u32,
    pub scale: f32,
    pub origin: V2,
    pub style: String,
    pub pal: Palette,
    pub seed: V2,
    pub unit: f32,
    pub density: f32,
    pub glow: f32,
    pub intensity: f32,
    pub speed: f32,
    pub fps: u32,
    pub topo: Topo,
}

pub fn is_animated(style: &str) -> bool {
    ["topo", "aurora", "blobs", "cells", "stars", "synth", "waves"].contains(&style)
}

/// Palettes.js
const PRESETS: [(&str, &str, &str, &str, &str, &str); 10] = [
    ("aurora", "#040c18", "#0b2536", "#3cffb4", "#3fa7ff", "#b46cff"),
    ("sunset", "#160a2b", "#5b1f4f", "#ff7a59", "#ffb347", "#ff3d7f"),
    ("ocean", "#021526", "#063b5b", "#2ec4ff", "#57f0d4", "#1b6dff"),
    ("forest", "#0b1a12", "#1e3a2a", "#8ad86b", "#e8d36b", "#3fbf9b"),
    ("neon", "#0a0014", "#1b0033", "#ff2bd6", "#00f0ff", "#fff200"),
    ("ember", "#120604", "#2b0f08", "#ff5a1f", "#ffb000", "#ff2a2a"),
    ("rose", "#1d1016", "#3a1d2a", "#ff9ec4", "#ffd1dc", "#c27dff"),
    ("mono", "#0f1011", "#1d1f21", "#e8e8e8", "#9a9a9a", "#5f5f5f"),
    ("paper", "#f4efe6", "#e3d8c5", "#b04a2f", "#2f6f8f", "#3a3a3a"),
    ("mint", "#eef7f2", "#cfe8dc", "#16a37a", "#3f7fd9", "#0f5c45"),
];

fn hex(s: &str) -> Option<V3> {
    let h = s.trim().trim_start_matches('#');
    if h.len() < 6 {
        return None;
    }
    let p = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok().map(|v| v as f32 / 255.0);
    Some([p(0)?, p(2)?, p(4)?])
}

fn darker(c: V3, f: f32) -> V3 {
    [c[0] / f, c[1] / f, c[2] / f]
}

fn rgb_to_hsl(c: V3) -> (f32, f32, f32) {
    let (mx, mn) = (c[0].max(c[1]).max(c[2]), c[0].min(c[1]).min(c[2]));
    let l = (mx + mn) / 2.0;
    if mx == mn {
        return (0.0, 0.0, l);
    }
    let d = mx - mn;
    let s = if l > 0.5 { d / (2.0 - mx - mn) } else { d / (mx + mn) };
    let h = if mx == c[0] { (c[1] - c[2]) / d + if c[1] < c[2] { 6.0 } else { 0.0 } } else if mx == c[1] { (c[2] - c[0]) / d + 2.0 } else { (c[0] - c[1]) / d + 4.0 };
    (h / 6.0, s, l)
}

fn hsl_to_rgb(h: f32, s: f32, l: f32) -> V3 {
    let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
    let p = 2.0 * l - q;
    let f = |mut t: f32| {
        if t < 0.0 {
            t += 1.0
        }
        if t > 1.0 {
            t -= 1.0
        }
        if t < 1.0 / 6.0 {
            p + (q - p) * 6.0 * t
        } else if t < 0.5 {
            q
        } else if t < 2.0 / 3.0 {
            p + (q - p) * (2.0 / 3.0 - t) * 6.0
        } else {
            p
        }
    };
    [f(h + 1.0 / 3.0), f(h), f(h - 1.0 / 3.0)]
}

/// AnimatedWallpaper.hueShift
fn hue_shift(c: V3, d: f32) -> V3 {
    let (h, s, l) = rgb_to_hsl(c);
    hsl_to_rgb((h + d + 1.0) % 1.0, s.max(0.35), l)
}

fn seed_pair(seed: f32, scale: f32, off: f32) -> V2 {
    let r = |n: f32| {
        let x = (n as f64).sin() * 43758.5453;
        (x - x.floor()) as f32
    };
    (r(seed * 12.9898) * scale + off, r(seed * 78.233) * scale + off)
}

/// What theme.json asks for on one screen. `tint` is the theme's two ground colours (Appearance.tintSpec
/// a and b), `accent` and `ink` the theme's.
pub fn screen_for(raw: &Value, dark: bool, tint: (V3, V3), accent: V3, ink: V3, geo: (usize, u32, u32, f32, V2)) -> Screen {
    let num = |k: &str, d: f64| raw[k].as_f64().unwrap_or(d) as f32;
    let key = raw["animPalette"].as_str().unwrap_or("theme");
    let col = |k: &str, d: V3| raw[k].as_str().and_then(hex).unwrap_or(d);
    let pal = if key == "custom" {
        Palette { bg1: col("animBg1", [0.0; 3]), bg2: col("animBg2", [0.1; 3]), c1: col("animC1", [1.0; 3]), c2: col("animC2", [0.8; 3]), c3: col("animC3", [0.6; 3]) }
    } else if let Some(p) = PRESETS.iter().find(|p| p.0 == key) {
        let c = |s: &str| hex(s).unwrap_or([0.5; 3]);
        Palette { bg1: c(p.1), bg2: c(p.2), c1: c(p.3), c2: c(p.4), c3: c(p.5) }
    } else {
        Palette { bg1: darker(tint.1, if dark { 1.35 } else { 1.05 }), bg2: tint.0, c1: accent, c2: hue_shift(accent, 0.10), c3: hue_shift(accent, -0.12) }
    };
    let style = raw["wallpaperStyle"].as_str().unwrap_or("gradient").to_string();
    let topo_ground_custom = raw["topoGround"].as_str() == Some("custom");
    let line = match raw["topoLine"].as_str().unwrap_or("ink") {
        "accent" => accent,
        "custom" => col("topoLineCustom", ink),
        _ => ink,
    };
    let motion = raw["topoMotion"].as_str().unwrap_or("both");
    let topo = Topo {
        detail: num("topoDetail", 4.0).clamp(1.0, 6.0),
        warp: num("topoFlow", 45.0) / 100.0,
        levels: num("topoLevels", 18.0).max(2.0),
        line_width: num("topoWidth", 1.2) * geo.3,
        major_every: num("topoMajor", 5.0),
        line_alpha: num("topoStrength", 30.0) / 100.0,
        shade: match raw["topoShade"].as_str().unwrap_or("smooth") {
            "bands" => 2.0,
            "smooth" => 1.0,
            _ => 0.0,
        },
        glow: num("topoGlow", 0.0) / 100.0,
        line,
        low: if topo_ground_custom { col("topoLow", [0.1; 3]) } else { darker(tint.1, if dark { 1.35 } else { 1.05 }) },
        high: if topo_ground_custom { col("topoHigh", [0.2; 3]) } else { tint.0 },
        drift: raw["topoDrift"].as_bool().unwrap_or(true),
        move_terrain: motion != "flow",
        move_lines: motion != "drift",
        speed: num("topoSpeed", 30.0).max(5.0) / 30.0,
    };
    let topo_scale = num("topoScale", 100.0).max(25.0) / 100.0;
    let anim_scale = num("animScale", 100.0).max(25.0) / 100.0;
    let is_topo = style == "topo";
    Screen {
        bar: geo.0,
        w: geo.1,
        h: geo.2,
        scale: geo.3,
        origin: geo.4,
        style,
        pal,
        seed: if is_topo { seed_pair(num("topoSeed", 1.0), 240.0, -120.0) } else { seed_pair(num("animSeed", 1.0), 97.0, 0.0) },
        unit: 650.0 * if is_topo { topo_scale } else { anim_scale },
        density: num("animDensity", 50.0) / 100.0,
        glow: num("animGlow", 50.0) / 100.0,
        intensity: num("animIntensity", 70.0) / 100.0,
        speed: num("animWallSpeed", 100.0) / 100.0,
        fps: (num("animFps", 30.0) as u32).clamp(10, 60),
        topo,
    }
}

// ── the styles ────────────────────────────────────────────────────────

struct Ctx<'a> {
    s: &'a Screen,
    time: f32,
    rise: f32,
    /// Size in logical px, and in render pixels.
    size: V2,
    rw: usize,
    rh: usize,
}

fn dither(c: V3, x: usize, y: usize, t: f32) -> V3 {
    let n = (hash1((x as f32 + fract(t), y as f32)) - 0.5) / 255.0;
    [c[0] + n, c[1] + n, c[2] + n]
}

fn sparkle(px: V2, chance: f32, t: f32, seed: V2) -> f32 {
    const CELL: f32 = 22.0;
    let g = (px.0 / CELL, px.1 / CELL);
    let id = (g.0.floor(), g.1.floor());
    let h = hash2((id.0 + seed.0, id.1 + seed.1));
    if h.0 > chance {
        return 0.0;
    }
    let o = hash2((id.0 + seed.0 + 17.0, id.1 + seed.1 + 17.0));
    let pos = (id.0 + 0.15 + 0.7 * o.0, id.1 + 0.15 + 0.7 * o.1);
    let d = ((g.0 - pos.0).hypot(g.1 - pos.1)) * CELL;
    let r = 0.6 + 0.9 * h.1;
    let tw = 0.6 + 0.4 * (t * (0.8 + 1.6 * h.1) + h.1 * 50.0).sin();
    tw * (0.45 + 0.55 * h.1) * ((1.0 - smoothstep(0.0, r, d)) + 0.25 * (-d / (r * 1.8)).exp())
}

fn star_layer(px: V2, cell: f32, chance: f32, t: f32, seed: f32) -> f32 {
    let g = (px.0 / cell, px.1 / cell);
    let id = (g.0.floor(), g.1.floor());
    let h = hash2((id.0 + seed, id.1 + seed));
    if h.0 > chance {
        return 0.0;
    }
    let o = hash2((id.0 + seed + 7.0, id.1 + seed + 7.0));
    let pos = (id.0 + 0.2 + 0.6 * o.0, id.1 + 0.2 + 0.6 * o.1);
    let d = ((g.0 - pos.0).hypot(g.1 - pos.1)) * cell;
    let tw = 0.65 + 0.35 * (t * (1.0 + 2.0 * h.1) + h.1 * 40.0).sin();
    let r = 0.6 + 1.4 * h.1;
    tw * (1.0 - smoothstep(r * 0.4, r, d)) + tw * 0.25 * (-d / (r * 2.5)).exp()
}

/// Everything a column of pixels shares, for the styles that hang off x alone.
struct Columns {
    a: Vec<f32>,
    b: Vec<f32>,
    n: usize,
}

fn aurora_columns(c: &Ctx) -> Columns {
    let s = c.s;
    let n = (2.0 + s.density * 4.0) as usize;
    let mut a = vec![0.0; c.rw * 6];
    let mut b = vec![0.0; c.rw * 6];
    for x in 0..c.rw {
        let u = (x as f32 + 0.5) / c.rw as f32;
        let px = s.origin.0 + u * c.size.0;
        let xx = px / s.unit + s.seed.0;
        for i in 0..n.min(6) {
            let fi = i as f32;
            a[x * 6 + i] = (xx * 1.1 + c.time * 0.31 + fi * 1.7).sin() * 0.07 + (xx * 2.7 - c.time * 0.23 + fi * 0.9).sin() * 0.035 + (fbm((xx * 0.7 + fi * 3.1, c.time * 0.06)) - 0.5) * 0.18;
            b[x * 6 + i] = 0.45 + 0.55 * fbm((xx * 9.0 + fi * 7.0, c.time * 0.25 + fi));
        }
    }
    Columns { a, b, n }
}

fn aurora(c: &Ctx, cols: &Columns, x: usize, y: usize) -> V3 {
    let s = c.s;
    let (u, v) = ((x as f32 + 0.5) / c.rw as f32, (y as f32 + 0.5) / c.rh as f32);
    let px = (s.origin.0 + u * c.size.0, s.origin.1 + v * c.size.1);
    let p = &s.pal;
    let mut col = mix3(p.bg1, p.bg2, v);
    col = mix3(col, [1.0; 3], sparkle(px, 0.16, c.time * 1.7, s.seed).clamp(0.0, 1.0) * (1.0 - v) * 0.6);
    let n = cols.n;
    for i in 0..n.min(6) {
        let fi = i as f32;
        let base = 0.30 + 0.36 * (fi + 0.5) / n as f32;
        let d = v - (base + cols.a[x * 6 + i]);
        let reach = 5.0 + (1.0 - s.glow) * 11.0;
        let a = if d < 0.0 { (d * reach).exp() } else { (-d * d * 3500.0).exp() };
        let c_a = [p.c1, p.c2, p.c3, p.c1, p.c2, p.c3][i];
        let c_b = if i == 0 { p.c2 } else if i == 1 { p.c3 } else { p.c1 };
        let cc = mix3(c_a, c_b, (-d * 3.0).clamp(0.0, 1.0));
        let k = 1.0 - (-a * cols.b[x * 6 + i] * (0.35 + s.intensity * 1.1) * 1.6).exp();
        col = mix3(col, cc, k);
    }
    col
}

fn blobs(c: &Ctx, centres: &[(V2, V3)], x: usize, y: usize) -> V3 {
    let s = c.s;
    let (u, v) = ((x as f32 + 0.5) / c.rw as f32, (y as f32 + 0.5) / c.rh as f32);
    let aspect = c.size.0 / c.size.1.max(1.0);
    let q = (u * aspect, v);
    let sc = s.unit / 650.0;
    let bw = 0.18 + (1.0 - s.intensity) * 0.6;
    let mut acc = [s.pal.bg1[0] * bw, s.pal.bg1[1] * bw, s.pal.bg1[2] * bw];
    let mut wsum = bw;
    let r = (0.22 + 0.30 * s.glow) * sc;
    for (ce, cc) in centres {
        let d = (q.0 - ce.0, q.1 - ce.1);
        let w = (-(d.0 * d.0 + d.1 * d.1) / (r * r)).exp();
        acc = madd(acc, *cc, w);
        wsum += w;
    }
    let mut col = [acc[0] / wsum, acc[1] / wsum, acc[2] / wsum];
    let g = (hash1((x as f32 * 0.73, y as f32 * 0.73 + (c.time * 12.0).floor())) - 0.5) * 0.018;
    for k in col.iter_mut() {
        *k += g;
    }
    col
}

fn blob_centres(c: &Ctx) -> Vec<(V2, V3)> {
    let s = c.s;
    let aspect = c.size.0 / c.size.1.max(1.0);
    let n = 3 + (s.density * 5.0) as usize;
    (0..n.min(8))
        .map(|i| {
            let fi = i as f32;
            let h = hash2((fi + s.seed.0, 3.7 + s.seed.1));
            let ce = (aspect * (0.5 + 0.48 * (c.time * (0.07 + 0.05 * h.0) + fi * 2.4 + h.1 * 6.28).sin()), 0.5 + 0.48 * (c.time * (0.06 + 0.05 * h.1) + fi * 1.7 + h.0 * 6.28).cos());
            let cc = [s.pal.c1, s.pal.c2, s.pal.c3, s.pal.bg2][i % 4];
            (ce, cc)
        })
        .collect()
}

fn cells_edge(p: V2, t: f32) -> (f32, V2) {
    let (ip, fp) = ((p.0.floor(), p.1.floor()), (fract(p.0), fract(p.1)));
    let (mut f1, mut f2) = (8.0f32, 8.0f32);
    let mut best = (0.0, 0.0);
    for j in -1..=1 {
        for i in -1..=1 {
            let o = (i as f32, j as f32);
            let h = hash2((ip.0 + o.0, ip.1 + o.1));
            let pt = (o.0 + 0.5 + 0.42 * (t * 0.35 + 6.2831 * h.0).sin(), o.1 + 0.5 + 0.42 * (t * 0.35 + 6.2831 * h.1).sin());
            let d = (pt.0 - fp.0).hypot(pt.1 - fp.1);
            if d < f1 {
                f2 = f1;
                f1 = d;
                best = (ip.0 + o.0, ip.1 + o.1);
            } else if d < f2 {
                f2 = d;
            }
        }
    }
    (f2 - f1, best)
}

fn cells(c: &Ctx, x: usize, y: usize) -> V3 {
    let s = c.s;
    let (u, v) = ((x as f32 + 0.5) / c.rw as f32, (y as f32 + 0.5) / c.rh as f32);
    let k = 1.5 + s.density * 6.0;
    let at = |u: f32, v: f32| ((s.origin.0 + u * c.size.0) / s.unit * k + s.seed.0, (s.origin.1 + v * c.size.1) / s.unit * k + s.seed.1);
    let (edge, best) = cells_edge(at(u, v), c.time);
    // fwidth: how fast the edge distance changes across a pixel.
    let e_x = cells_edge(at(u + 1.0 / c.rw as f32, v), c.time).0;
    let e_y = cells_edge(at(u, v + 1.0 / c.rh as f32), c.time).0;
    let fwv = (e_x - edge).abs() + (e_y - edge).abs();
    let h = hash1(best);
    let p = &s.pal;
    let mut fill = mix3(p.bg1, p.bg2, h);
    fill = mix3(fill, p.c2, 0.18 * (0.5 + 0.5 * (c.time * 0.6 + h * 30.0).sin()));
    let line = 1.0 - smoothstep(0.0, (fwv * (1.2 + s.intensity * 2.5)).max(1e-6), edge);
    let mut col = mix3(fill, p.c1, line * (0.35 + s.intensity * 0.65));
    col = madd(col, p.c3, (-edge * (30.0 - s.glow * 22.0)).exp() * s.glow * 0.45);
    col
}

fn stars(c: &Ctx, x: usize, y: usize) -> V3 {
    let s = c.s;
    let (u, v) = ((x as f32 + 0.5) / c.rw as f32, (y as f32 + 0.5) / c.rh as f32);
    let px = (s.origin.0 + u * c.size.0, s.origin.1 + v * c.size.1);
    let p = &s.pal;
    let mut col = mix3(p.bg1, p.bg2, v);
    let np = (px.0 / s.unit * 1.3 + s.seed.0, px.1 / s.unit * 1.3 + s.seed.1);
    let t = c.time;
    let neb = fbm((np.0 + t * 0.015, np.1 - t * 0.01));
    let neb2 = fbm((np.0 * 1.7 - 4.0 - t * 0.01, np.1 * 1.7 - 4.0 + t * 0.012));
    let nc = mix3(p.c1, p.c2, smoothstep(0.3, 0.7, neb2));
    col = mix3(col, nc, smoothstep(0.42, 0.85, neb) * s.glow * 0.75);
    let chance = 0.05 + s.density * 0.30;
    let dpr = s.scale;
    let mut st = 0.0;
    st += star_layer((px.0 + t * 2.0, px.1), 28.0 * dpr, chance, t, s.seed.0);
    st += star_layer((px.0 + t * 5.0, px.1 + t * 0.6), 46.0 * dpr, chance * 0.7, t * 1.3, s.seed.1) * 1.1;
    st += star_layer((px.0 + t * 11.0, px.1 + t * 1.4), 80.0 * dpr, chance * 0.5, t * 0.8, s.seed.0 + 3.0) * 1.3;
    let sc = mix3([1.0; 3], p.c3, 0.35);
    mix3(col, sc, (st * (0.4 + s.intensity * 0.8)).clamp(0.0, 1.0))
}

fn waves_columns(c: &Ctx) -> Columns {
    let s = c.s;
    let n = (8.0 + s.density * 52.0) as usize;
    let ys = c.size.1 / s.unit;
    let mut a = vec![0.0; c.rw * 60];
    for x in 0..c.rw {
        let u = (x as f32 + 0.5) / c.rw as f32;
        let xx = (s.origin.0 + u * c.size.0) / s.unit + s.seed.0;
        for i in 0..n.min(60) {
            let t = i as f32 / ((n - 1) as f32).max(1.0);
            let y0 = 0.06 + t * 0.88;
            let amp = 0.5 + 0.5 * (t * 3.14159).sin();
            a[x * 60 + i] = y0
                + amp * (0.055 * (xx * 1.5 + c.time * 0.45 + t * 2.6).sin() + 0.030 * (xx * 3.3 - c.time * 0.33 + t * 5.0 + s.seed.1).sin() + 0.030 * (noise((xx * 0.9 + c.time * 0.08, t * 3.0)) - 0.5)) / ys.max(0.5) * 1.6;
        }
    }
    Columns { a, b: Vec::new(), n }
}

fn waves(c: &Ctx, cols: &Columns, x: usize, y: usize) -> V3 {
    let s = c.s;
    let v = (y as f32 + 0.5) / c.rh as f32;
    let p = &s.pal;
    let mut col = mix3(p.bg1, p.bg2, v);
    let n = cols.n;
    let mut halo = [0.0f32; 3];
    // Device pixels from a line, though this is drawn smaller.
    let px_per_u = c.size.1 * s.scale;
    for i in 0..n.min(60) {
        let t = i as f32 / ((n - 1) as f32).max(1.0);
        let d = (v - cols.a[x * 60 + i]).abs() * px_per_u;
        let w = 0.5 + s.intensity * 1.6;
        let lc = if t < 0.5 { mix3(p.c1, p.c2, t * 2.0) } else { mix3(p.c2, p.c3, t * 2.0 - 1.0) };
        let a = 1.0 - smoothstep(w - 0.6, w + 0.6, d);
        col = mix3(col, lc, a * (0.55 + 0.45 * s.intensity));
        let g = (-d / (4.0 + s.glow * 14.0)).exp();
        halo = madd(halo, lc, g);
    }
    madd(col, halo, s.glow * 0.10)
}

fn synth_terms(c: &Ctx, u: f32, v: f32) -> (f32, f32, f32) {
    let aspect = c.size.0 / c.size.1.max(1.0);
    let hz = 0.62;
    let sp = ((u - 0.5) * aspect, v - (hz - 0.17));
    let d = sp.0.hypot(sp.1);
    let s = (sp.1 + 0.24) * 16.0 - c.time * 0.35;
    let y = v - hz;
    let z = 0.12 / y.max(1e-4);
    let zw = z + c.time * 0.6;
    (d, s, zw)
}

fn synth(c: &Ctx, x: usize, y: usize) -> V3 {
    let s = c.s;
    let (u, v) = ((x as f32 + 0.5) / c.rw as f32, (y as f32 + 0.5) / c.rh as f32);
    let px = (s.origin.0 + u * c.size.0, s.origin.1 + v * c.size.1);
    let p = &s.pal;
    let aspect = c.size.0 / c.size.1.max(1.0);
    let hz = 0.62;
    let r = 0.24;
    let (du, dv) = (1.0 / c.rw as f32, 1.0 / c.rh as f32);
    let (d, sv, _) = synth_terms(c, u, v);
    let (dx, sx, _) = synth_terms(c, u + du, v);
    let (dy, sy, _) = synth_terms(c, u, v + dv);
    let dw = ((dx - d).abs() + (dy - d).abs()).max(1e-6);
    let w = ((sx - sv).abs() + (sy - sv).abs()).max(1e-6);
    let mut col;
    if v < hz {
        col = mix3(p.bg1, p.bg2, (v / hz).powf(1.6));
        let sp_y = v - (hz - 0.17);
        let k = ((sp_y + r) / (2.0 * r)).clamp(0.0, 1.0);
        let sun = mix3(p.c2, p.c3, k);
        let f = fract(sv);
        let thr = ((k - 0.45) * 1.2).max(0.0);
        let cut = if thr > 0.001 { (smoothstep(-w, w, f) * (1.0 - smoothstep(thr - w, thr + w, f))).max(smoothstep(1.0 - w, 1.0 + w, f)) } else { 0.0 };
        let inside = (1.0 - smoothstep(r - dw, r + dw, d)) * (1.0 - cut);
        col = mix3(col, sun, inside);
        col = mix3(col, p.c2, (-(d - r).max(0.0) * 9.0).exp() * s.glow * 0.45 * (1.0 - inside));
        col = mix3(col, [1.0; 3], sparkle(px, 0.22, c.time * 2.0, s.seed).clamp(0.0, 1.0) * (1.0 - v / hz) * 0.8 * (1.0 - inside));
    } else {
        let yy = v - hz;
        let z = 0.12 / yy.max(1e-4);
        let xw = (u - 0.5) * aspect * z;
        let zw = z + c.time * 0.6;
        let cells = 1.5 + s.density * 5.0;
        let g = (xw * cells, zw * cells);
        // The grid's lines, kept clear of aliasing with fwidth's stand-in: the change over one pixel.
        let gz = |u: f32, v: f32| {
            let yy = (v - hz).max(1e-4);
            let z = 0.12 / yy;
            ((u - 0.5) * aspect * z * cells, (z + c.time * 0.6) * cells)
        };
        let (gx1, gy1) = (gz(u + du, v), gz(u, v + dv));
        let fw = (((gx1.0 - g.0).abs() + (gy1.0 - g.0).abs()).max(1e-4), ((gx1.1 - g.1).abs() + (gy1.1 - g.1).abs()).max(1e-4));
        let l = ((fract(g.0 - 0.5) - 0.5).abs() / fw.0, (fract(g.1 - 0.5) - 0.5).abs() / fw.1);
        let line = 1.0 - (l.0.min(l.1) / (1.0 + s.intensity * 1.5)).min(1.0);
        let fade = smoothstep(0.0, 0.25, yy);
        let ground = mix3([p.bg1[0] * 0.6, p.bg1[1] * 0.6, p.bg1[2] * 0.6], [p.bg2[0] * 0.35, p.bg2[1] * 0.35, p.bg2[2] * 0.35], smoothstep(0.0, 0.4, yy));
        col = mix3(ground, p.c1, (line * fade).clamp(0.0, 1.0));
        col = mix3(col, p.c1, (-yy * 18.0).exp() * s.glow * 0.5);
    }
    mix3(col, p.c3, (-(v - hz).abs() * c.size.1 * s.scale / 3.0).exp() * 0.6)
}

// ── topography ────────────────────────────────────────────────────────

fn t_hash2(p: V2) -> V2 {
    let h = hash2(p);
    (-1.0 + 2.0 * h.0, -1.0 + 2.0 * h.1)
}
fn t_noise(p: V2) -> f32 {
    let (ix, iy) = (p.0.floor(), p.1.floor());
    let (fx, fy) = (p.0 - ix, p.1 - iy);
    let (ux, uy) = (fx * fx * (3.0 - 2.0 * fx), fy * fy * (3.0 - 2.0 * fy));
    let g = |dx: f32, dy: f32| {
        let h = t_hash2((ix + dx, iy + dy));
        h.0 * (fx - dx) + h.1 * (fy - dy)
    };
    mix(mix(g(0.0, 0.0), g(1.0, 0.0), ux), mix(g(0.0, 1.0), g(1.0, 1.0), ux), uy)
}
fn t_fbm(mut p: V2, detail: f32) -> f32 {
    let (mut amp, mut sum, mut norm) = (0.5, 0.0, 0.0);
    for i in 0..6 {
        if i as f32 >= detail {
            break;
        }
        sum += amp * t_noise(p);
        norm += amp;
        p = ((0.8 * p.0 - 0.6 * p.1) * 2.03 + 1.7, (0.6 * p.0 + 0.8 * p.1) * 2.03 + 9.2);
        amp *= 0.5;
    }
    sum / norm
}

/// The terrain's height at a point (logical px), with the contour index it falls on: `v` in levels.
fn topo_height(c: &Ctx, px: V2) -> (f32, f32) {
    let s = c.s;
    let t = &s.topo;
    let p = (px.0 / s.unit + s.seed.0, px.1 / s.unit + s.seed.1);
    let tm = c.time;
    let q = (t_fbm((p.0 + tm * 0.021, p.1 + tm * 0.013), t.detail), t_fbm((p.0 + 5.2 - tm * 0.017, p.1 + 1.3 - tm * 0.024), t.detail));
    let h = t_fbm((p.0 + t.warp * 2.5 * q.0, p.1 + t.warp * 2.5 * q.1), t.detail);
    let h = (0.5 + h * 1.25).clamp(0.0, 1.0);
    (h, h * t.levels + c.rise)
}

// ── the frame ─────────────────────────────────────────────────────────

fn par_rows(out: &mut [u8], rw: usize, rh: usize, f: &(dyn Fn(usize, &mut [u8]) + Sync)) {
    let n = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(16).max(1);
    let per = rh.div_ceil(n).max(1);
    std::thread::scope(|sc| {
        for (ci, chunk) in out.chunks_mut(per * rw * 4).enumerate() {
            sc.spawn(move || {
                for (ry, row) in chunk.chunks_mut(rw * 4).enumerate() {
                    f(ci * per + ry, row);
                }
            });
        }
    });
}

fn put(row: &mut [u8], x: usize, c: V3) {
    let q = |v: f32| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u8;
    row[x * 4] = q(c[2]);
    row[x * 4 + 1] = q(c[1]);
    row[x * 4 + 2] = q(c[0]);
    row[x * 4 + 3] = 255;
}

/// One frame of a screen's style, `rw` × `rh` pixels, in Xrgb8888.
pub fn render(s: &Screen, time: f32, rise: f32, rw: usize, rh: usize) -> Vec<u8> {
    let size = (s.w as f32 / s.scale, s.h as f32 / s.scale);
    let c = Ctx { s, time, rise, size, rw, rh };
    let mut out = vec![0u8; rw * rh * 4];
    match s.style.as_str() {
        "aurora" => {
            let cols = aurora_columns(&c);
            par_rows(&mut out, rw, rh, &|y, row| {
                for x in 0..rw {
                    put(row, x, dither(aurora(&c, &cols, x, y), x, y, time));
                }
            });
        }
        "blobs" => {
            let centres = blob_centres(&c);
            par_rows(&mut out, rw, rh, &|y, row| {
                for x in 0..rw {
                    put(row, x, blobs(&c, &centres, x, y));
                }
            });
        }
        "cells" => par_rows(&mut out, rw, rh, &|y, row| {
            for x in 0..rw {
                put(row, x, dither(cells(&c, x, y), x, y, time));
            }
        }),
        "stars" => par_rows(&mut out, rw, rh, &|y, row| {
            for x in 0..rw {
                put(row, x, dither(stars(&c, x, y), x, y, time));
            }
        }),
        "waves" => {
            let cols = waves_columns(&c);
            par_rows(&mut out, rw, rh, &|y, row| {
                for x in 0..rw {
                    put(row, x, dither(waves(&c, &cols, x, y), x, y, time));
                }
            });
        }
        "synth" => par_rows(&mut out, rw, rh, &|y, row| {
            for x in 0..rw {
                put(row, x, dither(synth(&c, x, y), x, y, time));
            }
        }),
        _ => topo(&c, &mut out),
    }
    out
}

fn topo(c: &Ctx, out: &mut [u8]) {
    let (rw, rh) = (c.rw, c.rh);
    let t = &c.s.topo;
    // The terrain is smooth over many pixels, so it is worked out on a coarse grid and the
    // contours read off its bilinear surface: the lines stay sharp at the full size.
    let step = (rw as f32 / 360.0).max(2.0);
    let (gw, gh) = ((rw as f32 / step).ceil() as usize + 2, (rh as f32 / step).ceil() as usize + 2);
    let mut grid = vec![(0.0f32, 0.0f32); gw * gh];
    {
        let n = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4).min(16).max(1);
        let per = gh.div_ceil(n).max(1);
        std::thread::scope(|sc| {
            for (ci, chunk) in grid.chunks_mut(per * gw).enumerate() {
                sc.spawn(move || {
                    for (ry, row) in chunk.chunks_mut(gw).enumerate() {
                        let gy = ci * per + ry;
                        for (gx, cell) in row.iter_mut().enumerate() {
                            let (u, v) = (gx as f32 * step / rw as f32, gy as f32 * step / rh as f32);
                            *cell = topo_height(c, (c.s.origin.0 + u * c.size.0, c.s.origin.1 + v * c.size.1));
                        }
                    }
                });
            }
        });
    }
    let at = |gx: usize, gy: usize| grid[gy.min(gh - 1) * gw + gx.min(gw - 1)];
    // Light at a render pixel: lines, glow and ground.
    par_rows(out, rw, rh, &|y, row| {
        let fy = y as f32 / step;
        let (gy, ty) = (fy as usize, fract(fy));
        for x in 0..rw {
            let fx = x as f32 / step;
            let (gx, tx) = (fx as usize, fract(fx));
            let (a, b, cc, d) = (at(gx, gy), at(gx + 1, gy), at(gx, gy + 1), at(gx + 1, gy + 1));
            let bil = |f: &dyn Fn((f32, f32)) -> f32| mix(mix(f(a), f(b), tx), mix(f(cc), f(d), tx), ty);
            let h = bil(&|p| p.0);
            let v = bil(&|p| p.1);
            // fwidth: the surface's slope, per render pixel.
            let dvdx = (mix(b.1, d.1, ty) - mix(a.1, cc.1, ty)) / step;
            let dvdy = (mix(cc.1, d.1, tx) - mix(a.1, b.1, tx)) / step;
            let fw = (dvdx.abs() + dvdy.abs()).max(1e-5);
            let dd = (fract(v + 0.5) - 0.5).abs() / fw;
            let index = (v + 0.5).floor();
            let major = t.major_every > 0.5 && index.rem_euclid(t.major_every) < 0.5;
            // Line widths are in device pixels; this may be drawn smaller than the screen.
            let k = rw as f32 / c.s.w as f32;
            let w = (t.line_width * if major { 1.9 } else { 1.0 }) * k;
            let w = w.max(0.9);
            let mut al = 1.0 - smoothstep(w * 0.5 - 0.6, w * 0.5 + 0.6, dd);
            al *= t.line_alpha * if major || t.major_every < 0.5 { 1.0 } else { 0.65 };
            al *= 1.0 - smoothstep(0.25, 0.5, fw);
            let g = t.glow * (-dd / (w * 2.5).max(1.0)).exp() * t.line_alpha * (1.0 - smoothstep(0.25, 0.5, fw));
            let tt = if t.shade < 0.5 { y as f32 / rh as f32 } else if t.shade < 1.5 { h } else { 1.0 - (fract(v.floor() / (t.levels - 1.0).max(1.0) * 0.5) * 2.0 - 1.0).abs() };
            let bg = mix3(t.low, t.high, tt.clamp(0.0, 1.0));
            let col = madd(mix3(bg, t.line, al), t.line, g * 0.6);
            put(row, x, col);
        }
    });
}

// ── the thread ────────────────────────────────────────────────────────

pub struct Frame {
    pub bar: usize,
    pub w: u32,
    pub h: u32,
    pub px: Vec<u8>,
}

pub enum Cmd {
    /// The screens that have an animated wallpaper now (none: nothing runs).
    Set(Vec<Screen>),
    /// Which of them can't be seen right now, by bar index.
    Still(Vec<usize>),
}

pub struct Anim {
    tx: Sender<Cmd>,
    pub rx: Receiver<Frame>,
}

struct Live {
    s: Screen,
    time: f32,
    rise: f32,
    /// What fraction of the screen's size a frame is drawn at, found by what the frame costs.
    div: f32,
}

impl Anim {
    /// Starts the thread; each frame is announced with a byte on `wake`.
    pub fn start(wake: std::os::unix::net::UnixStream) -> Anim {
        let (tx, rx_cmd) = channel::<Cmd>();
        let (tx_frame, rx) = sync_channel::<Frame>(2);
        std::thread::spawn(move || run(rx_cmd, tx_frame, wake));
        Anim { tx, rx }
    }

    pub fn send(&self, c: Cmd) {
        let _ = self.tx.send(c);
    }
}

fn run(rx: Receiver<Cmd>, tx: SyncSender<Frame>, mut wake: std::os::unix::net::UnixStream) {
    use std::io::Write;
    let mut screens: Vec<Live> = Vec::new();
    let mut still: Vec<usize> = Vec::new();
    let mut last = Instant::now();
    loop {
        let active = |l: &Live, still: &Vec<usize>| !still.contains(&l.s.bar) && (l.s.style != "topo" || l.s.topo.drift);
        let any = screens.iter().any(|l| active(l, &still));
        let interval = Duration::from_micros(1_000_000 / screens.iter().map(|l| l.s.fps).max().unwrap_or(30).max(1) as u64);
        let got = if any { rx.recv_timeout(Duration::ZERO) } else { rx.recv().map_err(|_| RecvTimeoutError::Disconnected) };
        match got {
            Ok(Cmd::Set(list)) => {
                let old = std::mem::take(&mut screens);
                screens = list
                    .into_iter()
                    .map(|s| {
                        let prev = old.iter().find(|o| o.s.bar == s.bar && o.s.style == s.style);
                        // Soft styles can be drawn small; the ones made of thin lines need their pixels.
                        let div = prev.map(|o| o.div).unwrap_or(match s.style.as_str() { "topo" => 1.0, "cells" | "synth" | "waves" => 0.85, _ => 0.5 });
                        Live { time: prev.map(|o| o.time).unwrap_or(0.0), rise: prev.map(|o| o.rise).unwrap_or(0.0), div, s }
                    })
                    .collect();
                last = Instant::now();
                // A frame at once, so a changed setting shows without waiting a tick.
                for l in screens.iter_mut() {
                    if !still.contains(&l.s.bar) || true {
                        send_frame(l, &tx, &mut wake);
                    }
                }
                continue;
            }
            Ok(Cmd::Still(list)) => {
                still = list;
                last = Instant::now();
                continue;
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }
        if !any {
            continue;
        }
        let began = Instant::now();
        let dt = began.duration_since(last).as_secs_f32().min(0.25);
        last = began;
        for l in screens.iter_mut() {
            if !active(l, &still) {
                continue;
            }
            if l.s.style == "topo" {
                let d = dt * l.s.topo.speed;
                if l.s.topo.move_terrain {
                    l.time += d;
                }
                if l.s.topo.move_lines {
                    l.rise += d * 0.35;
                }
            } else {
                l.time += dt * l.s.speed;
            }
            let cost = send_frame(l, &tx, &mut wake);
            // Keep a frame inside the time there is for it.
            let budget = interval.as_secs_f32() * 0.7;
            if cost > budget && l.div > 0.25 {
                l.div = (l.div * 0.88).max(0.25);
            } else if cost < budget * 0.45 && l.div < if ["topo", "cells", "synth", "waves"].contains(&l.s.style.as_str()) { 1.0 } else { 0.8 } {
                l.div = (l.div * 1.04).min(1.0);
            }
        }
        let _ = wake.flush();
        let spent = began.elapsed();
        if spent < interval {
            std::thread::sleep(interval - spent);
        }
    }
}

/// Draws one frame and hands it over; how long it took, seconds.
fn send_frame(l: &mut Live, tx: &SyncSender<Frame>, wake: &mut std::os::unix::net::UnixStream) -> f32 {
    use std::io::Write;
    let began = Instant::now();
    let (rw, rh) = (((l.s.w as f32 * l.div).round() as usize).max(64), ((l.s.h as f32 * l.div).round() as usize).max(36));
    let px = render(&l.s, l.time, l.rise, rw, rh);
    let cost = began.elapsed().as_secs_f32();
    if tx.try_send(Frame { bar: l.s.bar, w: rw as u32, h: rh as u32, px }).is_ok() {
        let _ = wake.write_all(b"!");
    }
    cost
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(style: &str) -> Screen {
        let raw = serde_json::json!({ "wallpaperStyle": style, "animPalette": "aurora" });
        screen_for(&raw, true, ([0.2, 0.2, 0.2], [0.1, 0.1, 0.1]), [1.0, 0.3, 0.2], [0.9; 3], (0, 640, 400, 1.0, (0.0, 0.0)))
    }

    #[test]
    fn every_style_draws_something_that_changes_with_time() {
        for style in ["topo", "aurora", "blobs", "cells", "stars", "synth", "waves"] {
            let s = screen(style);
            let a = render(&s, 1.0, 0.0, 160, 100);
            let b = render(&s, 9.0, 3.0, 160, 100);
            assert_eq!(a.len(), 160 * 100 * 4);
            assert!(a.chunks(4).any(|p| p[0] != a[0] || p[1] != a[1] || p[2] != a[2]), "{style} is one flat colour");
            assert_ne!(a, b, "{style} doesn't move");
            assert!(a.chunks(4).all(|p| p[3] == 255));
        }
    }

    #[test]
    fn palettes_and_the_theme_ones() {
        let s = screen("blobs");
        assert!((s.pal.c1[1] - 1.0).abs() < 0.01, "the aurora palette's first colour is #3cffb4");
        let raw = serde_json::json!({ "wallpaperStyle": "aurora" });
        let t = screen_for(&raw, true, ([0.2; 3], [0.1; 3]), [1.0, 0.3, 0.2], [0.9; 3], (0, 64, 64, 1.0, (0.0, 0.0)));
        assert_eq!(t.pal.c1, [1.0, 0.3, 0.2]);
        assert_ne!(t.pal.c2, t.pal.c3);
    }
}
