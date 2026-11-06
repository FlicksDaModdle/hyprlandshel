//! Settings → Updates (services/ShellUpdates.qml): which parts of
//! Hyprshell have new commits on GitHub, from scripts/hyprshell-update.py,
//! and putting them in when asked — in a terminal, where the installers
//! can ask for your password and you can see what they do. Never on its
//! own: a check only looks.

use crate::{UpCommit, UpPart, Upd};
use serde_json::Value;
use slint::{ComponentHandle, ModelRc, VecModel};
use std::collections::HashSet;
use std::path::PathBuf;

#[derive(Default)]
pub struct Updates {
    pub checking: bool,
    pub error: String,
    pub repo: String,
    pub branch: String,
    pub local_changes: bool,
    /// When it was last looked, epoch seconds; 0 for never.
    pub checked_at: i64,
    pub parts: Vec<Value>,
    pub open: HashSet<String>,
    /// The update-done file as it was when an update was started; a
    /// different one means it's over.
    pub waiting: Option<(String, i64)>,
}

pub fn script() -> PathBuf {
    hyprshell_kit::config_dir().join("quickshell/hyprshell/scripts/hyprshell-update.py")
}
fn done_file() -> PathBuf {
    let state = std::env::var("XDG_STATE_HOME").ok().filter(|s| !s.is_empty()).map(PathBuf::from).unwrap_or_else(|| hyprshell_kit::home().join(".local/state"));
    state.join("hyprshell/update-done")
}
pub fn done_text() -> String {
    std::fs::read_to_string(done_file()).unwrap_or_default()
}

/// The check, blocking (it fetches from GitHub): its answer, or an error.
pub fn run_check() -> Result<Value, String> {
    let out = std::process::Command::new("python3").arg(script()).arg("check").output().map_err(|_| "The update check failed (python3 is needed)".to_string())?;
    match serde_json::from_slice::<Value>(&out.stdout) {
        Ok(v) => Ok(v),
        Err(e) if out.status.success() => Err(format!("The update check didn't answer ({e})")),
        Err(_) => Err("The update check failed (python3 is needed)".into()),
    }
}

impl Updates {
    pub fn take(&mut self, r: Result<Value, String>) {
        self.checking = false;
        self.checked_at = hyprshell_kit::now();
        match r {
            Ok(v) => {
                let s = |k: &str| v[k].as_str().unwrap_or("").to_string();
                self.repo = s("repo");
                self.branch = s("branch");
                self.error = s("error");
                self.local_changes = v["localChanges"] == true;
                self.parts = v["parts"].as_array().cloned().unwrap_or_default();
            }
            Err(e) => self.error = e,
        }
    }

    fn pending(&self) -> usize {
        self.parts.iter().filter(|p| p["behind"].as_i64().unwrap_or(0) > 0).count()
    }

    /// One part, or "all": pulled and installed in a terminal.
    pub fn update(&mut self, id: &str) {
        let _ = std::process::Command::new("sh")
            .args(["-c", crate::hypr::TERM, "hyprshell-update", "-e", "python3"])
            .arg(script())
            .args(["run", id])
            .spawn();
        self.waiting = Some((done_text(), hyprshell_kit::now()));
    }

    pub fn publish(&self, ui: &crate::AppWindow) {
        let g = ui.global::<Upd>();
        let pending = self.pending();
        g.set_checking(self.checking);
        g.set_failed(!self.error.is_empty());
        g.set_pending(pending as i32);
        g.set_icon(if !self.error.is_empty() { "alert" } else if pending > 0 { "download" } else { "check" }.into());
        g.set_title(
            if self.checking {
                "Looking for updates…".to_string()
            } else if !self.error.is_empty() {
                "Couldn't look for updates".into()
            } else if self.checked_at == 0 {
                "Not looked yet".into()
            } else if pending == 0 {
                "Everything is up to date".into()
            } else if pending == 1 {
                "An update for one part".into()
            } else {
                format!("Updates for {pending} parts")
            }
            .into(),
        );
        g.set_sub(
            if !self.error.is_empty() {
                self.error.clone()
            } else if !self.branch.is_empty() {
                let (_, _, _, h, m, _) = hyprshell_kit::local(self.checked_at);
                format!(
                    "From GitHub, {}{}",
                    self.branch.trim_start_matches("origin/"),
                    if self.checked_at > 0 { format!(" · looked {h:02}:{m:02}") } else { String::new() }
                )
            } else {
                String::new()
            }
            .into(),
        );
        g.set_local_line(
            if self.local_changes {
                format!("Files in {} have been changed there. An update pulls only if they don't clash; commit or stash them first if it can't.", self.repo)
            } else {
                String::new()
            }
            .into(),
        );
        let parts: Vec<UpPart> = self
            .parts
            .iter()
            .map(|p| {
                let behind = p["behind"].as_i64().unwrap_or(0);
                let commits: Vec<UpCommit> = p["commits"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(|c| UpCommit { subject: c["subject"].as_str().unwrap_or("").into(), when: c["when"].as_str().unwrap_or("").into() })
                    .collect();
                let id = p["id"].as_str().unwrap_or("").to_string();
                UpPart {
                    open: self.open.contains(&id),
                    id: id.into(),
                    name: p["name"].as_str().unwrap_or("").into(),
                    sub: if behind > 0 {
                        format!(
                            "{} · {}",
                            if behind == 1 { "1 change".to_string() } else { format!("{behind} changes") },
                            commits.first().map(|c| c.subject.to_string()).unwrap_or_default()
                        )
                    } else {
                        format!("Up to date · {}", p["note"].as_str().unwrap_or(""))
                    }
                    .into(),
                    behind: behind > 0,
                    root: p["root"] == true,
                    more: (behind - commits.len() as i64).max(0) as i32,
                    commits: ModelRc::new(VecModel::from(commits)),
                }
            })
            .collect();
        g.set_parts(ModelRc::new(VecModel::from(parts)));
    }
}
