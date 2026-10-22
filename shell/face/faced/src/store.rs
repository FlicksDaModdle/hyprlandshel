//! The service's settings (/etc/hyprshell-face.conf) and the faces it
//! knows (/var/lib/hyprshell-face/USER.json).

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const CONFIG: &str = "/etc/hyprshell-face.conf";
pub const STATE: &str = "/var/lib/hyprshell-face";
pub const MODELS: &str = "/usr/local/share/hyprshell-face";

/// Read from the file at each request, so a change needs no restart.
#[derive(Clone, Debug)]
pub struct Config {
    /// The infrared camera (/dev/videoN, or dir:… for tests).
    pub ir_device: String,
    /// The webcam, for the webcam check.
    pub webcam_device: String,
    pub webcam_check: bool,
    /// How alike (cosine, -1 to 1) the infrared face has to be.
    pub threshold: f32,
    /// The same for the webcam.
    pub webcam_threshold: f32,
    /// Seconds to look before giving up.
    pub timeout: f32,
    /// Webcam frames darker than this (average, 0-255) don't count, and if
    /// it's all of them, the infrared camera decides alone.
    pub min_light: f32,
    /// Infrared frames darker than this are skipped unlooked-at: the
    /// emitter flashes, and some frames are unlit.
    pub dark_frame: f32,
    /// How sure the face finder has to be that a face is there (0-1).
    pub detect_score: f32,
    pub models: PathBuf,
}

impl Default for Config {
    fn default() -> Config {
        Config {
            ir_device: String::new(),
            webcam_device: String::new(),
            webcam_check: false,
            threshold: 0.45,
            webcam_threshold: 0.40,
            timeout: 4.0,
            min_light: 45.0,
            dark_frame: 8.0,
            detect_score: 0.8,
            models: PathBuf::from(MODELS),
        }
    }
}

impl Config {
    pub fn load() -> Config {
        Config::from_text(&std::fs::read_to_string(CONFIG).unwrap_or_default())
    }

    /// `key = value` lines; # comments; unknown keys and bad values are
    /// left at their defaults.
    pub fn from_text(text: &str) -> Config {
        let mut c = Config::default();
        for line in text.lines() {
            let line = line.split('#').next().unwrap_or("").trim();
            let Some((k, v)) = line.split_once('=') else { continue };
            let (k, v) = (k.trim(), v.trim());
            let num = |lo: f32, hi: f32| v.parse::<f32>().ok().filter(|n| (lo..=hi).contains(n));
            match k {
                "ir_device" => c.ir_device = v.to_string(),
                "webcam_device" => c.webcam_device = v.to_string(),
                "webcam_check" => c.webcam_check = v == "true",
                "threshold" => c.threshold = num(0.2, 0.9).unwrap_or(c.threshold),
                "webcam_threshold" => c.webcam_threshold = num(0.2, 0.9).unwrap_or(c.webcam_threshold),
                "timeout" => c.timeout = num(1.0, 20.0).unwrap_or(c.timeout),
                "min_light" => c.min_light = num(0.0, 200.0).unwrap_or(c.min_light),
                "dark_frame" => c.dark_frame = num(0.0, 100.0).unwrap_or(c.dark_frame),
                "detect_score" => c.detect_score = num(0.5, 0.99).unwrap_or(c.detect_score),
                "models" => c.models = PathBuf::from(v),
                _ => {}
            }
        }
        c
    }
}

/// One look: the infrared camera's faces of you, and the webcam's if it
/// had pictures, from one time of adding.
#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Look {
    pub id: u32,
    pub label: String,
    pub time: u64,
    pub ir: Vec<Vec<f32>>,
    #[serde(default)]
    pub webcam: Vec<Vec<f32>>,
}

#[derive(Serialize, Deserialize, Default, Debug)]
pub struct Faces {
    pub looks: Vec<Look>,
}

pub fn path_for(user: &str) -> PathBuf {
    Path::new(STATE).join(format!("{user}.json"))
}

impl Faces {
    pub fn load(user: &str) -> Faces {
        std::fs::read(path_for(user)).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }

    /// Written whole and swapped in, readable by the service alone.
    pub fn save(&self, user: &str) -> std::io::Result<()> {
        use std::os::unix::fs::OpenOptionsExt;
        let path = path_for(user);
        if self.looks.is_empty() {
            return match std::fs::remove_file(&path) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            };
        }
        let tmp = path.with_extension("json.new");
        let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp)?;
        std::io::Write::write_all(&mut f, &serde_json::to_vec(self)?)?;
        f.sync_all()?;
        std::fs::rename(tmp, path)
    }

    pub fn ir(&self) -> Vec<Vec<f32>> {
        self.looks.iter().flat_map(|l| l.ir.iter().cloned()).collect()
    }

    pub fn webcam(&self) -> Vec<Vec<f32>> {
        self.looks.iter().flat_map(|l| l.webcam.iter().cloned()).collect()
    }

    pub fn next_id(&self) -> u32 {
        self.looks.iter().map(|l| l.id + 1).max().unwrap_or(0)
    }
}

/// A user name fit to be a file name and to have been given by PAM.
pub fn plain_user(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('.')
        && !name.starts_with('-')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

/// The lid's state, where the laptop says it.
pub fn lid_closed() -> bool {
    let Ok(dir) = std::fs::read_dir("/proc/acpi/button/lid") else { return false };
    dir.filter_map(|e| e.ok())
        .any(|e| std::fs::read_to_string(e.path().join("state")).is_ok_and(|s| s.contains("closed")))
}
