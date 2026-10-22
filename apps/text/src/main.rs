//! Text Editor: plain text and code, in tabs, with find and replace.
//!
//! Files are kept as they came: UTF-8 or Latin-1, a byte-order mark,
//! Windows line endings — all written back the same way. Saving writes a
//! sibling first and renames it over, with the old file's permissions, and
//! through a symlink to the file it points at. A file changed by something
//! else is reloaded when there's nothing unsaved here, and asked about when
//! there is. The view (wrapping, the font, its size), recent files and the
//! files left open are kept in ~/.config/hyprshell-text/settings.json.

slint::include_modules!();

use hyprshell_kit as kit;
use slint::{ComponentHandle, ModelRc, VecModel};
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, SystemTime};

const TOO_BIG: u64 = 16 * 1024 * 1024;

// ── files ────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, PartialEq, Debug)]
enum Enc {
    Utf8,
    Latin1,
}

#[derive(Clone, Debug)]
struct Doc {
    path: Option<PathBuf>,
    /// The text, while another tab is shown (the shown one's is the page's).
    text: String,
    /// As last saved or loaded, to know when it's back to unchanged.
    saved: String,
    enc: Enc,
    bom: bool,
    crlf: bool,
    mtime: Option<SystemTime>,
    /// Cursor and anchor, byte offsets, for coming back to the tab.
    sel: (i32, i32),
    dirty: bool,
    /// Changed on disk while it has changes here.
    conflict: bool,
    /// For a new file: its number among the untitled.
    untitled: u32,
}

impl Doc {
    fn new(untitled: u32) -> Doc {
        Doc {
            path: None,
            text: String::new(),
            saved: String::new(),
            enc: Enc::Utf8,
            bom: false,
            crlf: false,
            mtime: None,
            sel: (0, 0),
            dirty: false,
            conflict: false,
            untitled,
        }
    }

    fn title(&self) -> String {
        match &self.path {
            Some(p) => p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| p.display().to_string()),
            None if self.untitled <= 1 => "Untitled".into(),
            None => format!("Untitled {}", self.untitled),
        }
    }
}

fn mtime(p: &Path) -> Option<SystemTime> {
    std::fs::metadata(p).and_then(|m| m.modified()).ok()
}

/// Bytes to text, and how to write it back.
fn decode(bytes: &[u8]) -> Result<(String, Enc, bool, bool), String> {
    let head = &bytes[..bytes.len().min(8192)];
    if head.contains(&0) {
        return Err("it looks like a binary file, not text".into());
    }
    let (body, bom) = match bytes.strip_prefix(b"\xEF\xBB\xBF") {
        Some(b) => (b, true),
        None => (bytes, false),
    };
    let (text, enc) = match std::str::from_utf8(body) {
        Ok(s) => (s.to_string(), Enc::Utf8),
        // Not UTF-8: Latin-1, where every byte is a character.
        Err(_) => (body.iter().map(|&b| b as char).collect(), Enc::Latin1),
    };
    let crlf = text.contains("\r\n");
    let text = if crlf { text.replace("\r\n", "\n") } else { text };
    Ok((text, enc, bom, crlf))
}

/// Text to bytes, the way the file had it. Latin-1 that can't hold what was
/// typed becomes UTF-8 (and says so).
fn encode(text: &str, enc: Enc, bom: bool, crlf: bool) -> (Vec<u8>, Enc) {
    let text = if crlf { text.replace('\n', "\r\n") } else { text.to_string() };
    if enc == Enc::Latin1 && text.chars().all(|c| (c as u32) < 256) {
        return (text.chars().map(|c| c as u8).collect(), Enc::Latin1);
    }
    let mut out = Vec::with_capacity(text.len() + 3);
    if bom {
        out.extend_from_slice(b"\xEF\xBB\xBF");
    }
    out.extend_from_slice(text.as_bytes());
    (out, Enc::Utf8)
}

fn load(path: &Path) -> Result<Doc, String> {
    let meta = std::fs::metadata(path).map_err(|e| e.to_string())?;
    if meta.is_dir() {
        return Err("it's a folder".into());
    }
    if meta.len() > TOO_BIG {
        return Err(format!("it's {} — too big to edit here", kit::bytes(meta.len())));
    }
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let (text, enc, bom, crlf) = decode(&bytes)?;
    Ok(Doc { path: Some(path.to_path_buf()), saved: text.clone(), text, enc, bom, crlf, mtime: meta.modified().ok(), ..Doc::new(0) })
}

/// Write the whole file or none of it, keeping its permissions; through a
/// symlink, to the file it points at.
fn write_file(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let target = if path.is_symlink() { std::fs::canonicalize(path)? } else { path.to_path_buf() };
    let perms = std::fs::metadata(&target).ok().map(|m| m.permissions());
    let name = target.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = target.with_file_name(format!(".{name}.hyprshell-text-{}", std::process::id()));
    let r = (|| {
        std::fs::write(&tmp, data)?;
        if let Some(p) = perms {
            std::fs::set_permissions(&tmp, p)?;
        }
        std::fs::rename(&tmp, &target)
    })();
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r
}

// ── text ─────────────────────────────────────────────────────────────────

/// Line and column (from 1) at a byte offset.
fn line_col(text: &str, at: usize) -> (usize, usize) {
    let at = floor(text, at);
    let before = &text[..at];
    let line = before.matches('\n').count() + 1;
    let col = before.rsplit('\n').next().map(|s| s.chars().count()).unwrap_or(0) + 1;
    (line, col)
}

fn floor(text: &str, mut at: usize) -> usize {
    at = at.min(text.len());
    while !text.is_char_boundary(at) {
        at -= 1;
    }
    at
}

fn words(text: &str) -> usize {
    text.split_whitespace().count()
}

/// Every match of `needle`, as byte ranges. Ignoring case is ASCII-only,
/// which keeps the offsets the text's own.
fn matches(text: &str, needle: &str, case: bool) -> Vec<(usize, usize)> {
    if needle.is_empty() {
        return Vec::new();
    }
    let (hay, pat) = if case { (text.to_string(), needle.to_string()) } else { (text.to_ascii_lowercase(), needle.to_ascii_lowercase()) };
    hay.match_indices(&pat).map(|(i, m)| (i, i + m.len())).collect()
}

/// The match to go to from a selection: `dir` 1 the next after it, -1 the
/// one before, 0 the first at or after its start (for typing in Find).
/// Round to the other end when there's none that way.
fn pick_match(all: &[(usize, usize)], sel: (usize, usize), dir: i32) -> Option<usize> {
    if all.is_empty() {
        return None;
    }
    let (s, e) = sel;
    match dir {
        0 => all.iter().position(|m| m.0 >= s).or(Some(0)),
        d if d > 0 => all.iter().position(|m| m.0 >= e && (m.0, m.1) != (s, e)).or(Some(0)),
        _ => all.iter().rposition(|m| m.1 <= s && (m.0, m.1) != (s, e)).or(Some(all.len() - 1)),
    }
}

/// How the text indents: tabs if its lines mostly start with one.
fn indent_unit(text: &str) -> &'static str {
    let tabs = text.lines().filter(|l| l.starts_with('\t')).count();
    let spaces = text.lines().filter(|l| l.starts_with("  ")).count();
    if tabs > spaces { "\t" } else { "    " }
}

/// Tab and Shift+Tab: a cursor gets an indent; a selection's lines move in
/// or out together. Returns the new text and selection.
fn indent(text: &str, sel: (usize, usize), out: bool) -> (String, (usize, usize)) {
    let unit = indent_unit(text);
    let (s, e) = (floor(text, sel.0.min(sel.1)), floor(text, sel.0.max(sel.1)));
    if s == e && !out {
        let mut t = text.to_string();
        t.insert_str(s, unit);
        return (t, (s + unit.len(), s + unit.len()));
    }
    let first = text[..s].rfind('\n').map(|i| i + 1).unwrap_or(0);
    // A selection ending at a line's very start leaves that line alone.
    let e_in = if e > s && e > first && text.as_bytes()[e - 1] == b'\n' { e - 1 } else { e };
    let last = text[e_in..].find('\n').map(|i| e_in + i).unwrap_or(text.len());
    let block = &text[first..last];
    let lines: Vec<String> = block
        .split('\n')
        .map(|line| {
            if out {
                let cut = if line.starts_with('\t') { 1 } else { line.bytes().take(4).take_while(|&b| b == b' ').count() };
                line[cut..].to_string()
            } else if line.trim().is_empty() && e > s {
                line.to_string()
            } else {
                format!("{unit}{line}")
            }
        })
        .collect();
    let new_block = lines.join("\n");
    let t = format!("{}{}{}", &text[..first], new_block, &text[last..]);
    if s == e {
        // Out, with only a cursor: it stays where it was on its line.
        let moved = block.len() - new_block.len();
        let at = s.saturating_sub(moved).max(first);
        return (t, (at, at));
    }
    (t, (first, first + new_block.len()))
}

// ── settings ─────────────────────────────────────────────────────────────

#[derive(serde::Serialize, serde::Deserialize)]
struct Settings {
    #[serde(default = "yes")]
    wrap: bool,
    #[serde(default = "yes")]
    mono: bool,
    #[serde(default = "size")]
    font_size: f32,
    #[serde(default)]
    recent: Vec<PathBuf>,
    #[serde(default)]
    open: Vec<PathBuf>,
    #[serde(default)]
    current: usize,
}

fn yes() -> bool {
    true
}
fn size() -> f32 {
    14.0
}

impl Default for Settings {
    fn default() -> Self {
        Settings { wrap: true, mono: true, font_size: 14.0, recent: Vec::new(), open: Vec::new(), current: 0 }
    }
}

fn settings_file() -> PathBuf {
    kit::config_dir().join("hyprshell-text/settings.json")
}

// ── the app ──────────────────────────────────────────────────────────────

#[derive(Clone, Copy)]
enum Closing {
    Tab(usize),
    Window,
}

struct App {
    ui: slint::Weak<AppWindow>,
    docs: Vec<Doc>,
    current: Option<usize>,
    settings: Settings,
    closing: Option<Closing>,
    /// The window may go: everything was saved or let go.
    may_quit: bool,
    toast_seq: u64,
}

type Shared = Rc<RefCell<App>>;

impl App {
    fn ui(&self) -> Option<AppWindow> {
        self.ui.upgrade()
    }

    /// The shown doc's text from the page into the doc.
    fn sync(&mut self) {
        let Some(ui) = self.ui() else { return };
        if let Some(i) = self.current {
            let text = ui.global::<Ed>().get_text().to_string();
            let d = &mut self.docs[i];
            d.text = text;
        }
    }

    fn save_settings(&mut self) {
        self.settings.open = self.docs.iter().filter_map(|d| d.path.clone()).collect();
        // Its place among the docs that are kept: those with a file.
        self.settings.current = self.current.map(|c| self.docs[..c].iter().filter(|d| d.path.is_some()).count()).unwrap_or(0);
        if let Some(ui) = self.ui() {
            let e = ui.global::<Ed>();
            self.settings.wrap = e.get_wrap();
            self.settings.mono = e.get_mono();
            self.settings.font_size = e.get_font_size();
        }
        let _ = std::fs::create_dir_all(settings_file().parent().unwrap());
        if let Ok(j) = serde_json::to_string_pretty(&self.settings) {
            let _ = kit::write_atomic(&settings_file(), j.as_bytes());
        }
    }

    fn remember(&mut self, p: &Path) {
        self.settings.recent.retain(|r| r != p);
        self.settings.recent.insert(0, p.to_path_buf());
        self.settings.recent.truncate(10);
    }

    fn show_tabs(&self) {
        let Some(ui) = self.ui() else { return };
        let e = ui.global::<Ed>();
        let tabs: Vec<TabItem> = self
            .docs
            .iter()
            .map(|d| TabItem {
                title: d.title().into(),
                path: d.path.as_ref().map(|p| tilde(p)).unwrap_or_default().into(),
                dirty: d.dirty,
            })
            .collect();
        e.set_tabs(ModelRc::new(VecModel::from(tabs)));
        e.set_current(self.current.map(|c| c as i32).unwrap_or(-1));
        e.set_changed_on_disk(self.current.is_some_and(|c| self.docs[c].conflict));
        let recent: Vec<RecentItem> = self
            .settings
            .recent
            .iter()
            .filter(|p| p.exists())
            .take(6)
            .map(|p| RecentItem {
                name: p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default().into(),
                folder: p.parent().map(|d| tilde(d)).unwrap_or_default().into(),
            })
            .collect();
        e.set_recent(ModelRc::new(VecModel::from(recent)));
    }

    /// The status line, line numbers and the find count, from the text.
    fn show_status(&self) {
        let Some(ui) = self.ui() else { return };
        let e = ui.global::<Ed>();
        let Some(c) = self.current else { return };
        let d = &self.docs[c];
        let text = e.get_text();
        let mut info = vec![format!("{} words", words(&text))];
        info.push(match d.enc { Enc::Utf8 if d.bom => "UTF-8 with BOM".into(), Enc::Utf8 => "UTF-8".to_string(), Enc::Latin1 => "Latin-1".into() });
        info.push(if d.crlf { "CRLF".into() } else { "LF".into() });
        e.set_info(info.join("  ·  ").into());
        if !e.get_wrap() {
            let n = text.matches('\n').count() + 1;
            let mut s = String::with_capacity(n * 6);
            for i in 1..=n {
                if i > 1 {
                    s.push('\n');
                }
                s.push_str(&i.to_string());
            }
            e.set_lines(s.into());
        }
        self.show_position(d.sel);
    }

    fn show_position(&self, sel: (i32, i32)) {
        let Some(ui) = self.ui() else { return };
        let e = ui.global::<Ed>();
        let text = e.get_text();
        let (line, col) = line_col(&text, sel.0.max(0) as usize);
        let (a, b) = (sel.0.min(sel.1).max(0) as usize, sel.0.max(sel.1).max(0) as usize);
        let mut s = format!("Line {line}, column {col}");
        if a != b {
            let n = text.get(floor(&text, a)..floor(&text, b)).map(|t| t.chars().count()).unwrap_or(0);
            s.push_str(&format!("  ·  {n} selected"));
        }
        e.set_position(s.into());
    }

    /// Show doc `i` on the page.
    fn show(&mut self, i: Option<usize>) {
        self.sync();
        self.current = i.filter(|&i| i < self.docs.len());
        let Some(ui) = self.ui() else { return };
        let e = ui.global::<Ed>();
        match self.current {
            Some(c) => {
                let d = &self.docs[c];
                e.set_text(d.text.clone().into());
                let sel = d.sel;
                self.show_tabs();
                self.show_status();
                ui.invoke_select(sel.1, sel.0);
            }
            None => {
                e.set_text("".into());
                self.show_tabs();
            }
        }
    }

    fn toast(app: &Shared, text: &str) {
        let seq = {
            let mut a = app.borrow_mut();
            a.toast_seq += 1;
            a.toast_seq
        };
        if let Some(ui) = app.borrow().ui() {
            ui.global::<Ed>().set_toast(text.into());
        }
        let app = app.clone();
        slint::Timer::single_shot(Duration::from_millis(2800), move || {
            if app.borrow().toast_seq == seq {
                if let Some(ui) = app.borrow().ui() {
                    ui.global::<Ed>().set_toast("".into());
                }
            }
        });
    }

    fn next_untitled(&self) -> u32 {
        (1..).find(|n| !self.docs.iter().any(|d| d.path.is_none() && d.untitled == *n)).unwrap_or(1)
    }
}

fn tilde(p: &Path) -> String {
    let home = kit::home();
    match p.strip_prefix(&home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

/// Open files: each in a tab, or the tab it's in already.
fn open_paths(app: &Shared, paths: Vec<PathBuf>) {
    let mut last = None;
    let mut errors = Vec::new();
    {
        let mut a = app.borrow_mut();
        a.sync();
        for p in paths {
            let p = std::fs::canonicalize(&p).unwrap_or(p);
            if let Some(i) = a.docs.iter().position(|d| d.path.as_ref() == Some(&p)) {
                last = Some(i);
                continue;
            }
            if !p.exists() {
                // Named but not there yet: a new file, made on saving.
                let mut d = Doc::new(0);
                d.path = Some(p.clone());
                a.docs.push(d);
                last = Some(a.docs.len() - 1);
                continue;
            }
            match load(&p) {
                Ok(d) => {
                    a.remember(&p);
                    // An untouched, empty Untitled gives its place up.
                    if let Some(c) = a.current {
                        let cur = &a.docs[c];
                        if cur.path.is_none() && !cur.dirty && cur.text.is_empty() {
                            a.docs.remove(c);
                            a.current = None;
                        }
                    }
                    a.docs.push(d);
                    last = Some(a.docs.len() - 1);
                }
                Err(e) => errors.push(format!("Couldn't open {}: {e}", p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default())),
            }
        }
        if last.is_some() {
            // Shown below, with the page's text not read back over it.
            a.current = None;
        }
    }
    if let Some(i) = last {
        app.borrow_mut().show(Some(i));
        app.borrow_mut().save_settings();
    }
    if let Some(e) = errors.first() {
        App::toast(app, e);
    }
}

/// Save doc `i`, asking where for a new one; `then` hears whether it was.
fn save(app: &Shared, i: usize, ask: bool, then: impl FnOnce(&Shared, bool) + 'static) {
    app.borrow_mut().sync();
    let (path, title) = {
        let a = app.borrow();
        let d = &a.docs[i];
        (d.path.clone(), d.title())
    };
    match path {
        Some(p) if !ask => {
            let ok = write_doc(app, i, &p);
            then(app, ok);
        }
        _ => {
            let folder = path.as_ref().and_then(|p| p.parent().map(Path::to_path_buf)).or_else(|| Some(kit::home()));
            let name = path.as_ref().and_then(|p| p.file_name().map(|n| n.to_string_lossy().to_string())).unwrap_or_else(|| format!("{title}.txt"));
            let app = app.clone();
            kit::spawn(
                move || kit::portal::save_file("Save as", &name, folder.as_deref()),
                move |chosen| match chosen {
                    Some(p) => {
                        let ok = write_doc(&app, i, &p);
                        if ok {
                            let mut a = app.borrow_mut();
                            a.docs[i].path = Some(p.clone());
                            a.remember(&p);
                            a.save_settings();
                            a.show_tabs();
                        }
                        then(&app, ok);
                    }
                    None => then(&app, false),
                },
            );
        }
    }
}

fn write_doc(app: &Shared, i: usize, p: &Path) -> bool {
    let (bytes, enc, was) = {
        let a = app.borrow();
        let d = &a.docs[i];
        let (b, enc) = encode(&d.text, d.enc, d.bom, d.crlf);
        (b, enc, d.enc)
    };
    match write_file(p, &bytes) {
        Ok(()) => {
            {
                let mut a = app.borrow_mut();
                let d = &mut a.docs[i];
                d.saved = d.text.clone();
                d.dirty = false;
                d.conflict = false;
                d.enc = enc;
                d.mtime = mtime(p);
                a.show_tabs();
                a.show_status();
            }
            if enc != was {
                App::toast(app, "Saved as UTF-8: Latin-1 can't hold some of what's in it");
            }
            true
        }
        Err(e) => {
            App::toast(app, &format!("Couldn't save: {e}"));
            false
        }
    }
}

fn close_tab(app: &Shared, i: usize) {
    {
        let mut a = app.borrow_mut();
        a.sync();
        if i >= a.docs.len() {
            return;
        }
        a.docs.remove(i);
        let next = match a.current {
            Some(c) if c > i => Some(c - 1),
            Some(c) if c == i => {
                if a.docs.is_empty() { None } else { Some(i.min(a.docs.len() - 1)) }
            }
            other => other,
        };
        // The closed tab's text is gone: nothing to read back.
        a.current = None;
        a.show(next);
        a.save_settings();
    }
}

/// Close the window, asking first about anything unsaved.
fn close_window(app: &Shared) -> bool {
    let dirty: Vec<String> = {
        let mut a = app.borrow_mut();
        a.sync();
        a.save_settings();
        if a.may_quit {
            return true;
        }
        a.docs.iter().filter(|d| d.dirty).map(|d| d.title()).collect()
    };
    if dirty.is_empty() {
        return true;
    }
    let mut a = app.borrow_mut();
    a.closing = Some(Closing::Window);
    if let Some(ui) = a.ui() {
        let e = ui.global::<Ed>();
        if dirty.len() == 1 {
            e.set_ask_title(format!("Save changes to {}?", dirty[0]).into());
        } else {
            e.set_ask_title(format!("Save changes to {} documents?", dirty.len()).into());
        }
        e.set_ask_text("What isn't saved is lost if you close without.".into());
        e.set_ask_close(true);
    }
    false
}

fn quit(app: &Shared) {
    app.borrow_mut().may_quit = true;
    if let Some(ui) = app.borrow().ui() {
        let _ = ui.hide();
    }
    let _ = slint::quit_event_loop();
}

/// Save each unsaved doc in turn, then close the window, unless one wasn't.
fn save_all_then_quit(app: &Shared) {
    let next = app.borrow().docs.iter().position(|d| d.dirty);
    match next {
        None => quit(app),
        Some(i) => {
            app.borrow_mut().show(Some(i));
            save(app, i, false, |app, ok| {
                if ok {
                    save_all_then_quit(app);
                }
            });
        }
    }
}

/// Look for files changed by something else.
fn check_disk(app: &Shared) {
    let mut reloaded = Vec::new();
    {
        let mut a = app.borrow_mut();
        a.sync();
        let cur = a.current;
        for (i, d) in a.docs.iter_mut().enumerate() {
            let Some(p) = d.path.clone() else { continue };
            let Some(m) = mtime(&p) else { continue };
            if d.mtime == Some(m) || d.conflict || d.mtime.is_none() {
                continue;
            }
            if d.dirty {
                d.conflict = true;
                continue;
            }
            if let Ok(fresh) = load(&p) {
                let sel = d.sel;
                *d = Doc { sel, untitled: d.untitled, ..fresh };
                reloaded.push((i, d.title()));
            }
        }
        if let Some(c) = cur {
            if reloaded.iter().any(|(i, _)| *i == c) {
                a.current = None;
                a.show(Some(c));
            }
        }
        a.show_tabs();
    }
    if let Some((_, name)) = reloaded.first() {
        App::toast(app, &format!("{name} changed on disk — reloaded"));
    }
}

fn main() {
    kit::init("hyprshell-text");
    let settings: Settings = std::fs::read_to_string(settings_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();

    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-text");
    let e = ui.global::<Ed>();
    e.set_wrap(settings.wrap);
    e.set_mono(settings.mono);
    e.set_font_size(settings.font_size.clamp(8.0, 40.0));
    // The toolkit wants a family's own name, not "monospace".
    if let Ok(o) = std::process::Command::new("fc-match").args(["-f", "%{family[0]}", "monospace"]).output() {
        let name = String::from_utf8_lossy(&o.stdout).trim().to_string();
        if !name.is_empty() {
            e.set_mono_family(name.into());
        }
    }

    let app: Shared = Rc::new(RefCell::new(App { ui: ui.as_weak(), docs: Vec::new(), current: None, settings, closing: None, may_quit: false, toast_seq: 0 }));

    // Typing: the tab marked at once; the rest a moment after it stops.
    let settle = Rc::new(slint::Timer::default());
    {
        let (app, settle) = (app.clone(), settle.clone());
        e.on_edited(move || {
            {
                let mut a = app.borrow_mut();
                if let Some(c) = a.current {
                    if !a.docs[c].dirty {
                        a.docs[c].dirty = true;
                        a.show_tabs();
                    }
                }
            }
            let app = app.clone();
            settle.start(slint::TimerMode::SingleShot, Duration::from_millis(300), move || {
                let mut a = app.borrow_mut();
                a.sync();
                if let Some(c) = a.current {
                    let d = &mut a.docs[c];
                    let dirty = d.text != d.saved || (d.path.as_ref().is_some_and(|p| !p.exists()) && !d.text.is_empty());
                    if dirty != d.dirty {
                        d.dirty = dirty;
                        a.show_tabs();
                    }
                }
                a.show_status();
            });
        });
    }
    {
        let app = app.clone();
        e.on_moved(move |cursor, anchor| {
            // Moved by the app itself, mid-change: it knows where.
            let Ok(mut a) = app.try_borrow_mut() else { return };
            if let Some(c) = a.current {
                a.docs[c].sel = (cursor, anchor);
                a.show_position((cursor, anchor));
            }
        });
    }
    {
        let app = app.clone();
        e.on_new_tab(move || {
            let mut a = app.borrow_mut();
            a.sync();
            let n = a.next_untitled();
            a.docs.push(Doc::new(n));
            let i = a.docs.len() - 1;
            a.show(Some(i));
        });
    }
    {
        let app = app.clone();
        e.on_open(move || {
            let app = app.clone();
            kit::spawn(|| kit::portal::open_files("Open", &[("All files", &["*"][..])]), move |paths| open_paths(&app, paths));
        });
    }
    {
        let app = app.clone();
        e.on_open_recent(move |i| {
            let p = app.borrow().settings.recent.iter().filter(|p| p.exists()).nth(i as usize).cloned();
            if let Some(p) = p {
                open_paths(&app, vec![p]);
            }
        });
    }
    {
        let app = app.clone();
        e.on_save(move || {
            let Some(c) = app.borrow().current else { return };
            save(&app, c, false, |app, ok| {
                if ok {
                    App::toast(app, "Saved");
                }
            });
        });
    }
    {
        let app = app.clone();
        e.on_save_as(move || {
            let Some(c) = app.borrow().current else { return };
            save(&app, c, true, |app, ok| {
                if ok {
                    App::toast(app, "Saved");
                }
            });
        });
    }
    {
        let app = app.clone();
        e.on_pick(move |i| {
            app.borrow_mut().show(Some(i as usize));
        });
    }
    {
        let app = app.clone();
        e.on_close_tab(move |i| {
            if i < 0 {
                return;
            }
            let i = i as usize;
            let dirty = {
                let mut a = app.borrow_mut();
                a.sync();
                a.docs.get(i).map(|d| (d.dirty, d.title()))
            };
            match dirty {
                Some((true, title)) => {
                    let mut a = app.borrow_mut();
                    a.closing = Some(Closing::Tab(i));
                    if let Some(ui) = a.ui() {
                        let e = ui.global::<Ed>();
                        e.set_ask_title(format!("Save changes to {title}?").into());
                        e.set_ask_text("What isn't saved is lost if you close it without.".into());
                        e.set_ask_close(true);
                    }
                }
                Some((false, _)) => close_tab(&app, i),
                None => {}
            }
        });
    }
    {
        let app = app.clone();
        e.on_answer(move |choice| {
            let closing = {
                let mut a = app.borrow_mut();
                if let Some(ui) = a.ui() {
                    ui.global::<Ed>().set_ask_close(false);
                }
                a.closing.take()
            };
            let Some(closing) = closing else { return };
            match (closing, choice) {
                (_, 0) => {}
                (Closing::Tab(i), 1) => close_tab(&app, i),
                (Closing::Tab(i), _) => save(&app, i, false, move |app, ok| {
                    if ok {
                        close_tab(app, i);
                    }
                }),
                (Closing::Window, 1) => quit(&app),
                (Closing::Window, _) => save_all_then_quit(&app),
            }
        });
    }
    // Find and replace.
    {
        let app = app.clone();
        e.on_find(move |needle, dir| {
            let a = app.borrow();
            let Some(ui) = a.ui() else { return };
            let Some(c) = a.current else { return };
            let e = ui.global::<Ed>();
            let text = e.get_text();
            let all = matches(&text, &needle, e.get_match_case());
            let (cur, anc) = a.docs[c].sel;
            let sel = (cur.min(anc).max(0) as usize, cur.max(anc).max(0) as usize);
            match pick_match(&all, sel, dir) {
                Some(k) => {
                    e.set_find_note(format!("{} of {}", k + 1, all.len()).into());
                    let (s, en) = all[k];
                    drop(a);
                    // Shown, while typing goes on in Find.
                    ui.invoke_mark(s as i32, en as i32);
                }
                None => e.set_find_note(if needle.is_empty() { "".into() } else { "No matches".into() }),
            }
        });
    }
    {
        let app = app.clone();
        e.on_replace_one(move || {
            let (ui, c) = {
                let a = app.borrow();
                let (Some(ui), Some(c)) = (a.ui(), a.current) else { return };
                (ui, c)
            };
            let e = ui.global::<Ed>();
            let text = e.get_text().to_string();
            let needle = e.get_find_text().to_string();
            let with = e.get_replace_text().to_string();
            let (cur, anc) = app.borrow().docs[c].sel;
            let (s, en) = (cur.min(anc).max(0) as usize, cur.max(anc).max(0) as usize);
            let all = matches(&text, &needle, e.get_match_case());
            if all.contains(&(s, en)) {
                let t = format!("{}{}{}", &text[..s], with, &text[en..]);
                e.set_text(t.into());
                let after = (s + with.len()) as i32;
                ui.invoke_select(after, after);
                app.borrow_mut().docs[c].sel = (after, after);
                e.invoke_edited();
            }
            e.invoke_find(needle.into(), 1);
        });
    }
    {
        let app = app.clone();
        e.on_replace_all(move || {
            let Some(ui) = app.borrow().ui() else { return };
            let e = ui.global::<Ed>();
            let text = e.get_text().to_string();
            let needle = e.get_find_text().to_string();
            let with = e.get_replace_text().to_string();
            let all = matches(&text, &needle, e.get_match_case());
            if all.is_empty() {
                return;
            }
            let mut t = String::with_capacity(text.len());
            let mut last = 0;
            for (s, en) in &all {
                t.push_str(&text[last..*s]);
                t.push_str(&with);
                last = *en;
            }
            t.push_str(&text[last..]);
            e.set_text(t.into());
            e.invoke_edited();
            e.set_find_note("".into());
            let n = all.len();
            App::toast(&app, &if n == 1 { "1 replaced".to_string() } else { format!("{n} replaced") });
        });
    }
    {
        let app = app.clone();
        e.on_indent(move |out| {
            let (ui, c) = {
                let a = app.borrow();
                let (Some(ui), Some(c)) = (a.ui(), a.current) else { return };
                (ui, c)
            };
            let e = ui.global::<Ed>();
            let text = e.get_text().to_string();
            let (cur, anc) = app.borrow().docs[c].sel;
            let (t, (s, en)) = indent(&text, (anc.max(0) as usize, cur.max(0) as usize), out);
            if t != text {
                e.set_text(t.into());
                e.invoke_edited();
            }
            ui.invoke_select(s as i32, en as i32);
        });
    }
    {
        let app = app.clone();
        e.on_reload(move || {
            let mut a = app.borrow_mut();
            let Some(c) = a.current else { return };
            let Some(p) = a.docs[c].path.clone() else { return };
            if let Ok(fresh) = load(&p) {
                let sel = a.docs[c].sel;
                a.docs[c] = Doc { sel, ..fresh };
                a.current = None;
                a.show(Some(c));
            }
        });
    }
    {
        let app = app.clone();
        e.on_keep_mine(move || {
            let mut a = app.borrow_mut();
            let Some(c) = a.current else { return };
            let d = &mut a.docs[c];
            d.conflict = false;
            d.mtime = d.path.as_deref().and_then(mtime);
            a.show_tabs();
        });
    }
    {
        let app = app.clone();
        e.on_settings_changed(move || {
            let mut a = app.borrow_mut();
            a.save_settings();
            a.show_status();
        });
    }

    // Closing the window, from its button or the compositor.
    {
        let app = app.clone();
        ui.global::<Win>().on_close(move || {
            if close_window(&app) {
                quit(&app);
            }
        });
    }
    {
        let app = app.clone();
        ui.window().on_close_requested(move || {
            if close_window(&app) {
                let _ = slint::quit_event_loop();
                slint::CloseRequestResponse::HideWindow
            } else {
                slint::CloseRequestResponse::KeepWindowShown
            }
        });
    }

    let disk = slint::Timer::default();
    {
        let app = app.clone();
        disk.start(slint::TimerMode::Repeated, Duration::from_secs(2), move || check_disk(&app));
    }

    // Files from the command line; else the ones left open last time.
    let args: Vec<PathBuf> = std::env::args()
        .skip(1)
        .filter(|a| !a.starts_with("--"))
        .map(|a| kit::portal::uri_to_path(&a).unwrap_or_else(|| PathBuf::from(&a)))
        .map(|p| if p.is_absolute() { p } else { std::env::current_dir().map(|d| d.join(&p)).unwrap_or(p) })
        .collect();
    if !args.is_empty() {
        open_paths(&app, args);
    } else {
        let (open, current) = {
            let a = app.borrow();
            (a.settings.open.iter().filter(|p| p.exists()).cloned().collect::<Vec<_>>(), a.settings.current)
        };
        if !open.is_empty() {
            open_paths(&app, open);
            let n = app.borrow().docs.len();
            if n > 0 {
                app.borrow_mut().show(Some(current.min(n - 1)));
            }
        } else {
            app.borrow().show_tabs();
        }
    }

    ui.run().expect("run");
    app.borrow_mut().save_settings();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_what_files_are() {
        let (t, enc, bom, crlf) = decode(b"\xEF\xBB\xBFone\r\ntwo\r\n").unwrap();
        assert_eq!((t.as_str(), enc, bom, crlf), ("one\ntwo\n", Enc::Utf8, true, true));
        assert_eq!(encode(&t, enc, bom, crlf).0, b"\xEF\xBB\xBFone\r\ntwo\r\n");
        let (t, enc, _, _) = decode(b"caf\xe9").unwrap();
        assert_eq!((t.as_str(), enc), ("café", Enc::Latin1));
        assert_eq!(encode(&t, enc, false, false), (b"caf\xe9".to_vec(), Enc::Latin1));
        // What Latin-1 can't hold: UTF-8.
        assert_eq!(encode("café →", Enc::Latin1, false, false).1, Enc::Utf8);
        assert!(decode(b"\x7fELF\x00\x00").is_err());
    }

    #[test]
    fn finds() {
        let t = "Fox fox FOX";
        assert_eq!(matches(t, "fox", false).len(), 3);
        assert_eq!(matches(t, "fox", true), vec![(4, 7)]);
        let all = matches(t, "fox", false);
        assert_eq!(pick_match(&all, (0, 0), 0), Some(0));
        assert_eq!(pick_match(&all, (0, 3), 1), Some(1));
        assert_eq!(pick_match(&all, (8, 11), 1), Some(0));
        assert_eq!(pick_match(&all, (0, 3), -1), Some(2));
        assert_eq!(line_col("ab\ncdé\nx", 7), (2, 4));
    }

    #[test]
    fn indents() {
        assert_eq!(indent("ab", (1, 1), false), ("a    b".to_string(), (5, 5)));
        let (t, _) = indent("one\ntwo\nthree", (0, 6), false);
        assert_eq!(t, "    one\n    two\nthree");
        let (t, _) = indent("    one\n    two\nthree", (0, 12), true);
        assert_eq!(t, "one\ntwo\nthree");
        // Tabs where the file uses them.
        let (t, _) = indent("\ta\n\tb\nc", (6, 7), false);
        assert_eq!(t, "\ta\n\tb\n\tc");
    }

    #[test]
    fn writes_through_links_keeping_modes() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("hyprshell-text-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let real = dir.join("real.sh");
        std::fs::write(&real, "old").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o750)).unwrap();
        let link = dir.join("link.sh");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        write_file(&link, b"new").unwrap();
        assert!(link.is_symlink());
        assert_eq!(std::fs::read(&real).unwrap(), b"new");
        assert_eq!(std::fs::metadata(&real).unwrap().permissions().mode() & 0o777, 0o750);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
