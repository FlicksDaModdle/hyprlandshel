//! Notes: Markdown files in ~/Notes, folders as folders, so they are as
//! much yours in a text editor, a sync tool or git as they are here.
//!
//! Everything happens on the UI thread — a notes folder is small — with
//! the open note saved half a second after the last keystroke, and the
//! folder looked at again every few seconds for changes made elsewhere.
//!
//! HYPRSHELL_NOTES_DIR points it somewhere other than ~/Notes.

slint::include_modules!();

use hyprshell_kit as kit;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};
use slint::{ComponentHandle, ModelRc, SharedString, StyledText, VecModel};
use std::cell::RefCell;
use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

const EXTS: [&str; 3] = ["md", "markdown", "txt"];

#[derive(Clone)]
struct Note {
    rel: String,
    folder: String,
    title: String,
    snippet: String,
    modified: i64,
    haystack: String,
}

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct Saved {
    #[serde(default)]
    pinned: Vec<String>,
    #[serde(default)]
    last: String,
    #[serde(default)]
    place: String,
    #[serde(default)]
    view: i32,
}

struct State {
    root: PathBuf,
    notes: Vec<Note>,
    folders: Vec<String>,
    pinned: HashSet<String>,
    place: String,
    search: String,
    current: Option<String>,
    // What the file held when it was last read or written: an edit made
    // elsewhere shows up as a difference from this.
    on_disk: String,
    dirty: bool,
    stamp: Vec<(String, i64)>,
}

fn state_file() -> PathBuf {
    kit::config_dir().join("hyprshell-notes/state.json")
}

fn mtime(p: &Path) -> i64 {
    std::fs::metadata(p)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// The title: the first line with something in it, without its heading
/// marks; or the file's name.
fn title_of(text: &str, rel: &str) -> String {
    for line in text.lines() {
        let t = line.trim().trim_start_matches('#').trim();
        if !t.is_empty() {
            return t.chars().take(120).collect();
        }
    }
    Path::new(rel).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default()
}

/// A line or two of what follows the title, without the Markdown.
fn snippet_of(text: &str) -> String {
    let mut out = String::new();
    let mut first = true;
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if first {
            first = false;
            continue;
        }
        let t = t
            .trim_start_matches(|c| c == '#' || c == '>' || c == ' ')
            .trim_start_matches("- [ ] ")
            .trim_start_matches("- [x] ")
            .trim_start_matches("- ")
            .trim_start_matches("* ");
        if t.starts_with("```") {
            continue;
        }
        let t: String = t.chars().filter(|c| !matches!(c, '*' | '_' | '`')).collect();
        if !out.is_empty() {
            out.push(' ');
        }
        out += &t;
        if out.len() > 160 {
            break;
        }
    }
    out.chars().take(160).collect()
}

impl State {
    fn scan(&mut self) {
        let mut notes = Vec::new();
        let mut folders = BTreeSet::new();
        fn walk(root: &Path, dir: &Path, depth: u32, notes: &mut Vec<Note>, folders: &mut BTreeSet<String>) {
            let Ok(rd) = std::fs::read_dir(dir) else { return };
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().to_string();
                if name.starts_with('.') {
                    continue;
                }
                let p = e.path();
                let rel = p.strip_prefix(root).unwrap_or(&p).to_string_lossy().to_string();
                if p.is_dir() {
                    if depth < 4 {
                        folders.insert(rel.clone());
                        walk(root, &p, depth + 1, notes, folders);
                    }
                } else if p.extension().map(|x| EXTS.contains(&x.to_string_lossy().to_lowercase().as_str())).unwrap_or(false) {
                    let text = std::fs::read_to_string(&p).unwrap_or_default();
                    let folder = Path::new(&rel).parent().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
                    notes.push(Note {
                        title: title_of(&text, &rel),
                        snippet: snippet_of(&text),
                        modified: mtime(&p),
                        haystack: text.to_lowercase(),
                        rel,
                        folder,
                    });
                }
            }
        }
        walk(&self.root, &self.root, 0, &mut notes, &mut folders);
        notes.sort_by(|a, b| b.modified.cmp(&a.modified));
        self.stamp = notes.iter().map(|n| (n.rel.clone(), n.modified)).collect();
        self.notes = notes;
        self.folders = folders.into_iter().collect();
        self.pinned.retain(|p| self.notes.iter().any(|n| n.rel == *p));
    }

    /// Whether anything in the folder changed since the last scan.
    fn changed_on_disk(&self) -> bool {
        let mut now = Vec::new();
        fn walk(root: &Path, dir: &Path, depth: u32, out: &mut Vec<(String, i64)>) {
            let Ok(rd) = std::fs::read_dir(dir) else { return };
            for e in rd.flatten() {
                let p = e.path();
                if e.file_name().to_string_lossy().starts_with('.') {
                    continue;
                }
                if p.is_dir() {
                    if depth < 4 {
                        out.push((p.strip_prefix(root).unwrap_or(&p).to_string_lossy().to_string() + "/", 0));
                        walk(root, &p, depth + 1, out);
                    }
                } else if p.extension().map(|x| EXTS.contains(&x.to_string_lossy().to_lowercase().as_str())).unwrap_or(false) {
                    out.push((p.strip_prefix(root).unwrap_or(&p).to_string_lossy().to_string(), mtime(&p)));
                }
            }
        }
        walk(&self.root, &self.root, 0, &mut now);
        let mut a: Vec<_> = now.into_iter().filter(|(r, _)| !r.ends_with('/')).collect();
        let mut b = self.stamp.clone();
        a.sort();
        b.sort();
        // Folders count too, so a new empty one shows.
        let dirs = {
            let mut d = BTreeSet::new();
            fn walk_dirs(root: &Path, dir: &Path, depth: u32, d: &mut BTreeSet<String>) {
                let Ok(rd) = std::fs::read_dir(dir) else { return };
                for e in rd.flatten() {
                    let p = e.path();
                    if p.is_dir() && !e.file_name().to_string_lossy().starts_with('.') && depth < 4 {
                        d.insert(p.strip_prefix(root).unwrap_or(&p).to_string_lossy().to_string());
                        walk_dirs(root, &p, depth + 1, d);
                    }
                }
            }
            walk_dirs(&self.root, &self.root, 0, &mut d);
            d.into_iter().collect::<Vec<_>>()
        };
        a != b || dirs != self.folders
    }

    fn visible(&self) -> Vec<&Note> {
        let words: Vec<String> = self.search.to_lowercase().split_whitespace().map(|w| w.to_string()).collect();
        let mut v: Vec<&Note> = self
            .notes
            .iter()
            .filter(|n| match self.place.as_str() {
                "" => true,
                "@pinned" => self.pinned.contains(&n.rel),
                f => n.folder == f || n.folder.starts_with(&format!("{f}/")),
            })
            .filter(|n| words.iter().all(|w| n.haystack.contains(w.as_str()) || n.title.to_lowercase().contains(w.as_str())))
            .collect();
        // Pinned first, then the most recently changed.
        v.sort_by(|a, b| {
            (self.pinned.contains(&b.rel), b.modified).cmp(&(self.pinned.contains(&a.rel), a.modified))
        });
        v
    }

    fn save_state(&self, view: i32) {
        let s = Saved {
            pinned: self.pinned.iter().cloned().collect(),
            last: self.current.clone().unwrap_or_default(),
            place: self.place.clone(),
            view,
        };
        let p = state_file();
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        let _ = kit::write_atomic(&p, serde_json::to_string_pretty(&s).unwrap_or_default().as_bytes());
    }

    fn abs(&self, rel: &str) -> PathBuf {
        self.root.join(rel)
    }

    /// A file name in `dir` from `title`, not already taken.
    fn free_name(&self, dir: &Path, title: &str, except: Option<&Path>) -> PathBuf {
        let clean: String = title
            .chars()
            .map(|c| if matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') { ' ' } else { c })
            .collect::<String>()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let base: String = if clean.is_empty() { "Untitled".into() } else { clean.chars().take(80).collect() };
        let mut n = 1;
        loop {
            let name = if n == 1 { format!("{base}.md") } else { format!("{base} {n}.md") };
            let p = dir.join(name);
            if !p.exists() || Some(p.as_path()) == except {
                return p;
            }
            n += 1;
        }
    }
}

// ── the preview ─────────────────────────────────────────────────────────

fn styled(src: &str) -> StyledText {
    let s = src.trim();
    StyledText::from_markdown(s).unwrap_or_else(|_| StyledText::from_plain_text(s))
}

fn line_of(text: &str, byte: usize) -> i32 {
    text[..byte.min(text.len())].matches('\n').count() as i32
}

/// The note as blocks the window draws one by one: Slint's own Markdown
/// covers emphasis, code and links inside a block, not headings, lists,
/// quotes or code blocks, so those are worked out here.
fn blocks(text: &str) -> Vec<Block> {
    let mut out = Vec::new();
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_TASKLISTS);
    opts.insert(Options::ENABLE_STRIKETHROUGH);
    let parser = Parser::new_ext(text, opts).into_offset_iter();
    let mut lists: Vec<Option<u64>> = Vec::new();
    let mut quote = 0;
    let mut item: Option<(usize, bool, Option<bool>, String)> = None; // start, numbered, task, marker
    let mut item_end: Option<usize> = None;
    let mut heading: Option<(u32, String)> = None;
    let mut code: Option<String> = None;
    let mut para_start: Option<usize> = None;

    let blank = |kind: &str| Block {
        kind: kind.into(),
        text: SharedString::new(),
        styled: StyledText::default(),
        checked: false,
        line: 0,
        level: 0,
        marker: SharedString::new(),
    };

    let flush_item = |item: &mut Option<(usize, bool, Option<bool>, String)>, end: usize, depth: usize, out: &mut Vec<Block>| {
        if let Some((start, numbered, task, marker)) = item.take() {
            let src = &text[start..end.max(start)];
            // The item's own text: its first lines, without the marker and
            // the task box.
            let first: String = src.lines().take_while(|l| !l.trim().is_empty()).collect::<Vec<_>>().join(" ");
            let t = first.trim_start();
            let t = t.trim_start_matches(|c: char| c.is_ascii_digit());
            let t = t.trim_start_matches(['-', '*', '+', '.', ')']).trim_start();
            let t = t.strip_prefix("[ ]").or_else(|| t.strip_prefix("[x]")).or_else(|| t.strip_prefix("[X]")).unwrap_or(t).trim_start();
            let mut b = Block {
                kind: if task.is_some() { "task" } else if numbered { "number" } else { "bullet" }.into(),
                text: t.into(),
                styled: styled(t),
                checked: task.unwrap_or(false),
                line: line_of(text, start),
                level: depth.saturating_sub(1) as i32,
                marker: marker.into(),
                ..blank("p")
            };
            b.kind = if task.is_some() { "task".into() } else if numbered { "number".into() } else { "bullet".into() };
            out.push(b);
        }
    };

    for (ev, range) in parser {
        match ev {
            Event::Start(Tag::Heading { level, .. }) => heading = Some((level as u32, String::new())),
            Event::End(TagEnd::Heading(_)) => {
                if let Some((lvl, t)) = heading.take() {
                    let kind = match lvl { 1 => "h1", 2 => "h2", _ => "h3" };
                    out.push(Block { text: t.trim().into(), line: line_of(text, range.start), ..blank(kind) });
                }
            }
            Event::Start(Tag::CodeBlock(_)) => code = Some(String::new()),
            Event::End(TagEnd::CodeBlock) => {
                if let Some(c) = code.take() {
                    out.push(Block { text: c.trim_end().into(), line: line_of(text, range.start), ..blank("code") });
                }
            }
            Event::Start(Tag::BlockQuote(_)) => quote += 1,
            Event::End(TagEnd::BlockQuote(_)) => quote -= 1,
            Event::Start(Tag::List(first)) => {
                // A nested list ends the text of the item it is in.
                flush_item(&mut item, range.start, lists.len(), &mut out);
                lists.push(first);
            }
            Event::End(TagEnd::List(_)) => {
                flush_item(&mut item, item_end.unwrap_or(range.end), lists.len(), &mut out);
                lists.pop();
            }
            Event::Start(Tag::Item) => {
                flush_item(&mut item, range.start, lists.len(), &mut out);
                let marker = match lists.last_mut() {
                    Some(Some(n)) => {
                        let m = format!("{n}.");
                        *n += 1;
                        m
                    }
                    _ => "•".to_string(),
                };
                item = Some((range.start, matches!(lists.last(), Some(Some(_))), None, marker));
                item_end = Some(range.end);
            }
            Event::End(TagEnd::Item) => {
                flush_item(&mut item, range.end, lists.len(), &mut out);
            }
            Event::TaskListMarker(done) => {
                if let Some(i) = item.as_mut() {
                    i.2 = Some(done);
                }
            }
            Event::Start(Tag::Paragraph) => {
                if item.is_none() {
                    para_start = Some(range.start);
                }
            }
            Event::End(TagEnd::Paragraph) => {
                if let Some(s) = para_start.take() {
                    let src = &text[s..range.end];
                    // Quoted lines lose their markers before styling.
                    let body: String = if quote > 0 {
                        src.lines().map(|l| l.trim_start().trim_start_matches('>').trim_start()).collect::<Vec<_>>().join("\n")
                    } else {
                        src.to_string()
                    };
                    out.push(Block {
                        text: body.trim().into(),
                        styled: styled(&body),
                        line: line_of(text, s),
                        ..blank(if quote > 0 { "quote" } else { "p" })
                    });
                }
            }
            Event::Rule => out.push(Block { line: line_of(text, range.start), ..blank("rule") }),
            Event::Text(t) | Event::Code(t) => {
                if let Some((_, h)) = heading.as_mut() {
                    h.push_str(&t);
                } else if let Some(c) = code.as_mut() {
                    c.push_str(&t);
                }
            }
            _ => {}
        }
    }
    out
}

// ── formatting ──────────────────────────────────────────────────────────

fn line_start(t: &str, at: usize) -> usize {
    t[..at.min(t.len())].rfind('\n').map(|i| i + 1).unwrap_or(0)
}
fn line_end(t: &str, at: usize) -> usize {
    t[at.min(t.len())..].find('\n').map(|i| at + i).unwrap_or(t.len())
}
fn floor(t: &str, mut i: usize) -> usize {
    i = i.min(t.len());
    while !t.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// Apply a formatting button to `text` with the selection from `a` to `c`
/// (byte offsets): (new text, new anchor, new cursor).
fn format(kind: &str, text: &str, a: usize, c: usize) -> (String, usize, usize) {
    let (s, e) = (floor(text, a.min(c)), floor(text, a.max(c)));
    let wrap = |mark: &str| {
        let mut t = String::with_capacity(text.len() + 2 * mark.len());
        t += &text[..s];
        let inner = &text[s..e];
        // Already wrapped: unwrap.
        if s >= mark.len() && text[..s].ends_with(mark) && text[e..].starts_with(mark) {
            let mut t = String::new();
            t += &text[..s - mark.len()];
            t += inner;
            t += &text[e + mark.len()..];
            return (t, s - mark.len(), e - mark.len());
        }
        t += mark;
        t += inner;
        t += mark;
        t += &text[e..];
        (t, s + mark.len(), e + mark.len())
    };
    match kind {
        "bold" => wrap("**"),
        "italic" => wrap("_"),
        "code" => {
            if text[s..e].contains('\n') {
                let mut t = String::new();
                t += &text[..s];
                t += "```\n";
                t += &text[s..e];
                t += "\n```";
                t += &text[e..];
                (t, s + 4, e + 4)
            } else {
                wrap("`")
            }
        }
        "h1" => {
            // # → ## → ### → none, on the cursor's line.
            let ls = line_start(text, c);
            let le = line_end(text, c);
            let line = &text[ls..le];
            let hashes = line.chars().take_while(|ch| *ch == '#').count();
            let rest = line[hashes..].trim_start();
            let next = match hashes { 0 => "# ".to_string(), 1 => "## ".into(), 2 => "### ".into(), _ => String::new() };
            let new_line = format!("{next}{rest}");
            let t = format!("{}{}{}", &text[..ls], new_line, &text[le..]);
            let pos = ls + new_line.len();
            (t, pos, pos)
        }
        "task" | "bullet" | "quote" => {
            let prefix = match kind { "task" => "- [ ] ", "bullet" => "- ", _ => "> " };
            let ls = line_start(text, s);
            let le = line_end(text, e);
            let lines: Vec<&str> = text[ls..le].split('\n').collect();
            let all_have = lines.iter().all(|l| l.trim().is_empty() || l.trim_start().starts_with(prefix.trim_end()));
            let changed: Vec<String> = lines
                .iter()
                .map(|l| {
                    if all_have {
                        let lead = l.len() - l.trim_start().len();
                        let body = &l[lead..];
                        let body = body.strip_prefix(prefix).or_else(|| body.strip_prefix(prefix.trim_end())).unwrap_or(body);
                        let body = if kind == "task" { body.strip_prefix("- [x] ").unwrap_or(body) } else { body };
                        format!("{}{}", &l[..lead], body)
                    } else if l.trim().is_empty() && lines.len() > 1 {
                        l.to_string()
                    } else {
                        format!("{prefix}{l}")
                    }
                })
                .collect();
            let block = changed.join("\n");
            let t = format!("{}{}{}", &text[..ls], block, &text[le..]);
            let end = ls + block.len();
            (t, end, end)
        }
        _ => (text.to_string(), a, c),
    }
}

fn toggle_task(text: &str, line: usize) -> String {
    let mut lines: Vec<String> = text.split('\n').map(|l| l.to_string()).collect();
    if let Some(l) = lines.get_mut(line) {
        if let Some(i) = l.find("[ ]") {
            l.replace_range(i..i + 3, "[x]");
        } else if let Some(i) = l.find("[x]").or_else(|| l.find("[X]")) {
            l.replace_range(i..i + 3, "[ ]");
        }
    }
    lines.join("\n")
}

// ── the window ──────────────────────────────────────────────────────────

struct App {
    ui: slint::Weak<AppWindow>,
    st: RefCell<State>,
    save_timer: slint::Timer,
    preview_timer: slint::Timer,
    toast_timer: slint::Timer,
}

impl App {
    fn ui(&self) -> AppWindow {
        self.ui.upgrade().unwrap()
    }

    fn toast(self: &Rc<Self>, text: &str) {
        let ui = self.ui();
        ui.global::<Notes>().set_toast(text.into());
        let w = self.ui.clone();
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(2600), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Notes>().set_toast(SharedString::new());
            }
        });
    }

    fn refresh_list(&self) {
        let ui = self.ui();
        let n = ui.global::<Notes>();
        let st = self.st.borrow();
        let rows: Vec<NoteRow> = st
            .visible()
            .iter()
            .map(|x| NoteRow {
                path: x.rel.clone().into(),
                title: x.title.clone().into(),
                snippet: x.snippet.clone().into(),
                when: kit::when(x.modified).into(),
                pinned: st.pinned.contains(&x.rel),
                folder: if st.place == x.folder { SharedString::new() } else { x.folder.clone().into() },
            })
            .collect();
        n.set_notes(ModelRc::new(VecModel::from(rows)));
        let folders: Vec<Folder> = st
            .folders
            .iter()
            .map(|f| Folder {
                path: f.clone().into(),
                name: f.clone().into(),
                count: st.notes.iter().filter(|x| x.folder == *f).count() as i32,
            })
            .collect();
        n.set_folders(ModelRc::new(VecModel::from(folders)));
        n.set_all_count(st.notes.len() as i32);
        n.set_pinned_count(st.pinned.len() as i32);
        n.set_place(st.place.clone().into());
        let cur = st.current.clone().unwrap_or_default();
        n.set_current(cur.clone().into());
        n.set_current_pinned(st.pinned.contains(&cur));
        n.set_current_title(st.notes.iter().find(|x| x.rel == cur).map(|x| x.title.clone()).unwrap_or_default().into());
    }

    fn refresh_preview(&self) {
        let ui = self.ui();
        let n = ui.global::<Notes>();
        let body = n.get_body().to_string();
        n.set_preview(ModelRc::new(VecModel::from(blocks(&body))));
        n.set_words(body.split_whitespace().count() as i32);
    }

    fn open(self: &Rc<Self>, rel: &str) {
        self.flush();
        let text = {
            let st = self.st.borrow();
            std::fs::read_to_string(st.abs(rel)).unwrap_or_default()
        };
        {
            let mut st = self.st.borrow_mut();
            st.current = Some(rel.to_string());
            st.on_disk = text.clone();
            st.dirty = false;
        }
        let ui = self.ui();
        ui.global::<Notes>().set_body(text.into());
        ui.global::<Notes>().set_status("".into());
        self.refresh_preview();
        self.refresh_list();
        self.st.borrow().save_state(ui.get_view());
    }

    /// Write the open note now if it has changes.
    fn flush(&self) {
        let ui = self.ui();
        let body = ui.global::<Notes>().get_body().to_string();
        let mut st = self.st.borrow_mut();
        if !st.dirty {
            return;
        }
        let Some(rel) = st.current.clone() else { return };
        let mut path = st.abs(&rel);
        if kit::write_atomic(&path, body.as_bytes()).is_err() {
            ui.global::<Notes>().set_status("Couldn't save".into());
            return;
        }
        st.dirty = false;
        st.on_disk = body.clone();
        // A note still called Untitled takes its name from its title the
        // first time it has one.
        let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
        let title = title_of(&body, &rel);
        if stem.starts_with("Untitled") && !title.starts_with("Untitled") && !body.trim().is_empty() {
            let dir = path.parent().unwrap().to_path_buf();
            let target = st.free_name(&dir, &title, Some(&path));
            if target != path && std::fs::rename(&path, &target).is_ok() {
                let new_rel = target.strip_prefix(&st.root).unwrap_or(&target).to_string_lossy().to_string();
                if st.pinned.remove(&rel) {
                    st.pinned.insert(new_rel.clone());
                }
                st.current = Some(new_rel);
                path = target;
            }
        }
        let rel = st.current.clone().unwrap();
        let modified = mtime(&path);
        let folder = Path::new(&rel).parent().map(|f| f.to_string_lossy().to_string()).unwrap_or_default();
        let entry = Note {
            rel: rel.clone(),
            folder,
            title: title_of(&body, &rel),
            snippet: snippet_of(&body),
            modified,
            haystack: body.to_lowercase(),
        };
        let root = st.root.clone();
        st.notes.retain(|n| n.rel != rel && st_exists(&root, &n.rel));
        st.notes.insert(0, entry);
        st.stamp = st.notes.iter().map(|n| (n.rel.clone(), n.modified)).collect();
        ui.global::<Notes>().set_status("Saved".into());
    }

    fn rescan(self: &Rc<Self>) {
        self.flush();
        self.st.borrow_mut().scan();
        // The open note changed elsewhere, and not here: take the new text.
        let (cur, on_disk) = {
            let st = self.st.borrow();
            (st.current.clone(), st.on_disk.clone())
        };
        if let Some(rel) = cur {
            let path = self.st.borrow().abs(&rel);
            if !path.exists() {
                self.st.borrow_mut().current = None;
                self.ui().global::<Notes>().set_body("".into());
            } else {
                let now = std::fs::read_to_string(&path).unwrap_or_default();
                if now != on_disk && !self.st.borrow().dirty {
                    self.st.borrow_mut().on_disk = now.clone();
                    self.ui().global::<Notes>().set_body(now.into());
                    self.refresh_preview();
                }
            }
        }
        self.refresh_list();
    }
}

fn st_exists(root: &Path, rel: &str) -> bool {
    root.join(rel).exists()
}

fn main() {
    kit::init("hyprshell-notes");
    let root = std::env::var_os("HYPRSHELL_NOTES_DIR").map(PathBuf::from).unwrap_or_else(|| kit::home().join("Notes"));
    let _ = std::fs::create_dir_all(&root);
    let saved: Saved = std::fs::read_to_string(state_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();

    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-notes");
    ui.set_view(saved.view.clamp(0, 2));
    ui.global::<Notes>().set_root_dir(root.to_string_lossy().to_string().into());

    let mut st = State {
        root: root.clone(),
        notes: Vec::new(),
        folders: Vec::new(),
        pinned: saved.pinned.into_iter().collect(),
        place: saved.place,
        search: String::new(),
        current: None,
        on_disk: String::new(),
        dirty: false,
        stamp: Vec::new(),
    };
    st.scan();
    if !st.folders.contains(&st.place) && st.place != "@pinned" {
        st.place.clear();
    }
    // A first run gets a note that says what this is.
    if st.notes.is_empty() {
        let welcome = "# Welcome to Notes\n\nNotes are plain Markdown files in ~/Notes. Folders here are folders there, so they stay yours in any editor.\n\n## Try it\n\n- [ ] Write a **bold** word with the B above, or _italics_ with the I\n- [ ] Tick this box in the preview\n- [x] Open Notes\n\n> Each note saves itself as you type.\n";
        let p = root.join("Welcome to Notes.md");
        let _ = std::fs::write(&p, welcome);
        st.scan();
    }
    let first = if !saved.last.is_empty() && st.notes.iter().any(|n| n.rel == saved.last) {
        Some(saved.last.clone())
    } else {
        st.visible().first().map(|n| n.rel.clone())
    };

    let app = Rc::new(App {
        ui: ui.as_weak(),
        st: RefCell::new(st),
        save_timer: slint::Timer::default(),
        preview_timer: slint::Timer::default(),
        toast_timer: slint::Timer::default(),
    });
    app.refresh_list();
    if let Some(rel) = first {
        app.open(&rel);
    }

    let n = ui.global::<Notes>();
    let a = app.clone();
    n.on_pick_place(move |p| {
        a.st.borrow_mut().place = p.to_string();
        a.refresh_list();
        let ui = a.ui();
        a.st.borrow().save_state(ui.get_view());
    });
    let a = app.clone();
    n.on_open(move |p| a.open(&p));
    let a = app.clone();
    n.on_searched(move |t| {
        a.st.borrow_mut().search = t.to_string();
        a.refresh_list();
    });
    let a = app.clone();
    n.on_edited(move |_| {
        a.st.borrow_mut().dirty = true;
        a.ui().global::<Notes>().set_status("Editing…".into());
        let b = a.clone();
        a.save_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(600), move || {
            b.flush();
            b.refresh_list();
        });
        let b = a.clone();
        a.preview_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(150), move || b.refresh_preview());
    });
    let a = app.clone();
    n.on_new_note(move || {
        a.flush();
        let (path, rel) = {
            let st = a.st.borrow();
            let dir = if st.place.is_empty() || st.place == "@pinned" { st.root.clone() } else { st.abs(&st.place) };
            let p = st.free_name(&dir, "Untitled", None);
            let rel = p.strip_prefix(&st.root).unwrap_or(&p).to_string_lossy().to_string();
            (p, rel)
        };
        if std::fs::write(&path, "").is_err() {
            a.toast("Couldn't create the note");
            return;
        }
        {
            let mut st = a.st.borrow_mut();
            st.search.clear();
            st.scan();
        }
        a.ui().global::<Notes>().set_search("".into());
        a.open(&rel);
        let ui = a.ui();
        if ui.get_view() == 1 {
            ui.set_view(0);
        }
        ui.invoke_apply_format("".into(), 0, 0);
    });
    let a = app.clone();
    n.on_new_folder(move |name| {
        let name = name.trim().replace('/', " ");
        if name.is_empty() {
            return;
        }
        let path = {
            let st = a.st.borrow();
            let base = if st.place.is_empty() || st.place == "@pinned" { st.root.clone() } else { st.abs(&st.place) };
            base.join(&name)
        };
        match std::fs::create_dir_all(&path) {
            Ok(_) => {
                let rel = path.strip_prefix(&a.st.borrow().root).unwrap_or(&path).to_string_lossy().to_string();
                a.st.borrow_mut().scan();
                a.st.borrow_mut().place = rel;
                a.refresh_list();
            }
            Err(e) => a.toast(&format!("Couldn't make the folder: {e}")),
        }
    });
    let a = app.clone();
    n.on_toggle_pin(move |p| {
        {
            let mut st = a.st.borrow_mut();
            let p = p.to_string();
            if !st.pinned.remove(&p) {
                st.pinned.insert(p);
            }
        }
        a.refresh_list();
        let ui = a.ui();
        a.st.borrow().save_state(ui.get_view());
    });
    let a = app.clone();
    n.on_delete_note(move |p| {
        a.flush();
        let path = a.st.borrow().abs(&p);
        match kit::trash(&path) {
            Ok(_) => {
                let was_open = a.st.borrow().current.as_deref() == Some(p.as_str());
                a.st.borrow_mut().scan();
                if was_open {
                    let next = a.st.borrow().visible().first().map(|n| n.rel.clone());
                    a.st.borrow_mut().current = None;
                    a.ui().global::<Notes>().set_body("".into());
                    if let Some(n) = next {
                        a.open(&n);
                    }
                }
                a.refresh_list();
                a.toast("Moved to the Trash");
            }
            Err(e) => a.toast(&format!("Couldn't move it to the Trash: {e}")),
        }
    });
    let a = app.clone();
    n.on_move_note(move |p, folder| {
        a.flush();
        let (from, to) = {
            let st = a.st.borrow();
            let from = st.abs(&p);
            let dir = if folder.is_empty() { st.root.clone() } else { st.abs(&folder) };
            let stem = from.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            let to = st.free_name(&dir, &stem, None);
            (from, to)
        };
        if std::fs::rename(&from, &to).is_ok() {
            let new_rel = to.strip_prefix(&a.st.borrow().root).unwrap_or(&to).to_string_lossy().to_string();
            {
                let mut st = a.st.borrow_mut();
                if st.pinned.remove(p.as_str()) {
                    st.pinned.insert(new_rel.clone());
                }
                if st.current.as_deref() == Some(p.as_str()) {
                    st.current = Some(new_rel);
                }
                st.scan();
            }
            a.refresh_list();
        } else {
            a.toast("Couldn't move the note");
        }
    });
    let a = app.clone();
    n.on_rename_folder(move |from, to| {
        let to = to.trim().replace('/', " ");
        if to.is_empty() {
            return;
        }
        a.flush();
        let (src, dst) = {
            let st = a.st.borrow();
            let src = st.abs(&from);
            let dst = src.parent().unwrap_or(&st.root).join(&to);
            (src, dst)
        };
        if dst.exists() || std::fs::rename(&src, &dst).is_err() {
            a.toast("Couldn't rename the folder");
            return;
        }
        let new_rel = dst.strip_prefix(&a.st.borrow().root).unwrap_or(&dst).to_string_lossy().to_string();
        {
            let mut st = a.st.borrow_mut();
            let old = format!("{from}/");
            let fix = |r: &str| if let Some(rest) = r.strip_prefix(&old) { format!("{new_rel}/{rest}") } else { r.to_string() };
            st.pinned = st.pinned.iter().map(|p| fix(p)).collect();
            st.current = st.current.as_deref().map(fix);
            if st.place == from.as_str() {
                st.place = new_rel.clone();
            }
            st.scan();
        }
        a.refresh_list();
    });
    let a = app.clone();
    n.on_delete_folder(move |f| {
        a.flush();
        let path = a.st.borrow().abs(&f);
        match kit::trash(&path) {
            Ok(_) => {
                {
                    let mut st = a.st.borrow_mut();
                    if st.place == f.as_str() {
                        st.place.clear();
                    }
                    if st.current.as_deref().map(|c| c.starts_with(&format!("{f}/"))).unwrap_or(false) {
                        st.current = None;
                    }
                    st.scan();
                }
                if a.st.borrow().current.is_none() {
                    a.ui().global::<Notes>().set_body("".into());
                }
                a.refresh_list();
                a.toast("Folder moved to the Trash");
            }
            Err(e) => a.toast(&format!("Couldn't move it to the Trash: {e}")),
        }
    });
    let a = app.clone();
    n.on_toggle_task(move |line| {
        let ui = a.ui();
        let body = ui.global::<Notes>().get_body().to_string();
        let next = toggle_task(&body, line.max(0) as usize);
        ui.global::<Notes>().set_body(next.into());
        a.st.borrow_mut().dirty = true;
        a.flush();
        a.refresh_preview();
        a.refresh_list();
    });
    let a = app.clone();
    n.on_format(move |kind, text, anchor, cursor| {
        let (t, an, cu) = format(&kind, &text, anchor.max(0) as usize, cursor.max(0) as usize);
        let ui = a.ui();
        ui.invoke_apply_format(t.clone().into(), an as i32, cu as i32);
        ui.global::<Notes>().invoke_edited(t.into());
    });
    let a = app.clone();
    n.on_show_folder(move || {
        let root = a.st.borrow().root.clone();
        let _ = std::process::Command::new("xdg-open").arg(root).spawn();
    });

    // Changes made elsewhere: another editor, a sync, git.
    let a = app.clone();
    let watch = slint::Timer::default();
    watch.start(slint::TimerMode::Repeated, Duration::from_secs(3), move || {
        if a.st.borrow().changed_on_disk() {
            a.rescan();
        }
    });

    let a = app.clone();
    ui.window().on_close_requested(move || {
        a.flush();
        let ui = a.ui();
        a.st.borrow().save_state(ui.get_view());
        slint::CloseRequestResponse::HideWindow
    });
    ui.run().expect("run");
    app.flush();
    let ui2 = app.ui.upgrade();
    if let Some(ui) = ui2 {
        app.st.borrow().save_state(ui.get_view());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn titles() {
        assert_eq!(title_of("\n\n# Groceries\nmilk", "x.md"), "Groceries");
        assert_eq!(title_of("", "Ideas.md"), "Ideas");
    }
    #[test]
    fn bold_wraps_and_unwraps() {
        let (t, a, c) = format("bold", "a word here", 2, 6);
        assert_eq!(t, "a **word** here");
        assert_eq!((a, c), (4, 8));
        let (t2, ..) = format("bold", &t, a, c);
        assert_eq!(t2, "a word here");
    }
    #[test]
    fn heading_cycles() {
        let (t, ..) = format("h1", "title\nbody", 2, 2);
        assert_eq!(t, "# title\nbody");
        let (t, ..) = format("h1", &t, 2, 2);
        assert_eq!(t, "## title\nbody");
    }
    #[test]
    fn tasks_toggle() {
        let (t, ..) = format("task", "one\ntwo", 0, 7);
        assert_eq!(t, "- [ ] one\n- [ ] two");
        assert_eq!(toggle_task(&t, 1), "- [ ] one\n- [x] two");
    }
    #[test]
    fn preview_blocks() {
        let b = blocks("# Title\n\nSome **bold** text.\n\n- [ ] todo\n- [x] done\n  - nested\n\n> quoted\n\n```\ncode\n```\n");
        let kinds: Vec<String> = b.iter().map(|x| x.kind.to_string()).collect();
        assert_eq!(kinds, ["h1", "p", "task", "task", "bullet", "quote", "code"]);
        assert!(b[3].checked && !b[2].checked);
        assert_eq!(b[2].line, 4);
        assert_eq!(b[4].level, 1);
        assert_eq!(b[2].text, "todo");
    }
}
