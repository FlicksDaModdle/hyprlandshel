//! Settings → Display, as Settings.qml's "Display" case and the parts of
//! services/Devices.qml it calls: one display at a time, its mode, rate,
//! scale and colour (HDR, depth, range, calibration), the main display,
//! the lid, the shell's size on it, the idle timers and what applies to
//! every screen. Changes that can leave a screen dark are on trial: kept
//! only if you say so within 15 seconds (Devices.tryDisplay).

use crate::hypr;
use crate::rows::*;
use serde_json::{json, Map, Value};
use std::time::{Duration, Instant};

/// A change on trial: what to go back to.
pub struct Trial {
    pub name: String,
    pub before: Value,
    pub had: Value,
    pub until: Instant,
}

fn live(name: &str) -> Option<Value> {
    hypr::json("monitors").as_array().and_then(|a| a.iter().find(|m| m["name"] == name).cloned())
}

/// Devices.tryDisplay: saved and applied, with the way back kept.
pub fn try_display(c: &mut Ctx, name: &str, patch: Value) {
    if c.ui.trial.as_ref().map(|t| t.name.as_str()) != Some(name) {
        if c.ui.trial.is_some() {
            c.ui.trial = None;
        }
        let m = live(name).unwrap_or(json!({}));
        let had = hypr::display_map(&c.p).get(name).cloned().unwrap_or(json!({}));
        let mut before = json!({
            "mode": format!("{}x{}@{}", m["width"].as_i64().unwrap_or(0), m["height"].as_i64().unwrap_or(0),
                            (m["refreshRate"].as_f64().unwrap_or(60.0) * 1000.0).round() / 1000.0),
            "scale": m["scale"].as_f64().unwrap_or(1.0),
            "cm": m["colorManagementPreset"].as_str().unwrap_or("srgb"),
            "bitdepth": if m["currentFormat"].as_str().unwrap_or("").contains("2101010") { 10 } else { 8 },
        });
        if let (Some(b), Some(h)) = (before.as_object_mut(), had.as_object()) {
            for (k, v) in h {
                b.insert(k.clone(), v.clone());
            }
        }
        c.ui.trial = Some(Trial { name: name.into(), before, had, until: Instant::now() });
    }
    if let Some(t) = &mut c.ui.trial {
        t.until = Instant::now() + Duration::from_secs(15);
    }
    hypr::save_display(&mut c.p, name, patch);
    hypr::apply_display(&c.p, name);
}

pub fn keep_trial(c: &mut Ctx) {
    c.ui.trial = None;
}

/// Devices.revertTrial: applied in full as it was, then the entry put back
/// to what it held, no more.
pub fn revert_trial(c: &mut Ctx) {
    let Some(t) = c.ui.trial.take() else { return };
    let mut map = hypr::display_map(&c.p);
    map.insert(t.name.clone(), t.before);
    c.set("displays", json!(serde_json::to_string(&Value::Object(map)).unwrap_or_default()));
    hypr::apply_display(&c.p, &t.name);
    let mut after = hypr::display_map(&c.p);
    if t.had.as_object().is_none_or(|o| o.is_empty()) {
        after.remove(&t.name);
    } else {
        after.insert(t.name.clone(), t.had);
    }
    c.set("displays", json!(serde_json::to_string(&Value::Object(after)).unwrap_or_default()));
}

/// Devices.rememberColour: saved and applied, not a trial.
fn remember_colour(c: &mut Ctx, name: &str, patch: Value) {
    hypr::save_display(&mut c.p, name, patch);
    hypr::apply_display(&c.p, name);
}

/// scripts/edid-caps.py: what each panel says it can do.
pub fn edid_caps() -> Map<String, Value> {
    let script = hyprshell_kit::config_dir().join("quickshell/hyprshell/scripts/edid-caps.py");
    std::process::Command::new("python3")
        .arg(script)
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

fn set_hdr(c: &mut Ctx, name: &str, on: bool, anyway: bool, caps: &Value) {
    if !on {
        if c.ui.trial.as_ref().is_some_and(|t| t.name == name) {
            keep_trial(c);
        }
        remember_colour(c, name, json!({ "cm": "srgb" }));
        return;
    }
    let mut patch = json!({ "bitdepth": 10, "cm": "hdr" });
    let pq = caps["pq"] == true;
    let bt = caps["bt2020"] == true;
    let did = caps["via"] == "displayid";
    if anyway || did || (pq && !bt) {
        patch["supports_wide_color"] = json!(1);
        patch["supports_hdr"] = json!(1);
        let had = hypr::display_map(&c.p).get(name).cloned().unwrap_or(json!({}));
        for (k, from) in [("max_luminance", "maxLum"), ("max_avg_luminance", "maxAvgLum")] {
            if caps[from].as_f64().unwrap_or(0.0) > 0.0 && had.get(k).is_none() {
                patch[k] = json!(caps[from].as_f64().unwrap_or(0.0).round() as i64);
            }
        }
        if caps["minLum"].as_f64().unwrap_or(0.0) > 0.0 && had.get("min_luminance").is_none() {
            patch["min_luminance"] = caps["minLum"].clone();
        }
    }
    let claims = pq || bt || did;
    if anyway && !claims {
        try_display(c, name, patch);
    } else {
        if c.ui.trial.as_ref().is_some_and(|t| t.name == name) {
            keep_trial(c);
        }
        remember_colour(c, name, patch);
    }
}

/// Devices.calibrateHdr's quick set-up.
fn calibrate_hdr(c: &mut Ctx, name: &str, caps: &Value) {
    let min = caps["minLum"].as_f64();
    let oled = min.is_some_and(|m| m > 0.0 && m < 0.05);
    let mut patch = json!({
        "sdr_eotf": "gamma22",
        "sdr_min_luminance": if oled || min.is_none() { 0.005 } else { ((min.unwrap() * 1000.0).round() / 1000.0).max(0.005) },
        "sdr_max_luminance": 203,
        "sdrbrightness": 1,
    });
    if caps["maxLum"].as_f64().unwrap_or(0.0) > 0.0 {
        patch["max_luminance"] = json!(caps["maxLum"].as_f64().unwrap_or(0.0).round() as i64);
    }
    if min.unwrap_or(0.0) > 0.0 {
        patch["min_luminance"] = json!(min.unwrap());
    }
    remember_colour(c, name, patch);
}

pub fn main_display(c: &Ctx, mons: &[Value]) -> String {
    let id = c.p.s("mainDisplayId");
    if !id.is_empty() {
        if let Some(m) = mons.iter().find(|m| m["description"].as_str().unwrap_or("").trim() == id) {
            return m["name"].as_str().unwrap_or("").into();
        }
    }
    let want = c.p.s("mainDisplay");
    if !want.is_empty() && mons.iter().any(|m| m["name"] == want.as_str()) {
        return want;
    }
    mons.first().and_then(|m| m["name"].as_str()).unwrap_or("").into()
}

fn set_main_display(c: &mut Ctx, name: &str, mons: &[Value]) {
    let desc = mons.iter().find(|m| m["name"] == name).and_then(|m| m["description"].as_str()).unwrap_or("").trim().to_string();
    c.set("mainDisplay", json!(name));
    c.set("mainDisplayId", json!(if name.is_empty() { String::new() } else { desc.clone() }));
    if !name.is_empty() {
        let sel = if desc.is_empty() { name.to_string() } else { format!("desc:{desc}") };
        hypr::eval(&format!("hl.workspace_rule({{ workspace = \"1\", monitor = {}, default = true }})", hypr::lua_string(&sel)));
        hypr::eval(&format!("hl.dispatch(hl.dsp.workspace.move({{ workspace = 1, monitor = {} }}))", hypr::lua_string(name)));
    }
}

/// Appearance.screenScaleMap: "name=pct" lines.
fn screen_scale(c: &Ctx, name: &str) -> f64 {
    for line in c.p.s("screenScales").lines() {
        if let Some((n, v)) = line.split_once('=') {
            if n.trim() == name {
                return v.trim().parse::<f64>().unwrap_or(100.0).clamp(40.0, 200.0);
            }
        }
    }
    100.0
}
fn set_screen_scale(c: &mut Ctx, name: &str, pct: f64) {
    let mut keep: Vec<String> = c.p.s("screenScales").lines().filter(|l| l.split_once('=').is_some_and(|(n, _)| n.trim() != name)).map(str::to_string).collect();
    if pct.round() != 100.0 {
        keep.push(format!("{name}={}", pct.round()));
    }
    c.set("screenScales", json!(keep.join("\n")));
}

pub fn rows(c: &Ctx) -> Vec<Spec> {
    let p = &c.p;
    let mons: Vec<Value> = hypr::json("monitors").as_array().cloned().unwrap_or_default();
    if mons.is_empty() {
        return vec![info("No display", "Hyprland reported no monitors", "—")];
    }
    let m = mons.iter().find(|x| x["name"] == c.ui.display_pick.as_str()).unwrap_or(&mons[0]).clone();
    let name = m["name"].as_str().unwrap_or("").to_string();
    let (w, h) = (m["width"].as_i64().unwrap_or(0), m["height"].as_i64().unwrap_or(0));
    let rate = m["refreshRate"].as_f64().unwrap_or(0.0);
    let cur_res = format!("{w}x{h}");
    let scale = m["scale"].as_f64().unwrap_or(1.0);
    let map = hypr::display_map(p);
    let saved = map.get(&name).cloned().unwrap_or(json!({}));
    let mut r = vec![];

    // A change on trial: kept, or back by itself.
    if let Some(t) = &c.ui.trial {
        let left = t.until.saturating_duration_since(Instant::now()).as_secs();
        r.push(buttons(
            "Keep these display settings?",
            &format!("Going back to how {} was in {left} s", t.name),
            vec![btn("Keep", false, true, keep_trial), btn("Revert", true, true, revert_trial)],
        ));
    }
    let main = main_display(c, &mons);
    if mons.len() > 1 {
        let mut map = panel("monitors");
        map.row.n = "Arrangement".into();
        map.row.s = "Drag the screens to where they are on your desk; click one to set it up below".into();
        r.push(map);
        let opts: Vec<(String, String)> = mons
            .iter()
            .map(|x| (format!("{}{}", x["name"].as_str().unwrap_or(""), if x["focused"] == true { " ·" } else { "" }), x["name"].as_str().unwrap_or("").to_string()))
            .collect();
        let refs: Vec<(&str, &str)> = opts.iter().map(|o| (o.0.as_str(), o.1.as_str())).collect();
        r.push(seg_with("Display", "Which screen these settings apply to", &refs, &name, |c, v| c.ui.display_pick = v));
    }
    r.push(header(
        &name,
        &format!(
            "{}{}  ·  {cur_res} at {} Hz",
            m["description"].as_str().filter(|s| !s.is_empty()).unwrap_or("Display"),
            if m["focused"] == true { "  ·  focused" } else { "" },
            rate.round()
        ),
    ));
    if mons.len() > 1 {
        let is_main = main == name;
        let (n2, ms) = (name.clone(), mons.clone());
        r.push(toggle_with(
            "Main display",
            if is_main {
                "Workspace 1, the pointer at login and the login screen are here — and again whenever this monitor is plugged back in"
            } else {
                "Make this the screen workspace 1 and the login screen go to"
            },
            is_main,
            move |c, v| set_main_display(c, if v { &n2 } else { "" }, &ms),
        ));
    }
    let builtin = name.starts_with("eDP") || name.starts_with("LVDS") || name.starts_with("DSI");
    let lid = std::fs::read_dir("/proc/acpi/button/lid").map(|mut d| d.next().is_some()).unwrap_or(false);
    if builtin && lid {
        r.push(toggle(
            p,
            "Turn off when the lid is closed",
            "While another monitor is plugged in, as a docked laptop does; it comes back when the lid opens or the other monitor is unplugged",
            "lidScreenOff",
        ));
    }

    // Modes, by resolution, rates deduped on the rounded value.
    let mut by_res: Vec<(String, Vec<f64>)> = vec![];
    for md in m["availableModes"].as_array().into_iter().flatten().filter_map(|v| v.as_str()) {
        let Some((res, hz)) = md.split_once('@') else { continue };
        let Ok(hz) = hz.trim_end_matches("Hz").parse::<f64>() else { continue };
        match by_res.iter_mut().find(|e| e.0 == res) {
            Some(e) => {
                if !e.1.iter().any(|x| x.round() == hz.round()) {
                    e.1.push(hz)
                }
            }
            None => by_res.push((res.to_string(), vec![hz])),
        }
    }
    let area = |r: &str| r.split_once('x').map(|(a, b)| a.parse::<i64>().unwrap_or(0) * b.parse::<i64>().unwrap_or(0)).unwrap_or(0);
    by_res.sort_by_key(|e| -area(&e.0));
    let res_list: Vec<String> = by_res.iter().map(|e| e.0.clone()).collect();
    let mut rate_list = by_res.iter().find(|e| e.0 == cur_res).map(|e| e.1.clone()).unwrap_or_default();
    rate_list.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
    let hz = |x: f64| format!("{} Hz", x.round());
    let plain = |x: f64| ((x * 1000.0).round() / 1000.0).to_string();
    let main_rate = saved["mode"].as_str().and_then(|md| md.split('@').nth(1)).and_then(|v| v.parse::<f64>().ok()).unwrap_or(rate);
    let on_battery = crate::system::battery().is_some_and(|b| b.state == "Discharging");
    let battery_rate = saved["batteryRate"].as_f64().unwrap_or(0.0);
    let on_battery_rate = on_battery && battery_rate > 0.0;
    let nearest = |rates: &[f64], want: f64| rates.iter().cloned().min_by(|a, b| (a - want).abs().partial_cmp(&(b - want).abs()).unwrap_or(std::cmp::Ordering::Equal)).unwrap_or(want);
    {
        let (n2, by) = (name.clone(), by_res.clone());
        let s = if res_list.len() > 1 { format!("{} modes reported by this output", res_list.len()) } else { "Only one mode reported".into() };
        r.push(if res_list.len() > 1 {
            menu_with("Resolution", &s, res_list.clone(), &cur_res, move |c, v| {
                let rates = by.iter().find(|e| e.0 == v).map(|e| e.1.clone()).unwrap_or_default();
                let mode = format!("{v}@{}", plain(nearest(&rates, main_rate)));
                try_display(c, &n2, json!({ "mode": mode, "scale": live(&n2).and_then(|m| m["scale"].as_f64()).unwrap_or(1.0) }));
            })
        } else {
            info("Resolution", &s, &cur_res)
        });
    }
    let rate_labels: Vec<String> = rate_list.iter().map(|x| hz(*x)).collect();
    {
        let (n2, rl, cr, labels) = (name.clone(), rate_list.clone(), cur_res.clone(), rate_labels.clone());
        let off_target = !on_battery_rate && saved.get("mode").is_some() && (rate - main_rate).abs() >= 0.5;
        let s = if rate_list.len() <= 1 {
            "Only one rate at this resolution".to_string()
        } else if on_battery_rate {
            format!("Plugged in — on battery now, at {} Hz", rate.round())
        } else if off_target {
            format!("Set to {} Hz, running at {} Hz — the shell is putting it back", main_rate.round(), rate.round())
        } else {
            format!("Rates available at {cur_res}")
        };
        r.push(if rate_list.len() > 1 {
            menu_with("Refresh rate", &s, rate_labels.clone(), &hz(if on_battery_rate { main_rate } else { rate }), move |c, v| {
                if let Some(k) = labels.iter().position(|l| *l == v) {
                    let scale = live(&n2).and_then(|m| m["scale"].as_f64()).unwrap_or(1.0);
                    try_display(c, &n2, json!({ "mode": format!("{cr}@{}", plain(rl[k])), "scale": scale }));
                }
            })
        } else {
            info("Refresh rate", &s, hz(rate))
        });
    }
    if rate_list.len() > 1 && crate::system::battery().is_some() {
        let same = "Same as plugged in".to_string();
        let mut labels = vec![same.clone()];
        labels.extend(rate_labels.iter().cloned());
        let (n2, rl, rls) = (name.clone(), rate_list.clone(), rate_labels.clone());
        r.push(menu_with(
            "On battery",
            &if battery_rate > 0.0 {
                format!("Drops to {} Hz unplugged, to save power", battery_rate.round())
            } else {
                format!("Stays at {} Hz unplugged", main_rate.round())
            },
            labels,
            &if battery_rate > 0.0 { hz(battery_rate) } else { same },
            move |c, v| {
                let hz = rls.iter().position(|l| *l == v).map(|k| rl[k]).unwrap_or(0.0);
                hypr::save_display(&mut c.p, &n2, json!({ "batteryRate": if hz > 0.0 { json!(hz) } else { Value::Null } }));
                hypr::apply_display(&c.p, &n2);
            },
        ));
    }
    {
        let scales = hypr::valid_scales(w as f64, h as f64);
        let labels: Vec<String> = scales.iter().map(|x| format!("{}%", (x * 100.0).round())).collect();
        let n2 = name.clone();
        let s = if scales.len() > 1 { format!("Whole-pixel scales available at {cur_res}") } else { format!("No fractional scale divides {cur_res} cleanly") };
        let cur = format!("{}%", (scale * 100.0).round());
        let mode_now = saved["mode"].as_str().map(str::to_string).unwrap_or(format!("{cur_res}@{}", plain(rate)));
        r.push(if scales.len() > 1 {
            menu_with("Scale", &s, labels.clone(), &cur, move |c, v| {
                if let Some(k) = labels.iter().position(|l| *l == v) {
                    try_display(c, &n2, json!({ "mode": mode_now, "scale": scales[k] }));
                }
            })
        } else {
            info("Scale", &s, cur)
        });
    }
    r.push(toggle_with("Adaptive sync", "VRR while a fullscreen client is focused", m["vrr"].as_bool().unwrap_or(false), |_, v| {
        hypr::set_config(json!({ "misc": { "vrr": if v { 2 } else { 0 } } }))
    }));

    // ── colour ────────────────────────────────────────────────────────
    let all_caps = edid_caps();
    let caps = all_caps.get(&name).cloned().unwrap_or(json!({}));
    let bt2020 = caps["bt2020"] == true;
    let hdr_meta = caps["pq"] == true && caps["via"] != "displayid";
    let forced_wide = saved["supports_wide_color"] == 1;
    let forced_hdr = saved["supports_hdr"] == 1;
    let can_wide = bt2020 || forced_wide;
    let can_hdr = (can_wide && hdr_meta) || forced_hdr;
    let can_edid = true;
    let fmt = m["currentFormat"].as_str().unwrap_or("").to_string();
    let live10 = fmt.contains("2101010");
    let want10 = saved["bitdepth"] == 10;
    let live_preset = m["colorManagementPreset"].as_str().unwrap_or("srgb").to_string();
    let want_preset = saved["cm"].as_str().map(str::to_string).unwrap_or(live_preset.clone());
    let mut claims = vec![];
    if bt2020 {
        claims.push("wide gamut");
    }
    if hdr_meta {
        claims.push("HDR metadata");
    }
    claims.push("its own colour primaries");
    r.push(header("Colour", &format!("{name} advertises {} in its EDID", claims.join(", "))));
    let running_hdr = live_preset == "hdr" || live_preset == "hdredid";
    let want_hdr = want_preset == "hdr" || want_preset == "hdredid";
    let panel_hdr = caps["pq"] == true || can_hdr || forced_hdr;
    {
        let (n2, cp) = (name.clone(), caps.clone());
        let max_lum = caps["maxLum"].as_f64().unwrap_or(0.0);
        r.push(toggle_with(
            if panel_hdr { "Use HDR" } else { "Try HDR anyway" },
            &if want_hdr && !running_hdr {
                format!(
                    "Asked for HDR, running {}: Hyprland wouldn't hold it on this output. {}",
                    if live_preset.is_empty() { "sRGB" } else { &live_preset },
                    if panel_hdr { "Turn it off and on again; if it stays like this, the driver refuses HDR here" } else { "This display really can't, it seems" }
                )
            } else if running_hdr {
                format!(
                    "On: HDR, {}{}. Ordinary windows follow SDR brightness below",
                    if live10 { "10-bit" } else { "8-bit" },
                    if max_lum > 0.0 { format!(", up to {} nits", max_lum.round()) } else { String::new() }
                )
            } else if panel_hdr {
                "Off. HDR games and video still switch the screen to HDR while fullscreen".into()
            } else {
                "This display doesn't say it can do HDR; some can anyway. It goes back by itself unless you keep it".into()
            },
            want_hdr,
            move |c, v| set_hdr(c, &n2, v, !panel_hdr, &cp),
        ));
    }
    {
        let n2 = name.clone();
        r.push(seg_with(
            "Colour depth",
            &if want10 && !live10 {
                "Asked for 10-bit, running 8-bit — this output offers no 10-bit format, so the request was dropped. Nothing is broken; it simply has nowhere to go.".to_string()
            } else if live10 {
                format!("10-bit, about a billion colours — {fmt}")
            } else {
                format!(
                    "8-bit, 16.7 million colours{}. Switch to 10-bit to try; this line will say if the panel refuses.",
                    if fmt.is_empty() { String::new() } else { format!(" — {fmt}") }
                )
            },
            &[("8-bit", "8"), ("10-bit", "10")],
            if want10 { "10" } else { "8" },
            move |c, v| try_display(c, &n2, json!({ "bitdepth": if v == "10" { 10 } else { 8 } })),
        ));
    }
    const CM_ALL: &[(&str, &str)] = &[
        ("Standard (sRGB)", "srgb"),
        ("Automatic", "auto"),
        ("Wide gamut (BT.2020)", "wide"),
        ("HDR", "hdr"),
        ("The display's primaries", "edid"),
        ("HDR, display's primaries", "hdredid"),
        ("DCI-P3", "dcip3"),
        ("Display P3", "dp3"),
        ("Adobe RGB", "adobe"),
    ];
    let offered = |v: &str| match v {
        "srgb" | "auto" => true,
        "edid" => can_edid,
        "hdr" => can_hdr,
        "hdredid" => can_hdr && can_edid,
        "wide" => can_wide,
        _ => false,
    };
    let cm_options: Vec<(&str, &str)> = CM_ALL.iter().cloned().filter(|o| offered(o.1) || o.1 == live_preset || o.1 == want_preset).collect();
    let label_for = |v: &str| CM_ALL.iter().find(|o| o.1 == v).map(|o| o.0.to_string()).unwrap_or(v.to_string());
    {
        let resolves = want_preset == "auto";
        let s = if !resolves && want_preset != live_preset {
            format!("Asked for {}, running {} — this output can't hold it, so Hyprland fell back.", label_for(&want_preset), label_for(&live_preset))
        } else if resolves {
            format!("Wide gamut where the panel is 10-bit and says it can, sRGB otherwise. Currently {}.", label_for(&live_preset))
        } else {
            format!(
                "Currently {}{}",
                label_for(&live_preset),
                if can_hdr {
                    ""
                } else if can_wide {
                    ". HDR also needs HDR metadata in the EDID."
                } else {
                    ". Wide gamut and HDR need a panel that advertises BT.2020."
                }
            )
        };
        let labels: Vec<String> = cm_options.iter().map(|o| o.0.to_string()).collect();
        let values: Vec<String> = cm_options.iter().map(|o| o.1.to_string()).collect();
        let n2 = name.clone();
        r.push(
            menu_with("Colour range", &s, labels.clone(), &label_for(&want_preset), move |c, v| {
                if let Some(k) = labels.iter().position(|l| *l == v) {
                    try_display(c, &n2, json!({ "cm": values[k] }));
                }
            })
            .adv(),
        );
    }
    if running_hdr {
        let sdr_min = m["sdrMinLuminance"].as_f64().unwrap_or(0.2);
        let sdr_max = m["sdrMaxLuminance"].as_f64().unwrap_or(80.0);
        let max_lum = caps["maxLum"].as_f64().unwrap_or(0.0);
        r.push(header("HDR calibration", "How ordinary windows and the panel's range look with HDR on"));
        let (n2, cp) = (name.clone(), caps.clone());
        r.push(buttons(
            "Set up for this display",
            &format!(
                "Calibrate walks through each setting on the display itself. Quick set up: deep blacks, natural shadows and SDR white at 203 nits, with {} from its EDID",
                if max_lum > 0.0 { format!("its {}-nit peak", max_lum.round()) } else { "its peak".into() }
            ),
            vec![
                {
                    let n = name.clone();
                    btn("Calibrate", false, true, move |c| c.ui.hdr = Some((n.clone(), false)))
                },
                btn("Quick set up", true, true, move |c| calibrate_hdr(c, &n2, &cp)),
                {
                    let n = name.clone();
                    btn("Test pattern", true, true, move |c| c.ui.hdr = Some((n.clone(), true)))
                },
            ],
        ));
        let curve = saved["sdr_eotf"].as_str().unwrap_or("default").to_string();
        let n2 = name.clone();
        r.push(seg_with(
            "Shadows",
            if curve == "gamma22" {
                "Gamma 2.2, as SDR displays show it: deep shadows and full contrast. For every display in HDR"
            } else {
                "The sRGB curve lifts dark tones, which reads as washed out and low in contrast; Gamma 2.2 is usually right"
            },
            &[("Gamma 2.2", "gamma22force"), ("sRGB", "srgb"), ("Default", "default")],
            if curve == "gamma22" { "gamma22force" } else { &curve },
            move |c, v| remember_colour(c, &n2, json!({ "sdr_eotf": if v == "gamma22force" { "gamma22".to_string() } else { v } })),
        ));
        let n2 = name.clone();
        r.push(seg_with(
            "Black level",
            &if sdr_min >= 0.15 {
                "Hyprland's default, 0.2 nits: grey on an OLED, and the usual reason HDR looks washed out".to_string()
            } else {
                format!("SDR black at {sdr_min} nits. The test pattern shows whether it's right")
            },
            &[("Deepest", "0.005"), ("Deep", "0.05"), ("Default", "0.2")],
            if sdr_min < 0.02 {
                "0.005"
            } else if sdr_min < 0.15 {
                "0.05"
            } else {
                "0.2"
            },
            move |c, v| remember_colour(c, &n2, json!({ "sdr_min_luminance": v.parse::<f64>().unwrap_or(0.2) })),
        ));
        let n2 = name.clone();
        r.push(slider_with(
            "SDR content brightness",
            "How bright ordinary windows are beside HDR highlights, in nits. Around 200 matches a bright SDR screen",
            80.0,
            480.0,
            1.0,
            " nits",
            sdr_max.round(),
            move |c, v| remember_colour(c, &n2, json!({ "sdr_max_luminance": v.round() as i64 })),
        ));
        let n2 = name.clone();
        r.push(slider_with(
            "Peak brightness",
            &format!(
                "The brightest the panel goes; HDR highlights are fitted to it{}",
                if max_lum > 0.0 { format!(". Its EDID says {} nits", max_lum.round()) } else { String::new() }
            ),
            200.0,
            2000.0,
            1.0,
            " nits",
            saved["max_luminance"].as_f64().filter(|v| *v > 0.0).unwrap_or(if max_lum > 0.0 { max_lum } else { 1000.0 }).round(),
            move |c, v| remember_colour(c, &n2, json!({ "max_luminance": v.round() as i64 })),
        ));
        let n2 = name.clone();
        r.push(
            slider_with(
                "SDR brightness",
                "A further multiplier on SDR content's brightness, over the nits above",
                50.0,
                300.0,
                1.0,
                "%",
                (m["sdrBrightness"].as_f64().unwrap_or(1.0) * 100.0).round(),
                move |c, v| remember_colour(c, &n2, json!({ "sdrbrightness": v.round() / 100.0 })),
            )
            .adv(),
        );
        let n2 = name.clone();
        r.push(
            slider_with(
                "SDR saturation",
                "Turn down if sRGB reds and greens look oversaturated",
                50.0,
                150.0,
                1.0,
                "%",
                (m["sdrSaturation"].as_f64().unwrap_or(1.0) * 100.0).round(),
                move |c, v| remember_colour(c, &n2, json!({ "sdrsaturation": v.round() / 100.0 })),
            )
            .adv(),
        );
    }
    if !bt2020 {
        let n2 = name.clone();
        r.push(
            toggle_with("Force wide gamut", "For panels whose EDID undersells them. If colours look wrong, turn it back off", forced_wide, move |c, v| {
                remember_colour(c, &n2, json!({ "supports_wide_color": if v { 1 } else { 0 } }))
            })
            .adv(),
        );
    }
    if !hdr_meta && can_wide {
        let n2 = name.clone();
        r.push(
            toggle_with("Force HDR", "Same, for HDR. Needs wide gamut on or advertised", forced_hdr, move |c, v| {
                remember_colour(c, &n2, json!({ "supports_hdr": if v { 1 } else { 0 } }))
            })
            .adv(),
        );
    }
    {
        let n2 = name.clone();
        r.push(
            slider_with(
                "Shell size on this display",
                &format!(
                    "The bar, dock and menus on {name}, independently of the display scale above. A laptop panel scaled up so applications are legible makes the shell large to match; this gives that back."
                ),
                60.0,
                140.0,
                1.0,
                "%",
                screen_scale(c, &name).round(),
                move |c, v| set_screen_scale(c, &n2, v),
            )
            .adv(),
        );
    }

    // ── idle (Services.Idle, the daemon's own timers) ─────────────────
    r.push(header("When you leave it alone", "Apps that keep the screen on — a video, a call — hold these too"));
    let unit = |v: i64| match v {
        0 => "Never".to_string(),
        1 => "1 minute".into(),
        v => format!("{v} minutes"),
    };
    let off = p.i("idleOff");
    r.push(slider(
        p,
        "Turn the screen off after",
        &if off == 0 { "Never — the panel stays on until something else turns it off".to_string() } else { format!("{} of stillness, and back on when you touch anything", unit(off)) },
        0.0,
        60.0,
        " min",
        "idleOff",
    ));
    let sus = p.i("idleSuspend");
    r.push(slider(
        p,
        "Sleep after",
        &if sus == 0 { "Never — this machine will not suspend on its own".to_string() } else { format!("{} of stillness", unit(sus)) },
        0.0,
        180.0,
        " min",
        "idleSuspend",
    ));
    let lock = p.i("idleLock");
    r.push(slider(
        p,
        "Lock after",
        &if lock == 0 { "Never locks on its own".to_string() } else { format!("{} of stillness", unit(lock)) },
        0.0,
        120.0,
        " min",
        "idleLock",
    ));
    r.push(toggle(p, "Not while media plays", "Music or a video playing holds the timers", "idleHoldMedia"));
    r.push(toggle(p, "Not while a window is fullscreen", "A game or a film in fullscreen holds them", "idleHoldFullscreen"));

    r.push(header("All displays", "These apply to every screen"));
    match crate::system::brightness() {
        Some((dev, v)) => r.push(slider_with("Brightness", &format!("Backlight on {dev}"), 1.0, 100.0, 1.0, "%", (v * 100.0).round(), |_, v| {
            crate::system::set_brightness(v / 100.0)
        })),
        None => r.push(info("Brightness", "No backlight on this machine", "")),
    }
    r.extend(night_rows(p));
    r.push(
        action("Forget saved layouts", "Every output goes back to what hyprland.lua says at the next reload", "Forget", |c| {
            c.set("displays", json!(""));
        })
        .adv(),
    );
    r
}

/// Settings.nightRows, the built-in night light (the daemon's).
pub fn night_rows(p: &crate::prefs::Prefs) -> Vec<Spec> {
    let mode = p.s("nightMode");
    let mut r = vec![
        seg(
            p,
            "Night light",
            &match mode.as_str() {
                "sun" => "Working out sunset…".to_string(),
                "times" => format!("From {} to {}", p.s("nightFrom"), p.s("nightTo")),
                _ => "Warms the screen; fades in and out".into(),
            },
            &[("Off", "off"), ("On", "on"), ("Sunset to sunrise", "sun"), ("Set times", "times")],
            "nightMode",
        ),
        slider(p, "Colour temperature", "Lower is warmer. Around 3400 K suits most evenings.", 1900.0, 6000.0, " K", "nightTemp"),
    ];
    let hhmm = |v: &str| {
        let v = v.trim();
        v.split_once(':').is_some_and(|(h, m)| h.parse::<u32>().is_ok_and(|h| h < 24) && m.len() == 2 && m.parse::<u32>().is_ok_and(|m| m < 60))
    };
    if mode == "times" {
        r.push(text("From", "24-hour, like 20:00", &p.s("nightFrom"), "20:00", "Set", move |c, v| {
            if hhmm(&v) {
                c.set("nightFrom", json!(v.trim()))
            }
        }));
        r.push(text("Until", "24-hour, like 07:00", &p.s("nightTo"), "07:00", "Set", move |c, v| {
            if hhmm(&v) {
                c.set("nightTo", json!(v.trim()))
            }
        }));
    }
    if mode == "sun" {
        let (lat, lon) = (p.s("nightLat"), p.s("nightLon"));
        r.push(text(
            "Location",
            "Latitude, longitude. Empty uses your time zone's city; never sent anywhere",
            &if lat.is_empty() { String::new() } else { format!("{lat}, {lon}") },
            "e.g. 51.5, -0.12",
            "Set",
            |c, v| {
                let parts: Vec<&str> = v.split(|ch: char| ch == ',' || ch.is_whitespace()).filter(|s| !s.is_empty()).collect();
                if v.trim().is_empty() {
                    c.set("nightLat", json!(""));
                    c.set("nightLon", json!(""));
                } else if let [a, b] = parts[..] {
                    if let (Ok(la), Ok(lo)) = (a.parse::<f64>(), b.parse::<f64>()) {
                        if la.abs() <= 90.0 && lo.abs() <= 180.0 {
                            c.set("nightLat", json!(a));
                            c.set("nightLon", json!(b));
                        }
                    }
                }
            },
        ));
    }
    r
}
