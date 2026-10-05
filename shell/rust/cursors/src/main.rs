//! hyprshell-cursors — turns the shell's cursor set (services/Cursor.qml
//! draws it, as SVG, in the accent colour) into an installed cursor theme.
//!
//!   hyprshell-cursors <spec.json> <theme dir> [--preview sheet.png]
//!
//! Two themes in one directory, for the two ways a cursor is asked for:
//!
//!   hyprcursors/   Hyprland's own format: per shape a zip (.hlc) holding the
//!                  SVGs and a meta.hl. Drawn from the SVG at whatever size is
//!                  asked, so it is sharp at any scale. Hyprland uses it for
//!                  its own cursor and for every app that asks by name through
//!                  cursor-shape-v1 — most native Wayland apps.
//!   cursors/       XCursor, rendered here at a set of sizes, for everything
//!                  that loads a cursor theme itself: XWayland, GTK 3, older Qt.
//!
//! The spec, from the shell:
//!   { "name": "Hyprshell", "sizes": [24, 32, 48, 64, 96],
//!     "shapes": [ { "name": "default", "aliases": ["left_ptr", …],
//!                   "hot": [0.22, 0.12], "delay": 0, "frames": ["<svg …>", …] } ] }
//!
//! The same contract as the Qt version in ../../agent/cursors.cpp, which is
//! what install.sh builds when there is no cargo. This one draws with resvg,
//! which follows the SVG specification more closely than QtSvg and needs no
//! Qt module.
//!
//! The theme is built beside the target and swapped in whole, so nothing
//! reading it ever sees half of one.

use resvg::{tiny_skia, usvg};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

// ── a zip, stored (no compression), as hyprcursor reads one ──────────────

fn crc32(data: &[u8]) -> u32 {
    let mut table = [0u32; 256];
    for (i, slot) in table.iter_mut().enumerate() {
        let mut c = i as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
        }
        *slot = c;
    }
    let mut c = 0xFFFF_FFFFu32;
    for &b in data {
        c = table[((c ^ b as u32) & 0xFF) as usize] ^ (c >> 8);
    }
    c ^ 0xFFFF_FFFF
}

fn le16(b: &mut Vec<u8>, v: u16) {
    b.extend_from_slice(&v.to_le_bytes());
}
fn le32(b: &mut Vec<u8>, v: u32) {
    b.extend_from_slice(&v.to_le_bytes());
}

fn make_zip(files: &[(String, Vec<u8>)]) -> Vec<u8> {
    let mut out = Vec::new();
    let mut central = Vec::new();
    for (name, data) in files {
        let name = name.as_bytes();
        let crc = crc32(data);
        let offset = out.len() as u32;
        le32(&mut out, 0x0403_4b50);
        le16(&mut out, 20);
        le16(&mut out, 0);
        le16(&mut out, 0);
        le16(&mut out, 0);
        le16(&mut out, 0x21); // 1980-01-01 00:00
        le32(&mut out, crc);
        le32(&mut out, data.len() as u32);
        le32(&mut out, data.len() as u32);
        le16(&mut out, name.len() as u16);
        le16(&mut out, 0);
        out.extend_from_slice(name);
        out.extend_from_slice(data);

        le32(&mut central, 0x0201_4b50);
        le16(&mut central, 20);
        le16(&mut central, 20);
        le16(&mut central, 0);
        le16(&mut central, 0);
        le16(&mut central, 0);
        le16(&mut central, 0x21);
        le32(&mut central, crc);
        le32(&mut central, data.len() as u32);
        le32(&mut central, data.len() as u32);
        le16(&mut central, name.len() as u16);
        for _ in 0..4 {
            le16(&mut central, 0);
        }
        le32(&mut central, 0);
        le32(&mut central, offset);
        central.extend_from_slice(name);
    }
    let cd_offset = out.len() as u32;
    let cd_len = central.len() as u32;
    out.extend_from_slice(&central);
    le32(&mut out, 0x0605_4b50);
    le16(&mut out, 0);
    le16(&mut out, 0);
    le16(&mut out, files.len() as u16);
    le16(&mut out, files.len() as u16);
    le32(&mut out, cd_len);
    le32(&mut out, cd_offset);
    le16(&mut out, 0);
    out
}

// ── drawing ───────────────────────────────────────────────────────────────

/// The SVG drawn into a size×size square, as premultiplied RGBA.
fn render(svg: &str, size: u32) -> Result<tiny_skia::Pixmap, String> {
    let tree = usvg::Tree::from_str(svg, &usvg::Options::default()).map_err(|e| e.to_string())?;
    let mut pixmap = tiny_skia::Pixmap::new(size, size).ok_or("zero-sized cursor")?;
    let s = tree.size();
    let transform = tiny_skia::Transform::from_scale(size as f32 / s.width(), size as f32 / s.height());
    resvg::render(&tree, transform, &mut pixmap.as_mut());
    Ok(pixmap)
}

// ── XCursor ───────────────────────────────────────────────────────────────

struct XImage {
    size: u32,
    xhot: u32,
    yhot: u32,
    delay: u32,
    img: tiny_skia::Pixmap,
}

fn make_xcursor(images: &[XImage]) -> Vec<u8> {
    let mut out = Vec::new();
    let ntoc = images.len() as u32;
    le32(&mut out, 0x7275_6358); // "Xcur"
    le32(&mut out, 16);
    le32(&mut out, 0x10000);
    le32(&mut out, ntoc);
    let mut pos = 16 + ntoc * 12;
    for im in images {
        le32(&mut out, 0xfffd_0002);
        le32(&mut out, im.size);
        le32(&mut out, pos);
        pos += 36 + im.img.width() * im.img.height() * 4;
    }
    for im in images {
        le32(&mut out, 36);
        le32(&mut out, 0xfffd_0002);
        le32(&mut out, im.size);
        le32(&mut out, 1);
        le32(&mut out, im.img.width());
        le32(&mut out, im.img.height());
        le32(&mut out, im.xhot);
        le32(&mut out, im.yhot);
        le32(&mut out, im.delay);
        // XCursor pixels are premultiplied ARGB words; tiny-skia's are
        // premultiplied RGBA bytes.
        for px in im.img.pixels() {
            let v = (px.alpha() as u32) << 24 | (px.red() as u32) << 16 | (px.green() as u32) << 8 | px.blue() as u32;
            le32(&mut out, v);
        }
    }
    out
}

fn write_png(path: &Path, pixmap: &tiny_skia::Pixmap) -> Result<(), String> {
    // PNG wants straight (not premultiplied) alpha.
    let mut data = Vec::with_capacity((pixmap.width() * pixmap.height() * 4) as usize);
    for px in pixmap.pixels() {
        let c = px.demultiply();
        data.extend_from_slice(&[c.red(), c.green(), c.blue(), c.alpha()]);
    }
    let file = fs::File::create(path).map_err(|e| e.to_string())?;
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), pixmap.width(), pixmap.height());
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut w = enc.write_header().map_err(|e| e.to_string())?;
    w.write_image_data(&data).map_err(|e| e.to_string())
}

fn parse_colour(s: &str) -> tiny_skia::Color {
    let h = s.trim_start_matches('#');
    let v = u32::from_str_radix(h, 16).unwrap_or(0x808080);
    tiny_skia::Color::from_rgba8((v >> 16) as u8, (v >> 8) as u8, v as u8, 255)
}

fn run(args: &[String]) -> Result<PathBuf, String> {
    let spec: Value = serde_json::from_slice(&fs::read(&args[1]).map_err(|e| format!("cannot read {}: {e}", args[1]))?)
        .map_err(|e| format!("bad spec: {e}"))?;
    let name = spec["name"].as_str().unwrap_or("Hyprshell");
    let mut sizes: Vec<u32> = spec["sizes"].as_array().map(|a| a.iter().filter_map(|v| v.as_u64()).map(|v| v as u32).collect()).unwrap_or_default();
    if sizes.is_empty() {
        sizes = vec![24, 32, 48, 64, 96];
    }
    let empty = Vec::new();
    let shapes = spec["shapes"].as_array().unwrap_or(&empty);

    let target = PathBuf::from(args[2].trim_end_matches('/'));
    let tmp = PathBuf::from(format!("{}.new", target.display()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(tmp.join("hyprcursors")).map_err(|e| format!("cannot create {}: {e}", tmp.display()))?;
    fs::create_dir_all(tmp.join("cursors")).map_err(|e| format!("cannot create {}: {e}", tmp.display()))?;

    fs::write(
        tmp.join("manifest.hl"),
        format!("name = {name}\ndescription = Drawn by Hyprshell in its accent colour\nversion = 1\ncursors_directory = hyprcursors\n"),
    )
    .map_err(|e| e.to_string())?;
    fs::write(tmp.join("index.theme"), format!("[Icon Theme]\nName={name}\nComment=Drawn by Hyprshell in its accent colour\n"))
        .map_err(|e| e.to_string())?;

    let mut written: Vec<String> = Vec::new(); // names with a real XCursor file, so aliases never replace one
    for s in shapes {
        let shape = s["name"].as_str().unwrap_or("");
        let frames: Vec<&str> = s["frames"].as_array().map(|a| a.iter().filter_map(|f| f.as_str()).collect()).unwrap_or_default();
        if shape.is_empty() || frames.is_empty() {
            continue;
        }
        let hx = s["hot"][0].as_f64().unwrap_or(0.0);
        let hy = s["hot"][1].as_f64().unwrap_or(0.0);
        let delay = s["delay"].as_u64().unwrap_or(0) as u32;
        let aliases: Vec<&str> = s["aliases"].as_array().map(|a| a.iter().filter_map(|v| v.as_str()).collect()).unwrap_or_default();

        // hyprcursor
        let mut meta = format!("resize_algorithm = bilinear\nhotspot_x = {hx}\nhotspot_y = {hy}\nnominal_size = 1.0\n");
        for a in &aliases {
            meta.push_str(&format!("define_override = {a}\n"));
        }
        let mut files: Vec<(String, Vec<u8>)> = Vec::new();
        for (i, f) in frames.iter().enumerate() {
            let file = format!("{shape}_{i}.svg");
            meta.push_str(&format!("define_size = 0, {file}"));
            if frames.len() > 1 && delay > 0 {
                meta.push_str(&format!(", {delay}"));
            }
            meta.push('\n');
            files.push((file, f.as_bytes().to_vec()));
        }
        files.insert(0, ("meta.hl".to_string(), meta.into_bytes()));
        fs::write(tmp.join("hyprcursors").join(format!("{shape}.hlc")), make_zip(&files)).map_err(|e| e.to_string())?;

        // XCursor
        let mut images = Vec::new();
        for &size in &sizes {
            for f in &frames {
                images.push(XImage {
                    size,
                    xhot: (hx * size as f64).round() as u32,
                    yhot: (hy * size as f64).round() as u32,
                    delay: if frames.len() > 1 { delay } else { 0 },
                    img: render(f, size).map_err(|e| format!("{shape}: {e}"))?,
                });
            }
        }
        fs::write(tmp.join("cursors").join(shape), make_xcursor(&images)).map_err(|e| e.to_string())?;
        written.push(shape.to_string());
        for a in &aliases {
            let link = tmp.join("cursors").join(a);
            if *a == shape || written.iter().any(|w| w == a) || link.symlink_metadata().is_ok() {
                continue;
            }
            let _ = std::os::unix::fs::symlink(shape, &link);
        }
    }

    // A sheet of every shape, for looking at.
    if let Some(pi) = args.iter().position(|a| a == "--preview") {
        if let Some(out) = args.get(pi + 1) {
            let (cell, cols) = (72u32, 8u32);
            let rows = ((shapes.len() as u32) + cols - 1) / cols;
            let mut sheet = tiny_skia::Pixmap::new(cols * cell, rows.max(1) * cell).ok_or("empty sheet")?;
            sheet.fill(parse_colour(spec["previewBg"].as_str().unwrap_or("#808080")));
            for (i, s) in shapes.iter().enumerate() {
                if let Some(f) = s["frames"][0].as_str() {
                    let img = render(f, 64)?;
                    let (x, y) = ((i as u32 % cols) * cell + 4, (i as u32 / cols) * cell + 4);
                    sheet.draw_pixmap(x as i32, y as i32, img.as_ref(), &tiny_skia::PixmapPaint::default(), tiny_skia::Transform::identity(), None);
                }
            }
            write_png(Path::new(out), &sheet)?;
        }
    }

    // Swap the new theme in whole.
    let old = PathBuf::from(format!("{}.old", target.display()));
    let _ = fs::remove_dir_all(&old);
    if target.exists() {
        fs::rename(&target, &old).map_err(|e| format!("cannot move the old theme aside: {e}"))?;
    }
    if let Err(e) = fs::rename(&tmp, &target) {
        let _ = fs::rename(&old, &target);
        return Err(format!("cannot put the new theme in place: {e}"));
    }
    let _ = fs::remove_dir_all(&old);
    Ok(target)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: hyprshell-cursors <spec.json> <theme dir> [--preview sheet.png]");
        return ExitCode::from(2);
    }
    match run(&args) {
        Ok(target) => {
            println!("{}", target.display());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
