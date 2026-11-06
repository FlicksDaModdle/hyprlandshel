//! Settings → Sound's equalizer, noise suppression and listening
//! (SoundEq.qml, EqGraph.qml, and SoundPanel.qml's microphone effects).
//!
//! The settings are theme.json's, as AudioFx.qml keeps them; the shell
//! (the Rust one, rshell/src/audiofx.rs) runs the chains from them and says
//! how it's going in $XDG_RUNTIME_DIR/hyprshell/fx.json. Frequency, gain
//! and Q are heard as they change: sent here straight to the running
//! filter (pw-cli set-param), as AudioFx.sendGains did.

use crate::prefs::Prefs;
use crate::sound::Sound;
use crate::{EqApp, EqBandChip, EqChipRow, EqCurve, EqHandle, EqLook, EqPreset, EqPresetGroup, EqTick};
use hyprshell_kit::eqmath::{self as m, Band};
use serde_json::{json, Value};
use slint::{Color, ComponentHandle, Model, ModelRc, SharedString, VecModel};
use std::sync::{Arc, Mutex};

const HUES: [&str; 8] = ["#ff6a55", "#ffa94d", "#f2cc4d", "#6fd48c", "#4dc3e8", "#7d8cff", "#c07dff", "#ff79b0"];
const GROUPS: [&str; 7] = ["Basics", "Character", "Voice", "Device", "Target curves", "Tools", "Yours"];

fn hue(i: usize) -> Color {
    let h = HUES[i % HUES.len()].trim_start_matches('#');
    let p = |k: usize| u8::from_str_radix(&h[k..k + 2], 16).unwrap_or(0);
    Color::from_rgb_u8(p(0), p(2), p(4))
}

pub fn bands(p: &Prefs) -> Vec<Band> {
    m::parse(&p.s("peqBands"))
}

/// The shell's word on the chains (rshell's fx.json).
pub fn status_text() -> String {
    let run = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    std::fs::read_to_string(format!("{run}/hyprshell/fx.json")).unwrap_or_default()
}
pub fn status() -> Value {
    serde_json::from_str(&status_text()).unwrap_or(json!({}))
}
pub fn first_id(p: &Prefs) -> i32 {
    bands(p).first().map(|b| b.id as i32).unwrap_or(-1)
}
pub fn user_names(p: &Prefs) -> Vec<String> {
    user_presets(p).iter().map(|u| u["name"].as_str().unwrap_or("").to_string()).collect()
}
/// Scrolled on a handle: Q narrower or wider, a notch at a time.
pub fn q_steps(p: &Prefs, id: i32, n: i32) -> Vec<(&'static str, Value)> {
    let Some(b) = bands(p).into_iter().find(|b| b.id as i32 == id) else { return vec![] };
    set_band(p, id, &json!({ "q": (b.q * 1.12f64.powi(n)).clamp(m::Q_MIN, m::Q_MAX) }))
}

fn user_presets(p: &Prefs) -> Vec<Value> {
    serde_json::from_str::<Value>(&p.s("peqPresets"))
        .ok()
        .and_then(|v| v.as_array().cloned())
        .unwrap_or_default()
        .into_iter()
        .filter(|x| x["name"].is_string())
        .collect()
}

/// Rows of chips, about as many as fit in a row of `per` (Flow's wrap).
fn rows<T: Clone>(items: Vec<T>, per: usize) -> Vec<Vec<T>> {
    items.chunks(per.max(1)).map(|c| c.to_vec()).collect()
}

/// A list into the window, row by row when it is as long as before, so
/// what is drawn from it (a handle being dragged) isn't made again.
fn fill<T: Clone + PartialEq + 'static>(cur: ModelRc<T>, new: Vec<T>, set: impl FnOnce(ModelRc<T>)) {
    if cur.row_count() == new.len() && new.len() > 0 {
        for (i, x) in new.into_iter().enumerate() {
            if cur.row_data(i).as_ref() != Some(&x) {
                cur.set_row_data(i, x);
            }
        }
    } else {
        set(ModelRc::new(VecModel::from(new)));
    }
}

// ── the graph ───────────────────────────────────────────────────────────
/// x across the plot, 0–1000, for a frequency.
fn xf(f: f64) -> f64 {
    ((f.ln() - m::F_MIN.ln()) / (m::F_MAX.ln() - m::F_MIN.ln())) * 1000.0
}
/// y down the plot, 0–1000, for dB on a ±range scale.
fn yd(db: f64, range: f64) -> f64 {
    500.0 - db / range * 500.0
}
/// A curve as a path on a plot `w` by `h` pixels.
fn path(curve: &[f64], freqs: &[f64], range: f64, w: f64, h: f64) -> String {
    let mut s = String::new();
    for (i, (f, d)) in freqs.iter().zip(curve).enumerate() {
        let y = yd(*d, range).clamp(-20.0, 1020.0) / 1000.0 * h;
        s += &format!("{}{:.1} {:.1} ", if i == 0 { "M " } else { "L " }, xf(*f) / 1000.0 * w, y);
    }
    s
}

/// Everything the equalizer card draws, into the window.
pub fn publish(ui: &crate::AppWindow, p: &Prefs, snd: &Sound) {
    let g = ui.global::<EqLook>();
    let selected = g.get_selected();
    let sink_label = {
        let l = snd.label(p, &snd.default_sink);
        if l.is_empty() { "the output".to_string() } else { l }
    };
    let st = status();
    let list = bands(p);
    let on = p.b("eqEnabled");
    let eq_status = st["eq"]["status"].as_str().unwrap_or("off").to_string();
    let available = st["eq"]["available"].as_bool();
    g.set_enabled(on);
    g.set_shell(st["shell"].is_number());
    g.set_available(available != Some(false));
    g.set_failed(on && eq_status == "error");
    g.set_error(st["eq"]["error"].as_str().unwrap_or("").into());
    let apps: Vec<String> = serde_json::from_str(&p.s("eqApps")).unwrap_or_default();
    let per_app = p.s("eqScope") == "apps";
    g.set_per_app(per_app);
    let app_list: Vec<EqApp> = snd
        .eq_apps(&apps)
        .into_iter()
        .map(|(key, label, glyph, live)| EqApp { chosen: apps.contains(&key), key: key.into(), label: label.into(), glyph: glyph.into(), live })
        .collect();
    g.set_no_apps(app_list.is_empty());
    g.set_app_rows(ModelRc::new(VecModel::from(
        rows(app_list, 4).into_iter().map(|r| EqChipRow { apps: ModelRc::new(VecModel::from(r)), ..Default::default() }).collect::<Vec<_>>(),
    )));
    g.set_types(ModelRc::new(VecModel::from(m::TYPES.iter().map(|t| SharedString::from(t.2)).collect::<Vec<_>>())));
    g.set_slopes(ModelRc::new(VecModel::from(m::SLOPES.iter().map(|s| SharedString::from(format!("{s} dB"))).collect::<Vec<_>>())));

    // Noise suppression and listening (SoundPanel.qml).
    let ns_on = p.b("nsEnabled");
    let ns_status = st["ns"]["status"].as_str().unwrap_or("off").to_string();
    let ns_avail = st["ns"]["available"].as_bool();
    g.set_ns_enabled(ns_on);
    g.set_ns_available(ns_avail != Some(false));
    g.set_ns_failed(ns_on && ns_status == "error");
    g.set_ns_error(st["ns"]["error"].as_str().unwrap_or("").into());
    g.set_ns_threshold(p.f("nsThreshold").round() as i32);
    let src_label = |n: &str| {
        let l = snd.label(p, n);
        if l.is_empty() { "the microphone".to_string() } else { l }
    };
    g.set_ns_sub(
        if !st["shell"].is_number() {
            "The shell runs noise suppression; it isn't running".to_string()
        } else if ns_avail == Some(false) {
            "Needs the RNNoise plugin — install noise-suppression-for-voice".into()
        } else if !ns_on {
            "Off — keyboard, fans and traffic go out with your voice".into()
        } else if ns_status == "starting" {
            "Starting…".into()
        } else if ns_status == "error" {
            "Didn't start — see below".into()
        } else {
            format!("On, for {}", src_label(&snd.default_source))
        }
        .into(),
    );
    let listen_src = st["listen"]["source"].as_str().unwrap_or("").to_string();
    let listening = st["listen"]["module"].as_i64().unwrap_or(-1) >= 0;
    let inspected = snd.inspected_name(false);
    g.set_listening(listening);
    g.set_can_listen(st["shell"].is_number() && !inspected.is_empty());
    g.set_listen_sub(
        if listening {
            format!("Playing {} through {}", src_label(&listen_src), sink_label)
        } else {
            format!("Hear what {} picks up, live", src_label(&inspected))
        }
        .into(),
    );
    g.set_sub(
        if !st["shell"].is_number() {
            "The shell runs the equalizer; it isn't running".to_string()
        } else if available == Some(false) {
            "Needs the pipewire program, which wasn't found".into()
        } else if !on {
            "Off — shape the sound of everything you play".into()
        } else if eq_status == "starting" {
            "Starting…".into()
        } else if eq_status == "error" {
            "Didn't start — see below".into()
        } else {
            format!(
                "On, for {} · {} · {} bands",
                if per_app { if apps.len() == 1 { "1 app".into() } else { format!("{} apps", apps.len()) } } else { sink_label.to_string() },
                p.s("eqPreset"),
                list.iter().filter(|b| b.on).count()
            )
        }
        .into(),
    );
    g.set_preset(p.s("eqPreset").into());
    g.set_preamp(p.f("eqPreamp") as f32);
    g.set_preamp_text(format!("{} dB", m::fmt_gain(p.f("eqPreamp"))).into());
    let range = p.f("eqRange").max(1.0);
    g.set_range(range as f32);
    g.set_can_add(list.len() < m::MAX_BANDS);

    // Presets, by what they are for; yours last.
    let cur = p.s("eqPreset");
    let users = user_presets(p);
    let groups: Vec<EqPresetGroup> = GROUPS
        .iter()
        .filter_map(|grp| {
            let items: Vec<EqPreset> = if *grp == "Yours" {
                users.iter().map(|u| EqPreset { name: u["name"].as_str().unwrap_or("").into(), user: true, current: u["name"] == cur.as_str() }).collect()
            } else {
                m::PRESETS.iter().filter(|x| x.1 == *grp).map(|x| EqPreset { name: x.0.into(), user: false, current: x.0 == cur }).collect()
            };
            (!items.is_empty()).then(|| EqPresetGroup {
                name: if *grp == "Yours" { "Saved".into() } else { (*grp).into() },
                rows: ModelRc::new(VecModel::from(rows(items, 5).into_iter().map(|r| EqChipRow { presets: ModelRc::new(VecModel::from(r)), ..Default::default() }).collect::<Vec<_>>())),
            })
        })
        .collect();
    g.set_preset_groups(ModelRc::new(VecModel::from(groups)));
    g.set_user_names(ModelRc::new(VecModel::from(users.iter().map(|u| SharedString::from(u["name"].as_str().unwrap_or(""))).collect::<Vec<_>>())));

    // The curves: each band's own shape, and the sum with the preamp.
    let (w, h) = (g.get_vw().max(10.0) as f64, g.get_vh().max(10.0) as f64);
    let freqs = m::log_freqs(((w / 3.0).round() as usize).max(64));
    let mut curves = vec![];
    for (i, b) in list.iter().enumerate() {
        let c = m::band_curve(b, &freqs);
        let line = path(&c, &freqs, range, w, h);
        let zero = yd(0.0, range) / 1000.0 * h;
        let fill = format!("{line}L {w:.1} {zero:.1} L 0 {zero:.1} Z");
        let sel = b.id as i32 == selected;
        curves.push(EqCurve { fill: fill.into(), stroke: line.into(), color: hue(i), sel, on: b.on });
    }
    fill(g.get_curves(), curves, |m| g.set_curves(m));
    let total = m::total_curve(&list, p.f("eqPreamp"), &freqs);
    g.set_total(path(&total, &freqs, range, w, h).into());
    // Above 0 dB, loud passages clip: marked along the top.
    let clips: Vec<f32> = freqs.iter().zip(&total).filter(|(_, d)| **d > 0.05).map(|(f, _)| (xf(*f) / 1000.0) as f32).collect();
    g.set_clips(ModelRc::new(VecModel::from(clips)));
    let grid: Vec<EqTick> = [20, 30, 40, 50, 60, 70, 80, 90, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10000, 20000]
        .iter()
        .map(|f| EqTick { at: (xf(*f as f64) / 1000.0) as f32, major: [100, 1000, 10000].contains(f), label: SharedString::new() })
        .collect();
    g.set_grid(ModelRc::new(VecModel::from(grid)));
    let flabels: Vec<EqTick> = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]
        .iter()
        .map(|f| EqTick { at: (xf(*f as f64) / 1000.0) as f32, major: false, label: m::fmt_freq(*f as f64).into() })
        .collect();
    g.set_flabels(ModelRc::new(VecModel::from(flabels)));
    let dlabels: Vec<EqTick> = (-2..=2)
        .map(|k| {
            let v = k as f64 * range / 2.0;
            EqTick { at: (yd(v, range) / 1000.0) as f32, major: k == 0, label: format!("{}{}", if v > 0.0 { "+" } else if v < 0.0 { "−" } else { "" }, v.abs()).into() }
        })
        .collect();
    g.set_dlabels(ModelRc::new(VecModel::from(dlabels)));

    // The handles, and the chips under the graph (in order of frequency).
    let handles: Vec<EqHandle> = list
        .iter()
        .enumerate()
        .map(|(i, b)| {
            let gainy = m::has_gain(&b.kind);
            EqHandle {
                id: b.id as i32,
                n: (i + 1) as i32,
                x: (xf(b.freq) / 1000.0) as f32,
                y: (yd(if gainy { b.gain } else { 0.0 }, range) / 1000.0) as f32,
                gainy,
                on: b.on,
                color: hue(i),
                tip: format!(
                    "{} · {} Hz{}{}{}",
                    m::label_of(&b.kind),
                    m::fmt_freq(b.freq),
                    if gainy { format!(" · {} dB", m::fmt_gain(b.gain)) } else { String::new() },
                    if m::is_cut(&b.kind) { format!(" · {} dB/oct", b.slope) } else { format!(" · Q {:.2}", b.q) },
                    if b.on { "" } else { " · off" }
                )
                .into(),
            }
        })
        .collect();
    fill(g.get_handles(), handles, |m| g.set_handles(m));
    let mut sorted: Vec<(usize, &Band)> = list.iter().enumerate().collect();
    sorted.sort_by(|a, b| a.1.freq.total_cmp(&b.1.freq));
    let chips: Vec<EqBandChip> = sorted
        .iter()
        .map(|(i, b)| EqBandChip {
            id: b.id as i32,
            label: format!(
                "{} {}{}",
                m::short_of(&b.kind),
                m::fmt_freq(b.freq),
                if m::has_gain(&b.kind) { format!("  {}", m::fmt_gain(b.gain)) } else { String::new() }
            )
            .into(),
            color: hue(*i),
            on: b.on,
            add: false,
        })
        .collect();
    let mut chips = chips;
    if list.len() < m::MAX_BANDS {
        chips.push(EqBandChip { id: -1, label: "Band".into(), color: Color::default(), on: true, add: true });
    }
    g.set_band_rows(ModelRc::new(VecModel::from(
        rows(chips, 6).into_iter().map(|r| EqChipRow { bands: ModelRc::new(VecModel::from(r)), ..Default::default() }).collect::<Vec<_>>(),
    )));

    // The band picked.
    match list.iter().find(|b| b.id as i32 == selected) {
        Some(b) => {
            g.set_has_sel(true);
            g.set_sel_type(m::TYPES.iter().position(|t| t.0 == b.kind).unwrap_or(0) as i32);
            g.set_sel_on(b.on);
            g.set_sel_gainy(m::has_gain(&b.kind));
            g.set_sel_cut(m::is_cut(&b.kind));
            g.set_sel_slope(m::SLOPES.iter().position(|s| *s == b.slope).unwrap_or(1) as i32);
            g.set_sel_freq(
                if b.freq >= 1000.0 { format!("{}k", if b.freq >= 10000.0 { format!("{:.1}", b.freq / 1000.0) } else { format!("{:.2}", b.freq / 1000.0) }) } else if b.freq < 100.0 { format!("{:.1}", b.freq) } else { format!("{:.0}", b.freq) }.into(),
            );
            g.set_sel_gain(m::fmt_gain(b.gain).into());
            g.set_sel_q(format!("{:.2}", b.q).into());
        }
        None => g.set_has_sel(false),
    }
}

// ── changes (AudioFx.qml's) ─────────────────────────────────────────────
/// The bands kept, the preset now Custom.
pub fn store(p: &Prefs, list: &[Band], custom: bool) -> Vec<(&'static str, Value)> {
    let mut out = vec![("peqBands", json!(m::store(list)))];
    if custom {
        out.push(("eqPreset", json!("Custom")));
    }
    let _ = p;
    out
}

/// A band changed: patch is any of type, freq, gain, q, slope, on.
pub fn set_band(p: &Prefs, id: i32, patch: &Value) -> Vec<(&'static str, Value)> {
    let list: Vec<Band> = bands(p)
        .into_iter()
        .map(|b| {
            if b.id as i32 != id {
                return b;
            }
            let mut v = m::to_json(&b);
            for (k, x) in patch.as_object().into_iter().flatten() {
                v[k] = x.clone();
            }
            let mut n = m::clean(&v, b.id);
            if patch.get("type").is_some() {
                // A band turned into a cut or a notch has no gain to keep.
                if !m::has_gain(&n.kind) {
                    n.gain = 0.0;
                }
                if m::is_cut(&n.kind) && !m::is_cut(&b.kind) {
                    n.q = 0.71;
                }
            }
            n
        })
        .collect();
    store(p, &list, true)
}

/// A new band where it was asked for; its id, or none when there are as
/// many as there can be.
pub fn add_band(p: &Prefs, freq: f64, gain: f64) -> (Option<i32>, Vec<(&'static str, Value)>) {
    let mut list = bands(p);
    if list.len() >= m::MAX_BANDS {
        return (None, vec![]);
    }
    let id = m::next_id(&list);
    list.push(m::band_at(freq, gain, id));
    (Some(id as i32), store(p, &list, true))
}
/// In the widest gap between the bands there are, so a new one is never
/// on top of another.
pub fn add_in_gap(p: &Prefs) -> (Option<i32>, Vec<(&'static str, Value)>) {
    let mut fs: Vec<f64> = vec![20.0];
    let mut bf: Vec<f64> = bands(p).iter().map(|b| b.freq).collect();
    bf.sort_by(f64::total_cmp);
    fs.extend(bf);
    fs.push(20000.0);
    let (mut best, mut gap) = (1000.0, 0.0);
    for w in fs.windows(2) {
        let g = (w[1] / w[0]).ln();
        if g > gap {
            gap = g;
            best = (w[1] * w[0]).sqrt();
        }
    }
    add_band(p, best.clamp(60.0, 12000.0), 0.0)
}
pub fn remove_band(p: &Prefs, id: i32) -> Vec<(&'static str, Value)> {
    let list: Vec<Band> = bands(p).into_iter().filter(|b| b.id as i32 != id).collect();
    store(p, &list, true)
}
pub fn toggle_band(p: &Prefs, id: i32) -> Vec<(&'static str, Value)> {
    let on = bands(p).iter().find(|b| b.id as i32 == id).map(|b| b.on).unwrap_or(true);
    set_band(p, id, &json!({ "on": !on }))
}
pub fn set_preamp(db: f64) -> Vec<(&'static str, Value)> {
    vec![("eqPreamp", json!((db.clamp(-24.0, 24.0) * 10.0).round() / 10.0))]
}
/// The preamp down by however far the curve rises above 0 dB.
pub fn auto_preamp(p: &Prefs) -> Vec<(&'static str, Value)> {
    let on: Vec<Band> = bands(p).into_iter().filter(|b| b.on).collect();
    let top = m::peak_boost(&on);
    set_preamp(if top > 0.05 { -(top * 10.0).ceil() / 10.0 } else { 0.0 })
}
pub fn reset() -> Vec<(&'static str, Value)> {
    vec![("peqBands", json!("[]")), ("eqPreamp", json!(0)), ("eqPreset", json!("Flat"))]
}
pub fn apply_preset(p: &Prefs, name: &str, user: bool) -> Vec<(&'static str, Value)> {
    if user {
        let Some(u) = user_presets(p).into_iter().find(|u| u["name"] == name) else { return vec![] };
        let list: Vec<Band> = u["bands"].as_array().into_iter().flatten().enumerate().map(|(i, b)| m::clean(b, i as i64 + 1)).collect();
        let mut out = vec![("peqBands", json!(m::store(&list))), ("eqPreset", json!(name))];
        if let Some(pre) = u["preamp"].as_f64() {
            out.push(("eqPreamp", json!(pre)));
        } else {
            let top = m::peak_boost(&list);
            out.push(("eqPreamp", json!(if top > 0.05 { -(top * 10.0).ceil() / 10.0 } else { 0.0 })));
        }
        return out;
    }
    let list = m::preset_bands(name);
    let top = m::peak_boost(&list);
    vec![
        ("peqBands", json!(m::store(&list))),
        ("eqPreset", json!(name)),
        ("eqPreamp", json!(if top > 0.05 { -(top * 10.0).ceil() / 10.0 } else { 0.0 })),
    ]
}
/// Yours, kept beside the built-in ones: the bands and preamp as they are.
pub fn save_preset(p: &Prefs, name: &str) -> Vec<(&'static str, Value)> {
    let name: String = name.trim().chars().take(40).collect();
    if name.is_empty() {
        return vec![];
    }
    let mut list: Vec<Value> = user_presets(p).into_iter().filter(|u| u["name"] != name.as_str()).collect();
    list.push(json!({ "name": name, "preamp": p.f("eqPreamp"), "bands": bands(p).iter().map(m::to_json).collect::<Vec<_>>() }));
    list.sort_by(|a, b| a["name"].as_str().unwrap_or("").cmp(b["name"].as_str().unwrap_or("")));
    vec![("peqPresets", json!(Value::Array(list).to_string())), ("eqPreset", json!(name))]
}
pub fn delete_preset(p: &Prefs, name: &str) -> Vec<(&'static str, Value)> {
    let list: Vec<Value> = user_presets(p).into_iter().filter(|u| u["name"] != name).collect();
    let mut out = vec![("peqPresets", json!(Value::Array(list).to_string()))];
    if p.s("eqPreset") == name {
        out.push(("eqPreset", json!("Custom")));
    }
    out
}
pub fn set_app(p: &Prefs, key: &str, on: bool) -> Vec<(&'static str, Value)> {
    if key.is_empty() {
        return vec![];
    }
    let mut list: Vec<String> = serde_json::from_str::<Vec<String>>(&p.s("eqApps")).unwrap_or_default().into_iter().filter(|x| x != key).collect();
    if on {
        list.push(key.into());
    }
    vec![("eqApps", json!(json!(list).to_string()))]
}

/// EqValue's steps: a band's frequency, gain or Q nudged n notches (Shift:
/// a fifth as far). `which`: 0 frequency, 1 gain, 2 Q.
pub fn nudge(p: &Prefs, id: i32, which: i32, n: i32, fine: bool) -> Vec<(&'static str, Value)> {
    let Some(b) = bands(p).into_iter().find(|b| b.id as i32 == id) else { return vec![] };
    let k: f64 = if fine { 0.2 } else { 1.0 };
    let n = n as f64;
    let patch = match which {
        0 => json!({ "freq": (b.freq * (1.0 + 0.03 * k).powf(n)).clamp(m::F_MIN, m::F_MAX) }),
        1 => json!({ "gain": (b.gain + 0.5 * k * n).clamp(-m::GAIN_MAX, m::GAIN_MAX) }),
        _ => json!({ "q": (b.q * (1.0 + 0.08 * k).powf(n)).clamp(m::Q_MIN, m::Q_MAX) }),
    };
    set_band(p, id, &patch)
}
/// A value typed in ("1.2k" is a frequency as people write one).
pub fn typed(p: &Prefs, id: i32, which: i32, text: &str) -> Vec<(&'static str, Value)> {
    let t = text.trim().to_lowercase().replace(',', ".").replace('−', "-");
    let num: String = t.chars().take_while(|c| c.is_ascii_digit() || *c == '.' || *c == '-' || *c == '+').collect();
    let Ok(mut v) = num.parse::<f64>() else { return vec![] };
    if t.contains('k') {
        v *= 1000.0;
    }
    let patch = match which {
        0 => json!({ "freq": v.clamp(m::F_MIN, m::F_MAX) }),
        1 => json!({ "gain": v.clamp(-m::GAIN_MAX, m::GAIN_MAX) }),
        _ => json!({ "q": v.clamp(m::Q_MIN, m::Q_MAX) }),
    };
    set_band(p, id, &patch)
}
/// A handle dragged to (x, y) on the plot, 0–1 each way.
pub fn drag(p: &Prefs, id: i32, x: f64, y: f64) -> Vec<(&'static str, Value)> {
    let Some(b) = bands(p).into_iter().find(|b| b.id as i32 == id) else { return vec![] };
    let range = p.f("eqRange").max(1.0);
    let f = (m::F_MIN.ln() + x.clamp(0.0, 1.0) * (m::F_MAX.ln() - m::F_MIN.ln())).exp();
    let mut patch = json!({ "freq": f });
    if m::has_gain(&b.kind) {
        patch["gain"] = json!(((0.5 - y.clamp(0.0, 1.0)) * 2.0 * range).clamp(-m::GAIN_MAX, m::GAIN_MAX));
    }
    set_band(p, id, &patch)
}
/// Where a double-click on the graph is: frequency and gain.
pub fn at(p: &Prefs, x: f64, y: f64) -> (f64, f64) {
    let range = p.f("eqRange").max(1.0);
    let f = (m::F_MIN.ln() + x.clamp(0.0, 1.0) * (m::F_MAX.ln() - m::F_MIN.ln())).exp();
    let g = ((0.5 - y.clamp(0.0, 1.0)) * 2.0 * range).clamp(-range, range);
    (f, (g * 2.0).round() / 2.0)
}

// ── live ────────────────────────────────────────────────────────────────
/// Gains to the running filter, at most one pw-cli at a time; the latest
/// wins (AudioFx.sendGains).
#[derive(Default, Clone)]
pub struct Live {
    busy: Arc<Mutex<(bool, Option<(String, String)>)>>,
}
impl Live {
    pub fn push(&self, node: &str, props: String) {
        if node.is_empty() {
            return;
        }
        {
            let mut b = self.busy.lock().unwrap();
            if b.0 {
                b.1 = Some((node.into(), props));
                return;
            }
            b.0 = true;
        }
        let busy = self.busy.clone();
        let (mut node, mut props) = (node.to_string(), props);
        std::thread::spawn(move || loop {
            let _ = std::process::Command::new("pw-cli").args(["set-param", &node, "Props", &props]).output();
            let mut b = busy.lock().unwrap();
            match b.1.take() {
                Some((n, pr)) => {
                    node = n;
                    props = pr;
                }
                None => {
                    b.0 = false;
                    return;
                }
            }
        });
    }
}
pub fn gains(p: &Prefs) -> String {
    m::gain_params(&bands(p), p.f("eqPreamp"))
}
pub fn ns_params(p: &Prefs) -> String {
    format!("{{ params = [ \"rnnoise:VAD Threshold (%)\" {:.2} ] }}", p.f("nsThreshold"))
}
