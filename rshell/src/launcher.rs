//! What the launcher shows and starts (modules/launcher/Launcher.qml and
//! config/Apps.qml): the installed apps from their desktop entries, the
//! pinned ones from theme.json's dockPinned, the shell's commands, recent
//! files from recently-used.xbel, and how a search ranks them.

use crate::art::{self, Pixels};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub struct Entry {
    pub id: String,
    pub name: String,
    /// What the list shows under the name: its generic name, comment or
    /// first category.
    pub about: String,
    pub icon: String,
    pub exec: Vec<String>,
    pub terminal: bool,
    pub path: String,
    pub class: String,
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
}

fn data_dirs() -> Vec<PathBuf> {
    let mut v = vec![std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/share"))];
    let sys = std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".into());
    v.extend(sys.split(':').filter(|d| !d.is_empty()).map(PathBuf::from));
    v
}

/// An Exec= line as the arguments it runs: quoting undone, the field codes
/// (%f %U …) left out, %% as a percent sign.
pub fn split_exec(line: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quoted = false;
    let mut any = false;
    let mut it = line.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            '"' => {
                quoted = !quoted;
                any = true;
            }
            '\\' if quoted => {
                if let Some(n) = it.next() {
                    cur.push(n);
                }
            }
            ' ' | '\t' if !quoted => {
                if any || !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                    any = false;
                }
            }
            '%' => match it.next() {
                Some('%') => cur.push('%'),
                Some(_) => {}
                None => {}
            },
            _ => cur.push(c),
        }
    }
    if any || !cur.is_empty() {
        out.push(cur);
    }
    out.retain(|a| !a.is_empty());
    out
}

fn parse(path: &Path, id: &str) -> Option<Entry> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    let mut f: HashMap<&str, &str> = HashMap::new();
    for l in text.lines() {
        let l = l.trim();
        if l.starts_with('[') {
            in_entry = l == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some((k, v)) = l.split_once('=') {
            // The untranslated keys; Name[de] and the like are left alone.
            f.entry(k.trim()).or_insert(v.trim());
        }
    }
    if f.get("Type").copied().unwrap_or("Application") != "Application" {
        return None;
    }
    let yes = |k: &str| f.get(k).is_some_and(|v| *v == "true");
    if yes("NoDisplay") || yes("Hidden") {
        return None;
    }
    let desktops = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_else(|_| "Hyprland".into());
    let ours = |list: &str| list.split(';').any(|d| !d.is_empty() && desktops.split(':').any(|x| x.eq_ignore_ascii_case(d)));
    if f.get("OnlyShowIn").is_some_and(|v| !ours(v)) || f.get("NotShowIn").is_some_and(|v| ours(v)) {
        return None;
    }
    let name = f.get("Name")?.to_string();
    let about = f
        .get("GenericName")
        .or(f.get("Comment"))
        .map(|s| s.to_string())
        .or_else(|| f.get("Categories").and_then(|c| c.split(';').next()).map(|s| s.to_string()))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Application".into());
    Some(Entry {
        id: id.to_string(),
        name,
        about,
        icon: f.get("Icon").unwrap_or(&"").to_string(),
        exec: split_exec(f.get("Exec").copied().unwrap_or("")),
        terminal: yes("Terminal"),
        path: f.get("Path").unwrap_or(&"").to_string(),
        class: f.get("StartupWMClass").unwrap_or(&"").to_string(),
    })
}

fn walk(dir: &Path, prefix: &str, seen: &mut HashMap<String, ()>, out: &mut Vec<Entry>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut names: Vec<_> = rd.flatten().collect();
    names.sort_by_key(|e| e.file_name());
    for e in names {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if p.is_dir() {
            walk(&p, &format!("{prefix}{name}-"), seen, out);
        } else if let Some(stem) = name.strip_suffix(".desktop") {
            let id = format!("{prefix}{stem}");
            // The first one found wins: the user's own over the system's.
            if seen.insert(id.clone(), ()).is_none() {
                if let Some(entry) = parse(&p, &id) {
                    out.push(entry);
                }
            }
        }
    }
}

/// Every app there is to start, as DesktopEntries.applications has them.
pub fn entries() -> Vec<Entry> {
    let mut seen = HashMap::new();
    let mut out = Vec::new();
    for d in data_dirs() {
        walk(&d.join("applications"), "", &mut seen, &mut out);
    }
    // The shell's own task manager has a tile of its own.
    out.retain(|e| e.id != "hyprshell-tasks");
    out.sort_by_key(|e| e.name.to_lowercase());
    out
}

/// The entries' icons, from the icon theme, decoded: a slow-ish job for a
/// helper thread, done once.
pub fn entry_icons(list: &[Entry], size: u32) -> Vec<(String, Pixels)> {
    list.iter()
        .filter_map(|e| {
            let p = crate::icons::find(&e.icon, size, None)?;
            Some((e.id.clone(), art::file(&p, size)?))
        })
        .collect()
}

#[derive(Clone)]
pub struct Pinned {
    pub key: String,
    pub label: String,
    pub icon: String,
    pub exec: Vec<String>,
    /// Which windows are this app's: a pattern over their class.
    pub matcher: String,
}

impl Pinned {
    pub fn matches(&self, class: &str) -> bool {
        regex::RegexBuilder::new(&self.matcher).case_insensitive(true).build().is_ok_and(|r| r.is_match(class))
    }
}

const WEB_FINDER: &str = "command -v hyprshell-browser >/dev/null 2>&1 && exec hyprshell-browser \"$@\"; \
    [ -x \"$HOME/.local/bin/hyprshell-browser\" ] && exec \"$HOME/.local/bin/hyprshell-browser\" \"$@\"; \
    for b in firefox chromium google-chrome-stable brave; do command -v \"$b\" >/dev/null 2>&1 && exec \"$b\" \"$@\"; done; \
    notify-send \"Web\" \"no browser is installed\" 2>/dev/null; exit 127";

const FILES_FINDER: &str = "command -v hyprshell-files >/dev/null 2>&1 && exec hyprshell-files \"$@\"; \
    [ -x \"$HOME/.local/bin/hyprshell-files\" ] && exec \"$HOME/.local/bin/hyprshell-files\" \"$@\"; \
    exec xdg-open \"${1:-$HOME}\"";

fn defaults() -> Vec<Pinned> {
    let p = |key: &str, label: &str, icon: &str, exec: &[&str], m: &str| Pinned {
        key: key.into(),
        label: label.into(),
        icon: icon.into(),
        exec: exec.iter().map(|s| s.to_string()).collect(),
        matcher: m.into(),
    };
    vec![
        p("appTerm", "Terminal", "terminal", &[], r"^(hyprshell-term|kitty|foot|alacritty|wezterm|org\.wezfurlong\.wezterm)$"),
        p("appFiles", "Files", "folder", &[], r"^(hyprshell-files|org\.gnome\.Nautilus|nautilus|thunar|dolphin|nemo|pcmanfm.*)$"),
        p("appWeb", "Web", "globe", &["sh", "-c", WEB_FINDER, "open-web"], r"^(hyprshell-browser|firefox.*|chromium|google-chrome.*|brave-browser|zen.*)$"),
        p("appCode", "Code", "code", &["neovide"], r"^(neovide|code|code-oss|codium|dev\.zed\.Zed|jetbrains-.*)$"),
        p("appNotes", "Notes", "stickyNote", &["obsidian"], r"^(obsidian|org\.gnome\.TextEditor|logseq)$"),
        p("appMusic", "Music", "music", &[], r"^(ncmpcpp|spotify|org\.gnome\.Rhythmbox3|io\.bassi\.Amberol)$"),
    ]
}

/// The pinned apps, as Config.Apps.pinned reads them from theme.json.
pub fn pinned(theme: &Value) -> Vec<Pinned> {
    let raw = theme["dockPinned"].as_str().unwrap_or("");
    let list: Vec<Value> = serde_json::from_str(raw).unwrap_or_default();
    if list.is_empty() {
        return defaults();
    }
    let defs = defaults();
    list.iter()
        .filter_map(|e| {
            let key = e["key"].as_str()?.to_string();
            if key == "appSettings" {
                return None;
            }
            let def = defs.iter().find(|d| d.key == key);
            let mut exec: Vec<String> = e["exec"].as_array().into_iter().flatten().filter_map(|a| a.as_str().map(str::to_string)).collect();
            if key == "appWeb" && exec == ["firefox"] {
                exec = def.map(|d| d.exec.clone()).unwrap_or(exec);
            }
            // A stored pattern that has lost the default's names gets them
            // back, as Apps.qml does.
            let stored = e["match"].as_str().unwrap_or("^$").to_string();
            let matcher = match def {
                Some(d) if !stored.contains(&d.matcher) => format!("(?:{stored})|(?:{})", d.matcher),
                _ => stored,
            };
            Some(Pinned {
                matcher,
                label: e["label"].as_str().filter(|s| !s.is_empty()).map(str::to_string).or(def.map(|d| d.label.clone())).unwrap_or_default(),
                icon: e["icon"].as_str().unwrap_or("square").to_string(),
                exec,
                key,
            })
        })
        .collect()
}

/// The shell's own tiles: what a pinned app with no command of its own runs.
pub fn tile_command(key: &str) -> Option<Vec<String>> {
    let term = crate::extras::terminal();
    Some(match key {
        "appTerm" => vec![term],
        "appFiles" => vec!["sh".into(), "-c".into(), FILES_FINDER.into(), "open-files".into()],
        "appMusic" => vec![term, "-e".into(), "ncmpcpp".into()],
        _ => return None,
    })
}

pub fn files_command(path: &str) -> Vec<String> {
    vec!["sh".into(), "-c".into(), FILES_FINDER.into(), "open-files".into(), path.into()]
}

/// The commands the launcher lists (config/Commands.qml), those this shell
/// can do so far.
pub const COMMANDS: [(&str, &str, &str, &str); 22] = [
    ("overview", "Overview", "panelsTopLeft", "Command · workspaces"),
    ("settings", "Settings", "settings", "System · shell and device"),
    ("theme", "Theme", "palette", "Command · switch light / dark"),
    ("capture", "Screenshot", "camera", "Command · region, window or screen — or a recording"),
    ("record", "Record screen", "monitor", "Command · start or stop a screen recording"),
    ("ocr", "Text from screen", "font", "Command · copy the words in a region"),
    ("displays", "Displays", "monitor", "System · monitors and scaling"),
    ("tasks", "Task Manager", "cpu", "System · processes, performance, services, startup apps"),
    ("updates", "Updates", "package", "System · pending package updates"),
    ("timers", "Timers", "timer", "Command · timer, pomodoro, alarms"),
    ("clipboard", "Clipboard history", "clipboard", "System · what you copied, to paste again"),
    ("sound", "Sound", "volume", "System · output and input"),
    ("network", "Network", "wifi", "System · wireless"),
    ("bluetooth", "Bluetooth", "bluetooth", "System · paired devices"),
    ("keybinds", "Keybinds", "keyboard", "Command · cheatsheet"),
    ("osk", "On-screen keyboard", "keyboard", "Command · type without a keyboard"),
    ("iconmaker", "Icon Maker", "palette", "Command · draw a shell icon"),
    ("wallpaper", "Wallpaper", "image", "Command · change the ground"),
    ("reload", "Reload shell", "refresh", "Command · re-read the QML tree"),
    ("lock", "Lock", "lock", "Session · lock the screen"),
    ("logout", "Log out", "logOut", "Session · end this session"),
    ("suspend", "Suspend", "moon", "Session · sleep"),
];

/// Searchable only, not tiles in the grid (Commands.qml has no tile for it).
pub const SEARCH_ONLY: [(&str, &str, &str, &str); 2] = [
    ("reboot", "Restart", "reboot", "Session · restart"),
    ("poweroff", "Shut down", "power", "Session · shut down"),
];

/// Every command the search can find.
pub fn all_commands() -> impl Iterator<Item = &'static (&'static str, &'static str, &'static str, &'static str)> {
    COMMANDS.iter().chain(SEARCH_ONLY.iter())
}

#[derive(Clone)]
pub struct Recent {
    pub name: String,
    pub path: String,
    pub modified: String,
}

/// The four files used last, from recently-used.xbel.
pub fn recent() -> Vec<Recent> {
    let base = std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".local/share"));
    let Ok(xml) = std::fs::read_to_string(base.join("recently-used.xbel")) else { return Vec::new() };
    let attr = |tag: &str, name: &str| -> Option<String> {
        let at = tag.find(&format!("{name}=\""))? + name.len() + 2;
        let end = tag[at..].find('"')?;
        Some(tag[at..at + end].to_string())
    };
    let mut out: Vec<Recent> = xml
        .split("<bookmark ")
        .skip(1)
        .filter_map(|t| {
            let tag = &t[..t.find('>')?];
            let href = attr(tag, "href")?;
            let path = art::percent_decode(href.strip_prefix("file://")?);
            Some(Recent { name: path.rsplit('/').next().unwrap_or("").to_string(), modified: attr(tag, "modified").unwrap_or_default(), path })
        })
        .collect();
    out.sort_by(|a, b| b.modified.cmp(&a.modified));
    out.truncate(4);
    out
}

/// "5 min ago", "yesterday", "3 Nov".
pub fn relative(iso: &str) -> String {
    // 2026-11-05T09:12:33.123456Z
    let n = |a: usize, b: usize| iso.get(a..b).and_then(|s| s.parse::<i64>().ok());
    let (Some(y), Some(mo), Some(d), Some(h), Some(mi)) = (n(0, 4), n(5, 7), n(8, 10), n(11, 13), n(14, 16)) else {
        return String::new();
    };
    // Days from the civil date (Howard Hinnant's), then seconds.
    let (y2, m2) = if mo <= 2 { (y - 1, mo + 9) } else { (y, mo - 3) };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * m2 + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    let then = days * 86400 + h * 3600 + mi * 60;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
    let mins = (now - then) / 60;
    const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    match mins {
        m if m < 1 => "just now".into(),
        m if m < 60 => format!("{m} min ago"),
        m if m < 60 * 24 => {
            let h = (m + 30) / 60;
            if h == 1 { "1 hour ago".into() } else { format!("{h} hours ago") }
        }
        m if m < 60 * 48 => "yesterday".into(),
        m if m < 60 * 24 * 7 => format!("{} days ago", m / 60 / 24),
        _ => format!("{} {}", d, MONTHS[(mo - 1).clamp(0, 11) as usize]),
    }
}

/// The glyph for a file, by its extension (FileSearch.icon, iconForFile).
pub fn file_glyph(name: &str, dir: bool) -> &'static str {
    if dir {
        return "folder";
    }
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "svg" | "avif" | "heic" | "bmp" | "tiff" => "image",
        "mp4" | "mkv" | "webm" | "mov" | "avi" => "film",
        "mp3" | "flac" | "ogg" | "opus" | "wav" | "m4a" => "music",
        "zip" | "tar" | "gz" | "xz" | "zst" | "7z" | "rar" | "deb" | "rpm" => "package",
        "c" | "cpp" | "h" | "hpp" | "rs" | "py" | "js" | "ts" | "qml" | "lua" | "sh" | "go" | "java" | "json" | "toml"
        | "yaml" | "yml" | "html" | "css" => "code",
        _ => "file",
    }
}

/// How well a label (and its line underneath) matches a search, as the
/// launcher ranks: the start of the name, the start of a word in it,
/// anywhere in it, then the line under it. None for no match.
pub fn score(label: &str, about: &str, q: &str) -> Option<u8> {
    let l = label.to_lowercase();
    if l.starts_with(q) {
        Some(0)
    } else if l.contains(&format!(" {q}")) {
        Some(1)
    } else if l.contains(q) {
        Some(2)
    } else if about.to_lowercase().contains(q) {
        Some(3)
    } else {
        None
    }
}

const SESSION_RUNNER: &str = "f=\"${XDG_STATE_HOME:-$HOME/.local/state}/hyprshell/session.env\"; \
    [ -r \"$f\" ] && . \"$f\"; \
    if [ -n \"$HYPRSHELL_CWD\" ]; then cd \"$HYPRSHELL_CWD\" 2>/dev/null; unset HYPRSHELL_CWD; fi; \
    exec \"$@\"";

/// Starts a program as Config.Apps.launch does: through the session's
/// environment file, in its own session, in `cwd` if one is given.
pub fn launch(argv: &[String], cwd: &str) {
    if argv.is_empty() {
        return;
    }
    let mut cmd: Vec<String> = Vec::new();
    if !cwd.is_empty() {
        cmd.extend(["env".into(), format!("HYPRSHELL_CWD={cwd}")]);
    }
    cmd.extend(["sh".into(), "-c".into(), SESSION_RUNNER.into(), "launch".into()]);
    cmd.extend(argv.iter().cloned());
    let refs: Vec<&str> = cmd.iter().map(String::as_str).collect();
    crate::extras::spawn(&refs);
}

pub fn launch_entry(e: &Entry) {
    if e.terminal {
        let mut argv = vec![crate::extras::terminal(), "-e".into()];
        argv.extend(e.exec.iter().cloned());
        launch(&argv, &e.path);
    } else {
        launch(&e.exec, &e.path);
    }
}

/// A glyph for an app by its window class or desktop id, as
/// Config.Apps.iconFor's hints have it, for an app with no icon to show.
pub fn glyph_for_class(cls: &str) -> &'static str {
    let c = cls.to_lowercase();
    let has = |words: &[&str]| words.iter().any(|w| c.contains(w));
    if has(&["term", "foot", "kitty", "alacritty", "wezterm", "konsole", "tmux"]) {
        "terminal"
    } else if has(&["nautilus", "thunar", "dolphin", "nemo", "pcmanfm", "files", "ranger"]) {
        "folder"
    } else if has(&["firefox", "chrom", "brave", "epiphany", "zen", "browser", "webkit"]) {
        "globe"
    } else if has(&["code", "nvim", "neovide", "vim", "zed", "jetbrains", "emacs", "idea", "studio"]) {
        "code"
    } else if has(&["obsidian", "logseq", "notes", "texteditor", "gedit", "writer"]) {
        "stickyNote"
    } else if has(&["spotify", "music", "mpd", "ncmpcpp", "audacious", "amberol", "rhythmbox"]) {
        "music"
    } else if has(&["pavucontrol", "volume", "audio", "helvum", "easyeffects"]) {
        "sliders"
    } else if has(&["settings", "control", "config", "tweaks"]) {
        "settings"
    } else if has(&["image", "viewer", "loupe", "eog", "imv", "gwenview", "gimp", "inkscape"]) {
        "image"
    } else if has(&["video", "mpv", "vlc", "celluloid", "obs"]) {
        "monitor"
    } else if has(&["mail", "thunderbird", "evolution", "geary"]) {
        "mail"
    } else if has(&["discord", "telegram", "signal", "element", "slack", "whatsapp", "chat"]) {
        "chat"
    } else if has(&["steam", "game", "lutris", "heroic"]) {
        "gamepad"
    } else if has(&["monitor", "htop", "btop", "system", "resources", "task"]) {
        "cpu"
    } else {
        "square"
    }
}

/// Writes the pinned apps back to theme.json's dockPinned, as Apps.save.
pub fn save_pinned(list: &[Pinned]) {
    let v: Vec<Value> = list
        .iter()
        .map(|p| serde_json::json!({ "key": p.key, "label": p.label, "icon": p.icon, "exec": p.exec, "match": p.matcher }))
        .collect();
    crate::theme::set("dockPinned", Value::String(serde_json::to_string(&v).unwrap_or_default()));
}

/// The desktop entry for a window class, by id or StartupWMClass.
pub fn entry_for_class(cls: &str) -> Option<Entry> {
    let c = cls.to_lowercase();
    entries().into_iter().find(|e| {
        e.class.to_lowercase() == c || e.id.to_lowercase() == c || e.id.to_lowercase().rsplit('.').next() == Some(&c)
    })
}
