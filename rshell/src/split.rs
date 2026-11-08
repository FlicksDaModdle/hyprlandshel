//! Cutting a shape in two with a lasso (modules/icons/Split.js).
//!
//! The point of it is colour: a logo that arrives as one silhouette can only be one
//! colour, so a region is drawn round and what is inside becomes a shape of its own,
//! to be given ink or the accent like any other.
//!
//! A filled shape is an area, and cutting an area means intersecting it with the
//! lasso: it is rasterised on a fine grid, the two halves masked apart and each traced
//! back with the tracer already here. An outline is a line: its nodes are cut into the
//! run inside the lasso and the runs outside, and the curves survive exactly.

use crate::tracing::{trace, Opts};
use serde_json::{json, Value};

type P = (f64, f64);

pub struct Cut {
    pub inside: Vec<Value>,
    pub outside: Vec<Value>,
}

fn f(v: &Value, k: &str) -> f64 {
    v[k].as_f64().unwrap_or(0.0)
}

pub fn point_in_poly(x: f64, y: f64, pts: &[P]) -> bool {
    let mut inside = false;
    let mut j = pts.len().wrapping_sub(1);
    for i in 0..pts.len() {
        let (a, b) = (pts[i], pts[j]);
        if (a.1 > y) != (b.1 > y) && x < (b.0 - a.0) * (y - a.1) / (b.1 - a.1) + a.0 {
            inside = !inside;
        }
        j = i;
    }
    inside
}

fn handle(nd: &Value, k: &str) -> Option<P> {
    nd[k].as_object().map(|_| (f(&nd[k], "x"), f(&nd[k], "y")))
}

/// A node list as straight segments: curves walked in twelve steps, finer than anything seen.
fn flatten(nodes: &[Value], closed: bool) -> Vec<P> {
    let mut out = Vec::new();
    let Some(first) = nodes.first() else { return out };
    let seg = |out: &mut Vec<P>, a: &Value, b: &Value| {
        let (ho, hi) = (handle(a, "ho"), handle(b, "hi"));
        if ho.is_none() && hi.is_none() {
            out.push((f(b, "x"), f(b, "y")));
            return;
        }
        let c1 = ho.unwrap_or((f(a, "x"), f(a, "y")));
        let c2 = hi.unwrap_or((f(b, "x"), f(b, "y")));
        let (a, b) = ((f(a, "x"), f(a, "y")), (f(b, "x"), f(b, "y")));
        for k in 1..=12 {
            let t = k as f64 / 12.0;
            let u = 1.0 - t;
            out.push((
                u * u * u * a.0 + 3.0 * u * u * t * c1.0 + 3.0 * u * t * t * c2.0 + t * t * t * b.0,
                u * u * u * a.1 + 3.0 * u * u * t * c1.1 + 3.0 * u * t * t * c2.1 + t * t * t * b.1,
            ));
        }
    };
    out.push((f(first, "x"), f(first, "y")));
    for i in 1..nodes.len() {
        seg(&mut out, &nodes[i - 1], &nodes[i]);
    }
    if closed && nodes.len() > 2 {
        seg(&mut out, &nodes[nodes.len() - 1], &nodes[0]);
    }
    out
}

fn rings_of(shape: &Value) -> Vec<Vec<P>> {
    let arr = |v: &Value| v.as_array().cloned().unwrap_or_default();
    let mut rings = vec![flatten(&arr(&shape["nodes"]), true)];
    for h in arr(&shape["holes"]) {
        rings.push(flatten(&arr(&h), true));
    }
    rings
}

/// Odd-even against every ring, the rule the renderer fills by: inside a hole is outside the shape.
fn inside_rings(x: f64, y: f64, rings: &[Vec<P>]) -> bool {
    rings.iter().filter(|r| point_in_poly(x, y, r)).count() % 2 == 1
}

/// What a piece keeps of its shape: everything but where it is.
fn like(shape: &Value, nodes: Value, holes: Option<Value>, closed: bool) -> Value {
    let mut out = json!({ "kind": "path", "c": shape["c"], "sw": shape["sw"], "closed": closed, "nodes": nodes });
    if shape["fill"].as_bool() == Some(true) && closed {
        out["fill"] = json!(true);
    }
    if let Some(r) = shape.get("rot").filter(|r| !r.is_null()) {
        out["rot"] = r.clone();
    }
    if let Some(h) = holes {
        out["holes"] = h;
    }
    out
}

const UNITS: usize = 24;
/// Cells to a grid unit: six is 144 across, a tenth of a unit, finer than the grid snaps.
const CELLS: usize = 6;
/// How far each half reaches past the cut, in cells, so the two overlap and no seam shows through.
const BLEED: usize = 2;

fn split_filled(shape: &Value, lasso: &[P]) -> Result<Cut, String> {
    let n = UNITS * CELLS;
    let s = CELLS as f64;
    let rings = rings_of(shape);
    let mut in_mask = vec![0f32; n * n];
    let mut out_mask = vec![0f32; n * n];
    let mut shape_mask = vec![false; n * n];
    let (mut any_in, mut any_out) = (false, false);
    for j in 0..n {
        for i in 0..n {
            // The cell's centre, so a boundary along a grid line isn't ambiguous.
            let (x, y) = ((i as f64 + 0.5) / s, (j as f64 + 0.5) / s);
            if !inside_rings(x, y, &rings) {
                continue;
            }
            let at = j * n + i;
            shape_mask[at] = true;
            if point_in_poly(x, y, lasso) {
                in_mask[at] = 255.0;
                any_in = true;
            } else {
                out_mask[at] = 255.0;
                any_out = true;
            }
        }
    }
    if !any_in {
        return Err("That lasso did not catch any of the shape.".into());
    }
    if !any_out {
        return Err("That lasso caught the whole shape — nothing to split off.".into());
    }
    // Each half grown into the other along the cut, but only into cells the shape covers.
    let grow = |mask: &mut Vec<f32>| {
        for _ in 0..BLEED {
            let prev = mask.clone();
            for y in 0..n {
                for x in 0..n {
                    let at = y * n + x;
                    if prev[at] > 0.0 || !shape_mask[at] {
                        continue;
                    }
                    if (x > 0 && prev[at - 1] > 0.0) || (x < n - 1 && prev[at + 1] > 0.0) || (y > 0 && prev[at - n] > 0.0) || (y < n - 1 && prev[at + n] > 0.0) {
                        mask[at] = 255.0;
                    }
                }
            }
        }
    };
    grow(&mut in_mask);
    grow(&mut out_mask);
    // A sliver deliberately lassoed off a logo is supposed to survive.
    let o = Opts { cells: s, min_area: 0.00005, ..Default::default() };
    let inside = trace(&in_mask, n as u32, n as u32, &o).map_err(|_| "Nothing came out of the lasso.".to_string())?;
    let outside = trace(&out_mask, n as u32, n as u32, &o).map_err(|_| "Nothing was left outside it.".to_string())?;
    let dress = |list: Vec<Value>| -> Vec<Value> { list.iter().map(|p| like(shape, p["nodes"].clone(), p.get("holes").cloned(), true)).collect() };
    Ok(Cut { inside: dress(inside), outside: dress(outside) })
}

fn split_outline(shape: &Value, lasso: &[P]) -> Result<Cut, String> {
    let nodes = shape["nodes"].as_array().cloned().unwrap_or_default();
    if nodes.len() < 2 {
        return Err("There is nothing to split.".into());
    }
    let flags: Vec<bool> = nodes.iter().map(|nd| point_in_poly(f(nd, "x"), f(nd, "y"), lasso)).collect();
    if !flags.iter().any(|b| *b) {
        return Err("That lasso did not catch any of the line.".into());
    }
    if flags.iter().all(|b| *b) {
        return Err("That lasso caught the whole line — nothing to split off.".into());
    }
    let closed = shape["closed"].as_bool() == Some(true);
    // Runs of consecutive nodes on one side; a closed path is walked round, so a run may wrap.
    let mut start = 0;
    if closed {
        while start < nodes.len() && flags[start] == flags[nodes.len() - 1] {
            start += 1;
        }
        if start >= nodes.len() {
            start = 0;
        }
    }
    let mut runs: Vec<(bool, Vec<Value>)> = Vec::new();
    for k in 0..nodes.len() {
        let at = (start + k) % nodes.len();
        if runs.last().map(|r| r.0) != Some(flags[at]) {
            runs.push((flags[at], Vec::new()));
        }
        runs.last_mut().expect("a run").1.push(nodes[at].clone());
    }
    // A run of one node draws nothing, so it joins its neighbour.
    let mut r = runs.len();
    while r > 1 {
        r -= 1;
        if runs[r].1.len() < 2 {
            let moved = runs.remove(r).1;
            runs[r - 1].1.extend(moved);
        }
    }
    let (mut inside, mut outside) = (Vec::new(), Vec::new());
    for (is_in, ns) in runs {
        if ns.len() < 2 {
            continue;
        }
        let piece = like(shape, Value::Array(ns), None, false);
        if is_in { inside.push(piece) } else { outside.push(piece) }
    }
    if inside.is_empty() || outside.is_empty() {
        return Err("There was not enough on one side of that lasso to split.".into());
    }
    Ok(Cut { inside, outside })
}

/// `shape` cut by `lasso` (grid units): what is inside it, and what is not.
pub fn split(shape: &Value, lasso: &[P]) -> Result<Cut, String> {
    if lasso.len() < 3 {
        return Err("Draw a region to split with.".into());
    }
    if shape["kind"] == "dot" {
        return Err("A dot cannot be split.".into());
    }
    let filled = shape["fill"].as_bool() == Some(true);
    if shape["kind"] != "path" && !filled {
        return Err("Only paths and filled shapes can be split — the pen tool makes paths out of anything.".into());
    }
    if filled && shape["closed"].as_bool() != Some(false) { split_filled(shape, lasso) } else { split_outline(shape, lasso) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn square() -> Value {
        let n = |x: f64, y: f64| json!({ "x": x, "y": y, "corner": true });
        json!({ "kind": "path", "c": "ink", "sw": 2, "closed": true, "fill": true, "nodes": [n(4.0, 4.0), n(20.0, 4.0), n(20.0, 20.0), n(4.0, 20.0)] })
    }

    #[test]
    fn a_filled_square_cut_in_half() {
        let lasso = [(0.0, 0.0), (12.0, 0.0), (12.0, 24.0), (0.0, 24.0)];
        let cut = split(&square(), &lasso).expect("a cut");
        assert_eq!(cut.inside.len(), 1);
        assert_eq!(cut.outside.len(), 1);
        // The left half stays on the left, within the bleed.
        let xs: Vec<f64> = cut.inside[0]["nodes"].as_array().unwrap().iter().map(|n| n["x"].as_f64().unwrap()).collect();
        assert!(xs.iter().all(|x| *x < 12.8 && *x > 3.5), "{xs:?}");
        let xs: Vec<f64> = cut.outside[0]["nodes"].as_array().unwrap().iter().map(|n| n["x"].as_f64().unwrap()).collect();
        assert!(xs.iter().all(|x| *x > 11.2 && *x < 20.5), "{xs:?}");
    }

    #[test]
    fn a_lasso_that_misses_or_takes_everything_says_so() {
        assert!(split(&square(), &[(0.0, 0.0), (2.0, 0.0), (2.0, 2.0)]).is_err());
        assert!(split(&square(), &[(0.0, 0.0), (24.0, 0.0), (24.0, 24.0), (0.0, 24.0)]).is_err());
    }

    #[test]
    fn an_outline_is_cut_between_its_nodes() {
        let n = |x: f64| json!({ "x": x, "y": 10.0, "corner": true });
        let line = json!({ "kind": "path", "c": "ink", "sw": 2, "closed": false, "nodes": [n(2.0), n(6.0), n(10.0), n(14.0), n(18.0)] });
        let cut = split(&line, &[(8.0, 0.0), (20.0, 0.0), (20.0, 20.0), (8.0, 20.0)]).expect("a cut");
        assert_eq!(cut.inside[0]["nodes"].as_array().unwrap().len(), 3);
        assert_eq!(cut.outside[0]["nodes"].as_array().unwrap().len(), 2);
    }
}
