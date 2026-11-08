//! The overview on screen (Overview.qml), Super+Tab: what it lists — each workspace
//! with its windows, placed to scale on a card of the monitor's shape — and what
//! a click, a drag or a key does. ui/overview.slint draws it.

use crate::{dock, glyphs, hypr, launcher, OvWin, OvWs, OverviewWin};
use slint::platform::software_renderer::MinimalSoftwareWindow;
use slint::{ComponentHandle, Image, ModelRc, VecModel};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

pub enum Act {
    Focus(i32),
    Close(i32),
    FocusWs(i32),
    Move(i32, i32),
    Cancel,
}

#[derive(Clone)]
struct Client {
    address: String,
    stable: String,
    class: String,
    ws: i64,
    at: (f64, f64),
    size: (f64, f64),
    minimised: bool,
    active: bool,
}

pub struct Host {
    pub ui: OverviewWin,
    pub window: Rc<MinimalSoftwareWindow>,
    pub surface: Option<usize>,
    pub open: bool,
    clients: Vec<Client>,
    /// (id, name, focused, the indexes of its windows in `clients`)
    spaces: Vec<(i64, String, bool, Vec<usize>)>,
    mon: (f64, f64, f64, f64),
    us: f32,
    pictures: HashMap<String, Image>,
}

impl Host {
    pub fn new(queue: Rc<RefCell<Vec<Act>>>) -> Host {
        let ui = OverviewWin::new().expect("the overview");
        let window = crate::platform::take_adapter().expect("the overview's window");
        let q = queue.clone();
        ui.on_focus_window(move |i| q.borrow_mut().push(Act::Focus(i)));
        let q = queue.clone();
        ui.on_close_window(move |i| q.borrow_mut().push(Act::Close(i)));
        let q = queue.clone();
        ui.on_focus_ws(move |i| q.borrow_mut().push(Act::FocusWs(i)));
        let q = queue.clone();
        ui.on_move_window(move |i, w| q.borrow_mut().push(Act::Move(i, w)));
        let q = queue;
        ui.on_cancel(move || q.borrow_mut().push(Act::Cancel));
        Host { ui, window, surface: None, open: false, clients: Vec::new(), spaces: Vec::new(), mon: (0.0, 0.0, 1920.0, 1080.0), us: 1.0, pictures: HashMap::new() }
    }

    /// Reads the workspaces and windows; the stableIds to ask pictures for.
    pub fn open(&mut self, monitor: &str, us: f32, slots: &[(i64, bool)]) -> Vec<String> {
        self.us = us;
        // The monitor's own shape, in logical pixels (Overview.qml's monitorW/H).
        let mons = hypr::json("j/monitors");
        let m = mons.as_array().and_then(|a| a.iter().find(|m| m["name"] == monitor).or(a.first()));
        if let Some(m) = m {
            let scale = m["scale"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0);
            let turned = m["transform"].as_i64().unwrap_or(0) % 2 == 1;
            let (w, h) = (m["width"].as_f64().unwrap_or(1920.0), m["height"].as_f64().unwrap_or(1080.0));
            let (w, h) = if turned { (h, w) } else { (w, h) };
            self.mon = (m["x"].as_f64().unwrap_or(0.0), m["y"].as_f64().unwrap_or(0.0), (w / scale).max(1.0), (h / scale).max(1.0));
        }
        let active = hypr::json("j/activewindow")["address"].as_str().unwrap_or("").to_string();
        self.clients = hypr::json("j/clients")
            .as_array()
            .into_iter()
            .flatten()
            .filter(|c| c["mapped"] != false && c["class"].as_str().is_some_and(|s| !s.is_empty()))
            .map(|c| Client {
                address: c["address"].as_str().unwrap_or("").to_string(),
                stable: c["stableId"].as_str().unwrap_or("").to_string(),
                class: c["class"].as_str().unwrap_or("").to_string(),
                ws: c["workspace"]["id"].as_i64().unwrap_or(0),
                at: (c["at"][0].as_f64().unwrap_or(0.0), c["at"][1].as_f64().unwrap_or(0.0)),
                size: (c["size"][0].as_f64().unwrap_or(0.0), c["size"][1].as_f64().unwrap_or(0.0)),
                minimised: c["workspace"]["name"].as_str() == Some(dock::MINIMISED),
                active: c["address"].as_str() == Some(active.as_str()),
            })
            .collect();
        let names = hypr::json("j/workspaces");
        self.spaces = slots
            .iter()
            .map(|(id, focused)| {
                let named = names.as_array().and_then(|a| a.iter().find(|w| w["id"].as_i64() == Some(*id))).and_then(|w| w["name"].as_str()).filter(|n| *n != id.to_string()).map(str::to_string);
                let wins = self.clients.iter().enumerate().filter(|(_, c)| c.ws == *id).map(|(i, _)| i).collect();
                (*id, named.unwrap_or_else(|| format!("Workspace {id}")), *focused, wins)
            })
            .collect();
        self.ui.set_us(us);
        self.ui.set_mon_w(self.mon.2 as f32);
        self.ui.set_mon_h(self.mon.3 as f32);
        self.ui.set_new_ws(self.spaces.iter().map(|s| s.0).max().unwrap_or(0) as i32 + 1);
        self.ui.set_drag_active(false);
        self.open = true;
        self.rebuild();
        self.clients.iter().filter(|c| !c.stable.is_empty()).map(|c| c.stable.clone()).collect()
    }

    fn rebuild(&mut self) {
        let cw = (312.0 * self.us as f64).round();
        let sx = cw / self.mon.2;
        let sy = (cw * self.mon.3 / self.mon.2).round() / self.mon.3;
        let spaces: Vec<OvWs> = self
            .spaces
            .iter()
            .map(|(id, name, focused, wins)| {
                let rows: Vec<OvWin> = wins
                    .iter()
                    .map(|i| {
                        let c = &self.clients[*i];
                        let pic = self.pictures.get(&c.stable);
                        OvWin {
                            idx: *i as i32,
                            px: ((c.at.0 - self.mon.0) * sx).round() as f32,
                            py: ((c.at.1 - self.mon.1) * sy).round() as f32,
                            pw: (c.size.0 * sx).round() as f32,
                            ph: (c.size.1 * sy).round() as f32,
                            label: dock::label_for(&c.class).into(),
                            glyph: glyphs::glyph(launcher::glyph_for_class(&c.class)),
                            thumb: pic.cloned().unwrap_or_default(),
                            has_thumb: pic.is_some(),
                            active: c.active,
                        }
                    })
                    .collect();
                OvWs { id: *id as i32, name: name.clone().into(), focused: *focused, count: rows.len() as i32, wins: ModelRc::new(VecModel::from(rows)) }
            })
            .collect();
        self.ui.set_spaces(ModelRc::new(VecModel::from(spaces)));
    }

    /// A window's picture has come.
    pub fn picture(&mut self, id: &str, img: Image) {
        self.pictures.insert(id.to_string(), img);
        if self.open && self.clients.iter().any(|c| c.stable == id) {
            self.rebuild();
        }
    }

    pub fn close(&mut self) {
        self.open = false;
    }

    pub fn client(&self, i: i32) -> Option<(String, bool, i64)> {
        self.clients.get(i as usize).map(|c| (c.address.clone(), c.minimised, c.ws))
    }

    /// The workspace shown now, for focusing a window from another.
    pub fn current_ws(&self) -> i64 {
        self.spaces.iter().find(|s| s.2).map(|s| s.0).unwrap_or(1)
    }
}
