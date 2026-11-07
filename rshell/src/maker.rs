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
}

enum Drag {
    Move { last: (f64, f64), moved: bool },
    Draw { start: (f64, f64) },
}

pub struct Host {
    pub ui: IconMakerWin,
    pub window: Rc<slint::platform::software_renderer::MinimalSoftwareWindow>,
    pub surface: Option<usize>,
    pub model: Model,
    pub acts: Rc<RefCell<Vec<Act>>>,
    tool: String,
    next_acc: bool,
    next_sw: i32,
    next_fill: bool,
    drag: Option<Drag>,
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
            next_acc: false,
            next_sw: 2,
            next_fill: false,
            drag: None,
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
            Act::Tool(t) => self.tool = t,
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
            Act::Pointer(k, x, y) => self.pointer(k, x as f64, y as f64),
        }
        self.refresh();
        false
    }

    fn pointer(&mut self, k: i32, x: f64, y: f64) {
        let (sx, sy) = (snap(x), snap(y));
        match k {
            0 => {
                if self.tool == "select" {
                    self.model.selected = self.model.pick(x, y, 0.9);
                    self.drag = self.model.selected.map(|_| Drag::Move { last: (sx, sy), moved: false });
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
            if is(Key::Delete) || is(Key::Backspace) {
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
        match src.trace(&crate::tracing::Opts { threshold: self.thr, detail: self.det }) {
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
                ui.set_bx(x as f32);
                ui.set_by(y as f32);
                ui.set_bw(w as f32);
                ui.set_bh(h as f32);
            }
            None => ui.set_has_sel(false),
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
