//! The two models, run with tract (pure Rust, nothing to install):
//!
//!   YuNet (face_detection_yunet_2023mar.onnx, MIT)    where faces are, and
//!       five points on each: eyes, nose tip, mouth corners
//!   SFace (face_recognition_sface_2021dec.onnx, Apache-2.0)    a face,
//!       lined up by those five points, as 128 numbers; two of the same
//!       person point the same way (cosine similarity near 1)
//!
//! Both from OpenCV's model zoo; their pre- and post-processing here follow
//! OpenCV's FaceDetectorYN and FaceRecognizerSF, number for number.

use std::collections::HashMap;
use std::path::Path;

use tract_onnx::prelude::*;

use crate::image::Rgb;

type Plan = SimplePlan<TypedFact, Box<dyn TypedOp>, Graph<TypedFact, Box<dyn TypedOp>>>;

/// A face found: its box, its five points, how sure YuNet is.
#[derive(Clone, Debug)]
pub struct Face {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    /// Right eye, left eye, nose tip, right and left mouth corners.
    pub points: [[f32; 2]; 5],
    pub score: f32,
}

/// The width faces are looked for at: small is fast, and a face at arm's
/// length is still 50 pixels across in it.
pub const DETECT_WIDTH: usize = 320;

pub struct Detector {
    proto: tract_onnx::pb::ModelProto,
    /// Output order, by name: cls, obj, bbox, kps for strides 8, 16, 32.
    order: Vec<usize>,
    /// One optimised plan per input size (the IR camera's shape, the
    /// webcam's), made the first time it's needed.
    plans: HashMap<(usize, usize), Plan>,
    pub threshold: f32,
}

/// Loads an ONNX model with its stored shapes for every layer left out:
/// YuNet's file fixes them at 640 × 640, and they're worked out afresh for
/// the size it's given.
fn load_proto(path: &Path) -> TractResult<tract_onnx::pb::ModelProto> {
    let mut proto = tract_onnx::onnx().proto_model_for_path(path)?;
    if let Some(graph) = proto.graph.as_mut() {
        graph.value_info.clear();
        for output in graph.output.iter_mut() {
            output.r#type = None;
        }
    }
    Ok(proto)
}

const STRIDES: [usize; 3] = [8, 16, 32];

impl Detector {
    pub fn load(path: &Path) -> TractResult<Detector> {
        let proto = load_proto(path)?;
        let names: Vec<String> = proto.graph.as_ref().map(|g| g.output.iter().map(|o| o.name.clone()).collect()).unwrap_or_default();
        let mut order = Vec::new();
        for kind in ["cls", "obj", "bbox", "kps"] {
            for stride in STRIDES {
                let want = format!("{kind}_{stride}");
                let at = names.iter().position(|n| *n == want).ok_or_else(|| TractError::msg(format!("YuNet has no output {want}")))?;
                order.push(at);
            }
        }
        Ok(Detector { proto, order, plans: HashMap::new(), threshold: 0.8 })
    }

    fn plan(&mut self, w: usize, h: usize) -> TractResult<&Plan> {
        if !self.plans.contains_key(&(w, h)) {
            let plan = tract_onnx::onnx()
                .model_for_proto_model(&self.proto)?
                .with_input_fact(0, f32::fact([1, 3, h, w]).into())?
                .into_optimized()?
                .into_runnable()?;
            self.plans.insert((w, h), plan);
        }
        Ok(&self.plans[&(w, h)])
    }

    /// The faces in a picture, biggest first, in its own coordinates.
    pub fn detect(&mut self, picture: &Rgb) -> TractResult<Vec<Face>> {
        let small = picture.scaled_to_width(DETECT_WIDTH);
        let k = picture.w as f32 / small.w as f32;
        // Padded with black to a multiple of 32, right and bottom.
        let pw = small.w.div_ceil(32) * 32;
        let ph = small.h.div_ceil(32) * 32;
        // BGR, 0-255, as OpenCV's blobFromImage gives it.
        let mut input = tract_ndarray::Array4::<f32>::zeros((1, 3, ph, pw));
        for y in 0..small.h {
            for x in 0..small.w {
                let i = (y * small.w + x) * 3;
                input[[0, 0, y, x]] = small.px[i + 2] as f32;
                input[[0, 1, y, x]] = small.px[i + 1] as f32;
                input[[0, 2, y, x]] = small.px[i] as f32;
            }
        }
        let threshold = self.threshold;
        let order = self.order.clone();
        let outputs = self.plan(pw, ph)?.run(tvec!(Tensor::from(input).into()))?;
        let view = |n: usize| -> TractResult<Vec<f32>> {
            Ok(outputs[order[n]].to_array_view::<f32>()?.iter().copied().collect())
        };

        let mut faces = Vec::new();
        for (s, stride) in STRIDES.iter().enumerate() {
            let (cls, obj, bbox, kps) = (view(s)?, view(3 + s)?, view(6 + s)?, view(9 + s)?);
            let cols = pw / stride;
            let rows = ph / stride;
            let st = *stride as f32;
            for r in 0..rows {
                for c in 0..cols {
                    let i = r * cols + c;
                    if i >= cls.len() {
                        break;
                    }
                    let score = (cls[i].clamp(0.0, 1.0) * obj[i].clamp(0.0, 1.0)).sqrt();
                    if score < threshold {
                        continue;
                    }
                    let cx = (c as f32 + bbox[i * 4]) * st;
                    let cy = (r as f32 + bbox[i * 4 + 1]) * st;
                    let w = bbox[i * 4 + 2].exp() * st;
                    let h = bbox[i * 4 + 3].exp() * st;
                    let mut points = [[0.0f32; 2]; 5];
                    for (n, p) in points.iter_mut().enumerate() {
                        p[0] = (kps[i * 10 + 2 * n] + c as f32) * st * k;
                        p[1] = (kps[i * 10 + 2 * n + 1] + r as f32) * st * k;
                    }
                    faces.push(Face { x: (cx - w / 2.0) * k, y: (cy - h / 2.0) * k, w: w * k, h: h * k, points, score });
                }
            }
        }
        Ok(suppress(faces, 0.3))
    }
}

/// Non-maximum suppression: of boxes that overlap much, the surest stays.
/// Biggest first after that.
fn suppress(mut faces: Vec<Face>, iou: f32) -> Vec<Face> {
    faces.sort_by(|a, b| b.score.total_cmp(&a.score));
    let mut kept: Vec<Face> = Vec::new();
    for f in faces {
        let overlaps = kept.iter().any(|k| {
            let ix = (f.x + f.w).min(k.x + k.w) - f.x.max(k.x);
            let iy = (f.y + f.h).min(k.y + k.h) - f.y.max(k.y);
            let inter = ix.max(0.0) * iy.max(0.0);
            inter / (f.w * f.h + k.w * k.h - inter) > iou
        });
        if !overlaps {
            kept.push(f);
        }
    }
    kept.sort_by(|a, b| (b.w * b.h).total_cmp(&(a.w * a.h)));
    kept
}

/// Where SFace expects the five points, in its 112 × 112 picture.
const TEMPLATE: [[f32; 2]; 5] =
    [[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655], [70.7299, 92.2041]];

pub struct Recognizer {
    plan: Plan,
}

impl Recognizer {
    pub fn load(path: &Path) -> TractResult<Recognizer> {
        let plan = tract_onnx::onnx()
            .model_for_proto_model(&load_proto(path)?)?
            .with_input_fact(0, f32::fact([1, 3, 112, 112]).into())?
            .into_optimized()?
            .into_runnable()?;
        Ok(Recognizer { plan })
    }

    /// The face, turned, scaled and moved so its five points sit where
    /// SFace expects them: a similarity transform, least squares
    /// (Umeyama's, as OpenCV's alignCrop), then sampled bilinearly.
    pub fn align(picture: &Rgb, face: &Face) -> Rgb {
        let n = 5.0;
        let (mut sx, mut sy, mut dx, mut dy) = (0.0f64, 0.0, 0.0, 0.0);
        for i in 0..5 {
            sx += face.points[i][0] as f64;
            sy += face.points[i][1] as f64;
            dx += TEMPLATE[i][0] as f64;
            dy += TEMPLATE[i][1] as f64;
        }
        let (sx, sy, dx, dy) = (sx / n, sy / n, dx / n, dy / n);
        // dst - mean = (a + ib)(src - mean), in complex numbers.
        let (mut num_re, mut num_im, mut den) = (0.0f64, 0.0f64, 0.0f64);
        for i in 0..5 {
            let (px, py) = (face.points[i][0] as f64 - sx, face.points[i][1] as f64 - sy);
            let (qx, qy) = (TEMPLATE[i][0] as f64 - dx, TEMPLATE[i][1] as f64 - dy);
            num_re += px * qx + py * qy;
            num_im += px * qy - py * qx;
            den += px * px + py * py;
        }
        let (a, b) = if den > 0.0 { (num_re / den, num_im / den) } else { (1.0, 0.0) };
        // Forward: x' = a x - b y + tx, y' = b x + a y + ty. Each output
        // pixel is fetched from the inverse.
        let tx = dx - (a * sx - b * sy);
        let ty = dy - (b * sx + a * sy);
        let det = a * a + b * b;
        let mut px = vec![0u8; 112 * 112 * 3];
        for v in 0..112 {
            for u in 0..112 {
                let (ux, vy) = (u as f64 - tx, v as f64 - ty);
                let x = (a * ux + b * vy) / det;
                let y = (-b * ux + a * vy) / det;
                let c = picture.sample(x as f32, y as f32);
                let o = (v * 112 + u) * 3;
                px[o] = c[0].round().clamp(0.0, 255.0) as u8;
                px[o + 1] = c[1].round().clamp(0.0, 255.0) as u8;
                px[o + 2] = c[2].round().clamp(0.0, 255.0) as u8;
            }
        }
        Rgb { w: 112, h: 112, px }
    }

    /// The face as 128 numbers, of length 1.
    pub fn describe(&self, picture: &Rgb, face: &Face) -> TractResult<Vec<f32>> {
        let aligned = Recognizer::align(picture, face);
        // RGB, 0-255 (OpenCV's blobFromImage with swapRB from BGR).
        let mut input = tract_ndarray::Array4::<f32>::zeros((1, 3, 112, 112));
        for y in 0..112 {
            for x in 0..112 {
                let i = (y * 112 + x) * 3;
                for ch in 0..3 {
                    input[[0, ch, y, x]] = aligned.px[i + ch] as f32;
                }
            }
        }
        let out = self.plan.run(tvec!(Tensor::from(input).into()))?;
        let mut v: Vec<f32> = out[0].to_array_view::<f32>()?.iter().copied().collect();
        let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-6);
        v.iter_mut().for_each(|x| *x /= norm);
        Ok(v)
    }
}

/// How alike two faces are: 1 the same, around 0 strangers.
pub fn similarity(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// The best similarity of a face to any of a set.
pub fn best(face: &[f32], known: &[Vec<f32>]) -> f32 {
    known.iter().map(|k| similarity(face, k)).fold(-1.0, f32::max)
}
