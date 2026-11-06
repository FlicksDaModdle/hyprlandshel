//! Settings → Wallpaper → Live's gallery (WallpaperGallery.qml, fed as
//! services/LiveWallpaper.qml feeds it): a still from each video, made with
//! ffmpeg into the cache the shell's own gallery uses, so each is made
//! once for both.

use crate::{GalItem, Gal};
use slint::{ComponentHandle, Image, ModelRc, SharedString, VecModel};
use std::collections::HashMap;
use std::process::Command;

#[derive(Clone, Default)]
pub struct Video {
    pub dir: String,
    pub title: String,
    pub preview: String,
}

#[derive(Default)]
pub struct Videos {
    pub list: Vec<Video>,
    pub ffmpeg: bool,
    pub scanned: bool,
    pub scanning: bool,
    /// Stills already loaded, by file.
    pub images: HashMap<String, Image>,
}

fn cache() -> String {
    let base = std::env::var("XDG_CACHE_HOME").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| format!("{}/.cache", hyprshell_kit::home().display()));
    format!("{base}/hyprshell/live/thumbs")
}

/// LiveWallpaper.scanProc: the videos in the folders (two levels down) and
/// the files, each with its still when there is one, and the stills to
/// make. A still is named by the cksum of the video's path, as there.
const SCAN: &str = r#"
command -v ffmpeg >/dev/null 2>&1 && echo ffmpeg
thumbs=$1 n=$2; shift 2
mkdir -p "$thumbs"
list() {
    i=0
    for f in "$@"; do
        i=$((i + 1))
        if [ $i -le $n ]; then
            [ -d "$f" ] && find -L "$f" -maxdepth 2 -type f \( -iname '*.mp4' -o -iname '*.m4v' \
                -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.avi' \
                -o -iname '*.ogv' -o -iname '*.gif' \) 2>/dev/null
        else
            [ -f "$f" ] && printf '%s\n' "$f"
        fi
    done
}
list "$@" | while IFS= read -r v; do
    t="$thumbs/$(printf '%s' "$v" | cksum | cut -d' ' -f1).jpg"
    if [ -s "$t" ]; then printf 'V\t%s\t%s\n' "$v" "$t"
    else printf 'V\t%s\t\n' "$v"; printf 'T\t%s\t%s\n' "$v" "$t"; fi
done
"#;

/// LiveWallpaper.thumbProc: a frame a second in; the first frame when the
/// video is shorter than that.
const THUMBS: &str = r#"
made=0
while [ $# -ge 2 ]; do
    v=$1 t=$2; shift 2
    ffmpeg -nostdin -loglevel error -ss 1 -i "$v" -frames:v 1 -vf scale=360:-2 -y "$t" 2>/dev/null
    [ -s "$t" ] || ffmpeg -nostdin -loglevel error -i "$v" -frames:v 1 -vf scale=360:-2 -y "$t" 2>/dev/null
    [ -s "$t" ] && made=1
done
echo $made
"#;

/// What there is, and the stills still to make. Blocking: run it off the
/// window's thread.
pub fn scan(folders: &[String], files: &[String]) -> (Vec<Video>, Vec<String>, bool) {
    let mut args = vec!["-c".to_string(), SCAN.to_string(), "sh".into(), cache(), folders.len().to_string()];
    args.extend(folders.iter().cloned());
    args.extend(files.iter().cloned());
    let out = Command::new("sh").args(&args).output().map(|o| String::from_utf8_lossy(&o.stdout).to_string()).unwrap_or_default();
    let (mut found, mut todo, mut ff) = (Vec::<Video>::new(), vec![], false);
    let mut seen = std::collections::HashSet::new();
    for line in out.lines() {
        if line == "ffmpeg" {
            ff = true;
            continue;
        }
        let p: Vec<&str> = line.split('\t').collect();
        if p.len() < 3 {
            continue;
        }
        if p[0] == "T" {
            todo.push(p[1].to_string());
            todo.push(p[2].to_string());
            continue;
        }
        if p[0] != "V" || !seen.insert(p[1].to_string()) {
            continue;
        }
        let name = p[1].rsplit('/').next().unwrap_or(p[1]);
        let name = name.rsplit_once('.').map(|x| x.0).unwrap_or(name);
        found.push(Video { dir: p[1].into(), title: name.replace('_', " "), preview: p[2].into() });
    }
    found.sort_by_key(|v| v.title.to_lowercase());
    (found, todo, ff)
}

/// Makes the stills; true if any was made. Blocking, and slow: niced.
pub fn make_thumbs(todo: &[String]) -> bool {
    let mut args = vec!["-n".to_string(), "15".into(), "sh".into(), "-c".into(), THUMBS.into(), "sh".into()];
    args.extend(todo.iter().cloned());
    Command::new("nice").args(&args).output().map(|o| String::from_utf8_lossy(&o.stdout).trim() == "1").unwrap_or(false)
}

impl Videos {
    /// The gallery into the window: what matches the search, the one on
    /// (or the one for the screen being picked for) ticked.
    pub fn publish(&mut self, ui: &crate::AppWindow, current: &str) {
        let g = ui.global::<Gal>();
        let q = g.get_query().trim().to_lowercase();
        let mut items = vec![];
        for v in self.list.iter().filter(|v| q.is_empty() || v.title.to_lowercase().contains(&q)) {
            let img = if v.preview.is_empty() {
                None
            } else {
                Some(self.images.entry(v.preview.clone()).or_insert_with(|| Image::load_from_path(std::path::Path::new(&v.preview)).unwrap_or_default()).clone())
            };
            items.push(GalItem {
                dir: v.dir.clone().into(),
                title: v.title.clone().into(),
                has_img: img.as_ref().is_some_and(|i| i.size().width > 0),
                img: img.unwrap_or_default(),
                badge: SharedString::new(),
                current: v.dir == current,
            });
        }
        g.set_items(ModelRc::new(VecModel::from(items)));
        g.set_total(self.list.len() as i32);
    }
}
