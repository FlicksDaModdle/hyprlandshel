//! Settings → Bar → Layout and Plugins: which modules the top bar has, on
//! which side, in what order; and the plugins folder.
//!
//! The rules (what is on a side by default, where a new plugin goes) are the
//! shell's own, from the same file (rshell/src/barmods.rs).

#[path = "../../../rshell/src/barmods.rs"]
#[allow(dead_code)]
mod barmods;

use crate::prefs::Prefs;
use crate::rows::{action, btn, buttons, header, info, Ctx, Spec};
use serde_json::json;
use std::path::PathBuf;

fn plugins_dir() -> PathBuf {
    hyprshell_kit::theme::theme_path().with_file_name("bar-plugins")
}

/// The plugins there are: (`plugin:<name>`, what it calls itself, its folder or file, its side).
fn plugins() -> Vec<(String, String, PathBuf, String)> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(plugins_dir()) else { return out };
    for e in rd.flatten() {
        let path = e.path();
        let (name, file) = if path.is_dir() {
            (e.file_name().to_string_lossy().to_string(), path.join("plugin.json"))
        } else if path.extension().is_some_and(|x| x == "json") {
            (path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default(), path.clone())
        } else {
            continue;
        };
        let ok = !name.is_empty() && name.len() <= 40 && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
        let Some(v) = std::fs::read_to_string(&file).ok().and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok()) else { continue };
        if ok {
            out.push((format!("plugin:{name}"), v["name"].as_str().filter(|n| !n.is_empty()).unwrap_or(&name).to_string(), path, if v["side"] == "left" { "left" } else { "right" }.to_string()));
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

fn save(c: &mut Ctx, l: &barmods::Layout) {
    c.set("barLeft", json!(l.left));
    c.set("barRight", json!(l.right));
    c.set("barHidden", json!(l.hidden));
}

pub fn rows(p: &Prefs) -> Vec<Spec> {
    let found = plugins();
    let ids: Vec<String> = found.iter().map(|f| f.0.clone()).collect();
    let layout = barmods::layout(&p.v, &ids);
    let label = |id: &str| -> String {
        if barmods::is_builtin(id) {
            barmods::name(id).to_string()
        } else {
            format!("{} (plugin)", found.iter().find(|f| f.0 == id).map(|f| f.1.as_str()).unwrap_or(id))
        }
    };
    let mut out: Vec<Spec> = Vec::new();
    for (side, list) in [("left", &layout.left), ("right", &layout.right)] {
        out.push(header(if side == "left" { "Top bar: left side" } else { "Top bar: right side" }, if side == "left" { "What is on the bar, in order from the edge. Changes show at once. Right-click the bar for Edit bar, to drag them." } else { "" }));
        for (i, id) in list.iter().enumerate() {
            let (l0, id0) = (layout.clone(), id.clone());
            let earlier = {
                let (l, id) = (l0.clone(), id0.clone());
                move |c: &mut Ctx| {
                    let mut l = l.clone();
                    let v = if side == "left" { &mut l.left } else { &mut l.right };
                    if let Some(at) = v.iter().position(|x| *x == id).filter(|a| *a > 0) {
                        v.swap(at, at - 1);
                        save(c, &l);
                    }
                }
            };
            let later = {
                let (l, id) = (l0.clone(), id0.clone());
                move |c: &mut Ctx| {
                    let mut l = l.clone();
                    let v = if side == "left" { &mut l.left } else { &mut l.right };
                    if let Some(at) = v.iter().position(|x| *x == id).filter(|a| a + 1 < v.len()) {
                        v.swap(at, at + 1);
                        save(c, &l);
                    }
                }
            };
            let across = {
                let (l, id) = (l0.clone(), id0.clone());
                move |c: &mut Ctx| {
                    let mut l = l.clone();
                    l.left.retain(|x| *x != id);
                    l.right.retain(|x| *x != id);
                    // Beside the middle of the bar: the end of the left, the start of the right.
                    if side == "left" {
                        l.right.insert(0, id.clone());
                    } else {
                        l.left.push(id.clone());
                    }
                    save(c, &l);
                }
            };
            let hide = {
                let (l, id) = (l0.clone(), id0.clone());
                move |c: &mut Ctx| {
                    let mut l = l.clone();
                    l.left.retain(|x| *x != id);
                    l.right.retain(|x| *x != id);
                    l.hidden.push(id.clone());
                    save(c, &l);
                }
            };
            out.push(buttons(
                &label(id),
                "",
                vec![
                    btn("◀ Earlier", true, i > 0, earlier),
                    btn("Later ▶", true, i + 1 < list.len(), later),
                    btn(if side == "left" { "To the right side" } else { "To the left side" }, true, true, across),
                    btn("Hide", true, true, hide),
                ],
            ));
        }
    }
    if !layout.hidden.is_empty() {
        out.push(header("Hidden", "Taken off the bar"));
        for id in &layout.hidden {
            let (l, id) = (layout.clone(), id.clone());
            let name = label(&id);
            let side = found.iter().find(|f| f.0 == id).map(|f| f.3.clone()).unwrap_or_else(|| if barmods::LEFT.contains(&id.as_str()) { "left".into() } else { "right".into() });
            out.push(buttons(
                &name,
                "",
                vec![btn("Show", false, true, move |c: &mut Ctx| {
                    let mut l = l.clone();
                    l.hidden.retain(|x| *x != id);
                    if side == "left" {
                        l.left.push(id.clone());
                    } else {
                        l.right.insert(0, id.clone());
                    }
                    save(c, &l);
                })],
            ));
        }
    }
    out.push(action("Back to the usual", "Every module where the bar had it before", "Reset", |c: &mut Ctx| {
        c.set("barLeft", serde_json::Value::Null);
        c.set("barRight", serde_json::Value::Null);
        c.set("barHidden", serde_json::Value::Null);
    }));

    out.push(header("Plugins", "Your own modules for the bar: a script that prints text (or a little JSON), run every few seconds, with actions for a click, a scroll and a menu. Any language."));
    out.push(info("Folder", "A plugin is a folder with plugin.json in it (or one .json file). It is picked up within a few seconds, no restart", plugins_dir().display().to_string()));
    for (id, name, path, _) in &found {
        out.push(info(name, &format!("{id} · {}", path.display()), ""));
    }
    out.push(action("Open the plugins folder", "", "Open", |_| {
        let _ = std::fs::create_dir_all(plugins_dir());
        let _ = std::process::Command::new("xdg-open").arg(plugins_dir()).spawn();
    }));
    out.push(action("New plugin", "A working example to change: it shows the time and says so when clicked", "Make one", |_| {
        let dir = plugins_dir();
        let n = (1..).find(|n| !dir.join(format!("my-plugin-{n}")).exists()).unwrap_or(1);
        let folder = dir.join(format!("my-plugin-{n}"));
        if std::fs::create_dir_all(&folder).is_err() {
            return;
        }
        let _ = std::fs::write(
            folder.join("plugin.json"),
            "{\n  \"name\": \"My plugin\",\n  \"side\": \"right\",\n  \"exec\": \"./run.sh\",\n  \"interval\": 5,\n  \"icon\": \"zap\",\n  \"on_click\": [\"notify My plugin | You clicked it\"],\n  \"menu\": []\n}\n",
        );
        let _ = std::fs::write(folder.join("run.sh"), "#!/bin/sh\n# What this prints is the module. A JSON object also works:\n#   {\"text\": \"42%\", \"icon\": \"cpu\", \"tooltip\": \"more\", \"class\": \"warn\"}\ndate +%H:%M:%S\n");
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(folder.join("run.sh"), std::fs::Permissions::from_mode(0o755));
    }));
    out
}
