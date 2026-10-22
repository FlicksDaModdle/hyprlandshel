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
//! While it looks, the lock and login screens are told what the camera
//! sees ("Come a little closer"), as PAM information messages that start
//! with a zero-width space, which they show under the field and nothing
//! else does; sudo and the rest aren't sent them.
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
const PAM_SERVICE: c_int = 1;
const PAM_CONV: c_int = 5;
const PAM_RHOST: c_int = 4;
const PAM_TEXT_INFO: c_int = 4;

/// What a hint starts with, for the screens that show them to know one.
const HINT_MARK: &str = "\u{200b}";

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
    conv: Option<unsafe extern "C" fn(c_int, *mut *const PamMessage, *mut *mut PamResponse, *mut c_void) -> c_int>,
    appdata_ptr: *mut c_void,
}

const SOCKET: &str = "/run/hyprshell-face/socket";

#[link(name = "pam")]
extern "C" {
    fn pam_get_user(pamh: *mut c_void, user: *mut *const c_char, prompt: *const c_char) -> c_int;
    fn pam_get_item(pamh: *const c_void, item_type: c_int, item: *mut *const c_void) -> c_int;
}

extern "C" {
    fn free(p: *mut c_void);
}

/// A line of information through the asking program's conversation.
fn tell(pamh: *mut c_void, text: &str) {
    let Ok(text) = std::ffi::CString::new(format!("{HINT_MARK}{text}")) else { return };
    let mut item: *const c_void = std::ptr::null();
    // SAFETY: PAM_CONV is a struct pam_conv owned by PAM; only read here,
    // and its function called as Linux-PAM documents. The response, if
    // the program gave one, is ours to free.
    unsafe {
        if pam_get_item(pamh, PAM_CONV, &mut item) != PAM_SUCCESS || item.is_null() {
            return;
        }
        let conv = &*(item as *const PamConv);
        let Some(f) = conv.conv else { return };
        let message = PamMessage { msg_style: PAM_TEXT_INFO, msg: text.as_ptr() };
        let mut list: *const PamMessage = &message;
        let mut response: *mut PamResponse = std::ptr::null_mut();
        f(1, &mut list, &mut response, conv.appdata_ptr);
        if !response.is_null() {
            if !(*response).resp.is_null() {
                free((*response).resp as *mut c_void);
            }
            free(response as *mut c_void);
        }
    }
}

/// The lock screen (hyprshell-lock) or the login screen (greetd): the
/// programs that show hints. Anything else — sudo in a terminal — isn't
/// sent them.
fn shows_hints(pamh: *mut c_void) -> bool {
    let mut item: *const c_void = std::ptr::null();
    // SAFETY: reading a string item PAM owns.
    if unsafe { pam_get_item(pamh, PAM_SERVICE, &mut item) } != PAM_SUCCESS || item.is_null() {
        return false;
    }
    let service = unsafe { CStr::from_ptr(item as *const c_char) }.to_string_lossy();
    service.starts_with("hyprshell") || service.starts_with("greetd")
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
    let hints = shows_hints(pamh);
    match ask(&user, hints.then_some(pamh)) {
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

fn ask(user: &str, hints: Option<*mut c_void>) -> Option<Answer> {
    if !plain(user) {
        return None;
    }
    let mut stream = connect()?;
    // Generous: the service has its own, shorter, timeout.
    stream.set_read_timeout(Some(Duration::from_secs(20))).ok()?;
    stream.set_write_timeout(Some(Duration::from_secs(2))).ok()?;
    let wants = if hints.is_some() { ",\"hints\":true" } else { "" };
    stream.write_all(format!("{{\"op\":\"verify\",\"user\":\"{user}\"{wants}}}\n").as_bytes()).ok()?;
    // Hints first, a line each, then the answer.
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 512];
    let reply = loop {
        if let Some(end) = buffer.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buffer.drain(..=end).collect();
            let line = String::from_utf8_lossy(&line).into_owned();
            if line.starts_with("{\"hint\":") {
                if let (Some(pamh), Ok(v)) = (hints, serde_hint(&line)) {
                    tell(pamh, &v);
                }
                continue;
            }
            break line;
        }
        if buffer.len() > 65536 {
            return None;
        }
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            break String::from_utf8_lossy(&buffer).into_owned();
        }
        buffer.extend_from_slice(&chunk[..n]);
    };
    // Whatever was said last is taken back.
    if let Some(pamh) = hints {
        tell(pamh, "");
    }
    Some(if reply.contains("\"result\":\"match\"") {
        Answer::Match
    } else if reply.contains("\"result\":\"nomatch\"") {
        Answer::NoMatch
    } else {
        Answer::Unavailable
    })
}

/// The text of a `{"hint":"..."}` line: the service writes it with
/// serde_json, so a plain string with \" and \\ escapes at most.
fn serde_hint(line: &str) -> Result<String, ()> {
    let rest = line.trim().strip_prefix("{\"hint\":\"").ok_or(())?;
    let rest = rest.strip_suffix("\"}").ok_or(())?;
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push(' '),
                Some(c) => out.push(c),
                None => break,
            }
        } else if !c.is_control() {
            out.push(c);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::serde_hint;

    #[test]
    fn reads_hint_lines() {
        assert_eq!(serde_hint("{\"hint\":\"Come a little closer\"}\n"), Ok("Come a little closer".to_string()));
        assert_eq!(serde_hint("{\"hint\":\"\"}"), Ok(String::new()));
        assert_eq!(serde_hint("{\"hint\":\"It's \\\"dark\\\"\"}"), Ok("It's \"dark\"".to_string()));
        assert!(serde_hint("{\"result\":\"match\"}").is_err());
    }
}
