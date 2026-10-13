//! Music: the songs in your music folder by album, artist and title, a
//! queue, shuffle and repeat, and MPRIS so the shell's media pill and the
//! media keys drive it. Decoding is symphonia's and the sound goes to
//! PulseAudio (or PipeWire's pulse server) over its own protocol, spoken in
//! Rust: nothing here links a C audio library.
//!
//!   hyprshell-music [FILE|FOLDER]...

slint::include_modules!();

mod engine;
mod library;
mod mpris;

use engine::{Cmd, Engine, Event};
use hyprshell_kit as kit;
use library::Song;
use slint::{Color, ComponentHandle, Image, Model, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Sender};
use std::sync::Arc;
use std::time::Duration;

/// Album tiles are drawn from pictures this size; the now-playing one larger.
const TILE: u32 = 288;
const BIG: u32 = 560;
/// Tile pictures kept in memory at once.
const KEEP: usize = 96;

// ── what's kept between runs ────────────────────────────────────────────

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct Saved {
    #[serde(default)]
    folder: String,
    #[serde(default = "full")]
    volume: f32,
    #[serde(default)]
    muted: bool,
    #[serde(default)]
    shuffle: bool,
    #[serde(default)]
    repeat: String,
    #[serde(default)]
    queue: Vec<String>,
    #[serde(default)]
    order: Vec<String>,
    #[serde(default)]
    at: Option<usize>,
    #[serde(default)]
    pos: f64,
}
fn full() -> f32 {
    80.0
}

fn state_file() -> PathBuf {
    kit::config_dir().join("hyprshell-music/state.json")
}

// ── the library, arranged ───────────────────────────────────────────────

struct Album {
    key: String,
    title: String,
    artist: String,
    year: u32,
    songs: Vec<usize>,
    tint: Color,
}

#[derive(Clone, PartialEq)]
enum Page {
    None,
    Album(String),
    Artist(String),
}

/// A colour of its own for something with no picture, from its name.
fn tint(key: &str) -> Color {
    let mut h: u32 = 2166136261;
    for b in key.bytes() {
        h = (h ^ b as u32).wrapping_mul(16777619);
    }
    let hue = (h % 360) as f32;
    let (s, l) = (0.42f32, 0.44f32);
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let x = c * (1.0 - ((hue / 60.0) % 2.0 - 1.0).abs());
    let m = l - c / 2.0;
    let (r, g, b) = match (hue / 60.0) as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let u = |v: f32| ((v + m) * 255.0).round().clamp(0.0, 255.0) as u8;
    Color::from_rgb_u8(u(r), u(g), u(b))
}

fn initials(name: &str) -> String {
    let mut out = String::new();
    for w in name.split_whitespace().filter(|w| w.chars().next().is_some_and(|c| c.is_alphanumeric())).take(2) {
        out.extend(w.chars().next().unwrap().to_uppercase());
    }
    if out.is_empty() { "♪".into() } else { out }
}

/// Sort names as people read them: case aside, and "The" aside.
fn sort_key(s: &str) -> String {
    let l = s.to_lowercase();
    l.strip_prefix("the ").map(str::to_string).unwrap_or(l)
}

/// A small, good-enough shuffle: xorshift seeded from the clock.
fn shuffle<T>(v: &mut [T]) {
    let mut x = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0x9e3779b9, |d| d.as_nanos() as u64) | 1;
    for i in (1..v.len()).rev() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        v.swap(i, (x % (i as u64 + 1)) as usize);
    }
}

// ── art, drawn on a thread of its own ───────────────────────────────────

struct ArtAsk {
    key: String,
    paths: Vec<PathBuf>,
    size: u32,
    save: Option<PathBuf>,
}

fn art_worker() -> Sender<ArtAsk> {
    let (tx, rx) = channel::<ArtAsk>();
    std::thread::Builder::new()
        .name("music-art".into())
        .spawn(move || {
            for ask in rx {
                let img = library::art(&ask.paths, ask.size);
                let mut saved = None;
                if let (Some(img), Some(p)) = (img.as_ref(), ask.save.as_ref()) {
                    if p.exists() || (std::fs::create_dir_all(p.parent().unwrap()).is_ok() && img.save(p).is_ok()) {
                        saved = Some(p.clone());
                    }
                }
                let buf = img.map(|i| SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(i.as_raw(), i.width(), i.height()));
                let (key, size) = (ask.key, ask.size);
                let _ = slint::invoke_from_event_loop(move || {
                    APP.with(|a| {
                        if let Some(a) = a.borrow().as_ref() {
                            a.art_done(key, size, buf, saved);
                        }
                    })
                });
            }
        })
        .expect("art thread");
    tx
}

// ── the app ─────────────────────────────────────────────────────────────

struct App {
    // Held strongly: the app and its window live and die together.
    win: AppWindow,
    engine: Engine,
    mpris: RefCell<Option<Sender<mpris::Update>>>,
    folder: RefCell<PathBuf>,
    songs: RefCell<Vec<Song>>,
    albums: RefCell<Vec<Album>>,
    album_index: RefCell<HashMap<String, usize>>,
    /// Albums in the grid now (all, or one artist's), as indices.
    shelf: RefCell<Vec<usize>>,
    shelf_model: Rc<VecModel<AlbumTile>>,
    in_view: Cell<(i32, i32)>,
    /// What the songs list shows (song indices), searched.
    listed: RefCell<Vec<usize>>,
    art: RefCell<HashMap<String, Image>>,
    art_used: RefCell<Vec<String>>,
    art_pending: RefCell<HashSet<String>>,
    art_none: RefCell<HashSet<String>>,
    art_tx: Sender<ArtAsk>,
    now_art_key: RefCell<String>,
    now_art_url: RefCell<String>,
    queue: RefCell<Vec<usize>>,
    order: RefCell<Vec<usize>>,
    at: Cell<Option<usize>>,
    loaded: Cell<bool>,
    resume_at: Cell<f64>,
    shuffle: Cell<bool>,
    repeat: RefCell<String>,
    volume: Cell<f32>,
    muted: Cell<bool>,
    track_id: Cell<u64>,
    failures: Cell<u32>,
    page: RefCell<Page>,
    back_stack: RefCell<Vec<(String, Page)>>,
    scanning: Arc<AtomicUsize>,
    scan_busy: Cell<bool>,
    tick: slint::Timer,
    toast_timer: slint::Timer,
    save_timer: slint::Timer,
}

thread_local! {
    static APP: RefCell<Option<Rc<App>>> = const { RefCell::new(None) };
}

impl App {
    fn g(&self) -> Music<'_> {
        self.win.global::<Music>()
    }

    fn toast(&self, t: &str) {
        self.g().set_toast(t.into());
        let w = self.win.as_weak();
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(2800), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Music>().set_toast(SharedString::new());
            }
        });
    }

    // ── library ────────────────────────────────────────────────────────

    fn set_songs(&self, new: Vec<Song>) {
        // Keep the queue pointing at the same files across a rescan.
        let old_paths = |v: &Vec<usize>, songs: &Vec<Song>| -> Vec<String> { v.iter().filter_map(|&i| songs.get(i).map(|s| s.path.clone())).collect() };
        let (q, o, strays) = {
            let songs = self.songs.borrow();
            let strays: Vec<Song> = songs.iter().filter(|s| s.stray).cloned().collect();
            (old_paths(&self.queue.borrow(), &songs), old_paths(&self.order.borrow(), &songs), strays)
        };
        let mut new = new;
        let known: HashSet<String> = new.iter().map(|s| s.path.clone()).collect();
        new.extend(strays.into_iter().filter(|s| !known.contains(&s.path)));
        *self.songs.borrow_mut() = new;
        let q = self.indices(&q);
        let at = self.at.get().map(|i| i.min(q.len().saturating_sub(1)));
        *self.queue.borrow_mut() = q;
        *self.order.borrow_mut() = self.indices(&o);
        self.at.set(if self.queue.borrow().is_empty() { None } else { at });
        self.arrange();
    }

    /// Paths to song indices; files not in the library are read and kept
    /// as strays; ones that are gone are dropped.
    fn indices(&self, paths: &[String]) -> Vec<usize> {
        let mut out = Vec::new();
        let mut map: HashMap<String, usize> = self.songs.borrow().iter().enumerate().map(|(i, s)| (s.path.clone(), i)).collect();
        for p in paths {
            if let Some(&i) = map.get(p) {
                out.push(i);
            } else if Path::new(p).is_file() {
                let mut s = library::read(Path::new(p));
                s.stray = true;
                let mut songs = self.songs.borrow_mut();
                songs.push(s);
                map.insert(p.clone(), songs.len() - 1);
                out.push(songs.len() - 1);
            }
        }
        out
    }

    /// Albums, artists and songs from the songs.
    fn arrange(&self) {
        let songs = self.songs.borrow();
        let mut by: HashMap<String, Album> = HashMap::new();
        for (i, s) in songs.iter().enumerate() {
            if s.stray {
                continue;
            }
            let key = s.album_key();
            let a = by.entry(key.clone()).or_insert_with(|| Album {
                tint: tint(&key),
                key,
                title: s.album_name().to_string(),
                artist: s.by().to_string(),
                year: 0,
                songs: Vec::new(),
            });
            a.year = a.year.max(s.year);
            a.songs.push(i);
        }
        let mut albums: Vec<Album> = by.into_values().collect();
        for a in albums.iter_mut() {
            a.songs.sort_by(|&x, &y| {
                let (p, q) = (&songs[x], &songs[y]);
                (p.disc, p.track, sort_key(&p.title)).cmp(&(q.disc, q.track, sort_key(&q.title)))
            });
        }
        albums.sort_by(|a, b| (sort_key(&a.title), sort_key(&a.artist)).cmp(&(sort_key(&b.title), sort_key(&b.artist))));
        *self.album_index.borrow_mut() = albums.iter().enumerate().map(|(i, a)| (a.key.clone(), i)).collect();
        let count = songs.iter().filter(|s| !s.stray).count();
        drop(songs);
        let n = albums.len();
        *self.albums.borrow_mut() = albums;
        let g = self.g();
        g.set_song_count(count as i32);
        g.set_album_count(n as i32);
        self.show_artists();
        self.search(&g.get_search());
        // Keep the page that's open, if it's still there.
        let page = self.page.borrow().clone();
        match page {
            Page::Album(k) if self.album_index.borrow().contains_key(&k) => self.show_album(&k, false),
            Page::Artist(n) => self.show_artist(&n, false),
            _ => {
                if g.get_view() == "album" || g.get_view() == "artist" {
                    g.set_view("albums".into());
                }
                *self.page.borrow_mut() = Page::None;
                self.set_shelf((0..n).collect());
            }
        }
        self.show_queue();
        self.show_now();
    }

    fn set_shelf(&self, idx: Vec<usize>) {
        let albums = self.albums.borrow();
        let art = self.art.borrow();
        let rows: Vec<AlbumTile> = idx
            .iter()
            .map(|&i| {
                let a = &albums[i];
                let img = art.get(&a.key);
                AlbumTile {
                    key: a.key.clone().into(),
                    title: a.title.clone().into(),
                    artist: a.artist.clone().into(),
                    year: if a.year > 0 { a.year.to_string().into() } else { SharedString::new() },
                    has_art: img.is_some(),
                    art: img.cloned().unwrap_or_default(),
                    tint: a.tint,
                }
            })
            .collect();
        drop(art);
        drop(albums);
        *self.shelf.borrow_mut() = idx;
        self.shelf_model.set_vec(rows);
        let (a, b) = self.in_view.get();
        self.albums_in_view(a, b);
    }

    fn show_artists(&self) {
        let songs = self.songs.borrow();
        let mut by: HashMap<String, (String, HashSet<usize>, usize)> = HashMap::new();
        let index = self.album_index.borrow();
        for s in songs.iter().filter(|s| !s.stray) {
            let e = by.entry(s.by().to_lowercase()).or_insert_with(|| (s.by().to_string(), HashSet::new(), 0));
            if let Some(&a) = index.get(&s.album_key()) {
                e.1.insert(a);
            }
            e.2 += 1;
        }
        let mut list: Vec<(String, usize, usize)> = by.into_values().map(|(n, a, c)| (n, a.len(), c)).collect();
        list.sort_by_key(|a| sort_key(&a.0));
        let rows: Vec<ArtistRow> = list
            .into_iter()
            .map(|(name, a, c)| ArtistRow {
                sub: format!("{} {} · {} {}", a, if a == 1 { "album" } else { "albums" }, c, if c == 1 { "song" } else { "songs" }).into(),
                initials: initials(&name).into(),
                tint: tint(&name.to_lowercase()),
                name: name.into(),
            })
            .collect();
        self.g().set_artists(ModelRc::new(VecModel::from(rows)));
    }

    fn row(&self, i: usize, num: String, slot: i32) -> SongRow {
        let songs = self.songs.borrow();
        let s = &songs[i];
        SongRow {
            id: i as i32,
            title: s.title.clone().into(),
            artist: s.artist_name().into(),
            album: s.album_name().into(),
            time: if s.secs > 0.0 { kit::clock(s.secs).into() } else { SharedString::new() },
            num: num.into(),
            current: self.current() == Some(i) && (slot < 0 || Some(slot as usize) == self.at.get()),
            slot,
        }
    }

    fn search(&self, q: &str) {
        let words: Vec<String> = q.to_lowercase().split_whitespace().map(str::to_string).collect();
        let mut list: Vec<usize> = {
            let songs = self.songs.borrow();
            songs
                .iter()
                .enumerate()
                .filter(|(_, s)| !s.stray)
                .filter(|(_, s)| {
                    if words.is_empty() {
                        return true;
                    }
                    let hay = format!("{} {} {} {}", s.title, s.artist, s.album, s.album_artist).to_lowercase();
                    words.iter().all(|w| hay.contains(w.as_str()))
                })
                .map(|(i, _)| i)
                .collect()
        };
        {
            let songs = self.songs.borrow();
            list.sort_by_cached_key(|&i| (sort_key(&songs[i].title), sort_key(songs[i].artist_name())));
        }
        let rows: Vec<SongRow> = list.iter().enumerate().map(|(n, &i)| self.row(i, (n + 1).to_string(), -1)).collect();
        *self.listed.borrow_mut() = list;
        self.g().set_songs(ModelRc::new(VecModel::from(rows)));
    }

    // ── pages ──────────────────────────────────────────────────────────

    fn go(&self, view: &str) {
        self.back_stack.borrow_mut().clear();
        *self.page.borrow_mut() = Page::None;
        let g = self.g();
        if view == "albums" && g.get_view() != "albums" {
            let n = self.albums.borrow().len();
            self.set_shelf((0..n).collect());
        }
        g.set_view(view.into());
    }

    fn push(&self) {
        let g = self.g();
        let v = g.get_view().to_string();
        let p = self.page.borrow().clone();
        self.back_stack.borrow_mut().push((v, p));
    }

    fn back(&self) {
        let Some((v, p)) = self.back_stack.borrow_mut().pop() else {
            self.go("albums");
            return;
        };
        match p {
            Page::Artist(n) => self.show_artist(&n, false),
            Page::Album(k) => self.show_album(&k, false),
            Page::None => {
                *self.page.borrow_mut() = Page::None;
                if v == "albums" {
                    let n = self.albums.borrow().len();
                    self.set_shelf((0..n).collect());
                }
                self.g().set_view(v.into());
            }
        }
    }

    fn show_album(&self, key: &str, push: bool) {
        let Some(&ai) = self.album_index.borrow().get(key) else { return };
        if push && *self.page.borrow() != Page::Album(key.to_string()) {
            self.push();
        }
        *self.page.borrow_mut() = Page::Album(key.to_string());
        let (rows, title, sub, tint, paths) = {
            let albums = self.albums.borrow();
            let a = &albums[ai];
            let secs: f64 = a.songs.iter().map(|&i| self.songs.borrow()[i].secs).sum();
            let rows: Vec<SongRow> = a
                .songs
                .iter()
                .map(|&i| {
                    let t = self.songs.borrow()[i].track;
                    let mut r = self.row(i, if t > 0 { t.to_string() } else { String::new() }, -1);
                    // The album's own artist goes without saying.
                    if r.artist.as_str() == a.artist {
                        r.artist = SharedString::new();
                    }
                    r
                })
                .collect();
            let mut sub = a.artist.clone();
            if a.year > 0 {
                sub += &format!(" · {}", a.year);
            }
            sub += &format!(" · {} {}", a.songs.len(), if a.songs.len() == 1 { "song" } else { "songs" });
            if secs > 0.0 {
                let m = (secs / 60.0).round() as u64;
                sub += &if m >= 60 { format!(", {} h {} min", m / 60, m % 60) } else { format!(", {m} min") };
            }
            let paths: Vec<PathBuf> = a.songs.iter().map(|&i| PathBuf::from(&self.songs.borrow()[i].path)).collect();
            (rows, a.title.clone(), sub, a.tint, paths)
        };
        let g = self.g();
        g.set_tracks(ModelRc::new(VecModel::from(rows)));
        g.set_page_key(key.into());
        g.set_page_title(title.into());
        g.set_page_sub(sub.into());
        g.set_page_tint(tint);
        let img = self.art.borrow().get(key).cloned();
        g.set_page_has_art(img.is_some());
        g.set_page_art(img.unwrap_or_default());
        if !self.art.borrow().contains_key(key) {
            self.ask_art(key, paths);
        }
        g.set_view("album".into());
    }

    fn artist_songs(&self, name: &str) -> Vec<usize> {
        let n = name.to_lowercase();
        let albums = self.albums.borrow();
        let mut mine: Vec<&Album> = albums.iter().filter(|a| a.artist.to_lowercase() == n).collect();
        mine.sort_by_key(|a| (a.year, sort_key(&a.title)));
        let mut out: Vec<usize> = mine.iter().flat_map(|a| a.songs.iter().copied()).collect();
        // And their songs on other people's albums.
        let songs = self.songs.borrow();
        for (i, s) in songs.iter().enumerate() {
            if !s.stray && s.artist.to_lowercase() == n && s.by().to_lowercase() != n {
                out.push(i);
            }
        }
        out
    }

    fn show_artist(&self, name: &str, push: bool) {
        if push && *self.page.borrow() != Page::Artist(name.to_string()) {
            self.push();
        }
        *self.page.borrow_mut() = Page::Artist(name.to_string());
        let n = name.to_lowercase();
        let mut idx: Vec<usize> = {
            let albums = self.albums.borrow();
            albums.iter().enumerate().filter(|(_, a)| a.artist.to_lowercase() == n).map(|(i, _)| i).collect()
        };
        {
            let albums = self.albums.borrow();
            idx.sort_by_key(|&i| (std::cmp::Reverse(albums[i].year), sort_key(&albums[i].title)));
        }
        let count = self.artist_songs(name).len();
        let g = self.g();
        g.set_page_title(name.into());
        g.set_page_sub(
            format!("{} {} · {} {}", idx.len(), if idx.len() == 1 { "album" } else { "albums" }, count, if count == 1 { "song" } else { "songs" })
                .into(),
        );
        self.set_shelf(idx);
        g.set_view("artist".into());
    }

    // ── art ────────────────────────────────────────────────────────────

    fn albums_in_view(&self, a: i32, b: i32) {
        self.in_view.set((a, b));
        let shelf = self.shelf.borrow().clone();
        if shelf.is_empty() {
            return;
        }
        let lo = (a - 12).max(0) as usize;
        let hi = ((b + 12).max(0) as usize).min(shelf.len());
        let wanted: Vec<(String, Vec<PathBuf>)> = {
            let albums = self.albums.borrow();
            let songs = self.songs.borrow();
            (lo..hi)
                .map(|r| &albums[shelf[r]])
                .filter(|al| !self.art.borrow().contains_key(&al.key))
                .map(|al| (al.key.clone(), al.songs.iter().map(|&i| PathBuf::from(&songs[i].path)).collect()))
                .collect()
        };
        for (k, p) in wanted {
            self.ask_art(&k, p);
        }
        // Touch what's on screen, so it's the last to go.
        let albums = self.albums.borrow();
        let mut used = self.art_used.borrow_mut();
        for r in lo..hi {
            let k = &albums[shelf[r]].key;
            if let Some(p) = used.iter().position(|x| x == k) {
                let k = used.remove(p);
                used.push(k);
            }
        }
    }

    fn ask_art(&self, key: &str, paths: Vec<PathBuf>) {
        if self.art_none.borrow().contains(key) || !self.art_pending.borrow_mut().insert(key.to_string()) {
            return;
        }
        let _ = self.art_tx.send(ArtAsk { key: key.to_string(), paths, size: TILE, save: None });
    }

    fn art_done(&self, key: String, size: u32, buf: Option<SharedPixelBuffer<Rgba8Pixel>>, saved: Option<PathBuf>) {
        if size == BIG {
            if *self.now_art_key.borrow() != key {
                return;
            }
            let g = self.g();
            match buf {
                Some(b) => {
                    g.set_now_art(Image::from_rgba8(b));
                    g.set_now_has_art(true);
                }
                None => g.set_now_has_art(false),
            }
            if let Some(p) = saved {
                *self.now_art_url.borrow_mut() = format!("file://{}", p.display());
                self.tell_bus();
            }
            return;
        }
        self.art_pending.borrow_mut().remove(&key);
        let Some(b) = buf else {
            self.art_none.borrow_mut().insert(key);
            return;
        };
        let img = Image::from_rgba8(b);
        self.art.borrow_mut().insert(key.clone(), img.clone());
        self.art_used.borrow_mut().push(key.clone());
        for r in 0..self.shelf_model.row_count() {
            if let Some(mut t) = self.shelf_model.row_data(r) {
                if t.key == key.as_str() {
                    t.art = img.clone();
                    t.has_art = true;
                    self.shelf_model.set_row_data(r, t);
                }
            }
        }
        let g = self.g();
        if g.get_view() == "album" && g.get_page_key() == key.as_str() {
            g.set_page_art(img);
            g.set_page_has_art(true);
        }
        self.evict();
    }

    /// Let go of pictures well out of sight once there are too many.
    fn evict(&self) {
        let mut used = self.art_used.borrow_mut();
        if used.len() <= KEEP {
            return;
        }
        let (a, b) = self.in_view.get();
        let shelf = self.shelf.borrow();
        let albums = self.albums.borrow();
        let near: HashSet<&str> =
            ((a - 12).max(0) as usize..((b + 12).max(0) as usize).min(shelf.len())).map(|r| albums[shelf[r]].key.as_str()).collect();
        let mut gone = Vec::new();
        let mut i = 0;
        while used.len() - gone.len() > KEEP && i < used.len() {
            if !near.contains(used[i].as_str()) {
                gone.push(i);
            }
            i += 1;
        }
        let mut art = self.art.borrow_mut();
        for &i in gone.iter().rev() {
            let k = used.remove(i);
            art.remove(&k);
            for r in 0..self.shelf_model.row_count() {
                if let Some(mut t) = self.shelf_model.row_data(r) {
                    if t.key == k.as_str() {
                        t.art = Image::default();
                        t.has_art = false;
                        self.shelf_model.set_row_data(r, t);
                    }
                }
            }
        }
    }

    // ── the queue ──────────────────────────────────────────────────────

    fn current(&self) -> Option<usize> {
        self.at.get().and_then(|i| self.queue.borrow().get(i).copied())
    }

    /// Play `list` from `start` (an index into it).
    fn play_list(&self, list: Vec<usize>, start: Option<usize>, shuffled: bool) {
        if list.is_empty() {
            return;
        }
        self.shuffle.set(shuffled);
        *self.order.borrow_mut() = list.clone();
        let mut q = list;
        let first = match start {
            Some(s) => s.min(q.len() - 1),
            None if shuffled => (std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.subsec_nanos()) as usize) % q.len(),
            None => 0,
        };
        if shuffled {
            let head = q.remove(first);
            shuffle(&mut q);
            q.insert(0, head);
            *self.queue.borrow_mut() = q;
            self.at.set(Some(0));
        } else {
            *self.queue.borrow_mut() = q;
            self.at.set(Some(first));
        }
        self.failures.set(0);
        self.load(true, 0.0);
        self.show_queue();
        self.save_soon();
    }

    fn load(&self, play: bool, at: f64) {
        let Some(i) = self.current() else {
            self.stop();
            return;
        };
        let path = PathBuf::from(&self.songs.borrow()[i].path);
        self.track_id.set(self.track_id.get() + 1);
        self.engine.send(Cmd::Load { path, play, at, token: self.track_id.get() });
        self.loaded.set(true);
        let g = self.g();
        g.set_playing(play);
        g.set_pos(at as f32);
        g.set_pos_text(kit::clock(at).into());
        self.show_now();
        self.mark_current();
        self.ticking(play);
    }

    fn stop(&self) {
        self.engine.send(Cmd::Stop);
        self.loaded.set(false);
        let g = self.g();
        g.set_playing(false);
        g.set_pos(0.0);
        g.set_pos_text("0:00".into());
        self.ticking(false);
        self.tell_bus();
    }

    /// The now-playing corner and page.
    fn show_now(&self) {
        let g = self.g();
        let Some(i) = self.current() else {
            g.set_has_track(false);
            g.set_now_title(SharedString::new());
            g.set_now_artist(SharedString::new());
            g.set_now_album(SharedString::new());
            g.set_now_has_art(false);
            g.set_dur(0.0);
            g.set_dur_text("0:00".into());
            *self.now_art_key.borrow_mut() = String::new();
            self.tell_bus();
            return;
        };
        let (title, artist, album, secs, key, paths) = {
            let songs = self.songs.borrow();
            let s = &songs[i];
            let key = s.album_key();
            let mut paths = vec![PathBuf::from(&s.path)];
            if let Some(&ai) = self.album_index.borrow().get(&key) {
                if !s.stray {
                    let first = paths[0].clone();
                    paths.extend(self.albums.borrow()[ai].songs.iter().map(|&j| PathBuf::from(&songs[j].path)).filter(|p| *p != first));
                }
            }
            (s.title.clone(), s.artist_name().to_string(), s.album_name().to_string(), s.secs, key, paths)
        };
        g.set_has_track(true);
        g.set_now_title(title.into());
        g.set_now_artist(artist.into());
        g.set_now_album(album.into());
        g.set_now_tint(tint(&key));
        g.set_dur(secs as f32);
        g.set_dur_text(kit::clock(secs).into());
        if *self.now_art_key.borrow() != key {
            *self.now_art_key.borrow_mut() = key.clone();
            self.now_art_url.borrow_mut().clear();
            g.set_now_has_art(false);
            let mut h: u64 = 1469598103934665603;
            for b in key.bytes() {
                h = (h ^ b as u64).wrapping_mul(1099511628211);
            }
            let save = library::cache_dir().join(format!("art/{h:016x}.png"));
            let _ = self.art_tx.send(ArtAsk { key, paths, size: BIG, save: Some(save) });
        }
        self.tell_bus();
    }

    fn mark_current(&self) {
        let cur = self.current();
        let at = self.at.get();
        let fix = |m: ModelRc<SongRow>, by_slot: bool| {
            for r in 0..m.row_count() {
                if let Some(mut row) = m.row_data(r) {
                    let on = if by_slot { Some(row.slot as usize) == at } else { cur == Some(row.id as usize) };
                    if row.current != on {
                        row.current = on;
                        m.set_row_data(r, row);
                    }
                }
            }
        };
        let g = self.g();
        fix(g.get_songs(), false);
        fix(g.get_tracks(), false);
        self.show_queue();
    }

    fn show_queue(&self) {
        let q = self.queue.borrow().clone();
        let from = self.at.get().unwrap_or(0);
        let rows: Vec<SongRow> =
            q.iter().enumerate().skip(from).filter(|(_, &i)| i < self.songs.borrow().len()).map(|(slot, &i)| self.row(i, String::new(), slot as i32)).collect();
        let g = self.g();
        g.set_queue_count(q.len().saturating_sub(from + 1) as i32);
        g.set_queue(ModelRc::new(VecModel::from(rows)));
    }

    fn advance(&self, by_user: bool) {
        let Some(at) = self.at.get() else { return };
        let len = self.queue.borrow().len();
        let repeat = self.repeat.borrow().clone();
        if !by_user && repeat == "one" {
            self.load(true, 0.0);
            return;
        }
        if at + 1 < len {
            self.at.set(Some(at + 1));
            self.load(true, 0.0);
        } else if repeat == "all" && len > 0 {
            if self.shuffle.get() {
                let mut q = self.queue.borrow().clone();
                shuffle(&mut q);
                *self.queue.borrow_mut() = q;
            }
            self.at.set(Some(0));
            self.load(true, 0.0);
        } else {
            // The end: back to the start of the last song, paused.
            self.engine.send(Cmd::Stop);
            self.loaded.set(false);
            self.resume_at.set(0.0);
            let g = self.g();
            g.set_playing(false);
            g.set_pos(0.0);
            g.set_pos_text("0:00".into());
            self.ticking(false);
            self.tell_bus();
        }
        self.save_soon();
    }

    fn prev(&self) {
        let pos = self.engine.position();
        match self.at.get() {
            Some(at) if pos < 3.0 && at > 0 => {
                self.at.set(Some(at - 1));
                self.load(true, 0.0);
            }
            Some(_) => self.seek(0.0),
            None => {}
        }
    }

    fn toggle(&self) {
        let g = self.g();
        if self.current().is_none() {
            // Nothing queued: everything, shuffled.
            let all: Vec<usize> = self.listed.borrow().clone();
            self.play_list(all, None, true);
            return;
        }
        if !self.loaded.get() {
            self.load(true, self.resume_at.get());
            return;
        }
        if g.get_playing() {
            self.engine.send(Cmd::Pause);
            g.set_playing(false);
            self.ticking(false);
        } else {
            self.engine.send(Cmd::Play);
            g.set_playing(true);
            self.ticking(true);
        }
        self.tell_bus();
        self.save_soon();
    }

    fn play(&self) {
        if !self.g().get_playing() {
            self.toggle();
        }
    }

    fn pause(&self) {
        if self.g().get_playing() {
            self.toggle();
        }
    }

    fn seek(&self, t: f64) {
        let t = t.max(0.0);
        let g = self.g();
        if !self.loaded.get() {
            self.resume_at.set(t);
        } else {
            self.engine.send(Cmd::Seek(t));
        }
        g.set_pos(t as f32);
        g.set_pos_text(kit::clock(t).into());
        if let Some(m) = self.mpris.borrow().as_ref() {
            let _ = m.send(mpris::Update::Seeked(t));
        }
    }

    fn set_shuffle(&self, on: bool) {
        if on == self.shuffle.get() {
            return;
        }
        self.shuffle.set(on);
        let cur = self.current();
        if on {
            if let Some(at) = self.at.get() {
                let mut q = self.queue.borrow().clone();
                let mut rest = q.split_off(at + 1);
                shuffle(&mut rest);
                q.extend(rest);
                *self.queue.borrow_mut() = q;
            }
        } else {
            let order = self.order.borrow().clone();
            if !order.is_empty() {
                let at = cur.and_then(|c| order.iter().position(|&x| x == c));
                *self.queue.borrow_mut() = order;
                self.at.set(at.or(Some(0)));
            }
        }
        self.g().set_shuffle(on);
        self.show_queue();
        self.tell_bus();
        self.save_soon();
    }

    fn set_repeat(&self, r: &str) {
        *self.repeat.borrow_mut() = r.to_string();
        self.g().set_repeat(r.into());
        self.tell_bus();
        self.save_soon();
    }

    fn set_volume(&self, v: f32) {
        let v = v.clamp(0.0, 100.0);
        self.volume.set(v);
        if v > 0.0 {
            self.muted.set(false);
        }
        let g = self.g();
        g.set_volume(v);
        g.set_muted(self.muted.get());
        self.engine.send(Cmd::Volume(if self.muted.get() { 0.0 } else { v / 100.0 }));
        self.tell_bus();
        self.save_soon();
    }

    fn song_action(&self, id: usize, slot: i32, action: i32) {
        let len = self.songs.borrow().len();
        if id >= len {
            return;
        }
        match action {
            0 | 1 => {
                if self.current().is_none() {
                    self.play_list(vec![id], Some(0), false);
                    return;
                }
                let at = self.at.get().unwrap_or(0);
                if slot >= 0 {
                    // Already queued: move it up.
                    let s = slot as usize;
                    if s != at {
                        let mut q = self.queue.borrow_mut();
                        let x = q.remove(s);
                        let at2 = if s < at { at - 1 } else { at };
                        q.insert(at2 + 1, x);
                        drop(q);
                        self.at.set(Some(at2));
                    }
                } else if action == 0 {
                    self.queue.borrow_mut().insert(at + 1, id);
                    let mut o = self.order.borrow_mut();
                    let p = self.current().and_then(|c| o.iter().position(|&x| x == c)).map_or(o.len(), |p| p + 1);
                    o.insert(p, id);
                    drop(o);
                    self.toast("Plays next");
                } else {
                    self.queue.borrow_mut().push(id);
                    self.order.borrow_mut().push(id);
                    self.toast("Added to the queue");
                }
                self.show_queue();
                self.tell_bus();
                self.save_soon();
            }
            2 => {
                let key = self.songs.borrow()[id].album_key();
                self.show_album(&key, true);
            }
            3 => {
                let n = self.songs.borrow()[id].by().to_string();
                self.show_artist(&n, true);
            }
            4 if slot >= 0 => {
                let s = slot as usize;
                let at = self.at.get().unwrap_or(0);
                let removed = {
                    let mut q = self.queue.borrow_mut();
                    if s >= q.len() {
                        return;
                    }
                    q.remove(s)
                };
                if let Some(p) = self.order.borrow().iter().position(|&x| x == removed) {
                    self.order.borrow_mut().remove(p);
                }
                if s < at {
                    self.at.set(Some(at - 1));
                } else if s == at {
                    if self.queue.borrow().len() > at {
                        let playing = self.g().get_playing();
                        self.load(playing, 0.0);
                    } else {
                        self.at.set(None);
                        self.stop();
                        self.show_now();
                    }
                }
                self.show_queue();
                self.tell_bus();
                self.save_soon();
            }
            _ => {}
        }
    }

    /// Files and folders from outside: play the first now, or queue them.
    fn open_paths(&self, paths: Vec<PathBuf>, queue_only: bool) {
        let mut files = Vec::new();
        for p in paths {
            if p.is_dir() {
                let mut found = library::scan(&p, Vec::new(), &|_| {});
                found.sort_by(|a, b| (&a.album, a.disc, a.track, &a.path).cmp(&(&b.album, b.disc, b.track, &b.path)));
                files.extend(found.into_iter().map(|s| s.path));
            } else if library::is_audio(&p) {
                files.push(p.to_string_lossy().to_string());
            }
        }
        if files.is_empty() {
            self.toast("Music can't play that");
            return;
        }
        let ids = self.indices(&files);
        if queue_only && self.current().is_some() {
            self.queue.borrow_mut().extend(ids.iter().copied());
            self.order.borrow_mut().extend(ids.iter().copied());
            self.show_queue();
            self.tell_bus();
            self.save_soon();
        } else {
            self.play_list(ids, Some(0), false);
            self.g().set_shuffle(false);
        }
    }

    // ── the clock, the bus, the disk ───────────────────────────────────

    fn ticking(&self, on: bool) {
        let scanning = self.scan_busy.get();
        if on || scanning {
            if !self.tick.running() {
                self.tick.start(slint::TimerMode::Repeated, Duration::from_millis(250), || {
                    APP.with(|a| {
                        if let Some(a) = a.borrow().as_ref() {
                            a.on_tick();
                        }
                    })
                });
            }
        } else {
            self.tick.stop();
        }
    }

    fn on_tick(&self) {
        let g = self.g();
        if self.scan_busy.get() {
            let n = self.scanning.load(Ordering::Relaxed);
            g.set_scan_text(if n > 0 { format!("Reading songs… {n}").into() } else { "Looking for music…".into() });
        }
        if self.loaded.get() {
            let p = self.engine.position();
            g.set_pos(p as f32);
            g.set_pos_text(kit::clock(p).into());
            let d = self.engine.duration();
            if d > 0.0 && (g.get_dur() - d as f32).abs() > 0.5 {
                g.set_dur(d as f32);
                g.set_dur_text(kit::clock(d).into());
                self.tell_bus();
            }
        }
        if !g.get_playing() && !self.scan_busy.get() {
            self.tick.stop();
        }
    }

    fn tell_bus(&self) {
        let Some(tx) = self.mpris.borrow().as_ref().cloned() else { return };
        let g = self.g();
        let at = self.at.get();
        let len = self.queue.borrow().len();
        let repeat = self.repeat.borrow().clone();
        let mut st = mpris::State {
            status: if self.current().is_none() {
                "Stopped".into()
            } else if g.get_playing() {
                "Playing".into()
            } else {
                "Paused".into()
            },
            loop_status: match repeat.as_str() {
                "one" => "Track",
                "all" => "Playlist",
                _ => "None",
            }
            .into(),
            shuffle: self.shuffle.get(),
            volume: if self.muted.get() { 0.0 } else { self.volume.get() as f64 / 100.0 },
            id: self.track_id.get(),
            can_next: at.is_some_and(|a| a + 1 < len || repeat == "all"),
            can_prev: at.is_some(),
            has_track: self.current().is_some(),
            ..Default::default()
        };
        if let Some(i) = self.current() {
            let songs = self.songs.borrow();
            let s = &songs[i];
            st.title = s.title.clone();
            st.artist = s.artist_name().to_string();
            st.album = s.album_name().to_string();
            st.length = if s.secs > 0.0 { s.secs } else { g.get_dur() as f64 };
            st.art = self.now_art_url.borrow().clone();
        }
        let _ = tx.send(mpris::Update::State(st));
    }

    fn remote(&self, r: mpris::Remote) {
        use mpris::Remote as R;
        match r {
            R::Raise => {
                let _ = self.win.show();
            }
            R::Quit => {
                self.save();
                let _ = slint::quit_event_loop();
            }
            R::Play => self.play(),
            R::Pause => self.pause(),
            R::PlayPause => self.toggle(),
            R::Stop => {
                self.pause();
                self.seek(0.0);
            }
            R::Next => self.advance(true),
            R::Previous => self.prev(),
            R::Seek(d) => {
                let p = self.engine.position() + d;
                if p >= self.g().get_dur() as f64 && self.g().get_dur() > 0.0 {
                    self.advance(true);
                } else {
                    self.seek(p);
                }
            }
            R::SetPosition(p) => self.seek(p),
            R::Open(uri) => {
                let (uri, queue) = match uri.strip_suffix("#queue") {
                    Some(u) => (u.to_string(), true),
                    None => (uri, false),
                };
                if let Some(p) = kit::portal::uri_to_path(&uri).or_else(|| (!uri.contains("://")).then(|| PathBuf::from(&uri))) {
                    self.open_paths(vec![p], queue);
                }
            }
            R::Volume(v) => self.set_volume((v * 100.0) as f32),
            R::Shuffle(on) => self.set_shuffle(on),
            R::Loop(l) => self.set_repeat(match l.as_str() {
                "Track" => "one",
                "Playlist" => "all",
                _ => "off",
            }),
        }
    }

    fn save_soon(&self) {
        self.save_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(800), || {
            APP.with(|a| {
                if let Some(a) = a.borrow().as_ref() {
                    a.save();
                }
            })
        });
    }

    fn save(&self) {
        let songs = self.songs.borrow();
        let paths = |v: &Vec<usize>| v.iter().filter_map(|&i| songs.get(i).map(|s| s.path.clone())).collect::<Vec<_>>();
        let custom = std::env::var_os("HYPRSHELL_MUSIC_DIR").is_none() && *self.folder.borrow() != library::root();
        let s = Saved {
            folder: if custom { self.folder.borrow().to_string_lossy().to_string() } else { String::new() },
            volume: self.volume.get(),
            muted: self.muted.get(),
            shuffle: self.shuffle.get(),
            repeat: self.repeat.borrow().clone(),
            queue: paths(&self.queue.borrow()),
            order: paths(&self.order.borrow()),
            at: self.at.get(),
            pos: if self.loaded.get() { self.engine.position() } else { self.resume_at.get() },
        };
        let p = state_file();
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        let _ = kit::write_atomic(&p, serde_json::to_string_pretty(&s).unwrap_or_default().as_bytes());
    }

    fn rescan(self: &Rc<Self>) {
        if self.scan_busy.get() {
            return;
        }
        self.scan_busy.set(true);
        self.scanning.store(0, Ordering::Relaxed);
        let g = self.g();
        g.set_scanning(true);
        g.set_scan_text("Looking for music…".into());
        self.ticking(g.get_playing());
        let root = self.folder.borrow().clone();
        let cached: Vec<Song> = self.songs.borrow().iter().filter(|s| !s.stray).cloned().collect();
        let counter = self.scanning.clone();
        let a = self.clone();
        kit::spawn(
            move || {
                let found = library::scan(&root, cached, &|n| counter.store(n, Ordering::Relaxed));
                library::save_cache(&found);
                found
            },
            move |found| {
                a.scan_busy.set(false);
                a.set_songs(found);
                let g = a.g();
                g.set_scanning(false);
                a.ticking(g.get_playing());
            },
        );
    }
}

fn main() {
    let args: Vec<PathBuf> = std::env::args_os().skip(1).map(PathBuf::from).filter(|p| !p.to_string_lossy().starts_with("--")).collect();
    let uris: Vec<String> = args
        .iter()
        .map(|p| std::fs::canonicalize(p).unwrap_or_else(|_| p.clone()))
        .map(|p| format!("file://{}", p.display()))
        .collect();
    // One Music at a time: a second launch hands over and leaves.
    if mpris::hand_over(&uris) {
        return;
    }

    kit::init("hyprshell-music");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-music");

    let saved: Saved = std::fs::read_to_string(state_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Saved {
        volume: 80.0,
        ..Default::default()
    });
    let folder = if !saved.folder.is_empty() && std::env::var_os("HYPRSHELL_MUSIC_DIR").is_none() {
        PathBuf::from(&saved.folder)
    } else {
        library::root()
    };

    let engine = Engine::new(|e| {
        let _ = slint::invoke_from_event_loop(move || {
            APP.with(|a| {
                let Some(a) = a.borrow().as_ref().cloned() else { return };
                match e {
                    // Only what's playing now; not a track already left behind.
                    Event::Ended(t) if t == a.track_id.get() => {
                        a.failures.set(0);
                        a.advance(false);
                    }
                    Event::Ended(_) => {}
                    Event::Failed(t, why) => {
                        if t != a.track_id.get() {
                            return;
                        }
                        a.toast(&why);
                        let n = a.failures.get() + 1;
                        a.failures.set(n);
                        // A file it can't play is skipped; no sound server at all stops.
                        if why.contains("sound server") || n >= 5 {
                            a.stop();
                        } else {
                            a.advance(true);
                        }
                    }
                }
            })
        });
    });

    let app = Rc::new(App {
        win: ui.clone_strong(),
        engine,
        mpris: RefCell::new(None),
        folder: RefCell::new(folder.clone()),
        songs: RefCell::new(Vec::new()),
        albums: RefCell::new(Vec::new()),
        album_index: RefCell::new(HashMap::new()),
        shelf: RefCell::new(Vec::new()),
        shelf_model: Rc::new(VecModel::default()),
        in_view: Cell::new((0, 24)),
        listed: RefCell::new(Vec::new()),
        art: RefCell::new(HashMap::new()),
        art_used: RefCell::new(Vec::new()),
        art_pending: RefCell::new(HashSet::new()),
        art_none: RefCell::new(HashSet::new()),
        art_tx: art_worker(),
        now_art_key: RefCell::new(String::new()),
        now_art_url: RefCell::new(String::new()),
        queue: RefCell::new(Vec::new()),
        order: RefCell::new(Vec::new()),
        at: Cell::new(None),
        loaded: Cell::new(false),
        resume_at: Cell::new(saved.pos),
        shuffle: Cell::new(saved.shuffle),
        repeat: RefCell::new(if saved.repeat.is_empty() { "off".into() } else { saved.repeat.clone() }),
        volume: Cell::new(saved.volume),
        muted: Cell::new(saved.muted),
        track_id: Cell::new(0),
        failures: Cell::new(0),
        page: RefCell::new(Page::None),
        back_stack: RefCell::new(Vec::new()),
        scanning: Arc::new(AtomicUsize::new(0)),
        scan_busy: Cell::new(false),
        tick: slint::Timer::default(),
        toast_timer: slint::Timer::default(),
        save_timer: slint::Timer::default(),
    });
    APP.with(|a| *a.borrow_mut() = Some(app.clone()));

    let g = ui.global::<Music>();
    g.set_albums(ModelRc::from(app.shelf_model.clone()));
    g.set_folder(folder.to_string_lossy().replace(&*kit::home().to_string_lossy(), "~").into());
    g.set_shuffle(app.shuffle.get());
    g.set_repeat(app.repeat.borrow().as_str().into());
    g.set_volume(app.volume.get());
    g.set_muted(app.muted.get());
    app.engine.send(Cmd::Volume(if app.muted.get() { 0.0 } else { app.volume.get() / 100.0 }));

    // What we knew last time, at once; then a look for what changed.
    let cached: Vec<Song> = library::load_cache().into_iter().filter(|s| Path::new(&s.path).starts_with(&folder)).collect();
    *app.songs.borrow_mut() = cached;
    *app.queue.borrow_mut() = app.indices(&saved.queue);
    *app.order.borrow_mut() = app.indices(&saved.order);
    app.at.set(saved.at.filter(|&a| a < app.queue.borrow().len()));
    app.arrange();
    if app.current().is_some() {
        g.set_pos(saved.pos as f32);
        g.set_pos_text(kit::clock(saved.pos).into());
    }
    app.rescan();

    // The bus.
    let tx = mpris::serve(
        |r| {
            let _ = slint::invoke_from_event_loop(move || {
                APP.with(|a| {
                    if let Some(a) = a.borrow().as_ref().cloned() {
                        a.remote(r);
                    }
                })
            });
        },
        // Read from the bus's thread: the engine's own clock.
        app.engine.clock(),
    );
    *app.mpris.borrow_mut() = tx;
    app.tell_bus();

    let a = app.clone();
    g.on_go(move |v| a.go(&v));
    let a = app.clone();
    g.on_back(move || a.back());
    let a = app.clone();
    g.on_open_album(move |k| a.show_album(&k, true));
    let a = app.clone();
    g.on_open_artist(move |n| a.show_artist(&n, true));
    let a = app.clone();
    g.on_open_now(move || a.go("queue"));
    let a = app.clone();
    g.on_play_song(move |id, from| {
        let id = id.max(0) as usize;
        match from.as_str() {
            "queue" => {
                if id < a.queue.borrow().len() {
                    a.at.set(Some(id));
                    a.load(true, 0.0);
                }
            }
            "album" => {
                let key = match &*a.page.borrow() {
                    Page::Album(k) => k.clone(),
                    _ => return,
                };
                let list = a.album_index.borrow().get(&key).map(|&i| a.albums.borrow()[i].songs.clone()).unwrap_or_default();
                let start = list.iter().position(|&x| x == id);
                a.play_list(list, start, a.shuffle.get());
            }
            _ => {
                let list = a.listed.borrow().clone();
                let start = list.iter().position(|&x| x == id);
                a.play_list(list, start, a.shuffle.get());
            }
        }
        a.g().set_shuffle(a.shuffle.get());
    });
    let a = app.clone();
    g.on_play_page(move |shuffled| {
        let page = a.page.borrow().clone();
        let list = match page {
            Page::Album(k) => a.album_index.borrow().get(&k).map(|&i| a.albums.borrow()[i].songs.clone()).unwrap_or_default(),
            Page::Artist(n) => a.artist_songs(&n),
            Page::None => return,
        };
        a.play_list(list, None, shuffled);
        a.g().set_shuffle(shuffled);
    });
    let a = app.clone();
    g.on_play_all(move |shuffled| {
        let list: Vec<usize> = a.albums.borrow().iter().flat_map(|al| al.songs.iter().copied()).collect();
        a.play_list(list, None, shuffled);
        a.g().set_shuffle(shuffled);
    });
    let a = app.clone();
    g.on_toggle(move || a.toggle());
    let a = app.clone();
    g.on_next(move || a.advance(true));
    let a = app.clone();
    g.on_prev(move || a.prev());
    let a = app.clone();
    g.on_seek(move |t| a.seek(t as f64));
    let a = app.clone();
    g.on_set_volume(move |v| a.set_volume(v));
    let a = app.clone();
    g.on_toggle_mute(move || {
        a.muted.set(!a.muted.get());
        let v = a.volume.get();
        let m = a.muted.get();
        a.g().set_muted(m);
        a.engine.send(Cmd::Volume(if m { 0.0 } else { v / 100.0 }));
        a.tell_bus();
        a.save_soon();
    });
    let a = app.clone();
    g.on_toggle_shuffle(move || a.set_shuffle(!a.shuffle.get()));
    let a = app.clone();
    g.on_cycle_repeat(move || {
        let next = match a.repeat.borrow().as_str() {
            "off" => "all",
            "all" => "one",
            _ => "off",
        };
        a.set_repeat(next);
    });
    let a = app.clone();
    g.on_song_action(move |id, slot, act| a.song_action(id.max(0) as usize, slot, act));
    let a = app.clone();
    g.on_clear_queue(move || {
        // Keep what's playing; drop what's after it.
        if let Some(at) = a.at.get() {
            let cur = a.queue.borrow()[at];
            *a.queue.borrow_mut() = vec![cur];
            *a.order.borrow_mut() = vec![cur];
            a.at.set(Some(0));
        }
        a.show_queue();
        a.tell_bus();
        a.save_soon();
    });
    let a = app.clone();
    g.on_search_edited(move |q| a.search(&q));
    let a = app.clone();
    g.on_albums_in_view(move |x, y| a.albums_in_view(x, y));
    let a = app.clone();
    g.on_rescan(move || a.rescan());
    let a = app.clone();
    g.on_pick_folder(move || {
        let b = a.clone();
        kit::spawn(
            || kit::portal::open_folder("Choose your music folder"),
            move |p| {
                let Some(p) = p else { return };
                *b.folder.borrow_mut() = p.clone();
                b.g().set_folder(p.to_string_lossy().replace(&*kit::home().to_string_lossy(), "~").into());
                b.art.borrow_mut().clear();
                b.art_used.borrow_mut().clear();
                b.art_none.borrow_mut().clear();
                b.set_songs(Vec::new());
                b.save();
                b.rescan();
            },
        );
    });
    let a = app.clone();
    g.on_open_files(move || {
        let b = a.clone();
        kit::spawn(
            || {
                let pats: Vec<String> = library::AUDIO.iter().flat_map(|e| [format!("*.{e}"), format!("*.{}", e.to_uppercase())]).collect();
                let pats: Vec<&str> = pats.iter().map(String::as_str).collect();
                kit::portal::open_files("Open music", &[("Music", pats.as_slice()), ("All files", &["*"][..])])
            },
            move |files| {
                if !files.is_empty() {
                    b.open_paths(files, false);
                }
            },
        );
    });

    // Files given on the command line.
    if !args.is_empty() {
        let a = app.clone();
        let files: Vec<PathBuf> = args.iter().map(|p| std::fs::canonicalize(p).unwrap_or_else(|_| p.clone())).collect();
        slint::Timer::single_shot(Duration::from_millis(50), move || a.open_paths(files, false));
    }

    // Save where we are now and then while playing, and on the way out.
    let a = app.clone();
    let keep = slint::Timer::default();
    keep.start(slint::TimerMode::Repeated, Duration::from_secs(10), move || {
        if a.g().get_playing() {
            a.save();
        }
    });
    ui.run().expect("run");
    app.save();
    library::save_cache(&app.songs.borrow());
}
