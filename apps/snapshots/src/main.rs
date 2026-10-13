//! Snapshots: snapper's btrfs snapshots, in the shell's look.
//!
//! Everything goes through the snapper command (its --jsonout for lists
//! and settings), on a thread of its own so a slow btrfs never holds the
//! window. What needs root — putting files back, rolling back, changing
//! settings when this account is not in the config's ALLOW_USERS — runs
//! through pkexec, which puts up the shell's polkit prompt.
//!
//! HYPRSHELL_SNAPPER points it at another snapper binary (tests).

slint::include_modules!();

use hyprshell_kit as kit;
use serde_json::Value;
use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::process::Command;
use std::rc::Rc;
use std::time::Duration;

fn snapper_bin() -> String {
    std::env::var("HYPRSHELL_SNAPPER").unwrap_or_else(|_| "snapper".into())
}

/// Run snapper; with `root`, through pkexec. Ok(stdout) or Err(what it
/// said went wrong).
fn snapper(args: &[String], root: bool) -> Result<String, String> {
    let mut cmd = if root {
        let mut c = Command::new("pkexec");
        c.arg(snapper_bin());
        c
    } else {
        Command::new(snapper_bin())
    };
    let out = cmd.args(args).env("LANG", "C").env("LC_ALL", "C").output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    } else {
        let err = String::from_utf8_lossy(&out.stderr).trim().to_string();
        // pkexec's own codes: 126 dismissed, 127 not authorised.
        Err(match out.status.code() {
            Some(126) if root => "Cancelled".into(),
            Some(127) if root => "Not allowed".into(),
            _ if err.is_empty() => format!("snapper exited with {}", out.status),
            _ => err.lines().last().unwrap_or("").to_string(),
        })
    }
}

/// Try as this user first, then as root if snapper said no.
fn snapper_either(args: &[String]) -> Result<String, String> {
    match snapper(args, false) {
        Ok(o) => Ok(o),
        Err(e) if denied(&e) => snapper(args, true),
        Err(e) => Err(e),
    }
}

fn denied(e: &str) -> bool {
    let e = e.to_lowercase();
    e.contains("permission") || e.contains("not allowed") || e.contains("denied")
}

fn s(v: &str) -> String {
    v.to_string()
}

#[derive(Clone, Debug)]
struct Raw {
    number: i64,
    kind: String,
    pre: i64,
    date: String,
    user: String,
    cleanup: String,
    description: String,
    used: Option<u64>,
    default: bool,
    active: bool,
}

fn parse_list(json: &str, config: &str) -> Vec<Raw> {
    let v: Value = serde_json::from_str(json).unwrap_or(Value::Null);
    let list = v.get(config).and_then(|x| x.as_array()).cloned().unwrap_or_default();
    list.iter()
        .map(|x| Raw {
            number: x["number"].as_i64().unwrap_or(-1),
            kind: x["type"].as_str().unwrap_or("single").to_string(),
            pre: x["pre-number"].as_i64().unwrap_or(-1),
            date: x["date"].as_str().unwrap_or("").to_string(),
            user: x["user"].as_str().unwrap_or("").to_string(),
            cleanup: x["cleanup"].as_str().unwrap_or("").to_string(),
            description: x["description"].as_str().unwrap_or("").to_string(),
            used: x["used-space"].as_u64(),
            default: x["default"].as_bool().unwrap_or(false),
            active: x["active"].as_bool().unwrap_or(false),
        })
        .filter(|r| r.number > 0)
        .collect()
}

/// "2025-10-13 14:22:01" (snapper's local time) → (y, m, d, hh, mm).
fn parse_date(d: &str) -> Option<(i32, u32, u32, u32, u32)> {
    let (date, time) = d.split_once(' ')?;
    let mut p = date.split('-');
    let y = p.next()?.parse().ok()?;
    let m = p.next()?.parse().ok()?;
    let dd = p.next()?.parse().ok()?;
    let mut t = time.split(':');
    Some((y, m, dd, t.next()?.parse().ok()?, t.next()?.parse().ok()?))
}

const MONTHS: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y } as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = m as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

/// When, said plainly, and the heading it goes under.
fn when_and_group(date: &str) -> (String, String) {
    let Some((y, m, d, hh, mm)) = parse_date(date) else { return (date.to_string(), "Earlier".into()) };
    let (ny, nm, nd, ..) = kit::local(kit::now());
    let ago = days_from_civil(ny, nm, nd) - days_from_civil(y, m, d);
    let time = format!("{hh:02}:{mm:02}");
    let short = format!("{d} {}", &MONTHS[(m as usize + 11) % 12][..3]);
    match ago {
        0 => (format!("Today, {time}"), "Today".into()),
        1 => (format!("Yesterday, {time}"), "Yesterday".into()),
        2..=6 => (format!("{short}, {time}"), "This week".into()),
        _ if y == ny && m == nm => (format!("{short}, {time}"), "Earlier this month".into()),
        _ => (
            if y == ny { format!("{short}, {time}") } else { format!("{short} {y}, {time}") },
            format!("{} {y}", MONTHS[(m as usize + 11) % 12]),
        ),
    }
}

fn title_for(r: &Raw, post: Option<&Raw>) -> String {
    let d = r.description.trim();
    if !d.is_empty() {
        // snap-pac's descriptions are the pacman command line.
        if post.is_some() && (d.starts_with("pacman") || d.starts_with("/usr/bin/pacman") || d.contains("pacman -")) {
            return format!("Update: {}", d.trim_start_matches("/usr/bin/"));
        }
        return d.to_string();
    }
    match (r.cleanup.as_str(), post.is_some()) {
        ("timeline", _) => "Hourly snapshot".into(),
        (_, true) => "Before and after".into(),
        _ => "Snapshot".into(),
    }
}

/// Snapper's flat list as rows: a pre and its post become one row.
fn rows(raw: &[Raw]) -> (Vec<Snap>, Vec<(i64, i64)>) {
    let mut out = Vec::new();
    let mut spans = Vec::new();
    let mut used_post = std::collections::HashSet::new();
    let mut sorted = raw.to_vec();
    sorted.sort_by(|a, b| b.number.cmp(&a.number));
    let mut last_group = String::new();
    for r in &sorted {
        if r.kind == "post" {
            continue;
        }
        let post = if r.kind == "pre" { raw.iter().find(|p| p.kind == "post" && p.pre == r.number) } else { None };
        if let Some(p) = post {
            used_post.insert(p.number);
        }
        let (when, group) = when_and_group(&r.date);
        let first = group != last_group;
        last_group = group.clone();
        let size = match (r.used, post.and_then(|p| p.used)) {
            (Some(a), Some(b)) => a + b,
            (Some(a), None) => a,
            _ => 0,
        };
        out.push(Snap {
            number: r.number as i32,
            kind: if post.is_some() { "pair".into() } else { "single".into() },
            post: post.map(|p| p.number as i32).unwrap_or(-1),
            title: title_for(r, post).into(),
            when: when.into(),
            group: group.into(),
            user: r.user.clone().into(),
            cleanup: r.cleanup.clone().into(),
            size: if size > 0 { kit::bytes(size).into() } else { SharedString::new() },
            is_default: r.default || post.map(|p| p.default).unwrap_or(false),
            is_active: r.active || post.map(|p| p.active).unwrap_or(false),
            first_in_group: first,
        });
        spans.push((r.number, post.map(|p| p.number).unwrap_or(0)));
    }
    // A post whose pre is gone stands on its own.
    for r in sorted.iter().filter(|r| r.kind == "post" && !used_post.contains(&r.number)) {
        let (when, group) = when_and_group(&r.date);
        out.push(Snap {
            number: r.number as i32,
            kind: "single".into(),
            post: -1,
            title: title_for(r, None).into(),
            when: when.into(),
            group: group.into(),
            user: r.user.clone().into(),
            cleanup: r.cleanup.clone().into(),
            size: r.used.map(|u| kit::bytes(u).into()).unwrap_or_default(),
            is_default: r.default,
            is_active: r.active,
            first_in_group: false,
        });
        spans.push((r.number, 0));
    }
    (out, spans)
}

/// snapper status: "c..... /etc/fstab" — what changed, then the path.
fn parse_status(text: &str) -> Vec<(String, String, String)> {
    text.lines()
        .filter_map(|l| {
            let (flags, path) = l.split_once(' ')?;
            let f: Vec<char> = flags.chars().collect();
            let first = *f.first()?;
            let (status, what) = match first {
                '+' => ("+", "new".to_string()),
                '-' => ("-", "removed".to_string()),
                _ => {
                    let mut w = Vec::new();
                    if f.first() == Some(&'c') { w.push("contents"); }
                    if f.first() == Some(&'t') { w.push("type"); }
                    if f.get(1) == Some(&'p') { w.push("permissions"); }
                    if f.get(2) == Some(&'u') || f.get(3) == Some(&'g') { w.push("owner"); }
                    if f.get(4) == Some(&'x') || f.get(5) == Some(&'a') { w.push("attributes"); }
                    ("~", w.join(", "))
                }
            };
            Some((path.trim().to_string(), status.to_string(), what))
        })
        .collect()
}

fn fs_type(path: &str) -> String {
    Command::new("stat").args(["-f", "-c", "%T", path]).output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
}

fn whoami() -> String {
    std::env::var("USER").ok().filter(|u| !u.is_empty()).unwrap_or_else(|| {
        Command::new("id").arg("-un").output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default()
    })
}

struct App {
    ui: slint::Weak<AppWindow>,
    configs: RefCell<Vec<(String, String)>>,
    spans: RefCell<Vec<(i64, i64)>>,
    changes: RefCell<Vec<(String, String, String, bool)>>,
    compare_span: RefCell<(i64, i64)>,
    toast_timer: slint::Timer,
}

impl App {
    fn ui(&self) -> AppWindow {
        self.ui.upgrade().unwrap()
    }
    fn toast(&self, text: &str, bad: bool) {
        let ui = self.ui();
        ui.global::<Snapper>().set_toast(text.into());
        ui.global::<Snapper>().set_toast_bad(bad);
        let w = self.ui.clone();
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(3200), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Snapper>().set_toast(SharedString::new());
            }
        });
    }
    fn config(&self) -> String {
        self.ui().global::<Snapper>().get_config().to_string()
    }
    fn subvolume(&self) -> String {
        let c = self.config();
        self.configs.borrow().iter().find(|(n, _)| *n == c).map(|(_, s)| s.clone()).unwrap_or_else(|| "/".into())
    }

    /// Everything about the current config, read again.
    fn load(self: &Rc<Self>) {
        let ui = self.ui();
        ui.global::<Snapper>().set_busy(true);
        let config = self.config();
        let me = whoami();
        let a = self.clone();
        kit::spawn(
            move || {
                // Is snapper there at all?
                if Command::new(snapper_bin()).arg("--version").output().is_err() {
                    return Err("missing".to_string());
                }
                let cfgs = snapper(&[s("--jsonout"), s("list-configs")], false).map_err(|e| format!("error:{e}"))?;
                let v: Value = serde_json::from_str(&cfgs).unwrap_or(Value::Null);
                let configs: Vec<(String, String)> = v["configs"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .iter()
                    .map(|c| (c["config"].as_str().unwrap_or("").to_string(), c["subvolume"].as_str().unwrap_or("/").to_string()))
                    .filter(|(n, _)| !n.is_empty())
                    .collect();
                if configs.is_empty() {
                    return Err("no-config".into());
                }
                let config = if configs.iter().any(|(n, _)| *n == config) { config } else {
                    configs.iter().find(|(n, _)| n == "root").unwrap_or(&configs[0]).0.clone()
                };
                let list = snapper(&[s("--jsonout"), s("-c"), config.clone(), s("list")], false);
                let settings = snapper(&[s("--jsonout"), s("-c"), config.clone(), s("get-config")], false).ok();
                let allowed = match &settings {
                    Some(t) => {
                        let v: Value = serde_json::from_str(t).unwrap_or(Value::Null);
                        let users = v["ALLOW_USERS"].as_str().unwrap_or("").split_whitespace().any(|u| u == me);
                        users || me == "root"
                    }
                    None => false,
                };
                Ok((configs, config, list, settings, allowed))
            },
            move |r| {
                let ui = a.ui();
                let g = ui.global::<Snapper>();
                g.set_ready(true);
                g.set_busy(false);
                match r {
                    Err(e) if e == "missing" => g.set_problem("missing".into()),
                    Err(e) if e == "no-config" => {
                        g.set_problem("no-config".into());
                        g.set_can_set_up(fs_type("/") == "btrfs");
                    }
                    Err(e) => {
                        g.set_problem("error".into());
                        g.set_detail(e.trim_start_matches("error:").to_string().into());
                    }
                    Ok((configs, config, list, settings, allowed)) => {
                        g.set_problem("".into());
                        g.set_allowed(allowed);
                        let cfg_rows: Vec<Config> = configs
                            .iter()
                            .map(|(n, sv)| Config {
                                name: n.clone().into(),
                                label: match n.as_str() { "root" => "System".to_string(), "home" => "Home".to_string(), o => o.to_string() }.into(),
                                subvolume: sv.clone().into(),
                            })
                            .collect();
                        *a.configs.borrow_mut() = configs;
                        g.set_configs(ModelRc::new(VecModel::from(cfg_rows)));
                        g.set_config(config.clone().into());
                        match list {
                            Ok(json) => {
                                let raw = parse_list(&json, &config);
                                let (snaps, spans) = rows(&raw);
                                let keep = g.get_picked();
                                let n = snaps.len() as i32;
                                g.set_snaps(ModelRc::new(VecModel::from(snaps)));
                                *a.spans.borrow_mut() = spans;
                                g.set_picked(if keep >= 0 && keep < n { keep } else if n > 0 { 0 } else { -1 });
                            }
                            Err(e) => {
                                g.set_snaps(ModelRc::new(VecModel::from(Vec::<Snap>::new())));
                                g.set_picked(-1);
                                if denied(&e) {
                                    g.set_allowed(false);
                                } else {
                                    a.toast(&e, true);
                                }
                            }
                        }
                        if let Some(t) = settings {
                            let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
                            let num = |k: &str| v[k].as_str().and_then(|x| x.split('-').last()).and_then(|x| x.parse::<i32>().ok()).unwrap_or(0);
                            g.set_timeline(v["TIMELINE_CREATE"].as_str() == Some("yes"));
                            g.set_keep_hourly(num("TIMELINE_LIMIT_HOURLY"));
                            g.set_keep_daily(num("TIMELINE_LIMIT_DAILY"));
                            g.set_keep_weekly(num("TIMELINE_LIMIT_WEEKLY"));
                            g.set_keep_monthly(num("TIMELINE_LIMIT_MONTHLY"));
                            g.set_keep_yearly(num("TIMELINE_LIMIT_YEARLY"));
                            g.set_keep_number(num("NUMBER_LIMIT"));
                        }
                    }
                }
            },
        );
    }

    /// Run snapper for an action, then show what it said and read again.
    fn act(self: &Rc<Self>, args: Vec<String>, root: Option<bool>, done: &'static str) {
        self.ui().global::<Snapper>().set_busy(true);
        let a = self.clone();
        kit::spawn(
            move || match root {
                Some(r) => snapper(&args, r),
                None => snapper_either(&args),
            },
            move |r| {
                a.ui().global::<Snapper>().set_busy(false);
                match r {
                    Ok(_) => a.toast(done, false),
                    Err(e) => a.toast(&e, true),
                }
                a.load();
            },
        );
    }

    fn show_changes(&self) {
        let ui = self.ui();
        let g = ui.global::<Snapper>();
        let filter = g.get_filter().to_lowercase();
        let ch = self.changes.borrow();
        let rows: Vec<Change> = ch
            .iter()
            .filter(|(p, ..)| filter.is_empty() || p.to_lowercase().contains(&filter))
            .map(|(p, st, w, picked)| Change { path: p.clone().into(), status: st.clone().into(), what: w.clone().into(), picked: *picked })
            .collect();
        g.set_picked_count(ch.iter().filter(|c| c.3).count() as i32);
        g.set_changes(ModelRc::new(VecModel::from(rows)));
    }
}

fn main() {
    kit::init("hyprshell-snapshots");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-snapshots");
    ui.global::<Snapper>().set_user(whoami().into());
    ui.global::<Snapper>().set_config("root".into());

    let app = Rc::new(App {
        ui: ui.as_weak(),
        configs: RefCell::new(Vec::new()),
        spans: RefCell::new(Vec::new()),
        changes: RefCell::new(Vec::new()),
        compare_span: RefCell::new((0, 0)),
        toast_timer: slint::Timer::default(),
    });
    app.load();

    let g = ui.global::<Snapper>();
    let a = app.clone();
    g.on_refresh(move || a.load());
    let a = app.clone();
    g.on_pick_config(move |c| {
        let ui = a.ui();
        ui.global::<Snapper>().set_config(c);
        ui.global::<Snapper>().set_picked(-1);
        a.load();
    });
    let a = app.clone();
    g.on_create(move |d| {
        let d = d.trim().to_string();
        let mut args = vec![s("-c"), a.config(), s("create"), s("--description")];
        args.push(if d.is_empty() { "Taken by hand".into() } else { d });
        a.act(args, None, "Snapshot taken");
    });
    let a = app.clone();
    g.on_delete(move |n, post| {
        let mut args = vec![s("-c"), a.config(), s("delete"), n.to_string()];
        if post > 0 {
            args.push(post.to_string());
        }
        a.act(args, None, "Deleted");
    });
    let a = app.clone();
    g.on_rollback(move |n| {
        a.act(vec![s("rollback"), n.to_string()], Some(true), "Rolled back: restart to finish");
    });
    let a = app.clone();
    g.on_set_config(move |k, v| {
        let args = vec![s("-c"), a.config(), s("set-config"), format!("{k}={v}")];
        a.act(args, None, "Saved");
    });
    let a = app.clone();
    g.on_set_up(move || {
        a.act(vec![s("-c"), s("root"), s("create-config"), s("/")], Some(true), "Snapshots are set up");
    });
    let a = app.clone();
    g.on_allow_me(move || {
        // One prompt: add this account to ALLOW_USERS (keeping who is
        // there) and SYNC_ACL, which also lets it read the snapshots.
        let me = whoami();
        let config = a.config();
        a.ui().global::<Snapper>().set_busy(true);
        let b = a.clone();
        kit::spawn(
            move || {
                let script = r#"cfg=$1; me=$2; snap=$3
                    cur=$("$snap" --jsonout -c "$cfg" get-config | sed -n 's/.*"ALLOW_USERS" *: *"\([^"]*\)".*/\1/p')
                    case " $cur " in *" $me "*) exit 0 ;; esac
                    exec "$snap" -c "$cfg" set-config "ALLOW_USERS=${cur:+$cur }$me" SYNC_ACL=yes"#;
                let out = Command::new("pkexec").args(["sh", "-c", script, "allow", &config, &me, &snapper_bin()]).output();
                match out {
                    Ok(o) if o.status.success() => Ok(()),
                    Ok(o) if o.status.code() == Some(126) => Err("Cancelled".to_string()),
                    Ok(o) => Err(String::from_utf8_lossy(&o.stderr).trim().to_string()),
                    Err(e) => Err(e.to_string()),
                }
            },
            move |r| {
                b.ui().global::<Snapper>().set_busy(false);
                match r {
                    Ok(_) => b.toast("Your account can manage snapshots now", false),
                    Err(e) => b.toast(&e, true),
                }
                b.load();
            },
        );
    });
    let a = app.clone();
    g.on_open_files(move |n| {
        let sub = a.subvolume();
        let base = if sub == "/" { String::new() } else { sub };
        let path = format!("{base}/.snapshots/{n}/snapshot");
        let _ = Command::new("xdg-open").arg(path).spawn();
    });

    // Comparing.
    let a = app.clone();
    g.on_compare(move |i| {
        let ui = a.ui();
        let g = ui.global::<Snapper>();
        let Some(&(from, to)) = a.spans.borrow().get(i as usize) else { return };
        let snap = g.get_snaps().row_data(i as usize);
        *a.compare_span.borrow_mut() = (from, to);
        a.changes.borrow_mut().clear();
        g.set_filter("".into());
        g.set_change_picked(-1);
        g.set_diff(ModelRc::new(VecModel::from(Vec::<DiffLine>::new())));
        g.set_compare_title(
            match snap {
                Some(s) if to == 0 => format!("#{} → now  ·  {}", from, s.title),
                Some(s) => format!("#{from} → #{to}  ·  {}", s.title),
                None => String::new(),
            }
            .into(),
        );
        g.set_comparing(true);
        g.set_changes_loading(true);
        a.show_changes();
        let config = a.config();
        let b = a.clone();
        kit::spawn(
            move || snapper_either(&[s("-c"), config, s("status"), format!("{from}..{to}")]),
            move |r| {
                let ui = b.ui();
                ui.global::<Snapper>().set_changes_loading(false);
                match r {
                    Ok(t) => {
                        *b.changes.borrow_mut() = parse_status(&t).into_iter().map(|(p, s, w)| (p, s, w, false)).collect();
                        b.show_changes();
                    }
                    Err(e) => b.toast(&e, true),
                }
            },
        );
    });
    let a = app.clone();
    g.on_close_compare(move || {
        a.ui().global::<Snapper>().set_comparing(false);
    });
    let a = app.clone();
    g.on_filtered(move |_| a.show_changes());
    let a = app.clone();
    g.on_toggle_change(move |i| {
        let ui = a.ui();
        let path = ui.global::<Snapper>().get_changes().row_data(i as usize).map(|c| c.path.to_string());
        if let Some(p) = path {
            if let Some(c) = a.changes.borrow_mut().iter_mut().find(|c| c.0 == p) {
                c.3 = !c.3;
            }
        }
        a.show_changes();
    });
    let a = app.clone();
    g.on_pick_change(move |i| {
        let ui = a.ui();
        let g = ui.global::<Snapper>();
        g.set_change_picked(i);
        let Some(c) = g.get_changes().row_data(i as usize) else { return };
        let (from, to) = *a.compare_span.borrow();
        g.set_diff_loading(true);
        let config = a.config();
        let path = c.path.to_string();
        let b = a.clone();
        kit::spawn(
            move || snapper_either(&[s("-c"), config, s("diff"), format!("{from}..{to}"), path]),
            move |r| {
                let ui = b.ui();
                let g = ui.global::<Snapper>();
                g.set_diff_loading(false);
                let lines: Vec<DiffLine> = match r {
                    Ok(t) if t.trim().is_empty() => vec![DiffLine { text: "No differences in the text (a binary file, or only its permissions or owner changed).".into(), kind: " ".into() }],
                    Ok(t) => t
                        .lines()
                        .filter(|l| !l.starts_with("---") && !l.starts_with("+++") && !l.starts_with("diff "))
                        .take(4000)
                        .map(|l| DiffLine {
                            text: l.into(),
                            kind: match l.chars().next() { Some('+') => "+", Some('-') => "-", Some('@') => "@", _ => " " }.into(),
                        })
                        .collect(),
                    Err(e) => vec![DiffLine { text: e.into(), kind: "-".into() }],
                };
                g.set_diff(ModelRc::new(VecModel::from(lines)));
            },
        );
    });
    let a = app.clone();
    g.on_restore_picked(move || {
        let (from, to) = *a.compare_span.borrow();
        let paths: Vec<String> = a.changes.borrow().iter().filter(|c| c.3).map(|c| c.0.clone()).collect();
        if paths.is_empty() {
            return;
        }
        let mut args = vec![s("-c"), a.config(), s("undochange"), format!("{from}..{to}")];
        args.extend(paths);
        a.ui().global::<Snapper>().set_busy(true);
        let b = a.clone();
        kit::spawn(
            // Files belong to root: straight to pkexec.
            move || snapper(&args, true),
            move |r| {
                let ui = b.ui();
                ui.global::<Snapper>().set_busy(false);
                match r {
                    Ok(_) => {
                        b.toast("Put back", false);
                        for c in b.changes.borrow_mut().iter_mut() {
                            c.3 = false;
                        }
                        b.show_changes();
                    }
                    Err(e) => b.toast(&e, true),
                }
            },
        );
    });

    // HYPRSHELL_SNAPSHOTS_COMPARE=row opens that row's comparison and its
    // fourth file (for screenshots and tests).
    let peek = slint::Timer::default();
    if let Some(i) = std::env::var("HYPRSHELL_SNAPSHOTS_COMPARE").ok().and_then(|v| v.parse::<i32>().ok()) {
        let w = ui.as_weak();
        peek.start(slint::TimerMode::SingleShot, Duration::from_millis(1200), move || {
            let Some(ui) = w.upgrade() else { return };
            ui.global::<Snapper>().invoke_compare(i);
            let w = ui.as_weak();
            slint::Timer::single_shot(Duration::from_millis(900), move || {
                if let Some(ui) = w.upgrade() {
                    ui.global::<Snapper>().invoke_toggle_change(0);
                    ui.global::<Snapper>().invoke_pick_change(3);
                }
            });
        });
    }

    // Hourly ones arrive while the window is open.
    let a = app.clone();
    let tick = slint::Timer::default();
    tick.start(slint::TimerMode::Repeated, Duration::from_secs(120), move || {
        let ui = a.ui();
        if !ui.global::<Snapper>().get_comparing() && !ui.global::<Snapper>().get_busy() {
            a.load();
        }
    });

    ui.run().expect("run");
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pairs() {
        let json = r#"{"root":[
            {"number":0,"type":"single","description":"current","date":"","user":"root","cleanup":""},
            {"number":1,"type":"single","description":"","date":"2025-01-02 10:00:00","user":"root","cleanup":"timeline"},
            {"number":2,"type":"pre","description":"pacman -Syu","date":"2025-01-02 11:00:00","user":"root","cleanup":"number"},
            {"number":3,"type":"post","pre-number":2,"description":"pacman -Syu","date":"2025-01-02 11:01:00","user":"root","cleanup":"number"}
        ]}"#;
        let raw = parse_list(json, "root");
        assert_eq!(raw.len(), 3);
        let (rows, spans) = rows(&raw);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].kind, "pair");
        assert_eq!(rows[0].title, "Update: pacman -Syu");
        assert_eq!(spans[0], (2, 3));
        assert_eq!(rows[1].title, "Hourly snapshot");
        assert_eq!(spans[1], (1, 0));
    }
    #[test]
    fn status_lines() {
        let s = parse_status("c..... /etc/fstab\n+..... /usr/bin/new\n-..... /old\n.p.... /etc/x\n");
        assert_eq!(s[0], ("/etc/fstab".into(), "~".into(), "contents".into()));
        assert_eq!(s[1].1, "+");
        assert_eq!(s[2].1, "-");
        assert_eq!(s[3].2, "permissions");
    }
}
