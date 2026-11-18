//! Shortcuts: tiles for the control center that you make yourself, in
//! `shortcuts.json` beside theme.json (the Settings app edits it, under
//! Control center → Shortcuts).
//!
//! A shortcut is a name, an icon (any glyph the shell has), and steps, one
//! per line, that run in order when its tile is pressed:
//!
//!     run <command>          run it and wait for it to end
//!     start <command>        start it and go on (an app, a daemon)
//!     open <app, file or address>
//!     notify <title> | <text>
//!     set <setting> <value>  a theme.json setting; the value is JSON or text
//!     flip <setting>         a yes/no setting turned the other way
//!     hypr <lua>             a line for Hyprland's Lua
//!     wait <seconds>         up to an hour
//!
//! A **toggle** has a second list of steps for turning it off, and may say
//! how to tell it is on: `state` is a command that ends 0 when on, or
//! `theme:<setting>` for a yes/no setting, or `theme:<setting>=<value>` for
//! one that is a word (`theme:theme=dark`). Without one the tile remembers
//! what you last pressed.
//!
//! A shortcut can instead be an **applet**: a small panel the tile opens, with
//! a state of its own (see applets.rs): a repeating timer (a Pomodoro), a
//! counter (glasses of water), a stopwatch.
//!
//! ```json
//! [{ "id": "focus", "name": "Focus", "icon": "moon", "toggle": true,
//!    "steps": ["set dnd true", "run makoctl mode -a focus"],
//!    "off":   ["set dnd false"], "state": "theme:dnd" },
//!  { "id": "pomodoro", "name": "Pomodoro", "icon": "timer",
//!    "applet": { "kind": "cycle", "rounds": 4, "quiet": true,
//!                "phases": [{ "name": "Focus", "minutes": 25 }, { "name": "Break", "minutes": 5 }] } }]
//! ```

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Read as _;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

#[derive(Clone, Debug, Default)]
pub struct Shortcut {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub toggle: bool,
    pub steps: Vec<String>,
    pub off: Vec<String>,
    pub state: String,
    /// A mini applet (a timer, a counter) whose panel the tile opens, in place of steps.
    pub applet: Option<crate::applets::Spec>,
}

pub fn path() -> PathBuf {
    crate::theme::path().with_file_name("shortcuts.json")
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().into_iter().flatten().filter_map(|s| s.as_str()).map(str::trim).filter(|s| !s.is_empty()).map(String::from).collect()
}

pub fn parse(text: &str) -> Vec<Shortcut> {
    let Ok(Value::Array(list)) = serde_json::from_str::<Value>(text) else { return vec![] };
    let mut seen = std::collections::HashSet::new();
    list.iter()
        .filter_map(|v| {
            let id = v["id"].as_str()?.trim().to_string();
            if id.is_empty() || !seen.insert(id.clone()) {
                return None;
            }
            Some(Shortcut {
                name: v["name"].as_str().filter(|n| !n.trim().is_empty()).unwrap_or(&id).trim().to_string(),
                icon: v["icon"].as_str().filter(|i| !i.is_empty()).unwrap_or("zap").to_string(),
                toggle: v["toggle"].as_bool().unwrap_or(false),
                steps: strings(&v["steps"]),
                off: strings(&v["off"]),
                state: v["state"].as_str().unwrap_or("").trim().to_string(),
                applet: crate::applets::Spec::from_json(&v["applet"]),
                id,
            })
        })
        .collect()
}

/// The shortcuts, kept up to date with the file, and what each toggle's
/// state is as last found.
pub struct Shortcuts {
    pub list: Vec<Shortcut>,
    stamp: Option<SystemTime>,
    on: Arc<Mutex<HashMap<String, bool>>>,
    polled: Instant,
}

impl Shortcuts {
    pub fn load() -> Self {
        let p = path();
        Shortcuts {
            list: std::fs::read_to_string(&p).map(|t| parse(&t)).unwrap_or_default(),
            stamp: std::fs::metadata(&p).and_then(|m| m.modified()).ok(),
            on: Arc::new(Mutex::new(HashMap::new())),
            polled: Instant::now() - Duration::from_secs(60),
        }
    }

    /// Read again if the file changed: whether it did.
    pub fn reload(&mut self) -> bool {
        let stamp = std::fs::metadata(path()).and_then(|m| m.modified()).ok();
        if stamp == self.stamp {
            return false;
        }
        let on = self.on.clone();
        *self = Shortcuts::load();
        self.on = on;
        true
    }

    pub fn get(&self, id: &str) -> Option<&Shortcut> {
        self.list.iter().find(|s| s.id == id)
    }

    pub fn is_on(&self, s: &Shortcut) -> bool {
        if let Some(spec) = s.state.strip_prefix("theme:") {
            let raw = crate::theme::raw();
            return match spec.split_once('=') {
                Some((key, want)) => match &raw[key.trim()] {
                    serde_json::Value::String(v) => v == want.trim(),
                    serde_json::Value::Bool(b) => b.to_string() == want.trim(),
                    other => other.to_string() == want.trim(),
                },
                None => raw[spec.trim()].as_bool().unwrap_or(false),
            };
        }
        self.on.lock().ok().and_then(|m| m.get(&s.id).copied()).unwrap_or(false)
    }

    /// Ask each toggle that has a state command where it stands, off the
    /// shell's thread. Not more than every few seconds; `force` for just
    /// after one was pressed.
    pub fn poll(&mut self, force: bool) {
        if !force && self.polled.elapsed() < Duration::from_secs(5) {
            return;
        }
        self.polled = Instant::now();
        for s in self.list.iter().filter(|s| s.toggle && !s.state.is_empty() && !s.state.starts_with("theme:")) {
            let (id, cmd, on) = (s.id.clone(), s.state.clone(), self.on.clone());
            std::thread::spawn(move || {
                let ok = std::process::Command::new("sh")
                    .args(["-c", &cmd])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .is_ok_and(|s| s.success());
                if let Ok(mut m) = on.lock() {
                    m.insert(id, ok);
                }
            });
        }
    }

    /// Press a shortcut's tile.
    pub fn press(&mut self, id: &str) {
        let Some(s) = self.get(id).cloned() else { return };
        if !s.toggle {
            run(s.steps);
            return;
        }
        let was = self.is_on(&s);
        if let Ok(mut m) = self.on.lock() {
            m.insert(s.id.clone(), !was);
        }
        run(if was { s.off } else { s.steps });
        // Let the steps run, then ask where it ended up.
        self.polled = Instant::now() - Duration::from_secs(60);
    }
}

/// A tool button's steps, run here and now (call it from a thread): the
/// values the panel holds reach `run` and `start` steps as environment
/// variables, never as text in the command; `notify` and `open` have `{id}`
/// filled in. Returns what the last `run` printed. A step that takes more
/// than 30 seconds is stopped.
pub fn run_tool(steps: &[String], env: &HashMap<String, String>) -> Option<String> {
    let mut last = None;
    for step in steps {
        let step = step.trim();
        let (verb, rest) = step.split_once(char::is_whitespace).map_or((step, ""), |(v, r)| (v, r.trim()));
        match verb {
            "run" if !rest.is_empty() => {
                let child = std::process::Command::new("sh")
                    .args(["-c", rest])
                    .envs(env)
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::piped())
                    .stderr(std::process::Stdio::null())
                    .spawn();
                let Ok(mut child) = child else { continue };
                let mut stdout = child.stdout.take();
                let reader = std::thread::spawn(move || {
                    let mut buf = Vec::new();
                    if let Some(o) = stdout.as_mut() {
                        let _ = std::io::Read::take(o, 16384).read_to_end(&mut buf);
                    }
                    buf
                });
                let start = Instant::now();
                loop {
                    match child.try_wait() {
                        Ok(Some(_)) | Err(_) => break,
                        Ok(None) if start.elapsed() > Duration::from_secs(30) => {
                            let _ = child.kill();
                            let _ = child.wait();
                            break;
                        }
                        Ok(None) => std::thread::sleep(Duration::from_millis(50)),
                    }
                }
                last = Some(String::from_utf8_lossy(&reader.join().unwrap_or_default()).to_string());
            }
            "start" if !rest.is_empty() => {
                let _ = quiet(std::process::Command::new("setsid").args(["-f", "sh", "-c", rest]).envs(env)).status();
            }
            "notify" | "open" => step_once(&format!("{verb} {}", crate::applets::fill(rest, env))),
            _ => step_once(step),
        }
    }
    last
}

/// The steps, one after another, on a thread of their own.
pub fn run(steps: Vec<String>) {
    if steps.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        for step in &steps {
            step_once(step);
        }
    });
}

fn quiet(c: &mut std::process::Command) -> &mut std::process::Command {
    c.stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null())
}

fn step_once(step: &str) {
    let step = step.trim();
    let (verb, rest) = step.split_once(char::is_whitespace).map_or((step, ""), |(v, r)| (v, r.trim()));
    match verb {
        "run" if !rest.is_empty() => {
            let _ = quiet(std::process::Command::new("sh").args(["-c", rest])).status();
        }
        "start" if !rest.is_empty() => {
            let _ = quiet(std::process::Command::new("setsid").args(["-f", "sh", "-c", rest])).status();
        }
        "open" if !rest.is_empty() => {
            // No shell here, so a leading ~ is turned into the home folder.
            let target = match rest.strip_prefix("~/") {
                Some(r) => format!("{}/{r}", std::env::var("HOME").unwrap_or_default()),
                None if rest == "~" => std::env::var("HOME").unwrap_or_default(),
                None => rest.to_string(),
            };
            let _ = quiet(std::process::Command::new("setsid").args(["-f", "xdg-open", &target])).status();
        }
        "notify" if !rest.is_empty() => {
            let (title, text) = rest.split_once('|').map_or((rest, ""), |(t, x)| (t.trim(), x.trim()));
            let mut c = std::process::Command::new("notify-send");
            c.arg("-a").arg("Shortcuts").arg(title);
            if !text.is_empty() {
                c.arg(text);
            }
            let _ = quiet(&mut c).status();
        }
        "set" => {
            if let Some((key, value)) = rest.split_once(char::is_whitespace) {
                let value = value.trim();
                crate::theme::set(key, serde_json::from_str(value).unwrap_or_else(|_| json!(value)));
            }
        }
        "flip" if !rest.is_empty() => {
            let now = crate::theme::raw()[rest].as_bool().unwrap_or(false);
            crate::theme::set(rest, json!(!now));
        }
        "hypr" if !rest.is_empty() => crate::hypr::eval_lua(rest),
        "wait" => {
            if let Ok(s) = rest.parse::<f64>() {
                std::thread::sleep(Duration::from_secs_f64(s.clamp(0.0, 3600.0)));
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_shortcuts_and_skips_broken_ones() {
        let l = parse(
            r#"[{"id":"a","name":"Focus","icon":"moon","toggle":true,"steps":["set dnd true"," "],"off":["set dnd false"],"state":"theme:dnd"},
                {"id":"a","name":"Twice"},{"name":"No id"},{"id":"b"}]"#,
        );
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].steps, ["set dnd true"]);
        assert!(l[0].toggle && l[0].state == "theme:dnd");
        assert_eq!((l[1].name.as_str(), l[1].icon.as_str()), ("b", "zap"));
        assert!(parse("not json").is_empty());
    }
}

#[cfg(test)]
mod run_tool_tests {
    use super::*;

    #[test]
    fn values_reach_a_command_as_variables_and_its_output_comes_back() {
        let env: HashMap<String, String> = [("celsius".to_string(), "37; echo pwned".to_string())].into_iter().collect();
        // Typed text with shell characters is data, not code.
        let out = run_tool(&["run printf '%s' \"$celsius\"".into()], &env).unwrap();
        assert_eq!(out, "37; echo pwned");
        // The last run's output is what comes back.
        let out = run_tool(&["run echo one".into(), "run echo two".into()], &HashMap::new()).unwrap();
        assert_eq!(out.trim(), "two");
        assert!(run_tool(&["wait 0".into()], &HashMap::new()).is_none());
    }
}
