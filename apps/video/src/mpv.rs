//! libmpv, found at run time. mpv does the playing — every format there is,
//! the GPU's decoder, its scalers and tone mapping — and draws into a
//! texture of ours (or, with no GPU, into a buffer); the app around it is
//! Rust and Slint.

use libloading::Library;
use std::ffi::{c_char, c_double, c_int, c_void, CStr, CString};
use std::sync::Arc;

const FORMAT_STRING: c_int = 1;
const FORMAT_FLAG: c_int = 3;
const FORMAT_INT64: c_int = 4;
const FORMAT_DOUBLE: c_int = 5;
pub const FORMAT_NONE: c_int = 0;

const EVENT_NONE: c_int = 0;
const EVENT_SHUTDOWN: c_int = 1;
const EVENT_START_FILE: c_int = 6;
const EVENT_END_FILE: c_int = 7;
const EVENT_FILE_LOADED: c_int = 8;
const EVENT_VIDEO_RECONFIG: c_int = 17;
const EVENT_PLAYBACK_RESTART: c_int = 21;
const EVENT_PROPERTY_CHANGE: c_int = 22;

const RENDER_PARAM_INVALID: c_int = 0;
const RENDER_PARAM_API_TYPE: c_int = 1;
const RENDER_PARAM_OPENGL_INIT_PARAMS: c_int = 2;
const RENDER_PARAM_OPENGL_FBO: c_int = 3;
const RENDER_PARAM_FLIP_Y: c_int = 4;
const RENDER_PARAM_WL_DISPLAY: c_int = 9;
const RENDER_PARAM_SW_SIZE: c_int = 17;
const RENDER_PARAM_SW_FORMAT: c_int = 18;
const RENDER_PARAM_SW_STRIDE: c_int = 19;
const RENDER_PARAM_SW_POINTER: c_int = 20;
const RENDER_UPDATE_FRAME: u64 = 1;

#[repr(C)]
struct RawEvent {
    event_id: c_int,
    error: c_int,
    reply_userdata: u64,
    data: *mut c_void,
}

#[repr(C)]
struct RawProperty {
    name: *const c_char,
    format: c_int,
    data: *mut c_void,
}

#[repr(C)]
struct RawEndFile {
    reason: c_int,
    error: c_int,
}

#[repr(C)]
struct RenderParam {
    kind: c_int,
    data: *mut c_void,
}

#[repr(C)]
struct GlInit {
    get_proc_address: unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_void,
    get_proc_address_ctx: *mut c_void,
}

#[repr(C)]
struct GlFbo {
    fbo: c_int,
    w: c_int,
    h: c_int,
    internal_format: c_int,
}

type Wakeup = unsafe extern "C" fn(*mut c_void);

struct Api {
    _lib: Library,
    create: unsafe extern "C" fn() -> *mut c_void,
    initialize: unsafe extern "C" fn(*mut c_void) -> c_int,
    terminate_destroy: unsafe extern "C" fn(*mut c_void),
    set_option_string: unsafe extern "C" fn(*mut c_void, *const c_char, *const c_char) -> c_int,
    command: unsafe extern "C" fn(*mut c_void, *mut *const c_char) -> c_int,
    set_property: unsafe extern "C" fn(*mut c_void, *const c_char, c_int, *mut c_void) -> c_int,
    get_property: unsafe extern "C" fn(*mut c_void, *const c_char, c_int, *mut c_void) -> c_int,
    get_property_string: unsafe extern "C" fn(*mut c_void, *const c_char) -> *mut c_char,
    free: unsafe extern "C" fn(*mut c_void),
    observe_property: unsafe extern "C" fn(*mut c_void, u64, *const c_char, c_int) -> c_int,
    wait_event: unsafe extern "C" fn(*mut c_void, c_double) -> *mut RawEvent,
    set_wakeup_callback: unsafe extern "C" fn(*mut c_void, Option<Wakeup>, *mut c_void),
    error_string: unsafe extern "C" fn(c_int) -> *const c_char,
    render_create: unsafe extern "C" fn(*mut *mut c_void, *mut c_void, *mut RenderParam) -> c_int,
    render_set_update_callback: unsafe extern "C" fn(*mut c_void, Option<Wakeup>, *mut c_void),
    render_update: unsafe extern "C" fn(*mut c_void) -> u64,
    render_render: unsafe extern "C" fn(*mut c_void, *mut RenderParam) -> c_int,
    render_report_swap: unsafe extern "C" fn(*mut c_void),
    render_free: unsafe extern "C" fn(*mut c_void),
}

fn api() -> Result<&'static Api, String> {
    static API: std::sync::OnceLock<Result<&'static Api, String>> = std::sync::OnceLock::new();
    API.get_or_init(|| unsafe {
        let lib = ["libmpv.so.2", "libmpv.so"]
            .iter()
            .find_map(|n| Library::new(n).ok())
            .ok_or_else(|| "Videos needs mpv. Install it (pacman -S mpv) and open Videos again.".to_string())?;
        macro_rules! f {
            ($n:literal) => {
                *lib.get(concat!($n, "\0").as_bytes()).map_err(|_| format!("This mpv is too old ({} is missing)", $n))?
            };
        }
        let a = Api {
            create: f!("mpv_create"),
            initialize: f!("mpv_initialize"),
            terminate_destroy: f!("mpv_terminate_destroy"),
            set_option_string: f!("mpv_set_option_string"),
            command: f!("mpv_command"),
            set_property: f!("mpv_set_property"),
            get_property: f!("mpv_get_property"),
            get_property_string: f!("mpv_get_property_string"),
            free: f!("mpv_free"),
            observe_property: f!("mpv_observe_property"),
            wait_event: f!("mpv_wait_event"),
            set_wakeup_callback: f!("mpv_set_wakeup_callback"),
            error_string: f!("mpv_error_string"),
            render_create: f!("mpv_render_context_create"),
            render_set_update_callback: f!("mpv_render_context_set_update_callback"),
            render_update: f!("mpv_render_context_update"),
            render_render: f!("mpv_render_context_render"),
            render_report_swap: f!("mpv_render_context_report_swap"),
            render_free: f!("mpv_render_context_free"),
            _lib: lib,
        };
        Ok(&*Box::leak(Box::new(a)))
    })
    .clone()
}

/// A property's new value, as mpv gave it.
#[derive(Debug, Clone)]
pub enum Value {
    None,
    Flag(bool),
    Int(i64),
    Double(f64),
    Str(String),
}

#[derive(Debug)]
pub enum Event {
    Property(String, Value),
    StartFile,
    FileLoaded,
    /// reason: 0 eof, 2 stop, 3 quit, 4 error, 5 redirect; error code.
    EndFile(i32, i32),
    VideoReconfig,
    PlaybackRestart,
    Shutdown,
    Other,
}

pub struct Mpv {
    api: &'static Api,
    h: *mut c_void,
    wakeup: std::sync::Mutex<Option<Box<Box<dyn Fn() + Send + Sync>>>>,
}

// libmpv's client API may be used from any thread.
unsafe impl Send for Mpv {}
unsafe impl Sync for Mpv {}

fn cs(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap()
}

impl Mpv {
    /// A player, set up with `options` (name, value) before it starts.
    pub fn new(options: &[(&str, &str)]) -> Result<Arc<Mpv>, String> {
        let api = api()?;
        let h = unsafe { (api.create)() };
        if h.is_null() {
            return Err("mpv couldn't start".into());
        }
        let m = Mpv { api, h, wakeup: std::sync::Mutex::new(None) };
        for (k, v) in options {
            let (k, v) = (cs(k), cs(v));
            unsafe { (api.set_option_string)(h, k.as_ptr(), v.as_ptr()) };
        }
        let r = unsafe { (api.initialize)(h) };
        if r < 0 {
            return Err(format!("mpv couldn't start ({})", m.error(r)));
        }
        Ok(Arc::new(m))
    }

    fn error(&self, code: c_int) -> String {
        unsafe { CStr::from_ptr((self.api.error_string)(code)).to_string_lossy().into_owned() }
    }

    pub fn command(&self, args: &[&str]) -> Result<(), String> {
        let owned: Vec<CString> = args.iter().map(|a| cs(a)).collect();
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        let r = unsafe { (self.api.command)(self.h, ptrs.as_mut_ptr()) };
        if r < 0 { Err(self.error(r)) } else { Ok(()) }
    }

    pub fn set_str(&self, name: &str, v: &str) {
        let (n, v) = (cs(name), cs(v));
        let mut p = v.as_ptr();
        unsafe { (self.api.set_property)(self.h, n.as_ptr(), FORMAT_STRING, &mut p as *mut _ as *mut c_void) };
    }
    pub fn set_flag(&self, name: &str, v: bool) {
        let n = cs(name);
        let mut f: c_int = v as c_int;
        unsafe { (self.api.set_property)(self.h, n.as_ptr(), FORMAT_FLAG, &mut f as *mut _ as *mut c_void) };
    }
    pub fn set_double(&self, name: &str, v: f64) {
        let n = cs(name);
        let mut d: f64 = v;
        unsafe { (self.api.set_property)(self.h, n.as_ptr(), FORMAT_DOUBLE, &mut d as *mut _ as *mut c_void) };
    }
    pub fn get_double(&self, name: &str) -> Option<f64> {
        let n = cs(name);
        let mut d: f64 = 0.0;
        let r = unsafe { (self.api.get_property)(self.h, n.as_ptr(), FORMAT_DOUBLE, &mut d as *mut _ as *mut c_void) };
        (r >= 0).then_some(d)
    }
    pub fn get_int(&self, name: &str) -> Option<i64> {
        let n = cs(name);
        let mut d: i64 = 0;
        let r = unsafe { (self.api.get_property)(self.h, n.as_ptr(), FORMAT_INT64, &mut d as *mut _ as *mut c_void) };
        (r >= 0).then_some(d)
    }
    pub fn get_flag(&self, name: &str) -> Option<bool> {
        let n = cs(name);
        let mut d: c_int = 0;
        let r = unsafe { (self.api.get_property)(self.h, n.as_ptr(), FORMAT_FLAG, &mut d as *mut _ as *mut c_void) };
        (r >= 0).then_some(d != 0)
    }
    pub fn get_str(&self, name: &str) -> Option<String> {
        let n = cs(name);
        unsafe {
            let p = (self.api.get_property_string)(self.h, n.as_ptr());
            if p.is_null() {
                return None;
            }
            let s = CStr::from_ptr(p).to_string_lossy().into_owned();
            (self.api.free)(p as *mut c_void);
            Some(s)
        }
    }

    /// Changes to `name` arrive as events. Kinds: "flag", "double", "int", "string", "none".
    pub fn observe(&self, name: &str, kind: &str) {
        let n = cs(name);
        let f = match kind {
            "flag" => FORMAT_FLAG,
            "double" => FORMAT_DOUBLE,
            "int" => FORMAT_INT64,
            "string" => FORMAT_STRING,
            _ => FORMAT_NONE,
        };
        unsafe { (self.api.observe_property)(self.h, 0, n.as_ptr(), f) };
    }

    /// Called (on mpv's thread) whenever there are events to take.
    pub fn on_wakeup(&self, f: impl Fn() + Send + Sync + 'static) {
        unsafe extern "C" fn tramp(d: *mut c_void) {
            let f = &*(d as *const Box<dyn Fn() + Send + Sync>);
            f();
        }
        let b: Box<Box<dyn Fn() + Send + Sync>> = Box::new(Box::new(f));
        let ptr = &*b as *const Box<dyn Fn() + Send + Sync> as *mut c_void;
        *self.wakeup.lock().unwrap() = Some(b);
        unsafe { (self.api.set_wakeup_callback)(self.h, Some(tramp), ptr) };
    }

    /// The next event, if one is waiting.
    pub fn next_event(&self) -> Option<Event> {
        unsafe {
            let e = &*(self.api.wait_event)(self.h, 0.0);
            Some(match e.event_id {
                EVENT_NONE => return None,
                EVENT_SHUTDOWN => Event::Shutdown,
                EVENT_START_FILE => Event::StartFile,
                EVENT_FILE_LOADED => Event::FileLoaded,
                EVENT_VIDEO_RECONFIG => Event::VideoReconfig,
                EVENT_PLAYBACK_RESTART => Event::PlaybackRestart,
                EVENT_END_FILE => {
                    let d = &*(e.data as *const RawEndFile);
                    Event::EndFile(d.reason, d.error)
                }
                EVENT_PROPERTY_CHANGE => {
                    let p = &*(e.data as *const RawProperty);
                    let name = CStr::from_ptr(p.name).to_string_lossy().into_owned();
                    let v = if p.data.is_null() {
                        Value::None
                    } else {
                        match p.format {
                            FORMAT_FLAG => Value::Flag(*(p.data as *const c_int) != 0),
                            FORMAT_INT64 => Value::Int(*(p.data as *const i64)),
                            FORMAT_DOUBLE => Value::Double(*(p.data as *const f64)),
                            FORMAT_STRING => {
                                let s = *(p.data as *const *const c_char);
                                Value::Str(if s.is_null() { String::new() } else { CStr::from_ptr(s).to_string_lossy().into_owned() })
                            }
                            _ => Value::None,
                        }
                    };
                    Event::Property(name, v)
                }
                _ => Event::Other,
            })
        }
    }
}

impl Drop for Mpv {
    fn drop(&mut self) {
        unsafe {
            (self.api.set_wakeup_callback)(self.h, None, std::ptr::null_mut());
            (self.api.terminate_destroy)(self.h);
        }
    }
}

/// Where mpv draws. Holds the player, so the player outlives it (mpv asks
/// for that order).
pub struct Render {
    api: &'static Api,
    ctx: *mut c_void,
    _mpv: Arc<Mpv>,
    update: Option<Box<Box<dyn Fn() + Send + Sync>>>,
}

impl Render {
    /// Drawing with OpenGL, in the GL context current now. `get_proc` is
    /// only used while this runs.
    pub fn gl(mpv: &Arc<Mpv>, get_proc: &dyn Fn(&CStr) -> *const c_void, wl_display: *mut c_void) -> Result<Render, String> {
        unsafe extern "C" fn tramp(ctx: *mut c_void, name: *const c_char) -> *mut c_void {
            let f = &*(ctx as *const &dyn Fn(&CStr) -> *const c_void);
            f(CStr::from_ptr(name)) as *mut c_void
        }
        let api = mpv.api;
        let gp: &dyn Fn(&CStr) -> *const c_void = get_proc;
        let mut init = GlInit { get_proc_address: tramp, get_proc_address_ctx: &gp as *const _ as *mut c_void };
        let kind = c"opengl";
        let mut params = vec![
            RenderParam { kind: RENDER_PARAM_API_TYPE, data: kind.as_ptr() as *mut c_void },
            RenderParam { kind: RENDER_PARAM_OPENGL_INIT_PARAMS, data: &mut init as *mut _ as *mut c_void },
        ];
        if !wl_display.is_null() {
            // For the GPU decoder's frames to go straight to GL.
            params.push(RenderParam { kind: RENDER_PARAM_WL_DISPLAY, data: wl_display });
        }
        params.push(RenderParam { kind: RENDER_PARAM_INVALID, data: std::ptr::null_mut() });
        let mut ctx = std::ptr::null_mut();
        let r = unsafe { (api.render_create)(&mut ctx, mpv.h, params.as_mut_ptr()) };
        if r < 0 {
            return Err(mpv.error(r));
        }
        Ok(Render { api, ctx, _mpv: mpv.clone(), update: None })
    }

    /// Drawing on the CPU, into memory of ours.
    pub fn sw(mpv: &Arc<Mpv>) -> Result<Render, String> {
        let api = mpv.api;
        let kind = c"sw";
        let mut params = [
            RenderParam { kind: RENDER_PARAM_API_TYPE, data: kind.as_ptr() as *mut c_void },
            RenderParam { kind: RENDER_PARAM_INVALID, data: std::ptr::null_mut() },
        ];
        let mut ctx = std::ptr::null_mut();
        let r = unsafe { (api.render_create)(&mut ctx, mpv.h, params.as_mut_ptr()) };
        if r < 0 {
            return Err(mpv.error(r));
        }
        Ok(Render { api, ctx, _mpv: mpv.clone(), update: None })
    }

    /// Called (from any thread) when there may be a new frame to draw.
    pub fn on_update(&mut self, f: impl Fn() + Send + Sync + 'static) {
        unsafe extern "C" fn tramp(d: *mut c_void) {
            let f = &*(d as *const Box<dyn Fn() + Send + Sync>);
            f();
        }
        let b: Box<Box<dyn Fn() + Send + Sync>> = Box::new(Box::new(f));
        let ptr = &*b as *const Box<dyn Fn() + Send + Sync> as *mut c_void;
        unsafe { (self.api.render_set_update_callback)(self.ctx, Some(tramp), ptr) };
        self.update = Some(b);
    }

    /// Whether a new frame wants drawing.
    pub fn wants_frame(&self) -> bool {
        unsafe { (self.api.render_update)(self.ctx) & RENDER_UPDATE_FRAME != 0 }
    }

    pub fn draw_gl(&self, fbo: u32, w: i32, h: i32, flip: bool) {
        let mut f = GlFbo { fbo: fbo as c_int, w, h, internal_format: 0 };
        let mut flip: c_int = flip as c_int;
        let mut params = [
            RenderParam { kind: RENDER_PARAM_OPENGL_FBO, data: &mut f as *mut _ as *mut c_void },
            RenderParam { kind: RENDER_PARAM_FLIP_Y, data: &mut flip as *mut _ as *mut c_void },
            RenderParam { kind: RENDER_PARAM_INVALID, data: std::ptr::null_mut() },
        ];
        unsafe { (self.api.render_render)(self.ctx, params.as_mut_ptr()) };
    }

    /// Draw as RGB0 into `buf` (w × h, `stride` bytes a row).
    pub fn draw_sw(&self, w: i32, h: i32, stride: usize, buf: &mut [u8]) {
        let mut size: [c_int; 2] = [w, h];
        let fmt = c"rgb0";
        let mut stride = stride;
        let mut params = [
            RenderParam { kind: RENDER_PARAM_SW_SIZE, data: size.as_mut_ptr() as *mut c_void },
            RenderParam { kind: RENDER_PARAM_SW_FORMAT, data: fmt.as_ptr() as *mut c_void },
            RenderParam { kind: RENDER_PARAM_SW_STRIDE, data: &mut stride as *mut _ as *mut c_void },
            RenderParam { kind: RENDER_PARAM_SW_POINTER, data: buf.as_mut_ptr() as *mut c_void },
            RenderParam { kind: RENDER_PARAM_INVALID, data: std::ptr::null_mut() },
        ];
        unsafe { (self.api.render_render)(self.ctx, params.as_mut_ptr()) };
    }

    pub fn report_swap(&self) {
        unsafe { (self.api.render_report_swap)(self.ctx) };
    }
}

impl Drop for Render {
    fn drop(&mut self) {
        unsafe {
            (self.api.render_set_update_callback)(self.ctx, None, std::ptr::null_mut());
            (self.api.render_free)(self.ctx);
        }
    }
}
