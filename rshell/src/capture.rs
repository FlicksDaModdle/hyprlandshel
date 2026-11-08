//! Screenshots and text from the screen (the Quickshell shell's
//! services/Capture.qml and modules/capture/Snipper.qml).
//!
//!   screenshot region|window   the frozen screen: every output captured the
//!                              moment the key goes down (grim, one per
//!                              output, at once), shown still on a surface
//!                              of its own, and the choosing done over that
//!                              (ui/snipper.slint), so a menu or a video
//!                              holds still while you frame it
//!   screenshot screen|all      the focused screen, or every one, at once
//!   ocr                        the frozen screen, and the part chosen read
//!                              by tesseract onto the clipboard
//!
//! A shot is saved to ~/Pictures/Screenshots, put on the clipboard and
//! announced with Open and Show in Files. The part chosen is cut from the
//! still picture at full resolution, not captured again.

use slint::{Rgba8Pixel, SharedPixelBuffer};
use std::io::Write;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Instant;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Shot,
    Ocr,
}

/// One output's still picture, as grim took it.
pub struct Still {
    pub output: String,
    pub pixels: SharedPixelBuffer<Rgba8Pixel>,
}

/// A window on screen, in layout (logical) coordinates.
#[derive(Clone, Copy, Debug)]
pub struct Win {
    pub workspace: i64,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub pinned: bool,
}

/// A monitor's place in the layout and the workspace it shows.
#[derive(Clone, Debug)]
pub struct Mon {
    pub name: String,
    pub x: f32,
    pub y: f32,
    pub workspace: i64,
}

pub enum Msg {
    /// Every output captured: the frozen screen goes up.
    Frozen { kind: Kind, stills: Vec<Still>, wins: Vec<Win>, mons: Vec<Mon> },
    Failed(String),
    /// A shot was saved, or nothing came of it: the next may start.
    Done,
}

pub struct Capture {
    tx: Sender<Msg>,
    pub rx: Receiver<Msg>,
    wake: UnixStream,
    pub busy: bool,
    busy_since: Instant,
    /// When the last one was asked for: Super on its own is a release
    /// bind, and letting go of Super+Shift+S would open the launcher.
    pub shot_at: Option<Instant>,
}

pub fn pictures_dir() -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
    home.join("Pictures").join("Screenshots")
}

fn stamp() -> String {
    // Local time, as `date` gives it, so the name sorts and reads right.
    Command::new("date")
        .arg("+%Y-%m-%d_%H-%M-%S")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| format!("{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)))
}

pub fn trace(msg: &str) {
    eprintln!("capture: {msg}");
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")));
    if let Some(dir) = cache.map(|c| c.join("hyprshell")) {
        let _ = std::fs::create_dir_all(&dir);
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("capture.log")) {
            let _ = writeln!(f, "{msg}");
        }
    }
}

fn which(prog: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(prog).is_file()))
}

/// "Show the pointer" off: hidden outright for the moment of the capture
/// (a cursor Hyprland draws in software is in the picture whatever grim is
/// told), and shown again straight after.
fn cursor(visible: bool) {
    if !which("hyprctl") {
        return;
    }
    let lua = format!("hl.config({{ cursor = {{ invisible = {} }} }})", !visible);
    let _ = Command::new("hyprctl").args(["eval", &lua]).stdout(Stdio::null()).stderr(Stdio::null()).status();
}

fn grim(out: Option<&str>, pointer: bool, file: &Path) -> Result<(), String> {
    let mut c = Command::new("grim");
    if pointer {
        c.arg("-c");
    }
    if let Some(o) = out {
        c.args(["-o", o]);
    }
    // Uncompressed when it is only to be shown (a .ppm): several times
    // faster than a PNG at a screen's size, and nothing to decode slowly.
    if file.extension().is_some_and(|e| e == "ppm") {
        c.args(["-t", "ppm"]);
    }
    c.arg(file).stdout(Stdio::null()).stderr(Stdio::piped());
    match c.output() {
        Ok(o) if o.status.success() => Ok(()),
        Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
        Err(e) => Err(format!("grim: {e}")),
    }
}

fn windows() -> (Vec<Win>, Vec<Mon>) {
    let f = |v: &serde_json::Value| v.as_f64().unwrap_or(0.0) as f32;
    let wins = crate::hypr::json("j/clients")
        .as_array()
        .map(|cs| {
            cs.iter()
                .filter(|c| c["mapped"].as_bool().unwrap_or(true) && !c["hidden"].as_bool().unwrap_or(false))
                .map(|c| Win {
                    workspace: c["workspace"]["id"].as_i64().unwrap_or(-1),
                    x: f(&c["at"][0]),
                    y: f(&c["at"][1]),
                    w: f(&c["size"][0]),
                    h: f(&c["size"][1]),
                    pinned: c["pinned"].as_bool().unwrap_or(false),
                })
                .filter(|w| w.w > 0.0 && w.h > 0.0)
                .collect()
        })
        .unwrap_or_default();
    let mons = crate::hypr::json("j/monitors")
        .as_array()
        .map(|ms| {
            ms.iter()
                .map(|m| Mon {
                    name: m["name"].as_str().unwrap_or("").to_string(),
                    x: f(&m["x"]),
                    y: f(&m["y"]),
                    workspace: m["activeWorkspace"]["id"].as_i64().unwrap_or(-1),
                })
                .collect()
        })
        .unwrap_or_default();
    (wins, mons)
}

/// The windows on `mon`, in its own coordinates, smallest first so a
/// dialog over its parent wins.
pub fn boxes_on(wins: &[Win], mons: &[Mon], mon: &str, size: (f32, f32)) -> Vec<(f32, f32, f32, f32)> {
    let Some(m) = mons.iter().find(|m| m.name == mon) else { return Vec::new() };
    let mut v: Vec<(f32, f32, f32, f32)> = wins
        .iter()
        .filter(|w| w.workspace == m.workspace || w.pinned)
        .map(|w| (w.x - m.x, w.y - m.y, w.w, w.h))
        .filter(|(x, y, w, h)| x + w > 0.0 && y + h > 0.0 && *x < size.0 && *y < size.1)
        .collect();
    v.sort_by(|a, b| (a.2 * a.3).total_cmp(&(b.2 * b.3)));
    v
}

/// The window under (x, y), cut to the screen; all zeros when none.
pub fn window_at(boxes: &[(f32, f32, f32, f32)], x: f32, y: f32, size: (f32, f32)) -> (f32, f32, f32, f32) {
    for &(bx, by, bw, bh) in boxes {
        if x >= bx && x < bx + bw && y >= by && y < by + bh {
            let (x0, y0) = (bx.max(0.0), by.max(0.0));
            return (x0, y0, (bx + bw).min(size.0) - x0, (by + bh).min(size.1) - y0);
        }
    }
    (0.0, 0.0, 0.0, 0.0)
}

/// A rectangle in logical pixels, in a picture's own pixels, kept inside
/// it: rounding each edge at a fractional scale could otherwise ask for a
/// pixel past the last one.
pub fn pixel_rect(r: (f32, f32, f32, f32), ratio: f32, pw: u32, ph: u32) -> (u32, u32, u32, u32) {
    let (w, h) = (pw as f32, ph as f32);
    let x0 = (r.0 * ratio).round().clamp(0.0, w - 1.0);
    let y0 = (r.1 * ratio).round().clamp(0.0, h - 1.0);
    let x1 = ((r.0 + r.2) * ratio).round().min(w).max(x0 + 1.0);
    let y1 = ((r.1 + r.3) * ratio).round().min(h).max(y0 + 1.0);
    (x0 as u32, y0 as u32, (x1 - x0) as u32, (y1 - y0) as u32)
}

impl Capture {
    pub fn new(wake: &UnixStream) -> Capture {
        let (tx, rx) = channel();
        Capture { tx, rx, wake: wake.try_clone().expect("wake"), busy: false, busy_since: Instant::now(), shot_at: None }
    }

    fn sender(&self) -> (Sender<Msg>, UnixStream) {
        (self.tx.clone(), self.wake.try_clone().expect("wake"))
    }

    /// May a new one start? `busy` left set by one that died half-way must
    /// not leave every later press doing nothing.
    fn claim(&mut self) -> bool {
        if self.busy && self.busy_since.elapsed().as_secs() < 20 {
            trace("busy; ignored");
            return false;
        }
        self.busy = true;
        self.busy_since = Instant::now();
        self.shot_at = Some(Instant::now());
        true
    }

    /// Freezes every output: `outputs` by name.
    pub fn freeze(&mut self, kind: Kind, outputs: Vec<String>, delay: u64, pointer: bool) {
        if !self.claim() {
            return;
        }
        trace(&format!("freeze {kind:?} {outputs:?} delay={delay} pointer={pointer}"));
        let (tx, mut wake) = self.sender();
        std::thread::spawn(move || {
            let msg = (|| {
                if !which("grim") {
                    return Msg::Failed("Needs grim — sudo pacman -S grim".into());
                }
                if delay > 0 {
                    std::thread::sleep(std::time::Duration::from_secs(delay));
                }
                let run = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
                let dir = run.join(format!("hyprshell-snip-{}", std::process::id()));
                let _ = std::fs::create_dir_all(&dir);
                if !pointer {
                    cursor(false);
                    std::thread::sleep(std::time::Duration::from_millis(70));
                }
                // All at once, so they are the same moment.
                let jobs: Vec<_> = outputs
                    .iter()
                    .map(|o| {
                        let file = dir.join(format!("{o}.ppm"));
                        let o = o.clone();
                        std::thread::spawn(move || grim(Some(&o), pointer, &file).map(|_| (o, file)))
                    })
                    .collect();
                let shots: Vec<Result<(String, PathBuf), String>> = jobs.into_iter().map(|j| j.join().unwrap_or(Err("grim crashed".into()))).collect();
                if !pointer {
                    cursor(true);
                }
                let mut stills = Vec::new();
                let mut why = String::new();
                for s in shots {
                    match s {
                        Ok((o, file)) => {
                            match image::open(&file) {
                                Ok(img) => {
                                    let img = img.to_rgba8();
                                    let (w, h) = img.dimensions();
                                    stills.push(Still { output: o, pixels: SharedPixelBuffer::clone_from_slice(img.as_raw(), w, h) });
                                }
                                Err(e) => why = format!("{o}: {e}"),
                            }
                            let _ = std::fs::remove_file(&file);
                        }
                        Err(e) => why = e,
                    }
                }
                let _ = std::fs::remove_dir(&dir);
                if stills.is_empty() {
                    return Msg::Failed(if why.is_empty() { "Nothing was captured".into() } else { why });
                }
                let (wins, mons) = windows();
                Msg::Frozen { kind, stills, wins, mons }
            })();
            let _ = tx.send(msg);
            let _ = wake.write_all(b"!");
        });
    }

    /// The focused screen (`Some`) or every one, straight to a file.
    pub fn whole(&mut self, output: Option<String>, delay: u64, pointer: bool) {
        if !self.claim() {
            return;
        }
        trace(&format!("screen {output:?}"));
        let (tx, mut wake) = self.sender();
        std::thread::spawn(move || {
            if delay > 0 {
                std::thread::sleep(std::time::Duration::from_secs(delay));
            }
            let dir = pictures_dir();
            let msg = match std::fs::create_dir_all(&dir) {
                Err(e) => Msg::Failed(format!("Could not create {}: {e}", dir.display())),
                Ok(()) => {
                    let file = dir.join(format!("Screenshot_{}.png", stamp()));
                    if !pointer {
                        cursor(false);
                        std::thread::sleep(std::time::Duration::from_millis(70));
                    }
                    let r = grim(output.as_deref(), pointer, &file);
                    if !pointer {
                        cursor(true);
                    }
                    match r {
                        Ok(()) => {
                            delivered(&file);
                            Msg::Done
                        }
                        Err(e) => Msg::Failed(if e.is_empty() { "grim failed".into() } else { e }),
                    }
                }
            };
            let _ = tx.send(msg);
            let _ = wake.write_all(b"!");
        });
    }

    /// The part `r` (logical, on that output) of a still: saved and copied,
    /// or read as text.
    pub fn cut(&mut self, kind: Kind, still: SharedPixelBuffer<Rgba8Pixel>, r: (f32, f32, f32, f32), ratio: f32) {
        let (tx, mut wake) = self.sender();
        std::thread::spawn(move || {
            let (x, y, w, h) = pixel_rect(r, ratio, still.width(), still.height());
            trace(&format!("take {r:?} ratio {ratio} -> {x},{y} {w}x{h}"));
            let stride = still.width() as usize * 4;
            let src = still.as_bytes();
            let mut out = Vec::with_capacity((w * h * 4) as usize);
            for row in y..y + h {
                let at = row as usize * stride + x as usize * 4;
                out.extend_from_slice(&src[at..at + w as usize * 4]);
            }
            let msg = match image::RgbaImage::from_raw(w, h, out) {
                None => Msg::Failed("The picture could not be cut out".into()),
                Some(img) => match kind {
                    Kind::Shot => {
                        let dir = pictures_dir();
                        let file = dir.join(format!("Screenshot_{}.png", stamp()));
                        match std::fs::create_dir_all(&dir).map_err(|e| e.to_string()).and_then(|_| img.save(&file).map_err(|e| e.to_string())) {
                            Ok(()) => {
                                delivered(&file);
                                Msg::Done
                            }
                            Err(e) => Msg::Failed(format!("Could not write {}: {e}", file.display())),
                        }
                    }
                    Kind::Ocr => {
                        ocr(img);
                        Msg::Done
                    }
                },
            };
            let _ = tx.send(msg);
            let _ = wake.write_all(b"!");
        });
    }

    pub fn finished(&mut self) {
        self.busy = false;
    }
}

/// A saved shot: onto the clipboard, and announced.
fn delivered(file: &Path) {
    trace(&format!("saved {}", file.display()));
    if let Ok(f) = std::fs::File::open(file) {
        let _ = Command::new("wl-copy").args(["--type", "image/png"]).stdin(f).stdout(Stdio::null()).stderr(Stdio::null()).status();
    }
    let name = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let path = file.to_string_lossy().to_string();
    let dir = file.parent().map(|d| d.to_string_lossy().to_string()).unwrap_or_default();
    let body = format!("Copied to the clipboard · {name}");
    let image = format!("string:image-path:file://{path}");
    std::thread::spawn(move || {
        let out = Command::new("notify-send")
            .args(["-a", "Screenshot", "-i", "camera-photo", "-h", &image, "-A", "open=Open", "-A", "folder=Show in Files", "--wait", "Screenshot saved", &body])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output();
        let act = out.ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
        match act.as_str() {
            "open" => crate::extras::spawn(&["xdg-open", &path]),
            "folder" => crate::extras::spawn(&["xdg-open", &dir]),
            _ => {}
        }
    });
}

pub fn say(title: &str, body: &str) {
    crate::extras::spawn(&["notify-send", "-a", "Screenshot", "-i", "camera-photo", title, body]);
}

fn ocr(img: image::RgbaImage) {
    if !which("tesseract") {
        say("Text from screen", "Needs tesseract — sudo pacman -S tesseract tesseract-data-eng");
        return;
    }
    // At twice the size: screen text is small, and tesseract reads it far
    // better enlarged.
    let big = image::imageops::resize(&img, img.width() * 2, img.height() * 2, image::imageops::FilterType::CatmullRom);
    let run = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
    let file = run.join(format!("hyprshell-ocr-{}.png", std::process::id()));
    if big.save(&file).is_err() {
        say("Text from screen", "The picture could not be saved for reading");
        return;
    }
    let lang = crate::theme::raw()["captureOcrLang"].as_str().filter(|s| !s.is_empty()).unwrap_or("eng").to_string();
    let out = Command::new("tesseract").arg(&file).args(["stdout", "-l", &lang]).stderr(Stdio::null()).output();
    let _ = std::fs::remove_file(&file);
    let text = out.ok().map(|o| String::from_utf8_lossy(&o.stdout).replace('\u{c}', "").trim().to_string()).unwrap_or_default();
    if text.is_empty() {
        say("Text from screen", "No text found in that area.");
        return;
    }
    if let Ok(mut c) = Command::new("wl-copy").stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
        if let Some(mut i) = c.stdin.take() {
            let _ = i.write_all(text.as_bytes());
        }
        let _ = c.wait();
    }
    let first = text.lines().next().unwrap_or("");
    let first: String = if first.chars().count() > 80 { first.chars().take(80).collect::<String>() + "…" } else { first.to_string() };
    let more = text.lines().count().saturating_sub(1);
    say("Text copied", &if more > 0 { format!("{first} (+{more} lines)") } else { first });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pixel_rect_stays_inside() {
        assert_eq!(pixel_rect((10.0, 20.0, 30.0, 40.0), 2.0, 1000, 1000), (20, 40, 60, 80));
        // Past the edge at a fractional scale: clipped to the picture.
        assert_eq!(pixel_rect((0.0, 0.0, 1536.0, 960.0), 1.6667, 2560, 1600), (0, 0, 2560, 1600));
        // Never empty.
        let (_, _, w, h) = pixel_rect((5.0, 5.0, 0.0, 0.0), 1.0, 100, 100);
        assert!(w >= 1 && h >= 1);
    }

    #[test]
    fn boxes_are_local_and_smallest_first() {
        let wins = vec![
            Win { workspace: 1, x: 1600.0, y: 0.0, w: 800.0, h: 600.0, pinned: false },
            Win { workspace: 1, x: 1700.0, y: 100.0, w: 200.0, h: 100.0, pinned: false },
            Win { workspace: 2, x: 1600.0, y: 0.0, w: 50.0, h: 50.0, pinned: false },
        ];
        let mons = vec![Mon { name: "DP-1".into(), x: 1600.0, y: 0.0, workspace: 1 }];
        let b = boxes_on(&wins, &mons, "DP-1", (1920.0, 1080.0));
        assert_eq!(b, vec![(100.0, 100.0, 200.0, 100.0), (0.0, 0.0, 800.0, 600.0)]);
    }
}


// ── recording (Capture.qml's wf-recorder) ────────────────────────────────

static REC_PID: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

pub fn recording() -> bool {
    REC_PID.load(std::sync::atomic::Ordering::SeqCst) > 0
}

fn pactl(what: &str) -> String {
    Command::new("pactl").arg(what).stderr(Stdio::null()).output().ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
}

/// Starts a recording of `mode` (region | screen) with `audio` (none |
/// desktop | mic) of `output`; or, if one runs, stops it (wf-recorder
/// finishes the file on SIGINT).
pub fn toggle_recording(mode: &str, audio: &str, output: &str) {
    use std::sync::atomic::Ordering;
    let pid = REC_PID.load(Ordering::SeqCst);
    if pid > 0 {
        unsafe {
            libc::kill(pid, libc::SIGINT);
        }
        return;
    }
    if !which("wf-recorder") {
        say("Screen recording", "Needs wf-recorder — sudo pacman -S wf-recorder");
        return;
    }
    let dev = match audio {
        "desktop" => {
            let s = pactl("get-default-sink");
            if s.is_empty() { s } else { format!("{s}.monitor") }
        }
        "mic" => pactl("get-default-source"),
        _ => String::new(),
    };
    let (mode, output) = (mode.to_string(), output.to_string());
    let dir = std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Videos/Recordings")).unwrap_or_else(|| "/tmp".into());
    std::thread::spawn(move || {
        let script = "mode=$1; dev=$2; dir=$3; out=$4; mkdir -p \"$dir\" || exit 3; \
            f=\"$dir/Recording_$(date +%Y-%m-%d_%H-%M-%S).mp4\"; \
            set -- -f \"$f\"; \
            if [ \"$mode\" = region ]; then g=$(slurp -d < /dev/null) || exit 1; set -- \"$@\" -g \"$g\"; \
            elif [ -n \"$out\" ]; then set -- \"$@\" -o \"$out\"; fi; \
            [ -n \"$dev\" ] && set -- \"$@\" \"--audio=$dev\"; \
            printf 'FILE %s\\n' \"$f\"; \
            exec wf-recorder -y \"$@\"";
        let child = Command::new("sh")
            .args(["-c", script, "record", &mode, &dev, &dir.to_string_lossy(), &output])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn();
        let Ok(mut child) = child else { return };
        REC_PID.store(child.id() as i32, Ordering::SeqCst);
        let mut file = String::new();
        let mut since = Instant::now();
        if let Some(out) = child.stdout.take() {
            use std::io::BufRead;
            for line in std::io::BufReader::new(out).lines().map_while(Result::ok) {
                if let Some(f) = line.strip_prefix("FILE ") {
                    file = f.to_string();
                    since = Instant::now();
                    say("Recording", "Started — press the key again to stop");
                }
            }
        }
        let err = child.stderr.take().map(|mut e| {
            let mut t = String::new();
            let _ = std::io::Read::read_to_string(&mut e, &mut t);
            t
        });
        let code = child.wait().ok().and_then(|s| s.code()).unwrap_or(-1);
        REC_PID.store(0, Ordering::SeqCst);
        if file.is_empty() {
            // Cancelled in the selection, or never began.
            if code != 1 {
                say("Recording failed", err.unwrap_or_default().trim().lines().last().unwrap_or("wf-recorder did not start"));
            }
            return;
        }
        let secs = since.elapsed().as_secs();
        let name = file.rsplit('/').next().unwrap_or(&file).to_string();
        let out = Command::new("notify-send")
            .args(["-a", "Screenshot", "-i", "camera-video", "-A", "open=Play", "-A", "folder=Show in Files", "--wait", "Recording saved", &format!("{}:{:02} · {name}", secs / 60, secs % 60)])
            .stderr(Stdio::null())
            .output();
        match out.ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).as_deref() {
            Some("open") => crate::extras::spawn(&["xdg-open", &file]),
            Some("folder") => crate::launcher::launch(&crate::launcher::files_command(&dir.to_string_lossy()), ""),
            _ => {}
        }
    });
}
