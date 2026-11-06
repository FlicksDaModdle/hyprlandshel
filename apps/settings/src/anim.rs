//! Settings → Wallpaper → Animated's gallery (AnimatedGallery.qml): every
//! style as a small live preview, and the palettes as strips of their five
//! colours.
//!
//! The shell draws these styles with fragment shaders
//! (modules/background/shaders/*.frag). Slint has no shaders of its own,
//! so each is worked here on the processor, pixel by pixel, the same sums
//! as the GLSL — small, a tile at a time, on a thread of their own, 24
//! times a second while the gallery is on screen. Where a shader takes
//! fwidth() (how fast a value changes from one pixel to the next), the
//! value is worked for the whole tile first and its neighbours compared.

use crate::prefs::Prefs;
use crate::{AnimTile, PalChip};
use slint::{ComponentHandle, Image, Model, ModelRc, Rgba8Pixel, SharedPixelBuffer, VecModel};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Palettes.js.
pub const PRESETS: [(&str, &str, [&str; 5]); 10] = [
    ("aurora", "Aurora", ["#040c18", "#0b2536", "#3cffb4", "#3fa7ff", "#b46cff"]),
    ("sunset", "Sunset", ["#160a2b", "#5b1f4f", "#ff7a59", "#ffb347", "#ff3d7f"]),
    ("ocean", "Ocean", ["#021526", "#063b5b", "#2ec4ff", "#57f0d4", "#1b6dff"]),
    ("forest", "Forest", ["#0b1a12", "#1e3a2a", "#8ad86b", "#e8d36b", "#3fbf9b"]),
    ("neon", "Neon", ["#0a0014", "#1b0033", "#ff2bd6", "#00f0ff", "#fff200"]),
    ("ember", "Ember", ["#120604", "#2b0f08", "#ff5a1f", "#ffb000", "#ff2a2a"]),
    ("rose", "Rosé", ["#1d1016", "#3a1d2a", "#ff9ec4", "#ffd1dc", "#c27dff"]),
    ("mono", "Mono", ["#0f1011", "#1d1f21", "#e8e8e8", "#9a9a9a", "#5f5f5f"]),
    ("paper", "Paper", ["#f4efe6", "#e3d8c5", "#b04a2f", "#2f6f8f", "#3a3a3a"]),
    ("mint", "Mint", ["#eef7f2", "#cfe8dc", "#16a37a", "#3f7fd9", "#0f5c45"]),
];
/// The styles, in the gallery's order.
pub const STYLES: [(&str, &str); 7] = [
    ("topo", "Topographic"),
    ("aurora", "Aurora"),
    ("blobs", "Blobs"),
    ("waves", "Waves"),
    ("stars", "Starfield"),
    ("synth", "Synthwave"),
    ("cells", "Cells"),
];

/// The preview's own size, in its pixels; Slint scales it to the tile.
pub const W: usize = 224;
pub const H: usize = 140;

type V3 = [f32; 3];

pub fn hex(s: &str) -> V3 {
    let h = s.trim().trim_start_matches('#');
    let h = if h.len() == 8 { &h[2..] } else { h };
    let p = |i: usize| h.get(i..i + 2).and_then(|x| u8::from_str_radix(x, 16).ok()).unwrap_or(0) as f32 / 255.0;
    [p(0), p(2), p(4)]
}
fn to_hex(c: V3) -> String {
    format!("#{:02x}{:02x}{:02x}", (c[0] * 255.0).round() as u8, (c[1] * 255.0).round() as u8, (c[2] * 255.0).round() as u8)
}

/// Appearance.tintSpec's a and b.
fn tint(p: &Prefs) -> (V3, V3) {
    let (a, b) = match (p.dark(), p.s("tint").as_str()) {
        (false, "Neutral") => ("#f5f4f4", "#e4e2e2"),
        (false, "Cool") => ("#f2f4f5", "#e2e5e7"),
        (false, _) => ("#f6f4f3", "#e7e3e1"),
        (true, "Neutral") => ("#221f1e", "#151413"),
        (true, "Cool") => ("#1d2022", "#131516"),
        (true, _) => ("#24211f", "#161514"),
    };
    (hex(a), hex(b))
}
fn darker(c: V3, f: f32) -> V3 {
    [c[0] / f, c[1] / f, c[2] / f]
}

fn rgb_to_hsl(c: V3) -> (f32, f32, f32) {
    let (mx, mn) = (c[0].max(c[1]).max(c[2]), c[0].min(c[1]).min(c[2]));
    let l = (mx + mn) / 2.0;
    if mx == mn {
        return (-1.0, 0.0, l);
    }
    let d = mx - mn;
    let s = if l > 0.5 { d / (2.0 - mx - mn) } else { d / (mx + mn) };
    let h = if mx == c[0] {
        (c[1] - c[2]) / d + if c[1] < c[2] { 6.0 } else { 0.0 }
    } else if mx == c[1] {
        (c[2] - c[0]) / d + 2.0
    } else {
        (c[0] - c[1]) / d + 4.0
    };
    (h / 6.0, s, l)
}
fn hsl_to_rgb(h: f32, s: f32, l: f32) -> V3 {
    let f = |t: f32| {
        let q = if l < 0.5 { l * (1.0 + s) } else { l + s - l * s };
        let p = 2.0 * l - q;
        let t = t.rem_euclid(1.0);
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
/// AnimatedWallpaper.hueShift.
fn hue_shift(c: V3, d: f32) -> V3 {
    let (h, s, l) = rgb_to_hsl(c);
    hsl_to_rgb((h.max(0.0) + d + 1.0) % 1.0, s.max(0.35), l)
}

/// AnimatedWallpaper.colours: bg1, bg2, c1, c2, c3.
pub fn palette(p: &Prefs, key: &str) -> [V3; 5] {
    if key == "custom" {
        return ["animBg1", "animBg2", "animC1", "animC2", "animC3"].map(|k| hex(&p.s(k)));
    }
    if let Some((_, _, c)) = PRESETS.iter().find(|x| x.0 == key) {
        return c.map(hex);
    }
    let a = p.accent().map(|x| x as f32);
    let (ta, tb) = tint(p);
    [darker(tb, if p.dark() { 1.35 } else { 1.05 }), ta, a, hue_shift(a, 0.10), hue_shift(a, -0.12)]
}

// ── the shaders' own helpers ───────────────────────────────────────────
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
fn hash1(x: f32, y: f32) -> f32 {
    let mut p = [fract(x * 0.1031), fract(y * 0.1031), fract(x * 0.1031)];
    let d = p[0] * (p[1] + 33.33) + p[1] * (p[2] + 33.33) + p[2] * (p[0] + 33.33);
    p = [p[0] + d, p[1] + d, p[2] + d];
    fract((p[0] + p[1]) * p[2])
}
fn hash2(x: f32, y: f32) -> (f32, f32) {
    let mut p = [fract(x * 0.1031), fract(y * 0.1030), fract(x * 0.0973)];
    let d = p[0] * (p[1] + 33.33) + p[1] * (p[2] + 33.33) + p[2] * (p[0] + 33.33);
    p = [p[0] + d, p[1] + d, p[2] + d];
    (fract((p[0] + p[1]) * p[2]), fract((p[0] + p[2]) * p[1]))
}
fn noise(x: f32, y: f32) -> f32 {
    let (ix, iy) = (x.floor(), y.floor());
    let (fx, fy) = (x - ix, y - iy);
    let (ux, uy) = (fx * fx * (3.0 - 2.0 * fx), fy * fy * (3.0 - 2.0 * fy));
    let a = hash1(ix, iy);
    let b = hash1(ix + 1.0, iy);
    let c = hash1(ix, iy + 1.0);
    let d = hash1(ix + 1.0, iy + 1.0);
    mix(mix(a, b, ux), mix(c, d, ux), uy)
}
fn fbm(mut x: f32, mut y: f32) -> f32 {
    let (mut s, mut a) = (0.0, 0.5);
    for _ in 0..5 {
        s += a * noise(x, y);
        // mat2(0.8, 0.6, -0.6, 0.8) * p, column-major.
        let (nx, ny) = (0.8 * x - 0.6 * y, 0.6 * x + 0.8 * y);
        x = nx * 2.02 + 3.1;
        y = ny * 2.02 + 3.1;
        a *= 0.5;
    }
    s
}
fn len(x: f32, y: f32) -> f32 {
    (x * x + y * y).sqrt()
}

/// What a preview is drawn from: AnimatedWallpaper's uniforms.
#[derive(Clone)]
pub struct Uni {
    pub seed: (f32, f32),
    pub unit: f32,
    pub density: f32,
    pub glow: f32,
    pub intensity: f32,
    pub c: [V3; 5],
    pub speed: f32,
}

/// Topography's.
#[derive(Clone)]
pub struct Topo {
    pub seed: (f32, f32),
    pub unit: f32,
    pub detail: f32,
    pub warp: f32,
    pub levels: f32,
    pub line_width: f32,
    pub major: f32,
    pub alpha: f32,
    pub shade: f32,
    pub glow: f32,
    pub line: V3,
    pub low: V3,
    pub high: V3,
    pub speed: f32,
    pub drift: bool,
    pub flow: bool,
}

fn seed_of(n: f64, span: f64, shift: f64) -> (f32, f32) {
    let r = |n: f64| {
        let x = n.sin() * 43758.5453;
        x - x.floor()
    };
    ((r(n * 12.9898) * span - shift) as f32, (r(n * 78.233) * span - shift) as f32)
}

pub fn uniforms(p: &Prefs, style: &str) -> Uni {
    let scale = W as f32 / 1280.0;
    Uni {
        seed: seed_of(p.f("animSeed"), 97.0, 0.0),
        unit: 650.0 * p.f("animScale").max(25.0) as f32 / 100.0 * if style == "blobs" { 1.0 } else { scale },
        density: p.f("animDensity") as f32 / 100.0,
        glow: p.f("animGlow") as f32 / 100.0,
        intensity: p.f("animIntensity") as f32 / 100.0,
        c: palette(p, &p.s("animPalette")),
        speed: p.f("animWallSpeed") as f32 / 100.0,
    }
}

pub fn topo_uniforms(p: &Prefs) -> Topo {
    let (ta, tb) = tint(p);
    let accent = p.accent().map(|x| x as f32);
    let ink = if p.dark() { hex("#f8f4f4") } else { hex("#201e1d") };
    let custom = p.s("topoGround") == "custom";
    Topo {
        seed: seed_of(p.f("topoSeed"), 240.0, 120.0),
        unit: 650.0 * p.f("topoScale").max(25.0) as f32 / 100.0 * (W as f32 / 1280.0),
        detail: p.f("topoDetail").clamp(1.0, 6.0) as f32,
        warp: p.f("topoFlow") as f32 / 100.0,
        levels: p.f("topoLevels").max(2.0) as f32,
        line_width: (p.f("topoWidth") * 0.6).max(0.7) as f32,
        major: p.f("topoMajor") as f32,
        alpha: p.f("topoStrength") as f32 / 100.0,
        shade: match p.s("topoShade").as_str() {
            "bands" => 2.0,
            "smooth" => 1.0,
            _ => 0.0,
        },
        glow: p.f("topoGlow") as f32 / 100.0,
        line: match p.s("topoLine").as_str() {
            "accent" => accent,
            "custom" => hex(&p.s("topoLineCustom")),
            _ => ink,
        },
        low: if custom { hex(&p.s("topoLow")) } else { darker(tb, if p.dark() { 1.35 } else { 1.05 }) },
        high: if custom { hex(&p.s("topoHigh")) } else { ta },
        speed: p.f("topoSpeed").max(5.0) as f32 / 30.0,
        drift: p.s("topoMotion") != "flow",
        flow: p.s("topoMotion") != "drift",
    }
}

fn dither(c: V3, x: f32, y: f32, t: f32) -> V3 {
    let n = (hash1(x + fract(t), y + fract(t)) - 0.5) / 255.0;
    [c[0] + n, c[1] + n, c[2] + n]
}

/// The shaders' sparkle(): small round stars that twinkle.
fn sparkle(px: f32, py: f32, chance: f32, t: f32, seed: (f32, f32)) -> f32 {
    let cell = 22.0;
    let (gx, gy) = (px / cell, py / cell);
    let (ix, iy) = (gx.floor(), gy.floor());
    let h = hash2(ix + seed.0, iy + seed.1);
    if h.0 > chance {
        return 0.0;
    }
    let o = hash2(ix + seed.0 + 17.0, iy + seed.1 + 17.0);
    let (posx, posy) = (ix + 0.15 + 0.7 * o.0, iy + 0.15 + 0.7 * o.1);
    let d = len(gx - posx, gy - posy) * cell;
    let r = 0.6 + 0.9 * h.1;
    let tw = 0.6 + 0.4 * (t * (0.8 + 1.6 * h.1) + h.1 * 50.0).sin();
    tw * (0.45 + 0.55 * h.1) * ((1.0 - smoothstep(0.0, r, d)) + 0.25 * (-d / (r * 1.8)).exp())
}

fn star_layer(px: f32, py: f32, cell: f32, chance: f32, t: f32, seed: f32) -> f32 {
    let (gx, gy) = (px / cell, py / cell);
    let (ix, iy) = (gx.floor(), gy.floor());
    let h = hash2(ix + seed, iy + seed);
    if h.0 > chance {
        return 0.0;
    }
    let o = hash2(ix + seed + 7.0, iy + seed + 7.0);
    let d = len(gx - (ix + 0.2 + 0.6 * o.0), gy - (iy + 0.2 + 0.6 * o.1)) * cell;
    let tw = 0.65 + 0.35 * (t * (1.0 + 2.0 * h.1) + h.1 * 40.0).sin();
    let r = 0.6 + 1.4 * h.1;
    tw * (1.0 - smoothstep(r * 0.4, r, d)) + tw * 0.25 * (-d / (r * 2.5)).exp()
}

/// A smooth field worked at half the size (every other pixel, each way)
/// and read back blended: noise this soft loses nothing by it.
struct Half {
    w: usize,
    v: Vec<f32>,
}
impl Half {
    fn new(f: impl Fn(f32, f32) -> f32) -> Half {
        let (w, h) = (W / 2 + 2, H / 2 + 2);
        let mut v = vec![0.0; w * h];
        for j in 0..h {
            for i in 0..w {
                v[j * w + i] = f(i as f32 * 2.0 + 0.5, j as f32 * 2.0 + 0.5);
            }
        }
        Half { w, v }
    }
    fn at(&self, x: usize, y: usize) -> f32 {
        let (i, j) = (x / 2, y / 2);
        let (fx, fy) = ((x % 2) as f32 * 0.5, (y % 2) as f32 * 0.5);
        let a = self.v[j * self.w + i];
        let b = self.v[j * self.w + i + 1];
        let c = self.v[(j + 1) * self.w + i];
        let d = self.v[(j + 1) * self.w + i + 1];
        mix(mix(a, b, fx), mix(c, d, fx), fy)
    }
}

/// fwidth() of a field worked for every pixel: |d/dx| + |d/dy|.
fn fwidth(f: &[f32], x: usize, y: usize) -> f32 {
    let i = y * W + x;
    let dx = if x + 1 < W { f[i + 1] - f[i] } else { f[i] - f[i - 1] };
    let dy = if y + 1 < H { f[i + W] - f[i] } else { f[i] - f[i - W] };
    dx.abs() + dy.abs()
}

/// One frame of a style, RGBA.
pub fn render(style: &str, u: &Uni, t: f32, out: &mut [u8]) {
    let (w, h) = (W as f32, H as f32);
    let [bg1, bg2, c1, c2, c3] = u.c;
    let mut put = |x: usize, y: usize, c: V3| {
        let i = (y * W + x) * 4;
        out[i] = (c[0].clamp(0.0, 1.0) * 255.0) as u8;
        out[i + 1] = (c[1].clamp(0.0, 1.0) * 255.0) as u8;
        out[i + 2] = (c[2].clamp(0.0, 1.0) * 255.0) as u8;
        out[i + 3] = 255;
    };
    // The pixel's centre, as the GPU samples it.
    let at = |x: usize, y: usize| ((x as f32 + 0.5) / w, (y as f32 + 0.5) / h);
    match style {
        "aurora" => {
            let n = (2.0 + u.density * 4.0) as usize;
            let n6 = n.min(6);
            let reach = 5.0 + (1.0 - u.glow) * 11.0;
            // A curtain's line and its rays change only along x: worked
            // once a column.
            let mut line = vec![0.0f32; W * 6];
            let mut rays = vec![0.0f32; W * 6];
            for x in 0..W {
                let xx = (x as f32 + 0.5) / u.unit + u.seed.0;
                for i in 0..n6 {
                    let fi = i as f32;
                    let base = 0.30 + 0.36 * (fi + 0.5) / n as f32;
                    let wv = (xx * 1.1 + t * 0.31 + fi * 1.7).sin() * 0.07
                        + (xx * 2.7 - t * 0.23 + fi * 0.9).sin() * 0.035
                        + (fbm(xx * 0.7 + fi * 3.1, t * 0.06) - 0.5) * 0.18;
                    line[x * 6 + i] = base + wv;
                    rays[x * 6 + i] = 0.45 + 0.55 * fbm(xx * 9.0 + fi * 7.0, t * 0.25 + fi);
                }
            }
            for y in 0..H {
                for x in 0..W {
                    let (uvx, uvy) = at(x, y);
                    let (px, py) = (uvx * w, uvy * h);
                    let mut col = mix3(bg1, bg2, uvy);
                    col = mix3(col, [1.0; 3], sparkle(px, py, 0.16, t * 1.7, u.seed).clamp(0.0, 1.0) * (1.0 - uvy) * 0.6);
                    for i in 0..n6 {
                        let d = uvy - line[x * 6 + i];
                        let a = if d < 0.0 { (d * reach).exp() } else { (-d * d * 3500.0).exp() };
                        if a < 1e-4 {
                            continue;
                        }
                        let ca = [c1, c2, c3, c1, c2, c3][i];
                        let cb = [c2, c3, c1, c1, c1, c1][i];
                        let cc = mix3(ca, cb, (-d * 3.0).clamp(0.0, 1.0));
                        let k = 1.0 - (-a * rays[x * 6 + i] * (0.35 + u.intensity * 1.1) * 1.6).exp();
                        col = mix3(col, cc, k);
                    }
                    put(x, y, dither(col, px, py, t));
                }
            }
        }
        "blobs" => {
            let aspect = w / h.max(1.0);
            let s = u.unit / 650.0;
            let n = 3 + (u.density * 5.0) as usize;
            let bw = 0.18 + (1.0 - u.intensity) * 0.6;
            let centres: Vec<(f32, f32, V3)> = (0..n.min(8))
                .map(|i| {
                    let fi = i as f32;
                    let hh = hash2(fi + u.seed.0, 3.7 + u.seed.1);
                    let c = (
                        aspect * (0.5 + 0.48 * (t * (0.07 + 0.05 * hh.0) + fi * 2.4 + hh.1 * 6.28).sin()),
                        0.5 + 0.48 * (t * (0.06 + 0.05 * hh.1) + fi * 1.7 + hh.0 * 6.28).cos(),
                    );
                    (c.0, c.1, [c1, c2, c3, bg2][i % 4])
                })
                .collect();
            let r = (0.22 + 0.30 * u.glow) * s;
            for y in 0..H {
                for x in 0..W {
                    let (uvx, uvy) = at(x, y);
                    let (qx, qy) = (uvx * aspect, uvy);
                    let mut acc = [bg1[0] * bw, bg1[1] * bw, bg1[2] * bw];
                    let mut wsum = bw;
                    for (cx, cy, cc) in &centres {
                        let d2 = (qx - cx) * (qx - cx) + (qy - cy) * (qy - cy);
                        let wg = (-d2 / (r * r)).exp();
                        acc = [acc[0] + cc[0] * wg, acc[1] + cc[1] * wg, acc[2] + cc[2] * wg];
                        wsum += wg;
                    }
                    let g = (hash1(uvx * w * 0.73 + (t * 12.0).floor(), uvy * h * 0.73 + (t * 12.0).floor()) - 0.5) * 0.018;
                    put(x, y, [acc[0] / wsum + g, acc[1] / wsum + g, acc[2] / wsum + g]);
                }
            }
        }
        "waves" => {
            let ys = h / u.unit;
            let n = ((8.0 + u.density * 52.0) as usize).min(60);
            // Each line's height changes only along x: worked once a column.
            let mut ly = vec![0.0f32; W * n];
            for x in 0..W {
                let xx = (x as f32 + 0.5) / u.unit + u.seed.0;
                for i in 0..n {
                    let tt = i as f32 / ((n - 1).max(1)) as f32;
                    let amp = 0.5 + 0.5 * (tt * 3.14159).sin();
                    ly[x * n + i] = 0.06
                        + tt * 0.88
                        + amp
                            * (0.055 * (xx * 1.5 + t * 0.45 + tt * 2.6).sin()
                                + 0.030 * (xx * 3.3 - t * 0.33 + tt * 5.0 + u.seed.1).sin()
                                + 0.030 * (noise(xx * 0.9 + t * 0.08, tt * 3.0) - 0.5))
                            / ys.max(0.5)
                            * 1.6;
                }
            }
            let colours: Vec<V3> = (0..n)
                .map(|i| {
                    let tt = i as f32 / ((n - 1).max(1)) as f32;
                    if tt < 0.5 { mix3(c1, c2, tt * 2.0) } else { mix3(c2, c3, tt * 2.0 - 1.0) }
                })
                .collect();
            let wd = 0.5 + u.intensity * 1.6;
            let reach = 4.0 + u.glow * 14.0;
            for y in 0..H {
                for x in 0..W {
                    let (uvx, uvy) = at(x, y);
                    let (px, py) = (uvx * w, uvy * h);
                    let mut col = mix3(bg1, bg2, uvy);
                    let mut halo = [0.0f32; 3];
                    for i in 0..n {
                        let d = (uvy - ly[x * n + i]).abs() * h;
                        // Past ten glows nothing shows.
                        if d > reach * 10.0 {
                            continue;
                        }
                        let lc = colours[i];
                        let a = 1.0 - smoothstep(wd - 0.6, wd + 0.6, d);
                        if a > 0.0 {
                            col = mix3(col, lc, a * (0.55 + 0.45 * u.intensity));
                        }
                        let g = (-d / reach).exp();
                        halo = [halo[0] + lc[0] * g, halo[1] + lc[1] * g, halo[2] + lc[2] * g];
                    }
                    let k = u.glow * 0.10;
                    put(x, y, dither([col[0] + halo[0] * k, col[1] + halo[1] * k, col[2] + halo[2] * k], px, py, t));
                }
            }
        }
        "stars" => {
            let chance = 0.05 + u.density * 0.30;
            let sc = mix3([1.0; 3], c3, 0.35);
            // The nebula, soft: at half the size.
            let np = |px: f32, py: f32| (px / u.unit * 1.3 + u.seed.0, py / u.unit * 1.3 + u.seed.1);
            let neb_f = Half::new(|px, py| {
                let (nx, ny) = np(px, py);
                fbm(nx + t * 0.015, ny - t * 0.01)
            });
            let neb2_f = Half::new(|px, py| {
                let (nx, ny) = np(px, py);
                fbm(nx * 1.7 - 4.0 - t * 0.01, ny * 1.7 - 4.0 + t * 0.012)
            });
            for y in 0..H {
                for x in 0..W {
                    let (uvx, uvy) = at(x, y);
                    let (px, py) = (uvx * w, uvy * h);
                    let mut col = mix3(bg1, bg2, uvy);
                    let (neb, neb2) = (neb_f.at(x, y), neb2_f.at(x, y));
                    let nc = mix3(c1, c2, smoothstep(0.3, 0.7, neb2));
                    col = mix3(col, nc, smoothstep(0.42, 0.85, neb) * u.glow * 0.75);
                    let mut s = star_layer(px + t * 2.0, py, 28.0, chance, t, u.seed.0);
                    s += star_layer(px + t * 5.0, py + t * 0.6, 46.0, chance * 0.7, t * 1.3, u.seed.1) * 1.1;
                    s += star_layer(px + t * 11.0, py + t * 1.4, 80.0, chance * 0.5, t * 0.8, u.seed.0 + 3.0) * 1.3;
                    col = mix3(col, sc, (s * (0.4 + u.intensity * 0.8)).clamp(0.0, 1.0));
                    put(x, y, dither(col, px, py, t));
                }
            }
        }
        "synth" => {
            let aspect = w / h.max(1.0);
            let hz = 0.62;
            let r = 0.24;
            let cells = 1.5 + u.density * 5.0;
            // The fields fwidth() is taken of: the sun's distance, its
            // bands, and the grid.
            let mut fd = vec![0.0f32; W * H];
            let mut fs = vec![0.0f32; W * H];
            let mut gx = vec![0.0f32; W * H];
            let mut gz = vec![0.0f32; W * H];
            for y in 0..H {
                for x in 0..W {
                    let (uvx, uvy) = at(x, y);
                    let (spx, spy) = ((uvx - 0.5) * aspect, uvy - (hz - 0.17));
                    let i = y * W + x;
                    fd[i] = len(spx, spy);
                    fs[i] = (spy + r) * 16.0 - t * 0.35;
                    let yy = (uvy - hz).max(1e-4);
                    let z = 0.12 / yy;
                    gx[i] = (uvx - 0.5) * aspect * z * cells;
                    gz[i] = (z + t * 0.6) * cells;
                }
            }
            for y in 0..H {
                for x in 0..W {
                    let (uvx, uvy) = at(x, y);
                    let (px, py) = (uvx * w, uvy * h);
                    let i = y * W + x;
                    let spy = uvy - (hz - 0.17);
                    let d = fd[i];
                    let dw = fwidth(&fd, x, y);
                    let s = fs[i];
                    let sw = fwidth(&fs, x, y);
                    let mut col;
                    if uvy < hz {
                        col = mix3(bg1, bg2, (uvy / hz).powf(1.6));
                        let k = ((spy + r) / (2.0 * r)).clamp(0.0, 1.0);
                        let sun = mix3(c2, c3, k);
                        let f = fract(s);
                        let thr = ((k - 0.45) * 1.2).max(0.0);
                        let cut = (smoothstep(-sw, sw, f) * (1.0 - smoothstep(thr - sw, thr + sw, f))).max(smoothstep(1.0 - sw, 1.0 + sw, f))
                            * if thr >= 0.001 { 1.0 } else { 0.0 };
                        let inside = (1.0 - smoothstep(r - dw, r + dw, d)) * (1.0 - cut);
                        col = mix3(col, sun, inside);
                        col = mix3(col, c2, (-(d - r).max(0.0) * 9.0).exp() * u.glow * 0.45 * (1.0 - inside));
                        col = mix3(col, [1.0; 3], sparkle(px, py, 0.22, t * 2.0, u.seed).clamp(0.0, 1.0) * (1.0 - uvy / hz) * 0.8 * (1.0 - inside));
                    } else {
                        let yy = uvy - hz;
                        let fwx = fwidth(&gx, x, y).max(1e-4);
                        let fwz = fwidth(&gz, x, y).max(1e-4);
                        let lx = (fract(gx[i] - 0.5) - 0.5).abs() / fwx;
                        let lz = (fract(gz[i] - 0.5) - 0.5).abs() / fwz;
                        let line = 1.0 - (lx.min(lz) / (1.0 + u.intensity * 1.5)).min(1.0);
                        let fade = smoothstep(0.0, 0.25, yy);
                        let ground = mix3([bg1[0] * 0.6, bg1[1] * 0.6, bg1[2] * 0.6], [bg2[0] * 0.35, bg2[1] * 0.35, bg2[2] * 0.35], smoothstep(0.0, 0.4, yy));
                        col = mix3(ground, c1, (line * fade).clamp(0.0, 1.0));
                        col = mix3(col, c1, (-yy * 18.0).exp() * u.glow * 0.5);
                    }
                    col = mix3(col, c3, (-(uvy - hz).abs() * h / 3.0).exp() * 0.6);
                    put(x, y, dither(col, px, py, t));
                }
            }
        }
        "cells" => {
            let k = 1.5 + u.density * 6.0;
            let mut edge = vec![0.0f32; W * H];
            let mut fill = vec![[0.0f32; 3]; W * H];
            for y in 0..H {
                for x in 0..W {
                    let (uvx, uvy) = at(x, y);
                    let (pxx, pyy) = (uvx * w / u.unit * k + u.seed.0, uvy * h / u.unit * k + u.seed.1);
                    let (ipx, ipy) = (pxx.floor(), pyy.floor());
                    let (fpx, fpy) = (pxx - ipx, pyy - ipy);
                    let (mut f1, mut f2) = (8.0f32, 8.0f32);
                    let mut best = (0.0, 0.0);
                    for j in -1..=1 {
                        for i in -1..=1 {
                            let (ox, oy) = (i as f32, j as f32);
                            let hh = hash2(ipx + ox, ipy + oy);
                            let ptx = ox + 0.5 + 0.42 * (t * 0.35 + 6.2831 * hh.0).sin();
                            let pty = oy + 0.5 + 0.42 * (t * 0.35 + 6.2831 * hh.1).sin();
                            let d = len(ptx - fpx, pty - fpy);
                            if d < f1 {
                                f2 = f1;
                                f1 = d;
                                best = (ipx + ox, ipy + oy);
                            } else if d < f2 {
                                f2 = d;
                            }
                        }
                    }
                    let i = y * W + x;
                    edge[i] = f2 - f1;
                    let hh = hash1(best.0, best.1);
                    let f = mix3(bg1, bg2, hh);
                    fill[i] = mix3(f, c2, 0.18 * (0.5 + 0.5 * (t * 0.6 + hh * 30.0).sin()));
                }
            }
            for y in 0..H {
                for x in 0..W {
                    let i = y * W + x;
                    let (uvx, uvy) = at(x, y);
                    let fw = fwidth(&edge, x, y);
                    let line = 1.0 - smoothstep(0.0, fw * (1.2 + u.intensity * 2.5), edge[i]);
                    let mut col = mix3(fill[i], c1, line * (0.35 + u.intensity * 0.65));
                    let g = (-edge[i] * (30.0 - u.glow * 22.0)).exp() * u.glow * 0.45;
                    col = [col[0] + c3[0] * g, col[1] + c3[1] * g, col[2] + c3[2] * g];
                    put(x, y, dither(col, uvx * w, uvy * h, t));
                }
            }
        }
        _ => {}
    }
}

// ── topography (topo.frag) ─────────────────────────────────────────────
fn thash2(x: f32, y: f32) -> (f32, f32) {
    let h = hash2(x, y);
    (-1.0 + 2.0 * h.0, -1.0 + 2.0 * h.1)
}
fn tnoise(x: f32, y: f32) -> f32 {
    let (ix, iy) = (x.floor(), y.floor());
    let (fx, fy) = (x - ix, y - iy);
    let (ux, uy) = (fx * fx * (3.0 - 2.0 * fx), fy * fy * (3.0 - 2.0 * fy));
    let g = |ox: f32, oy: f32| {
        let h = thash2(ix + ox, iy + oy);
        h.0 * (fx - ox) + h.1 * (fy - oy)
    };
    mix(mix(g(0.0, 0.0), g(1.0, 0.0), ux), mix(g(0.0, 1.0), g(1.0, 1.0), ux), uy)
}
fn tfbm(mut x: f32, mut y: f32, detail: f32) -> f32 {
    let (mut amp, mut sum, mut norm) = (0.5, 0.0, 0.0);
    for i in 0..6 {
        if i as f32 >= detail {
            break;
        }
        sum += amp * tnoise(x, y);
        norm += amp;
        let (nx, ny) = (0.8 * x - 0.6 * y, 0.6 * x + 0.8 * y);
        x = nx * 2.03 + 1.7;
        y = ny * 2.03 + 9.2;
        amp *= 0.5;
    }
    sum / norm
}

pub fn render_topo(tp: &Topo, time: f32, rise: f32, out: &mut [u8]) {
    let (w, h) = (W as f32, H as f32);
    let mut fv = vec![0.0f32; W * H];
    let mut fh = vec![0.0f32; W * H];
    // The warp, soft: at half the size.
    let pos = |x: f32, y: f32| (x / tp.unit + tp.seed.0, y / tp.unit + tp.seed.1);
    let qxf = Half::new(|x, y| {
        let (px, py) = pos(x, y);
        tfbm(px + time * 0.021, py + time * 0.013, tp.detail)
    });
    let qyf = Half::new(|x, y| {
        let (px, py) = pos(x, y);
        tfbm(px + 5.2 - time * 0.017, py + 1.3 - time * 0.024, tp.detail)
    });
    for y in 0..H {
        for x in 0..W {
            let (uvx, uvy) = ((x as f32 + 0.5) / w, (y as f32 + 0.5) / h);
            let (px, py) = (uvx * w / tp.unit + tp.seed.0, uvy * h / tp.unit + tp.seed.1);
            let (qx, qy) = (qxf.at(x, y), qyf.at(x, y));
            let hh = tfbm(px + tp.warp * 2.5 * qx, py + tp.warp * 2.5 * qy, tp.detail);
            let hh = (0.5 + hh * 1.25).clamp(0.0, 1.0);
            fh[y * W + x] = hh;
            fv[y * W + x] = hh * tp.levels + rise;
        }
    }
    for y in 0..H {
        for x in 0..W {
            let i = y * W + x;
            let v = fv[i];
            let fw = fwidth(&fv, x, y).max(1e-5);
            let d = (fract(v + 0.5) - 0.5).abs() / fw;
            let index = (v + 0.5).floor();
            let major = tp.major > 0.5 && index.rem_euclid(tp.major) < 0.5;
            let lw = tp.line_width * if major { 1.9 } else { 1.0 };
            let crowd = 1.0 - smoothstep(0.25, 0.5, fw);
            let mut a = 1.0 - smoothstep(lw * 0.5 - 0.6, lw * 0.5 + 0.6, d);
            a *= tp.alpha * if major || tp.major < 0.5 { 1.0 } else { 0.65 };
            a *= crowd;
            let g = tp.glow * (-d / (lw * 2.5).max(1.0)).exp() * tp.alpha * crowd;
            let t = if tp.shade < 0.5 {
                (y as f32 + 0.5) / h
            } else if tp.shade < 1.5 {
                fh[i]
            } else {
                1.0 - (fract(v.floor() / (tp.levels - 1.0).max(1.0) * 0.5) * 2.0 - 1.0).abs()
            };
            let bg = mix3(tp.low, tp.high, t.clamp(0.0, 1.0));
            let c = mix3(bg, tp.line, a);
            let o = i * 4;
            for k in 0..3 {
                out[o + k] = ((c[k] + tp.line[k] * g * 0.6).clamp(0.0, 1.0) * 255.0) as u8;
            }
            out[o + 3] = 255;
        }
    }
}

// ── running it ─────────────────────────────────────────────────────────
/// The thread drawing the gallery. `on` while it's on screen; the settings
/// it draws from are handed over whenever they change.
pub struct Gallery {
    on: Arc<AtomicBool>,
    look: Arc<Mutex<Option<(Vec<Uni>, Topo)>>>,
}

impl Gallery {
    pub fn start(weak: slint::Weak<crate::AppWindow>) -> Gallery {
        let on = Arc::new(AtomicBool::new(false));
        let look: Arc<Mutex<Option<(Vec<Uni>, Topo)>>> = Arc::new(Mutex::new(None));
        let (on2, look2) = (on.clone(), look.clone());
        std::thread::spawn(move || {
            let (mut time, mut ttime, mut rise) = (vec![0.0f32; STYLES.len()], 0.0f32, 0.0f32);
            let frame = Duration::from_millis(1000 / 24);
            loop {
                let t0 = Instant::now();
                if !on2.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(200));
                    continue;
                }
                let Some((unis, topo)) = look2.lock().unwrap().clone() else {
                    std::thread::sleep(Duration::from_millis(50));
                    continue;
                };
                // A thread a style: each tile is its own work.
                let mut bufs: Vec<SharedPixelBuffer<Rgba8Pixel>> = (0..STYLES.len()).map(|_| SharedPixelBuffer::new(W as u32, H as u32)).collect();
                std::thread::scope(|s| {
                    for (i, buf) in bufs.iter_mut().enumerate() {
                        let (key, u, topo, t) = (STYLES[i].0, &unis[i], &topo, time[i]);
                        s.spawn(move || {
                            let out = buf.make_mut_bytes();
                            if key == "topo" {
                                render_topo(topo, ttime, rise, out);
                            } else {
                                render(key, u, t, out);
                            }
                        });
                    }
                });
                let dt = frame.as_secs_f32();
                for (i, u) in unis.iter().enumerate() {
                    time[i] += dt * u.speed;
                }
                if topo.drift {
                    ttime += dt * topo.speed;
                }
                if topo.flow {
                    rise += dt * topo.speed * 0.35;
                }
                let _ = weak.upgrade_in_event_loop(move |ui| {
                    let g = ui.global::<crate::AnimLook>();
                    let tiles: Vec<AnimTile> = g
                        .get_tiles()
                        .iter()
                        .zip(bufs)
                        .map(|(mut t, b)| {
                            t.img = Image::from_rgba8(b);
                            t
                        })
                        .collect();
                    g.set_tiles(ModelRc::new(VecModel::from(tiles)));
                });
                if let Some(rest) = frame.checked_sub(t0.elapsed()) {
                    std::thread::sleep(rest);
                }
            }
        });
        Gallery { on, look }
    }

    /// Shown or not, and the settings to draw from; the tiles' words and
    /// the palette strips into the window.
    pub fn show(&self, ui: &crate::AppWindow, p: &Prefs, on: bool) {
        self.on.store(on, Ordering::Relaxed);
        if !on {
            return;
        }
        let unis: Vec<Uni> = STYLES.iter().map(|s| uniforms(p, s.0)).collect();
        *self.look.lock().unwrap() = Some((unis, topo_uniforms(p)));
        let g = ui.global::<crate::AnimLook>();
        let style = p.s("wallpaperStyle");
        let old = g.get_tiles();
        let tiles: Vec<AnimTile> = STYLES
            .iter()
            .enumerate()
            .map(|(i, (k, n))| AnimTile {
                key: (*k).into(),
                name: (*n).into(),
                chosen: style == *k,
                img: old.row_data(i).map(|t| t.img).unwrap_or_default(),
            })
            .collect();
        g.set_tiles(ModelRc::new(VecModel::from(tiles)));
        // The palettes: the theme's, the presets, your own.
        let topo = style == "topo";
        let pal = p.s("animPalette");
        let (ta, tb) = tint(p);
        let accent = p.accent().map(|x| x as f32);
        let ink = if p.dark() { hex("#f8f4f4") } else { hex("#201e1d") };
        let mut chips = vec![PalChip {
            key: "theme".into(),
            name: "Theme".into(),
            chosen: if topo { p.s("topoGround") == "theme" } else { pal == "theme" },
            colours: strip([tb, ta, accent, accent, ink]),
        }];
        for (k, n, c) in PRESETS.iter() {
            chips.push(PalChip { key: (*k).into(), name: (*n).into(), chosen: !topo && pal == *k, colours: strip(c.map(hex)) });
        }
        chips.push(PalChip {
            key: "custom".into(),
            name: "Custom".into(),
            chosen: !topo && pal == "custom",
            colours: strip(["animBg1", "animBg2", "animC1", "animC2", "animC3"].map(|k| hex(&p.s(k)))),
        });
        g.set_palettes(ModelRc::new(VecModel::from(chips)));
    }
}

fn strip(c: [V3; 5]) -> ModelRc<slint::Color> {
    ModelRc::new(VecModel::from(
        c.iter().map(|v| slint::Color::from_rgb_u8((v[0] * 255.0).round() as u8, (v[1] * 255.0).round() as u8, (v[2] * 255.0).round() as u8)).collect::<Vec<_>>(),
    ))
}

/// AnimatedGallery.choose: a palette, and for the topographic map its
/// ground and lines from it.
pub fn choose_palette(p: &Prefs, key: &str) -> Vec<(&'static str, serde_json::Value)> {
    use serde_json::json;
    let mut out = vec![("animPalette", json!(key))];
    if p.s("wallpaperStyle") != "topo" {
        return out;
    }
    if key == "theme" {
        out.push(("topoGround", json!("theme")));
        out.push(("topoLine", json!("ink")));
        return out;
    }
    let c = if key == "custom" {
        [hex(&p.s("animBg1")), hex(&p.s("animBg2")), hex(&p.s("animC1"))]
    } else {
        match PRESETS.iter().find(|x| x.0 == key) {
            Some((_, _, c)) => [hex(c[0]), hex(c[1]), hex(c[2])],
            None => return out,
        }
    };
    out.push(("topoGround", json!("custom")));
    out.push(("topoLow", json!(to_hex(c[0]))));
    out.push(("topoHigh", json!(to_hex(c[1]))));
    out.push(("topoLine", json!("custom")));
    out.push(("topoLineCustom", json!(to_hex(c[2]))));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frame_cost() {
        let u = Uni { seed: (3.0, 5.0), unit: 650.0 * W as f32 / 1280.0, density: 0.5, glow: 0.5, intensity: 0.6, c: PRESETS[0].2.map(hex), speed: 1.0 };
        let tp = Topo {
            seed: (1.0, 2.0), unit: 650.0 * W as f32 / 1280.0, detail: 4.0, warp: 0.5, levels: 14.0, line_width: 0.9, major: 5.0, alpha: 0.8,
            shade: 0.0, glow: 0.2, line: [1.0; 3], low: [0.1; 3], high: [0.3; 3], speed: 1.0, drift: true, flow: true,
        };
        let mut out = vec![0u8; W * H * 4];
        for (k, _) in STYLES {
            let t0 = Instant::now();
            for i in 0..10 {
                if k == "topo" { render_topo(&tp, i as f32, 0.0, &mut out) } else { render(k, &u, i as f32, &mut out) }
            }
            eprintln!("{k}: {:.1} ms/frame", t0.elapsed().as_secs_f64() * 100.0);
        }
    }
}
