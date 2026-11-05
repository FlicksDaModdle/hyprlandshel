//! The polkit authentication agent (modules/polkit/PolkitPrompt.qml, and
//! the agent Quickshell.Services.Polkit registers): what asks for a
//! password when something wants admin rights (pkexec, the face unlock
//! setup, mounting, …). Without one, those requests fail or hang.
//!
//! Registered with polkit on the system bus for this session. A request
//! (BeginAuthentication) shows the prompt; the password goes to polkit's
//! helper, which checks it with PAM: over /run/polkit/agent-helper.socket
//! where polkit runs it as a service (polkit 126 on), else the setuid
//! polkit-agent-helper-1. The password never goes on a command line or
//! anywhere but the helper's input.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use zbus::zvariant::{OwnedValue, Value};

const PATH: &str = "/org/hyprshell/PolicyKit1/AuthenticationAgent";

/// A request for the prompt.
pub struct Request {
    pub cookie: String,
    pub action: String,
    pub message: String,
    /// The users who may answer: (name, uid).
    pub users: Vec<(String, u32)>,
}

pub enum Event {
    Begin(Request),
    /// polkit gave up on it (the program asking went away).
    Cancelled(String),
}

/// How a request ended: answered, or turned down.
type Outcomes = Arc<Mutex<HashMap<String, bool>>>;

struct Agent {
    tx: Mutex<Sender<Event>>,
    wake: Mutex<UnixStream>,
    outcomes: Outcomes,
}

fn user_name(uid: u32) -> Option<String> {
    // SAFETY: getpwuid's result is copied out before anything else runs it.
    unsafe {
        let pw = libc::getpwuid(uid);
        if pw.is_null() || (*pw).pw_name.is_null() {
            return None;
        }
        Some(std::ffi::CStr::from_ptr((*pw).pw_name).to_string_lossy().into_owned())
    }
}

#[zbus::interface(name = "org.freedesktop.PolicyKit1.AuthenticationAgent")]
impl Agent {
    /// Answered only once the user has: polkit waits on the reply.
    async fn begin_authentication(
        &self,
        action_id: String,
        message: String,
        _icon_name: String,
        _details: HashMap<String, String>,
        cookie: String,
        identities: Vec<(String, HashMap<String, OwnedValue>)>,
    ) -> zbus::fdo::Result<()> {
        let users: Vec<(String, u32)> = identities
            .iter()
            .filter(|(kind, _)| kind == "unix-user")
            .filter_map(|(_, d)| d.get("uid").and_then(|v| u32::try_from(v).ok()))
            .filter_map(|uid| Some((user_name(uid)?, uid)))
            .collect();
        if users.is_empty() {
            return Err(zbus::fdo::Error::Failed("no user to ask".into()));
        }
        if let (Ok(tx), Ok(mut w)) = (self.tx.lock(), self.wake.lock()) {
            let _ = tx.send(Event::Begin(Request { cookie: cookie.clone(), action: action_id, message, users }));
            let _ = w.write_all(b"!");
        }
        loop {
            async_io::Timer::after(Duration::from_millis(100)).await;
            let done = self.outcomes.lock().ok().and_then(|mut o| o.remove(&cookie));
            match done {
                Some(true) => return Ok(()),
                Some(false) => return Err(zbus::fdo::Error::Failed("org.freedesktop.PolicyKit1.Error.Cancelled".into())),
                None => {}
            }
        }
    }

    fn cancel_authentication(&self, cookie: String) {
        if let (Ok(tx), Ok(mut w)) = (self.tx.lock(), self.wake.lock()) {
            let _ = tx.send(Event::Cancelled(cookie));
            let _ = w.write_all(b"!");
        }
    }
}

/// This process's start time, as polkit identifies a process by it.
fn start_time() -> u64 {
    std::fs::read_to_string("/proc/self/stat")
        .ok()
        .and_then(|s| s.rsplit_once(')').map(|(_, rest)| rest.to_string()))
        .and_then(|rest| rest.split_whitespace().nth(19).and_then(|v| v.parse().ok()))
        .unwrap_or(0)
}

/// Registers the agent (again and again until it can: the Quickshell
/// shell's may still be there a moment) and serves it. `outcomes` is where
/// the main loop says how each request ended.
pub fn start(tx: Sender<Event>, wake: UnixStream, outcomes: Outcomes) {
    std::thread::spawn(move || {
        for attempt in 0u32.. {
            let Ok(w) = wake.try_clone() else { return };
            let agent = Agent { tx: Mutex::new(tx.clone()), wake: Mutex::new(w), outcomes: outcomes.clone() };
            let conn = match zbus::blocking::connection::Builder::system().and_then(|b| b.serve_at(PATH, agent)).and_then(|b| b.build()) {
                Ok(c) => c,
                Err(e) => {
                    if attempt == 0 {
                        eprintln!("hyprshell-rs: no system bus for the polkit agent ({e})");
                    }
                    std::thread::sleep(Duration::from_secs(10));
                    continue;
                }
            };
            // This session, or failing that this process.
            let subject: (String, HashMap<String, Value>) = match std::env::var("XDG_SESSION_ID") {
                Ok(id) if !id.is_empty() => ("unix-session".into(), HashMap::from([("session-id".to_string(), Value::from(id))])),
                _ => (
                    "unix-process".into(),
                    HashMap::from([
                        ("pid".to_string(), Value::from(std::process::id())),
                        ("start-time".to_string(), Value::from(start_time())),
                    ]),
                ),
            };
            let locale = std::env::var("LANG").unwrap_or_else(|_| "en_US.UTF-8".into());
            let r = conn.call_method(
                Some("org.freedesktop.PolicyKit1"),
                "/org/freedesktop/PolicyKit1/Authority",
                Some("org.freedesktop.PolicyKit1.Authority"),
                "RegisterAuthenticationAgent",
                &(subject, locale, PATH),
            );
            match r {
                Ok(_) => {
                    eprintln!("hyprshell-rs: polkit agent registered");
                    // The connection serves on its own thread; keep it.
                    loop {
                        std::thread::sleep(Duration::from_secs(3600));
                        let _ = &conn;
                    }
                }
                Err(e) => {
                    if attempt == 0 {
                        eprintln!("hyprshell-rs: can't be the polkit agent yet ({e}); trying again");
                    }
                    drop(conn);
                    std::thread::sleep(Duration::from_secs(if attempt < 6 { 2 } else { 15 }));
                }
            }
        }
    });
}

/// What the helper said, for the prompt.
pub enum Said {
    Success,
    Failure(String),
    /// It wants another answer (a second factor, a new prompt).
    Ask(String),
    Info(String),
}

/// g_strcompress: the helper escapes its lines as C strings.
fn unescape(s: &str) -> String {
    let mut out = String::new();
    let mut it = s.chars();
    while let Some(c) = it.next() {
        if c == '\\' {
            match it.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some('\\') => out.push('\\'),
                Some('"') => out.push('"'),
                Some(o) => out.push(o),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// One attempt: the user, the cookie and the password to polkit's helper;
/// what it says comes back over `tx`. Runs on a thread of its own.
pub fn attempt(user: String, cookie: String, password: String, tx: Sender<Said>, mut wake: UnixStream) {
    std::thread::spawn(move || {
        let said = |s: Said, wake: &mut UnixStream| {
            let _ = tx.send(s);
            let _ = wake.write_all(b"!");
        };
        // The socket where there is one; else the setuid helper.
        let (mut input, output): (Box<dyn Write>, Box<dyn std::io::Read>) =
            match UnixStream::connect("/run/polkit/agent-helper.socket") {
                Ok(sock) => {
                    let mut w = sock.try_clone().expect("socket");
                    let _ = writeln!(w, "{user}");
                    (Box::new(w), Box::new(sock))
                }
                Err(_) => {
                    let helper = ["/usr/lib/polkit-1/polkit-agent-helper-1", "/usr/libexec/polkit-agent-helper-1"]
                        .into_iter()
                        .find(|p| std::path::Path::new(p).exists());
                    let Some(helper) = helper else {
                        said(Said::Failure("polkit's helper isn't installed".into()), &mut wake);
                        return;
                    };
                    match std::process::Command::new(helper)
                        .arg(&user)
                        .stdin(std::process::Stdio::piped())
                        .stdout(std::process::Stdio::piped())
                        .stderr(std::process::Stdio::null())
                        .spawn()
                    {
                        Ok(mut c) => {
                            let i = c.stdin.take().expect("piped");
                            let o = c.stdout.take().expect("piped");
                            std::thread::spawn(move || {
                                let _ = c.wait();
                            });
                            (Box::new(i), Box::new(o))
                        }
                        Err(e) => {
                            said(Said::Failure(format!("can't run polkit's helper ({e})")), &mut wake);
                            return;
                        }
                    }
                }
            };
        let _ = writeln!(input, "{cookie}");
        let _ = input.flush();
        let mut answered = false;
        for line in BufReader::new(output).lines() {
            let Ok(line) = line else { break };
            let l = unescape(&line);
            if let Some(p) = l.strip_prefix("PAM_PROMPT_ECHO_OFF ").or(l.strip_prefix("PAM_PROMPT_ECHO_ON ")) {
                if !answered {
                    // The password the user typed answers the first prompt.
                    answered = true;
                    let _ = writeln!(input, "{password}");
                    let _ = input.flush();
                } else {
                    said(Said::Ask(p.to_string()), &mut wake);
                    // Another prompt can't be answered here yet: give up
                    // on this attempt; the user can try again.
                    let _ = writeln!(input);
                    let _ = input.flush();
                }
            } else if let Some(m) = l.strip_prefix("PAM_ERROR_MSG ") {
                said(Said::Failure(m.to_string()), &mut wake);
            } else if let Some(m) = l.strip_prefix("PAM_TEXT_INFO ") {
                said(Said::Info(m.to_string()), &mut wake);
            } else if l.starts_with("SUCCESS") {
                said(Said::Success, &mut wake);
                return;
            } else if l.starts_with("FAILURE") {
                said(Said::Failure(String::new()), &mut wake);
                return;
            }
        }
        said(Said::Failure(String::new()), &mut wake);
    });
}
