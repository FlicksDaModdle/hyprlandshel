//! Pictures of windows, for the Alt+Tab cards and the overview.
//!
//! A thread of its own with its own Wayland connection, so none of this touches
//! the shell's: it keeps the compositor's list of toplevels (ext-foreign-toplevel-list,
//! each with an identifier that is Hyprland's `stableId`), and for each picture asked
//! for makes a capture source from that toplevel and copies one frame of it into
//! shared memory (ext-image-copy-capture). A window on another workspace or behind
//! others is captured as it is, which is the point. The frame is cut down to a
//! thumbnail here before it is handed back.

use std::collections::HashMap;
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::time::{Duration, Instant};
use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::{wl_buffer, wl_registry, wl_shm, wl_shm_pool};
use wayland_client::{delegate_noop, event_created_child, Connection, Dispatch, Proxy, QueueHandle, WEnum};
use wayland_protocols::ext::foreign_toplevel_list::v1::client::{
    ext_foreign_toplevel_handle_v1::{self, ExtForeignToplevelHandleV1},
    ext_foreign_toplevel_list_v1::{self, ExtForeignToplevelListV1},
};
use wayland_protocols::ext::image_capture_source::v1::client::{
    ext_foreign_toplevel_image_capture_source_manager_v1::ExtForeignToplevelImageCaptureSourceManagerV1, ext_image_capture_source_v1::ExtImageCaptureSourceV1,
};
use wayland_protocols::ext::image_copy_capture::v1::client::{
    ext_image_copy_capture_frame_v1::{self, ExtImageCopyCaptureFrameV1},
    ext_image_copy_capture_manager_v1::{ExtImageCopyCaptureManagerV1, Options},
    ext_image_copy_capture_session_v1::{self, ExtImageCopyCaptureSessionV1},
};

/// A window's picture, ready to show: RGBA, row after row.
pub struct Thumb {
    /// Hyprland's stableId for it.
    pub id: String,
    pub w: u32,
    pub h: u32,
    pub rgba: Vec<u8>,
}

pub struct Thumbs {
    tx: Sender<Vec<String>>,
    pub rx: Receiver<Thumb>,
}

impl Thumbs {
    /// Starts the thread; each picture that arrives is announced with a byte on `wake`.
    pub fn start(wake: UnixStream, width: u32) -> Thumbs {
        let (req_tx, req_rx) = channel::<Vec<String>>();
        let (out_tx, out_rx) = channel::<Thumb>();
        std::thread::spawn(move || {
            if let Err(e) = run(req_rx, out_tx, wake, width) {
                eprintln!("hyprshell-rs: window pictures aren't available ({e})");
            }
        });
        Thumbs { tx: req_tx, rx: out_rx }
    }

    /// Pictures of these windows, by stableId.
    pub fn ask(&self, ids: Vec<String>) {
        let _ = self.tx.send(ids);
    }
}

static NEXT_HANDLE: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(1);

struct Job {
    id: String,
    started: Instant,
    size: (u32, u32),
    formats: Vec<u32>,
    shm: Option<(OwnedFd, usize, u32, wl_buffer::WlBuffer)>,
    session: Option<ExtImageCopyCaptureSessionV1>,
    source: Option<ExtImageCaptureSourceV1>,
    frame: Option<ExtImageCopyCaptureFrameV1>,
}

struct St {
    shm: wl_shm::WlShm,
    list: ExtForeignToplevelListV1,
    sources: ExtForeignToplevelImageCaptureSourceManagerV1,
    copy: ExtImageCopyCaptureManagerV1,
    /// identifier → handle, as they arrive.
    handles: HashMap<u32, (Option<String>, ExtForeignToplevelHandleV1)>,
    jobs: HashMap<u64, Job>,
    next_job: u64,
    out: Sender<Thumb>,
    wake: UnixStream,
    width: u32,
    done: Vec<u64>,
}

delegate_noop!(St: ignore wl_shm::WlShm);
delegate_noop!(St: ignore wl_shm_pool::WlShmPool);
delegate_noop!(St: ignore wl_buffer::WlBuffer);
delegate_noop!(St: ignore ExtForeignToplevelImageCaptureSourceManagerV1);
delegate_noop!(St: ignore ExtImageCaptureSourceV1);
delegate_noop!(St: ignore ExtImageCopyCaptureManagerV1);

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for St {
    fn event(_: &mut Self, _: &wl_registry::WlRegistry, _: wl_registry::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}

impl Dispatch<ExtForeignToplevelListV1, ()> for St {
    fn event(st: &mut Self, _: &ExtForeignToplevelListV1, ev: ext_foreign_toplevel_list_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        // A window: kept under the key it was given, its identifier to follow.
        if let ext_foreign_toplevel_list_v1::Event::Toplevel { toplevel } = ev {
            if let Some(key) = toplevel.data::<u32>().copied() {
                st.handles.insert(key, (None, toplevel));
            }
        }
    }
    event_created_child!(St, ExtForeignToplevelListV1, [
        ext_foreign_toplevel_list_v1::EVT_TOPLEVEL_OPCODE => (ExtForeignToplevelHandleV1, NEXT_HANDLE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)),
    ]);
}

impl Dispatch<ExtForeignToplevelHandleV1, u32> for St {
    fn event(st: &mut Self, _: &ExtForeignToplevelHandleV1, ev: ext_foreign_toplevel_handle_v1::Event, key: &u32, _: &Connection, _: &QueueHandle<Self>) {
        match ev {
            ext_foreign_toplevel_handle_v1::Event::Identifier { identifier } => {
                if let Some(h) = st.handles.get_mut(key) {
                    h.0 = Some(identifier);
                }
            }
            ext_foreign_toplevel_handle_v1::Event::Closed => {
                st.handles.remove(key);
            }
            _ => {}
        }
    }
}

impl Dispatch<ExtImageCopyCaptureSessionV1, u64> for St {
    fn event(st: &mut Self, session: &ExtImageCopyCaptureSessionV1, ev: ext_image_copy_capture_session_v1::Event, key: &u64, _: &Connection, qh: &QueueHandle<Self>) {
        let Some(job) = st.jobs.get_mut(key) else { return };
        match ev {
            ext_image_copy_capture_session_v1::Event::BufferSize { width, height } => job.size = (width, height),
            ext_image_copy_capture_session_v1::Event::ShmFormat { format } => {
                if let WEnum::Value(f) = format {
                    job.formats.push(f as u32);
                }
            }
            ext_image_copy_capture_session_v1::Event::Done => {
                if job.frame.is_some() {
                    return;
                }
                // A format this can read, the first the compositor likes.
                let want = [wl_shm::Format::Argb8888 as u32, wl_shm::Format::Xrgb8888 as u32, wl_shm::Format::Abgr8888 as u32, wl_shm::Format::Xbgr8888 as u32];
                let Some(fmt) = job.formats.iter().copied().find(|f| want.contains(f)) else {
                    st.done.push(*key);
                    return;
                };
                let (w, h) = job.size;
                if w == 0 || h == 0 {
                    st.done.push(*key);
                    return;
                }
                let stride = w * 4;
                let len = (stride * h) as usize;
                let fd = unsafe { libc::memfd_create(c"hyprshell-thumb".as_ptr(), libc::MFD_CLOEXEC) };
                if fd < 0 || unsafe { libc::ftruncate(fd, len as libc::off_t) } != 0 {
                    st.done.push(*key);
                    return;
                }
                let fd = unsafe { OwnedFd::from_raw_fd(fd) };
                let pool = st.shm.create_pool(fd.as_fd(), len as i32, qh, ());
                let format = wl_shm::Format::try_from(fmt).unwrap_or(wl_shm::Format::Argb8888);
                let buffer = pool.create_buffer(0, w as i32, h as i32, stride as i32, format, qh, ());
                pool.destroy();
                let frame = session.create_frame(qh, *key);
                frame.attach_buffer(&buffer);
                frame.damage_buffer(0, 0, w as i32, h as i32);
                frame.capture();
                job.shm = Some((fd, len, fmt, buffer));
                job.frame = Some(frame);
            }
            ext_image_copy_capture_session_v1::Event::Stopped => st.done.push(*key),
            _ => {}
        }
    }
}

impl Dispatch<ExtImageCopyCaptureFrameV1, u64> for St {
    fn event(st: &mut Self, _: &ExtImageCopyCaptureFrameV1, ev: ext_image_copy_capture_frame_v1::Event, key: &u64, _: &Connection, _: &QueueHandle<Self>) {
        match ev {
            ext_image_copy_capture_frame_v1::Event::Ready => {
                if let Some(job) = st.jobs.get(key) {
                    if let Some(t) = read_thumb(job, st.width) {
                        use std::io::Write;
                        let _ = st.out.send(t);
                        let _ = st.wake.write_all(b"!");
                    }
                }
                st.done.push(*key);
            }
            ext_image_copy_capture_frame_v1::Event::Failed { .. } => st.done.push(*key),
            _ => {}
        }
    }
}

/// The frame in the buffer, as RGBA and cut down to `width` across.
fn read_thumb(job: &Job, width: u32) -> Option<Thumb> {
    let (fd, len, fmt, _) = job.shm.as_ref()?;
    let (w, h) = job.size;
    // SAFETY: the memfd is `len` bytes, mapped read-only for the copy below.
    let map = unsafe { libc::mmap(std::ptr::null_mut(), *len, libc::PROT_READ, libc::MAP_SHARED, std::os::fd::AsRawFd::as_raw_fd(fd), 0) };
    if map == libc::MAP_FAILED {
        return None;
    }
    let src = unsafe { std::slice::from_raw_parts(map as *const u8, *len) };
    let (tw, th) = if w > width { (width, ((h as u64 * width as u64) / w as u64).max(1) as u32) } else { (w, h) };
    let mut out = vec![0u8; (tw * th * 4) as usize];
    // Each thumbnail pixel the mean of the block of source pixels it covers.
    for ty in 0..th {
        let (y0, y1) = ((ty as u64 * h as u64 / th as u64) as u32, (((ty as u64 + 1) * h as u64 / th as u64) as u32).max((ty as u64 * h as u64 / th as u64) as u32 + 1).min(h));
        for tx in 0..tw {
            let (x0, x1) = ((tx as u64 * w as u64 / tw as u64) as u32, (((tx as u64 + 1) * w as u64 / tw as u64) as u32).max((tx as u64 * w as u64 / tw as u64) as u32 + 1).min(w));
            let (mut r, mut g, mut b, mut n) = (0u32, 0u32, 0u32, 0u32);
            for y in y0..y1 {
                for x in x0..x1 {
                    let p = ((y * w + x) * 4) as usize;
                    // ARGB/XRGB as little-endian words are B, G, R, A in memory; the ABGR/XBGR ones R, G, B, A.
                    let (pr, pg, pb) = if *fmt == wl_shm::Format::Abgr8888 as u32 || *fmt == wl_shm::Format::Xbgr8888 as u32 { (src[p], src[p + 1], src[p + 2]) } else { (src[p + 2], src[p + 1], src[p]) };
                    r += pr as u32;
                    g += pg as u32;
                    b += pb as u32;
                    n += 1;
                }
            }
            let o = ((ty * tw + tx) * 4) as usize;
            let n = n.max(1);
            out[o] = (r / n) as u8;
            out[o + 1] = (g / n) as u8;
            out[o + 2] = (b / n) as u8;
            out[o + 3] = 255;
        }
    }
    unsafe { libc::munmap(map, *len) };
    Some(Thumb { id: job.id.clone(), w: tw, h: th, rgba: out })
}

fn run(requests: Receiver<Vec<String>>, out: Sender<Thumb>, wake: UnixStream, width: u32) -> Result<(), String> {
    let conn = Connection::connect_to_env().map_err(|e| e.to_string())?;
    let (globals, mut queue) = registry_queue_init::<St>(&conn).map_err(|e| e.to_string())?;
    let qh = queue.handle();
    let missing = |what: &str| format!("the compositor has no {what}");
    let mut st = St {
        shm: globals.bind(&qh, 1..=1, ()).map_err(|_| missing("wl_shm"))?,
        list: globals.bind(&qh, 1..=1, ()).map_err(|_| missing("ext-foreign-toplevel-list"))?,
        sources: globals.bind(&qh, 1..=1, ()).map_err(|_| missing("window capture source"))?,
        copy: globals.bind(&qh, 1..=1, ()).map_err(|_| missing("ext-image-copy-capture"))?,
        handles: HashMap::new(),
        jobs: HashMap::new(),
        next_job: 0,
        out,
        wake,
        width,
        done: Vec::new(),
    };
    let _ = &st.list;
    let mut wanted: Vec<(String, Instant)> = Vec::new();
    loop {
        // What is asked for: kept until its window shows up in the list, a few seconds at most.
        loop {
            match requests.try_recv() {
                Ok(ids) => {
                    let now = Instant::now();
                    for id in ids {
                        wanted.retain(|w| w.0 != id);
                        wanted.push((id, now));
                    }
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => return Ok(()),
            }
        }
        let mut still = Vec::new();
        for (id, since) in wanted.drain(..) {
            let handle = st.handles.values().find(|h| h.0.as_deref() == Some(id.as_str())).map(|h| h.1.clone());
            match handle {
                Some(h) => {
                    let key = st.next_job;
                    st.next_job += 1;
                    let source = st.sources.create_source(&h, &qh, ());
                    let session = st.copy.create_session(&source, Options::empty(), &qh, key);
                    st.jobs.insert(key, Job { id, started: Instant::now(), size: (0, 0), formats: Vec::new(), shm: None, session: Some(session), source: Some(source), frame: None });
                }
                None if since.elapsed() < Duration::from_secs(3) => still.push((id, since)),
                None => {}
            }
        }
        wanted = still;

        // Wayland: what has come, then wait a little for more.
        queue.dispatch_pending(&mut st).map_err(|e| e.to_string())?;
        conn.flush().map_err(|e| e.to_string())?;
        if let Some(guard) = queue.prepare_read() {
            let fd = guard.connection_fd().as_raw_fd_value();
            let mut p = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
            // SAFETY: poll on the connection's own descriptor.
            let ready = unsafe { libc::poll(&mut p, 1, 40) };
            if ready > 0 {
                let _ = guard.read();
            } else {
                drop(guard);
            }
        }
        queue.dispatch_pending(&mut st).map_err(|e| e.to_string())?;

        // Finished (or failed, or stuck) jobs let go of what they hold.
        let stuck: Vec<u64> = st.jobs.iter().filter(|(_, j)| j.started.elapsed() > Duration::from_secs(4)).map(|(k, _)| *k).collect();
        st.done.extend(stuck);
        for key in std::mem::take(&mut st.done) {
            if let Some(j) = st.jobs.remove(&key) {
                if let Some(f) = j.frame {
                    f.destroy();
                }
                if let Some(s) = j.session {
                    s.destroy();
                }
                if let Some(s) = j.source {
                    s.destroy();
                }
                if let Some((_, _, _, b)) = j.shm {
                    b.destroy();
                }
            }
        }
    }
}

trait RawFdValue {
    fn as_raw_fd_value(&self) -> i32;
}

impl RawFdValue for std::os::fd::BorrowedFd<'_> {
    fn as_raw_fd_value(&self) -> i32 {
        std::os::fd::AsRawFd::as_raw_fd(self)
    }
}
