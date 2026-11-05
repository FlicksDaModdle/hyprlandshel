//! Slint, drawing into Wayland layer-shell surfaces.
//!
//! Slint has no layer-shell backend of its own (its winit backend makes
//! ordinary windows), so this is one: Slint's software renderer draws each
//! component into a buffer the size of its surface in *device* pixels, and
//! that buffer is handed to the compositor as the surface's content.
//!
//! Every Slint window made while this platform is set gets a
//! `MinimalSoftwareWindow`; `take_adapter()` hands the most recent one to
//! whoever is about to put it on a layer surface (`wl::Shell::add`).

use slint::platform::software_renderer::{MinimalSoftwareWindow, PremultipliedRgbaColor, RepaintBufferType, TargetPixel};
use slint::platform::{Platform, WindowAdapter};
use std::cell::RefCell;
use std::rc::Rc;

thread_local! {
    static MADE: RefCell<Vec<Rc<MinimalSoftwareWindow>>> = const { RefCell::new(Vec::new()) };
}

pub struct ShellPlatform;

impl Platform for ShellPlatform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        let w = MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer);
        MADE.with(|m| m.borrow_mut().push(w.clone()));
        Ok(w)
    }
}

/// The adapter of the Slint window made last.
pub fn take_adapter() -> Option<Rc<MinimalSoftwareWindow>> {
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
