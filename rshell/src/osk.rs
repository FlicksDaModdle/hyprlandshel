//! The on-screen keyboard's keys (modules/osk/Keys.js) and its typing
//! (services/Keyboard.qml): wtype, with Hyprland's sendshortcut where
//! there is none. Modifiers are latched, not held: there is one pointer.

use std::io::Write;
use std::process::{Command, Stdio};

pub struct Key {
    /// A character: (unshifted, shifted).
    pub c: Option<(&'static str, &'static str)>,
    /// A named key: its keysym.
    pub k: Option<&'static str>,
    /// A modifier: shift | ctrl | alt | super | caps.
    pub m: Option<&'static str>,
    pub label: Option<&'static str>,
    pub w: f32,
}

const fn ch(a: &'static str, b: &'static str) -> Key {
    Key { c: Some((a, b)), k: None, m: None, label: None, w: 1.0 }
}
const fn chw(a: &'static str, b: &'static str, w: f32) -> Key {
    Key { c: Some((a, b)), k: None, m: None, label: None, w }
}
const fn named(k: &'static str, label: &'static str, w: f32) -> Key {
    Key { c: None, k: Some(k), m: None, label: Some(label), w }
}
const fn modk(m: &'static str, label: &'static str, w: f32) -> Key {
    Key { c: None, k: None, m: Some(m), label: Some(label), w }
}

pub fn rows() -> Vec<Vec<Key>> {
    vec![
        vec![ch("`", "~"), ch("1", "!"), ch("2", "@"), ch("3", "#"), ch("4", "$"), ch("5", "%"), ch("6", "^"), ch("7", "&"), ch("8", "*"), ch("9", "("), ch("0", ")"), ch("-", "_"), ch("=", "+"), named("BackSpace", "⌫", 2.0)],
        vec![named("Tab", "tab", 1.5), ch("q", "Q"), ch("w", "W"), ch("e", "E"), ch("r", "R"), ch("t", "T"), ch("y", "Y"), ch("u", "U"), ch("i", "I"), ch("o", "O"), ch("p", "P"), ch("[", "{"), ch("]", "}"), chw("\\", "|", 1.5)],
        vec![modk("caps", "caps", 1.75), ch("a", "A"), ch("s", "S"), ch("d", "D"), ch("f", "F"), ch("g", "G"), ch("h", "H"), ch("j", "J"), ch("k", "K"), ch("l", "L"), ch(";", ":"), ch("'", "\""), named("Return", "⏎", 2.25)],
        vec![modk("shift", "shift", 2.25), ch("z", "Z"), ch("x", "X"), ch("c", "C"), ch("v", "V"), ch("b", "B"), ch("n", "N"), ch("m", "M"), ch(",", "<"), ch(".", ">"), ch("/", "?"), modk("shift", "shift", 2.75)],
        vec![
            modk("ctrl", "ctrl", 1.25),
            modk("super", "super", 1.25),
            modk("alt", "alt", 1.25),
            Key { c: Some((" ", " ")), k: None, m: None, label: Some("space"), w: 6.0 },
            named("Escape", "esc", 1.25),
            named("Left", "←", 1.0),
            named("Down", "↓", 1.0),
            named("Up", "↑", 1.0),
            named("Right", "→", 1.0),
        ],
    ]
}

pub fn widest() -> f32 {
    rows().iter().map(|r| r.iter().map(|k| k.w).sum::<f32>()).fold(0.0, f32::max)
}

/// The keysym of a character that is not its own name.
fn keysym(ch: &str) -> &'static str {
    match ch {
        " " => "space",
        "`" => "grave",
        "~" => "asciitilde",
        "!" => "exclam",
        "@" => "at",
        "#" => "numbersign",
        "$" => "dollar",
        "%" => "percent",
        "^" => "asciicircum",
        "&" => "ampersand",
        "*" => "asterisk",
        "(" => "parenleft",
        ")" => "parenright",
        "-" => "minus",
        "_" => "underscore",
        "=" => "equal",
        "+" => "plus",
        "[" => "bracketleft",
        "{" => "braceleft",
        "]" => "bracketright",
        "}" => "braceright",
        "\\" => "backslash",
        "|" => "bar",
        ";" => "semicolon",
        ":" => "colon",
        "'" => "apostrophe",
        "\"" => "quotedbl",
        "," => "comma",
        "<" => "less",
        "." => "period",
        ">" => "greater",
        "/" => "slash",
        "?" => "question",
        _ => "",
    }
}

#[derive(Default)]
pub struct Osk {
    /// Latched modifiers, in the order pressed.
    pub held: Vec<&'static str>,
    /// "" when something can type; else what to tell the user.
    pub note: String,
}

impl Osk {
    pub fn is_held(&self, m: &str) -> bool {
        self.held.contains(&m)
    }

    pub fn shifted(&self) -> bool {
        self.is_held("shift") != self.is_held("caps")
    }

    pub fn hold(&mut self, m: &'static str) {
        if let Some(i) = self.held.iter().position(|h| *h == m) {
            self.held.remove(i);
        } else {
            self.held.push(m);
        }
    }

    fn release_all(&mut self) {
        // Caps is a lock: it is the one that stays.
        let caps = self.is_held("caps");
        self.held.clear();
        if caps {
            self.held.push("caps");
        }
    }

    /// A key pressed: a modifier latches; anything else is sent.
    pub fn press(&mut self, key: &Key) {
        if let Some(m) = key.m {
            self.hold(m);
            return;
        }
        let shifted = self.shifted();
        if let Some(k) = key.k {
            self.send("key", k);
        } else if let Some((a, b)) = key.c {
            self.send("text", if shifted { b } else { a });
        }
    }

    fn send(&mut self, mode: &str, payload: &str) {
        let mods: Vec<&str> = self.held.iter().copied().filter(|m| *m != "caps").collect();
        let ok = if have("wtype") {
            let mut args: Vec<String> = Vec::new();
            for m in &mods {
                args.extend(["-M".into(), (*m).into()]);
            }
            if mode == "key" {
                args.extend(["-k".into(), payload.into()]);
            } else {
                args.extend(["--".into(), payload.into()]);
            }
            for m in &mods {
                args.extend(["-m".into(), (*m).into()]);
            }
            Command::new("wtype").args(&args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
        } else {
            false
        };
        if !ok {
            // Hyprland's own: it wants a keysym, so a character is turned into one.
            let sym = if mode == "key" { payload.to_string() } else { keysym(payload).to_string() };
            let sym = if sym.is_empty() && payload.chars().count() == 1 && payload.chars().all(|c| c.is_ascii_alphabetic()) { payload.to_string() } else { sym };
            if sym.is_empty() {
                self.note = "Symbols need wtype; install it for the full keyboard".into();
            } else {
                let hm = mods.iter().map(|m| m.to_uppercase()).collect::<Vec<_>>().join(" ");
                let sent = Command::new("hyprctl")
                    .args(["dispatch", "sendshortcut", &format!("{hm},{sym},activewindow")])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status()
                    .is_ok_and(|s| s.success());
                if !sent {
                    self.note = "Nothing here can type — install wtype".into();
                }
            }
        }
        let _ = std::io::stdout().flush();
        self.release_all();
    }
}

fn have(prog: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(prog).is_file()))
}
