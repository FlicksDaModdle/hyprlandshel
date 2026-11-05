//! The desktop's ground (modules/background/Wallpaper.qml): the chosen
//! picture, cropped to fill the screen, or the theme's tinted gradient
//! (GradientGround.qml: a diagonal wash and two soft pools of colour). Drawn
//! once per screen at its own pixel size, on a helper thread, straight into
//! the buffer the compositor shows.
//!
//! A live (video) wallpaper is mpvpaper on the layer above it, as
//! services/LiveWallpaper.qml runs it; this keeps it running while the shell
//! is, and it goes when the shell does.
//!
//! The shader styles (aurora, waves, topography and the rest) need the
//! graphics card; until they come, they show as the gradient.

use serde_json::Value;
use std::path::PathBuf;

#[derive(Clone, PartialEq)]
pub enum Spec {
    Picture(PathBuf),
    /// Appearance.tintSpec: a, b, and the two pools ("" for none).
    Gradient { a: [u8; 3], b: [u8; 3], g1: Option<[u8; 3]>, g2: Option<[u8; 3]> },
}

fn hex(s: &str) -> Option<[u8; 3]> {
    let h = s.trim_start_matches('#');
    if h.len() < 6 {
        return None;
    }
    let p = |i: usize| u8::from_str_radix(&h[i..i + 2], 16).ok();
    Some([p(0)?, p(2)?, p(4)?])
}

/// What theme.json asks for.
pub fn spec(raw: &Value, dark: bool) -> Spec {
    let wall = raw["wallpaper"].as_str().unwrap_or("");
    if !wall.is_empty() && std::path::Path::new(wall).exists() {
        return Spec::Picture(PathBuf::from(wall));
    }
    // Appearance.qml's TINTS.
    let (a, b, g1, g2) = match (dark, raw["tint"].as_str().unwrap_or("Warm")) {
        (false, "Neutral") => ("#f5f4f4", "#e4e2e2", "#e9e7e6", ""),
        (false, "Cool") => ("#f2f4f5", "#e2e5e7", "#d7dee2", "#dcdcde"),
        (false, _) => ("#f6f4f3", "#e7e3e1", "#ffd9d0", "#dcd8d6"),
        (true, "Neutral") => ("#221f1e", "#151413", "#33302f", ""),
        (true, "Cool") => ("#1d2022", "#131516", "#1e2b33", "#24282a"),
        (true, _) => ("#24211f", "#161514", "#4a2119", "#2a2827"),
    };
    Spec::Gradient { a: hex(a).unwrap_or([0; 3]), b: hex(b).unwrap_or([0; 3]), g1: hex(g1), g2: hex(g2) }
}

/// Draws it into `out`, BGRX, `w`×`h`. None if a picture can't be read
/// (then the gradient is drawn instead by the caller).
pub fn draw(spec: &Spec, w: u32, h: u32) -> Option<Vec<u8>> {
    match spec {
        Spec::Picture(p) => picture(p, w, h),
        Spec::Gradient { a, b, g1, g2 } => Some(gradient(*a, *b, *g1, *g2, w, h)),
    }
}

fn picture(path: &std::path::Path, w: u32, h: u32) -> Option<Vec<u8>> {
    let img = image::open(path).ok()?.to_rgb8();
    // PreserveAspectCrop: fill the screen, cut off what overhangs.
    let filled = image::imageops::resize(
        &img,
        {
            let k = (w as f32 / img.width() as f32).max(h as f32 / img.height() as f32);
            ((img.width() as f32 * k).ceil() as u32).max(w)
        },
        {
            let k = (w as f32 / img.width() as f32).max(h as f32 / img.height() as f32);
            ((img.height() as f32 * k).ceil() as u32).max(h)
        },
        image::imageops::FilterType::CatmullRom,
    );
    let (ox, oy) = ((filled.width() - w) / 2, (filled.height() - h) / 2);
    let mut out = vec![0u8; (w * h * 4) as usize];
    for y in 0..h {
        for x in 0..w {
            let p = filled.get_pixel(ox + x, oy + y);
            let i = ((y * w + x) * 4) as usize;
            out[i] = p[2];
            out[i + 1] = p[1];
            out[i + 2] = p[0];
            out[i + 3] = 255;
        }
    }
    Some(out)
}

/// GradientGround.qml: a linear wash from a (top left) to b, along a line
/// tilted 0.21 of the width across the height; a pool of g1 at the top
/// right (radius 0.62 of the width, gone by 58 %), one of g2 at the bottom
/// left (0.55, gone by 62 %).
fn gradient(a: [u8; 3], b: [u8; 3], g1: Option<[u8; 3]>, g2: Option<[u8; 3]>, w: u32, h: u32) -> Vec<u8> {
    let (fw, fh) = (w as f32, h as f32);
    let (vx, vy) = (fw * 0.21, fh);
    let vlen2 = vx * vx + vy * vy;
    let lerp = |p: [u8; 3], q: [u8; 3], t: f32| -> [f32; 3] {
        [0, 1, 2].map(|i| p[i] as f32 + (q[i] as f32 - p[i] as f32) * t)
    };
    let pools: Vec<(f32, f32, f32, f32, [u8; 3])> = [
        g1.map(|c| (fw * 0.78, fh * 0.04, fw * 0.62, 0.58, c)),
        g2.map(|c| (fw * 0.04, fh * 0.96, fw * 0.55, 0.62, c)),
    ]
    .into_iter()
    .flatten()
    .collect();
    let mut out = vec![0u8; (w * h * 4) as usize];
    for y in 0..h {
        for x in 0..w {
            let (px, py) = (x as f32 + 0.5, y as f32 + 0.5);
            let t = ((px * vx + py * vy) / vlen2).clamp(0.0, 1.0);
            let mut c = lerp(a, b, t);
            for &(cx, cy, r, end, col) in &pools {
                let d = ((px - cx).powi(2) + (py - cy).powi(2)).sqrt() / r;
                if d < end {
                    // From the colour at the centre to clear at `end`.
                    let alpha = 1.0 - d / end;
                    for i in 0..3 {
                        c[i] = c[i] * (1.0 - alpha) + col[i] as f32 * alpha;
                    }
                }
            }
            // A touch of noise against banding on the slow wash.
            let n = (((x.wrapping_mul(73856093) ^ y.wrapping_mul(19349663)) % 7) as f32 - 3.0) * 0.25;
            let i = ((y * w + x) * 4) as usize;
            out[i] = (c[2] + n).clamp(0.0, 255.0) as u8;
            out[i + 1] = (c[1] + n).clamp(0.0, 255.0) as u8;
            out[i + 2] = (c[0] + n).clamp(0.0, 255.0) as u8;
            out[i + 3] = 255;
        }
    }
    out
}

/// mpvpaper, for a live wallpaper: started with the shell's options, and
/// again if it stops (twice in a row within 20 s and it is left alone).
pub struct Live {
    child: Option<std::process::Child>,
    started: std::time::Instant,
    quick_failures: u32,
    retry_at: Option<std::time::Instant>,
    wanted: Option<(String, String)>,
}

fn is_video(p: &str) -> bool {
    let l = p.to_lowercase();
    [".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".gif"].iter().any(|e| l.ends_with(e))
}

impl Live {
    pub fn new() -> Live {
        Live { child: None, started: std::time::Instant::now(), quick_failures: 0, retry_at: None, wanted: None }
    }

    /// mpv's options, as LiveWallpaper.mpvOptions.
    fn options(raw: &Value) -> String {
        let mut o = vec!["hwdec=auto-safe".to_string(), "profile=fast".into(), "loop".into(), "keep-open=yes".into()];
        let vol = raw["liveVolume"].as_f64().unwrap_or(0.0);
        if raw["liveSound"].as_bool() != Some(true) || vol <= 0.0 {
            o.push("no-audio".into());
        } else {
            o.push(format!("volume={}", vol.round()));
        }
        o.push(match raw["liveScaling"].as_str() {
            Some("fit") => "panscan=0.0".into(),
            Some("stretch") => "keepaspect=no".into(),
            _ => "panscan=1.0".into(),
        });
        o.join(" ")
    }

    /// Follows theme.json's liveWallpaper: starts, restarts or stops it.
    pub fn follow(&mut self, raw: &Value) {
        let chosen = raw["liveWallpaper"].as_str().unwrap_or("").to_string();
        let want = (is_video(&chosen) && std::path::Path::new(&chosen).exists()).then(|| (chosen, Self::options(raw)));
        if want != self.wanted {
            self.stop();
            self.wanted = want;
            self.quick_failures = 0;
            self.retry_at = Some(std::time::Instant::now());
        }
    }

    fn stop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }

    /// Keeps it running; called every second or so.
    pub fn tick(&mut self) {
        if let Some(c) = &mut self.child {
            if let Ok(Some(_)) = c.try_wait() {
                self.child = None;
                if self.started.elapsed().as_secs() > 20 {
                    self.quick_failures = 0;
                } else {
                    self.quick_failures += 1;
                }
                if self.quick_failures < 2 {
                    self.retry_at = Some(std::time::Instant::now() + std::time::Duration::from_millis(1500));
                } else {
                    eprintln!("hyprshell-rs: mpvpaper keeps stopping; the live wallpaper is off until it's chosen again");
                }
            }
            return;
        }
        let Some((video, opts)) = self.wanted.clone() else { return };
        if !self.retry_at.is_some_and(|t| std::time::Instant::now() >= t) {
            return;
        }
        self.retry_at = None;
        use std::os::unix::process::CommandExt;
        let mut cmd = std::process::Command::new("nice");
        cmd.args(["-n", "10", "mpvpaper", "-l", "bottom", "-o", &opts, "*", &video])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        // It goes when the shell does, however the shell ends.
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        match cmd.spawn() {
            Ok(c) => {
                self.child = Some(c);
                self.started = std::time::Instant::now();
            }
            Err(e) => eprintln!("hyprshell-rs: can't start mpvpaper ({e})"),
        }
    }
}

impl Drop for Live {
    fn drop(&mut self) {
        self.stop();
    }
}
