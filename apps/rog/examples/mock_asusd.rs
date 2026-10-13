//! A stand-in asusd on the session bus, for trying ROG Control Center on a
//! machine without one (HYPRSHELL_ROG_BUS=session). Platform, keyboard,
//! fan curves and a few firmware attributes, shaped like a G14's.
//!
//!   cargo run --example mock_asusd

use std::sync::{Arc, Mutex};
use zbus::interface;

struct Platform {
    profile: u32,
    charge: u8,
    change_ac: bool,
}

#[interface(name = "xyz.ljones.Platform")]
impl Platform {
    #[zbus(property)]
    fn version(&self) -> String { "6.1.0 (stand-in)".into() }
    #[zbus(property)]
    fn platform_profile(&self) -> u32 { self.profile }
    #[zbus(property)]
    fn set_platform_profile(&mut self, v: u32) { self.profile = v; }
    #[zbus(property)]
    fn platform_profile_choices(&self) -> Vec<u32> { vec![0, 1, 2] }
    #[zbus(property)]
    fn charge_control_end_threshold(&self) -> u8 { self.charge }
    #[zbus(property)]
    fn set_charge_control_end_threshold(&mut self, v: u8) { self.charge = v; }
    #[zbus(property)]
    fn change_platform_profile_on_ac(&self) -> bool { self.change_ac }
    #[zbus(property)]
    fn set_change_platform_profile_on_ac(&mut self, v: bool) { self.change_ac = v; }
    #[zbus(property)]
    fn change_platform_profile_on_battery(&self) -> bool { false }
    #[zbus(property)]
    fn platform_profile_on_ac(&self) -> u32 { 1 }
    #[zbus(property)]
    fn platform_profile_on_battery(&self) -> u32 { 2 }
    fn one_shot_full_charge(&self) {}
}

struct Aura {
    brightness: u32,
    effect: (u32, u32, (u8, u8, u8), (u8, u8, u8), String, String),
}

#[interface(name = "xyz.ljones.Aura")]
impl Aura {
    #[zbus(property)]
    fn brightness(&self) -> u32 { self.brightness }
    #[zbus(property)]
    fn set_brightness(&mut self, v: u32) { self.brightness = v; }
    #[zbus(property)]
    fn supported_brightness(&self) -> Vec<u32> { vec![0, 1, 2, 3] }
    #[zbus(property)]
    fn led_mode(&self) -> u32 { self.effect.0 }
    #[zbus(property)]
    fn supported_basic_modes(&self) -> Vec<u32> { vec![0, 1, 2, 3, 10] }
    #[zbus(property)]
    fn led_mode_data(&self) -> (u32, u32, (u8, u8, u8), (u8, u8, u8), String, String) { self.effect.clone() }
    #[zbus(property)]
    fn set_led_mode_data(&mut self, v: (u32, u32, (u8, u8, u8), (u8, u8, u8), String, String)) { self.effect = v; }
}

struct Attr {
    value: i32,
    min: i32,
    max: i32,
    possible: Vec<i32>,
}

#[interface(name = "xyz.ljones.AsusArmoury")]
impl Attr {
    #[zbus(property)]
    fn current_value(&self) -> i32 { self.value }
    #[zbus(property)]
    fn set_current_value(&mut self, v: i32) { self.value = v; }
    #[zbus(property)]
    fn min_value(&self) -> i32 { self.min }
    #[zbus(property)]
    fn max_value(&self) -> i32 { self.max }
    #[zbus(property)]
    fn possible_values(&self) -> Vec<i32> { self.possible.clone() }
}

type Curve = (String, [u8; 8], [u8; 8], bool);

struct Fans {
    curves: Arc<Mutex<Vec<Curve>>>,
}

#[interface(name = "xyz.ljones.FanCurves")]
impl Fans {
    fn fan_curve_data(&self, _profile: u32) -> Vec<Curve> { self.curves.lock().unwrap().clone() }
    fn set_fan_curve(&self, _profile: u32, c: Curve) {
        let mut all = self.curves.lock().unwrap();
        if let Some(x) = all.iter_mut().find(|x| x.0 == c.0) { *x = c; }
    }
    fn set_profile_fan_curve_enabled(&self, _profile: u32, fan: String, on: bool) {
        if let Some(x) = self.curves.lock().unwrap().iter_mut().find(|x| x.0 == fan) { x.3 = on; }
    }
    fn set_curves_to_defaults(&self, _profile: u32) {}
}

fn main() -> zbus::Result<()> {
    let curves = Arc::new(Mutex::new(vec![
        ("CPU".to_string(), [20, 40, 70, 110, 150, 190, 230, 255], [35, 45, 55, 65, 72, 80, 88, 95], true),
        ("GPU".to_string(), [10, 30, 60, 100, 140, 180, 220, 255], [35, 45, 55, 65, 72, 80, 88, 95], false),
    ]));
    let conn = zbus::blocking::connection::Builder::session()?
        .name("xyz.ljones.Asusd")?
        .serve_at("/", zbus::fdo::ObjectManager)?
        .serve_at("/xyz/ljones", Platform { profile: 0, charge: 80, change_ac: true })?
        .serve_at("/xyz/ljones", Fans { curves })?
        .serve_at("/xyz/ljones/aura/19b6_4_4", Aura { brightness: 2, effect: (0, 0, (255, 86, 60), (0, 0, 255), "Med".into(), "Right".into()) })?
        .serve_at("/xyz/ljones/asus_armoury/panel_overdrive", Attr { value: 1, min: 0, max: 1, possible: vec![0, 1] })?
        .serve_at("/xyz/ljones/asus_armoury/boot_sound", Attr { value: 0, min: 0, max: 1, possible: vec![0, 1] })?
        .serve_at("/xyz/ljones/asus_armoury/ppt_pl1_spl", Attr { value: 45, min: 15, max: 80, possible: vec![] })?
        .serve_at("/xyz/ljones/asus_armoury/nv_dynamic_boost", Attr { value: 15, min: 5, max: 25, possible: vec![] })?
        .serve_at("/xyz/ljones/asus_armoury/dgpu_disable", Attr { value: 0, min: 0, max: 1, possible: vec![0, 1] })?
        .serve_at("/xyz/ljones/asus_armoury/gpu_mux_mode", Attr { value: 1, min: 0, max: 1, possible: vec![0, 1] })?
        .build()?;
    let _ = conn;
    loop {
        std::thread::sleep(std::time::Duration::from_secs(3600));
    }
}
