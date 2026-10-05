//! File search for the launcher: the names under $HOME, matched as you
//! type (nucleo, the fuzzy matcher Helix uses), kept current by inotify.
//!
//! Commands:  fs-config {on}                 off forgets the index
//!            fs-warm                        the launcher opened: build the
//!                                           index if there isn't one
//!            fs-search {id, query, limit}
//! Events:    fs-results {id, query, results: [{path, name, dir, isDir}],
//!                        indexing}
//!
//! Left out: hidden files and folders, node_modules, __pycache__, Python
//! environments, and any folder marked as a cache (CACHEDIR.TAG — Cargo's
//! target/ is one). Symlinks are not followed.
//!
//! The index is built when the launcher first opens and let go after ten
//! minutes without a search, so it costs nothing while it isn't used.

use crate::out;
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::ffi::{CString, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const MAX_ITEMS: usize = 400_000;
const MAX_DEPTH: usize = 14;
const MAX_WATCHES: usize = 60_000;
const IDLE: Duration = Duration::from_secs(600);
const SKIP: [&str; 6] = ["node_modules", "__pycache__", "venv", "site-packages", "dist-packages", "lost+found"];

struct Item {
    /// Relative to $HOME.
    rel: Box<str>,
    dir: bool,
    /// Minutes since the epoch, for "recently changed".
    mtime: u32,
}

impl Item {
    fn name(&self) -> &str {
        self.rel.rsplit('/').next().unwrap_or(&self.rel)
    }
    fn parent(&self) -> &str {
        self.rel.rfind('/').map(|i| &self.rel[..i]).unwrap_or("")
    }
}

#[derive(Default)]
struct Index {
    items: Vec<Item>,
    building: bool,
}

fn skip(name: &OsStr) -> bool {
    let b = name.as_bytes();
    b.first() == Some(&b'.') || SKIP.iter().any(|s| s.as_bytes() == b)
}

fn minutes(m: &std::fs::Metadata) -> u32 {
    m.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| (d.as_secs() / 60) as u32)
        .unwrap_or(0)
}

/// One folder's entries, not descending: (items, subfolders to walk).
fn list(home: &Path, rel: &str) -> (Vec<Item>, Vec<String>) {
    let mut items = Vec::new();
    let mut dirs = Vec::new();
    let abs = if rel.is_empty() { home.to_path_buf() } else { home.join(rel) };
    let Ok(rd) = std::fs::read_dir(&abs) else { return (items, dirs) };
    // A folder marked as a cache is not listed at all.
    if !rel.is_empty() && abs.join("CACHEDIR.TAG").exists() {
        return (items, dirs);
    }
    for e in rd.flatten() {
        let name = e.file_name();
        if skip(&name) {
            continue;
        }
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_symlink() {
            continue;
        }
        let Some(n) = name.to_str() else { continue };
        let r = if rel.is_empty() { n.to_string() } else { format!("{rel}/{n}") };
        let mtime = e.metadata().map(|m| minutes(&m)).unwrap_or(0);
        if ft.is_dir() {
            dirs.push(r.clone());
        }
        items.push(Item { rel: r.into(), dir: ft.is_dir(), mtime });
    }
    (items, dirs)
}

// ══ inotify ═════════════════════════════════════════════════════════════

struct Watch {
    fd: i32,
    dirs: HashMap<i32, String>,
    by_dir: HashMap<String, i32>,
    stop: Arc<AtomicBool>,
}

const MASK: u32 = libc::IN_CREATE | libc::IN_DELETE | libc::IN_MOVED_FROM | libc::IN_MOVED_TO | libc::IN_DELETE_SELF | libc::IN_ONLYDIR;

impl Watch {
    fn new(tx: Sender<Value>) -> Option<Watch> {
        let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
        if fd < 0 {
            return None;
        }
        let stop = Arc::new(AtomicBool::new(false));
        let stop2 = stop.clone();
        // Reads the events and passes on which folders changed; the index
        // is updated on the search thread.
        std::thread::spawn(move || {
            let mut buf = vec![0u8; 65536];
            while !stop2.load(Ordering::Relaxed) {
                let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
                if unsafe { libc::poll(&mut p, 1, 1000) } <= 0 {
                    continue;
                }
                let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                if n <= 0 {
                    continue;
                }
                let mut i = 0usize;
                let mut wds: HashSet<i32> = HashSet::new();
                let mut gone: Vec<(i32, String)> = Vec::new();
                while i + std::mem::size_of::<libc::inotify_event>() <= n as usize {
                    let ev = unsafe { &*(buf.as_ptr().add(i) as *const libc::inotify_event) };
                    let name_start = i + std::mem::size_of::<libc::inotify_event>();
                    let name_bytes = &buf[name_start..name_start + ev.len as usize];
                    let name = String::from_utf8_lossy(name_bytes.split(|b| *b == 0).next().unwrap_or(&[])).to_string();
                    if ev.mask & libc::IN_Q_OVERFLOW != 0 {
                        let _ = tx.send(json!({ "cmd": "_fs-overflow" }));
                    }
                    if ev.mask & (libc::IN_DELETE | libc::IN_MOVED_FROM) != 0 && ev.mask & libc::IN_ISDIR != 0 {
                        gone.push((ev.wd, name));
                    }
                    wds.insert(ev.wd);
                    i = name_start + ev.len as usize;
                }
                let gone: Vec<Value> = gone.into_iter().map(|(w, n)| json!([w, n])).collect();
                if tx.send(json!({ "cmd": "_fs-changed", "wds": wds.into_iter().collect::<Vec<_>>(), "gone": gone })).is_err() {
                    break;
                }
            }
            unsafe { libc::close(fd) };
        });
        Some(Watch { fd, dirs: HashMap::new(), by_dir: HashMap::new(), stop })
    }
    fn add(&mut self, home: &Path, rel: &str) {
        if self.dirs.len() >= MAX_WATCHES || self.by_dir.contains_key(rel) {
            return;
        }
        let abs = if rel.is_empty() { home.to_path_buf() } else { home.join(rel) };
        let Ok(c) = CString::new(abs.as_os_str().as_bytes()) else { return };
        let wd = unsafe { libc::inotify_add_watch(self.fd, c.as_ptr(), MASK) };
        if wd >= 0 {
            self.dirs.insert(wd, rel.to_string());
            self.by_dir.insert(rel.to_string(), wd);
        }
    }
    fn forget_under(&mut self, rel: &str) {
        let prefix = format!("{rel}/");
        let wds: Vec<i32> = self.dirs.iter().filter(|(_, d)| d.as_str() == rel || d.starts_with(&prefix)).map(|(w, _)| *w).collect();
        for w in wds {
            unsafe { libc::inotify_rm_watch(self.fd, w) };
            if let Some(d) = self.dirs.remove(&w) {
                self.by_dir.remove(&d);
            }
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

// ══ building ════════════════════════════════════════════════════════════

/// Walks `start` (and below), adding to the index in batches so a search
/// during the first build already finds something. Returns the folders
/// seen, to watch.
fn walk(home: &Path, start: &str, index: &Arc<Mutex<Index>>, budget: usize) -> Vec<String> {
    let mut seen = Vec::new();
    let mut queue: std::collections::VecDeque<(String, usize)> = std::collections::VecDeque::new();
    queue.push_back((start.to_string(), 0));
    let mut batch: Vec<Item> = Vec::new();
    let mut total = 0usize;
    while let Some((rel, depth)) = queue.pop_front() {
        let (items, dirs) = list(home, &rel);
        seen.push(rel);
        total += items.len();
        batch.extend(items);
        if depth < MAX_DEPTH {
            for d in dirs {
                queue.push_back((d, depth + 1));
            }
        }
        if batch.len() > 4000 {
            index.lock().unwrap().items.append(&mut batch);
        }
        if total > budget {
            break;
        }
    }
    index.lock().unwrap().items.append(&mut batch);
    seen
}

// ══ matching ════════════════════════════════════════════════════════════

fn now_minutes() -> u32 {
    (SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) / 60) as u32
}

fn search(index: &Index, matcher: &mut Matcher, query: &str, limit: usize) -> Vec<Value> {
    let q = query.trim();
    if q.chars().count() < 2 {
        return Vec::new();
    }
    // "photos 2024" or "docs/tax": words that may be in different parts
    // of the path, so the whole path is matched; otherwise the name.
    let on_path = q.contains('/') || q.contains(' ');
    // nucleo scores a clean match at about 25 a character and letters
    // scattered through a long name at about 17: "report" should not find
    // "software-properties".
    let floor = q.chars().filter(|c| !c.is_whitespace() && *c != '/').count() as u32 * 22;
    let pat = Pattern::parse(q, CaseMatching::Smart, Normalization::Smart);
    let now = now_minutes();
    let mut buf = Vec::new();
    let mut hits: Vec<(i64, usize)> = Vec::new();
    for (i, it) in index.items.iter().enumerate() {
        let hay = if on_path { &*it.rel } else { it.name() };
        let Some(s) = pat.score(Utf32Str::new(hay, &mut buf), matcher) else { continue };
        if s < floor {
            continue;
        }
        let mut score = s as i64 * 4;
        // Changed lately: likelier to be what is wanted.
        let age_days = now.saturating_sub(it.mtime) / 1440;
        score += match age_days {
            0..=1 => 60,
            2..=7 => 40,
            8..=30 => 20,
            _ => 0,
        };
        // Nearer the top of home, and shorter, first.
        score -= it.rel.matches('/').count() as i64 * 6;
        score -= it.rel.len() as i64 / 8;
        hits.push((score, i));
    }
    let n = limit.min(hits.len());
    if n == 0 {
        return Vec::new();
    }
    hits.select_nth_unstable_by(n - 1, |a, b| b.0.cmp(&a.0));
    hits.truncate(n);
    hits.sort_by(|a, b| b.0.cmp(&a.0));
    hits.iter()
        .map(|(_, i)| {
            let it = &index.items[*i];
            json!({ "path": &*it.rel, "name": it.name(), "dir": it.parent(), "isDir": it.dir })
        })
        .collect()
}

// ══ the thread ══════════════════════════════════════════════════════════

/// Hands the index's memory back to the system: glibc's allocator keeps
/// what was freed for reuse otherwise, and the point of dropping the index
/// is to not be holding it.
fn give_back() {
    #[cfg(target_env = "gnu")]
    unsafe {
        libc::malloc_trim(0);
    }
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    let me = tx.clone();
    std::thread::spawn(move || {
        let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else { return };
        let mut enabled = false;
        let mut index: Option<Arc<Mutex<Index>>> = None;
        let mut watch: Option<Watch> = None;
        let mut matcher = Matcher::new({
            let mut c = Config::DEFAULT;
            c.set_match_paths();
            c
        });
        let mut last_use = Instant::now();
        // The last search, answered again when the first build finishes.
        let mut last_query: Option<Value> = None;
        let mut pending: HashSet<String> = HashSet::new();
        let mut pending_since: Option<Instant> = None;
        // Which build an index came from, so a build that finishes after
        // its index was let go is ignored.
        let mut generation = 0u64;

        loop {
            let wait = match (pending_since, &index) {
                (Some(t), _) => Duration::from_millis(400).saturating_sub(t.elapsed()),
                (None, Some(_)) => Duration::from_secs(60),
                _ => Duration::from_secs(3600),
            };
            let cmd = match rx.recv_timeout(wait) {
                Ok(c) => Some(c),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => return,
            };

            if let Some(c) = cmd {
                match c["cmd"].as_str().unwrap_or("") {
                    "fs-config" => {
                        enabled = c["on"].as_bool().unwrap_or(false);
                        if !enabled {
                            index = None;
                            watch = None;
                            give_back();
                        }
                    }
                    "fs-warm" | "fs-search" if enabled => {
                        last_use = Instant::now();
                        if index.is_none() {
                            generation += 1;
                            let ix = Arc::new(Mutex::new(Index { items: Vec::new(), building: true }));
                            index = Some(ix.clone());
                            let (h, back, gen) = (home.clone(), me.clone(), generation);
                            std::thread::spawn(move || {
                                let dirs = walk(&h, "", &ix, MAX_ITEMS);
                                ix.lock().unwrap().building = false;
                                let _ = back.send(json!({ "cmd": "_fs-built", "dirs": dirs, "gen": gen }));
                            });
                        }
                        if c["cmd"] == "fs-search" {
                            let ix = index.as_ref().unwrap().lock().unwrap();
                            let results = search(&ix, &mut matcher, c["query"].as_str().unwrap_or(""), c["limit"].as_u64().unwrap_or(8) as usize);
                            out::emit(json!({ "ev": "fs-results", "id": c["id"], "query": c["query"], "results": results, "indexing": ix.building }));
                            last_query = if ix.building { Some(c.clone()) } else { None };
                        }
                    }
                    "fs-search" => {
                        out::emit(json!({ "ev": "fs-results", "id": c["id"], "query": c["query"], "results": [], "indexing": false }));
                    }
                    "_fs-built" if c["gen"].as_u64() == Some(generation) && index.is_some() => {
                        if let Some(w) = Watch::new(me.clone()) {
                            let mut w = w;
                            if let Some(dirs) = c["dirs"].as_array() {
                                for d in dirs {
                                    w.add(&home, d.as_str().unwrap_or(""));
                                }
                            }
                            watch = Some(w);
                        }
                        if let (Some(q), Some(ix)) = (last_query.take(), &index) {
                            let ix = ix.lock().unwrap();
                            let results = search(&ix, &mut matcher, q["query"].as_str().unwrap_or(""), q["limit"].as_u64().unwrap_or(8) as usize);
                            out::emit(json!({ "ev": "fs-results", "id": q["id"], "query": q["query"], "results": results, "indexing": false }));
                        }
                    }
                    "_fs-changed" => {
                        if let Some(w) = &mut watch {
                            // A folder deleted or moved away: everything under
                            // it goes now.
                            for g in c["gone"].as_array().into_iter().flatten() {
                                let (Some(wd), Some(name)) = (g[0].as_i64(), g[1].as_str()) else { continue };
                                let Some(parent) = w.dirs.get(&(wd as i32)).cloned() else { continue };
                                let rel = if parent.is_empty() { name.to_string() } else { format!("{parent}/{name}") };
                                w.forget_under(&rel);
                                if let Some(ix) = &index {
                                    let prefix = format!("{rel}/");
                                    ix.lock().unwrap().items.retain(|it| !it.rel.starts_with(&prefix));
                                }
                            }
                            for wd in c["wds"].as_array().into_iter().flatten() {
                                if let Some(d) = w.dirs.get(&(wd.as_i64().unwrap_or(-1) as i32)) {
                                    pending.insert(d.clone());
                                }
                            }
                            pending_since.get_or_insert(Instant::now());
                        }
                    }
                    "_fs-overflow" => {
                        // Too much changed at once to follow: start over
                        // next time it is wanted.
                        index = None;
                        watch = None;
                        give_back();
                    }
                    _ => {}
                }
            }

            // Changed folders, once the burst is over: their own entries
            // listed again, and any new folder walked and watched.
            if pending_since.map(|t| t.elapsed() >= Duration::from_millis(400)).unwrap_or(false) {
                pending_since = None;
                if let (Some(ix), Some(w)) = (&index, &mut watch) {
                    for d in pending.drain() {
                        let (items, dirs) = list(&home, &d);
                        let mut new_dirs = Vec::new();
                        {
                            let mut ixl = ix.lock().unwrap();
                            ixl.items.retain(|it| it.parent() != d);
                            ixl.items.extend(items);
                        }
                        for sub in dirs {
                            if !w.by_dir.contains_key(&sub) {
                                new_dirs.push(sub);
                            }
                        }
                        // A new folder (made, or moved in): the folder itself
                        // was listed above; walk what is in it.
                        for sub in new_dirs {
                            for seen in walk(&home, &sub, ix, 50_000) {
                                w.add(&home, &seen);
                            }
                        }
                    }
                } else {
                    pending.clear();
                }
            }

            if index.is_some() && last_use.elapsed() > IDLE {
                index = None;
                watch = None;
                give_back();
            }
        }
    });
    tx
}
