//! Settings → Notifications' two panels (services/Focus.qml):
//! FocusPanel.qml, quiet hours on a schedule, and NotifAppsPanel.qml, how
//! each app that has sent a notification may interrupt.

use crate::prefs::Prefs;
use crate::{FocusLook, FocusSch, NotifApp};
use serde_json::{json, Value};
use slint::{ComponentHandle, Image, ModelRc, VecModel};
use std::collections::HashMap;
use std::path::PathBuf;

fn parse(text: &str, fallback: Value) -> Value {
    serde_json::from_str::<Value>(text).ok().filter(|v| !v.is_null()).unwrap_or(fallback)
}
pub fn schedules(p: &Prefs) -> Vec<Value> {
    parse(&p.s("focusSchedules"), json!([])).as_array().cloned().unwrap_or_default()
}
fn rules(p: &Prefs) -> serde_json::Map<String, Value> {
    parse(&p.s("notifRules"), json!({})).as_object().cloned().unwrap_or_default()
}
fn apps(p: &Prefs) -> Vec<String> {
    parse(&p.s("notifApps"), json!([])).as_array().into_iter().flatten().filter_map(|v| v.as_str().map(str::to_string)).collect()
}
pub fn rule(p: &Prefs, app: &str) -> String {
    rules(p).get(app).and_then(|v| v.as_str()).unwrap_or("normal").to_string()
}

/// Focus.minutes: "22:30" → 1350.
pub fn minutes(hhmm: &str) -> i64 {
    let mut it = hhmm.trim().split(':');
    let h = it.next().and_then(|x| x.parse::<i64>().ok());
    let m = it.next().and_then(|x| (x.len() == 2).then(|| x.parse::<i64>().ok()).flatten());
    match (h, m) {
        (Some(h), Some(m)) => h.min(23) * 60 + m.min(59),
        _ => 0,
    }
}
fn two(n: i64) -> String {
    format!("{n:02}")
}
/// Focus.hm: a time of day as the clock shows it.
fn hm(p: &Prefs, mins: i64) -> String {
    let (h, m) = (mins.rem_euclid(1440) / 60, mins.rem_euclid(60));
    if p.b("clock24") {
        format!("{}:{}", two(h), two(m))
    } else {
        format!("{}:{} {}", if h % 12 == 0 { 12 } else { h % 12 }, two(m), if h < 12 { "AM" } else { "PM" })
    }
}

/// Focus.current: the schedule running now and when it ends, in minutes
/// from today's midnight (windows that cross midnight checked from
/// yesterday's start too).
fn current(p: &Prefs) -> Option<(Value, i64)> {
    let (_, _, _, hh, mm, wd) = hyprshell_kit::local(hyprshell_kit::now());
    let now = (hh * 60 + mm) as i64;
    for s in schedules(p) {
        if s["on"] != true {
            continue;
        }
        let (from, to) = (minutes(s["from"].as_str().unwrap_or("")), minutes(s["to"].as_str().unwrap_or("")));
        let len = match (to - from).rem_euclid(1440) {
            0 => 1440,
            l => l,
        };
        let days: Vec<i64> = s["days"].as_array().into_iter().flatten().filter_map(|d| d.as_i64()).collect();
        for back in [0i64, 1] {
            let day = (wd as i64 - back).rem_euclid(7);
            if !days.is_empty() && !days.contains(&day) {
                continue;
            }
            let start = -back * 1440 + from;
            if now >= start && now < start + len {
                return Some((s.clone(), start + len));
            }
        }
    }
    None
}

/// The line over the schedules: quiet now, and why.
fn now_line(p: &Prefs) -> (String, bool) {
    if p.b("dnd") {
        return ("Quiet now: Do not disturb.".into(), true);
    }
    match current(p) {
        Some((s, end)) => {
            let name = s["name"].as_str().filter(|n| !n.is_empty()).unwrap_or("Focus");
            (format!("Quiet now: {name} until {}.", hm(p, end)), true)
        }
        None => ("Not quiet now.".into(), false),
    }
}

// ── an app's own icon, from its desktop entry ─────────────────────────
#[derive(Default)]
pub struct Icons {
    /// Desktop entries: (lower-case name, lower-case id, Icon=).
    entries: Option<Vec<(String, String, String)>>,
    loaded: HashMap<String, Option<Image>>,
}

fn data_dirs() -> Vec<PathBuf> {
    let data = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| hyprshell_kit::home().join(".local/share"));
    let mut dirs = vec![data];
    let sys = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    dirs.extend(sys.split(':').filter(|d| !d.is_empty()).map(PathBuf::from));
    dirs
}

impl Icons {
    fn entries(&mut self) -> &Vec<(String, String, String)> {
        self.entries.get_or_insert_with(|| {
            let mut out = vec![];
            for d in data_dirs() {
                let Ok(rd) = std::fs::read_dir(d.join("applications")) else { continue };
                for e in rd.flatten() {
                    let path = e.path();
                    let Some(id) = path.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_suffix(".desktop")).map(str::to_lowercase) else { continue };
                    let Ok(t) = std::fs::read_to_string(&path) else { continue };
                    let (mut name, mut icon, mut main) = (String::new(), String::new(), false);
                    for l in t.lines() {
                        let l = l.trim();
                        if l.starts_with('[') {
                            main = l == "[Desktop Entry]";
                            continue;
                        }
                        if !main {
                            continue;
                        }
                        if let Some(v) = l.strip_prefix("Name=") {
                            name = v.to_lowercase();
                        } else if let Some(v) = l.strip_prefix("Icon=") {
                            icon = v.to_string();
                        }
                    }
                    out.push((name, id, icon));
                }
            }
            out
        })
    }

    /// NotifAppsPanel.entryFor: by name, else by id (or its last part).
    pub fn for_app(&mut self, app: &str) -> Option<Image> {
        if let Some(hit) = self.loaded.get(app) {
            return hit.clone();
        }
        let low = app.to_lowercase();
        let es = self.entries();
        let icon = es
            .iter()
            .find(|e| e.0 == low)
            .or_else(|| es.iter().find(|e| e.1 == low || e.1.ends_with(&format!(".{low}"))))
            .map(|e| e.2.clone())
            .filter(|i| !i.is_empty());
        let img = icon
            .and_then(|i| hyprshell_kit::themeicons::find(&i, 60, None))
            .and_then(|path| Image::load_from_path(&path).ok());
        self.loaded.insert(app.to_string(), img.clone());
        img
    }
}

/// Both panels into the window.
pub fn publish(ui: &crate::AppWindow, p: &Prefs, icons: &mut Icons) {
    let g = ui.global::<FocusLook>();
    let (line, quiet) = now_line(p);
    g.set_now_line(line.into());
    g.set_quiet(quiet);
    let list: Vec<FocusSch> = schedules(p)
        .iter()
        .map(|s| {
            let days: Vec<i64> = s["days"].as_array().into_iter().flatten().filter_map(|d| d.as_i64()).collect();
            FocusSch {
                id: s["id"].as_i64().unwrap_or(0) as i32,
                name: s["name"].as_str().unwrap_or("").into(),
                on: s["on"] == true,
                from: s["from"].as_str().unwrap_or("00:00").into(),
                to: s["to"].as_str().unwrap_or("00:00").into(),
                // Monday first, as the chips are.
                days: ModelRc::new(VecModel::from((0..7).map(|i| days.contains(&((i + 1) % 7))).collect::<Vec<bool>>())),
            }
        })
        .collect();
    g.set_schedules(ModelRc::new(VecModel::from(list)));
    let apps: Vec<NotifApp> = apps(p)
        .iter()
        .map(|a| {
            let r = rule(p, a);
            let allowed = r != "block" && r != "mute";
            let icon = icons.for_app(a);
            NotifApp {
                name: a.clone().into(),
                rule: r.clone().into(),
                allowed,
                sub: if !allowed {
                    "Blocked"
                } else if r == "always" {
                    "Banners even during Do not disturb"
                } else if r == "silent" {
                    "In the center, without a banner"
                } else {
                    "Banners and the center"
                }
                .into(),
                has_icon: icon.is_some(),
                icon: icon.unwrap_or_default(),
                initial: a.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default().into(),
            }
        })
        .collect();
    g.set_apps(ModelRc::new(VecModel::from(apps)));
}

// ── changes (Focus.qml's) ───────────────────────────────────────────────
fn save(list: Vec<Value>) -> (&'static str, Value) {
    ("focusSchedules", json!(Value::Array(list).to_string()))
}
pub fn add(p: &Prefs) -> (&'static str, Value) {
    let mut list = schedules(p);
    let id = list.iter().filter_map(|s| s["id"].as_i64()).max().unwrap_or(0) + 1;
    list.push(json!({ "id": id, "name": "Night", "from": "22:00", "to": "07:00", "days": [0, 1, 2, 3, 4, 5, 6], "on": true }));
    save(list)
}
pub fn update(p: &Prefs, id: i32, change: impl Fn(&mut serde_json::Map<String, Value>)) -> (&'static str, Value) {
    save(
        schedules(p)
            .into_iter()
            .map(|mut s| {
                if s["id"].as_i64() == Some(id as i64) {
                    if let Some(o) = s.as_object_mut() {
                        change(o);
                    }
                }
                s
            })
            .collect(),
    )
}
pub fn remove(p: &Prefs, id: i32) -> (&'static str, Value) {
    save(schedules(p).into_iter().filter(|s| s["id"].as_i64() != Some(id as i64)).collect())
}
/// TimeStep.bump: a quarter of an hour a step.
pub fn bump(hhmm: &str, dir: i32) -> String {
    let m = (minutes(hhmm) + dir as i64 * 15 + 1440).rem_euclid(1440);
    format!("{}:{}", two(m / 60), two(m % 60))
}
pub fn set_rule(p: &Prefs, app: &str, r: &str) -> (&'static str, Value) {
    let mut next = rules(p);
    if r == "normal" {
        next.remove(app);
    } else {
        next.insert(app.into(), json!(r));
    }
    ("notifRules", json!(Value::Object(next).to_string()))
}
pub fn forget(p: &Prefs, app: &str) -> Vec<(&'static str, Value)> {
    let list: Vec<String> = apps(p).into_iter().filter(|a| a != app).collect();
    vec![("notifApps", json!(json!(list).to_string())), set_rule(p, app, "normal")]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times() {
        assert_eq!(minutes("22:30"), 1350);
        assert_eq!(minutes("7:05"), 425);
        assert_eq!(minutes("nope"), 0);
        assert_eq!(bump("23:50", 1), "00:05");
        assert_eq!(bump("00:00", -1), "23:45");
    }
}
