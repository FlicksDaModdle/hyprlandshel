//! The library: every song under the music folder, its tags read once
//! (lofty) and kept in a cache, so opening again only reads what changed.
//! Album art comes from the files' own pictures, or a cover image beside
//! them.

use lofty::prelude::*;
use lofty::picture::PictureType;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const AUDIO: &[&str] = &["mp3", "flac", "ogg", "oga", "wav", "m4a", "mp4", "aac", "alac"];

#[derive(Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct Song {
    pub path: String,
    #[serde(default)]
    pub mtime: i64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    #[serde(default)]
    pub album_artist: String,
    #[serde(default)]
    pub track: u32,
    #[serde(default)]
    pub disc: u32,
    #[serde(default)]
    pub year: u32,
    #[serde(default)]
    pub genre: String,
    #[serde(default)]
    pub secs: f64,
    /// Opened from outside the library (a file given to the app).
    #[serde(skip)]
    pub stray: bool,
}

impl Song {
    /// Who the album is by: its album artist, else its artist.
    pub fn by(&self) -> &str {
        if !self.album_artist.is_empty() {
            &self.album_artist
        } else if !self.artist.is_empty() {
            &self.artist
        } else {
            "Unknown artist"
        }
    }
    pub fn album_name(&self) -> &str {
        if self.album.is_empty() { "Unknown album" } else { &self.album }
    }
    pub fn artist_name(&self) -> &str {
        if self.artist.is_empty() { "Unknown artist" } else { &self.artist }
    }
    pub fn album_key(&self) -> String {
        format!("{}\u{1f}{}", self.by().to_lowercase(), self.album_name().to_lowercase())
    }
}

/// The music folder: $HYPRSHELL_MUSIC_DIR, XDG's music directory, ~/Music.
pub fn root() -> PathBuf {
    if let Some(d) = std::env::var_os("HYPRSHELL_MUSIC_DIR") {
        return PathBuf::from(d);
    }
    let home = hyprshell_kit::home();
    let dirs = hyprshell_kit::config_dir().join("user-dirs.dirs");
    if let Ok(t) = std::fs::read_to_string(dirs) {
        for l in t.lines() {
            if let Some(v) = l.strip_prefix("XDG_MUSIC_DIR=") {
                let v = v.trim().trim_matches('"').replace("$HOME", &home.to_string_lossy());
                let p = PathBuf::from(v);
                if p != home {
                    return p;
                }
            }
        }
    }
    home.join("Music")
}

pub fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| hyprshell_kit::home().join(".cache"))
        .join("hyprshell-music")
}

fn cache_file() -> PathBuf {
    cache_dir().join("library.json")
}

pub fn load_cache() -> Vec<Song> {
    std::fs::read_to_string(cache_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

pub fn save_cache(songs: &[Song]) {
    let p = cache_file();
    let _ = std::fs::create_dir_all(p.parent().unwrap());
    let keep: Vec<&Song> = songs.iter().filter(|s| !s.stray).collect();
    let _ = hyprshell_kit::write_atomic(&p, serde_json::to_string(&keep).unwrap_or_default().as_bytes());
}

pub fn is_audio(p: &Path) -> bool {
    p.extension().and_then(|e| e.to_str()).is_some_and(|e| AUDIO.contains(&e.to_ascii_lowercase().as_str()))
}

fn mtime(p: &Path) -> i64 {
    std::fs::metadata(p)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs() as i64)
}

/// Walk the folder; reuse what the cache already knows.
pub fn scan(root: &Path, cached: Vec<Song>, progress: &dyn Fn(usize)) -> Vec<Song> {
    let mut known: HashMap<String, Song> = cached.into_iter().map(|s| (s.path.clone(), s)).collect();
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let name = e.file_name();
            if name.to_string_lossy().starts_with('.') {
                continue;
            }
            let p = e.path();
            let Ok(ft) = e.file_type() else { continue };
            if ft.is_dir() || (ft.is_symlink() && p.is_dir()) {
                stack.push(p);
            } else if is_audio(&p) {
                let key = p.to_string_lossy().to_string();
                let mt = mtime(&p);
                match known.remove(&key) {
                    Some(s) if s.mtime == mt => out.push(s),
                    _ => {
                        let mut s = read(&p);
                        if s.album.is_empty() && dir != root {
                            s.album = dir.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                        }
                        out.push(s);
                        progress(out.len());
                    }
                }
            }
        }
    }
    out
}

/// One file's tags (and, without any, a name from the file and folder).
pub fn read(p: &Path) -> Song {
    let mut s = Song { path: p.to_string_lossy().to_string(), mtime: mtime(p), ..Default::default() };
    if let Ok(f) = lofty::read_from_path(p) {
        s.secs = f.properties().duration().as_secs_f64();
        if let Some(t) = f.primary_tag().or_else(|| f.first_tag()) {
            s.title = t.title().map(|v| v.trim().to_string()).unwrap_or_default();
            s.artist = t.artist().map(|v| v.trim().to_string()).unwrap_or_default();
            s.album = t.album().map(|v| v.trim().to_string()).unwrap_or_default();
            s.genre = t.genre().map(|v| v.trim().to_string()).unwrap_or_default();
            s.album_artist = t.get_string(&ItemKey::AlbumArtist).map(|v| v.trim().to_string()).unwrap_or_default();
            s.track = t.track().unwrap_or(0);
            s.disc = t.disk().unwrap_or(0);
            s.year = t.year().unwrap_or(0);
        }
    }
    if s.title.is_empty() {
        let stem = p.file_stem().map(|x| x.to_string_lossy().to_string()).unwrap_or_default();
        // "03 - Name" and "03. Name": the number is the track's.
        let t = stem.trim_start_matches(|c: char| c.is_ascii_digit());
        let t = t.trim_start_matches([' ', '-', '.', '_']);
        if t.len() < stem.len() && s.track == 0 {
            s.track = stem[..stem.len() - stem.trim_start_matches(|c: char| c.is_ascii_digit()).len()].parse().unwrap_or(0);
        }
        s.title = if t.is_empty() { stem } else { t.to_string() };
    }
    s
}

/// The picture for an album, from any of its files, else a cover image in
/// their folder; as RGBA at `size` square.
pub fn art(paths: &[PathBuf], size: u32) -> Option<image::RgbaImage> {
    let bytes = paths.iter().take(4).find_map(|p| embedded(p)).or_else(|| beside(paths.first()?))?;
    let img = image::load_from_memory(&bytes).ok()?;
    Some(img.resize_to_fill(size, size, image::imageops::FilterType::Triangle).to_rgba8())
}

fn embedded(p: &Path) -> Option<Vec<u8>> {
    let f = lofty::read_from_path(p).ok()?;
    let mut best: Option<&lofty::picture::Picture> = None;
    for t in f.tags() {
        for pic in t.pictures() {
            if pic.pic_type() == PictureType::CoverFront {
                return Some(pic.data().to_vec());
            }
            best.get_or_insert(pic);
        }
    }
    best.map(|p| p.data().to_vec())
}

fn beside(p: &Path) -> Option<Vec<u8>> {
    let dir = p.parent()?;
    let mut found: Vec<(u8, PathBuf)> = Vec::new();
    for e in std::fs::read_dir(dir).ok()?.flatten() {
        let n = e.file_name().to_string_lossy().to_lowercase();
        if !(n.ends_with(".jpg") || n.ends_with(".jpeg") || n.ends_with(".png")) {
            continue;
        }
        let rank = if n.starts_with("cover") {
            0
        } else if n.starts_with("folder") {
            1
        } else if n.starts_with("front") {
            2
        } else if n.contains("cover") || n.starts_with("album") {
            3
        } else {
            9
        };
        found.push((rank, e.path()));
    }
    found.sort();
    std::fs::read(&found.first()?.1).ok()
}
