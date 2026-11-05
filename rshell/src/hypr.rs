//! Hyprland, straight from its sockets: no `hyprctl` started per question.
//!
//! `.socket.sock` answers one request per connection ("j/workspaces" gives
//! JSON); `.socket2.sock` is a stream of events, one "name>>data" per line,
//! read on a thread of its own that wakes the main loop through a pipe.

use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc::Sender;

fn dir() -> Option<PathBuf> {
    let sig = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE")?;
    let run = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
    Some(run.join("hypr").join(sig))
}

/// One request: "j/workspaces", "j/activeworkspace", "j/activewindow",
/// "dispatch workspace 3". None outside Hyprland.
pub fn ask(request: &str) -> Option<String> {
    let mut s = UnixStream::connect(dir()?.join(".socket.sock")).ok()?;
    s.write_all(request.as_bytes()).ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    Some(out)
}

pub fn json(request: &str) -> Value {
    ask(request).and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(Value::Null)
}

/// Each event line goes to `tx`, and a byte to `wake` so the loop polling
/// the Wayland connection notices.
pub fn listen(tx: Sender<String>, mut wake: UnixStream) {
    let Some(path) = dir().map(|d| d.join(".socket2.sock")) else { return };
    std::thread::spawn(move || loop {
        if let Ok(s) = UnixStream::connect(&path) {
            for line in BufReader::new(s).lines().map_while(Result::ok) {
                if tx.send(line).is_err() {
                    return;
                }
                let _ = wake.write_all(b"!");
            }
        }
        std::thread::sleep(std::time::Duration::from_secs(1));
    });
}
