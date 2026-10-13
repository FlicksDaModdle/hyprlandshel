//! The shell's glyphs (its IconPaths.js, as icons.json — regenerate with
//! `node tools/gen-icons.mjs`), drawn the way its MonoIcon draws them in
//! image mode: one SVG per glyph, size and pair of colours, shared by every
//! copy on screen.

use slint::{Color, Image};
use std::cell::RefCell;
use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(serde::Deserialize, Default)]
struct Spec {
    #[serde(default)]
    ink: Option<String>,
    #[serde(default)]
    acc: Option<String>,
    #[serde(default, rename = "inkW")]
    ink_w: Option<String>,
    #[serde(default, rename = "accW")]
    acc_w: Option<String>,
    #[serde(default)]
    fill: Option<String>,
    #[serde(default, rename = "fillInk")]
    fill_ink: Option<String>,
    #[serde(default)]
    dots: Vec<[f32; 4]>,
}

fn table() -> &'static HashMap<String, Spec> {
    static T: OnceLock<HashMap<String, Spec>> = OnceLock::new();
    T.get_or_init(|| {
        let mut t: HashMap<String, Spec> = serde_json::from_str(include_str!("../icons.json")).unwrap_or_default();
        let extra: HashMap<String, Spec> = serde_json::from_str(include_str!("../extra-icons.json")).unwrap_or_default();
        t.extend(extra);
        t
    })
}

pub fn has(name: &str) -> bool {
    table().contains_key(name)
}

fn paint(c: Color, kind: &str) -> String {
    let mut s = format!("{kind}=\"#{:02x}{:02x}{:02x}\"", c.red(), c.green(), c.blue());
    if c.alpha() < 255 {
        s += &format!(" {kind}-opacity=\"{:.3}\"", c.alpha() as f32 / 255.0);
    }
    s
}

pub fn svg(name: &str, ink: Color, acc: Color, size: f32) -> Option<String> {
    let sp = table().get(name)?;
    // The stroke is held at 2 device pixels whatever the size (MonoIcon's
    // rule): 2 authored units at 13 px would be a one-pixel smudge.
    let k = 24.0 / size.max(1.0);
    let stroke = (2.0 * k).max(2.0);
    let stroke_w = stroke * 1.5;
    let line = |d: &Option<String>, c: Color, w: f32| match d {
        Some(d) => format!(
            "<path d=\"{d}\" fill=\"none\" {} stroke-width=\"{w}\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>",
            paint(c, "stroke")
        ),
        None => String::new(),
    };
    let area = |d: &Option<String>, c: Color| match d {
        Some(d) => format!("<path d=\"{d}\" {} fill-rule=\"evenodd\"/>", paint(c, "fill")),
        None => String::new(),
    };
    let mut out = String::from("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\">");
    out += &area(&sp.fill_ink, ink);
    out += &area(&sp.fill, acc);
    out += &line(&sp.ink, ink, stroke);
    out += &line(&sp.acc, acc, stroke);
    out += &line(&sp.ink_w, ink, stroke_w);
    out += &line(&sp.acc_w, acc, stroke_w);
    for d in &sp.dots {
        out += &format!("<circle cx=\"{}\" cy=\"{}\" r=\"{}\" {}/>", d[0], d[1], d[2], paint(if d[3] > 0.5 { acc } else { ink }, "fill"));
    }
    out += "</svg>";
    Some(out)
}

thread_local! {
    static CACHE: RefCell<HashMap<(String, u32, u32, u32), Image>> = RefCell::new(HashMap::new());
}

/// The glyph as an image, or an empty one for a name the table lacks.
pub fn image(name: &str, ink: Color, acc: Color, size: f32) -> Image {
    if name.is_empty() {
        return Image::default();
    }
    let key = (name.to_string(), argb(ink), argb(acc), size.round().max(1.0) as u32);
    if let Some(img) = CACHE.with(|c| c.borrow().get(&key).cloned()) {
        return img;
    }
    let img = svg(name, ink, acc, size)
        .and_then(|s| Image::load_from_svg_data(s.as_bytes()).ok())
        .unwrap_or_default();
    CACHE.with(|c| {
        let mut c = c.borrow_mut();
        // Colours follow the theme; a palette change leaves the old ones
        // behind, so the cache is let go of now and then.
        if c.len() > 2000 {
            c.clear();
        }
        c.insert(key, img.clone());
    });
    img
}

fn argb(c: Color) -> u32 {
    (c.alpha() as u32) << 24 | (c.red() as u32) << 16 | (c.green() as u32) << 8 | c.blue() as u32
}
