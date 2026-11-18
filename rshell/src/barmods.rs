//! The top bar as modules: which are on it, on which side, in what order.
//!
//! Each side is a list of module ids. The built-in ones are named here; a
//! plugin (plugins.rs) is `plugin:<name>`. theme.json holds the choice:
//!
//!   barLeft, barRight   the ids in order (absent: the usual)
//!   barHidden           ids taken off the bar
//!
//! A built-in that is in neither list (one added by a newer shell) goes on
//! its usual side; a plugin found in the plugins folder that is in neither
//! list (and not hidden) goes at the start of the right side, so it shows
//! up without being asked. A module in both lists stays where it first is.

use serde_json::Value;

pub const LEFT: &[&str] = &["workspaces", "app", "window", "appmenus"];
pub const RIGHT: &[&str] = &["tray", "privacy", "timers", "updates", "mail", "drives", "notifications", "status", "clock", "power"];

/// What a built-in module is called in Settings.
pub fn name(id: &str) -> &'static str {
    match id {
        "workspaces" => "Workspaces",
        "app" => "App name",
        "window" => "Window menu",
        "appmenus" => "The app's own menus (File, Edit…)",
        "tray" => "Tray",
        "privacy" => "Privacy indicators",
        "timers" => "Timers",
        "updates" => "Updates",
        "mail" => "Mail",
        "drives" => "Drives",
        "notifications" => "Notifications",
        "status" => "Network, sound and battery (control center)",
        "clock" => "Clock and date",
        "power" => "Power",
        _ => "",
    }
}

/// A short name, for a chip while the bar is edited.
pub fn short(id: &str) -> &'static str {
    match id {
        "workspaces" => "Workspaces",
        "app" => "App name",
        "window" => "Window",
        "appmenus" => "App menus",
        "tray" => "Tray",
        "privacy" => "Privacy",
        "timers" => "Timers",
        "updates" => "Updates",
        "mail" => "Mail",
        "drives" => "Drives",
        "notifications" => "Alerts",
        "status" => "Control",
        "clock" => "Clock",
        "power" => "Power",
        _ => "",
    }
}

pub fn is_builtin(id: &str) -> bool {
    LEFT.contains(&id) || RIGHT.contains(&id)
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Layout {
    pub left: Vec<String>,
    pub right: Vec<String>,
    /// Taken off the bar by choice.
    pub hidden: Vec<String>,
}

fn list(v: &Value) -> Option<Vec<String>> {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_str()).map(String::from).collect())
}

/// The bar's layout from theme.json and the plugins found (`plugin:<name>`).
pub fn layout(raw: &Value, plugins: &[String]) -> Layout {
    let hidden = list(&raw["barHidden"]).unwrap_or_default();
    let mut left = list(&raw["barLeft"]).unwrap_or_else(|| LEFT.iter().map(|s| s.to_string()).collect());
    let mut right = list(&raw["barRight"]).unwrap_or_else(|| RIGHT.iter().map(|s| s.to_string()).collect());
    let known = |id: &String| is_builtin(id) || plugins.contains(id);
    left.retain(known);
    right.retain(known);
    // Once only, the first place it is given.
    let mut seen: Vec<String> = Vec::new();
    for side in [&mut left, &mut right] {
        side.retain(|id| {
            if seen.contains(id) {
                false
            } else {
                seen.push(id.clone());
                true
            }
        });
    }
    // What is on neither list goes where it usually does.
    for id in LEFT {
        if !seen.iter().any(|s| s == id) {
            left.push(id.to_string());
            seen.push(id.to_string());
        }
    }
    for id in RIGHT {
        if !seen.iter().any(|s| s == id) {
            // Before the clock and what follows it, so a new one doesn't push the clock about.
            let at = right.iter().position(|r| r == "notifications" || r == "status" || r == "clock").unwrap_or(right.len());
            right.insert(at, id.to_string());
            seen.push(id.to_string());
        }
    }
    let mut fresh: Vec<String> = plugins.iter().filter(|p| !seen.contains(p)).cloned().collect();
    fresh.extend(right);
    let right = fresh;
    left.retain(|id| !hidden.contains(id));
    let right: Vec<String> = right.into_iter().filter(|id| !hidden.contains(id)).collect();
    Layout { left, right, hidden: hidden.into_iter().filter(|h| is_builtin(h) || plugins.contains(h)).collect() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn the_usual_layout_is_what_the_bar_had() {
        let l = layout(&Value::Null, &[]);
        assert_eq!(l.left, LEFT);
        assert_eq!(l.right, RIGHT);
    }

    #[test]
    fn order_and_hiding_are_followed_and_nothing_is_lost_or_doubled() {
        let raw = json!({ "barLeft": ["clock", "workspaces", "workspaces", "nonsense"], "barRight": ["power", "tray"], "barHidden": ["mail"] });
        let l = layout(&raw, &[]);
        assert_eq!(l.left[..2], v(&["clock", "workspaces"]));
        // What was left out of both lists goes back on its usual side.
        assert!(l.left.contains(&"app".to_string()) && l.right.contains(&"notifications".to_string()));
        assert!(!l.right.contains(&"mail".to_string()) && !l.left.contains(&"mail".to_string()));
        assert_eq!(l.hidden, ["mail"]);
        let all: Vec<&String> = l.left.iter().chain(l.right.iter()).collect();
        assert_eq!(all.len(), all.iter().collect::<std::collections::HashSet<_>>().len());
        // Power stays first on the right as it was put.
        assert_eq!(l.right[0], "power");
    }

    #[test]
    fn a_plugin_shows_up_at_the_start_of_the_right_side_until_it_is_placed_or_hidden() {
        let p = v(&["plugin:cpu", "plugin:gone"]);
        let l = layout(&Value::Null, &p[..1]);
        assert_eq!(l.right[0], "plugin:cpu");
        // Placed on the left by choice.
        let l = layout(&json!({ "barLeft": ["workspaces", "plugin:cpu"] }), &p[..1]);
        assert!(l.left.contains(&"plugin:cpu".to_string()) && !l.right.contains(&"plugin:cpu".to_string()));
        // Hidden.
        assert!(!layout(&json!({ "barHidden": ["plugin:cpu"] }), &p[..1]).right.contains(&"plugin:cpu".to_string()));
        // A plugin that is no longer there is dropped.
        assert!(!layout(&json!({ "barRight": ["plugin:gone"] }), &p[..1]).right.contains(&"plugin:gone".to_string()));
    }
}

#[cfg(test)]
mod name_tests {
    use super::*;

    #[test]
    fn every_built_in_module_has_a_name_and_a_short_one() {
        for id in LEFT.iter().chain(RIGHT.iter()) {
            assert!(!name(id).is_empty() && !short(id).is_empty(), "{id}");
            assert!(short(id).chars().count() <= 10, "{id}'s chip name is too long for its chip");
        }
    }
}

// ── editing the bar where it is: where each module sits, and where a drop goes ──

use std::collections::HashMap;

/// A module that is on the bar now, and where.
#[derive(Clone, Debug, PartialEq)]
pub struct Slot {
    pub id: String,
    pub x: f32,
    pub w: f32,
}

/// The gap between modules on each side (the bar's own spacing).
pub const GAP_LEFT: f32 = 10.0;
pub const GAP_RIGHT: f32 = 2.0;
/// Space between the bar's edge and the first module.
pub const MARGIN: f32 = 10.0;

/// Where the modules of a side sit, from their widths (as the bar reports
/// them): the left from the left edge, the right from the right edge.
pub fn slots(ids: &[String], widths: &HashMap<String, f32>, bar_w: f32, right: bool) -> Vec<Slot> {
    let w = |id: &String| widths.get(id).copied().unwrap_or(0.0);
    if right {
        let total: f32 = ids.iter().map(w).sum::<f32>() + GAP_RIGHT * ids.len().saturating_sub(1) as f32;
        let mut x = bar_w - MARGIN - total;
        ids.iter()
            .map(|id| {
                let s = Slot { id: id.clone(), x, w: w(id) };
                x += w(id) + GAP_RIGHT;
                s
            })
            .collect()
    } else {
        let mut x = MARGIN;
        ids.iter()
            .map(|id| {
                let s = Slot { id: id.clone(), x, w: w(id) };
                x += w(id) + GAP_LEFT;
                s
            })
            .collect()
    }
}

/// The slot under `x`, if any.
pub fn hit(slots: &[Slot], x: f32) -> Option<usize> {
    slots.iter().position(|s| x >= s.x && x < s.x + s.w)
}

/// Where a module dropped at `x` goes among these: before the first whose
/// middle is past it, else at the end.
pub fn index_for(slots: &[Slot], x: f32) -> usize {
    slots.iter().position(|s| x < s.x + s.w / 2.0).unwrap_or(slots.len())
}

/// Which side a pointer at `x` is on: the left cluster's end and the right
/// cluster's start have the middle between them.
pub fn is_left(left: &[Slot], right: &[Slot], bar_w: f32, x: f32) -> bool {
    let l_end = left.last().map(|s| s.x + s.w).unwrap_or(MARGIN);
    let r_start = right.first().map(|s| s.x).unwrap_or(bar_w - MARGIN);
    x < (l_end + r_start) / 2.0
}

/// Where the drop line goes for index `j` among `slots` on a side.
pub fn hint_x(slots: &[Slot], j: usize, bar_w: f32, right: bool) -> f32 {
    match (slots.get(j), j.checked_sub(1).and_then(|p| slots.get(p))) {
        (Some(next), Some(prev)) => (prev.x + prev.w + next.x) / 2.0,
        (Some(next), None) => next.x - 4.0,
        (None, Some(prev)) => prev.x + prev.w + 4.0,
        (None, None) => if right { bar_w - MARGIN } else { MARGIN },
    }
}

/// Put `id` in a side's full list so that it lands at index `j` among the
/// modules on show (`present`): before the one now at `j`, else after the last
/// of them. The full list also holds modules with nothing to show right now.
pub fn insert_at(full: &mut Vec<String>, present: &[Slot], j: usize, id: &str) {
    full.retain(|x| x != id);
    // `j` was counted with the module still in place: with it gone, a drop
    // past where it was is one slot earlier.
    let j = match present.iter().position(|s| s.id == id) {
        Some(p) if p < j => j - 1,
        _ => j,
    };
    let present: Vec<&Slot> = present.iter().filter(|s| s.id != id).collect();
    let j = j.min(present.len());
    let at = match present.get(j) {
        Some(next) => full.iter().position(|x| *x == next.id).unwrap_or(full.len()),
        None => match present.last() {
            Some(last) => full.iter().position(|x| *x == last.id).map(|p| p + 1).unwrap_or(full.len()),
            None => full.len(),
        },
    };
    full.insert(at.min(full.len()), id.to_string());
}

#[cfg(test)]
mod geometry_tests {
    use super::*;

    fn w(pairs: &[(&str, f32)]) -> HashMap<String, f32> {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }
    fn ids(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn slots_follow_the_bars_own_layout_from_each_edge() {
        let widths = w(&[("a", 100.0), ("b", 50.0), ("c", 40.0), ("d", 60.0)]);
        let l = slots(&ids(&["a", "b"]), &widths, 1000.0, false);
        assert_eq!((l[0].x, l[1].x), (10.0, 120.0)); // 10 + 100 + 10
        let r = slots(&ids(&["c", "d"]), &widths, 1000.0, true);
        assert_eq!((r[1].x + r[1].w, r[0].x), (990.0, 990.0 - 60.0 - 2.0 - 40.0));
    }

    #[test]
    fn a_pointer_finds_its_slot_its_drop_index_and_its_side() {
        let widths = w(&[("a", 100.0), ("b", 50.0), ("c", 40.0)]);
        let l = slots(&ids(&["a", "b"]), &widths, 1000.0, false);
        let r = slots(&ids(&["c"]), &widths, 1000.0, true);
        assert_eq!(hit(&l, 50.0), Some(0));
        assert_eq!(hit(&l, 115.0), None); // in the gap
        assert_eq!(index_for(&l, 20.0), 0); // before a's middle
        assert_eq!(index_for(&l, 70.0), 1); // past a's middle
        assert_eq!(index_for(&l, 130.0), 1); // b spans 120-170: before its middle (145)
        assert_eq!(index_for(&l, 150.0), 2); // past it
        assert!(is_left(&l, &r, 1000.0, 400.0));
        assert!(!is_left(&l, &r, 1000.0, 900.0));
        // The line goes between neighbours, or just outside the ends.
        assert_eq!(hint_x(&l, 1, 1000.0, false), 115.0);
        assert_eq!(hint_x(&l, 0, 1000.0, false), 6.0);
        assert_eq!(hint_x(&l, 2, 1000.0, false), 174.0);
    }

    #[test]
    fn a_drop_lands_among_the_modules_on_show_even_with_unseen_ones_between() {
        // "timers" is in the layout but has nothing to show now.
        let mut full = ids(&["tray", "timers", "mail", "clock"]);
        let present = vec![Slot { id: "tray".into(), x: 0.0, w: 10.0 }, Slot { id: "mail".into(), x: 20.0, w: 10.0 }, Slot { id: "clock".into(), x: 40.0, w: 10.0 }];
        // Clock to the front of the mail.
        insert_at(&mut full, &present, 1, "clock");
        assert_eq!(full, ids(&["tray", "timers", "clock", "mail"]));
        // A new one at the very end, and at the very start.
        let mut f2 = ids(&["tray", "timers", "mail"]);
        insert_at(&mut f2, &present[..2], 2, "power");
        assert_eq!(f2, ids(&["tray", "timers", "mail", "power"]));
        insert_at(&mut f2, &present[..2], 0, "x");
        assert_eq!(f2, ids(&["x", "tray", "timers", "mail", "power"]));
        // Dropped where it already is: nothing changes.
        let mut f3 = ids(&["tray", "mail"]);
        insert_at(&mut f3, &present[..2], 1, "mail");
        assert_eq!(f3, ids(&["tray", "mail"]));
    }
}
