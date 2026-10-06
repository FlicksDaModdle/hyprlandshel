//! Write the files that carry the shell's accent out to other programs.
//!
//! The shell writes these itself whenever the accent changes — see
//! services/Theming.qml. This does the same thing from outside it, so that
//! they exist the moment the shell is installed rather than the next time
//! it runs, and so that a machine where the shell is not running can still
//! have them.
//!
//!   ~/.config/fastfetch/presets/hyprshell.jsonc   a fastfetch preset
//!   ~/.config/hyprshell/accent                    the accent, one line of hex
//!
//! The accent is resolved exactly as config/Appearance.qml resolves it, and
//! the preset list is read out of that file rather than copied here: a
//! palette in two places is a palette that will disagree with itself.
//!
//!   hyprshell-accent-files <path to Appearance.qml> [config home]

use serde_json::Value;
use std::path::{Path, PathBuf};

fn fail(msg: impl AsRef<str>) -> ! {
    eprintln!("accent-files: {}", msg.as_ref());
    std::process::exit(1);
}

fn is_hex6(s: &str) -> bool {
    s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit())
}

/// The text after `key` and any whitespace, if `key` is in `s`.
fn after<'a>(s: &'a str, key: &str) -> Option<&'a str> {
    s.find(key).map(|i| s[i + key.len()..].trim_start())
}

/// The quoted string at the start of `s`.
fn quoted(s: &str) -> Option<&str> {
    let s = s.strip_prefix('"')?;
    s.find('"').map(|e| &s[..e])
}

/// The accent presets, as Appearance.qml lists them: every
/// `light: "#…", dark: "#…"` pair up to the list's first `]`.
fn presets(src: &str, path: &str) -> Vec<(String, String)> {
    let body = after(src, "readonly property var accentPresets:")
        .and_then(|s| s.strip_prefix('['))
        .and_then(|s| s.find(']').map(|e| &s[..e]))
        .unwrap_or_else(|| fail(format!("no accentPresets in {path}")));
    let mut out = Vec::new();
    let mut rest = body;
    while let Some(i) = rest.find("light:") {
        rest = &rest[i + 6..];
        let Some(light) = quoted(rest.trim_start()) else { continue };
        let tail = rest.trim_start()[light.len() + 2..].trim_start();
        let Some(tail) = tail.strip_prefix(',') else { continue };
        let Some(tail) = tail.trim_start().strip_prefix("dark:") else { continue };
        let Some(dark) = quoted(tail.trim_start()) else { continue };
        if is_hex6(light) && is_hex6(dark) {
            out.push((light.to_string(), dark.to_string()));
        }
    }
    if out.is_empty() {
        fail(format!("accentPresets is empty in {path}"));
    }
    out
}

/// A JsonAdapter default, for the keys theme.json may leave out.
fn default_int(src: &str, name: &str) -> i64 {
    after(src, &format!("property int {name}:"))
        .and_then(|s| {
            let end = s.char_indices().find(|(i, c)| !(c.is_ascii_digit() || (*i == 0 && *c == '-'))).map(|(i, _)| i).unwrap_or(s.len());
            s[..end].parse().ok()
        })
        .unwrap_or_else(|| fail(format!("no default for {name}")))
}
fn default_string(src: &str, name: &str) -> String {
    after(src, &format!("property string {name}:"))
        .and_then(quoted)
        .map(|s| s.to_string())
        .unwrap_or_else(|| fail(format!("no default for {name}")))
}

fn accent_hex(theme: &Value, presets: &[(String, String)], src: &str) -> String {
    let mode = theme["theme"].as_str().map(|s| s.to_string()).unwrap_or_else(|| default_string(src, "theme"));
    // "auto" follows the system, which only the running shell can know.
    // Dark is the assumption, and the shell corrects it the moment it
    // starts — it rewrites both files on the way up.
    let dark = mode != "light";
    // The accent taken from the wallpaper, while that is switched on and
    // a colour was found (Appearance.qml's wallAccentOn).
    if theme["accentFromWallpaper"].as_bool() == Some(true) {
        let (l, d) = (theme["wallAccentLight"].as_str().unwrap_or(""), theme["wallAccentDark"].as_str().unwrap_or(""));
        if !l.is_empty() && !d.is_empty() {
            return if dark { d } else { l }.to_string();
        }
    }
    let index = theme["accent"].as_i64().unwrap_or_else(|| default_int(src, "accent"));
    if index == -1 {
        return theme["customAccent"].as_str().map(|s| s.to_string()).unwrap_or_else(|| default_string(src, "customAccent"));
    }
    let p = &presets[index.clamp(0, presets.len() as i64 - 1) as usize];
    if dark { p.1.clone() } else { p.0.clone() }
}

/// Byte for byte what services/Theming.qml writes.
fn preset_text(accent: &str, ff_dir: &str) -> String {
    format!(
        "{{\n  \"$schema\": \"https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json\",\n\n  \
         // Written by the shell (services/Theming.qml) whenever the accent\n  \
         // or the theme changes. Edits here are overwritten; put your own\n  \
         // settings in config.jsonc and use --color-keys instead, with the\n  \
         // hex in ~/.config/hyprshell/accent.\n  //\n  \
         //   fastfetch --config {ff_dir}/hyprshell.jsonc\n\n  \
         \"logo\": {{ \"type\": \"none\" }},\n  \"display\": {{\n    \"color\": {{\n      \
         \"keys\": \"{accent}\",\n      \"title\": \"{accent}\"\n    }},\n    \"separator\": \": \"\n  }}\n}}\n"
    )
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        fail("usage: hyprshell-accent-files <path to Appearance.qml> [config home]");
    }
    let appearance = &args[1];
    let config_home: PathBuf = match args.get(2) {
        Some(p) => p.into(),
        None => std::env::var_os("XDG_CONFIG_HOME")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| Path::new(&std::env::var("HOME").unwrap_or_default()).join(".config")),
    };
    let src = std::fs::read_to_string(appearance).unwrap_or_else(|e| fail(format!("{appearance}: {e}")));
    let presets = presets(&src, appearance);

    // No theme yet, or one that cannot be read: the defaults are the right
    // answer and are what the shell would use as well.
    let theme: Value = std::fs::read_to_string(config_home.join("quickshell/hyprshell/theme.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .filter(|v: &Value| v.is_object())
        .unwrap_or(Value::Null);

    let accent = accent_hex(&theme, &presets, &src);
    let ff_dir = config_home.join("fastfetch/presets");
    let write = |p: PathBuf, text: String| std::fs::write(&p, text).unwrap_or_else(|e| fail(format!("{}: {e}", p.display())));
    std::fs::create_dir_all(&ff_dir).unwrap_or_else(|e| fail(format!("{}: {e}", ff_dir.display())));
    std::fs::create_dir_all(config_home.join("hyprshell")).unwrap_or_else(|e| fail(e.to_string()));
    write(ff_dir.join("hyprshell.jsonc"), preset_text(&accent, &ff_dir.to_string_lossy()));
    write(config_home.join("hyprshell/accent"), format!("{accent}\n"));
    println!("{accent}");
}
