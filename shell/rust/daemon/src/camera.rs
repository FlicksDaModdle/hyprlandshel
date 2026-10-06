//! Who has the camera open.
//!
//! PipeWire knows about apps that reach the camera through it; many (most
//! browsers, Zoom, OBS's V4L2 source) open /dev/video* directly, and only
//! the kernel knows. So the devices are watched with inotify — opening and
//! closing a device node raises IN_OPEN / IN_CLOSE like any file — and on
//! each change /proc is searched for the processes holding one open.
//! PipeWire and WirePlumber themselves are left out: they hold the device
//! for whoever is streaming through them, and the shell names that app
//! from PipeWire.
//!
//! Events:  camera {apps: [{pid, name}]}   (on start, and when it changes)
//! Commands: camera-refresh

use crate::out;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::CString;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::time::Duration;

const IGNORED: &[&str] = &["pipewire", "wireplumber", "hyprshell-daemon", "pipewire-media-session"];

fn is_video(target: &str) -> bool {
    target.strip_prefix("/dev/video").map(|n| n.chars().all(|c| c.is_ascii_digit()) && !n.is_empty()).unwrap_or(false)
}

/// pid → name, for every process of ours with a /dev/videoN open.
pub fn holders() -> BTreeMap<u32, String> {
    let mut out = BTreeMap::new();
    let Ok(procs) = std::fs::read_dir("/proc") else { return out };
    for p in procs.flatten() {
        let Some(pid) = p.file_name().to_str().and_then(|s| s.parse::<u32>().ok()) else { continue };
        let Ok(fds) = std::fs::read_dir(p.path().join("fd")) else { continue };
        let open = fds.flatten().any(|fd| std::fs::read_link(fd.path()).map(|t| is_video(&t.to_string_lossy())).unwrap_or(false));
        if !open {
            continue;
        }
        let comm = std::fs::read_to_string(p.path().join("comm")).unwrap_or_default().trim().to_string();
        if IGNORED.contains(&comm.as_str()) {
            continue;
        }
        out.insert(pid, comm);
    }
    out
}

fn watch_all(fd: i32) {
    let mask = libc::IN_OPEN | libc::IN_CLOSE_WRITE | libc::IN_CLOSE_NOWRITE;
    if let Ok(dev) = std::fs::read_dir("/dev") {
        for e in dev.flatten() {
            let path = e.path();
            if is_video(&path.to_string_lossy()) {
                if let Ok(c) = CString::new(path.to_string_lossy().as_bytes()) {
                    unsafe { libc::inotify_add_watch(fd, c.as_ptr(), mask) };
                }
            }
        }
    }
    // A camera plugged in later.
    if let Ok(c) = CString::new("/dev") {
        unsafe { libc::inotify_add_watch(fd, c.as_ptr(), libc::IN_CREATE) };
    }
}

fn emit(apps: &BTreeMap<u32, String>) {
    let list: Vec<Value> = apps.iter().map(|(pid, name)| json!({ "pid": pid, "name": name })).collect();
    out::emit(json!({ "ev": "camera", "apps": list }));
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    let poke = tx.clone();
    std::thread::spawn(move || {
        let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
        if fd >= 0 {
            watch_all(fd);
            // Reading blocks; each batch of events is one nudge to the
            // thread below, which looks after a short settle.
            let poke = poke.clone();
            std::thread::spawn(move || {
                let mut buf = [0u8; 4096];
                loop {
                    let n = unsafe { libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                    if n <= 0 {
                        return;
                    }
                    // Something new in /dev may be a camera to watch.
                    watch_all(fd);
                    if poke.send(json!({ "cmd": "_changed" })).is_err() {
                        return;
                    }
                }
            });
        }
        run(rx);
    });
    tx
}

fn run(rx: Receiver<Value>) {
    let mut last = holders();
    emit(&last);
    loop {
        // Every half-minute as well, for anything inotify could not see
        // (a device it was not allowed to watch).
        match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(_) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        // Opening a camera is a burst of opens and closes; let it settle.
        std::thread::sleep(Duration::from_millis(250));
        while rx.try_recv().is_ok() {}
        let now = holders();
        if now != last {
            emit(&now);
            last = now;
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn video_paths() {
        assert!(super::is_video("/dev/video0"));
        assert!(super::is_video("/dev/video12"));
        assert!(!super::is_video("/dev/video"));
        assert!(!super::is_video("/dev/videox"));
        assert!(!super::is_video("/dev/vhost-net"));
    }
}
