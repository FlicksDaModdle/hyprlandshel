//! Checking a password, or your face, against PAM (Quickshell's
//! PamContext, as LockAuth.qml used it).
//!
//! Each attempt is a child process: this same program, run as
//! `hyprshell-rs --pam-helper SERVICE USER`. A face attempt that has to be
//! called off (you started typing) is then ended by ending the process, which
//! PAM itself has no way to do from inside a call; and a module that hangs
//! takes only the child with it.
//!
//! Between the two, JSON lines. The child writes what PAM says:
//!
//!   {"ev":"prompt","echo":false,"msg":"Password: "}   it wants an answer
//!   {"ev":"info","msg":"…","error":false}               words to show
//!   {"ev":"done","ok":true,"code":0,"msg":"…"}          the result
//!
//! and reads each answer as one line on its stdin — the password goes there,
//! never on a command line, where any process could read it.

use serde_json::{json, Value};
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::io::{BufRead, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver};

const PAM_SUCCESS: c_int = 0;
const PAM_BUF_ERR: c_int = 5;
const PAM_CONV_ERR: c_int = 19;
const PAM_PROMPT_ECHO_OFF: c_int = 1;
const PAM_PROMPT_ECHO_ON: c_int = 2;
const PAM_ERROR_MSG: c_int = 3;
pub const PAM_MAXTRIES: i64 = 11;

#[repr(C)]
struct PamMessage {
    msg_style: c_int,
    msg: *const c_char,
}
#[repr(C)]
struct PamResponse {
    resp: *mut c_char,
    resp_retcode: c_int,
}
#[repr(C)]
struct PamConv {
    conv: extern "C" fn(c_int, *mut *const PamMessage, *mut *mut PamResponse, *mut c_void) -> c_int,
    appdata_ptr: *mut c_void,
}

#[link(name = "pam")]
extern "C" {
    fn pam_start(service: *const c_char, user: *const c_char, conv: *const PamConv, pamh: *mut *mut c_void) -> c_int;
    fn pam_authenticate(pamh: *mut c_void, flags: c_int) -> c_int;
    fn pam_end(pamh: *mut c_void, status: c_int) -> c_int;
    fn pam_strerror(pamh: *mut c_void, errnum: c_int) -> *const c_char;
}

fn say(v: Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{v}");
    let _ = out.flush();
}

/// PAM's questions, answered from stdin; its words, passed on.
extern "C" fn converse(n: c_int, msgs: *mut *const PamMessage, resp: *mut *mut PamResponse, _: *mut c_void) -> c_int {
    if n <= 0 || msgs.is_null() || resp.is_null() {
        return PAM_CONV_ERR;
    }
    // SAFETY: calloc'd for n responses, freed by PAM (with each answer).
    let out = unsafe { libc::calloc(n as usize, std::mem::size_of::<PamResponse>()) } as *mut PamResponse;
    if out.is_null() {
        return PAM_BUF_ERR;
    }
    let stdin = std::io::stdin();
    for i in 0..n as usize {
        // SAFETY: Linux-PAM passes an array of n pointers to messages.
        let m = unsafe { &**msgs.add(i) };
        let text = if m.msg.is_null() { String::new() } else { unsafe { CStr::from_ptr(m.msg) }.to_string_lossy().into_owned() };
        match m.msg_style {
            PAM_PROMPT_ECHO_OFF | PAM_PROMPT_ECHO_ON => {
                say(json!({ "ev": "prompt", "echo": m.msg_style == PAM_PROMPT_ECHO_ON, "msg": text }));
                let mut line = String::new();
                if stdin.lock().read_line(&mut line).unwrap_or(0) == 0 {
                    // No answer coming: called off.
                    unsafe { libc::free(out as *mut c_void) };
                    return PAM_CONV_ERR;
                }
                let answer = line.strip_suffix('\n').unwrap_or(&line);
                let c = CString::new(answer).unwrap_or_default();
                // SAFETY: strdup'd, for PAM to free.
                unsafe { (*out.add(i)).resp = libc::strdup(c.as_ptr()) };
                // The copies here are wiped as they go.
                let mut bytes = line.into_bytes();
                bytes.iter_mut().for_each(|b| *b = 0);
                let mut c = c.into_bytes();
                c.iter_mut().for_each(|b| *b = 0);
            }
            _ => say(json!({ "ev": "info", "msg": text, "error": m.msg_style == PAM_ERROR_MSG })),
        }
    }
    // SAFETY: resp is PAM's out-pointer.
    unsafe { *resp = out };
    PAM_SUCCESS
}

/// The child's side: one authentication, then out.
pub fn helper(service: &str, user: &str) -> ! {
    let (Ok(svc), Ok(usr)) = (CString::new(service), CString::new(user)) else { std::process::exit(2) };
    let conv = PamConv { conv: converse, appdata_ptr: std::ptr::null_mut() };
    let mut h: *mut c_void = std::ptr::null_mut();
    // SAFETY: valid C strings and a conversation that outlives the handle.
    let mut r = unsafe { pam_start(svc.as_ptr(), usr.as_ptr(), &conv, &mut h) };
    if r == PAM_SUCCESS {
        r = unsafe { pam_authenticate(h, 0) };
    }
    let msg = if h.is_null() { String::new() } else { unsafe { CStr::from_ptr(pam_strerror(h, r)) }.to_string_lossy().into_owned() };
    if !h.is_null() {
        unsafe { pam_end(h, r) };
    }
    say(json!({ "ev": "done", "ok": r == PAM_SUCCESS, "code": r, "msg": msg }));
    std::process::exit(if r == PAM_SUCCESS { 0 } else { 1 })
}

/// An attempt under way, from the shell's side.
pub struct Attempt {
    child: Child,
    stdin: Option<ChildStdin>,
    pub rx: Receiver<Value>,
}

impl Attempt {
    /// Starts one; `wake` is written to as each line comes, to wake the loop.
    pub fn start(service: &str, user: &str, wake: &std::os::unix::net::UnixStream) -> Option<Attempt> {
        let exe = crate::testhooks::pam_helper()?;
        let mut child = Command::new(exe)
            .args(["--pam-helper", service, user])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let stdout = child.stdout.take()?;
        let stdin = child.stdin.take();
        let (tx, rx) = channel();
        let mut wake = wake.try_clone().ok()?;
        std::thread::spawn(move || {
            let mut ended = false;
            for line in std::io::BufReader::new(stdout).lines().map_while(Result::ok) {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    ended |= v["ev"] == "done";
                    let _ = tx.send(v);
                    let _ = wake.write_all(b"!");
                }
            }
            // Gone without a word: killed, or it crashed.
            if !ended {
                let _ = tx.send(json!({ "ev": "done", "ok": false, "code": -1, "msg": "", "gone": true }));
                let _ = wake.write_all(b"!");
            }
        });
        Some(Attempt { child, stdin, rx })
    }

    /// An answer to PAM's question.
    pub fn answer(&mut self, text: &str) {
        if let Some(s) = self.stdin.as_mut() {
            let mut line = Vec::with_capacity(text.len() + 1);
            line.extend_from_slice(text.as_bytes());
            line.push(b'\n');
            let _ = s.write_all(&line);
            let _ = s.flush();
            line.iter_mut().for_each(|b| *b = 0);
        }
    }

    /// Ends it, whatever it was doing.
    pub fn abort(&mut self) {
        self.stdin = None;
        let _ = self.child.kill();
    }
}

impl Drop for Attempt {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
