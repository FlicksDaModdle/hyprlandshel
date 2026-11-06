//! Settings → Network's Wi-Fi panel: services/Network.qml (what
//! NetworkManager says, through the daemon, and what to ask it) and
//! WifiPanel.qml's own state (which network is open, the form).
//!
//! Every action goes to the daemon over its stdin — passwords included —
//! and the daemon drives NetworkManager over D-Bus: nothing is on a command
//! line. One action at a time, in order (Network.qml's queue).

use crate::daemon::Daemon;
use crate::{AppWindow, KV, SavedNet, Wifi, WifiNet};
use serde_json::{json, Value};
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use std::collections::{HashMap, VecDeque};

#[derive(Clone, Default)]
pub struct Ap {
    pub ssid: String,
    pub signal: i64,
    pub security: String,
    pub in_use: bool,
    pub band: String,
    pub rate: String,
    pub freq: i64,
    pub flags: u64,
    pub wpa: u64,
    pub rsn: u64,
    pub bssid: String,
}

#[derive(Clone, Default)]
pub struct Profile {
    pub uuid: String,
    pub name: String,
    pub ssid: String,
    pub autoconnect: bool,
    pub key_mgmt: String,
    pub enterprise: bool,
}

#[derive(Clone, Default)]
pub struct Info {
    pub eap: String,
    pub phase2: String,
    pub identity: String,
    pub anonymous: String,
    pub domain: String,
    pub ca: String,
    pub system_ca: bool,
    pub client_cert: String,
    pub private_key: String,
    pub peap_ver: String,
    pub pac_file: String,
    pub fast_prov: String,
    pub key_mgmt: String,
    /// The profile's General / IPv4 / IPv6 settings, as the daemon reads them.
    pub general: Value,
}

struct Job {
    cmd: Value,
    ssid: String,
    after_ok_profile: Option<String>,
}

#[derive(Default)]
pub struct Net {
    pub available: bool,
    pub missing: bool,
    pub wifi_enabled: bool,
    pub connected: bool,
    pub connecting: bool,
    pub ssid: String,
    pub signal: i64,
    pub security: String,
    pub ifname: String,
    pub vpn_active: bool,
    pub vpn_name: String,
    pub networks: Vec<Ap>,
    pub scanning: bool,
    pub saved: Vec<Profile>,
    pub details: HashMap<String, String>,
    pub errors: HashMap<String, String>,
    pub busy_ssid: String,
    pub profile_info: HashMap<String, Info>,
    queue: VecDeque<Job>,
    job: Option<(i64, Job)>,
    seq: i64,
    // WifiPanel's own.
    pub open_ssid: String,
    pub hidden_open: bool,
    pub edit_signin: bool,
    pub new_password: bool,
    pub show_details: bool,
    pub show_saved: bool,
    pub show_all: bool,
    /// A saved network's settings open for changing.
    pub edit_general: bool,
    /// The list, held still while a form is open.
    pub list: Vec<Ap>,
    pub watching: bool,
}

pub fn is_enterprise(sec: &str) -> bool {
    let s = sec.to_uppercase();
    s.contains("802.1X") || s.contains("EAP")
}
pub fn is_secured(sec: &str) -> bool {
    let s = sec.trim().to_lowercase();
    !s.is_empty() && s != "open" && s != "--"
}
/// What a network's security is, worked out from NetworkManager's flags
/// (what KDE's applet reads): the name, which form it takes, the key
/// management to ask for, and the details behind it.
pub struct Sec {
    pub label: String,
    /// "open", "password", "wep" or "enterprise".
    pub form: &'static str,
    /// NetworkManager's key-mgmt for it; "" lets NetworkManager choose
    /// (a WPA2/WPA3 network, where it picks WPA3 when the card can).
    pub key: &'static str,
    pub detail: String,
    pub warn: String,
}

pub fn classify(flags: u64, wpa: u64, rsn: u64, fallback: &str) -> Sec {
    const PRIVACY: u64 = 0x1;
    const PAIR_TKIP: u64 = 0x4;
    const PAIR_CCMP: u64 = 0x8;
    const PSK: u64 = 0x100;
    const X8021: u64 = 0x200;
    const SAE: u64 = 0x400;
    const OWE: u64 = 0x800;
    const OWE_TM: u64 = 0x1000;
    const SUITE_B: u64 = 0x2000;
    let sec = |label: &str, form, key, warn: &str| Sec { label: label.into(), form, key, detail: String::new(), warn: warn.into() };
    let all = wpa | rsn;
    if all == 0 && flags == 0 && is_secured(fallback) {
        // An older daemon: only nmcli's words to go by.
        let f = fallback.to_uppercase();
        return if is_enterprise(fallback) {
            sec("WPA Enterprise (802.1X)", "enterprise", "wpa-eap", "")
        } else if f.contains("WPA3") && f.contains("WPA2") {
            sec("WPA2/WPA3 Personal", "password", "", "")
        } else if f.contains("WPA3") {
            sec("WPA3 Personal", "password", "sae", "")
        } else if f.contains("WEP") {
            sec("WEP", "wep", "wep", "WEP can be broken in minutes. Use it only if nothing else works with this router.")
        } else {
            sec("WPA2 Personal", "password", "wpa-psk", "")
        };
    }
    let mut s = if all == 0 {
        if flags & PRIVACY != 0 {
            sec("WEP", "wep", "wep", "WEP can be broken in minutes. Use it only if nothing else works with this router.")
        } else {
            sec("Open", "open", "none", "An open network: anyone nearby can see what you send over it that isn't encrypted.")
        }
    } else if all & SUITE_B != 0 {
        sec("WPA3 Enterprise 192-bit", "enterprise", "wpa-eap-suite-b-192", "")
    } else if all & X8021 != 0 {
        match (wpa & X8021 != 0, rsn & X8021 != 0) {
            (true, false) => sec("WPA Enterprise", "enterprise", "wpa-eap", "The first WPA only — an old and weak kind."),
            (true, true) => sec("WPA/WPA2 Enterprise", "enterprise", "wpa-eap", ""),
            _ => sec("WPA2/WPA3 Enterprise", "enterprise", "wpa-eap", ""),
        }
    } else if rsn & SAE != 0 && rsn & PSK != 0 {
        sec("WPA2/WPA3 Personal", "password", "", "")
    } else if rsn & SAE != 0 {
        sec("WPA3 Personal", "password", "sae", "")
    } else if all & PSK != 0 {
        match (wpa & PSK != 0, rsn & PSK != 0) {
            (true, false) => sec("WPA Personal", "password", "wpa-psk", "The first WPA only — an old and weak kind."),
            (true, true) => sec("WPA/WPA2 Personal", "password", "wpa-psk", ""),
            _ => sec("WPA2 Personal", "password", "wpa-psk", ""),
        }
    } else if rsn & OWE != 0 {
        sec("Enhanced Open (OWE)", "open", "owe", "")
    } else if rsn & OWE_TM != 0 {
        sec("Open, with Enhanced Open", "open", "", "")
    } else {
        sec("Secured", "password", "", "")
    };
    let mut bits: Vec<&str> = vec![];
    if all & SAE != 0 {
        bits.push("SAE");
    }
    if all & PSK != 0 {
        bits.push("pre-shared key");
    }
    if all & X8021 != 0 {
        bits.push("802.1X");
    } else if all & SUITE_B != 0 {
        bits.push("802.1X, 192-bit");
    }
    if all & (OWE | OWE_TM) != 0 {
        bits.push("OWE");
    }
    let pair = all & 0xf;
    let tkip_only = pair & PAIR_TKIP != 0 && pair & PAIR_CCMP == 0;
    if pair & PAIR_CCMP != 0 {
        bits.push("AES (CCMP)");
    }
    if pair & PAIR_TKIP != 0 {
        bits.push("TKIP");
    }
    s.detail = bits.join(" · ");
    if tkip_only && s.warn.is_empty() {
        s.warn = "Uses only the old TKIP cipher: slow, and weaker than AES.".into();
    }
    s
}

/// What a saved profile's key-mgmt is called.
pub fn key_mgmt_label(km: &str) -> &'static str {
    match km {
        "" => "Open",
        "none" => "WEP",
        "owe" => "Enhanced Open (OWE)",
        "wpa-psk" => "WPA/WPA2 Personal",
        "sae" => "WPA3 Personal",
        "wpa-eap" | "ieee8021x" => "Enterprise (802.1X)",
        "wpa-eap-suite-b-192" => "WPA3 Enterprise 192-bit",
        _ => "Secured",
    }
}

/// The form a picked security takes.
pub fn form_of(key: &str) -> &'static str {
    match key {
        "none" | "owe" => "open",
        "wep" => "wep",
        "wpa-eap" | "wpa-eap-suite-b-192" => "enterprise",
        _ => "password",
    }
}

pub fn channel(freq: i64) -> i64 {
    match freq {
        2484 => 14,
        2412..=2472 => (freq - 2407) / 5,
        5000..=5900 => (freq - 5000) / 5,
        5925..=7125 => (freq - 5950) / 5,
        _ => 0,
    }
}

/// Network.explain: NetworkManager's errors as something to do about them.
pub fn explain(text: &str) -> String {
    let t = text.trim_start_matches("Error:").trim();
    let l = t.to_lowercase();
    if l.contains("secrets were required, but not provided") {
        return "The password wasn't accepted, or none was given.".into();
    }
    if l.contains("802.1x supplicant took too long") || (l.contains("supplicant") && (l.contains("failed") || l.contains("disconnect"))) || l.contains("802-1x") {
        return "The network didn't accept the sign-in. The username and password may be right and the method wrong — open More options and try what your university lists (often PEAP with MSCHAPv2, or TTLS with PAP).".into();
    }
    if l.contains("no network with ssid") || l.contains("could not be found") {
        return "That network isn't in range any more.".into();
    }
    if l.contains("timed out") || l.contains("timeout") {
        return "The network didn't answer in time.".into();
    }
    if l.contains("ip configuration could not be reserved") || l.contains("ip-config-unavailable") || l.contains("dhcp") {
        return "Joined the network but didn't get an address from it (DHCP).".into();
    }
    if l.contains("not authorized") || l.contains("not authorised") || l.contains("insufficient privileges") {
        return "You're not allowed to change network settings in this session (polkit).".into();
    }
    if l.contains("property is invalid") || (l.contains("invalid") && l.contains("property")) {
        return format!("NetworkManager refused one of the settings: {t}");
    }
    t.trim_start_matches("Connection activation failed:").trim().to_string()
}

fn band(freq: i64) -> String {
    if freq >= 5925 {
        "6 GHz"
    } else if freq >= 4900 {
        "5 GHz"
    } else if freq > 0 {
        "2.4 GHz"
    } else {
        ""
    }
    .into()
}

impl Net {
    pub fn profile_for(&self, name: &str) -> Option<&Profile> {
        self.saved.iter().find(|p| p.ssid == name).or_else(|| self.saved.iter().find(|p| p.name == name))
    }

    /// Wanted while the Network pane is up: every access point, and a scan.
    pub fn watch(&mut self, d: &mut Daemon, on: bool) {
        if self.watching == on {
            return;
        }
        self.watching = on;
        d.send(json!({ "cmd": "net-watch", "on": on }));
        if on {
            d.send(json!({ "cmd": "net-refresh" }));
            self.scan(d);
        }
    }

    pub fn scan(&mut self, d: &mut Daemon) {
        self.scanning = true;
        d.send(json!({ "cmd": "net-scan" }));
    }

    /// One event from the daemon; true if the panel should be drawn again.
    pub fn event(&mut self, d: &mut Daemon, ev: &Value) -> bool {
        match ev["ev"].as_str() {
            Some("missing") => {
                self.missing = true;
                self.available = false;
                true
            }
            Some("net-done") => {
                let id = ev["id"].as_i64().unwrap_or(-1);
                if self.job.as_ref().is_some_and(|j| j.0 == id) {
                    let (_, job) = self.job.take().unwrap();
                    self.finish(d, job, ev["ok"] == true, ev["error"].as_str().unwrap_or(""));
                }
                true
            }
            Some("net-profile") => {
                let uuid = ev["uuid"].as_str().unwrap_or("").to_string();
                let g = |k: &str| ev[k].as_str().unwrap_or("").to_string();
                self.profile_info.insert(
                    uuid,
                    Info {
                        eap: g("eap"),
                        phase2: g("phase2"),
                        identity: g("identity"),
                        anonymous: g("anonymous"),
                        domain: g("domain"),
                        ca: g("ca"),
                        system_ca: ev["systemCa"] == true,
                        client_cert: g("clientCert"),
                        private_key: g("privateKey"),
                        peap_ver: g("peapVer"),
                        pac_file: g("pacFile"),
                        fast_prov: g("fastProv"),
                        key_mgmt: g("keyMgmt"),
                        general: ev["general"].clone(),
                    },
                );
                true
            }
            Some("exited") => {
                if let Some((_, job)) = self.job.take() {
                    self.finish(d, job, false, "hyprshell-daemon stopped");
                }
                self.available = false;
                true
            }
            Some("net") => {
                if ev["available"] != true {
                    self.available = false;
                    return true;
                }
                self.available = true;
                self.wifi_enabled = ev["wifiEnabled"] == true;
                if !self.wifi_enabled {
                    self.networks.clear();
                    self.ssid.clear();
                    self.signal = 0;
                }
                // The active connections (Network.applyActive).
                let (mut wifi, mut activating, mut vpn) = (false, false, false);
                let (mut dev, mut vpn_label) = (String::new(), String::new());
                for a in ev["active"].as_array().into_iter().flatten() {
                    let t = a["type"].as_str().unwrap_or("");
                    if t == "802-11-wireless" || t == "wifi" {
                        if a["state"] == "activated" {
                            wifi = true;
                        } else {
                            activating = true;
                        }
                        dev = a["device"].as_str().unwrap_or("").to_string();
                    } else if t == "vpn" || t == "wireguard" || t == "tun" {
                        vpn = true;
                        vpn_label = a["name"].as_str().unwrap_or(t).to_string();
                    }
                }
                self.connected = wifi;
                self.connecting = activating && !wifi;
                self.ifname = dev;
                self.vpn_active = vpn;
                self.vpn_name = vpn_label;
                if !wifi {
                    if !self.connecting {
                        self.ssid.clear();
                    }
                    self.signal = 0;
                    self.details.clear();
                } else if ev["wifi"].is_object() {
                    let w = &ev["wifi"];
                    let s = |k: &str| w[k].as_str().unwrap_or("").to_string();
                    self.details.insert("hw".into(), s("hw"));
                    self.details.insert("ip4".into(), s("ip4"));
                    self.details.insert("gateway".into(), s("gateway"));
                    self.details.insert(
                        "dns".into(),
                        w["dns"].as_array().map(|a| a.iter().filter_map(|v| v.as_str()).collect::<Vec<_>>().join(", ")).unwrap_or_default(),
                    );
                    self.details.insert("ip6".into(), s("ip6"));
                }
                if let Some(saved) = ev["saved"].as_array() {
                    self.saved = saved
                        .iter()
                        .map(|p| {
                            let s = |k: &str| p[k].as_str().unwrap_or("").to_string();
                            let km = s("keyMgmt");
                            let ssid = if s("ssid").is_empty() { s("name") } else { s("ssid") };
                            Profile { uuid: s("uuid"), name: s("name"), ssid, autoconnect: p["autoconnect"] != false, enterprise: km == "wpa-eap" || km == "ieee8021x", key_mgmt: km }
                        })
                        .collect();
                }
                if self.wifi_enabled {
                    self.apply_aps(ev["aps"].as_array().cloned().unwrap_or_default(), ev["full"] == true);
                }
                true
            }
            _ => false,
        }
    }

    /// Network.applyAps: one per name (the one in use, else the strongest),
    /// in use first, then saved, then by signal.
    fn apply_aps(&mut self, list: Vec<Value>, complete: bool) {
        let mut by: Vec<Ap> = vec![];
        for a in list {
            let name = a["ssid"].as_str().unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }
            let e = Ap {
                in_use: a["inUse"] == true,
                ssid: name.clone(),
                signal: a["signal"].as_i64().unwrap_or(0),
                security: a["security"].as_str().unwrap_or("").trim().to_string(),
                band: band(a["freq"].as_i64().unwrap_or(0)),
                rate: a["rate"].as_str().unwrap_or("").to_string(),
                freq: a["freq"].as_i64().unwrap_or(0),
                flags: a["flags"].as_u64().unwrap_or(0),
                wpa: a["wpaFlags"].as_u64().unwrap_or(0),
                rsn: a["rsnFlags"].as_u64().unwrap_or(0),
                bssid: a["bssid"].as_str().unwrap_or("").to_string(),
            };
            match by.iter_mut().find(|x| x.ssid == name) {
                Some(was) => {
                    if e.in_use || (!was.in_use && e.signal > was.signal) {
                        *was = e;
                    }
                }
                None => by.push(e),
            }
        }
        let known = |s: &str, saved: &[Profile]| saved.iter().any(|p| p.ssid == s || p.name == s);
        by.sort_by(|a, b| {
            (b.in_use, known(&b.ssid, &self.saved), b.signal).cmp(&(a.in_use, known(&a.ssid, &self.saved), a.signal))
        });
        for e in by.iter().filter(|e| e.in_use) {
            self.ssid = e.ssid.clone();
            self.signal = e.signal;
            self.security = classify(e.flags, e.wpa, e.rsn, &e.security).label;
            self.details.insert("band".into(), e.band.clone());
            self.details.insert("rate".into(), e.rate.clone());
        }
        if complete {
            self.networks = by;
            if self.open_ssid.is_empty() {
                self.list = self.networks.iter().filter(|n| !n.in_use).cloned().collect();
            }
        }
        self.scanning = false;
    }

    // ── actions (Network.qml's act / pump / finish) ─────────────────────
    fn act(&mut self, d: &mut Daemon, cmd: Value, ssid: &str, after: Option<String>) {
        self.queue.push_back(Job { cmd, ssid: ssid.to_string(), after_ok_profile: after });
        self.pump(d);
    }
    fn pump(&mut self, d: &mut Daemon) {
        if self.job.is_some() {
            return;
        }
        let Some(job) = self.queue.pop_front() else { return };
        self.seq += 1;
        let mut cmd = job.cmd.clone();
        cmd["id"] = json!(self.seq);
        d.send(cmd);
        self.job = Some((self.seq, job));
    }
    fn finish(&mut self, d: &mut Daemon, job: Job, ok: bool, err: &str) {
        if !job.ssid.is_empty() {
            if ok {
                self.errors.remove(&job.ssid);
            } else {
                self.errors.insert(job.ssid.clone(), explain(err));
            }
            if self.busy_ssid == job.ssid {
                self.busy_ssid.clear();
            }
            // Joined: the form has done its job.
            if ok && self.open_ssid == job.ssid {
                self.open_ssid.clear();
                self.edit_general = false;
                self.list = self.networks.iter().filter(|n| !n.in_use).cloned().collect();
            }
        }
        if ok {
            if let Some(uuid) = job.after_ok_profile {
                d.send(json!({ "cmd": "net-profile", "id": 0, "uuid": uuid }));
            }
        }
        d.send(json!({ "cmd": "net-refresh" }));
        self.pump(d);
    }

    pub fn set_wifi(&mut self, d: &mut Daemon, on: bool) {
        self.wifi_enabled = on;
        self.act(d, json!({ "cmd": "net-wifi", "on": on }), "", None);
        if on {
            self.scan(d);
        }
    }

    /// Network.join: a saved network as it is (or with a new password), a
    /// new one with its password, or open.
    pub fn join(&mut self, d: &mut Daemon, name: &str, password: &str) {
        if name.is_empty() {
            return;
        }
        self.errors.remove(name);
        self.busy_ssid = name.to_string();
        if let Some(p) = self.profile_for(name).cloned() {
            if password.is_empty() {
                self.act(d, json!({ "cmd": "net-up", "uuid": p.uuid }), name, None);
            } else {
                self.act(d, json!({ "cmd": "net-up", "uuid": p.uuid, "secret": password }), name, None);
            }
            return;
        }
        self.act(d, json!({ "cmd": "net-join", "ssid": name, "secret": password }), name, None);
    }

    /// Network.joinEnterprise. A saved profile is changed in place.
    /// `extra` carries the rest of the form (certificates, PEAP version,
    /// FAST, key management, general settings).
    #[allow(clippy::too_many_arguments)]
    pub fn join_enterprise(&mut self, d: &mut Daemon, name: &str, identity: &str, password: &str, eap: &str, phase2: &str, ca: &str, domain: &str, anon: &str, hidden: bool, extra: Value) {
        if name.is_empty() {
            return;
        }
        let eap = if eap.is_empty() { "peap" } else { eap };
        let phase2 = if eap == "pwd" || eap == "tls" {
            ""
        } else if phase2.is_empty() {
            if eap == "ttls" {
                "pap"
            } else {
                "mschapv2"
            }
        } else {
            phase2
        };
        self.errors.remove(name);
        self.busy_ssid = name.to_string();
        let uuid = self.profile_for(name).map(|p| p.uuid.clone()).unwrap_or_default();
        let after = (!uuid.is_empty()).then(|| uuid.clone());
        let mut cmd = json!({ "cmd": "net-enterprise", "ssid": name, "uuid": uuid, "hidden": hidden, "eap": eap, "phase2": phase2,
                "identity": identity, "anonymous": anon, "domain": domain, "ca": if ca.is_empty() { "none" } else { ca }, "secret": password });
        if let (Some(c), Some(x)) = (cmd.as_object_mut(), extra.as_object()) {
            for (k, v) in x {
                c.insert(k.clone(), v.clone());
            }
        }
        self.act(d, cmd, name, after);
    }

    /// A new network with its security picked (or worked out), and its
    /// general settings: KDE's whole dialog in one go.
    pub fn join_new(&mut self, d: &mut Daemon, name: &str, key: &str, secret: &str, wep_type: &str, hidden: bool, general: Value) {
        if name.is_empty() {
            return;
        }
        self.errors.remove(name);
        self.busy_ssid = name.to_string();
        let mut cmd = json!({ "cmd": "net-join", "ssid": name, "hidden": hidden, "secret": secret, "general": general });
        if !key.is_empty() {
            cmd["keyMgmt"] = json!(key);
            cmd["wepType"] = json!(wep_type);
        }
        self.act(d, cmd, name, None);
    }

    /// A saved network's general settings, changed.
    pub fn save_general(&mut self, d: &mut Daemon, name: &str, general: Value) {
        let Some(p) = self.profile_for(name).cloned() else { return };
        self.errors.remove(name);
        self.act(d, json!({ "cmd": "net-edit", "uuid": p.uuid, "general": general }), name, Some(p.uuid));
    }

    pub fn forget(&mut self, d: &mut Daemon, name_or_uuid: &str) {
        let p = self.saved.iter().find(|x| x.uuid == name_or_uuid).cloned().or_else(|| self.profile_for(name_or_uuid).cloned());
        let Some(p) = p else { return };
        self.errors.remove(&p.ssid);
        self.act(d, json!({ "cmd": "net-forget", "uuid": p.uuid }), "", None);
    }

    pub fn set_autoconnect(&mut self, d: &mut Daemon, uuid: &str, on: bool) {
        self.act(d, json!({ "cmd": "net-autoconnect", "uuid": uuid, "on": on }), "", None);
    }

    pub fn disconnect(&mut self, d: &mut Daemon) {
        if !self.ifname.is_empty() {
            self.act(d, json!({ "cmd": "net-disconnect" }), "", None);
        }
    }

    /// WifiPanel.openRow.
    pub fn open_row(&mut self, d: &mut Daemon, ssid: &str) {
        self.hidden_open = false;
        self.edit_signin = false;
        self.new_password = false;
        self.edit_general = false;
        if self.open_ssid == ssid {
            self.open_ssid.clear();
            self.list = self.networks.iter().filter(|n| !n.in_use).cloned().collect();
            return;
        }
        self.open_ssid = ssid.to_string();
        if let Some(p) = self.profile_for(ssid).cloned() {
            d.send(json!({ "cmd": "net-profile", "id": 0, "uuid": p.uuid }));
        }
    }

    /// Everything the panel draws, into the window.
    pub fn publish(&self, ui: &AppWindow) {
        let w = ui.global::<Wifi>();
        w.set_available(self.available);
        w.set_missing(self.missing);
        w.set_wifi_on(self.wifi_enabled);
        w.set_connected(self.connected);
        w.set_title(
            if !self.wifi_enabled {
                "Wi-Fi is off".to_string()
            } else if self.connecting {
                format!("Connecting to {}", if self.ssid.is_empty() { "…" } else { &self.ssid })
            } else if self.connected {
                self.ssid.clone()
            } else {
                "Not connected".into()
            }
            .into(),
        );
        w.set_sub(
            if !self.wifi_enabled {
                "Turn it on to see networks".to_string()
            } else if self.connected {
                ["Connected".to_string(), self.security.clone(), self.details.get("band").cloned().unwrap_or_default()]
                    .into_iter()
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" · ")
            } else if self.connecting {
                "Signing in…".into()
            } else {
                "Pick a network below".into()
            }
            .into(),
        );
        w.set_show_details(self.show_details);
        let g = |k: &str| self.details.get(k).cloned().unwrap_or_default();
        let strip = |s: String| s.split('/').next().unwrap_or("").to_string();
        let rows: Vec<KV> = [
            ("IP address", strip(g("ip4"))),
            ("Gateway", g("gateway")),
            ("DNS", g("dns")),
            ("IPv6", strip(g("ip6"))),
            ("Band", g("band")),
            ("Link speed", g("rate")),
            ("Hardware address", g("hw")),
            ("Signal", format!("{}%", self.signal)),
        ]
        .into_iter()
        .filter(|r| !r.1.is_empty())
        .map(|(k, v)| KV { k: k.into(), v: v.into() })
        .collect();
        w.set_details(ModelRc::new(VecModel::from(rows)));
        let cur = self.profile_for(&self.ssid);
        w.set_has_profile(self.connected && cur.is_some());
        w.set_autoconnect(cur.is_some_and(|p| p.autoconnect));
        w.set_scanning(self.scanning);
        w.set_open_ssid(self.open_ssid.clone().into());
        w.set_edit_signin(self.edit_signin);
        w.set_edit_general(self.edit_general);
        w.set_new_password(self.new_password);
        let shown: Vec<&Ap> = if self.show_all { self.list.iter().collect() } else { self.list.iter().take(12).collect() };
        let nets: Vec<WifiNet> = shown
            .iter()
            .map(|ap| {
                let prof = self.profile_for(&ap.ssid);
                let err = self.errors.get(&ap.ssid).cloned().unwrap_or_default();
                let busy = self.busy_ssid == ap.ssid || (self.connecting && self.ssid == ap.ssid);
                let info = prof.and_then(|p| self.profile_info.get(&p.uuid));
                let signin = match (prof, info) {
                    (Some(p), Some(i)) if p.enterprise => format!(
                        "Signs in{} with {}{}{}.",
                        if i.identity.is_empty() { String::new() } else { format!(" as {}", i.identity) },
                        i.eap.to_uppercase(),
                        if i.phase2.is_empty() { String::new() } else { format!(" / {}", i.phase2.to_uppercase()) },
                        if i.system_ca {
                            ", checking the server against the system's certificates"
                        } else if !i.ca.is_empty() {
                            ", checking the server's certificate"
                        } else {
                            ", without checking the server's certificate"
                        }
                    ),
                    (Some(p), None) if p.enterprise => "Signs in with a username and password.".into(),
                    _ => String::new(),
                };
                let sec = classify(ap.flags, ap.wpa, ap.rsn, &ap.security);
                let ch = channel(ap.freq);
                let place = [
                    ap.band.clone(),
                    if ch > 0 { format!("channel {ch}") } else { String::new() },
                    ap.rate.clone(),
                    if ap.bssid.is_empty() { String::new() } else { format!("BSSID {}", ap.bssid) },
                ]
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(" · ");
                let sub = if busy {
                    "Connecting…".to_string()
                } else if !err.is_empty() {
                    "Didn't connect — open for details".into()
                } else {
                    [if prof.is_some() { "Saved".to_string() } else { String::new() }, sec.label.clone(), ap.band.clone()]
                        .into_iter()
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                        .join(" · ")
                };
                let lit = if ap.signal >= 75 {
                    4
                } else if ap.signal >= 50 {
                    3
                } else if ap.signal >= 25 {
                    2
                } else if ap.signal > 0 {
                    1
                } else {
                    0
                };
                WifiNet {
                    ssid: ap.ssid.clone().into(),
                    bars: lit,
                    secured: sec.form != "open",
                    enterprise: sec.form == "enterprise",
                    sec: sec.label.clone().into(),
                    sec_detail: sec.detail.clone().into(),
                    sec_warn: sec.warn.clone().into(),
                    form: sec.form.into(),
                    sec_key: sec.key.into(),
                    place: place.into(),
                    // Only when it was saved as something else than the
                    // network now offers (a router changed to WPA3, say).
                    profile_sec: prof
                        .map(|p| info.map(|i| i.key_mgmt.clone()).unwrap_or_else(|| p.key_mgmt.clone()))
                        .filter(|km| {
                            // In a saved profile "none" is WEP's key-mgmt.
                            let f = match km.as_str() {
                                "" => "open",
                                "none" => "wep",
                                k => form_of(k),
                            };
                            f != sec.form && !(km == "owe" && sec.form == "open")
                        })
                        .map(|km| key_mgmt_label(&km))
                        .unwrap_or("")
                        .into(),
                    info_ready: info.is_some(),
                    saved: prof.is_some(),
                    saved_enterprise: prof.is_some_and(|p| p.enterprise),
                    autoconnect: prof.is_some_and(|p| p.autoconnect),
                    sub: sub.into(),
                    bad: !err.is_empty() && !busy,
                    err: err.into(),
                    busy,
                    signin: signin.into(),
                }
            })
            .collect();
        w.set_networks(ModelRc::new(VecModel::from(nets)));
        w.set_more(if self.list.len() > 12 { self.list.len() as i32 } else { 0 });
        w.set_show_all(self.show_all);
        w.set_hidden_open(self.hidden_open);
        w.set_hidden_err(self.errors.get(&w.get_h_name().trim().to_string()).cloned().unwrap_or_default().into());
        w.set_hidden_busy(!w.get_h_name().trim().is_empty() && self.busy_ssid == w.get_h_name().trim());
        let away: Vec<SavedNet> = self
            .saved
            .iter()
            .filter(|p| !self.networks.iter().any(|n| n.ssid == p.ssid))
            .map(|p| SavedNet {
                ssid: p.ssid.clone().into(),
                uuid: p.uuid.clone().into(),
                sub: format!(
                    "{}{}",
                    if p.enterprise {
                        "Sign-in"
                    } else if !p.key_mgmt.is_empty() {
                        "Password"
                    } else {
                        "Open"
                    },
                    if p.autoconnect { " · connects automatically" } else { "" }
                )
                .into(),
            })
            .collect();
        w.set_away(ModelRc::new(VecModel::from(away)));
        w.set_show_saved(self.show_saved);
        w.set_vpn(if self.vpn_active { SharedString::from(format!("VPN: {} is connected.", self.vpn_name)) } else { SharedString::new() });
    }

    /// WifiPanel.prefillFrom: a saved university network's settings into
    /// the form.
    pub fn prefill(&self, ui: &AppWindow, ssid: &str) {
        let w = ui.global::<Wifi>();
        let Some(i) = self.profile_for(ssid).and_then(|p| self.profile_info.get(&p.uuid)) else { return };
        let eap = if ["peap", "ttls", "pwd", "tls", "fast"].contains(&i.eap.as_str()) { i.eap.clone() } else { "peap".into() };
        w.set_f_client_cert(i.client_cert.clone().into());
        w.set_f_private_key(i.private_key.clone().into());
        w.set_f_peap_ver(i.peap_ver.clone().into());
        w.set_f_pac_file(i.pac_file.clone().into());
        w.set_f_fast_prov(if i.fast_prov.is_empty() { "1".into() } else { i.fast_prov.clone().into() });
        w.set_f_sec(if i.key_mgmt == "wpa-eap-suite-b-192" { "wpa-eap-suite-b-192".into() } else { "auto".into() });
        w.set_f_identity(i.identity.clone().into());
        w.set_f_phase2(if i.phase2.is_empty() { if eap == "ttls" { "pap".into() } else { "mschapv2".into() } } else { i.phase2.clone().into() });
        w.set_f_eap(eap.into());
        w.set_f_ca(if i.system_ca {
            "system".into()
        } else if !i.ca.is_empty() {
            "file".into()
        } else {
            "none".into()
        });
        w.set_f_ca_file(i.ca.trim_start_matches("file://").to_string().into());
        w.set_f_domain(i.domain.clone().into());
        w.set_f_anon(i.anonymous.clone().into());
        w.set_f_more(true);
    }

    /// A saved network's general settings into the form.
    pub fn prefill_general(&self, ui: &AppWindow, ssid: &str) -> bool {
        let Some(i) = self.profile_for(ssid).and_then(|p| self.profile_info.get(&p.uuid)) else { return false };
        let g = &i.general;
        if !g.is_object() {
            return false;
        }
        let w = ui.global::<Wifi>();
        let st = |v: &Value| SharedString::from(v.as_str().unwrap_or(""));
        w.set_g_auto(g["autoconnect"] != false);
        w.set_g_all(g["allUsers"] != false);
        w.set_g_metered(if g["metered"].is_string() { st(&g["metered"]) } else { "auto".into() });
        w.set_g_mac(st(&g["mac"]));
        w.set_g_band(st(&g["band"]));
        w.set_g_v4(if g["ipv4"]["method"].is_string() { st(&g["ipv4"]["method"]) } else { "auto".into() });
        w.set_g_addr(st(&g["ipv4"]["address"]));
        w.set_g_gw(st(&g["ipv4"]["gateway"]));
        w.set_g_dns(st(&g["ipv4"]["dns"]));
        w.set_g_dns_only(g["ipv4"]["ignoreAutoDns"] == true);
        w.set_g_v6(if g["ipv6"]["method"].is_string() { st(&g["ipv6"]["method"]) } else { "auto".into() });
        true
    }
}

/// The form's general settings, as the daemon takes them.
pub fn general(ui: &AppWindow, hidden: bool) -> Value {
    let w = ui.global::<Wifi>();
    let mut g = json!({
        "autoconnect": w.get_g_auto(),
        "allUsers": w.get_g_all(),
        "metered": w.get_g_metered().as_str(),
        "mac": w.get_g_mac().as_str(),
        "band": w.get_g_band().as_str(),
        "ipv4": {
            "method": w.get_g_v4().as_str(),
            "address": w.get_g_addr().trim(),
            "gateway": w.get_g_gw().trim(),
            "dns": w.get_g_dns().trim(),
            "ignoreAutoDns": w.get_g_dns_only(),
        },
        "ipv6": { "method": w.get_g_v6().as_str() },
    });
    if hidden {
        g["hidden"] = json!(true);
    }
    g
}

/// WifiPanel.resetForm.
pub fn reset_form(ui: &AppWindow) {
    let w = ui.global::<Wifi>();
    w.set_f_password(SharedString::new());
    w.set_f_identity(SharedString::new());
    w.set_f_eap("peap".into());
    w.set_f_phase2("mschapv2".into());
    w.set_f_ca("none".into());
    w.set_f_ca_file(SharedString::new());
    w.set_f_domain(SharedString::new());
    w.set_f_anon(SharedString::new());
    w.set_f_more(false);
    w.set_f_sec("auto".into());
    w.set_f_wep_type("key".into());
    w.set_f_client_cert(SharedString::new());
    w.set_f_private_key(SharedString::new());
    w.set_f_key_pass(SharedString::new());
    w.set_f_peap_ver(SharedString::new());
    w.set_f_pac_file(SharedString::new());
    w.set_f_fast_prov("1".into());
    w.set_f_adv(false);
    w.set_g_auto(true);
    w.set_g_all(true);
    w.set_g_metered("auto".into());
    w.set_g_mac(SharedString::new());
    w.set_g_band(SharedString::new());
    w.set_g_v4("auto".into());
    w.set_g_addr(SharedString::new());
    w.set_g_gw(SharedString::new());
    w.set_g_dns(SharedString::new());
    w.set_g_dns_only(false);
    w.set_g_v6("auto".into());
}
