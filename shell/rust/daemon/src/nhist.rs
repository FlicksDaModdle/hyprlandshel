//! Notification history: every notification the shell shows, kept after
//! it is dismissed so it can be found again (the notification center's
//! History, with search).
//!
//! Kept in ~/.local/state/hyprshell/notifications.json, readable by this
//! user alone; at most 1000, and none older than the days chosen. A
//! notification its sender marks transient is never kept.
//!
//! Commands:  nh-config {on, days}
//!            nh-add {app, summary, body, icon, urgency}
//!            nh-search {id, query, limit}
//!            nh-delete {id}
//!            nh-clear
//! Events:    nh-results {id, query, entries: [{id, app, summary, body,
//!                        icon, urgency, time}], total}
//!            nh-changed {total}

use crate::out;
use serde_json::{json, Value};
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX: usize = 1000;

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))?;
    Some(base.join("hyprshell/notifications.json"))
}

/// Notification bodies may carry a little markup (<b>, <a href>, &amp;):
/// kept as the text it reads as.
pub fn plain(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut in_tag = false;
    for c in s.chars() {
        match c {
            '<' => in_tag = true,
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&#39;", "'").replace("&amp;", "&")
}

struct Store {
    entries: Vec<Value>,
    next: u64,
    on: bool,
    days: u64,
}

impl Store {
    fn load() -> Store {
        let mut s = Store { entries: Vec::new(), next: 1, on: false, days: 7 };
        if let Some(p) = path() {
            if let Ok(Value::Array(a)) = std::fs::read_to_string(p).map(|t| serde_json::from_str(&t).unwrap_or(Value::Null)) {
                s.entries = a;
            }
        }
        s.next = s.entries.iter().filter_map(|e| e["id"].as_u64()).max().unwrap_or(0) + 1;
        s
    }
    fn save(&self) {
        let Some(p) = path() else { return };
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = p.with_extension("json.tmp");
        use std::os::unix::fs::OpenOptionsExt;
        let ok = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .and_then(|mut f| f.write_all(Value::Array(self.entries.clone()).to_string().as_bytes()));
        if ok.is_ok() {
            let _ = std::fs::rename(&tmp, &p);
        }
    }
    /// Oldest first in the file; too old, or past the cap, goes.
    fn prune(&mut self) -> bool {
        let before = self.entries.len();
        let cutoff = now().saturating_sub(self.days * 86400);
        self.entries.retain(|e| e["time"].as_u64().unwrap_or(0) >= cutoff);
        if self.entries.len() > MAX {
            let drop = self.entries.len() - MAX;
            self.entries.drain(..drop);
        }
        self.entries.len() != before
    }
    fn search(&self, q: &str, limit: usize) -> Vec<Value> {
        let words: Vec<String> = q.to_lowercase().split_whitespace().map(|w| w.to_string()).collect();
        self.entries
            .iter()
            .rev()
            .filter(|e| {
                if words.is_empty() {
                    return true;
                }
                let hay = format!("{} {} {}", e["app"].as_str().unwrap_or(""), e["summary"].as_str().unwrap_or(""), e["body"].as_str().unwrap_or("")).to_lowercase();
                words.iter().all(|w| hay.contains(w.as_str()))
            })
            .take(limit)
            .cloned()
            .collect()
    }
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    std::thread::spawn(move || {
        let mut st = Store::load();
        let mut dirty = false;
        loop {
            let c = match rx.recv_timeout(if dirty { Duration::from_millis(500) } else { Duration::from_secs(3600) }) {
                Ok(c) => c,
                Err(RecvTimeoutError::Timeout) => {
                    if dirty {
                        st.save();
                        dirty = false;
                    } else if st.on && st.prune() {
                        // Hourly: the days' limit, as time passes.
                        st.save();
                        out::emit(json!({ "ev": "nh-changed", "total": st.entries.len() }));
                    }
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => {
                    if dirty {
                        st.save();
                    }
                    return;
                }
            };
            match c["cmd"].as_str().unwrap_or("") {
                "nh-config" => {
                    let on = c["on"].as_bool().unwrap_or(false);
                    st.days = c["days"].as_u64().unwrap_or(7).clamp(1, 365);
                    if st.on && !on {
                        // Off forgets.
                        st.entries.clear();
                        st.save();
                    }
                    st.on = on;
                    if st.prune() {
                        st.save();
                    }
                    out::emit(json!({ "ev": "nh-changed", "total": st.entries.len() }));
                }
                "nh-add" if st.on => {
                    let summary = plain(c["summary"].as_str().unwrap_or(""));
                    let body = plain(c["body"].as_str().unwrap_or(""));
                    if summary.trim().is_empty() && body.trim().is_empty() {
                        continue;
                    }
                    let id = st.next;
                    st.next += 1;
                    st.entries.push(json!({
                        "id": id, "app": c["app"].as_str().unwrap_or(""), "summary": summary, "body": body,
                        "icon": c["icon"].as_str().unwrap_or(""), "urgency": c["urgency"].as_u64().unwrap_or(1), "time": now()
                    }));
                    st.prune();
                    dirty = true;
                    out::emit(json!({ "ev": "nh-changed", "total": st.entries.len() }));
                }
                "nh-search" => {
                    let entries = st.search(c["query"].as_str().unwrap_or(""), c["limit"].as_u64().unwrap_or(200) as usize);
                    out::emit(json!({ "ev": "nh-results", "id": c["id"], "query": c["query"], "entries": entries, "total": st.entries.len() }));
                }
                "nh-delete" => {
                    let id = c["id"].as_u64().unwrap_or(0);
                    st.entries.retain(|e| e["id"].as_u64() != Some(id));
                    st.save();
                    out::emit(json!({ "ev": "nh-changed", "total": st.entries.len() }));
                }
                "nh-clear" => {
                    st.entries.clear();
                    st.save();
                    out::emit(json!({ "ev": "nh-changed", "total": 0 }));
                }
                _ => {}
            }
        }
    });
    tx
}

#[cfg(test)]
mod tests {
    #[test]
    fn markup() {
        assert_eq!(super::plain("<b>Build</b> done &amp; <a href=\"x\">tested</a> &lt;3"), "Build done & tested <3");
    }
}
