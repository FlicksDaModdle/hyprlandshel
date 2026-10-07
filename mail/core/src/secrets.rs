// Passwords and sign-in tokens, kept in the desktop's keyring (the Secret
// Service: GNOME Keyring, KWallet, KeePassXC) and nowhere else — not in the
// database, not in a settings file, never on a command line.
//
// Each is an item labelled "Hyprshell Mail: <account>" with the attributes
// application=hyprshell-mail, account=<id>, kind=password|refresh.
//
// HYPRSHELL_MAIL_INSECURE_SECRETS=<file> keeps them in a plain file
// instead, readable only by you. It is for tests, where there is no keyring
// to talk to; nothing sets it otherwise.

use serde_json::{Map, Value};
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::Duration;

// One keyring conversation at a time: four connections asking at once for
// a locked keyring meant four unlock windows. And what has been read once
// is remembered for as long as the service runs, so the keyring is asked
// at startup and when something changes, not before every sign-in.
fn gate() -> &'static tokio::sync::Mutex<HashMap<String, String>> {
    static G: OnceLock<tokio::sync::Mutex<HashMap<String, String>>> = OnceLock::new();
    G.get_or_init(|| tokio::sync::Mutex::new(HashMap::new()))
}

const LOCKED: &str = "The keyring is locked, and Mail can't read your sign-ins until it's unlocked — \
    the unlock window didn't appear, or was closed. Unlock it in Passwords and Keys (seahorse); \
    `hyprshell-maild --status` says how to have it unlock when you log in.";

/// A keyring call, given `secs` to finish: one that waits on a locked
/// keyring with no unlock window to answer would otherwise wait forever,
/// and every check for mail with it.
async fn timed<T>(secs: u64, f: impl std::future::Future<Output = Result<T, oo7::Error>>) -> Result<T, String> {
    match tokio::time::timeout(Duration::from_secs(secs), f).await {
        Ok(r) => r.map_err(explain),
        Err(_) => Err(LOCKED.to_string()),
    }
}

/// Unlocks, with long enough to type a password into the window if one
/// comes up.
async fn unlock(keyring: &oo7::Keyring) -> Result<(), String> {
    if let Ok(Ok(false)) = tokio::time::timeout(Duration::from_secs(10), keyring.is_locked()).await {
        return Ok(());
    }
    match tokio::time::timeout(Duration::from_secs(120), keyring.unlock()).await {
        Ok(Ok(_)) => Ok(()),
        Ok(Err(e)) => Err(explain(e)),
        Err(_) => Err(LOCKED.to_string()),
    }
}

fn insecure_path() -> Option<String> {
    std::env::var("HYPRSHELL_MAIL_INSECURE_SECRETS").ok().filter(|s| !s.is_empty())
}

fn read_file(path: &str) -> Map<String, Value> {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

fn write_file(path: &str, map: &Map<String, Value>) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| e.to_string())?;
    f.write_all(Value::Object(map.clone()).to_string().as_bytes())
        .map_err(|e| e.to_string())
}

fn explain(e: oo7::Error) -> String {
    // A locked keyring whose unlock window couldn't be shown, or was
    // closed, comes back as a dismissed prompt — not a missing keyring.
    let said = e.to_string();
    let l = said.to_ascii_lowercase();
    if l.contains("dismissed") || l.contains("locked") || l.contains("prompt") {
        return format!("{} ({})", LOCKED, said);
    }
    format!(
        "The keyring is not available ({}). Mail keeps passwords in the desktop keyring: \
         install gnome-keyring (or KeePassXC with Secret Service on) and log in again.",
        e
    )
}

pub async fn store(account: &str, kind: &str, secret: &str) -> Result<(), String> {
    if let Some(p) = insecure_path() {
        let mut m = read_file(&p);
        m.insert(format!("{}/{}", account, kind), Value::String(secret.to_string()));
        return write_file(&p, &m);
    }
    let mut cache = gate().lock().await;
    let keyring = timed(20, oo7::Keyring::new()).await?;
    unlock(&keyring).await?;
    timed(
        30,
        keyring.create_item(
            &format!("Hyprshell Mail: {}", account),
            &[("application", "hyprshell-mail"), ("account", account), ("kind", kind)],
            secret,
            true,
        ),
    )
    .await?;
    cache.insert(format!("{}/{}", account, kind), secret.to_string());
    Ok(())
}

pub async fn load(account: &str, kind: &str) -> Result<Option<String>, String> {
    if let Some(p) = insecure_path() {
        let m = read_file(&p);
        return Ok(m
            .get(&format!("{}/{}", account, kind))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()));
    }
    let mut cache = gate().lock().await;
    let key = format!("{}/{}", account, kind);
    if let Some(v) = cache.get(&key) {
        return Ok(Some(v.clone()));
    }
    let keyring = timed(20, oo7::Keyring::new()).await?;
    unlock(&keyring).await?;
    let items = timed(
        30,
        keyring.search_items(&[("application", "hyprshell-mail"), ("account", account), ("kind", kind)]),
    )
    .await?;
    let Some(item) = items.into_iter().next() else {
        return Ok(None);
    };
    if item.is_locked().await.unwrap_or(false) {
        match tokio::time::timeout(Duration::from_secs(120), item.unlock()).await {
            Ok(_) => {}
            Err(_) => return Err(LOCKED.to_string()),
        }
    }
    let secret = timed(30, item.secret()).await?;
    let v = String::from_utf8_lossy(secret.as_bytes()).to_string();
    cache.insert(key, v.clone());
    Ok(Some(v))
}

pub async fn forget(account: &str) {
    gate().lock().await.retain(|k, _| !k.starts_with(&format!("{}/", account)));
    if let Some(p) = insecure_path() {
        let mut m = read_file(&p);
        m.retain(|k, _| !k.starts_with(&format!("{}/", account)));
        let _ = write_file(&p, &m);
        return;
    }
    if let Ok(keyring) = timed(20, oo7::Keyring::new()).await {
        let _ = timed(30, keyring.delete(&[("application", "hyprshell-mail"), ("account", account)])).await;
    }
}

/// Whether there is a keyring to keep anything in.
pub async fn available() -> Result<(), String> {
    if insecure_path().is_some() {
        return Ok(());
    }
    timed(20, oo7::Keyring::new()).await.map(|_| ())
}
