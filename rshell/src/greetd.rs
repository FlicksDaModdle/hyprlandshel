//! greetd's side of the greeter (Quickshell.Services.Greetd, as
//! GreeterState.qml used it): the socket greetd gives its greeter in
//! GREETD_SOCK, spoken in greetd's IPC — each message a JSON object after
//! its length (four bytes, the machine's own byte order), each request
//! answered by exactly one reply.
//!
//! The requests go one at a time on a thread of their own, so a PAM module
//! that takes its time (a face being looked for) never stops the screen; what
//! comes back is put in the shape the greeter thinks in:
//!
//!   Ask { msg, echo }     PAM wants an answer (a password, a code)
//!   Info { msg, error }   words to show; acknowledged here
//!   Failed                the answer was wrong
//!   Error(desc)           anything else that went wrong
//!   Ready                 authenticated: the session can be started
//!   Started               it has been; the greeter's work is done
//!
//! The password goes down the socket to greetd and nowhere else.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{channel, Receiver, Sender};

pub enum Req {
    Create(String),
    Respond(Option<String>),
    Start(Vec<String>, Vec<String>),
    Cancel,
}

#[derive(Debug)]
pub enum Event {
    Ask { msg: String, echo: bool },
    Info { msg: String, error: bool },
    Failed,
    Error(String),
    Ready,
    Started,
}

pub struct Greetd {
    tx: Sender<Req>,
    pub rx: Receiver<Event>,
}

fn send(s: &mut UnixStream, v: &Value) -> std::io::Result<()> {
    let body = v.to_string().into_bytes();
    s.write_all(&(body.len() as u32).to_ne_bytes())?;
    s.write_all(&body)?;
    let mut b = body;
    // A response may have been in it.
    b.iter_mut().for_each(|x| *x = 0);
    s.flush()
}

fn recv(s: &mut UnixStream) -> std::io::Result<Value> {
    let mut len = [0u8; 4];
    s.read_exact(&mut len)?;
    let n = u32::from_ne_bytes(len) as usize;
    if n > 1 << 20 {
        return Err(std::io::Error::other("greetd sent too much"));
    }
    let mut body = vec![0u8; n];
    s.read_exact(&mut body)?;
    serde_json::from_slice(&body).map_err(std::io::Error::other)
}

impl Greetd {
    /// None outside greetd: the greeter is then a preview.
    pub fn connect(wake: &UnixStream) -> Option<Greetd> {
        let path = std::env::var("GREETD_SOCK").ok().filter(|p| !p.is_empty())?;
        let mut sock = UnixStream::connect(path).ok()?;
        let (tx, rq) = channel::<Req>();
        let (ev, rx) = channel::<Event>();
        let mut wake = wake.try_clone().ok()?;
        std::thread::spawn(move || {
            let mut out = |e: Event| {
                let _ = ev.send(e);
                let _ = wake.write_all(b"!");
            };
            for r in rq {
                let starting = matches!(r, Req::Start(..));
                let cancelling = matches!(r, Req::Cancel);
                let v = match r {
                    Req::Create(user) => json!({ "type": "create_session", "username": user }),
                    Req::Respond(a) => json!({ "type": "post_auth_message_response", "response": a }),
                    Req::Start(cmd, env) => json!({ "type": "start_session", "cmd": cmd, "env": env }),
                    Req::Cancel => json!({ "type": "cancel_session" }),
                };
                if send(&mut sock, &v).is_err() {
                    out(Event::Error("Lost the connection to greetd".into()));
                    return;
                }
                // Each reply, and the acknowledgements of PAM's words, which
                // only ask to be read.
                loop {
                    let reply = match recv(&mut sock) {
                        Ok(r) => r,
                        Err(_) => {
                            out(Event::Error("Lost the connection to greetd".into()));
                            return;
                        }
                    };
                    if cancelling {
                        break;
                    }
                    match reply["type"].as_str() {
                        Some("success") => out(if starting { Event::Started } else { Event::Ready }),
                        Some("error") => {
                            if reply["error_type"] == "auth_error" {
                                out(Event::Failed);
                                // The attempt is over: greetd is told, for a
                                // clean start next time.
                                if send(&mut sock, &json!({ "type": "cancel_session" })).is_ok() {
                                    let _ = recv(&mut sock);
                                }
                            } else {
                                out(Event::Error(reply["description"].as_str().unwrap_or("").to_string()));
                                if !starting && send(&mut sock, &json!({ "type": "cancel_session" })).is_ok() {
                                    let _ = recv(&mut sock);
                                }
                            }
                        }
                        Some("auth_message") => {
                            let msg = reply["auth_message"].as_str().unwrap_or("").to_string();
                            match reply["auth_message_type"].as_str() {
                                Some("secret") => out(Event::Ask { msg, echo: false }),
                                Some("visible") => out(Event::Ask { msg, echo: true }),
                                kind => {
                                    out(Event::Info { msg, error: kind == Some("error") });
                                    // Read; nothing to answer.
                                    if send(&mut sock, &json!({ "type": "post_auth_message_response", "response": null })).is_err() {
                                        out(Event::Error("Lost the connection to greetd".into()));
                                        return;
                                    }
                                    continue;
                                }
                            }
                        }
                        _ => out(Event::Error("greetd said something unexpected".into())),
                    }
                    break;
                }
            }
        });
        Some(Greetd { tx, rx })
    }

    pub fn send(&self, r: Req) {
        let _ = self.tx.send(r);
    }
}
