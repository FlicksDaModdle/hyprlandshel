//! pam_hyprshell_face.so: face unlock in PAM, by asking hyprshell-faced.
//!
//! It runs inside whatever is asking for a login — greetd, the lock
//! screen, sudo — so it does next to nothing itself: it sends the user's
//! name to the service's socket and waits for its answer.
//!
//!   PAM_SUCCESS           the service recognised you
//!   PAM_AUTH_ERR          it looked, and it wasn't you (or you weren't there)
//!   PAM_AUTHINFO_UNAVAIL  it couldn't say: the service isn't running, no
//!                         face of yours is enrolled with it, the camera
//!                         wouldn't open, a remote login. PAM files set
//!                         this to move on to Howdy:
//!
//!   auth [success=done authinfo_unavail=ignore default=die] pam_hyprshell_face.so
//!   auth required pam_howdy.so
//!
//! Nothing in here may bring its host down: any fault is "unavailable".

use std::ffi::CStr;
use std::io::{Read, Write};
use std::os::raw::{c_char, c_int, c_void};
use std::os::unix::net::UnixStream;
use std::time::Duration;

const PAM_SUCCESS: c_int = 0;
const PAM_AUTH_ERR: c_int = 7;
const PAM_AUTHINFO_UNAVAIL: c_int = 9;
const PAM_RHOST: c_int = 4;

const SOCKET: &str = "/run/hyprshell-face/socket";

#[link(name = "pam")]
extern "C" {
    fn pam_get_user(pamh: *mut c_void, user: *mut *const c_char, prompt: *const c_char) -> c_int;
    fn pam_get_item(pamh: *const c_void, item_type: c_int, item: *mut *const c_void) -> c_int;
}

#[no_mangle]
pub extern "C" fn pam_sm_authenticate(pamh: *mut c_void, _flags: c_int, _argc: c_int, _argv: *const *const c_char) -> c_int {
    std::panic::catch_unwind(|| authenticate(pamh)).unwrap_or(PAM_AUTHINFO_UNAVAIL)
}

#[no_mangle]
pub extern "C" fn pam_sm_setcred(_pamh: *mut c_void, _flags: c_int, _argc: c_int, _argv: *const *const c_char) -> c_int {
    PAM_SUCCESS
}

fn authenticate(pamh: *mut c_void) -> c_int {
    // Not for logins from elsewhere: the camera sees who's here.
    let mut rhost: *const c_void = std::ptr::null();
    // SAFETY: pamh is the handle PAM called us with; the item is only read.
    if unsafe { pam_get_item(pamh, PAM_RHOST, &mut rhost) } == PAM_SUCCESS && !rhost.is_null() {
        let host = unsafe { CStr::from_ptr(rhost as *const c_char) }.to_string_lossy();
        if !host.is_empty() && host != "localhost" {
            return PAM_AUTHINFO_UNAVAIL;
        }
    }
    let mut user: *const c_char = std::ptr::null();
    // SAFETY: as above; PAM owns the returned string.
    if unsafe { pam_get_user(pamh, &mut user, std::ptr::null()) } != PAM_SUCCESS || user.is_null() {
        return PAM_AUTHINFO_UNAVAIL;
    }
    let user = unsafe { CStr::from_ptr(user) }.to_string_lossy().into_owned();
    match ask(&user) {
        Some(Answer::Match) => PAM_SUCCESS,
        Some(Answer::NoMatch) => PAM_AUTH_ERR,
        _ => PAM_AUTHINFO_UNAVAIL,
    }
}

enum Answer {
    Match,
    NoMatch,
    Unavailable,
}

/// A user name as PAM's are on this kind of system: anything else isn't
/// sent anywhere.
fn plain(name: &str) -> bool {
    !name.is_empty() && name.len() <= 64 && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

/// The service's socket. If the service is installed but not answering
/// yet (it's still loading, just after boot), it's given a few seconds,
/// rather than handing the login to Howdy at once.
fn connect() -> Option<UnixStream> {
    let installed = std::path::Path::new("/usr/local/libexec/hyprshell-faced").exists();
    let until = std::time::Instant::now() + Duration::from_secs(if installed { 6 } else { 0 });
    loop {
        match UnixStream::connect(SOCKET) {
            Ok(s) => return Some(s),
            Err(_) if std::time::Instant::now() < until => std::thread::sleep(Duration::from_millis(100)),
            Err(_) => return None,
        }
    }
}

fn ask(user: &str) -> Option<Answer> {
    if !plain(user) {
        return None;
    }
    let mut stream = connect()?;
    // Generous: the service has its own, shorter, timeout.
    stream.set_read_timeout(Some(Duration::from_secs(20))).ok()?;
    stream.set_write_timeout(Some(Duration::from_secs(2))).ok()?;
    stream.write_all(format!("{{\"op\":\"verify\",\"user\":\"{user}\"}}\n").as_bytes()).ok()?;
    let mut reply = Vec::new();
    let mut chunk = [0u8; 512];
    while !reply.contains(&b'\n') && reply.len() < 8192 {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            break;
        }
        reply.extend_from_slice(&chunk[..n]);
    }
    let reply = String::from_utf8_lossy(&reply);
    Some(if reply.contains("\"result\":\"match\"") {
        Answer::Match
    } else if reply.contains("\"result\":\"nomatch\"") {
        Answer::NoMatch
    } else {
        Answer::Unavailable
    })
}
