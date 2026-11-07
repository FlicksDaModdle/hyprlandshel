//! The image behind a frosted menu: the window as it is, the part under the
//! menu cut out and blurred. Slint draws no backdrop blur of its own, so
//! when a menu opens the app looks at its own window (`take_snapshot`), crops
//! the menu's rectangle and runs a box blur over it three times, which is a
//! close match for a Gaussian one. Settings → Appearance → Frosted menus.

use slint::{Image, Rgba8Pixel, SharedPixelBuffer};

/// A three-pass box blur of an RGBA image, `radius` pixels, edges held.
pub fn blur(buf: &mut SharedPixelBuffer<Rgba8Pixel>, radius: usize) {
    let (w, h) = (buf.width() as usize, buf.height() as usize);
    if w == 0 || h == 0 || radius == 0 {
        return;
    }
    let px = buf.make_mut_slice();
    let mut tmp = px.to_vec();
    for _ in 0..3 {
        pass(px, &mut tmp, w, h, radius, true);
        pass(&tmp, px, w, h, radius, false);
    }
}

/// One direction: each pixel the mean of the `2r+1` along the line.
fn pass(src: &[Rgba8Pixel], dst: &mut [Rgba8Pixel], w: usize, h: usize, r: usize, horizontal: bool) {
    let (lines, len) = if horizontal { (h, w) } else { (w, h) };
    let at = |line: usize, i: usize| -> usize { if horizontal { line * w + i } else { i * w + line } };
    let n = (2 * r + 1) as u32;
    for line in 0..lines {
        let mut sum = [0u32; 4];
        let get = |i: isize| -> &Rgba8Pixel { &src[at(line, i.clamp(0, len as isize - 1) as usize)] };
        for k in -(r as isize)..=(r as isize) {
            let p = get(k);
            sum[0] += p.r as u32;
            sum[1] += p.g as u32;
            sum[2] += p.b as u32;
            sum[3] += p.a as u32;
        }
        for i in 0..len {
            dst[at(line, i)] = Rgba8Pixel { r: (sum[0] / n) as u8, g: (sum[1] / n) as u8, b: (sum[2] / n) as u8, a: (sum[3] / n) as u8 };
            let (out, inn) = (get(i as isize - r as isize), get(i as isize + r as isize + 1));
            sum[0] = sum[0] + inn.r as u32 - out.r as u32;
            sum[1] = sum[1] + inn.g as u32 - out.g as u32;
            sum[2] = sum[2] + inn.b as u32 - out.b as u32;
            sum[3] = sum[3] + inn.a as u32 - out.a as u32;
        }
    }
}

/// The blurred part of a snapshot under a rectangle given in logical pixels.
pub fn behind(snapshot: &SharedPixelBuffer<Rgba8Pixel>, scale: f32, x: f32, y: f32, w: f32, h: f32, radius_px: f32) -> Option<Image> {
    let (sw, sh) = (snapshot.width() as i32, snapshot.height() as i32);
    let x0 = ((x * scale).floor() as i32).clamp(0, sw - 1);
    let y0 = ((y * scale).floor() as i32).clamp(0, sh - 1);
    let x1 = (((x + w) * scale).ceil() as i32).clamp(x0 + 1, sw);
    let y1 = (((y + h) * scale).ceil() as i32).clamp(y0 + 1, sh);
    let (cw, ch) = ((x1 - x0) as usize, (y1 - y0) as usize);
    let mut out = SharedPixelBuffer::<Rgba8Pixel>::new(cw as u32, ch as u32);
    let src = snapshot.as_slice();
    let dst = out.make_mut_slice();
    for row in 0..ch {
        let from = (y0 as usize + row) * sw as usize + x0 as usize;
        dst[row * cw..(row + 1) * cw].copy_from_slice(&src[from..from + cw]);
    }
    blur(&mut out, radius_px.round().max(1.0) as usize);
    Some(Image::from_rgba8(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_blur_spreads_an_edge_and_keeps_the_mean() {
        // Left half black, right half white.
        let mut b = SharedPixelBuffer::<Rgba8Pixel>::new(20, 4);
        for (i, p) in b.make_mut_slice().iter_mut().enumerate() {
            let v = if i % 20 >= 10 { 255 } else { 0 };
            *p = Rgba8Pixel { r: v, g: v, b: v, a: 255 };
        }
        blur(&mut b, 3);
        let row = &b.as_slice()[0..20];
        // Far from the edge it is still black and white; at it, grey.
        assert!(row[0].r < 5 && row[19].r > 250);
        assert!(row[10].r > 60 && row[10].r < 200, "the edge is soft: {}", row[10].r);
        assert!(row.windows(2).all(|w| w[0].r <= w[1].r), "and it rises");
    }
}
