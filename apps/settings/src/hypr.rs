//! What Settings changes in Hyprland itself, as services/Devices.qml,
//! Compositor.qml and Keybinds.qml do it: hl.config / hl.device /
//! hl.monitor through `hyprctl eval`, binds.lua written and Hyprland
//! reloaded. Hyprland forgets all of it on every launch, so `apply_all`
//! (hyprshell-settings --apply, run by the shell at login) puts it back.

use crate::prefs::{hypr_color, shade, Prefs};
use serde_json::{json, Map, Value};

// ── Lua ──────────────────────────────────────────────────────────────────
pub fn lua_string(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\"").replace('\n', "\\n"))
}

pub fn lua_value(v: &Value) -> String {
    match v {
        Value::Bool(b) => b.to_string(),
        Value::Null => "nil".into(),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.to_string()
            } else {
                let f = n.as_f64().unwrap_or(0.0);
                if f.fract() == 0.0 && f.abs() < 1e15 {
                    format!("{}", f as i64)
                } else {
                    format!("{f:.6}")
                }
            }
        }
        Value::Array(a) => format!("{{{}}}", a.iter().map(lua_value).collect::<Vec<_>>().join(",")),
        Value::Object(o) => lua_table(o),
        Value::String(s) => lua_string(s),
    }
}

pub fn lua_table(o: &Map<String, Value>) -> String {
    let bare = |k: &str| k.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_') && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    let parts: Vec<String> = o
        .iter()
        .map(|(k, v)| if bare(k) { format!("{k}={}", lua_value(v)) } else { format!("[{}]={}", lua_string(k), lua_value(v)) })
        .collect();
    format!("{{{}}}", parts.join(","))
}

/// `hyprctl eval`; what it said when it wasn't "ok".
pub fn eval(code: &str) -> Option<String> {
    let out = std::process::Command::new("hyprctl").args(["eval", code]).stderr(std::process::Stdio::null()).output().ok()?;
    let reply = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if reply.eq_ignore_ascii_case("ok") || reply.is_empty() {
        None
    } else {
        eprintln!("hyprshell-settings: hyprctl eval rejected {code:?} -> {reply}");
        Some(reply)
    }
}

pub fn set_config(tree: Value) {
    if let Value::Object(o) = tree {
        eval(&format!("hl.config({})", lua_table(&o)));
    }
}

pub fn json(path: &str) -> Value {
    std::process::Command::new("hyprctl")
        .args(["-j", path])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .and_then(|o| serde_json::from_slice(&o.stdout).ok())
        .unwrap_or(Value::Null)
}

pub fn reload() {
    let _ = std::process::Command::new("hyprctl").arg("reload").stdout(std::process::Stdio::null()).status();
}

// ── input (Devices.inputTree) ────────────────────────────────────────────
fn input_tree(p: &Prefs) -> Value {
    json!({
        "input": {
            "repeat_rate": p.i("repeatRate"),
            "repeat_delay": p.i("repeatDelay"),
            "numlock_by_default": p.b("numlock"),
            "follow_mouse": p.follow_mouse_now(),
            "float_switch_override_focus": if p.s("windowMode") == "windows" { 0 } else { 1 },
            "sensitivity": p.f("sensitivity"),
            "accel_profile": p.s("accelProfile"),
            "left_handed": p.b("leftHanded"),
            "natural_scroll": p.b("mouseNaturalScroll"),
            "scroll_factor": p.f("mouseScrollFactor"),
            "touchpad": {
                "tap_to_click": p.b("tapToClick"),
                "tap_and_drag": p.b("tapAndDrag"),
                "drag_lock": p.b("dragLock"),
                "natural_scroll": p.b("padNaturalScroll"),
                "scroll_factor": p.f("padScrollFactor"),
                "disable_while_typing": p.b("disableWhileTyping"),
                "clickfinger_behavior": p.b("clickfinger"),
                "tap_button_map": p.s("tapButtonMap"),
                "middle_button_emulation": p.b("middleEmulation"),
            }
        },
        "cursor": {
            "hide_on_key_press": p.b("hideCursorOnKey"),
            "inactive_timeout": p.i("cursorTimeout"),
        }
    })
}

/// The pointers Hyprland has, and which of them are touchpads (by name, as
/// Devices.isTouchpad).
pub fn pointers() -> (Vec<String>, Vec<String>) {
    let mice: Vec<String> = json("devices")["mice"].as_array().into_iter().flatten().filter_map(|m| m["name"].as_str().map(str::to_string)).collect();
    let re = |n: &str| {
        let l = n.to_lowercase();
        ["touchpad", "touch-pad", "trackpad", "track-pad", "clickpad", "glidepoint"].iter().any(|k| l.contains(k))
    };
    let pads = mice.iter().filter(|n| re(n)).cloned().collect();
    (mice, pads)
}

pub fn apply_touchpads(p: &Prefs) {
    for name in pointers().1 {
        let spec = json!({ "name": name, "sensitivity": p.pad_sensitivity_now(), "accel_profile": p.pad_accel_now() });
        if let Value::Object(o) = spec {
            eval(&format!("hl.device({})", lua_table(&o)));
        }
    }
}

pub fn apply_input(p: &Prefs) {
    set_config(input_tree(p));
    apply_touchpads(p);
}

// ── frame (Devices.frameTree, motionLua, applyShellBlur) ────────────────
fn frame_tree(p: &Prefs) -> Value {
    let mut col = json!({ "inactive_border": hypr_color(shade(p.div(), p.f("inactiveBorderPct")), "aa") });
    if p.b("borderFollowsAccent") {
        col["active_border"] = json!(hypr_color(shade(p.accent(), p.f("activeBorderPct")), "ee"));
    }
    json!({
        "general": {
            "gaps_in": p.i("gapsIn"),
            "gaps_out": p.i("gapsOut"),
            "border_size": p.i("borderSize"),
            "layout": p.s("hyprLayout"),
            "col": col,
        },
        "decoration": {
            "rounding": (p.f("hyprRounding") * p.rf()).round() as i64,
            "inactive_opacity": (p.f("hyprInactiveOpacity") / 100.0).clamp(0.4, 1.0),
            "blur": { "enabled": p.b("hyprBlur"), "size": p.i("hyprBlurSize"), "passes": p.i("hyprBlurPasses") },
            "shadow": { "enabled": p.b("hyprShadow") },
        },
        "animations": { "enabled": p.b("hyprAnimEnabled") },
    })
}

fn motion_lua(p: &Prefs) -> String {
    let speed = p.f("hyprAnimSpeed").max(25.0) / 100.0;
    let amount = if p.springy() { p.f("motionBounce") / 100.0 } else { 0.0 };
    let settle = (1.0 - 0.22 * amount).max(0.5);
    let spring = |name: &str, response: f64, zeta: f64| {
        let w = 2.0 * std::f64::consts::PI / response * speed;
        let k = (w * w * 100.0).round() / 100.0;
        let c = (2.0 * zeta * w * 100.0).round() / 100.0;
        let body = format!("type = \"spring\", mass = 1, stiffness = {k}");
        format!(
            "if not pcall(hl.curve, \"{name}\", {{ {body}, dampening = {c} }}) then pcall(hl.curve, \"{name}\", {{ {body}, damping = {c} }}) end "
        )
    };
    let leaf = |name: &str, curve: &str, style: &str, tenths: f64| {
        let st = if style.is_empty() { String::new() } else { format!(", style = \"{style}\"") };
        let head = format!("pcall(hl.animation, {{ leaf = \"{name}\", enabled = true, speed = ");
        let fallback = ((tenths / speed * 10.0).round() / 10.0).max(0.5);
        format!("if not {head}{tenths}{st}, spring = \"{curve}\" }}) then {head}{fallback}{st}, bezier = \"hsSmooth\" }}) end ")
    };
    let springy = p.springy();
    [
        "pcall(hl.curve, \"hsSmooth\", { type = \"bezier\", points = { {0.23, 1}, {0.32, 1} } }) ".to_string(),
        spring("hsArrive", 0.42, settle),
        spring("hsLeave", 0.30, 1.0),
        spring("hsFade", 0.30, 1.0),
        spring("hsBorder", 0.40, 1.0),
        leaf("windows", "hsArrive", if springy { "popin 86%" } else { "popin 94%" }, 4.5),
        leaf("windowsOut", "hsLeave", if springy { "popin 90%" } else { "popin 96%" }, 2.6),
        leaf("windowsMove", "hsArrive", "", 4.5),
        leaf("workspaces", "hsArrive", "slide", 4.0),
        leaf("specialWorkspace", "hsArrive", "slidevert", 4.0),
        leaf("fade", "hsFade", "", 2.5),
        leaf("border", "hsBorder", "", 5.0),
        leaf("layers", "hsFade", "fade", 2.5),
    ]
    .concat()
}

/// The shell's surfaces' blur rules (Devices.applyShellBlur). In auto the
/// bar and dock blur live and the menus blur the wallpaper (the Rust
/// shell doesn't follow the windows under them yet).
pub fn apply_shell_blur(p: &Prefs) {
    let mode = p.s("shellBlurMode");
    let mut lua = String::new();
    for n in ["bar", "dock", "panel", "launcher", "overview"] {
        let live = match mode.as_str() {
            "live" => true,
            "wallpaper" => false,
            _ => n == "bar" || n == "dock",
        };
        lua += &format!(
            "hl.layer_rule({{ name = \"blur-quickshell-{n}\", match = {{ namespace = \"^quickshell:{n}$\" }}, blur = true, ignore_alpha = 0.15, xray = {} }}) ",
            !live
        );
    }
    lua += "hl.layer_rule({ name = \"blur-quickshell-polkit\", match = { namespace = \"^quickshell:polkit$\" }, blur = true, ignore_alpha = 0.38 }) ";
    eval(&lua);
    eval("hl.layer_rule({ name = \"launcher-no-anim\", match = { namespace = \"^quickshell:launcher$\" }, no_anim = true })");
}

pub fn apply_frame(p: &Prefs) {
    set_config(frame_tree(p));
    apply_shell_blur(p);
    eval(&motion_lua(p));
}

// ── displays (Devices.displaySpec / applyDisplay) ───────────────────────
pub fn display_map(p: &Prefs) -> Map<String, Value> {
    serde_json::from_str::<Value>(&p.s("displays")).ok().and_then(|v| v.as_object().cloned()).unwrap_or_default()
}

pub fn save_display(p: &mut Prefs, name: &str, patch: Value) {
    let mut map = display_map(p);
    let mut entry = map.get(name).and_then(|v| v.as_object().cloned()).unwrap_or_default();
    if let Value::Object(o) = patch {
        for (k, v) in o {
            if v.is_null() {
                entry.remove(&k);
            } else {
                entry.insert(k, v);
            }
        }
    }
    map.insert(name.to_string(), Value::Object(entry));
    let _ = p.set("displays", json!(serde_json::to_string(&Value::Object(map)).unwrap_or_default()));
}

const MONITOR_FIELDS: &[&str] = &[
    "position", "bitdepth", "cm", "sdrbrightness", "sdrsaturation", "supports_wide_color", "supports_hdr", "max_luminance", "max_avg_luminance",
    "min_luminance", "sdr_eotf", "sdr_min_luminance", "sdr_max_luminance",
];

pub fn apply_display(p: &Prefs, name: &str) {
    let mons = json("monitors");
    let Some(live) = mons.as_array().and_then(|a| a.iter().find(|m| m["name"] == name)).cloned() else { return };
    let want = display_map(p).get(name).cloned().unwrap_or(json!({}));
    let mode = want["mode"].as_str().map(str::to_string).unwrap_or_else(|| {
        format!(
            "{}x{}@{}",
            live["width"].as_i64().unwrap_or(0),
            live["height"].as_i64().unwrap_or(0),
            (live["refreshRate"].as_f64().unwrap_or(60.0) * 1000.0).round() / 1000.0
        )
    });
    let mut spec = Map::new();
    spec.insert("output".into(), json!(name));
    spec.insert("mode".into(), json!(mode));
    spec.insert("scale".into(), want.get("scale").filter(|v| !v.is_null()).cloned().unwrap_or_else(|| live["scale"].clone()));
    for f in MONITOR_FIELDS {
        if let Some(v) = want.get(*f).filter(|v| !v.is_null()) {
            spec.insert((*f).into(), v.clone());
        }
    }
    if !spec.contains_key("position") {
        spec.insert("position".into(), json!(format!("{}x{}", live["x"].as_i64().unwrap_or(0), live["y"].as_i64().unwrap_or(0))));
    }
    eval(&format!("hl.monitor({})", lua_table(&spec)));
}

pub fn apply_displays(p: &Prefs) {
    let map = display_map(p);
    for m in json("monitors").as_array().into_iter().flatten() {
        if let Some(n) = m["name"].as_str() {
            if map.contains_key(n) {
                apply_display(p, n);
            }
        }
    }
}

/// Compositor.validScales: the steps that divide the mode into whole
/// logical pixels.
pub fn valid_scales(w: f64, h: f64) -> Vec<f64> {
    [1.0, 1.25, 1.333333, 1.5, 1.666667, 1.75, 2.0, 2.25, 2.5, 3.0]
        .into_iter()
        .filter(|s| {
            let (a, b) = (w / s, h / s);
            (a - a.round()).abs() < 0.001 && (b - b.round()).abs() < 0.001
        })
        .collect()
}

// ── keybinds (Keybinds.qml) ──────────────────────────────────────────────
pub struct Action {
    pub key: &'static str,
    pub n: &'static str,
    pub def: &'static str,
    ipc: &'static str,
    arg: &'static str,
    exec: &'static str,
    dsp: &'static str,
    release: bool,
}

const fn ipc(key: &'static str, n: &'static str, def: &'static str, ipc: &'static str, arg: &'static str) -> Action {
    Action { key, n, def, ipc, arg, exec: "", dsp: "", release: false }
}

pub const ACTIONS: &[Action] = &[
    Action { key: "launcher", n: "Open launcher", def: "Super_L", ipc: "toggleLauncher", arg: "", exec: "", dsp: "", release: true },
    ipc("overview", "Overview", "SUPER + Tab", "toggleOverview", ""),
    ipc("control", "Control center", "SUPER + C", "toggleControlCenter", ""),
    ipc("notes", "Notification center", "SUPER + N", "toggleNotifications", ""),
    ipc("dnd", "Toggle do not disturb", "SUPER + SHIFT + N", "toggleDnd", ""),
    ipc("settings", "Open settings", "SUPER + comma", "openSettings", "Appearance"),
    ipc("theme", "Toggle theme", "SUPER + SHIFT + T", "toggleTheme", ""),
    ipc("reload", "Reload shell", "SUPER + SHIFT + R", "reloadShell", ""),
    ipc("lock", "Lock screen", "SUPER + L", "lock", ""),
    ipc("showdesktop", "Show desktop", "SUPER + D", "showDesktop", ""),
    ipc("osk", "On-screen keyboard", "", "toggleKeyboard", ""),
    ipc("clipboard", "Clipboard history", "SUPER + SHIFT + V", "toggleClipboard", ""),
    ipc("capture", "Capture toolbar", "Print", "toggleCapture", ""),
    ipc("screenshot", "Snip — freeze the screen and choose", "SUPER + SHIFT + S", "screenshot", "region"),
    ipc("shotscreen", "Screenshot the screen", "SHIFT + Print", "screenshot", "screen"),
    ipc("record", "Start / stop recording", "SUPER + SHIFT + Print", "toggleRecording", ""),
    Action { key: "terminal", n: "Terminal", def: "SUPER + Return", ipc: "", arg: "", exec: "terminal", dsp: "", release: false },
    Action { key: "files", n: "File manager", def: "SUPER + E", ipc: "", arg: "", exec: "files", dsp: "", release: false },
    Action { key: "browser", n: "Browser", def: "SUPER + B", ipc: "", arg: "", exec: "browser", dsp: "", release: false },
    Action { key: "close", n: "Close window", def: "SUPER + Q", ipc: "", arg: "", exec: "", dsp: "hl.dsp.window.close()", release: false },
    Action { key: "float", n: "Toggle floating", def: "SUPER + V", ipc: "", arg: "", exec: "", dsp: "hl.dsp.window.float({ action = \"toggle\" })", release: false },
    Action {
        key: "fullscreen",
        n: "Fullscreen",
        def: "SUPER + F",
        ipc: "",
        arg: "",
        exec: "",
        dsp: "hl.dsp.window.fullscreen({ mode = \"fullscreen\", action = \"toggle\" })",
        release: false,
    },
];

const TAP_KEYS: &[(&str, &str)] = &[("SUPER", "Super_L"), ("ALT", "Alt_L"), ("CTRL", "Control_L"), ("HYPER", "Hyper_L")];

pub fn overrides(p: &Prefs) -> Map<String, Value> {
    serde_json::from_str::<Value>(&p.s("keybinds")).ok().and_then(|v| v.as_object().cloned()).unwrap_or_default()
}
fn mod_key(p: &Prefs) -> String {
    let m = p.s("modKey");
    if m.is_empty() {
        "SUPER".into()
    } else {
        m
    }
}
fn with_mod_key(p: &Prefs, accel: &str) -> String {
    let m = mod_key(p);
    if accel.is_empty() || m == "SUPER" {
        return accel.to_string();
    }
    if accel == "Super_L" {
        return TAP_KEYS.iter().find(|t| t.0 == m).map(|t| t.1.to_string()).unwrap_or(accel.to_string());
    }
    let re = regex_lite_super(accel, &m);
    re
}
/// SUPER as a whole word, replaced.
fn regex_lite_super(accel: &str, with: &str) -> String {
    accel.split(" + ").map(|part| if part == "SUPER" { with } else { part }).collect::<Vec<_>>().join(" + ")
}
pub fn accel_for(p: &Prefs, key: &str) -> String {
    if let Some(v) = overrides(p).get(key).and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        return v.to_string();
    }
    ACTIONS.iter().find(|a| a.key == key).map(|a| a.def.to_string()).unwrap_or_default()
}
pub fn bound_accel(p: &Prefs, key: &str) -> String {
    with_mod_key(p, &accel_for(p, key))
}
pub fn is_custom(p: &Prefs, key: &str) -> bool {
    overrides(p).get(key).and_then(|v| v.as_str()).is_some_and(|s| !s.is_empty())
}
pub fn display_accel(p: &Prefs, key: &str) -> String {
    let a = bound_accel(p, key);
    for (m, k) in TAP_KEYS {
        if a == *k {
            return format!("Tap {m}");
        }
    }
    a
}
pub fn set_accel(p: &mut Prefs, key: &str, accel: &str) {
    let mut o = overrides(p);
    let Some(a) = ACTIONS.iter().find(|a| a.key == key) else { return };
    if accel.is_empty() || accel == a.def {
        o.remove(key);
    } else {
        o.insert(key.into(), json!(accel));
    }
    let _ = p.set("keybinds", json!(serde_json::to_string(&Value::Object(o)).unwrap_or_default()));
    write_binds(p);
}
pub fn reset_binds(p: &mut Prefs) {
    let _ = p.set("keybinds", json!(""));
    write_binds(p);
}

pub fn alt_tab_mod(p: &Prefs) -> String {
    let m = p.s("altTabMod").to_uppercase();
    if m == "SUPER" || m == "CTRL" {
        m
    } else {
        "ALT".into()
    }
}
pub fn alt_tab_accel(p: &Prefs, shift: bool) -> String {
    let m = if alt_tab_mod(p) == "SUPER" { mod_key(p) } else { alt_tab_mod(p) };
    format!("{m}{} + Tab", if shift { " + SHIFT" } else { "" })
}
pub fn alt_tab_clash(p: &Prefs) -> String {
    let squash = |s: &str| s.split_whitespace().collect::<String>().to_uppercase();
    let want = [squash(&alt_tab_accel(p, false)), squash(&alt_tab_accel(p, true))];
    ACTIONS
        .iter()
        .find(|a| {
            let b = bound_accel(p, a.key);
            !b.is_empty() && want.contains(&squash(&b))
        })
        .map(|a| a.n.to_string())
        .unwrap_or_default()
}

fn hypr_dir() -> std::path::PathBuf {
    std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()).map(std::path::PathBuf::from).unwrap_or_else(|| hyprshell_kit::home().join(".config")).join("hypr")
}

const TERM: &str = "command -v hyprshell-term >/dev/null 2>&1 && exec hyprshell-term \"$@\"; for d in \"$HOME/.local/bin\" /usr/local/bin /usr/bin; do [ -x \"$d/hyprshell-term\" ] && exec \"$d/hyprshell-term\" \"$@\"; done; for t in kitty foot alacritty wezterm xterm; do command -v \"$t\" >/dev/null 2>&1 && exec \"$t\" \"$@\"; done; notify-send \"Terminal\" \"no terminal is installed\" 2>/dev/null; exit 127";
const FILES: &str = "command -v hyprshell-files >/dev/null 2>&1 && exec hyprshell-files \"$@\"; for d in \"$HOME/.local/bin\" /usr/local/bin /usr/bin; do [ -x \"$d/hyprshell-files\" ] && exec \"$d/hyprshell-files\" \"$@\"; done; notify-send \"Files\" \"hyprshell-files is not installed\" 2>/dev/null; exit 127";
const WEB: &str = "command -v hyprshell-browser >/dev/null 2>&1 && exec hyprshell-browser \"$@\"; for b in firefox chromium google-chrome-stable brave; do command -v \"$b\" >/dev/null 2>&1 && exec \"$b\" \"$@\"; done; notify-send \"Web\" \"no browser is installed\" 2>/dev/null; exit 127";

/// Keybinds.body: only what was changed, Alt+Tab, and the workspaces when
/// the modifier moved.
pub fn binds_body(p: &Prefs) -> String {
    let ipc_call = |f: &str, arg: &str| {
        let call = if arg.is_empty() { f.to_string() } else { format!("{f} {arg}") };
        format!("hl.dsp.exec_cmd(shell({}))", lua_string(&call))
    };
    let m = mod_key(p);
    let mut lines: Vec<String> = [
        "-- Generated by the shell's Settings → Keybinds. Do not hand-edit:",
        "-- it is rewritten whenever a shortcut changes.",
        "--",
        "-- Only shortcuts you have *changed* appear here. hyprland.lua reads",
        "-- this at the end of its own run, so these replace its defaults and",
        "-- everything else keeps using the definition in that file.",
        "--",
        "-- Deleting this file restores every default.",
        "",
        "-- The modifier the Windows key sends on this keyboard.",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    lines.push(format!("local MOD = {}", lua_string(&m)));
    lines.extend(
        [
            "",
            "-- The shell IPC call, borrowed from hyprland.lua rather than",
            "-- copied: it hands this file its own `shell` helper just before",
            "-- loading it, so a rebound shortcut runs exactly what the default",
            "-- it replaced would have run. The fallback is only for the case",
            "-- of this file being loaded on its own, which nothing does.",
            "local shell = _G.hyprshellCall",
            "    or function(call) return \"qs -c hyprshell ipc call shell \" .. call end",
            "",
        ]
        .iter()
        .map(|s| s.to_string()),
    );
    lines.push(format!("local apps = {{ terminal = {}, files = {}, browser = {} }}", lua_string(TERM), lua_string(FILES), lua_string(WEB)));
    lines.push(String::new());
    let mut emitted = 0;
    for a in ACTIONS {
        if !is_custom(p, a.key) && m == "SUPER" {
            continue;
        }
        let accel = bound_accel(p, a.key);
        if accel.is_empty() {
            continue;
        }
        let d = if !a.ipc.is_empty() {
            ipc_call(a.ipc, a.arg)
        } else if !a.exec.is_empty() {
            format!("hl.dsp.exec_cmd(apps.{})", a.exec)
        } else {
            a.dsp.to_string()
        };
        let opts = if a.release && !is_custom(p, a.key) { ", { release = true }" } else { "" };
        lines.push(format!("hl.bind({}, {d}{opts})   -- {}", lua_string(&accel), a.n));
        emitted += 1;
    }
    if emitted == 0 {
        lines.push("-- (nothing overridden)".into());
    }
    lines.push(String::new());
    lines.push("-- Alt+Tab, from Settings → Alt+Tab.".into());
    if !p.b("altTabEnabled") {
        lines.push("-- (turned off: the chord goes to applications as usual)".into());
    } else {
        for shift in [false, true] {
            let accel = alt_tab_accel(p, shift);
            lines.push(format!("hl.unbind({})", lua_string(&accel)));
            lines.push(format!("hl.bind({}, {}, {{ repeating = true }})", lua_string(&accel), ipc_call("altTab", if shift { "prev" } else { "next" })));
        }
    }
    if m == "SUPER" {
        return lines.join("\n") + "\n";
    }
    lines.push(String::new());
    lines.push("-- Workspaces 1-10, and moving windows to them.".into());
    lines.push("for i = 1, 10 do".into());
    lines.push("    local k = i % 10".into());
    lines.push("    hl.bind(MOD .. \" + \" .. k, hl.dsp.focus({ workspace = i }))".into());
    lines.push("    hl.bind(MOD .. \" + SHIFT + \" .. k, hl.dsp.window.move({ workspace = i }))".into());
    lines.push("end".into());
    lines.join("\n") + "\n"
}

/// binds.lua written, and Hyprland reloaded so it reads it; then the
/// settings it forgets on a reload put back.
pub fn write_binds(p: &Prefs) {
    let path = hypr_dir().join("binds.lua");
    let body = binds_body(p);
    if std::fs::read_to_string(&path).ok().as_deref() == Some(body.as_str()) {
        return;
    }
    let _ = std::fs::create_dir_all(hypr_dir());
    if hyprshell_kit::write_atomic(&path, body.as_bytes()).is_ok() {
        reload();
        apply_all(p);
    }
}

/// Everything Settings holds for Hyprland, sent again.
pub fn apply_all(p: &Prefs) {
    apply_input(p);
    apply_frame(p);
    apply_displays(p);
}
