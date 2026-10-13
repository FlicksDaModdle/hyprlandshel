//! Documents: PDFs (hayro, a PDF renderer in pure Rust), comic books (CBZ:
//! a zip of pictures) page by page, and e-books (EPUB) as flowing text.
//!
//! Pages are drawn on a thread of its own, only the ones on screen and
//! near it, at the screen's own scale, and let go again when they are far
//! away — a 500-page PDF costs a dozen pages of memory. Each document
//! opens where it was left.
//!
//!   hyprshell-docs [FILE]

slint::include_modules!();

use hyprshell_kit as kit;
use slint::{ComponentHandle, Image, Model, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::Duration;

const PX_PER_PT: f32 = 96.0 / 72.0;

// ── recents ─────────────────────────────────────────────────────────────

#[derive(Clone, Default, serde::Serialize, serde::Deserialize)]
struct Seen {
    path: String,
    #[serde(default)]
    page: i32,
    #[serde(default)]
    chapter: i32,
    #[serde(default)]
    fit: String,
    #[serde(default)]
    zoom: f32,
    #[serde(default)]
    opened: i64,
}

fn recent_file() -> PathBuf {
    kit::config_dir().join("hyprshell-docs/recent.json")
}
fn load_recents() -> Vec<Seen> {
    std::fs::read_to_string(recent_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}
fn save_recents(r: &[Seen]) {
    let p = recent_file();
    let _ = std::fs::create_dir_all(p.parent().unwrap());
    let _ = kit::write_atomic(&p, serde_json::to_string_pretty(r).unwrap_or_default().as_bytes());
}

fn kind_of(p: &Path) -> &'static str {
    match p.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref() {
        Some("pdf") => "PDF",
        Some("cbz") | Some("zip") => "Comic",
        Some("epub") => "E-book",
        _ => "",
    }
}

// ── the renderer ────────────────────────────────────────────────────────

enum Req {
    Render { page: usize, scale: f32, gen: i32 },
}

enum Reply {
    Opened { sizes: Vec<(f32, f32)> },
    Rendered { page: usize, gen: i32, w: u32, h: u32, rgba: Vec<u8> },
    Failed(String),
}

fn natural_key(s: &str) -> Vec<(String, u64)> {
    // "page2" before "page10".
    let mut out = Vec::new();
    let mut text = String::new();
    let mut num = String::new();
    for c in s.chars() {
        if c.is_ascii_digit() {
            num.push(c);
        } else {
            if !num.is_empty() {
                out.push((std::mem::take(&mut text), num.parse().unwrap_or(0)));
                num.clear();
            }
            text.push(c.to_ascii_lowercase());
        }
    }
    out.push((text, num.parse().unwrap_or(0)));
    out
}

fn is_picture(name: &str) -> bool {
    let n = name.to_lowercase();
    [".jpg", ".jpeg", ".png", ".webp", ".gif"].iter().any(|e| n.ends_with(e)) && !n.contains("__macosx")
}

/// The renderer's thread: owns the document, answers page requests with
/// pixels. The newest request for a page wins; ones for a stale zoom are
/// skipped.
fn renderer(path: PathBuf, rx: Receiver<Req>, reply: impl Fn(Reply) + Send + 'static) {
    std::thread::spawn(move || {
        match kind_of(&path) {
            "PDF" => {
                let data = match std::fs::read(&path) {
                    Ok(d) => d,
                    Err(e) => return reply(Reply::Failed(e.to_string())),
                };
                let pdf = match hayro::hayro_syntax::Pdf::new(data) {
                    Ok(p) => p,
                    Err(e) => return reply(Reply::Failed(format!("Not a PDF this can read ({e:?}) — it may be password-protected"))),
                };
                let pages = pdf.pages();
                let sizes: Vec<(f32, f32)> = pages.iter().map(|p| { let (w, h) = p.render_dimensions(); (w, h) }).collect();
                reply(Reply::Opened { sizes });
                let cache = hayro::RenderCache::new();
                let settings = hayro::hayro_interpret::InterpreterSettings::default();
                let rs = hayro::RenderSettings::default();
                let mut latest_gen = 0;
                while let Ok(first) = rx.recv() {
                    // Everything waiting, newest zoom first.
                    let mut batch = vec![first];
                    while let Ok(r) = rx.try_recv() {
                        batch.push(r);
                    }
                    for Req::Render { gen, .. } in &batch {
                        latest_gen = latest_gen.max(*gen);
                    }
                    let mut done = HashSet::new();
                    for Req::Render { page, scale, gen } in batch.into_iter().rev() {
                        if gen < latest_gen || !done.insert(page) {
                            continue;
                        }
                        let Some(p) = pages.get(page) else { continue };
                        let ps = hayro::PixmapSettings { x_scale: scale, y_scale: scale, bg_color: hayro::vello_cpu::color::palette::css::WHITE };
                        let pix = hayro::render(p, &cache, &settings, &rs, &ps);
                        let (w, h) = (pix.width() as u32, pix.height() as u32);
                        let mut rgba = Vec::with_capacity((w * h * 4) as usize);
                        for px in pix.data() {
                            rgba.extend_from_slice(&[px.r, px.g, px.b, 255]);
                        }
                        reply(Reply::Rendered { page, gen, w, h, rgba });
                    }
                }
            }
            "Comic" => {
                let f = match std::fs::File::open(&path) {
                    Ok(f) => f,
                    Err(e) => return reply(Reply::Failed(e.to_string())),
                };
                let mut zip = match zip::ZipArchive::new(f) {
                    Ok(z) => z,
                    Err(e) => return reply(Reply::Failed(format!("Not a comic book archive ({e})"))),
                };
                let mut names: Vec<String> = zip.file_names().filter(|n| is_picture(n)).map(|n| n.to_string()).collect();
                names.sort_by_key(|n| natural_key(n));
                if names.is_empty() {
                    return reply(Reply::Failed("No pictures inside".into()));
                }
                let decode = |zip: &mut zip::ZipArchive<std::fs::File>, name: &str| -> Option<image::RgbaImage> {
                    let mut e = zip.by_name(name).ok()?;
                    let mut buf = Vec::new();
                    e.read_to_end(&mut buf).ok()?;
                    image::load_from_memory(&buf).ok().map(|i| i.to_rgba8())
                };
                // Every page sized like the first until it is drawn.
                let first = decode(&mut zip, &names[0]);
                let (w0, h0) = first.as_ref().map(|i| (i.width() as f32, i.height() as f32)).unwrap_or((800.0, 1200.0));
                // Pixels shown at 72 per inch would be huge; a comic page
                // counts as ~8.5 inches wide.
                let k = 612.0 / w0;
                reply(Reply::Opened { sizes: vec![(w0 * k, h0 * k); names.len()] });
                while let Ok(first) = rx.recv() {
                    let mut batch = vec![first];
                    while let Ok(r) = rx.try_recv() {
                        batch.push(r);
                    }
                    let mut done = HashSet::new();
                    for Req::Render { page, gen, .. } in batch.into_iter().rev() {
                        if !done.insert(page) {
                            continue;
                        }
                        let Some(name) = names.get(page).cloned() else { continue };
                        if let Some(img) = decode(&mut zip, &name) {
                            let (w, h) = img.dimensions();
                            reply(Reply::Rendered { page, gen, w, h, rgba: img.into_raw() });
                        }
                    }
                }
            }
            _ => reply(Reply::Failed("Not a document this opens".into())),
        }
    });
}

// ── e-books ─────────────────────────────────────────────────────────────

struct Chapter {
    title: String,
    paras: Vec<(String, String)>,
}

fn read_epub(path: &Path) -> Result<Vec<Chapter>, String> {
    let f = std::fs::File::open(path).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipArchive::new(f).map_err(|e| e.to_string())?;
    let text = |zip: &mut zip::ZipArchive<std::fs::File>, name: &str| -> Option<String> {
        let mut e = zip.by_name(name).ok()?;
        let mut s = String::new();
        e.read_to_string(&mut s).ok()?;
        Some(s)
    };
    let container = text(&mut zip, "META-INF/container.xml").ok_or("Not an EPUB (no container.xml)")?;
    let opf_path = attr_of(&container, "rootfile", "full-path").ok_or("No package file named in the EPUB")?;
    let opf = text(&mut zip, &opf_path).ok_or("The EPUB's package file is missing")?;
    let base = opf_path.rsplit_once('/').map(|(b, _)| format!("{b}/")).unwrap_or_default();
    // manifest id → href, then the spine's order.
    let mut manifest = HashMap::new();
    let mut spine = Vec::new();
    let mut r = quick_xml::Reader::from_str(&opf);
    loop {
        match r.read_event() {
            Ok(quick_xml::events::Event::Empty(e)) | Ok(quick_xml::events::Event::Start(e)) => {
                let name = e.local_name();
                let get = |k: &[u8]| e.attributes().flatten().find(|a| a.key.local_name().as_ref() == k).map(|a| String::from_utf8_lossy(&a.value).to_string());
                match name.as_ref() {
                    b"item" => {
                        if let (Some(id), Some(href)) = (get(b"id"), get(b"href")) {
                            manifest.insert(id, href);
                        }
                    }
                    b"itemref" => {
                        if let Some(id) = get(b"idref") {
                            spine.push(id);
                        }
                    }
                    _ => {}
                }
            }
            Ok(quick_xml::events::Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    let mut out = Vec::new();
    for (n, id) in spine.iter().enumerate() {
        let Some(href) = manifest.get(id) else { continue };
        let href = href.split('#').next().unwrap_or(href);
        let full = format!("{base}{}", href.replace("%20", " "));
        let Some(xhtml) = text(&mut zip, &full) else { continue };
        let paras = paragraphs(&xhtml);
        if paras.is_empty() {
            continue;
        }
        let title = paras.iter().find(|(k, _)| k != "p").map(|(_, t)| t.clone()).unwrap_or_else(|| format!("Part {}", n + 1));
        out.push(Chapter { title, paras });
    }
    if out.is_empty() {
        return Err("No readable text inside".into());
    }
    Ok(out)
}

fn attr_of(xml: &str, tag: &str, attr: &str) -> Option<String> {
    let mut r = quick_xml::Reader::from_str(xml);
    loop {
        match r.read_event() {
            Ok(quick_xml::events::Event::Empty(e)) | Ok(quick_xml::events::Event::Start(e)) if e.local_name().as_ref() == tag.as_bytes() => {
                return e.attributes().flatten().find(|a| a.key.local_name().as_ref() == attr.as_bytes()).map(|a| String::from_utf8_lossy(&a.value).to_string());
            }
            Ok(quick_xml::events::Event::Eof) | Err(_) => return None,
            _ => {}
        }
    }
}

/// An XHTML chapter as headings and paragraphs of plain text.
fn paragraphs(xhtml: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut r = quick_xml::Reader::from_str(xhtml);
    r.config_mut().check_end_names = false;
    let mut cur = String::new();
    let mut kind = "p".to_string();
    let mut skip = 0;
    let flush = |cur: &mut String, kind: &str, out: &mut Vec<(String, String)>| {
        let t = cur.split_whitespace().collect::<Vec<_>>().join(" ");
        if !t.is_empty() {
            out.push((kind.to_string(), t));
        }
        cur.clear();
    };
    loop {
        match r.read_event() {
            Ok(quick_xml::events::Event::Start(e)) => match e.local_name().as_ref() {
                b"script" | b"style" | b"head" => skip += 1,
                b"h1" | b"h2" | b"h3" | b"h4" | b"h5" | b"h6" => {
                    flush(&mut cur, &kind, &mut out);
                    let n = e.local_name().as_ref()[1] - b'0';
                    kind = format!("h{}", n.min(3));
                }
                b"p" | b"div" | b"li" | b"blockquote" | b"tr" | b"section" => flush(&mut cur, &kind, &mut out),
                _ => {}
            },
            Ok(quick_xml::events::Event::End(e)) => match e.local_name().as_ref() {
                b"script" | b"style" | b"head" => skip -= 1,
                b"h1" | b"h2" | b"h3" | b"h4" | b"h5" | b"h6" => {
                    flush(&mut cur, &kind, &mut out);
                    kind = "p".into();
                }
                b"p" | b"div" | b"li" | b"blockquote" | b"tr" | b"section" => flush(&mut cur, &kind, &mut out),
                _ => {}
            },
            Ok(quick_xml::events::Event::Empty(e)) if e.local_name().as_ref() == b"br" => cur.push('\n'),
            Ok(quick_xml::events::Event::Text(t)) if skip == 0 => {
                // XHTML's named entities beyond XML's five.
                let s = t
                    .unescape_with(|e| match e {
                        "nbsp" => Some(" "), "mdash" => Some("—"), "ndash" => Some("–"), "hellip" => Some("…"),
                        "rsquo" => Some("’"), "lsquo" => Some("‘"), "ldquo" => Some("“"), "rdquo" => Some("”"),
                        "copy" => Some("©"), "eacute" => Some("é"), "shy" => Some(""),
                        _ => None,
                    })
                    .map(|c| c.to_string())
                    .unwrap_or_else(|_| String::from_utf8_lossy(&t).to_string());
                cur.push_str(&s);
            }
            Ok(quick_xml::events::Event::Eof) | Err(_) => break,
            _ => {}
        }
    }
    flush(&mut cur, &kind, &mut out);
    out
}

// ── the window ──────────────────────────────────────────────────────────

struct Doc {
    path: PathBuf,
    sizes: Vec<(f32, f32)>,
    tx: Option<Sender<Req>>,
    chapters: Vec<Chapter>,
}

struct App {
    ui: slint::Weak<AppWindow>,
    doc: RefCell<Option<Doc>>,
    gen: RefCell<i32>,
    zoom: RefCell<f32>,
    fit: RefCell<String>,
    held: RefCell<Vec<usize>>,
    recents: RefCell<Vec<Seen>>,
    toast_timer: slint::Timer,
    last_width: RefCell<f32>,
}

thread_local! {
    static APP: RefCell<Option<Rc<App>>> = const { RefCell::new(None) };
}

impl App {
    fn ui(&self) -> AppWindow {
        self.ui.upgrade().unwrap()
    }
    fn toast(&self, t: &str) {
        let ui = self.ui();
        ui.global::<Docs>().set_toast(t.into());
        let w = self.ui.clone();
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(2600), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Docs>().set_toast(SharedString::new());
            }
        });
    }

    fn show_recents(&self) {
        let ui = self.ui();
        let rows: Vec<Recent> = self
            .recents
            .borrow()
            .iter()
            .filter(|r| Path::new(&r.path).exists())
            .map(|r| {
                let p = Path::new(&r.path);
                let kind = kind_of(p);
                let place = p.parent().map(|d| d.to_string_lossy().replace(&kit::home().to_string_lossy().to_string(), "~")).unwrap_or_default();
                let where_ = if kind == "E-book" { format!("chapter {}", r.chapter + 1) } else { format!("page {}", r.page + 1) };
                Recent {
                    path: r.path.clone().into(),
                    name: p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default().into(),
                    sub: format!("{kind} · {where_} · {place} · {}", kit::when(r.opened)).into(),
                    kind: kind.into(),
                }
            })
            .collect();
        ui.global::<Docs>().set_recents(ModelRc::new(VecModel::from(rows)));
    }

    fn remember(&self) {
        let ui = self.ui();
        let g = ui.global::<Docs>();
        let Some(path) = self.doc.borrow().as_ref().map(|d| d.path.to_string_lossy().to_string()) else { return };
        let mut r = self.recents.borrow_mut();
        r.retain(|x| x.path != path);
        r.insert(0, Seen { path, page: g.get_current(), chapter: g.get_chapter(), fit: self.fit.borrow().clone(), zoom: *self.zoom.borrow(), opened: kit::now() });
        r.truncate(30);
        save_recents(&r);
    }

    fn open(self: &Rc<Self>, path: PathBuf) {
        self.remember();
        let ui = self.ui();
        let g = ui.global::<Docs>();
        let kind = kind_of(&path);
        g.set_name(path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default().into());
        g.set_kind(kind.into());
        let seen = self.recents.borrow().iter().find(|r| Path::new(&r.path) == path).cloned();
        if kind == "E-book" {
            g.set_mode("loading".into());
            let a = self.clone();
            let p = path.clone();
            kit::spawn(
                move || read_epub(&p),
                move |r| {
                    let ui = a.ui();
                    let g = ui.global::<Docs>();
                    match r {
                        Ok(chapters) => {
                            g.set_chapters(chapters.len() as i32);
                            *a.doc.borrow_mut() = Some(Doc { path: path.clone(), sizes: vec![], tx: None, chapters });
                            let ch = seen.map(|s| s.chapter).unwrap_or(0);
                            a.show_chapter(ch);
                            g.set_mode("text".into());
                            a.remember();
                            a.show_recents();
                        }
                        Err(e) => {
                            g.set_error(e.into());
                            g.set_mode("error".into());
                        }
                    }
                },
            );
            return;
        }
        if kind.is_empty() {
            g.set_error("Documents opens PDFs, comic books (.cbz) and e-books (.epub).".into());
            g.set_mode("error".into());
            return;
        }
        g.set_mode("loading".into());
        let (tx, rx) = channel();
        *self.doc.borrow_mut() = Some(Doc { path: path.clone(), sizes: vec![], tx: Some(tx), chapters: vec![] });
        self.held.borrow_mut().clear();
        if let Some(s) = &seen {
            *self.fit.borrow_mut() = if s.fit.is_empty() { "width".into() } else { s.fit.clone() };
            if s.zoom > 0.0 {
                *self.zoom.borrow_mut() = s.zoom;
            }
        } else {
            *self.fit.borrow_mut() = "width".into();
        }
        let start_page = seen.map(|s| s.page).unwrap_or(0);
        let w = self.ui.clone();
        renderer(path, rx, move |reply| {
            let w = w.clone();
            let _ = slint::invoke_from_event_loop(move || {
                let _ = w;
                APP.with(|a| {
                    if let Some(a) = a.borrow().clone() {
                        a.on_reply(reply, start_page);
                    }
                });
            });
        });
    }

    fn on_reply(self: &Rc<Self>, r: Reply, start_page: i32) {
        let ui = self.ui();
        let g = ui.global::<Docs>();
        match r {
            Reply::Failed(e) => {
                g.set_error(e.into());
                g.set_mode("error".into());
            }
            Reply::Opened { sizes } => {
                if let Some(d) = self.doc.borrow_mut().as_mut() {
                    d.sizes = sizes;
                }
                g.set_page_count(self.doc.borrow().as_ref().map(|d| d.sizes.len()).unwrap_or(0) as i32);
                g.set_mode("pages".into());
                self.relayout();
                let page = start_page.max(0);
                let w = self.ui.clone();
                slint::Timer::single_shot(Duration::from_millis(60), move || {
                    if let Some(ui) = w.upgrade() {
                        ui.invoke_go_to(page);
                    }
                });
                self.remember();
                self.show_recents();
            }
            Reply::Rendered { page, gen, w, h, rgba } => {
                if gen != *self.gen.borrow() {
                    return;
                }
                let pages = g.get_pages();
                let Some(mut row) = pages.row_data(page) else { return };
                let buf = SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(&rgba, w, h);
                row.image = Image::from_rgba8(buf);
                row.ready = true;
                pages.set_row_data(page, row);
                // Pages far from the one in view let their pixels go.
                let cur = g.get_current().max(0) as usize;
                let mut held = self.held.borrow_mut();
                held.retain(|p| *p != page);
                held.push(page);
                let far: Vec<usize> = held.iter().copied().filter(|p| p.abs_diff(cur) > 6).collect();
                for p in far {
                    if let Some(mut r) = pages.row_data(p) {
                        r.image = Image::default();
                        r.ready = false;
                        pages.set_row_data(p, r);
                    }
                }
                held.retain(|p| p.abs_diff(cur) <= 6);
            }
        }
    }

    /// Sizes at the zoom (or the fit), and a new generation of renders.
    fn relayout(&self) {
        let ui = self.ui();
        let g = ui.global::<Docs>();
        let doc = self.doc.borrow();
        let Some(d) = doc.as_ref() else { return };
        if d.sizes.is_empty() {
            return;
        }
        let vw = ui.get_view_width() as f32;
        let vh = ui.get_view_height() as f32;
        let maxw = d.sizes.iter().map(|s| s.0).fold(1.0, f32::max);
        let first_h = d.sizes[0].1.max(1.0);
        let fit = self.fit.borrow().clone();
        if vw > 50.0 {
            let width_fit = (vw - 48.0) / (maxw * PX_PER_PT);
            match fit.as_str() {
                "width" => *self.zoom.borrow_mut() = width_fit.min(4.0),
                "page" => *self.zoom.borrow_mut() = width_fit.min((vh - 24.0) / (first_h * PX_PER_PT)).min(4.0),
                _ => {}
            }
        }
        let zoom = *self.zoom.borrow();
        *self.gen.borrow_mut() += 1;
        let gen = *self.gen.borrow();
        *self.last_width.borrow_mut() = vw;
        let old = g.get_pages();
        let rows: Vec<PageView> = d
            .sizes
            .iter()
            .enumerate()
            .map(|(i, (w, h))| {
                // Keep the old pixels, stretched, until the new ones come.
                let prev = old.row_data(i);
                PageView {
                    index: i as i32,
                    width: (w * PX_PER_PT * zoom).round(),
                    height: (h * PX_PER_PT * zoom).round(),
                    image: prev.as_ref().map(|p| p.image.clone()).unwrap_or_default(),
                    ready: false,
                    gen,
                }
            })
            .collect();
        g.set_pages(ModelRc::new(VecModel::from(rows)));
        g.set_zoom(zoom);
        g.set_fit(fit.into());
    }

    fn need(&self, page: i32, gen: i32) {
        if gen != *self.gen.borrow() {
            return;
        }
        let ui = self.ui();
        let scale = *self.zoom.borrow() * PX_PER_PT * ui.window().scale_factor();
        if let Some(tx) = self.doc.borrow().as_ref().and_then(|d| d.tx.clone()) {
            let _ = tx.send(Req::Render { page: page.max(0) as usize, scale, gen });
        }
    }

    fn show_chapter(&self, i: i32) {
        let ui = self.ui();
        let g = ui.global::<Docs>();
        let doc = self.doc.borrow();
        let Some(d) = doc.as_ref() else { return };
        let i = i.clamp(0, d.chapters.len() as i32 - 1);
        let ch = &d.chapters[i as usize];
        g.set_chapter(i);
        g.set_chapter_title(ch.title.clone().into());
        g.set_text(ModelRc::new(VecModel::from(ch.paras.iter().map(|(k, t)| Para { kind: k.into(), text: t.into() }).collect::<Vec<_>>())));
    }
}

fn main() {
    kit::init("hyprshell-docs");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-docs");
    let app = Rc::new(App {
        ui: ui.as_weak(),
        doc: RefCell::new(None),
        gen: RefCell::new(0),
        zoom: RefCell::new(1.0),
        fit: RefCell::new("width".into()),
        held: RefCell::new(Vec::new()),
        recents: RefCell::new(load_recents()),
        toast_timer: slint::Timer::default(),
        last_width: RefCell::new(0.0),
    });
    APP.with(|a| *a.borrow_mut() = Some(app.clone()));
    app.show_recents();

    let g = ui.global::<Docs>();
    let a = app.clone();
    g.on_need(move |p, gen| a.need(p, gen));
    let a = app.clone();
    g.on_open_recent(move |p| {
        let p = PathBuf::from(p.as_str());
        if p.exists() {
            a.open(p);
        } else {
            a.toast("That file has moved or gone");
        }
    });
    let a = app.clone();
    g.on_forget_recent(move |p| {
        a.recents.borrow_mut().retain(|r| r.path != p.as_str());
        save_recents(&a.recents.borrow());
        a.show_recents();
    });
    let a = app.clone();
    g.on_open_dialog(move || {
        let b = a.clone();
        kit::spawn(
            || kit::portal::open_file("Open a document", &[("Documents", &["*.pdf", "*.PDF", "*.cbz", "*.epub"]), ("All files", &["*"])]),
            move |p| {
                if let Some(p) = p {
                    b.open(p);
                }
            },
        );
    });
    let a = app.clone();
    g.on_zoom_by(move |f| {
        let z = (*a.zoom.borrow() * f).clamp(0.2, 6.0);
        *a.zoom.borrow_mut() = z;
        *a.fit.borrow_mut() = "none".into();
        let cur = a.ui().global::<Docs>().get_current();
        a.relayout();
        let w = a.ui.clone();
        slint::Timer::single_shot(Duration::from_millis(30), move || {
            if let Some(ui) = w.upgrade() {
                ui.invoke_go_to(cur);
            }
        });
    });
    let a = app.clone();
    g.on_set_fit(move |f| {
        *a.fit.borrow_mut() = f.to_string();
        let cur = a.ui().global::<Docs>().get_current();
        a.relayout();
        let w = a.ui.clone();
        slint::Timer::single_shot(Duration::from_millis(30), move || {
            if let Some(ui) = w.upgrade() {
                ui.invoke_go_to(cur);
            }
        });
    });
    let a = app.clone();
    g.on_scrolled(move |_| a.remember());
    let a = app.clone();
    g.on_go_chapter(move |i| {
        a.show_chapter(i);
        a.remember();
    });

    // A window resized while fitted re-fits.
    let a = app.clone();
    let watch = slint::Timer::default();
    watch.start(slint::TimerMode::Repeated, Duration::from_millis(300), move || {
        let ui = a.ui();
        if ui.global::<Docs>().get_mode() != "pages" || *a.fit.borrow() == "none" {
            return;
        }
        let w = ui.get_view_width() as f32;
        if (w - *a.last_width.borrow()).abs() > 2.0 {
            let cur = ui.global::<Docs>().get_current();
            a.relayout();
            ui.invoke_go_to(cur);
        }
    });

    if let Some(arg) = std::env::args().nth(1) {
        let p = kit::portal::uri_to_path(&arg).unwrap_or_else(|| PathBuf::from(&arg));
        let a = app.clone();
        slint::Timer::single_shot(Duration::from_millis(50), move || a.open(p));
    }

    let a = app.clone();
    ui.window().on_close_requested(move || {
        a.remember();
        slint::CloseRequestResponse::HideWindow
    });
    ui.run().expect("run");
    app.remember();
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn natural_order() {
        let mut v = vec!["p10.jpg", "p2.jpg", "p1.jpg"];
        v.sort_by_key(|n| natural_key(n));
        assert_eq!(v, ["p1.jpg", "p2.jpg", "p10.jpg"]);
    }
    #[test]
    fn xhtml() {
        let p = paragraphs("<html><head><title>x</title></head><body><h1>One</h1><p>Hello <b>there</b>&nbsp;you.</p><p>Two</p></body></html>");
        assert_eq!(p, vec![("h1".into(), "One".into()), ("p".into(), "Hello there you.".into()), ("p".into(), "Two".into())]);
    }
}
