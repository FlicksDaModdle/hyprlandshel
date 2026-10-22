//! Fonts: every font family fontconfig knows, each shown in itself, a
//! family's styles, sizes and characters, and fonts added to or taken out
//! of your own fonts folder (~/.local/share/fonts).
//!
//! The samples are drawn here, with ab_glyph, from the font files
//! themselves, not by asking the toolkit for a family by name: that way a
//! font file opened from the Files app shows before it's installed, and
//! each style shows as itself rather than as whatever the nearest match is.

slint::include_modules!();

use ab_glyph::{Font, FontVec, GlyphId, PxScale, ScaleFont, VariableFont};
use hyprshell_kit as kit;
use slint::{ComponentHandle, Image, Model, ModelRc, SharedPixelBuffer, VecModel};
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

// ── fonts on the computer ────────────────────────────────────────────────

/// One face of a family, as fontconfig lists it.
#[derive(Clone, Debug)]
struct Face {
    family: String,
    style: String,
    file: PathBuf,
    /// The face in the file; a variable font's named instances carry their
    /// number in the high 16 bits.
    index: u32,
    /// fontconfig's scale: 80 regular, 200 bold.
    weight: f32,
    /// 0 upright, 100 italic, 110 oblique.
    slant: i32,
    mono: bool,
}

#[derive(Clone, Debug)]
struct Family {
    name: String,
    faces: Vec<Face>,
    mono: bool,
    yours: bool,
}

impl Family {
    /// The face to show the family by: the one closest to plain regular.
    fn regular(&self) -> &Face {
        self.faces
            .iter()
            .min_by(|a, b| {
                let k = |f: &Face| (f.weight - 80.0).abs() + if f.slant != 0 { 1000.0 } else { 0.0 };
                k(a).total_cmp(&k(b))
            })
            .expect("a family has a face")
    }
}

const FORMAT: &str = "%{family[0]}\t%{style[0]}\t%{file}\t%{index}\t%{weight}\t%{slant}\t%{spacing}\n";

fn parse_list(text: &str) -> Vec<Face> {
    text.lines()
        .filter_map(|l| {
            let mut p = l.split('\t');
            let family = p.next()?.trim().to_string();
            let style = p.next()?.trim().to_string();
            let file = PathBuf::from(p.next()?);
            let index = p.next()?.trim().parse().unwrap_or(0);
            // A variable font's own entry gives its range, "[0 210]".
            let weight = p.next().unwrap_or("").trim().parse().unwrap_or(80.0);
            let slant = p.next().unwrap_or("").trim().parse().unwrap_or(0);
            let mono = p.next().unwrap_or("").trim() == "100";
            if family.is_empty() {
                return None;
            }
            Some(Face { family, style: if style.is_empty() { "Regular".into() } else { style }, file, index, weight, slant, mono })
        })
        .collect()
}

fn your_dirs() -> [PathBuf; 2] {
    [kit::data_dir().join("fonts"), kit::home().join(".fonts")]
}

fn is_yours(p: &Path) -> bool {
    your_dirs().iter().any(|d| p.starts_with(d))
}

fn group(faces: Vec<Face>) -> Vec<Family> {
    let mut by: HashMap<String, Family> = HashMap::new();
    for f in faces {
        let fam = by.entry(f.family.to_lowercase()).or_insert_with(|| Family { name: f.family.clone(), faces: Vec::new(), mono: false, yours: false });
        // A style once: a variable font lists itself and its instances.
        if let Some(i) = fam.faces.iter().position(|g| g.style.eq_ignore_ascii_case(&f.style)) {
            if f.index >> 16 != 0 && fam.faces[i].index >> 16 == 0 {
                fam.faces[i] = f;
            }
            continue;
        }
        fam.faces.push(f);
    }
    let mut out: Vec<Family> = by
        .into_values()
        .map(|mut fam| {
            fam.faces.sort_by(|a, b| a.slant.cmp(&b.slant).then(a.weight.total_cmp(&b.weight)).then(a.style.cmp(&b.style)));
            fam.mono = fam.faces.iter().any(|f| f.mono);
            fam.yours = fam.faces.iter().all(|f| is_yours(&f.file));
            fam
        })
        .collect();
    out.sort_by_key(|f| f.name.to_lowercase());
    out
}

fn list_fonts() -> Vec<Family> {
    let out = std::process::Command::new("fc-list").arg("--format").arg(FORMAT).output();
    match out {
        Ok(o) => group(parse_list(&String::from_utf8_lossy(&o.stdout))),
        Err(_) => Vec::new(),
    }
}

/// The faces in font files that aren't (necessarily) installed.
fn scan(files: &[PathBuf]) -> Vec<Face> {
    let mut out = Vec::new();
    for f in files {
        if let Ok(o) = std::process::Command::new("fc-scan").arg("--format").arg(FORMAT).arg(f).output() {
            out.extend(parse_list(&String::from_utf8_lossy(&o.stdout)));
        }
    }
    out
}

// ── drawing ──────────────────────────────────────────────────────────────

/// fontconfig's weight to OpenType's, for a variable font's `wght` axis.
fn ot_weight(fc: f32) -> f32 {
    const MAP: [(f32, f32); 11] = [
        (0.0, 100.0), (40.0, 200.0), (50.0, 300.0), (55.0, 350.0), (75.0, 380.0), (80.0, 400.0),
        (100.0, 500.0), (180.0, 600.0), (200.0, 700.0), (205.0, 800.0), (210.0, 900.0),
    ];
    if fc <= 0.0 {
        return 100.0;
    }
    for w in MAP.windows(2) {
        let ((a, x), (b, y)) = (w[0], w[1]);
        if fc <= b {
            return x + (y - x) * (fc - a) / (b - a);
        }
    }
    1000.0
}

fn load(face: &Face) -> Option<FontVec> {
    let data = std::fs::read(&face.file).ok()?;
    let mut font = FontVec::try_from_vec_and_index(data, face.index & 0xffff).ok()?;
    if face.index >> 16 != 0 {
        font.set_variation(b"wght", ot_weight(face.weight));
    }
    Some(font)
}

/// Whether the font has most of `text`'s letters.
fn covers(font: &FontVec, text: &str) -> bool {
    let chars: Vec<char> = text.chars().filter(|c| !c.is_whitespace()).collect();
    let missing = chars.iter().filter(|&&c| font.glyph_id(c) == GlyphId(0)).count();
    missing * 2 <= chars.len()
}

/// What the font has, when it hasn't the sample's letters (symbols,
/// another script): its own characters, from the start of its table.
fn own_chars(font: &FontVec, skip: usize, n: usize) -> String {
    let mut cs: Vec<char> = font.codepoint_ids().map(|(_, c)| c).filter(|c| !c.is_control() && !c.is_whitespace()).collect();
    cs.sort_unstable();
    cs.dedup();
    cs.into_iter().skip(skip).take(n).map(String::from).collect::<Vec<_>>().join(" ")
}

/// One line of `text`, `px` device pixels tall, white on clear (the window
/// tints it with its ink), no wider than `max_w`.
fn draw_line(font: &FontVec, text: &str, px: f32, max_w: f32) -> Option<SharedPixelBuffer<slint::Rgba8Pixel>> {
    let scaled = font.as_scaled(PxScale::from(px));
    let ascent = scaled.ascent();
    let height = (ascent - scaled.descent()).ceil().max(1.0);
    let mut glyphs = Vec::new();
    let mut caret = 0.0f32;
    let mut prev: Option<GlyphId> = None;
    for c in text.chars() {
        let id = font.glyph_id(c);
        if let Some(p) = prev {
            caret += scaled.kern(p, id);
        }
        let advance = scaled.h_advance(id);
        if caret + advance > max_w {
            break;
        }
        glyphs.push(id.with_scale_and_position(px, ab_glyph::point(caret, ascent)));
        caret += advance;
        prev = Some(id);
    }
    let width = caret.ceil().max(1.0) as u32;
    let h = height as u32;
    let mut buf = SharedPixelBuffer::<slint::Rgba8Pixel>::new(width, h);
    let pixels = buf.make_mut_slice();
    for p in pixels.iter_mut() {
        *p = slint::Rgba8Pixel { r: 255, g: 255, b: 255, a: 0 };
    }
    let mut any = false;
    for g in glyphs {
        if let Some(o) = font.outline_glyph(g) {
            any = true;
            let b = o.px_bounds();
            o.draw(|x, y, c| {
                let (x, y) = (b.min.x as i32 + x as i32, b.min.y as i32 + y as i32);
                if x >= 0 && y >= 0 && (x as u32) < width && (y as u32) < h {
                    let p = &mut pixels[(y as u32 * width + x as u32) as usize];
                    p.a = p.a.saturating_add((c.clamp(0.0, 1.0) * 255.0) as u8);
                }
            });
        }
    }
    any.then_some(buf)
}

/// The family's sample: the text in it, or its own characters if it hasn't
/// the text's.
fn draw_sample(face: &Face, text: &str, px: f32, max_w: f32) -> Option<SharedPixelBuffer<slint::Rgba8Pixel>> {
    let font = load(face)?;
    let text = if text.trim().is_empty() { "The quick brown fox jumps over the lazy dog" } else { text };
    if covers(&font, text) {
        draw_line(&font, text, px, max_w)
    } else {
        draw_line(&font, &own_chars(&font, 0, 40), px, max_w)
    }
}

type Pixels = SharedPixelBuffer<slint::Rgba8Pixel>;

/// Everything shown for one family.
struct Sheet {
    styles: Vec<(String, Option<Pixels>)>,
    sizes: Vec<(String, Option<Pixels>)>,
    glyphs: Vec<(String, Option<Pixels>)>,
}

fn draw_sheet(fam: &Family, text: &str, px: f32, scale: f32) -> Sheet {
    let max_w = 2400.0 * scale;
    let styles = fam.faces.iter().map(|f| (f.style.clone(), draw_sample(f, text, px * scale, max_w))).collect();
    let regular = fam.regular();
    let sizes = [12.0f32, 16.0, 20.0, 28.0, 36.0, 48.0, 72.0]
        .iter()
        .map(|&s| (format!("{s} px"), draw_sample(regular, text, s * scale, max_w)))
        .collect();
    let mut glyphs = Vec::new();
    if let Some(font) = load(regular) {
        let latin = ["ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", "0123456789", "!?&@#%$€£¥ ()[]{} .,:;'\"‘’“” -–— +=*/\\|<>~^_"];
        if covers(&font, latin[0]) {
            for l in latin {
                glyphs.push((String::new(), draw_line(&font, l, 36.0 * scale, max_w)));
            }
        } else {
            for row in 0..6 {
                let s = own_chars(&font, row * 24, 24);
                if s.is_empty() {
                    break;
                }
                glyphs.push((String::new(), draw_line(&font, &s, 36.0 * scale, max_w)));
            }
        }
    }
    Sheet { styles, sizes, glyphs }
}

// ── the app ──────────────────────────────────────────────────────────────

struct App {
    ui: slint::Weak<AppWindow>,
    families: Vec<Family>,
    /// Which families the list shows, in order.
    shown: Vec<usize>,
    rows: Rc<VecModel<FamilyRow>>,
    /// Samples drawn for the current text and size, by family.
    samples: HashMap<String, Image>,
    /// Bumped when what's drawn changes, so stale drawing is dropped.
    gen: u64,
    /// The family open, and whether it came from files not installed.
    open: Option<Family>,
    from_files: Vec<PathBuf>,
    toast_seq: u64,
}

type Shared = Rc<RefCell<App>>;

impl App {
    fn ui(&self) -> Option<AppWindow> {
        self.ui.upgrade()
    }

    fn settings(&self) -> (String, f32, f32) {
        let Some(ui) = self.ui() else { return (String::new(), 28.0, 1.0) };
        let f = ui.global::<Fonts>();
        (f.get_sample_text().to_string(), f.get_size().round(), ui.window().scale_factor())
    }

    fn row(&self, i: usize) -> FamilyRow {
        let fam = &self.families[i];
        let n = fam.faces.len();
        let mut note = if n == 1 { "1 style".to_string() } else { format!("{n} styles") };
        if fam.mono {
            note.push_str(" · monospace");
        }
        let sample = self.samples.get(&fam.name).cloned();
        FamilyRow { name: fam.name.clone().into(), note: note.into(), pending: sample.is_none(), sample: sample.unwrap_or_default(), yours: fam.yours }
    }

    /// The list, for the filter and search.
    fn show_list(&mut self) {
        let Some(ui) = self.ui() else { return };
        let f = ui.global::<Fonts>();
        let filter = f.get_filter();
        let q = f.get_query().to_lowercase();
        self.shown = (0..self.families.len())
            .filter(|&i| {
                let fam = &self.families[i];
                (filter != 1 || fam.mono) && (filter != 2 || fam.yours) && (q.is_empty() || fam.name.to_lowercase().contains(q.trim()))
            })
            .collect();
        let rows: Vec<FamilyRow> = self.shown.iter().map(|&i| self.row(i)).collect();
        self.rows.set_vec(rows);
        f.set_total(self.families.len() as i32);
        f.set_mono_count(self.families.iter().filter(|f| f.mono).count() as i32);
        f.set_yours_count(self.families.iter().filter(|f| f.yours).count() as i32);
    }

    fn toast(app: &Shared, text: &str) {
        let seq = {
            let mut a = app.borrow_mut();
            a.toast_seq += 1;
            a.toast_seq
        };
        if let Some(ui) = app.borrow().ui() {
            ui.global::<Fonts>().set_toast(text.into());
        }
        let app = app.clone();
        slint::Timer::single_shot(Duration::from_millis(2600), move || {
            if app.borrow().toast_seq == seq {
                if let Some(ui) = app.borrow().ui() {
                    ui.global::<Fonts>().set_toast("".into());
                }
            }
        });
    }
}

/// Draw the samples the list is missing, a few families at a time, so the
/// first ones show at once.
fn draw_samples(app: &Shared) {
    let (gen, jobs, text, px, scale) = {
        let a = app.borrow();
        let (text, px, scale) = a.settings();
        let jobs: Vec<(String, Face)> = a
            .shown
            .iter()
            .map(|&i| &a.families[i])
            .filter(|f| !a.samples.contains_key(&f.name))
            .take(24)
            .map(|f| (f.name.clone(), f.regular().clone()))
            .collect();
        (a.gen, jobs, text, px, scale)
    };
    if jobs.is_empty() {
        return;
    }
    let app = app.clone();
    kit::spawn(
        move || jobs.into_iter().map(|(name, face)| (name, draw_sample(&face, &text, px * scale, 1600.0 * scale))).collect::<Vec<_>>(),
        move |done| {
            {
                let mut a = app.borrow_mut();
                if a.gen != gen {
                    return;
                }
                for (name, px) in done {
                    // Nothing drawable (a bitmap or colour font): an empty
                    // picture, so it isn't drawn again and again.
                    let img = px.map(Image::from_rgba8).unwrap_or_default();
                    a.samples.insert(name, img);
                }
                for (r, &i) in a.shown.clone().iter().enumerate() {
                    if a.rows.row_data(r).is_some_and(|row| row.pending) && a.samples.contains_key(&a.families[i].name) {
                        let row = a.row(i);
                        a.rows.set_row_data(r, row);
                    }
                }
            }
            draw_samples(&app);
        },
    );
}

/// Start over on the samples: the text or size changed.
fn redraw(app: &Shared) {
    {
        let mut a = app.borrow_mut();
        a.gen += 1;
        a.samples.clear();
        a.show_list();
    }
    draw_samples(app);
    draw_open(app);
}

fn reload(app: &Shared, then: impl FnOnce(&Shared) + 'static) {
    if let Some(ui) = app.borrow().ui() {
        ui.global::<Fonts>().set_loading(app.borrow().families.is_empty());
    }
    let app = app.clone();
    kit::spawn(list_fonts, move |families| {
        {
            let mut a = app.borrow_mut();
            a.families = families;
            a.gen += 1;
            a.samples.clear();
            a.show_list();
            if let Some(ui) = a.ui() {
                ui.global::<Fonts>().set_loading(false);
            }
        }
        draw_samples(&app);
        then(&app);
    });
}

fn samples_model(list: Vec<(String, Option<Pixels>)>) -> ModelRc<Sample> {
    ModelRc::new(VecModel::from(
        list.into_iter().map(|(label, px)| match px {
            Some(px) => Sample { label: label.into(), image: Image::from_rgba8(px) },
            None => Sample { label: format!("{label} — no preview for this kind of font").trim_start_matches(" — ").into(), image: Image::default() },
        }).collect::<Vec<_>>(),
    ))
}

/// Draw the open family's sheet.
fn draw_open(app: &Shared) {
    let (fam, gen, text, px, scale) = {
        let a = app.borrow();
        let Some(fam) = a.open.clone() else { return };
        let (text, px, scale) = a.settings();
        (fam, a.gen, text, px, scale)
    };
    if let Some(ui) = app.borrow().ui() {
        ui.global::<Fonts>().set_drawing(true);
    }
    let app = app.clone();
    kit::spawn(
        move || draw_sheet(&fam, &text, px, scale),
        move |sheet| {
            let a = app.borrow();
            let Some(ui) = a.ui() else { return };
            if a.gen != gen {
                return;
            }
            let f = ui.global::<Fonts>();
            f.set_styles(samples_model(sheet.styles));
            f.set_sizes(samples_model(sheet.sizes));
            f.set_glyphs(samples_model(sheet.glyphs));
            f.set_drawing(false);
        },
    );
}

fn open_family(app: &Shared, fam: Family, from_files: Vec<PathBuf>) {
    {
        let mut a = app.borrow_mut();
        let Some(ui) = a.ui() else { return };
        let f = ui.global::<Fonts>();
        let files: std::collections::BTreeSet<&PathBuf> = fam.faces.iter().map(|f| &f.file).collect();
        let where_ = if files.len() == 1 {
            files.iter().next().map(|p| p.display().to_string()).unwrap_or_default()
        } else {
            format!("{} files", files.len())
        };
        let n = fam.faces.len();
        f.set_name(fam.name.clone().into());
        f.set_info(format!("{} · {}", if n == 1 { "1 style".to_string() } else { format!("{n} styles") }, where_).into());
        f.set_can_install(!from_files.is_empty());
        f.set_can_remove(from_files.is_empty() && fam.yours);
        f.set_styles(ModelRc::default());
        f.set_sizes(ModelRc::default());
        f.set_glyphs(ModelRc::default());
        f.set_open(true);
        a.open = Some(fam);
        a.from_files = from_files;
    }
    draw_open(app);
}

/// Copy font files into your fonts folder and tell fontconfig.
fn install(files: &[PathBuf]) -> Result<usize, String> {
    let dir = kit::data_dir().join("fonts");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut n = 0;
    for f in files {
        let Some(name) = f.file_name() else { continue };
        if f.starts_with(&dir) {
            continue;
        }
        let data = std::fs::read(f).map_err(|e| format!("{}: {e}", name.to_string_lossy()))?;
        let mut to = dir.join(name);
        let mut k = 1;
        let mut same = false;
        while to.exists() {
            // The very same file in there already: nothing to do.
            if std::fs::read(&to).is_ok_and(|d| d == data) {
                same = true;
                break;
            }
            k += 1;
            let stem = Path::new(name).file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
            let ext = Path::new(name).extension().map(|s| format!(".{}", s.to_string_lossy())).unwrap_or_default();
            to = dir.join(format!("{stem} {k}{ext}"));
        }
        if same {
            continue;
        }
        kit::write_atomic(&to, &data).map_err(|e| format!("{}: {e}", name.to_string_lossy()))?;
        n += 1;
    }
    let _ = std::process::Command::new("fc-cache").arg("-f").arg(&dir).status();
    Ok(n)
}

const FONT_FILES: &[&str] = &["*.ttf", "*.otf", "*.ttc", "*.otc", "*.TTF", "*.OTF", "*.TTC", "*.OTC", "*.pfb", "*.pfa"];

fn main() {
    kit::init("hyprshell-fonts");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-fonts");

    let rows = Rc::new(VecModel::<FamilyRow>::default());
    ui.global::<Fonts>().set_families(ModelRc::from(rows.clone()));
    let app: Shared = Rc::new(RefCell::new(App {
        ui: ui.as_weak(),
        families: Vec::new(),
        shown: Vec::new(),
        rows,
        samples: HashMap::new(),
        gen: 0,
        open: None,
        from_files: Vec::new(),
        toast_seq: 0,
    }));

    let f = ui.global::<Fonts>();
    f.set_scale(ui.window().scale_factor());

    {
        let app = app.clone();
        f.on_search(move |_| {
            app.borrow_mut().show_list();
            draw_samples(&app);
        });
    }
    {
        let app = app.clone();
        f.on_set_filter(move |i| {
            if let Some(ui) = app.borrow().ui() {
                ui.global::<Fonts>().set_filter(i);
                ui.global::<Fonts>().set_open(false);
            }
            app.borrow_mut().show_list();
            draw_samples(&app);
        });
    }
    // The text and size: drawn again a moment after they stop changing.
    let later = Rc::new(slint::Timer::default());
    {
        let (app, later) = (app.clone(), later.clone());
        f.on_set_sample(move |_| {
            let app = app.clone();
            later.start(slint::TimerMode::SingleShot, Duration::from_millis(250), move || redraw(&app));
        });
    }
    {
        let (app, later) = (app.clone(), later.clone());
        f.on_set_size(move |_| {
            let app = app.clone();
            later.start(slint::TimerMode::SingleShot, Duration::from_millis(200), move || redraw(&app));
        });
    }
    {
        let app = app.clone();
        f.on_pick(move |r| {
            let fam = {
                let a = app.borrow();
                a.shown.get(r as usize).map(|&i| a.families[i].clone())
            };
            if let Some(fam) = fam {
                open_family(&app, fam, Vec::new());
            }
        });
    }
    {
        let app = app.clone();
        f.on_back(move || {
            let mut a = app.borrow_mut();
            a.open = None;
            a.from_files.clear();
            if let Some(ui) = a.ui() {
                ui.global::<Fonts>().set_open(false);
            }
        });
    }
    {
        let app = app.clone();
        f.on_add_files(move || {
            let app = app.clone();
            kit::spawn(
                || {
                    let files = kit::portal::open_files("Add fonts", &[("Fonts", FONT_FILES), ("All files", &["*"])]);
                    if files.is_empty() {
                        return None;
                    }
                    Some(install(&files))
                },
                move |r| match r {
                    None => {}
                    Some(Ok(0)) => App::toast(&app, "Already installed"),
                    Some(Ok(n)) => {
                        reload(&app, |_| {});
                        App::toast(&app, &if n == 1 { "Font added".to_string() } else { format!("{n} fonts added") });
                    }
                    Some(Err(e)) => App::toast(&app, &format!("Couldn't add it: {e}")),
                },
            );
        });
    }
    {
        let app = app.clone();
        f.on_install_shown(move || {
            let files = app.borrow().from_files.clone();
            let name = app.borrow().open.as_ref().map(|f| f.name.clone()).unwrap_or_default();
            let app = app.clone();
            kit::spawn(
                move || install(&files),
                move |r| match r {
                    Ok(_) => {
                        App::toast(&app, &format!("{name} installed"));
                        reload(&app, move |app| {
                            let fam = app.borrow().families.iter().find(|f| f.name.eq_ignore_ascii_case(&name)).cloned();
                            if let Some(fam) = fam {
                                open_family(app, fam, Vec::new());
                            }
                        });
                    }
                    Err(e) => App::toast(&app, &format!("Couldn't install it: {e}")),
                },
            );
        });
    }
    {
        let app = app.clone();
        f.on_remove_shown(move || {
            let Some(fam) = app.borrow().open.clone() else { return };
            let mut files: Vec<PathBuf> = fam.faces.iter().map(|f| f.file.clone()).filter(|p| is_yours(p)).collect();
            files.sort();
            files.dedup();
            let app = app.clone();
            kit::spawn(
                move || {
                    let mut failed = None;
                    for f in &files {
                        if let Err(e) = kit::trash(f) {
                            failed = Some(e.to_string());
                        }
                    }
                    for d in your_dirs() {
                        if d.is_dir() {
                            let _ = std::process::Command::new("fc-cache").arg("-f").arg(&d).status();
                        }
                    }
                    failed
                },
                move |failed| {
                    match failed {
                        Some(e) => App::toast(&app, &format!("Couldn't remove all of it: {e}")),
                        None => App::toast(&app, &format!("{} moved to the Trash", fam.name)),
                    }
                    {
                        let mut a = app.borrow_mut();
                        a.open = None;
                        if let Some(ui) = a.ui() {
                            ui.global::<Fonts>().set_open(false);
                        }
                    }
                    reload(&app, |_| {});
                },
            );
        });
    }

    // Font files to look at, from the Files app: shown, ready to install.
    let files: Vec<PathBuf> = std::env::args()
        .skip(1)
        .filter(|a| !a.starts_with("--"))
        .map(|a| kit::portal::uri_to_path(&a).unwrap_or_else(|| PathBuf::from(&a)))
        .filter(|p| p.is_file())
        .collect();

    ui.show().expect("show");
    f.set_scale(ui.window().scale_factor());
    {
        let app = app.clone();
        reload(&app, move |app| {
            if files.is_empty() {
                return;
            }
            let faces = scan(&files);
            let Some(fam) = group(faces).into_iter().next() else {
                App::toast(app, "That isn't a font this can read");
                return;
            };
            // Installed already: shown as itself, not offered again.
            let have = fam.faces.iter().all(|f| is_yours(&f.file))
                || app.borrow().families.iter().any(|g| g.faces.iter().any(|h| fam.faces.iter().any(|f| f.file == h.file)));
            if have {
                open_family(app, fam, Vec::new());
            } else {
                open_family(app, fam, files.clone());
            }
        });
    }
    // The scale can change when the window moves to another screen.
    let scale_timer = slint::Timer::default();
    {
        let app = app.clone();
        scale_timer.start(slint::TimerMode::Repeated, Duration::from_secs(2), move || {
            let changed = {
                let a = app.borrow();
                let Some(ui) = a.ui() else { return };
                let s = ui.window().scale_factor();
                let f = ui.global::<Fonts>();
                let changed = (f.get_scale() - s).abs() > 0.01;
                f.set_scale(s);
                changed
            };
            if changed {
                redraw(&app);
            }
        });
    }
    slint::run_event_loop().expect("run");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_list() {
        let text = "DejaVu Sans\tBold\t/usr/share/fonts/DejaVuSans-Bold.ttf\t0\t200\t0\t\n\
                    DejaVu Sans\tBook\t/usr/share/fonts/DejaVuSans.ttf\t0\t80\t0\t\n\
                    DejaVu Sans Mono\tBook\t/usr/share/fonts/DejaVuSansMono.ttf\t0\t80\t0\t100\n\
                    Inter\tRegular\t/f/Inter.ttf\t0\t[0 210]\t0\t\n\
                    Inter\tRegular\t/f/Inter.ttf\t262144\t80\t0\t\n\
                    Inter\tBold\t/f/Inter.ttf\t458752\t200\t0\t\n";
        let fams = group(parse_list(text));
        assert_eq!(fams.len(), 3);
        assert_eq!(fams[0].name, "DejaVu Sans");
        assert_eq!(fams[0].regular().style, "Book");
        assert!(fams[1].mono && !fams[0].mono);
        let inter = &fams[2];
        assert_eq!(inter.faces.len(), 2);
        assert_eq!(inter.regular().index >> 16, 4);
    }

    #[test]
    fn installs_once() {
        let base = std::env::temp_dir().join(format!("hyprshell-fonts-test-{}", std::process::id()));
        let src = base.join("in");
        std::fs::create_dir_all(&src).unwrap();
        std::env::set_var("XDG_DATA_HOME", base.join("data"));
        let a = src.join("A.ttf");
        std::fs::write(&a, b"one").unwrap();
        assert_eq!(install(&[a.clone()]), Ok(1));
        // The same again: left alone.
        assert_eq!(install(&[a.clone()]), Ok(0));
        // Another file by the same name: kept beside it.
        std::fs::write(&a, b"two").unwrap();
        assert_eq!(install(&[a]), Ok(1));
        let fonts = base.join("data/fonts");
        assert_eq!(std::fs::read(fonts.join("A.ttf")).unwrap(), b"one");
        assert_eq!(std::fs::read(fonts.join("A 2.ttf")).unwrap(), b"two");
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn weights() {
        assert_eq!(ot_weight(80.0), 400.0);
        assert_eq!(ot_weight(200.0), 700.0);
        assert!((ot_weight(140.0) - 550.0).abs() < 0.1);
    }
}
