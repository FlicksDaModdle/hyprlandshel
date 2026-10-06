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
    let keyring = oo7::Keyring::new().await.map_err(explain)?;
    let _ = keyring.unlock().await;
    keyring
        .create_item(
            &format!("Hyprshell Mail: {}", account),
            &[("application", "hyprshell-mail"), ("account", account), ("kind", kind)],
            secret,
            true,
        )
        .await
        .map_err(explain)
}

pub async fn load(account: &str, kind: &str) -> Result<Option<String>, String> {
    if let Some(p) = insecure_path() {
        let m = read_file(&p);
        return Ok(m
            .get(&format!("{}/{}", account, kind))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()));
    }
    let keyring = oo7::Keyring::new().await.map_err(explain)?;
    let _ = keyring.unlock().await;
    let items = keyring
        .search_items(&[("application", "hyprshell-mail"), ("account", account), ("kind", kind)])
        .await
        .map_err(explain)?;
    let Some(item) = items.into_iter().next() else {
        return Ok(None);
    };
    if item.is_locked().await.unwrap_or(false) {
        let _ = item.unlock().await;
    }
    let secret = item.secret().await.map_err(explain)?;
    Ok(Some(String::from_utf8_lossy(secret.as_bytes()).to_string()))
}

pub async fn forget(account: &str) {
    if let Some(p) = insecure_path() {
        let mut m = read_file(&p);
        m.retain(|k, _| !k.starts_with(&format!("{}/", account)));
        let _ = write_file(&p, &m);
        return;
    }
    if let Ok(keyring) = oo7::Keyring::new().await {
        let _ = keyring
            .delete(&[("application", "hyprshell-mail"), ("account", account)])
            .await;
    }
}

/// Whether there is a keyring to keep anything in.
pub async fn available() -> Result<(), String> {
    if insecure_path().is_some() {
        return Ok(());
    }
    oo7::Keyring::new().await.map(|_| ()).map_err(explain)
}
