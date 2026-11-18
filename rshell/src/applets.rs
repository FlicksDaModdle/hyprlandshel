//! Applets: shortcuts that open a small panel from the control center and
//! keep a state of their own, in place of running steps when pressed.
//!
//!   cycle       phases that count down one after another and go round again:
//!               a Pomodoro (Focus 25, Break 5), a 20-20-20 eye break, a plain
//!               countdown (one phase, one round)
//!   counter     a number you add to, with a goal; starts again each day
//!               (glasses of water, pages read)
//!   stopwatch   counts up
//!   tool        a layout of its own: text, inputs, choices, sliders, toggles,
//!               buttons and result displays (a unit converter, a quick
//!               lookup). A button runs steps; what the inputs hold reaches a
//!               `run` step as environment variables named by the widget's id
//!               (so `echo "$celsius"` is safe whatever was typed), and a
//!               button may `capture` what its last `run` printed into result
//!               displays (a line each; the last one takes the rest).
//!
//! Time is kept from the clock, not from how often this is asked, so a late
//! tick doesn't lose any. What each phase does when it starts or ends is
//! steps, as for any shortcut (`quiet` is the usual one: do not disturb
//! while it runs).
//!
//! The state lives in memory and in `$XDG_STATE_HOME/hyprshell/applets.json`,
//! so a restart of the shell doesn't lose the count or the place in a cycle.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Instant;

#[derive(Clone, Debug, PartialEq)]
pub struct Phase {
    pub name: String,
    pub seconds: f64,
    /// Steps run as it starts.
    pub steps: Vec<String>,
    /// A notification as it ends ("" for none).
    pub notify: String,
}

/// One thing on a tool's panel.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct Widget {
    /// text, input, choice, slider, toggle, button, output
    pub kind: String,
    pub id: String,
    pub label: String,
    /// A text's words (`{id}` is filled with that widget's value).
    pub text: String,
    pub options: Vec<String>,
    pub default: String,
    pub min: f64,
    pub max: f64,
    pub step: f64,
    pub unit: String,
    /// A button's steps.
    pub steps: Vec<String>,
    /// The output widget a button's last `run` fills ("" for none).
    pub capture: Vec<String>,
    pub primary: bool,
    pub placeholder: String,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Cycle { phases: Vec<Phase>, rounds: u32, quiet: bool },
    Counter { goal: i64, unit: String, step: i64 },
    Stopwatch,
    Tool { widgets: Vec<Widget> },
}

/// A widget's id is also the name of the environment variable its value reaches
/// a `run` step in, so: lowercase (every variable programs read from their
/// environment, PATH and HOME and LD_PRELOAD among them, is upper), and not the
/// few lowercase ones that are read (the proxies).
fn id_ok(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 32
        && s.chars().next().is_some_and(|c| c.is_ascii_lowercase())
        && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
        && !["http_proxy", "https_proxy", "ftp_proxy", "all_proxy", "no_proxy", "ignoreeof"].contains(&s)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Spec {
    pub kind: Kind,
}

impl Spec {
    pub fn from_json(v: &Value) -> Option<Spec> {
        let strings = |v: &Value| -> Vec<String> { v.as_array().into_iter().flatten().filter_map(|s| s.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect() };
        let kind = match v["kind"].as_str()? {
            "cycle" => {
                let phases: Vec<Phase> = v["phases"]
                    .as_array()?
                    .iter()
                    .filter_map(|p| {
                        let seconds = p["seconds"].as_f64().or_else(|| p["minutes"].as_f64().map(|m| m * 60.0))?;
                        (seconds >= 1.0).then(|| Phase {
                            name: p["name"].as_str().map(str::trim).filter(|n| !n.is_empty()).unwrap_or("Timer").to_string(),
                            seconds: seconds.min(24.0 * 3600.0),
                            steps: strings(&p["steps"]),
                            notify: p["notify"].as_str().unwrap_or("").trim().to_string(),
                        })
                    })
                    .collect();
                if phases.is_empty() {
                    return None;
                }
                Kind::Cycle { phases, rounds: v["rounds"].as_u64().unwrap_or(0).min(1000) as u32, quiet: v["quiet"].as_bool().unwrap_or(false) }
            }
            "counter" => Kind::Counter {
                goal: v["goal"].as_i64().unwrap_or(0).clamp(0, 1_000_000),
                unit: v["unit"].as_str().unwrap_or("").trim().to_string(),
                step: v["step"].as_i64().unwrap_or(1).clamp(1, 1_000_000),
            },
            "stopwatch" => Kind::Stopwatch,
            "tool" => {
                let mut widgets = Vec::new();
                for w in v["ui"].as_array()?.iter().take(16) {
                    let kind = w["type"].as_str()?.to_string();
                    if !["text", "input", "choice", "slider", "toggle", "button", "output"].contains(&kind.as_str()) {
                        continue;
                    }
                    let id = w["id"].as_str().unwrap_or("").to_string();
                    // What holds a value needs a name to be found by.
                    if matches!(kind.as_str(), "input" | "choice" | "slider" | "toggle" | "output") && !id_ok(&id) {
                        continue;
                    }
                    let f = |k: &str, d: f64| w[k].as_f64().unwrap_or(d);
                    widgets.push(Widget {
                        kind,
                        id,
                        label: w["label"].as_str().unwrap_or("").trim().to_string(),
                        text: w["text"].as_str().unwrap_or("").to_string(),
                        options: w["options"].as_array().into_iter().flatten().filter_map(|o| o.as_str()).map(|o| o.trim().to_string()).filter(|o| !o.is_empty()).take(12).collect(),
                        default: match &w["default"] {
                            Value::String(s) => s.clone(),
                            Value::Null => String::new(),
                            other => other.to_string(),
                        },
                        min: f("min", 0.0),
                        max: f("max", 100.0).max(f("min", 0.0)),
                        step: f("step", 1.0).max(0.000_001),
                        unit: w["unit"].as_str().unwrap_or("").to_string(),
                        steps: strings(&w["steps"]),
                        capture: match &w["capture"] {
                            Value::String(s) if !s.is_empty() => vec![s.clone()],
                            Value::Array(a) => a.iter().filter_map(|x| x.as_str()).map(String::from).filter(|x| !x.is_empty()).take(8).collect(),
                            _ => Vec::new(),
                        },
                        primary: w["primary"].as_bool().unwrap_or(false),
                        placeholder: w["placeholder"].as_str().unwrap_or("").to_string(),
                    });
                }
                if widgets.is_empty() {
                    return None;
                }
                Kind::Tool { widgets }
            }
            _ => return None,
        };
        Some(Spec { kind })
    }
}

/// A cycle's settings as the panel changes them (kept with the rest of its
/// state): the minutes of phase `i`, the rounds, and do-not-disturb. What the
/// shortcut says is used until one is set.
fn phase_secs(phases: &[Phase], i: usize, vars: &HashMap<String, String>) -> f64 {
    let base = phases.get(i).map(|p| p.seconds).unwrap_or(60.0);
    vars.get(&format!("_p{i}")).and_then(|v| v.parse::<f64>().ok()).filter(|m| *m >= 1.0 / 60.0).map(|m| (m * 60.0).min(24.0 * 3600.0)).unwrap_or(base)
}
fn rounds_of(base: u32, vars: &HashMap<String, String>) -> u32 {
    vars.get("_rounds").and_then(|v| v.parse::<f64>().ok()).map(|r| r.round().clamp(0.0, 1000.0) as u32).unwrap_or(base)
}
fn quiet_of(base: bool, vars: &HashMap<String, String>) -> bool {
    match vars.get("_quiet").map(String::as_str) {
        Some("true") => true,
        Some("false") => false,
        _ => base,
    }
}

/// What a tick or a press asks the shell to do.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    Run(Vec<String>),
    Notify(String, String),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    pub running: bool,
    pub phase: usize,
    /// Seconds left in the phase (a cycle), or gone by (a stopwatch).
    pub clock: f64,
    pub rounds_done: u32,
    pub count: i64,
    /// The day a counter counts (local, as y*10000+m*100+d).
    pub day: i64,
    /// A cycle begun and not finished or reset: paused still counts.
    pub active: bool,
    /// A tool's inputs and results, by widget id.
    pub vars: HashMap<String, String>,
}

/// What the panel and the tile show.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct View {
    pub big: String,
    pub sub: String,
    /// 0 to 1, or -1 for none.
    pub progress: f32,
    pub running: bool,
    /// (id, label, primary)
    pub buttons: Vec<(String, String, bool)>,
    /// For the tile: the short state ("Focus 12:30", "3/8").
    pub glance: String,
    /// A tool's widgets, as they are now (the other kinds have none).
    pub widgets: Vec<WidgetView>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct WidgetView {
    pub kind: String,
    pub id: String,
    pub label: String,
    /// A text's words with the values in, or an output's result.
    pub text: String,
    /// An input's or choice's value.
    pub value: String,
    pub options: Vec<String>,
    pub pick: i32,
    pub num: f32,
    pub min: f32,
    pub max: f32,
    pub step: f32,
    pub unit: String,
    pub on: bool,
    pub primary: bool,
    pub placeholder: String,
}

/// What pressing a tool's button asks to be run, off the shell's thread.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolRun {
    pub steps: Vec<String>,
    /// Every value the panel holds, by widget id.
    pub env: HashMap<String, String>,
    /// The output widget to put what the last `run` printed in.
    pub capture: Vec<String>,
}

/// `{id}` in a text filled with that widget's value.
pub fn fill(template: &str, vars: &HashMap<String, String>) -> String {
    let mut out = String::new();
    let mut rest = template;
    while let Some(a) = rest.find('{') {
        out.push_str(&rest[..a]);
        match rest[a..].find('}') {
            Some(b) => {
                let key = &rest[a + 1..a + b];
                out.push_str(vars.get(key).map(String::as_str).unwrap_or(""));
                rest = &rest[a + b + 1..];
            }
            None => {
                out.push_str(&rest[a..]);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

pub fn clock_text(secs: f64) -> String {
    let s = secs.max(0.0).ceil() as u64;
    if s >= 3600 {
        format!("{}:{:02}:{:02}", s / 3600, (s / 60) % 60, s % 60)
    } else {
        format!("{:02}:{:02}", s / 60, s % 60)
    }
}

fn today() -> i64 {
    let (y, m, d, ..) = hyprshell_day();
    y * 10000 + m * 100 + d
}

fn hyprshell_day() -> (i64, i64, i64) {
    // SAFETY: localtime_r fills the tm it is given.
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        (tm.tm_year as i64 + 1900, tm.tm_mon as i64 + 1, tm.tm_mday as i64)
    }
}

/// Every applet's state, and the clock it was last advanced by.
pub struct Applets {
    pub states: HashMap<String, State>,
    last: Instant,
    saved: String,
}

fn path() -> PathBuf {
    let state = std::env::var_os("XDG_STATE_HOME").filter(|s| !s.is_empty()).map(PathBuf::from).unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"));
    state.join("hyprshell/applets.json")
}

impl Applets {
    pub fn load() -> Self {
        let mut states = HashMap::new();
        if let Some(Value::Object(o)) = std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()) {
            for (id, v) in o {
                states.insert(
                    id,
                    State {
                        // A restart doesn't carry on counting by itself: it is paused where it was.
                        running: false,
                        phase: v["phase"].as_u64().unwrap_or(0) as usize,
                        clock: v["clock"].as_f64().unwrap_or(0.0),
                        rounds_done: v["roundsDone"].as_u64().unwrap_or(0) as u32,
                        count: v["count"].as_i64().unwrap_or(0),
                        day: v["day"].as_i64().unwrap_or(0),
                        active: v["active"].as_bool().unwrap_or(false),
                        vars: v["vars"].as_object().map(|o| o.iter().filter_map(|(k, x)| x.as_str().map(|s| (k.clone(), s.to_string()))).collect()).unwrap_or_default(),
                    },
                );
            }
        }
        Applets { states, last: Instant::now(), saved: String::new() }
    }

    fn save(&mut self) {
        let v: serde_json::Map<String, Value> = self
            .states
            .iter()
            .map(|(id, s)| (id.clone(), json!({ "phase": s.phase, "clock": s.clock, "roundsDone": s.rounds_done, "count": s.count, "day": s.day, "active": s.active, "vars": s.vars })))
            .collect();
        let text = Value::Object(v).to_string();
        if text == self.saved {
            return;
        }
        let p = path();
        if let Some(d) = p.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let tmp = p.with_extension("json.tmp");
        if std::fs::write(&tmp, &text).is_ok() && std::fs::rename(&tmp, &p).is_ok() {
            self.saved = text;
        }
    }

    pub fn state(&self, id: &str) -> State {
        self.states.get(id).cloned().unwrap_or_default()
    }

    /// Any applet counting now.
    pub fn any_running(&self) -> bool {
        self.states.values().any(|s| s.running)
    }

    /// Start a phase: its clock set, its steps asked for.
    fn begin(phases: &[Phase], st: &mut State, quiet: bool, out: &mut Vec<Effect>) {
        let Some(p) = phases.get(st.phase) else { return };
        st.clock = phase_secs(phases, st.phase, &st.vars);
        st.active = true;
        if st.phase == 0 && st.rounds_done == 0 && quiet {
            out.push(Effect::Run(vec!["set dnd true".into()]));
        }
        if !p.steps.is_empty() {
            out.push(Effect::Run(p.steps.clone()));
        }
    }

    fn finish(quiet: bool, out: &mut Vec<Effect>) {
        if quiet {
            out.push(Effect::Run(vec!["set dnd false".into()]));
        }
    }

    /// A press on one of the panel's buttons.
    pub fn act(&mut self, id: &str, spec: &Spec, name: &str, action: &str) -> Vec<Effect> {
        let mut out = Vec::new();
        let st = self.states.entry(id.to_string()).or_default();
        match &spec.kind {
            Kind::Cycle { phases, quiet: base_quiet, .. } => match action {
                "toggle" => {
                    let quiet = &quiet_of(*base_quiet, &st.vars);
                    if st.running {
                        st.running = false;
                    } else {
                        if !st.active || st.clock <= 0.0 {
                            st.phase = 0;
                            st.rounds_done = 0;
                            Applets::begin(phases, st, *quiet, &mut out);
                        }
                        st.running = true;
                        self.last = Instant::now();
                    }
                }
                "skip" if st.active => {
                    out.extend(Applets::advance(phases, spec, st, name));
                }
                "reset" => {
                    if st.active {
                        Applets::finish(quiet_of(*base_quiet, &st.vars), &mut out);
                    }
                    *st = State { count: st.count, day: st.day, vars: std::mem::take(&mut st.vars), ..State::default() };
                }
                _ => {}
            },
            Kind::Counter { goal, step, unit } => {
                let before = st.count;
                match action {
                    "plus" => st.count += step,
                    "minus" => st.count = (st.count - step).max(0),
                    "reset" => st.count = 0,
                    _ => {}
                }
                st.day = today();
                if *goal > 0 && before < *goal && st.count >= *goal {
                    out.push(Effect::Notify(name.to_string(), format!("Goal reached: {} {unit}", goal).trim().to_string()));
                }
            }
            Kind::Stopwatch => match action {
                "toggle" => {
                    st.running = !st.running;
                    st.active = true;
                    self.last = Instant::now();
                }
                "reset" => *st = State::default(),
                _ => {}
            },
            Kind::Tool { .. } => {}
        }
        self.save();
        out
    }

    /// A value a tool's widget holds now, or its default.
    fn tool_value(widgets: &[Widget], vars: &HashMap<String, String>, id: &str) -> String {
        vars.get(id).cloned().or_else(|| widgets.iter().find(|w| w.id == id).map(|w| w.default.clone())).unwrap_or_default()
    }

    /// A tool's input changed.
    pub fn tool_set(&mut self, id: &str, var: &str, value: &str) {
        let st = self.states.entry(id.to_string()).or_default();
        st.vars.insert(var.to_string(), value.chars().take(4096).collect());
        self.save();
    }

    /// What pressing the button at `index` of a tool asks for: its steps, and
    /// the values they can use.
    pub fn tool_press(&mut self, id: &str, spec: &Spec, index: usize) -> Option<ToolRun> {
        let Kind::Tool { widgets } = &spec.kind else { return None };
        let w = widgets.get(index).filter(|w| w.kind == "button")?;
        let st = self.states.entry(id.to_string()).or_default();
        let mut env = HashMap::new();
        for x in widgets.iter().filter(|x| !x.id.is_empty()) {
            env.insert(x.id.clone(), Applets::tool_value(widgets, &st.vars, &x.id));
        }
        Some(ToolRun { steps: w.steps.clone(), env, capture: w.capture.clone() })
    }

    /// What a button's run printed, into the outputs it names: all of it into
    /// one, or a line each into several.
    pub fn tool_done(&mut self, id: &str, vars: &[String], output: &str) {
        match vars {
            [] => {}
            [one] => self.tool_set(id, one, output.trim_end()),
            many => {
                // A line each; the last one takes whatever lines are left.
                let mut lines = output.lines();
                for (i, v) in many.iter().enumerate() {
                    if i + 1 == many.len() {
                        let rest: Vec<&str> = lines.by_ref().collect();
                        self.tool_set(id, v, rest.join("\n").trim_end());
                    } else {
                        self.tool_set(id, v, lines.next().unwrap_or("").trim());
                    }
                }
            }
        }
    }

    /// The next phase (or the end), and what it asks for.
    fn advance(phases: &[Phase], spec: &Spec, st: &mut State, name: &str) -> Vec<Effect> {
        let mut out = Vec::new();
        let Kind::Cycle { rounds: base_rounds, quiet: base_quiet, .. } = &spec.kind else { return out };
        let (rounds, quiet) = (&rounds_of(*base_rounds, &st.vars), &quiet_of(*base_quiet, &st.vars));
        let ended = &phases[st.phase.min(phases.len() - 1)];
        if !ended.notify.is_empty() {
            out.push(Effect::Notify(name.to_string(), ended.notify.clone()));
        }
        st.phase += 1;
        if st.phase >= phases.len() {
            st.phase = 0;
            st.rounds_done += 1;
            if *rounds > 0 && st.rounds_done >= *rounds {
                // All the rounds done.
                st.running = false;
                st.active = false;
                st.clock = 0.0;
                st.rounds_done = 0;
                Applets::finish(*quiet, &mut out);
                out.push(Effect::Notify(name.to_string(), "All rounds done".into()));
                return out;
            }
        }
        Applets::begin(phases, st, false, &mut out);
        out
    }

    /// Move the clocks on to now. Called about once a second.
    pub fn tick(&mut self, specs: &[(String, String, Spec)]) -> Vec<Effect> {
        let now = Instant::now();
        let dt = now.duration_since(self.last).as_secs_f64();
        self.last = now;
        let mut out = Vec::new();
        for (id, name, spec) in specs {
            let st = self.states.entry(id.clone()).or_default();
            match &spec.kind {
                Kind::Cycle { phases, .. } if st.running => {
                    let mut left = dt;
                    // A long gap (the machine slept) carries through as many phases as it covered.
                    let mut guard = 0;
                    while left > 0.0 && st.running && guard < 1000 {
                        guard += 1;
                        if st.clock > left {
                            st.clock -= left;
                            left = 0.0;
                        } else {
                            left -= st.clock;
                            st.clock = 0.0;
                            out.extend(Applets::advance(phases, spec, st, name));
                        }
                    }
                }
                Kind::Stopwatch if st.running => st.clock += dt,
                Kind::Counter { .. } => {
                    // A new day starts the count again.
                    let d = today();
                    if st.day != 0 && st.day != d {
                        st.count = 0;
                        st.day = d;
                    }
                }
                _ => {}
            }
        }
        // Forgotten applets (shortcuts since removed) don't linger.
        self.states.retain(|id, _| specs.iter().any(|(i, ..)| i == id));
        self.save();
        out
    }

    /// What to show for an applet now.
    pub fn view(&self, id: &str, spec: &Spec) -> View {
        let st = self.state(id);
        match &spec.kind {
            Kind::Cycle { phases, rounds: base_rounds, quiet: base_quiet } => {
                let p = &phases[st.phase.min(phases.len() - 1)];
                let rounds = &rounds_of(*base_rounds, &st.vars);
                let this = phase_secs(phases, st.phase.min(phases.len() - 1), &st.vars);
                let (big, progress) = if st.active { (clock_text(st.clock), (1.0 - st.clock / this).clamp(0.0, 1.0) as f32) } else { (clock_text(phase_secs(phases, 0, &st.vars)), 0.0) };
                // Its own settings: the minutes of each phase, the rounds, do not disturb.
                let slider = |id: String, label: String, value: f64, min: f64, max: f64, unit: &str| WidgetView {
                    kind: "slider".into(),
                    id,
                    label,
                    value: value.to_string(),
                    num: value as f32,
                    min: min as f32,
                    max: max as f32,
                    step: 1.0,
                    unit: unit.into(),
                    ..WidgetView::default()
                };
                let mut settings: Vec<WidgetView> = phases
                    .iter()
                    .enumerate()
                    .take(8)
                    .map(|(i, ph)| slider(format!("_p{i}"), format!("{} (minutes)", ph.name), (phase_secs(phases, i, &st.vars) / 60.0).round().max(1.0), 1.0, 180.0, " min"))
                    .collect();
                settings.push(slider("_rounds".into(), "Rounds (0 keeps going)".into(), *rounds as f64, 0.0, 12.0, ""));
                let quiet = quiet_of(*base_quiet, &st.vars);
                settings.push(WidgetView { kind: "toggle".into(), id: "_quiet".into(), label: "Do not disturb while it runs".into(), value: quiet.to_string(), on: quiet, ..WidgetView::default() });
                let round = if *rounds > 0 { format!(" · round {} of {}", st.rounds_done + 1, rounds) } else if st.rounds_done > 0 { format!(" · round {}", st.rounds_done + 1) } else { String::new() };
                let sub = if st.active { format!("{}{}{}", p.name, round, if st.running { "" } else { " · paused" }) } else { format!("{} next", phases[0].name) };
                View {
                    widgets: settings,
                    glance: if st.active { format!("{} {}", p.name, clock_text(st.clock)) } else { "ready".into() },
                    big,
                    sub,
                    progress,
                    running: st.running,
                    buttons: vec![
                        ("toggle".into(), if st.running { "Pause" } else if st.active { "Resume" } else { "Start" }.into(), true),
                        ("skip".into(), "Skip".into(), false),
                        ("reset".into(), "Reset".into(), false),
                    ],
                }
            }
            Kind::Counter { goal, unit, .. } => {
                let big = if *goal > 0 { format!("{} / {}", st.count, goal) } else { st.count.to_string() };
                View {
                    widgets: Vec::new(),
                    glance: if *goal > 0 { format!("{}/{}", st.count, goal) } else { st.count.to_string() },
                    big,
                    sub: if unit.is_empty() { "today".into() } else { format!("{unit} today") },
                    progress: if *goal > 0 { (st.count as f32 / *goal as f32).clamp(0.0, 1.0) } else { -1.0 },
                    running: *goal > 0 && st.count >= *goal,
                    buttons: vec![("minus".into(), "−".into(), false), ("plus".into(), "+".into(), true), ("reset".into(), "Reset".into(), false)],
                }
            }
            Kind::Tool { widgets } => {
                let val = |w: &Widget| Applets::tool_value(widgets, &st.vars, &w.id);
                let mut all: HashMap<String, String> = HashMap::new();
                for w in widgets.iter().filter(|w| !w.id.is_empty()) {
                    all.insert(w.id.clone(), val(w));
                }
                let views = widgets
                    .iter()
                    .map(|w| {
                        let value = if w.id.is_empty() { String::new() } else { val(w) };
                        WidgetView {
                            kind: w.kind.clone(),
                            id: w.id.clone(),
                            label: w.label.clone(),
                            text: if w.kind == "output" { value.clone() } else { fill(&w.text, &all) },
                            pick: w.options.iter().position(|o| *o == value).map(|i| i as i32).unwrap_or(-1),
                            num: value.parse::<f64>().unwrap_or(w.default.parse().unwrap_or(w.min)).clamp(w.min, w.max) as f32,
                            on: value == "true",
                            value,
                            options: w.options.clone(),
                            min: w.min as f32,
                            max: w.max as f32,
                            step: w.step as f32,
                            unit: w.unit.clone(),
                            primary: w.primary,
                            placeholder: w.placeholder.clone(),
                        }
                    })
                    .collect();
                View { glance: "tool".into(), progress: -1.0, widgets: views, ..View::default() }
            }
            Kind::Stopwatch => View {
                widgets: Vec::new(),
                glance: if st.active { clock_text(st.clock) } else { "ready".into() },
                big: clock_text(st.clock.floor()),
                sub: if st.running { "running" } else if st.active { "paused" } else { "ready" }.into(),
                progress: -1.0,
                running: st.running,
                buttons: vec![("toggle".into(), if st.running { "Pause" } else { "Start" }.into(), true), ("reset".into(), "Reset".into(), false)],
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pomodoro(rounds: u32) -> Spec {
        Spec::from_json(&json!({ "kind": "cycle", "rounds": rounds, "quiet": true, "phases": [
            { "name": "Focus", "minutes": 25, "notify": "Break time" },
            { "name": "Break", "seconds": 300, "notify": "Back to work", "steps": ["notify x"] }
        ] })).unwrap()
    }

    fn run(a: &mut Applets, spec: &Spec, secs: f64) -> Vec<Effect> {
        a.last = Instant::now() - std::time::Duration::from_secs_f64(secs);
        a.tick(&[("p".into(), "Pomodoro".into(), spec.clone())])
    }

    #[test]
    fn a_cycle_counts_down_goes_to_the_next_phase_and_finishes_its_rounds() {
        let spec = pomodoro(1);
        let mut a = Applets { states: HashMap::new(), last: Instant::now(), saved: "x".into() };
        let fx = a.act("p", &spec, "Pomodoro", "toggle");
        assert!(fx.contains(&Effect::Run(vec!["set dnd true".into()])));
        assert!(a.state("p").running);
        assert_eq!(a.view("p", &spec).big, "25:00");
        run(&mut a, &spec, 600.0);
        assert_eq!(a.view("p", &spec).big, "15:00");
        // Past the end of Focus: Break begins, and says so.
        let fx = run(&mut a, &spec, 900.0 + 10.0);
        assert!(fx.contains(&Effect::Notify("Pomodoro".into(), "Break time".into())));
        assert!(fx.contains(&Effect::Run(vec!["notify x".into()])));
        assert_eq!(a.state("p").phase, 1);
        // Past the end of Break, the only round: done, quiet off again.
        let fx = run(&mut a, &spec, 300.0);
        assert!(fx.contains(&Effect::Run(vec!["set dnd false".into()])));
        assert!(!a.state("p").running && !a.state("p").active);
    }

    #[test]
    fn a_long_gap_carries_through_several_phases() {
        let spec = pomodoro(0); // forever
        let mut a = Applets { states: HashMap::new(), last: Instant::now(), saved: "x".into() };
        a.act("p", &spec, "Pomodoro", "toggle");
        run(&mut a, &spec, 25.0 * 60.0 + 300.0 + 60.0); // a full round and a minute (the machine slept)
        let st = a.state("p");
        assert_eq!((st.phase, st.rounds_done), (0, 1));
        assert_eq!(a.view("p", &spec).big, "24:00");
    }

    #[test]
    fn pause_resume_reset() {
        let spec = pomodoro(0);
        let mut a = Applets { states: HashMap::new(), last: Instant::now(), saved: "x".into() };
        a.act("p", &spec, "P", "toggle");
        run(&mut a, &spec, 60.0);
        a.act("p", &spec, "P", "toggle"); // pause
        assert!(!a.state("p").running);
        run(&mut a, &spec, 600.0); // time passing while paused changes nothing
        assert_eq!(a.view("p", &spec).big, "24:00");
        assert_eq!(a.view("p", &spec).buttons[0].1, "Resume");
        let fx = a.act("p", &spec, "P", "reset");
        assert!(fx.contains(&Effect::Run(vec!["set dnd false".into()])));
        assert_eq!(a.view("p", &spec).big, "25:00");
    }

    #[test]
    fn a_counter_counts_to_its_goal_and_says_so_once() {
        let spec = Spec::from_json(&json!({ "kind": "counter", "goal": 2, "unit": "glasses" })).unwrap();
        let mut a = Applets { states: HashMap::new(), last: Instant::now(), saved: "x".into() };
        assert!(a.act("w", &spec, "Water", "plus").is_empty());
        let fx = a.act("w", &spec, "Water", "plus");
        assert_eq!(fx, vec![Effect::Notify("Water".into(), "Goal reached: 2 glasses".into())]);
        assert!(a.act("w", &spec, "Water", "plus").is_empty()); // past it: no second notice
        assert_eq!(a.view("w", &spec).big, "3 / 2");
        a.act("w", &spec, "Water", "minus");
        a.act("w", &spec, "Water", "reset");
        assert_eq!(a.view("w", &spec).big, "0 / 2");
    }

    #[test]
    fn a_stopwatch_runs_pauses_and_resets() {
        let spec = Spec::from_json(&json!({ "kind": "stopwatch" })).unwrap();
        let mut a = Applets { states: HashMap::new(), last: Instant::now(), saved: "x".into() };
        a.act("s", &spec, "S", "toggle");
        a.last = Instant::now() - std::time::Duration::from_secs(75);
        a.tick(&[("s".into(), "S".into(), spec.clone())]);
        assert_eq!(a.view("s", &spec).big, "01:15");
    }

    #[test]
    fn bad_specs_are_not_applets() {
        assert!(Spec::from_json(&json!({ "kind": "cycle", "phases": [] })).is_none());
        assert!(Spec::from_json(&json!({ "kind": "cycle", "phases": [{ "name": "x", "minutes": 0 }] })).is_none());
        assert!(Spec::from_json(&json!({ "kind": "teapot" })).is_none());
        assert!(Spec::from_json(&Value::Null).is_none());
        assert_eq!(clock_text(3725.0), "1:02:05");
    }
}

#[cfg(test)]
mod tool_tests {
    use super::*;

    fn converter() -> Spec {
        Spec::from_json(&json!({ "kind": "tool", "ui": [
            { "type": "text", "text": "Celsius to Fahrenheit" },
            { "type": "input", "id": "celsius", "label": "°C", "default": "20" },
            { "type": "choice", "id": "mode", "options": ["C to F", "F to C"], "default": "C to F" },
            { "type": "slider", "id": "n", "min": 0, "max": 10, "default": 3 },
            { "type": "toggle", "id": "round", "default": true },
            { "type": "button", "label": "Convert", "primary": true, "steps": ["run echo $celsius"], "capture": "result" },
            { "type": "output", "id": "result", "label": "Result" },
            { "type": "input", "label": "no id: dropped" },
            { "type": "teapot", "id": "x" }
        ] })).unwrap()
    }

    #[test]
    fn a_tool_keeps_widgets_that_make_sense_and_drops_the_rest() {
        let Kind::Tool { widgets } = &converter().kind else { panic!() };
        assert_eq!(widgets.len(), 7);
        assert!(widgets.iter().all(|w| w.kind != "teapot"));
        assert!(Spec::from_json(&json!({ "kind": "tool", "ui": [] })).is_none());
    }

    #[test]
    fn a_tool_shows_defaults_then_what_was_typed_and_fills_texts() {
        let spec = converter();
        let mut a = Applets { states: HashMap::new(), last: Instant::now(), saved: "x".into() };
        let v = a.view("t", &spec);
        let by = |v: &View, id: &str| v.widgets.iter().find(|w| w.id == id).cloned().unwrap();
        assert_eq!(by(&v, "celsius").value, "20");
        assert_eq!(by(&v, "mode").pick, 0);
        assert_eq!(by(&v, "n").num, 3.0);
        assert!(by(&v, "round").on);
        a.tool_set("t", "celsius", "37");
        a.tool_set("t", "mode", "F to C");
        let v = a.view("t", &spec);
        assert_eq!((by(&v, "celsius").value.as_str(), by(&v, "mode").pick), ("37", 1));
        assert_eq!(fill("{celsius} degrees, {nope}!", &[("celsius".to_string(), "37".to_string())].into_iter().collect()), "37 degrees, !");
    }

    #[test]
    fn a_button_gets_every_value_and_its_result_goes_to_the_output() {
        let spec = converter();
        let mut a = Applets { states: HashMap::new(), last: Instant::now(), saved: "x".into() };
        a.tool_set("t", "celsius", "37; rm -rf ~");
        let Kind::Tool { widgets } = &spec.kind else { panic!() };
        let at = widgets.iter().position(|w| w.kind == "button").unwrap();
        let run = a.tool_press("t", &spec, at).unwrap();
        // What was typed travels as a value, never as part of the command line.
        assert_eq!(run.steps, ["run echo $celsius"]);
        assert_eq!(run.env["celsius"], "37; rm -rf ~");
        assert_eq!((run.env["mode"].as_str(), run.env["n"].as_str()), ("C to F", "3"));
        assert_eq!(run.capture, ["result"]);
        // Several outputs take a line each.
        a.tool_done("t", &["result".to_string(), "other".to_string()], "one\ntwo\nthree\n");
        assert_eq!(a.state("t").vars["result"], "one");
        assert_eq!(a.state("t").vars["other"], "two\nthree"); // the last takes the rest
        a.tool_done("t", &run.capture, "98.6\n");
        assert_eq!(a.view("t", &spec).widgets.iter().find(|w| w.id == "result").unwrap().text, "98.6");
        // Not a button: nothing to run.
        assert!(a.tool_press("t", &spec, 0).is_none());
    }
}

#[cfg(test)]
mod settings_tests {
    use super::*;

    fn spec() -> Spec {
        Spec::from_json(&json!({ "kind": "cycle", "rounds": 0, "phases": [{ "name": "Focus", "minutes": 25 }, { "name": "Break", "minutes": 5 }] })).unwrap()
    }
    fn fresh() -> Applets {
        Applets { states: HashMap::new(), last: Instant::now(), saved: "x".into() }
    }

    #[test]
    fn every_timer_panel_has_settings_that_change_the_timer() {
        let spec = spec();
        let mut a = fresh();
        let v = a.view("p", &spec);
        let ids: Vec<&str> = v.widgets.iter().map(|w| w.id.as_str()).collect();
        assert_eq!(ids, ["_p0", "_p1", "_rounds", "_quiet"]);
        assert_eq!(v.widgets[0].num, 25.0);
        // Change Focus to 50 minutes and Break to 10 from the panel: the idle readout follows, and so does a run.
        a.tool_set("p", "_p0", "50");
        a.tool_set("p", "_p1", "10");
        assert_eq!(a.view("p", &spec).big, "50:00");
        a.act("p", &spec, "P", "toggle");
        assert_eq!(a.view("p", &spec).big, "50:00");
        a.last = Instant::now() - std::time::Duration::from_secs(50 * 60 + 5);
        a.tick(&[("p".into(), "P".into(), spec.clone())]);
        assert_eq!(a.state("p").phase, 1);
        assert_eq!(a.view("p", &spec).big, "09:55"); // the 10-minute break, 5 seconds in
    }

    #[test]
    fn rounds_and_do_not_disturb_can_be_set_in_the_panel_too() {
        let spec = spec();
        let mut a = fresh();
        a.tool_set("p", "_rounds", "1");
        a.tool_set("p", "_quiet", "true");
        let fx = a.act("p", &spec, "P", "toggle");
        assert!(fx.contains(&Effect::Run(vec!["set dnd true".into()])));
        a.last = Instant::now() - std::time::Duration::from_secs(25 * 60 + 5 * 60 + 1);
        let fx = a.tick(&[("p".into(), "P".into(), spec.clone())]);
        // One round, then done, and quiet off again.
        assert!(fx.contains(&Effect::Run(vec!["set dnd false".into()])));
        assert!(!a.state("p").active);
        // Reset keeps the settings.
        a.act("p", &spec, "P", "reset");
        assert_eq!(a.state("p").vars["_rounds"], "1");
    }
}
