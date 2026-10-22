//! Calendar: by the month, the week or as a list.
//!
//!   Your calendars       .ics files in ~/.local/share/hyprshell-calendar,
//!                        yours in any other calendar program too
//!   Subscriptions        any calendar's .ics address (webcal:// too):
//!                        read every hour with curl, kept in
//!                        ~/.cache/hyprshell-calendar for when offline
//!   Invitations          the ones accepted in Mail, from its service
//!
//! Which calendars there are, their colours and what's shown are kept in
//! ~/.config/hyprshell-calendar/calendars.json. The next weeks' events are
//! written to ~/.local/share/hyprshell-calendar/upcoming.json for the
//! bar's calendar.

slint::include_modules!();

mod ics;

use chrono::{Datelike, Duration, Local, NaiveDate, NaiveDateTime, NaiveTime, TimeZone, Timelike, Utc, Weekday};
use hyprshell_kit as kit;
use ics::{Event, Freq, Occurrence, Rule, Time};
use slint::{Color, ComponentHandle, ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration as StdDuration;

const COLOURS: [&str; 8] = ["#ff563c", "#4c9cf0", "#4cc38a", "#f0b429", "#b67cf2", "#f06292", "#26c6da", "#a1887f"];
const MONTHS: [&str; 12] = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
const DAYS: [&str; 7] = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct CalendarConf {
    id: String,
    name: String,
    color: String,
    /// "local" or "url"
    kind: String,
    #[serde(default)]
    url: String,
    #[serde(default = "yes")]
    visible: bool,
}

fn yes() -> bool {
    true
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Conf {
    #[serde(default)]
    calendars: Vec<CalendarConf>,
    #[serde(default)]
    view: i32,
    #[serde(default = "yes")]
    mail_visible: bool,
}

impl Default for Conf {
    fn default() -> Self {
        Conf { calendars: Vec::new(), view: 0, mail_visible: true }
    }
}

fn conf_file() -> PathBuf {
    kit::config_dir().join("hyprshell-calendar/calendars.json")
}
fn data_dir() -> PathBuf {
    kit::data_dir().join("hyprshell-calendar")
}
fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from).filter(|p| p.is_absolute()).unwrap_or_else(|| kit::home().join(".cache")).join("hyprshell-calendar")
}
fn file_of(c: &CalendarConf) -> PathBuf {
    if c.kind == "url" { cache_dir().join(format!("{}.ics", c.id)) } else { data_dir().join(format!("{}.ics", c.id)) }
}

fn colour(hex: &str) -> Color {
    let h = hex.trim_start_matches('#');
    let v = u32::from_str_radix(h, 16).unwrap_or(0xff563c);
    Color::from_rgb_u8((v >> 16) as u8, (v >> 8) as u8, v as u8)
}

/// A name fit for a file: letters, digits and dashes.
fn slug(name: &str) -> String {
    let s: String = name.to_lowercase().chars().map(|c| if c.is_alphanumeric() { c } else { '-' }).collect();
    let s = s.trim_matches('-').to_string();
    if s.is_empty() { "calendar".into() } else { s }
}

fn new_uid() -> String {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    format!("{n:x}-{:x}@hyprshell", std::process::id())
}

/// One calendar, loaded.
struct Loaded {
    conf: CalendarConf,
    events: Vec<Event>,
    note: String,
}

/// One occurrence on screen, with where it came from.
#[derive(Clone)]
struct Item {
    cal: usize,
    ev: usize,
    occ: Occurrence,
}

struct App {
    ui: slint::Weak<AppWindow>,
    conf: Conf,
    cals: Vec<Loaded>,
    /// Mail's accepted invitations, as events of a calendar of their own.
    mail: Vec<Event>,
    selected: NaiveDate,
    /// The event open in the editor: (calendar, uid), or None for a new one.
    editing: Option<(usize, String)>,
    toast_seq: u64,
}

type Shared = Rc<RefCell<App>>;

const MAIL: usize = usize::MAX;

impl App {
    fn save_conf(&self) {
        let p = conf_file();
        let _ = std::fs::create_dir_all(p.parent().unwrap());
        if let Ok(t) = serde_json::to_string_pretty(&self.conf) {
            let _ = kit::write_atomic(&p, t.as_bytes());
        }
    }

    fn load_calendar(conf: &CalendarConf) -> Loaded {
        let text = std::fs::read_to_string(file_of(conf)).unwrap_or_default();
        let (_, events) = ics::parse(&text);
        Loaded { conf: conf.clone(), events, note: String::new() }
    }

    fn write_calendar(&self, i: usize) -> std::io::Result<()> {
        let c = &self.cals[i];
        let _ = std::fs::create_dir_all(data_dir());
        kit::write_atomic(&file_of(&c.conf), ics::write(&c.conf.name, &c.events).as_bytes())
    }

    fn event(&self, cal: usize, ev: usize) -> &Event {
        if cal == MAIL { &self.mail[ev] } else { &self.cals[cal].events[ev] }
    }

    fn colour_of(&self, cal: usize) -> Color {
        if cal == MAIL { colour("#8d9db6") } else { colour(&self.cals[cal].conf.color) }
    }

    /// Everything shown that overlaps [from, to), in order.
    fn items(&self, from: NaiveDate, to: NaiveDate) -> Vec<Item> {
        let mut out = Vec::new();
        for (ci, c) in self.cals.iter().enumerate() {
            if !c.conf.visible {
                continue;
            }
            for (ei, e) in c.events.iter().enumerate() {
                for occ in ics::occurrences(e, from, to) {
                    out.push(Item { cal: ci, ev: ei, occ });
                }
            }
        }
        if self.conf.mail_visible {
            for (ei, e) in self.mail.iter().enumerate() {
                for occ in ics::occurrences(e, from, to) {
                    out.push(Item { cal: MAIL, ev: ei, occ });
                }
            }
        }
        out.sort_by(|a, b| (!a.occ.all_day, a.occ.start).cmp(&(!b.occ.all_day, b.occ.start)));
        out
    }

    fn id_of(&self, it: &Item) -> String {
        format!("{}|{}", if it.cal == MAIL { "@mail".to_string() } else { it.cal.to_string() }, self.event(it.cal, it.ev).uid)
    }

    fn title_of(&self, it: &Item) -> String {
        let s = &self.event(it.cal, it.ev).summary;
        if s.is_empty() { "(No title)".into() } else { s.clone() }
    }

    fn show(&self) {
        let Some(ui) = self.ui.upgrade() else { return };
        let c = ui.global::<Cal>();
        let today = Local::now().date_naive();
        let sel = self.selected;
        c.set_view(self.conf.view);
        c.set_weekday_names(ModelRc::new(VecModel::from(DAYS.iter().map(|d| SharedString::from(&d[..3])).collect::<Vec<_>>())));

        // The calendars.
        let mut rows: Vec<CalRow> = self.cals.iter().map(|l| CalRow {
            id: l.conf.id.clone().into(),
            name: l.conf.name.clone().into(),
            color: colour(&l.conf.color),
            visible: l.conf.visible,
            kind: l.conf.kind.clone().into(),
            note: l.note.clone().into(),
        }).collect();
        if !self.mail.is_empty() {
            rows.push(CalRow { id: "@mail".into(), name: "Invitations".into(), color: self.colour_of(MAIL), visible: self.conf.mail_visible,
                               kind: "mail".into(), note: "Accepted in Mail".into() });
        }
        c.set_calendars(ModelRc::new(VecModel::from(rows)));

        let chip = |it: &Item| Chip {
            id: self.id_of(it).into(),
            title: self.title_of(it).into(),
            time: if it.occ.all_day { "".into() } else { hm(it.occ.start).into() },
            color: self.colour_of(it.cal),
            all_day: it.occ.all_day,
        };

        match self.conf.view {
            0 => {
                // Six weeks from the Monday on or before the 1st.
                let first = NaiveDate::from_ymd_opt(sel.year(), sel.month(), 1).unwrap();
                let start = first - Duration::days(first.weekday().num_days_from_monday() as i64);
                let items = self.items(start, start + Duration::days(42));
                let cells: Vec<MonthCell> = (0..42).map(|i| {
                    let d = start + Duration::days(i);
                    let on: Vec<&Item> = items.iter().filter(|it| touches(it, d)).collect();
                    MonthCell {
                        iso: d.to_string().into(),
                        day: d.day().to_string().into(),
                        in_month: d.month() == sel.month(),
                        today: d == today,
                        selected: d == sel,
                        chips: ModelRc::new(VecModel::from(on.iter().take(3).map(|it| chip(it)).collect::<Vec<_>>())),
                        more: on.len().saturating_sub(3) as i32,
                    }
                }).collect();
                c.set_cells(ModelRc::new(VecModel::from(cells)));
                c.set_heading(format!("{} {}", MONTHS[sel.month0() as usize], sel.year()).into());
            }
            1 => {
                let monday = sel - Duration::days(sel.weekday().num_days_from_monday() as i64);
                let items = self.items(monday, monday + Duration::days(7));
                let week: Vec<WeekDay> = (0..7).map(|i| {
                    let d = monday + Duration::days(i);
                    WeekDay {
                        iso: d.to_string().into(),
                        name: DAYS[i as usize][..3].to_uppercase().into(),
                        day: d.day().to_string().into(),
                        today: d == today,
                        selected: d == sel,
                        all_day: ModelRc::new(VecModel::from(items.iter().filter(|it| it.occ.all_day && touches(it, d)).map(|it| chip(it)).collect::<Vec<_>>())),
                    }
                }).collect();
                c.set_week(ModelRc::new(VecModel::from(week)));
                c.set_blocks(ModelRc::new(VecModel::from(self.blocks(&items, monday))));
                let now = Local::now().naive_local();
                let off = (now.date() - monday).num_days();
                c.set_now_day(if (0..7).contains(&off) { off as i32 } else { -1 });
                c.set_now_minutes((now.hour() * 60 + now.minute()) as f32);
                let sunday = monday + Duration::days(6);
                c.set_heading(if monday.month() == sunday.month() {
                    format!("{} – {} {} {}", monday.day(), sunday.day(), &MONTHS[monday.month0() as usize][..3], monday.year())
                } else {
                    format!("{} {} – {} {} {}", monday.day(), &MONTHS[monday.month0() as usize][..3], sunday.day(), &MONTHS[sunday.month0() as usize][..3], sunday.year())
                }.into());
            }
            _ => {
                let items = self.items(sel, sel + Duration::days(56));
                let mut rows = Vec::new();
                let mut last = None;
                for it in &items {
                    let day = it.occ.start.date().max(sel);
                    if last != Some(day) {
                        rows.push(AgendaRow { header: true, label: day_name(day, today).into(), ..Default::default() });
                        last = Some(day);
                    }
                    rows.push(self.agenda_row(it));
                }
                c.set_agenda(ModelRc::new(VecModel::from(rows)));
                c.set_heading(format!("From {}", day_name(sel, today)).into());
            }
        }

        // The chosen day, down the side.
        c.set_day_heading(day_name(sel, today).to_uppercase().into());
        let day_rows: Vec<AgendaRow> = self.items(sel, sel + Duration::days(1)).iter().map(|it| self.agenda_row(it)).collect();
        c.set_day_events(ModelRc::new(VecModel::from(day_rows)));
    }

    fn agenda_row(&self, it: &Item) -> AgendaRow {
        let ev = self.event(it.cal, it.ev);
        AgendaRow {
            header: false,
            label: "".into(),
            id: self.id_of(it).into(),
            title: self.title_of(it).into(),
            time: if it.occ.all_day { "All day".into() } else if it.occ.end > it.occ.start {
                format!("{} – {}", hm(it.occ.start), hm(it.occ.end)).into()
            } else {
                hm(it.occ.start).into()
            },
            place: ev.location.clone().into(),
            color: self.colour_of(it.cal),
        }
    }

    /// The week's timed events, each in its day, side by side where they
    /// overlap.
    fn blocks(&self, items: &[Item], monday: NaiveDate) -> Vec<Block> {
        let mut out = Vec::new();
        for day in 0..7 {
            let d = monday + Duration::days(day);
            let day_start = d.and_time(NaiveTime::MIN);
            let day_end = day_start + Duration::days(1);
            // This day's part of each timed event.
            let mut parts: Vec<(f32, f32, &Item)> = items.iter()
                .filter(|it| !it.occ.all_day && it.occ.start < day_end && (it.occ.end > day_start || (it.occ.end == it.occ.start && it.occ.start >= day_start)))
                .map(|it| {
                    let s = it.occ.start.max(day_start);
                    let e = it.occ.end.min(day_end).max(s + Duration::minutes(30));
                    ((s - day_start).num_minutes() as f32, (e - s).num_minutes() as f32, it)
                })
                .collect();
            parts.sort_by(|a, b| a.0.total_cmp(&b.0));
            // Groups that overlap, each laid out in columns.
            let mut i = 0;
            while i < parts.len() {
                let mut end = parts[i].0 + parts[i].1;
                let mut j = i + 1;
                while j < parts.len() && parts[j].0 < end {
                    end = end.max(parts[j].0 + parts[j].1);
                    j += 1;
                }
                let mut cols: Vec<f32> = Vec::new();
                let mut placed = Vec::new();
                for p in &parts[i..j] {
                    let col = cols.iter().position(|free| *free <= p.0).unwrap_or_else(|| { cols.push(0.0); cols.len() - 1 });
                    cols[col] = p.0 + p.1;
                    placed.push((col, p));
                }
                for (col, (from, length, it)) in placed {
                    out.push(Block {
                        id: self.id_of(it).into(),
                        day: day as i32,
                        from: *from,
                        length: *length,
                        col: col as i32,
                        cols: cols.len() as i32,
                        title: self.title_of(it).into(),
                        time: format!("{} – {}", hm(it.occ.start), hm(it.occ.end)).into(),
                        color: self.colour_of(it.cal),
                    });
                }
                i = j;
            }
        }
        out
    }

    /// The next weeks' events, for the bar's calendar.
    fn export(&self) {
        let today = Local::now().date_naive();
        let items = self.items(today - Duration::days(40), today + Duration::days(400));
        let list: Vec<serde_json::Value> = items.iter().map(|it| {
            let ev = self.event(it.cal, it.ev);
            let epoch = |t: NaiveDateTime| Local.from_local_datetime(&t).earliest().map(|x| x.timestamp()).unwrap_or(0);
            serde_json::json!({
                "uid": ev.uid, "summary": self.title_of(it), "location": ev.location,
                "start": epoch(it.occ.start), "end": epoch(it.occ.end.max(it.occ.start)),
                "allDay": it.occ.all_day, "calendar": if it.cal == MAIL { "Invitations".to_string() } else { self.cals[it.cal].conf.name.clone() },
                "color": if it.cal == MAIL { "#8d9db6".to_string() } else { self.cals[it.cal].conf.color.clone() },
            })
        }).collect();
        let _ = std::fs::create_dir_all(data_dir());
        let _ = kit::write_atomic(&data_dir().join("upcoming.json"), serde_json::Value::Array(list).to_string().as_bytes());
    }

    fn toast(app: &Shared, text: &str) {
        let seq = { let mut a = app.borrow_mut(); a.toast_seq += 1; a.toast_seq };
        if let Some(ui) = app.borrow().ui.upgrade() {
            ui.global::<Cal>().set_toast(text.into());
        }
        let app = app.clone();
        slint::Timer::single_shot(StdDuration::from_secs(3), move || {
            if app.borrow().toast_seq == seq {
                if let Some(ui) = app.borrow().ui.upgrade() { ui.global::<Cal>().set_toast("".into()); }
            }
        });
    }
}

fn hm(t: NaiveDateTime) -> String {
    format!("{:02}:{:02}", t.hour(), t.minute())
}

fn day_name(d: NaiveDate, today: NaiveDate) -> String {
    let base = format!("{} {} {}", DAYS[d.weekday().num_days_from_monday() as usize], d.day(), MONTHS[d.month0() as usize]);
    if d == today {
        format!("Today, {base}")
    } else if d == today + Duration::days(1) {
        format!("Tomorrow, {base}")
    } else if d.year() != today.year() {
        format!("{base} {}", d.year())
    } else {
        base
    }
}

/// Whether an occurrence is on a day: it starts that day, or runs into it.
fn touches(it: &Item, d: NaiveDate) -> bool {
    let start = d.and_time(NaiveTime::MIN);
    let end = start + Duration::days(1);
    if it.occ.end <= it.occ.start {
        return it.occ.start >= start && it.occ.start < end;
    }
    it.occ.start < end && it.occ.end > start
}

// ── subscriptions and Mail ───────────────────────────────────────────────

fn fetch(url: &str) -> Result<String, String> {
    let url = url.trim().replacen("webcal://", "https://", 1);
    let out = std::process::Command::new("curl")
        .args(["-fsSL", "--max-time", "30", &url])
        .output()
        .map_err(|e| format!("curl isn't available ({e})"))?;
    if !out.status.success() {
        return Err("Couldn't be read just now".into());
    }
    let text = String::from_utf8_lossy(&out.stdout).to_string();
    if !text.contains("BEGIN:VCALENDAR") {
        return Err("Not a calendar".into());
    }
    Ok(text)
}

fn refresh_subscription(app: &Shared, i: usize) {
    let conf = app.borrow().cals[i].conf.clone();
    let app = app.clone();
    kit::spawn(move || fetch(&conf.url).map(|t| (conf, t)), move |result| {
        let mut a = app.borrow_mut();
        match result {
            Ok((conf, text)) => {
                let _ = std::fs::create_dir_all(cache_dir());
                let _ = kit::write_atomic(&file_of(&conf), text.as_bytes());
                if let Some(c) = a.cals.iter_mut().find(|c| c.conf.id == conf.id) {
                    c.events = ics::parse(&text).1;
                    c.note.clear();
                }
            }
            Err(e) => {
                if let Some(c) = a.cals.get_mut(i) {
                    c.note = e;
                }
            }
        }
        a.show();
        a.export();
    });
}

/// Mail's accepted invitations, from its service, if it's running.
fn mail_events() -> Vec<Event> {
    use std::io::{BufRead, BufReader, Write};
    let path = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into()).join("hyprshell-mail.sock");
    let Ok(mut s) = std::os::unix::net::UnixStream::connect(path) else { return Vec::new() };
    let _ = s.set_read_timeout(Some(StdDuration::from_secs(5)));
    let now = kit::now();
    let req = serde_json::json!({ "cmd": "events.list", "rid": 1, "from": now - 60 * 86400, "to": now + 400 * 86400 });
    if s.write_all(format!("{req}\n").as_bytes()).is_err() {
        return Vec::new();
    }
    let mut reader = BufReader::new(s);
    let mut line = String::new();
    // Its answer, among any events it sends unasked.
    for _ in 0..20 {
        line.clear();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            break;
        }
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&line) else { continue };
        if v["rid"].as_i64() != Some(1) {
            continue;
        }
        return v["result"].as_array().map(|a| a.iter().filter_map(|e| {
            let start = e["start"].as_i64()?;
            let end = e["end"].as_i64().unwrap_or(start);
            let all_day = e["allDay"].as_bool().unwrap_or(false);
            let at = |s: i64| Utc.timestamp_opt(s, 0).single();
            let (start, end) = if all_day {
                let d = |s: i64| at(s).map(|t| Time::Day(t.with_timezone(&Local).date_naive()));
                (d(start)?, d(end)?)
            } else {
                (Time::At(at(start)?), Time::At(at(end)?))
            };
            Some(Event {
                uid: e["uid"].as_str()?.to_string(),
                summary: e["summary"].as_str().unwrap_or("").to_string(),
                location: e["location"].as_str().unwrap_or("").to_string(),
                start: Some(start),
                end: Some(end),
                ..Default::default()
            })
        }).collect()).unwrap_or_default();
    }
    Vec::new()
}

fn refresh_mail(app: &Shared) {
    let app = app.clone();
    kit::spawn(mail_events, move |events| {
        let mut a = app.borrow_mut();
        a.mail = events;
        a.show();
        a.export();
    });
}

// ── the editor ───────────────────────────────────────────────────────────

fn writable(app: &App) -> Vec<usize> {
    app.cals.iter().enumerate().filter(|(_, c)| c.conf.kind == "local").map(|(i, _)| i).collect()
}

fn open_editor(app: &Shared, ev: Option<(usize, usize)>, date: NaiveDate, hour: i32) {
    let mut a = app.borrow_mut();
    let Some(ui) = a.ui.upgrade() else { return };
    let c = ui.global::<Cal>();
    let cals = writable(&a);
    c.set_ed_calendars(ModelRc::new(VecModel::from(cals.iter().map(|i| SharedString::from(a.cals[*i].conf.name.clone())).collect::<Vec<_>>())));
    c.set_ed_error("".into());
    match ev {
        None => {
            a.editing = None;
            let (start, end) = if hour >= 0 {
                let s = date.and_hms_opt(hour as u32, 0, 0).unwrap();
                (s, s + Duration::hours(1))
            } else {
                let now = Local::now().naive_local();
                let s = date.and_hms_opt((now.hour() + 1).min(23), 0, 0).unwrap();
                (s, s + Duration::hours(1))
            };
            c.set_ed_new(true);
            c.set_ed_read_only(cals.is_empty());
            c.set_ed_calendar_name("".into());
            c.set_ed_calendar(0);
            c.set_ed_title("".into());
            c.set_ed_all_day(false);
            c.set_ed_date(start.date().to_string().into());
            c.set_ed_start(hm(start).into());
            c.set_ed_end_date(end.date().to_string().into());
            c.set_ed_end(hm(end).into());
            c.set_ed_location("".into());
            c.set_ed_notes("".into());
            c.set_ed_repeat(0);
        }
        Some((cal, i)) => {
            let e = a.event(cal, i).clone();
            let read_only = cal == MAIL || a.cals[cal].conf.kind != "local";
            a.editing = Some((cal, e.uid.clone()));
            let all_day = e.all_day();
            let s = e.start.as_ref().map(|t| t.local()).unwrap_or_default();
            // An all-day event's DTEND is the day after its last.
            let mut end = s + e.length();
            if all_day && end > s {
                end -= Duration::days(1);
            }
            c.set_ed_new(false);
            c.set_ed_read_only(read_only);
            c.set_ed_calendar_name(if cal == MAIL { "Invitations".into() } else { a.cals[cal].conf.name.clone().into() });
            c.set_ed_calendar(cals.iter().position(|x| *x == cal).unwrap_or(0) as i32);
            c.set_ed_title(e.summary.clone().into());
            c.set_ed_all_day(all_day);
            c.set_ed_date(s.date().to_string().into());
            c.set_ed_start(hm(s).into());
            c.set_ed_end_date(end.date().to_string().into());
            c.set_ed_end(hm(end).into());
            c.set_ed_location(e.location.clone().into());
            c.set_ed_notes(e.notes.clone().into());
            c.set_ed_repeat(match e.rule.as_ref().map(|r| r.freq) {
                None => 0,
                Some(Freq::Daily) => 1,
                Some(Freq::Weekly) => 2,
                Some(Freq::Monthly) => 3,
                Some(Freq::Yearly) => 4,
            });
        }
    }
    c.set_editing(true);
}

fn parse_hm(s: &str) -> Option<NaiveTime> {
    let s = s.trim();
    NaiveTime::parse_from_str(s, "%H:%M").or_else(|_| NaiveTime::parse_from_str(s, "%H.%M")).ok()
        .or_else(|| s.parse::<u32>().ok().and_then(|h| NaiveTime::from_hms_opt(h, 0, 0)))
}

fn save_editor(app: &Shared) -> Result<String, String> {
    let ui = app.borrow().ui.upgrade().ok_or("")?;
    let c = ui.global::<Cal>();
    let date = NaiveDate::parse_from_str(c.get_ed_date().trim(), "%Y-%m-%d").map_err(|_| "The date is year-month-day: 2026-10-22")?;
    let end_date = NaiveDate::parse_from_str(c.get_ed_end_date().trim(), "%Y-%m-%d").unwrap_or(date);
    let all_day = c.get_ed_all_day();
    let to_utc = |t: NaiveDateTime| Local.from_local_datetime(&t).earliest().map(|x| x.with_timezone(&Utc)).ok_or("That time doesn't exist here (the clocks change)");
    let (start, end) = if all_day {
        if end_date < date {
            return Err("It ends before it starts".into());
        }
        (Time::Day(date), Time::Day(end_date + Duration::days(1)))
    } else {
        let s = date.and_time(parse_hm(&c.get_ed_start()).ok_or("The start is hours and minutes: 14:00")?);
        let e = end_date.and_time(parse_hm(&c.get_ed_end()).ok_or("The end is hours and minutes: 15:00")?);
        if e < s {
            return Err("It ends before it starts".into());
        }
        (Time::At(to_utc(s)?), Time::At(to_utc(e)?))
    };
    let mut a = app.borrow_mut();
    let cals = writable(&a);
    let target = *cals.get(c.get_ed_calendar().max(0) as usize).or(cals.first()).ok_or("There's no calendar of your own to put it in")?;
    let rule = match c.get_ed_repeat() {
        1 => Some(Freq::Daily),
        2 => Some(Freq::Weekly),
        3 => Some(Freq::Monthly),
        4 => Some(Freq::Yearly),
        _ => None,
    };
    // The event as it was, from the calendar it was in.
    let mut ev = Event::default();
    if let Some((cal, uid)) = a.editing.clone() {
        if cal != MAIL {
            if let Some(i) = a.cals[cal].events.iter().position(|e| e.uid == uid) {
                ev = a.cals[cal].events.remove(i);
                if cal != target {
                    a.write_calendar(cal).map_err(|e| e.to_string())?;
                }
            }
        }
    }
    if ev.uid.is_empty() {
        ev.uid = new_uid();
    }
    ev.summary = c.get_ed_title().trim().to_string();
    ev.location = c.get_ed_location().trim().to_string();
    ev.notes = c.get_ed_notes().to_string();
    ev.start = Some(start);
    ev.end = Some(end);
    // Its rule kept if the repeat is the same kind (its interval, its days).
    ev.rule = match (rule, ev.rule.take()) {
        (Some(f), Some(old)) if old.freq == f => Some(old),
        (Some(f), _) => Some(Rule { freq: f, interval: 1, count: None, until: None, by_day: Vec::new() }),
        (None, _) => None,
    };
    if ev.rule.is_none() {
        ev.except.clear();
    }
    let title = if ev.summary.is_empty() { "Event".to_string() } else { ev.summary.clone() };
    a.cals[target].events.push(ev);
    a.write_calendar(target).map_err(|e| e.to_string())?;
    a.selected = date;
    Ok(title)
}

// ── starting ─────────────────────────────────────────────────────────────

fn main() {
    kit::init("hyprshell-calendar");
    let mut conf: Conf = match std::fs::read_to_string(conf_file()) {
        Ok(t) => serde_json::from_str(&t).unwrap_or_else(|e| {
            // Keep a file we can't read rather than overwrite it.
            eprintln!("calendars.json: {e}; keeping it as calendars.json.bad");
            let _ = std::fs::rename(conf_file(), conf_file().with_extension("json.bad"));
            Conf::default()
        }),
        Err(_) => Conf::default(),
    };
    if conf.calendars.is_empty() {
        conf.calendars.push(CalendarConf { id: "personal".into(), name: "Personal".into(), color: COLOURS[0].into(), kind: "local".into(), url: String::new(), visible: true });
    }
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-calendar");
    let cals = conf.calendars.iter().map(App::load_calendar).collect();
    let app: Shared = Rc::new(RefCell::new(App {
        ui: ui.as_weak(),
        conf,
        cals,
        mail: Vec::new(),
        selected: Local::now().date_naive(),
        editing: None,
        toast_seq: 0,
    }));
    app.borrow().save_conf();
    app.borrow().show();
    app.borrow().export();

    let c = ui.global::<Cal>();
    let step = |app: &Shared, dir: i64| {
        let mut a = app.borrow_mut();
        a.selected = match a.conf.view {
            0 => {
                let d = a.selected;
                let total = d.year() * 12 + d.month0() as i32 + dir as i32;
                NaiveDate::from_ymd_opt(total.div_euclid(12), total.rem_euclid(12) as u32 + 1, 1).unwrap_or(d)
            }
            1 => a.selected + Duration::days(7 * dir),
            _ => a.selected + Duration::days(28 * dir),
        };
        a.show();
    };
    { let app = app.clone(); c.on_prev(move || step(&app, -1)); }
    { let app = app.clone(); c.on_next(move || step(&app, 1)); }
    { let app = app.clone(); c.on_today(move || { app.borrow_mut().selected = Local::now().date_naive(); app.borrow().show(); }); }
    {
        let app = app.clone();
        c.on_set_view(move |v| {
            app.borrow_mut().conf.view = v.clamp(0, 2);
            app.borrow().save_conf();
            app.borrow().show();
        });
    }
    {
        let app = app.clone();
        c.on_pick(move |iso| {
            if let Ok(d) = NaiveDate::parse_from_str(&iso, "%Y-%m-%d") {
                app.borrow_mut().selected = d;
                app.borrow().show();
            }
        });
    }
    {
        let app = app.clone();
        c.on_new_event(move |iso, hour| {
            let date = NaiveDate::parse_from_str(&iso, "%Y-%m-%d").unwrap_or(app.borrow().selected);
            open_editor(&app, None, date, hour);
        });
    }
    {
        let app = app.clone();
        c.on_open_event(move |id| {
            let Some((cal, uid)) = id.split_once('|') else { return };
            let found = {
                let a = app.borrow();
                if cal == "@mail" {
                    a.mail.iter().position(|e| e.uid == uid).map(|i| (MAIL, i))
                } else {
                    cal.parse::<usize>().ok().and_then(|ci| a.cals.get(ci)?.events.iter().position(|e| e.uid == uid).map(|i| (ci, i)))
                }
            };
            if let Some((ci, i)) = found {
                let date = app.borrow().selected;
                open_editor(&app, Some((ci, i)), date, -1);
            }
        });
    }
    {
        let app = app.clone();
        c.on_save_event(move || match save_editor(&app) {
            Ok(title) => {
                if let Some(ui) = app.borrow().ui.upgrade() { ui.global::<Cal>().set_editing(false); }
                app.borrow().show();
                app.borrow().export();
                App::toast(&app, &format!("{title} saved"));
            }
            Err(e) => {
                if let Some(ui) = app.borrow().ui.upgrade() { ui.global::<Cal>().set_ed_error(e.into()); }
            }
        });
    }
    {
        let app = app.clone();
        c.on_delete_event(move || {
            let done = {
                let mut a = app.borrow_mut();
                match a.editing.clone() {
                    Some((cal, uid)) if cal != MAIL => {
                        a.cals[cal].events.retain(|e| e.uid != uid);
                        a.write_calendar(cal).is_ok()
                    }
                    _ => false,
                }
            };
            if let Some(ui) = app.borrow().ui.upgrade() { ui.global::<Cal>().set_editing(false); }
            app.borrow().show();
            app.borrow().export();
            if done { App::toast(&app, "Deleted"); }
        });
    }
    {
        let app = app.clone();
        c.on_toggle_calendar(move |id| {
            {
                let mut a = app.borrow_mut();
                if id == "@mail" {
                    a.conf.mail_visible = !a.conf.mail_visible;
                } else if let Some(i) = a.cals.iter().position(|c| c.conf.id == id.as_str()) {
                    let v = !a.cals[i].conf.visible;
                    a.cals[i].conf.visible = v;
                    a.conf.calendars[i].visible = v;
                }
                a.save_conf();
            }
            app.borrow().show();
        });
    }
    let add = |app: &Shared, name: &str, url: &str| -> Option<usize> {
        let name = name.trim();
        if name.is_empty() && url.is_empty() {
            return None;
        }
        let mut a = app.borrow_mut();
        let base = slug(if name.is_empty() { "subscription" } else { name });
        let mut id = base.clone();
        let mut n = 2;
        while a.conf.calendars.iter().any(|c| c.id == id) {
            id = format!("{base}-{n}");
            n += 1;
        }
        let used = a.conf.calendars.len();
        let conf = CalendarConf {
            id,
            name: if name.is_empty() { "Subscription".into() } else { name.into() },
            color: COLOURS[used % COLOURS.len()].into(),
            kind: if url.is_empty() { "local".into() } else { "url".into() },
            url: url.trim().into(),
            visible: true,
        };
        a.conf.calendars.push(conf.clone());
        a.cals.push(Loaded { conf, events: Vec::new(), note: if url.is_empty() { String::new() } else { "Reading…".into() } });
        let i = a.cals.len() - 1;
        if url.is_empty() {
            let _ = a.write_calendar(i);
        }
        a.save_conf();
        a.show();
        Some(i)
    };
    {
        let app = app.clone();
        c.on_add_calendar(move |name| { add(&app, &name, ""); });
    }
    {
        let app = app.clone();
        c.on_subscribe(move |name, url| {
            let url = url.trim().to_string();
            if !(url.starts_with("https://") || url.starts_with("http://") || url.starts_with("webcal://")) {
                App::toast(&app, "An address starting https:// or webcal://");
                return;
            }
            if let Some(i) = add(&app, &name, &url) {
                refresh_subscription(&app, i);
            }
        });
    }
    {
        let app = app.clone();
        c.on_remove_calendar(move |id| {
            let name = {
                let mut a = app.borrow_mut();
                let Some(i) = a.cals.iter().position(|c| c.conf.id == id.as_str()) else { return };
                let gone = a.cals.remove(i);
                a.conf.calendars.remove(i);
                a.save_conf();
                let file = file_of(&gone.conf);
                if gone.conf.kind == "local" {
                    if file.exists() { let _ = kit::trash(&file); }
                } else {
                    let _ = std::fs::remove_file(&file);
                }
                gone.conf.name
            };
            app.borrow().show();
            app.borrow().export();
            App::toast(&app, &format!("{name} removed"));
        });
    }

    // Subscriptions every hour, Mail's invitations every few minutes.
    let subs: Vec<usize> = app.borrow().cals.iter().enumerate().filter(|(_, c)| c.conf.kind == "url").map(|(i, _)| i).collect();
    for i in subs {
        refresh_subscription(&app, i);
    }
    refresh_mail(&app);
    let hourly = slint::Timer::default();
    {
        let app = app.clone();
        hourly.start(slint::TimerMode::Repeated, StdDuration::from_secs(3600), move || {
            let subs: Vec<usize> = app.borrow().cals.iter().enumerate().filter(|(_, c)| c.conf.kind == "url").map(|(i, _)| i).collect();
            for i in subs {
                refresh_subscription(&app, i);
            }
        });
    }
    let often = slint::Timer::default();
    {
        let app = app.clone();
        often.start(slint::TimerMode::Repeated, StdDuration::from_secs(300), move || refresh_mail(&app));
    }
    // The red line moves, and "today" changes at midnight.
    let minute = slint::Timer::default();
    {
        let app = app.clone();
        minute.start(slint::TimerMode::Repeated, StdDuration::from_secs(60), move || app.borrow().show());
    }

    ui.run().expect("run");
    let _ = Weekday::Mon;
}
