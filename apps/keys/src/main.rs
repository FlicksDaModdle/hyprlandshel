//! Passwords and Keys: the Secret Service keyring (gnome-keyring, KeePassXC
//! or any other that speaks it), SSH keys in ~/.ssh, and gpg's keys.
//!
//! Secrets are only read when asked to show or copy one, are never put on a
//! command line, and leave the window when another item is picked. A copied
//! password is marked so clipboard histories skip it, and taken back off
//! the clipboard after 45 seconds (clip.rs).
//!
//! The keyring is spoken to over the session bus with the "plain"
//! transfer: the bus is this user's alone, which is what libsecret's own
//! tools rely on too.

slint::include_modules!();

mod clip;

use hyprshell_kit as kit;
use slint::{ComponentHandle, ModelRc, SharedString, VecModel};
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::time::Duration;
use zbus::blocking::Connection;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};

const SS: &str = "org.freedesktop.secrets";
const SS_PATH: &str = "/org/freedesktop/secrets";
const SERVICE: &str = "org.freedesktop.Secret.Service";
const COLLECTION: &str = "org.freedesktop.Secret.Collection";
const ITEM: &str = "org.freedesktop.Secret.Item";
const PROMPT: &str = "org.freedesktop.Secret.Prompt";
const PROPS: &str = "org.freedesktop.DBus.Properties";

type Secret = (OwnedObjectPath, Vec<u8>, Vec<u8>, String);

fn err(e: zbus::Error) -> String {
    match e {
        zbus::Error::MethodError(n, d, _) => d.unwrap_or_else(|| n.to_string()),
        o => o.to_string(),
    }
}

// ── the keyring ─────────────────────────────────────────────────────────

#[derive(Clone)]
struct Keyring {
    conn: Connection,
    session: OwnedObjectPath,
}

#[derive(Clone, Default)]
struct RingInfo {
    path: String,
    label: String,
    locked: bool,
    items: Vec<String>,
    default: bool,
}

#[derive(Clone, Default)]
struct ItemInfo {
    path: String,
    label: String,
    attrs: Vec<(String, String)>,
    created: u64,
    modified: u64,
}

impl Keyring {
    fn open() -> Result<Keyring, String> {
        let conn = Connection::session().map_err(err)?;
        let m = conn
            .call_method(Some(SS), SS_PATH, Some(SERVICE), "OpenSession", &("plain", Value::from("")))
            .map_err(err)?;
        let (_, session): (OwnedValue, OwnedObjectPath) = m.body().deserialize().map_err(|e| e.to_string())?;
        Ok(Keyring { conn, session })
    }

    fn props(&self, path: &str, iface: &str) -> HashMap<String, OwnedValue> {
        self.conn
            .call_method(Some(SS), path, Some(PROPS), "GetAll", &(iface,))
            .ok()
            .and_then(|m| m.body().deserialize().ok())
            .unwrap_or_default()
    }

    fn rings(&self) -> Result<Vec<RingInfo>, String> {
        let p = self.props(SS_PATH, SERVICE);
        let paths: Vec<OwnedObjectPath> = p.get("Collections").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or_default();
        let default: String = self
            .conn
            .call_method(Some(SS), SS_PATH, Some(SERVICE), "ReadAlias", &("default",))
            .ok()
            .and_then(|m| m.body().deserialize::<OwnedObjectPath>().ok())
            .map(|p| p.to_string())
            .unwrap_or_default();
        let mut out: Vec<RingInfo> = paths
            .iter()
            .map(|c| {
                let cp = self.props(c.as_str(), COLLECTION);
                let label: String = cp.get("Label").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or_default();
                let items: Vec<OwnedObjectPath> = cp.get("Items").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or_default();
                let locked: bool = cp.get("Locked").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or(false);
                RingInfo {
                    path: c.to_string(),
                    label: if label.is_empty() { c.as_str().rsplit('/').next().unwrap_or("").to_string() } else { label },
                    locked,
                    items: items.iter().map(|i| i.to_string()).collect(),
                    default: c.as_str() == default,
                }
            })
            // The "session" keyring is gnome-keyring's scratch space.
            .filter(|r| !r.path.ends_with("/session"))
            .collect();
        out.sort_by(|a, b| (!a.default, a.label.clone()).cmp(&(!b.default, b.label.clone())));
        Ok(out)
    }

    fn item(&self, path: &str) -> ItemInfo {
        let p = self.props(path, ITEM);
        let attrs: HashMap<String, String> = p.get("Attributes").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or_default();
        let mut attrs: Vec<(String, String)> = attrs.into_iter().collect();
        attrs.sort();
        ItemInfo {
            path: path.to_string(),
            label: p.get("Label").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or_default(),
            attrs,
            created: p.get("Created").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or(0),
            modified: p.get("Modified").and_then(|v| v.try_clone().ok()).and_then(|v| v.try_into().ok()).unwrap_or(0),
        }
    }

    fn secret(&self, path: &str) -> Result<String, String> {
        let m = self.conn.call_method(Some(SS), path, Some(ITEM), "GetSecret", &(&self.session,)).map_err(err)?;
        let (_, _, value, _): Secret = m.body().deserialize().map_err(|e| e.to_string())?;
        Ok(String::from_utf8_lossy(&value).to_string())
    }

    /// The keyring's own prompt (its password dialog), waited out.
    fn prompt(&self, prompt: &OwnedObjectPath) -> Result<(), String> {
        if prompt.as_str() == "/" {
            return Ok(());
        }
        let rule = zbus::MatchRule::builder()
            .msg_type(zbus::message::Type::Signal)
            .interface(PROMPT)
            .and_then(|b| b.member("Completed"))
            .and_then(|b| b.path(prompt.as_str()))
            .map(|b| b.build())
            .map_err(|e| e.to_string())?;
        let mut iter = zbus::blocking::MessageIterator::for_match_rule(rule, &self.conn, Some(4)).map_err(err)?;
        self.conn.call_method(Some(SS), prompt.as_str(), Some(PROMPT), "Prompt", &("",)).map_err(err)?;
        if let Some(Ok(msg)) = iter.next() {
            let (dismissed, _): (bool, OwnedValue) = msg.body().deserialize().map_err(|e| e.to_string())?;
            if dismissed {
                return Err("Cancelled".into());
            }
        }
        Ok(())
    }

    fn unlock(&self, path: &str) -> Result<(), String> {
        let p = ObjectPath::try_from(path).map_err(|e| e.to_string())?;
        let m = self.conn.call_method(Some(SS), SS_PATH, Some(SERVICE), "Unlock", &(vec![p],)).map_err(err)?;
        let (_, prompt): (Vec<OwnedObjectPath>, OwnedObjectPath) = m.body().deserialize().map_err(|e| e.to_string())?;
        self.prompt(&prompt)
    }

    fn lock(&self, path: &str) -> Result<(), String> {
        let p = ObjectPath::try_from(path).map_err(|e| e.to_string())?;
        let m = self.conn.call_method(Some(SS), SS_PATH, Some(SERVICE), "Lock", &(vec![p],)).map_err(err)?;
        let (_, prompt): (Vec<OwnedObjectPath>, OwnedObjectPath) = m.body().deserialize().map_err(|e| e.to_string())?;
        self.prompt(&prompt)
    }

    fn add(&self, ring: &str, label: &str, attrs: HashMap<String, String>, secret: &str) -> Result<(), String> {
        let mut props: HashMap<&str, Value> = HashMap::new();
        props.insert("org.freedesktop.Secret.Item.Label", Value::from(label.to_string()));
        props.insert("org.freedesktop.Secret.Item.Attributes", Value::from(attrs));
        let s: Secret = (self.session.clone(), Vec::new(), secret.as_bytes().to_vec(), "text/plain".into());
        let m = self.conn.call_method(Some(SS), ring, Some(COLLECTION), "CreateItem", &(props, s, true)).map_err(err)?;
        let (_, prompt): (OwnedObjectPath, OwnedObjectPath) = m.body().deserialize().map_err(|e| e.to_string())?;
        self.prompt(&prompt)
    }

    fn delete(&self, item: &str) -> Result<(), String> {
        let m = self.conn.call_method(Some(SS), item, Some(ITEM), "Delete", &()).map_err(err)?;
        let prompt: OwnedObjectPath = m.body().deserialize().map_err(|e| e.to_string())?;
        self.prompt(&prompt)
    }

    fn rename(&self, item: &str, label: &str) -> Result<(), String> {
        self.conn
            .call_method(Some(SS), item, Some(PROPS), "Set", &(ITEM, "Label", Value::from(label.to_string())))
            .map(|_| ())
            .map_err(err)
    }

    fn new_ring(&self, label: &str) -> Result<(), String> {
        let mut props: HashMap<&str, Value> = HashMap::new();
        props.insert("org.freedesktop.Secret.Collection.Label", Value::from(label.to_string()));
        let m = self.conn.call_method(Some(SS), SS_PATH, Some(SERVICE), "CreateCollection", &(props, "")).map_err(err)?;
        let (_, prompt): (OwnedObjectPath, OwnedObjectPath) = m.body().deserialize().map_err(|e| e.to_string())?;
        self.prompt(&prompt)
    }
}

/// What a keyring item is, from its attributes: the glyph, a better label
/// where the stored one is a machine's, and a line about it.
fn describe(it: &ItemInfo) -> (String, String, String) {
    let a: HashMap<&str, &str> = it.attrs.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
    let schema = a.get("xdg:schema").copied().unwrap_or("");
    let user = a.get("username").or(a.get("user")).or(a.get("account")).or(a.get("login")).copied().unwrap_or("");
    let server = a.get("server").or(a.get("host")).or(a.get("domain")).or(a.get("origin_url")).or(a.get("signon_realm")).copied().unwrap_or("");
    let sub = [user, server].iter().filter(|x| !x.is_empty()).cloned().collect::<Vec<_>>().join(" · ");
    if schema.contains("NetworkManager") {
        let id = a.get("connection-uuid").map(|_| it.label.trim_start_matches("Network secret for ").to_string()).unwrap_or(it.label.clone());
        return ("wifi".into(), id, if sub.is_empty() { "Network".into() } else { sub });
    }
    if it.label.to_lowercase().contains("mail") || schema.contains("hyprshell.mail") || a.contains_key("hyprshell-mail") {
        return ("mail".into(), it.label.clone(), sub);
    }
    if schema.contains("chrome") || it.label.contains("Safe Storage") || schema.contains("mozilla") {
        return ("globe".into(), it.label.clone(), if sub.is_empty() { "Browser".into() } else { sub });
    }
    if schema.contains("ssh") || it.label.contains("SSH") || it.label.starts_with("Unlock password for:") {
        return ("terminal".into(), it.label.clone(), sub);
    }
    if !server.is_empty() {
        return ("globe".into(), it.label.clone(), sub);
    }
    ("key".into(), it.label.clone(), sub)
}

fn friendly_attr(k: &str) -> String {
    match k {
        "xdg:schema" => "Kind".into(),
        "username" | "user" => "Username".into(),
        "server" | "host" => "Server".into(),
        "protocol" => "Protocol".into(),
        "connection-uuid" => "Connection".into(),
        "setting-name" => "Setting".into(),
        "setting-key" => "Field".into(),
        o => o.replace(['_', '-'], " "),
    }
}

// ── SSH ─────────────────────────────────────────────────────────────────

fn ssh_dir() -> PathBuf {
    kit::home().join(".ssh")
}

fn fingerprint(public: &str) -> String {
    use base64::Engine;
    use sha2::Digest;
    let Some(blob) = public.split_whitespace().nth(1) else { return String::new() };
    let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(blob) else { return String::new() };
    let sum = sha2::Sha256::digest(&raw);
    format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode(sum))
}

fn ssh_keys() -> Vec<SshKey> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(ssh_dir()) else { return out };
    let mut pubs: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.extension().map(|x| x == "pub").unwrap_or(false)).collect();
    pubs.sort();
    for p in pubs {
        let text = std::fs::read_to_string(&p).unwrap_or_default();
        let line = text.lines().next().unwrap_or("").trim().to_string();
        let mut parts = line.split_whitespace();
        let algo = parts.next().unwrap_or("");
        let _blob = parts.next();
        let comment = parts.collect::<Vec<_>>().join(" ");
        let kind = match algo {
            "ssh-ed25519" => "Ed25519",
            "ssh-rsa" => "RSA",
            a if a.starts_with("ecdsa") => "ECDSA",
            a if a.starts_with("sk-") => "Security key",
            _ => "Key",
        };
        let private = p.with_extension("");
        let priv_text = std::fs::read_to_string(&private).unwrap_or_default();
        // An OpenSSH private key says in its header whether it is
        // encrypted ("aes256-ctr" vs "none"); PEM keys say ENCRYPTED.
        let encrypted = if priv_text.contains("BEGIN OPENSSH PRIVATE KEY") {
            ssh_key::PrivateKey::from_openssh(&priv_text).map(|k| k.is_encrypted()).unwrap_or(false)
        } else {
            priv_text.contains("ENCRYPTED")
        };
        out.push(SshKey {
            name: private.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default().into(),
            kind: kind.into(),
            comment: comment.into(),
            fingerprint: fingerprint(&line).into(),
            has_private: private.exists(),
            encrypted,
            public: line.into(),
        });
    }
    out
}

fn new_ssh(name: &str, comment: &str, pass: &str) -> Result<(), String> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let name: String = name.chars().filter(|c| c.is_ascii_alphanumeric() || "._-".contains(*c)).collect();
    if name.is_empty() {
        return Err("Give it a file name".into());
    }
    let dir = ssh_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
    let path = dir.join(&name);
    if path.exists() || path.with_extension("pub").exists() {
        return Err(format!("~/.ssh/{name} already exists"));
    }
    let mut rng = rand_core::OsRng;
    let mut key = ssh_key::PrivateKey::random(&mut rng, ssh_key::Algorithm::Ed25519).map_err(|e| e.to_string())?;
    key.set_comment(comment);
    let public = key.public_key().to_openssh().map_err(|e| e.to_string())?;
    let key = if pass.is_empty() { key } else { key.encrypt(&mut rng, pass).map_err(|e| e.to_string())? };
    let private = key.to_openssh(ssh_key::LineEnding::LF).map_err(|e| e.to_string())?;
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).map_err(|e| e.to_string())?;
    use std::io::Write;
    f.write_all(private.as_bytes()).map_err(|e| e.to_string())?;
    std::fs::write(path.with_extension("pub"), format!("{public}\n")).map_err(|e| e.to_string())?;
    Ok(())
}

// ── GPG ─────────────────────────────────────────────────────────────────

fn gpg_keys() -> Option<Vec<GpgKey>> {
    let list = |args: &[&str]| Command::new("gpg").args(args).env("LANG", "C").output().ok().map(|o| String::from_utf8_lossy(&o.stdout).to_string());
    let public = list(&["--list-keys", "--with-colons", "--fixed-list-mode"])?;
    let secret = list(&["--list-secret-keys", "--with-colons", "--fixed-list-mode"]).unwrap_or_default();
    let secret_ids: Vec<String> = secret.lines().filter(|l| l.starts_with("sec:")).filter_map(|l| l.split(':').nth(4).map(|s| s.to_string())).collect();
    let date = |s: &str| -> String {
        let Ok(t) = s.parse::<i64>() else { return "never".into() };
        let (y, m, d, ..) = kit::local(t);
        format!("{d} {} {y}", ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][(m as usize + 11) % 12])
    };
    let mut out = Vec::new();
    let mut cur: Option<GpgKey> = None;
    for l in public.lines() {
        let f: Vec<&str> = l.split(':').collect();
        match f.first().copied() {
            Some("pub") => {
                if let Some(k) = cur.take() {
                    out.push(k);
                }
                let algo = match f.get(3).copied().unwrap_or("") {
                    "1" => "RSA",
                    "17" => "DSA",
                    "18" => "ECDH",
                    "19" => "ECDSA",
                    "22" => "EdDSA",
                    _ => "Key",
                };
                let id = f.get(4).copied().unwrap_or("").to_string();
                cur = Some(GpgKey {
                    secret: secret_ids.contains(&id),
                    id: id.into(),
                    uid: SharedString::new(),
                    kind: format!("{algo} {}", f.get(2).copied().unwrap_or("")).trim().to_string().into(),
                    created: date(f.get(5).copied().unwrap_or("")).into(),
                    expires: f.get(6).filter(|x| !x.is_empty()).map(|x| date(x)).unwrap_or_else(|| "never".into()).into(),
                });
            }
            Some("uid") => {
                if let Some(k) = cur.as_mut() {
                    if k.uid.is_empty() {
                        k.uid = f.get(9).copied().unwrap_or("").replace("\\x3a", ":").into();
                    }
                }
            }
            _ => {}
        }
    }
    if let Some(k) = cur {
        out.push(k);
    }
    Some(out)
}

/// Text to the clipboard through wl-copy's stdin (never its arguments),
/// for things that are not secrets and should outlive this window.
fn copy_plain(text: &str) -> Result<(), String> {
    let mut child = Command::new("wl-copy").stdin(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    use std::io::Write;
    child.stdin.take().unwrap().write_all(text.as_bytes()).map_err(|e| e.to_string())?;
    child.wait().map_err(|e| e.to_string())?;
    Ok(())
}

// ── the window ──────────────────────────────────────────────────────────

struct App {
    ui: slint::Weak<AppWindow>,
    ring: RefCell<Option<Keyring>>,
    rings: RefCell<Vec<RingInfo>>,
    items: RefCell<Vec<ItemInfo>>,
    shown: RefCell<Vec<ItemInfo>>,
    toast_timer: slint::Timer,
}

impl App {
    fn ui(&self) -> AppWindow {
        self.ui.upgrade().unwrap()
    }
    fn toast(&self, t: &str, bad: bool) {
        let ui = self.ui();
        ui.global::<Keys>().set_toast(t.into());
        ui.global::<Keys>().set_toast_bad(bad);
        let w = self.ui.clone();
        self.toast_timer.start(slint::TimerMode::SingleShot, Duration::from_millis(3000), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Keys>().set_toast(SharedString::new());
            }
        });
    }
    fn forget_secret(&self) {
        let ui = self.ui();
        ui.global::<Keys>().set_secret(SharedString::new());
        ui.global::<Keys>().set_secret_shown(false);
    }

    fn load(self: &Rc<Self>) {
        let a = self.clone();
        kit::spawn(
            || {
                let ring = Keyring::open();
                let rings = ring.as_ref().ok().map(|r| r.rings());
                (ring, rings, ssh_keys(), gpg_keys())
            },
            move |(ring, rings, ssh, gpg)| {
                let ui = a.ui();
                let g = ui.global::<Keys>();
                g.set_ready(true);
                g.set_ssh(ModelRc::new(VecModel::from(ssh)));
                g.set_has_gpg(gpg.is_some());
                g.set_gpg(ModelRc::new(VecModel::from(gpg.unwrap_or_default())));
                match (ring, rings) {
                    (Ok(r), Some(Ok(list))) => {
                        g.set_problem("".into());
                        *a.ring.borrow_mut() = Some(r);
                        let rows: Vec<Ring> = list
                            .iter()
                            .map(|r| Ring {
                                path: r.path.clone().into(),
                                label: if r.label == "login" || r.label == "Login" { "Login".into() } else { r.label.clone().into() },
                                locked: r.locked,
                                count: r.items.len() as i32,
                                is_default: r.default,
                            })
                            .collect();
                        g.set_rings(ModelRc::new(VecModel::from(rows)));
                        let place = g.get_place().to_string();
                        if place.is_empty() || (!place.starts_with('@') && !list.iter().any(|r| r.path == place)) {
                            let first = list.first().map(|r| r.path.clone()).unwrap_or_else(|| "@ssh".into());
                            g.set_place(first.into());
                        }
                        *a.rings.borrow_mut() = list;
                        a.show_ring();
                    }
                    (Err(e), _) | (_, Some(Err(e))) => {
                        g.set_problem(format!("Passwords are kept by a Secret Service keyring (gnome-keyring or KeePassXC). None answered: {e}").into());
                        if g.get_place().is_empty() {
                            g.set_place("@ssh".into());
                        }
                    }
                    _ => {}
                }
            },
        );
    }

    fn show_ring(self: &Rc<Self>) {
        let ui = self.ui();
        let g = ui.global::<Keys>();
        let place = g.get_place().to_string();
        self.forget_secret();
        g.set_item(-1);
        let Some(ring) = self.rings.borrow().iter().find(|r| r.path == place).cloned() else { return };
        g.set_ring_label(if ring.label.eq_ignore_ascii_case("login") { "Login".into() } else { ring.label.clone().into() });
        g.set_ring_locked(ring.locked);
        if ring.locked {
            self.items.borrow_mut().clear();
            g.set_items(ModelRc::new(VecModel::from(Vec::<Item>::new())));
            return;
        }
        let Some(kr) = self.ring.borrow().clone() else { return };
        let a = self.clone();
        kit::spawn(
            move || {
                let mut v: Vec<ItemInfo> = ring.items.iter().map(|i| kr.item(i)).collect();
                v.sort_by(|a, b| a.label.to_lowercase().cmp(&b.label.to_lowercase()));
                v
            },
            move |items| {
                *a.items.borrow_mut() = items;
                a.filter();
            },
        );
    }

    fn filter(&self) {
        let ui = self.ui();
        let g = ui.global::<Keys>();
        let q = g.get_search().to_lowercase();
        let shown: Vec<ItemInfo> = self
            .items
            .borrow()
            .iter()
            .filter(|i| q.is_empty() || i.label.to_lowercase().contains(&q) || i.attrs.iter().any(|(_, v)| v.to_lowercase().contains(&q)))
            .cloned()
            .collect();
        let rows: Vec<Item> = shown
            .iter()
            .map(|i| {
                let (icon, label, sub) = describe(i);
                Item { path: i.path.clone().into(), label: label.into(), sub: sub.into(), icon: icon.into(), when: kit::when(i.modified as i64).into() }
            })
            .collect();
        g.set_items(ModelRc::new(VecModel::from(rows)));
        *self.shown.borrow_mut() = shown;
    }

    fn current(&self) -> Option<ItemInfo> {
        let i = self.ui().global::<Keys>().get_item();
        if i < 0 {
            return None;
        }
        self.shown.borrow().get(i as usize).cloned()
    }

    fn after<T: Send + 'static>(self: &Rc<Self>, work: impl FnOnce(Keyring) -> Result<T, String> + Send + 'static, ok: &'static str) {
        let Some(kr) = self.ring.borrow().clone() else { return };
        let a = self.clone();
        kit::spawn(
            move || work(kr),
            move |r| {
                match r {
                    Ok(_) => {
                        if !ok.is_empty() {
                            a.toast(ok, false);
                        }
                    }
                    Err(e) => a.toast(&e, true),
                }
                a.load();
            },
        );
    }
}

fn main() {
    kit::init("hyprshell-keys");
    let ui = AppWindow::new().expect("window");
    kit::setup!(ui, "hyprshell-keys");
    let app = Rc::new(App {
        ui: ui.as_weak(),
        ring: RefCell::new(None),
        rings: RefCell::new(Vec::new()),
        items: RefCell::new(Vec::new()),
        shown: RefCell::new(Vec::new()),
        toast_timer: slint::Timer::default(),
    });
    if let Ok(p) = std::env::var("HYPRSHELL_KEYS_PAGE") {
        ui.global::<Keys>().set_place(p.into());
    }
    app.load();

    let g = ui.global::<Keys>();
    let a = app.clone();
    g.on_pick(move |p| {
        let ui = a.ui();
        ui.global::<Keys>().set_place(p.clone());
        ui.global::<Keys>().set_search("".into());
        if !p.starts_with('@') {
            a.show_ring();
        }
    });
    let a = app.clone();
    g.on_searched(move |_| a.filter());
    let a = app.clone();
    g.on_pick_item(move |i| {
        a.forget_secret();
        let ui = a.ui();
        let g = ui.global::<Keys>();
        g.set_item(i);
        if let Some(it) = a.current() {
            let (_, label, _) = describe(&it);
            g.set_detail_label(label.into());
            g.set_detail_attrs(ModelRc::new(VecModel::from(
                it.attrs.iter().filter(|(k, _)| k != "xdg:schema").map(|(k, v)| Attr { key: friendly_attr(k).into(), value: v.into() }).collect::<Vec<_>>(),
            )));
            g.set_detail_created(if it.created > 0 { kit::when(it.created as i64) } else { "—".into() }.into());
            g.set_detail_modified(if it.modified > 0 { kit::when(it.modified as i64) } else { "—".into() }.into());
        }
    });
    let a = app.clone();
    g.on_show_secret(move || {
        let (Some(it), Some(kr)) = (a.current(), a.ring.borrow().clone()) else { return };
        let b = a.clone();
        kit::spawn(
            move || kr.secret(&it.path),
            move |r| match r {
                Ok(s) => {
                    let ui = b.ui();
                    ui.global::<Keys>().set_secret(s.into());
                    ui.global::<Keys>().set_secret_shown(true);
                }
                Err(e) => b.toast(&e, true),
            },
        );
    });
    let a = app.clone();
    g.on_hide_secret(move || a.forget_secret());
    let a = app.clone();
    g.on_copy_secret(move || {
        let (Some(it), Some(kr)) = (a.current(), a.ring.borrow().clone()) else { return };
        let b = a.clone();
        kit::spawn(
            move || kr.secret(&it.path).and_then(|s| clip::copy(s, true, Duration::from_secs(45))),
            move |r| match r {
                Ok(_) => b.toast("Copied — it leaves the clipboard in 45 seconds", false),
                Err(e) => b.toast(&e, true),
            },
        );
    });
    let a = app.clone();
    g.on_copy_text(move |t| match copy_plain(&t) {
        Ok(_) => a.toast("Copied", false),
        Err(e) => a.toast(&e, true),
    });
    let a = app.clone();
    g.on_rename(move |label| {
        let Some(it) = a.current() else { return };
        let label = label.to_string();
        a.after(move |kr| kr.rename(&it.path, &label), "Renamed");
    });
    let a = app.clone();
    g.on_delete_item(move || {
        let Some(it) = a.current() else { return };
        a.forget_secret();
        a.after(move |kr| kr.delete(&it.path), "Deleted");
    });
    let a = app.clone();
    g.on_add(move |label, user, place, secret| {
        let ring = a.ui().global::<Keys>().get_place().to_string();
        let mut attrs = HashMap::new();
        attrs.insert("xdg:schema".to_string(), "org.freedesktop.Secret.Generic".to_string());
        if !user.is_empty() {
            attrs.insert("username".into(), user.to_string());
        }
        if !place.is_empty() {
            attrs.insert("server".into(), place.to_string());
        }
        let (label, secret) = (label.to_string(), secret.to_string());
        a.after(move |kr| kr.add(&ring, &label, attrs, &secret), "Saved");
    });
    let a = app.clone();
    g.on_unlock(move |p| {
        let p = p.to_string();
        a.after(move |kr| kr.unlock(&p), "");
    });
    let a = app.clone();
    g.on_lock(move |p| {
        let p = p.to_string();
        a.forget_secret();
        a.after(move |kr| kr.lock(&p), "Locked");
    });
    let a = app.clone();
    g.on_new_keyring(move |label| {
        let label = label.trim().to_string();
        if label.is_empty() {
            return;
        }
        a.after(move |kr| kr.new_ring(&label), "Keyring made");
    });
    let a = app.clone();
    g.on_new_ssh(move |name, comment, pass| {
        let (name, comment, pass) = (name.to_string(), comment.to_string(), pass.to_string());
        let b = a.clone();
        kit::spawn(
            move || new_ssh(&name, &comment, &pass),
            move |r| {
                match r {
                    Ok(_) => b.toast("Key made — copy its public half to where it should log in", false),
                    Err(e) => b.toast(&e, true),
                }
                b.ui().global::<Keys>().set_ssh(ModelRc::new(VecModel::from(ssh_keys())));
            },
        );
    });
    let a = app.clone();
    g.on_delete_ssh(move |name| {
        let p = ssh_dir().join(name.as_str());
        let r = kit::trash(&p.with_extension("pub")).and_then(|_| if p.exists() { kit::trash(&p) } else { Ok(()) });
        match r {
            Ok(_) => a.toast("Moved to the Trash", false),
            Err(e) => a.toast(&e.to_string(), true),
        }
        a.ui().global::<Keys>().set_ssh(ModelRc::new(VecModel::from(ssh_keys())));
    });
    let a = app.clone();
    g.on_export_gpg(move |id| {
        let out = Command::new("gpg").args(["--armor", "--export", id.as_str()]).output();
        match out {
            Ok(o) if o.status.success() && !o.stdout.is_empty() => match copy_plain(&String::from_utf8_lossy(&o.stdout)) {
                Ok(_) => a.toast("Public key copied", false),
                Err(e) => a.toast(&e, true),
            },
            _ => a.toast("gpg couldn't export it", true),
        }
    });
    // HYPRSHELL_KEYS_PEEK=row opens that item and shows its password (for
    // screenshots and tests).
    let peek = slint::Timer::default();
    if let Some(i) = std::env::var("HYPRSHELL_KEYS_PEEK").ok().and_then(|v| v.parse::<i32>().ok()) {
        let w = ui.as_weak();
        peek.start(slint::TimerMode::SingleShot, Duration::from_millis(1500), move || {
            if let Some(ui) = w.upgrade() {
                ui.global::<Keys>().invoke_pick_item(i);
                ui.global::<Keys>().invoke_show_secret();
            }
        });
    }
    ui.run().expect("run");
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fingerprints() {
        // From ssh-keygen -lf on this public key.
        let k = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl test";
        assert!(fingerprint(k).starts_with("SHA256:"));
    }
    #[test]
    fn makes_ssh_keys() {
        let dir = std::env::temp_dir().join(format!("hs-keys-{}", std::process::id()));
        std::env::set_var("HOME", &dir);
        new_ssh("id_test", "me@test", "a passphrase").unwrap();
        let keys = ssh_keys();
        assert_eq!(keys.len(), 1);
        assert!(keys[0].encrypted && keys[0].has_private);
        assert_eq!(keys[0].kind, "Ed25519");
        assert!(new_ssh("id_test", "", "").is_err());
        // OpenSSH itself takes it, with the passphrase (from stdin's file,
        // never an argument in real use; fine in a test).
        if std::process::Command::new("ssh-keygen").arg("-?").output().is_ok() {
            let out = std::process::Command::new("ssh-keygen").args(["-y", "-P", "a passphrase", "-f"]).arg(dir.join(".ssh/id_test")).output().unwrap();
            assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
            let wrong = std::process::Command::new("ssh-keygen").args(["-y", "-P", "wrong", "-f"]).arg(dir.join(".ssh/id_test")).output().unwrap();
            assert!(!wrong.status.success());
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
    #[test]
    fn kinds() {
        let it = ItemInfo { label: "Network secret for Home".into(), attrs: vec![("xdg:schema".into(), "org.freedesktop.NetworkManager.Connection".into()), ("connection-uuid".into(), "x".into())], ..Default::default() };
        assert_eq!(describe(&it).0, "wifi");
        assert_eq!(describe(&it).1, "Home");
    }
}
