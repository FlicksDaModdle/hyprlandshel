//! A stand-in asusd on the session bus, for testing src/rog.rs without an
//! ASUS laptop: the same service name, object paths, interfaces, property
//! names and D-Bus types as asusd 6.x (rog-dbus), with its GPU behaviour —
//! GPU attributes are queued for the next boot, not applied.
//!
//!   cargo run --example mock_asusd      (then HYPRSHELL_ROG_BUS=session)

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use zbus::zvariant::{OwnedValue, Structure, Value};

struct Platform {
    profile: u32,
    charge: u8,
}

#[zbus::interface(name = "xyz.ljones.Platform")]
impl Platform {
    #[zbus(property)]
    fn version(&self) -> String {
        "6.3.8-mock".into()
    }
    #[zbus(property)]
    fn platform_profile(&self) -> u32 {
        self.profile
    }
    #[zbus(property)]
    fn set_platform_profile(&mut self, p: u32) -> zbus::fdo::Result<()> {
        if ![0, 1, 2].contains(&p) {
            return Err(zbus::fdo::Error::NotSupported("profile not supported".into()));
        }
        println!("SET profile {p}");
        self.profile = p;
        Ok(())
    }
    #[zbus(property)]
    fn platform_profile_choices(&self) -> Vec<u32> {
        vec![2, 0, 1]
    }
    #[zbus(property)]
    fn charge_control_end_threshold(&self) -> u8 {
        self.charge
    }
    #[zbus(property)]
    fn set_charge_control_end_threshold(&mut self, v: u8) -> zbus::fdo::Result<()> {
        if !(20..=100).contains(&v) {
            return Err(zbus::fdo::Error::InvalidArgs(format!("Charge limit {v} out of range")));
        }
        println!("SET charge {v}");
        self.charge = v;
        Ok(())
    }
    fn one_shot_full_charge(&self) {
        println!("CALL one-shot full charge");
    }
    #[zbus(property)]
    fn platform_profile_on_ac(&self) -> u32 {
        1
    }
    #[zbus(property)]
    fn platform_profile_on_battery(&self) -> u32 {
        2
    }
    #[zbus(property)]
    fn change_platform_profile_on_ac(&self) -> bool {
        true
    }
    #[zbus(property)]
    fn change_platform_profile_on_battery(&self) -> bool {
        true
    }
}

type Effect = (u32, u32, (u8, u8, u8), (u8, u8, u8), String, String);

struct Aura {
    brightness: u32,
    effect: Effect,
}

#[zbus::interface(name = "xyz.ljones.Aura")]
impl Aura {
    #[zbus(property)]
    fn brightness(&self) -> u32 {
        self.brightness
    }
    #[zbus(property)]
    fn set_brightness(&mut self, b: u32) {
        println!("SET kbd brightness {b}");
        self.brightness = b;
    }
    #[zbus(property)]
    fn supported_brightness(&self) -> Vec<u32> {
        vec![0, 1, 2, 3]
    }
    #[zbus(property)]
    fn supported_basic_modes(&self) -> Vec<u32> {
        vec![0, 1, 2, 3, 10]
    }
    #[zbus(property)]
    fn led_mode(&self) -> u32 {
        self.effect.0
    }
    #[zbus(property)]
    fn led_mode_data(&self) -> Value<'static> {
        Value::from(Structure::from(self.effect.clone()))
    }
    #[zbus(property)]
    fn set_led_mode_data(&mut self, v: OwnedValue) -> zbus::fdo::Result<()> {
        let e: Effect = v.try_into().map_err(|e: zbus::zvariant::Error| zbus::fdo::Error::InvalidArgs(e.to_string()))?;
        println!("SET kbd effect mode={} colour=#{:02x}{:02x}{:02x} speed={} dir={}", e.0, e.2 .0, e.2 .1, e.2 .2, e.4, e.5);
        self.effect = e;
        Ok(())
    }
}

struct Attr {
    name: &'static str,
    value: i32,
    possible: Vec<i32>,
    gpu: bool,
    queued: Arc<Mutex<HashMap<&'static str, i32>>>,
}

#[zbus::interface(name = "xyz.ljones.AsusArmoury")]
impl Attr {
    #[zbus(property)]
    fn current_value(&self) -> i32 {
        self.value
    }
    #[zbus(property)]
    fn set_current_value(&mut self, v: i32) -> zbus::fdo::Result<()> {
        if !self.possible.is_empty() && !self.possible.contains(&v) {
            return Err(zbus::fdo::Error::InvalidArgs(format!("{v} not allowed for {}", self.name)));
        }
        if self.gpu {
            println!("QUEUE {} = {v}", self.name);
            self.queued.lock().unwrap().insert(self.name, v);
        } else {
            println!("SET {} = {v}", self.name);
            self.value = v;
        }
        Ok(())
    }
    #[zbus(property)]
    fn default_value(&self) -> i32 {
        0
    }
    #[zbus(property)]
    fn min_value(&self) -> i32 {
        -1
    }
    #[zbus(property)]
    fn max_value(&self) -> i32 {
        -1
    }
    #[zbus(property)]
    fn scalar_increment(&self) -> i32 {
        -1
    }
    #[zbus(property)]
    fn possible_values(&self) -> Vec<i32> {
        self.possible.clone()
    }
    #[zbus(property)]
    fn queued_gpu_value(&self) -> i32 {
        self.queued.lock().unwrap().get(self.name).copied().unwrap_or(-1)
    }
}

fn main() -> zbus::Result<()> {
    let queued = Arc::new(Mutex::new(HashMap::new()));
    let attr = |name, value, gpu| Attr { name, value, possible: vec![0, 1], gpu, queued: queued.clone() };
    let conn = zbus::blocking::connection::Builder::session()?
        .serve_at("/", zbus::fdo::ObjectManager)?
        .serve_at("/xyz/ljones", Platform { profile: 0, charge: 100 })?
        .serve_at("/xyz/ljones/aura/19b6_kbd", Aura { brightness: 2, effect: (0, 0, (166, 0, 0), (0, 0, 0), "Med".into(), "Right".into()) })?
        .serve_at("/xyz/ljones/asus_armoury/dgpu_disable", attr("dgpu_disable", 0, true))?
        .serve_at("/xyz/ljones/asus_armoury/gpu_mux_mode", attr("gpu_mux_mode", 1, true))?
        .serve_at("/xyz/ljones/asus_armoury/panel_overdrive", attr("panel_overdrive", 1, false))?
        .serve_at("/xyz/ljones/asus_armoury/boot_sound", attr("boot_sound", 0, false))?
        .name("xyz.ljones.Asusd")?
        .build()?;
    let _ = conn;
    println!("MOCK ASUSD READY");
    loop {
        std::thread::park();
    }
}
