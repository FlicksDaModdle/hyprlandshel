//! The keyboard shortcuts' channel: hyprland.lua's binds append a line to
//! $XDG_RUNTIME_DIR/hyprshell.cmd, and this reads it (inotify) and hands
//! each line to the shell (services/Commands.qml) — where a shell loop
//! running `tail -F` did, two processes for as long as the session lasted.
//!
//! It also writes hyprshell.cmd.status the way that loop did ("watcher
//! <pid>", "shell <pid>", "socket …"), so the binds' trace and
//! `hyprshellctl doctor` can still tell whether anything is listening.
//!
//! Command:  cmd-watch {shellPid, socket}
//! Event:    cmd {line}

use crate::out;
use serde_json::{json, Value};
use std::ffi::CString;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::mpsc::{channel, Sender};

const MASK_FILE: u32 = libc::IN_MODIFY | libc::IN_CLOSE_WRITE | libc::IN_DELETE_SELF | libc::IN_MOVE_SELF;
const MASK_DIR: u32 = libc::IN_CREATE | libc::IN_MOVED_TO;

fn add_watch(fd: i32, path: &std::path::Path, mask: u32) -> i32 {
    let Ok(c) = CString::new(path.as_os_str().as_bytes()) else { return -1 };
    unsafe { libc::inotify_add_watch(fd, c.as_ptr(), mask) }
}

/// Everything appended since `offset`, as whole lines; a partial last
/// line waits for the rest.
fn read_new(path: &std::path::Path, offset: &mut u64, partial: &mut String) {
    let Ok(mut f) = std::fs::File::open(path) else { return };
    let len = f.metadata().map(|m| m.len()).unwrap_or(0);
    if len < *offset {
        // Truncated (or replaced): from the top.
        *offset = 0;
        partial.clear();
    }
    if f.seek(SeekFrom::Start(*offset)).is_err() {
        return;
    }
    let mut buf = String::new();
    if f.read_to_string(&mut buf).is_err() {
        return;
    }
    *offset += buf.len() as u64;
    partial.push_str(&buf);
    while let Some(i) = partial.find('\n') {
        let line = partial[..i].trim().to_string();
        partial.drain(..=i);
        if !line.is_empty() {
            out::emit(json!({ "ev": "cmd", "line": line }));
        }
    }
}

fn watch(dir: PathBuf, shell_pid: i64, socket: String) {
    let file = dir.join("hyprshell.cmd");
    let status = dir.join("hyprshell.cmd.status");
    // Start empty, as the shell's loop did: what was there was for a shell
    // that has gone.
    let _ = std::fs::write(&file, "");
    let sock_line = if !socket.is_empty() && std::path::Path::new(&socket).exists() {
        format!("socket {socket}")
    } else {
        format!("socket missing {socket}")
    };
    let _ = std::fs::write(&status, format!("watcher {}\nshell {shell_pid}\n{sock_line}\n", std::process::id()));

    let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
    if fd < 0 {
        out::emit(json!({ "ev": "cmd-error", "message": "inotify unavailable" }));
        return;
    }
    // The folder too, for the file being deleted and made again.
    add_watch(fd, &dir, MASK_DIR);
    let mut fwd = add_watch(fd, &file, MASK_FILE);
    let (mut offset, mut partial) = (0u64, String::new());
    let mut buf = vec![0u8; 4096];
    loop {
        let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n <= 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        let mut i = 0usize;
        let mut recreated = false;
        let mut touched = false;
        while i + std::mem::size_of::<libc::inotify_event>() <= n as usize {
            let ev = unsafe { &*(buf.as_ptr().add(i) as *const libc::inotify_event) };
            let start = i + std::mem::size_of::<libc::inotify_event>();
            let name = &buf[start..start + ev.len as usize];
            let name = name.split(|b| *b == 0).next().unwrap_or(&[]);
            if ev.wd != fwd && name == b"hyprshell.cmd" {
                recreated = true;
            }
            if ev.wd == fwd {
                touched = true;
            }
            if ev.wd == fwd && ev.mask & (libc::IN_DELETE_SELF | libc::IN_MOVE_SELF) != 0 {
                fwd = -1;
            }
            i = start + ev.len as usize;
        }
        if recreated {
            fwd = add_watch(fd, &file, MASK_FILE);
            offset = 0;
            partial.clear();
        }
        // The folder's other comings and goings are not ours.
        if touched || recreated {
            read_new(&file, &mut offset, &mut partial);
        }
    }
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    std::thread::spawn(move || {
        let mut started = false;
        for c in rx {
            if c["cmd"] != "cmd-watch" || started {
                continue;
            }
            let dir = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| "/tmp".into());
            let pid = c["shellPid"].as_i64().unwrap_or(0);
            let socket = c["socket"].as_str().unwrap_or("").to_string();
            started = true;
            std::thread::spawn(move || watch(dir, pid, socket));
        }
    });
    tx
}
