//! Chats: WhatsApp in the shell's own window.
//!
//! This is the window; hyprshell-chatsd (daemon/, Go) is the WhatsApp side —
//! a linked device, like WhatsApp Web, that keeps the encrypted session, the
//! messages and the notifications whether or not this window is open. The
//! two talk over a Unix socket (client.rs).
//!
//!   hyprshell-chats              open (a second one brings the first forward)
//!   hyprshell-chats --chat JID   open on a chat (what a notification does)
//!   hyprshell-chats --demo       made-up chats, nothing linked

slint::include_modules!();

mod client;
mod voice;

use hyprshell_audio::engine::{Cmd, Engine, Event, Who};
use hyprshell_audio::record::Recording;
use hyprshell_kit as kit;
use serde::Deserialize;
use serde_json::{json, Value};
use slint::{Color, ComponentHandle, Image, Model, ModelRc, Rgba8Pixel, SharedPixelBuffer, Timer, TimerMode, VecModel};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

// ── what the daemon sends ───────────────────────────────────────────────

#[derive(Deserialize, Clone, Default, Debug)]
#[serde(default, rename_all = "camelCase")]
struct ChatD {
    jid: String,
    name: String,
    is_group: bool,
    last_ts: i64,
    preview: String,
    preview_kind: String,
    preview_me: bool,
    preview_who: String,
    preview_status: i32,
    unread: i32,
    muted_until: i64,
    pinned: bool,
    archived: bool,
    avatar: String,
}

#[derive(Deserialize, Clone, Default, Debug)]
#[serde(default)]
struct MediaD {
    mime: String,
    size: i64,
    w: i32,
    h: i32,
    seconds: i32,
    name: String,
    thumb: String,
    path: String,
    waveform: Vec<i32>,
    failed: String,
}

#[derive(Deserialize, Clone, Default, Debug)]
#[serde(default, rename_all = "camelCase")]
struct QuoteD {
    id: String,
    sender: String,
    sender_name: String,
    from_me: bool,
    text: String,
    kind: String,
}

#[derive(Deserialize, Clone, Default, Debug)]
#[serde(default, rename_all = "camelCase")]
struct ReactionD {
    emoji: String,
    sender: String,
    from_me: bool,
}

#[derive(Deserialize, Clone, Default, Debug)]
#[serde(default, rename_all = "camelCase")]
struct MsgD {
    chat: String,
    id: String,
    sender: String,
    sender_name: String,
    from_me: bool,
    ts: i64,
    kind: String,
    text: String,
    media: Option<MediaD>,
    quote: Option<QuoteD>,
    reactions: Vec<ReactionD>,
    status: i32,
    edited: bool,
}

fn parse<T: for<'a> Deserialize<'a>>(v: &Value) -> Option<T> {
    serde_json::from_value(v.clone()).ok()
}

// ── how things look ─────────────────────────────────────────────────────

/// A person's or group's colour, the same every time.
fn tint(key: &str) -> Color {
    const T: [(u8, u8, u8); 10] = [
        (0xe5, 0x6b, 0x5b), (0xd9, 0x8a, 0x3d), (0xc9, 0xa2, 0x27), (0x6e, 0xa8, 0x4f), (0x3f, 0xa8, 0x8c),
        (0x3d, 0x9b, 0xc9), (0x5b, 0x7f, 0xe0), (0x8e, 0x6b, 0xd9), (0xc2, 0x5b, 0xb0), (0xd9, 0x5b, 0x83),
    ];
    let h = key.bytes().fold(5381u32, |h, b| h.wrapping_mul(33) ^ b as u32);
    let (r, g, b) = T[(h % T.len() as u32) as usize];
    Color::from_rgb_u8(r, g, b)
}

fn initials(name: &str) -> String {
    let n = name.trim_start_matches('~');
    if n.starts_with('+') || n.is_empty() || n.chars().next().is_some_and(|c| c.is_ascii_digit()) {
        return String::new();
    }
    n.split_whitespace()
        .filter_map(|w| w.chars().find(|c| c.is_alphanumeric()))
        .take(2)
        .flat_map(|c| c.to_uppercase())
        .collect()
}

fn hhmm(ms: i64) -> String {
    let (_, _, _, h, m, _) = kit::local(ms / 1000);
    format!("{h:02}:{m:02}")
}

fn day_of(ms: i64) -> (i32, u32, u32) {
    let (y, m, d, ..) = kit::local(ms / 1000);
    (y, m, d)
}

fn day_label(ms: i64) -> String {
    let today = day_of(kit::now() * 1000);
    let yesterday = day_of((kit::now() - 86400) * 1000);
    let d = day_of(ms);
    if d == today {
        "Today".into()
    } else if d == yesterday {
        "Yesterday".into()
    } else {
        let s = kit::when(ms / 1000);
        if s.contains(':') { "Today".into() } else { s }
    }
}

/// One to three emoji and nothing else.
fn only_emoji(text: &str) -> bool {
    let t = text.trim();
    if t.is_empty() || t.chars().count() > 24 {
        return false;
    }
    let mut pictures = 0;
    for c in t.chars() {
        let u = c as u32;
        let picture = (0x1F000..=0x1FAFF).contains(&u) || (0x2600..=0x27BF).contains(&u) || (0x2B00..=0x2BFF).contains(&u);
        let joiner = u == 0x200D || u == 0xFE0F || (0x1F3FB..=0x1F3FF).contains(&u) || (0xE0020..=0xE007F).contains(&u) || c == ' ';
        if picture {
            pictures += 1;
        } else if !joiner {
            return false;
        }
    }
    (1..=3).contains(&pictures)
}

fn kind_icon(kind: &str) -> &'static str {
    match kind {
        "image" => "image",
        "video" | "gif" => "film",
        "voice" => "mic",
        "audio" => "music",
        "document" => "file",
        "sticker" => "sparkle",
        "location" => "pin",
        "contact" => "user",
        "poll" => "listChecks",
        "deleted" => "x",
        _ => "",
    }
}

fn file_icon(m: &MsgD) -> &'static str {
    let mime = m.media.as_ref().map(|x| x.mime.as_str()).unwrap_or("");
    match m.kind.as_str() {
        "audio" => "music",
        "video" | "gif" => "play",
        _ if mime.contains("pdf") => "pdf",
        _ if mime.starts_with("image/") => "image",
        _ if mime.contains("zip") || mime.contains("compressed") => "archive",
        _ => "file",
    }
}

// ── the app ─────────────────────────────────────────────────────────────

struct Rec {
    _rec: Recording,
    samples: Arc<Mutex<Vec<f32>>>,
    levels: Arc<Mutex<Vec<f32>>>,
    started: Instant,
}

struct App {
    ui: AppWindow,
    state: RefCell<String>,
    me: RefCell<String>,
    chats: RefCell<Vec<ChatD>>,
    current: RefCell<String>,
    msgs: RefCell<Vec<MsgD>>,
    typing: RefCell<HashMap<String, (String, bool, Instant)>>,
    images: RefCell<HashMap<String, Option<(Image, u32, u32)>>>,
    reply_to: RefCell<Option<String>>,
    focused: Cell<bool>,
    to_open: RefCell<HashSet<String>>,
    loading: RefCell<HashSet<String>>,
    avatars_asked: RefCell<HashSet<String>>,
    engine: Engine,
    playing: RefCell<Option<(String, f64)>>,
    play_tick: Timer,
    rec: RefCell<Option<Rec>>,
    rec_tick: Timer,
    typing_sent: Cell<Option<Instant>>,
    typing_off: Timer,
    toast_timer: Timer,
    tick: Timer,
    soon_msgs: Timer,
    soon_chats: Timer,
    open_chat: RefCell<Option<String>>,
}

thread_local! {
    static APP: RefCell<Option<Rc<App>>> = const { RefCell::new(None) };
}

fn with_app(f: impl FnOnce(&Rc<App>)) {
    let a = APP.with(|a| a.borrow().clone());
    if let Some(a) = a {
        f(&a);
    }
}

fn cache_dir() -> PathBuf {
    let base = std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from).unwrap_or_else(|| kit::home().join(".cache"));
    base.join("hyprshell-chats")
}

impl App {
    fn g(&self) -> Chats<'_> {
        self.ui.global::<Chats>()
    }

    fn toast(self: &Rc<Self>, text: &str, bad: bool) {
        self.g().set_toast(text.into());
        self.g().set_toast_bad(bad);
        let w = Rc::downgrade(self);
        self.toast_timer.start(TimerMode::SingleShot, Duration::from_millis(3200), move || {
            if let Some(a) = w.upgrade() {
                a.g().set_toast("".into());
            }
        });
    }

    fn set_state(self: &Rc<Self>, st: &str, err: &str) {
        *self.state.borrow_mut() = st.to_string();
        self.g().set_state(st.into());
        self.g().set_error(err.into());
        if st == "pairing" {
            self.g().set_has_qr(false);
            self.g().set_pair_code("".into());
            if !err.is_empty() {
                self.g().set_pair_note("".into());
            }
        }
    }

    // ── pictures ────────────────────────────────────────────────────────

    /// A picture from disk, made small enough to keep, in the background;
    /// the lists are redrawn when it's ready.
    fn image(self: &Rc<Self>, path: &str, edge: u32) -> Option<(Image, u32, u32)> {
        if path.is_empty() {
            return None;
        }
        let key = format!("{path}@{edge}");
        if let Some(v) = self.images.borrow().get(&key) {
            return v.clone();
        }
        self.images.borrow_mut().insert(key.clone(), None);
        let p = path.to_string();
        let w = Rc::downgrade(self);
        kit::spawn(
            move || {
                let img = image::ImageReader::open(&p).ok()?.with_guessed_format().ok()?.decode().ok()?;
                let (ow, oh) = (img.width(), img.height());
                let img = if ow > edge || oh > edge { img.thumbnail(edge, edge) } else { img };
                let rgba = img.to_rgba8();
                let (w, h) = rgba.dimensions();
                let buf = SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(rgba.as_raw(), w, h);
                Some((buf, ow, oh))
            },
            move |r| {
                let Some(a) = w.upgrade() else { return };
                if let Some((buf, ow, oh)) = r {
                    a.images.borrow_mut().insert(key, Some((Image::from_rgba8(buf), ow, oh)));
                    a.redraw_soon();
                }
            },
        );
        None
    }

    fn redraw_soon(self: &Rc<Self>) {
        let w = Rc::downgrade(self);
        self.soon_msgs.start(TimerMode::SingleShot, Duration::from_millis(40), move || {
            if let Some(a) = w.upgrade() {
                a.show_messages();
                a.show_chats();
            }
        });
    }

    // ── the list ────────────────────────────────────────────────────────

    fn chats_soon(self: &Rc<Self>) {
        let w = Rc::downgrade(self);
        self.soon_chats.start(TimerMode::SingleShot, Duration::from_millis(30), move || {
            if let Some(a) = w.upgrade() {
                a.show_chats();
            }
        });
    }

    fn typing_text(&self, jid: &str, group: bool) -> String {
        match self.typing.borrow().get(jid) {
            Some((who, audio, _)) => {
                let what = if *audio { "recording audio…" } else { "typing…" };
                if group && !who.is_empty() { format!("{who} is {what}") } else { what.to_string() }
            }
            None => String::new(),
        }
    }

    fn show_chats(self: &Rc<Self>) {
        let g = self.g();
        let filter = g.get_filter().to_lowercase();
        let archived = g.get_show_archived();
        let now = now_ms();
        let chats = self.chats.borrow();
        let mut list: Vec<&ChatD> = chats
            .iter()
            .filter(|c| (c.last_ts > 0 || c.pinned) && c.archived == archived)
            .filter(|c| filter.is_empty() || c.name.to_lowercase().contains(&filter) || c.jid.contains(&filter))
            .collect();
        list.sort_by(|a, b| b.pinned.cmp(&a.pinned).then(b.last_ts.cmp(&a.last_ts)));
        let mut ask = Vec::new();
        let rows: Vec<ChatItem> = list
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let avatar = self.image(&c.avatar, 128);
                if c.avatar.is_empty() && i < 40 && !self.avatars_asked.borrow().contains(&c.jid) {
                    ask.push(c.jid.clone());
                }
                ChatItem {
                    jid: c.jid.clone().into(),
                    name: c.name.clone().into(),
                    initials: initials(&c.name).into(),
                    tint: tint(&c.jid),
                    has_avatar: avatar.is_some(),
                    avatar: avatar.map(|a| a.0).unwrap_or_default(),
                    time: if c.last_ts > 0 { kit::when(c.last_ts / 1000).into() } else { "".into() },
                    preview: c.preview.clone().into(),
                    preview_icon: kind_icon(&c.preview_kind).into(),
                    preview_who: if c.is_group && !c.preview_me { c.preview_who.trim_start_matches('~').into() } else { "".into() },
                    ticks: if c.preview_me && c.preview_kind != "deleted" { c.preview_status } else { -2 },
                    unread: c.unread,
                    muted: c.muted_until > now,
                    pinned: c.pinned,
                    group: c.is_group,
                    typing: self.typing_text(&c.jid, c.is_group).into(),
                    archived: c.archived,
                }
            })
            .collect();
        let archived_count = chats.iter().filter(|c| c.archived && c.last_ts > 0).count();
        drop(chats);
        g.set_chats(ModelRc::new(VecModel::from(rows)));
        g.set_archived_count(archived_count as i32);
        // Pictures for the chats in view, one request at a time (the daemon
        // spaces them out).
        for jid in ask {
            self.avatars_asked.borrow_mut().insert(jid.clone());
            let w = Rc::downgrade(self);
            let j = jid.clone();
            client::request("avatar", json!({ "jid": jid }), move |r| {
                let (Some(a), Some(p)) = (w.upgrade(), r["path"].as_str()) else { return };
                if p.is_empty() {
                    return;
                }
                if let Some(c) = a.chats.borrow_mut().iter_mut().find(|c| c.jid == j) {
                    c.avatar = p.to_string();
                }
                a.chats_soon();
            });
        }
        self.show_header();
    }

    fn reload_chats(self: &Rc<Self>) {
        let w = Rc::downgrade(self);
        client::request("chats", json!({}), move |r| {
            let Some(a) = w.upgrade() else { return };
            if let Some(list) = r["chats"].as_array() {
                *a.chats.borrow_mut() = list.iter().filter_map(parse::<ChatD>).collect();
                a.show_chats();
                if let Some(jid) = a.open_chat.borrow_mut().take() {
                    a.open(&jid);
                }
            }
        });
    }

    fn upsert_chat(self: &Rc<Self>, c: ChatD) {
        {
            let mut list = self.chats.borrow_mut();
            match list.iter_mut().find(|x| x.jid == c.jid) {
                Some(x) => *x = c,
                None => list.push(c),
            }
        }
        self.chats_soon();
    }

    // ── the open chat ───────────────────────────────────────────────────

    fn current_chat(&self) -> Option<ChatD> {
        let cur = self.current.borrow();
        self.chats.borrow().iter().find(|c| c.jid == *cur).cloned()
    }

    fn show_header(self: &Rc<Self>) {
        let g = self.g();
        let cur = self.current.borrow().clone();
        if cur.is_empty() {
            return;
        }
        let c = self.current_chat().unwrap_or(ChatD { jid: cur.clone(), name: cur.split('@').next().map(|n| format!("+{n}")).unwrap_or_default(), ..Default::default() });
        g.set_current_name(c.name.clone().into());
        g.set_current_initials(initials(&c.name).into());
        g.set_current_tint(tint(&c.jid));
        g.set_current_group(c.is_group || c.jid.ends_with("@g.us"));
        let av = self.image(&c.avatar, 128);
        g.set_current_has_avatar(av.is_some());
        g.set_current_avatar(av.map(|a| a.0).unwrap_or_default());
        let typing = self.typing_text(&c.jid, c.is_group);
        g.set_current_sub(
            if !typing.is_empty() {
                typing
            } else if c.is_group {
                "Group".to_string()
            } else if c.jid.ends_with("@s.whatsapp.net") {
                format!("+{}", c.jid.split('@').next().unwrap_or(""))
            } else {
                String::new()
            }
            .into(),
        );
    }

    fn open(self: &Rc<Self>, jid: &str) {
        if jid.is_empty() {
            return;
        }
        let same = *self.current.borrow() == jid;
        *self.current.borrow_mut() = jid.to_string();
        let g = self.g();
        g.set_current(jid.into());
        if !same {
            *self.reply_to.borrow_mut() = None;
            g.set_replying(false);
            g.set_draft("".into());
            self.msgs.borrow_mut().clear();
            g.set_messages(ModelRc::default());
            g.set_stick(true);
            self.stop_playing();
        }
        // Show it even if it's archived and the list isn't.
        if let Some(c) = self.current_chat() {
            if c.archived != g.get_show_archived() {
                g.set_show_archived(c.archived);
                self.show_chats();
            }
        }
        self.show_header();
        let w = Rc::downgrade(self);
        let j = jid.to_string();
        client::request("messages", json!({ "chat": jid, "limit": 80 }), move |r| {
            let Some(a) = w.upgrade() else { return };
            if *a.current.borrow() != j {
                return;
            }
            let list: Vec<MsgD> = r["messages"].as_array().map(|l| l.iter().filter_map(parse).collect()).unwrap_or_default();
            a.g().set_more_above(list.len() >= 80);
            *a.msgs.borrow_mut() = list;
            a.g().set_stick(true);
            a.show_messages();
            a.to_bottom();
        });
        self.tell_view();
        self.mark_read();
        self.ui.invoke_focus_composer();
    }

    fn older(self: &Rc<Self>) {
        let before = self.msgs.borrow().first().map(|m| m.ts).unwrap_or(0);
        if before == 0 {
            return;
        }
        let w = Rc::downgrade(self);
        let j = self.current.borrow().clone();
        client::request("messages", json!({ "chat": j, "before": before, "limit": 80 }), move |r| {
            let Some(a) = w.upgrade() else { return };
            if *a.current.borrow() != j {
                return;
            }
            let list: Vec<MsgD> = r["messages"].as_array().map(|l| l.iter().filter_map(parse).collect()).unwrap_or_default();
            a.g().set_more_above(list.len() >= 80);
            if list.is_empty() {
                return;
            }
            // Keep what's in view where it is as the older ones go in above.
            a.g().set_stick(false);
            a.g().set_prepending(true);
            {
                let mut msgs = a.msgs.borrow_mut();
                let mut all = list;
                all.extend(msgs.drain(..));
                *msgs = all;
            }
            a.show_messages();
        });
    }

    /// Down to the newest message, once the view has laid out (and again,
    /// in case pictures changed its height).
    fn to_bottom(self: &Rc<Self>) {
        for ms in [30u64, 200, 600] {
            let w = Rc::downgrade(self);
            Timer::single_shot(Duration::from_millis(ms), move || {
                if let Some(a) = w.upgrade() {
                    let g = a.g();
                    g.set_bottom_request(g.get_bottom_request() + 1);
                }
            });
        }
    }

    fn mark_read(self: &Rc<Self>) {
        if !self.focused.get() {
            return;
        }
        let Some(c) = self.current_chat() else { return };
        if c.unread > 0 {
            client::tell("read", json!({ "chat": c.jid }));
        }
    }

    fn tell_view(&self) {
        client::tell("view", json!({ "chat": *self.current.borrow(), "focused": self.focused.get() }));
    }

    fn name_for(&self, jid: &str, fallback: &str) -> String {
        if jid == *self.me.borrow() {
            return "You".into();
        }
        if let Some(c) = self.chats.borrow().iter().find(|c| c.jid == jid) {
            if !c.name.is_empty() {
                return c.name.clone();
            }
        }
        if !fallback.is_empty() {
            return fallback.trim_start_matches('~').to_string();
        }
        jid.split('@').next().map(|n| format!("+{n}")).unwrap_or_default()
    }

    fn show_messages(self: &Rc<Self>) {
        let msgs = self.msgs.borrow();
        let playing = self.playing.borrow().clone();
        let pos = self.engine.position();
        let mut out = Vec::with_capacity(msgs.len());
        let mut prev: Option<&MsgD> = None;
        for m in msgs.iter() {
            let day = match prev {
                Some(p) if day_of(p.ts) == day_of(m.ts) => String::new(),
                _ => day_label(m.ts),
            };
            let first = !day.is_empty() || prev.is_none_or(|p| p.from_me != m.from_me || p.sender != m.sender || m.ts - p.ts > 10 * 60_000);
            let media = m.media.clone().unwrap_or_default();
            // The picture: the file once it's here, its little preview until then.
            let pictured = matches!(m.kind.as_str(), "image" | "sticker" | "video" | "gif");
            let mut pic: Option<(Image, u32, u32)> = None;
            if pictured {
                if !media.path.is_empty() && m.kind != "video" && m.kind != "gif" {
                    pic = self.image(&media.path, 720);
                }
                if pic.is_none() && !media.thumb.is_empty() {
                    pic = self.image(&media.thumb, 360);
                }
            }
            let (mut pw, mut ph) = (media.w as f32, media.h as f32);
            if (pw <= 0.0 || ph <= 0.0) && pic.is_some() {
                let p = pic.as_ref().unwrap();
                pw = p.1 as f32;
                ph = p.2 as f32;
            }
            if pw <= 0.0 || ph <= 0.0 {
                pw = 280.0;
                ph = 210.0;
            }
            // Shown at most 320 wide and 360 tall; stickers small.
            let (mut dw, mut dh) = if m.kind == "sticker" { (150.0, 150.0 * ph / pw) } else { (pw.min(320.0), pw.min(320.0) * ph / pw) };
            if dh > 360.0 {
                dw *= 360.0 / dh;
                dh = 360.0;
            }
            let quote = m.quote.clone();
            let (quote_name, quote_tint) = match &quote {
                Some(q) if q.from_me => ("You".to_string(), self.ui.global::<Theme>().get_accent()),
                Some(q) => (self.name_for(&q.sender, &q.sender_name), tint(&q.sender)),
                None => (String::new(), Color::default()),
            };
            let mut reactions: Vec<ReactionChip> = Vec::new();
            for r in &m.reactions {
                match reactions.iter_mut().find(|x| x.emoji.as_str() == r.emoji) {
                    Some(x) => x.count += 1,
                    None => reactions.push(ReactionChip { emoji: r.emoji.clone().into(), count: 1 }),
                }
            }
            let is_playing = playing.as_ref().is_some_and(|p| p.0 == m.id);
            let wave: Vec<f32> = if media.waveform.is_empty() {
                (0..48).map(|i| 0.25 + 0.2 * ((i as f32 * 0.7).sin().abs())).collect()
            } else {
                media.waveform.iter().map(|v| (*v as f32 / 100.0).clamp(0.08, 1.0)).collect()
            };
            let loading = self.loading.borrow().contains(&m.id);
            out.push(Bubble {
                id: m.id.clone().into(),
                mine: m.from_me,
                kind: m.kind.clone().into(),
                text: m.text.clone().into(),
                time: hhmm(m.ts).into(),
                status: m.status,
                sender: self.name_for(&m.sender, &m.sender_name).into(),
                sender_tint: tint(&m.sender),
                first,
                day: day.into(),
                has_picture: pic.is_some(),
                picture: pic.map(|p| p.0).unwrap_or_default(),
                pic_w: dw,
                pic_h: dh,
                file_name: if !media.name.is_empty() {
                    media.name.clone().into()
                } else if m.kind == "audio" {
                    "Audio".into()
                } else if m.kind == "video" || m.kind == "gif" {
                    "Video".into()
                } else {
                    "Document".into()
                },
                file_sub: {
                    let mut parts = Vec::new();
                    if media.size > 0 {
                        parts.push(kit::bytes(media.size as u64));
                    }
                    if media.seconds > 0 {
                        parts.push(kit::clock(media.seconds as f64));
                    }
                    if let Some(ext) = media.name.rsplit_once('.').map(|x| x.1.to_uppercase()).filter(|e| e.len() <= 5) {
                        parts.push(ext);
                    }
                    parts.join(" · ").into()
                },
                file_icon: file_icon(m).into(),
                media_state: if loading { "loading".into() } else if !media.failed.is_empty() && media.path.is_empty() { "failed".into() } else { "".into() },
                media_note: media.failed.clone().into(),
                has_quote: quote.is_some(),
                quote_name: quote_name.into(),
                quote_text: quote.as_ref().map(|q| q.text.clone()).unwrap_or_default().into(),
                quote_tint,
                reactions: ModelRc::new(VecModel::from(reactions)),
                big_emoji: m.kind == "text" && m.quote.is_none() && only_emoji(&m.text),
                edited: m.edited,
                wave: ModelRc::new(VecModel::from(wave)),
                seconds: if is_playing {
                    kit::clock(pos).into()
                } else {
                    kit::clock(media.seconds.max(0) as f64).into()
                },
                playing: is_playing,
                progress: match &playing {
                    Some((id, dur)) if *id == m.id && *dur > 0.0 => (pos / dur) as f32,
                    _ => 0.0,
                },
            });
            prev = Some(m);
        }
        drop(msgs);
        let g = self.g();
        // Same count: update in place, so the view doesn't jump.
        let model = g.get_messages();
        if model.row_count() == out.len() && out.len() > 0 {
            if let Some(vm) = model.as_any().downcast_ref::<VecModel<Bubble>>() {
                for (i, b) in out.into_iter().enumerate() {
                    if vm.row_data(i).as_ref() != Some(&b) {
                        vm.set_row_data(i, b);
                    }
                }
                return;
            }
        }
        g.set_messages(ModelRc::new(VecModel::from(out)));
    }

    fn upsert_message(self: &Rc<Self>, m: MsgD) {
        if m.chat != *self.current.borrow() {
            return;
        }
        {
            let mut msgs = self.msgs.borrow_mut();
            match msgs.iter_mut().find(|x| x.id == m.id) {
                Some(x) => *x = m.clone(),
                None => {
                    let at = msgs.iter().rposition(|x| x.ts <= m.ts).map(|i| i + 1).unwrap_or(0);
                    msgs.insert(at, m.clone());
                }
            }
        }
        if m.media.as_ref().is_some_and(|x| !x.path.is_empty() || !x.failed.is_empty()) {
            self.loading.borrow_mut().remove(&m.id);
            if self.to_open.borrow_mut().remove(&m.id) {
                if let Some(md) = &m.media {
                    if !md.path.is_empty() {
                        open_path(&md.path);
                    } else if !md.failed.is_empty() {
                        self.toast(&md.failed, true);
                    }
                }
            }
        }
        self.show_messages();
        // Your own just sent: down to it.
        if m.from_me && m.status == 0 {
            self.to_bottom();
        }
        if !m.from_me {
            self.mark_read();
        }
    }

    fn msg(&self, id: &str) -> Option<MsgD> {
        self.msgs.borrow().iter().find(|m| m.id == id).cloned()
    }

    // ── doing things ────────────────────────────────────────────────────

    fn send(self: &Rc<Self>) {
        let g = self.g();
        let text = g.get_draft().trim_end().to_string();
        if text.trim().is_empty() {
            return;
        }
        let chat = self.current.borrow().clone();
        let quote = self.reply_to.borrow_mut().take().unwrap_or_default();
        g.set_replying(false);
        g.set_draft("".into());
        self.typing_sent.set(None);
        self.typing_off.stop();
        let w = Rc::downgrade(self);
        client::request("send", json!({ "chat": chat, "text": text, "quote": quote }), move |r| {
            let Some(a) = w.upgrade() else { return };
            if r["ok"] != json!(true) {
                // Put it back, so nothing typed is lost.
                if a.g().get_draft().is_empty() {
                    a.g().set_draft(text.into());
                }
                a.toast(r["error"].as_str().unwrap_or("Couldn't send"), true);
            }
        });
    }

    fn send_file(self: &Rc<Self>, path: PathBuf, voice: Option<(i32, Vec<i32>)>) {
        let chat = self.current.borrow().clone();
        let mut args = json!({ "chat": chat, "path": path.to_string_lossy() });
        if let Some((secs, wave)) = voice {
            args["voice"] = json!(true);
            args["seconds"] = json!(secs);
            args["waveform"] = json!(wave);
        }
        self.g().set_sending_file(true);
        let w = Rc::downgrade(self);
        client::request("sendFile", args, move |r| {
            let Some(a) = w.upgrade() else { return };
            a.g().set_sending_file(false);
            if r["ok"] != json!(true) {
                a.toast(r["error"].as_str().unwrap_or("Couldn't send it"), true);
            }
        });
    }

    fn attach(self: &Rc<Self>) {
        let w = Rc::downgrade(self);
        kit::spawn(
            || kit::portal::open_files("Send files", &[("All files", &["*"][..]), ("Pictures", &["*.jpg", "*.jpeg", "*.png"][..])]),
            move |files| {
                let Some(a) = w.upgrade() else { return };
                for f in files {
                    a.send_file(f, None);
                }
            },
        );
    }

    fn edited(self: &Rc<Self>) {
        // "typing…" for the other side, at most every few seconds, and
        // "paused" when you stop.
        let now = Instant::now();
        if self.typing_sent.get().is_none_or(|t| now - t > Duration::from_secs(4)) {
            self.typing_sent.set(Some(now));
            client::tell("typing", json!({ "chat": *self.current.borrow(), "on": true }));
        }
        let w = Rc::downgrade(self);
        self.typing_off.start(TimerMode::SingleShot, Duration::from_secs(5), move || {
            if let Some(a) = w.upgrade() {
                a.typing_sent.set(None);
                client::tell("typing", json!({ "chat": *a.current.borrow(), "on": false }));
            }
        });
    }

    fn open_media(self: &Rc<Self>, id: &str) {
        let Some(m) = self.msg(id) else { return };
        let media = m.media.clone().unwrap_or_default();
        if !media.path.is_empty() && Path::new(&media.path).exists() {
            open_path(&media.path);
            return;
        }
        self.to_open.borrow_mut().insert(m.id.clone());
        self.download(&m);
    }

    fn download(self: &Rc<Self>, m: &MsgD) {
        self.loading.borrow_mut().insert(m.id.clone());
        self.show_messages();
        let w = Rc::downgrade(self);
        let id = m.id.clone();
        client::request("download", json!({ "chat": m.chat, "msg": m.id }), move |r| {
            let Some(a) = w.upgrade() else { return };
            a.loading.borrow_mut().remove(&id);
            if r["ok"] != json!(true) {
                a.to_open.borrow_mut().remove(&id);
                a.toast(r["error"].as_str().unwrap_or("Couldn't download it"), true);
            } else if let Some(m) = r.get("msg").and_then(|v| parse::<MsgD>(v)) {
                a.upsert_message(m);
            }
            a.show_messages();
        });
    }

    fn save_media(self: &Rc<Self>, id: &str) {
        let Some(m) = self.msg(id) else { return };
        let media = m.media.clone().unwrap_or_default();
        if media.path.is_empty() {
            self.toast("Downloading it first — try again in a moment", false);
            self.download(&m);
            return;
        }
        let downloads = kit::home().join("Downloads");
        let _ = std::fs::create_dir_all(&downloads);
        let name = if !media.name.is_empty() {
            media.name.clone()
        } else {
            let ext = Path::new(&media.path).extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
            let (y, mo, d, h, mi, _) = kit::local(m.ts / 1000);
            format!("WhatsApp {} {y}-{mo:02}-{d:02} {h:02}.{mi:02}.{ext}", if m.kind == "image" { "Image" } else { "File" })
        };
        let mut dst = downloads.join(&name);
        let mut n = 2;
        while dst.exists() {
            let (stem, ext) = name.rsplit_once('.').map(|(s, e)| (s.to_string(), format!(".{e}"))).unwrap_or((name.clone(), String::new()));
            dst = downloads.join(format!("{stem} ({n}){ext}"));
            n += 1;
        }
        match std::fs::copy(&media.path, &dst) {
            Ok(_) => self.toast(&format!("Saved to Downloads as {}", dst.file_name().unwrap_or_default().to_string_lossy()), false),
            Err(e) => self.toast(&format!("Couldn't save it: {e}"), true),
        }
    }

    fn copy(self: &Rc<Self>, id: &str) {
        let Some(m) = self.msg(id) else { return };
        let text = m.text.clone();
        match std::process::Command::new("wl-copy").arg("--").arg(&text).spawn() {
            Ok(_) => self.toast("Copied", false),
            Err(_) => self.toast("Copying needs wl-clipboard (sudo pacman -S wl-clipboard)", true),
        }
    }

    fn reply(self: &Rc<Self>, id: &str) {
        let Some(m) = self.msg(id) else { return };
        let g = self.g();
        let name = if m.from_me { "You".into() } else { self.name_for(&m.sender, &m.sender_name) };
        let text = if !m.text.is_empty() {
            m.text.lines().next().unwrap_or("").to_string()
        } else {
            match m.kind.as_str() {
                "image" => "Photo".into(),
                "video" | "gif" => "Video".into(),
                "voice" => "Voice message".into(),
                "sticker" => "Sticker".into(),
                "document" => m.media.as_ref().map(|x| x.name.clone()).unwrap_or_else(|| "Document".into()),
                k => k.to_string(),
            }
        };
        g.set_reply_name(name.into());
        g.set_reply_text(text.into());
        g.set_reply_tint(if m.from_me { self.ui.global::<Theme>().get_accent() } else { tint(&m.sender) });
        g.set_replying(true);
        *self.reply_to.borrow_mut() = Some(m.id);
    }

    fn react(self: &Rc<Self>, id: &str, emoji: &str) {
        let Some(m) = self.msg(id) else { return };
        // Choosing your own reaction again takes it back.
        let mine = m.reactions.iter().find(|r| r.from_me).map(|r| r.emoji.clone());
        let emoji = if mine.as_deref() == Some(emoji) { "" } else { emoji };
        let w = Rc::downgrade(self);
        client::request("react", json!({ "chat": m.chat, "msg": m.id, "emoji": emoji }), move |r| {
            if r["ok"] != json!(true) {
                if let Some(a) = w.upgrade() {
                    a.toast(r["error"].as_str().unwrap_or("Couldn't react"), true);
                }
            }
        });
    }

    fn delete(self: &Rc<Self>, id: &str) {
        let Some(m) = self.msg(id) else { return };
        let w = Rc::downgrade(self);
        client::request("revoke", json!({ "chat": m.chat, "msg": m.id }), move |r| {
            if r["ok"] != json!(true) {
                if let Some(a) = w.upgrade() {
                    a.toast(r["error"].as_str().unwrap_or("Couldn't delete it"), true);
                }
            }
        });
    }

    // ── voice ───────────────────────────────────────────────────────────

    fn play(self: &Rc<Self>, id: &str) {
        if self.playing.borrow().as_ref().is_some_and(|p| p.0 == id) {
            self.stop_playing();
            self.show_messages();
            return;
        }
        let Some(m) = self.msg(id) else { return };
        let media = m.media.clone().unwrap_or_default();
        if media.path.is_empty() {
            self.download(&m);
            return;
        }
        self.stop_playing();
        let src = PathBuf::from(&media.path);
        let w = Rc::downgrade(self);
        let id = id.to_string();
        kit::spawn(
            move || voice::playable(&src, &cache_dir().join("voice")),
            move |r| {
                let Some(a) = w.upgrade() else { return };
                match r {
                    Ok(p) => {
                        let dur = hyprshell_audio::engine::peaks(&p, 1).map(|x| x.1).unwrap_or(media.seconds as f64);
                        a.engine.send(Cmd::Load { path: p, play: true, at: 0.0, token: 1 });
                        *a.playing.borrow_mut() = Some((id, dur));
                        let w = Rc::downgrade(&a);
                        a.play_tick.start(TimerMode::Repeated, Duration::from_millis(100), move || {
                            if let Some(a) = w.upgrade() {
                                a.show_messages();
                            }
                        });
                        a.show_messages();
                    }
                    Err(e) => a.toast(&e, true),
                }
            },
        );
    }

    fn stop_playing(&self) {
        if self.playing.borrow_mut().take().is_some() {
            self.engine.send(Cmd::Stop);
        }
        self.play_tick.stop();
    }

    fn record(self: &Rc<Self>) {
        if self.rec.borrow().is_some() {
            return;
        }
        self.stop_playing();
        let samples = Arc::new(Mutex::new(Vec::<f32>::new()));
        let levels = Arc::new(Mutex::new(Vec::<f32>::new()));
        let (s2, l2) = (samples.clone(), levels.clone());
        let mut acc: Vec<f32> = Vec::new();
        let rec = Recording::start(None, 1, 48_000, move |block: &[f32]| {
            s2.lock().unwrap().extend_from_slice(block);
            acc.extend_from_slice(block);
            // A bar every tenth of a second.
            while acc.len() >= 4800 {
                let rms = (acc[..4800].iter().map(|v| v * v).sum::<f32>() / 4800.0).sqrt();
                acc.drain(..4800);
                let mut l = l2.lock().unwrap();
                l.push((rms * 6.0).sqrt().clamp(0.06, 1.0));
                let n = l.len();
                if n > 80 {
                    l.drain(..n - 80);
                }
            }
        });
        match rec {
            Ok(r) => {
                *self.rec.borrow_mut() = Some(Rec { _rec: r, samples, levels, started: Instant::now() });
                self.g().set_recording(true);
                self.g().set_rec_time("0:00".into());
                let w = Rc::downgrade(self);
                self.rec_tick.start(TimerMode::Repeated, Duration::from_millis(100), move || {
                    let Some(a) = w.upgrade() else { return };
                    let rec = a.rec.borrow();
                    let Some(r) = rec.as_ref() else { return };
                    let secs = r.started.elapsed().as_secs_f64();
                    let mut l = r.levels.lock().unwrap().clone();
                    while l.len() < 80 {
                        l.insert(0, 0.06);
                    }
                    a.g().set_rec_time(kit::clock(secs).into());
                    a.g().set_rec_levels(ModelRc::new(VecModel::from(l)));
                });
            }
            Err(e) => self.toast(&format!("Couldn't use the microphone: {e}"), true),
        }
    }

    fn stop_recording(self: &Rc<Self>, send: bool) {
        self.rec_tick.stop();
        self.g().set_recording(false);
        let Some(r) = self.rec.borrow_mut().take() else { return };
        let secs = r.started.elapsed().as_secs_f64();
        let samples = std::mem::take(&mut *r.samples.lock().unwrap());
        drop(r);
        if !send {
            return;
        }
        if secs < 0.8 {
            self.toast("Hold on a little longer to record a voice message", false);
            return;
        }
        let dir = cache_dir().join("recordings");
        let _ = std::fs::create_dir_all(&dir);
        let out = dir.join(format!("voice-{}.ogg", now_ms()));
        let w = Rc::downgrade(self);
        kit::spawn(
            move || {
                let wave = voice::waveform(&samples);
                voice::encode(&samples, &out).map(|_| (out, wave))
            },
            move |r| {
                let Some(a) = w.upgrade() else { return };
                match r {
                    Ok((p, wave)) => a.send_file(p, Some((secs.round() as i32, wave))),
                    Err(e) => a.toast(&e, true),
                }
            },
        );
    }

    // ── what the daemon says ────────────────────────────────────────────

    fn event(self: &Rc<Self>, v: Value) {
        let ev = v["ev"].as_str().unwrap_or("");
        match ev {
            "state" => {
                let st = v["state"].as_str().unwrap_or("").to_string();
                let was = self.state.borrow().clone();
                self.set_state(&st, v["error"].as_str().unwrap_or(""));
                if let Some(me) = v["me"].as_str() {
                    *self.me.borrow_mut() = me.to_string();
                }
                if st == "pairing" && was != "pairing" && v["error"].as_str().unwrap_or("").is_empty() {
                    self.pair("");
                }
                if (st == "online" || st == "connecting") && was == "pairing" {
                    self.reload_chats();
                }
            }
            "qr" => {
                if let Some(code) = v["code"].as_str() {
                    if let Some(img) = qr_image(code) {
                        self.g().set_qr(img);
                        self.g().set_has_qr(true);
                        self.g().set_error("".into());
                    }
                }
            }
            "pairCode" => {
                if let Some(e) = v["error"].as_str() {
                    self.g().set_pair_note(e.into());
                    self.g().set_pair_code("".into());
                } else if let Some(c) = v["code"].as_str() {
                    self.g().set_pair_code(c.into());
                }
            }
            "chat" => {
                if let Some(c) = parse::<ChatD>(&v["chat"]) {
                    let is_current = c.jid == *self.current.borrow();
                    self.upsert_chat(c);
                    if is_current {
                        self.show_header();
                    }
                }
            }
            "message" => {
                if let Some(m) = parse::<MsgD>(&v["msg"]) {
                    self.typing.borrow_mut().remove(&m.chat);
                    self.upsert_message(m);
                }
            }
            "typing" => {
                let chat = v["chat"].as_str().unwrap_or("").to_string();
                if v["on"] == json!(true) {
                    let who = v["who"].as_str().unwrap_or("").trim_start_matches('~').to_string();
                    self.typing.borrow_mut().insert(chat, (who, v["audio"] == json!(true), Instant::now()));
                } else {
                    self.typing.borrow_mut().remove(&chat);
                }
                self.chats_soon();
            }
            "reload" => {
                self.reload_chats();
                let cur = self.current.borrow().clone();
                if !cur.is_empty() {
                    self.open(&cur);
                }
            }
            "unread" => {
                self.g().set_unread_total(v["count"].as_i64().unwrap_or(0) as i32);
            }
            "open" => {
                if let Some(c) = v["chat"].as_str().filter(|c| !c.is_empty()) {
                    self.open(c);
                }
                self.raise();
            }
            "lost" => {
                self.set_state("connecting", "");
                let w = Rc::downgrade(self);
                kit::spawn(
                    || {
                        std::thread::sleep(Duration::from_millis(500));
                        client::connect()
                    },
                    move |r| {
                        let Some(a) = w.upgrade() else { return };
                        match r {
                            Ok(s) => {
                                client::rerun(s);
                                a.hello();
                            }
                            Err(e) => a.set_state("nodaemon", &e),
                        }
                    },
                );
            }
            _ => {}
        }
    }

    fn hello(self: &Rc<Self>) {
        let w = Rc::downgrade(self);
        client::request("hello", json!({}), move |r| {
            let Some(a) = w.upgrade() else { return };
            if r["ok"] != json!(true) {
                a.set_state("nodaemon", r["error"].as_str().unwrap_or(""));
                return;
            }
            a.g().set_demo(r["demo"] == json!(true));
            *a.me.borrow_mut() = r["me"].as_str().unwrap_or("").to_string();
            a.g().set_unread_total(r["unread"].as_i64().unwrap_or(0) as i32);
            let st = r["state"].as_str().unwrap_or("connecting").to_string();
            a.set_state(&st, r["error"].as_str().unwrap_or(""));
            if st == "pairing" && r["error"].as_str().unwrap_or("").is_empty() {
                a.pair("");
            }
            a.reload_chats();
            a.tell_view();
        });
    }

    fn pair(self: &Rc<Self>, phone: &str) {
        self.g().set_error("".into());
        if !phone.is_empty() {
            self.g().set_pair_code("".into());
            self.g().set_pair_note("Asking WhatsApp for a code…".into());
        }
        let w = Rc::downgrade(self);
        client::request("pair", json!({ "phone": phone }), move |r| {
            if r["ok"] != json!(true) {
                if let Some(a) = w.upgrade() {
                    a.g().set_error(r["error"].as_str().unwrap_or("Couldn't start linking").into());
                }
            }
        });
    }

    /// Bring the window forward (a notification was clicked, or a second
    /// copy was started).
    fn raise(&self) {
        self.ui.window().set_minimized(false);
        let _ = self.ui.show();
        let _ = std::process::Command::new("hyprctl")
            .args(["dispatch", "hl.dsp.focus({ window = \"class:^(hyprshell-chats)$\" })"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }

    /// Once a second: whether the window has the focus (for read receipts,
    /// "online", and notifications), and typing that has gone quiet.
    fn every_second(self: &Rc<Self>) {
        let focused = HYPR_FOCUS.get().map(|f| f.load(Ordering::Relaxed)).unwrap_or(true) && self.ui.window().is_visible();
        if focused != self.focused.get() {
            self.focused.set(focused);
            self.tell_view();
            if focused {
                self.mark_read();
            }
        }
        let before = self.typing.borrow().len();
        self.typing.borrow_mut().retain(|_, (_, _, t)| t.elapsed() < Duration::from_secs(12));
        if self.typing.borrow().len() != before {
            self.chats_soon();
        }
    }
}

/// Whether this window is Hyprland's active one, from Hyprland's event
/// socket (activewindow>>class,title) — winit's own idea of focus isn't
/// reliable on every compositor. Elsewhere it's taken to be in front.
static HYPR_FOCUS: std::sync::OnceLock<Arc<AtomicBool>> = std::sync::OnceLock::new();

fn watch_hyprland_focus() {
    let Some(sig) = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE") else { return };
    let run = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let dir = [run.join("hypr").join(&sig), PathBuf::from("/tmp/hypr").join(&sig)].into_iter().find(|d| d.exists());
    let Some(dir) = dir else { return };
    let flag = Arc::new(AtomicBool::new(true));
    let _ = HYPR_FOCUS.set(flag.clone());
    std::thread::Builder::new()
        .name("hyprland-focus".into())
        .spawn(move || {
            use std::io::{BufRead, Read, Write};
            // Where it is now…
            if let Ok(mut s) = std::os::unix::net::UnixStream::connect(dir.join(".socket.sock")) {
                let _ = s.write_all(b"j/activewindow");
                let mut out = String::new();
                let _ = s.read_to_string(&mut out);
                if let Ok(v) = serde_json::from_str::<Value>(&out) {
                    flag.store(v["class"].as_str() == Some("hyprshell-chats"), Ordering::Relaxed);
                }
            }
            // …and as it changes.
            loop {
                let Ok(s) = std::os::unix::net::UnixStream::connect(dir.join(".socket2.sock")) else { return };
                for line in std::io::BufReader::new(s).lines() {
                    let Ok(line) = line else { break };
                    if let Some(rest) = line.strip_prefix("activewindow>>") {
                        let class = rest.split(',').next().unwrap_or("");
                        flag.store(class == "hyprshell-chats", Ordering::Relaxed);
                    }
                }
                std::thread::sleep(Duration::from_secs(2));
            }
        })
        .ok();
}

fn open_path(p: &str) {
    let _ = std::process::Command::new("xdg-open")
        .arg(p)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

/// The linking QR code, black on white, a square per module.
fn qr_image(code: &str) -> Option<Image> {
    // Quartile error correction: the mark in the middle covers a little.
    let q = qrcode::QrCode::with_error_correction_level(code.as_bytes(), qrcode::EcLevel::Q).ok()?;
    let n = q.width();
    let quiet = 2;
    let scale = 6;
    let side = (n + quiet * 2) * scale;
    let mut buf = SharedPixelBuffer::<Rgba8Pixel>::new(side as u32, side as u32);
    let px = buf.make_mut_slice();
    let colors = q.to_colors();
    for y in 0..side {
        for x in 0..side {
            let (mx, my) = ((x / scale) as isize - quiet as isize, (y / scale) as isize - quiet as isize);
            let dark = mx >= 0 && my >= 0 && (mx as usize) < n && (my as usize) < n && colors[my as usize * n + mx as usize] == qrcode::Color::Dark;
            let v = if dark { 0x1c } else { 0xff };
            px[y * side + x] = Rgba8Pixel { r: v, g: v, b: v, a: 255 };
        }
    }
    Some(Image::from_rgba8(buf))
}

/// Colour emoji: the GL renderer draws Noto Color Emoji, but fontconfig's
/// fallback can land on a monochrome font with emoji in it (GNU Unifont,
/// Symbola) first. With a colour emoji font installed, those are kept out
/// of this program's fallback.
fn prefer_colour_emoji() {
    if std::env::var_os("FONTCONFIG_FILE").is_some() {
        return;
    }
    let Ok(out) = std::process::Command::new("fc-list").args([":charset=1f600", "family"]).output() else { return };
    let list = String::from_utf8_lossy(&out.stdout).to_string();
    let colour = list.lines().any(|l| l.contains("Color Emoji") || l.contains("Twemoji") || l.contains("JoyPixels"));
    let mono: Vec<&str> = list
        .lines()
        .flat_map(|l| l.split(','))
        .map(str::trim)
        .filter(|f| f.starts_with("Unifont") || *f == "Symbola" || *f == "Noto Emoji" || *f == "OpenMoji")
        .collect();
    if !colour || mono.is_empty() {
        return;
    }
    let dir = cache_dir();
    let _ = std::fs::create_dir_all(&dir);
    let pats: String = mono
        .iter()
        .map(|f| format!("    <pattern><patelt name=\"family\"><string>{}</string></patelt></pattern>\n", f.replace('&', "&amp;").replace('<', "&lt;")))
        .collect();
    let conf = format!(
        "<?xml version=\"1.0\"?>\n<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">\n<fontconfig>\n  <include ignore_missing=\"yes\">/etc/fonts/fonts.conf</include>\n  <selectfont><rejectfont>\n{pats}  </rejectfont></selectfont>\n</fontconfig>\n"
    );
    let p = dir.join("fonts.conf");
    if std::fs::write(&p, conf).is_ok() {
        std::env::set_var("FONTCONFIG_FILE", p);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--demo") && std::env::var_os("HYPRSHELL_CHATS_DEMO").is_none() {
        std::env::set_var("HYPRSHELL_CHATS_DEMO", "1");
    }
    let open_chat = args.iter().position(|a| a == "--chat").and_then(|i| args.get(i + 1)).cloned();

    // One window: a second start brings the first forward instead.
    if let Ok(mut s) = std::os::unix::net::UnixStream::connect(client::socket()) {
        use std::io::{BufRead, Write};
        let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
        let _ = s.write_all(b"{\"cmd\":\"hello\",\"id\":1}\n");
        let mut line = String::new();
        let _ = std::io::BufReader::new(s.try_clone().unwrap()).read_line(&mut line);
        let windows = serde_json::from_str::<Value>(&line).ok().and_then(|v| v["windows"].as_i64()).unwrap_or(0);
        if windows > 1 {
            let _ = s.write_all(format!("{}\n", json!({ "cmd": "show", "chat": open_chat.clone().unwrap_or_default() })).as_bytes());
            return;
        }
    }

    prefer_colour_emoji();
    watch_hyprland_focus();
    // GL, for colour emoji; the software renderer if there's no GL.
    if std::env::var_os("SLINT_BACKEND").is_none() {
        let _ = slint::BackendSelector::new().backend_name("winit".into()).renderer_name("femtovg".into()).select();
    }
    kit::init("hyprshell-chats");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-chats");

    let engine = Engine::new(Who { name: c"Chats", id: c"hyprshell-chats", role: c"phone" }, |e| {
        let _ = slint::invoke_from_event_loop(move || {
            with_app(|a| {
                match e {
                    Event::Ended(_) => {}
                    Event::Failed(_, why) => a.toast(&why, true),
                }
                a.stop_playing();
                a.show_messages();
            })
        });
    });

    let app = Rc::new(App {
        ui: ui.clone_strong(),
        state: RefCell::new("starting".into()),
        me: RefCell::new(String::new()),
        chats: RefCell::new(Vec::new()),
        current: RefCell::new(String::new()),
        msgs: RefCell::new(Vec::new()),
        typing: RefCell::new(HashMap::new()),
        images: RefCell::new(HashMap::new()),
        reply_to: RefCell::new(None),
        focused: Cell::new(true),
        to_open: RefCell::new(HashSet::new()),
        loading: RefCell::new(HashSet::new()),
        avatars_asked: RefCell::new(HashSet::new()),
        engine,
        playing: RefCell::new(None),
        play_tick: Timer::default(),
        rec: RefCell::new(None),
        rec_tick: Timer::default(),
        typing_sent: Cell::new(None),
        typing_off: Timer::default(),
        toast_timer: Timer::default(),
        tick: Timer::default(),
        soon_msgs: Timer::default(),
        soon_chats: Timer::default(),
        open_chat: RefCell::new(open_chat),
    });
    APP.with(|a| *a.borrow_mut() = Some(app.clone()));

    let g = ui.global::<Chats>();
    macro_rules! on {
        ($set:ident, |$a:ident $(, $arg:ident)*| $body:expr) => {{
            let w = Rc::downgrade(&app);
            g.$set(move |$($arg),*| {
                if let Some($a) = w.upgrade() {
                    $body
                }
            });
        }};
    }
    on!(on_pair, |a, phone| a.pair(&phone));
    on!(on_retry, |a| a.pair(""));
    on!(on_open, |a, jid| a.open(&jid));
    on!(on_send, |a| a.send());
    on!(on_edited, |a, _t| a.edited());
    on!(on_attach, |a| a.attach());
    on!(on_record, |a| a.record());
    on!(on_stop_recording, |a, send| a.stop_recording(send));
    on!(on_reply, |a, id| a.reply(&id));
    on!(on_cancel_reply, |a| {
        *a.reply_to.borrow_mut() = None;
        a.g().set_replying(false);
    });
    on!(on_react, |a, id, e| a.react(&id, &e));
    on!(on_open_media, |a, id| a.open_media(&id));
    on!(on_save_media, |a, id| a.save_media(&id));
    on!(on_play, |a, id| a.play(&id));
    on!(on_copy, |a, id| a.copy(&id));
    on!(on_delete, |a, id| a.delete(&id));
    on!(on_older, |a| a.older());
    on!(on_new_chat, |a, phone| {
        let w = Rc::downgrade(&a);
        client::request("newChat", json!({ "phone": phone.to_string() }), move |r| {
            let Some(a) = w.upgrade() else { return };
            match r["chat"].as_str() {
                Some(jid) if r["ok"] == json!(true) => {
                    let jid = jid.to_string();
                    a.reload_chats();
                    *a.open_chat.borrow_mut() = Some(jid);
                }
                _ => a.toast(r["error"].as_str().unwrap_or("Couldn't start that chat"), true),
            }
        });
    });
    on!(on_unlink, |a| {
        let w = Rc::downgrade(&a);
        client::request("logout", json!({}), move |r| {
            let Some(a) = w.upgrade() else { return };
            if r["ok"] != json!(true) {
                a.toast(r["error"].as_str().unwrap_or("Couldn't unlink"), true);
            }
            a.chats.borrow_mut().clear();
            a.msgs.borrow_mut().clear();
            *a.current.borrow_mut() = String::new();
            a.g().set_current("".into());
            a.show_chats();
        });
    });
    // Search filters the list as you type.
    {
        let w = Rc::downgrade(&app);
        let last = RefCell::new(String::new());
        let t = Timer::default();
        t.start(TimerMode::Repeated, Duration::from_millis(150), move || {
            if let Some(a) = w.upgrade() {
                let f = a.g().get_filter().to_string();
                if f != *last.borrow() {
                    *last.borrow_mut() = f;
                    a.show_chats();
                }
            }
        });
        std::mem::forget(t);
    }
    {
        let w = Rc::downgrade(&app);
        let last = Cell::new(false);
        let t = Timer::default();
        t.start(TimerMode::Repeated, Duration::from_millis(150), move || {
            if let Some(a) = w.upgrade() {
                let s = a.g().get_show_archived();
                if s != last.get() {
                    last.set(s);
                    a.show_chats();
                }
            }
        });
        std::mem::forget(t);
    }
    // The reply's "Menu" flags for a message: mine, has media, has text, can delete.
    {
        let w = Rc::downgrade(&app);
        ui.on_menu_for(move |id| {
            let Some(a) = w.upgrade() else { return ModelRc::default() };
            let Some(m) = a.msg(&id) else { return ModelRc::default() };
            let media = m.media.is_some() && !matches!(m.kind.as_str(), "deleted" | "location" | "contact");
            let v = vec![m.from_me, media, !m.text.is_empty(), m.from_me && m.kind != "deleted" && m.status >= 1];
            ModelRc::new(VecModel::from(v))
        });
    }

    let w = Rc::downgrade(&app);
    app.tick.start(TimerMode::Repeated, Duration::from_secs(1), move || {
        if let Some(a) = w.upgrade() {
            a.every_second();
        }
    });

    // Connect (starting the daemon if need be) off the UI thread.
    let w = Rc::downgrade(&app);
    kit::spawn(client::connect, move |r| {
        let Some(a) = w.upgrade() else { return };
        match r {
            Ok(s) => {
                let wa = Rc::downgrade(&a);
                client::run(s, move |v| {
                    if let Some(a) = wa.upgrade() {
                        a.event(v);
                    }
                });
                a.hello();
            }
            Err(e) => a.set_state("nodaemon", &e),
        }
    });

    ui.run().expect("run");
    // Going: not typing, not online.
    if let Some(a) = APP.with(|a| a.borrow_mut().take()) {
        client::tell("view", json!({ "chat": "", "focused": false }));
        a.stop_playing();
    }
}
