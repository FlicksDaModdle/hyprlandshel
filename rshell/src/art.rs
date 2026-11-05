//! Pictures, decoded into pixels Slint can show: album art, notification
//! images and icons. PNG, JPEG and WebP through `image`; SVG drawn by resvg
//! at the size it will be shown, so it stays sharp. Everything here runs on
//! helper threads: a `SharedPixelBuffer` crosses threads, a `slint::Image`
//! does not, so the main loop makes the Image.

use slint::{Rgba8Pixel, SharedPixelBuffer};
use std::path::Path;

pub type Pixels = SharedPixelBuffer<Rgba8Pixel>;

/// Fits within `max`×`max`, keeping its shape; never scaled up.
fn fit(img: image::RgbaImage, max: u32) -> Pixels {
    let (w, h) = img.dimensions();
    let img = if w > max || h > max {
        let k = max as f32 / w.max(h) as f32;
        image::imageops::resize(&img, ((w as f32 * k).round() as u32).max(1), ((h as f32 * k).round() as u32).max(1), image::imageops::FilterType::Triangle)
    } else {
        img
    };
    let (w, h) = img.dimensions();
    SharedPixelBuffer::clone_from_slice(img.as_raw(), w, h)
}

fn svg(data: &[u8], size: u32) -> Option<Pixels> {
    let tree = resvg::usvg::Tree::from_data(data, &resvg::usvg::Options::default()).ok()?;
    let s = tree.size();
    let k = size as f32 / s.width().max(s.height());
    let (w, h) = (((s.width() * k).round() as u32).max(1), ((s.height() * k).round() as u32).max(1));
    let mut map = resvg::tiny_skia::Pixmap::new(w, h)?;
    resvg::render(&tree, resvg::tiny_skia::Transform::from_scale(k, k), &mut map.as_mut());
    // tiny-skia keeps premultiplied alpha; Slint wants it straight.
    let mut px = map.take();
    for p in px.chunks_exact_mut(4) {
        let a = p[3] as u32;
        if a > 0 && a < 255 {
            for c in &mut p[..3] {
                *c = ((*c as u32 * 255 + a / 2) / a).min(255) as u8;
            }
        }
    }
    Some(SharedPixelBuffer::clone_from_slice(&px, w, h))
}

/// A picture from a file, at most `size` pixels on its long side.
pub fn file(path: &Path, size: u32) -> Option<Pixels> {
    let data = std::fs::read(path).ok()?;
    bytes(&data, size)
}

/// A picture from its bytes, whatever kind it is.
pub fn bytes(data: &[u8], size: u32) -> Option<Pixels> {
    let head = &data[..data.len().min(256)];
    let text = String::from_utf8_lossy(head);
    if text.contains("<svg") || text.contains("<?xml") {
        return svg(data, size);
    }
    let img = image::load_from_memory(data).ok()?.to_rgba8();
    Some(fit(img, size))
}

/// Raw pixels as notifications send them (image-data: width, height,
/// rowstride, has_alpha, bits, channels, data).
pub fn raw(w: i32, h: i32, stride: i32, alpha: bool, data: &[u8], size: u32) -> Option<Pixels> {
    let (w, h, stride) = (w.max(0) as usize, h.max(0) as usize, stride.max(0) as usize);
    let ch = if alpha { 4 } else { 3 };
    if w == 0 || h == 0 || data.len() < stride * (h - 1) + w * ch {
        return None;
    }
    let mut out = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        for x in 0..w {
            let p = &data[y * stride + x * ch..];
            out.extend_from_slice(&[p[0], p[1], p[2], if alpha { p[3] } else { 255 }]);
        }
    }
    let img = image::RgbaImage::from_raw(w as u32, h as u32, out)?;
    Some(fit(img, size))
}

/// ARGB32 in network order, as status notifier items send their pixmaps.
pub fn argb(w: i32, h: i32, data: &[u8], size: u32) -> Option<Pixels> {
    let (w, h) = (w.max(0) as usize, h.max(0) as usize);
    if w == 0 || h == 0 || data.len() < w * h * 4 {
        return None;
    }
    let mut out = Vec::with_capacity(w * h * 4);
    for p in data[..w * h * 4].chunks_exact(4) {
        out.extend_from_slice(&[p[1], p[2], p[3], p[0]]);
    }
    let img = image::RgbaImage::from_raw(w as u32, h as u32, out)?;
    Some(fit(img, size))
}

/// Album art from an MPRIS artUrl: a file, or a web address fetched once
/// into the cache (with curl, which every system here has).
pub fn album(url: &str, size: u32) -> Option<Pixels> {
    if let Some(p) = url.strip_prefix("file://") {
        let p = percent_decode(p);
        return file(Path::new(&p), size);
    }
    if url.starts_with("https://") || url.starts_with("http://") {
        let cache = std::env::var_os("XDG_CACHE_HOME")
            .map(std::path::PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".cache")))?
            .join("hyprshell/art");
        let _ = std::fs::create_dir_all(&cache);
        let name = format!("{:016x}", hash(url));
        let path = cache.join(name);
        if !path.exists() {
            let tmp = path.with_extension("part");
            let ok = std::process::Command::new("curl")
                .args(["-sfL", "--max-time", "8", "--max-filesize", "8000000", "-o"])
                .arg(&tmp)
                .arg(url)
                .status()
                .is_ok_and(|s| s.success());
            if !ok || std::fs::rename(&tmp, &path).is_err() {
                let _ = std::fs::remove_file(&tmp);
                return None;
            }
        }
        return file(&path, size);
    }
    None
}

fn hash(s: &str) -> u64 {
    // FNV-1a: a stable name for the cached file.
    s.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

pub fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
