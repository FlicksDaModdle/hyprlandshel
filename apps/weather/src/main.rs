//! Weather: the places you keep, the weather now, the next 24 hours and
//! ten days ahead, in the shell's look.
//!
//! Forecasts and place names come from Open-Meteo (open-meteo.com, free,
//! no account or key; CC BY 4.0, credited in the window). They're fetched
//! with curl, off the UI thread, and the last one for each place is kept in
//! ~/.cache/hyprshell-weather, so the window opens on it at once, and
//! without a connection. Places and units are kept in
//! ~/.config/hyprshell-weather/places.json.
//!
//! Nothing finds where you are by itself: you add the places you want.

slint::include_modules!();

use hyprshell_kit as kit;
use serde_json::Value;
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct Place {
    name: String,
    region: String,
    lat: f64,
    lon: f64,
}

impl Place {
    /// Stable, for the cache's file name and the list: its position.
    fn id(&self) -> String {
        format!("{:.3},{:.3}", self.lat, self.lon)
    }
}

#[derive(Default, serde::Serialize, serde::Deserialize)]
struct Saved {
    #[serde(default)]
    places: Vec<Place>,
    #[serde(default)]
    current: String,
    #[serde(default)]
    units: i32,
}

fn saved_file() -> PathBuf {
    kit::config_dir().join("hyprshell-weather/places.json")
}

fn cache_dir() -> PathBuf {
    std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| kit::home().join(".cache"))
        .join("hyprshell-weather")
}

// ── fetching ─────────────────────────────────────────────────────────────

/// GET through curl: what Arch always has, with the system's certificates
/// and proxy settings.
fn get(url: &str) -> Result<String, String> {
    let out = std::process::Command::new("curl")
        .args(["-fsSL", "--max-time", "15", "--retry", "1", "-H", "Accept: application/json", url])
        .output()
        .map_err(|e| format!("curl isn't available ({e})"))?;
    if !out.status.success() {
        let why = String::from_utf8_lossy(&out.stderr).trim().to_string();
        return Err(if why.contains("resolve") || why.contains("connect") {
            "No connection".into()
        } else if why.is_empty() {
            "Couldn't reach Open-Meteo".into()
        } else {
            format!("Couldn't reach Open-Meteo ({})", why.trim_start_matches("curl: "))
        });
    }
    String::from_utf8(out.stdout).map_err(|_| "An answer that wasn't text".into())
}

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") })
        .collect()
}

fn forecast_url(p: &Place) -> String {
    format!(
        "https://api.open-meteo.com/v1/forecast?latitude={:.4}&longitude={:.4}&timezone=auto&forecast_days=10\
         &current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,precipitation,\
cloud_cover,pressure_msl,wind_speed_10m,wind_direction_10m,wind_gusts_10m,dew_point_2m\
         &hourly=temperature_2m,weather_code,precipitation_probability,is_day,visibility,uv_index\
         &daily=weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset,precipitation_probability_max,\
precipitation_sum,uv_index_max",
        p.lat, p.lon
    )
    .replace(' ', "")
}

/// Places by name, for Add a place.
fn search(query: &str) -> Result<Vec<Place>, String> {
    let url = format!("https://geocoding-api.open-meteo.com/v1/search?name={}&count=8&language=en&format=json", encode(query));
    let v: Value = serde_json::from_str(&get(&url)?).map_err(|_| "An answer that couldn't be read".to_string())?;
    Ok(parse_places(&v))
}

fn parse_places(v: &Value) -> Vec<Place> {
    v["results"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|r| {
                    let name = r["name"].as_str()?.to_string();
                    let region = [r["admin1"].as_str(), r["country"].as_str()]
                        .into_iter()
                        .flatten()
                        .filter(|s| !s.is_empty() && *s != name)
                        .collect::<Vec<_>>()
                        .join(", ");
                    Some(Place { name, region, lat: r["latitude"].as_f64()?, lon: r["longitude"].as_f64()? })
                })
                .collect()
        })
        .unwrap_or_default()
}

// ── the forecast, read ───────────────────────────────────────────────────

#[derive(Clone, Default)]
struct Now {
    time: String,
    temp: f64,
    feels: f64,
    humidity: f64,
    dew: f64,
    code: i64,
    day: bool,
    precip: f64,
    cloud: f64,
    pressure: f64,
    wind: f64,
    wind_dir: f64,
    gusts: f64,
}

#[derive(Clone, Default)]
struct HourF {
    time: String,
    temp: f64,
    code: i64,
    rain: Option<f64>,
    day: bool,
    visibility: Option<f64>,
    uv: Option<f64>,
}

#[derive(Clone, Default)]
struct DayF {
    date: String,
    code: i64,
    high: f64,
    low: f64,
    sunrise: String,
    sunset: String,
    rain: Option<f64>,
    precip: f64,
    uv: f64,
}

#[derive(Clone, Default)]
struct Forecast {
    now: Now,
    hours: Vec<HourF>,
    days: Vec<DayF>,
    fetched: i64,
}

fn parse_forecast(v: &Value) -> Option<Forecast> {
    let c = &v["current"];
    let f = |x: &Value| x.as_f64().unwrap_or(0.0);
    let now = Now {
        time: c["time"].as_str()?.to_string(),
        temp: c["temperature_2m"].as_f64()?,
        feels: f(&c["apparent_temperature"]),
        humidity: f(&c["relative_humidity_2m"]),
        dew: f(&c["dew_point_2m"]),
        code: c["weather_code"].as_i64().unwrap_or(0),
        day: c["is_day"].as_i64().unwrap_or(1) == 1,
        precip: f(&c["precipitation"]),
        cloud: f(&c["cloud_cover"]),
        pressure: f(&c["pressure_msl"]),
        wind: f(&c["wind_speed_10m"]),
        wind_dir: f(&c["wind_direction_10m"]),
        gusts: f(&c["wind_gusts_10m"]),
    };
    let arr = |o: &Value, k: &str| o[k].as_array().cloned().unwrap_or_default();
    let h = &v["hourly"];
    let (ht, htemp, hcode, hrain, hday, hvis, huv) = (
        arr(h, "time"), arr(h, "temperature_2m"), arr(h, "weather_code"), arr(h, "precipitation_probability"),
        arr(h, "is_day"), arr(h, "visibility"), arr(h, "uv_index"),
    );
    let hours = ht
        .iter()
        .enumerate()
        .filter_map(|(i, t)| {
            Some(HourF {
                time: t.as_str()?.to_string(),
                temp: htemp.get(i)?.as_f64()?,
                code: hcode.get(i).and_then(|x| x.as_i64()).unwrap_or(0),
                rain: hrain.get(i).and_then(|x| x.as_f64()),
                day: hday.get(i).and_then(|x| x.as_i64()).unwrap_or(1) == 1,
                visibility: hvis.get(i).and_then(|x| x.as_f64()),
                uv: huv.get(i).and_then(|x| x.as_f64()),
            })
        })
        .collect();
    let d = &v["daily"];
    let (dt, dcode, dhi, dlo, drise, dset, drain, dsum, duv) = (
        arr(d, "time"), arr(d, "weather_code"), arr(d, "temperature_2m_max"), arr(d, "temperature_2m_min"),
        arr(d, "sunrise"), arr(d, "sunset"), arr(d, "precipitation_probability_max"), arr(d, "precipitation_sum"),
        arr(d, "uv_index_max"),
    );
    let days = dt
        .iter()
        .enumerate()
        .filter_map(|(i, t)| {
            let s = |a: &Vec<Value>| a.get(i).and_then(|x| x.as_str()).unwrap_or("").to_string();
            Some(DayF {
                date: t.as_str()?.to_string(),
                code: dcode.get(i).and_then(|x| x.as_i64()).unwrap_or(0),
                high: dhi.get(i)?.as_f64()?,
                low: dlo.get(i)?.as_f64()?,
                sunrise: s(&drise),
                sunset: s(&dset),
                rain: drain.get(i).and_then(|x| x.as_f64()),
                precip: dsum.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0),
                uv: duv.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0),
            })
        })
        .collect();
    Some(Forecast { now, hours, days, fetched: 0 })
}

/// WMO weather codes, as Open-Meteo gives them: a glyph and a few words.
fn condition(code: i64, day: bool) -> (&'static str, &'static str) {
    match code {
        0 => (if day { "sun" } else { "moon" }, if day { "Sunny" } else { "Clear" }),
        1 => (if day { "cloudSun" } else { "cloudMoon" }, "Mostly clear"),
        2 => (if day { "cloudSun" } else { "cloudMoon" }, "Partly cloudy"),
        3 => ("cloud", "Cloudy"),
        45 | 48 => ("fog", "Fog"),
        51 | 53 | 55 => ("drizzle", "Drizzle"),
        56 | 57 => ("drizzle", "Freezing drizzle"),
        61 => ("rain", "Light rain"),
        63 => ("rain", "Rain"),
        65 => ("rain", "Heavy rain"),
        66 | 67 => ("rain", "Freezing rain"),
        71 => ("snow", "Light snow"),
        73 => ("snow", "Snow"),
        75 => ("snow", "Heavy snow"),
        77 => ("snow", "Snow grains"),
        80 => ("rain", "Showers"),
        81 => ("rain", "Heavy showers"),
        82 => ("rain", "Violent showers"),
        85 | 86 => ("snow", "Snow showers"),
        95 => ("storm", "Thunderstorm"),
        96 | 99 => ("storm", "Thunderstorm with hail"),
        _ => ("cloud", "—"),
    }
}

// ── units and words ──────────────────────────────────────────────────────

fn temp(c: f64, units: i32) -> String {
    let v = if units == 1 { c * 9.0 / 5.0 + 32.0 } else { c };
    format!("{}°", v.round() as i64)
}

fn speed(kmh: f64, units: i32) -> String {
    if units == 1 { format!("{} mph", (kmh * 0.621_371).round() as i64) } else { format!("{} km/h", kmh.round() as i64) }
}

fn compass(deg: f64) -> &'static str {
    const POINTS: [&str; 8] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
    POINTS[(((deg % 360.0) + 22.5) / 45.0) as usize % 8]
}

fn uv_word(uv: f64) -> &'static str {
    match uv {
        u if u < 3.0 => "Low",
        u if u < 6.0 => "Moderate",
        u if u < 8.0 => "High",
        u if u < 11.0 => "Very high",
        _ => "Extreme",
    }
}

/// "2026-10-22T07:14" → "07:14".
fn hhmm(iso: &str) -> String {
    iso.split('T').nth(1).map(|t| t.chars().take(5).collect()).unwrap_or_default()
}

/// The weekday of a date, 0 Sunday (Sakamoto's method).
fn weekday(date: &str) -> usize {
    let mut it = date.split('-').filter_map(|x| x.parse::<i64>().ok());
    let (Some(mut y), Some(m), Some(d)) = (it.next(), it.next(), it.next()) else { return 0 };
    const T: [i64; 12] = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
    if m < 3 {
        y -= 1;
    }
    ((y + y / 4 - y / 100 + y / 400 + T[((m - 1) % 12) as usize] + d) % 7) as usize
}

const DAYS: [&str; 7] = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

// ── the app ──────────────────────────────────────────────────────────────

struct App {
    ui: slint::Weak<AppWindow>,
    saved: Saved,
    forecasts: std::collections::HashMap<String, Forecast>,
    found: Vec<Place>,
    errors: std::collections::HashMap<String, String>,
    loading: std::collections::HashSet<String>,
    search_seq: u64,
    toast_seq: u64,
}

type Shared = Rc<RefCell<App>>;

impl App {
    fn save(&self) {
        let path = saved_file();
        let _ = std::fs::create_dir_all(path.parent().unwrap());
        if let Ok(text) = serde_json::to_string_pretty(&self.saved) {
            let _ = kit::write_atomic(&path, text.as_bytes());
        }
    }

    fn place(&self, id: &str) -> Option<&Place> {
        self.saved.places.iter().find(|p| p.id() == id)
    }

    /// Everything on screen, from what's known.
    fn show(&self) {
        let Some(ui) = self.ui.upgrade() else { return };
        let w = ui.global::<Weather>();
        let units = self.saved.units;
        w.set_units(units);
        w.set_current(self.saved.current.clone().into());
        let rows: Vec<PlaceRow> = self
            .saved
            .places
            .iter()
            .map(|p| {
                let f = self.forecasts.get(&p.id());
                PlaceRow {
                    id: p.id().into(),
                    name: p.name.clone().into(),
                    region: p.region.clone().into(),
                    temp: f.map(|f| temp(f.now.temp, units)).unwrap_or_default().into(),
                    icon: f.map(|f| condition(f.now.code, f.now.day).0).unwrap_or("").into(),
                }
            })
            .collect();
        w.set_places(ModelRc::new(VecModel::from(rows)));

        let id = self.saved.current.clone();
        w.set_loading(self.loading.contains(&id));
        w.set_error(self.errors.get(&id).cloned().unwrap_or_default().into());
        let Some(place) = self.place(&id) else {
            w.set_have_data(false);
            w.set_updated("".into());
            return;
        };
        w.set_place_name(place.name.clone().into());
        w.set_place_region(place.region.clone().into());
        let Some(f) = self.forecasts.get(&id) else {
            w.set_have_data(false);
            w.set_updated("".into());
            return;
        };
        w.set_have_data(true);
        w.set_updated(if f.fetched > 0 { format!("Updated {}", kit::when(f.fetched)) } else { String::new() }.into());

        let (icon, words) = condition(f.now.code, f.now.day);
        w.set_temp(temp(f.now.temp, units).into());
        w.set_icon(icon.into());
        w.set_summary(words.into());
        w.set_feels(format!("Feels like {}", temp(f.now.feels, units)).into());
        let today = f.days.first();
        w.set_high_low(today.map(|d| format!("H {}  L {}", temp(d.high, units), temp(d.low, units))).unwrap_or_default().into());

        // The next 24 hours, from this one.
        let this_hour: String = f.now.time.chars().take(13).collect();
        let start = f.hours.iter().position(|h| h.time.starts_with(&this_hour)).unwrap_or(0);
        let hours: Vec<Hour> = f.hours.iter().skip(start).take(25).enumerate()
            .map(|(i, h)| Hour {
                time: hhmm(&h.time).into(),
                // Now is what it is now, not the hour's forecast.
                icon: if i == 0 { condition(f.now.code, f.now.day).0 } else { condition(h.code, h.day).0 }.into(),
                temp: temp(if i == 0 { f.now.temp } else { h.temp }, units).into(),
                rain: h.rain.filter(|r| *r >= 10.0).map(|r| format!("{}%", r.round() as i64)).unwrap_or_default().into(),
                now: i == 0,
            })
            .collect();
        w.set_hours(ModelRc::new(VecModel::from(hours)));

        // Ten days, each day's range within all of theirs.
        let lo = f.days.iter().map(|d| d.low).fold(f64::MAX, f64::min);
        let hi = f.days.iter().map(|d| d.high).fold(f64::MIN, f64::max);
        let span = (hi - lo).max(1.0);
        let days: Vec<Day> = f.days.iter().enumerate()
            .map(|(i, d)| Day {
                name: match i {
                    0 => "Today".into(),
                    1 => "Tomorrow".into(),
                    _ => DAYS[weekday(&d.date)].into(),
                },
                icon: condition(d.code, true).0.into(),
                rain: d.rain.filter(|r| *r >= 10.0).map(|r| format!("{}%", r.round() as i64)).unwrap_or_default().into(),
                low: temp(d.low, units).into(),
                high: temp(d.high, units).into(),
                from: ((d.low - lo) / span) as f32,
                to: ((d.high - lo) / span) as f32,
            })
            .collect();
        w.set_days(ModelRc::new(VecModel::from(days)));

        let hour = f.hours.get(start);
        let mut details = vec![
            Detail {
                icon: "wind".into(),
                title: "WIND".into(),
                value: speed(f.now.wind, units).into(),
                note: format!("From the {}, gusts to {}", compass(f.now.wind_dir), speed(f.now.gusts, units)).into(),
            },
            Detail {
                icon: "droplet".into(),
                title: "HUMIDITY".into(),
                value: format!("{}%", f.now.humidity.round() as i64).into(),
                note: format!("Dew point {}", temp(f.now.dew, units)).into(),
            },
        ];
        let uv = hour.and_then(|h| h.uv).unwrap_or(0.0);
        details.push(Detail {
            icon: "sun".into(),
            title: "UV INDEX".into(),
            value: format!("{} {}", uv.round() as i64, uv_word(uv)).into(),
            note: today.map(|d| format!("Up to {} today", d.uv.round() as i64)).unwrap_or_default().into(),
        });
        if let Some(d) = today {
            details.push(Detail {
                icon: "sunset".into(),
                title: "SUNRISE AND SUNSET".into(),
                value: format!("{}  ·  {}", hhmm(&d.sunrise), hhmm(&d.sunset)).into(),
                note: "Sunrise, then sunset".into(),
            });
            details.push(Detail {
                icon: "umbrella".into(),
                title: "RAIN TODAY".into(),
                value: format!("{:.1} mm", d.precip).into(),
                note: d.rain.map(|r| format!("{}% chance", r.round() as i64)).unwrap_or_default().into(),
            });
        }
        details.push(Detail {
            icon: "gauge".into(),
            title: "PRESSURE".into(),
            value: format!("{} hPa", f.now.pressure.round() as i64).into(),
            note: "At sea level".into(),
        });
        if let Some(vis) = hour.and_then(|h| h.visibility) {
            let km = vis / 1000.0;
            details.push(Detail {
                icon: "eye".into(),
                title: "VISIBILITY".into(),
                value: if units == 1 { format!("{:.0} mi", km * 0.621_371) } else { format!("{:.0} km", km) }.into(),
                note: if km >= 10.0 { "Clear" } else if km >= 4.0 { "Hazy" } else { "Poor" }.into(),
            });
        }
        details.push(Detail {
            icon: "cloud".into(),
            title: "CLOUD COVER".into(),
            value: format!("{}%", f.now.cloud.round() as i64).into(),
            note: if f.now.precip > 0.0 { format!("{:.1} mm falling now", f.now.precip) } else { "Nothing falling now".into() }.into(),
        });
        w.set_details(ModelRc::new(VecModel::from(details)));
    }

    fn toast(app: &Shared, text: &str) {
        let seq = {
            let mut a = app.borrow_mut();
            a.toast_seq += 1;
            a.toast_seq
        };
        if let Some(ui) = app.borrow().ui.upgrade() {
            ui.global::<Weather>().set_toast(text.into());
        }
        let app = app.clone();
        slint::Timer::single_shot(Duration::from_secs(3), move || {
            if app.borrow().toast_seq == seq {
                if let Some(ui) = app.borrow().ui.upgrade() {
                    ui.global::<Weather>().set_toast("".into());
                }
            }
        });
    }
}

fn read_cache(id: &str) -> Option<Forecast> {
    let path = cache_dir().join(format!("{id}.json"));
    let text = std::fs::read_to_string(&path).ok()?;
    let mut f = parse_forecast(&serde_json::from_str(&text).ok()?)?;
    f.fetched = std::fs::metadata(&path).ok()?.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
    Some(f)
}

/// A fresh forecast for one place, unless one is already on its way.
fn refresh(app: &Shared, id: &str) {
    let Some(place) = app.borrow().place(id).cloned() else { return };
    if !app.borrow_mut().loading.insert(id.to_string()) {
        return;
    }
    app.borrow().show();
    let id = id.to_string();
    let app2 = app.clone();
    kit::spawn(
        move || -> Result<Forecast, String> {
            let text = get(&forecast_url(&place))?;
            let v: Value = serde_json::from_str(&text).map_err(|_| "An answer that couldn't be read".to_string())?;
            if let Some(reason) = v["reason"].as_str() {
                return Err(reason.to_string());
            }
            let mut f = parse_forecast(&v).ok_or("A forecast that couldn't be read")?;
            f.fetched = kit::now();
            let _ = std::fs::create_dir_all(cache_dir());
            let _ = kit::write_atomic(&cache_dir().join(format!("{}.json", place.id())), text.as_bytes());
            Ok(f)
        },
        move |result| {
            let mut a = app2.borrow_mut();
            a.loading.remove(&id);
            match result {
                Ok(f) => {
                    a.errors.remove(&id);
                    a.forecasts.insert(id, f);
                }
                Err(e) => {
                    a.errors.insert(id, e);
                }
            }
            a.show();
        },
    );
}

fn stale(app: &Shared, id: &str) -> bool {
    app.borrow().forecasts.get(id).map(|f| kit::now() - f.fetched > 10 * 60).unwrap_or(true)
}

fn main() {
    kit::init("hyprshell-weather");
    let saved: Saved = std::fs::read_to_string(saved_file()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();

    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-weather");

    let mut forecasts = std::collections::HashMap::new();
    for p in &saved.places {
        if let Some(f) = read_cache(&p.id()) {
            forecasts.insert(p.id(), f);
        }
    }
    let mut app = App {
        ui: ui.as_weak(),
        saved,
        forecasts,
        found: Vec::new(),
        errors: Default::default(),
        loading: Default::default(),
        search_seq: 0,
        toast_seq: 0,
    };
    if app.place(&app.saved.current.clone()).is_none() {
        app.saved.current = app.saved.places.first().map(|p| p.id()).unwrap_or_default();
    }
    let app: Shared = Rc::new(RefCell::new(app));
    app.borrow().show();

    let w = ui.global::<Weather>();

    {
        let app = app.clone();
        w.on_pick(move |id| {
            app.borrow_mut().saved.current = id.to_string();
            app.borrow().save();
            app.borrow().show();
            if stale(&app, &id) {
                refresh(&app, &id);
            }
        });
    }
    {
        let app = app.clone();
        w.on_refresh(move || {
            let id = app.borrow().saved.current.clone();
            refresh(&app, &id);
        });
    }
    {
        let app = app.clone();
        w.on_set_units(move |u| {
            app.borrow_mut().saved.units = u.clamp(0, 1);
            app.borrow().save();
            app.borrow().show();
        });
    }
    {
        let app = app.clone();
        w.on_remove(move |id| {
            let name = {
                let mut a = app.borrow_mut();
                let name = a.place(&id).map(|p| p.name.clone()).unwrap_or_default();
                a.saved.places.retain(|p| p.id() != id.as_str());
                a.forecasts.remove(id.as_str());
                if a.saved.current == id.as_str() {
                    a.saved.current = a.saved.places.first().map(|p| p.id()).unwrap_or_default();
                }
                a.save();
                let _ = std::fs::remove_file(cache_dir().join(format!("{id}.json")));
                name
            };
            app.borrow().show();
            App::toast(&app, &format!("{name} removed"));
        });
    }

    // Add a place: what's typed, looked up a moment after the typing stops.
    let search_timer = Rc::new(slint::Timer::default());
    {
        let app = app.clone();
        let timer = search_timer.clone();
        w.on_search(move |q| {
            let q = q.trim().to_string();
            let seq = {
                let mut a = app.borrow_mut();
                a.search_seq += 1;
                a.found.clear();
                a.search_seq
            };
            let Some(ui) = app.borrow().ui.upgrade() else { return };
            let w = ui.global::<Weather>();
            w.set_found(ModelRc::new(VecModel::from(Vec::<Found>::new())));
            if q.chars().count() < 2 {
                w.set_searching(false);
                w.set_search_note("Type a town or city".into());
                timer.stop();
                return;
            }
            w.set_searching(true);
            let app = app.clone();
            timer.start(slint::TimerMode::SingleShot, Duration::from_millis(350), move || {
                let q = q.clone();
                let app = app.clone();
                kit::spawn(move || search(&q), move |result| {
                    let mut a = app.borrow_mut();
                    if a.search_seq != seq {
                        return;
                    }
                    let Some(ui) = a.ui.upgrade() else { return };
                    let w = ui.global::<Weather>();
                    w.set_searching(false);
                    match result {
                        Ok(places) => {
                            w.set_search_note(if places.is_empty() { "Nowhere by that name" } else { "" }.into());
                            let rows: Vec<Found> = places.iter()
                                .map(|p| Found { name: p.name.clone().into(), region: p.region.clone().into(), lat: p.lat as f32, lon: p.lon as f32 })
                                .collect();
                            w.set_found(ModelRc::new(VecModel::from(rows)));
                            a.found = places;
                        }
                        Err(e) => w.set_search_note(SharedString::from(e)),
                    }
                });
            });
        });
    }
    {
        let app = app.clone();
        w.on_add(move |i| {
            let Some(place) = app.borrow().found.get(i as usize).cloned() else { return };
            let id = place.id();
            {
                let mut a = app.borrow_mut();
                if a.place(&id).is_none() {
                    a.saved.places.push(place);
                }
                a.saved.current = id.clone();
                a.found.clear();
                a.save();
            }
            if let Some(ui) = app.borrow().ui.upgrade() {
                let w = ui.global::<Weather>();
                w.set_query("".into());
                w.set_found(ModelRc::new(VecModel::from(Vec::<Found>::new())));
            }
            app.borrow().show();
            refresh(&app, &id);
        });
    }

    // Fresh at the start, and every quarter of an hour after.
    let ids: Vec<String> = app.borrow().saved.places.iter().map(|p| p.id()).collect();
    for id in ids {
        if stale(&app, &id) {
            refresh(&app, &id);
        }
    }
    let every = slint::Timer::default();
    {
        let app = app.clone();
        every.start(slint::TimerMode::Repeated, Duration::from_secs(15 * 60), move || {
            let ids: Vec<String> = app.borrow().saved.places.iter().map(|p| p.id()).collect();
            for id in ids {
                refresh(&app, &id);
            }
        });
    }
    // "Updated 14:05" kept true as time passes.
    let tick = slint::Timer::default();
    {
        let app = app.clone();
        tick.start(slint::TimerMode::Repeated, Duration::from_secs(60), move || app.borrow().show());
    }

    ui.run().expect("run");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weekdays() {
        assert_eq!(weekday("2026-10-22"), 4); // a Thursday
        assert_eq!(weekday("2024-02-29"), 4);
        assert_eq!(weekday("2000-01-01"), 6);
    }

    #[test]
    fn compass_points() {
        assert_eq!(compass(0.0), "N");
        assert_eq!(compass(350.0), "N");
        assert_eq!(compass(90.0), "E");
        assert_eq!(compass(225.0), "SW");
    }

    #[test]
    fn units() {
        assert_eq!(temp(20.0, 0), "20°");
        assert_eq!(temp(20.0, 1), "68°");
        assert_eq!(speed(100.0, 1), "62 mph");
    }

    #[test]
    fn reads_a_forecast() {
        let v: Value = serde_json::from_str(include_str!("../tests/forecast.json")).unwrap();
        let f = parse_forecast(&v).expect("parsed");
        assert_eq!(f.days.len(), 3);
        assert_eq!(f.hours.len(), 4);
        assert_eq!(f.now.code, 61);
        assert_eq!(condition(f.now.code, f.now.day).1, "Light rain");
        assert_eq!(hhmm(&f.days[0].sunrise), "07:14");
    }

    #[test]
    fn reads_places() {
        let v: Value = serde_json::from_str(include_str!("../tests/places.json")).unwrap();
        let p = parse_places(&v);
        assert_eq!(p.len(), 2);
        assert_eq!(p[0].name, "Cambridge");
        assert_eq!(p[0].region, "England, United Kingdom");
        assert_eq!(p[1].region, "Massachusetts, United States");
    }
}
