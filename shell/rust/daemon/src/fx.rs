//! The equalizer and noise suppression (services/AudioFx.qml) as PipeWire
//! filter-chains loaded into this process, where each was a `pipewire -c`
//! process of its own.
//!
//! libpipewire is opened at run time (dlopen), not linked: the handful of
//! calls needed here are declared below, so building this needs neither
//! PipeWire's headers nor clang, and a machine without PipeWire still runs
//! the rest of the daemon.
//!
//! Commands:  fx-load {key, args}   args: the filter-chain module's
//!                                  arguments, SPA-JSON, as in a .conf
//!            fx-unload {key}
//! Events:    fx {key, loaded, error?}
//!
//! The context — one connection to PipeWire, a thread for the sound — is
//! made for the first chain and closed after the last.

use crate::out;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::sync::mpsc::{channel, Sender};
use std::sync::{Mutex, OnceLock};

type Ptr = *mut c_void;

#[repr(C)]
struct SpaHook {
    link: [Ptr; 2],
    funcs: *const c_void,
    data: Ptr,
    removed: Ptr,
    private: Ptr,
}

#[repr(C)]
struct ModuleEvents {
    version: u32,
    destroy: Option<unsafe extern "C" fn(Ptr)>,
    free: Option<unsafe extern "C" fn(Ptr)>,
    initialized: Option<unsafe extern "C" fn(Ptr)>,
    registered: Option<unsafe extern "C" fn(Ptr)>,
}

struct Lib {
    init: unsafe extern "C" fn(*mut c_int, *mut *mut *mut c_char),
    loop_new: unsafe extern "C" fn(*const c_char, *const c_void) -> Ptr,
    loop_get_loop: unsafe extern "C" fn(Ptr) -> Ptr,
    loop_start: unsafe extern "C" fn(Ptr) -> c_int,
    loop_stop: unsafe extern "C" fn(Ptr),
    loop_destroy: unsafe extern "C" fn(Ptr),
    lock: unsafe extern "C" fn(Ptr),
    unlock: unsafe extern "C" fn(Ptr),
    context_new: unsafe extern "C" fn(Ptr, Ptr, usize) -> Ptr,
    context_destroy: unsafe extern "C" fn(Ptr),
    load_module: unsafe extern "C" fn(Ptr, *const c_char, *const c_char, Ptr) -> Ptr,
    module_destroy: unsafe extern "C" fn(Ptr),
    module_add_listener: unsafe extern "C" fn(Ptr, *mut SpaHook, *const ModuleEvents, Ptr),
}
unsafe impl Send for Lib {}
unsafe impl Sync for Lib {}

fn lib() -> Option<&'static Lib> {
    static LIB: OnceLock<Option<Lib>> = OnceLock::new();
    LIB.get_or_init(|| unsafe {
        let h = libc::dlopen(c"libpipewire-0.3.so.0".as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL);
        if h.is_null() {
            return None;
        }
        macro_rules! sym {
            ($name:literal) => {{
                let p = libc::dlsym(h, concat!($name, "\0").as_ptr() as *const c_char);
                if p.is_null() {
                    return None;
                }
                std::mem::transmute::<*mut c_void, _>(p)
            }};
        }
        Some(Lib {
            init: sym!("pw_init"),
            loop_new: sym!("pw_thread_loop_new"),
            loop_get_loop: sym!("pw_thread_loop_get_loop"),
            loop_start: sym!("pw_thread_loop_start"),
            loop_stop: sym!("pw_thread_loop_stop"),
            loop_destroy: sym!("pw_thread_loop_destroy"),
            lock: sym!("pw_thread_loop_lock"),
            unlock: sym!("pw_thread_loop_unlock"),
            context_new: sym!("pw_context_new"),
            context_destroy: sym!("pw_context_destroy"),
            load_module: sym!("pw_context_load_module"),
            module_destroy: sym!("pw_impl_module_destroy"),
            module_add_listener: sym!("pw_impl_module_add_listener"),
        })
    })
    .as_ref()
}

/// Whether filter-chains can run here: libpipewire is there and has what
/// is called below.
pub fn available() -> bool {
    lib().is_some()
}

// The chains running, by key. A module PipeWire takes down itself (the
// server restarting, say) leaves through on_destroy, which finds its key
// still here; one unloaded on request has been taken out first.
static MODULES: Mutex<Option<HashMap<String, usize>>> = Mutex::new(None);

static EVENTS: ModuleEvents = ModuleEvents { version: 0, destroy: Some(on_destroy), free: None, initialized: None, registered: None };

unsafe extern "C" fn on_destroy(data: Ptr) {
    let key = CStr::from_ptr(data as *const c_char).to_string_lossy().into_owned();
    let gone = MODULES.lock().unwrap().as_mut().and_then(|m| m.remove(&key)).is_some();
    if gone {
        out::emit(json!({ "ev": "fx", "key": key, "loaded": false, "error": "PipeWire stopped it" }));
    }
}

struct Pw {
    tl: Ptr,
    ctx: Ptr,
}

impl Pw {
    unsafe fn open(l: &Lib) -> Option<Pw> {
        static INIT: std::sync::Once = std::sync::Once::new();
        INIT.call_once(|| (l.init)(std::ptr::null_mut(), std::ptr::null_mut()));
        let tl = (l.loop_new)(c"hyprshell-fx".as_ptr(), std::ptr::null());
        if tl.is_null() {
            return None;
        }
        // The client configuration: the native protocol, client-node and
        // adapter that a filter-chain needs, and realtime for its thread.
        let ctx = (l.context_new)((l.loop_get_loop)(tl), std::ptr::null_mut(), 0);
        if ctx.is_null() {
            (l.loop_destroy)(tl);
            return None;
        }
        if (l.loop_start)(tl) < 0 {
            (l.context_destroy)(ctx);
            (l.loop_destroy)(tl);
            return None;
        }
        Some(Pw { tl, ctx })
    }
    unsafe fn close(self, l: &Lib) {
        (l.loop_stop)(self.tl);
        (l.context_destroy)(self.ctx);
        (l.loop_destroy)(self.tl);
    }
}

fn running() -> usize {
    MODULES.lock().unwrap().as_ref().map(|m| m.len()).unwrap_or(0)
}

pub fn start() -> Sender<Value> {
    let (tx, rx) = channel::<Value>();
    std::thread::spawn(move || {
        let Some(l) = lib() else {
            for c in rx {
                if let Some(key) = c["key"].as_str() {
                    out::emit(json!({ "ev": "fx", "key": key, "loaded": false, "error": "libpipewire is not installed" }));
                }
            }
            return;
        };
        *MODULES.lock().unwrap() = Some(HashMap::new());
        let mut pw: Option<Pw> = None;
        for c in rx {
            let key = c["key"].as_str().unwrap_or("").to_string();
            if key.is_empty() {
                continue;
            }
            unsafe {
                // Either way the old one goes first: two chains must not
                // make two devices of the same name.
                let old = MODULES.lock().unwrap().as_mut().and_then(|m| m.remove(&key));
                if let (Some(m), Some(p)) = (old, &pw) {
                    (l.lock)(p.tl);
                    (l.module_destroy)(m as Ptr);
                    (l.unlock)(p.tl);
                }
                match c["cmd"].as_str() {
                    Some("fx-load") => {
                        let args = CString::new(c["args"].as_str().unwrap_or("")).unwrap_or_default();
                        if pw.is_none() {
                            pw = Pw::open(l);
                        }
                        let Some(p) = &pw else {
                            out::emit(json!({ "ev": "fx", "key": key, "loaded": false, "error": "could not start a PipeWire context" }));
                            continue;
                        };
                        (l.lock)(p.tl);
                        let m = (l.load_module)(p.ctx, c"libpipewire-module-filter-chain".as_ptr(), args.as_ptr(), std::ptr::null_mut());
                        let err = std::io::Error::last_os_error();
                        if !m.is_null() {
                            // Leaked on purpose: PipeWire holds both until
                            // the module goes, which may be after we last
                            // look at it.
                            let hook = Box::into_raw(Box::new(std::mem::zeroed::<SpaHook>()));
                            let tag = CString::new(key.clone()).unwrap_or_default().into_raw();
                            (l.module_add_listener)(m, hook, &EVENTS, tag as Ptr);
                            MODULES.lock().unwrap().as_mut().unwrap().insert(key.clone(), m as usize);
                        }
                        (l.unlock)(p.tl);
                        if m.is_null() {
                            out::emit(json!({ "ev": "fx", "key": key, "loaded": false, "error": format!("filter-chain: {err}") }));
                        } else {
                            out::emit(json!({ "ev": "fx", "key": key, "loaded": true }));
                        }
                    }
                    _ => out::emit(json!({ "ev": "fx", "key": key, "loaded": false })),
                }
                if running() == 0 {
                    if let Some(p) = pw.take() {
                        p.close(l);
                    }
                }
            }
        }
    });
    tx
}
