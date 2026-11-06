//! Finding an icon by name in the icon theme, as the freedesktop icon theme
//! spec has it: the user's theme (from GTK's settings.ini, which Settings →
//! Appearance writes), the themes it inherits, then hicolor, then pixmaps.
//! Within a theme, the size nearest to the one wanted, a scalable one
//! counting as exact. Answers are cached, so asking again costs nothing.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

struct Dir {
    path: String,
    size: u32,
    scalable: bool,
}

struct Theme {
    roots: Vec<PathBuf>,
    dirs: Vec<Dir>,
    inherits: Vec<String>,
}

#[derive(Default)]
struct Cache {
    themes: HashMap<String, Option<Theme>>,
    found: HashMap<(String, u32), Option<PathBuf>>,
    user: Option<String>,
}

fn cache() -> &'static Mutex<Cache> {
    static C: OnceLock<Mutex<Cache>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(Cache::default()))
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

fn bases() -> Vec<PathBuf> {
    let mut v = Vec::new();
    let data = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/share"));
    v.push(data.join("icons"));
    v.push(home().join(".icons"));
    let dirs = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    for d in dirs.split(':').filter(|d| !d.is_empty()) {
        v.push(Path::new(d).join("icons"));
    }
    v
}

/// The icon theme GTK apps use: gtk-4.0's settings.ini, then gtk-3.0's.
fn user_theme() -> String {
    let cfg = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".config"));
    for f in ["gtk-4.0/settings.ini", "gtk-3.0/settings.ini"] {
        if let Ok(t) = std::fs::read_to_string(cfg.join(f)) {
            for l in t.lines() {
                if let Some(v) = l.trim().strip_prefix("gtk-icon-theme-name") {
                    let v = v.trim_start_matches([' ', '=']).trim().trim_matches('"');
                    if !v.is_empty() {
                        return v.to_string();
                    }
                }
            }
        }
    }
    "hicolor".into()
}

fn load_theme(name: &str) -> Option<Theme> {
    let roots: Vec<PathBuf> = bases().into_iter().map(|b| b.join(name)).filter(|p| p.is_dir()).collect();
    let index = roots.iter().find_map(|r| std::fs::read_to_string(r.join("index.theme")).ok())?;
    let mut dirs = Vec::new();
    let mut inherits = Vec::new();
    let mut section = String::new();
    let mut cur: Option<Dir> = None;
    let (mut scale, mut ty) = (1u32, String::new());
    let flush = |cur: &mut Option<Dir>, scale: u32, ty: &str, dirs: &mut Vec<Dir>| {
        if let Some(mut d) = cur.take() {
            d.size *= scale.max(1);
            d.scalable = ty == "Scalable";
            dirs.push(d);
        }
    };
    let mut listed: Vec<String> = Vec::new();
    for l in index.lines() {
        let l = l.trim();
        if l.starts_with('[') {
            flush(&mut cur, scale, &ty, &mut dirs);
            section = l.trim_matches(['[', ']']).to_string();
            scale = 1;
            ty.clear();
            if listed.contains(&section) {
                cur = Some(Dir { path: section.clone(), size: 0, scalable: false });
            }
            continue;
        }
        let Some((k, v)) = l.split_once('=') else { continue };
        let (k, v) = (k.trim(), v.trim());
        if section == "Icon Theme" {
            match k {
                "Directories" | "ScaledDirectories" => listed.extend(v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty())),
                "Inherits" => inherits = v.split(',').map(|s| s.trim().to_string()).collect(),
                _ => {}
            }
        } else if let Some(d) = cur.as_mut() {
            match k {
                "Size" => d.size = v.parse().unwrap_or(0),
                "Scale" => scale = v.parse().unwrap_or(1),
                "Type" => ty = v.to_string(),
                _ => {}
            }
        }
    }
    flush(&mut cur, scale, &ty, &mut dirs);
    Some(Theme { roots, dirs, inherits })
}

fn in_theme(c: &mut Cache, theme: &str, name: &str, size: u32, seen: &mut Vec<String>) -> Option<PathBuf> {
    if seen.iter().any(|s| s == theme) {
        return None;
    }
    seen.push(theme.to_string());
    if !c.themes.contains_key(theme) {
        let t = load_theme(theme);
        c.themes.insert(theme.to_string(), t);
    }
    let mut best: Option<(u32, PathBuf)> = None;
    let inherits = {
        let t = c.themes.get(theme)?.as_ref()?;
        for d in &t.dirs {
            for r in &t.roots {
                for ext in ["svg", "png"] {
                    let p = r.join(&d.path).join(format!("{name}.{ext}"));
                    if p.exists() {
                        let dist = if d.scalable { 0 } else { d.size.abs_diff(size) * 2 + u32::from(d.size < size) };
                        if best.as_ref().is_none_or(|(b, _)| dist < *b) {
                            best = Some((dist, p));
                        }
                    }
                }
            }
        }
        t.inherits.clone()
    };
    if let Some((_, p)) = best {
        return Some(p);
    }
    for parent in inherits {
        if let Some(p) = in_theme(c, &parent, name, size, seen) {
            return Some(p);
        }
    }
    None
}

/// The file for an icon name at about `size` pixels; an absolute path is
/// taken as it is. `extra` is a directory an app ships its own icons in (a
/// tray item's IconThemePath).
pub fn find(name: &str, size: u32, extra: Option<&Path>) -> Option<PathBuf> {
    if name.is_empty() {
        return None;
    }
    let name = name.strip_prefix("file://").unwrap_or(name);
    if name.starts_with('/') {
        return Path::new(name).exists().then(|| PathBuf::from(name));
    }
    if let Some(dir) = extra {
        for ext in ["svg", "png"] {
            let p = dir.join(format!("{name}.{ext}"));
            if p.exists() {
                return Some(p);
            }
        }
        // Some ship a little theme of their own there.
        if let Ok(rd) = std::fs::read_dir(dir) {
            for e in rd.flatten() {
                let hit = walk(&e.path(), name, 3);
                if hit.is_some() {
                    return hit;
                }
            }
        }
    }
    let mut c = cache().lock().ok()?;
    let key = (name.to_string(), size);
    if let Some(hit) = c.found.get(&key) {
        return hit.clone();
    }
    let user = c.user.get_or_insert_with(user_theme).clone();
    let mut seen = Vec::new();
    let hit = in_theme(&mut c, &user, name, size, &mut seen)
        .or_else(|| in_theme(&mut c, "hicolor", name, size, &mut seen))
        .or_else(|| {
            ["svg", "png", "xpm"]
                .iter()
                .map(|e| PathBuf::from(format!("/usr/share/pixmaps/{name}.{e}")))
                .find(|p| p.exists() && !p.to_string_lossy().ends_with(".xpm"))
        });
    c.found.insert(key, hit.clone());
    hit
}

fn walk(dir: &Path, name: &str, depth: u32) -> Option<PathBuf> {
    if depth == 0 || !dir.is_dir() {
        return None;
    }
    for ext in ["svg", "png"] {
        let p = dir.join(format!("{name}.{ext}"));
        if p.exists() {
            return Some(p);
        }
    }
    for e in std::fs::read_dir(dir).ok()?.flatten() {
        if let Some(p) = walk(&e.path(), name, depth - 1) {
            return Some(p);
        }
    }
    None
}

/// The Icon= of an app's desktop entry ("firefox" → firefox.desktop), for a
/// notification that names its app but sends no icon.
pub fn desktop_icon(entry: &str) -> Option<String> {
    if entry.is_empty() {
        return None;
    }
    let data = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/share"));
    let mut dirs = vec![data];
    let sys = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    dirs.extend(sys.split(':').filter(|d| !d.is_empty()).map(PathBuf::from));
    let file = if entry.ends_with(".desktop") { entry.to_string() } else { format!("{entry}.desktop") };
    for d in dirs {
        let Ok(t) = std::fs::read_to_string(d.join("applications").join(&file)) else { continue };
        for l in t.lines() {
            if let Some(v) = l.strip_prefix("Icon=") {
                return Some(v.trim().to_string());
            }
        }
    }
    None
}
