//! Bar plugins: your own modules for the top bar, from files, in any language.
//!
//! A plugin is a folder (or a single file) in `~/.config/hyprshell/bar-plugins/`:
//!
//!     bar-plugins/cpu/plugin.json      or      bar-plugins/cpu.json
//!
//! ```json
//! {
//!   "name": "CPU load",
//!   "side": "right",
//!   "exec": "./cpu.sh",
//!   "interval": 5,
//!   "icon": "cpu",
//!   "on_click": ["run kitty htop"],
//!   "on_scroll_up": ["run ..."], "on_scroll_down": ["run ..."],
//!   "on_right_click": ["notify CPU | right-clicked"],
//!   "menu": [{ "label": "Open htop", "steps": ["start kitty htop"] }]
//! }
//! ```
//!
//! `exec` is run by `sh` in the plugin's folder every `interval` seconds
//! (at least 1; 0 runs it once); what it prints is the module. Plain text:
//! the first line is the label. Or one JSON object:
//!
//!     { "text": "42%", "icon": "cpu", "tooltip": "8 cores", "class": "warn" }
//!
//! `class` tints the label: `ok`, `warn`, `crit` or `accent`. The actions
//! are steps as a shortcut has them (see shortcuts.rs); they run with
//! `PLUGIN_ID` and `PLUGIN_DIR` set. A click opens `menu` when there is
//! one and no `on_click`.
//!
//! (A script named in `exec` has to be executable: `chmod +x`.)
//!
//! The folder is looked at every few seconds: a plugin added, changed or
//! removed is picked up without restarting the shell. The module's id is
//! `plugin:<name of the folder or file>`; where it sits is the bar's
//! layout (barmods.rs), and Settings → Bar changes that.

use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

#[derive(Clone, Debug, Default, PartialEq)]
pub struct MenuItem {
    pub label: String,
    pub steps: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Manifest {
    /// The id as the bar names it: `plugin:<folder>`.
    pub id: String,
    pub name: String,
    /// Where it goes the first time: "left" or "right".
    pub side: String,
    pub dir: PathBuf,
    pub exec: String,
    pub interval: f64,
    pub icon: String,
    pub tooltip: String,
    pub on_click: Vec<String>,
    pub on_right_click: Vec<String>,
    pub on_scroll_up: Vec<String>,
    pub on_scroll_down: Vec<String>,
    pub menu: Vec<MenuItem>,
}

/// What a plugin last printed.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Output {
    pub text: String,
    pub icon: String,
    pub tooltip: String,
    /// 0 none, 1 ok, 2 warn, 3 crit, 4 accent.
    pub tint: i32,
}

pub fn dir() -> PathBuf {
    crate::theme::path().with_file_name("bar-plugins")
}

fn steps(v: &Value) -> Vec<String> {
    match v {
        Value::String(s) if !s.trim().is_empty() => vec![s.trim().to_string()],
        Value::Array(a) => a.iter().filter_map(|x| x.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect(),
        _ => Vec::new(),
    }
}

/// `plugin:<name>` for a name made of letters, digits, `-` and `_`.
fn id_for(name: &str) -> Option<String> {
    let ok = !name.is_empty() && name.len() <= 40 && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    ok.then(|| format!("plugin:{name}"))
}

pub fn parse(name: &str, base: &Path, text: &str) -> Option<Manifest> {
    let v: Value = serde_json::from_str(text).ok()?;
    let id = id_for(name)?;
    let exec = v["exec"].as_str().unwrap_or("").trim().to_string();
    let menu: Vec<MenuItem> = v["menu"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let label = m["label"].as_str()?.trim().to_string();
            (!label.is_empty()).then(|| MenuItem { label, steps: steps(&m["steps"]) })
        })
        .take(24)
        .collect();
    let m = Manifest {
        id,
        name: v["name"].as_str().map(str::trim).filter(|n| !n.is_empty()).unwrap_or(name).to_string(),
        side: if v["side"].as_str() == Some("left") { "left" } else { "right" }.into(),
        dir: base.to_path_buf(),
        exec,
        interval: v["interval"].as_f64().unwrap_or(5.0).clamp(0.0, 86400.0),
        icon: v["icon"].as_str().unwrap_or("").trim().to_string(),
        tooltip: v["tooltip"].as_str().unwrap_or("").to_string(),
        on_click: steps(&v["on_click"]),
        on_right_click: steps(&v["on_right_click"]),
        on_scroll_up: steps(&v["on_scroll_up"]),
        on_scroll_down: steps(&v["on_scroll_down"]),
        menu,
    };
    // Nothing to show and nothing to do is no plugin.
    (!m.exec.is_empty() || !m.icon.is_empty() || !m.on_click.is_empty() || !m.menu.is_empty()).then_some(m)
}

/// Every plugin in the folder, with when each changed (so a change is noticed).
pub fn discover(root: &Path) -> Vec<(Manifest, SystemTime)> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(root) else { return out };
    for e in rd.flatten() {
        let path = e.path();
        let (name, file, base) = if path.is_dir() {
            (e.file_name().to_string_lossy().to_string(), path.join("plugin.json"), path.clone())
        } else if path.extension().is_some_and(|x| x == "json") {
            (path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(), path.clone(), root.to_path_buf())
        } else {
            continue;
        };
        let (Ok(text), Ok(meta)) = (std::fs::read_to_string(&file), std::fs::metadata(&file)) else { continue };
        // The script beside it counts for the change too: edit it and it runs again.
        let when = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        if let Some(m) = parse(&name, &base, &text) {
            out.push((m, when));
        }
    }
    out.sort_by(|a, b| a.0.id.cmp(&b.0.id));
    out
}

/// What a plugin printed, as a module shows it.
pub fn parse_output(m: &Manifest, printed: &str) -> Output {
    let printed = printed.trim();
    let mut o = Output { icon: m.icon.clone(), tooltip: m.tooltip.clone(), ..Output::default() };
    if printed.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<Value>(printed) {
            o.text = v["text"].as_str().map(|t| t.to_string()).unwrap_or_else(|| v["text"].to_string().trim_matches('"').replace("null", ""));
            if let Some(i) = v["icon"].as_str().filter(|i| !i.is_empty()) {
                o.icon = i.to_string();
            }
            if let Some(t) = v["tooltip"].as_str() {
                o.tooltip = t.to_string();
            }
            o.tint = match v["class"].as_str().unwrap_or("") {
                "ok" => 1,
                "warn" => 2,
                "crit" | "critical" => 3,
                "accent" => 4,
                _ => 0,
            };
            o.text = o.text.chars().take(60).collect();
            return o;
        }
    }
    o.text = printed.lines().next().unwrap_or("").trim().chars().take(60).collect();
    o
}

/// Run a plugin's `exec` once, and return what it printed (a minute at most).
pub fn run_exec(m: &Manifest) -> Option<String> {
    if m.exec.is_empty() {
        return None;
    }
    let mut child = std::process::Command::new("sh")
        .args(["-c", &m.exec])
        .current_dir(&m.dir)
        .env("PLUGIN_ID", &m.id)
        .env("PLUGIN_DIR", &m.dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(o) = stdout.as_mut() {
            let _ = std::io::Read::read_to_end(&mut std::io::Read::take(o, 8192), &mut buf);
        }
        buf
    });
    let start = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => break,
            Ok(None) if start.elapsed() > Duration::from_secs(60) => {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
    Some(String::from_utf8_lossy(&reader.join().unwrap_or_default()).to_string())
}

/// A new plugin to change: a folder with a working `plugin.json` and a script that
/// prints the time. Returns its folder.
pub fn make_template() -> Option<PathBuf> {
    let root = dir();
    let n = (1..).find(|n| !root.join(format!("my-plugin-{n}")).exists())?;
    let folder = root.join(format!("my-plugin-{n}"));
    std::fs::create_dir_all(&folder).ok()?;
    std::fs::write(
        folder.join("plugin.json"),
        "{\n  \"name\": \"My plugin\",\n  \"side\": \"right\",\n  \"exec\": \"./run.sh\",\n  \"interval\": 5,\n  \"icon\": \"zap\",\n  \"on_click\": [\"notify My plugin | You clicked it\"],\n  \"menu\": []\n}\n",
    )
    .ok()?;
    std::fs::write(folder.join("run.sh"), "#!/bin/sh\n# What this prints is the module. A JSON object also works:\n#   {\"text\": \"42%\", \"icon\": \"cpu\", \"tooltip\": \"more\", \"class\": \"warn\"}\ndate +%H:%M:%S\n").ok()?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(folder.join("run.sh"), std::fs::Permissions::from_mode(0o755)).ok()?;
    Some(folder)
}

/// The plugins, running: each on its own thread, printing into one table.
pub struct Plugins {
    pub list: Vec<Manifest>,
    stamps: Vec<(String, SystemTime)>,
    pub out: Arc<Mutex<HashMap<String, Output>>>,
    stop: Arc<AtomicBool>,
    checked: Instant,
}

impl Plugins {
    pub fn new() -> Self {
        Plugins { list: Vec::new(), stamps: Vec::new(), out: Arc::new(Mutex::new(HashMap::new())), stop: Arc::new(AtomicBool::new(false)), checked: Instant::now() - Duration::from_secs(60) }
    }

    /// Look at the folder (every few seconds); true if the set of plugins changed.
    pub fn refresh(&mut self) -> bool {
        if self.checked.elapsed() < Duration::from_secs(4) {
            return false;
        }
        self.checked = Instant::now();
        let found = discover(&dir());
        let stamps: Vec<(String, SystemTime)> = found.iter().map(|(m, t)| (m.id.clone(), *t)).collect();
        // A change of the script itself isn't seen, but it is read afresh at each run.
        if stamps == self.stamps {
            return false;
        }
        // The old ones stop; the new ones start.
        self.stop.store(true, Ordering::SeqCst);
        self.stop = Arc::new(AtomicBool::new(false));
        self.stamps = stamps;
        self.list = found.into_iter().map(|(m, _)| m).collect();
        if let Ok(mut o) = self.out.lock() {
            o.retain(|id, _| self.list.iter().any(|m| &m.id == id));
        }
        for m in self.list.clone() {
            let (out, stop) = (self.out.clone(), self.stop.clone());
            std::thread::spawn(move || loop {
                if stop.load(Ordering::SeqCst) {
                    return;
                }
                if let Some(text) = run_exec(&m) {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    if let Ok(mut o) = out.lock() {
                        o.insert(m.id.clone(), parse_output(&m, &text));
                    }
                }
                if m.interval <= 0.0 {
                    return;
                }
                // In small steps, so a stop is heard.
                let until = Instant::now() + Duration::from_secs_f64(m.interval.max(1.0));
                while Instant::now() < until {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(250));
                }
            });
        }
        true
    }

    pub fn ids(&self) -> Vec<String> {
        self.list.iter().map(|m| m.id.clone()).collect()
    }

    pub fn get(&self, id: &str) -> Option<&Manifest> {
        self.list.iter().find(|m| m.id == id)
    }

    /// What a module shows now: its last output, or its icon until there is one.
    pub fn shown(&self, id: &str) -> Output {
        let m = self.get(id);
        self.out.lock().ok().and_then(|o| o.get(id).cloned()).unwrap_or_else(|| Output { icon: m.map(|m| m.icon.clone()).unwrap_or_default(), ..Output::default() })
    }
}

/// Run a plugin's action steps, off the shell's thread.
pub fn act(m: &Manifest, steps: Vec<String>) {
    if steps.is_empty() {
        return;
    }
    let env: HashMap<String, String> = [("PLUGIN_ID".to_string(), m.id.clone()), ("PLUGIN_DIR".to_string(), m.dir.display().to_string())].into_iter().collect();
    std::thread::spawn(move || {
        crate::shortcuts::run_tool(&steps, &env);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("hs-plugins-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn a_manifest_is_read_and_a_useless_or_oddly_named_one_is_not() {
        let base = Path::new("/x");
        let m = parse("cpu", base, r#"{"name":"CPU","exec":"echo hi","interval":0.2,"icon":"cpu","on_click":"run foo","menu":[{"label":"A","steps":["run a"]},{"label":""}]}"#).unwrap();
        assert_eq!((m.id.as_str(), m.name.as_str(), m.side.as_str()), ("plugin:cpu", "CPU", "right"));
        assert_eq!(m.on_click, ["run foo"]); // a single string is one step
        assert_eq!(m.menu.len(), 1);
        assert!(parse("bad name!", base, r#"{"exec":"x"}"#).is_none());
        assert!(parse("empty", base, r#"{"name":"nothing"}"#).is_none());
        assert!(parse("junk", base, "not json").is_none());
        assert_eq!(parse("l", base, r#"{"exec":"x","side":"left"}"#).unwrap().side, "left");
    }

    #[test]
    fn output_is_plain_text_or_json() {
        let m = parse("c", Path::new("/x"), r#"{"exec":"x","icon":"cpu","tooltip":"static"}"#).unwrap();
        let o = parse_output(&m, "42%\nsecond line\n");
        assert_eq!((o.text.as_str(), o.icon.as_str(), o.tooltip.as_str(), o.tint), ("42%", "cpu", "static", 0));
        let o = parse_output(&m, r#"{"text":"97%","icon":"zap","tooltip":"hot","class":"crit"}"#);
        assert_eq!((o.text.as_str(), o.icon.as_str(), o.tooltip.as_str(), o.tint), ("97%", "zap", "hot", 3));
        assert_eq!(parse_output(&m, "{broken").text, "{broken");
    }

    #[test]
    fn plugins_are_found_as_folders_and_as_single_files_and_run() {
        let root = temp("find");
        std::fs::create_dir_all(root.join("greet")).unwrap();
        std::fs::write(root.join("greet/plugin.json"), r#"{"exec":"./hello.sh"}"#).unwrap();
        std::fs::write(root.join("greet/hello.sh"), "#!/bin/sh\necho \"hello from $PLUGIN_ID\"\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(root.join("greet/hello.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::write(root.join("solo.json"), r#"{"exec":"echo solo","side":"left"}"#).unwrap();
        std::fs::write(root.join("notes.txt"), "ignored").unwrap();
        let found = discover(&root);
        assert_eq!(found.iter().map(|(m, _)| m.id.as_str()).collect::<Vec<_>>(), ["plugin:greet", "plugin:solo"]);
        // exec runs in the plugin's folder, with its id in the environment.
        let greet = &found[0].0;
        assert_eq!(run_exec(greet).unwrap().trim(), "hello from plugin:greet");
        assert_eq!(run_exec(&found[1].0).unwrap().trim(), "solo");
        let _ = std::fs::remove_dir_all(&root);
    }
}
