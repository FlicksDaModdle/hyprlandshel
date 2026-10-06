//! Render an SVG icon to the PNG sizes desktops and Firefox use.
//!
//!   hyprshell-render-icon <icon.svg> <out dir> [prefix] [sizes…]
//!
//! Writes <out dir>/<prefix><size>.png for each size (prefix "default",
//! sizes 16 32 48 64 128 256 unless given) — what browser/branding holds.
//! The picture is scaled to fill each square, as a desktop draws an icon.

use resvg::{tiny_skia, usvg};
use std::path::Path;

fn write_png(path: &Path, pixmap: &tiny_skia::Pixmap) -> Result<(), String> {
    // PNG wants straight (not premultiplied) alpha.
    let mut data = Vec::with_capacity((pixmap.width() * pixmap.height() * 4) as usize);
    for px in pixmap.pixels() {
        let c = px.demultiply();
        data.extend_from_slice(&[c.red(), c.green(), c.blue(), c.alpha()]);
    }
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), pixmap.width(), pixmap.height());
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut w = enc.write_header().map_err(|e| e.to_string())?;
    w.write_image_data(&data).map_err(|e| e.to_string())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: hyprshell-render-icon <icon.svg> <out dir> [prefix] [sizes…]");
        std::process::exit(2);
    }
    let svg = std::fs::read(&args[1]).unwrap_or_else(|e| {
        eprintln!("{}: {e}", args[1]);
        std::process::exit(1)
    });
    let tree = usvg::Tree::from_data(&svg, &usvg::Options::default()).unwrap_or_else(|e| {
        eprintln!("{}: {e}", args[1]);
        std::process::exit(1)
    });
    let prefix = args.get(3).map(|s| s.as_str()).unwrap_or("default");
    let mut sizes: Vec<u32> = args.iter().skip(4).filter_map(|s| s.parse().ok()).collect();
    if sizes.is_empty() {
        sizes = vec![16, 32, 48, 64, 128, 256];
    }
    let view = tree.size();
    for s in sizes {
        let mut pix = tiny_skia::Pixmap::new(s, s).expect("size");
        let t = tiny_skia::Transform::from_scale(s as f32 / view.width(), s as f32 / view.height());
        resvg::render(&tree, t, &mut pix.as_mut());
        let out = Path::new(&args[2]).join(format!("{prefix}{s}.png"));
        if let Err(e) = write_png(&out, &pix) {
            eprintln!("{}: {e}", out.display());
            std::process::exit(1);
        }
    }
    println!("rendered");
}
