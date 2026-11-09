//! The bar's smaller indicators, each from where the Quickshell shell gets
//! it: updates from checkupdates (and paru or yay for the AUR), Mail's
//! unread count from hyprshell-maild's socket, timers from timers.json.

use serde_json::Value;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::time::Duration;

pub enum Event {
    Updates { names: Vec<String>, helper: String },
    /// None: Mail isn't running.
    Mail(Option<i64>),
}

fn runtime() -> PathBuf {
    std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into())
}

fn state_home() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"))
}

const CHECK: &str = r#"db="${XDG_CACHE_HOME:-$HOME/.cache}/hyprshell/checkup-db"
mkdir -p "$db"
if command -v checkupdates >/dev/null 2>&1; then
  CHECKUPDATES_DB="$db" checkupdates 2>/dev/null | awk 'NF>=4 {print "R", $1, $2, $4}'
fi
for h in paru yay; do
  if command -v "$h" >/dev/null 2>&1; then
    echo "H $h"
    "$h" -Qua 2>/dev/null | awk 'NF>=4 && $1 !~ /^::/ {print "A", $1, $2, $4}'
    break
  fi
done"#;

fn send(tx: &Sender<Event>, wake: &mut UnixStream, ev: Event) -> bool {
    let ok = tx.send(ev).is_ok();
    let _ = wake.write_all(b"!");
    ok
}

/// Updates: a minute and a half after starting (as the Quickshell shell
/// waits), then every three hours, or at once when `now` is poked.
pub fn updates(tx: Sender<Event>, now: std::sync::mpsc::Receiver<()>, mut wake: UnixStream) {
    std::thread::spawn(move || {
        let mut wait = Duration::from_secs(90);
        loop {
            match now.recv_timeout(wait) {
                Ok(()) | Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => return,
            }
            wait = Duration::from_secs(3 * 3600);
            let Ok(out) = std::process::Command::new("sh").arg("-c").arg(CHECK).output() else { continue };
            let text = String::from_utf8_lossy(&out.stdout);
            let mut names = Vec::new();
            let mut helper = String::new();
            for l in text.lines() {
                let f: Vec<&str> = l.split_whitespace().collect();
                match f.as_slice() {
                    // "name  1.0 → 1.1", the AUR's marked.
                    [k @ ("R" | "A"), n, from, to] => names.push(format!("{n}  {from} → {to}{}", if *k == "A" { "  · AUR" } else { "" })),
                    [k @ ("R" | "A"), n] => names.push(format!("{n}{}", if *k == "A" { "  · AUR" } else { "" })),
                    ["H", h] => helper = h.to_string(),
                    _ => {}
                }
            }
            if !send(&tx, &mut wake, Event::Updates { names, helper }) {
                return;
            }
        }
    });
}

/// Mail's unread count, while hyprshell-maild runs: asked once on
/// connecting, then told whenever it changes.
pub fn mail(tx: Sender<Event>, mut wake: UnixStream) {
    std::thread::spawn(move || {
        let path = runtime().join("hyprshell-mail.sock");
        let mut was_up = false;
        loop {
            if let Ok(mut s) = UnixStream::connect(&path) {
                was_up = true;
                let _ = s.write_all(b"{\"cmd\":\"status\",\"rid\":1}\n");
                for line in BufReader::new(s).lines().map_while(Result::ok) {
                    let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                    let n = if v["event"] == "unread" {
                        v["total"].as_i64()
                    } else {
                        v["result"]["unread"].as_i64()
                    };
                    if let Some(n) = n {
                        if !send(&tx, &mut wake, Event::Mail(Some(n))) {
                            return;
                        }
                    }
                }
            }
            if was_up {
                was_up = false;
                if !send(&tx, &mut wake, Event::Mail(None)) {
                    return;
                }
            }
            std::thread::sleep(Duration::from_secs(10));
        }
    });
}

pub struct Timer {
    pub label: String,
    /// Seconds left.
    pub left: i64,
    pub running: bool,
    pub pomodoro: bool,
}

/// "4:05", or "1:02:09" past the hour.
pub fn clock(secs: i64) -> String {
    let s = secs.max(0);
    let (h, m, s) = (s / 3600, s / 60 % 60, s % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// The timers and the pomodoro, from the file the Quickshell shell's Timers
/// service keeps (it is the one that rings them; this only shows them).
pub fn timers() -> Vec<Timer> {
    let Ok(t) = std::fs::read_to_string(state_home().join("hyprshell/timers.json")) else { return Vec::new() };
    let Ok(v) = serde_json::from_str::<Value>(&t) else { return Vec::new() };
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0);
    let mut out = Vec::new();
    for t in v["timers"].as_array().into_iter().flatten() {
        let running = t["running"].as_bool().unwrap_or(false);
        let left = if running { (t["endsAt"].as_f64().unwrap_or(0.0) as i64 - now) / 1000 } else { t["left"].as_f64().unwrap_or(0.0) as i64 };
        let label = t["label"].as_str().filter(|s| !s.is_empty()).unwrap_or("Timer").to_string();
        out.push(Timer { label, left: left.max(0), running, pomodoro: false });
    }
    let p = &v["pomo"];
    let phase = p["phase"].as_str().unwrap_or("idle");
    if phase != "idle" && !phase.is_empty() {
        let running = p["running"].as_bool().unwrap_or(false);
        let left = if running { (p["endsAt"].as_f64().unwrap_or(0.0) as i64 - now) / 1000 } else { p["left"].as_f64().unwrap_or(0.0) as i64 };
        let label = match phase {
            "work" => "Focus",
            "short" => "Short break",
            "long" => "Long break",
            _ => "Pomodoro",
        };
        out.push(Timer { label: label.into(), left: left.max(0), running, pomodoro: true });
    }
    out
}

/// A program the shell starts and leaves running on its own.
pub fn spawn(argv: &[&str]) {
    use std::os::unix::process::CommandExt;
    let Some((prog, args)) = argv.split_first() else { return };
    let mut c = std::process::Command::new(prog);
    c.args(args).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null());
    // Its own session, so it outlives this shell and gets no signals meant for it.
    unsafe {
        c.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    if let Ok(mut child) = c.spawn() {
        // Reaped on a thread, so it leaves no zombie.
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

/// `sh -c` for the session actions, which chain fallbacks.
pub fn sh(script: &str) {
    spawn(&["sh", "-c", script]);
}

/// The user's terminal, as hyprland.lua picks it.
pub fn terminal() -> String {
    std::env::var("TERMINAL").ok().filter(|t| !t.is_empty()).unwrap_or_else(|| "kitty".into())
}
