// hyprshell-maild: Hyprshell Mail's background half.
//
// Keeps every account's mail in a local cache, in step with the servers
// (IDLE for the inbox, a look round every five minutes for the rest), sends,
// and serves the app and the shell over a Unix socket at
// $XDG_RUNTIME_DIR/hyprshell-mail.sock — JSON, a line at a time (proto.rs).
// It also brings snoozed mail back and sends what was scheduled, which is
// why it runs on its own rather than inside the app.
//
//   hyprshell-maild [--socket PATH] [--data DIR]

mod account;
mod db;
mod ics;
mod imap;
mod oauth;
mod parse;
mod proto;
mod secrets;
mod smtp;
mod state;

use serde_json::{json, Value};
use state::{AccountRt, State};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, mpsc, RwLock};

fn dirs() -> (PathBuf, PathBuf, PathBuf) {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let data = std::env::var("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(&home).join(".local/share"));
    let cache = std::env::var("XDG_CACHE_HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(&home).join(".cache"));
    let run = std::env::var("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("/tmp"));
    (data.join("hyprshell/mail"), cache.join("hyprshell/mail"), run.join("hyprshell-mail.sock"))
}

#[tokio::main]
async fn main() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let (mut data, cache, mut sock) = dirs();
    let args: Vec<String> = std::env::args().collect();
    let mut status_mode = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--socket" if i + 1 < args.len() => { sock = PathBuf::from(&args[i + 1]); i += 1; }
            "--data" if i + 1 < args.len() => { data = PathBuf::from(&args[i + 1]); i += 1; }
            "--help" | "-h" => {
                println!("hyprshell-maild [--socket PATH] [--data DIR]");
                println!("hyprshell-maild --status     what each account is doing, from the running service");
                return;
            }
            "--status" => status_mode = true,
            _ => {}
        }
        i += 1;
    }
    if status_mode {
        // Piped into `head` and the like: stop quietly when the reader goes,
        // rather than panic on the closed pipe.
        unsafe { libc_signal(13, 0) };
        print_status(&sock);
        keyring_status().await;
        return;
    }
    // Only you can read the cache. What you save elsewhere gets the
    // permissions you would otherwise have given it (proto::part_save).
    let prev = unsafe { libc_umask(0o077) };
    USER_UMASK.store(prev, std::sync::atomic::Ordering::Relaxed);
    std::fs::create_dir_all(&data).expect("cannot create the data directory");
    std::fs::create_dir_all(&cache).ok();

    // One daemon at a time: if the socket answers, one is already running.
    if UnixStream::connect(&sock).await.is_ok() {
        eprintln!("hyprshell-maild is already running ({})", sock.display());
        return;
    }
    let _ = std::fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).expect("cannot open the socket");

    let db = db::Db::open(&data.join("mail.db")).expect("cannot open the mail database");
    let (tx, _) = broadcast::channel(512);
    let state = Arc::new(State {
        db: Mutex::new(db),
        accounts: RwLock::new(HashMap::new()),
        events: tx,
        tokens: tokio::sync::Mutex::new(HashMap::new()),
        cache_dir: cache,
        sched: tokio::sync::Notify::new(),
    });

    // The accounts, and their sync.
    let saved: Vec<String> = {
        let db = state.db.lock().unwrap();
        let mut st = db.conn.prepare("SELECT data FROM accounts ORDER BY position").unwrap();
        let rows: Vec<String> = st.query_map([], |r| r.get(0)).unwrap().flatten().collect();
        rows
    };
    for d in saved {
        if let Ok(a) = serde_json::from_str::<account::Account>(&d) {
            let rt = Arc::new(AccountRt::new(a.clone()));
            state.accounts.write().await.insert(a.id.clone(), rt.clone());
            imap::start(state.clone(), rt);
        }
    }

    tokio::spawn(scheduler(state.clone()));
    tokio::spawn(wake_watch(state.clone()));

    eprintln!("hyprshell-maild: listening on {}", sock.display());
    let stop = async {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).unwrap();
        tokio::select! { _ = term.recv() => {}, _ = tokio::signal::ctrl_c() => {} }
    };
    tokio::pin!(stop);
    loop {
        tokio::select! {
            _ = &mut stop => break,
            c = listener.accept() => {
                if let Ok((stream, _)) = c {
                    tokio::spawn(client(state.clone(), stream));
                }
            }
        }
    }
    let _ = std::fs::remove_file(&sock);
}

/// The umask this was started with, before the cache's own.
pub static USER_UMASK: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0o022);

extern "C" {
    #[link_name = "umask"]
    fn libc_umask(mask: u32) -> u32;
    #[link_name = "signal"]
    fn libc_signal(sig: i32, handler: usize) -> usize;
}

/// One connection: requests in, answers and events out.
async fn client(state: Arc<State>, stream: UnixStream) {
    let (rd, mut wr) = stream.into_split();
    let (tx, mut rx) = mpsc::channel::<String>(256);
    let mut events = state.events.subscribe();
    let writer = tokio::spawn(async move {
        loop {
            let line = tokio::select! {
                m = rx.recv() => match m { Some(m) => m, None => break },
                e = events.recv() => match e {
                    Ok(e) => e,
                    Err(broadcast::error::RecvError::Lagged(_)) => json!({ "event": "resync" }).to_string(),
                    Err(_) => break,
                },
            };
            if wr.write_all(line.as_bytes()).await.is_err() || wr.write_all(b"\n").await.is_err() {
                break;
            }
        }
    });
    let mut lines = BufReader::new(rd).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let line = line.trim().to_string();
        if line.is_empty() {
            continue;
        }
        let st = state.clone();
        let tx = tx.clone();
        tokio::spawn(async move {
            let req: Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(e) => {
                    let _ = tx.send(json!({ "ok": false, "error": format!("Bad request: {}", e) }).to_string()).await;
                    return;
                }
            };
            let rid = req.get("rid").cloned().unwrap_or(Value::Null);
            let out = match proto::handle(&st, &req).await {
                Ok(r) => json!({ "rid": rid, "ok": true, "result": r }),
                Err(e) => json!({ "rid": rid, "ok": false, "error": e }),
            };
            let _ = tx.send(out.to_string()).await;
        });
    }
    drop(tx);
    let _ = writer.await;
}

/// Every twenty seconds: snoozed mail whose time has come, and mail
/// scheduled to send.
/// `--status`: asks the running service, and says it in words.
fn print_status(sock: &std::path::Path) {
    use std::io::{BufRead, Write};
    let mut c = match std::os::unix::net::UnixStream::connect(sock) {
        Ok(c) => c,
        Err(e) => {
            println!("The mail service isn't running ({}: {}).", sock.display(), e);
            println!("Start it with: systemctl --user start hyprshell-maild");
            return;
        }
    };
    let _ = c.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = c.write_all(b"{\"rid\":1,\"cmd\":\"diag\"}\n");
    let mut line = String::new();
    let mut r = std::io::BufReader::new(c);
    // Events may come first; the answer is the line with our rid.
    let v: Value = loop {
        line.clear();
        if r.read_line(&mut line).unwrap_or(0) == 0 {
            println!("The mail service didn't answer (it may be an older version: reinstall with mail/install.sh).");
            return;
        }
        let v: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        if v.get("rid").and_then(|x| x.as_i64()) == Some(1) {
            break v;
        }
    };
    if v["ok"] != json!(true) {
        println!("The mail service is an older version without --status: reinstall with mail/install.sh.");
        return;
    }
    let res = &v["result"];
    let now = res["now"].as_i64().unwrap_or(0);
    let when = |t: &Value| -> String {
        match t.as_i64() {
            Some(t) if t > 0 => {
                let ago = now - t;
                let at = chrono::DateTime::from_timestamp(t, 0)
                    .map(|d| d.with_timezone(&chrono::Local).format("%a %H:%M").to_string())
                    .unwrap_or_default();
                if ago < 60 { format!("{} (just now)", at) }
                else if ago < 3600 { format!("{} ({} min ago)", at, ago / 60) }
                else if ago < 86400 { format!("{} ({} h ago)", at, ago / 3600) }
                else { format!("{} ({} days ago)", at, ago / 86400) }
            }
            _ => "never".into(),
        }
    };
    for a in res["accounts"].as_array().cloned().unwrap_or_default() {
        let d = &a["diag"];
        println!("{} <{}>  [{}]", a["name"].as_str().unwrap_or(""), a["email"].as_str().unwrap_or(""), a["id"].as_str().unwrap_or(""));
        println!("  server        {} ({})", a["host"].as_str().unwrap_or(""), a["auth"].as_str().unwrap_or(""));
        println!("  state         {}{}", a["status"].as_str().unwrap_or(""),
                 if a["enabled"] == json!(false) { " — turned off" } else { "" });
        if let Some(e) = a["error"].as_str().filter(|e| !e.is_empty()) {
            println!("  error         {}", e);
        }
        println!("  loops running {} of 2", a["running"]);
        if let Some(st) = d["step"]["what"].as_str() {
            if st != "done" {
                println!("  busy with     {} — since {}", st, when(&d["step"]["at"]));
            }
        }
        println!("  last look     {}", when(&d["lastTry"]));
        println!("  last good one {}", when(&d["lastOk"]));
        if d["lastError"].is_string() {
            println!("  last failure  {} — {}", when(&d["lastErrorAt"]), d["lastError"].as_str().unwrap_or(""));
        }
        let i = &d["inbox"];
        if i.is_object() {
            println!("  inbox, server {} messages; {} in the last 60 days, newest uid {}; next uid {}",
                     i["serverCount"], i["inWindow"], i["newestOnServer"], i["serverNextUid"]);
            println!("  inbox, here   {} kept, newest uid {}; {} to fetch, {} stored, {} passed over (looked {})",
                     i["keptHere"], i["newestKept"], i["toFetch"], i["stored"], i["passedOver"], when(&i["at"]));
        } else {
            println!("  inbox         not looked at yet");
        }
        println!("  newest kept   {}", when(&a["inboxNewestDate"]));
        let idle = &d["idle"];
        if let Some(e) = idle["error"].as_str() {
            println!("  new-mail push failing ({}): {}", when(&idle["at"]), e);
        } else if idle["listeningSince"].is_i64() {
            println!("  new-mail push listening since {}", when(&idle["listeningSince"]));
        } else {
            println!("  new-mail push not started");
        }
        println!();
    }
}

/// `--status`, the keyring: whether it is unlocked, and if it isn't, how
/// to have your login unlock it — the usual reason Mail can't sign in after
/// a restart on a desktop without GNOME's own login screen.
async fn keyring_status() {
    if std::env::var("HYPRSHELL_MAIL_INSECURE_SECRETS").map(|s| !s.is_empty()).unwrap_or(false) {
        return;
    }
    let locked = match tokio::time::timeout(Duration::from_secs(10), oo7::Keyring::new()).await {
        Err(_) => { println!("Keyring: didn't answer within 10 seconds."); return; }
        Ok(Err(e)) if { let l = e.to_string().to_ascii_lowercase(); l.contains("dismissed") || l.contains("locked") || l.contains("prompt") } => {
            println!("Keyring: locked — its unlock window didn't appear or was closed ({}).", e);
            Ok(Ok(true))
        }
        Ok(Err(e)) => { println!("Keyring: not available ({}). Install gnome-keyring and log in again.", e); return; }
        Ok(Ok(k)) => tokio::time::timeout(Duration::from_secs(10), k.is_locked()).await,
    };
    match locked {
        Ok(Ok(false)) => { println!("Keyring: unlocked."); return; }
        Ok(Ok(true)) => {}
        _ => { println!("Keyring: couldn't tell whether it's locked."); return; }
    }
    // Which login program PAM runs for: the display manager's, or the
    // console's.
    let dm = std::fs::read_link("/etc/systemd/system/display-manager.service")
        .ok()
        .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().to_string()));
    let service = match dm.as_deref() {
        Some(d) if std::path::Path::new(&format!("/etc/pam.d/{}", d)).exists() => d.to_string(),
        Some("plasmalogin") => "plasmalogin".into(),
        _ => "login".into(),
    };
    let pam = format!("/etc/pam.d/{}", service);
    let has = std::fs::read_to_string(&pam).map(|t| t.contains("pam_gnome_keyring")).unwrap_or(false);
    println!("Mail can't read your sign-ins until it's unlocked.");
    println!();
    println!("Unlock it now: open Passwords and Keys (seahorse), right-click \"Login\", Unlock.");
    println!();
    if has {
        println!("{} already unlocks the keyring at login, so the keyring's password", pam);
        println!("probably isn't your login password any more. In Passwords and Keys, right-click");
        println!("\"Login\" → Change Password, and set it to your login password.");
    } else {
        println!("To have it unlock when you log in ({}), add these two lines to {}:", dm.as_deref().unwrap_or("console login"), pam);
        println!("  auth     optional  pam_gnome_keyring.so");
        println!("  session  optional  pam_gnome_keyring.so auto_start");
        println!("(the auth line after the other auth lines, the session line at the end) — e.g.");
        println!("  sudoedit {}", pam);
        println!("The keyring's password has to be the same as your login password.");
    }
}

/// Back from sleep: every connection made before it is as good as gone,
/// and mail has very likely arrived. Rather than wait for each to be found
/// dead, start every account afresh — new connections, a look at once.
///
/// Sleep is noticed by the clocks: the wall clock goes on through it, the
/// one tokio keeps time with does not, so a check meant to come 20 seconds
/// after the last that finds much more than 20 seconds on the wall clock
/// slept in between.
async fn wake_watch(state: Arc<State>) {
    let step = Duration::from_secs(20);
    let mut wall = std::time::SystemTime::now();
    loop {
        tokio::time::sleep(step).await;
        let now = std::time::SystemTime::now();
        let gone = now.duration_since(wall).unwrap_or_default();
        wall = now;
        if gone < step + Duration::from_secs(30) {
            continue;
        }
        eprintln!("hyprshell-maild: awake after {}s; reconnecting", gone.as_secs());
        let accts: Vec<Arc<AccountRt>> = state.accounts.read().await.values().cloned().collect();
        for rt in accts {
            // The loops first (aborting them lets go of the connection they
            // hold), then the connection, then the loops again.
            rt.stop();
            *rt.imap.lock().await = None;
            imap::start(state.clone(), rt);
        }
    }
}

async fn scheduler(state: Arc<State>) {
    loop {
        // Until the next thing is due (a send with seconds of undo, say),
        // or twenty seconds, or something new is queued.
        let next: i64 = {
            let db = state.db.lock().unwrap();
            db.conn
                .query_row(
                    "SELECT MIN(t) FROM (SELECT MIN(send_at) AS t FROM outbox WHERE error = '' \
                     UNION ALL SELECT MIN(until) FROM snoozed)",
                    [],
                    |r| r.get::<_, Option<i64>>(0),
                )
                .ok()
                .flatten()
                .unwrap_or(i64::MAX)
        };
        let wait = (next - db::now()).clamp(0, 20) as u64;
        if wait > 0 {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(wait)) => {}
                _ = state.sched.notified() => { continue; }
            }
        }
        let t = db::now();

        // Snoozes.
        let due: Vec<(i64, String, String)> = {
            let db = state.db.lock().unwrap();
            let mut st = db.conn.prepare(
                "SELECT s.message, m.subject, CASE m.from_name WHEN '' THEN m.from_addr ELSE m.from_name END \
                 FROM snoozed s JOIN messages m ON m.id = s.message WHERE s.until <= ?").unwrap();
            let rows: Vec<(i64, String, String)> = st.query_map([t], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().flatten().collect();
            for (id, _, _) in &rows {
                let _ = db.conn.execute("DELETE FROM snoozed WHERE message = ?", [id]);
                let _ = db.conn.execute("UPDATE messages SET sort_date = ? WHERE id = ?", rusqlite::params![t, id]);
            }
            rows
        };
        if !due.is_empty() {
            state.emit("changed", json!({}));
            state.emit_unread();
            state.emit("unsnoozed", json!({ "ids": due.iter().map(|d| d.0).collect::<Vec<_>>() }));
            let notify = state.db.lock().unwrap().setting("notify").map(|v| v != "false").unwrap_or(true);
            if notify {
                for (id, subject, from) in due {
                    let title = format!("Back from snooze: {}", from);
                    let icon = imap::notify_icon();
                    tokio::spawn(async move {
                        let out = tokio::process::Command::new("notify-send")
                            .args(["-a", "Mail", "-i", &icon, "-h", "string:desktop-entry:hyprshell-mail", "-A", "open=Open", "--wait", &title, &subject])
                            .stderr(std::process::Stdio::null())
                            .output()
                            .await;
                        if let Ok(o) = out {
                            if String::from_utf8_lossy(&o.stdout).trim() == "open" {
                                let _ = tokio::process::Command::new("hyprshell-mail").arg(format!("--message={}", id)).spawn();
                            }
                        }
                    });
                }
            }
        }

        // The outbox.
        let sending: Vec<(i64, String, String)> = {
            let db = state.db.lock().unwrap();
            let mut st = db.conn.prepare("SELECT id, account, payload FROM outbox WHERE send_at <= ? AND error = ''").unwrap();
            let rows: Vec<(i64, String, String)> = st.query_map([t], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap().flatten().collect();
            rows
        };
        for (id, account, payload) in sending {
            let req: Value = serde_json::from_str(&payload).unwrap_or(json!({}));
            let result = match state.rt(&account).await {
                Some(rt) => proto::deliver(&state, &rt, &req).await,
                None => Err("Its account is gone".to_string()),
            };
            {
                let db = state.db.lock().unwrap();
                match &result {
                    Ok(()) => { let _ = db.conn.execute("DELETE FROM outbox WHERE id = ?", [id]); }
                    Err(e) => { let _ = db.conn.execute("UPDATE outbox SET error = ? WHERE id = ?", rusqlite::params![e, id]); }
                }
            }
            if let Err(e) = result {
                state.emit("error", json!({ "message": format!("A scheduled message could not be sent: {}", e) }));
            }
            state.emit("outbox", json!({}));
        }
    }
}
