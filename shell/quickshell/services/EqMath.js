.pragma library

// The parametric equalizer's arithmetic (services/AudioFx.qml draws on it
// to build the PipeWire filter-chain, modules/settings/EqGraph.qml to draw
// the curve), in one place so what is drawn is what is heard.
//
// Every band is one or more of PipeWire's builtin biquads. The formulas
// below are PipeWire's own (spa/plugins/audioconvert/biquad.c): the RBJ
// cookbook, Q on every type, shelves included, and the frequency taken as
// a fraction of Nyquist. The curve is worked out at 48 kHz, which is what
// the chain runs at on almost every machine; at 44.1 kHz the top octave
// differs by a hair.

var FS = 48000;
var F_MIN = 20;
var F_MAX = 20000;
var GAIN_MAX = 24;
var Q_MIN = 0.1;
var Q_MAX = 18;
var MAX_BANDS = 16;

// What a band can be. `gain`: whether it has one; `slope`: whether it is
// a cut, whose steepness is chosen rather than its Q alone.
var TYPES = [
    { key: "bell",      label: "Bell",       short: "Bell",  gain: true,  slope: false },
    { key: "lowshelf",  label: "Low shelf",  short: "LS",    gain: true,  slope: false },
    { key: "highshelf", label: "High shelf", short: "HS",    gain: true,  slope: false },
    { key: "lowcut",    label: "Low cut",    short: "LC",    gain: false, slope: true },
    { key: "highcut",   label: "High cut",   short: "HC",    gain: false, slope: true },
    { key: "notch",     label: "Notch",      short: "Notch", gain: false, slope: false },
    { key: "bandpass",  label: "Band pass",  short: "BP",    gain: false, slope: false }
];
var SLOPES = [12, 24, 36, 48];

function typeOf(key) {
    for (var i = 0; i < TYPES.length; i++) if (TYPES[i].key === key) return TYPES[i];
    return TYPES[0];
}
function hasGain(key) { return typeOf(key).gain; }
function isCut(key) { return typeOf(key).slope; }

// A cut steeper than 12 dB/octave is a cascade of second-order sections
// with Butterworth Qs — flat to the corner, then falling at the slope.
// The band's own Q is the resonance at the corner: it scales the
// sharpest section, so 0.71 is Butterworth and higher peaks before the
// fall, as in a DAW's cut.
var BUTTERWORTH = {
    12: [0.70711],
    24: [0.54120, 1.30656],
    36: [0.51764, 0.70711, 1.93185],
    48: [0.50980, 0.60134, 0.89998, 2.56292]
};

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

// The PipeWire nodes one band becomes: [{ label, freq, q, gain }].
function stages(b) {
    var f = clamp(Number(b.freq) || 1000, F_MIN, F_MAX);
    var q = clamp(Number(b.q) || 0.71, Q_MIN, Q_MAX);
    var g = clamp(Number(b.gain) || 0, -GAIN_MAX, GAIN_MAX);
    switch (b.type) {
    case "lowshelf":  return [{ label: "bq_lowshelf",  freq: f, q: q, gain: g }];
    case "highshelf": return [{ label: "bq_highshelf", freq: f, q: q, gain: g }];
    case "notch":     return [{ label: "bq_notch",     freq: f, q: q, gain: 0 }];
    case "bandpass":  return [{ label: "bq_bandpass",  freq: f, q: q, gain: 0 }];
    case "lowcut":
    case "highcut": {
        var label = b.type === "lowcut" ? "bq_highpass" : "bq_lowpass";
        var qs = BUTTERWORTH[b.slope] || BUTTERWORTH[12];
        var res = q / 0.70711;
        var out = [];
        for (var i = 0; i < qs.length; i++)
            out.push({ label: label, freq: f, q: i === qs.length - 1 ? clamp(qs[i] * res, Q_MIN, Q_MAX * 2) : qs[i], gain: 0 });
        return out;
    }
    default:          return [{ label: "bq_peaking",   freq: f, q: q, gain: g }];
    }
}

// PipeWire's coefficients for one stage, normalised (a0 = 1).
function coeffs(st, fs) {
    var nf = st.freq * 2 / (fs || FS);       // fraction of Nyquist
    nf = clamp(nf, 0, 1);
    var A = Math.pow(10, st.gain / 40);
    var w0 = Math.PI * nf, k = Math.cos(w0), alpha = Math.sin(w0) / (2 * st.q);
    var b0, b1, b2, a0, a1, a2;
    switch (st.label) {
    case "bq_lowpass":
        b0 = (1 - k) / 2; b1 = 1 - k; b2 = (1 - k) / 2; a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    case "bq_highpass":
        b0 = (1 + k) / 2; b1 = -(1 + k); b2 = (1 + k) / 2; a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    case "bq_bandpass":
        b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    case "bq_notch":
        b0 = 1; b1 = -2 * k; b2 = 1; a0 = 1 + alpha; a1 = -2 * k; a2 = 1 - alpha; break;
    case "bq_lowshelf": {
        var k2 = 2 * Math.sqrt(A) * alpha, ap = A + 1, am = A - 1;
        b0 = A * (ap - am * k + k2); b1 = 2 * A * (am - ap * k); b2 = A * (ap - am * k - k2);
        a0 = ap + am * k + k2; a1 = -2 * (am + ap * k); a2 = ap + am * k - k2; break;
    }
    case "bq_highshelf": {
        var k3 = 2 * Math.sqrt(A) * alpha, bp = A + 1, bm = A - 1;
        b0 = A * (bp + bm * k + k3); b1 = -2 * A * (bm + bp * k); b2 = A * (bp + bm * k - k3);
        a0 = bp - bm * k + k3; a1 = 2 * (bm - bp * k); a2 = bp - bm * k - k3; break;
    }
    default: // bq_peaking
        b0 = 1 + alpha * A; b1 = -2 * k; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * k; a2 = 1 - alpha / A;
    }
    return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 };
}

// |H| in dB at f, for normalised coefficients.
function magDb(c, f, fs) {
    var w = 2 * Math.PI * f / (fs || FS);
    var cw = Math.cos(w), c2w = Math.cos(2 * w);
    var num = c.b0 * c.b0 + c.b1 * c.b1 + c.b2 * c.b2 + 2 * (c.b0 * c.b1 + c.b1 * c.b2) * cw + 2 * c.b0 * c.b2 * c2w;
    var den = 1 + c.a1 * c.a1 + c.a2 * c.a2 + 2 * (c.a1 + c.a1 * c.a2) * cw + 2 * c.a2 * c2w;
    if (num <= 1e-24) return -120;
    return Math.max(-120, 10 * Math.log(num / den) / Math.LN10);
}

// The frequencies a curve is drawn at: n, evenly spaced on a log axis.
function logFreqs(n) {
    var out = [], lo = Math.log(F_MIN), hi = Math.log(F_MAX);
    for (var i = 0; i < n; i++) out.push(Math.exp(lo + (hi - lo) * i / (n - 1)));
    return out;
}

// One band's response, in dB, at each of freqs.
function bandCurve(b, freqs) {
    var cs = stages(b).map(function (s) { return coeffs(s); });
    return freqs.map(function (f) {
        var d = 0;
        for (var i = 0; i < cs.length; i++) d += magDb(cs[i], f);
        return d;
    });
}

// Every band that is on, and the preamp, summed.
function totalCurve(bands, preamp, freqs) {
    var out = freqs.map(function () { return Number(preamp) || 0; });
    for (var i = 0; i < bands.length; i++) {
        if (!bands[i].on) continue;
        var c = bandCurve(bands[i], freqs);
        for (var j = 0; j < out.length; j++) out[j] += c[j];
    }
    return out;
}

// The loudest the curve goes above 0 dB, ignoring the preamp: how far the
// preamp has to come down for nothing to clip.
function peakBoost(bands, freqs) {
    var c = totalCurve(bands, 0, freqs || logFreqs(240));
    var top = 0;
    for (var i = 0; i < c.length; i++) top = Math.max(top, c[i]);
    return top;
}

// A band as it is kept: every field present and in range.
function clean(b, id) {
    var t = typeOf(b && b.type).key;
    return {
        id: (b && b.id !== undefined) ? Number(b.id) : id,
        type: t,
        freq: Math.round(clamp(Number(b && b.freq) || 1000, F_MIN, F_MAX) * 10) / 10,
        gain: Math.round(clamp(Number(b && b.gain) || 0, -GAIN_MAX, GAIN_MAX) * 10) / 10,
        q: Math.round(clamp(Number(b && b.q) || 0.71, Q_MIN, Q_MAX) * 100) / 100,
        slope: SLOPES.indexOf(Number(b && b.slope)) >= 0 ? Number(b.slope) : 24,
        on: !(b && b.on === false)
    };
}

function parse(text) {
    var arr;
    try { arr = JSON.parse(text || "[]"); } catch (e) { arr = []; }
    if (!Array.isArray(arr)) arr = [];
    var out = [], used = {};
    for (var i = 0; i < arr.length && out.length < MAX_BANDS; i++) {
        var b = clean(arr[i], i + 1);
        while (used[b.id]) b.id++;
        used[b.id] = true;
        out.push(b);
    }
    return out;
}

function nextId(bands) {
    var m = 0;
    for (var i = 0; i < bands.length; i++) m = Math.max(m, bands[i].id);
    return m + 1;
}

// A sensible new band for where it was asked for: a cut at either end, a
// shelf near them, a bell in between.
function bandAt(freq, gain, id) {
    var t = freq < 40 ? "lowcut" : freq > 15000 ? "highcut"
          : freq < 90 ? "lowshelf" : freq > 9000 ? "highshelf" : "bell";
    return clean({ id: id, type: t, freq: freq, gain: hasGain(t) ? gain : 0,
                   q: isCut(t) ? 0.71 : (t === "bell" ? 1.0 : 0.71), slope: 24, on: true }, id);
}

function fmtFreq(f) {
    if (f >= 10000) return (f / 1000).toFixed(1).replace(/\.0$/, "") + "k";
    if (f >= 1000) return (f / 1000).toFixed(2).replace(/0$/, "").replace(/\.0$/, "") + "k";
    return Math.round(f) + "";
}
function fmtGain(g) { return (g > 0 ? "+" : g < 0 ? "−" : "") + Math.abs(g).toFixed(1); }

// The ten-band equalizer this replaced, as parametric bands: the bands it
// had boosted or cut, where they were, as they sounded (shelves at the
// ends, bells between). Bands left at 0 are left out.
function fromGraphic(gainsText) {
    var centres = [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    var g = String(gainsText || "").split(",").map(function (v) { return parseFloat(v) || 0; });
    var out = [], id = 1;
    for (var i = 0; i < 10; i++) {
        if (!g[i]) continue;
        out.push(clean({ id: id++, type: i === 0 ? "lowshelf" : i === 9 ? "highshelf" : "bell",
                         freq: centres[i], gain: g[i], q: i === 0 || i === 9 ? 0.7 : 1.0, on: true }, id));
    }
    return out;
}

// ── presets ──────────────────────────────────────────────────────────────
// Starting points, each a handful of bands placed where an engineer would
// put them. Gains are modest: the preamp is set from the curve when one is
// applied, so nothing clips.
function B(type, freq, gain, q, slope) { return { type: type, freq: freq, gain: gain || 0, q: q || 0.71, slope: slope || 24, on: true }; }
var PRESETS = [
    { name: "Flat", group: "Basics", bands: [] },
    { name: "Bass boost", group: "Basics", bands: [B("lowcut", 25, 0, 0.71, 24), B("lowshelf", 110, 5, 0.6)] },
    { name: "Bass cut", group: "Basics", bands: [B("lowshelf", 150, -5, 0.6)] },
    { name: "Treble boost", group: "Basics", bands: [B("highshelf", 6000, 4.5, 0.6)] },
    { name: "Treble cut", group: "Basics", bands: [B("highshelf", 5000, -4.5, 0.6)] },
    { name: "Loudness", group: "Basics", bands: [B("lowshelf", 90, 5, 0.6), B("bell", 3000, -1.5, 0.8), B("highshelf", 9000, 4, 0.6)] },
    { name: "Warmth", group: "Character", bands: [B("bell", 200, 2.5, 0.8), B("highshelf", 8000, -2, 0.6)] },
    { name: "Air", group: "Character", bands: [B("highshelf", 12000, 4, 0.5)] },
    { name: "Clarity", group: "Character", bands: [B("bell", 300, -2.5, 1.0), B("bell", 3500, 2.5, 0.9), B("highshelf", 10000, 1.5, 0.6)] },
    { name: "Smile", group: "Character", bands: [B("lowshelf", 80, 4, 0.6), B("bell", 800, -3, 0.6), B("highshelf", 8000, 4, 0.6)] },
    { name: "Vocal presence", group: "Voice", bands: [B("lowcut", 90, 0, 0.71, 12), B("bell", 250, -2, 1.2), B("bell", 3000, 3.5, 1.0), B("highshelf", 10000, 1.5, 0.6)] },
    { name: "Podcast", group: "Voice", bands: [B("lowcut", 80, 0, 0.71, 24), B("bell", 180, -2.5, 1.0), B("bell", 2500, 3, 1.2), B("bell", 6500, -2.5, 3.0)] },
    { name: "De-ess", group: "Voice", bands: [B("bell", 6800, -5, 4.0)] },
    { name: "Laptop speakers", group: "Device", bands: [B("lowcut", 120, 0, 0.71, 24), B("bell", 200, 3, 1.0), B("bell", 900, -2, 1.0), B("bell", 3000, 2, 1.0), B("highshelf", 9000, 3, 0.6)] },
    { name: "Headphones", group: "Device", bands: [B("lowshelf", 105, 4, 0.7), B("bell", 2900, 2, 1.4), B("bell", 6500, -2, 3.0), B("highshelf", 10000, -1, 0.6)] },
    { name: "Earbuds", group: "Device", bands: [B("lowshelf", 120, 3, 0.7), B("bell", 1500, -1.5, 1.0), B("bell", 5500, -3, 2.0), B("highshelf", 11000, 2, 0.6)] },
    { name: "Rumble filter", group: "Tools", bands: [B("lowcut", 35, 0, 0.71, 48)] },
    { name: "Hum notch", group: "Tools", bands: [B("notch", 60, 0, 12), B("notch", 120, 0, 12), B("notch", 180, 0, 12)] },
    { name: "Telephone", group: "Tools", bands: [B("lowcut", 300, 0, 0.71, 24), B("highcut", 3400, 0, 0.71, 24), B("bell", 1500, 3, 1.0)] }
];

// A preset's bands, ready to keep: ids given, everything checked.
function presetBands(p) {
    return (p.bands || []).map(function (b, i) { return clean(b, i + 1); });
}
