//! Settings → Display → Arrangement (MonitorMap.qml): the screens on one
//! plane, to scale, dragged into the arrangement you have. While one is
//! dragged, where it would land: snapped flush against a neighbour, never
//! over another, never floating free. On release the position is saved
//! with the screen's entry and applied from it, so its colour settings go
//! with it (a monitor rule of just a position turns HDR and 10-bit off).

use crate::hypr;
use crate::rows::Ctx;
use crate::{MonBox, MonMap};
use serde_json::{json, Value};
use slint::{ComponentHandle, ModelRc, VecModel};

/// How close counts as touching, in logical pixels of the real desktop.
const SNAP: f64 = 80.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Mon {
    pub name: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

pub fn monitors() -> Vec<Mon> {
    hypr::json("monitors")
        .as_array()
        .into_iter()
        .flatten()
        .map(|m| {
            let s = m["scale"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0);
            Mon {
                name: m["name"].as_str().unwrap_or("").into(),
                x: m["x"].as_f64().unwrap_or(0.0),
                y: m["y"].as_f64().unwrap_or(0.0),
                w: m["width"].as_f64().unwrap_or(0.0) / s,
                h: m["height"].as_f64().unwrap_or(0.0) / s,
            }
        })
        .collect()
}

/// The plane, with room all round to drag a screen to any side.
pub fn bounds(ms: &[Mon]) -> (f64, f64, f64, f64) {
    if ms.is_empty() {
        return (0.0, 0.0, 1.0, 1.0);
    }
    let x0 = ms.iter().map(|m| m.x).fold(f64::MAX, f64::min);
    let y0 = ms.iter().map(|m| m.y).fold(f64::MAX, f64::min);
    let x1 = ms.iter().map(|m| m.x + m.w).fold(f64::MIN, f64::max);
    let y1 = ms.iter().map(|m| m.y + m.h).fold(f64::MIN, f64::max);
    let (px, py) = ((x1 - x0) * 0.35 + 300.0, (y1 - y0) * 0.35 + 300.0);
    (x0 - px, y0 - py, (x1 - x0) + px * 2.0, (y1 - y0) + py * 2.0)
}

/// Flush against a neighbour on whichever axis is closest, and aligned on
/// the other if it is near enough to have been meant.
fn snap_to(ms: &[Mon], name: &str, x: f64, y: f64, w: f64, h: f64) -> (f64, f64) {
    let (mut bx, mut by, mut best_x, mut best_y) = (x, y, SNAP, SNAP);
    for o in ms.iter().filter(|o| o.name != name) {
        for c in [o.x + o.w, o.x - w, o.x, o.x + o.w - w, o.x + (o.w - w) / 2.0] {
            if (c - x).abs() < best_x {
                best_x = (c - x).abs();
                bx = c;
            }
        }
        for c in [o.y + o.h, o.y - h, o.y, o.y + o.h - h, o.y + (o.h - h) / 2.0] {
            if (c - y).abs() < best_y {
                best_y = (c - y).abs();
                by = c;
            }
        }
    }
    (bx, by)
}

fn overlaps<'a>(ms: &'a [Mon], name: &str, x: f64, y: f64, w: f64, h: f64) -> Option<&'a Mon> {
    ms.iter().find(|o| o.name != name && x < o.x + o.w && x + w > o.x && y < o.y + o.h && y + h > o.y)
}

/// Never on top of another screen: moved the least way out of any it
/// overlaps, to lie against it. And never floating free: one with no
/// neighbour touching is pulled in against the nearest.
fn clear(ms: &[Mon], name: &str, mut x: f64, mut y: f64, w: f64, h: f64) -> (f64, f64) {
    for _ in 0..6 {
        let Some(o) = overlaps(ms, name, x, y, w, h) else { break };
        let mut ways = [(o.x - w, y), (o.x + o.w, y), (x, o.y - h), (x, o.y + o.h)];
        ways.sort_by(|a, b| ((a.0 - x).abs() + (a.1 - y).abs()).total_cmp(&((b.0 - x).abs() + (b.1 - y).abs())));
        (x, y) = ways[0];
    }
    let others: Vec<&Mon> = ms.iter().filter(|o| o.name != name).collect();
    if others.is_empty() {
        return (x, y);
    }
    let touches = others.iter().any(|o| {
        let xt = ((x + w - o.x).abs() < 1.0 || (o.x + o.w - x).abs() < 1.0) && y < o.y + o.h && y + h > o.y;
        let yt = ((y + h - o.y).abs() < 1.0 || (o.y + o.h - y).abs() < 1.0) && x < o.x + o.w && x + w > o.x;
        xt || yt
    });
    if touches {
        return (x, y);
    }
    // The nearest side of the nearest screen, keeping the other axis
    // within its span.
    let mut best: Option<(f64, f64)> = None;
    let mut best_d = f64::MAX;
    for o in others {
        let cy = (o.y.min(o.y + o.h - h)).max(y.min(o.y.max(o.y + o.h - h)));
        let cx = (o.x.min(o.x + o.w - w)).max(x.min(o.x.max(o.x + o.w - w)));
        for c in [(o.x - w, cy), (o.x + o.w, cy), (cx, o.y - h), (cx, o.y + o.h)] {
            if overlaps(ms, name, c.0, c.1, w, h).is_some() {
                continue;
            }
            let d = (c.0 - x).hypot(c.1 - y);
            if d < best_d {
                best_d = d;
                best = Some(c);
            }
        }
    }
    best.unwrap_or((x, y))
}

/// Where a screen dragged to (x, y) lands.
pub fn landing(ms: &[Mon], name: &str, x: f64, y: f64) -> Option<(f64, f64, f64, f64)> {
    let m = ms.iter().find(|m| m.name == name)?;
    let (sx, sy) = snap_to(ms, name, x, y, m.w, m.h);
    let (cx, cy) = clear(ms, name, sx, sy, m.w, m.h);
    Some((cx.round(), cy.round(), m.w, m.h))
}

/// The map into the window.
pub fn publish(ui: &crate::AppWindow, c: &Ctx, selected: &str) {
    let ms = monitors();
    let raw: Vec<Value> = hypr::json("monitors").as_array().cloned().unwrap_or_default();
    let main = crate::display::main_display(c, &raw);
    let g = ui.global::<MonMap>();
    let (bx, by, bw, bh) = bounds(&ms);
    g.set_bx(bx as f32);
    g.set_by(by as f32);
    g.set_bw(bw as f32);
    g.set_bh(bh as f32);
    g.set_selected(selected.into());
    g.set_monitors(ModelRc::new(VecModel::from(
        ms.iter()
            .map(|m| MonBox { name: m.name.clone().into(), x: m.x as f32, y: m.y as f32, w: m.w as f32, h: m.h as f32, main: m.name == main })
            .collect::<Vec<_>>(),
    )));
}

/// Saved with the screen's entry, then applied from it.
pub fn place(c: &mut Ctx, name: &str, x: f64, y: f64) {
    hypr::save_display(&mut c.p, name, json!({ "position": format!("{}x{}", x.round() as i64, y.round() as i64) }));
    hypr::apply_display(&c.p, name);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(name: &str, x: f64, y: f64, w: f64, h: f64) -> Mon {
        Mon { name: name.into(), x, y, w, h }
    }

    #[test]
    fn lands_flush_and_clear() {
        let ms = vec![m("eDP-1", 0.0, 0.0, 1536.0, 960.0), m("DP-1", 1536.0, 0.0, 1920.0, 1080.0)];
        // Dragged a little short of the laptop's right edge: snapped flush.
        assert_eq!(landing(&ms, "DP-1", 1500.0, 30.0).map(|l| (l.0, l.1)), Some((1536.0, 0.0)));
        // Dropped on top of it: out the least way, against it.
        let l = landing(&ms, "DP-1", 300.0, 200.0).unwrap();
        assert!(overlaps(&ms, "DP-1", l.0, l.1, l.2, l.3).is_none());
        // Far off: pulled in against the nearest.
        let l = landing(&ms, "DP-1", 6000.0, 4000.0).unwrap();
        assert!(l.0 <= 1536.0 + 1.0 && l.1 <= 960.0 + 1.0);
    }
}
