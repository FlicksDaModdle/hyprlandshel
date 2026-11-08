//! A picture → shapes the icon maker can edit (modules/icons/Trace.js and
//! Svg.js). A bitmap is traced: the alpha (or, with none, the darkness) is
//! thresholded, the boundary between inside and outside walked, the
//! staircase simplified and joined with curves. An SVG is not traced —
//! it already is its curves — so its paths are read as they are.
//!
//! What comes back is ordinary `path` shapes in the maker's 24-unit grid,
//! so they rotate, take ink or accent and follow the accent afterwards.

use resvg::usvg;
use serde_json::{json, Value};
use std::collections::BTreeMap;

const UNITS: f64 = 24.0;
/// The size a bitmap is looked at: about five pixels to a grid unit.
pub const TRACE_SIZE: u32 = 128;

type P = (f64, f64);

fn r2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

// ── contours ──────────────────────────────────────────────────────────

/// Marching squares on the grayscale mask: the outline where it crosses
/// `thr`, placed between pixels by linear interpolation. The old way — walk
/// the edges between whole inside and outside pixels — leaves a staircase
/// that no amount of simplifying turns back into a smooth curve; this has
/// no stairs to begin with. The mask is padded with an empty border so every
/// outline closes.
fn contours(mask: &[f32], w: i32, h: i32, thr: f32) -> Vec<Vec<P>> {
    let (pw, ph) = (w + 2, h + 2);
    let at = |x: i32, y: i32| -> f32 {
        let (px, py) = (x - 1, y - 1);
        if px < 0 || py < 0 || px >= w || py >= h { 0.0 } else { mask[(py * w + px) as usize] }
    };
    // An edge: (x, y, 0) is the horizontal one from (x,y) to (x+1,y),
    // (x, y, 1) the vertical one from (x,y) to (x,y+1).
    type Id = (i32, i32, u8);
    let point = |id: Id| -> P {
        let (x, y, v) = id;
        let (x1, y1) = if v == 0 { (x + 1, y) } else { (x, y + 1) };
        let (a, b) = (at(x, y), at(x1, y1));
        let t = if (b - a).abs() < 1e-6 { 0.5 } else { ((thr - a) / (b - a)) as f64 };
        // Back to the unpadded image's pixel centres.
        ((x as f64 + (x1 - x) as f64 * t) - 1.0, (y as f64 + (y1 - y) as f64 * t) - 1.0)
    };
    let mut next: BTreeMap<Id, Id> = BTreeMap::new();
    for y in 0..ph - 1 {
        for x in 0..pw - 1 {
            // Clockwise round the cell: a (top left), b, c, d.
            let corner = [(x, y), (x + 1, y), (x + 1, y + 1), (x, y + 1)];
            let inside: Vec<bool> = corner.iter().map(|c| at(c.0, c.1) >= thr).collect();
            // The edges in the same order: top, right, bottom, left.
            let edges: [Id; 4] = [(x, y, 0), (x + 1, y, 1), (x, y + 1, 0), (x, y, 1)];
            // (edge, goes inside → outside round the cell?)
            let mut cross: Vec<(Id, bool)> = Vec::new();
            for i in 0..4 {
                let (p, q) = (inside[i], inside[(i + 1) % 4]);
                if p != q {
                    cross.push((edges[i], p));
                }
            }
            // Each way in is joined to the next way out, round the cell.
            for (i, (from, leaving)) in cross.iter().enumerate() {
                if *leaving {
                    continue;
                }
                for k in 1..=cross.len() {
                    let (to, leaving2) = cross[(i + k) % cross.len()];
                    if leaving2 {
                        next.insert(*from, to);
                        break;
                    }
                }
            }
        }
    }
    let mut loops = Vec::new();
    let mut seen: std::collections::BTreeSet<Id> = std::collections::BTreeSet::new();
    let keys: Vec<Id> = next.keys().copied().collect();
    for start in keys {
        if seen.contains(&start) {
            continue;
        }
        let mut lp: Vec<P> = Vec::new();
        let mut cur = start;
        loop {
            seen.insert(cur);
            lp.push(point(cur));
            match next.get(&cur) {
                Some(n) if *n != start && !seen.contains(n) => cur = *n,
                _ => break,
            }
        }
        if lp.len() >= 4 {
            // Wound so an outer outline has positive area and a hole negative.
            lp.reverse();
            loops.push(lp);
        }
    }
    loops
}

// ── simplification ────────────────────────────────────────────────────

fn perp(p: P, a: P, b: P) -> f64 {
    let (vx, vy) = (b.0 - a.0, b.1 - a.1);
    let len = vx.hypot(vy);
    if len == 0.0 {
        return (p.0 - a.0).hypot(p.1 - a.1);
    }
    ((p.0 - a.0) * vy - (p.1 - a.1) * vx).abs() / len
}

/// Douglas–Peucker, with a stack rather than recursion: a loop can be
/// thousands of points long.
fn simplify(points: &[P], eps: f64) -> Vec<P> {
    if points.len() < 3 {
        return points.to_vec();
    }
    let mut keep = vec![false; points.len()];
    keep[0] = true;
    keep[points.len() - 1] = true;
    let mut stack = vec![(0usize, points.len() - 1)];
    while let Some((first, last)) = stack.pop() {
        let (mut worst, mut at) = (0.0, None);
        for j in first + 1..last {
            let d = perp(points[j], points[first], points[last]);
            if d > worst {
                worst = d;
                at = Some(j);
            }
        }
        if let (true, Some(a)) = (worst > eps, at) {
            keep[a] = true;
            stack.push((first, a));
            stack.push((a, last));
        }
    }
    points.iter().zip(keep).filter(|(_, k)| *k).map(|(p, _)| *p).collect()
}

/// Drops the start/end duplicate of a loop and any point its neighbours imply.
fn prune_closed(pts: &[P], eps: f64) -> Vec<P> {
    let mut out = pts.to_vec();
    if out.len() > 1 {
        let (a, b) = (out[0], out[out.len() - 1]);
        if (a.0 - b.0).abs() < 1e-9 && (a.1 - b.1).abs() < 1e-9 {
            out.pop();
        }
    }
    let mut changed = true;
    while changed && out.len() > 3 {
        changed = false;
        for i in 0..out.len() {
            let n = out.len();
            let (prev, next) = (out[(i + n - 1) % n], out[(i + 1) % n]);
            if perp(out[i], prev, next) <= eps {
                out.remove(i);
                changed = true;
                break;
            }
        }
    }
    out
}

/// Catmull-Rom handles on every gentle turn; a sharp one stays a corner.
fn smooth_loop(pts: &[P], corner_deg: f64) -> Vec<Value> {
    let n = pts.len();
    let mut out = Vec::new();
    for i in 0..n {
        let p = pts[i];
        let (prev, next) = (pts[(i + n - 1) % n], pts[(i + 1) % n]);
        let corner = |p: P| json!({ "x": p.0, "y": p.1, "corner": true });
        let (ax, ay) = (p.0 - prev.0, p.1 - prev.1);
        let (bx, by) = (next.0 - p.0, next.1 - p.1);
        let (la, lb) = (ax.hypot(ay), bx.hypot(by));
        if la == 0.0 || lb == 0.0 {
            out.push(corner(p));
            continue;
        }
        let cos = ((ax * bx + ay * by) / (la * lb)).clamp(-1.0, 1.0);
        if cos.acos().to_degrees() > corner_deg {
            out.push(corner(p));
            continue;
        }
        let (mut dx, mut dy) = (next.0 - prev.0, next.1 - prev.1);
        let dl = dx.hypot(dy).max(f64::MIN_POSITIVE);
        dx /= dl;
        dy /= dl;
        out.push(json!({
            "x": p.0, "y": p.1,
            "hi": { "x": r2(p.0 - dx * la / 3.0), "y": r2(p.1 - dy * la / 3.0) },
            "ho": { "x": r2(p.0 + dx * lb / 3.0), "y": r2(p.1 + dy * lb / 3.0) },
        }));
    }
    out
}

fn signed_area(l: &[P]) -> f64 {
    let mut a = 0.0;
    let mut j = l.len() - 1;
    for i in 0..l.len() {
        a += l[j].0 * l[i].1 - l[i].0 * l[j].1;
        j = i;
    }
    a / 2.0
}

fn point_in_loop(p: P, l: &[P]) -> bool {
    let mut inside = false;
    let mut j = l.len() - 1;
    for i in 0..l.len() {
        let (a, b) = (l[i], l[j]);
        if (a.1 > p.1) != (b.1 > p.1) && p.0 < (b.0 - a.0) * (p.1 - a.1) / (b.1 - a.1) + a.0 {
            inside = !inside;
        }
        j = i;
    }
    inside
}

pub struct Opts {
    pub threshold: f64,
    pub detail: f64,
    /// Cells to the grid unit when the mask already is the grid (a shape cut apart): the
    /// outline keeps its place instead of being fitted to the square. 0 fits.
    pub cells: f64,
    /// The smallest ring kept, as a share of the mask (0 for the usual).
    pub min_area: f64,
}

impl Default for Opts {
    fn default() -> Self {
        Opts { threshold: 128.0, detail: 1.0, cells: 0.0, min_area: 0.0 }
    }
}

/// `mask` is one value per pixel, row major, `w` × `h`.
pub fn trace(mask: &[f32], w: u32, h: u32, o: &Opts) -> Result<Vec<Value>, String> {
    let (wi, hi) = (w as i32, h as i32);
    let margin = 2.0;
    let min_area = if o.min_area > 0.0 { o.min_area } else { 0.0006 };
    let corner_deg = 42.0;
    // Half a pixel of slack: the outline is already smooth, so this only
    // drops points that lie on a line.
    let eps = 0.5 / o.detail.max(0.1);

    if !mask.iter().any(|v| *v as f64 >= o.threshold) {
        return Err("Every pixel is transparent — is this the right image?".into());
    }
    let loops = contours(mask, wi, hi, o.threshold as f32);
    if loops.is_empty() {
        return Err("Nothing to trace.".into());
    }
    let (mut x0, mut y0, mut x1, mut y1) = (f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY);
    for p in loops.iter().flatten() {
        x0 = x0.min(p.0);
        x1 = x1.max(p.0);
        y0 = y0.min(p.1);
        y1 = y1.max(p.1);
    }

    // The drawing fitted into the grid, proportions kept.
    let (bw, bh) = ((x1 - x0).max(1e-6), (y1 - y0).max(1e-6));
    let (scale, off_x, off_y) = if o.cells > 0.0 {
        // Cell i covers [i, i+1): the contour runs through cell centres, half a cell in.
        (1.0 / o.cells, 0.5 / o.cells, 0.5 / o.cells)
    } else {
        let scale = (UNITS - margin * 2.0) / bw.max(bh);
        (scale, (UNITS - bw * scale) / 2.0 - x0 * scale, (UNITS - bh * scale) / 2.0 - y0 * scale)
    };
    let to_grid = |p: P| (r2(p.0 * scale + off_x), r2(p.1 * scale + off_y));

    let area = (w * h) as f64;
    struct Ring {
        pts: Vec<P>,
        area: f64,
        used: bool,
    }
    let (mut outers, mut holes): (Vec<Ring>, Vec<Ring>) = (Vec::new(), Vec::new());
    for l in &loops {
        let a = signed_area(l);
        if a.abs() < area * min_area {
            continue;
        }
        let pts = prune_closed(&simplify(l, eps), eps);
        if pts.len() < 3 {
            continue;
        }
        let ring = Ring { pts, area: a.abs(), used: false };
        if a > 0.0 { outers.push(ring) } else { holes.push(ring) }
    }
    if outers.is_empty() {
        return Err("Nothing came out of that image.".into());
    }
    // Biggest first, so the largest part of a logo is selected first.
    outers.sort_by(|p, q| q.area.partial_cmp(&p.area).unwrap_or(std::cmp::Ordering::Equal));

    let mut shapes = Vec::new();
    for outer in &outers {
        let mut mine = Vec::new();
        for hole in holes.iter_mut() {
            if hole.used || !point_in_loop(hole.pts[0], &outer.pts) {
                continue;
            }
            hole.used = true;
            let g: Vec<P> = hole.pts.iter().map(|p| to_grid(*p)).collect();
            mine.push(Value::Array(smooth_loop(&g, corner_deg)));
        }
        let g: Vec<P> = outer.pts.iter().map(|p| to_grid(*p)).collect();
        let mut s = json!({ "kind": "path", "c": "ink", "sw": 2, "closed": true, "fill": true, "nodes": smooth_loop(&g, corner_deg) });
        if !mine.is_empty() {
            s["holes"] = Value::Array(mine);
        }
        shapes.push(s);
    }
    Ok(shapes)
}

// ── bitmaps ───────────────────────────────────────────────────────────

/// A picture decoded and fitted into the trace square: both masks, the
/// alpha and the darkness, and which one says what the mark is.
pub struct Bitmap {
    pub alpha: Vec<f32>,
    pub dark: Vec<f32>,
    pub use_alpha: bool,
}

impl Bitmap {
    pub fn decode(bytes: &[u8]) -> Result<Bitmap, String> {
        let img = image::load_from_memory(bytes).map_err(|_| "Could not read that file — is it an image?".to_string())?;
        let rgba = img.to_rgba8();
        let (w, h) = (rgba.width(), rgba.height());
        if w == 0 || h == 0 {
            return Err("That file has no picture in it.".into());
        }
        // Fitted, not stretched, and centred.
        let k = (TRACE_SIZE as f64 / w as f64).min(TRACE_SIZE as f64 / h as f64);
        let (nw, nh) = (((w as f64 * k).round() as u32).max(1), ((h as f64 * k).round() as u32).max(1));
        let small = image::imageops::resize(&rgba, nw, nh, image::imageops::FilterType::Triangle);
        let (dx, dy) = ((TRACE_SIZE - nw) / 2, (TRACE_SIZE - nh) / 2);
        let count = (TRACE_SIZE * TRACE_SIZE) as usize;
        let (mut alpha, mut dark) = (vec![0f32; count], vec![0f32; count]);
        let mut clear = 0;
        for (x, y, p) in small.enumerate_pixels() {
            let i = ((y + dy) * TRACE_SIZE + x + dx) as usize;
            alpha[i] = p[3] as f32;
            // Rec. 601 luma, inverted: dark ink on light paper.
            let l = 0.299 * p[0] as f32 + 0.587 * p[1] as f32 + 0.114 * p[2] as f32;
            dark[i] = 255.0 - l;
        }
        for i in 0..count {
            if alpha[i] < 250.0 {
                clear += 1;
            }
        }
        // A logo saved on a flat background has no transparency: darkness
        // stands in for it, and the caller says so.
        let use_alpha = clear as f64 > count as f64 * 0.02;
        // The picture's own pixels only count where there is picture.
        if !use_alpha {
            for (i, d) in dark.iter_mut().enumerate() {
                if alpha[i] == 0.0 {
                    *d = 0.0;
                }
            }
        }
        Ok(Bitmap { alpha, dark, use_alpha })
    }

    pub fn trace(&self, o: &Opts) -> Result<Vec<Value>, String> {
        trace(if self.use_alpha { &self.alpha } else { &self.dark }, TRACE_SIZE, TRACE_SIZE, o)
    }
}

// ── SVG ───────────────────────────────────────────────────────────────

struct Piece {
    subpaths: Vec<(Vec<Value>, bool)>,
    filled: bool,
    luma: f64,
}

fn map_node(nd: &Value, f: &dyn Fn(P) -> P) -> Value {
    let g = |v: &Value| (v["x"].as_f64().unwrap_or(0.0), v["y"].as_f64().unwrap_or(0.0));
    let p = f(g(nd));
    let mut o = json!({ "x": r2(p.0), "y": r2(p.1) });
    if nd["corner"] == true {
        o["corner"] = json!(true);
    }
    for h in ["hi", "ho"] {
        if nd[h].is_object() {
            let q = f(g(&nd[h]));
            o[h] = json!({ "x": r2(q.0), "y": r2(q.1) });
        }
    }
    o
}

fn node_bounds(nodes: &[Value]) -> (f64, f64, f64, f64) {
    let (mut x0, mut y0, mut x1, mut y1) = (f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY);
    for nd in nodes {
        for v in [Some(nd), nd["hi"].is_object().then_some(&nd["hi"]), nd["ho"].is_object().then_some(&nd["ho"])].into_iter().flatten() {
            let (x, y) = (v["x"].as_f64().unwrap_or(0.0), v["y"].as_f64().unwrap_or(0.0));
            x0 = x0.min(x);
            x1 = x1.max(x);
            y0 = y0.min(y);
            y1 = y1.max(y);
        }
    }
    (x0, y0, x1, y1)
}

fn ring_pts(nodes: &[Value]) -> Vec<P> {
    nodes.iter().map(|n| (n["x"].as_f64().unwrap_or(0.0), n["y"].as_f64().unwrap_or(0.0))).collect()
}

fn ring_area(nodes: &[Value]) -> f64 {
    signed_area(&ring_pts(nodes)).abs()
}

fn inside_ring(p: P, nodes: &[Value]) -> bool {
    point_in_loop(p, &ring_pts(nodes))
}

/// Subpaths of one SVG path as nodes with absolute handles.
fn subpaths(path: &usvg::tiny_skia_path::Path, t: &usvg::tiny_skia_path::Transform) -> Vec<(Vec<Value>, bool)> {
    use usvg::tiny_skia_path::PathSegment as S;
    let m = |p: usvg::tiny_skia_path::Point| -> P {
        let (x, y) = (p.x as f64, p.y as f64);
        (t.sx as f64 * x + t.kx as f64 * y + t.tx as f64, t.ky as f64 * x + t.sy as f64 * y + t.ty as f64)
    };
    let mut out = Vec::new();
    let mut nodes: Vec<Value> = Vec::new();
    let mut cur: P = (0.0, 0.0);
    let mut finish = |nodes: &mut Vec<Value>, closed: bool, out: &mut Vec<(Vec<Value>, bool)>| {
        if closed && nodes.len() > 1 {
            // A closing segment back to the first point isn't a node of its own.
            let (a, b) = (&nodes[0], &nodes[nodes.len() - 1]);
            if (a["x"].as_f64().unwrap_or(0.0) - b["x"].as_f64().unwrap_or(1.0)).abs() < 1e-6
                && (a["y"].as_f64().unwrap_or(0.0) - b["y"].as_f64().unwrap_or(1.0)).abs() < 1e-6
            {
                // The last node's incoming handle belongs to the first.
                let last = nodes.pop().unwrap_or(Value::Null);
                if last["hi"].is_object() {
                    nodes[0]["hi"] = last["hi"].clone();
                }
            }
        }
        if nodes.len() >= 2 {
            out.push((std::mem::take(nodes), closed));
        } else {
            nodes.clear();
        }
    };
    for seg in path.segments() {
        match seg {
            S::MoveTo(p) => {
                finish(&mut nodes, false, &mut out);
                cur = m(p);
                nodes.push(json!({ "x": cur.0, "y": cur.1, "corner": true }));
            }
            S::LineTo(p) => {
                cur = m(p);
                nodes.push(json!({ "x": cur.0, "y": cur.1, "corner": true }));
            }
            S::QuadTo(c, p) => {
                // Raised to a cubic.
                let (c, e) = (m(c), m(p));
                let c1 = (cur.0 + 2.0 / 3.0 * (c.0 - cur.0), cur.1 + 2.0 / 3.0 * (c.1 - cur.1));
                let c2 = (e.0 + 2.0 / 3.0 * (c.0 - e.0), e.1 + 2.0 / 3.0 * (c.1 - e.1));
                if let Some(l) = nodes.last_mut() {
                    l["ho"] = json!({ "x": c1.0, "y": c1.1 });
                    l.as_object_mut().map(|o| o.remove("corner"));
                }
                nodes.push(json!({ "x": e.0, "y": e.1, "hi": { "x": c2.0, "y": c2.1 } }));
                cur = e;
            }
            S::CubicTo(c1, c2, p) => {
                let (c1, c2, e) = (m(c1), m(c2), m(p));
                if let Some(l) = nodes.last_mut() {
                    l["ho"] = json!({ "x": c1.0, "y": c1.1 });
                    l.as_object_mut().map(|o| o.remove("corner"));
                }
                nodes.push(json!({ "x": e.0, "y": e.1, "hi": { "x": c2.0, "y": c2.1 } }));
                cur = e;
            }
            S::Close => finish(&mut nodes, true, &mut out),
        }
    }
    finish(&mut nodes, false, &mut out);
    out
}

fn walk(g: &usvg::Group, pieces: &mut Vec<Piece>) {
    for n in g.children() {
        match n {
            usvg::Node::Group(g) => walk(g, pieces),
            usvg::Node::Path(p) => {
                let subs = subpaths(p.data(), &p.abs_transform());
                if subs.is_empty() {
                    continue;
                }
                let luma = match p.fill().map(|f| f.paint()) {
                    Some(usvg::Paint::Color(c)) => (0.299 * c.red as f64 + 0.587 * c.green as f64 + 0.114 * c.blue as f64) / 255.0,
                    _ => -1.0,
                };
                pieces.push(Piece { subpaths: subs, filled: p.fill().is_some(), luma });
            }
            _ => {}
        }
    }
}

/// An SVG read as what it is: paths with curves, fitted into the grid.
/// The note says what was left out.
pub fn svg(bytes: &[u8]) -> Result<(Vec<Value>, String), String> {
    let text = String::from_utf8_lossy(bytes);
    if !text.contains("<svg") {
        return Err("That does not look like an SVG.".into());
    }
    let saw_text = text.contains("<text");
    let tree = usvg::Tree::from_data(bytes, &usvg::Options::default()).map_err(|e| format!("Could not read that SVG: {e}"))?;
    let mut pieces = Vec::new();
    walk(tree.root(), &mut pieces);
    if pieces.is_empty() {
        return Err(if saw_text {
            "That SVG is mostly text — convert the text to outlines and try again.".into()
        } else {
            "No shapes in that SVG that this understands.".into()
        });
    }

    // One scale for the whole drawing, so the pieces keep their places.
    let (mut x0, mut y0, mut x1, mut y1) = (f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY);
    for p in &pieces {
        for (nodes, _) in &p.subpaths {
            let b = node_bounds(nodes);
            x0 = x0.min(b.0);
            y0 = y0.min(b.1);
            x1 = x1.max(b.2);
            y1 = y1.max(b.3);
        }
    }
    let (bw, bh) = (x1 - x0, y1 - y0);
    if !(bw > 0.0) && !(bh > 0.0) {
        return Err("That SVG has no size.".into());
    }
    let k = (UNITS - 4.0) / bw.max(bh);
    let (off_x, off_y) = ((UNITS - bw * k) / 2.0 - x0 * k, (UNITS - bh * k) / 2.0 - y0 * k);
    let fit = move |p: P| (p.0 * k + off_x, p.1 * k + off_y);

    struct Out {
        shape: Value,
        luma: f64,
    }
    let mut shapes: Vec<Out> = Vec::new();
    for piece in &pieces {
        let mut rings: Vec<(Vec<Value>, bool)> = piece.subpaths.iter().map(|(n, c)| (n.iter().map(|x| map_node(x, &fit)).collect(), *c)).collect();
        rings.sort_by(|a, b| ring_area(&b.0).partial_cmp(&ring_area(&a.0)).unwrap_or(std::cmp::Ordering::Equal));
        let mut used = vec![false; rings.len()];
        for r1 in 0..rings.len() {
            if used[r1] {
                continue;
            }
            let mut holes = Vec::new();
            if piece.filled {
                for r2 in r1 + 1..rings.len() {
                    if used[r2] || !inside_ring((rings[r2].0[0]["x"].as_f64().unwrap_or(0.0), rings[r2].0[0]["y"].as_f64().unwrap_or(0.0)), &rings[r1].0) {
                        continue;
                    }
                    used[r2] = true;
                    holes.push(Value::Array(rings[r2].0.clone()));
                }
            }
            let mut shape = json!({ "kind": "path", "c": "ink", "sw": 2, "closed": if piece.filled { true } else { rings[r1].1 }, "nodes": rings[r1].0 });
            if piece.filled {
                shape["fill"] = json!(true);
            }
            if !holes.is_empty() {
                shape["holes"] = Value::Array(holes);
            }
            shapes.push(Out { shape, luma: piece.luma });
        }
    }

    // Knockouts: a pale filled shape sitting inside an earlier dark one is a
    // hole cut by covering it up. In an icon that takes its colours from the
    // theme it would be ink on ink and vanish, so it becomes a real hole.
    let mut c1 = shapes.len();
    while c1 > 1 {
        c1 -= 1;
        let inner = &shapes[c1];
        if inner.shape["fill"] != true || inner.shape.get("holes").is_some() || !(inner.luma > 0.75) {
            continue;
        }
        let first = inner.shape["nodes"][0].clone();
        let p0 = (first["x"].as_f64().unwrap_or(0.0), first["y"].as_f64().unwrap_or(0.0));
        let nodes = inner.shape["nodes"].clone();
        let target = (0..c1).rev().find(|c2| {
            let o = &shapes[*c2];
            o.shape["fill"] == true && o.luma < 0.75 && inside_ring(p0, o.shape["nodes"].as_array().map(|a| a.as_slice()).unwrap_or(&[]))
        });
        if let Some(c2) = target {
            let holes = shapes[c2].shape["holes"].as_array().cloned().unwrap_or_default();
            let mut holes = holes;
            holes.push(nodes);
            shapes[c2].shape["holes"] = Value::Array(holes);
            shapes.remove(c1);
        }
    }
    let note = if saw_text { "Some text in that SVG was skipped — convert text to outlines to keep it.".to_string() } else { String::new() };
    Ok((shapes.into_iter().map(|o| o.shape).collect(), note))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn disc(w: u32, h: u32, cx: f32, cy: f32, r: f32) -> Vec<f32> {
        (0..w * h).map(|i| {
            let (x, y) = ((i % w) as f32, (i / w) as f32);
            if ((x - cx).powi(2) + (y - cy).powi(2)).sqrt() < r { 255.0 } else { 0.0 }
        }).collect()
    }

    #[test]
    fn a_disc_comes_back_as_one_smooth_filled_path() {
        let m = disc(96, 96, 48.0, 48.0, 30.0);
        let s = trace(&m, 96, 96, &Opts::default()).expect("a trace");
        assert_eq!(s.len(), 1);
        assert_eq!(s[0]["kind"], "path");
        assert_eq!(s[0]["fill"], true);
        // Fitted into the grid with its margin, centred.
        let pts = ring_pts(s[0]["nodes"].as_array().unwrap());
        let (x0, x1) = pts.iter().fold((f64::INFINITY, f64::NEG_INFINITY), |a, p| (a.0.min(p.0), a.1.max(p.0)));
        let (y0, y1) = pts.iter().fold((f64::INFINITY, f64::NEG_INFINITY), |a, p| (a.0.min(p.1), a.1.max(p.1)));
        assert!(((x0 + x1) / 2.0 - 12.0).abs() < 0.3 && ((y0 + y1) / 2.0 - 12.0).abs() < 0.3);
        assert!(x1 - x0 <= 20.1 && x1 - x0 > 17.0, "width {}", x1 - x0);
        // Curves, not a staircase.
        assert!(s[0]["nodes"].as_array().unwrap().iter().any(|n| n["ho"].is_object()));
    }

    #[test]
    fn a_ring_has_a_hole() {
        let mut m = disc(96, 96, 48.0, 48.0, 36.0);
        let inner = disc(96, 96, 48.0, 48.0, 18.0);
        for (a, b) in m.iter_mut().zip(inner) {
            if b > 0.0 {
                *a = 0.0;
            }
        }
        let s = trace(&m, 96, 96, &Opts::default()).expect("a trace");
        assert_eq!(s.len(), 1);
        assert_eq!(s[0]["holes"].as_array().map(|h| h.len()), Some(1));
    }

    #[test]
    fn an_empty_image_says_so() {
        assert!(trace(&vec![0.0; 96 * 96], 96, 96, &Opts::default()).is_err());
    }

    #[test]
    fn an_svg_circle_and_its_knockout() {
        let svg_text = br#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><circle cx="50" cy="50" r="40"/><circle cx="50" cy="50" r="15" fill="white"/></svg>"#;
        let (shapes, _) = svg(svg_text).expect("an svg");
        // The white disc became a hole in the black one.
        assert_eq!(shapes.len(), 1);
        assert_eq!(shapes[0]["holes"].as_array().map(|h| h.len()), Some(1));
    }
}
