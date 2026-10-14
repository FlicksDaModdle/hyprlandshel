//! The line to hyprshell-chatsd: JSON over a Unix socket, one object a
//! line. Requests go out with an id and their answers come back to the
//! callback given; everything else is an event, handed to the app. All
//! callbacks run on the UI thread.

use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

static WRITER: Mutex<Option<UnixStream>> = Mutex::new(None);
static NEXT: AtomicU64 = AtomicU64::new(1);

type Reply = Box<dyn FnOnce(Value)>;
thread_local! {
    static PENDING: RefCell<HashMap<u64, Reply>> = RefCell::new(HashMap::new());
    static ON_EVENT: RefCell<Option<Box<dyn Fn(Value)>>> = const { RefCell::new(None) };
}

pub fn demo() -> bool {
    std::env::var_os("HYPRSHELL_CHATS_DEMO").is_some()
}

pub fn socket() -> PathBuf {
    if let Some(p) = std::env::var_os("HYPRSHELL_CHATS_SOCKET") {
        return PathBuf::from(p);
    }
    let run = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    run.join(if demo() { "hyprshell-chats-demo.sock" } else { "hyprshell-chats.sock" })
}

/// The daemon: beside this program, else on the PATH.
fn daemon() -> PathBuf {
    if let Ok(me) = std::env::current_exe() {
        let p = me.with_file_name("hyprshell-chatsd");
        if p.exists() {
            return p;
        }
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    for d in [home.join(".local/bin"), "/usr/local/bin".into(), "/usr/bin".into()] {
        let p = d.join("hyprshell-chatsd");
        if p.exists() {
            return p;
        }
    }
    PathBuf::from("hyprshell-chatsd")
}

fn start_daemon() -> Result<(), String> {
    let mut cmd = std::process::Command::new(daemon());
    if demo() {
        cmd.arg("--demo");
    }
    cmd.env("HYPRSHELL_CHATS_SOCKET", socket())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .process_group(0);
    // It outlives the window: messages keep arriving with it closed.
    cmd.spawn().map(|_| ()).map_err(|e| format!("couldn't start hyprshell-chatsd: {e}"))
}

/// Connect, starting the daemon if nothing answers. Blocking: from a
/// worker thread.
pub fn connect() -> Result<UnixStream, String> {
    let sock = socket();
    if let Ok(s) = UnixStream::connect(&sock) {
        return Ok(s);
    }
    start_daemon()?;
    for _ in 0..60 {
        std::thread::sleep(Duration::from_millis(100));
        if let Ok(s) = UnixStream::connect(&sock) {
            return Ok(s);
        }
    }
    Err("hyprshell-chatsd didn't start".into())
}

/// Read from `stream` for good, handing each line to the UI thread. When
/// the line drops, a `{"ev": "lost"}` event says so.
pub fn run(stream: UnixStream, on_event: impl Fn(Value) + 'static) {
    *WRITER.lock().unwrap() = stream.try_clone().ok();
    ON_EVENT.with(|e| *e.borrow_mut() = Some(Box::new(on_event)));
    std::thread::Builder::new()
        .name("chatsd".into())
        .spawn(move || {
            let mut r = BufReader::new(stream);
            let mut line = String::new();
            loop {
                line.clear();
                match r.read_line(&mut line) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {}
                }
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                let _ = slint::invoke_from_event_loop(move || dispatch(v));
            }
            *WRITER.lock().unwrap() = None;
            let _ = slint::invoke_from_event_loop(|| dispatch(json!({ "ev": "lost" })));
        })
        .expect("reader thread");
}

/// After a lost line: the same handler, a new stream.
pub fn rerun(stream: UnixStream) {
    let handler = ON_EVENT.with(|e| e.borrow_mut().take());
    if let Some(h) = handler {
        run(stream, h);
    }
}

fn dispatch(v: Value) {
    if let Some(id) = v.get("re").and_then(Value::as_u64) {
        let cb = PENDING.with(|p| p.borrow_mut().remove(&id));
        if let Some(cb) = cb {
            cb(v);
        }
        return;
    }
    ON_EVENT.with(|e| {
        if let Some(f) = e.borrow().as_ref() {
            f(v);
        }
    });
}

fn write(v: &Value) -> bool {
    let mut w = WRITER.lock().unwrap();
    let Some(s) = w.as_mut() else { return false };
    let mut line = v.to_string();
    line.push('\n');
    s.write_all(line.as_bytes()).is_ok()
}

/// Ask, and hear back on the UI thread. Not connected: the callback gets
/// an error answer straight away.
pub fn request(cmd: &str, mut args: Value, cb: impl FnOnce(Value) + 'static) {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    if !args.is_object() {
        args = json!({});
    }
    args["cmd"] = json!(cmd);
    args["id"] = json!(id);
    PENDING.with(|p| p.borrow_mut().insert(id, Box::new(cb)));
    if !write(&args) {
        let cb = PENDING.with(|p| p.borrow_mut().remove(&id));
        if let Some(cb) = cb {
            cb(json!({ "ok": false, "error": "Chats' service isn't running" }));
        }
    }
}

/// Say something that needs no answer.
pub fn tell(cmd: &str, mut args: Value) {
    if !args.is_object() {
        args = json!({});
    }
    args["cmd"] = json!(cmd);
    write(&args);
}
