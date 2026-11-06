//! The parametric equalizer's arithmetic (services/EqMath.js): the bands
//! as Settings keeps them, the PipeWire biquads each becomes, the curve
//! they make, and the presets. Shared, so what Settings draws is what the
//! shell has PipeWire play: the Rust shell takes this same file in with
//! `#[path]`, and it needs nothing but serde_json.
//!
//! Every band is one or more of PipeWire's builtin biquads. The formulas
//! are PipeWire's own (spa/plugins/audioconvert/biquad.c): the RBJ
//! cookbook, Q on every type, shelves included, and the frequency taken as
//! a fraction of Nyquist. The curve is worked out at 48 kHz.

use serde_json::{json, Value};

pub const FS: f64 = 48000.0;
pub const F_MIN: f64 = 20.0;
pub const F_MAX: f64 = 20000.0;
pub const GAIN_MAX: f64 = 24.0;
pub const Q_MIN: f64 = 0.1;
pub const Q_MAX: f64 = 18.0;
pub const MAX_BANDS: usize = 16;

/// What a band can be: key, label, short label, has a gain, is a cut.
pub const TYPES: [(&str, &str, &str, bool, bool); 7] = [
    ("bell", "Bell", "Bell", true, false),
    ("lowshelf", "Low shelf", "LS", true, false),
    ("highshelf", "High shelf", "HS", true, false),
    ("lowcut", "Low cut", "LC", false, true),
    ("highcut", "High cut", "HC", false, true),
    ("notch", "Notch", "Notch", false, false),
    ("bandpass", "Band pass", "BP", false, false),
];
pub const SLOPES: [i64; 4] = [12, 24, 36, 48];

#[derive(Clone, Debug, PartialEq)]
pub struct Band {
    pub id: i64,
    pub kind: String,
    pub freq: f64,
    pub gain: f64,
    pub q: f64,
    pub slope: i64,
    pub on: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Stage {
    pub label: &'static str,
    pub freq: f64,
    pub q: f64,
    pub gain: f64,
}

fn type_of(key: &str) -> (&'static str, &'static str, &'static str, bool, bool) {
    TYPES.iter().copied().find(|t| t.0 == key).unwrap_or(TYPES[0])
}
pub fn has_gain(key: &str) -> bool {
    type_of(key).3
}
pub fn is_cut(key: &str) -> bool {
    type_of(key).4
}
pub fn label_of(key: &str) -> &'static str {
    type_of(key).1
}
pub fn short_of(key: &str) -> &'static str {
    type_of(key).2
}

fn clamp(v: f64, lo: f64, hi: f64) -> f64 {
    v.max(lo).min(hi)
}

/// A cut steeper than 12 dB/octave is a cascade of second-order sections
/// with Butterworth Qs; the band's own Q is the resonance at the corner,
/// scaling the sharpest section (0.71 is Butterworth).
fn butterworth(slope: i64) -> &'static [f64] {
    match slope {
        24 => &[0.54120, 1.30656],
        36 => &[0.51764, 0.70711, 1.93185],
        48 => &[0.50980, 0.60134, 0.89998, 2.56292],
        _ => &[0.70711],
    }
}

/// The PipeWire nodes one band becomes.
pub fn stages(b: &Band) -> Vec<Stage> {
    let f = clamp(if b.freq > 0.0 { b.freq } else { 1000.0 }, F_MIN, F_MAX);
    let q = clamp(if b.q > 0.0 { b.q } else { 0.71 }, Q_MIN, Q_MAX);
    let g = clamp(b.gain, -GAIN_MAX, GAIN_MAX);
    let one = |label: &'static str, gain: f64| vec![Stage { label, freq: f, q, gain }];
    match b.kind.as_str() {
        "lowshelf" => one("bq_lowshelf", g),
        "highshelf" => one("bq_highshelf", g),
        "notch" => one("bq_notch", 0.0),
        "bandpass" => one("bq_bandpass", 0.0),
        "lowcut" | "highcut" => {
            let label = if b.kind == "lowcut" { "bq_highpass" } else { "bq_lowpass" };
            let qs = butterworth(b.slope);
            let res = q / 0.70711;
            qs.iter()
                .enumerate()
                .map(|(i, bq)| Stage { label, freq: f, q: if i == qs.len() - 1 { clamp(bq * res, Q_MIN, Q_MAX * 2.0) } else { *bq }, gain: 0.0 })
                .collect()
        }
        _ => one("bq_peaking", g),
    }
}

/// PipeWire's coefficients for one stage, normalised (a0 = 1):
/// b0, b1, b2, a1, a2.
pub fn coeffs(st: &Stage, fs: f64) -> [f64; 5] {
    let nf = clamp(st.freq * 2.0 / fs, 0.0, 1.0);
    let a = 10f64.powf(st.gain / 40.0);
    let w0 = std::f64::consts::PI * nf;
    let (k, alpha) = (w0.cos(), w0.sin() / (2.0 * st.q));
    let (b0, b1, b2, a0, a1, a2) = match st.label {
        "bq_lowpass" => ((1.0 - k) / 2.0, 1.0 - k, (1.0 - k) / 2.0, 1.0 + alpha, -2.0 * k, 1.0 - alpha),
        "bq_highpass" => ((1.0 + k) / 2.0, -(1.0 + k), (1.0 + k) / 2.0, 1.0 + alpha, -2.0 * k, 1.0 - alpha),
        "bq_bandpass" => (alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * k, 1.0 - alpha),
        "bq_notch" => (1.0, -2.0 * k, 1.0, 1.0 + alpha, -2.0 * k, 1.0 - alpha),
        "bq_lowshelf" => {
            let (k2, ap, am) = (2.0 * a.sqrt() * alpha, a + 1.0, a - 1.0);
            (a * (ap - am * k + k2), 2.0 * a * (am - ap * k), a * (ap - am * k - k2), ap + am * k + k2, -2.0 * (am + ap * k), ap + am * k - k2)
        }
        "bq_highshelf" => {
            let (k3, bp, bm) = (2.0 * a.sqrt() * alpha, a + 1.0, a - 1.0);
            (a * (bp + bm * k + k3), -2.0 * a * (bm + bp * k), a * (bp + bm * k - k3), bp - bm * k + k3, 2.0 * (bm - bp * k), bp - bm * k - k3)
        }
        _ => (1.0 + alpha * a, -2.0 * k, 1.0 - alpha * a, 1.0 + alpha / a, -2.0 * k, 1.0 - alpha / a),
    };
    [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
}

/// |H| in dB at f, for normalised coefficients.
pub fn mag_db(c: &[f64; 5], f: f64, fs: f64) -> f64 {
    let w = 2.0 * std::f64::consts::PI * f / fs;
    let (cw, c2w) = (w.cos(), (2.0 * w).cos());
    let [b0, b1, b2, a1, a2] = *c;
    let num = b0 * b0 + b1 * b1 + b2 * b2 + 2.0 * (b0 * b1 + b1 * b2) * cw + 2.0 * b0 * b2 * c2w;
    let den = 1.0 + a1 * a1 + a2 * a2 + 2.0 * (a1 + a1 * a2) * cw + 2.0 * a2 * c2w;
    if num <= 1e-24 {
        return -120.0;
    }
    (10.0 * (num / den).log10()).max(-120.0)
}

/// n frequencies, evenly spaced on a log axis.
pub fn log_freqs(n: usize) -> Vec<f64> {
    let (lo, hi) = (F_MIN.ln(), F_MAX.ln());
    (0..n).map(|i| (lo + (hi - lo) * i as f64 / (n - 1).max(1) as f64).exp()).collect()
}

/// One band's response, in dB, at each of freqs.
pub fn band_curve(b: &Band, freqs: &[f64]) -> Vec<f64> {
    let cs: Vec<[f64; 5]> = stages(b).iter().map(|s| coeffs(s, FS)).collect();
    freqs.iter().map(|f| cs.iter().map(|c| mag_db(c, *f, FS)).sum()).collect()
}

/// Every band that is on, and the preamp, summed.
pub fn total_curve(bands: &[Band], preamp: f64, freqs: &[f64]) -> Vec<f64> {
    let mut out = vec![preamp; freqs.len()];
    for b in bands.iter().filter(|b| b.on) {
        for (o, d) in out.iter_mut().zip(band_curve(b, freqs)) {
            *o += d;
        }
    }
    out
}

/// How far the curve goes above 0 dB, ignoring the preamp.
pub fn peak_boost(bands: &[Band]) -> f64 {
    total_curve(bands, 0.0, &log_freqs(240)).into_iter().fold(0.0, f64::max)
}

/// A band as it is kept: every field present and in range.
pub fn clean(v: &Value, id: i64) -> Band {
    let num = |k: &str| v[k].as_f64().or_else(|| v[k].as_str().and_then(|s| s.parse().ok()));
    let kind = type_of(v["type"].as_str().unwrap_or("")).0.to_string();
    let r = |x: f64, k: f64| (x * k).round() / k;
    Band {
        id: v["id"].as_i64().or_else(|| v["id"].as_f64().map(|f| f as i64)).unwrap_or(id),
        kind,
        freq: r(clamp(num("freq").filter(|f| *f != 0.0).unwrap_or(1000.0), F_MIN, F_MAX), 10.0),
        gain: r(clamp(num("gain").unwrap_or(0.0), -GAIN_MAX, GAIN_MAX), 10.0),
        q: r(clamp(num("q").filter(|f| *f != 0.0).unwrap_or(0.71), Q_MIN, Q_MAX), 100.0),
        slope: num("slope").map(|s| s as i64).filter(|s| SLOPES.contains(s)).unwrap_or(24),
        on: v["on"] != false,
    }
}

pub fn to_json(b: &Band) -> Value {
    json!({ "id": b.id, "type": b.kind, "freq": b.freq, "gain": b.gain, "q": b.q, "slope": b.slope, "on": b.on })
}

pub fn parse(text: &str) -> Vec<Band> {
    let arr: Vec<Value> = serde_json::from_str::<Value>(text).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
    let mut out: Vec<Band> = vec![];
    for (i, v) in arr.iter().enumerate() {
        if out.len() >= MAX_BANDS {
            break;
        }
        let mut b = clean(v, i as i64 + 1);
        while out.iter().any(|x| x.id == b.id) {
            b.id += 1;
        }
        out.push(b);
    }
    out
}

pub fn store(bands: &[Band]) -> String {
    Value::Array(bands.iter().map(to_json).collect()).to_string()
}

pub fn next_id(bands: &[Band]) -> i64 {
    bands.iter().map(|b| b.id).max().unwrap_or(0) + 1
}

/// A sensible new band for where it was asked for: a cut at either end, a
/// shelf near them, a bell in between.
pub fn band_at(freq: f64, gain: f64, id: i64) -> Band {
    let t = if freq < 40.0 {
        "lowcut"
    } else if freq > 15000.0 {
        "highcut"
    } else if freq < 90.0 {
        "lowshelf"
    } else if freq > 9000.0 {
        "highshelf"
    } else {
        "bell"
    };
    clean(
        &json!({ "id": id, "type": t, "freq": freq, "gain": if has_gain(t) { gain } else { 0.0 },
                 "q": if is_cut(t) { 0.71 } else if t == "bell" { 1.0 } else { 0.71 }, "slope": 24, "on": true }),
        id,
    )
}

pub fn fmt_freq(f: f64) -> String {
    if f >= 10000.0 {
        let s = format!("{:.1}", f / 1000.0);
        format!("{}k", s.strip_suffix(".0").unwrap_or(&s))
    } else if f >= 1000.0 {
        let s = format!("{:.2}", f / 1000.0);
        let s = s.strip_suffix('0').unwrap_or(&s).to_string();
        let s = s.strip_suffix(".0").map(str::to_string).unwrap_or(s);
        format!("{s}k")
    } else {
        format!("{}", f.round())
    }
}
pub fn fmt_gain(g: f64) -> String {
    format!("{}{:.1}", if g > 0.0 { "+" } else if g < 0.0 { "−" } else { "" }, g.abs())
}

/// The ten-band equalizer this replaced, as parametric bands.
pub fn from_graphic(gains: &str) -> Vec<Band> {
    let centres = [31.0, 63.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
    let g: Vec<f64> = gains.split(',').map(|v| v.trim().parse().unwrap_or(0.0)).collect();
    let mut out = vec![];
    let mut id = 1;
    for i in 0..10 {
        let gi = g.get(i).copied().unwrap_or(0.0);
        if gi == 0.0 {
            continue;
        }
        let t = if i == 0 { "lowshelf" } else if i == 9 { "highshelf" } else { "bell" };
        out.push(clean(&json!({ "id": id, "type": t, "freq": centres[i], "gain": gi, "q": if i == 0 || i == 9 { 0.7 } else { 1.0 }, "on": true }), id));
        id += 1;
    }
    out
}

// ── presets ─────────────────────────────────────────────────────────────
/// (name, group, bands as (type, freq, gain, q, slope)).
pub type PresetBand = (&'static str, f64, f64, f64, i64);
pub const PRESETS: &[(&str, &str, &[PresetBand])] = &[
    ("Flat", "Basics", &[]),
    ("Bass boost", "Basics", &[("lowcut", 25.0, 0.0, 0.71, 24), ("lowshelf", 110.0, 5.0, 0.6, 24)]),
    ("Bass cut", "Basics", &[("lowshelf", 150.0, -5.0, 0.6, 24)]),
    ("Treble boost", "Basics", &[("highshelf", 6000.0, 4.5, 0.6, 24)]),
    ("Treble cut", "Basics", &[("highshelf", 5000.0, -4.5, 0.6, 24)]),
    ("Loudness", "Basics", &[("lowshelf", 90.0, 5.0, 0.6, 24), ("bell", 3000.0, -1.5, 0.8, 24), ("highshelf", 9000.0, 4.0, 0.6, 24)]),
    ("Warmth", "Character", &[("bell", 200.0, 2.5, 0.8, 24), ("highshelf", 8000.0, -2.0, 0.6, 24)]),
    ("Air", "Character", &[("highshelf", 12000.0, 4.0, 0.5, 24)]),
    ("Clarity", "Character", &[("bell", 300.0, -2.5, 1.0, 24), ("bell", 3500.0, 2.5, 0.9, 24), ("highshelf", 10000.0, 1.5, 0.6, 24)]),
    ("Smile", "Character", &[("lowshelf", 80.0, 4.0, 0.6, 24), ("bell", 800.0, -3.0, 0.6, 24), ("highshelf", 8000.0, 4.0, 0.6, 24)]),
    ("Vocal presence", "Voice", &[("lowcut", 90.0, 0.0, 0.71, 12), ("bell", 250.0, -2.0, 1.2, 24), ("bell", 3000.0, 3.5, 1.0, 24), ("highshelf", 10000.0, 1.5, 0.6, 24)]),
    ("Podcast", "Voice", &[("lowcut", 80.0, 0.0, 0.71, 24), ("bell", 180.0, -2.5, 1.0, 24), ("bell", 2500.0, 3.0, 1.2, 24), ("bell", 6500.0, -2.5, 3.0, 24)]),
    ("De-ess", "Voice", &[("bell", 6800.0, -5.0, 4.0, 24)]),
    ("Laptop speakers", "Device", &[("lowcut", 120.0, 0.0, 0.71, 24), ("bell", 200.0, 3.0, 1.0, 24), ("bell", 900.0, -2.0, 1.0, 24), ("bell", 3000.0, 2.0, 1.0, 24), ("highshelf", 9000.0, 3.0, 0.6, 24)]),
    ("Headphones", "Device", &[("lowshelf", 105.0, 4.0, 0.7, 24), ("bell", 2900.0, 2.0, 1.4, 24), ("bell", 6500.0, -2.0, 3.0, 24), ("highshelf", 10000.0, -1.0, 0.6, 24)]),
    ("Earbuds", "Device", &[("lowshelf", 120.0, 3.0, 0.7, 24), ("bell", 1500.0, -1.5, 1.0, 24), ("bell", 5500.0, -3.0, 2.0, 24), ("highshelf", 11000.0, 2.0, 0.6, 24)]),
    ("Harman (over-ear)", "Target curves", &[("lowshelf", 105.0, 6.0, 0.71, 24), ("bell", 2900.0, -2.5, 1.0, 24), ("highshelf", 8000.0, -2.0, 0.6, 24)]),
    ("Harman (in-ear)", "Target curves", &[("lowshelf", 105.0, 8.0, 0.71, 24), ("bell", 2900.0, -2.0, 1.0, 24), ("highshelf", 9000.0, -3.0, 0.6, 24)]),
    ("Rumble filter", "Tools", &[("lowcut", 35.0, 0.0, 0.71, 48)]),
    ("Hum notch", "Tools", &[("notch", 60.0, 0.0, 12.0, 24), ("notch", 120.0, 0.0, 12.0, 24), ("notch", 180.0, 0.0, 12.0, 24)]),
    ("Telephone", "Tools", &[("lowcut", 300.0, 0.0, 0.71, 24), ("highcut", 3400.0, 0.0, 0.71, 24), ("bell", 1500.0, 3.0, 1.0, 24)]),
];

/// A built-in preset's bands, ready to keep.
pub fn preset_bands(name: &str) -> Vec<Band> {
    PRESETS
        .iter()
        .find(|p| p.0 == name)
        .map(|p| {
            p.2.iter()
                .enumerate()
                .map(|(i, b)| clean(&json!({ "type": b.0, "freq": b.1, "gain": b.2, "q": b.3, "slope": b.4, "on": true }), i as i64 + 1))
                .collect()
        })
        .unwrap_or_default()
}

/// The bands in the chain: every band that is on, and the gain types even
/// while off (at 0 dB), so switching one is a change of gain, not a new
/// chain.
pub fn chain_bands(bands: &[Band]) -> Vec<Band> {
    bands.iter().filter(|b| b.on || has_gain(&b.kind)).cloned().collect()
}
/// What the chain is built from; anything else about a band moves live.
pub fn structure(bands: &[Band]) -> String {
    chain_bands(bands)
        .iter()
        .map(|b| format!("{}:{}{}", b.id, b.kind, if is_cut(&b.kind) { format!("/{}", b.slope) } else { String::new() }))
        .collect::<Vec<_>>()
        .join(",")
}

fn num(v: f64) -> String {
    format!("{v:.2}")
}

/// The live parameters for `pw-cli set-param <node> Props`: every stage's
/// frequency, Q and gain, and the preamp.
pub fn gain_params(bands: &[Band], preamp: f64) -> String {
    let mut parts = vec![format!("\"preamp:Gain\" {}", num(preamp))];
    for b in chain_bands(bands) {
        for (k, st) in stages(&b).iter().enumerate() {
            let n = format!("\"b{}_{}:", b.id, k);
            parts.push(format!("{n}Freq\" {}", num(st.freq)));
            parts.push(format!("{n}Q\" {}", num(st.q)));
            parts.push(format!("{n}Gain\" {}", num(if b.on { st.gain } else { 0.0 })));
        }
    }
    format!("{{ params = [ {} ] }}", parts.join(" "))
}

/// The equalizer's filter-chain arguments (AudioFx.eqArgs).
pub fn eq_args(bands: &[Band], preamp: f64, target: &str, sink_name: &str, out_name: &str) -> String {
    let mut nodes = vec![format!(
        "{{ type = builtin name = preamp label = bq_highshelf control = {{ \"Freq\" = 0.0 \"Q\" = 1.0 \"Gain\" = {} }} }}",
        num(preamp)
    )];
    let mut links = vec![];
    let mut prev = "preamp".to_string();
    for b in chain_bands(bands) {
        for (k, st) in stages(&b).iter().enumerate() {
            let name = format!("b{}_{}", b.id, k);
            nodes.push(format!(
                "{{ type = builtin name = {name} label = {} control = {{ \"Freq\" = {} \"Q\" = {} \"Gain\" = {} }} }}",
                st.label,
                num(st.freq),
                num(st.q),
                num(if b.on { st.gain } else { 0.0 })
            ));
            links.push(format!("{{ output = \"{prev}:Out\" input = \"{name}:In\" }}"));
            prev = name;
        }
    }
    let target = if target.is_empty() { String::new() } else { format!("\n                target.object = \"{}\"", target.replace('"', "")) };
    let mut s = String::from("{\n            node.description = \"Equalizer\"\n            media.name = \"Equalizer\"\n            filter.graph = {\n");
    s += &format!("                nodes = [\n                    {}\n                ]\n", nodes.join("\n                    "));
    if !links.is_empty() {
        s += &format!("                links = [\n                    {}\n                ]\n", links.join("\n                    "));
    }
    s += "            }\n            audio.channels = 2\n            audio.position = [ FL FR ]\n";
    s += &format!("            capture.props = {{\n                node.name = \"{sink_name}\"\n                node.description = \"Equalizer\"\n                media.class = Audio/Sink\n            }}\n");
    s += &format!("            playback.props = {{\n                node.name = \"{out_name}\"\n                node.passive = true\n                application.name = \"hyprshell-eq\"{target}\n            }}\n        }}");
    s
}

/// Noise suppression's filter-chain arguments (AudioFx.nsArgs).
pub fn ns_args(plugin: &str, threshold: f64, target: &str, in_name: &str, source_name: &str) -> String {
    let target = if target.is_empty() { String::new() } else { format!("\n                target.object = \"{}\"", target.replace('"', "")) };
    format!(
        "{{\n            node.description = \"Noise suppression\"\n            media.name = \"Noise suppression\"\n            filter.graph = {{\n                nodes = [\n                    {{ type = ladspa name = rnnoise plugin = \"{plugin}\" label = noise_suppressor_mono\n                      control = {{ \"VAD Threshold (%)\" = {} \"VAD Grace Period (ms)\" = 200.0 \"Retroactive VAD Grace (ms)\" = 0.0 }} }}\n                ]\n            }}\n            audio.rate = 48000\n            audio.position = [ MONO ]\n            capture.props = {{\n                node.name = \"{in_name}\"\n                node.passive = true\n                application.name = \"hyprshell-ns\"{target}\n            }}\n            playback.props = {{\n                node.name = \"{source_name}\"\n                node.description = \"Microphone (noise suppressed)\"\n                media.class = Audio/Source\n            }}\n        }}",
        num(threshold)
    )
}

/// A whole PipeWire configuration around a filter-chain, to run it as a
/// process of its own (AudioFx.conf).
pub fn conf(args: &str) -> String {
    format!(
        "context.properties = {{ log.level = 0 }}\ncontext.spa-libs = {{\n    audio.convert.* = audioconvert/libspa-audioconvert\n    support.* = support/libspa-support\n}}\ncontext.modules = [\n    {{ name = libpipewire-module-rt args = {{ nice.level = -11 }} flags = [ ifexists nofail ] }}\n    {{ name = libpipewire-module-protocol-native }}\n    {{ name = libpipewire-module-client-node }}\n    {{ name = libpipewire-module-adapter }}\n    {{ name = libpipewire-module-filter-chain\n        args = {args}\n    }}\n]\n"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes() {
        let b = clean(&json!({ "type": "bell", "freq": 1000, "gain": 6, "q": 1.0 }), 1);
        let c = band_curve(&b, &[1000.0, 100.0]);
        assert!((c[0] - 6.0).abs() < 0.05, "a bell peaks at its gain: {}", c[0]);
        assert!(c[1].abs() < 0.3);
        let cut = clean(&json!({ "type": "lowcut", "freq": 100, "slope": 48 }), 1);
        assert_eq!(stages(&cut).len(), 4);
        assert!(band_curve(&cut, &[25.0])[0] < -40.0);
        assert_eq!(fmt_freq(1250.0), "1.25k");
        assert_eq!(fmt_freq(1500.0), "1.5k");
        assert_eq!(fmt_freq(12000.0), "12k");
        assert_eq!(fmt_gain(-3.0), "−3.0");
        let bands = parse(r#"[{"id":1,"type":"bell","freq":1000,"gain":6},{"id":1,"type":"notch","freq":8000}]"#);
        assert_eq!(bands[1].id, 2);
        let pb = peak_boost(&bands);
        assert!(pb > 5.5, "peak {pb} from {bands:?}");
        assert_eq!(preset_bands("Hum notch").len(), 3);
    }
}
