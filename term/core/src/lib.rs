//! Hyprterm's terminal emulation: alacritty_terminal — the parser and grid
//! Alacritty itself runs on — behind a small C interface for the Qt side
//! (src/term.cpp), which keeps the pty, the drawing and the window.
//!
//! What alacritty_terminal leaves to the program around it is here too:
//! turning keys and clicks into the bytes a program on the far side
//! expects for the modes it has set, the working directory a shell
//! announces (OSC 7, which the parser does not keep), and answering colour
//! and size questions.
//!
//! Lines are addressed as alacritty addresses them: 0 is the top of the
//! live screen, -1 the newest line of scrollback.

use alacritty_terminal::event::{Event, EventListener, WindowSize};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::{Cell, Flags};
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, CursorShape, CursorStyle, NamedColor, Processor, Rgb, StdSyncHandler};
use std::cell::RefCell;
use std::ffi::c_void;
use std::rc::Rc;
use std::time::Instant;

pub const HT_MAX_CHARS: usize = 6;
const HISTORY: usize = 10000;

/// One cell, resolved for drawing. Mirrors HtCell in src/htcore.h.
#[repr(C)]
pub struct HtCell {
    pub chars: [u32; HT_MAX_CHARS],
    pub fg: u32,
    pub bg: u32,
    /// 0 for the second half of a wide character, else 1 or 2.
    pub width: u8,
    pub fg_default: u8,
    pub bg_default: u8,
    pub bold: u8,
    pub italic: u8,
    pub underline: u8,
    pub strike: u8,
    pub reverse: u8,
    pub conceal: u8,
    pub dim: u8,
}

/// Mirrors HtState in src/htcore.h.
#[repr(C)]
pub struct HtState {
    pub rows: i32,
    pub cols: i32,
    pub history: i32,
    pub cursor_row: i32,
    pub cursor_col: i32,
    pub cursor_visible: u8,
    /// 1 block, 2 underline, 3 bar (DECSCUSR's numbering).
    pub cursor_shape: u8,
    pub cursor_blink: u8,
    pub alt_screen: u8,
    pub mouse: u8,
    pub bracketed_paste: u8,
    pub focus_events: u8,
}

/// What happened during a feed, for the Qt side: kind, then bytes.
pub const HT_EV_WRITE: i32 = 1;
pub const HT_EV_TITLE: i32 = 2;
pub const HT_EV_BELL: i32 = 3;
pub const HT_EV_CWD: i32 = 4;
pub const HT_EV_CLIPBOARD: i32 = 5;
pub type HtCallback = extern "C" fn(user: *mut c_void, kind: i32, data: *const u8, len: usize);

#[derive(Clone)]
struct Listener {
    events: Rc<RefCell<Vec<Event>>>,
}
impl EventListener for Listener {
    fn send_event(&self, event: Event) {
        self.events.borrow_mut().push(event);
    }
}

struct Size {
    rows: usize,
    cols: usize,
}
impl Dimensions for Size {
    fn total_lines(&self) -> usize {
        self.rows
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn columns(&self) -> usize {
        self.cols
    }
}

/// OSC 7 — "file://host/path", the shell saying where it is. The parser
/// drops it, so the stream is watched for it on the way in.
#[derive(Default)]
struct Osc7 {
    state: u8, // 0 ground, 1 after ESC, 2 OSC number, 3 OSC 7 body, 4 body after ESC, 5 other OSC
    num: Vec<u8>,
    body: Vec<u8>,
}
impl Osc7 {
    fn scan(&mut self, bytes: &[u8], found: &mut Vec<String>) {
        for &b in bytes {
            self.state = match (self.state, b) {
                (_, 0x18) | (_, 0x1a) => 0,
                (0, 0x1b) => 1,
                (0, _) => 0,
                (1, b']') => {
                    self.num.clear();
                    2
                }
                (1, 0x1b) => 1,
                (1, _) => 0,
                (2, b'0'..=b'9') if self.num.len() < 4 => {
                    self.num.push(b);
                    2
                }
                (2, b';') if self.num == b"7" => {
                    self.body.clear();
                    3
                }
                (2, 0x07) => 0,
                (2, 0x1b) => 1,
                (2, _) => 5,
                (3, 0x07) => {
                    found.push(String::from_utf8_lossy(&self.body).into_owned());
                    0
                }
                (3, 0x1b) => 4,
                (3, _) => {
                    if self.body.len() < 4096 {
                        self.body.push(b);
                    }
                    3
                }
                (4, b'\\') => {
                    found.push(String::from_utf8_lossy(&self.body).into_owned());
                    0
                }
                (4, _) => 0,
                (5, 0x07) => 0,
                (5, 0x1b) => 1,
                (5, _) => 5,
                _ => 0,
            };
        }
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = |c: u8| (c as char).to_digit(16);
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// "file://host/home/you" → "/home/you". The host is the machine's, and
/// the path is what means anything here.
fn cwd_of(url: &str) -> Option<String> {
    let rest = url.strip_prefix("file://")?;
    let path = &rest[rest.find('/')?..];
    let p = percent_decode(path);
    if p.is_empty() {
        None
    } else {
        Some(p)
    }
}

pub struct Core {
    term: Term<Listener>,
    parser: Processor<StdSyncHandler>,
    events: Rc<RefCell<Vec<Event>>>,
    osc7: Osc7,
    callback: Option<(HtCallback, *mut c_void)>,
    fg: Rgb,
    bg: Rgb,
    palette: [Rgb; 16],
    cell_w: u16,
    cell_h: u16,
    /// The mouse button held, for drag reports.
    held: u8,
    /// Lines that left the top of the screen during the last feed; see
    /// scrolled().
    last_scrolled: i64,
}

const DEFAULT_PALETTE: [u32; 16] = [
    0x1a1a18, 0xd9534f, 0x5cb85c, 0xe5c07b, 0x61afef, 0xc678dd, 0x56b6c2, 0xdcdcdc, 0x5c6370, 0xe06c75, 0x98c379, 0xf0d58c, 0x7cbcf5,
    0xd7a0e8, 0x7fd0db, 0xffffff,
];

fn rgb(v: u32) -> Rgb {
    Rgb { r: (v >> 16) as u8, g: (v >> 8) as u8, b: v as u8 }
}
fn pack(c: Rgb) -> u32 {
    ((c.r as u32) << 16) | ((c.g as u32) << 8) | c.b as u32
}
fn dim(c: Rgb) -> Rgb {
    Rgb { r: (c.r as u32 * 2 / 3) as u8, g: (c.g as u32 * 2 / 3) as u8, b: (c.b as u32 * 2 / 3) as u8 }
}

impl Core {
    fn new(rows: usize, cols: usize) -> Core {
        let events = Rc::new(RefCell::new(Vec::new()));
        let config = Config {
            scrolling_history: HISTORY,
            // A caret unless the program asks otherwise; see
            // Term::cursorShape() for when it is obeyed.
            default_cursor_style: CursorStyle { shape: CursorShape::Beam, blinking: true },
            kitty_keyboard: false,
            ..Config::default()
        };
        let term = Term::new(config, &Size { rows, cols }, Listener { events: events.clone() });
        Core {
            term,
            parser: Processor::new(),
            events,
            osc7: Osc7::default(),
            callback: None,
            fg: rgb(0xe8e6e3),
            bg: rgb(0x1a1a18),
            palette: DEFAULT_PALETTE.map(rgb),
            cell_w: 8,
            cell_h: 16,
            held: 0,
            last_scrolled: 0,
        }
    }

    fn emit(&self, kind: i32, data: &[u8]) {
        if let Some((cb, user)) = self.callback {
            cb(user, kind, data.as_ptr(), data.len());
        }
    }

    /// What colour index i is now: a program's OSC 4 override, else ours.
    fn indexed(&self, i: usize) -> Rgb {
        if let Some(c) = self.term.colors()[i] {
            return c;
        }
        match i {
            0..=15 => self.palette[i],
            16..=231 => {
                let i = i - 16;
                let step = |v: usize| if v == 0 { 0 } else { (v * 40 + 55) as u8 };
                Rgb { r: step(i / 36), g: step((i / 6) % 6), b: step(i % 6) }
            }
            _ => {
                let v = ((i - 232) * 10 + 8) as u8;
                Rgb { r: v, g: v, b: v }
            }
        }
    }
    fn named(&self, n: NamedColor) -> (Rgb, bool) {
        let idx = n as usize;
        if let Some(c) = self.term.colors()[idx] {
            return (c, false);
        }
        match n {
            NamedColor::Foreground | NamedColor::BrightForeground => (self.fg, true),
            NamedColor::Background => (self.bg, true),
            NamedColor::Cursor => (self.fg, false),
            NamedColor::DimForeground => (dim(self.fg), false),
            _ if idx < 16 => (self.palette[idx], false),
            n => {
                // Dim black … dim white.
                let base = n as usize - NamedColor::DimBlack as usize;
                (dim(self.palette[base.min(7)]), false)
            }
        }
    }
    fn color(&self, c: Color) -> (u32, bool) {
        match c {
            Color::Spec(rgb) => (pack(rgb), false),
            Color::Indexed(i) => (pack(self.indexed(i as usize)), false),
            Color::Named(n) => {
                let (c, d) = self.named(n);
                (pack(c), d)
            }
        }
    }

    /// Lines identify themselves by where their cells live: scrolling
    /// rotates the ring of rows and leaves each row's cells where they
    /// are, so the line that was at the bottom before a feed is found
    /// again however far up it went. (A resize may move them; that is
    /// handled where it happens.)
    fn row_id(&self, line: i32) -> usize {
        &self.term.grid()[Line(line)][Column(0)] as *const Cell as usize
    }
    fn find_row(&self, id: usize, from: i32) -> Option<i32> {
        let top = -(self.term.grid().history_size() as i32);
        let mut l = from;
        while l >= top {
            if self.row_id(l) == id {
                return Some(l);
            }
            l -= 1;
        }
        None
    }

    fn feed(&mut self, bytes: &[u8]) {
        // In pieces no bigger than the scrollback, so a line that went up
        // is always still there to be found.
        for chunk in bytes.chunks(4096) {
            let mut found = Vec::new();
            self.osc7.scan(chunk, &mut found);
            let alt = self.term.mode().contains(TermMode::ALT_SCREEN);
            let bottom = self.term.screen_lines() as i32 - 1;
            let id = self.row_id(bottom);
            self.parser.advance(&mut self.term, chunk);
            if self.term.mode().contains(TermMode::ALT_SCREEN) == alt {
                self.last_scrolled += match self.find_row(id, bottom) {
                    Some(l) => (bottom - l) as i64,
                    // Gone from the scrollback altogether: more went
                    // past than it holds.
                    None => (HISTORY + self.term.screen_lines()) as i64,
                };
            }
            for url in found {
                if let Some(p) = cwd_of(&url) {
                    self.emit(HT_EV_CWD, p.as_bytes());
                }
            }
            self.drain();
        }
    }

    fn drain(&mut self) {
        let events: Vec<Event> = std::mem::take(&mut *self.events.borrow_mut());
        for e in events {
            match e {
                Event::PtyWrite(s) => self.emit(HT_EV_WRITE, s.as_bytes()),
                Event::Title(t) => self.emit(HT_EV_TITLE, t.as_bytes()),
                Event::ResetTitle => self.emit(HT_EV_TITLE, b""),
                Event::Bell => self.emit(HT_EV_BELL, b""),
                Event::ClipboardStore(_, s) => self.emit(HT_EV_CLIPBOARD, s.as_bytes()),
                Event::ColorRequest(i, fmt) => {
                    let c = match i {
                        0..=255 => self.indexed(i),
                        256 => self.term.colors()[i].unwrap_or(self.fg),
                        257 => self.term.colors()[i].unwrap_or(self.bg),
                        _ => self.term.colors()[i].unwrap_or(self.fg),
                    };
                    self.emit(HT_EV_WRITE, fmt(c).as_bytes());
                }
                Event::TextAreaSizeRequest(fmt) => {
                    let ws = WindowSize {
                        num_lines: self.term.screen_lines() as u16,
                        num_cols: self.term.columns() as u16,
                        cell_width: self.cell_w,
                        cell_height: self.cell_h,
                    };
                    self.emit(HT_EV_WRITE, fmt(ws).as_bytes());
                }
                _ => {}
            }
        }
    }

    fn cell(&self, line: i32, col: usize, out: &mut HtCell) -> bool {
        let rows = self.term.screen_lines() as i32;
        let hist = self.term.grid().history_size() as i32;
        if line >= rows || line < -hist || col >= self.term.columns() {
            return false;
        }
        let c = &self.term.grid()[Line(line)][Column(col)];
        *out = HtCell {
            chars: [0; HT_MAX_CHARS],
            fg: 0,
            bg: 0,
            width: 1,
            fg_default: 0,
            bg_default: 0,
            bold: c.flags.contains(Flags::BOLD) as u8,
            italic: c.flags.contains(Flags::ITALIC) as u8,
            underline: c.flags.intersects(Flags::ALL_UNDERLINES) as u8,
            strike: c.flags.contains(Flags::STRIKEOUT) as u8,
            reverse: c.flags.contains(Flags::INVERSE) as u8,
            conceal: c.flags.contains(Flags::HIDDEN) as u8,
            dim: c.flags.contains(Flags::DIM) as u8,
        };
        if c.flags.contains(Flags::WIDE_CHAR_SPACER) {
            out.width = 0;
        } else if c.flags.contains(Flags::WIDE_CHAR) {
            out.width = 2;
        }
        if c.c != ' ' && !c.flags.contains(Flags::LEADING_WIDE_CHAR_SPACER) {
            out.chars[0] = c.c as u32;
            if let Some(z) = c.zerowidth() {
                for (i, ch) in z.iter().take(HT_MAX_CHARS - 1).enumerate() {
                    out.chars[i + 1] = *ch as u32;
                }
            }
        }
        let (fg, fd) = self.color(c.fg);
        let (bg, bd) = self.color(c.bg);
        out.fg = fg;
        out.fg_default = fd as u8;
        out.bg = bg;
        out.bg_default = bd as u8;
        if out.dim != 0 && out.fg_default == 0 {
            out.fg = pack(dim(rgb(out.fg)));
        }
        true
    }

    fn state(&self) -> HtState {
        let mode = *self.term.mode();
        let cur = self.term.grid().cursor.point;
        let style = self.term.cursor_style();
        HtState {
            rows: self.term.screen_lines() as i32,
            cols: self.term.columns() as i32,
            history: self.term.grid().history_size() as i32,
            cursor_row: cur.line.0,
            cursor_col: cur.column.0 as i32,
            cursor_visible: mode.contains(TermMode::SHOW_CURSOR) as u8,
            cursor_shape: match style.shape {
                CursorShape::Block | CursorShape::HollowBlock => 1,
                CursorShape::Underline => 2,
                _ => 3,
            },
            cursor_blink: style.blinking as u8,
            alt_screen: mode.contains(TermMode::ALT_SCREEN) as u8,
            mouse: mode.intersects(TermMode::MOUSE_MODE) as u8,
            bracketed_paste: mode.contains(TermMode::BRACKETED_PASTE) as u8,
            focus_events: mode.contains(TermMode::FOCUS_IN_OUT) as u8,
        }
    }
}

// ── keys ─────────────────────────────────────────────────────────────────

/// Keys that are not text. Mirrors HtKey in src/htcore.h.
pub mod key {
    pub const ENTER: i32 = 1;
    pub const TAB: i32 = 2;
    pub const BACKSPACE: i32 = 3;
    pub const ESCAPE: i32 = 4;
    pub const UP: i32 = 5;
    pub const DOWN: i32 = 6;
    pub const LEFT: i32 = 7;
    pub const RIGHT: i32 = 8;
    pub const INSERT: i32 = 9;
    pub const DELETE: i32 = 10;
    pub const HOME: i32 = 11;
    pub const END: i32 = 12;
    pub const PAGE_UP: i32 = 13;
    pub const PAGE_DOWN: i32 = 14;
    pub const BACKTAB: i32 = 15;
    /// F1 is F0 + 1, up to F20.
    pub const F0: i32 = 100;
}
pub const MOD_SHIFT: i32 = 1;
pub const MOD_ALT: i32 = 2;
pub const MOD_CTRL: i32 = 4;

/// What xterm sends for a key, given the modes the program has set.
pub fn encode_key(mode: TermMode, k: i32, mods: i32, text: &str) -> Vec<u8> {
    let m = 1 + mods; // xterm's modifier parameter
    let alt = mods & MOD_ALT != 0;
    let ctrl = mods & MOD_CTRL != 0;
    let esc = |s: &[u8]| -> Vec<u8> {
        let mut v = Vec::with_capacity(s.len() + 1);
        if alt {
            v.push(0x1b);
        }
        v.extend_from_slice(s);
        v
    };
    // CSI letter keys: arrows, Home, End; SS3 in application mode with no
    // modifiers.
    let letter = |c: u8| -> Vec<u8> {
        if mods == 0 {
            if mode.contains(TermMode::APP_CURSOR) {
                vec![0x1b, b'O', c]
            } else {
                vec![0x1b, b'[', c]
            }
        } else {
            format!("\x1b[1;{m}{}", c as char).into_bytes()
        }
    };
    let tilde = |n: u32| -> Vec<u8> {
        if mods == 0 {
            format!("\x1b[{n}~").into_bytes()
        } else {
            format!("\x1b[{n};{m}~").into_bytes()
        }
    };
    match k {
        key::ENTER => {
            if mode.contains(TermMode::LINE_FEED_NEW_LINE) {
                esc(b"\r\n")
            } else {
                esc(b"\r")
            }
        }
        key::TAB if mods & MOD_SHIFT != 0 => b"\x1b[Z".to_vec(),
        key::TAB => esc(b"\t"),
        key::BACKTAB => b"\x1b[Z".to_vec(),
        key::BACKSPACE => {
            if ctrl {
                esc(b"\x08")
            } else {
                esc(b"\x7f")
            }
        }
        key::ESCAPE => esc(b"\x1b"),
        key::UP => letter(b'A'),
        key::DOWN => letter(b'B'),
        key::RIGHT => letter(b'C'),
        key::LEFT => letter(b'D'),
        key::HOME => letter(b'H'),
        key::END => letter(b'F'),
        key::INSERT => tilde(2),
        key::DELETE => tilde(3),
        key::PAGE_UP => tilde(5),
        key::PAGE_DOWN => tilde(6),
        f if f > key::F0 && f <= key::F0 + 20 => {
            let n = f - key::F0;
            if n <= 4 {
                let c = b"PQRS"[(n - 1) as usize];
                if mods == 0 {
                    vec![0x1b, b'O', c]
                } else {
                    format!("\x1b[1;{m}{}", c as char).into_bytes()
                }
            } else {
                const CODES: [u32; 16] = [15, 17, 18, 19, 20, 21, 23, 24, 25, 26, 28, 29, 31, 32, 33, 34];
                tilde(CODES[(n - 5) as usize])
            }
        }
        _ => {
            // Text. With Ctrl, the control character it names.
            let mut chars = text.chars();
            let (Some(c), None) = (chars.next(), chars.clone().next()) else {
                return esc(text.as_bytes());
            };
            if ctrl {
                let code = match c {
                    '@' | ' ' | '2' => Some(0u8),
                    'a'..='z' => Some(c as u8 - b'a' + 1),
                    'A'..='Z' => Some(c as u8 - b'A' + 1),
                    '[' | '3' => Some(0x1b),
                    '\\' | '4' => Some(0x1c),
                    ']' | '5' => Some(0x1d),
                    '^' | '6' | '~' => Some(0x1e),
                    '_' | '7' | '-' | '/' => Some(0x1f),
                    '8' | '?' => Some(0x7f),
                    _ => None,
                };
                if let Some(code) = code {
                    return esc(&[code]);
                }
            }
            let mut b = [0u8; 4];
            esc(c.encode_utf8(&mut b).as_bytes())
        }
    }
}

/// A click, a release, a drag or a wheel step, as the program asked to be
/// told: buttons 1–3, 4 and 5 for the wheel, 0 for motion alone.
pub fn encode_mouse(mode: TermMode, held: &mut u8, row: i32, col: i32, button: i32, pressed: bool, mods: i32) -> Vec<u8> {
    if !mode.intersects(TermMode::MOUSE_MODE) {
        return Vec::new();
    }
    let motion = button == 0;
    if motion {
        let report = mode.contains(TermMode::MOUSE_MOTION) || (mode.contains(TermMode::MOUSE_DRAG) && *held != 0);
        if !report {
            return Vec::new();
        }
    } else if button <= 3 {
        *held = if pressed { button as u8 } else { 0 };
    }
    let wheel = button == 4 || button == 5;
    if wheel && !pressed {
        return Vec::new();
    }
    let mut cb: i32 = if motion {
        (if *held == 0 { 3 } else { *held as i32 - 1 }) + 32
    } else if wheel {
        64 + (button - 4)
    } else {
        button - 1
    };
    if mods & MOD_SHIFT != 0 {
        cb += 4;
    }
    if mods & MOD_ALT != 0 {
        cb += 8;
    }
    if mods & MOD_CTRL != 0 {
        cb += 16;
    }
    let (x, y) = (col.max(0) + 1, row.max(0) + 1);
    if mode.contains(TermMode::SGR_MOUSE) {
        let end = if !motion && !wheel && !pressed { 'm' } else { 'M' };
        return format!("\x1b[<{cb};{x};{y}{end}").into_bytes();
    }
    if !motion && !wheel && !pressed {
        cb = (cb & !3) | 3;
    }
    let mut v = vec![0x1b, b'[', b'M', (32 + cb).min(255) as u8];
    for n in [x, y] {
        if mode.contains(TermMode::UTF8_MOUSE) {
            let mut b = [0u8; 4];
            let c = char::from_u32((32 + n) as u32).unwrap_or(' ');
            v.extend_from_slice(c.encode_utf8(&mut b).as_bytes());
        } else {
            v.push((32 + n).min(255) as u8);
        }
    }
    v
}

// ── the C interface ──────────────────────────────────────────────────────

unsafe fn core<'a>(c: *mut Core) -> &'a mut Core {
    &mut *c
}

#[no_mangle]
pub extern "C" fn ht_new(rows: i32, cols: i32) -> *mut Core {
    Box::into_raw(Box::new(Core::new(rows.max(1) as usize, cols.max(2) as usize)))
}

/// # Safety
/// `c` must come from ht_new and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn ht_free(c: *mut Core) {
    if !c.is_null() {
        drop(Box::from_raw(c));
    }
}

/// # Safety
/// `c` must come from ht_new.
#[no_mangle]
pub unsafe extern "C" fn ht_set_callback(c: *mut Core, cb: HtCallback, user: *mut c_void) {
    core(c).callback = Some((cb, user));
}

/// # Safety
/// `ansi16` must point at 16 values (0xRRGGBB).
#[no_mangle]
pub unsafe extern "C" fn ht_set_palette(c: *mut Core, fg: u32, bg: u32, ansi16: *const u32) {
    let c = core(c);
    c.fg = rgb(fg);
    c.bg = rgb(bg);
    if !ansi16.is_null() {
        for (i, p) in std::slice::from_raw_parts(ansi16, 16).iter().enumerate() {
            c.palette[i] = rgb(*p);
        }
    }
}

/// # Safety
/// `data` must point at `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn ht_feed(c: *mut Core, data: *const u8, len: usize) {
    if len == 0 {
        return;
    }
    core(c).feed(std::slice::from_raw_parts(data, len));
}

/// Milliseconds until a synchronized update (mode 2026) has to be shown
/// even though the program has not finished it; -1 when none is waiting.
///
/// # Safety
/// `c` must come from ht_new.
#[no_mangle]
pub unsafe extern "C" fn ht_sync_wait(c: *mut Core) -> i64 {
    match core(c).parser.sync_timeout().sync_timeout() {
        Some(t) => t.saturating_duration_since(Instant::now()).as_millis() as i64,
        None => -1,
    }
}

/// # Safety
/// `c` must come from ht_new.
#[no_mangle]
pub unsafe extern "C" fn ht_sync_flush(c: *mut Core) {
    let c = core(c);
    if c.parser.sync_timeout().sync_timeout().is_some() {
        let bottom = c.term.screen_lines() as i32 - 1;
        let id = c.row_id(bottom);
        c.parser.stop_sync(&mut c.term);
        c.last_scrolled += c.find_row(id, bottom).map(|l| (bottom - l) as i64).unwrap_or(0);
        c.drain();
    }
}

/// Lines that went up off the screen since the last call — how the Qt side
/// keeps a line's identity (and a selection on it) while output scrolls.
///
/// # Safety
/// `c` must come from ht_new.
#[no_mangle]
pub unsafe extern "C" fn ht_take_scrolled(c: *mut Core) -> i64 {
    std::mem::take(&mut core(c).last_scrolled)
}

/// # Safety
/// `c` must come from ht_new.
#[no_mangle]
pub unsafe extern "C" fn ht_resize(c: *mut Core, rows: i32, cols: i32, cell_w: i32, cell_h: i32) {
    let c = core(c);
    if cell_w > 0 && cell_h > 0 {
        c.cell_w = cell_w as u16;
        c.cell_h = cell_h as u16;
    }
    let (rows, cols) = (rows.max(1) as usize, cols.max(2) as usize);
    if rows != c.term.screen_lines() || cols != c.term.columns() {
        c.term.resize(Size { rows, cols });
    }
}

/// # Safety
/// `out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ht_state(c: *mut Core, out: *mut HtState) {
    *out = core(c).state();
}

/// # Safety
/// `out` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ht_cell(c: *mut Core, line: i32, col: i32, out: *mut HtCell) -> bool {
    if col < 0 {
        return false;
    }
    core(c).cell(line, col as usize, &mut *out)
}

/// The bytes for a key; written to the pty through the callback.
///
/// # Safety
/// `text` must point at `len` bytes of UTF-8.
#[no_mangle]
pub unsafe extern "C" fn ht_key(c: *mut Core, key: i32, mods: i32, text: *const u8, len: usize) {
    let c = core(c);
    let t = if text.is_null() { "" } else { std::str::from_utf8(std::slice::from_raw_parts(text, len)).unwrap_or("") };
    let bytes = encode_key(*c.term.mode(), key, mods, t);
    if !bytes.is_empty() {
        c.emit(HT_EV_WRITE, &bytes);
    }
}

/// # Safety
/// `c` must come from ht_new.
#[no_mangle]
pub unsafe extern "C" fn ht_mouse(c: *mut Core, row: i32, col: i32, button: i32, pressed: bool, mods: i32) {
    let c = core(c);
    let mode = *c.term.mode();
    let bytes = encode_mouse(mode, &mut c.held, row, col, button, pressed, mods);
    if !bytes.is_empty() {
        c.emit(HT_EV_WRITE, &bytes);
    }
}

/// Pasted text, wrapped in the brackets a program that asked for them
/// uses to tell a paste from typing (so a pasted line is not run).
///
/// # Safety
/// `text` must point at `len` bytes.
#[no_mangle]
pub unsafe extern "C" fn ht_paste(c: *mut Core, text: *const u8, len: usize) {
    let c = core(c);
    let t = std::slice::from_raw_parts(text, len);
    if c.term.mode().contains(TermMode::BRACKETED_PASTE) {
        // The end marker inside the text would end the paste early, and
        // what followed would run as typed.
        let clean: Vec<u8> = String::from_utf8_lossy(t).replace("\x1b[201~", "").into_bytes();
        let mut v = b"\x1b[200~".to_vec();
        v.extend_from_slice(&clean);
        v.extend_from_slice(b"\x1b[201~");
        c.emit(HT_EV_WRITE, &v);
    } else {
        // Newlines as Enter presses, the way a terminal types them.
        let v: Vec<u8> = String::from_utf8_lossy(t).replace("\r\n", "\r").replace('\n', "\r").into_bytes();
        c.emit(HT_EV_WRITE, &v);
    }
}

/// The window gained or lost the keyboard, for a program that asked.
///
/// # Safety
/// `c` must come from ht_new.
#[no_mangle]
pub unsafe extern "C" fn ht_focus(c: *mut Core, focused: bool) {
    let c = core(c);
    c.term.is_focused = focused;
    if c.term.mode().contains(TermMode::FOCUS_IN_OUT) {
        c.emit(HT_EV_WRITE, if focused { b"\x1b[I" } else { b"\x1b[O" });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    extern "C" fn sink(user: *mut c_void, kind: i32, data: *const u8, len: usize) {
        let v = unsafe { &mut *(user as *mut Vec<(i32, Vec<u8>)>) };
        v.push((kind, unsafe { std::slice::from_raw_parts(data, len) }.to_vec()));
    }

    fn text(c: &Core, line: i32) -> String {
        let mut s = String::new();
        let mut cell = HtCell { chars: [0; 6], fg: 0, bg: 0, width: 0, fg_default: 0, bg_default: 0, bold: 0, italic: 0, underline: 0, strike: 0, reverse: 0, conceal: 0, dim: 0 };
        for col in 0..c.term.columns() {
            c.cell(line, col, &mut cell);
            if cell.width == 0 {
                continue;
            }
            s.push(if cell.chars[0] == 0 { ' ' } else { char::from_u32(cell.chars[0]).unwrap() });
        }
        s.trim_end().to_string()
    }

    #[test]
    fn scrolling_is_counted() {
        let mut c = Core::new(5, 20);
        let mut out: Vec<String> = Vec::new();
        for i in 0..12 {
            out.push(format!("line {i}"));
        }
        c.feed(out.join("\r\n").as_bytes());
        // 12 lines on a 5-line screen: 7 went up.
        assert_eq!(c.last_scrolled, 7);
        assert_eq!(c.term.grid().history_size(), 7);
        assert_eq!(text(&c, 0), "line 7");
        assert_eq!(text(&c, -1), "line 6");
        assert_eq!(text(&c, -7), "line 0");
        // A redraw in place moves nothing.
        c.last_scrolled = 0;
        c.feed(b"\rline 11 again");
        assert_eq!(c.last_scrolled, 0);
        // Clearing the screen moves it into the scrollback.
        c.feed(b"\x1b[2J");
        assert!(c.last_scrolled > 0);
    }

    #[test]
    fn scrollback_full_still_counts() {
        let mut c = Core::new(4, 10);
        let lines: String = (0..(HISTORY + 50)).map(|i| format!("{i}\r\n")).collect();
        c.feed(lines.as_bytes());
        assert_eq!(c.term.grid().history_size(), HISTORY);
        assert_eq!(c.last_scrolled as usize, HISTORY + 50 - 3);
    }

    #[test]
    fn events_and_osc7() {
        let mut c = Core::new(5, 20);
        let mut got: Vec<(i32, Vec<u8>)> = Vec::new();
        c.callback = Some((sink, &mut got as *mut _ as *mut c_void));
        c.feed(b"\x1b]2;hello\x07\x1b]7;file://box/home/me/My%20Dir\x1b\\\x07\x1b[c");
        assert!(got.contains(&(HT_EV_TITLE, b"hello".to_vec())));
        assert!(got.contains(&(HT_EV_CWD, b"/home/me/My Dir".to_vec())));
        assert!(got.iter().any(|(k, _)| *k == HT_EV_BELL));
        // Device attributes answered.
        assert!(got.iter().any(|(k, v)| *k == HT_EV_WRITE && v.starts_with(b"\x1b[?")));
    }

    #[test]
    fn keys() {
        let m = TermMode::default();
        assert_eq!(encode_key(m, key::UP, 0, ""), b"\x1b[A");
        assert_eq!(encode_key(m | TermMode::APP_CURSOR, key::UP, 0, ""), b"\x1bOA");
        assert_eq!(encode_key(m, key::LEFT, MOD_CTRL, ""), b"\x1b[1;5D");
        assert_eq!(encode_key(m, key::DELETE, 0, ""), b"\x1b[3~");
        assert_eq!(encode_key(m, key::F0 + 5, 0, ""), b"\x1b[15~");
        assert_eq!(encode_key(m, key::F0 + 1, MOD_SHIFT, ""), b"\x1b[1;2P");
        assert_eq!(encode_key(m, 0, MOD_CTRL, "c"), b"\x03");
        assert_eq!(encode_key(m, 0, MOD_ALT, "b"), b"\x1bb");
        assert_eq!(encode_key(m, 0, 0, "é"), "é".as_bytes());
        assert_eq!(encode_key(m, key::TAB, MOD_SHIFT, ""), b"\x1b[Z");
        assert_eq!(encode_key(m, key::ENTER, 0, ""), b"\r");
    }

    #[test]
    fn mouse() {
        let mut held = 0;
        let sgr = TermMode::MOUSE_REPORT_CLICK | TermMode::SGR_MOUSE;
        assert_eq!(encode_mouse(sgr, &mut held, 2, 4, 1, true, 0), b"\x1b[<0;5;3M");
        assert_eq!(encode_mouse(sgr, &mut held, 2, 4, 1, false, 0), b"\x1b[<0;5;3m");
        assert!(encode_mouse(sgr, &mut held, 2, 5, 0, false, 0).is_empty());
        let drag = TermMode::MOUSE_DRAG | TermMode::SGR_MOUSE;
        encode_mouse(drag, &mut held, 0, 0, 1, true, 0);
        assert_eq!(encode_mouse(drag, &mut held, 1, 1, 0, false, 0), b"\x1b[<32;2;2M");
        let x10 = TermMode::MOUSE_REPORT_CLICK;
        assert_eq!(encode_mouse(x10, &mut held, 0, 0, 1, true, 0), vec![0x1b, b'[', b'M', 32, 33, 33]);
        assert_eq!(encode_mouse(x10, &mut held, 0, 0, 4, true, 0), vec![0x1b, b'[', b'M', 96, 33, 33]);
    }

    #[test]
    fn wide_and_colours() {
        let mut c = Core::new(3, 10);
        c.feed("中a\x1b[31mr\x1b[0m".as_bytes());
        let mut cell = HtCell { chars: [0; 6], fg: 0, bg: 0, width: 0, fg_default: 0, bg_default: 0, bold: 0, italic: 0, underline: 0, strike: 0, reverse: 0, conceal: 0, dim: 0 };
        c.cell(0, 0, &mut cell);
        assert_eq!((cell.width, cell.chars[0]), (2, '中' as u32));
        c.cell(0, 1, &mut cell);
        assert_eq!(cell.width, 0);
        c.cell(0, 2, &mut cell);
        assert_eq!((cell.chars[0], cell.fg_default), ('a' as u32, 1));
        c.cell(0, 3, &mut cell);
        assert_eq!(cell.fg, DEFAULT_PALETTE[1]);
    }
}
