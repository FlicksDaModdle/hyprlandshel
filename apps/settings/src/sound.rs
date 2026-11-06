//! Settings → Sound: services/Audio.qml's reading of PipeWire (here the
//! daemon's PulseAudio snapshot, pa-watch) and SoundPanel.qml's own state.
//! Changes go through pactl, as Audio.qml's details did.

use crate::daemon::Daemon;
use crate::prefs::Prefs;
use crate::{AppWindow, Meters, Snd, SndApp, SndChan, SndDev, SndMix, SndOpt};
use serde_json::{json, Value};
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};

#[derive(Clone, Default)]
pub struct Node {
    pub index: i64,
    pub name: String,
    pub description: String,
    pub volume: f64,
    pub mute: bool,
    pub card: i64,
    pub ports: Vec<(String, String, bool)>,
    pub active_port: String,
    pub props: Value,
    pub sink: bool,
    /// Each channel's name ("front-left") and level, in order.
    pub channels: Vec<String>,
    pub volumes: Vec<f64>,
    /// An output's monitor source: what its level is read from.
    pub monitor: String,
}

#[derive(Clone, Default)]
pub struct Stream {
    pub index: i64,
    pub target: i64,
    pub volume: f64,
    pub mute: bool,
    pub props: Value,
    pub playing: bool,
    pub channels: Vec<String>,
    pub volumes: Vec<f64>,
}

fn chans(v: &Value) -> (Vec<String>, Vec<f64>) {
    (
        v["channels"].as_array().into_iter().flatten().map(|c| c.as_str().unwrap_or("").to_string()).collect(),
        v["volumes"].as_array().into_iter().flatten().map(|c| c.as_f64().unwrap_or(0.0)).collect(),
    )
}

// ── balance, fade and each channel (Audio.qml's) ───────────────────────
fn is_left(c: &str) -> bool {
    matches!(c, "front-left" | "rear-left" | "side-left")
}
fn is_right(c: &str) -> bool {
    matches!(c, "front-right" | "rear-right" | "side-right")
}
fn is_front(c: &str) -> bool {
    matches!(c, "front-left" | "front-right" | "front-center")
}
fn is_rear(c: &str) -> bool {
    matches!(c, "rear-left" | "rear-right" | "rear-center" | "side-left" | "side-right")
}
pub fn has_balance(ch: &[String]) -> bool {
    ch.iter().any(|c| c == "front-left") && ch.iter().any(|c| c == "front-right")
}
pub fn has_fade(ch: &[String]) -> bool {
    ch.iter().any(|c| is_rear(c)) && ch.iter().any(|c| is_front(c))
}
/// -1 (all left) to 1 (all right).
pub fn balance(ch: &[String], v: &[f64]) -> f64 {
    if !has_balance(ch) {
        return 0.0;
    }
    let at = |n: &str| ch.iter().position(|c| c == n).and_then(|i| v.get(i)).copied().unwrap_or(0.0);
    let (l, r) = (at("front-left"), at("front-right"));
    let top = l.max(r);
    if top <= 0.0001 {
        0.0
    } else if r >= l {
        1.0 - l / top
    } else {
        -(1.0 - r / top)
    }
}
/// -1 (all front) to 1 (all rear).
pub fn fade(ch: &[String], v: &[f64]) -> f64 {
    if !has_fade(ch) {
        return 0.0;
    }
    let (mut f, mut r) = (0.0f64, 0.0f64);
    for (c, x) in ch.iter().zip(v) {
        if is_front(c) {
            f = f.max(*x);
        } else if is_rear(c) {
            r = r.max(*x);
        }
    }
    let top = f.max(r);
    if top <= 0.0001 {
        0.0
    } else if r >= f {
        1.0 - f / top
    } else {
        -(1.0 - r / top)
    }
}
/// The levels for a balance, the loudest channel's level kept.
pub fn with_balance(ch: &[String], v: &[f64], b: f64) -> Vec<f64> {
    let b = if b.abs() < 0.03 { 0.0 } else { b.clamp(-1.0, 1.0) };
    let level = v.iter().cloned().fold(0.0, f64::max);
    ch.iter()
        .map(|c| {
            if is_left(c) {
                level * if b > 0.0 { 1.0 - b } else { 1.0 }
            } else if is_right(c) {
                level * if b < 0.0 { 1.0 + b } else { 1.0 }
            } else {
                level
            }
        })
        .collect()
}
pub fn with_fade(ch: &[String], v: &[f64], b: f64) -> Vec<f64> {
    let b = if b.abs() < 0.03 { 0.0 } else { b.clamp(-1.0, 1.0) };
    let level = v.iter().cloned().fold(0.0, f64::max);
    ch.iter()
        .map(|c| {
            if is_front(c) {
                level * if b > 0.0 { 1.0 - b } else { 1.0 }
            } else if is_rear(c) {
                level * if b < 0.0 { 1.0 + b } else { 1.0 }
            } else {
                level
            }
        })
        .collect()
}
/// Audio.channelName.
pub fn channel_name(c: &str) -> String {
    match c {
        "mono" => "Mono".into(),
        "front-left" => "Front left".into(),
        "front-right" => "Front right".into(),
        "front-center" => "Centre".into(),
        "lfe" => "Subwoofer".into(),
        "rear-left" => "Rear left".into(),
        "rear-right" => "Rear right".into(),
        "rear-center" => "Rear centre".into(),
        "side-left" => "Side left".into(),
        "side-right" => "Side right".into(),
        other => format!("Channel {other}"),
    }
}
/// "Centre", or how far and which way.
pub fn lean(b: f64, neg: &str, pos: &str) -> String {
    if b.abs() < 0.01 {
        "Centre".into()
    } else {
        format!("{} {}", (b.abs() * 100.0).round(), if b < 0.0 { neg } else { pos })
    }
}

/// Apps.iconFor's hints: an app's glyph by what it's called.
pub fn app_glyph(hint: &str) -> &'static str {
    let h = hint.to_lowercase();
    let any = |ks: &[&str]| ks.iter().any(|k| h.contains(k));
    const HINTS: &[(&[&str], &str)] = &[
        (&["hyprshell-rog"], "zap"),
        (&["hyprshell-notes"], "stickyNote"),
        (&["hyprshell-snapshots"], "rotateCw"),
        (&["hyprshell-disks"], "drive"),
        (&["hyprshell-keys"], "key"),
        (&["hyprshell-docs"], "file"),
        (&["hyprshell-music"], "music"),
        (&["hyprshell-video"], "film"),
        (&["hyprshell-recorder"], "mic"),
        (&["hyprshell-chats"], "chat"),
        (&["hyprshell-weather"], "cloudSun"),
        (&["hyprshell-calendar"], "calendar"),
        (&["hyprshell-fonts"], "font"),
        (&["hyprshell-text"], "doc"),
        (&["hyprshell-camera"], "camera"),
        (&["hyprshell-software"], "package"),
        (&["term", "foot", "kitty", "alacritty", "wezterm", "konsole", "tmux"], "terminal"),
        (&["nautilus", "thunar", "dolphin", "nemo", "pcmanfm", "files", "ranger"], "folder"),
        (&["firefox", "chrom", "brave", "epiphany", "zen", "browser", "webkit"], "globe"),
        (&["code", "nvim", "neovide", "vim", "zed", "jetbrains", "emacs", "idea", "studio"], "code"),
        (&["obsidian", "logseq", "notes", "texteditor", "gedit", "writer"], "stickyNote"),
        (&["spotify", "music", "mpd", "ncmpcpp", "audacious", "amberol", "rhythmbox"], "music"),
        (&["pavucontrol", "volume", "audio", "helvum", "easyeffects"], "sliders"),
        (&["settings", "control", "config", "tweaks"], "settings"),
        (&["image", "viewer", "loupe", "eog", "imv", "gwenview", "gimp", "inkscape"], "image"),
        (&["video", "mpv", "vlc", "celluloid", "obs"], "monitor"),
        (&["mail", "thunderbird", "evolution", "geary"], "mail"),
        (&["discord", "telegram", "signal", "element", "slack", "whatsapp", "chat"], "chat"),
        (&["steam", "game", "lutris", "heroic"], "gamepad"),
        (&["bluetooth", "blueman"], "bluetooth"),
        (&["network", "nm-", "wifi"], "wifi"),
        (&["screenshot", "grim", "slurp", "capture", "flameshot"], "camera"),
        (&["pkg", "package", "software", "discover", "store", "pamac"], "pkg"),
        (&["monitor", "htop", "btop", "system", "resources", "task"], "cpu"),
    ];
    HINTS.iter().find(|(ks, _)| any(ks)).map(|x| x.1).unwrap_or("square")
}

#[derive(Default)]
pub struct Sound {
    /// The sources whose levels the daemon is sending, and each one's
    /// level and hold line (0–1, on the meter's dB scale).
    pub peak_names: Vec<String>,
    pub levels: std::collections::HashMap<String, (f64, f64)>,
    pub up: bool,
    pub seen: bool,
    pub sinks: Vec<Node>,
    pub sources: Vec<Node>,
    pub streams: Vec<Stream>,
    pub cards: Vec<Value>,
    pub default_sink: String,
    pub default_source: String,
    pub picked_out: String,
    pub picked_in: String,
    pub show_hidden: bool,
    pub watching: bool,
    pub restarting: bool,
    pub last_error: String,
    /// The defaults as PipeWire has them: the equalizer's sink or the noise
    /// suppressor's source while one is in the way (Audio.qml's rawSink).
    pub raw_sink: String,
    pub raw_source: String,
    /// Their nodes' ids, for pw-cli; and the streams that carry them on to
    /// the device, to move when another device is picked.
    pub eq_node: String,
    pub ns_node: String,
    pub eq_out: i64,
    pub ns_in: i64,
}

fn node(v: &Value, sink: bool) -> Node {
    Node {
        index: v["index"].as_i64().unwrap_or(-1),
        name: v["name"].as_str().unwrap_or("").into(),
        description: v["description"].as_str().unwrap_or("").into(),
        volume: v["volume"].as_f64().unwrap_or(0.0),
        mute: v["mute"] == true,
        card: v["card"].as_i64().unwrap_or(-1),
        ports: v["ports"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|p| (p["name"].as_str().unwrap_or("").into(), p["description"].as_str().unwrap_or("").into(), p["availability"] != "no"))
            .collect(),
        active_port: v["active_port"].as_str().unwrap_or("").into(),
        props: v["properties"].clone(),
        sink,
        channels: chans(v).0,
        volumes: chans(v).1,
        monitor: v["monitorSource"].as_str().unwrap_or("").to_string(),
    }
}

/// pactl, one call, in the background.
pub fn pactl(args: &[String]) {
    let a = args.to_vec();
    std::thread::spawn(move || {
        let _ = std::process::Command::new("pactl").args(&a).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
    });
}
fn pa(args: &[&str]) {
    pactl(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>());
}

fn json_list(p: &Prefs, k: &str) -> Vec<String> {
    serde_json::from_str(&p.s(k)).unwrap_or_default()
}
fn nicknames(p: &Prefs) -> serde_json::Map<String, Value> {
    serde_json::from_str::<Value>(&p.s("soundNames")).ok().and_then(|v| v.as_object().cloned()).unwrap_or_default()
}

impl Sound {
    /// The sources to read levels from: the glance's and the inspector's,
    /// while the pane is up and meters are on.
    fn wanted_peaks(&self, p: &Prefs) -> Vec<String> {
        if !self.watching || !p.b("soundMeters") {
            return vec![];
        }
        let out = |n: Option<&Node>| n.map(|n| if n.monitor.is_empty() { format!("{}.monitor", n.name) } else { n.monitor.clone() });
        let mut v: Vec<String> = [
            out(self.sinks.iter().find(|n| n.name == self.default_sink)),
            out(self.inspected(true)),
            self.sources.iter().find(|n| n.name == self.default_source).map(|n| n.name.clone()),
            self.inspected(false).map(|n| n.name.clone()),
        ]
        .into_iter()
        .flatten()
        .collect();
        v.dedup();
        v.sort();
        v.dedup();
        v
    }
    pub fn sync_peaks(&mut self, d: &mut Daemon, p: &Prefs) {
        let want = self.wanted_peaks(p);
        if want != self.peak_names {
            d.send(json!({ "cmd": "pa-peaks", "sources": want }));
            self.levels.retain(|k, _| want.contains(k));
            self.peak_names = want;
        }
    }
    /// A pa-peak: onto the meter's scale, the hold line pushed up.
    pub fn peak(&mut self, ev: &Value) {
        let name = ev["name"].as_str().unwrap_or("").to_string();
        let p = ev["peak"].as_f64().unwrap_or(0.0);
        let level = if p > 0.0 { (1.0 + 20.0 * p.log10() / 60.0).clamp(0.0, 1.0) } else { 0.0 };
        let e = self.levels.entry(name).or_insert((0.0, 0.0));
        e.0 = level;
        e.1 = e.1.max(level);
    }
    /// The hold lines fall back (0.02 every 50 ms, as SoundLevel's timer).
    pub fn decay(&mut self, dt: f64) {
        for (l, h) in self.levels.values_mut() {
            *h = (*h - 0.02 * dt / 0.05).max(*l);
        }
    }
    pub fn publish_meters(&self, ui: &AppWindow) {
        let m = ui.global::<Meters>();
        let mon = |n: Option<&Node>, out: bool| {
            n.map(|n| if !out { n.name.clone() } else if n.monitor.is_empty() { format!("{}.monitor", n.name) } else { n.monitor.clone() })
                .and_then(|k| self.levels.get(&k).copied())
                .unwrap_or((0.0, 0.0))
        };
        let o = mon(self.sinks.iter().find(|n| n.name == self.default_sink), true);
        let i = mon(self.sources.iter().find(|n| n.name == self.default_source), false);
        let io = mon(self.inspected(true), true);
        let ii = mon(self.inspected(false), false);
        m.set_out(o.0 as f32);
        m.set_out_hold(o.1 as f32);
        m.set_in(i.0 as f32);
        m.set_in_hold(i.1 as f32);
        m.set_io(io.0 as f32);
        m.set_io_hold(io.1 as f32);
        m.set_ii(ii.0 as f32);
        m.set_ii_hold(ii.1 as f32);
    }

    pub fn watch(&mut self, d: &mut Daemon, on: bool) {
        if self.watching == on {
            return;
        }
        self.watching = on;
        d.send(json!({ "cmd": "pa-watch", "on": on }));
        if !on && !self.peak_names.is_empty() {
            d.send(json!({ "cmd": "pa-peaks", "sources": [] }));
            self.peak_names.clear();
            self.levels.clear();
        }
        if on {
            d.send(json!({ "cmd": "pa-snapshot" }));
        }
    }

    pub fn event(&mut self, ev: &Value) -> bool {
        if ev["ev"] != "pa" {
            return false;
        }
        self.seen = true;
        if ev["available"] != true {
            self.up = false;
            return true;
        }
        self.up = true;
        // The shell's own (Audio.isOurs): the effects' devices and streams.
        let ours_p = |p: &Value| p["node.name"].as_str().unwrap_or("").starts_with("hyprshell_") || p["application.name"].as_str().unwrap_or("").starts_with("hyprshell-");
        let ours = |n: &Node| n.name.starts_with("hyprshell_") || n.name.starts_with("hyprshell-") || ours_p(&n.props);
        let id_of = |v: &Value| v["properties"]["object.id"].as_str().map(str::to_string).or_else(|| v["properties"]["object.id"].as_i64().map(|i| i.to_string())).unwrap_or_else(|| v["index"].as_i64().unwrap_or(-1).to_string());
        let find = |k: &str, name: &str| ev[k].as_array().into_iter().flatten().find(|v| v["name"] == name || v["properties"]["node.name"] == name).cloned();
        self.eq_node = find("sinks", "hyprshell_eq").map(|v| id_of(&v)).unwrap_or_default();
        self.ns_node = find("sources", "hyprshell_ns").map(|v| id_of(&v)).unwrap_or_default();
        self.eq_out = find("sinkInputs", "hyprshell_eq_out").and_then(|v| v["index"].as_i64()).unwrap_or(-1);
        self.ns_in = find("sourceOutputs", "hyprshell_ns_in").and_then(|v| v["index"].as_i64()).unwrap_or(-1);
        self.sinks = ev["sinks"].as_array().into_iter().flatten().map(|v| node(v, true)).filter(|n| !ours(n)).collect();
        self.sources = ev["sources"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|v| v["monitor"] != true)
            .map(|v| node(v, false))
            .filter(|n| !ours(n))
            .collect();
        let monitor = |p: &Value| p["stream.monitor"] == "true" || p["media.category"] == "Monitor" || p["application.name"] == "Quickshell Peak Detect";
        let mut streams: Vec<Stream> = ev["sinkInputs"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|v| !monitor(&v["properties"]) && !ours_p(&v["properties"]))
            .map(|v| Stream {
                index: v["index"].as_i64().unwrap_or(-1),
                target: v["sink"].as_i64().unwrap_or(-1),
                volume: v["volume"].as_f64().unwrap_or(1.0),
                mute: v["mute"] == true,
                props: v["properties"].clone(),
                playing: true,
                channels: chans(v).0,
                volumes: chans(v).1,
            })
            .collect();
        streams.extend(ev["sourceOutputs"].as_array().into_iter().flatten().filter(|v| !monitor(&v["properties"]) && !ours_p(&v["properties"])).map(|v| Stream {
            index: v["index"].as_i64().unwrap_or(-1),
            target: v["source"].as_i64().unwrap_or(-1),
            volume: v["volume"].as_f64().unwrap_or(1.0),
            mute: v["mute"] == true,
            props: v["properties"].clone(),
            playing: false,
            channels: chans(v).0,
            volumes: chans(v).1,
        }));
        self.streams = streams;
        self.cards = ev["cards"].as_array().cloned().unwrap_or_default();
        self.raw_sink = ev["defaultSink"].as_str().unwrap_or("").into();
        self.raw_source = ev["defaultSource"].as_str().unwrap_or("").into();
        self.default_sink = self.raw_sink.clone();
        self.default_source = self.raw_source.clone();
        true
    }

    pub fn eq_active(&self) -> bool {
        self.raw_sink == "hyprshell_eq"
    }
    pub fn ns_active(&self) -> bool {
        self.raw_source == "hyprshell_ns"
    }
    /// With an effect in the way, the device in use is the one it feeds
    /// (Audio.sink / Audio.source): eqTarget, nsTarget.
    pub fn resolve(&mut self, p: &Prefs) {
        if self.eq_active() {
            let t = p.s("eqTarget");
            self.default_sink = self.sinks.iter().find(|n| n.name == t).or(self.sinks.first()).map(|n| n.name.clone()).unwrap_or_default();
        }
        if self.ns_active() {
            let t = p.s("nsTarget");
            self.default_source = self.sources.iter().find(|n| n.name == t).or(self.sources.first()).map(|n| n.name.clone()).unwrap_or_default();
        }
    }
    pub fn inspected_name(&self, out: bool) -> String {
        self.inspected(out).map(|n| n.name.clone()).unwrap_or_default()
    }
    /// A device's name as the panel shows it.
    pub fn label(&self, p: &Prefs, name: &str) -> String {
        self.find(name).map(|n| Self::display_name(p, n)).unwrap_or_default()
    }
    /// The apps for the equalizer's "Chosen apps": those playing now, then
    /// those chosen before that aren't — (key, label, glyph, live).
    pub fn eq_apps(&self, chosen: &[String]) -> Vec<(String, String, String, bool)> {
        let mut out: Vec<(String, String, String, bool)> = vec![];
        for s in self.streams.iter().filter(|s| s.playing) {
            let pr = &s.props;
            let key = pr["application.process.binary"].as_str().or(pr["application.name"].as_str()).or(pr["node.name"].as_str()).unwrap_or("").to_string();
            if key.is_empty() || out.iter().any(|x| x.0 == key) {
                continue;
            }
            let label = pr["application.name"].as_str().or(pr["application.process.binary"].as_str()).unwrap_or(&key).to_string();
            let hint = pr["application.process.binary"].as_str().or(pr["application.icon-name"].as_str()).or(pr["application.name"].as_str()).unwrap_or("");
            out.push((key.clone(), label, app_glyph(hint).into(), true));
        }
        for k in chosen {
            if !out.iter().any(|x| &x.0 == k) {
                out.push((k.clone(), k.clone(), app_glyph(k).into(), false));
            }
        }
        out
    }

    fn display_name(p: &Prefs, n: &Node) -> String {
        nicknames(p).get(&n.name).and_then(|v| v.as_str()).map(str::to_string).unwrap_or_else(|| if n.description.is_empty() { n.name.clone() } else { n.description.clone() })
    }

    /// Audio.deviceGlyph.
    fn glyph(n: &Node) -> &'static str {
        let hint = format!(
            "{} {} {}",
            n.props["device.form_factor"].as_str().unwrap_or(""),
            n.props["device.bus"].as_str().unwrap_or(""),
            n.active_port
        )
        .to_lowercase();
        if hint.contains("hdmi") || hint.contains("displayport") {
            return if n.sink { "monitor" } else { "mic" };
        }
        if ["headphone", "headset", "hands-free", "handsfree", "bluez", "bluetooth"].iter().any(|k| hint.contains(k)) {
            return if n.sink { "headphones" } else { "mic" };
        }
        if n.sink {
            "speaker"
        } else {
            "mic"
        }
    }

    pub fn max_volume(p: &Prefs) -> f64 {
        p.f("volumeMax").max(if p.b("volumeBoost") { 150.0 } else { 0.0 }) / 100.0
    }

    fn inspected(&self, out: bool) -> Option<&Node> {
        let (list, picked, def) = if out { (&self.sinks, &self.picked_out, &self.default_sink) } else { (&self.sources, &self.picked_in, &self.default_source) };
        list.iter().find(|n| n.name == *picked).or_else(|| list.iter().find(|n| n.name == *def))
    }

    pub fn publish(&self, ui: &AppWindow, p: &Prefs) {
        let s = ui.global::<Snd>();
        s.set_up(self.up || !self.seen);
        let listening = crate::eq::status()["listen"]["module"].as_i64().unwrap_or(-1) >= 0;
        s.set_out_fx(if self.eq_active() { "Equalizer on".into() } else { SharedString::new() });
        s.set_in_fx(
            [if self.ns_active() { "Noise suppression on" } else { "" }, if listening { "Listening through the output" } else { "" }]
                .into_iter()
                .filter(|x| !x.is_empty())
                .collect::<Vec<_>>()
                .join(" · ")
                .into(),
        );
        s.set_restarting(self.restarting);
        let tab = p.s("soundTab");
        s.set_tab(match tab.as_str() {
            "input" => 1,
            "apps" => 2,
            "options" => 3,
            _ => 0,
        });
        let hidden = json_list(p, "soundHidden");
        let max = Self::max_volume(p);
        let dev = |n: &Node, out: bool| {
            let in_use = if out { n.name == self.default_sink } else { n.name == self.default_source };
            let port = n.ports.iter().find(|x| x.0 == n.active_port);
            let name = Self::display_name(p, n);
            let unplugged = port.is_some_and(|x| !x.2);
            let sub: Vec<String> = [
                if in_use { "In use".to_string() } else { String::new() },
                if in_use && out && self.eq_active() { "through the equalizer".into() } else { String::new() },
                if in_use && !out && self.ns_active() { "noise suppressed".into() } else { String::new() },
                port.filter(|x| x.1 != name).map(|x| x.1.clone()).unwrap_or_default(),
                if unplugged { "unplugged".into() } else { String::new() },
                if hidden.contains(&n.name) { "hidden".into() } else { String::new() },
            ]
            .into_iter()
            .filter(|s| !s.is_empty())
            .collect();
            let picked = self.inspected(out).is_some_and(|x| x.name == n.name);
            SndDev {
                name: n.name.clone().into(),
                label: name.into(),
                sub: sub.join(" · ").into(),
                glyph: Self::glyph(n).into(),
                in_use,
                picked,
                muted: n.mute,
                level: (n.volume / if out { max } else { 1.5 }) as f32,
                pct: (n.volume * 100.0).round() as i32,
                loud: n.volume > 1.001,
                dim: unplugged && !in_use,
            }
        };
        let list = |nodes: &Vec<Node>, out: bool, cur: &str| -> Vec<SndDev> {
            nodes.iter().filter(|n| self.show_hidden || !hidden.contains(&n.name) || n.name == cur).map(|n| dev(n, out)).collect()
        };
        s.set_outputs(ModelRc::new(VecModel::from(list(&self.sinks, true, &self.default_sink))));
        s.set_inputs(ModelRc::new(VecModel::from(list(&self.sources, false, &self.default_source))));
        s.set_hidden_out(self.sinks.iter().filter(|n| hidden.contains(&n.name)).count() as i32);
        s.set_hidden_in(self.sources.iter().filter(|n| hidden.contains(&n.name)).count() as i32);
        s.set_show_hidden(self.show_hidden);
        // At a glance.
        let sink = self.sinks.iter().find(|n| n.name == self.default_sink);
        let source = self.sources.iter().find(|n| n.name == self.default_source);
        s.set_out_name(sink.map(|n| Self::display_name(p, n)).unwrap_or("No output".into()).into());
        s.set_in_name(source.map(|n| Self::display_name(p, n)).unwrap_or("No microphone".into()).into());
        s.set_out_glyph(sink.map(Self::glyph).unwrap_or("speaker").into());
        s.set_out_muted(sink.is_some_and(|n| n.mute));
        s.set_in_muted(source.is_some_and(|n| n.mute));
        s.set_has_out(sink.is_some());
        s.set_has_in(source.is_some());
        s.set_out_level(sink.map(|n| n.volume / max).unwrap_or(0.0) as f32);
        s.set_in_level(source.map(|n| n.volume / 1.5).unwrap_or(0.0) as f32);
        s.set_out_pct(sink.map(|n| (n.volume * 100.0).round() as i32).unwrap_or(0));
        s.set_in_pct(source.map(|n| (n.volume * 100.0).round() as i32).unwrap_or(0));
        // The inspector: the picked device, else the one in use.
        for out in [true, false] {
            let Some(n) = self.inspected(out) else {
                if out {
                    s.set_io_name(SharedString::new());
                } else {
                    s.set_ii_name(SharedString::new());
                }
                continue;
            };
            let card = self.cards.iter().find(|c| c["index"].as_i64() == Some(n.card));
            let ports: Vec<SndOpt> = n.ports.iter().map(|x| SndOpt { value: x.0.clone().into(), label: format!("{}{}", x.1, if x.2 { "" } else { " (unplugged)" }).into() }).collect();
            let profiles: Vec<SndOpt> = card
                .and_then(|c| c["profiles"].as_array())
                .into_iter()
                .flatten()
                .filter(|pr| pr["available"] != false)
                .map(|pr| SndOpt { value: pr["name"].as_str().unwrap_or("").into(), label: pr["description"].as_str().unwrap_or("").into() })
                .collect();
            let active_profile = card.and_then(|c| c["active_profile"].as_str()).unwrap_or("").to_string();
            let latency = card
                .and_then(|c| c["ports"].as_array())
                .and_then(|ps| ps.iter().find(|x| x["name"] == n.active_port.as_str()))
                .and_then(|x| x["latency_offset"].as_i64())
                .unwrap_or(0) as f64
                / 1000.0;
            let in_use = if out { n.name == self.default_sink } else { n.name == self.default_source };
            let nick = nicknames(p).get(&n.name).and_then(|v| v.as_str()).unwrap_or("").to_string();
            let pi = ports.iter().position(|x| x.value == n.active_port.as_str()).map(|i| i as i32).unwrap_or(-1);
            let fi = profiles.iter().position(|x| x.value == active_profile.as_str()).map(|i| i as i32).unwrap_or(-1);
            let details: String = [
                ("Driver name", if n.description.is_empty() { n.name.clone() } else { n.description.clone() }),
                ("Node", n.name.clone()),
                ("Card", card.and_then(|c| c["name"].as_str()).unwrap_or("").to_string()),
            ]
            .iter()
            .filter(|x| !x.1.is_empty())
            .map(|x| format!("{}: {}", x.0, x.1))
            .collect::<Vec<_>>()
            .join("\n");
            let ceiling = if out { max } else { 1.5 };
            let mix = SndMix {
                level: (n.volume / ceiling) as f32,
                pct: (n.volume * 100.0).round() as i32,
                loud: n.volume > 1.001,
                muted: n.mute,
                ceiling: ceiling as f32,
                has_balance: has_balance(&n.channels),
                balance: balance(&n.channels, &n.volumes) as f32,
                balance_text: lean(balance(&n.channels, &n.volumes), "L", "R").into(),
                has_fade: has_fade(&n.channels),
                fade: fade(&n.channels, &n.volumes) as f32,
                fade_text: lean(fade(&n.channels, &n.volumes), "F", "R").into(),
                channels: ModelRc::new(VecModel::from(
                    n.channels
                        .iter()
                        .zip(n.volumes.iter())
                        .map(|(c, v)| SndChan { name: channel_name(c).into(), level: (v / ceiling) as f32, pct: (v * 100.0).round() as i32 })
                        .collect::<Vec<_>>(),
                )),
            };
            if out {
                s.set_io_mix(mix);
                s.set_io_name(n.name.clone().into());
                s.set_io_label(Self::display_name(p, n).into());
                s.set_io_nick(nick.into());
                s.set_io_in_use(in_use);
                s.set_io_hidden(hidden.contains(&n.name));
                s.set_io_ports(ModelRc::new(VecModel::from(ports)));
                s.set_io_port(pi);
                s.set_io_profiles(ModelRc::new(VecModel::from(profiles)));
                s.set_io_profile(fi);
                s.set_io_delay(latency as f32);
                s.set_io_details(details.into());
            } else {
                s.set_ii_mix(mix);
                s.set_ii_name(n.name.clone().into());
                s.set_ii_label(Self::display_name(p, n).into());
                s.set_ii_nick(nick.into());
                s.set_ii_in_use(in_use);
                s.set_ii_hidden(hidden.contains(&n.name));
                s.set_ii_ports(ModelRc::new(VecModel::from(ports)));
                s.set_ii_port(pi);
                s.set_ii_profiles(ModelRc::new(VecModel::from(profiles)));
                s.set_ii_profile(fi);
                s.set_ii_delay(latency as f32);
                s.set_ii_details(details.into());
            }
        }
        // Apps, playing and recording.
        let app = |st: &Stream| {
            let pr = &st.props;
            let name = pr["application.name"].as_str().or(pr["application.process.binary"].as_str()).unwrap_or("Unknown").to_string();
            let media = pr["media.name"].as_str().unwrap_or("").to_string();
            let low = media.to_lowercase();
            let media = if media.is_empty()
                || media == name
                || ["playback", "audio stream", "audiostream", "output", "record", "capture", "recstream", "playstream"].contains(&low.as_str())
            {
                String::new()
            } else {
                media
            };
            let devs = if st.playing { &self.sinks } else { &self.sources };
            let target = devs.iter().position(|n| n.index == st.target).map(|i| i as i32).unwrap_or(-1);
            let hint = pr["application.process.binary"].as_str().or(pr["application.icon-name"].as_str()).or(pr["application.name"].as_str()).unwrap_or("");
            let device = devs.get(target.max(0) as usize).filter(|_| target >= 0).map(|n| Self::display_name(p, n)).unwrap_or_else(|| if st.playing { "Output".into() } else { "Input".into() });
            let device = if device.chars().count() > 16 { format!("{}…", device.chars().take(15).collect::<String>()) } else { device };
            SndApp {
                glyph: if st.playing { app_glyph(hint) } else { "mic" }.into(),
                device: format!("{device}  ▾").into(),
                multi: devs.len() > 1,
                has_balance: has_balance(&st.channels),
                balance: balance(&st.channels, &st.volumes) as f32,
                balance_text: lean(balance(&st.channels, &st.volumes), "L", "R").into(),
                key: format!("{}{}", if st.playing { "p" } else { "r" }, st.index).into(),
                index: st.index as i32,
                playing: st.playing,
                name: name.into(),
                media: media.into(),
                muted: st.mute,
                level: (st.volume / if st.playing { max } else { 1.5 }) as f32,
                pct: (st.volume * 100.0).round() as i32,
                target,
            }
        };
        let playing: Vec<SndApp> = self.streams.iter().filter(|s| s.playing).map(app).collect();
        let recording: Vec<SndApp> = self.streams.iter().filter(|s| !s.playing).map(app).collect();
        s.set_app_count((playing.len() + recording.len()) as i32);
        s.set_playing(ModelRc::new(VecModel::from(playing)));
        s.set_recording(ModelRc::new(VecModel::from(recording)));
        s.set_sink_names(ModelRc::new(VecModel::from(self.sinks.iter().map(|n| SharedString::from(Self::display_name(p, n))).collect::<Vec<_>>())));
        s.set_source_names(ModelRc::new(VecModel::from(self.sources.iter().map(|n| SharedString::from(Self::display_name(p, n))).collect::<Vec<_>>())));
        s.set_sink_glyphs(ModelRc::new(VecModel::from(self.sinks.iter().map(|n| SharedString::from(Self::glyph(n))).collect::<Vec<_>>())));
        s.set_source_glyphs(ModelRc::new(VecModel::from(self.sources.iter().map(|n| SharedString::from(Self::glyph(n))).collect::<Vec<_>>())));
        // Options.
        s.set_step(p.i("volumeStep") as i32);
        s.set_limit(p.f("volumeMax").max(if p.b("volumeBoost") { 150.0 } else { 0.0 }) as i32);
        s.set_feedback(p.b("volumeFeedback"));
        s.set_auto_switch(p.b("soundAutoSwitch"));
        s.set_meters(p.b("soundMeters"));
        s.set_names_line(format!("{} renamed, {} hidden — set in each device's details", nicknames(p).len(), hidden.len()).into());
        s.set_names_any(nicknames(p).len() + hidden.len() > 0);
        s.set_last_error(self.last_error.clone().into());
        s.set_pactl(crate::system::have("pactl"));
    }

    // ── actions (Audio.qml) ─────────────────────────────────────────────
    fn find(&self, name: &str) -> Option<&Node> {
        self.sinks.iter().chain(self.sources.iter()).find(|n| n.name == name)
    }
    pub fn set_volume(&mut self, p: &Prefs, name: &str, v: f64) {
        let Some(n) = self.find(name).cloned() else { return };
        let v = v.clamp(0.0, if n.sink { Self::max_volume(p) } else { 1.5 });
        pa(&[if n.sink { "set-sink-volume" } else { "set-source-volume" }, &n.name, &format!("{}%", (v * 100.0).round())]);
        for l in [&mut self.sinks, &mut self.sources] {
            if let Some(x) = l.iter_mut().find(|x| x.name == name) {
                x.volume = v;
            }
        }
    }
    /// Every channel's level at once (balance, fade, one channel moved).
    pub fn set_levels(&mut self, p: &Prefs, name: &str, levels: Vec<f64>) {
        let Some(n) = self.find(name).cloned() else { return };
        let cap = if n.sink { Self::max_volume(p) } else { 1.5 };
        let mut args: Vec<String> = vec![if n.sink { "set-sink-volume" } else { "set-source-volume" }.into(), n.name.clone()];
        args.extend(levels.iter().map(|v| format!("{}%", (v.clamp(0.0, cap) * 100.0).round())));
        pactl(&args);
        for l in [&mut self.sinks, &mut self.sources] {
            if let Some(x) = l.iter_mut().find(|x| x.name == name) {
                x.volumes = levels.iter().map(|v| v.clamp(0.0, cap)).collect();
                x.volume = x.volumes.iter().cloned().fold(0.0, f64::max);
            }
        }
    }
    pub fn set_balance(&mut self, p: &Prefs, name: &str, b: f64) {
        let Some(n) = self.find(name).cloned() else { return };
        if has_balance(&n.channels) {
            self.set_levels(p, name, with_balance(&n.channels, &n.volumes, b));
        }
    }
    pub fn set_fade(&mut self, p: &Prefs, name: &str, b: f64) {
        let Some(n) = self.find(name).cloned() else { return };
        if has_fade(&n.channels) {
            self.set_levels(p, name, with_fade(&n.channels, &n.volumes, b));
        }
    }
    pub fn set_channel(&mut self, p: &Prefs, name: &str, i: usize, v: f64) {
        let Some(n) = self.find(name).cloned() else { return };
        let mut levels = n.volumes.clone();
        if let Some(x) = levels.get_mut(i) {
            *x = v;
            self.set_levels(p, name, levels);
        }
    }
    /// An app's own balance.
    pub fn stream_balance(&mut self, p: &Prefs, index: i32, playing: bool, b: f64) {
        let Some(st) = self.streams.iter_mut().find(|s| s.index == index as i64 && s.playing == playing) else { return };
        if !has_balance(&st.channels) {
            return;
        }
        let cap = if playing { Self::max_volume(p) } else { 1.5 };
        let levels = with_balance(&st.channels, &st.volumes, b);
        let mut args: Vec<String> = vec![if playing { "set-sink-input-volume" } else { "set-source-output-volume" }.into(), index.to_string()];
        args.extend(levels.iter().map(|v| format!("{}%", (v.clamp(0.0, cap) * 100.0).round())));
        pactl(&args);
        st.volumes = levels;
    }

    pub fn set_mute(&mut self, name: &str, on: bool) {
        let Some(n) = self.find(name).cloned() else { return };
        pa(&[if n.sink { "set-sink-mute" } else { "set-source-mute" }, &n.name, if on { "1" } else { "0" }]);
        for l in [&mut self.sinks, &mut self.sources] {
            if let Some(x) = l.iter_mut().find(|x| x.name == name) {
                x.mute = on;
            }
        }
    }
    pub fn set_default(&mut self, name: &str) {
        let Some(n) = self.find(name).cloned() else { return };
        // With the equalizer or noise suppression in the way, "use this
        // device" points the effect at it and leaves the effect the default
        // (Audio.setDefaultSink); the shell keeps eqTarget from then on.
        if n.sink && self.eq_active() {
            if self.eq_out >= 0 {
                pa(&["move-sink-input", &self.eq_out.to_string(), &n.name]);
            }
            self.default_sink = n.name;
            return;
        }
        if !n.sink && self.ns_active() {
            if self.ns_in >= 0 {
                pa(&["move-source-output", &self.ns_in.to_string(), &n.name]);
            }
            self.default_source = n.name;
            return;
        }
        pa(&[if n.sink { "set-default-sink" } else { "set-default-source" }, &n.name]);
        if n.sink {
            self.default_sink = n.name;
        } else {
            self.default_source = n.name;
        }
    }
    pub fn set_port(&mut self, name: &str, port: &str) {
        let Some(n) = self.find(name).cloned() else { return };
        pa(&[if n.sink { "set-sink-port" } else { "set-source-port" }, &n.name, port]);
    }
    pub fn set_profile(&mut self, name: &str, profile: &str) {
        let Some(n) = self.find(name).cloned() else { return };
        if let Some(c) = self.cards.iter().find(|c| c["index"].as_i64() == Some(n.card)) {
            pa(&["set-card-profile", c["name"].as_str().unwrap_or(""), profile]);
        }
    }
    pub fn set_delay(&mut self, name: &str, ms: f64) {
        let Some(n) = self.find(name).cloned() else { return };
        match self.cards.iter().find(|c| c["index"].as_i64() == Some(n.card)) {
            Some(c) if !n.active_port.is_empty() => {
                pa(&["set-port-latency-offset", c["name"].as_str().unwrap_or(""), &n.active_port, &((ms * 1000.0).round() as i64).to_string()])
            }
            _ => self.last_error = "This device has no connector to set a delay on.".into(),
        }
    }
    pub fn test(&self, name: &str) {
        let n = name.to_string();
        std::thread::spawn(move || {
            for f in ["/usr/share/sounds/freedesktop/stereo/front-center.wav", "/usr/share/sounds/freedesktop/stereo/bell.oga", "/usr/share/sounds/freedesktop/stereo/complete.oga"] {
                if std::path::Path::new(f).exists() {
                    let _ = std::process::Command::new("paplay").args(["-d", &n, f]).status();
                    return;
                }
            }
        });
    }
    pub fn stream_volume(&mut self, p: &Prefs, index: i32, playing: bool, v: f64) {
        let v = v.clamp(0.0, if playing { Self::max_volume(p) } else { 1.5 });
        pa(&[if playing { "set-sink-input-volume" } else { "set-source-output-volume" }, &index.to_string(), &format!("{}%", (v * 100.0).round())]);
    }
    pub fn stream_mute(&mut self, index: i32, playing: bool, on: bool) {
        pa(&[if playing { "set-sink-input-mute" } else { "set-source-output-mute" }, &index.to_string(), if on { "1" } else { "0" }]);
    }
    pub fn stream_move(&mut self, index: i32, playing: bool, to: i32) {
        let devs = if playing { &self.sinks } else { &self.sources };
        if let Some(n) = devs.get(to as usize) {
            pa(&[if playing { "move-sink-input" } else { "move-source-output" }, &index.to_string(), &n.name]);
        }
    }
    pub fn restart(&mut self) {
        self.restarting = true;
        self.last_error.clear();
        let ok = std::process::Command::new("systemctl")
            .args(["--user", "restart", "wireplumber", "pipewire", "pipewire-pulse"])
            .stderr(std::process::Stdio::piped())
            .output();
        self.restarting = false;
        if let Ok(o) = ok {
            if !o.status.success() {
                self.last_error = String::from_utf8_lossy(&o.stderr).trim().lines().last().unwrap_or("").to_string();
            }
        }
    }
}
