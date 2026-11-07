//! The launcher on screen: its surface, its springs, what it lists, and
//! what each key and click does. launcher.rs knows the apps; this is the
//! part that drives ui/launcher.slint.

use crate::launcher::{self, Entry, Pinned, Recent};
use crate::spring::{Motion, Spring};
use crate::{extras, glyphs, LaunchItem, Launcher, RecentFile};
use slint::platform::software_renderer::MinimalSoftwareWindow;
use slint::platform::Key;
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use std::collections::HashMap;
use std::rc::Rc;

pub enum Act {
    Edited(String),
    Nav(String),
    RunPinned(i32),
    RunResult(i32),
    OpenRecent(i32),
    Hover(i32),
    ShowAll(bool),
    Page(i32),
    Close,
    TogglePower,
    Power(String),
}

/// What one row of the list stands for.
#[derive(Clone)]
enum Hit {
    App(usize),
    Command(&'static str),
    File { path: String, dir: bool },
    Calc(String),
}

/// What running a row asks of the rest of the shell.
pub enum Wants {
    Nothing,
    Close,
    /// A shell command by its Commands.qml key (theme, updates, lock …).
    Command(&'static str),
    /// A session action (lock, suspend …), from the power menu.
    Power(String),
}

pub struct Host {
    pub ui: Launcher,
    pub window: Rc<MinimalSoftwareWindow>,
    pub surface: Option<usize>,
    pub closing: bool,
    morph: Spring,
    morph_y: Spring,
    fade: Spring,
    entries: Vec<Entry>,
    icons: HashMap<String, slint::Image>,
    pinned: Vec<Pinned>,
    recent: Vec<Recent>,
    hits: Vec<Hit>,
    calc: Option<String>,
    files: Vec<(String, String, String, bool)>,
    query: String,
    show_all: bool,
    selected: i32,
    page: i32,
    per_page: usize,
    pub query_id: u64,
    pub wants_icons: bool,
}

fn model<T: Clone + 'static>(v: Vec<T>) -> ModelRc<T> {
    ModelRc::from(Rc::new(VecModel::from(v)))
}

fn key_is(text: &str, k: Key) -> bool {
    SharedString::from(k).as_str() == text
}

impl Host {
    pub fn new(queue: Rc<std::cell::RefCell<Vec<Act>>>) -> Host {
        let ui = Launcher::new().expect("the launcher");
        let window = crate::platform::take_adapter().expect("the launcher's window");
        macro_rules! on {
            ($set:ident, |$($a:ident),*| $act:expr) => {{
                let q = queue.clone();
                ui.$set(move |$($a),*| q.borrow_mut().push($act));
            }};
        }
        on!(on_edited, |t| Act::Edited(t.to_string()));
        on!(on_run_pinned, |i| Act::RunPinned(i));
        on!(on_run_result, |i| Act::RunResult(i));
        on!(on_open_recent, |i| Act::OpenRecent(i));
        on!(on_hover, |i| Act::Hover(i));
        on!(on_set_show_all, |b| Act::ShowAll(b));
        on!(on_set_page, |p| Act::Page(p));
        on!(on_dismiss, | | Act::Close);
        on!(on_toggle_power, | | Act::TogglePower);
        on!(on_power, |k| Act::Power(k.to_string()));
        {
            // Keys the search field doesn't keep. Answered at once (the
            // field needs to know), carried out with the rest.
            let q = queue.clone();
            let weak = ui.as_weak();
            ui.on_nav(move |t| {
                let Some(ui) = weak.upgrade() else { return false };
                let listing = !ui.get_query().is_empty() || ui.get_show_all();
                let t = t.as_str();
                let used = [Key::UpArrow, Key::DownArrow, Key::Return, Key::Escape, Key::Tab, Key::PageUp, Key::PageDown]
                    .into_iter()
                    .any(|k| key_is(t, k))
                    || (!listing && (key_is(t, Key::LeftArrow) || key_is(t, Key::RightArrow)));
                if used {
                    q.borrow_mut().push(Act::Nav(t.to_string()));
                }
                used
            });
        }
        Host {
            ui,
            window,
            surface: None,
            closing: false,
            morph: Spring::new(0.0),
            morph_y: Spring::new(0.0),
            fade: Spring::new(0.0),
            entries: Vec::new(),
            icons: HashMap::new(),
            pinned: Vec::new(),
            recent: Vec::new(),
            hits: Vec::new(),
            calc: None,
            files: Vec::new(),
            query: String::new(),
            show_all: false,
            selected: 0,
            page: 0,
            per_page: 9,
            query_id: 0,
            wants_icons: false,
        }
    }

    pub fn is_open(&self) -> bool {
        self.surface.is_some() && !self.closing
    }

    /// Sizes from theme.json, as Appearance.qml derives them.
    pub fn configure(&mut self, raw: &serde_json::Value, us: f32, user: &str) {
        let num = |k: &str, d: f64| raw[k].as_f64().unwrap_or(d);
        let zoom = num("launcherSize", 145.0).max(40.0) / 100.0;
        let stretch = |k: &str| num(k, 100.0).clamp(50.0, 220.0) / 100.0;
        let (wide, tall) = (stretch("launcherWide"), stretch("launcherTall"));
        let cols = ((3.0 * wide).round() as i32).clamp(3, 10);
        let rows = ((3.0 * tall).round() as i32).max(2);
        self.per_page = (cols * rows) as usize;
        let u = |px: f64| (px * us as f64).round().max(1.0);
        let near = u(num("dockGap", 16.0).clamp(0.0, 40.0)) + u(num("dockSize", 42.0) + 10.0) + 12.0;
        let ui = &self.ui;
        ui.set_zoom(zoom as f32);
        ui.set_panel_width((420.0 * zoom * wide).round() as f32);
        ui.set_panel_max((720.0 * zoom * tall).round() as f32);
        ui.set_columns(cols);
        ui.set_tile((60.0 * zoom).round() as f32);
        ui.set_title_size(num("launcherTitleSize", 13.0) as f32);
        ui.set_meta_size(num("launcherMetaSize", 11.0) as f32);
        ui.set_icon_size(((22.0 * zoom).round() * stretch("launcherIconScale")).round() as f32);
        ui.set_near_edge(near as f32);
        ui.set_user(user.into());
    }

    /// Fresh each time it opens: the apps (a new install shows at once),
    /// what's pinned, the recent files; an empty search.
    pub fn open(&mut self, raw: &serde_json::Value, m: &Motion, grows: bool) {
        self.entries = launcher::entries();
        self.wants_icons = self.entries.iter().any(|e| !e.icon.is_empty() && !self.icons.contains_key(&e.id));
        self.pinned = launcher::pinned(raw);
        self.recent = launcher::recent();
        self.query.clear();
        self.show_all = false;
        self.selected = 0;
        self.page = 0;
        self.calc = None;
        self.files.clear();
        self.ui.set_query("".into());
        self.ui.set_power_open(false);
        self.ui.set_grows(grows && m.springy && m.speed > 0.0);
        self.refresh();
        self.closing = false;
        if self.fade.value <= 0.05 {
            self.morph.snap(0.0);
            self.morph_y.snap(0.0);
            self.fade.snap(0.0);
        }
        self.morph.go(1.0, 400.0, 0.6, m);
        self.morph_y.go(1.0, 470.0, 0.8, m);
        self.fade.go(1.0, 320.0, 0.0, m);
        self.apply();
    }

    pub fn close(&mut self, m: &Motion) {
        if self.surface.is_none() || self.closing {
            return;
        }
        self.closing = true;
        self.morph.go(0.0, 300.0, 0.0, m);
        self.morph_y.go(0.0, 320.0, 0.0, m);
        self.fade.go(0.0, 140.0, 0.0, m);
    }

    pub fn moving(&self) -> bool {
        self.morph.moving || self.morph_y.moving || self.fade.moving
    }

    pub fn step(&mut self, dt: f64, m: &Motion) {
        for s in [&mut self.morph, &mut self.morph_y, &mut self.fade] {
            s.step(dt, m);
        }
        self.apply();
    }

    fn apply(&self) {
        self.ui.set_morph(self.morph.value as f32);
        self.ui.set_morph_y(self.morph_y.value as f32);
        self.ui.set_fade(self.fade.value as f32);
    }

    pub fn entries_for_icons(&self) -> Vec<Entry> {
        self.entries.iter().filter(|e| !e.icon.is_empty() && !self.icons.contains_key(&e.id)).cloned().collect()
    }

    pub fn add_icons(&mut self, list: Vec<(String, crate::art::Pixels)>) {
        for (id, px) in list {
            self.icons.insert(id, slint::Image::from_rgba8(px));
        }
        self.refresh();
    }

    pub fn calc_result(&mut self, query: &str, result: Option<String>) {
        if query.trim() == self.query.trim() {
            self.calc = result;
            self.refresh();
        }
    }

    pub fn file_results(&mut self, query: &str, list: Vec<(String, String, String, bool)>) {
        if query == self.query {
            self.files = list;
            self.refresh();
        }
    }

    fn item(&self, label: &str, about: &str, glyph: &str, icon: Option<&slint::Image>) -> LaunchItem {
        LaunchItem {
            label: label.into(),
            about: about.into(),
            glyph: glyphs::glyph(glyph),
            has_icon: icon.is_some(),
            icon: icon.cloned().unwrap_or_default(),
        }
    }

    /// The list, the page of pinned apps and the recent files, from the
    /// search as it stands. Ranked as Launcher.qml's appResults.
    fn refresh(&mut self) {
        let q = self.query.trim().to_lowercase();
        let mut hits: Vec<Hit> = Vec::new();
        if q.is_empty() {
            let mut all: Vec<(String, Hit)> = self.entries.iter().enumerate().map(|(i, e)| (e.name.to_lowercase(), Hit::App(i))).collect();
            all.extend(launcher::COMMANDS.iter().map(|c| (c.1.to_lowercase(), Hit::Command(c.0))));
            all.sort_by(|a, b| a.0.cmp(&b.0));
            hits = all.into_iter().map(|(_, h)| h).collect();
        } else {
            if let Some(c) = &self.calc {
                hits.push(Hit::Calc(c.clone()));
            }
            let mut scored: Vec<(u8, String, Hit)> = Vec::new();
            for (i, e) in self.entries.iter().enumerate() {
                if let Some(s) = launcher::score(&e.name, &e.about, &q) {
                    scored.push((s, e.name.to_lowercase(), Hit::App(i)));
                }
            }
            for c in launcher::COMMANDS.iter() {
                if let Some(s) = launcher::score(c.1, c.3, &q) {
                    scored.push((s, c.1.to_lowercase(), Hit::Command(c.0)));
                }
            }
            scored.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
            hits.extend(scored.into_iter().map(|(_, _, h)| h));
            hits.extend(self.files.iter().map(|(path, _, _, dir)| Hit::File { path: path.clone(), dir: *dir }));
        }
        let rows: Vec<LaunchItem> = hits
            .iter()
            .map(|h| match h {
                Hit::App(i) => {
                    let e = &self.entries[*i];
                    let glyph = crate::launcher::glyph_for_class(if e.class.is_empty() { &e.id } else { &e.class });
                    self.item(&e.name, &e.about, glyph, self.icons.get(&e.id))
                }
                Hit::Command(k) => {
                    let c = launcher::COMMANDS.iter().find(|c| c.0 == *k).expect("a listed command");
                    self.item(c.1, c.3, c.2, None)
                }
                Hit::File { path, dir } => {
                    let f = self.files.iter().find(|f| &f.0 == path);
                    let name = f.map(|f| f.1.as_str()).unwrap_or(path);
                    let where_ = f.map(|f| if f.2.is_empty() { "~".to_string() } else { format!("~/{}", f.2) }).unwrap_or_default();
                    self.item(name, &where_, launcher::file_glyph(name, *dir), None)
                }
                Hit::Calc(v) => self.item(
                    &format!("= {v}"),
                    &format!("{} · Enter copies it", self.query.trim()),
                    "calculator",
                    None,
                ),
            })
            .collect();
        let pages = self.pinned.len().div_ceil(self.per_page).max(1) as i32;
        self.page = self.page.clamp(0, pages - 1);
        let start = self.page as usize * self.per_page;
        let page: Vec<LaunchItem> = self.pinned[start.min(self.pinned.len())..(start + self.per_page).min(self.pinned.len())]
            .iter()
            .map(|p| self.item(&p.label, "", &p.icon, None))
            .collect();
        let recent: Vec<RecentFile> = self
            .recent
            .iter()
            .map(|r| RecentFile { name: r.name.clone().into(), when: launcher::relative(&r.modified).into(), glyph: glyphs::glyph(launcher::file_glyph(&r.name, false)) })
            .collect();
        let listing = !q.is_empty() || self.show_all;
        let count = if listing { rows.len() } else { page.len() } as i32;
        self.selected = self.selected.clamp(0, (count - 1).max(0));
        let title = if !q.is_empty() {
            format!("{} result{}", rows.len(), if rows.len() == 1 { "" } else { "s" })
        } else {
            "All apps".into()
        };
        self.hits = hits;
        let ui = &self.ui;
        ui.set_results(model(rows));
        ui.set_pinned(model(page));
        ui.set_page(self.page);
        ui.set_page_count(pages);
        ui.set_recent(model(recent));
        ui.set_list_title(title.into());
        ui.set_show_all(self.show_all);
        ui.set_selected(self.selected);
    }

    fn page_items(&self) -> usize {
        let start = self.page as usize * self.per_page;
        self.pinned.len().saturating_sub(start).min(self.per_page)
    }

    fn listing(&self) -> bool {
        !self.query.trim().is_empty() || self.show_all
    }

    fn run_hit(&mut self, i: usize) -> Wants {
        let Some(h) = self.hits.get(i).cloned() else { return Wants::Nothing };
        match h {
            Hit::App(i) => launcher::launch_entry(&self.entries[i]),
            Hit::Command(k) => return Wants::Command(k),
            Hit::File { path, dir } => {
                let abs = if path.starts_with('/') { path } else { format!("{}/{}", std::env::var("HOME").unwrap_or_default(), path) };
                if dir {
                    launcher::launch(&launcher::files_command(&abs), "");
                } else {
                    launcher::launch(&["xdg-open".into(), abs], "");
                }
            }
            Hit::Calc(v) => extras::spawn(&["wl-copy", "--", &v]),
        }
        Wants::Close
    }

    fn run_pinned(&mut self, i: usize) -> Wants {
        let Some(p) = self.pinned.get(self.page as usize * self.per_page + i).cloned() else { return Wants::Nothing };
        let argv = if p.exec.is_empty() { launcher::tile_command(&p.key) } else { Some(p.exec.clone()) };
        if let Some(a) = argv {
            launcher::launch(&a, "");
        }
        Wants::Close
    }

    /// One action from the UI; what it needs of the shell, if anything.
    pub fn act(&mut self, a: Act, daemon: &mut crate::daemon::Daemon) -> Wants {
        match a {
            Act::Edited(t) => {
                self.query = t;
                self.selected = 0;
                self.calc = None;
                self.files.clear();
                self.query_id += 1;
                let q = self.query.trim().to_string();
                if !q.is_empty() {
                    daemon.send(serde_json::json!({ "cmd": "calc", "id": self.query_id, "query": q }));
                    daemon.send(serde_json::json!({ "cmd": "fs-search", "id": self.query_id, "query": self.query, "limit": 6 }));
                }
                self.ui.set_power_open(false);
                self.refresh();
            }
            Act::Nav(k) => {
                let k = k.as_str();
                let listing = self.listing();
                let count = if listing { self.hits.len() } else { self.page_items() } as i32;
                let step = |s: &mut Self, d: i32| {
                    s.selected = (s.selected + d).clamp(0, (count - 1).max(0));
                    s.ui.set_selected(s.selected);
                };
                let cols = self.ui.get_columns();
                if key_is(k, Key::Escape) {
                    if self.ui.get_power_open() {
                        self.ui.set_power_open(false);
                    } else if !self.query.is_empty() {
                        self.ui.set_query("".into());
                        return self.act(Act::Edited(String::new()), daemon);
                    } else if self.show_all {
                        return self.act(Act::ShowAll(false), daemon);
                    } else {
                        return Wants::Close;
                    }
                } else if key_is(k, Key::Return) {
                    if listing {
                        if self.hits.is_empty() {
                            let q = self.query.trim().to_string();
                            if !q.is_empty() {
                                launcher::launch(&["sh".into(), "-c".into(), q], "");
                                return Wants::Close;
                            }
                        } else {
                            return self.run_hit(self.selected.max(0) as usize);
                        }
                    } else {
                        return self.run_pinned(self.selected.max(0) as usize);
                    }
                } else if key_is(k, Key::DownArrow) {
                    step(self, if listing { 1 } else { cols });
                } else if key_is(k, Key::UpArrow) {
                    step(self, if listing { -1 } else { -cols });
                } else if key_is(k, Key::Tab) || key_is(k, Key::RightArrow) {
                    step(self, 1);
                } else if key_is(k, Key::LeftArrow) {
                    step(self, -1);
                } else if key_is(k, Key::PageDown) {
                    if listing { step(self, 8) } else { return self.act(Act::Page(self.page + 1), daemon) }
                } else if key_is(k, Key::PageUp) {
                    if listing { step(self, -8) } else { return self.act(Act::Page(self.page - 1), daemon) }
                }
            }
            Act::RunPinned(i) => return self.run_pinned(i.max(0) as usize),
            Act::RunResult(i) => return self.run_hit(i.max(0) as usize),
            Act::OpenRecent(i) => {
                if let Some(r) = self.recent.get(i.max(0) as usize) {
                    launcher::launch(&["xdg-open".into(), r.path.clone()], "");
                    return Wants::Close;
                }
            }
            Act::Hover(i) => {
                if self.selected != i {
                    self.selected = i;
                    self.ui.set_selected(i);
                }
            }
            Act::ShowAll(b) => {
                self.show_all = b;
                self.selected = 0;
                self.refresh();
            }
            Act::Page(p) => {
                self.page = p;
                self.selected = 0;
                self.refresh();
            }
            Act::Close => return Wants::Close,
            Act::TogglePower => self.ui.set_power_open(!self.ui.get_power_open()),
            Act::Power(k) => return Wants::Power(k),
        }
        Wants::Nothing
    }
}
