//! The dock's side of things (modules/dock/Dock.qml): the windows Hyprland
//! has, which pinned app each belongs to, the tiles that makes, and what
//! clicking one does: focus, cycle, minimise, launch, close; pin and unpin.

use crate::hypr;
use crate::launcher::{self, Pinned};
use serde_json::Value;

/// Where minimised windows wait, as Compositor.qml keeps them.
pub const MINIMISED: &str = "special:minimized";

#[derive(Clone)]
pub struct Client {
    pub address: String,
    pub class: String,
    pub workspace: i64,
    pub minimised: bool,
    pub monitor: i64,
    pub pinned: bool,
    pub fullscreen: i64,
}

pub fn clients() -> Vec<Client> {
    hypr::json("j/clients")
        .as_array()
        .into_iter()
        .flatten()
        .filter(|c| c["mapped"] != false)
        .map(|c| Client {
            address: c["address"].as_str().unwrap_or("").to_string(),
            class: c["class"].as_str().unwrap_or("").to_string(),
            workspace: c["workspace"]["id"].as_i64().unwrap_or(0),
            minimised: c["workspace"]["name"].as_str() == Some(MINIMISED),
            monitor: c["monitor"].as_i64().unwrap_or(-1),
            pinned: c["pinned"] == true,
            fullscreen: c["fullscreen"].as_i64().unwrap_or(0),
        })
        .filter(|c| !c.class.is_empty())
        .collect()
}

/// A monitor's id and the workspace it shows.
pub fn monitor(name: &str) -> (i64, i64) {
    let ms = hypr::json("j/monitors");
    ms.as_array()
        .and_then(|a| a.iter().find(|m| m["name"] == name))
        .map(|m| (m["id"].as_i64().unwrap_or(-1), m["activeWorkspace"]["id"].as_i64().unwrap_or(0)))
        .unwrap_or((-1, 0))
}

/// The windows a monitor's dock counts (dockScope "workspace"): those on
/// the workspace it shows, those pinned to it, and the minimised.
pub fn shown_on(all: &[Client], name: &str, scope_all: bool) -> Vec<Client> {
    if scope_all {
        return all.to_vec();
    }
    let (id, ws) = monitor(name);
    all.iter().filter(|c| c.workspace == ws || (c.pinned && c.monitor == id) || c.minimised).cloned().collect()
}

/// A tile's label for a window class: its desktop entry's name, else the
/// last part of the class with a capital ("org.gnome.Nautilus" → "Nautilus").
pub fn label_for(cls: &str) -> String {
    if let Some(e) = launcher::entry_for_class(cls) {
        return e.name;
    }
    let tail = cls.rsplit('.').next().unwrap_or(cls);
    let mut c = tail.chars();
    c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
}

/// One tile, in the order the dock lays them out.
#[derive(Clone)]
pub enum Tile {
    Start,
    Divider,
    Pin { index: usize, windows: Vec<String> },
    App { class: String, windows: Vec<String> },
    Desktop,
}

/// The tiles: Start, the pinned apps, the running apps not pinned, show
/// desktop; dividers between.
pub fn tiles(pinned: &[Pinned], shown: &[Client], desktop_tile: bool) -> Vec<Tile> {
    let mut out = vec![Tile::Start];
    let mut unpinned: Vec<String> = Vec::new();
    for c in shown {
        if !pinned.iter().any(|p| p.matches(&c.class)) && !unpinned.contains(&c.class) {
            unpinned.push(c.class.clone());
        }
    }
    if !pinned.is_empty() || !unpinned.is_empty() {
        out.push(Tile::Divider);
    }
    for (i, p) in pinned.iter().enumerate() {
        let windows = shown.iter().filter(|c| p.matches(&c.class)).map(|c| c.address.clone()).collect();
        out.push(Tile::Pin { index: i, windows });
    }
    if !unpinned.is_empty() && !pinned.is_empty() {
        out.push(Tile::Divider);
    }
    for cls in unpinned {
        let windows = shown.iter().filter(|c| c.class == cls).map(|c| c.address.clone()).collect();
        out.push(Tile::App { class: cls, windows });
    }
    if desktop_tile {
        out.push(Tile::Divider);
        out.push(Tile::Desktop);
    }
    out
}

fn sel(address: &str) -> String {
    let a = if address.starts_with("0x") { address.to_string() } else { format!("0x{address}") };
    hypr::lua_str(&format!("address:{a}"))
}

pub fn focus(address: &str, minimised: bool, current_ws: i64) {
    let s = sel(address);
    if minimised {
        // Back from the minimised workspace to the one in view.
        let ws = if current_ws > 0 { current_ws } else { 1 };
        hypr::dispatch(
            &format!("hl.dsp.window.move({{ workspace = {ws}, follow = false, window = {s} }})"),
            &format!("movetoworkspacesilent {ws},address:{address}"),
        );
    }
    hypr::dispatch(&format!("hl.dsp.focus({{ window = {s} }})"), &format!("focuswindow address:{address}"));
}

pub fn minimise(address: &str) {
    let s = sel(address);
    hypr::dispatch(
        &format!("hl.dsp.window.move({{ workspace = \"{MINIMISED}\", follow = false, window = {s} }})"),
        &format!("movetoworkspacesilent {MINIMISED},address:{address}"),
    );
}

pub fn close(address: &str) {
    let s = sel(address);
    hypr::dispatch(&format!("hl.dsp.window.close({{ window = {s} }})"), &format!("closewindow address:{address}"));
}

/// Show desktop: to the stash workspace (99) and back.
pub fn toggle_desktop() {
    let ws = hypr::json("j/activeworkspace")["id"].as_i64().unwrap_or(1);
    if ws == 99 {
        hypr::dispatch("hl.dsp.focus({ workspace = \"previous\" })", "workspace previous");
    } else {
        hypr::dispatch("hl.dsp.focus({ workspace = 99 })", "workspace 99");
    }
}

/// Activates an app's windows as Compositor.activateOrMinimise: the next
/// one after the focused one; with one window, already focused, in the
/// Windows-style window mode, minimise it.
pub fn activate(windows: &[String], all: &[Client], active: &str, windows_mode: bool, current_ws: i64) {
    let at = windows.iter().position(|a| a == active && !all.iter().any(|c| &c.address == a && c.minimised));
    if let Some(i) = at {
        if windows.len() == 1 && windows_mode {
            minimise(&windows[i]);
            return;
        }
    }
    let next = at.map(|i| &windows[(i + 1) % windows.len()]).or(windows.first());
    if let Some(a) = next {
        let min = all.iter().any(|c| &c.address == a && c.minimised);
        focus(a, min, current_ws);
    }
}

/// The command that opens a pinned app (its own, or the shell's tile's).
pub fn command_for(p: &Pinned) -> Option<Vec<String>> {
    if p.exec.is_empty() { launcher::tile_command(&p.key) } else { Some(p.exec.clone()) }
}

/// Pins a running app's class to the end of the dock, as Apps.pinClass.
pub fn pin_class(raw: &Value, cls: &str) {
    let mut list = launcher::pinned(raw);
    let key = format!("app:{cls}");
    if list.iter().any(|p| p.key == key) {
        return;
    }
    let entry = launcher::entry_for_class(cls);
    list.push(Pinned {
        key,
        label: entry.as_ref().map(|e| e.name.clone()).unwrap_or_else(|| label_for(cls)),
        icon: launcher::glyph_for_class(cls).to_string(),
        exec: entry.map(|e| e.exec).filter(|e| !e.is_empty()).unwrap_or_else(|| vec![cls.to_string()]),
        matcher: format!("^{}$", regex::escape(cls)),
    });
    launcher::save_pinned(&list);
}

pub fn unpin(raw: &Value, key: &str) {
    let list: Vec<Pinned> = launcher::pinned(raw).into_iter().filter(|p| p.key != key).collect();
    launcher::save_pinned(&list);
}

pub fn move_pin(raw: &Value, key: &str, by: i32) {
    let mut list = launcher::pinned(raw);
    let Some(from) = list.iter().position(|p| p.key == key) else { return };
    let to = (from as i32 + by).clamp(0, list.len() as i32 - 1) as usize;
    if to != from {
        let p = list.remove(from);
        list.insert(to, p);
        launcher::save_pinned(&list);
    }
}
