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
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--socket" if i + 1 < args.len() => { sock = PathBuf::from(&args[i + 1]); i += 1; }
            "--data" if i + 1 < args.len() => { data = PathBuf::from(&args[i + 1]); i += 1; }
            "--help" | "-h" => {
                println!("hyprshell-maild [--socket PATH] [--data DIR]");
                return;
            }
            _ => {}
        }
        i += 1;
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
