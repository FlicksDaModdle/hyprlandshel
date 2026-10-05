//! The accent colour taken from the wallpaper, for Settings → Appearance →
//! "Accent from wallpaper" (off unless chosen; services/WallpaperAccent.qml).
//!
//! Command:  wp-accent {path}
//! Event:    wp-accent {path, light, dark}  or  {path, error}
//!
//! The picture is shrunk to a few thousand pixels and each is placed by
//! hue in OKLCH, weighted by how vivid it is; the strongest hue wins, and
//! its average colour is fitted twice — once dark enough to read on the
//! light theme, once light enough for the dark one — and kept inside sRGB.
//! A picture with no real colour in it (grey, black and white) gives an
//! error, and the shell keeps the accent it had.

use crate::out;
use serde_json::{json, Value};
use std::sync::mpsc::{channel, Sender};

fn lin(c: f32) -> f32 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}
fn gam(c: f32) -> f32 {
    if c <= 0.0031308 {
        12.92 * c
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

fn to_oklab(r: u8, g: u8, b: u8) -> [f32; 3] {
    let (r, g, b) = (lin(r as f32 / 255.0), lin(g as f32 / 255.0), lin(b as f32 / 255.0));
    let l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b).cbrt();
    let m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b).cbrt();
    let s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b).cbrt();
    [
        0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
        1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
        0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
    ]
}

/// Linear-light sRGB, possibly out of 0..1.
fn from_oklab(lab: [f32; 3]) -> [f32; 3] {
    let l = (lab[0] + 0.3963377774 * lab[1] + 0.2158037573 * lab[2]).powi(3);
    let m = (lab[0] - 0.1055613458 * lab[1] - 0.0638541728 * lab[2]).powi(3);
    let s = (lab[0] - 0.0894841775 * lab[1] - 1.2914855480 * lab[2]).powi(3);
    [
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ]
}

/// L, C, h → "#rrggbb", lowering the chroma until it fits sRGB.
fn fit(l: f32, mut c: f32, h: f32) -> String {
    loop {
        let rgb = from_oklab([l, c * h.cos(), c * h.sin()]);
        if rgb.iter().all(|v| (-0.0005..=1.0005).contains(v)) || c < 0.005 {
            let hex: Vec<String> = rgb.iter().map(|v| format!("{:02x}", (gam(v.clamp(0.0, 1.0)) * 255.0).round() as u8)).collect();
            return format!("#{}", hex.concat());
        }
        c -= 0.005;
    }
}

const BINS: usize = 36;

fn pick(path: &str) -> Result<(String, String), String> {
    let img = image::ImageReader::open(path)
        .map_err(|e| e.to_string())?
        .with_guessed_format()
        .map_err(|e| e.to_string())?
        .decode()
        .map_err(|e| e.to_string())?;
    let small = img.thumbnail(96, 96).to_rgb8();
    drop(img);

    let mut weight = [0f32; BINS];
    let mut sum = [[0f32; 3]; BINS];
    let mut vivid = 0usize;
    let total = (small.width() * small.height()).max(1) as usize;
    for p in small.pixels() {
        let lab = to_oklab(p[0], p[1], p[2]);
        let c = (lab[1] * lab[1] + lab[2] * lab[2]).sqrt();
        // Greys, near-black and near-white say nothing about a colour.
        if c < 0.04 || lab[0] < 0.2 || lab[0] > 0.96 {
            continue;
        }
        vivid += 1;
        let h = lab[2].atan2(lab[1]);
        let bin = (((h + std::f32::consts::PI) / std::f32::consts::TAU) * BINS as f32) as usize % BINS;
        // Vivid and mid-light counts most: that is what reads as "the
        // colour of" a picture.
        let w = c * c * (1.0 - (lab[0] - 0.65).abs());
        weight[bin] += w;
        for k in 0..3 {
            sum[bin][k] += lab[k] * w;
        }
    }
    if vivid * 50 < total {
        return Err("the wallpaper has almost no colour in it".into());
    }
    // A hue split across two bins is still one hue: each bin counted with
    // half its neighbours'.
    let score = |i: usize| weight[i] + 0.5 * (weight[(i + BINS - 1) % BINS] + weight[(i + 1) % BINS]);
    let best = (0..BINS).max_by(|a, b| score(*a).total_cmp(&score(*b))).unwrap();
    let (mut w, mut lab) = (0f32, [0f32; 3]);
    for i in [(best + BINS - 1) % BINS, best, (best + 1) % BINS] {
        w += weight[i];
        for k in 0..3 {
            lab[k] += sum[i][k];
        }
    }
    if w <= 0.0 {
        return Err("no colour found".into());
    }
    let (a, b) = (lab[1] / w, lab[2] / w);
    let h = b.atan2(a);
    // Strong enough to be an accent, not so strong it glares.
    let c = ((a * a + b * b).sqrt() * 1.15).clamp(0.09, 0.2);
    Ok((fit(0.60, c, h), fit(0.75, c, h)))
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    std::thread::spawn(move || {
        for c in rx {
            let path = c["path"].as_str().unwrap_or("").to_string();
            if path.is_empty() {
                continue;
            }
            match pick(&path) {
                Ok((light, dark)) => out::emit(json!({ "ev": "wp-accent", "path": path, "light": light, "dark": dark })),
                Err(e) => out::emit(json!({ "ev": "wp-accent", "path": path, "error": e })),
            }
            // A decoded 4K picture is tens of megabytes, held only for a
            // moment: give it back.
            #[cfg(target_env = "gnu")]
            unsafe {
                libc::malloc_trim(0);
            }
        }
    });
    tx
}
