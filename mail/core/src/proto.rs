// The commands the app (and the shell) send, one JSON object a line:
//   → {"rid": 7, "cmd": "list", "view": "inbox"}
//   ← {"rid": 7, "ok": true, "result": {...}}   or   {"rid": 7, "ok": false, "error": "…"}
// (`rid` is the caller's own number for matching answers to questions;
// `id`, where a command takes one, is a message's.)
// and events, unasked, to everyone connected:
//   ← {"event": "changed", "account": "…", "folder": "…"}
//
// The commands are listed in `handle`, each with what it takes.

use crate::account::{self, Account};
use crate::db::{self, now, SUMMARY_COLS};
use crate::imap;
use crate::ics;
use crate::oauth;
use crate::parse;
use crate::secrets;
use crate::smtp;
use crate::state::{AccountRt, State};
use rusqlite::params;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;

type R = Result<Value, String>;

fn s<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("")
}
fn i(v: &Value, k: &str) -> Option<i64> {
    v.get(k).and_then(|x| x.as_i64().or_else(|| x.as_str().and_then(|s| s.parse().ok())))
}
fn ids(v: &Value) -> Vec<i64> {
    match v.get("ids").or_else(|| v.get("id")) {
        Some(Value::Array(a)) => a.iter().filter_map(|x| x.as_i64()).collect(),
        Some(x) => x.as_i64().into_iter().collect(),
        None => vec![],
    }
}

/// With "thread": true, each message stands for its whole conversation:
/// every message of it in the same folder (for moves), or anywhere in the
/// account (for flags — a conversation is read when all of it is).
fn expand(state: &Arc<State>, req: &Value, same_folder: bool) -> Vec<i64> {
    let base = ids(req);
    if !req.get("thread").and_then(|x| x.as_bool()).unwrap_or(false) {
        return base;
    }
    let db = state.db.lock().unwrap();
    let mut out: Vec<i64> = vec![];
    for id in base {
        let row: Option<(String, String, String)> = db.conn
            .query_row("SELECT account, thread, folder FROM messages WHERE id = ?", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .ok();
        let Some((a, t, f)) = row else { continue };
        let sql = if same_folder {
            "SELECT id FROM messages WHERE account = ?1 AND thread = ?2 AND folder = ?3"
        } else {
            "SELECT m.id FROM messages m JOIN folders fo ON fo.account = m.account AND fo.path = m.folder \
             WHERE m.account = ?1 AND m.thread = ?2 AND (fo.role NOT IN ('trash', 'junk') OR m.folder = ?3)"
        };
        if let Ok(mut st) = db.conn.prepare(sql) {
            if let Ok(rows) = st.query_map(params![a, t, f], |r| r.get::<_, i64>(0)) {
                out.extend(rows.flatten());
            }
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

pub async fn handle(state: &Arc<State>, req: &Value) -> R {
    match s(req, "cmd") {
        "ping" => Ok(json!("pong")),
        "status" => status(state).await,

        // ── accounts ──
        "accounts.list" => accounts_list(state).await,
        "accounts.autoconfig" => Ok(account::autoconfig(s(req, "email")).await),
        "accounts.preset" => Ok(account::preset(s(req, "provider")).unwrap_or(Value::Null)),
        "accounts.test" => accounts_test(state, req).await,
        "accounts.save" => accounts_save(state, req).await,
        "accounts.remove" => accounts_remove(state, s(req, "account")).await,
        "accounts.reorder" => accounts_reorder(state, req).await,
        "keyring.check" => secrets::available().await.map(|_| json!(true)),

        // ── signing in ──
        "oauth.begin" => oauth_begin(state, req).await,
        "oauth.clients" => Ok(oauth_clients(state)),
        "oauth.setClient" => {
            let p = s(req, "provider");
            let db = state.db.lock().unwrap();
            db.set_setting(&format!("oauth.{}.clientId", p), s(req, "clientId").trim());
            // An empty secret leaves the one saved alone ("Unchanged").
            if !s(req, "clientSecret").trim().is_empty() || req.get("clearSecret").and_then(|x| x.as_bool()).unwrap_or(false) {
                db.set_setting(&format!("oauth.{}.clientSecret", p), s(req, "clientSecret").trim());
            }
            Ok(json!(true))
        }

        // ── reading ──
        "folders" => {
            let a = req.get("account").and_then(|x| x.as_str());
            Ok(json!(state.db.lock().unwrap().folders(a)))
        }
        "list" => list(state, req),
        "thread" => thread(state, req),
        "search" => search(state, req),
        "get" => get(state, req).await,
        "part.save" => part_save(state, req).await,
        "sync" => {
            let accts = state.accounts.read().await;
            for (id, rt) in accts.iter() {
                if s(req, "account").is_empty() || s(req, "account") == id {
                    rt.wake.notify_one();
                }
            }
            Ok(json!(true))
        }

        // ── acting ──
        "flag" => {
            let what = s(req, "flag");
            let on = req.get("value").and_then(|x| x.as_bool()).unwrap_or(true);
            act(state, &expand(state, req, false), Action::Flag(what.to_string(), on)).await
        }
        "move" => act(state, &expand(state, req, true), Action::Move(s(req, "to").to_string())).await,
        "archive" => act(state, &expand(state, req, true), Action::Move("archive".into())).await,
        "trash" => act(state, &expand(state, req, true), Action::Move("trash".into())).await,
        "spam" => act(state, &expand(state, req, true), Action::Move("junk".into())).await,
        "notSpam" => act(state, &expand(state, req, true), Action::Move("inbox".into())).await,
        "deleteForever" => act(state, &expand(state, req, true), Action::DeleteForever).await,

        // ── writing ──
        "send" => send(state, req).await,
        "outbox.list" => outbox_list(state),
        "outbox.cancel" => {
            let id = i(req, "id").unwrap_or(0);
            let payload: Option<String> = state.db.lock().unwrap().conn
                .query_row("SELECT payload FROM outbox WHERE id = ?", [id], |r| r.get(0)).ok();
            state.db.lock().unwrap().conn.execute("DELETE FROM outbox WHERE id = ?", [id]).map_err(|e| e.to_string())?;
            state.emit("outbox", json!({}));
            Ok(payload.and_then(|p| serde_json::from_str(&p).ok()).unwrap_or(Value::Null))
        }
        "outbox.sendNow" => {
            let id = i(req, "id").unwrap_or(0);
            state.db.lock().unwrap().conn
                .execute("UPDATE outbox SET send_at = 0, error = '' WHERE id = ?", [id]).map_err(|e| e.to_string())?;
            state.sched.notify_one();
            Ok(json!(true))
        }
        "drafts.save" => drafts_save(state, req),
        "drafts.list" => drafts_list(state),
        "drafts.delete" => {
            state.db.lock().unwrap().conn.execute("DELETE FROM drafts WHERE id = ?", [i(req, "id").unwrap_or(0)]).map_err(|e| e.to_string())?;
            state.emit("drafts", json!({}));
            Ok(json!(true))
        }

        // ── snoozing ──
        "snooze" => {
            let until = i(req, "until").ok_or("When should it come back?")?;
            {
                let list = expand(state, req, true);
                let db = state.db.lock().unwrap();
                for id in list {
                    let _ = db.conn.execute(
                        "INSERT INTO snoozed (message, until) VALUES (?, ?) ON CONFLICT(message) DO UPDATE SET until = excluded.until",
                        params![id, until],
                    );
                }
            }
            state.emit("changed", json!({}));
            state.emit_unread();
            state.sched.notify_one();
            Ok(json!(true))
        }
        "unsnooze" => {
            {
                let db = state.db.lock().unwrap();
                for id in ids(req) {
                    let _ = db.conn.execute("DELETE FROM snoozed WHERE message = ?", [id]);
                    let _ = db.conn.execute("UPDATE messages SET sort_date = ? WHERE id = ?", params![now(), id]);
                }
            }
            state.emit("changed", json!({}));
            state.emit_unread();
            Ok(json!(true))
        }

        // ── contacts ──
        "contacts.search" => contacts_search(state, req),
        "contacts.list" => contacts_search(state, &json!({ "q": "", "limit": 2000 })),
        "contacts.save" => {
            let db = state.db.lock().unwrap();
            db.conn.execute(
                "INSERT INTO contacts (email, name, score, last_used, manual) VALUES (?1, ?2, 5, ?3, 1) \
                 ON CONFLICT(email) DO UPDATE SET name = excluded.name, manual = 1, hidden = 0",
                params![s(req, "email").trim(), s(req, "name").trim(), now()],
            ).map_err(|e| e.to_string())?;
            Ok(json!(true))
        }
        "contacts.delete" => {
            state.db.lock().unwrap().conn
                .execute("UPDATE contacts SET hidden = 1 WHERE email = ?", [s(req, "email")]).map_err(|e| e.to_string())?;
            Ok(json!(true))
        }

        // ── templates ──
        "templates.list" => {
            let db = state.db.lock().unwrap();
            let mut st = db.conn.prepare("SELECT id, name, subject, body FROM templates ORDER BY name").map_err(|e| e.to_string())?;
            let rows: Vec<Value> = st
                .query_map([], |r| Ok(json!({ "id": r.get::<_, i64>(0)?, "name": r.get::<_, String>(1)?,
                    "subject": r.get::<_, String>(2)?, "body": r.get::<_, String>(3)? })))
                .map_err(|e| e.to_string())?
                .flatten()
                .collect();
            Ok(json!(rows))
        }
        "templates.save" => {
            let db = state.db.lock().unwrap();
            match i(req, "id") {
                Some(id) if id > 0 => {
                    db.conn.execute("UPDATE templates SET name = ?, subject = ?, body = ? WHERE id = ?",
                        params![s(req, "name"), s(req, "subject"), s(req, "body"), id]).map_err(|e| e.to_string())?;
                    Ok(json!(id))
                }
                _ => {
                    db.conn.execute("INSERT INTO templates (name, subject, body) VALUES (?, ?, ?)",
                        params![s(req, "name"), s(req, "subject"), s(req, "body")]).map_err(|e| e.to_string())?;
                    Ok(json!(db.conn.last_insert_rowid()))
                }
            }
        }
        "templates.delete" => {
            state.db.lock().unwrap().conn.execute("DELETE FROM templates WHERE id = ?", [i(req, "id").unwrap_or(0)]).map_err(|e| e.to_string())?;
            Ok(json!(true))
        }

        // ── invitations and the calendar ──
        "invite.respond" => invite_respond(state, req).await,
        "events.list" => {
            let from = i(req, "from").unwrap_or(0);
            let to = i(req, "to").unwrap_or(i64::MAX);
            let db = state.db.lock().unwrap();
            let mut st = db.conn.prepare("SELECT data FROM events").map_err(|e| e.to_string())?;
            let rows: Vec<Value> = st
                .query_map([], |r| r.get::<_, String>(0))
                .map_err(|e| e.to_string())?
                .flatten()
                .filter_map(|d| serde_json::from_str::<Value>(&d).ok())
                .filter(|e| e["end"].as_i64().unwrap_or(0) >= from && e["start"].as_i64().unwrap_or(0) <= to)
                .collect();
            Ok(json!(rows))
        }

        // ── settings ──
        "settings.get" => Ok(state.db.lock().unwrap().settings()),
        "settings.set" => {
            let k = s(req, "key");
            if k.starts_with("oauth.") {
                return Err("Use oauth.setClient".into());
            }
            let v = req.get("value").cloned().unwrap_or(Value::Null);
            state.db.lock().unwrap().set_setting(k, &v.to_string());
            state.emit("settings", json!({ "key": k, "value": v }));
            Ok(json!(true))
        }
        other => Err(format!("Unknown command: {}", other)),
    }
}

// ── status and accounts ───────────────────────────────────────────────────
async fn status(state: &Arc<State>) -> R {
    let accts = state.accounts.read().await;
    let list: Vec<Value> = accts
        .values()
        .map(|rt| json!({
            "id": rt.id(),
            "status": *rt.status.lock().unwrap(),
            "error": *rt.error.lock().unwrap(),
        }))
        .collect();
    let db = state.db.lock().unwrap();
    Ok(json!({ "accounts": list, "unread": db.unread_inbox(), "byAccount": db.unread_by_account() }))
}

async fn accounts_list(state: &Arc<State>) -> R {
    let rows: Vec<(String, i64)> = {
        let db = state.db.lock().unwrap();
        let mut st = db.conn.prepare("SELECT data, position FROM accounts ORDER BY position, id").map_err(|e| e.to_string())?;
        let r: Vec<(String, i64)> = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).map_err(|e| e.to_string())?.flatten().collect();
        r
    };
    let accts = state.accounts.read().await;
    let mut out = vec![];
    for (data, _) in rows {
        let mut v: Value = serde_json::from_str(&data).unwrap_or(json!({}));
        let id = v["id"].as_str().unwrap_or("").to_string();
        if let Some(rt) = accts.get(&id) {
            v["status"] = json!(*rt.status.lock().unwrap());
            v["error"] = json!(*rt.error.lock().unwrap());
        }
        out.push(v);
    }
    Ok(json!(out))
}

fn account_from(req: &Value) -> Result<Account, String> {
    let mut a: Account = serde_json::from_value(req.get("account").cloned().unwrap_or(json!({}))).map_err(|e| e.to_string())?;
    a.email = a.email.trim().to_string();
    if a.email.is_empty() || !a.email.contains('@') {
        return Err("Enter the account's email address".into());
    }
    if a.auth.is_empty() {
        a.auth = "password".into();
    }
    if a.provider.is_empty() {
        a.provider = "imap".into();
    }
    if a.imap_port == 0 {
        a.imap_port = if a.imap_security == "starttls" || a.imap_security == "none" { 143 } else { 993 };
    }
    if a.smtp_port == 0 {
        a.smtp_port = match a.smtp_security.as_str() { "tls" => 465, "none" => 25, _ => 587 };
    }
    if a.imap_security.is_empty() { a.imap_security = "tls".into(); }
    if a.smtp_security.is_empty() { a.smtp_security = "starttls".into(); }
    if a.name.is_empty() {
        a.name = a.email.clone();
    }
    if a.sync_days == 0 {
        a.sync_days = 60;
    }
    Ok(a)
}

fn new_id(email: &str) -> String {
    let base: String = email
        .split('@')
        .next()
        .unwrap_or("account")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .take(16)
        .collect();
    format!("{}-{:06x}", if base.is_empty() { "account".into() } else { base }, rand::random::<u32>() & 0xffffff)
}

/// Signs in to both servers with what was given, without saving anything.
async fn accounts_test(state: &Arc<State>, req: &Value) -> R {
    let mut a = account_from(req)?;
    if a.id.is_empty() {
        a.id = s(req, "pendingId").to_string();
    }
    let auth = if a.auth == "oauth" {
        imap::credentials(state, &a).await?
    } else {
        let p = s(req, "password");
        if p.is_empty() {
            match secrets::load(&a.id, "password").await? {
                Some(p) => imap::Auth::Password(p),
                None => imap::Auth::Password(String::new()),
            }
        } else {
            imap::Auth::Password(p.to_string())
        }
    };
    let mut imap = imap::open(&a, &auth).await.map_err(|e| format!("Receiving (IMAP): {}", e))?;
    let _ = imap.sess.logout().await;
    // SMTP: a connection and a sign-in, nothing sent.
    smtp_check(&a, &auth).await.map_err(|e| format!("Sending (SMTP): {}", e))?;
    Ok(json!({ "ok": true }))
}

async fn smtp_check(a: &Account, auth: &imap::Auth) -> Result<(), String> {
    use lettre::transport::smtp::authentication::{Credentials, Mechanism};
    use lettre::{AsyncSmtpTransport, Tokio1Executor};
    let host = a.smtp_host.trim();
    let b = match a.smtp_security.as_str() {
        "starttls" => AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(host).map_err(|e| e.to_string())?,
        "none" => {
            if !Account::is_local_host(host) {
                return Err("An unencrypted connection is only allowed to this computer".into());
            }
            AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(host)
        }
        _ => AsyncSmtpTransport::<Tokio1Executor>::relay(host).map_err(|e| e.to_string())?,
    };
    let mut b = b.port(a.smtp_port).timeout(Some(std::time::Duration::from_secs(20)));
    match auth {
        imap::Auth::Password(p) if !p.is_empty() => {
            b = b.credentials(Credentials::new(a.login().into(), p.clone())).authentication(vec![Mechanism::Plain, Mechanism::Login]);
        }
        imap::Auth::OAuth(t) => {
            b = b.credentials(Credentials::new(a.login().into(), t.clone())).authentication(vec![Mechanism::Xoauth2]);
        }
        _ => {}
    }
    let t: AsyncSmtpTransport<Tokio1Executor> = b.build();
    let ok = t.test_connection().await.map_err(|e| e.to_string())?;
    if ok { Ok(()) } else { Err("The server did not accept the connection".into()) }
}

async fn accounts_save(state: &Arc<State>, req: &Value) -> R {
    let mut a = account_from(req)?;
    let creating = a.id.is_empty();
    if creating {
        a.id = if s(req, "pendingId").is_empty() { new_id(&a.email) } else { s(req, "pendingId").to_string() };
    }
    let pw = s(req, "password");
    if a.auth == "password" && !pw.is_empty() {
        secrets::store(&a.id, "password", pw).await?;
    }
    {
        let db = state.db.lock().unwrap();
        let pos: i64 = db.conn.query_row("SELECT COALESCE(MAX(position), -1) + 1 FROM accounts", [], |r| r.get(0)).unwrap_or(0);
        db.conn
            .execute(
                "INSERT INTO accounts (id, data, position) VALUES (?1, ?2, ?3) ON CONFLICT(id) DO UPDATE SET data = excluded.data",
                params![a.id, serde_json::to_string(&a).unwrap(), pos],
            )
            .map_err(|e| e.to_string())?;
    }
    let rt = {
        let mut accts = state.accounts.write().await;
        match accts.get(&a.id) {
            Some(rt) => {
                *rt.acct.lock().unwrap() = a.clone();
                *rt.imap.lock().await = None;
                rt.clone()
            }
            None => {
                let rt = Arc::new(AccountRt::new(a.clone()));
                accts.insert(a.id.clone(), rt.clone());
                rt
            }
        }
    };
    state.tokens.lock().await.remove(&a.id);
    imap::start(state.clone(), rt);
    state.emit("accounts", json!({}));
    Ok(json!({ "id": a.id }))
}

async fn accounts_remove(state: &Arc<State>, id: &str) -> R {
    if let Some(rt) = state.accounts.write().await.remove(id) {
        rt.stop();
    }
    secrets::forget(id).await;
    {
        let db = state.db.lock().unwrap();
        let _ = db.conn.execute("DELETE FROM messages_fts WHERE rowid IN (SELECT id FROM messages WHERE account = ?)", [id]);
        let _ = db.conn.execute("DELETE FROM messages WHERE account = ?", [id]);
        let _ = db.conn.execute("DELETE FROM folders WHERE account = ?", [id]);
        let _ = db.conn.execute("DELETE FROM outbox WHERE account = ?", [id]);
        let _ = db.conn.execute("DELETE FROM accounts WHERE id = ?", [id]);
    }
    state.emit("accounts", json!({}));
    state.emit_unread();
    Ok(json!(true))
}

async fn accounts_reorder(state: &Arc<State>, req: &Value) -> R {
    if let Some(Value::Array(list)) = req.get("ids") {
        let db = state.db.lock().unwrap();
        for (n, id) in list.iter().enumerate() {
            let _ = db.conn.execute("UPDATE accounts SET position = ? WHERE id = ?", params![n as i64, id.as_str().unwrap_or("")]);
        }
    }
    state.emit("accounts", json!({}));
    Ok(json!(true))
}

fn oauth_clients(state: &Arc<State>) -> Value {
    let g = imap::oauth_client(state, "google");
    let m = imap::oauth_client(state, "microsoft");
    json!({
        "google": { "clientId": g.0, "hasSecret": !g.1.is_empty() },
        "microsoft": { "clientId": m.0 },
    })
}

/// Opens a sign-in. Returns the URL for the browser and the id the account
/// will have; an "oauth" event follows when it is done.
async fn oauth_begin(state: &Arc<State>, req: &Value) -> R {
    let provider = s(req, "provider").to_string();
    let id = if s(req, "account").is_empty() { new_id(s(req, "email")) } else { s(req, "account").to_string() };
    let (cid, secret) = imap::oauth_client(state, &provider);
    let flow = oauth::begin(&provider, &cid, &secret, s(req, "email")).await?;
    let url = flow.url.clone();
    let st = state.clone();
    let acct = id.clone();
    tokio::spawn(async move {
        match oauth::finish(flow).await {
            Ok(t) => {
                let stored = match &t.refresh {
                    Some(r) => secrets::store(&acct, "refresh", r).await,
                    None => Err("The provider gave no refresh token; remove this app's access in your account settings and sign in again".into()),
                };
                match stored {
                    Ok(()) => {
                        st.tokens.lock().await.insert(acct.clone(), (t.access.clone(), t.expires));
                        st.emit("oauth", json!({ "account": acct, "ok": true, "email": oauth::describe(&t)["email"] }));
                        if let Some(rt) = st.rt(&acct).await {
                            rt.wake.notify_one();
                        }
                    }
                    Err(e) => st.emit("oauth", json!({ "account": acct, "ok": false, "error": e })),
                }
            }
            Err(e) => st.emit("oauth", json!({ "account": acct, "ok": false, "error": e })),
        }
    });
    // The browser is opened here rather than by the app, so a sign-in can
    // be started from anywhere that can reach the socket.
    if req.get("open").and_then(|x| x.as_bool()).unwrap_or(true) {
        let _ = tokio::process::Command::new("xdg-open").arg(&url).spawn();
    }
    Ok(json!({ "account": id, "url": url }))
}

// ── lists ─────────────────────────────────────────────────────────────────
fn view_where(req: &Value) -> (String, Vec<rusqlite::types::Value>) {
    use rusqlite::types::Value as V;
    let mut w = vec![];
    let mut p: Vec<V> = vec![];
    let view = s(req, "view");
    let account = s(req, "account");
    let folder = s(req, "folder");
    if !folder.is_empty() {
        w.push("m.account = ? AND m.folder = ?".to_string());
        p.push(V::Text(account.into()));
        p.push(V::Text(folder.into()));
    } else {
        if !account.is_empty() {
            w.push("m.account = ?".to_string());
            p.push(V::Text(account.into()));
        }
        match view {
            "flagged" => w.push("m.flagged = 1 AND f.role NOT IN ('trash', 'junk')".into()),
            "unread" => w.push("m.seen = 0 AND f.role = 'inbox'".into()),
            "snoozed" => {}
            "attachments" => w.push("m.has_att = 1 AND f.role NOT IN ('trash', 'junk')".into()),
            "" => w.push("f.role = 'inbox'".into()),
            role => {
                w.push("f.role = ?".into());
                p.push(V::Text(role.into()));
            }
        }
    }
    if view == "snoozed" {
        w.push("EXISTS (SELECT 1 FROM snoozed z WHERE z.message = m.id AND z.until > ?)".into());
    } else {
        w.push("NOT EXISTS (SELECT 1 FROM snoozed z WHERE z.message = m.id AND z.until > ?)".into());
    }
    p.push(V::Integer(now()));
    (w.join(" AND "), p)
}

const BASE_COLS: &str = "m.id, m.account, m.folder, m.uid, m.thread, m.subject, m.from_name, m.from_addr, m.to_json, \
    m.date, m.sort_date, m.snippet, m.seen, m.flagged, m.answered, m.has_att, m.invite, m.msgid";

fn list(state: &Arc<State>, req: &Value) -> R {
    let (cond, mut p) = view_where(req);
    let threads = req.get("threads").and_then(|x| x.as_bool()).unwrap_or(true);
    let limit = i(req, "limit").unwrap_or(100).clamp(1, 1000);
    let offset = i(req, "offset").unwrap_or(0).max(0);
    let from = "FROM messages m JOIN folders f ON f.account = m.account AND f.path = m.folder";
    let db = state.db.lock().unwrap();
    let (sql, count_sql) = if threads {
        (
            format!(
                "WITH sel AS (SELECT {BASE_COLS} {from} WHERE {cond}), \
                 ranked AS (SELECT sel.*, ROW_NUMBER() OVER (PARTITION BY account, thread ORDER BY sort_date DESC) AS rn, \
                 COUNT(*) OVER (PARTITION BY account, thread) AS cnt, \
                 SUM(1 - seen) OVER (PARTITION BY account, thread) AS unread_cnt, \
                 MAX(flagged) OVER (PARTITION BY account, thread) AS any_flag \
                 FROM sel) \
                 SELECT {SUMMARY_COLS}, m.cnt, m.unread_cnt, m.any_flag FROM ranked m WHERE m.rn = 1 \
                 ORDER BY m.sort_date DESC LIMIT {limit} OFFSET {offset}"
            ),
            format!("SELECT COUNT(DISTINCT m.account || char(1) || m.thread) {from} WHERE {cond}"),
        )
    } else {
        (
            format!("SELECT {SUMMARY_COLS}, 1, 1 - m.seen, m.flagged {from} WHERE {cond} ORDER BY m.sort_date DESC LIMIT {limit} OFFSET {offset}"),
            format!("SELECT COUNT(*) {from} WHERE {cond}"),
        )
    };
    let mut st = db.conn.prepare(&sql).map_err(|e| e.to_string())?;
    let items: Vec<Value> = st
        .query_map(rusqlite::params_from_iter(p.iter()), |r| {
            let mut v = db::summary_row(r)?;
            v["count"] = json!(r.get::<_, i64>(18)?);
            v["unreadCount"] = json!(r.get::<_, i64>(19)?);
            v["anyFlagged"] = json!(r.get::<_, i64>(20)? != 0);
            Ok(v)
        })
        .map_err(|e| e.to_string())?
        .flatten()
        .collect();
    let total: i64 = db.conn.query_row(&count_sql, rusqlite::params_from_iter(p.drain(..)), |r| r.get(0)).unwrap_or(0);
    let snoozes = snooze_map(&db);
    let items = items
        .into_iter()
        .map(|mut v| {
            if let Some(u) = snoozes.get(&v["id"].as_i64().unwrap_or(0)) {
                v["snoozedUntil"] = json!(u);
            }
            v
        })
        .collect::<Vec<_>>();
    Ok(json!({ "items": items, "total": total }))
}

fn snooze_map(db: &db::Db) -> HashMap<i64, i64> {
    let mut out = HashMap::new();
    if let Ok(mut st) = db.conn.prepare("SELECT message, until FROM snoozed") {
        if let Ok(rows) = st.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))) {
            out.extend(rows.flatten());
        }
    }
    out
}

/// Every message of a conversation, oldest first, each once.
fn thread(state: &Arc<State>, req: &Value) -> R {
    let id = i(req, "id").ok_or("Which message?")?;
    let db = state.db.lock().unwrap();
    let (account, thread, folder): (String, String, String) = db
        .conn
        .query_row("SELECT account, thread, folder FROM messages WHERE id = ?", [id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(|_| "That message is no longer here".to_string())?;
    let role = db.conn.query_row("SELECT role FROM folders WHERE account = ? AND path = ?", params![account, folder], |r| r.get::<_, String>(0)).unwrap_or_default();
    let hide_bin = role != "trash" && role != "junk";
    let mut st = db
        .conn
        .prepare(&format!(
            "SELECT {SUMMARY_COLS}, f.role FROM messages m JOIN folders f ON f.account = m.account AND f.path = m.folder \
             WHERE m.account = ? AND m.thread = ? ORDER BY m.date ASC"
        ))
        .map_err(|e| e.to_string())?;
    let mut seen = std::collections::HashSet::new();
    let rows: Vec<Value> = st
        .query_map(params![account, thread], |r| {
            let mut v = db::summary_row(r)?;
            v["role"] = json!(r.get::<_, String>(18)?);
            Ok(v)
        })
        .map_err(|e| e.to_string())?
        .flatten()
        .filter(|v| !(hide_bin && matches!(v["role"].as_str(), Some("trash") | Some("junk"))) || v["id"].as_i64() == Some(id))
        .filter(|v| {
            let k = v["msgid"].as_str().unwrap_or("").to_string();
            k.is_empty() || seen.insert(k)
        })
        .collect();
    Ok(json!(rows))
}

/// Full-text search over everything kept: words, "quoted phrases",
/// from:someone, and has:attachment / is:unread / is:starred.
fn search(state: &Arc<State>, req: &Value) -> R {
    let q = s(req, "query").trim().to_string();
    let limit = i(req, "limit").unwrap_or(200).clamp(1, 1000);
    let mut fts: Vec<String> = vec![];
    let mut extra: Vec<&str> = vec![];
    let mut tokens = vec![];
    let mut cur = String::new();
    let mut quoted = false;
    for c in q.chars() {
        match c {
            '"' => { quoted = !quoted; cur.push(c); }
            ' ' if !quoted => { if !cur.is_empty() { tokens.push(std::mem::take(&mut cur)); } }
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() { tokens.push(cur); }
    for t in tokens {
        let lower = t.to_ascii_lowercase();
        match lower.as_str() {
            "has:attachment" | "has:attachments" => { extra.push("m.has_att = 1"); continue; }
            "is:unread" => { extra.push("m.seen = 0"); continue; }
            "is:starred" | "is:flagged" => { extra.push("m.flagged = 1"); continue; }
            "is:invite" => { extra.push("m.invite = 1"); continue; }
            _ => {}
        }
        let (col, word) = if let Some(w) = t.strip_prefix("from:") { ("people", w.to_string()) }
            else if let Some(w) = t.strip_prefix("subject:") { ("subject", w.to_string()) }
            else { ("", t.clone()) };
        let word = word.replace('"', "");
        if word.is_empty() { continue; }
        let term = format!("\"{}\"*", word);
        fts.push(if col.is_empty() { term } else { format!("{} : {}", col, term) });
    }
    let db = state.db.lock().unwrap();
    let mut conds: Vec<String> = extra.iter().map(|s| s.to_string()).collect();
    if !fts.is_empty() {
        conds.push("m.id IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?1)".into());
    }
    if conds.is_empty() {
        return Ok(json!({ "items": [], "total": 0 }));
    }
    let sql = format!(
        "SELECT {SUMMARY_COLS}, f.role FROM messages m JOIN folders f ON f.account = m.account AND f.path = m.folder \
         WHERE {} ORDER BY m.sort_date DESC LIMIT {limit}",
        conds.join(" AND ")
    );
    let mut st = db.conn.prepare(&sql).map_err(|e| e.to_string())?;
    let map = |r: &rusqlite::Row| {
        let mut v = db::summary_row(r)?;
        v["role"] = json!(r.get::<_, String>(18)?);
        v["count"] = json!(1);
        Ok(v)
    };
    let items: Vec<Value> = if fts.is_empty() {
        st.query_map([], map).map_err(|e| e.to_string())?.flatten().collect()
    } else {
        st.query_map([fts.join(" AND ")], map).map_err(|e| e.to_string())?.flatten().collect()
    };
    let n = items.len();
    Ok(json!({ "items": items, "total": n }))
}

/// The raw message, from the cache or, when only its header is kept, from
/// the server (and kept from then on).
async fn raw_of(state: &Arc<State>, id: i64) -> Result<Vec<u8>, String> {
    let (account, folder, uid, full, raw): (String, String, u32, bool, Vec<u8>) = {
        let db = state.db.lock().unwrap();
        db.conn
            .query_row("SELECT account, folder, uid, full, raw FROM messages WHERE id = ?", [id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get::<_, i64>(2)? as u32, r.get::<_, i64>(3)? != 0, r.get::<_, Option<Vec<u8>>>(4)?.unwrap_or_default()))
            })
            .map_err(|_| "That message is no longer here".to_string())?
    };
    if full {
        return Ok(raw);
    }
    let rt = state.rt(&account).await.ok_or("Its account is gone")?;
    let body = {
        let mut g = imap::session(state, &rt).await?;
        g.as_mut().unwrap().fetch_raw(&folder, uid).await?
    };
    {
        let db = state.db.lock().unwrap();
        let _ = db.conn.execute("UPDATE messages SET raw = ?, full = 1 WHERE id = ?", params![body, id]);
        if let Some(sm) = parse::summarize(&body) {
            let _ = db.conn.execute(
                "UPDATE messages SET has_att = ?, invite = ?, snippet = ? WHERE id = ?",
                params![sm.has_att as i64, sm.invite as i64, sm.snippet, id],
            );
            let _ = db.conn.execute("UPDATE messages_fts SET body = ? WHERE rowid = ?", params![sm.body, id]);
        }
    }
    Ok(body)
}

async fn get(state: &Arc<State>, req: &Value) -> R {
    let id = i(req, "id").ok_or("Which message?")?;
    let raw = raw_of(state, id).await?;
    let mut v = parse::full(&raw, true);
    let summary = imap::summary_of(state, id).ok_or("That message is no longer here")?;
    let (allowed, role) = {
        let db = state.db.lock().unwrap();
        let list: Vec<String> = db.setting("remoteImages").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default();
        let from = summary["fromAddr"].as_str().unwrap_or("").to_ascii_lowercase();
        let domain = from.rsplit('@').next().unwrap_or("").to_string();
        let allowed = list.iter().any(|x| { let x = x.to_ascii_lowercase(); x == from || x == domain || x == "*" });
        let role = db.conn.query_row(
            "SELECT role FROM folders WHERE account = ? AND path = ?",
            params![summary["account"].as_str().unwrap_or(""), summary["folder"].as_str().unwrap_or("")],
            |r| r.get::<_, String>(0),
        ).unwrap_or_default();
        (allowed, role)
    };
    v["id"] = json!(id);
    // How this invitation was answered, if it was.
    if let Some(uid) = v["invite"]["uid"].as_str() {
        let resp: Option<String> = state.db.lock().unwrap().conn
            .query_row("SELECT data FROM events WHERE uid = ?", [uid], |r| r.get::<_, String>(0)).ok()
            .and_then(|d| serde_json::from_str::<Value>(&d).ok())
            .and_then(|e| e["response"].as_str().map(|x| x.to_string()));
        if let Some(r) = resp {
            v["inviteResponse"] = json!(r);
        }
    }
    v["summary"] = summary.clone();
    v["role"] = json!(role);
    v["remoteAllowed"] = json!(allowed);
    let mark = req.get("markRead").and_then(|x| x.as_bool()).unwrap_or_else(|| {
        state.db.lock().unwrap().setting("markReadOnOpen").map(|v| v != "false").unwrap_or(true)
    });
    if mark && !summary["seen"].as_bool().unwrap_or(true) {
        let _ = act(state, &[id], Action::Flag("seen".into(), true)).await;
    }
    Ok(v)
}

async fn part_save(state: &Arc<State>, req: &Value) -> R {
    let id = i(req, "id").ok_or("Which message?")?;
    let index = i(req, "index").unwrap_or(0) as usize;
    let raw = raw_of(state, id).await?;
    let (name, mime, bytes) = parse::part(&raw, index).ok_or("That attachment is not in the message")?;
    // Names are the sender's choice: only the last part of one is used.
    let safe: String = name
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("attachment")
        .chars()
        .map(|c| if c.is_control() { '_' } else { c })
        .collect();
    let safe = if safe.is_empty() || safe == "." || safe == ".." { "attachment".to_string() } else { safe };
    let dest = s(req, "dest");
    let path = if dest.is_empty() {
        let dir = state.cache_dir.join("parts").join(id.to_string());
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        dir.join(&safe)
    } else {
        let d = std::path::PathBuf::from(dest.strip_prefix("file://").unwrap_or(dest));
        // Into a folder: beside whatever is there already, never over it
        // ("report.pdf", then "report (1).pdf"). A path that names the file
        // was chosen in a dialog that asked about replacing it.
        if d.is_dir() { free_name(&d, &safe) } else { d }
    };
    std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
    if !dest.is_empty() {
        // Saved for you, not cached: an ordinary file, not a private one.
        use std::os::unix::fs::PermissionsExt;
        let mode = 0o666 & !crate::USER_UMASK.load(std::sync::atomic::Ordering::Relaxed);
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode));
    }
    Ok(json!({ "path": path.to_string_lossy(), "name": safe, "mime": mime, "size": bytes.len() }))
}

/// `name` in `dir`, or "stem (n).ext" for the first n not taken.
fn free_name(dir: &std::path::Path, name: &str) -> std::path::PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    // ".bashrc" is all stem; "archive.tar.gz" keeps ".gz" — good enough.
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    };
    (1..)
        .map(|n| dir.join(format!("{} ({}){}", stem, n, ext)))
        .find(|p| !p.exists())
        .unwrap()
}

// ── actions ───────────────────────────────────────────────────────────────
enum Action {
    Flag(String, bool),
    Move(String),
    DeleteForever,
}

async fn resolve_dest(state: &Arc<State>, rt: &AccountRt, role_or_path: &str) -> Result<String, String> {
    let a = rt.account();
    let role = role_or_path;
    if !matches!(role, "inbox" | "archive" | "trash" | "junk" | "sent" | "drafts") {
        return Ok(role_or_path.to_string());
    }
    if role == "inbox" {
        return Ok("INBOX".into());
    }
    if let Some(p) = state.db.lock().unwrap().folder_role(&a.id, role) {
        return Ok(p);
    }
    // Gmail has no Archive: archiving is leaving the inbox for All Mail.
    if role == "archive" {
        if let Some(p) = state.db.lock().unwrap().folder_role(&a.id, "all") {
            return Ok(p);
        }
    }
    let name = match role { "archive" => "Archive", "trash" => "Trash", "junk" => "Junk", "sent" => "Sent", _ => "Drafts" };
    let mut g = imap::session(state, rt).await?;
    let _ = g.as_mut().unwrap().sess.create(name).await;
    drop(g);
    state.db.lock().unwrap().conn.execute(
        "INSERT OR IGNORE INTO folders (account, path, name, role) VALUES (?, ?, ?, ?)",
        params![a.id, name, name, role],
    ).map_err(|e| e.to_string())?;
    Ok(name.into())
}

async fn act(state: &Arc<State>, ids: &[i64], action: Action) -> R {
    // Grouped by where they are.
    let mut groups: HashMap<(String, String), Vec<(i64, u32)>> = HashMap::new();
    {
        let db = state.db.lock().unwrap();
        for id in ids {
            if let Some((a, f, u)) = db.message_key(*id) {
                groups.entry((a, f)).or_default().push((*id, u));
            }
        }
    }
    if groups.is_empty() {
        return Err("Those messages are no longer here".into());
    }
    for ((account, folder), list) in groups {
        let rt = state.rt(&account).await.ok_or("Its account is gone")?;
        let uids: Vec<u32> = list.iter().map(|x| x.1).collect();
        let local: Vec<i64> = list.iter().map(|x| x.0).collect();
        match &action {
            Action::Flag(what, on) => {
                let col = match what.as_str() { "seen" => "seen", "flagged" => "flagged", "answered" => "answered", _ => return Err("No such flag".into()) };
                {
                    let db = state.db.lock().unwrap();
                    for id in &local {
                        let _ = db.conn.execute(&format!("UPDATE messages SET {} = ? WHERE id = ?", col), params![*on as i64, id]);
                    }
                }
                state.emit("changed", json!({ "account": account, "folder": folder, "ids": local }));
                if col == "seen" { state.emit_unread(); }
                let imap_flag = match col { "seen" => "\\Seen", "flagged" => "\\Flagged", _ => "\\Answered" };
                let what = format!("{}FLAGS.SILENT ({})", if *on { "+" } else { "-" }, imap_flag);
                let st = state.clone();
                let rt2 = rt.clone();
                let f2 = folder.clone();
                tokio::spawn(async move {
                    let r = async {
                        let mut g = imap::session(&st, &rt2).await?;
                        g.as_mut().unwrap().store(&f2, &uids, &what).await
                    }.await;
                    if let Err(e) = r {
                        st.emit("error", json!({ "message": format!("Could not update the server: {}", e) }));
                        rt2.wake.notify_one();
                    }
                });
            }
            Action::Move(to) => {
                let src_role = state.db.lock().unwrap().conn.query_row(
                    "SELECT role FROM folders WHERE account = ? AND path = ?", params![account, folder], |r| r.get::<_, String>(0)
                ).unwrap_or_default();
                // Deleting from the bin is deleting.
                let forever = to == "trash" && src_role == "trash";
                let dest = if forever { String::new() } else { resolve_dest(state, &rt, to).await? };
                if !forever && dest == folder {
                    continue;
                }
                {
                    let db = state.db.lock().unwrap();
                    for id in &local {
                        db.delete_message(*id);
                    }
                }
                state.emit("changed", json!({ "account": account, "folder": folder, "removed": local }));
                state.emit_unread();
                let st = state.clone();
                let rt2 = rt.clone();
                let f2 = folder.clone();
                tokio::spawn(async move {
                    let r = async {
                        {
                            let mut g = imap::session(&st, &rt2).await?;
                            let imap = g.as_mut().unwrap();
                            if forever { imap.delete_forever(&f2, &uids).await?; } else { imap.move_to(&f2, &uids, &dest).await?; }
                        }
                        if !forever {
                            imap::sync_folder(&st, &rt2, &dest).await?;
                        }
                        Ok::<(), String>(())
                    }.await;
                    if let Err(e) = r {
                        st.emit("error", json!({ "message": format!("Could not move them on the server: {}", e) }));
                        rt2.wake.notify_one();
                    }
                });
            }
            Action::DeleteForever => {
                {
                    let db = state.db.lock().unwrap();
                    for id in &local {
                        db.delete_message(*id);
                    }
                }
                state.emit("changed", json!({ "account": account, "folder": folder, "removed": local }));
                state.emit_unread();
                let st = state.clone();
                let rt2 = rt.clone();
                let f2 = folder.clone();
                tokio::spawn(async move {
                    let r = async {
                        let mut g = imap::session(&st, &rt2).await?;
                        g.as_mut().unwrap().delete_forever(&f2, &uids).await
                    }.await;
                    if let Err(e) = r {
                        st.emit("error", json!({ "message": format!("Could not delete them on the server: {}", e) }));
                        rt2.wake.notify_one();
                    }
                });
            }
        }
    }
    Ok(json!(true))
}

// ── sending ───────────────────────────────────────────────────────────────
async fn send(state: &Arc<State>, req: &Value) -> R {
    let account = s(req, "account");
    let rt = state.rt(account).await.ok_or("Choose the account to send from")?;
    // Checked now, so a mistake shows at once rather than when it is due.
    smtp::build(&rt.account(), req)?;
    let at = i(req, "sendAt").unwrap_or(0);
    if at > now() {
        let summary = format!(
            "{} — {}",
            smtp::recipients(req).iter().map(|(n, e)| if n.is_empty() { e.clone() } else { n.clone() }).collect::<Vec<_>>().join(", "),
            s(req, "subject")
        );
        let id = {
            let db = state.db.lock().unwrap();
            db.conn.execute(
                "INSERT INTO outbox (account, send_at, payload, summary) VALUES (?, ?, ?, ?)",
                params![account, at, req.to_string(), summary],
            ).map_err(|e| e.to_string())?;
            db.conn.last_insert_rowid()
        };
        if let Some(d) = i(req, "draftId") {
            let _ = state.db.lock().unwrap().conn.execute("DELETE FROM drafts WHERE id = ?", [d]);
            state.emit("drafts", json!({}));
        }
        state.emit("outbox", json!({}));
        state.sched.notify_one();
        return Ok(json!({ "queued": id, "sendAt": at }));
    }
    deliver(state, &rt, req).await?;
    Ok(json!({ "sent": true }))
}

/// Sends now: SMTP, a copy in Sent, the original marked answered, the
/// people written to remembered.
pub async fn deliver(state: &Arc<State>, rt: &Arc<AccountRt>, req: &Value) -> Result<(), String> {
    let a = rt.account();
    let req = &with_forwarded(state, req).await?;
    let msg = smtp::build(&a, req)?;
    let auth = imap::credentials(state, &a).await?;
    smtp::send(&a, &auth, &msg).await?;
    {
        let db = state.db.lock().unwrap();
        for (n, e) in smtp::recipients(req) {
            db.remember_contact(&e, &n, 1.0);
        }
        if let Some(d) = i(req, "draftId") {
            let _ = db.conn.execute("DELETE FROM drafts WHERE id = ?", [d]);
        }
    }
    state.emit("drafts", json!({}));
    if let Some(orig) = i(req, "replyToId") {
        let _ = act(state, &[orig], Action::Flag("answered".into(), true)).await;
    }
    let st = state.clone();
    let rt2 = rt.clone();
    let raw = msg.formatted();
    tokio::spawn(async move {
        let r = async {
            let sent = resolve_dest(&st, &rt2, "sent").await?;
            if !a.server_saves_sent() {
                let mut g = imap::session(&st, &rt2).await?;
                g.as_mut().unwrap().append(&sent, "(\\Seen)", &raw).await?;
            }
            imap::sync_folder(&st, &rt2, &sent).await?;
            Ok::<(), String>(())
        }.await;
        if let Err(e) = r {
            st.emit("error", json!({ "message": format!("Sent, but not filed in Sent: {}", e) }));
        }
    });
    state.emit("sent", json!({ "account": rt.id(), "subject": s(req, "subject") }));
    Ok(())
}

/// A forward's attachments from the original message: saved out of it into
/// the cache, and added to the request's attachments.
async fn with_forwarded(state: &Arc<State>, req: &Value) -> Result<Value, String> {
    let Some(orig) = i(req, "forwardOf") else { return Ok(req.clone()) };
    let parts: Vec<usize> = match req.get("forwardParts") {
        Some(Value::Array(a)) => a.iter().filter_map(|x| x.as_u64().map(|n| n as usize)).collect(),
        _ => vec![],
    };
    if parts.is_empty() {
        return Ok(req.clone());
    }
    let raw = raw_of(state, orig).await?;
    let dir = state.cache_dir.join("forward").join(format!("{}-{}", orig, now()));
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let mut out = req.clone();
    let mut list: Vec<Value> = match req.get("attachments") {
        Some(Value::Array(a)) => a.clone(),
        _ => vec![],
    };
    for idx in parts {
        if let Some((name, _mime, bytes)) = parse::part(&raw, idx) {
            let safe: String = name.rsplit(['/', '\\']).next().unwrap_or("attachment").to_string();
            let path = dir.join(if safe.is_empty() { "attachment".to_string() } else { safe });
            std::fs::write(&path, &bytes).map_err(|e| e.to_string())?;
            list.push(json!(path.to_string_lossy()));
        }
    }
    out["attachments"] = json!(list);
    Ok(out)
}

fn outbox_list(state: &Arc<State>) -> R {
    let db = state.db.lock().unwrap();
    let mut st = db.conn.prepare("SELECT id, account, send_at, summary, error FROM outbox ORDER BY send_at").map_err(|e| e.to_string())?;
    let rows: Vec<Value> = st
        .query_map([], |r| Ok(json!({ "id": r.get::<_, i64>(0)?, "account": r.get::<_, String>(1)?,
            "sendAt": r.get::<_, i64>(2)?, "summary": r.get::<_, String>(3)?, "error": r.get::<_, String>(4)? })))
        .map_err(|e| e.to_string())?
        .flatten()
        .collect();
    Ok(json!(rows))
}

fn drafts_save(state: &Arc<State>, req: &Value) -> R {
    let payload = req.get("draft").cloned().unwrap_or(json!({}));
    let account = payload.get("account").and_then(|x| x.as_str()).unwrap_or("");
    let db = state.db.lock().unwrap();
    let id = match i(req, "id") {
        Some(id) if id > 0 => {
            db.conn.execute("UPDATE drafts SET account = ?, payload = ?, updated = ? WHERE id = ?",
                params![account, payload.to_string(), now(), id]).map_err(|e| e.to_string())?;
            id
        }
        _ => {
            db.conn.execute("INSERT INTO drafts (account, payload, updated) VALUES (?, ?, ?)",
                params![account, payload.to_string(), now()]).map_err(|e| e.to_string())?;
            db.conn.last_insert_rowid()
        }
    };
    drop(db);
    state.emit("drafts", json!({}));
    Ok(json!(id))
}

fn drafts_list(state: &Arc<State>) -> R {
    let db = state.db.lock().unwrap();
    let mut st = db.conn.prepare("SELECT id, payload, updated FROM drafts ORDER BY updated DESC").map_err(|e| e.to_string())?;
    let rows: Vec<Value> = st
        .query_map([], |r| Ok(json!({ "id": r.get::<_, i64>(0)?,
            "draft": serde_json::from_str::<Value>(&r.get::<_, String>(1)?).unwrap_or(json!({})),
            "updated": r.get::<_, i64>(2)? })))
        .map_err(|e| e.to_string())?
        .flatten()
        .collect();
    Ok(json!(rows))
}

fn contacts_search(state: &Arc<State>, req: &Value) -> R {
    let q = s(req, "q").trim().to_ascii_lowercase();
    let limit = i(req, "limit").unwrap_or(8).clamp(1, 5000);
    let like = format!("%{}%", q.replace('%', "").replace('_', ""));
    let prefix = format!("{}%", q.replace('%', "").replace('_', ""));
    let db = state.db.lock().unwrap();
    let mut st = db
        .conn
        .prepare(
            "SELECT email, name, score, manual FROM contacts WHERE hidden = 0 AND (email LIKE ?1 OR name LIKE ?1) \
             ORDER BY (email LIKE ?2 OR name LIKE ?2 OR name LIKE '% ' || ?2) DESC, manual DESC, \
             score / (1 + (strftime('%s','now') - last_used) / 2592000.0) DESC LIMIT ?3",
        )
        .map_err(|e| e.to_string())?;
    let rows: Vec<Value> = st
        .query_map(params![like, prefix, limit], |r| Ok(json!({ "email": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?,
            "score": r.get::<_, f64>(2)?, "manual": r.get::<_, i64>(3)? != 0 })))
        .map_err(|e| e.to_string())?
        .flatten()
        .collect();
    Ok(json!(rows))
}

// ── invitations ───────────────────────────────────────────────────────────
async fn invite_respond(state: &Arc<State>, req: &Value) -> R {
    let id = i(req, "id").ok_or("Which invitation?")?;
    let partstat = match s(req, "response") {
        "accept" | "yes" => "ACCEPTED",
        "tentative" | "maybe" => "TENTATIVE",
        "decline" | "no" => "DECLINED",
        _ => return Err("Answer accept, tentative or decline".into()),
    };
    let raw = raw_of(state, id).await?;
    let ics_text = parse::calendar(&raw).ok_or("This message has no invitation in it")?;
    let ev = ics::parse(&ics_text).ok_or("The invitation could not be read")?;
    let account = state.db.lock().unwrap().message_key(id).map(|k| k.0).ok_or("That message is no longer here")?;
    let rt = state.rt(&account).await.ok_or("Its account is gone")?;
    let a = rt.account();
    let reply = ics::reply(&ics_text, &a.email, &a.display_name, partstat).ok_or("The invitation could not be answered")?;
    let organizer = ev["organizer"]["email"].as_str().unwrap_or("").to_string();
    let word = match partstat { "ACCEPTED" => "Accepted", "TENTATIVE" => "Tentative", _ => "Declined" };
    let summary = ev["summary"].as_str().unwrap_or("");
    if !organizer.is_empty() && req.get("notify").and_then(|x| x.as_bool()).unwrap_or(true) {
        let me = if a.display_name.is_empty() { a.email.clone() } else { a.display_name.clone() };
        let send_req = json!({
            "account": account,
            "to": [{ "email": organizer, "name": ev["organizer"]["name"] }],
            "subject": format!("{}: {}", word, summary),
            "text": format!("{} has {} this invitation.", me, word.to_ascii_lowercase()),
            "calendar": { "method": "REPLY", "ics": reply },
        });
        deliver(state, &rt, &send_req).await?;
    }
    {
        let db = state.db.lock().unwrap();
        let uid = ev["uid"].as_str().unwrap_or("").to_string();
        if partstat == "DECLINED" {
            let _ = db.conn.execute("DELETE FROM events WHERE uid = ?", [&uid]);
        } else {
            let mut e = ev.clone();
            e["response"] = json!(partstat);
            e["account"] = json!(account);
            e["message"] = json!(id);
            let _ = db.conn.execute(
                "INSERT INTO events (uid, data) VALUES (?, ?) ON CONFLICT(uid) DO UPDATE SET data = excluded.data",
                params![uid, e.to_string()],
            );
        }
    }
    state.emit("events", json!({}));
    Ok(json!({ "response": partstat }))
}
