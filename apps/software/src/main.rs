//! Software: what's installed, what can be, and what's out of date — the
//! Arch repositories (pacman), the AUR (through paru or yay, when one is
//! installed) and Flathub (flatpak, when it is).
//!
//! Changes go through the tools themselves, one at a time, their output
//! shown as it comes: pacman through pkexec, so it's the system's own
//! password prompt that allows it; flatpak by itself (it asks polkit when
//! it needs to). AUR packages are built from scripts anyone publishes, so
//! they're installed in a terminal, where the helper shows the PKGBUILD
//! before running anything. Repository updates are always the whole
//! system at once (pacman -Syu): Arch doesn't do partial upgrades.

slint::include_modules!();

use hyprshell_kit as kit;
use slint::{ComponentHandle, ModelRc, VecModel};
use std::cell::RefCell;
use std::collections::HashSet;
use std::io::BufRead;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::time::Duration;

// ── packages ─────────────────────────────────────────────────────────────

#[derive(Clone, Debug, PartialEq)]
enum Src {
    /// A repository: core, extra, multilib, cachyos…
    Repo(String),
    Aur,
    /// A flatpak, and the remote it comes from (empty when not known).
    Flatpak(String),
}

#[derive(Clone, Debug)]
struct Pkg {
    src: Src,
    /// The package name, or the flatpak's application id.
    name: String,
    /// What to show: a flatpak's own name; otherwise the package name.
    title: String,
    version: String,
    to_version: String,
    desc: String,
    installed: bool,
}

impl Pkg {
    fn key(&self) -> String {
        match &self.src {
            Src::Repo(_) => format!("repo:{}", self.name),
            Src::Aur => format!("aur:{}", self.name),
            Src::Flatpak(_) => format!("flatpak:{}", self.name),
        }
    }

    fn source(&self) -> String {
        match &self.src {
            Src::Repo(r) if r.is_empty() || r == "local" => "Arch".into(),
            Src::Repo(r) => format!("Arch · {r}"),
            Src::Aur => "AUR".into(),
            Src::Flatpak(r) if r.is_empty() || r == "flathub" => "Flathub".into(),
            Src::Flatpak(r) => format!("Flatpak · {r}"),
        }
    }

    fn row(&self) -> PkgRow {
        PkgRow {
            key: self.key().into(),
            name: self.title.clone().into(),
            source: self.source().into(),
            version: self.version.clone().into(),
            to_version: self.to_version.clone().into(),
            desc: self.desc.clone().into(),
            installed: self.installed,
        }
    }
}

/// `pacman -Ss` and the AUR helpers' `-Ss`:
///   extra/firefox 131.0-1 [installed]
///       Fast, Private & Safe Web Browser
fn parse_search(text: &str) -> Vec<Pkg> {
    let mut out: Vec<Pkg> = Vec::new();
    for line in text.lines() {
        if line.starts_with(char::is_whitespace) {
            if let Some(p) = out.last_mut() {
                if p.desc.is_empty() {
                    p.desc = line.trim().to_string();
                }
            }
            continue;
        }
        let mut parts = line.split_whitespace();
        let (Some(full), Some(version)) = (parts.next(), parts.next()) else { continue };
        let Some((repo, name)) = full.split_once('/') else { continue };
        let installed = line.to_lowercase().contains("[installed");
        let src = if repo == "aur" { Src::Aur } else { Src::Repo(repo.to_string()) };
        out.push(Pkg { src, name: name.into(), title: name.into(), version: version.into(), to_version: String::new(), desc: String::new(), installed });
    }
    out
}

/// `pacman -Qi`/`-Si`: blocks of "Key : Value", continued on indented lines.
fn parse_info(text: &str) -> Vec<Vec<(String, String)>> {
    let mut blocks = Vec::new();
    let mut cur: Vec<(String, String)> = Vec::new();
    for line in text.lines() {
        if line.trim().is_empty() {
            if !cur.is_empty() {
                blocks.push(std::mem::take(&mut cur));
            }
            continue;
        }
        if line.starts_with(char::is_whitespace) {
            if let Some(last) = cur.last_mut() {
                last.1.push(' ');
                last.1.push_str(line.trim());
            }
            continue;
        }
        if let Some((k, v)) = line.split_once(" : ").or_else(|| line.split_once(':')) {
            cur.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    if !cur.is_empty() {
        blocks.push(cur);
    }
    blocks
}

fn field<'a>(block: &'a [(String, String)], key: &str) -> &'a str {
    block.iter().find(|(k, _)| k == key).map(|(_, v)| v.as_str()).unwrap_or("")
}

/// `checkupdates`, `paru -Qua`: "name 1.0-1 -> 1.1-1".
fn parse_updates(text: &str) -> Vec<(String, String, String)> {
    text.lines()
        .filter_map(|l| {
            let p: Vec<&str> = l.split_whitespace().collect();
            (p.len() >= 4 && p[2] == "->").then(|| (p[0].to_string(), p[1].to_string(), p[3].to_string()))
        })
        .collect()
}

/// flatpak's --columns output: tab-separated.
fn parse_columns(text: &str) -> Vec<Vec<String>> {
    text.lines().filter(|l| !l.trim().is_empty()).map(|l| l.split('\t').map(|s| s.trim().to_string()).collect()).collect()
}

/// A package name as pacman allows one: nothing a shell could take for
/// anything else.
fn valid_name(n: &str) -> bool {
    !n.is_empty() && !n.starts_with('-') && n.chars().all(|c| c.is_ascii_alphanumeric() || "@._+-".contains(c))
}

// ── running the tools ────────────────────────────────────────────────────

fn have(cmd: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(cmd).is_file()))
}

/// A tool's output. HYPRSHELL_SOFTWARE_FAKE names a folder of canned
/// outputs (file named after the command line) for trying the app out
/// where there's no pacman.
fn run(cmd: &str, args: &[&str]) -> String {
    if let Some(dir) = std::env::var_os("HYPRSHELL_SOFTWARE_FAKE") {
        let name = std::iter::once(cmd).chain(args.iter().copied()).collect::<Vec<_>>().join(" ").replace('/', "_");
        return std::fs::read_to_string(PathBuf::from(dir).join(format!("{name}.txt"))).unwrap_or_default();
    }
    Command::new(cmd)
        .args(args)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
}

fn faking() -> bool {
    std::env::var_os("HYPRSHELL_SOFTWARE_FAKE").is_some()
}

fn aur_helper() -> Option<&'static str> {
    if faking() {
        return Some("paru");
    }
    ["paru", "yay"].into_iter().find(|h| have(h))
}

fn has_flatpak() -> bool {
    faking() || have("flatpak")
}

struct Lists {
    installed: Vec<Pkg>,
    updates: Vec<Pkg>,
    notes: Vec<String>,
}

fn load_lists() -> Lists {
    let mut notes = Vec::new();
    let foreign: HashSet<String> = run("pacman", &["-Qmq"]).lines().map(|l| l.trim().to_string()).collect();
    let mut installed: Vec<Pkg> = parse_info(&run("pacman", &["-Qei"]))
        .iter()
        .map(|b| {
            let name = field(b, "Name").to_string();
            let src = if foreign.contains(&name) { Src::Aur } else { Src::Repo(String::new()) };
            Pkg { src, title: name.clone(), name, version: field(b, "Version").into(), to_version: String::new(), desc: field(b, "Description").into(), installed: true }
        })
        .filter(|p| !p.name.is_empty())
        .collect();
    if has_flatpak() {
        for c in parse_columns(&run("flatpak", &["list", "--app", "--columns=application,name,description,version,origin"])) {
            let get = |i: usize| c.get(i).cloned().unwrap_or_default();
            installed.push(Pkg { src: Src::Flatpak(get(4)), name: get(0), title: get(1), desc: get(2), version: get(3), to_version: String::new(), installed: true });
        }
    }
    installed.sort_by_key(|p| p.title.to_lowercase());

    let mut updates = Vec::new();
    if faking() || have("checkupdates") {
        for (n, from, to) in parse_updates(&run("checkupdates", &[])) {
            let desc = installed.iter().find(|p| p.name == n).map(|p| p.desc.clone()).unwrap_or_default();
            updates.push(Pkg { src: Src::Repo(String::new()), title: n.clone(), name: n, version: from, to_version: to, desc, installed: true });
        }
    } else {
        notes.push("Install pacman-contrib to see repository updates (sudo pacman -S pacman-contrib).".into());
    }
    if let Some(h) = aur_helper() {
        for (n, from, to) in parse_updates(&run(h, &["-Qua"])) {
            let desc = installed.iter().find(|p| p.name == n).map(|p| p.desc.clone()).unwrap_or_default();
            updates.push(Pkg { src: Src::Aur, title: n.clone(), name: n, version: from, to_version: to, desc, installed: true });
        }
    }
    if has_flatpak() {
        for c in parse_columns(&run("flatpak", &["remote-ls", "--updates", "--app", "--columns=application,version"])) {
            let id = c.first().cloned().unwrap_or_default();
            let Some(p) = installed.iter().find(|p| p.name == id) else { continue };
            updates.push(Pkg { to_version: c.get(1).cloned().filter(|v| !v.is_empty()).unwrap_or_else(|| "newer".into()), ..p.clone() });
        }
    }
    // Mark what's installed as having an update.
    for u in &updates {
        if let Some(p) = installed.iter_mut().find(|p| p.name == u.name && std::mem::discriminant(&p.src) == std::mem::discriminant(&u.src)) {
            p.to_version = u.to_version.clone();
        }
    }
    Lists { installed, updates, notes }
}

fn search_all(q: &str, installed: &[Pkg]) -> (Vec<Pkg>, Vec<String>) {
    let mut notes = Vec::new();
    let words: Vec<&str> = q.split_whitespace().collect();
    if words.is_empty() {
        return (Vec::new(), notes);
    }
    let mut out = parse_search(&run("pacman", &[&["-Ss"][..], &words].concat()));
    match aur_helper() {
        Some(h) => {
            let mut aur = parse_search(&run(h, &[&["-Ssa"][..], &words].concat()));
            aur.retain(|p| p.src == Src::Aur);
            aur.truncate(80);
            out.extend(aur);
        }
        None => notes.push("No AUR helper (paru or yay), so the AUR isn't searched.".into()),
    }
    if has_flatpak() {
        let ids: HashSet<&str> = installed.iter().filter(|p| matches!(p.src, Src::Flatpak(_))).map(|p| p.name.as_str()).collect();
        for c in parse_columns(&run("flatpak", &[&["search", "--columns=application,name,description,version,remotes"][..], &words].concat())) {
            let get = |i: usize| c.get(i).cloned().unwrap_or_default();
            let id = get(0);
            if id.is_empty() || id == "No matches found" {
                continue;
            }
            let remote = get(4).split(',').next().unwrap_or("").to_string();
            out.push(Pkg { installed: ids.contains(id.as_str()), src: Src::Flatpak(remote), name: id, title: get(1), desc: get(2), version: get(3), to_version: String::new() });
        }
    }
    // Names that are the words first, then names with them, then the rest.
    let ql = q.trim().to_lowercase();
    out.sort_by_key(|p| {
        let n = p.title.to_lowercase();
        let rank = if n == ql || p.name.to_lowercase() == ql { 0 } else if n.starts_with(&ql) { 1 } else if n.contains(&ql) { 2 } else { 3 };
        (rank, n.len(), n)
    });
    out.truncate(300);
    (out, notes)
}

/// The facts worth showing about one package.
fn details(p: &Pkg) -> Vec<(String, String)> {
    let (text, keys): (String, &[&str]) = match &p.src {
        Src::Repo(_) | Src::Aur if p.installed => (run("pacman", &["-Qi", &p.name]), &["URL", "Licenses", "Installed Size", "Depends On", "Required By", "Install Date", "Install Reason"]),
        Src::Repo(r) => (run("pacman", &["-Si", &format!("{r}/{}", p.name)]), &["URL", "Licenses", "Download Size", "Installed Size", "Depends On", "Packager", "Build Date"]),
        Src::Aur => match aur_helper() {
            Some(h) => (run(h, &["-Si", &p.name]), &["URL", "Licenses", "Maintainer", "Votes", "Popularity", "Depends On", "Make Deps", "Last Modified", "Out-of-date"]),
            None => (String::new(), &[]),
        },
        Src::Flatpak(r) if p.installed => {
            let _ = r;
            return flatpak_info(&run("flatpak", &["info", &p.name]));
        }
        Src::Flatpak(r) => {
            let remote = if r.is_empty() { "flathub".to_string() } else { r.clone() };
            return flatpak_info(&run("flatpak", &["remote-info", &remote, &p.name]));
        }
    };
    let Some(block) = parse_info(&text).into_iter().next() else { return Vec::new() };
    keys.iter()
        .map(|k| (k.to_string(), field(&block, k).to_string()))
        .filter(|(_, v)| !v.is_empty() && v != "None")
        .collect()
}

fn flatpak_info(text: &str) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for line in text.lines() {
        if let Some((k, v)) = line.split_once(':') {
            let k = k.trim();
            if ["ID", "Ref", "Branch", "Version", "License", "Origin", "Collection", "Installation", "Installed", "Download", "Runtime", "Date", "Subject"].contains(&k) && !v.trim().is_empty() {
                out.push((k.to_string(), v.trim().to_string()));
            }
        }
    }
    out
}

/// The terminal to install AUR packages in: Hyprshell's, or another.
fn terminal() -> Option<PathBuf> {
    for name in ["hyprshell-term"] {
        if let Some(p) = std::env::var_os("PATH").and_then(|p| std::env::split_paths(&p).map(|d| d.join(name)).find(|p| p.is_file())) {
            return Some(p);
        }
        for d in [kit::home().join(".local/bin"), PathBuf::from("/usr/local/bin"), PathBuf::from("/usr/bin")] {
            if d.join(name).is_file() {
                return Some(d.join(name));
            }
        }
    }
    ["kitty", "foot", "alacritty", "wezterm", "konsole", "xterm"].iter().find_map(|t| {
        std::env::var_os("PATH").and_then(|p| std::env::split_paths(&p).map(|d| d.join(t)).find(|p| p.is_file()))
    })
}

/// Run `script` in a terminal with `args` as its $1…, and keep the window
/// until Enter. Arguments are passed, never pasted into the script.
fn in_terminal(script: &str, args: &[&str]) -> Result<(), String> {
    let term = terminal().ok_or("No terminal found")?;
    let body = format!("{script}; echo; printf 'Done. Press Enter to close. '; read -r _");
    let mut cmd = Command::new(&term);
    if term.file_name().is_some_and(|n| n == "wezterm") {
        cmd.arg("start").arg("--");
    } else {
        cmd.arg("-e");
    }
    cmd.args(["sh", "-c", &body, "hyprshell-software"]).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    let mut child = cmd.spawn().map_err(|e| e.to_string())?;
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

// ── the app ──────────────────────────────────────────────────────────────

struct App {
    ui: slint::Weak<AppWindow>,
    installed: Vec<Pkg>,
    updates: Vec<Pkg>,
    found: Vec<Pkg>,
    list_notes: Vec<String>,
    search_notes: Vec<String>,
    search_seq: u64,
    loading: bool,
    searching: bool,
    selected: Option<Pkg>,
    busy: bool,
    log: Vec<String>,
    toast_seq: u64,
}

type Shared = Rc<RefCell<App>>;

impl App {
    fn ui(&self) -> Option<AppWindow> {
        self.ui.upgrade()
    }

    /// The list for the page, filtered by the search on Installed.
    fn show(&self) {
        let Some(ui) = self.ui() else { return };
        let s = ui.global::<Soft>();
        let page = s.get_page();
        let q = s.get_query().to_lowercase();
        let rows: Vec<PkgRow> = match page {
            0 => self.found.iter().map(Pkg::row).collect(),
            1 => self
                .installed
                .iter()
                .filter(|p| q.is_empty() || p.title.to_lowercase().contains(q.trim()) || p.name.to_lowercase().contains(q.trim()))
                .map(Pkg::row)
                .collect(),
            _ => self.updates.iter().map(Pkg::row).collect(),
        };
        s.set_rows(ModelRc::new(VecModel::from(rows)));
        s.set_installed_count(self.installed.len() as i32);
        s.set_update_count(self.updates.len() as i32);
        s.set_loading(if page == 0 { self.searching } else { self.loading });
        let notes = if page == 0 { &self.search_notes } else { &self.list_notes };
        let note = if page == 1 { notes.iter().filter(|n| !n.contains("pacman-contrib")).cloned().collect::<Vec<_>>().join(" ") } else { notes.join(" ") };
        s.set_note(note.into());
    }

    fn find(&self, key: &str) -> Option<Pkg> {
        self.found.iter().chain(&self.installed).chain(&self.updates).find(|p| p.key() == key).cloned().map(|mut p| {
            // What's known about it being installed, from wherever.
            if let Some(i) = self.installed.iter().find(|i| i.key() == p.key()) {
                p.installed = true;
                if p.to_version.is_empty() {
                    p.to_version = i.to_version.clone();
                }
            }
            p
        })
    }

    fn toast(app: &Shared, text: &str) {
        let seq = {
            let mut a = app.borrow_mut();
            a.toast_seq += 1;
            a.toast_seq
        };
        if let Some(ui) = app.borrow().ui() {
            ui.global::<Soft>().set_toast(text.into());
        }
        let app = app.clone();
        slint::Timer::single_shot(Duration::from_millis(3500), move || {
            if app.borrow().toast_seq == seq {
                if let Some(ui) = app.borrow().ui() {
                    ui.global::<Soft>().set_toast("".into());
                }
            }
        });
    }
}

fn refresh(app: &Shared) {
    {
        let mut a = app.borrow_mut();
        a.loading = true;
        a.show();
    }
    let app = app.clone();
    kit::spawn(load_lists, move |l| {
        let mut a = app.borrow_mut();
        a.installed = l.installed;
        a.updates = l.updates;
        a.list_notes = l.notes;
        a.loading = false;
        // The picked one, as it is now.
        if let Some(sel) = a.selected.clone() {
            let fresh = a.find(&sel.key()).unwrap_or(Pkg { installed: false, to_version: String::new(), ..sel });
            if let Some(ui) = a.ui() {
                ui.global::<Soft>().set_detail(fresh.row());
            }
            a.selected = Some(fresh);
        }
        a.show();
    });
}

fn search(app: &Shared, q: String) {
    let (seq, installed) = {
        let mut a = app.borrow_mut();
        a.search_seq += 1;
        a.searching = !q.trim().is_empty();
        if q.trim().is_empty() {
            a.found.clear();
            a.search_notes.clear();
        }
        a.show();
        (a.search_seq, a.installed.clone())
    };
    if q.trim().is_empty() {
        return;
    }
    let app = app.clone();
    kit::spawn(
        move || search_all(&q, &installed),
        move |(found, notes)| {
            let mut a = app.borrow_mut();
            if a.search_seq != seq {
                return;
            }
            a.found = found;
            a.search_notes = notes;
            a.searching = false;
            a.show();
        },
    );
}

fn pick(app: &Shared, key: &str) {
    let Some(p) = app.borrow().find(key) else { return };
    {
        let mut a = app.borrow_mut();
        if let Some(ui) = a.ui() {
            let s = ui.global::<Soft>();
            s.set_selected(key.into());
            s.set_detail(p.row());
            s.set_facts(ModelRc::default());
            s.set_facts_loading(true);
        }
        a.selected = Some(p.clone());
    }
    let app = app.clone();
    let key = key.to_string();
    kit::spawn(
        move || details(&p),
        move |facts| {
            let a = app.borrow();
            if a.selected.as_ref().map(|p| p.key()) != Some(key) {
                return;
            }
            if let Some(ui) = a.ui() {
                let s = ui.global::<Soft>();
                s.set_facts(ModelRc::new(VecModel::from(facts.into_iter().map(|(k, v)| Fact { key: k.into(), value: v.into() }).collect::<Vec<_>>())));
                s.set_facts_loading(false);
            }
        },
    );
}

/// Run the commands one after another, showing their output; then look
/// at what's installed again.
fn job(app: &Shared, title: &str, steps: Vec<Vec<String>>, done_msg: String) {
    {
        let mut a = app.borrow_mut();
        if a.busy {
            return;
        }
        a.busy = true;
        a.log.clear();
        if let Some(ui) = a.ui() {
            let s = ui.global::<Soft>();
            s.set_busy(true);
            s.set_busy_title(title.into());
            s.set_busy_line("".into());
            s.set_log("".into());
        }
    }
    let weak = app.borrow().ui.clone();
    let app2 = app.clone();
    kit::spawn(
        move || -> Result<(), String> {
            for argv in steps {
                let weak = weak.clone();
                let line = move |l: String| {
                    let weak = weak.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if weak.upgrade().is_some() {
                            APP.with(|a| {
                                if let Some(app) = a.borrow().as_ref() {
                                    output(app, l);
                                }
                            });
                        }
                    });
                };
                line(format!("$ {}", argv.join(" ")));
                if faking() {
                    std::thread::sleep(Duration::from_millis(800));
                    line("(pretend)".into());
                    continue;
                }
                let mut child = Command::new(&argv[0])
                    .args(&argv[1..])
                    .env("LC_ALL", "C")
                    .stdin(Stdio::null())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .spawn()
                    .map_err(|e| format!("{}: {e}", argv[0]))?;
                let err = child.stderr.take();
                let err_line = line.clone();
                let errs = std::thread::spawn(move || {
                    let mut last = String::new();
                    if let Some(e) = err {
                        for l in std::io::BufReader::new(e).lines().map_while(Result::ok) {
                            if !l.trim().is_empty() {
                                last = l.clone();
                            }
                            err_line(l);
                        }
                    }
                    last
                });
                if let Some(out) = child.stdout.take() {
                    for l in std::io::BufReader::new(out).lines().map_while(Result::ok) {
                        line(l);
                    }
                }
                let status = child.wait().map_err(|e| e.to_string())?;
                let last = errs.join().unwrap_or_default();
                if !status.success() {
                    return Err(match status.code() {
                        Some(126) if argv[0] == "pkexec" => "Not allowed (the password was refused or cancelled)".into(),
                        Some(127) if argv[0] == "pkexec" => "No password prompt could be shown — is a polkit agent running?".into(),
                        _ if !last.is_empty() => last,
                        _ => format!("{} failed", argv[0]),
                    });
                }
            }
            Ok(())
        },
        move |r| {
            {
                let mut a = app2.borrow_mut();
                a.busy = false;
                if let Some(ui) = a.ui() {
                    let s = ui.global::<Soft>();
                    s.set_busy(false);
                    s.set_busy_title(if r.is_ok() { "Done".into() } else { "Didn't finish".into() });
                }
            }
            match r {
                Ok(()) => App::toast(&app2, &done_msg),
                Err(e) => {
                    if let Some(ui) = app2.borrow().ui() {
                        ui.global::<Soft>().set_log_open(true);
                    }
                    App::toast(&app2, &e)
                }
            }
            refresh(&app2);
        },
    );
}

fn output(app: &Shared, line: String) {
    let mut a = app.borrow_mut();
    a.log.push(line.clone());
    if a.log.len() > 400 {
        let cut = a.log.len() - 400;
        a.log.drain(..cut);
    }
    if let Some(ui) = a.ui() {
        let s = ui.global::<Soft>();
        if !line.trim().is_empty() {
            s.set_busy_line(line.trim().into());
        }
        s.set_log(a.log.join("\n").into());
    }
}

thread_local! {
    static APP: RefCell<Option<Shared>> = const { RefCell::new(None) };
}

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|x| x.to_string()).collect()
}

fn install(app: &Shared, key: &str) {
    let Some(p) = app.borrow().find(key) else { return };
    if !valid_name(&p.name) {
        App::toast(app, "That name doesn't look like a package's");
        return;
    }
    match &p.src {
        Src::Aur => {
            let Some(h) = aur_helper() else {
                App::toast(app, "Installing from the AUR needs paru or yay");
                return;
            };
            match in_terminal(&format!("{h} -S -- \"$1\""), &[&p.name]) {
                Ok(()) => App::toast(app, "Follow along in the terminal; this updates when you check again"),
                Err(e) => App::toast(app, &e),
            }
        }
        // An update of a repository package is the whole system's.
        Src::Repo(_) if p.installed => job(app, "Updating the system", vec![s(&["pkexec", "pacman", "-Syu", "--noconfirm"])], "System updated".into()),
        Src::Repo(r) => {
            let target = if r.is_empty() { p.name.clone() } else { format!("{r}/{}", p.name) };
            job(app, &format!("Installing {}", p.title), vec![s(&["pkexec", "pacman", "-S", "--needed", "--noconfirm", &target])], format!("{} installed", p.title));
        }
        Src::Flatpak(_) if p.installed => job(app, &format!("Updating {}", p.title), vec![s(&["flatpak", "update", "-y", "--noninteractive", &p.name])], format!("{} updated", p.title)),
        Src::Flatpak(r) => {
            let remote = if r.is_empty() { "flathub".to_string() } else { r.clone() };
            job(app, &format!("Installing {}", p.title), vec![s(&["flatpak", "install", "-y", "--noninteractive", &remote, &p.name])], format!("{} installed", p.title));
        }
    }
}

fn remove(app: &Shared, key: &str) {
    let Some(p) = app.borrow().find(key) else { return };
    if !valid_name(&p.name) {
        return;
    }
    let steps = match p.src {
        Src::Flatpak(_) => vec![s(&["flatpak", "uninstall", "-y", "--noninteractive", &p.name])],
        _ => vec![s(&["pkexec", "pacman", "-Rns", "--noconfirm", &p.name])],
    };
    job(app, &format!("Removing {}", p.title), steps, format!("{} removed", p.title));
}

fn update_all(app: &Shared) {
    let (repo, aur, flat) = {
        let a = app.borrow();
        (
            a.updates.iter().any(|p| matches!(p.src, Src::Repo(_))),
            a.updates.iter().any(|p| p.src == Src::Aur),
            a.updates.iter().any(|p| matches!(p.src, Src::Flatpak(_))),
        )
    };
    let mut steps = Vec::new();
    if repo {
        steps.push(s(&["pkexec", "pacman", "-Syu", "--noconfirm"]));
    }
    if flat {
        steps.push(s(&["flatpak", "update", "-y", "--noninteractive"]));
    }
    if aur {
        if let Some(h) = aur_helper() {
            if let Err(e) = in_terminal(&format!("{h} -Sua"), &[]) {
                App::toast(app, &e);
            }
        }
    }
    if !steps.is_empty() {
        job(app, "Updating everything", steps, "Everything's updated".into());
    }
}

fn main() {
    kit::init("hyprshell-software");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-software");

    let app: Shared = Rc::new(RefCell::new(App {
        ui: ui.as_weak(),
        installed: Vec::new(),
        updates: Vec::new(),
        found: Vec::new(),
        list_notes: Vec::new(),
        search_notes: Vec::new(),
        search_seq: 0,
        loading: false,
        searching: false,
        selected: None,
        busy: false,
        log: Vec::new(),
        toast_seq: 0,
    }));
    APP.with(|a| *a.borrow_mut() = Some(app.clone()));
    let s = ui.global::<Soft>();

    // Typing: on Search, looked up a moment after it stops; on the other
    // pages, the list filtered at once.
    let later = Rc::new(slint::Timer::default());
    {
        let (app, later) = (app.clone(), later.clone());
        s.on_search(move |q| {
            let page = app.borrow().ui().map(|ui| ui.global::<Soft>().get_page()).unwrap_or(0);
            if page != 0 {
                if page == 1 {
                    app.borrow().show();
                    return;
                }
                if let Some(ui) = app.borrow().ui() {
                    ui.global::<Soft>().set_page(0);
                }
            }
            let app = app.clone();
            let q = q.to_string();
            later.start(slint::TimerMode::SingleShot, Duration::from_millis(450), move || search(&app, q.clone()));
        });
    }
    {
        let app = app.clone();
        s.on_set_page(move |p| {
            if let Some(ui) = app.borrow().ui() {
                ui.global::<Soft>().set_page(p);
            }
            app.borrow().show();
            if p == 0 {
                let q = app.borrow().ui().map(|ui| ui.global::<Soft>().get_query().to_string()).unwrap_or_default();
                if app.borrow().found.is_empty() && !q.trim().is_empty() {
                    search(&app, q);
                }
            }
        });
    }
    {
        let app = app.clone();
        s.on_pick(move |k| pick(&app, &k));
    }
    {
        let app = app.clone();
        s.on_install(move |k| install(&app, &k));
    }
    {
        let app = app.clone();
        s.on_remove(move |k| remove(&app, &k));
    }
    {
        let app = app.clone();
        s.on_update_all(move || update_all(&app));
    }
    {
        let app = app.clone();
        s.on_refresh(move || refresh(&app));
    }

    // Not while pacman is at work: cutting its output off mid-change could
    // stop it halfway.
    {
        let app = app.clone();
        ui.global::<Win>().on_close(move || {
            if app.borrow().busy {
                App::toast(&app, "Wait for it to finish first");
                return;
            }
            if let Some(ui) = app.borrow().ui() {
                let _ = ui.hide();
            }
            let _ = slint::quit_event_loop();
        });
    }
    {
        let app = app.clone();
        ui.window().on_close_requested(move || {
            if app.borrow().busy {
                App::toast(&app, "Wait for it to finish first");
                slint::CloseRequestResponse::KeepWindowShown
            } else {
                let _ = slint::quit_event_loop();
                slint::CloseRequestResponse::HideWindow
            }
        });
    }

    if !faking() && !have("pacman") {
        app.borrow_mut().list_notes.push("pacman isn't here: this is for Arch and its kin (CachyOS, EndeavourOS…).".into());
    }
    refresh(&app);
    ui.run().expect("run");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_searches() {
        let t = "extra/firefox 131.0-1 [installed]\n    Fast, Private & Safe Web Browser\naur/firefox-nightly 133.0a1-1 (+12 0.50) \n    Nightly builds\n";
        let p = parse_search(t);
        assert_eq!(p.len(), 2);
        assert_eq!(p[0].src, Src::Repo("extra".into()));
        assert!(p[0].installed && !p[1].installed);
        assert_eq!(p[1].src, Src::Aur);
        assert_eq!(p[1].desc, "Nightly builds");
    }

    #[test]
    fn reads_info_and_updates() {
        let t = "Name            : bash\nVersion         : 5.2-1\nDepends On      : readline  libreadline.so=8-64\n                  glibc\n\nName            : zsh\nVersion         : 5.9-1\n";
        let b = parse_info(t);
        assert_eq!(b.len(), 2);
        assert_eq!(field(&b[0], "Depends On"), "readline  libreadline.so=8-64 glibc");
        assert_eq!(parse_updates("linux 6.1-1 -> 6.2-1\nnoise\n"), vec![("linux".into(), "6.1-1".into(), "6.2-1".into())]);
    }

    #[test]
    fn names() {
        assert!(valid_name("lib32-mesa") && valid_name("gtk+3") && valid_name("org.gnome.Maps"));
        assert!(!valid_name("-Rns") && !valid_name("a;rm") && !valid_name("a b") && !valid_name("$(x)"));
    }
}
