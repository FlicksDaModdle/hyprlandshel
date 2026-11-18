//! Settings → Shortcuts: the tiles you make for the control center. They
//! live in `shortcuts.json` beside theme.json, which the shell reads (see
//! rshell/src/shortcuts.rs for what a step can be); each is a name, an icon,
//! and steps, one per line, run in order when its tile is pressed.

use crate::rows::{action, header, info, menu_with, seg_with, slider_with, text, textarea, toggle_with, Spec};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Mutex;

/// What describing a shortcut is up to ("" when idle), for the pane.
static STATUS: Mutex<String> = Mutex::new(String::new());
fn status(s: impl Into<String>) {
    if let Ok(mut m) = STATUS.lock() {
        *m = s.into();
    }
}

/// Ready-made ones to start from: (name, icon, toggle, steps, off steps, state check).
type Example = (&'static str, &'static str, bool, &'static [&'static str], &'static [&'static str], &'static str);
const EXAMPLES: &[Example] = &[
    ("Focus", "moon", true, &["set dnd true"], &["set dnd false"], "theme:dnd"),
    (
        "Quiet",
        "bell-off",
        true,
        &["set dnd true", "run wpctl set-mute @DEFAULT_AUDIO_SINK@ 1"],
        &["set dnd false", "run wpctl set-mute @DEFAULT_AUDIO_SINK@ 0"],
        "theme:dnd",
    ),
    ("Open the browser", "globe", false, &["start hyprshell-browser"], &[], ""),
    ("Reload Hyprland", "refresh", false, &["run hyprctl reload", "notify Hyprland | Config reloaded"], &[], ""),
    ("Lock in 10 seconds", "lock", false, &["notify Locking | in 10 seconds", "wait 10", "run loginctl lock-session"], &[], ""),
    ("Pause everything", "pause", false, &["run playerctl -a pause", "run wpctl set-mute @DEFAULT_AUDIO_SINK@ 1"], &[], ""),
];

/// Ready-made applets: (name, icon, the applet).
fn applet_examples() -> Vec<(&'static str, &'static str, Value)> {
    vec![
        ("Pomodoro (applet)", "timer", json!({ "kind": "cycle", "rounds": 4, "quiet": true, "phases": [
            { "name": "Focus", "minutes": 25, "notify": "Time for a break" }, { "name": "Break", "minutes": 5, "notify": "Back to work" }] })),
        ("Eye break 20-20-20 (applet)", "eye", json!({ "kind": "cycle", "rounds": 0, "quiet": false, "phases": [
            { "name": "Work", "minutes": 20, "notify": "Look at something 20 feet away for 20 seconds" }, { "name": "Look away", "seconds": 20, "notify": "Back to it" }] })),
        ("Water counter (applet)", "cloud-sun", json!({ "kind": "counter", "goal": 8, "unit": "glasses", "step": 1 })),
        ("Stopwatch (applet)", "timer", json!({ "kind": "stopwatch" })),
    ]
}

/// The verbs a step can start with (rshell/src/shortcuts.rs).
const STEP_VERBS: &[&str] = &["run", "start", "open", "notify", "set", "flip", "hypr", "wait"];

/// Icons a shortcut can have: glyphs the shell draws.
const ICONS: &[&str] = &[
    "zap", "moon", "sun", "bell", "bell-off", "camera", "wifi", "bluetooth", "plane", "gamepad", "lock", "volume", "mic", "headphones", "music",
    "monitor", "keyboard", "folder", "globe", "code", "terminal", "power", "battery", "star", "home", "film", "mail", "calendar", "cloud-sun",
    "clipboard", "timer", "eye", "pause", "play", "refresh", "key", "shield", "sliders", "cpu", "drive", "vpn", "image", "settings",
];

/// What a step starts with, for the hint on an empty one.
const VERBS: &str = "run · start · open · notify · set · flip · hypr · wait";

fn path() -> PathBuf {
    hyprshell_kit::theme::theme_path().with_file_name("shortcuts.json")
}

fn read() -> Vec<Value> {
    std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()).and_then(|v| v.as_array().cloned()).unwrap_or_default()
}

/// Change the list and write it, beside the file and moved into place so
/// the shell never reads half of it.
fn edit(f: impl FnOnce(&mut Vec<Value>)) {
    let mut list = read();
    f(&mut list);
    let p = path();
    if let Some(dir) = p.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string_pretty(&list) {
        let tmp = p.with_extension("json.tmp");
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }
}

fn lines(v: &Value) -> Vec<String> {
    v.as_array().into_iter().flatten().filter_map(|s| s.as_str()).map(String::from).collect()
}

/// A step list changed: step `at` becomes `text` (gone when empty), or one
/// more is added when `at` is past the end.
fn set_step(id: &str, key: &'static str, at: usize, text: String) {
    let id = id.to_string();
    edit(move |l| {
        let Some(s) = l.iter_mut().find(|s| s["id"] == id.as_str()) else { return };
        let mut steps = lines(&s[key]);
        let text = text.trim().to_string();
        if at < steps.len() {
            if text.is_empty() {
                steps.remove(at);
            } else {
                steps[at] = text;
            }
        } else if !text.is_empty() {
            steps.push(text);
        }
        s[key] = json!(steps);
    });
}

fn set_field(id: &str, key: &'static str, v: Value) {
    let id = id.to_string();
    edit(move |l| {
        if let Some(s) = l.iter_mut().find(|s| s["id"] == id.as_str()) {
            s[key] = v;
        }
    });
}

fn new_id(l: &[Value]) -> String {
    let n = (1..).find(|n| !l.iter().any(|s| s["id"] == format!("shortcut-{n}").as_str())).unwrap_or(1);
    format!("shortcut-{n}")
}

/// What a step may `set` or `flip`: a setting, and its words ("" for a yes/no one).
const SETTINGS: &[(&str, &[&str])] = &[
    ("dnd", &[]),
    ("gameMode", &[]),
    ("nightMode", &["off", "on", "sun", "times"]),
    ("theme", &["light", "dark", "auto"]),
];

/// Programs worth telling the model about (and about their absence).
const TOOLS: &[&str] = &[
    "wpctl", "pactl", "playerctl", "brightnessctl", "nmcli", "powerprofilesctl", "notify-send", "hyprctl", "loginctl", "systemctl", "xdg-open", "grim", "slurp",
    "wl-copy", "wl-paste", "bluetoothctl", "rfkill", "wtype", "jq",
];

/// Shell words that need no program of their own.
const BUILTINS: &[&str] = &[
    "cd", "echo", "true", "false", "test", "[", "]", "[[", "]]", "exit", "sleep", "export", "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
    "printf", "read", "set", "unset", "exec", "command", "!", "{", "}", "case", "esac", "local", "return", "wait", "eval", ":", "source", ".", "kill", "type",
];

fn have(cmd: &str) -> bool {
    let cmd = cmd.trim();
    if cmd.is_empty() || cmd.starts_with('$') || BUILTINS.contains(&cmd) {
        return true;
    }
    if let Some(rest) = cmd.strip_prefix("~/") {
        return hyprshell_kit::home().join(rest).exists();
    }
    if cmd.contains('/') {
        return std::path::Path::new(cmd).exists();
    }
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(cmd).is_file()))
}

/// A shell command with its quoted text and arithmetic taken out, so what is
/// left can be split into the pieces that start programs: quotes become `x`,
/// `$(( ))` becomes `x`, and `$( )` and backticks become list separators (what
/// is in them is looked at as commands).
fn flatten(script: &str) -> String {
    let c: Vec<char> = script.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    let at = |i: usize, s: &str| c[i..].iter().take(s.chars().count()).collect::<String>() == s;
    // The index just past the `)` that closes a `(` already opened, looking at nested ones.
    let close = |mut j: usize, double: bool| -> usize {
        let mut depth = 1;
        while j < c.len() && depth > 0 {
            match c[j] {
                '(' => depth += 1,
                ')' => depth -= 1,
                '\\' => j += 1,
                '\'' if !double => {
                    j += 1;
                    while j < c.len() && c[j] != '\'' {
                        j += 1;
                    }
                }
                _ => {}
            }
            j += 1;
        }
        j
    };
    while i < c.len() {
        match c[i] {
            '\\' => {
                out.push('x');
                i += 2;
            }
            '\'' => {
                out.push('x');
                i += 1;
                while i < c.len() && c[i] != '\'' {
                    i += 1;
                }
                i += 1;
            }
            '"' => {
                out.push('x');
                i += 1;
                while i < c.len() && c[i] != '"' {
                    if c[i] == '\\' {
                        i += 2;
                    } else if at(i, "$((") {
                        i = close(i + 2, true);
                    } else if at(i, "$(") {
                        // A command inside the string: looked at as one.
                        let end = close(i + 2, true);
                        let inner: String = c[i + 2..end.saturating_sub(1).max(i + 2)].iter().collect();
                        out.push_str(&format!(";{};", flatten(&inner)));
                        i = end;
                    } else {
                        i += 1;
                    }
                }
                i += 1;
            }
            '$' if at(i, "$((") => {
                out.push('x');
                i = close(i + 2, false);
            }
            '$' if at(i, "$(") => {
                let end = close(i + 2, false);
                let inner: String = c[i + 2..end.saturating_sub(1).max(i + 2)].iter().collect();
                out.push_str(&format!(";{};", flatten(&inner)));
                i = end;
            }
            '`' => {
                out.push(';');
                i += 1;
            }
            ch => {
                out.push(ch);
                i += 1;
            }
        }
    }
    out
}

/// The programs a shell command line starts, for checking they exist: each
/// piece of a pipeline or list, what is inside `$(…)`, and the script given
/// to `sh -c`.
fn programs_in(script: &str) -> Vec<String> {
    // sh -c '…' (or "…"): the script it is given is looked into as well, and
    // the rest goes on without it.
    let mut out = Vec::new();
    let mut rest = script.to_string();
    for shell in ["sh", "bash", "zsh"] {
        let key = format!("{shell} -c ");
        while let Some(at) = rest.find(&key) {
            let after = &rest[at + key.len()..];
            let Some(q) = after.chars().next().filter(|q| *q == '\'' || *q == '"') else { break };
            let inner_end = after[1..].find(q).map(|e| e + 1).unwrap_or(after.len());
            out.extend(programs_in(&after[1..inner_end]));
            let cut = at + key.len() + (inner_end + 1).min(after.len());
            rest = format!("{}{shell} x{}", &rest[..at], &rest[cut..]);
        }
    }
    for seg in flatten(&rest).split(['|', '&', ';', '\n', '(', ')', '{', '}']) {
        let mut words = seg.split_whitespace().peekable();
        // Leading VAR=value words are settings, not the program.
        while words.peek().is_some_and(|w| w.contains('=') && !w.starts_with('-') && !w.starts_with('/')) {
            words.next();
        }
        let Some(first) = words.next() else { continue };
        // What is left of a redirection or a pattern isn't a program: it has to
        // begin like a name or a path.
        if !first.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || matches!(c, '/' | '.' | '~' | '_')) {
            continue;
        }
        // The shell's own words, and the shell itself, are always there.
        if BUILTINS.contains(&first) || matches!(first, "sh" | "bash" | "zsh") {
            continue;
        }
        out.push(first.to_string());
    }
    out
}

/// A command that is no business of a shortcut made from a sentence.
fn dangerous(cmd: &str) -> Option<&'static str> {
    let c = format!(" {} ", cmd.to_lowercase());
    [
        (" sudo ", "needs a password it can't ask for"),
        (" pkexec ", "needs a password it can't ask for"),
        (" rm -rf / ", "deletes everything"),
        (" rm -rf /* ", "deletes everything"),
        (" rm -rf ~ ", "deletes your whole home folder"),
        (" rm -rf ~/ ", "deletes your whole home folder"),
        (" rm -rf ~/* ", "deletes your whole home folder"),
        (" rm -rf $home ", "deletes your whole home folder"),
        (" rm -rf --no-preserve-root", "deletes everything"),
        (" mkfs", "formats a disk"),
        (" dd if=", "writes raw to a disk"),
        ("> /dev/sd", "writes raw to a disk"),
        ("> /dev/nvme", "writes raw to a disk"),
        (":(){", "a fork bomb"),
    ]
    .iter()
    .find(|(bad, _)| c.contains(bad))
    .map(|(_, why)| *why)
}

/// A command that is allowed (it may be exactly what was asked) but that does
/// something big with one press: said plainly, so it is seen before it is used.
fn drastic(cmd: &str) -> Option<&'static str> {
    let c = format!(" {} ", cmd.to_lowercase());
    [
        (" rm ", "deletes files"),
        (" find ", "may delete files if it has -delete or -exec"),
        (" shred ", "destroys files"),
        (" trash-empty", "empties the trash"),
        (" reboot", "restarts the machine"),
        (" poweroff", "powers the machine off"),
        (" shutdown", "powers the machine off"),
        (" halt ", "powers the machine off"),
        (" kill ", "stops programs"),
        (" killall ", "stops programs"),
        (" pkill ", "stops programs"),
    ]
    .iter()
    .find(|(w, _)| c.contains(w) && (*w != " find " || c.contains(" -delete") || c.contains(" -exec")))
    .or_else(|| (c.contains("systemctl") && (c.contains(" reboot") || c.contains(" poweroff") || c.contains(" halt"))).then_some(&(" ", "restarts or powers off the machine")))
    .map(|(_, why)| *why)
}

/// The steps that are fit to keep, each checked: a known verb, a setting that
/// exists with a value it takes, a program that is installed. What is dropped
/// or doubtful goes into `notes`.
fn check_steps(steps: Vec<String>, notes: &mut Vec<String>) -> Vec<String> {
    let mut keep = Vec::new();
    for step in steps {
        let step = step.trim().to_string();
        let (verb, rest) = step.split_once(char::is_whitespace).map_or((step.as_str(), ""), |(v, r)| (v, r.trim()));
        if !STEP_VERBS.contains(&verb) {
            notes.push(format!("Left out “{step}”: it doesn't start with a step word."));
            continue;
        }
        match verb {
            "set" | "flip" => {
                let (key, value) = rest.split_once(char::is_whitespace).map_or((rest, ""), |(k, v)| (k, v.trim()));
                let Some((_, words)) = SETTINGS.iter().find(|(k, _)| *k == key) else {
                    notes.push(format!("Left out “{step}”: “{key}” isn't a setting a shortcut can change."));
                    continue;
                };
                let value = value.trim_matches('"');
                if verb == "flip" && !words.is_empty() {
                    notes.push(format!("Left out “{step}”: {key} isn't a yes/no setting."));
                    continue;
                }
                if verb == "set" {
                    let ok = if words.is_empty() { matches!(value, "true" | "false") } else { words.contains(&value) };
                    if !ok {
                        notes.push(format!("Left out “{step}”: {key} takes {}.", if words.is_empty() { "true or false".to_string() } else { words.join(", ") }));
                        continue;
                    }
                }
            }
            "run" | "start" => {
                if let Some(why) = dangerous(rest) {
                    notes.push(format!("Left out “{step}”: it {why}."));
                    continue;
                }
                let missing: Vec<String> = programs_in(rest).into_iter().filter(|p| !have(p)).collect();
                if !missing.is_empty() {
                    notes.push(format!("“{step}” needs {}, which isn't installed.", missing.join(" and ")));
                }
                if verb == "run" && programs_in(rest).iter().chain(rest.split_whitespace().map(|w| w.to_string()).collect::<Vec<_>>().iter()).any(|p| p == "sleep") {
                    notes.push(format!("“{step}” sleeps, but `run` is stopped after 30 seconds: a long wait has to be a `start` step."));
                }
                if let Some(what) = drastic(rest) {
                    notes.push(format!("⚠ “{step}” {what}, with one press."));
                }
                if rest.contains("hyprctl dispatch") && !rest.contains("hl.") {
                    notes.push(format!("“{step}” uses an old Hyprland command, which this Hyprland may not take; a `hypr` step with Lua is the way."));
                }
            }
            "hypr" if !rest.contains("hl.") => {
                notes.push(format!("Left out “{step}”: Hyprland here takes Lua (hl.dsp.…)."));
                continue;
            }
            "wait" => {
                if rest.parse::<f64>().is_err() {
                    notes.push(format!("Left out “{step}”: wait takes a number of seconds."));
                    continue;
                }
            }
            _ => {}
        }
        keep.push(step);
    }
    keep
}

/// A widget's id is also the environment variable its value reaches a `run`
/// step in (rshell/src/applets.rs): lowercase, and not one a program reads.
fn widget_id_ok(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 32
        && s.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        && !["http_proxy", "https_proxy", "ftp_proxy", "all_proxy", "no_proxy", "ignoreeof"].contains(&s)
}

/// The `$names` a shell command uses (`$x` and `${x}`).
fn variables_in(cmd: &str) -> Vec<String> {
    let b: Vec<char> = cmd.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == '$' && i + 1 < b.len() {
            let mut j = i + 1;
            let braced = b[j] == '{';
            if braced {
                j += 1;
            }
            let start = j;
            while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == '_') {
                j += 1;
            }
            if j > start && !b[start].is_ascii_digit() {
                out.push(b[start..j].iter().collect());
            }
            i = j;
        } else {
            i += 1;
        }
    }
    out
}

/// A value as the text it is shown as: a string, or a number or yes/no written out.
fn text_of(v: &Value) -> String {
    match v {
        Value::String(s) => s.trim().to_string(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// A tool's layout from a model's answer: known widget types, ids that are
/// safe and unique, buttons whose steps hold up and whose `$names` are
/// widgets that exist.
fn normalize_tool(a: &Value, notes: &mut Vec<String>) -> Option<Value> {
    let mut ui: Vec<Value> = Vec::new();
    let mut ids: Vec<String> = Vec::new();
    let mut outputs: Vec<String> = Vec::new();
    let num = |w: &Value, k: &str, d: f64| w[k].as_f64().unwrap_or(d);
    for w in a["ui"].as_array()?.iter().take(16) {
        let kind = w["type"].as_str().unwrap_or("");
        let id = w["id"].as_str().unwrap_or("").to_string();
        let needs_id = matches!(kind, "input" | "choice" | "slider" | "toggle" | "output");
        if needs_id && (!widget_id_ok(&id) || ids.contains(&id)) {
            notes.push(format!("Left out a {kind}: “{id}” isn't a usable name (lowercase letters, digits and _, and not used twice)."));
            continue;
        }
        let label = w["label"].as_str().unwrap_or("").trim().chars().take(60).collect::<String>();
        let item = match kind {
            "text" => json!({ "type": "text", "text": w["text"].as_str().unwrap_or("").chars().take(400).collect::<String>() }),
            "input" => json!({ "type": "input", "id": id, "label": label, "placeholder": w["placeholder"].as_str().unwrap_or("").chars().take(60).collect::<String>(), "default": text_of(&w["default"]) }),
            "choice" => {
                let options: Vec<String> = w["options"].as_array().into_iter().flatten().map(text_of).filter(|o| !o.is_empty()).take(12).collect();
                if options.len() < 2 {
                    notes.push(format!("Left out the choice “{id}”: it needs at least two options."));
                    continue;
                }
                let default = Some(text_of(&w["default"])).filter(|d| options.iter().any(|o| o == d)).unwrap_or_else(|| options[0].clone());
                json!({ "type": "choice", "id": id, "label": label, "options": options, "default": default })
            }
            "slider" => {
                let (min, max) = (num(w, "min", 0.0), num(w, "max", 100.0));
                if !(max > min) {
                    notes.push(format!("Left out the slider “{id}”: its top has to be above its bottom."));
                    continue;
                }
                json!({ "type": "slider", "id": id, "label": label, "min": min, "max": max, "step": num(w, "step", 1.0).max(0.000_001), "default": num(w, "default", min).clamp(min, max), "unit": w["unit"].as_str().unwrap_or("").chars().take(8).collect::<String>() })
            }
            "toggle" => json!({ "type": "toggle", "id": id, "label": label, "default": w["default"].as_bool().unwrap_or(false) }),
            "output" => {
                outputs.push(id.clone());
                json!({ "type": "output", "id": id, "label": label })
            }
            "button" => {
                let steps = check_steps(lines(&w["steps"]), notes);
                if steps.is_empty() {
                    notes.push(format!("Left out the button “{label}”: it has nothing to do."));
                    continue;
                }
                let mut b = json!({ "type": "button", "label": if label.is_empty() { "Go".to_string() } else { label }, "steps": steps, "primary": w["primary"].as_bool().unwrap_or(false) });
                let capture: Vec<String> = match &w["capture"] {
                    Value::String(c) if !c.is_empty() => vec![c.clone()],
                    Value::Array(a) => a.iter().filter_map(|x| x.as_str()).map(String::from).filter(|x| !x.is_empty()).take(8).collect(),
                    _ => Vec::new(),
                };
                if !capture.is_empty() {
                    b["capture"] = json!(capture);
                }
                b
            }
            other => {
                notes.push(format!("Left out a “{other}” widget: the shell doesn't have that one."));
                continue;
            }
        };
        if needs_id {
            ids.push(id);
        }
        ui.push(item);
    }
    if ui.is_empty() {
        return None;
    }
    // A button's capture has to name an output, and its `$names` real widgets.
    for w in ui.iter_mut().filter(|w| w["type"] == "button") {
        if let Some(list) = w["capture"].as_array().cloned() {
            let (good, bad): (Vec<Value>, Vec<Value>) = list.into_iter().partition(|c| c.as_str().is_some_and(|c| outputs.iter().any(|o| o == c)));
            for c in &bad {
                notes.push(format!("A button put its result in “{}”, which isn't a result display; the result won't show.", c.as_str().unwrap_or("")));
            }
            if let Some(o) = w.as_object_mut() {
                if good.is_empty() {
                    o.remove("capture");
                } else {
                    o.insert("capture".into(), Value::Array(good));
                }
            }
        }
        for step in lines(&w["steps"]) {
            for v in variables_in(&step).into_iter().filter(|v| v.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')) {
                if !ids.contains(&v) {
                    notes.push(format!("“{step}” uses ${v}, which isn't one of the tool's inputs."));
                }
            }
        }
    }
    if !ui.iter().any(|w| w["type"] == "button") {
        notes.push("The tool has no button, so nothing in it can do anything.".into());
    }
    Some(json!({ "kind": "tool", "ui": ui }))
}

/// An applet from a model's answer, kept to what the shell can run: a known
/// kind, phases of sensible length, steps that hold up.
fn normalize_applet(a: &Value, notes: &mut Vec<String>) -> Option<Value> {
    match a["kind"].as_str()? {
        "cycle" => {
            let mut phases = Vec::new();
            for p in a["phases"].as_array()? {
                let minutes = p["minutes"].as_f64().or_else(|| p["seconds"].as_f64().map(|s| s / 60.0))?;
                if !(0.1..=600.0).contains(&minutes) {
                    notes.push(format!("Left out a phase of {minutes} minutes: phases run from 0.1 to 600."));
                    continue;
                }
                let name = p["name"].as_str().map(str::trim).filter(|n| !n.is_empty()).unwrap_or("Timer");
                let steps = check_steps(lines(&p["steps"]), notes);
                let mut ph = json!({ "name": name, "minutes": minutes, "notify": p["notify"].as_str().unwrap_or("").trim() });
                if !steps.is_empty() {
                    ph["steps"] = json!(steps);
                }
                phases.push(ph);
            }
            if phases.is_empty() {
                return None;
            }
            Some(json!({ "kind": "cycle", "rounds": a["rounds"].as_u64().unwrap_or(0).min(1000), "quiet": a["quiet"].as_bool().unwrap_or(false), "phases": phases }))
        }
        "counter" => Some(json!({
            "kind": "counter",
            "goal": a["goal"].as_i64().unwrap_or(0).clamp(0, 1_000_000),
            "unit": a["unit"].as_str().unwrap_or("").trim(),
            "step": a["step"].as_i64().unwrap_or(1).clamp(1, 1_000_000),
        })),
        "stopwatch" => Some(json!({ "kind": "stopwatch" })),
        "tool" => normalize_tool(a, notes),
        other => {
            notes.push(format!("“{other}” isn't an applet the shell has."));
            None
        }
    }
}

/// A shortcut from a model's answer: the first JSON object in it, checked.
/// Steps that don't hold up are dropped (and said so), and an answer with no
/// steps left is no shortcut.
fn validate(answer: &str, id: String) -> Result<(Value, Vec<String>), String> {
    let (a, b) = (answer.find('{'), answer.rfind('}'));
    let (Some(a), Some(b)) = (a, b) else { return Err("It didn't answer with a shortcut.".into()) };
    let v: Value = serde_json::from_str(&answer[a..=b]).map_err(|_| "Its answer wasn't readable.".to_string())?;
    // It may say it can't be done.
    if let Some(why) = v["error"].as_str().map(str::trim).filter(|e| !e.is_empty()) {
        return Err(format!("It can't be made as a shortcut: {why}"));
    }
    let mut notes = Vec::new();
    // An applet: a panel with a timer, counter or stopwatch, in place of steps.
    if v["applet"].is_object() {
        let Some(applet) = normalize_applet(&v["applet"], &mut notes) else {
            return Err(notes.first().cloned().unwrap_or_else(|| "It couldn't turn that into an applet. Try saying it another way.".into()));
        };
        let icon = v["icon"].as_str().filter(|i| ICONS.contains(i)).unwrap_or("timer");
        let name = v["name"].as_str().map(str::trim).filter(|n| !n.is_empty()).unwrap_or("New applet");
        return Ok((json!({ "id": id, "name": name, "icon": icon, "toggle": false, "steps": [], "applet": applet }), notes));
    }
    let on = check_steps(lines(&v["steps"]), &mut notes);
    let off = check_steps(lines(&v["off"]), &mut notes);
    if on.is_empty() {
        let why = notes.first().cloned().unwrap_or_else(|| "It couldn't turn that into steps. Try saying it another way.".into());
        return Err(why);
    }
    let icon = v["icon"].as_str().filter(|i| ICONS.contains(i)).unwrap_or("zap");
    let mut toggle = v["toggle"].as_bool().unwrap_or(false);
    if toggle && off.is_empty() {
        toggle = false;
        notes.push("It has no turn-off steps, so it's a button, not a toggle.".into());
    }
    let name = v["name"].as_str().map(str::trim).filter(|n| !n.is_empty()).unwrap_or("New shortcut");
    let mut out = json!({ "id": id, "name": name, "icon": icon, "toggle": toggle, "steps": on });
    if toggle {
        out["off"] = json!(off);
        if let Some(st) = v["state"].as_str().map(str::trim).filter(|s| !s.is_empty()) {
            if let Some(spec) = st.strip_prefix("theme:") {
                let (key, want) = spec.split_once('=').map_or((spec, None), |(k, w)| (k, Some(w)));
                let known = SETTINGS.iter().find(|(k, _)| *k == key);
                let fits = match (known, want) {
                    (Some((_, words)), None) => words.is_empty(),
                    (Some((_, words)), Some(w)) => words.contains(&w) || (words.is_empty() && matches!(w, "true" | "false")),
                    _ => false,
                };
                if fits {
                    out["state"] = json!(st);
                } else {
                    notes.push(format!("Left out its on/off check “{st}”: that isn't a setting it can read."));
                }
            } else {
                let missing: Vec<String> = programs_in(st).into_iter().filter(|p| !have(p)).collect();
                if !missing.is_empty() {
                    notes.push(format!("Its on/off check needs {}, which isn't installed.", missing.join(" and ")));
                }
                out["state"] = json!(st);
            }
        }
    }
    Ok((out, notes))
}

/// The model that writes shortcuts: the strongest, since a mistake is the
/// thing that costs (`HYPRSHELL_DESCRIBE_MODEL` to try another).
fn model() -> String {
    std::env::var("HYPRSHELL_DESCRIBE_MODEL").ok().filter(|m| !m.is_empty()).unwrap_or_else(|| "opus".into())
}

/// What the model is told: the language of steps, what exists on this machine,
/// how to be accurate, and worked answers.
fn system_prompt() -> String {
    const PROMPT: &str = r#"You turn a plain-English description into ONE shortcut for a Linux desktop (Arch Linux, Hyprland, PipeWire). You are exact: the result must do what the description says, in every detail. A request makes exactly ONE shortcut, however many things it needs: never split one thing into two shortcuts. Answer with ONLY a JSON object: no prose, no code fence.

ACCURACY (the most important part)
- Do exactly what was asked. Every input, option, default, label, unit, range, step, calculation, wording and behaviour in the description must be in the result, as given. Use the person's own words for labels and titles. Never leave a detail out, never simplify one, and never add widgets, features or text that were not asked for.
- Numbers in the description are used exactly (ranges, steps, defaults, percentages, units, sizes, times).
- If something is ambiguous take the most literal reading. Do not ask questions.
- Begin the object with "checklist": one short line per requirement you find in the description, in order, then build the result so every line is satisfied.
- A tool must look finished: sensible order, short clear labels, a placeholder showing an example, one primary button, and each result the description asks for shown in its own labelled output widget.
- Calculations: one awk (or bc) call with the values passed in as -v name="$id", printing exactly the text to show, formatted as asked (decimals, currency sign, units, rounding).

FORMAT
{"checklist": [..], "name": short title, "icon": one of ICONS, "toggle": true only if it has an on and an off state, "steps": [..], "off": [..steps that turn it off, toggles only], "state": optional on/off check}

A step is one line starting with a verb:
  run <shell command>      runs it and waits (it is run by sh, so pipes and $(..) work). It is STOPPED after 30 seconds: use it only for things that finish quickly
  start <command>          starts a command, an app or a daemon and goes on without waiting (the way to do anything slow: sleep, a long wait, a download). It has the same environment variables; e.g. start sh -c 'sleep $((minutes*60)); notify-send "$label" done'. It cannot fill an output widget
  open <file, address or app>   (a leading ~ is your home folder)
  notify <title> | <text>
  set <setting> <value>    settings: dnd true/false (do not disturb), gameMode true/false, nightMode off|on|sun|times, theme light|dark|auto
  flip <setting>           a true/false setting, the other way
  hypr <Lua line>         for Hyprland. Hyprland here takes LUA, e.g. hl.dsp.window.close(), hl.dsp.focus({ workspace = 2 }), hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }). Never `hyprctl dispatch` with the old words.
  wait <seconds>           up to 3600

OR, for a small timer, counter or stopwatch with its own panel (a Pomodoro, a water counter, an eye-break reminder), answer with an applet instead of steps:
  {"checklist":[..],"name":..,"icon":..,"applet":{"kind":"cycle","rounds":0,"quiet":false,"phases":[{"name":"Focus","minutes":25,"notify":"Break time","steps":[optional steps run as the phase starts]},..]}}  phases count down one after another and go round again (rounds 0 = keep going; quiet true holds back notifications while it runs). EVERY timer's panel already has its own Settings section, where the person changes each phase's minutes, the rounds, and do not disturb. So "a pomodoro with settings", "adjustable durations" and the like are ONE timer applet with the usual phases as the starting values: never a second shortcut or a tool to hold settings
  {"applet":{"kind":"counter","goal":8,"unit":"glasses","step":1}}   a count with a daily goal      {"applet":{"kind":"stopwatch"}}

OR, when the person must type, choose or see something (a converter, a calculator, a lookup, a quick note, several sliders), answer with a TOOL: a panel you lay out yourself:
  {"checklist":[..],"name":..,"icon":..,"applet":{"kind":"tool","ui":[ widgets.. ]}}
  Widgets, top to bottom (at most 16):
    {"type":"text","text":"words"}
    {"type":"input","id":"city","label":"City","placeholder":"e.g. Paris","default":"5"}
    {"type":"choice","id":"unit","label":"Unit","options":["C","F"],"default":"C"}
    {"type":"slider","id":"mins","label":"Length","min":15,"max":180,"step":15,"default":60,"unit":" min"}
    {"type":"toggle","id":"prep","label":"Include prep time","default":false}
    {"type":"button","label":"Calculate","primary":true,"steps":[..],"capture":["total","per_minute"]}
    {"type":"output","id":"total","label":"Total cost"}
  Widget ids: lowercase letters, digits and _, each used once. What the person typed or picked reaches a `run` step as an ENVIRONMENT VARIABLE named by the widget id: write it quoted, e.g. run echo "$city" (never put a value into the command any other way; an unquoted or pasted value is a bug). Sliders arrive as plain numbers, toggles as true or false, choices as the option's text, empty inputs as empty text (handle that: say what to type instead of failing). A button's "capture" names the output widget(s) its last `run` step fills: with one, everything that step printed goes there; with several, each printed LINE goes to the next one, in order, and the LAST one takes all the lines that are left (so print one line for each output but the last, then as many lines as that last one should show). In `notify` and `open` steps {id} is filled in. Defaults are strings or numbers as they should appear.

For a toggle shortcut, "state" says whether it is on: theme:<yes/no setting> (theme:dnd), theme:<setting>=<value> (theme:theme=dark), or a shell command that exits 0 when on.
Use programs that are installed. Installed: {INSTALLED}. NOT installed: {MISSING}. Other standard tools are there; prefer these. Volume: wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.3, wpctl set-mute @DEFAULT_AUDIO_SINK@ 1.
Keep commands safe: never sudo or anything needing a password, never delete files or shut down unless that is exactly what was asked. If a part cannot be done with what is here, leave that part out and say so in the checklist line ("cannot: ..."). If none of it can be done (it is not something a computer can do, or needs hardware that is not here), answer {"error": "a short reason"} instead.

EXAMPLES
"turn on do not disturb and mute the speakers" -> {"checklist":["turn on do not disturb","mute the speakers","a toggle: on and off"],"name":"Quiet","icon":"bell-off","toggle":true,"steps":["set dnd true","run wpctl set-mute @DEFAULT_AUDIO_SINK@ 1"],"off":["set dnd false","run wpctl set-mute @DEFAULT_AUDIO_SINK@ 0"],"state":"theme:dnd"}
"switch between dark and light" -> {"checklist":["switch the theme between dark and light"],"name":"Theme","icon":"sun","toggle":true,"steps":["set theme dark"],"off":["set theme light"],"state":"theme:theme=dark"}
"a pomodoro timer" -> {"checklist":["a repeating timer: focus then break"],"name":"Pomodoro","icon":"timer","applet":{"kind":"cycle","rounds":4,"quiet":true,"phases":[{"name":"Focus","minutes":25,"notify":"Time for a break"},{"name":"Break","minutes":5,"notify":"Back to work"}]}}
"convert celsius to fahrenheit" -> {"checklist":["an input for celsius","a button that converts","show fahrenheit"],"name":"Temperature","icon":"cpu","applet":{"kind":"tool","ui":[{"type":"input","id":"celsius","label":"Celsius","placeholder":"20"},{"type":"button","label":"Convert","primary":true,"steps":["run awk -v c=\"$celsius\" 'BEGIN{ if (c == \"\") print \"Type a temperature\"; else printf \"%.1f F\", c*9/5+32 }'"],"capture":["result"]},{"type":"output","id":"result","label":"Fahrenheit"}]}}
"meeting cost: people (default 5), hourly rate in dollars (default 60), length 15 to 180 minutes in steps of 15, show total and cost per minute" -> {"checklist":["input: people, default 5","input: hourly rate in dollars, default 60","slider: length 15-180 min, step 15","show the total cost","show the cost per minute"],"name":"Meeting cost","icon":"clock","applet":{"kind":"tool","ui":[{"type":"input","id":"people","label":"People","default":5},{"type":"input","id":"rate","label":"Hourly rate ($)","default":60},{"type":"slider","id":"mins","label":"Length","min":15,"max":180,"step":15,"default":60,"unit":" min"},{"type":"button","label":"Calculate","primary":true,"steps":["run awk -v p=\"$people\" -v r=\"$rate\" -v m=\"$mins\" 'BEGIN{ t=p*r*m/60; printf \"$%.2f\\n$%.2f\\n\", t, t/m }'"],"capture":["total","per_minute"]},{"type":"output","id":"total","label":"Total cost"},{"type":"output","id":"per_minute","label":"Cost per minute"}]}}
"open my downloads" -> {"checklist":["open the downloads folder"],"name":"Downloads","icon":"folder","toggle":false,"steps":["open ~/Downloads"]}

ICONS: {ICONS}"#;
    let (yes, no): (Vec<&str>, Vec<&str>) = TOOLS.iter().partition(|t| have(t));
    PROMPT.replace("{INSTALLED}", &yes.join(", ")).replace("{MISSING}", &no.join(", ")).replace("{ICONS}", &ICONS.join(", "))
}

/// One call to `claude` (the CLI, with its tools off: it only writes text).
/// Gives up after three minutes.
fn ask(system: &str, user: &str) -> Result<String, String> {
    let mut child = std::process::Command::new("claude")
        .args(["-p", "--tools", "", "--no-session-persistence", "--model"])
        .arg(model())
        .arg("--system-prompt")
        .arg(system)
        .arg(user)
        .current_dir(std::env::var_os("XDG_RUNTIME_DIR").unwrap_or_else(|| "/tmp".into()))
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|_| "The claude command isn't installed.".to_string())?;
    let mut stdout = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut buf = String::new();
        if let Some(o) = stdout.as_mut() {
            let _ = std::io::Read::read_to_string(o, &mut buf);
        }
        buf
    });
    let start = std::time::Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if start.elapsed() > std::time::Duration::from_secs(180) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("claude took too long to answer. Try again.".into());
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(100)),
            Err(_) => return Err("claude stopped unexpectedly.".into()),
        }
    };
    let answer = reader.join().unwrap_or_default();
    if !status.success() {
        return Err("claude didn't answer (is it signed in? try `claude` once in a terminal).".into());
    }
    Ok(answer)
}

/// The first JSON object in an answer, as text.
fn json_in(answer: &str) -> Option<&str> {
    let (a, b) = (answer.find('{')?, answer.rfind('}')?);
    (b > a).then(|| &answer[a..=b])
}

/// What the model understood the request to ask for.
fn checklist_of(answer: &str) -> Vec<String> {
    json_in(answer).and_then(|j| serde_json::from_str::<Value>(j).ok()).map(|v| lines(&v["checklist"])).unwrap_or_default().into_iter().take(12).collect()
}

/// Make a shortcut from a sentence, as exactly as it can be done:
///  1. written, with a checklist of what the request asks for;
///  2. checked against the request, line by line, and corrected;
///  3. the problems the shell's own checks find (a `$name` that isn't an
///     input, a program that isn't installed, a step that can't be) handed
///     back to be fixed, once.
/// Returns the shortcut, and notes: what was understood (✓), then anything
/// still doubtful.
pub fn generate(text: &str, id: String) -> Result<(Value, Vec<String>), String> {
    let system = system_prompt();
    let progress = |what: &str| {
        status(format!("Working on it: {what}…"));
        crate::refresh_pane_later();
    };
    let unreadable = |e: &str| e.starts_with("Its answer wasn't readable") || e.starts_with("It didn't answer");

    progress("writing it");
    let mut draft = ask(&system, text)?;
    if validate(&draft, id.clone()).as_ref().is_err_and(|e| unreadable(e)) {
        draft = ask(&system, text)?;
    }
    // The model can decline, or the draft be hopeless: that is the answer.
    let first = validate(&draft, id.clone());
    if let Err(e) = &first {
        if !e.starts_with("It couldn't") || json_in(&draft).is_none() {
            return first;
        }
    }

    progress("checking it against what you wrote");
    let review = format!(
        "REVIEW. The request:\n<<<\n{text}\n>>>\n\nA draft answer:\n{}\n\nCheck the draft against the request, line by line. Every input, label, default, option, range, step, unit, behaviour, calculation, wording and output format the request asks for must be present and exactly as asked. Nothing asked for may be missing, and nothing that was not asked for may be added. Check the commands would really work: quoting, every $name is a widget id, numbers through awk, toggles arriving as true or false, an empty input handled. Then answer with ONLY the corrected, complete JSON object in the same format, with \"checklist\" updated to what the request asks for. If the draft is already exactly right, answer with it unchanged.",
        json_in(&draft).unwrap_or(&draft)
    );
    let mut best = ask(&system, &review).ok().filter(|r| validate(r, id.clone()).is_ok()).unwrap_or_else(|| draft.clone());
    let mut result = validate(&best, id.clone());

    // What the shell's own checks found that the model can fix.
    if let Ok((_, notes)) = &result {
        let fixable: Vec<&String> = notes.iter().filter(|n| !n.starts_with('⚠')).collect();
        if !fixable.is_empty() {
            progress("fixing a few things");
            let fix = format!(
                "REPAIR. The request:\n<<<\n{text}\n>>>\n\nYour answer:\n{}\n\nThe shell's checks found these problems:\n{}\n\nFix them, keeping everything else exactly as it is. If a program is not installed, use one that is, or leave that part out. Answer with ONLY the complete corrected JSON object.",
                json_in(&best).unwrap_or(&best),
                fixable.iter().map(|n| format!("- {n}")).collect::<Vec<_>>().join("\n")
            );
            if let Ok(fixed) = ask(&system, &fix) {
                if let Ok((v, n2)) = validate(&fixed, id.clone()) {
                    if n2.iter().filter(|n| !n.starts_with('⚠')).count() <= fixable.len() {
                        best = fixed;
                        result = Ok((v, n2));
                    }
                }
            }
        }
    }

    let (sc, notes) = result?;
    let mut out: Vec<String> = checklist_of(&best).into_iter().map(|c| format!("✓ {c}")).collect();
    out.extend(notes);
    Ok((sc, out))
}

/// Make a shortcut from a sentence, on a thread; the pane is told when it is done.
pub fn describe(text: String) {
    let text = text.trim().to_string();
    if text.is_empty() {
        return;
    }
    if STATUS.lock().map(|s| s.starts_with("Working")).unwrap_or(false) {
        return;
    }
    status("Working on it…");
    std::thread::spawn(move || {
        let result = generate(&text, new_id(&read())).map(|(sc, notes)| {
            let name = sc["name"].as_str().unwrap_or("").to_string();
            let steps = lines(&sc["steps"]);
            // A name already in use, said so: two of one name look like one thing.
            let taken = read().iter().any(|x| x["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(&name)));
            let mut notes = notes;
            if taken {
                notes.push(format!("⚠ There is already a shortcut called “{name}”; this is another one. Remove one if they are the same thing."));
            }
            edit(|l| {
                // Not the id it was given if another was made meanwhile.
                let mut sc = sc.clone();
                sc["id"] = json!(new_id(l));
                l.push(sc);
            });
            let (understood, problems): (Vec<String>, Vec<String>) = notes.into_iter().partition(|n| n.starts_with('✓'));
            let what = if steps.is_empty() { "an applet".to_string() } else { steps.join(" · ") };
            let mut said = format!("Made “{name}”: {what}. Look it over below, then put it on the control center (Edit → Add).");
            if !understood.is_empty() {
                said.push_str("\nWhat it took from your description:");
                for u in understood {
                    said.push_str("\n  ");
                    said.push_str(&u);
                }
            }
            for n in problems {
                said.push_str("\n• ");
                said.push_str(&n);
            }
            said
        });
        status(match result {
            Ok(said) => said,
            Err(e) => e,
        });
        crate::refresh_pane_later();
    });
}

/// `hyprshell-settings --describe "<sentence>"`: what would be made, printed and
/// not kept, for trying a sentence out.
pub fn describe_cli(text: &str) {
    match generate(text, "test".into()) {
        Ok((sc, notes)) => {
            println!("{}", serde_json::to_string_pretty(&sc).unwrap_or_default());
            for n in notes {
                println!("NOTE: {n}");
            }
        }
        Err(e) => println!("ERROR: {e}"),
    }
}

fn add_example(name: &str) {
    if let Some((n, icon, applet)) = applet_examples().into_iter().find(|e| e.0 == name) {
        edit(|l| {
            let id = new_id(l);
            l.push(json!({ "id": id, "name": n.trim_end_matches(" (applet)"), "icon": icon, "toggle": false, "steps": [], "applet": applet }));
        });
        return;
    }
    let Some((n, icon, toggle, steps, off, state)) = EXAMPLES.iter().find(|e| e.0 == name) else { return };
    edit(|l| {
        let mut v = json!({ "id": new_id(l), "name": n, "icon": icon, "toggle": toggle, "steps": steps });
        if *toggle {
            v["off"] = json!(off);
            if !state.is_empty() {
                v["state"] = json!(state);
            }
        }
        l.push(v);
    });
}

// ── applets: a panel the tile opens, in place of steps (rshell/src/applets.rs)

/// A new applet of a kind, with something sensible in it.
fn default_applet(kind: &str) -> Value {
    match kind {
        "counter" => json!({ "kind": "counter", "goal": 8, "unit": "glasses", "step": 1 }),
        "stopwatch" => json!({ "kind": "stopwatch" }),
        "tool" => json!({ "kind": "tool", "ui": [
            { "type": "input", "id": "text", "label": "Text", "placeholder": "Type something" },
            { "type": "button", "label": "Go", "primary": true, "steps": ["run echo \"$text\""], "capture": "result" },
            { "type": "output", "id": "result", "label": "Result" }] }),
        _ => json!({ "kind": "cycle", "rounds": 0, "quiet": false, "phases": [
            { "name": "Focus", "minutes": 25, "notify": "Focus is over" },
            { "name": "Break", "minutes": 5, "notify": "Break is over" } ] }),
    }
}

/// "Focus 25" → ("Focus", 25.0); "Long break 15 min" → ("Long break", 15.0).
fn parse_phase(text: &str) -> Option<(String, f64)> {
    let mut words: Vec<&str> = text.split_whitespace().collect();
    while words.last().is_some_and(|w| matches!(w.to_lowercase().as_str(), "min" | "mins" | "minutes" | "minute" | "m")) {
        words.pop();
    }
    let minutes: f64 = words.pop()?.trim_end_matches(['m', 'M']).parse().ok()?;
    if !(0.1..=600.0).contains(&minutes) {
        return None;
    }
    let name = words.join(" ");
    Some((if name.is_empty() { "Timer".into() } else { name }, minutes))
}

fn phase_text(p: &Value) -> String {
    let m = p["minutes"].as_f64().or_else(|| p["seconds"].as_f64().map(|s| s / 60.0)).unwrap_or(0.0);
    format!("{} {}", p["name"].as_str().unwrap_or("Timer"), if m.fract() == 0.0 { format!("{}", m as i64) } else { format!("{m}") })
}

fn set_applet(id: &str, f: impl FnOnce(&mut Value)) {
    let id = id.to_string();
    edit(move |l| {
        if let Some(sc) = l.iter_mut().find(|s| s["id"] == id.as_str()) {
            if sc["applet"].is_object() {
                f(&mut sc["applet"]);
            }
        }
    });
}

/// The rows for an applet's own settings.
fn applet_rows(id: &str, a: &Value, out: &mut Vec<Spec>) {
    let kind = a["kind"].as_str().unwrap_or("cycle").to_string();
    let i = id.to_string();
    out.push(menu_with(
        "Applet",
        "A timer that goes round (a Pomodoro), a counter with a goal, or a stopwatch",
        vec!["Timer".into(), "Counter".into(), "Stopwatch".into(), "Tool".into()],
        match kind.as_str() {
            "counter" => "Counter",
            "stopwatch" => "Stopwatch",
            "tool" => "Tool",
            _ => "Timer",
        },
        move |_, v| {
            let k = match v.as_str() {
                "Counter" => "counter",
                "Stopwatch" => "stopwatch",
                "Tool" => "tool",
                _ => "cycle",
            };
            set_field(&i, "applet", default_applet(k));
        },
    ));
    match kind.as_str() {
        "cycle" => {
            let phases = a["phases"].as_array().cloned().unwrap_or_default();
            for (n, ph) in phases.iter().enumerate() {
                let i = id.to_string();
                out.push(text(
                    &format!("Phase {}", n + 1),
                    if n == 0 { "A name and its minutes, e.g. Focus 25. Clear it to remove the phase" } else { "" },
                    &phase_text(ph),
                    "Name minutes",
                    "",
                    move |_, v| {
                        set_applet(&i, |a| {
                            let Some(list) = a["phases"].as_array_mut() else { return };
                            if n >= list.len() {
                                return;
                            }
                            if v.trim().is_empty() {
                                if list.len() > 1 {
                                    list.remove(n);
                                }
                            } else if let Some((name, minutes)) = parse_phase(&v) {
                                let notify = if list[n]["notify"].as_str().is_some_and(|x| !x.is_empty()) { format!("{name} is over") } else { String::new() };
                                list[n] = json!({ "name": name, "minutes": minutes, "notify": notify });
                            }
                        });
                    },
                ));
            }
            let i = id.to_string();
            out.push(text("Add a phase", "Then it goes round again from the first", "", "Break 5", "", move |_, v| {
                if let Some((name, minutes)) = parse_phase(&v) {
                    set_applet(&i, |a| {
                        if let Some(list) = a["phases"].as_array_mut() {
                            list.push(json!({ "name": name, "minutes": minutes, "notify": format!("{name} is over") }));
                        }
                    });
                }
            }));
            let i = id.to_string();
            out.push(slider_with("Rounds", "How many times round before it stops; 0 keeps going", 0.0, 12.0, 1.0, "", a["rounds"].as_f64().unwrap_or(0.0), move |_, v| {
                set_applet(&i, |a| a["rounds"] = json!(v.round() as i64));
            }));
            let i = id.to_string();
            out.push(toggle_with("Do not disturb while it runs", "Notifications are held back from when it starts until it ends or is reset", a["quiet"].as_bool().unwrap_or(false), move |_, v| {
                set_applet(&i, |a| a["quiet"] = json!(v));
            }));
            let i = id.to_string();
            let notifying = phases.iter().any(|p| p["notify"].as_str().is_some_and(|x| !x.is_empty()));
            out.push(toggle_with("Say when a phase ends", "A notification as each phase finishes", notifying, move |_, v| {
                set_applet(&i, |a| {
                    if let Some(list) = a["phases"].as_array_mut() {
                        for p in list {
                            let name = p["name"].as_str().unwrap_or("Timer").to_string();
                            p["notify"] = json!(if v { format!("{name} is over") } else { String::new() });
                        }
                    }
                });
            }));
        }
        "counter" => {
            let i = id.to_string();
            out.push(slider_with("Goal", "What the count is aiming for each day; 0 for none", 0.0, 50.0, 1.0, "", a["goal"].as_f64().unwrap_or(0.0), move |_, v| {
                set_applet(&i, |a| a["goal"] = json!(v.round() as i64));
            }));
            let i = id.to_string();
            out.push(text("Unit", "What is being counted, e.g. glasses", a["unit"].as_str().unwrap_or(""), "glasses", "", move |_, v| {
                set_applet(&i, |a| a["unit"] = json!(v.trim()));
            }));
            let i = id.to_string();
            out.push(slider_with("Step", "How much one press adds", 1.0, 20.0, 1.0, "", a["step"].as_f64().unwrap_or(1.0), move |_, v| {
                set_applet(&i, |a| a["step"] = json!(v.round().max(1.0) as i64));
            }));
        }
        "tool" => {
            let ui = a["ui"].as_array().cloned().unwrap_or_default();
            let summary: Vec<String> = ui
                .iter()
                .map(|w| {
                    let t = w["type"].as_str().unwrap_or("?");
                    let name = w["id"].as_str().or_else(|| w["label"].as_str()).unwrap_or("");
                    if name.is_empty() { t.to_string() } else { format!("{t} {name}") }
                })
                .collect();
            out.push(info("Layout", "Top to bottom. To change it, describe it again above, or edit the JSON below", summary.join(" · ")));
            let i = id.to_string();
            out.push(text(
                "Layout (JSON)",
                "The widgets as data: input, choice, slider, toggle, text, button (with steps) and output. An input's value reaches a run step as $its_id",
                &serde_json::to_string(&ui).unwrap_or_default(),
                "[ … ]",
                "Apply",
                move |_, v| {
                    let Ok(list) = serde_json::from_str::<Value>(&v) else { return };
                    let mut notes = Vec::new();
                    if let Some(t) = normalize_tool(&json!({ "kind": "tool", "ui": list }), &mut notes) {
                        set_field(&i, "applet", t);
                    }
                },
            ));
        }
        _ => {}
    }
}

pub fn rows() -> Vec<Spec> {
    let list = read();
    let mut out = vec![
        header("Make a shortcut", ""),
        textarea(
            "Describe it",
            "Say what you want in your own words and it is made for you. Your description is sent to Claude through the claude command. Look over the steps before you use it.",
            "",
            "a toggle that turns on do not disturb and mutes the speakers",
            "Make it",
            |_, v| describe(v),
        ),
    ];
    let said = STATUS.lock().map(|s| s.clone()).unwrap_or_default();
    if !said.is_empty() {
        out.push(info("", &said, ""));
    }
    out.push(menu_with(
        "Start from an example",
        "A ready-made one to change as you like",
        EXAMPLES.iter().map(|e| e.0.to_string()).chain(applet_examples().into_iter().map(|e| e.0.to_string())).collect(),
        "",
        |_, v| add_example(&v),
    ));
    out.push(action("Start empty", "Give it a name, an icon and steps yourself", "Add", |_| {
        edit(|l| {
            let id = new_id(l);
            l.push(json!({ "id": id, "name": "New shortcut", "icon": "zap", "toggle": false, "steps": [] }));
        });
    }));
    for s in &list {
        let id = s["id"].as_str().unwrap_or("").to_string();
        if id.is_empty() {
            continue;
        }
        let applet = s["applet"].is_object();
        let toggle = !applet && s["toggle"].as_bool().unwrap_or(false);
        let name = s["name"].as_str().unwrap_or("").to_string();
        out.push(header(if name.is_empty() { &id } else { &name }, ""));
        let i = id.clone();
        out.push(text("Name", "Shown on its tile", &name, "Shortcut name", "", move |_, v| set_field(&i, "name", json!(v.trim()))));
        let i = id.clone();
        let icon = s["icon"].as_str().unwrap_or("zap").to_string();
        out.push(menu_with("Icon", "", ICONS.iter().map(|s| s.to_string()).collect(), &icon, move |_, v| set_field(&i, "icon", json!(v))));
        let i = id.clone();
        out.push(seg_with(
            "Type",
            "A button runs its steps. A toggle is on or off, and has steps for each. An applet opens a small panel with a timer, counter or stopwatch.",
            &[("Button", "button"), ("Toggle", "toggle"), ("Applet", "applet")],
            if applet { "applet" } else if toggle { "toggle" } else { "button" },
            move |_, v| {
                if v == "applet" {
                    set_field(&i, "applet", default_applet("cycle"));
                } else {
                    // Back to steps: the applet goes, what the steps were stays.
                    let i2 = i.clone();
                    edit(move |l| {
                        if let Some(sc) = l.iter_mut().find(|x| x["id"] == i2.as_str()) {
                            if let Some(o) = sc.as_object_mut() {
                                o.remove("applet");
                            }
                            sc["toggle"] = json!(v == "toggle");
                        }
                    });
                }
            },
        ));
        if applet {
            applet_rows(&id, &s["applet"], &mut out);
            let i = id.clone();
            out.push(action("Remove this shortcut", "", "Remove", move |_| {
                let i = i.clone();
                edit(move |l| l.retain(|s| s["id"] != i.as_str()));
            }));
            continue;
        }
        let steps = lines(&s["steps"]);
        for (n, step) in steps.iter().enumerate() {
            let i = id.clone();
            out.push(text(
                &if toggle { format!("Turn on · step {}", n + 1) } else { format!("Step {}", n + 1) },
                if n == 0 { "Clear a step to remove it" } else { "" },
                step,
                "",
                "",
                move |_, v| set_step(&i, "steps", n, v),
            ));
        }
        let i = id.clone();
        out.push(text(if toggle { "Turn on · add a step" } else { "Add a step" }, VERBS, "", "run notify-send hello", "", move |_, v| set_step(&i, "steps", usize::MAX, v)));
        if toggle {
            let off = lines(&s["off"]);
            for (n, step) in off.iter().enumerate() {
                let i = id.clone();
                out.push(text(&format!("Turn off · step {}", n + 1), "", step, "", "", move |_, v| set_step(&i, "off", n, v)));
            }
            let i = id.clone();
            out.push(text("Turn off · add a step", "", "", "run notify-send bye", "", move |_, v| set_step(&i, "off", usize::MAX, v)));
            let i = id.clone();
            out.push(text(
                "Is it on?",
                "A command that ends 0 when it is on, or theme:<setting> for a yes/no setting. Empty: the tile remembers.",
                s["state"].as_str().unwrap_or(""),
                "theme:dnd",
                "",
                move |_, v| set_field(&i, "state", json!(v.trim())),
            ));
        }
        let i = id.clone();
        out.push(action("Remove this shortcut", "", "Remove", move |_| {
            let i = i.clone();
            edit(move |l| l.retain(|s| s["id"] != i.as_str()));
        }));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn icons_are_all_glyphs_the_shell_draws() {
        // The shell falls back to a dot for a name it doesn't know; keep ours in step.
        let glyphs = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../rshell/src/glyphs.rs")).unwrap_or_default();
        if glyphs.is_empty() {
            return;
        }
        for i in ICONS {
            assert!(glyphs.contains(&format!("\"{i}\" =>")) || glyphs.contains(&format!("\"{i}\"")), "{i}");
        }
    }
}

#[cfg(test)]
mod describe_tests {
    use super::*;

    #[test]
    fn examples_use_known_icons_and_verbs() {
        for (name, icon, _, steps, off, _) in EXAMPLES {
            assert!(ICONS.contains(icon), "{name}: {icon}");
            for s in steps.iter().chain(off.iter()) {
                assert!(STEP_VERBS.contains(&s.split_whitespace().next().unwrap()), "{name}: {s}");
            }
        }
    }

    #[test]
    fn an_answer_is_checked_before_it_is_kept() {
        let ok = validate("Sure!\n```json\n{\"name\":\"Quiet\",\"icon\":\"nope\",\"toggle\":true,\"steps\":[\"set dnd true\",\"rm -rf /\",\"hack the planet\"],\"off\":[\"set dnd false\"],\"state\":\"theme:dnd\"}\n```", "shortcut-1".into()).unwrap().0;
        assert_eq!(ok["icon"], "zap"); // unknown icon falls back
        assert_eq!(ok["steps"], json!(["set dnd true"])); // lines that aren't steps are dropped
        assert_eq!(ok["state"], "theme:dnd");
        assert!(validate("{\"name\":\"x\",\"steps\":[\"nonsense\"]}", "a".into()).is_err());
        assert!(validate("no json here", "a".into()).is_err());
    }
}

#[cfg(test)]
mod check_tests {
    use super::*;

    fn kept(steps: &[&str]) -> (Vec<String>, Vec<String>) {
        let mut notes = vec![];
        let k = check_steps(steps.iter().map(|s| s.to_string()).collect(), &mut notes);
        (k, notes)
    }

    #[test]
    fn settings_must_exist_and_take_the_value() {
        let (k, n) = kept(&["set dnd true", "set dnd maybe", "set theme dark", "set theme \"light\"", "set volume 5", "flip dnd", "flip theme", "wait soon"]);
        assert_eq!(k, ["set dnd true", "set theme dark", "set theme \"light\"", "flip dnd"]);
        assert_eq!(n.len(), 4);
    }

    #[test]
    fn dangerous_and_passworded_commands_are_left_out() {
        let (k, n) = kept(&["run sudo reboot", "run rm -rf /", "run rm -rf ~", "run echo hi", "start pkexec foo", "run rm -rf ~/Documents/old"]);
        // A named folder is the user's to ask for (and is warned about); the whole disk or home is not.
        assert_eq!(k, ["run echo hi", "run rm -rf ~/Documents/old"]);
        assert_eq!(n.len(), 5);
    }

    #[test]
    fn programs_are_found_through_pipes_and_sh_c() {
        assert_eq!(programs_in("grim -g \"$(slurp)\" - | wl-copy"), ["grim", "slurp", "wl-copy"]);
        assert_eq!(programs_in("sh -c 'playerctl pause && notify-send hi'"), ["playerctl", "notify-send"]);
        assert!(programs_in("FOO=1 echo $HOME > /tmp/x").is_empty()); // echo is always there
        assert!(have("sh") && !have("definitely-not-a-program-xyz"));
    }

    #[test]
    fn a_state_check_must_be_one_the_shell_can_read() {
        let ok = |state: &str| validate(&format!("{{\"name\":\"t\",\"toggle\":true,\"steps\":[\"set dnd true\"],\"off\":[\"set dnd false\"],\"state\":\"{state}\"}}"), "a".into()).unwrap().0;
        assert_eq!(ok("theme:dnd")["state"], "theme:dnd");
        assert_eq!(ok("theme:theme=dark")["state"], "theme:theme=dark");
        assert!(ok("theme:dark").get("state").is_none()); // not a setting
        assert!(ok("theme:theme").get("state").is_none()); // a word setting needs =value
        assert_eq!(ok("true")["state"], "true"); // a command
    }

    #[test]
    fn a_toggle_without_turn_off_steps_is_a_button() {
        let (v, notes) = validate("{\"name\":\"t\",\"toggle\":true,\"steps\":[\"set dnd true\"]}", "a".into()).unwrap();
        assert_eq!(v["toggle"], false);
        assert_eq!(notes.len(), 1);
    }
}

#[cfg(test)]
mod drastic_tests {
    use super::*;

    #[test]
    fn big_actions_are_said_plainly_but_kept() {
        let mut notes = vec![];
        let k = check_steps(vec!["run find ~/Downloads -mindepth 1 -delete".into(), "run systemctl reboot".into(), "run find ~/Downloads -name x".into(), "run rm ~/x".into()], &mut notes);
        assert_eq!(k.len(), 4);
        assert_eq!(notes.iter().filter(|n| n.starts_with('⚠')).count(), 3, "{notes:?}");
    }

    #[test]
    fn debris_of_a_command_substitution_is_not_a_program() {
        assert_eq!(programs_in("notify-send B \"$(cat /sys/x | head -n1)%\""), ["notify-send", "cat", "head"]);
    }

    #[test]
    fn the_model_can_say_it_cannot() {
        let e = validate("{\"error\":\"it needs a coffee machine\"}", "a".into()).unwrap_err();
        assert!(e.contains("coffee machine"));
    }
}

#[cfg(test)]
mod applet_tests {
    use super::*;

    #[test]
    fn an_applet_answer_is_kept_without_steps_and_checked() {
        let (v, notes) = validate(
            r#"{"name":"Pomodoro","icon":"nope","applet":{"kind":"cycle","rounds":4,"quiet":true,"phases":[
                {"name":"Focus","minutes":25,"notify":"Break","steps":["set dnd true","run sudo rm -rf /"]},
                {"name":"Silly","minutes":9999},
                {"name":"Break","seconds":300}]}}"#,
            "a".into(),
        )
        .unwrap();
        assert_eq!(v["icon"], "timer");
        assert_eq!(v["applet"]["phases"].as_array().unwrap().len(), 2); // the 9999-minute one is left out
        assert_eq!(v["applet"]["phases"][0]["steps"], json!(["set dnd true"])); // the sudo step too
        assert_eq!(v["applet"]["phases"][1]["minutes"], 5.0);
        assert_eq!(notes.len(), 2);
        assert!(validate(r#"{"applet":{"kind":"teapot"}}"#, "a".into()).is_err());
        let (c, _) = validate(r#"{"name":"W","applet":{"kind":"counter","goal":8,"unit":"glasses"}}"#, "a".into()).unwrap();
        assert_eq!(c["applet"]["step"], 1);
    }

    #[test]
    fn phases_are_read_from_a_name_and_minutes() {
        assert_eq!(parse_phase("Focus 25"), Some(("Focus".into(), 25.0)));
        assert_eq!(parse_phase("Long break 15 min"), Some(("Long break".into(), 15.0)));
        assert_eq!(parse_phase("30"), Some(("Timer".into(), 30.0)));
        assert_eq!(parse_phase("Focus soon"), None);
        assert_eq!(parse_phase("Focus 0"), None);
        assert_eq!(phase_text(&json!({ "name": "Break", "minutes": 7.5 })), "Break 7.5");
    }
}

#[cfg(test)]
mod tool_tests {
    use super::*;

    #[test]
    fn every_example_in_the_prompt_is_valid_and_passes_the_checks() {
        let prompt = system_prompt();
        let mut n = 0;
        for line in prompt.lines().filter(|l| l.starts_with('"') && l.contains("\" -> {")) {
            let json = line.split_once(" -> ").unwrap().1;
            serde_json::from_str::<Value>(json).unwrap_or_else(|e| panic!("example isn't JSON ({e}): {json}"));
            let (_, notes) = validate(json, "x".into()).unwrap_or_else(|e| panic!("example rejected ({e}): {json}"));
            assert!(notes.iter().all(|n| n.contains("isn't installed")), "{json}: {notes:?}");
            n += 1;
        }
        assert!(n >= 6, "found {n} examples");
    }

    #[test]
    fn a_tool_is_checked_widget_by_widget() {
        let (v, notes) = validate(
            r#"{"name":"T","applet":{"kind":"tool","ui":[
                {"type":"input","id":"city","label":"City"},
                {"type":"input","id":"city"},
                {"type":"input","id":"PATH"},
                {"type":"choice","id":"u","options":["only one"]},
                {"type":"slider","id":"s","min":10,"max":5},
                {"type":"teapot"},
                {"type":"button","label":"Go","steps":["run echo \"$city\" \"$other\"","run sudo reboot"],"capture":"nowhere"},
                {"type":"output","id":"result"}]}}"#,
            "a".into(),
        )
        .unwrap();
        let ui = v["applet"]["ui"].as_array().unwrap();
        let kinds: Vec<&str> = ui.iter().map(|w| w["type"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["input", "button", "output"]); // duplicates, bad ids, one-option choice, backwards slider, unknown type: gone
        assert_eq!(ui[1]["steps"], json!(["run echo \"$city\" \"$other\""])); // the sudo step too
        assert!(ui[1].get("capture").is_none()); // "nowhere" isn't an output
        assert!(notes.iter().any(|n| n.contains("$other")), "{notes:?}");
        assert!(notes.iter().any(|n| n.contains("nowhere")));
        assert_eq!(variables_in("echo \"$a ${b_1} $2 $\" x"), ["a", "b_1"]);
    }

    #[test]
    fn a_tool_with_no_usable_widgets_is_no_tool() {
        assert!(validate(r#"{"applet":{"kind":"tool","ui":[{"type":"teapot"}]}}"#, "a".into()).is_err());
    }
}

#[cfg(test)]
mod program_parse_tests {
    use super::*;

    #[test]
    fn quoted_text_and_arithmetic_are_not_commands() {
        assert_eq!(programs_in("awk -v b=\"$bill\" 'BEGIN{printf \"Tip %.2f | Total %.2f\", b}'"), ["awk"]);
        assert_eq!(programs_in("sleep $((minutes*60)); notify-send hi"), ["notify-send"]);
        assert_eq!(programs_in("echo \"today is $(date +%A)\" | tr a-z A-Z"), ["date", "tr"]);
        assert_eq!(programs_in("wpctl set-volume @DEFAULT_AUDIO_SINK@ \"$(awk -v v=\"$vol\" 'BEGIN{print v/100}')\""), ["wpctl", "awk"]);
        assert_eq!(programs_in("sh -c 'case \"$m\" in \"\"|*[!0-9]*) notify-send a;; *) sleep $((m*60)); notify-send b;; esac'"), ["notify-send", "notify-send"]);
    }

    #[test]
    fn real_missing_programs_are_still_found() {
        assert!(programs_in("echo hi | definitely-not-installed-xyz").contains(&"definitely-not-installed-xyz".to_string()));
        assert!(programs_in("sh -c 'definitely-not-installed-xyz --x'").contains(&"definitely-not-installed-xyz".to_string()));
    }
}

#[cfg(test)]
mod slow_step_tests {
    use super::*;

    #[test]
    fn a_long_wait_under_run_is_pointed_out_and_under_start_is_not() {
        let mut notes = vec![];
        check_steps(vec!["run sleep $((m*60)); notify-send hi".into(), "start sh -c 'sleep 600; notify-send hi'".into(), "run echo sleepy".into()], &mut notes);
        assert_eq!(notes.iter().filter(|n| n.contains("30 seconds")).count(), 1, "{notes:?}");
    }
}
