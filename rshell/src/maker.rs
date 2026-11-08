//! The icon maker (modules/iconmaker): draw an icon on the pack's 24 grid out
//! of lines, boxes, circles, ellipses, arcs and dots, and keep it in
//! icons.json, where every glyph lookup finds it. Shapes in the file's own
//! form (IconModel.qml / Compose.js), so what the QML maker saved opens here
//! and the other way round; a shape this editor can't draw (a traced path)
//! is kept, shown, moved and saved as it was.
//!
//! This file is the model: the shapes, the undo, picking and moving, and
//! the arithmetic from shapes to the path strings a glyph is drawn from.
//! launch-style host code (the window, the keys) is in `MakerHost`.

use crate::GlyphData;
use serde_json::{json, Value};

const UNITS: f64 = 24.0;

fn n(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

fn fmt(v: f64) -> String {
    let v = n(v);
    if v == v.trunc() {
        format!("{}", v as i64)
    } else {
        format!("{v}")
    }
}

fn f(s: &Value, k: &str) -> f64 {
    s[k].as_f64().unwrap_or(0.0)
}

fn kind(s: &Value) -> &str {
    s["kind"].as_str().unwrap_or("")
}

// ── geometry (Compose.js) ─────────────────────────────────────────────

fn nodes_of(v: &Value) -> Vec<(f64, f64, Option<(f64, f64)>, Option<(f64, f64)>)> {
    v.as_array()
        .into_iter()
        .flatten()
        .map(|nd| {
            let h = |k: &str| nd[k].as_object().map(|_| (f(&nd[k], "x"), f(&nd[k], "y")));
            (f(nd, "x"), f(nd, "y"), h("hi"), h("ho"))
        })
        .collect()
}

/// The point a shape turns about: its own middle.
pub fn centre_of(s: &Value) -> (f64, f64) {
    match kind(s) {
        "line" => ((f(s, "x1") + f(s, "x2")) / 2.0, (f(s, "y1") + f(s, "y2")) / 2.0),
        "rect" => (f(s, "x") + f(s, "w") / 2.0, f(s, "y") + f(s, "h") / 2.0),
        "poly" => {
            let pts: Vec<f64> = s["pts"].as_array().into_iter().flatten().filter_map(|v| v.as_f64()).collect();
            bbox((0..pts.len() / 2).map(|i| (pts[i * 2], pts[i * 2 + 1])))
                .map(|(x, y, w, h)| (x + w / 2.0, y + h / 2.0))
                .unwrap_or((12.0, 12.0))
        }
        "path" => bbox(nodes_of(&s["nodes"]).iter().map(|n| (n.0, n.1)))
            .map(|(x, y, w, h)| (x + w / 2.0, y + h / 2.0))
            .unwrap_or((12.0, 12.0)),
        _ => (f(s, "cx"), f(s, "cy")),
    }
}

fn bbox(it: impl Iterator<Item = (f64, f64)>) -> Option<(f64, f64, f64, f64)> {
    let (mut x0, mut y0, mut x1, mut y1) = (f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY);
    let mut any = false;
    for (x, y) in it {
        any = true;
        x0 = x0.min(x);
        x1 = x1.max(x);
        y0 = y0.min(y);
        y1 = y1.max(y);
    }
    any.then_some((x0, y0, x1 - x0, y1 - y0))
}

fn turn(s: &Value, deg: f64) -> impl Fn(f64, f64) -> (f64, f64) {
    let (cx, cy) = centre_of(s);
    let a = deg.to_radians();
    let (sin, cos) = a.sin_cos();
    let rot = deg != 0.0;
    move |x, y| {
        if !rot {
            return (x, y);
        }
        let (dx, dy) = (x - cx, y - cy);
        (cx + dx * cos - dy * sin, cy + dx * sin + dy * cos)
    }
}

fn circle_path(cx: f64, cy: f64, r: f64) -> String {
    format!(
        "M{} {}A{} {} 0 1 0 {} {}A{} {} 0 1 0 {} {}Z",
        fmt(cx - r), fmt(cy), fmt(r), fmt(r), fmt(cx + r), fmt(cy), fmt(r), fmt(r), fmt(cx - r), fmt(cy)
    )
}

fn rect_path(x: f64, y: f64, w: f64, h: f64, r: f64, map: &dyn Fn(f64, f64) -> (f64, f64)) -> String {
    let (x2, y2) = (x + w, y + h);
    let r = r.min(w.min(h) / 2.0).max(0.0);
    let p = |px: f64, py: f64| {
        let q = map(px, py);
        format!("{} {}", fmt(q.0), fmt(q.1))
    };
    if r <= 0.0 {
        return format!("M{}L{}L{}L{}Z", p(x, y), p(x2, y), p(x2, y2), p(x, y2));
    }
    let a = format!("A{} {} 0 0 1 ", fmt(r), fmt(r));
    format!(
        "M{}L{}{a}{}L{}{a}{}L{}{a}{}L{}{a}{}Z",
        p(x + r, y), p(x2 - r, y), p(x2, y + r), p(x2, y2 - r), p(x2 - r, y2), p(x + r, y2), p(x, y2 - r), p(x, y + r), p(x + r, y)
    )
}

fn polar(cx: f64, cy: f64, r: f64, deg: f64) -> (f64, f64) {
    let a = deg.to_radians();
    (cx + r * a.cos(), cy + r * a.sin())
}

fn arc_path(cx: f64, cy: f64, r: f64, a0: f64, a1: f64) -> String {
    let sweep = a1 - a0;
    if sweep.abs() >= 359.9 {
        return circle_path(cx, cy, r);
    }
    let (p0, p1) = (polar(cx, cy, r, a0), polar(cx, cy, r, a1));
    format!(
        "M{} {}A{} {} 0 {} {} {} {}",
        fmt(p0.0), fmt(p0.1), fmt(r), fmt(r), (sweep.abs() > 180.0) as i32, (sweep >= 0.0) as i32, fmt(p1.0), fmt(p1.1)
    )
}

type Node = (f64, f64, Option<(f64, f64)>, Option<(f64, f64)>);

fn segment_to(a: &Node, b: &Node, map: &dyn Fn(f64, f64) -> (f64, f64)) -> String {
    let pb = map(b.0, b.1);
    if a.3.is_none() && b.2.is_none() {
        return format!("L{} {}", fmt(pb.0), fmt(pb.1));
    }
    let c1 = a.3.map(|h| map(h.0, h.1)).unwrap_or_else(|| map(a.0, a.1));
    let c2 = b.2.map(|h| map(h.0, h.1)).unwrap_or_else(|| map(b.0, b.1));
    format!("C{} {} {} {} {} {}", fmt(c1.0), fmt(c1.1), fmt(c2.0), fmt(c2.1), fmt(pb.0), fmt(pb.1))
}

fn node_path(nodes: &[Node], closed: bool, map: &dyn Fn(f64, f64) -> (f64, f64)) -> String {
    if nodes.len() < 2 {
        return String::new();
    }
    let p0 = map(nodes[0].0, nodes[0].1);
    let mut d = format!("M{} {}", fmt(p0.0), fmt(p0.1));
    for i in 1..nodes.len() {
        d += &segment_to(&nodes[i - 1], &nodes[i], map);
    }
    if closed && nodes.len() > 2 {
        d += &segment_to(&nodes[nodes.len() - 1], &nodes[0], map);
        d += "Z";
    }
    d
}

pub fn path_for(s: &Value) -> String {
    let rot = f(s, "rot");
    let map = turn(s, rot);
    match kind(s) {
        "line" => {
            let (a, b) = (map(f(s, "x1"), f(s, "y1")), map(f(s, "x2"), f(s, "y2")));
            format!("M{} {}L{} {}", fmt(a.0), fmt(a.1), fmt(b.0), fmt(b.1))
        }
        "rect" => rect_path(f(s, "x"), f(s, "y"), f(s, "w"), f(s, "h"), f(s, "r"), &map),
        "circle" => circle_path(f(s, "cx"), f(s, "cy"), f(s, "r")),
        "ellipse" => {
            let (cx, cy, rx, ry) = (f(s, "cx"), f(s, "cy"), f(s, "rx"), f(s, "ry"));
            let (l, r) = (map(cx - rx, cy), map(cx + rx, cy));
            format!(
                "M{} {}A{} {} {} 1 0 {} {}A{} {} {} 1 0 {} {}Z",
                fmt(l.0), fmt(l.1), fmt(rx), fmt(ry), fmt(rot), fmt(r.0), fmt(r.1), fmt(rx), fmt(ry), fmt(rot), fmt(l.0), fmt(l.1)
            )
        }
        "arc" => arc_path(f(s, "cx"), f(s, "cy"), f(s, "r"), f(s, "a0") + rot, f(s, "a1") + rot),
        "poly" => {
            let pts: Vec<f64> = s["pts"].as_array().into_iter().flatten().filter_map(|v| v.as_f64()).collect();
            if pts.len() < 4 {
                return String::new();
            }
            let mut d = String::new();
            for i in 0..pts.len() / 2 {
                let q = map(pts[i * 2], pts[i * 2 + 1]);
                d += &format!("{}{} {}", if i == 0 { "M" } else { "L" }, fmt(q.0), fmt(q.1));
            }
            if s["closed"] == true {
                d += "Z";
            }
            d
        }
        "path" => {
            let mut d = node_path(&nodes_of(&s["nodes"]), s["closed"] == true, &map);
            for hole in s["holes"].as_array().into_iter().flatten() {
                let hd = node_path(&nodes_of(hole), true, &map);
                if !hd.is_empty() {
                    d += " ";
                    d += &hd;
                }
            }
            d
        }
        _ => String::new(),
    }
}

/// Which of a glyph's path buckets a shape goes in.
fn bucket_for(s: &Value) -> &'static str {
    if kind(s) == "dot" {
        return "dots";
    }
    let acc = s["c"] == "acc";
    if s["fill"] == true {
        return if acc { "fill" } else { "fillInk" };
    }
    match (acc, f(s, "sw") == 3.0) {
        (true, true) => "accW",
        (true, false) => "acc",
        (false, true) => "inkW",
        (false, false) => "ink",
    }
}

/// The whole drawing as a glyph spec, shapes riding along so it opens again.
pub fn compose(shapes: &[Value]) -> Value {
    let mut out = serde_json::Map::new();
    out.insert("shapes".into(), Value::Array(shapes.to_vec()));
    let mut parts: std::collections::BTreeMap<&str, Vec<String>> = std::collections::BTreeMap::new();
    let mut dots = Vec::new();
    for s in shapes {
        if kind(s) == "dot" {
            if f(s, "r") > 0.0 {
                dots.push(json!({ "cx": n(f(s, "cx")), "cy": n(f(s, "cy")), "r": n(f(s, "r")), "c": if s["c"] == "acc" { "acc" } else { "ink" } }));
            }
            continue;
        }
        let d = path_for(s);
        if !d.is_empty() {
            parts.entry(bucket_for(s)).or_default().push(d);
        }
    }
    for (k, v) in parts {
        out.insert(k.into(), Value::String(v.join(" ")));
    }
    if !dots.is_empty() {
        out.insert("dots".into(), Value::Array(dots));
    }
    Value::Object(out)
}

pub fn draws(shapes: &[Value]) -> bool {
    let g = compose(shapes);
    ["ink", "acc", "inkW", "accW", "fill", "fillInk", "dots"].iter().any(|k| !g[k].is_null())
}

/// One shape as a glyph, to draw it with the same renderer as the dock.
pub fn glyph_of(s: &Value) -> GlyphData {
    // A straight horizontal or vertical line has a bounding box with no
    // height or width, which the path renderer places wrongly. Drawn as the
    // capsule its stroke covers, filled, it sits where it should. For
    // display only: what is saved is the line as drawn.
    let mut shown = s.clone();
    let axis = kind(s) == "line" && (f(s, "y1") == f(s, "y2") || f(s, "x1") == f(s, "x2"));
    if axis {
        let map = turn(s, f(s, "rot"));
        let (p0, p1) = (map(f(s, "x1"), f(s, "y1")), map(f(s, "x2"), f(s, "y2")));
        let r = if f(s, "sw") == 3.0 { 1.5 } else { 1.0 };
        let (dx, dy) = (p1.0 - p0.0, p1.1 - p0.1);
        let len = dx.hypot(dy);
        shown = if len == 0.0 {
            json!({ "kind": "circle", "cx": p0.0, "cy": p0.1, "r": r, "fill": true, "c": s["c"] })
        } else {
            let (nx, ny) = (-dy / len * r, dx / len * r);
            let q = |x: f64, y: f64| format!("{} {}", fmt(x), fmt(y));
            let d = format!(
                "M{}L{}A{} {} 0 0 0 {}L{}A{} {} 0 0 0 {}Z",
                q(p0.0 + nx, p0.1 + ny), q(p1.0 + nx, p1.1 + ny), fmt(r), fmt(r), q(p1.0 - nx, p1.1 - ny),
                q(p0.0 - nx, p0.1 - ny), fmt(r), fmt(r), q(p0.0 + nx, p0.1 + ny)
            );
            // A filled shape of its own: composed by hand, as a poly can't carry arcs.
            let mut g = GlyphData::default();
            if s["c"] == "acc" { g.fill = d.into(); } else { g.fill_ink = d.into(); }
            return g;
        };
    }
    let spec = compose(std::slice::from_ref(&shown));
    let st = |k: &str| spec[k].as_str().unwrap_or("").to_string();
    let d = spec["dots"].as_array().and_then(|a| a.first()).cloned().unwrap_or(Value::Null);
    let fl = |k: &str| d[k].as_f64().unwrap_or(0.0) as f32;
    GlyphData {
        ink: st("ink").into(),
        acc: st("acc").into(),
        ink_w: st("inkW").into(),
        acc_w: st("accW").into(),
        fill: st("fill").into(),
        fill_ink: st("fillInk").into(),
        dot_x: fl("cx"),
        dot_y: fl("cy"),
        dot_r: fl("r"),
        dot_acc: d["c"] == "acc",
    }
}

// ── the model (IconModel.qml) ─────────────────────────────────────────

#[derive(Default)]
pub struct Model {
    pub shapes: Vec<Value>,
    pub selected: Option<usize>,
    undo: Vec<Vec<Value>>,
    redo: Vec<Vec<Value>>,
}

fn dist_segment(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    let t = if len2 == 0.0 { 0.0 } else { (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0) };
    (px - (ax + t * dx)).hypot(py - (ay + t * dy))
}

fn dist_rect_edge(px: f64, py: f64, x: f64, y: f64, w: f64, h: f64) -> f64 {
    let (x2, y2) = (x + w, y + h);
    [
        dist_segment(px, py, x, y, x2, y),
        dist_segment(px, py, x2, y, x2, y2),
        dist_segment(px, py, x2, y2, x, y2),
        dist_segment(px, py, x, y2, x, y),
    ]
    .into_iter()
    .fold(f64::INFINITY, f64::min)
}

impl Model {
    pub fn current(&self) -> Option<&Value> {
        self.selected.and_then(|i| self.shapes.get(i))
    }

    pub fn can_undo(&self) -> bool {
        !self.undo.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo.is_empty()
    }

    pub fn snapshot(&mut self) {
        self.undo.push(self.shapes.clone());
        if self.undo.len() > 60 {
            self.undo.remove(0);
        }
        self.redo.clear();
    }

    /// Takes back a snapshot made for something that didn't happen.
    pub fn forget_snapshot(&mut self) {
        self.undo.pop();
    }

    pub fn undo(&mut self) {
        if let Some(prev) = self.undo.pop() {
            self.redo.push(std::mem::replace(&mut self.shapes, prev));
            self.clamp();
        }
    }

    pub fn redo(&mut self) {
        if let Some(next) = self.redo.pop() {
            self.undo.push(std::mem::replace(&mut self.shapes, next));
            self.clamp();
        }
    }

    fn clamp(&mut self) {
        self.selected = self.selected.filter(|i| *i < self.shapes.len());
    }

    pub fn replace(&mut self, shapes: Vec<Value>) {
        self.snapshot();
        self.shapes = shapes;
        self.selected = None;
    }

    pub fn add(&mut self, s: Value) {
        self.snapshot();
        self.shapes.push(s);
        self.selected = Some(self.shapes.len() - 1);
    }

    /// Writes fields into the selected shape; `quiet` in the middle of a drag.
    pub fn update(&mut self, fields: &[(&str, Value)], quiet: bool) {
        let Some(i) = self.selected else { return };
        if !quiet {
            self.snapshot();
        }
        if let Some(o) = self.shapes[i].as_object_mut() {
            for (k, v) in fields {
                o.insert((*k).into(), v.clone());
            }
        }
    }

    pub fn remove_selected(&mut self) {
        let Some(i) = self.selected else { return };
        self.snapshot();
        self.shapes.remove(i);
        self.selected = if self.shapes.is_empty() { None } else { Some(i.min(self.shapes.len() - 1)) };
    }

    pub fn duplicate(&mut self) {
        if let Some(mut c) = self.current().cloned() {
            nudge(&mut c, 1.0, 1.0);
            self.add(c);
        }
    }

    /// Paint order is list order: later is in front.
    pub fn reorder(&mut self, delta: i32) {
        let Some(at) = self.selected else { return };
        let to = at as i32 + delta;
        if to < 0 || to as usize >= self.shapes.len() {
            return;
        }
        self.snapshot();
        let s = self.shapes.remove(at);
        self.shapes.insert(to as usize, s);
        self.selected = Some(to as usize);
    }

    /// The whole drawing mirrored across the middle of the grid.
    pub fn mirror(&mut self, horizontal: bool) {
        if self.shapes.is_empty() {
            return;
        }
        self.snapshot();
        for s in &mut self.shapes {
            mirror_shape(s, horizontal);
        }
    }

    pub fn clear(&mut self) {
        self.snapshot();
        self.shapes.clear();
        self.selected = None;
    }

    pub fn move_selected(&mut self, dx: f64, dy: f64) {
        if let Some(i) = self.selected {
            nudge(&mut self.shapes[i], dx, dy);
        }
    }

    /// The topmost shape within `reach` grid units of a point.
    pub fn pick(&self, px: f64, py: f64, reach: f64) -> Option<usize> {
        (0..self.shapes.len()).rev().find(|i| distance_to(&self.shapes[*i], px, py) <= reach)
    }
}

fn add_to(o: &mut Value, k: &str, d: f64) {
    if let Some(v) = o[k].as_f64() {
        o[k] = json!(v + d);
    }
}

pub fn nudge(s: &mut Value, dx: f64, dy: f64) {
    match kind(s) {
        "line" => {
            add_to(s, "x1", dx);
            add_to(s, "x2", dx);
            add_to(s, "y1", dy);
            add_to(s, "y2", dy);
        }
        "rect" => {
            add_to(s, "x", dx);
            add_to(s, "y", dy);
        }
        "poly" => {
            if let Some(a) = s["pts"].as_array_mut() {
                for (i, v) in a.iter_mut().enumerate() {
                    if let Some(x) = v.as_f64() {
                        *v = json!(x + if i % 2 == 0 { dx } else { dy });
                    }
                }
            }
        }
        "path" => {
            let shift = |nd: &mut Value| {
                add_to(nd, "x", dx);
                add_to(nd, "y", dy);
                for h in ["hi", "ho"] {
                    if nd[h].is_object() {
                        add_to(&mut nd[h], "x", dx);
                        add_to(&mut nd[h], "y", dy);
                    }
                }
            };
            if let Some(a) = s["nodes"].as_array_mut() {
                a.iter_mut().for_each(shift);
            }
            if let Some(holes) = s["holes"].as_array_mut() {
                for h in holes {
                    if let Some(a) = h.as_array_mut() {
                        a.iter_mut().for_each(shift);
                    }
                }
            }
        }
        _ => {
            add_to(s, "cx", dx);
            add_to(s, "cy", dy);
        }
    }
}

fn mirror_shape(s: &mut Value, horizontal: bool) {
    let ax = if horizontal { "x" } else { "y" };
    let flip = |v: f64| UNITS - v;
    let set = |o: &mut Value, k: &str, v: f64| o[k] = json!(v);
    let rot = f(s, "rot");
    if rot != 0.0 {
        set(s, "rot", (-rot).rem_euclid(360.0));
    }
    let kd = kind(s).to_string();
    match kd.as_str() {
        "line" => {
            for k in [format!("{ax}1"), format!("{ax}2")] {
                let v = f(s, &k);
                set(s, &k, flip(v));
            }
        }
        "rect" => {
            let (p, size) = (f(s, ax), f(s, if horizontal { "w" } else { "h" }));
            set(s, ax, flip(p + size));
        }
        "poly" => {
            if let Some(a) = s["pts"].as_array_mut() {
                for (i, v) in a.iter_mut().enumerate() {
                    if let Some(x) = v.as_f64() {
                        if (i % 2 == 0) == horizontal {
                            *v = json!(flip(x));
                        }
                    }
                }
            }
        }
        "path" => {
            let m = |nd: &mut Value| {
                let v = f(nd, ax);
                set(nd, ax, flip(v));
                for h in ["hi", "ho"] {
                    if nd[h].is_object() {
                        let v = f(&nd[h], ax);
                        set(&mut nd[h], ax, flip(v));
                    }
                }
            };
            if let Some(a) = s["nodes"].as_array_mut() {
                a.iter_mut().for_each(m);
            }
            if let Some(holes) = s["holes"].as_array_mut() {
                for h in holes {
                    if let Some(a) = h.as_array_mut() {
                        a.iter_mut().for_each(m);
                    }
                }
            }
        }
        k => {
            let c = if horizontal { "cx" } else { "cy" };
            let v = f(s, c);
            set(s, c, flip(v));
            if k == "arc" {
                // Angles run clockwise from the right, y down: a mirror
                // across a vertical line is 180 − a, across a horizontal one −a.
                let (a0, a1) = (f(s, "a0"), f(s, "a1"));
                let m = |a: f64| if horizontal { 180.0 - a } else { -a };
                set(s, "a0", m(a1));
                set(s, "a1", m(a0));
            }
        }
    }
}

pub fn bounds_of(s: &Value) -> (f64, f64, f64, f64) {
    match kind(s) {
        "line" => (f(s, "x1").min(f(s, "x2")), f(s, "y1").min(f(s, "y2")), (f(s, "x2") - f(s, "x1")).abs(), (f(s, "y2") - f(s, "y1")).abs()),
        "rect" => (f(s, "x"), f(s, "y"), f(s, "w"), f(s, "h")),
        "circle" | "dot" | "arc" => (f(s, "cx") - f(s, "r"), f(s, "cy") - f(s, "r"), f(s, "r") * 2.0, f(s, "r") * 2.0),
        "ellipse" => (f(s, "cx") - f(s, "rx"), f(s, "cy") - f(s, "ry"), f(s, "rx") * 2.0, f(s, "ry") * 2.0),
        "path" => bbox(nodes_of(&s["nodes"]).iter().map(|n| (n.0, n.1))).unwrap_or((0.0, 0.0, 0.0, 0.0)),
        "poly" => {
            let pts: Vec<f64> = s["pts"].as_array().into_iter().flatten().filter_map(|v| v.as_f64()).collect();
            bbox((0..pts.len() / 2).map(|i| (pts[i * 2], pts[i * 2 + 1]))).unwrap_or((0.0, 0.0, 0.0, 0.0))
        }
        _ => (0.0, 0.0, 0.0, 0.0),
    }
}

/// Distance from a point to a shape, in grid units, to pick one by clicking.
pub fn distance_to(s: &Value, px: f64, py: f64) -> f64 {
    let rot = f(s, "rot");
    let (px, py) = if rot != 0.0 { turn(s, -rot)(px, py) } else { (px, py) };
    let fill = s["fill"] == true;
    match kind(s) {
        "line" => dist_segment(px, py, f(s, "x1"), f(s, "y1"), f(s, "x2"), f(s, "y2")),
        "dot" => ((px - f(s, "cx")).hypot(py - f(s, "cy")) - f(s, "r")).max(0.0),
        "circle" | "arc" => {
            let d = (px - f(s, "cx")).hypot(py - f(s, "cy"));
            if fill { (d - f(s, "r")).max(0.0) } else { (d - f(s, "r")).abs() }
        }
        "ellipse" => {
            let nx = (px - f(s, "cx")) / f(s, "rx").max(0.01);
            let ny = (py - f(s, "cy")) / f(s, "ry").max(0.01);
            let d = nx.hypot(ny);
            let m = f(s, "rx").min(f(s, "ry"));
            if fill { ((d - 1.0) * m).max(0.0) } else { (d - 1.0).abs() * m }
        }
        "rect" => {
            let (x, y, w, h) = (f(s, "x"), f(s, "y"), f(s, "w"), f(s, "h"));
            if fill {
                (x - px).max(0.0).max(px - (x + w)).hypot((y - py).max(0.0).max(py - (y + h)))
            } else {
                dist_rect_edge(px, py, x, y, w, h)
            }
        }
        "poly" => {
            let pts: Vec<f64> = s["pts"].as_array().into_iter().flatten().filter_map(|v| v.as_f64()).collect();
            let mut best = f64::INFINITY;
            let m = pts.len() / 2;
            for i in 0..m.saturating_sub(1) {
                best = best.min(dist_segment(px, py, pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2], pts[i * 2 + 3]));
            }
            if s["closed"] == true && m >= 3 {
                best = best.min(dist_segment(px, py, pts[m * 2 - 2], pts[m * 2 - 1], pts[0], pts[1]));
            }
            best
        }
        "path" => {
            // The corners joined by straight lines: close enough to pick by.
            let nodes = nodes_of(&s["nodes"]);
            let mut best = f64::INFINITY;
            for i in 1..nodes.len() {
                best = best.min(dist_segment(px, py, nodes[i - 1].0, nodes[i - 1].1, nodes[i].0, nodes[i].1));
            }
            if s["closed"] == true && nodes.len() > 2 {
                let (a, b) = (&nodes[nodes.len() - 1], &nodes[0]);
                best = best.min(dist_segment(px, py, a.0, a.1, b.0, b.1));
            }
            best
        }
        _ => f64::INFINITY,
    }
}

pub fn snap(v: f64) -> f64 {
    ((v / 0.5).round() * 0.5).clamp(0.0, UNITS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_composes_like_compose_js() {
        let g = compose(&[json!({ "kind": "line", "x1": 4, "y1": 4, "x2": 20, "y2": 20, "c": "ink", "sw": 2 })]);
        assert_eq!(g["ink"], "M4 4L20 20");
    }

    #[test]
    fn a_filled_accent_box_goes_in_fill() {
        let g = compose(&[json!({ "kind": "rect", "x": 4, "y": 4, "w": 8, "h": 6, "r": 0, "c": "acc", "fill": true })]);
        assert_eq!(g["fill"], "M4 4L12 4L12 10L4 10Z");
    }

    #[test]
    fn a_dot_is_not_a_path() {
        let g = compose(&[json!({ "kind": "dot", "cx": 12, "cy": 12, "r": 1.5, "c": "acc" })]);
        assert!(g["ink"].is_null() && g["dots"][0]["r"] == 1.5);
    }

    #[test]
    fn picking_takes_the_ring_not_the_middle() {
        let mut m = Model::default();
        m.add(json!({ "kind": "circle", "cx": 12, "cy": 12, "r": 6, "c": "ink", "sw": 2 }));
        assert_eq!(m.pick(18.0, 12.0, 0.8), Some(0));
        assert_eq!(m.pick(12.0, 12.0, 0.8), None);
    }

    #[test]
    fn undo_takes_back_an_add() {
        let mut m = Model::default();
        m.add(json!({ "kind": "dot", "cx": 1, "cy": 1, "r": 1, "c": "ink" }));
        m.undo();
        assert!(m.shapes.is_empty());
        m.redo();
        assert_eq!(m.shapes.len(), 1);
    }
}

// ── the window ────────────────────────────────────────────────────────

use crate::{IconMakerWin, MakerShape};
use slint::{ModelRc, VecModel};
use std::cell::RefCell;
use std::rc::Rc;

pub enum Act {
    Pointer(i32, f32, f32),
    Tool(String),
    Colour(bool),
    Weight(i32),
    SelColour(bool),
    SelWeight(i32),
    FillToggle,
    Step(String, i32),
    Do(String),
    Load(String),
    Save,
    Close,
    Refresh,
    NextFill,
    Key(String, bool, bool),
    Import(String),
    ImportStep(String, i32),
    /// A path node's corner / split / remove.
    Node(String),
}

enum Drag {
    Move { last: (f64, f64), moved: bool },
    Draw { start: (f64, f64) },
    /// A pen point just placed: dragging pulls its curve handles out.
    Pen { at: (f64, f64) },
    /// One of the selected shape's handles, by its place in `handles()`.
    Handle { which: usize, moved: bool },
    /// The lasso being drawn round part of a shape.
    Lasso,
}

/// The points to take hold of a shape by, on the grid: the ends of a line, the
/// corners of a box, a circle's or an ellipse's edge, an arc's two ends and the
/// middle of its curve. None for the shapes with no such handles (paths) and
/// for a turned shape, whose own frame isn't the grid's.
pub fn handles(s: &Value) -> Vec<(f64, f64)> {
    if f(s, "rot") != 0.0 {
        return Vec::new();
    }
    match kind(s) {
        "line" => vec![(f(s, "x1"), f(s, "y1")), (f(s, "x2"), f(s, "y2"))],
        "rect" => {
            let (x, y, w, h) = (f(s, "x"), f(s, "y"), f(s, "w"), f(s, "h"));
            vec![(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
        }
        "circle" | "dot" => vec![(f(s, "cx") + f(s, "r"), f(s, "cy"))],
        "ellipse" => vec![(f(s, "cx") + f(s, "rx"), f(s, "cy")), (f(s, "cx"), f(s, "cy") + f(s, "ry"))],
        "arc" => {
            let (cx, cy, r, a0, a1) = (f(s, "cx"), f(s, "cy"), f(s, "r"), f(s, "a0"), f(s, "a1"));
            vec![polar(cx, cy, r, a0), polar(cx, cy, r, a1), polar(cx, cy, r, (a0 + a1) / 2.0)]
        }
        _ => Vec::new(),
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Role {
    Point,
    Node,
    Bezier,
    Rot,
}

pub struct Handle {
    pub x: f64,
    pub y: f64,
    pub role: Role,
    /// What a curve handle hangs off, for the stalk drawn back to it.
    pub from: Option<(f64, f64)>,
}

/// A path's handles in order: each node, then its two curve handles where it has them.
/// (node, 0 = the point, 1 = the handle into it, 2 = the handle out of it)
fn path_ids(s: &Value) -> Vec<(usize, u8)> {
    let mut out = Vec::new();
    for (i, nd) in s["nodes"].as_array().into_iter().flatten().enumerate() {
        out.push((i, 0));
        if nd["hi"].is_object() {
            out.push((i, 1));
        }
        if nd["ho"].is_object() {
            out.push((i, 2));
        }
    }
    out
}

/// Every handle of a shape: its own (a path's nodes and curve handles included) and,
/// last, the knob above it that turns it — all but a circle or a dot, which have nothing to turn.
pub fn all_handles(s: &Value) -> Vec<Handle> {
    let mut out: Vec<Handle> = Vec::new();
    if kind(s) == "path" && f(s, "rot") == 0.0 {
        let ids = path_ids(s);
        let nodes = nodes_of(&s["nodes"]);
        for (i, part) in ids {
            let nd = nodes[i];
            match part {
                0 => out.push(Handle { x: nd.0, y: nd.1, role: Role::Node, from: None }),
                1 => out.push(Handle { x: nd.2.unwrap_or((nd.0, nd.1)).0, y: nd.2.unwrap_or((nd.0, nd.1)).1, role: Role::Bezier, from: Some((nd.0, nd.1)) }),
                _ => out.push(Handle { x: nd.3.unwrap_or((nd.0, nd.1)).0, y: nd.3.unwrap_or((nd.0, nd.1)).1, role: Role::Bezier, from: Some((nd.0, nd.1)) }),
            }
        }
    } else {
        out.extend(handles(s).into_iter().map(|h| Handle { x: h.0, y: h.1, role: Role::Point, from: None }));
    }
    if !matches!(kind(s), "circle" | "dot") {
        let (x, y, w, h) = bounds_of(s);
        let top = (x + w / 2.0, y);
        let turned = turn(s, f(s, "rot"));
        let (kx, ky) = turned(x + w / 2.0, y - 2.2);
        let from = turned(top.0, top.1);
        out.push(Handle { x: kx, y: ky, role: Role::Rot, from: Some(from) });
    }
    out
}

/// Handle `which` of `all_handles` dragged to a point: `(px, py)` snapped to the grid,
/// `(rx, ry)` as it is (an angle isn't snapped).
pub fn drag_any(s: &Value, which: usize, (px, py): (f64, f64), (rx, ry): (f64, f64)) -> Vec<(&'static str, Value)> {
    let hs = all_handles(s);
    match hs.get(which).map(|h| h.role) {
        Some(Role::Rot) => {
            let (cx, cy) = centre_of(s);
            // Straight up is no turn: measured from due north.
            let mut deg = (ry - cy).atan2(rx - cx).to_degrees() + 90.0;
            while deg <= -180.0 {
                deg += 360.0;
            }
            while deg > 180.0 {
                deg -= 360.0;
            }
            vec![("rot", json!((deg * 10.0).round() / 10.0))]
        }
        Some(Role::Node) | Some(Role::Bezier) => {
            let Some(&(i, part)) = path_ids(s).get(which) else { return Vec::new() };
            let mut nodes = s["nodes"].clone();
            let Some(nd) = nodes.get_mut(i) else { return Vec::new() };
            let (ox, oy) = (f(nd, "x"), f(nd, "y"));
            match part {
                0 => {
                    // The point, its handles in tow.
                    let (dx, dy) = (px - ox, py - oy);
                    nd["x"] = json!(px);
                    nd["y"] = json!(py);
                    for k in ["hi", "ho"] {
                        if nd[k].is_object() {
                            nd[k]["x"] = json!(f(&nd[k], "x") + dx);
                            nd[k]["y"] = json!(f(&nd[k], "y") + dy);
                        }
                    }
                }
                _ => {
                    let (this, other) = if part == 1 { ("hi", "ho") } else { ("ho", "hi") };
                    nd[this] = json!({ "x": px, "y": py });
                    // A smooth point keeps its two handles opposite and equal, so the curve runs
                    // through it rather than kinking; a corner is the one marked for a kink.
                    if nd["corner"] != true && nd[other].is_object() {
                        nd[other] = json!({ "x": 2.0 * ox - px, "y": 2.0 * oy - py });
                    }
                }
            }
            vec![("nodes", nodes)]
        }
        _ => drag_handle(s, which, px, py),
    }
}

/// A node's corner/smooth toggle, split and remove (IconModel.pathNodeOp).
pub fn node_op(s: &Value, op: &str, index: usize) -> Option<Value> {
    let mut nodes = s["nodes"].as_array()?.clone();
    if index >= nodes.len() {
        return None;
    }
    match op {
        "delete" => {
            // Two nodes is the least that still draws a line.
            if nodes.len() <= 2 {
                return None;
            }
            nodes.remove(index);
        }
        "corner" => {
            let (prev, next) = (nodes[(index + nodes.len() - 1) % nodes.len()].clone(), nodes[(index + 1) % nodes.len()].clone());
            let nd = &mut nodes[index];
            if nd["corner"] == true {
                // Back to smooth: handles along the line between its neighbours.
                nd["corner"] = json!(false);
                let (dx, dy) = ((f(&next, "x") - f(&prev, "x")) / 4.0, (f(&next, "y") - f(&prev, "y")) / 4.0);
                nd["hi"] = json!({ "x": f(nd, "x") - dx, "y": f(nd, "y") - dy });
                nd["ho"] = json!({ "x": f(nd, "x") + dx, "y": f(nd, "y") + dy });
            } else {
                nd["corner"] = json!(true);
                nd.as_object_mut()?.remove("hi");
                nd.as_object_mut()?.remove("ho");
            }
        }
        "split" => {
            // A node halfway along the segment that follows this one.
            let closed = s["closed"] == true;
            let b = nodes.get(index + 1).cloned().or(if closed { nodes.first().cloned() } else { None })?;
            let a = nodes[index].clone();
            nodes.insert(index + 1, json!({ "x": (f(&a, "x") + f(&b, "x")) / 2.0, "y": (f(&a, "y") + f(&b, "y")) / 2.0, "corner": true }));
        }
        _ => return None,
    }
    Some(Value::Array(nodes))
}

/// A handle dragged to a grid point (already snapped): the fields it changes.
pub fn drag_handle(s: &Value, which: usize, px: f64, py: f64) -> Vec<(&'static str, Value)> {
    match kind(s) {
        "line" => if which == 0 { vec![("x1", json!(px)), ("y1", json!(py))] } else { vec![("x2", json!(px)), ("y2", json!(py))] },
        "rect" => {
            // The corner opposite is the one that stays.
            let hs = handles(s);
            let Some(fixed) = hs.get((which + 2) % 4) else { return Vec::new() };
            vec![("x", json!(px.min(fixed.0))), ("y", json!(py.min(fixed.1))), ("w", json!((px - fixed.0).abs())), ("h", json!((py - fixed.1).abs()))]
        }
        "circle" | "dot" => vec![("r", json!(n(((px - f(s, "cx")).hypot(py - f(s, "cy"))) * 2.0) / 2.0))],
        "ellipse" => if which == 0 { vec![("rx", json!((px - f(s, "cx")).abs()))] } else { vec![("ry", json!((py - f(s, "cy")).abs()))] },
        "arc" => {
            let (cx, cy) = (f(s, "cx"), f(s, "cy"));
            let angle = ((py - cy).atan2(px - cx).to_degrees() / 15.0).round() * 15.0;
            match which {
                0 => vec![("a0", json!(angle))],
                1 => {
                    // Kept within a turn of the start, so a drag never flips the arc's way round.
                    let a0 = f(s, "a0");
                    let mut a = angle;
                    while a <= a0 - 360.0 { a += 360.0 }
                    while a > a0 + 360.0 { a -= 360.0 }
                    vec![("a1", json!(a))]
                }
                _ => vec![("r", json!(n((px - cx).hypot(py - cy) * 2.0) / 2.0))],
            }
        }
        _ => Vec::new(),
    }
}

pub struct Host {
    pub ui: IconMakerWin,
    pub window: Rc<slint::platform::software_renderer::MinimalSoftwareWindow>,
    pub surface: Option<usize>,
    pub model: Model,
    pub acts: Rc<RefCell<Vec<Act>>>,
    tool: String,
    /// A path being drawn with the pen: Return (or its first point) ends it.
    pen: bool,
    next_acc: bool,
    next_sw: i32,
    next_fill: bool,
    drag: Option<Drag>,
    /// The node of the selected path last taken hold of, for the corner / split / remove buttons.
    sel_node: Option<usize>,
    /// The lasso's points so far, in grid units.
    lasso: Vec<(f64, f64)>,
    loaded_as: String,
    status: String,
    /// What was last saved (or loaded), to tell whether there is unsaved work.
    saved_shapes: Vec<Value>,
    /// Picture import: what was last read, how it is traced, where its
    /// shapes sit in the drawing (start, count) so a retrace replaces them.
    source: Option<crate::tracing::Bitmap>,
    thr: f64,
    det: f64,
    traced_at: Option<(usize, usize)>,
    busy: bool,
    /// Set by a click on an import button: the app starts the helper thread.
    pub want: Option<String>,
    pub rx: std::sync::mpsc::Receiver<Picked>,
    tx: std::sync::mpsc::Sender<Picked>,
}

/// What a helper thread brought back: a picture's bytes, or why not.
pub enum Picked {
    Bytes(Vec<u8>),
    Nothing(String),
}

fn name_problem(name: &str, shapes: &[Value], loaded_as: &str) -> String {
    let t = name.trim();
    let ok = !t.is_empty()
        && t.len() <= 32
        && t.chars().next().is_some_and(|c| c.is_ascii_alphabetic())
        && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if t.is_empty() {
        "Give it a name".into()
    } else if crate::iconpick::NAMES.contains(&t) {
        "The built-in pack already has one called that".into()
    } else if !ok {
        "Letters, digits, - and _, starting with a letter".into()
    } else if !draws(shapes) {
        "Draw something first".into()
    } else if crate::iconpick::user_icons().contains_key(t) && t != loaded_as {
        "You already have one called that".into()
    } else {
        String::new()
    }
}

impl Host {
    pub fn new() -> Self {
        let ui = IconMakerWin::new().expect("the icon maker");
        let window = crate::platform::take_adapter().expect("the icon maker's window");
        let acts: Rc<RefCell<Vec<Act>>> = Rc::new(RefCell::new(Vec::new()));
        macro_rules! on {
            ($m:ident, |$($a:ident),*| $e:expr) => {{
                let q = acts.clone();
                ui.$m(move |$($a),*| q.borrow_mut().push($e));
            }};
        }
        on!(on_pointer, |k, x, y| Act::Pointer(k, x, y));
        on!(on_node_act, |o| Act::Node(o.to_string()));
        on!(on_tool_set, |t| Act::Tool(t.to_string()));
        on!(on_colour, |a| Act::Colour(a));
        on!(on_weight, |w| Act::Weight(w));
        on!(on_sel_colour, |a| Act::SelColour(a));
        on!(on_sel_weight, |w| Act::SelWeight(w));
        on!(on_fill_toggle, | | Act::FillToggle);
        on!(on_step, |k, d| Act::Step(k.to_string(), d));
        on!(on_act, |a| Act::Do(a.to_string()));
        on!(on_load, |n| Act::Load(n.to_string()));
        on!(on_save, | | Act::Save);
        on!(on_done, | | Act::Close);
        on!(on_name_edited, | | Act::Refresh);
        on!(on_next_fill_toggle, | | Act::NextFill);
        on!(on_import_act, |k| Act::Import(k.to_string()));
        on!(on_import_step, |k, d| Act::ImportStep(k.to_string(), d));
        on!(on_key, |t, c, sh| Act::Key(t.to_string(), c, sh));
        let (tx, rx) = std::sync::mpsc::channel();
        let mut h = Host {
            ui,
            window,
            surface: None,
            model: Model::default(),
            acts,
            tool: "select".into(),
            pen: false,
            next_acc: false,
            next_sw: 2,
            next_fill: false,
            drag: None,
            sel_node: None,
            lasso: Vec::new(),
            loaded_as: String::new(),
            status: String::new(),
            saved_shapes: Vec::new(),
            source: None,
            thr: 128.0,
            det: 1.0,
            traced_at: None,
            busy: false,
            want: None,
            rx,
            tx,
        };
        h.refresh();
        h
    }

    /// Unsaved work: the drawing differs from what was last saved.
    pub fn dirty(&self) -> bool {
        !self.model.shapes.is_empty() && self.model.shapes != self.saved_shapes
    }

    fn fresh(&self, mut o: Value) -> Value {
        o["c"] = json!(if self.next_acc { "acc" } else { "ink" });
        o["sw"] = json!(self.next_sw);
        if self.next_fill {
            o["fill"] = json!(true);
        }
        o
    }

    /// One thing the window asked for; true when it should close.
    pub fn act(&mut self, a: Act) -> bool {
        self.status.clear();
        match a {
            Act::Close => return true,
            Act::Tool(t) => {
                self.finish_pen();
                self.tool = t;
            }
            Act::Colour(acc) => self.next_acc = acc,
            Act::Weight(w) => self.next_sw = w,
            Act::SelColour(acc) => self.model.update(&[("c", json!(if acc { "acc" } else { "ink" }))], false),
            Act::SelWeight(w) => self.model.update(&[("sw", json!(w))], false),
            Act::FillToggle => {
                let on = self.model.current().is_some_and(|s| s["fill"] == true);
                self.model.update(&[("fill", json!(!on))], false);
            }
            Act::Step(k, d) => {
                let Some(s) = self.model.current().cloned() else { return false };
                let d = d as f64;
                match k.as_str() {
                    "rot" => {
                        let r = (f(&s, "rot") + 15.0 * d).rem_euclid(360.0);
                        self.model.update(&[("rot", json!(r))], false);
                    }
                    "r" => self.model.update(&[("r", json!((f(&s, "r") + 0.5 * d).max(0.0)))], false),
                    "a0" => self.model.update(&[("a0", json!(f(&s, "a0") + 15.0 * d))], false),
                    "a1" => self.model.update(&[("a1", json!(f(&s, "a1") + 15.0 * d))], false),
                    _ => {}
                }
            }
            Act::Do(w) => match w.as_str() {
                "undo" => self.model.undo(),
                "redo" => self.model.redo(),
                "clear" => self.model.clear(),
                "delete" => self.model.remove_selected(),
                "duplicate" => self.model.duplicate(),
                "forward" => self.model.reorder(1),
                "back" => self.model.reorder(-1),
                "flipx" => self.model.mirror(true),
                "flipy" => self.model.mirror(false),
                "new" => {
                    self.model.replace(Vec::new());
                    self.ui.set_name("".into());
                    self.loaded_as.clear();
                    self.saved_shapes.clear();
                }
                "delete-saved" => self.delete_saved(),
                _ => {}
            },
            Act::Load(n) => {
                let spec = crate::iconpick::user_icons().get(&n).cloned().unwrap_or(Value::Null);
                match spec["shapes"].as_array() {
                    Some(sh) if !sh.is_empty() => {
                        self.model.replace(sh.clone());
                        self.ui.set_name(n.clone().into());
                        self.loaded_as = n;
                        self.saved_shapes = self.model.shapes.clone();
                    }
                    _ => self.status = format!("{n} has no shapes to edit"),
                }
            }
            Act::Save => self.save(),
            Act::Refresh => {}
            Act::Import(k) => {
                self.want = Some(k);
                self.busy = true;
            }
            Act::ImportStep(k, d) => {
                match k.as_str() {
                    "thr" => self.thr = (self.thr + 16.0 * d as f64).clamp(16.0, 240.0),
                    "det" => self.det = (self.det + 0.2 * d as f64).clamp(0.3, 3.3),
                    _ => {}
                }
                self.retrace();
            }
            Act::NextFill => self.next_fill = !self.next_fill,
            Act::Key(t, ctrl, shift) => return self.key(&t, ctrl, shift),
            Act::Node(op) => {
                if let (Some(cur), Some(i)) = (self.model.current().cloned(), self.sel_node) {
                    if kind(&cur) == "path" {
                        match node_op(&cur, &op, i) {
                            Some(nodes) => {
                                self.model.snapshot();
                                self.model.update(&[("nodes", nodes)], true);
                                if op == "delete" {
                                    self.sel_node = None;
                                }
                            }
                            None if op == "delete" => self.status = "A line needs at least two points.".into(),
                            None => {}
                        }
                    }
                }
            }
            Act::Pointer(k, x, y) => self.pointer(k, x as f64, y as f64),
        }
        self.refresh();
        false
    }

    fn pointer(&mut self, k: i32, x: f64, y: f64) {
        let (sx, sy) = (snap(x), snap(y));
        match k {
            0 => {
                // A handle of the shape already selected comes first, whatever the tool.
                if let Some(cur) = self.model.current() {
                    let hs = all_handles(cur);
                    // The nearest within reach, curve handles over the point they hang off.
                    let hit = hs.iter().enumerate().filter(|(_, h)| (h.x - x).hypot(h.y - y) <= 0.7).min_by(|a, b| (a.1.x - x).hypot(a.1.y - y).partial_cmp(&(b.1.x - x).hypot(b.1.y - y)).unwrap_or(std::cmp::Ordering::Equal));
                    if let Some((which, h)) = hit {
                        if h.role == Role::Node {
                            self.sel_node = path_ids(cur).get(which).map(|p| p.0);
                        }
                        self.drag = Some(Drag::Handle { which, moved: false });
                        return;
                    }
                }
                if self.tool == "lasso" {
                    self.lasso = vec![(x, y)];
                    self.drag = Some(Drag::Lasso);
                    return;
                }
                if self.tool == "select" {
                    let before = self.model.selected;
                    self.model.selected = self.model.pick(x, y, 0.9);
                    if self.model.selected != before {
                        self.sel_node = None;
                    }
                    self.drag = self.model.selected.map(|_| Drag::Move { last: (sx, sy), moved: false });
                    return;
                }
                if self.tool == "pen" {
                    self.pen_press(sx, sy);
                    return;
                }
                let s = match self.tool.as_str() {
                    "line" => json!({ "kind": "line", "x1": sx, "y1": sy, "x2": sx, "y2": sy }),
                    "rect" => json!({ "kind": "rect", "x": sx, "y": sy, "w": 0, "h": 0, "r": 0 }),
                    "circle" => json!({ "kind": "circle", "cx": sx, "cy": sy, "r": 0 }),
                    "ellipse" => json!({ "kind": "ellipse", "cx": sx, "cy": sy, "rx": 0, "ry": 0 }),
                    "arc" => json!({ "kind": "arc", "cx": sx, "cy": sy, "r": 0, "a0": 0, "a1": 270 }),
                    "dot" => {
                        let mut d = self.fresh(json!({ "kind": "dot", "cx": sx, "cy": sy, "r": 1.5 }));
                        d["fill"] = json!(true);
                        self.model.add(d);
                        return;
                    }
                    _ => return,
                };
                let s = self.fresh(s);
                self.model.add(s);
                self.drag = Some(Drag::Draw { start: (sx, sy) });
            }
            1 => match self.drag {
                Some(Drag::Move { ref mut last, ref mut moved }) => {
                    let (dx, dy) = (sx - last.0, sy - last.1);
                    if dx != 0.0 || dy != 0.0 {
                        if !*moved {
                            *moved = true;
                            self.model.snapshot();
                        }
                        *last = (sx, sy);
                        self.model.move_selected(dx, dy);
                    }
                }
                Some(Drag::Pen { at }) => {
                    let (dx, dy) = (x - at.0, y - at.1);
                    if dx.hypot(dy) > 0.4 {
                        // Handles out of the point, one each way (a smooth point).
                        let (hx, hy) = (snap(x), snap(y));
                        if let Some(i) = self.model.selected {
                            if let Some(nodes) = self.model.shapes[i]["nodes"].as_array_mut() {
                                if let Some(last) = nodes.last_mut() {
                                    last["ho"] = json!({ "x": hx, "y": hy });
                                    last["hi"] = json!({ "x": snap(2.0 * at.0 - x), "y": snap(2.0 * at.1 - y) });
                                }
                            }
                        }
                    }
                }
                Some(Drag::Lasso) => {
                    if self.lasso.last().is_none_or(|l| (l.0 - x).hypot(l.1 - y) > 0.2) {
                        self.lasso.push((x, y));
                    }
                }
                Some(Drag::Handle { which, ref mut moved }) => {
                    if let Some(cur) = self.model.current().cloned() {
                        let fields = drag_any(&cur, which, (sx, sy), (x, y));
                        if !fields.is_empty() {
                            if !*moved {
                                *moved = true;
                                self.model.snapshot();
                            }
                            self.model.update(&fields, true);
                        }
                    }
                }
                Some(Drag::Draw { start }) => {
                    let (w, h) = ((sx - start.0).abs(), (sy - start.1).abs());
                    let r = (sx - start.0).hypot(sy - start.1);
                    let fields: Vec<(&str, Value)> = match self.tool.as_str() {
                        "line" => vec![("x2", json!(sx)), ("y2", json!(sy))],
                        "rect" => vec![("x", json!(sx.min(start.0))), ("y", json!(sy.min(start.1))), ("w", json!(w)), ("h", json!(h))],
                        "circle" | "arc" => vec![("r", json!(n(r * 2.0) / 2.0))],
                        "ellipse" => vec![("rx", json!(w)), ("ry", json!(h))],
                        _ => Vec::new(),
                    };
                    self.model.update(&fields, true);
                }
                None => {}
            },
            _ => {
                if matches!(self.drag, Some(Drag::Lasso)) {
                    let pts = std::mem::take(&mut self.lasso);
                    self.drag = None;
                    self.split_by_lasso(&pts);
                    self.refresh();
                    return;
                }
                // A shape dragged out to nothing isn't kept.
                if let (Some(Drag::Draw { .. }), Some(s)) = (&self.drag, self.model.current()) {
                    let (_, _, w, h) = bounds_of(s);
                    if w == 0.0 && h == 0.0 && kind(s) != "line" || kind(s) == "line" && w == 0.0 && h == 0.0 {
                        self.model.remove_selected();
                        self.model.forget_snapshot();
                    }
                }
                self.drag = None;
            }
        }
        self.refresh();
    }

    /// What the lasso was drawn round becomes a piece of its own, in the accent (IconModel.splitByLasso):
    /// the selected shape, or the one under the lasso's middle if nothing is.
    fn split_by_lasso(&mut self, lasso: &[(f64, f64)]) {
        if lasso.len() < 3 {
            return;
        }
        let at = match self.model.selected {
            Some(i) => i,
            None => {
                let (mx, my) = (lasso.iter().map(|p| p.0).sum::<f64>() / lasso.len() as f64, lasso.iter().map(|p| p.1).sum::<f64>() / lasso.len() as f64);
                match self.model.pick(mx, my, 3.0) {
                    Some(i) => i,
                    None => {
                        self.status = "Draw the lasso over a shape to split it.".into();
                        return;
                    }
                }
            }
        };
        let Some(shape) = self.model.shapes.get(at).cloned() else { return };
        match crate::split::split(&shape, lasso) {
            Err(e) => self.status = e,
            Ok(cut) => {
                self.model.snapshot();
                let n_out = cut.outside.len();
                let inside = cut.inside.into_iter().map(|mut p| {
                    p["c"] = json!("acc");
                    p
                });
                let pieces: Vec<Value> = cut.outside.into_iter().chain(inside).collect();
                self.model.shapes.splice(at..=at, pieces);
                // The cut-out piece, so it can be recoloured straight away.
                self.model.selected = Some(at + n_out);
                self.sel_node = None;
            }
        }
    }

    /// Keys: Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y, Ctrl+S, Ctrl+D; Delete; the arrows
    /// nudge (Shift for a whole unit); letters pick a tool.
    fn key(&mut self, t: &str, ctrl: bool, shift: bool) -> bool {
        let lower = t.to_lowercase();
        if ctrl {
            match (lower.as_str(), shift) {
                ("z", false) => self.model.undo(),
                ("z", true) | ("y", _) => self.model.redo(),
                ("s", _) => self.save(),
                ("d", _) => self.model.duplicate(),
                _ => return false,
            }
        } else {
            use slint::platform::Key;
            let step = if shift { 1.0 } else { 0.5 };
            let is = |k: Key| slint::SharedString::from(k) == t;
            if is(Key::Return) && self.pen {
                self.finish_pen();
            } else if is(Key::Delete) || is(Key::Backspace) {
                self.model.remove_selected();
            } else if is(Key::LeftArrow) {
                self.model.snapshot();
                self.model.move_selected(-step, 0.0);
            } else if is(Key::RightArrow) {
                self.model.snapshot();
                self.model.move_selected(step, 0.0);
            } else if is(Key::UpArrow) {
                self.model.snapshot();
                self.model.move_selected(0.0, -step);
            } else if is(Key::DownArrow) {
                self.model.snapshot();
                self.model.move_selected(0.0, step);
            } else {
                match lower.as_str() {
                    "v" => self.tool = "select".into(),
                    "l" => self.tool = "line".into(),
                    "b" => self.tool = "rect".into(),
                    "c" => self.tool = "circle".into(),
                    "e" => self.tool = "ellipse".into(),
                    "a" => self.tool = "arc".into(),
                    "d" => self.tool = "dot".into(),
                    "s" => self.tool = "lasso".into(),
                    "p" => {
                        self.finish_pen();
                        self.tool = "pen".into();
                    }
                    _ => return false,
                }
            }
        }
        self.refresh();
        false
    }

    fn delete_saved(&mut self) {
        let name = self.loaded_as.clone();
        if name.is_empty() {
            return;
        }
        let path = crate::iconpick::path();
        let Some(mut doc) = std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) else { return };
        if let Some(o) = doc["icons"].as_object_mut() {
            o.remove(&name);
        }
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, serde_json::to_string_pretty(&doc).unwrap_or_default()).and_then(|_| std::fs::rename(&tmp, &path)).is_ok() {
            self.status = format!("Deleted {name}");
            self.loaded_as.clear();
            self.saved_shapes.clear();
        }
    }

    /// The helper thread for an import button: the Files dialog or the
    /// clipboard, off the main loop, its answer sent back with a wake.
    pub fn spawn_import(&mut self, kind: &str, mut wake: std::os::unix::net::UnixStream) {
        use std::io::Write;
        let tx = self.tx.clone();
        let clipboard = kind == "clipboard";
        std::thread::spawn(move || {
            let answer = if clipboard { read_clipboard() } else { pick_file() };
            let _ = tx.send(answer);
            let _ = wake.write_all(b"!");
        });
    }

    /// Whatever the helper thread sent, if anything yet.
    pub fn poll(&mut self) {
        while let Ok(p) = self.rx.try_recv() {
            self.busy = false;
            self.status.clear();
            match p {
                Picked::Nothing(why) => self.status = why,
                Picked::Bytes(b) => self.load_picture(&b),
            }
            self.refresh();
        }
    }

    /// A picture named on the command line (`iconMaker <path>`).
    pub fn import_path(&mut self, path: &str) {
        self.status.clear();
        match std::fs::read(path.strip_prefix("file://").unwrap_or(path)) {
            Ok(b) => self.load_picture(&b),
            Err(_) => self.status = "Could not open that file.".into(),
        }
        self.refresh();
    }

    fn load_picture(&mut self, bytes: &[u8]) {
        let head = String::from_utf8_lossy(&bytes[..bytes.len().min(4096)]).to_lowercase();
        if head.contains("<svg") {
            // Already curves: read, not traced.
            self.source = None;
            match crate::tracing::svg(bytes) {
                Ok((shapes, note)) => {
                    let count = shapes.len();
                    self.add_traced(shapes, false);
                    self.status = if note.is_empty() { format!("Read {count} shape{} from the SVG", if count == 1 { "" } else { "s" }) } else { note };
                }
                Err(e) => self.status = e,
            }
            return;
        }
        match crate::tracing::Bitmap::decode(bytes) {
            Ok(b) => {
                self.thr = 128.0;
                self.det = 1.0;
                let note = if b.use_alpha { String::new() } else { "No transparency in that file — traced the dark parts.".to_string() };
                self.source = Some(b);
                self.traced_at = None;
                self.retrace();
                if !note.is_empty() && self.status.starts_with("Traced") {
                    self.status = note;
                }
            }
            Err(e) => self.status = e,
        }
    }

    /// Traces the current picture with the sliders as they are; the shapes of
    /// the last trace, if the drawing hasn't been touched since, are replaced.
    fn retrace(&mut self) {
        let Some(src) = &self.source else { return };
        match src.trace(&crate::tracing::Opts { threshold: self.thr, detail: self.det, ..Default::default() }) {
            Ok(shapes) => {
                let count = shapes.len();
                self.add_traced(shapes, true);
                self.status = format!("Traced {count} shape{} — pick one and set ink or accent", if count == 1 { "" } else { "s" });
            }
            Err(e) => self.status = e,
        }
    }

    fn add_traced(&mut self, shapes: Vec<Value>, replace_last: bool) {
        let mut all = self.model.shapes.clone();
        if let (true, Some((at, n))) = (replace_last, self.traced_at) {
            if all.len() == at + n {
                all.truncate(at);
            }
        }
        let at = all.len();
        let n = shapes.len();
        all.extend(shapes);
        self.model.replace(all);
        self.model.selected = if n > 0 { Some(at + n - 1) } else { None };
        self.traced_at = Some((at, n));
    }

    /// A click with the pen: the first starts a path, each after adds a point, and one on
    /// the first point of three or more closes it.
    fn pen_press(&mut self, x: f64, y: f64) {
        let node = json!({ "x": x, "y": y });
        if !self.pen {
            let s = self.fresh(json!({ "kind": "path", "closed": false, "nodes": [node] }));
            self.model.add(s);
            self.pen = true;
            self.drag = Some(Drag::Pen { at: (x, y) });
            return;
        }
        let Some(i) = self.model.selected else { self.pen = false; return };
        let (close, count) = {
            let nodes = self.model.shapes[i]["nodes"].as_array().cloned().unwrap_or_default();
            let first = nodes.first().map(|n| (f(n, "x"), f(n, "y")));
            (nodes.len() >= 3 && first.is_some_and(|p| (p.0 - x).hypot(p.1 - y) < 0.7), nodes.len())
        };
        if close {
            self.model.shapes[i]["closed"] = json!(true);
            self.finish_pen();
            return;
        }
        if let Some(nodes) = self.model.shapes[i]["nodes"].as_array_mut() {
            nodes.push(node);
        }
        let _ = count;
        self.drag = Some(Drag::Pen { at: (x, y) });
    }

    /// Ends the path being drawn: kept if it has two points, dropped if not.
    fn finish_pen(&mut self) {
        if !self.pen {
            return;
        }
        self.pen = false;
        if let Some(i) = self.model.selected {
            let n = self.model.shapes[i]["nodes"].as_array().map(|a| a.len()).unwrap_or(0);
            if n < 2 {
                self.model.remove_selected();
                self.model.forget_snapshot();
                self.model.forget_snapshot();
            }
        }
    }

    fn save(&mut self) {
        let name = self.ui.get_name().trim().to_string();
        let problem = name_problem(&name, &self.model.shapes, &self.loaded_as);
        if !problem.is_empty() {
            self.status = problem;
            return;
        }
        let path = crate::iconpick::path();
        // Read again at save, so what other programs added since stays.
        let mut doc: Value = std::fs::read_to_string(&path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_else(|| json!({ "version": 1, "icons": {} }));
        if !doc["icons"].is_object() {
            doc["icons"] = json!({});
        }
        doc["icons"][&name] = compose(&self.model.shapes);
        doc["version"] = json!(1);
        let tmp = path.with_extension("json.tmp");
        let written = std::fs::create_dir_all(path.parent().unwrap_or(std::path::Path::new(".")))
            .and_then(|_| std::fs::write(&tmp, serde_json::to_string_pretty(&doc).unwrap_or_default()))
            .and_then(|_| std::fs::rename(&tmp, &path));
        match written {
            Ok(()) => {
                self.loaded_as = name.clone();
                self.saved_shapes = self.model.shapes.clone();
                self.status = format!("Saved {name}");
            }
            Err(e) => self.status = format!("Couldn't save: {e}"),
        }
    }

    pub fn refresh(&mut self) {
        let ui = &self.ui;
        let sel = self.model.selected;
        let shapes: Vec<MakerShape> = self
            .model
            .shapes
            .iter()
            .enumerate()
            .map(|(i, s)| MakerShape { glyph: glyph_of(s), selected: sel == Some(i) })
            .collect();
        ui.set_shapes(ModelRc::new(VecModel::from(shapes)));
        ui.set_tool(self.tool.clone().into());
        let mut d = String::new();
        for (i, p) in self.lasso.iter().enumerate() {
            d += &format!("{}{:.2} {:.2} ", if i == 0 { "M" } else { "L" }, p.0, p.1);
        }
        ui.set_lasso_path(d.into());
        ui.set_next_acc(self.next_acc);
        ui.set_next_sw(self.next_sw);
        ui.set_next_fill(self.next_fill);
        ui.set_bitmap(self.source.is_some());
        ui.set_busy(self.busy);
        ui.set_thr(format!("{}", self.thr as i32).into());
        ui.set_det(format!("{:.1}", self.det).into());
        ui.set_loaded(!self.loaded_as.is_empty() && crate::iconpick::user_icons().contains_key(&self.loaded_as));
        ui.set_dirty(self.dirty());
        ui.set_can_undo(self.model.can_undo());
        ui.set_can_redo(self.model.can_redo());
        match self.model.current() {
            Some(s) => {
                let (x, y, w, h) = bounds_of(s);
                ui.set_has_sel(true);
                ui.set_sel_kind(kind(s).into());
                ui.set_sel_acc(s["c"] == "acc");
                ui.set_sel_sw(if f(s, "sw") == 3.0 { 3 } else { 2 });
                ui.set_sel_fill(s["fill"] == true);
                ui.set_sel_rot(fmt(f(s, "rot")).into());
                ui.set_sel_r(fmt(f(s, "r")).into());
                ui.set_sel_a0(fmt(f(s, "a0")).into());
                ui.set_sel_a1(fmt(f(s, "a1")).into());
                let ids = path_ids(s);
                let hs: Vec<crate::MakerHandle> = all_handles(s)
                    .into_iter()
                    .enumerate()
                    .map(|(i, h)| crate::MakerHandle {
                        x: h.x as f32,
                        y: h.y as f32,
                        role: match h.role { Role::Point => "point", Role::Node => "node", Role::Bezier => "bezier", Role::Rot => "rot" }.into(),
                        fx: h.from.map_or(h.x, |p| p.0) as f32,
                        fy: h.from.map_or(h.y, |p| p.1) as f32,
                        stalk: h.from.is_some(),
                        on: h.role == Role::Node && ids.get(i).map(|p| p.0) == self.sel_node,
                    })
                    .collect();
                ui.set_handles(ModelRc::new(VecModel::from(hs)));
                ui.set_sel_node(kind(s) == "path" && self.sel_node.is_some_and(|i| i < s["nodes"].as_array().map_or(0, |a| a.len())));
                ui.set_node_note(if kind(s) == "path" { format!("{} points", s["nodes"].as_array().map_or(0, |a| a.len())) } else { String::new() }.into());
                ui.set_bx(x as f32);
                ui.set_by(y as f32);
                ui.set_bw(w as f32);
                ui.set_bh(h as f32);
            }
            None => {
                ui.set_has_sel(false);
                ui.set_sel_node(false);
                ui.set_handles(ModelRc::new(VecModel::from(Vec::<crate::MakerHandle>::new())));
            }
        }
        let name = ui.get_name().to_string();
        ui.set_problem(if self.model.shapes.is_empty() && name.is_empty() { "".into() } else { name_problem(&name, &self.model.shapes, &self.loaded_as).into() });
        ui.set_status(self.status.clone().into());
        let saved: Vec<slint::SharedString> = crate::iconpick::user_icons().keys().map(|k| k.as_str().into()).collect();
        ui.set_saved(ModelRc::new(VecModel::from(saved)));
    }
}

/// Tests: the picture the "clipboard" and the file dialog hand over, named in
/// a file of the test's own — the headless compositor has no focused client to
/// hold a selection or show a dialog. Only in the test build.
#[cfg(feature = "test-hooks")]
fn test_picture() -> Option<Picked> {
    let dir = std::env::var_os("XDG_RUNTIME_DIR")?;
    let path = std::fs::read_to_string(std::path::Path::new(&dir).join("maker-test-picture")).ok()?;
    Some(match std::fs::read(path.trim()) {
        Ok(b) => Picked::Bytes(b),
        Err(_) => Picked::Nothing("Could not open that file.".into()),
    })
}

#[cfg(not(feature = "test-hooks"))]
fn test_picture() -> Option<Picked> {
    None
}

fn read_clipboard() -> Picked {
    if let Some(p) = test_picture() {
        return p;
    }
    use std::process::Command;
    let types = Command::new("wl-paste").arg("--list-types").output();
    let Ok(types) = types else { return Picked::Nothing("wl-paste isn't installed".into()) };
    let list = String::from_utf8_lossy(&types.stdout).to_string();
    let kind = ["image/png", "image/svg+xml", "image/jpeg", "image/webp"].into_iter().find(|t| list.lines().any(|l| l.trim() == *t));
    let out = match kind {
        Some(t) => Command::new("wl-paste").args(["-t", t]).output(),
        None => Command::new("wl-paste").arg("--no-newline").output(),
    };
    match out {
        Ok(o) if !o.stdout.is_empty() => {
            // Text: SVG markup is read; a file path is read as that file.
            if kind.is_none() {
                let t = String::from_utf8_lossy(&o.stdout).trim().to_string();
                if t.to_lowercase().contains("<svg") {
                    return Picked::Bytes(t.into_bytes());
                }
                let path = t.strip_prefix("file://").unwrap_or(&t).to_string();
                return match std::fs::read(&path) {
                    Ok(b) => Picked::Bytes(b),
                    Err(_) => Picked::Nothing("The clipboard has no picture in it".into()),
                };
            }
            Picked::Bytes(o.stdout)
        }
        _ => Picked::Nothing("The clipboard has no picture in it".into()),
    }
}

fn pick_file() -> Picked {
    if let Some(p) = test_picture() {
        return p;
    }
    let cmd = crate::launcher::files_pick_command(&["Images:*.png *.svg *.jpg *.jpeg *.webp", "Vector:*.svg", "Bitmap:*.png *.jpg *.jpeg *.webp"]);
    let out = std::process::Command::new(&cmd[0]).args(&cmd[1..]).output();
    match out {
        Ok(o) => {
            let text = String::from_utf8_lossy(&o.stdout).to_string();
            match text.lines().map(|l| l.trim()).find(|l| !l.is_empty()) {
                Some(path) => match std::fs::read(path.strip_prefix("file://").unwrap_or(path)) {
                    Ok(b) => Picked::Bytes(b),
                    Err(_) => Picked::Nothing("Could not open that file.".into()),
                },
                None if o.status.code() == Some(1) => Picked::Nothing(String::new()),
                None => Picked::Nothing("Could not open the file dialog — is hyprshell-files installed?".into()),
            }
        }
        Err(_) => Picked::Nothing("Could not open the file dialog — is hyprshell-files installed?".into()),
    }
}

#[cfg(test)]
mod handle_tests {
    use super::*;

    #[test]
    fn dragging_a_boxs_corner_keeps_the_opposite_one() {
        let b = json!({ "kind": "rect", "x": 4, "y": 4, "w": 8, "h": 6, "r": 0 });
        // The bottom right corner (index 2) taken to (16, 14): top left stays at (4, 4).
        let fields = drag_handle(&b, 2, 16.0, 14.0);
        let get = |k: &str| fields.iter().find(|f| f.0 == k).map(|f| f.1.as_f64().unwrap());
        assert_eq!((get("x"), get("y"), get("w"), get("h")), (Some(4.0), Some(4.0), Some(12.0), Some(10.0)));
        // Past the opposite corner, it turns the box over rather than going negative.
        let flipped = drag_handle(&b, 2, 2.0, 2.0);
        let g = |k: &str| flipped.iter().find(|f| f.0 == k).map(|f| f.1.as_f64().unwrap());
        assert_eq!((g("x"), g("y"), g("w"), g("h")), (Some(2.0), Some(2.0), Some(2.0), Some(2.0)));
    }

    #[test]
    fn a_circles_handle_sets_the_radius_and_a_turned_shape_has_none() {
        let c = json!({ "kind": "circle", "cx": 12, "cy": 12, "r": 4 });
        assert_eq!(handles(&c), vec![(16.0, 12.0)]);
        let fields = drag_handle(&c, 0, 18.0, 12.0);
        assert_eq!(fields[0].1.as_f64(), Some(6.0));
        let turned = json!({ "kind": "rect", "x": 1, "y": 1, "w": 2, "h": 2, "rot": 30 });
        assert!(handles(&turned).is_empty());
    }

    #[test]
    fn an_arc_end_follows_the_pointer_in_steps_of_fifteen_degrees() {
        let a = json!({ "kind": "arc", "cx": 12, "cy": 12, "r": 6, "a0": 0, "a1": 270 });
        let fields = drag_handle(&a, 0, 12.0, 18.0);
        assert_eq!(fields[0].1.as_f64(), Some(90.0));
    }

    fn bend() -> Value {
        json!({ "kind": "path", "c": "ink", "sw": 2, "closed": false, "nodes": [
            { "x": 4.0, "y": 12.0, "corner": true },
            { "x": 12.0, "y": 8.0, "hi": { "x": 9.0, "y": 8.0 }, "ho": { "x": 15.0, "y": 8.0 } },
            { "x": 20.0, "y": 12.0, "corner": true } ] })
    }

    #[test]
    fn a_node_drags_with_its_handles_and_a_smooth_handle_mirrors() {
        let s = bend();
        let hs = all_handles(&s);
        // node 0, node 1, its two handles, node 2, then the knob.
        assert_eq!(hs.iter().map(|h| h.role).collect::<Vec<_>>(), vec![Role::Node, Role::Node, Role::Bezier, Role::Bezier, Role::Node, Role::Rot]);
        let moved = drag_any(&s, 1, (12.0, 10.0), (12.0, 10.0));
        let nd = &moved[0].1[1];
        assert_eq!((nd["y"].as_f64(), nd["ho"]["y"].as_f64()), (Some(10.0), Some(10.0)));
        // The handle out, pulled up: the one in goes the opposite way.
        let moved = drag_any(&s, 3, (15.0, 6.0), (15.0, 6.0));
        assert_eq!(moved[0].1[1]["hi"]["y"].as_f64(), Some(10.0));
    }

    #[test]
    fn the_knob_turns_and_node_ops_work() {
        let s = bend();
        let hs = all_handles(&s);
        let knob = hs.last().unwrap();
        assert_eq!(knob.role, Role::Rot);
        // Dragged to the right of the middle: a quarter turn.
        let c = centre_of(&s);
        let r = drag_any(&s, hs.len() - 1, (c.0 + 6.0, c.1), (c.0 + 6.0, c.1));
        assert_eq!(r[0].0, "rot");
        assert_eq!(r[0].1.as_f64(), Some(90.0));
        // Corner on a smooth node drops its handles, and again gives them back.
        let cornered = node_op(&s, "corner", 1).unwrap();
        assert!(cornered[1]["hi"].is_null() && cornered[1]["corner"] == true);
        // Split adds a node midway; remove won't go below two.
        assert_eq!(node_op(&s, "split", 0).unwrap().as_array().unwrap().len(), 4);
        assert_eq!(node_op(&s, "delete", 1).unwrap().as_array().unwrap().len(), 2);
        let two = json!({ "kind": "path", "closed": false, "nodes": [{ "x": 1.0, "y": 1.0 }, { "x": 2.0, "y": 2.0 }] });
        assert!(node_op(&two, "delete", 0).is_none());
    }
}
