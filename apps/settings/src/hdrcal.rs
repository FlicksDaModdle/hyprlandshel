//! Settings → Display → HDR calibration → Calibrate (HdrCalibration.qml):
//! Windows' HDR Calibration app, on the display being calibrated. Three
//! test patterns — minimum luminance, maximum luminance and maximum
//! full-frame luminance, each "drag the slider until the pattern isn't
//! visible" — then colour saturation and a before/after comparison. The
//! results become the display's luminance figures (what HDR content is
//! tone-mapped to) and its SDR black.
//!
//! How a shell that draws in SDR shows a pattern at, say, 900 nits: while a
//! test runs, Hyprland is told SDR white is far brighter than any panel
//! (sdr_max_luminance), with a pure 2.2 curve, a 0-nit black and no tone
//! mapping of its own (max_luminance 10000). An SDR value v then leaves the
//! compositor as W·v^2.2 nits, so the pattern is drawn at (L/W)^(1/2.2) and
//! the background at full white, which the panel clips to its peak. Once L
//! is past what the panel can do, pattern and background clip to the same
//! light and the pattern disappears: as in Windows, that's the panel's
//! limit. Nothing is saved until Save; Cancel or Esc shows the old values.

use crate::hypr;
use crate::prefs::Prefs;
use serde_json::{json, Map, Value};

pub const TITLES: [&str; 6] = ["HDR Calibration", "Minimum luminance", "Maximum luminance", "Maximum full frame luminance", "Color saturation", "Finish"];
pub const LAST: i32 = 5;
/// SDR white while each test runs, in nits: low for the near-black test,
/// so its tiny steps still fall on 8-bit codes; far above any panel for
/// the bright ones.
const WHITE_LOW: f64 = 10.0;
const WHITE_HIGH: f64 = 4000.0;

pub struct Cal {
    pub output: String,
    pub step: i32,
    pub lmin: f64,
    pub lmax: f64,
    pub lfull: f64,
    pub sat: f64,
    /// The values to show again on Cancel and as "Before".
    pub before: Map<String, Value>,
    /// What's kept besides the results (SDR content brightness and curve).
    keep: Map<String, Value>,
    pub show_before: bool,
    pub finished: bool,
    /// Hyprland decodes the shell's own windows with its global curve
    /// (Devices.sdrCurve), not the monitor's sdr_eotf.
    srgb_curve: bool,
}

fn sdr_curve() -> String {
    let state = std::env::var("XDG_STATE_HOME").ok().filter(|s| !s.is_empty()).map(std::path::PathBuf::from).unwrap_or_else(|| hyprshell_kit::home().join(".local/state"));
    let c = std::fs::read_to_string(state.join("hyprshell/sdr-curve")).unwrap_or_default().trim().to_string();
    if ["gamma22force", "gamma22", "srgb", "default"].contains(&c.as_str()) {
        c
    } else {
        "gamma22force".into()
    }
}

impl Cal {
    pub fn new(p: &Prefs, output: &str) -> Cal {
        let caps = crate::display::edid_caps().get(output).cloned().unwrap_or(json!({}));
        let had = hypr::display_map(p).get(output).cloned().unwrap_or(json!({}));
        let pick = |k: &str, or: Value| had.get(k).filter(|v| !v.is_null()).cloned().unwrap_or(or);
        // Devices.colourDefaults.
        let mut before = Map::new();
        for (k, d) in [("sdr_eotf", json!("default")), ("sdr_min_luminance", json!(0.2)), ("sdr_max_luminance", json!(80)), ("sdrbrightness", json!(1)), ("sdrsaturation", json!(1))] {
            before.insert(k.into(), pick(k, d));
        }
        let cap = |k: &str| caps[k].as_f64().filter(|v| *v > 0.0);
        for (k, v) in [
            ("max_luminance", cap("maxLum").map(|v| json!(v.round() as i64))),
            ("max_avg_luminance", cap("maxAvgLum").map(|v| json!(v.round() as i64))),
            ("min_luminance", cap("minLum").map(|v| json!(v))),
        ] {
            if let Some(v) = had.get(k).filter(|v| !v.is_null()).cloned().or(v) {
                before.insert(k.into(), v);
            }
        }
        let mut keep = Map::new();
        keep.insert("sdr_eotf".into(), pick("sdr_eotf", json!("gamma22")));
        keep.insert("sdr_max_luminance".into(), pick("sdr_max_luminance", json!(203)));
        keep.insert("sdrbrightness".into(), pick("sdrbrightness", json!(1)));
        let num = |k: &str, or: f64| had.get(k).and_then(|v| v.as_f64()).unwrap_or(or);
        let lmax = num("max_luminance", cap("maxLum").map(f64::round).unwrap_or(1000.0));
        let curve = sdr_curve();
        Cal {
            output: output.into(),
            step: 0,
            lmin: num("min_luminance", cap("minLum").unwrap_or(0.0)),
            lmax,
            lfull: num("max_avg_luminance", cap("maxAvgLum").map(f64::round).unwrap_or((lmax * 0.6).round())),
            sat: num("sdrsaturation", 1.0),
            before,
            keep,
            show_before: false,
            finished: false,
            srgb_curve: curve == "srgb" || curve == "default",
        }
    }

    fn test_values(white: f64) -> Map<String, Value> {
        json!({ "sdr_eotf": "gamma22", "sdr_min_luminance": 0, "sdr_max_luminance": white, "sdrbrightness": 1, "sdrsaturation": 1,
                "max_luminance": 10000, "max_avg_luminance": 10000, "min_luminance": 0 })
        .as_object()
        .cloned()
        .unwrap_or_default()
    }

    pub fn results(&self) -> Map<String, Value> {
        let mut r = self.keep.clone();
        let min = (self.lmin * 10000.0).round() / 10000.0;
        r.insert("min_luminance".into(), json!(min));
        // SDR black at the panel's own: 0.2 nits, Hyprland's default, is a
        // grey on an OLED, and below its floor an LCD crushes shadows.
        r.insert("sdr_min_luminance".into(), json!(min));
        r.insert("max_luminance".into(), json!(self.lmax.round() as i64));
        r.insert("max_avg_luminance".into(), json!(self.lfull.min(self.lmax).round() as i64));
        r.insert("sdrsaturation".into(), json!((self.sat * 100.0).round() / 100.0));
        r
    }

    /// What the display is told for this step.
    pub fn show(&self, p: &Prefs) {
        if self.finished {
            return;
        }
        match self.step {
            1 => hypr::show_colour(p, &self.output, &Self::test_values(WHITE_LOW)),
            2 | 3 => hypr::show_colour(p, &self.output, &Self::test_values(WHITE_HIGH)),
            s if s >= 4 => hypr::show_colour(p, &self.output, &if self.show_before { self.before.clone() } else { self.results() }),
            _ => {}
        }
    }

    pub fn save(&mut self, p: &mut Prefs) {
        if self.finished {
            return;
        }
        self.finished = true;
        hypr::save_display(p, &self.output, Value::Object(self.results()));
        hypr::apply_display(p, &self.output);
    }
    pub fn cancel(&mut self, p: &Prefs) {
        if self.finished {
            return;
        }
        self.finished = true;
        if self.step > 0 {
            hypr::show_colour(p, &self.output, &self.before);
        }
    }

    // ── each test's slider ─────────────────────────────────────────────
    // Minimum: 0–0.5 nits on a cubic scale, fine near black where it
    // matters. Maximum and full frame: 100–2500 nits in tens.
    fn value(&self) -> f64 {
        match self.step {
            1 => self.lmin,
            2 => self.lmax,
            _ => self.lfull,
        }
    }
    pub fn frac(&self) -> f64 {
        match self.step {
            1 => (self.lmin / 0.5).cbrt(),
            4 => self.sat - 0.5,
            _ => (self.value() - 100.0) / 2400.0,
        }
    }
    pub fn set_frac(&mut self, f: f64) {
        let f = f.clamp(0.0, 1.0);
        match self.step {
            1 => self.lmin = (0.5 * f * f * f * 10000.0).round() / 10000.0,
            2 => self.lmax = 100.0 + (f * 240.0).round() * 10.0,
            3 => self.lfull = 100.0 + (f * 240.0).round() * 10.0,
            4 => self.sat = ((0.5 + f) * 100.0).round() / 100.0,
            _ => {}
        }
    }
    pub fn nudge(&mut self, dir: i32) {
        let d = dir as f64;
        match self.step {
            1 => {
                // A step in the third decimal near black, coarser above.
                let s = if self.lmin < 0.02 { 0.0005 } else if self.lmin < 0.1 { 0.002 } else { 0.01 };
                self.lmin = (((self.lmin + d * s) * 10000.0).round() / 10000.0).clamp(0.0, 0.5);
            }
            2 => self.lmax = (self.lmax + d * 10.0).clamp(100.0, 2500.0),
            3 => self.lfull = (self.lfull + d * 10.0).clamp(100.0, 2500.0),
            4 => self.sat = (((self.sat + d * 0.01) * 100.0).round() / 100.0).clamp(0.5, 1.5),
            _ => {}
        }
    }

    /// The pattern's grey: L nits with SDR white at W, through the curve
    /// Hyprland decodes the shell's windows with.
    pub fn grey(&self) -> f64 {
        let level = |l: f64, w: f64| {
            let f = (l.max(0.0) / w).min(1.0);
            if !self.srgb_curve {
                f.powf(1.0 / 2.2)
            } else if f <= 0.0031308 {
                f * 12.92
            } else {
                1.055 * f.powf(1.0 / 2.4) - 0.055
            }
        };
        match self.step {
            1 => level(self.lmin, WHITE_LOW),
            2 => level(self.lmax, WHITE_HIGH),
            3 => level(self.lfull, WHITE_HIGH),
            _ => 0.0,
        }
    }

    pub fn value_text(&self) -> String {
        match self.step {
            1 => {
                let t = format!("{:.4}", self.lmin);
                let t = t.trim_end_matches('0');
                let t = if t.ends_with('.') { format!("{t}0") } else { t.to_string() };
                format!("{t} nits")
            }
            4 => format!("{}%", (self.sat * 100.0).round()),
            _ => format!("{} nits", self.value().round()),
        }
    }

    pub fn body(&self) -> String {
        match self.step {
            0 => format!(
                "Calibrate {} for HDR games, video and apps. Three test patterns find how dark and how bright this display really goes, then you set colour saturation. Do it in the light you usually use the display in. Nothing changes until you save; Esc cancels.",
                self.output
            ),
            1 => "Drag the slider until the pattern isn't visible. Arrow keys move it one step at a time.".into(),
            2 | 3 => "Drag the slider until the pattern isn't visible.".into(),
            4 => "Drag the slider until colours look the way you like: vivid but natural, skin tones not orange.".into(),
            _ => if self.show_before {
                "Showing how it was before. Switch to After to see the calibrated result."
            } else {
                "Calibrated. Switch to Before to compare, then save to keep it for this display."
            }
            .into(),
        }
    }

    pub fn summary(&self) -> String {
        let r = self.results();
        format!(
            "Black {} nits · peak {} nits · full screen {} nits · saturation {}%",
            r["min_luminance"],
            r["max_luminance"],
            r["max_avg_luminance"],
            (self.sat * 100.0).round()
        )
    }
}
