//! Frames from a camera: V4L2 directly (memory-mapped streaming), no
//! library in between. Greyscale (the infrared camera), YUYV and MJPEG
//! (webcams), each turned into RGB.
//!
//! For tests, a device named `dir:/some/folder` plays that folder's JPEGs
//! in turn, 15 a second, as if they came from a camera.

use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use crate::image::Rgb;

const fn fourcc(s: &[u8; 4]) -> u32 {
    (s[0] as u32) | (s[1] as u32) << 8 | (s[2] as u32) << 16 | (s[3] as u32) << 24
}
const GREY: u32 = fourcc(b"GREY");
const YUYV: u32 = fourcc(b"YUYV");
const MJPG: u32 = fourcc(b"MJPG");

const BUF_TYPE_VIDEO_CAPTURE: u32 = 1;
const MEMORY_MMAP: u32 = 1;
const FIELD_NONE: u32 = 1;

// The ioctls, as the kernel headers define them for 64-bit x86 and ARM
// (_IOR/_IOWR with the structures' sizes below).
const VIDIOC_G_FMT: libc::c_ulong = 0xc0d0_5604;
const VIDIOC_S_FMT: libc::c_ulong = 0xc0d0_5605;
const VIDIOC_REQBUFS: libc::c_ulong = 0xc014_5608;
const VIDIOC_QUERYBUF: libc::c_ulong = 0xc058_5609;
const VIDIOC_QBUF: libc::c_ulong = 0xc058_560f;
const VIDIOC_DQBUF: libc::c_ulong = 0xc058_5611;
const VIDIOC_STREAMON: libc::c_ulong = 0x4004_5612;
const VIDIOC_STREAMOFF: libc::c_ulong = 0x4004_5613;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct PixFormat {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    priv_: u32,
    flags: u32,
    ycbcr_enc: u32,
    quantization: u32,
    xfer_func: u32,
}

/// struct v4l2_format: the type, then a 200-byte union (8-aligned).
#[repr(C)]
struct Format {
    type_: u32,
    fmt: [u64; 25],
}

#[repr(C)]
#[derive(Default)]
struct RequestBuffers {
    count: u32,
    type_: u32,
    memory: u32,
    capabilities: u32,
    flags: u8,
    reserved: [u8; 3],
}

#[repr(C)]
#[derive(Default)]
struct TimeCode {
    type_: u32,
    flags: u32,
    frames: u8,
    seconds: u8,
    minutes: u8,
    hours: u8,
    userbits: [u8; 4],
}

/// struct v4l2_buffer, 88 bytes on 64-bit.
#[repr(C)]
#[derive(Default)]
struct Buffer {
    index: u32,
    type_: u32,
    bytesused: u32,
    flags: u32,
    field: u32,
    timestamp: libc::timeval,
    timecode: TimeCode,
    sequence: u32,
    memory: u32,
    /// The union m: the offset to mmap, for MMAP buffers.
    m: u64,
    length: u32,
    reserved2: u32,
    request_fd: i32,
}

const _: () = assert!(std::mem::size_of::<Format>() == 208);
const _: () = assert!(std::mem::size_of::<RequestBuffers>() == 20);
const _: () = assert!(std::mem::size_of::<Buffer>() == 88);
const _: () = assert!(std::mem::size_of::<PixFormat>() == 48);

fn ioctl<T>(fd: i32, request: libc::c_ulong, arg: &mut T) -> io::Result<()> {
    loop {
        // SAFETY: arg is the structure this request is defined with.
        let r = unsafe { libc::ioctl(fd, request as _, arg as *mut T) };
        if r == 0 {
            return Ok(());
        }
        let e = io::Error::last_os_error();
        if e.kind() != io::ErrorKind::Interrupted {
            return Err(e);
        }
    }
}

pub struct Mapped {
    ptr: *mut libc::c_void,
    len: usize,
}

pub enum Camera {
    Device {
        file: File,
        maps: Vec<Mapped>,
        width: usize,
        height: usize,
        format: u32,
    },
    Folder {
        pictures: Vec<PathBuf>,
        next: usize,
        last: Option<Instant>,
    },
}

/// What to ask a camera for: a size and format to try, or its own.
pub struct Want {
    pub mjpeg: Option<(u32, u32)>,
}

impl Camera {
    pub fn open(device: &str, want: &Want) -> io::Result<Camera> {
        if let Some(dir) = device.strip_prefix("dir:") {
            let mut pictures: Vec<PathBuf> = std::fs::read_dir(dir)?
                .filter_map(|e| e.ok().map(|e| e.path()))
                .filter(|p| p.extension().is_some_and(|x| x.eq_ignore_ascii_case("jpg")))
                .collect();
            pictures.sort();
            if pictures.is_empty() {
                return Err(io::Error::new(io::ErrorKind::NotFound, "no pictures in the folder"));
            }
            return Ok(Camera::Folder { pictures, next: 0, last: None });
        }

        let file = std::fs::OpenOptions::new().read(true).write(true).custom_flags_nonblock().open(device)?;
        let fd = file.as_raw_fd();

        // Small and compressed if asked for and offered (a webcam beside
        // the infrared camera on one USB bus); otherwise as it is.
        let mut fmt = Format { type_: BUF_TYPE_VIDEO_CAPTURE, fmt: [0; 25] };
        ioctl(fd, VIDIOC_G_FMT, &mut fmt)?;
        if let Some((w, h)) = want.mjpeg {
            let mut try_fmt = Format { type_: BUF_TYPE_VIDEO_CAPTURE, fmt: [0; 25] };
            let pix = PixFormat { width: w, height: h, pixelformat: MJPG, field: FIELD_NONE, ..Default::default() };
            // SAFETY: PixFormat fits in the union and has no padding.
            unsafe { std::ptr::write(try_fmt.fmt.as_mut_ptr() as *mut PixFormat, pix) };
            if ioctl(fd, VIDIOC_S_FMT, &mut try_fmt).is_ok() {
                fmt = try_fmt;
            }
        }
        // SAFETY: the kernel filled the union's pix member for a capture type.
        let pix: PixFormat = unsafe { std::ptr::read(fmt.fmt.as_ptr() as *const PixFormat) };
        if ![GREY, YUYV, MJPG].contains(&pix.pixelformat) {
            return Err(io::Error::new(io::ErrorKind::Unsupported, format!("camera format {:08x} isn't one of GREY, YUYV, MJPG", pix.pixelformat)));
        }

        let mut req = RequestBuffers { count: 4, type_: BUF_TYPE_VIDEO_CAPTURE, memory: MEMORY_MMAP, ..Default::default() };
        ioctl(fd, VIDIOC_REQBUFS, &mut req)?;
        let mut maps = Vec::new();
        for index in 0..req.count {
            let mut buf = Buffer { index, type_: BUF_TYPE_VIDEO_CAPTURE, memory: MEMORY_MMAP, ..Default::default() };
            ioctl(fd, VIDIOC_QUERYBUF, &mut buf)?;
            // SAFETY: mapping the buffer the driver just described.
            let ptr = unsafe {
                libc::mmap(std::ptr::null_mut(), buf.length as usize, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd, buf.m as libc::off_t)
            };
            if ptr == libc::MAP_FAILED {
                return Err(io::Error::last_os_error());
            }
            maps.push(Mapped { ptr, len: buf.length as usize });
            ioctl(fd, VIDIOC_QBUF, &mut buf)?;
        }
        let mut kind: i32 = BUF_TYPE_VIDEO_CAPTURE as i32;
        ioctl(fd, VIDIOC_STREAMON, &mut kind)?;
        Ok(Camera::Device { file, maps, width: pix.width as usize, height: pix.height as usize, format: pix.pixelformat })
    }

    /// The next frame, or None if none came in time.
    pub fn frame(&mut self, wait: Duration) -> io::Result<Option<Rgb>> {
        match self {
            Camera::Folder { pictures, next, last } => {
                // 15 a second, as a camera would.
                if let Some(t) = last {
                    let gap = Duration::from_millis(66);
                    if t.elapsed() < gap {
                        std::thread::sleep(gap - t.elapsed());
                    }
                }
                *last = Some(Instant::now());
                let path = &pictures[*next % pictures.len()];
                *next += 1;
                Ok(Rgb::from_jpeg(&std::fs::read(path)?))
            }
            Camera::Device { file, maps, width, height, format } => {
                let fd = file.as_raw_fd();
                let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
                // SAFETY: one pollfd, for our own descriptor.
                let ready = unsafe { libc::poll(&mut pfd, 1, wait.as_millis() as i32) };
                if ready < 0 {
                    return Err(io::Error::last_os_error());
                }
                if ready == 0 {
                    return Ok(None);
                }
                let mut buf = Buffer { type_: BUF_TYPE_VIDEO_CAPTURE, memory: MEMORY_MMAP, ..Default::default() };
                ioctl(fd, VIDIOC_DQBUF, &mut buf)?;
                let map = &maps[buf.index as usize];
                let used = (buf.bytesused as usize).min(map.len);
                // SAFETY: the driver handed this buffer back with `used` bytes in it.
                let data = unsafe { std::slice::from_raw_parts(map.ptr as *const u8, used) };
                let (w, h) = (*width, *height);
                let picture = match *format {
                    GREY if used >= w * h => Some(Rgb::from_gray(w, h, data)),
                    YUYV if used >= w * h * 2 => Some(Rgb::from_yuyv(w, h, data)),
                    MJPG => Rgb::from_jpeg(data),
                    _ => None,
                };
                ioctl(fd, VIDIOC_QBUF, &mut buf)?;
                Ok(picture)
            }
        }
    }
}

impl Drop for Camera {
    fn drop(&mut self) {
        if let Camera::Device { file, maps, .. } = self {
            let mut kind: i32 = BUF_TYPE_VIDEO_CAPTURE as i32;
            let _ = ioctl(file.as_raw_fd(), VIDIOC_STREAMOFF, &mut kind);
            for m in maps.drain(..) {
                // SAFETY: unmapping what open() mapped, once.
                unsafe { libc::munmap(m.ptr, m.len) };
            }
        }
    }
}

// The camera lives on one thread at a time; its maps are only touched there.
unsafe impl Send for Camera {}

trait NonBlock {
    fn custom_flags_nonblock(&mut self) -> &mut Self;
}
impl NonBlock for std::fs::OpenOptions {
    fn custom_flags_nonblock(&mut self) -> &mut Self {
        use std::os::unix::fs::OpenOptionsExt;
        self.custom_flags(libc::O_NONBLOCK | libc::O_CLOEXEC)
    }
}
