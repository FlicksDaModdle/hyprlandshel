//! Settings → Flatpak access: which folders each Flatpak app can reach,
//! and the same for every app at once. Read from `flatpak info
//! --show-permissions` (which already folds in the user's overrides) and
//! changed with `flatpak override --user`, so Flatpak's own files stay the
//! one place the answer lives and `flatpak override` shows the same.

use crate::{Fp, FpApp, FpFolder};
use slint::{ComponentHandle, ModelRc, VecModel};
use std::collections::HashSet;
use std::process::Command;

/// The folders worth a switch: (Flatpak's name for it, what it's called).
const FOLDERS: &[(&str, &str)] = &[
    ("xdg-download", "Downloads"),
    ("xdg-documents", "Documents"),
    ("xdg-pictures", "Pictures"),
    ("xdg-music", "Music"),
    ("xdg-videos", "Videos"),
    ("xdg-desktop", "Desktop"),
    ("home", "Home folder"),
    ("host", "Whole file system"),
];
const HOME: usize = 6;
const HOST: usize = 7;

/// What a change asks of `flatpak override`.
pub enum Op {
    /// App ("" for every app), folder, and 0 none, 1 read only, 2 read & write.
    Set(String, String, i32),
    /// Back to what the app came with ("" for the every-app settings).
    Reset(String),
}

#[derive(Clone, Default)]
pub struct AppData {
    id: String,
    name: String,
    /// Per folder: -1 not mentioned, 0 no access, 1 read only, 2 read & write.
    modes: Vec<i32>,
    /// Paths beyond those folders, as Flatpak spells them.
    other: Vec<String>,
}

#[derive(Default)]
pub struct Data {
    apps: Vec<AppData>,
    global: Vec<i32>,
    error: String,
}

#[derive(Default)]
pub struct Flatpak {
    pub loading: bool,
    pub data: Data,
    pub open: HashSet<String>,
}

/// The `filesystems=` line of a permissions listing or override file.
fn parse(text: &str) -> (Vec<i32>, Vec<String>) {
    let mut modes = vec![-1; FOLDERS.len()];
    let mut other = Vec::new();
    let line = text.lines().find_map(|l| l.strip_prefix("filesystems=")).unwrap_or("");
    for e in line.split(';').map(str::trim).filter(|e| !e.is_empty()) {
        let (denied, e) = e.strip_prefix('!').map_or((false, e), |r| (true, r));
        let (path, access) = e.rsplit_once(':').filter(|(_, a)| matches!(*a, "ro" | "rw" | "create")).map_or((e, "rw"), |(p, a)| (p, a));
        let mode = if denied { 0 } else if access == "ro" { 1 } else { 2 };
        match FOLDERS.iter().position(|(k, _)| *k == path) {
            Some(i) => modes[i] = mode,
            None if !denied => other.push(if mode == 1 { format!("{path} (read only)") } else { path.to_string() }),
            None => {}
        }
    }
    (modes, other)
}

fn out(args: &[&str]) -> Option<String> {
    let o = Command::new("flatpak").args(args).output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).into_owned())
}

/// Blocking: every installed app and what it can reach, after `op`.
pub fn run(op: Option<Op>) -> Data {
    let mut d = Data::default();
    if let Some(op) = op {
        let mut c = Command::new("flatpak");
        c.args(["override", "--user"]);
        let app = match &op {
            Op::Set(a, k, m) => {
                c.arg(match m {
                    0 => format!("--nofilesystem={k}"),
                    1 => format!("--filesystem={k}:ro"),
                    _ => format!("--filesystem={k}:rw"),
                });
                a
            }
            Op::Reset(a) => {
                c.arg("--reset");
                a
            }
        };
        if !app.is_empty() {
            c.arg(app);
        }
        match c.output() {
            Ok(o) if !o.status.success() => d.error = String::from_utf8_lossy(&o.stderr).trim().to_string(),
            Err(_) => d.error = "flatpak couldn't be run".into(),
            _ => {}
        }
    }
    let Some(list) = out(&["list", "--app", "--columns=application,name"]) else {
        if d.error.is_empty() {
            d.error = "Flatpak isn't installed, or it wouldn't list the apps.".into();
        }
        d.global = vec![-1; FOLDERS.len()];
        return d;
    };
    d.global = parse(&out(&["override", "--user", "--show"]).unwrap_or_default()).0;
    let mut seen = HashSet::new();
    for l in list.lines() {
        let (id, name) = l.split_once('\t').unwrap_or((l, l));
        if id.is_empty() || !seen.insert(id.to_string()) {
            continue;
        }
        let (modes, other) = parse(&out(&["info", "--show-permissions", id]).unwrap_or_default());
        d.apps.push(AppData { id: id.into(), name: name.trim().into(), modes, other });
    }
    d.apps.sort_by_key(|a| a.name.to_lowercase());
    d
}

/// What an app really reaches for one folder: its own entry, else what
/// the home folder or the whole file system lets it.
fn effective(modes: &[i32], i: usize) -> i32 {
    if modes[i] >= 0 {
        return modes[i];
    }
    modes[HOME].max(modes[HOST]).max(0)
}

fn folders(modes: &[i32], inherit: bool) -> ModelRc<FpFolder> {
    let v: Vec<FpFolder> = FOLDERS
        .iter()
        .enumerate()
        .map(|(i, (key, label))| FpFolder {
            key: (*key).into(),
            label: (*label).into(),
            mode: if inherit { effective(modes, i) } else { modes[i] },
        })
        .collect();
    ModelRc::new(VecModel::from(v))
}

impl Flatpak {
    pub fn take(&mut self, d: Data) {
        self.loading = false;
        self.data = d;
    }

    pub fn publish(&self, ui: &crate::AppWindow) {
        let g = ui.global::<Fp>();
        g.set_loading(self.loading);
        g.set_error(self.data.error.clone().into());
        let global = if self.data.global.is_empty() { vec![-1; FOLDERS.len()] } else { self.data.global.clone() };
        g.set_global_folders(folders(&global, false));
        let apps: Vec<FpApp> = self
            .data
            .apps
            .iter()
            .map(|a| {
                let reach: Vec<String> = FOLDERS
                    .iter()
                    .enumerate()
                    .filter(|(i, _)| *i < HOME && effective(&a.modes, *i) > 0)
                    .map(|(i, (_, l))| if effective(&a.modes, i) == 1 { format!("{l} (read only)") } else { (*l).to_string() })
                    .collect();
                let wide = a.modes[HOST] > 0;
                let home = a.modes[HOME] > 0;
                let mut sub = if wide {
                    "The whole file system".to_string()
                } else if home {
                    "The whole home folder".to_string()
                } else if reach.is_empty() {
                    "No folders".to_string()
                } else {
                    reach.join(", ")
                };
                if !a.other.is_empty() {
                    sub.push_str(&format!(" · {} more", a.other.len()));
                }
                FpApp {
                    open: self.open.contains(&a.id),
                    id: a.id.clone().into(),
                    name: a.name.clone().into(),
                    sub: sub.into(),
                    note: if wide || home {
                        "This app has the whole home folder or more, so the folders below can't narrow it.".into()
                    } else {
                        "".into()
                    },
                    other: a.other.join("\n").into(),
                    folders: folders(&a.modes, true),
                }
            })
            .collect();
        g.set_apps(ModelRc::new(VecModel::from(apps)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_folders_access_and_denials() {
        let (m, other) = parse("[Context]\nfilesystems=xdg-documents;xdg-download:ro;!xdg-music;~/.cups:ro;home:rw;\n");
        assert_eq!(m[1], 2); // Documents
        assert_eq!(m[0], 1); // Downloads, read only
        assert_eq!(m[3], 0); // Music, denied
        assert_eq!(m[2], -1); // Pictures, not mentioned
        assert_eq!(other, vec!["~/.cups (read only)".to_string()]);
        // Home covers what isn't mentioned, and a denial still wins.
        assert_eq!(effective(&m, 2), 2);
        assert_eq!(effective(&m, 3), 0);
    }
}
