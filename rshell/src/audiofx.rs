//! Sound effects the shell runs itself (services/AudioFx.qml), for
//! Settings → Sound:
//!
//!   equalizer          parametric, up to sixteen bands and a preamp, over
//!                      everything played (or the apps chosen). A PipeWire
//!                      filter-chain: a virtual output that becomes the
//!                      default and passes the sound on to the real device.
//!   noise suppression  RNNoise over the microphone the same way round: a
//!                      virtual input, fed from the real one, that becomes
//!                      the default.
//!   listen             the microphone through the output, to hear yourself
//!                      (pipewire-pulse's loopback module).
//!
//! Each runs only while this shell does. The chains are loaded into
//! hyprshell-daemon when it has the part (`fx`), or else run as a
//! `pipewire -c` process of their own. What this does is read from
//! theme.json (Settings writes it) and the daemon's sound snapshots; how it
//! is going is written to $XDG_RUNTIME_DIR/hyprshell/fx.json for Settings.
//! The gains move live from Settings itself (pw-cli set-param); a change in
//! what the chain is made of rebuilds it here.

#[path = "../../apps/kit/src/eqmath.rs"]
#[allow(dead_code)]
mod eqmath;

use crate::daemon::Daemon;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub const EQ_SINK: &str = "hyprshell_eq";
pub const EQ_OUT: &str = "hyprshell_eq_out";
pub const NS_SOURCE: &str = "hyprshell_ns";
pub const NS_IN: &str = "hyprshell_ns_in";

fn ours(name: &str) -> bool {
    [EQ_SINK, EQ_OUT, NS_SOURCE, NS_IN].contains(&name)
}

/// One chain: the equalizer or noise suppression.
#[derive(Default)]
struct Chain {
    /// "off", "starting", "on" or "error".
    status: String,
    error: String,
    /// Loaded (in the daemon, or as `proc`), and from what.
    loaded: bool,
    structure: String,
    proc: Option<Child>,
    started: Option<Instant>,
    /// Switched off: the device is let go a moment after the real one is
    /// the default again, never in the same instant.
    release_at: Option<Instant>,
    retries: u32,
    retry_at: Option<Instant>,
}

#[derive(Default)]
pub struct Fx {
    probed: bool,
    has_pipewire: bool,
    has_pw_cli: bool,
    rnnoise: String,
    /// The daemon has the `fx` part.
    fx_daemon: Option<bool>,
    eq: Chain,
    ns: Chain,
    // From the latest sound snapshot.
    up: bool,
    sinks: Vec<String>,
    sources: Vec<String>,
    default_sink: String,
    default_source: String,
    /// Playing streams: (PipeWire node id, app key, the sink it plays to).
    streams: Vec<(i64, String, String)>,
    /// Streams pointed at the equalizer, by node id.
    routed: HashMap<i64, bool>,
    // Listening.
    listen_module: i64,
    listen_source: String,
    last_written: String,
}

fn cache_dir() -> String {
    let base = std::env::var("XDG_CACHE_HOME").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| format!("{}/.cache", std::env::var("HOME").unwrap_or_default()));
    format!("{base}/hyprshell")
}
fn status_path() -> String {
    let run = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    format!("{run}/hyprshell/fx.json")
}
fn pactl(args: &[&str]) -> Option<String> {
    Command::new("pactl").args(args).stderr(Stdio::null()).output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
}
fn spawn_quiet(argv: &[&str]) {
    let _ = Command::new(argv[0]).args(&argv[1..]).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
}

impl Fx {
    pub fn new() -> Fx {
        let mut fx = Fx { listen_module: -1, ..Default::default() };
        fx.eq.status = "off".into();
        fx.ns.status = "off".into();
        fx.probe();
        fx
    }

    /// What this machine has; and listening left on by a shell since gone,
    /// taken away.
    fn probe(&mut self) {
        let have = |c: &str| Command::new("sh").args(["-c", &format!("command -v {c} >/dev/null 2>&1")]).status().is_ok_and(|s| s.success());
        self.has_pipewire = have("pipewire");
        self.has_pw_cli = have("pw-cli");
        let home = std::env::var("HOME").unwrap_or_default();
        let mut dirs: Vec<String> = std::env::var("LADSPA_PATH").unwrap_or_default().split(':').filter(|d| !d.is_empty()).map(str::to_string).collect();
        dirs.extend(["/usr/lib/ladspa".into(), "/usr/lib64/ladspa".into(), "/usr/local/lib/ladspa".into(), format!("{home}/.ladspa")]);
        self.rnnoise = dirs.iter().map(|d| format!("{d}/librnnoise_ladspa.so")).find(|p| std::path::Path::new(p).exists()).unwrap_or_default();
        if let Some(list) = pactl(&["-f", "json", "list", "modules"]) {
            if let Ok(Value::Array(ms)) = serde_json::from_str::<Value>(&list) {
                for m in ms.iter().filter(|m| m.to_string().contains("hyprshell-listen")) {
                    if let Some(i) = m["index"].as_i64() {
                        let _ = pactl(&["unload-module", &i.to_string()]);
                    }
                }
            }
        }
        self.probed = true;
    }

    fn eq_available(&self) -> bool {
        self.has_pipewire || self.fx_daemon == Some(true)
    }
    fn ns_available(&self) -> bool {
        self.eq_available() && !self.rnnoise.is_empty()
    }
    /// Where chains run: the daemon, once it said it has the part; a
    /// process of their own when it said it hasn't (or isn't there).
    fn in_daemon(&self) -> bool {
        self.fx_daemon == Some(true)
    }

    // ── what arrives ────────────────────────────────────────────────────
    /// A daemon event; true if anything here may need doing.
    pub fn event(&mut self, ev: &Value) -> bool {
        match ev["ev"].as_str() {
            Some("ready") => {
                self.fx_daemon = Some(ev["modules"]["fx"] == true);
                true
            }
            Some("exited") => {
                // Its chains went with it; loaded again when it's back.
                for c in [&mut self.eq, &mut self.ns] {
                    if self.fx_daemon == Some(true) && c.loaded {
                        c.loaded = false;
                        if c.status != "error" {
                            c.status = "starting".into();
                        }
                    }
                }
                true
            }
            Some("fx") if ev["loaded"] != true => {
                let c = if ev["key"] == "eq" { &mut self.eq } else { &mut self.ns };
                if let Some(e) = ev["error"].as_str().filter(|e| !e.is_empty()) {
                    if c.loaded {
                        c.status = "error".into();
                        c.error = e.into();
                        c.loaded = false;
                        if c.retries < 3 {
                            c.retry_at = Some(Instant::now() + Duration::from_secs(3));
                        }
                    }
                }
                true
            }
            Some("pa") => {
                self.up = ev["available"] == true;
                let names = |k: &str| ev[k].as_array().into_iter().flatten().filter(|n| n["monitor"] != true).filter_map(|n| n["name"].as_str().map(str::to_string)).collect::<Vec<_>>();
                self.sinks = names("sinks");
                self.sources = names("sources");
                self.default_sink = ev["defaultSink"].as_str().unwrap_or("").into();
                self.default_source = ev["defaultSource"].as_str().unwrap_or("").into();
                let by_index: HashMap<i64, String> =
                    ev["sinks"].as_array().into_iter().flatten().filter_map(|s| Some((s["index"].as_i64()?, s["name"].as_str()?.to_string()))).collect();
                self.streams = ev["sinkInputs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|s| {
                        let p = &s["properties"];
                        let id = p["object.id"].as_str().and_then(|x| x.parse().ok()).or(p["object.id"].as_i64())?;
                        let key = p["application.process.binary"].as_str().or(p["application.name"].as_str()).unwrap_or("").to_string();
                        let sink = s["sink"].as_i64().and_then(|i| by_index.get(&i).cloned()).unwrap_or_default();
                        Some((id, key, sink))
                    })
                    .collect();
                true
            }
            _ => false,
        }
    }

    /// From hyprshell.cmd: "fxListen <source>", "fxListen" (off),
    /// "fxRetry eq|ns".
    pub fn command(&mut self, name: &str, arg: &str) {
        match name {
            "fxListen" => self.listen(arg),
            "fxRetry" => {
                let c = if arg == "ns" { &mut self.ns } else { &mut self.eq };
                c.error.clear();
                c.retries = 0;
                if c.status == "error" {
                    c.status = "off".into();
                }
                c.structure.clear();
                c.loaded = false;
            }
            _ => {}
        }
        self.write_status();
    }

    // ── keeping it as Settings says ────────────────────────────────────
    /// Brings what runs in line with theme.json; called on each sound
    /// snapshot, fx event and once a second.
    pub fn sync(&mut self, prefs: &Value, daemon: &mut Daemon) {
        if !self.probed {
            return;
        }
        let s = |k: &str| prefs[k].as_str().unwrap_or("").to_string();
        let b = |k: &str| prefs[k] == true;
        let f = |k: &str, d: f64| prefs[k].as_f64().unwrap_or(d);
        let mut bands = eqmath::parse(&s("peqBands"));
        // The ten-band equalizer this replaced: its gains become bands once.
        if s("peqBands").is_empty() || (s("peqBands") == "[]" && !eqmath::from_graphic(&s("eqGains")).is_empty()) {
            let old = eqmath::from_graphic(&s("eqGains"));
            if prefs.is_object() && (!old.is_empty() || s("peqBands").is_empty()) {
                crate::theme::set("peqBands", json!(eqmath::store(&old)));
                if !old.is_empty() {
                    crate::theme::set("eqGains", json!("0,0,0,0,0,0,0,0,0,0"));
                    if s("eqPreset") == "Flat" {
                        crate::theme::set("eqPreset", json!("Custom"));
                    }
                }
                bands = old;
            }
        }
        let now = Instant::now();

        // ── the equalizer ──
        let eq_wanted = b("eqEnabled") && self.eq_available() && self.up;
        let eq_node = self.sinks.iter().any(|n| n == EQ_SINK);
        let per_app = s("eqScope") == "apps";
        let target = s("eqTarget");
        let real_sink = self.sinks.iter().find(|n| **n == target).or_else(|| self.sinks.iter().find(|n| !ours(n))).cloned();
        if eq_wanted {
            self.eq.release_at = None;
            // Remember the device it goes in front of.
            if self.default_sink != EQ_SINK && !self.default_sink.is_empty() && !ours(&self.default_sink) && target != self.default_sink && (!eq_node || per_app) {
                crate::theme::set("eqTarget", json!(self.default_sink));
            }
            let structure = eqmath::structure(&bands);
            let retry_due = self.eq.retry_at.is_some_and(|t| now >= t);
            if (!self.eq.loaded || self.eq.structure != structure) && (self.eq.status != "error" || retry_due) {
                if retry_due {
                    self.eq.retries += 1;
                    self.eq.retry_at = None;
                }
                let args = eqmath::eq_args(&bands, f("eqPreamp", 0.0), &s("eqTarget"), EQ_SINK, EQ_OUT);
                self.load("eq", &args, daemon);
                self.eq.structure = structure;
            }
            if eq_node {
                if self.eq.status != "on" {
                    self.eq.retries = 0;
                }
                self.eq.status = "on".into();
                self.eq.error.clear();
                if per_app {
                    // Only the chosen apps go through it: the device stays
                    // the default.
                    if self.default_sink == EQ_SINK {
                        if let Some(r) = &real_sink {
                            let _ = pactl(&["set-default-sink", r]);
                        }
                    }
                } else if self.default_sink != EQ_SINK {
                    let _ = pactl(&["set-default-sink", EQ_SINK]);
                }
            } else if self.eq.status == "starting" && self.eq.started.is_some_and(|t| now.duration_since(t) > Duration::from_secs(8)) {
                // Running but no device: PipeWire made nothing of it.
                self.eq.status = "error".into();
                self.eq.error = "PipeWire started the equalizer but no device appeared.".into();
            }
        } else if self.eq.loaded {
            // Off: the real device first, the equalizer's device a moment
            // after.
            if self.default_sink == EQ_SINK {
                if let Some(r) = &real_sink {
                    let _ = pactl(&["set-default-sink", r]);
                }
            }
            let at = *self.eq.release_at.get_or_insert(now + Duration::from_millis(900));
            if now >= at || !eq_node {
                self.unload("eq", daemon);
            }
        } else if self.eq.status != "error" || !b("eqEnabled") {
            self.eq.status = "off".into();
            if !b("eqEnabled") {
                self.eq.error.clear();
            }
        }
        // Only some apps: their streams pointed at it one by one.
        let routing = eq_wanted && per_app && eq_node;
        let apps: Vec<String> = serde_json::from_str(&s("eqApps")).unwrap_or_default();
        self.route(routing, &apps);

        // ── noise suppression ──
        let ns_wanted = b("nsEnabled") && self.ns_available() && self.up;
        let ns_node = self.sources.iter().any(|n| n == NS_SOURCE);
        let ns_target = s("nsTarget");
        let real_source = self.sources.iter().find(|n| **n == ns_target).or_else(|| self.sources.iter().find(|n| !ours(n))).cloned();
        if ns_wanted {
            if self.default_source != NS_SOURCE && !self.default_source.is_empty() && !ours(&self.default_source) && ns_target != self.default_source && !ns_node {
                crate::theme::set("nsTarget", json!(self.default_source));
            }
            let retry_due = self.ns.retry_at.is_some_and(|t| now >= t);
            if !self.ns.loaded && (self.ns.status != "error" || retry_due) {
                if retry_due {
                    self.ns.retries += 1;
                    self.ns.retry_at = None;
                }
                let args = eqmath::ns_args(&self.rnnoise, f("nsThreshold", 50.0), &ns_target, NS_IN, NS_SOURCE);
                self.load("ns", &args, daemon);
            }
            if ns_node {
                self.ns.status = "on".into();
                self.ns.error.clear();
                if self.default_source != NS_SOURCE {
                    let _ = pactl(&["set-default-source", NS_SOURCE]);
                }
            } else if self.ns.status == "starting" && self.ns.started.is_some_and(|t| now.duration_since(t) > Duration::from_secs(8)) {
                self.ns.status = "error".into();
                self.ns.error = "PipeWire started noise suppression but no microphone appeared — is the RNNoise plugin the LADSPA one?".into();
            }
        } else if self.ns.loaded {
            if self.default_source == NS_SOURCE {
                if let Some(r) = &real_source {
                    let _ = pactl(&["set-default-source", r]);
                }
            }
            self.unload("ns", daemon);
        } else if self.ns.status != "error" || !b("nsEnabled") {
            self.ns.status = "off".into();
            if !b("nsEnabled") {
                self.ns.error.clear();
            }
        }

        // A process of its own that has gone.
        for (key, c) in [("eq", &mut self.eq), ("ns", &mut self.ns)] {
            if let Some(p) = c.proc.as_mut() {
                if let Ok(Some(code)) = p.try_wait() {
                    let mut err = String::new();
                    if let Some(mut e) = p.stderr.take() {
                        use std::io::Read;
                        let _ = e.read_to_string(&mut err);
                    }
                    c.proc = None;
                    c.loaded = false;
                    c.status = "error".into();
                    c.error = err.lines().filter(|l| !l.trim().is_empty()).last().map(str::to_string).unwrap_or_else(|| format!("pipewire exited {code}"));
                    let _ = key;
                }
            }
        }
        self.write_status();
    }

    fn load(&mut self, key: &str, args: &str, daemon: &mut Daemon) {
        let c = if key == "eq" { &mut self.eq } else { &mut self.ns };
        c.status = "starting".into();
        c.error.clear();
        c.started = Some(Instant::now());
        c.loaded = true;
        if self.fx_daemon == Some(true) {
            daemon.send(json!({ "cmd": "fx-load", "key": key, "args": args }));
            return;
        }
        // A process of its own: the configuration written, and it becomes
        // the filter.
        if let Some(mut p) = c.proc.take() {
            let _ = p.kill();
            let _ = p.wait();
        }
        let file = format!("{}/{}.conf", cache_dir(), if key == "eq" { "equalizer" } else { "noise-suppression" });
        // It goes when the shell does (the shell is stopped, not asked).
        use std::os::unix::process::CommandExt;
        let mut cmd = Command::new("sh");
        unsafe {
            cmd.pre_exec(|| {
                libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
                Ok(())
            });
        }
        c.proc = cmd
            .args(["-c", "mkdir -p \"$(dirname \"$1\")\" && printf '%s' \"$2\" > \"$1\" && exec pipewire -c \"$1\"", "sh", &file, &eqmath::conf(args)])
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .ok();
    }

    fn unload(&mut self, key: &str, daemon: &mut Daemon) {
        let in_daemon = self.in_daemon();
        let c = if key == "eq" { &mut self.eq } else { &mut self.ns };
        if in_daemon {
            daemon.send(json!({ "cmd": "fx-unload", "key": key }));
        }
        if let Some(mut p) = c.proc.take() {
            let _ = p.kill();
            let _ = p.wait();
        }
        c.loaded = false;
        c.structure.clear();
        c.release_at = None;
        c.status = "off".into();
    }

    /// AudioFx.route: the chosen apps' streams to the equalizer
    /// (target.object, which WirePlumber follows and remembers per app),
    /// everything else let go to follow the default.
    fn route(&mut self, routing: bool, apps: &[String]) {
        let mut next = HashMap::new();
        for (id, key, sink) in self.streams.clone() {
            let want = routing && !key.is_empty() && apps.contains(&key);
            let on = self.routed.get(&id) == Some(&true) || sink == EQ_SINK;
            if want {
                if self.routed.get(&id) != Some(&true) {
                    spawn_quiet(&["pw-metadata", &id.to_string(), "target.object", EQ_SINK]);
                }
                next.insert(id, true);
            } else if on && (routing || self.routed.contains_key(&id)) {
                spawn_quiet(&["pw-metadata", "-d", &id.to_string(), "target.object"]);
            }
        }
        self.routed = next;
    }

    /// Listening to a microphone on (its name) or off ("").
    fn listen(&mut self, source: &str) {
        if self.listen_module >= 0 {
            let _ = pactl(&["unload-module", &self.listen_module.to_string()]);
            self.listen_module = -1;
            self.listen_source.clear();
        }
        if source.is_empty() {
            return;
        }
        let src = format!("source={source}");
        if let Some(i) = pactl(&[
            "load-module",
            "module-loopback",
            &src,
            "latency_msec=40",
            "source_dont_move=true",
            "sink_input_properties=application.name=hyprshell-listen",
            "source_output_properties=application.name=hyprshell-listen",
        ])
        .and_then(|o| o.trim().parse::<i64>().ok())
        {
            self.listen_module = i;
            self.listen_source = source.into();
        }
    }

    /// How it's going, for Settings.
    fn write_status(&mut self) {
        let v = json!({
            "eq": { "status": self.eq.status, "error": self.eq.error, "available": self.eq_available() },
            "ns": { "status": self.ns.status, "error": self.ns.error, "available": self.ns_available() },
            "pwCli": self.has_pw_cli,
            "pipewire": self.has_pipewire,
            "rnnoise": !self.rnnoise.is_empty(),
            "listen": { "module": self.listen_module, "source": self.listen_source },
            "shell": std::process::id(),
        })
        .to_string();
        if v != self.last_written {
            let p = status_path();
            if let Some(d) = std::path::Path::new(&p).parent() {
                let _ = std::fs::create_dir_all(d);
            }
            let tmp = format!("{p}.tmp");
            if std::fs::write(&tmp, &v).is_ok() {
                let _ = std::fs::rename(&tmp, &p);
            }
            self.last_written = v;
        }
    }
}
