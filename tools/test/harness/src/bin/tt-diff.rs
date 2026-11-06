//! tt-diff REFERENCE NEW DIFF.png [TOLERANCE]: how much of a screenshot
//! differs from its reference. A pixel counts when any channel is off by
//! more than 24 (anti-aliasing and blur differ a little between runs); the
//! pictures match when at most TOLERANCE percent of pixels count (0.5 by
//! default). The differing pixels are drawn red over a faded copy into
//! DIFF.png. Prints the percentage; exit 0 for a match, 1 for not, 2 when a
//! picture can't be read or the sizes differ.
fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 4 {
        eprintln!("tt-diff REFERENCE NEW DIFF.png [TOLERANCE]");
        std::process::exit(2);
    }
    let tol: f64 = a.get(4).and_then(|t| t.parse().ok()).unwrap_or(0.5);
    let (Ok(r), Ok(n)) = (image::open(&a[1]), image::open(&a[2])) else {
        eprintln!("tt-diff: can't read the pictures");
        std::process::exit(2);
    };
    let (r, n) = (r.to_rgba8(), n.to_rgba8());
    if r.dimensions() != n.dimensions() {
        println!("size {:?} against {:?}", n.dimensions(), r.dimensions());
        std::process::exit(2);
    }
    let mut out = image::RgbaImage::new(r.width(), r.height());
    let mut off = 0u64;
    for (x, y, p) in r.enumerate_pixels() {
        let q = n.get_pixel(x, y);
        let bad = (0..3).any(|i| (p[i] as i32 - q[i] as i32).abs() > 24);
        if bad {
            off += 1;
            out.put_pixel(x, y, image::Rgba([255, 0, 0, 255]));
        } else {
            let g = (q[0] as u32 + q[1] as u32 + q[2] as u32) / 3;
            let g = (g / 3 + 170) as u8;
            out.put_pixel(x, y, image::Rgba([g, g, g, 255]));
        }
    }
    let pct = off as f64 * 100.0 / (r.width() as f64 * r.height() as f64);
    println!("{pct:.3}%");
    if pct > tol {
        let _ = out.save(&a[3]);
        std::process::exit(1);
    }
}
