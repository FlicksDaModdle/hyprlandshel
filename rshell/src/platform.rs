//! Slint, drawing into Wayland layer-shell surfaces.
//!
//! Slint has no layer-shell backend of its own (its winit backend makes
//! ordinary windows), so this is one: Slint's software renderer draws each
//! component into a buffer the size of its surface in *device* pixels, and
//! that buffer is handed to the compositor as the surface's content.
//!
//! Every Slint window made while this platform is set gets a
//! `ShellWindow`; `take_adapter()` hands the most recent one to
//! whoever is about to put it on a layer surface (`wl::Shell::add`).

use i_slint_core::cursor::MouseCursorInner;
use i_slint_core::items::BuiltInMouseCursor;
use i_slint_core::window::WindowAdapterInternal;
use slint::platform::software_renderer::{PremultipliedRgbaColor, RepaintBufferType, SoftwareRenderer, TargetPixel};
use slint::platform::{Platform, Renderer, WindowAdapter};
use slint::{PhysicalSize, Window, WindowSize};
use std::cell::{Cell, RefCell};
use std::rc::Weak;
use wayland_protocols::wp::cursor_shape::v1::client::wp_cursor_shape_device_v1::Shape;
use std::rc::Rc;

thread_local! {
    static MADE: RefCell<Vec<Rc<ShellWindow>>> = const { RefCell::new(Vec::new()) };
}

pub struct ShellPlatform;

impl Platform for ShellPlatform {
    // The text fields' copy, cut and paste (Ctrl+C, X, V), through wl-clipboard.
    fn set_clipboard_text(&self, text: &str, clipboard: slint::platform::Clipboard) {
        use std::io::Write;
        if !matches!(clipboard, slint::platform::Clipboard::DefaultClipboard) {
            return;
        }
        let child = std::process::Command::new("wl-copy")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        if let Ok(mut c) = child {
            if let Some(mut i) = c.stdin.take() {
                let _ = i.write_all(text.as_bytes());
            }
            std::thread::spawn(move || {
                let _ = c.wait();
            });
        }
    }

    fn clipboard_text(&self, clipboard: slint::platform::Clipboard) -> Option<String> {
        if !matches!(clipboard, slint::platform::Clipboard::DefaultClipboard) {
            return None;
        }
        let out = std::process::Command::new("timeout")
            .args(["1", "wl-paste", "--no-newline", "--type", "text"])
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .output()
            .ok()?;
        let t = String::from_utf8_lossy(&out.stdout).to_string();
        (out.status.success() && !t.is_empty()).then_some(t)
    }

    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        let w = ShellWindow::new();
        MADE.with(|m| m.borrow_mut().push(w.clone()));
        Ok(w)
    }
}

/// The adapter of the Slint window made last.
pub fn take_adapter() -> Option<Rc<ShellWindow>> {
    MADE.with(|m| m.borrow_mut().pop())
}

/// One pixel of a wl_shm ARGB8888 buffer: little-endian, so B, G, R, A in
/// memory, premultiplied — exactly what the compositor reads.
#[derive(Clone, Copy, Default)]
#[repr(C)]
pub struct Bgra {
    pub b: u8,
    pub g: u8,
    pub r: u8,
    pub a: u8,
}

impl TargetPixel for Bgra {
    fn blend(&mut self, c: PremultipliedRgbaColor) {
        let inv = 255 - c.alpha as u16;
        let mix = |src: u8, dst: u8| (src as u16 + (dst as u16 * inv + 127) / 255) as u8;
        self.r = mix(c.red, self.r);
        self.g = mix(c.green, self.g);
        self.b = mix(c.blue, self.b);
        self.a = mix(c.alpha, self.a);
    }

    fn from_rgb(r: u8, g: u8, b: u8) -> Self {
        Bgra { b, g, r, a: 255 }
    }

    // Cleared to nothing, not to black: a bar's rounded ends and a panel's
    // shadow need to see the desktop through them.
    fn background() -> Self {
        Bgra::default()
    }
}


/// Slint's ShellWindow, plus the one thing it lacks: it keeps the
/// cursor the item under the pointer asks for (`mouse-cursor:` in the UI),
/// for the pointer handler to pass to the compositor.
pub struct ShellWindow {
    window: Window,
    renderer: SoftwareRenderer,
    needs_redraw: Cell<bool>,
    size: Cell<PhysicalSize>,
    shape: Cell<Shape>,
}

impl ShellWindow {
    pub fn new() -> Rc<Self> {
        Rc::new_cyclic(|w: &Weak<Self>| Self {
            window: Window::new(w.clone()),
            renderer: SoftwareRenderer::new_with_repaint_buffer_type(RepaintBufferType::ReusedBuffer),
            needs_redraw: Cell::new(false),
            size: Cell::new(PhysicalSize::default()),
            shape: Cell::new(Shape::Default),
        })
    }

    pub fn draw_if_needed(&self, render: impl FnOnce(&SoftwareRenderer)) -> bool {
        if self.needs_redraw.replace(false) {
            render(&self.renderer);
            true
        } else {
            false
        }
    }

    /// Resizes; the inherent form, so no trait import is needed to call it.
    pub fn set_size(&self, size: impl Into<WindowSize>) {
        WindowAdapter::set_size(self, size.into());
    }

    /// The cursor the item under the pointer asked for.
    pub fn shape(&self) -> Shape {
        self.shape.get()
    }
}

impl std::ops::Deref for ShellWindow {
    type Target = Window;
    fn deref(&self) -> &Window {
        &self.window
    }
}

impl WindowAdapter for ShellWindow {
    fn window(&self) -> &Window {
        &self.window
    }
    fn renderer(&self) -> &dyn Renderer {
        &self.renderer
    }
    fn size(&self) -> PhysicalSize {
        self.size.get()
    }
    fn set_size(&self, size: WindowSize) {
        let sf = self.window.scale_factor();
        self.size.set(size.to_physical(sf));
        self.window.dispatch_event(slint::platform::WindowEvent::Resized { size: size.to_logical(sf) });
    }
    fn request_redraw(&self) {
        self.needs_redraw.set(true);
    }
    fn internal(&self, _: i_slint_core::InternalToken) -> Option<&dyn WindowAdapterInternal> {
        Some(self)
    }
}

impl WindowAdapterInternal for ShellWindow {
    fn set_mouse_cursor(&self, cursor: MouseCursorInner) {
        use BuiltInMouseCursor as C;
        let shape = match cursor {
            MouseCursorInner::BuiltIn(c) => match c {
                C::Pointer => Shape::Pointer,
                C::Text => Shape::Text,
                C::Help => Shape::Help,
                C::Progress => Shape::Progress,
                C::Wait => Shape::Wait,
                C::Crosshair => Shape::Crosshair,
                C::Move => Shape::Move,
                C::NoDrop => Shape::NoDrop,
                C::NotAllowed => Shape::NotAllowed,
                C::Grab => Shape::Grab,
                C::Grabbing => Shape::Grabbing,
                C::ColResize => Shape::ColResize,
                C::RowResize => Shape::RowResize,
                _ => Shape::Default,
            },
            _ => Shape::Default,
        };
        self.shape.set(shape);
    }
}
