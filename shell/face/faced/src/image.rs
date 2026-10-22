//! Pictures as the models want them: 8-bit RGB, row by row.

/// An RGB picture, 3 bytes a pixel, rows packed.
#[derive(Clone)]
pub struct Rgb {
    pub w: usize,
    pub h: usize,
    pub px: Vec<u8>,
}

impl Rgb {
    /// A greyscale picture (the infrared camera's) as RGB: the models were
    /// trained on colour, and take grey as three equal channels.
    pub fn from_gray(w: usize, h: usize, gray: &[u8]) -> Rgb {
        let mut px = Vec::with_capacity(w * h * 3);
        for &g in &gray[..w * h] {
            px.extend_from_slice(&[g, g, g]);
        }
        Rgb { w, h, px }
    }

    /// YUYV 4:2:2, what most webcams send uncompressed.
    pub fn from_yuyv(w: usize, h: usize, yuyv: &[u8]) -> Rgb {
        let mut px = Vec::with_capacity(w * h * 3);
        for quad in yuyv[..w * h * 2].chunks_exact(4) {
            let (y0, u, y1, v) = (quad[0] as f32, quad[1] as f32 - 128.0, quad[2] as f32, quad[3] as f32 - 128.0);
            for y in [y0, y1] {
                let r = y + 1.402 * v;
                let g = y - 0.344 * u - 0.714 * v;
                let b = y + 1.772 * u;
                px.extend_from_slice(&[clamp(r), clamp(g), clamp(b)]);
            }
        }
        Rgb { w, h, px }
    }

    /// A JPEG (a webcam's MJPEG frame, or a still from Settings).
    pub fn from_jpeg(data: &[u8]) -> Option<Rgb> {
        use zune_jpeg::zune_core::colorspace::ColorSpace;
        use zune_jpeg::zune_core::options::DecoderOptions;
        let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGB);
        let mut decoder = zune_jpeg::JpegDecoder::new_with_options(data, options);
        let px = decoder.decode().ok()?;
        let (w, h) = decoder.dimensions()?;
        (px.len() == w * h * 3).then_some(Rgb { w, h, px })
    }

    /// Average brightness, 0-255.
    pub fn light(&self) -> f32 {
        if self.px.is_empty() {
            return 0.0;
        }
        // Every 7th pixel is plenty for an average.
        let mut sum = 0u64;
        let mut n = 0u64;
        for p in self.px.chunks_exact(3).step_by(7) {
            sum += (p[0] as u64 * 299 + p[1] as u64 * 587 + p[2] as u64 * 114) / 1000;
            n += 1;
        }
        sum as f32 / n.max(1) as f32
    }

    /// Bilinear sample at (x, y); black outside.
    #[inline]
    pub fn sample(&self, x: f32, y: f32) -> [f32; 3] {
        let x0 = x.floor();
        let y0 = y.floor();
        let (fx, fy) = (x - x0, y - y0);
        let (x0, y0) = (x0 as isize, y0 as isize);
        let mut out = [0.0f32; 3];
        for (dy, wy) in [(0isize, 1.0 - fy), (1, fy)] {
            for (dx, wx) in [(0isize, 1.0 - fx), (1, fx)] {
                let (xx, yy) = (x0 + dx, y0 + dy);
                if xx < 0 || yy < 0 || xx >= self.w as isize || yy >= self.h as isize {
                    continue;
                }
                let i = (yy as usize * self.w + xx as usize) * 3;
                let wgt = wx * wy;
                out[0] += self.px[i] as f32 * wgt;
                out[1] += self.px[i + 1] as f32 * wgt;
                out[2] += self.px[i + 2] as f32 * wgt;
            }
        }
        out
    }

    /// Scaled to `w` wide, its shape kept (area-averaged when shrinking,
    /// so a halving loses nothing to aliasing).
    pub fn scaled_to_width(&self, w: usize) -> Rgb {
        if w >= self.w {
            return self.clone();
        }
        let k = self.w as f32 / w as f32;
        let h = ((self.h as f32 / k).round() as usize).max(1);
        let mut px = vec![0u8; w * h * 3];
        for y in 0..h {
            let sy0 = (y as f32 * k) as usize;
            let sy1 = (((y + 1) as f32 * k) as usize).clamp(sy0 + 1, self.h);
            for x in 0..w {
                let sx0 = (x as f32 * k) as usize;
                let sx1 = (((x + 1) as f32 * k) as usize).clamp(sx0 + 1, self.w);
                let mut acc = [0u32; 3];
                for sy in sy0..sy1 {
                    for sx in sx0..sx1 {
                        let i = (sy * self.w + sx) * 3;
                        acc[0] += self.px[i] as u32;
                        acc[1] += self.px[i + 1] as u32;
                        acc[2] += self.px[i + 2] as u32;
                    }
                }
                let n = ((sy1 - sy0) * (sx1 - sx0)) as u32;
                let o = (y * w + x) * 3;
                px[o] = (acc[0] / n) as u8;
                px[o + 1] = (acc[1] / n) as u8;
                px[o + 2] = (acc[2] / n) as u8;
            }
        }
        Rgb { w, h, px }
    }
}

#[inline]
fn clamp(v: f32) -> u8 {
    v.round().clamp(0.0, 255.0) as u8
}
