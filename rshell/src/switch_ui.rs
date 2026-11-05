//! Alt+Tab (services/Switcher.qml): the windows most recently used first,
//! stepped through with the keybind's "altTab next / prev" while the
//! modifier is held, switched to when it is let go. Whether it is still
//! held is asked of Hyprland every 50 ms (hl.is_key_down, through
//! `hyprctl repl`), as the Quickshell shell does; the switcher's own
//! surface also sees the release once it has the keyboard.

use crate::{dock, glyphs, hypr, SwitchEntry, Switcher};
use slint::platform::software_renderer::MinimalSoftwareWindow;
use slint::platform::Key;
use slint::{ModelRc, SharedString, VecModel};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use std::time::{Duration, Instant};

pub enum Act {
    Key(String, bool),
    Released(String),
    Hover(i32),
    Pick(i32),
    Close(i32),
    Cancel,
}

#[derive(Clone)]
struct Win {
    address: String,
    minimised: bool,
}

pub struct Host {
    pub ui: Switcher,
    pub window: Rc<MinimalSoftwareWindow>,
    pub surface: Option<usize>,
    pub open: bool,
    pub shown: bool,
    wins: Vec<Win>,
    index: usize,
    show_at: Option<Instant>,
    settle_at: Option<Instant>,
    last_commit: Instant,
    polling: Option<Arc<AtomicBool>>,
    poll_rx: Option<Receiver<Option<bool>>>,
    broken: bool,
    mod_keys: [&'static str; 2],
    pub monitor: String,
}

fn key_is(text: &str, k: Key) -> bool {
    SharedString::from(k).as_str() == text
}

impl Host {
    pub fn new(queue: Rc<std::cell::RefCell<Vec<Act>>>) -> Host {
        let ui = Switcher::new().expect("the switcher");
        let window = crate::platform::take_adapter().expect("the switcher's window");
        {
            let q = queue.clone();
            ui.on_key(move |t, shift| {
                let t = t.as_str();
                let used = [
                    Key::Escape,
                    Key::Return,
                    Key::Tab,
                    Key::Backtab,
                    Key::LeftArrow,
                    Key::RightArrow,
                    Key::UpArrow,
                    Key::DownArrow,
                    Key::Home,
                    Key::End,
                    Key::Delete,
                ]
                .into_iter()
                .any(|k| key_is(t, k))
                    || t == " ";
                if used {
                    q.borrow_mut().push(Act::Key(t.to_string(), shift));
                }
                used
            });
        }
        macro_rules! on {
            ($set:ident, |$($a:ident),*| $act:expr) => {{
                let q = queue.clone();
                ui.$set(move |$($a),*| q.borrow_mut().push($act));
            }};
        }
        on!(on_released, |t| Act::Released(t.to_string()));
        on!(on_hover, |i| Act::Hover(i));
        on!(on_pick, |i| Act::Pick(i));
        on!(on_close_entry, |i| Act::Close(i));
        on!(on_cancel, | | Act::Cancel);
        Host {
            ui,
            window,
            surface: None,
            open: false,
            shown: false,
            wins: Vec::new(),
            index: 0,
            show_at: None,
            settle_at: None,
            last_commit: Instant::now() - Duration::from_secs(1),
            polling: None,
            poll_rx: None,
            broken: false,
            mod_keys: ["Alt_L", "Alt_R"],
            monitor: String::new(),
        }
    }

    /// The windows to list, as Switcher.build: by recent use, in the
    /// chosen scope, grouped per app if asked.
    fn build(&mut self, raw: &serde_json::Value, monitor: &str) -> Vec<SwitchEntry> {
        let scope = raw["altTabScope"].as_str().unwrap_or("workspace");
        let special = raw["altTabSpecial"].as_bool().unwrap_or(true);
        let group = raw["altTabGroup"].as_bool().unwrap_or(false);
        let all = hypr::json("j/clients");
        let (mon_id, ws) = dock::monitor(monitor);
        let mut list: Vec<&serde_json::Value> = all
            .as_array()
            .into_iter()
            .flatten()
            .filter(|c| c["mapped"] != false && c["class"].as_str().is_some_and(|s| !s.is_empty()))
            .filter(|c| {
                let name = c["workspace"]["name"].as_str().unwrap_or("");
                let id = c["workspace"]["id"].as_i64().unwrap_or(0);
                let minimised = name == dock::MINIMISED;
                let ok = match scope {
                    "all" => true,
                    "monitor" => c["monitor"].as_i64() == Some(mon_id),
                    _ => id == ws || minimised || (c["pinned"] == true && c["monitor"].as_i64() == Some(mon_id)),
                };
                ok && (special || !name.starts_with("special"))
            })
            .collect();
        list.sort_by_key(|c| c["focusHistoryID"].as_i64().unwrap_or(i64::MAX));
        let mut out: Vec<(SwitchEntry, Win, String, i64)> = Vec::new();
        for c in list {
            let cls = c["class"].as_str().unwrap_or("").to_string();
            if group {
                if let Some(e) = out.iter_mut().find(|e| e.2 == cls) {
                    e.0.count += 1;
                    continue;
                }
            }
            let label = dock::label_for(&cls);
            let title = c["title"].as_str().filter(|t| !t.is_empty()).map(str::to_string).unwrap_or_else(|| label.clone());
            let name = c["workspace"]["name"].as_str().unwrap_or("").to_string();
            let id = c["workspace"]["id"].as_i64().unwrap_or(0);
            let tag = name.strip_prefix("special:").map(str::to_string).unwrap_or_else(|| if id > 0 { id.to_string() } else { name.clone() });
            out.push((
                SwitchEntry { title: title.into(), label: label.into(), glyph: glyphs::glyph(crate::launcher::glyph_for_class(&cls)), tag: tag.into(), count: 1 },
                Win { address: c["address"].as_str().unwrap_or("").to_string(), minimised: name == dock::MINIMISED },
                cls,
                id,
            ));
        }
        // Workspace tags only when the windows aren't all on one.
        let mixed = out.first().is_some_and(|f| out.iter().any(|e| e.3 != f.3));
        self.ui.set_tags(raw["altTabWorkspaceTags"].as_bool().unwrap_or(true) && mixed);
        self.wins = out.iter().map(|e| e.1.clone()).collect();
        out.into_iter().map(|e| e.0).collect()
    }

    /// "altTab next" / "prev": opens it on the second most recent window
    /// (or the last), or moves along. Shown after the delay, unless the
    /// modifier is let go before then (a quick Alt+Tab just switches).
    pub fn step(&mut self, dir: i32, raw: &serde_json::Value, monitor: &str, us: f32) {
        if raw["altTabEnabled"].as_bool() == Some(false) {
            return;
        }
        if !self.open {
            if self.last_commit.elapsed() < Duration::from_millis(60) {
                return;
            }
            let entries = self.build(raw, monitor);
            if entries.is_empty() {
                return;
            }
            let n = entries.len();
            self.index = if n == 1 { 0 } else if dir > 0 { 1 } else { n - 1 };
            self.ui.set_entries(ModelRc::from(Rc::new(VecModel::from(entries))));
            self.ui.set_index(self.index as i32);
            self.ui.set_us(us);
            self.ui.set_k((raw["altTabSize"].as_f64().unwrap_or(100.0) / 100.0).clamp(0.6, 1.6) as f32);
            self.monitor = monitor.to_string();
            self.mod_keys = match raw["altTabMod"].as_str().unwrap_or("ALT").to_uppercase().as_str() {
                "SUPER" => ["Super_L", "Super_R"],
                "CTRL" => ["Control_L", "Control_R"],
                _ => ["Alt_L", "Alt_R"],
            };
            self.open = true;
            self.shown = false;
            let hold = raw["altTabHold"].as_bool().unwrap_or(true);
            if !hold || self.broken {
                self.show_at = Some(Instant::now());
            } else {
                self.show_at = Some(Instant::now() + Duration::from_millis(raw["altTabDelay"].as_u64().unwrap_or(100)));
                self.start_poll();
            }
            return;
        }
        if self.wins.is_empty() {
            return;
        }
        let n = self.wins.len() as i32;
        self.index = ((self.index as i32 + dir).rem_euclid(n)) as usize;
        self.ui.set_index(self.index as i32);
        self.show_at = Some(Instant::now());
    }

    fn start_poll(&mut self) {
        if let Some(p) = self.polling.take() {
            p.store(false, Ordering::Relaxed);
        }
        let flag = Arc::new(AtomicBool::new(true));
        let (tx, rx) = channel();
        let expr = self.mod_keys.iter().map(|k| format!("hl.is_key_down(\"{k}\")")).collect::<Vec<_>>().join(" or ");
        let f = flag.clone();
        std::thread::spawn(move || {
            while f.load(Ordering::Relaxed) {
                let out = std::process::Command::new("hyprctl").args(["repl", &expr]).output();
                let ans = out.ok().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
                let v = match ans.as_deref() {
                    Some("true") => Some(true),
                    Some("false") => Some(false),
                    _ => None,
                };
                if tx.send(v).is_err() || v != Some(true) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });
        self.polling = Some(flag);
        self.poll_rx = Some(rx);
    }

    fn release_seen(&mut self) {
        if self.open && self.settle_at.is_none() {
            self.settle_at = Some(Instant::now() + Duration::from_millis(70));
        }
    }

    /// Time passing: show it when its delay is up, switch once the
    /// modifier has been let go. True when it should now be on screen
    /// (the caller makes its surface); `commit` is then whether to close.
    pub fn tick(&mut self) -> (bool, bool) {
        let now = Instant::now();
        let answers: Vec<Option<bool>> = self.poll_rx.as_ref().map(|rx| rx.try_iter().collect()).unwrap_or_default();
        {
            for v in answers {
                match v {
                    Some(false) => self.release_seen(),
                    Some(true) => {}
                    None => {
                        // Can't tell: show it, and wait for Return, Esc or
                        // a click, as Switcher.qml does.
                        eprintln!("hyprshell-rs: can't tell whether the Alt+Tab modifier is held; waiting for Return or Esc");
                        self.broken = true;
                        self.show_at = Some(now);
                    }
                }
            }
        }
        let mut commit = false;
        if self.settle_at.is_some_and(|t| now >= t) {
            self.settle_at = None;
            commit = true;
        }
        if self.show_at.is_some_and(|t| now >= t) {
            self.show_at = None;
            self.shown = true;
        }
        (self.open && self.shown, commit)
    }

    pub fn next_due(&self) -> Option<Duration> {
        let now = Instant::now();
        [self.show_at, self.settle_at].into_iter().flatten().map(|t| t.saturating_duration_since(now)).min()
            .or(if self.polling.is_some() && self.open { Some(Duration::from_millis(50)) } else { None })
    }

    /// Switches to the chosen window and closes.
    pub fn commit(&mut self) {
        if !self.open {
            return;
        }
        let target = self.wins.get(self.index).cloned();
        self.close();
        self.last_commit = Instant::now();
        if let Some(w) = target {
            let ws = dock::monitor(&self.monitor).1;
            dock::focus(&w.address, w.minimised, ws);
        }
    }

    pub fn close(&mut self) {
        self.open = false;
        self.shown = false;
        self.show_at = None;
        self.settle_at = None;
        if let Some(p) = self.polling.take() {
            p.store(false, Ordering::Relaxed);
        }
        self.poll_rx = None;
        self.wins.clear();
    }

    fn close_entry(&mut self, i: usize) {
        let Some(w) = self.wins.get(i).cloned() else { return };
        dock::close(&w.address);
        self.wins.remove(i);
        let model = self.ui.get_entries();
        let mut rows: Vec<SwitchEntry> = (0..slint::Model::row_count(&model)).filter_map(|r| slint::Model::row_data(&model, r)).collect();
        if i < rows.len() {
            rows.remove(i);
        }
        if rows.is_empty() {
            self.close();
            return;
        }
        self.index = self.index.min(rows.len() - 1);
        self.ui.set_entries(ModelRc::from(Rc::new(VecModel::from(rows))));
        self.ui.set_index(self.index as i32);
    }

    /// What the switcher's surface reports.
    pub fn act(&mut self, a: Act) {
        let n = self.wins.len().max(1) as i32;
        let go = |s: &mut Self, d: i32| {
            s.index = ((s.index as i32 + d).rem_euclid(n)) as usize;
            s.ui.set_index(s.index as i32);
        };
        match a {
            Act::Key(t, shift) => {
                let t = t.as_str();
                if key_is(t, Key::Escape) {
                    self.close();
                } else if key_is(t, Key::Return) || t == " " {
                    self.commit();
                } else if key_is(t, Key::Tab) {
                    go(self, if shift { -1 } else { 1 });
                } else if key_is(t, Key::Backtab) || key_is(t, Key::LeftArrow) || key_is(t, Key::UpArrow) {
                    go(self, -1);
                } else if key_is(t, Key::RightArrow) || key_is(t, Key::DownArrow) {
                    go(self, 1);
                } else if key_is(t, Key::Home) {
                    self.index = 0;
                    self.ui.set_index(0);
                } else if key_is(t, Key::End) {
                    self.index = self.wins.len().saturating_sub(1);
                    self.ui.set_index(self.index as i32);
                } else if key_is(t, Key::Delete) {
                    self.close_entry(self.index);
                }
            }
            Act::Released(t) => {
                let t = t.as_str();
                let ours = match self.mod_keys[0] {
                    "Super_L" => key_is(t, Key::Meta),
                    "Control_L" => key_is(t, Key::Control),
                    _ => key_is(t, Key::Alt),
                };
                if ours {
                    self.release_seen();
                }
            }
            Act::Hover(i) => {
                if i >= 0 && (i as usize) < self.wins.len() {
                    self.index = i as usize;
                    self.ui.set_index(i);
                }
            }
            Act::Pick(i) => {
                if i >= 0 {
                    self.index = i as usize;
                }
                self.commit();
            }
            Act::Close(i) => self.close_entry(i.max(0) as usize),
            Act::Cancel => self.close(),
        }
    }
}
