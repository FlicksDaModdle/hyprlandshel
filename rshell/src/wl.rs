//! The Wayland side: outputs, layer surfaces, scaling and the pointer.
//!
//! Each `ShellSurface` is one Slint component on one layer surface. Sizes
//! are logical (what the layout says); the buffer is that times the
//! output's scale, fractional ones included (wp_fractional_scale_v1, shown
//! at the logical size through wp_viewporter), so text and the shell's
//! glyphs land on the screen's own pixels rather than being stretched.

use crate::platform::{self, Bgra};
use slint::platform::software_renderer::MinimalSoftwareWindow;
use slint::platform::{PointerEventButton, WindowAdapter, WindowEvent};
use slint::{LogicalPosition, PhysicalSize};
use smithay_client_toolkit::{
    compositor::{CompositorHandler, CompositorState},
    delegate_compositor, delegate_keyboard, delegate_layer, delegate_output, delegate_pointer, delegate_registry, delegate_seat,
    delegate_session_lock, delegate_shm,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
        keyboard::{KeyEvent, KeyboardHandler, Keysym, Modifiers, RepeatInfo},
        pointer::{PointerEvent, PointerEventKind, PointerHandler},
        Capability, SeatHandler, SeatState,
    },
    shell::{
        wlr_layer::{Anchor, KeyboardInteractivity, Layer, LayerShell, LayerShellHandler, LayerSurface, LayerSurfaceConfigure},
        WaylandSurface,
    },
    shm::{slot::SlotPool, Shm, ShmHandler},
};
use slint::platform::Key;
use smithay_client_toolkit::session_lock::{SessionLock, SessionLockHandler, SessionLockState, SessionLockSurface, SessionLockSurfaceConfigure};
use std::rc::Rc;
use wayland_client::{
    globals::GlobalList,
    protocol::{wl_keyboard, wl_output, wl_pointer, wl_seat, wl_shm, wl_surface},
    Connection, Dispatch, Proxy, QueueHandle,
};
use wayland_protocols::wp::fractional_scale::v1::client::{wp_fractional_scale_manager_v1, wp_fractional_scale_v1};
use wayland_protocols::wp::cursor_shape::v1::client::{wp_cursor_shape_device_v1, wp_cursor_shape_manager_v1};
use wayland_protocols::wp::viewporter::client::{wp_viewport, wp_viewporter};

/// Where and how a surface sits on its output.
pub struct Placement {
    pub namespace: &'static str,
    pub layer: Layer,
    pub anchor: Anchor,
    /// Logical; 0 along an anchored pair means "the output's whole length".
    pub width: u32,
    pub height: u32,
    pub exclusive: i32,
    pub keyboard: KeyboardInteractivity,
}

/// What a surface is to the compositor: a layer-shell surface (the bar,
/// panels, the dock …) or a session-lock one (the lock screen, one per
/// output, over everything and holding every key).
pub enum Role {
    Layer(LayerSurface),
    Lock(SessionLockSurface),
}

impl Role {
    pub fn wl_surface(&self) -> &wl_surface::WlSurface {
        match self {
            Role::Layer(l) => l.wl_surface(),
            Role::Lock(l) => l.wl_surface(),
        }
    }
    pub fn commit(&self) {
        self.wl_surface().commit();
    }
    fn set_layer(&self, layer: Layer) {
        if let Role::Layer(l) = self {
            l.set_layer(layer);
        }
    }
    fn set_exclusive_zone(&self, z: i32) {
        if let Role::Layer(l) = self {
            l.set_exclusive_zone(z);
        }
    }
    fn set_keyboard_interactivity(&self, k: KeyboardInteractivity) {
        if let Role::Layer(l) = self {
            l.set_keyboard_interactivity(k);
        }
    }
    fn set_size(&self, w: u32, h: u32) {
        if let Role::Layer(l) = self {
            l.set_size(w, h);
        }
    }
}

pub struct ShellSurface {
    pub layer: Role,
    pub adapter: Rc<MinimalSoftwareWindow>,
    #[allow(dead_code)] // the dock and panels, per monitor, read it
    pub output: Option<wl_output::WlOutput>,
    /// Logical size, as configured.
    pub width: u32,
    pub height: u32,
    /// The output's scale: 1.6666… on a 2560×1600 panel at 5/3.
    pub scale: f64,
    fractional: Option<wp_fractional_scale_v1::WpFractionalScaleV1>,
    viewport: Option<wp_viewport::WpViewport>,
    configured: bool,
    pool: Option<SlotPool>,
    /// The buffers handed to the compositor, each with the part of it that
    /// is out of date (x0, y0, x1, y1): a frame copies only that into
    /// whichever one the compositor has given back.
    bufs: Vec<(smithay_client_toolkit::shm::slot::Buffer, (i32, i32, i32, i32))>,
    /// The size last asked of the compositor.
    asked: (u32, u32),
    pixels: Vec<Bgra>,
    sized: (u32, u32, f64),
}

/// A surface showing one still picture, drawn by the caller straight into
/// the compositor's buffer with no Slint in between: the wallpaper, which
/// changes rarely and is the size of the screen, so it shouldn't also be
/// kept in a drawing buffer and spare copies.
pub struct Picture {
    layer: LayerSurface,
    fractional: Option<wp_fractional_scale_v1::WpFractionalScaleV1>,
    viewport: Option<wp_viewport::WpViewport>,
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    configured: bool,
    pool: Option<SlotPool>,
    buffer: Option<smithay_client_toolkit::shm::slot::Buffer>,
}

impl Picture {
    /// The size in device pixels to draw at, once the compositor has said.
    pub fn pixel_size(&self) -> Option<(u32, u32)> {
        (self.configured && self.width > 0 && self.height > 0)
            .then(|| (((self.width as f64) * self.scale).round() as u32, ((self.height as f64) * self.scale).round() as u32))
    }
}

pub struct Shell {
    registry: RegistryState,
    pub outputs: OutputState,
    seats: SeatState,
    compositor: CompositorState,
    layer_shell: LayerShell,
    shm: Shm,
    fractional: Option<wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1>,
    viewporter: Option<wp_viewporter::WpViewporter>,
    /// A removed surface's last frame, kept for its window: Slint redraws
    /// only what changed, so the window's next surface starts from it.
    kept: Vec<(Rc<MinimalSoftwareWindow>, Vec<Bgra>)>,
    pub pictures: Vec<Picture>,
    /// By id: a removed surface leaves a hole, so the ids of the rest hold.
    pub surfaces: Vec<Option<ShellSurface>>,
    pointer: Option<wl_pointer::WlPointer>,
    /// The surface the pointer is over, if one of ours.
    pub pointer_on: Option<usize>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    cursor_shapes: Option<wp_cursor_shape_manager_v1::WpCursorShapeManagerV1>,
    cursor: Option<wp_cursor_shape_device_v1::WpCursorShapeDeviceV1>,
    /// The surface with the keyboard, when one has it.
    focus: Option<usize>,
    /// Esc pressed on a surface, by id: what closes a panel.
    pub keys: Vec<(usize, Key)>,
    /// Key repeat, as the compositor says: (delay, interval).
    repeat: Option<(std::time::Duration, std::time::Duration)>,
    /// The key held down, what it types, and when it next repeats.
    held: Option<(u32, slint::SharedString, std::time::Instant)>,
    pub closed: bool,
    session_lock: Option<SessionLockState>,
    lock: Option<SessionLock>,
    /// The session lock: asked for, held (the compositor said so), or
    /// refused / ended.
    pub lock_state: LockState,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum LockState {
    Off,
    Asking,
    Locked,
    /// The compositor turned it down, or ended it.
    Finished,
}

impl Shell {
    pub fn new(globals: &GlobalList, qh: &QueueHandle<Self>) -> Result<Self, String> {
        let compositor = CompositorState::bind(globals, qh).map_err(|e| format!("wl_compositor: {e}"))?;
        let layer_shell = LayerShell::bind(globals, qh).map_err(|e| format!("layer shell (is this Hyprland?): {e}"))?;
        let shm = Shm::bind(globals, qh).map_err(|e| format!("wl_shm: {e}"))?;
        let fractional = globals.bind::<wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1, _, _>(qh, 1..=1, ()).ok();
        let viewporter = globals.bind::<wp_viewporter::WpViewporter, _, _>(qh, 1..=1, ()).ok();
        let cursor_shapes = globals.bind::<wp_cursor_shape_manager_v1::WpCursorShapeManagerV1, _, _>(qh, 1..=1, ()).ok();
        Ok(Shell {
            registry: RegistryState::new(globals),
            outputs: OutputState::new(globals, qh),
            seats: SeatState::new(globals, qh),
            compositor,
            layer_shell,
            shm,
            fractional,
            viewporter,
            surfaces: Vec::new(),
            pictures: Vec::new(),
            kept: Vec::new(),
            pointer: None,
            pointer_on: None,
            keyboard: None,
            cursor_shapes,
            cursor: None,
            focus: None,
            keys: Vec::new(),
            repeat: Some((std::time::Duration::from_millis(600), std::time::Duration::from_millis(40))),
            held: None,
            closed: false,
            session_lock: Some(SessionLockState::new(globals, qh)),
            lock: None,
            lock_state: LockState::Off,
        })
    }

    /// Puts the Slint window made last on a new layer surface.
    pub fn add(&mut self, qh: &QueueHandle<Self>, output: Option<&wl_output::WlOutput>, p: &Placement) -> usize {
        let adapter = platform::take_adapter().expect("a Slint window is made before it is placed");
        self.add_window(qh, adapter, output, p)
    }

    /// Puts a Slint window on a new layer surface: one made earlier and
    /// taken off its last one, as a panel is each time it opens.
    pub fn add_window(
        &mut self,
        qh: &QueueHandle<Self>,
        adapter: Rc<MinimalSoftwareWindow>,
        output: Option<&wl_output::WlOutput>,
        p: &Placement,
    ) -> usize {
        let surface = self.compositor.create_surface(qh);
        let fractional = self.fractional.as_ref().map(|m| m.get_fractional_scale(&surface, qh, surface.id()));
        let viewport = match (&self.fractional, &self.viewporter) {
            (Some(_), Some(v)) => Some(v.get_viewport(&surface, qh, ())),
            _ => None,
        };
        let layer = self.layer_shell.create_layer_surface(qh, surface, p.layer, Some(p.namespace), output);
        layer.set_anchor(p.anchor);
        layer.set_size(p.width, p.height);
        layer.set_exclusive_zone(p.exclusive);
        layer.set_keyboard_interactivity(p.keyboard);
        layer.commit();
        let layer = Role::Layer(layer);
        // The output's integer scale until it says otherwise: right for a
        // whole-number scale, and only the first frame's guess for 5/3.
        let scale = output
            .and_then(|o| self.outputs.info(o))
            .map(|i| i.scale_factor as f64)
            .unwrap_or(1.0);
        let pixels = match self.kept.iter().position(|(a, _)| Rc::ptr_eq(a, &adapter)) {
            Some(i) => self.kept.remove(i).1,
            None => Vec::new(),
        };
        let s = ShellSurface {
            layer,
            adapter,
            output: output.cloned(),
            width: p.width,
            height: p.height,
            scale,
            fractional,
            viewport,
            configured: false,
            pool: None,
            bufs: Vec::new(),
            asked: (p.width, p.height),
            pixels,
            sized: (0, 0, 0.0),
        };
        if let Some(free) = self.surfaces.iter().position(|s| s.is_none()) {
            self.surfaces[free] = Some(s);
            free
        } else {
            self.surfaces.push(Some(s));
            self.surfaces.len() - 1
        }
    }

    /// Asks the compositor to lock the session. Lock surfaces are put up
    /// with add_lock_window once it says it has (lock_state Locked); until
    /// then nothing is hidden.
    pub fn lock_session(&mut self, qh: &QueueHandle<Self>) -> bool {
        if self.lock.is_some() {
            return true;
        }
        let Some(state) = &self.session_lock else { return false };
        match state.lock(qh) {
            Ok(l) => {
                self.lock = Some(l);
                self.lock_state = LockState::Asking;
                true
            }
            Err(e) => {
                eprintln!("hyprshell-rs: no session lock ({e})");
                false
            }
        }
    }

    /// A Slint window on a lock surface for `output`.
    pub fn add_lock_window(&mut self, qh: &QueueHandle<Self>, adapter: Rc<MinimalSoftwareWindow>, output: &wl_output::WlOutput) -> Option<usize> {
        let lock = self.lock.as_ref()?;
        let surface = self.compositor.create_surface(qh);
        let fractional = self.fractional.as_ref().map(|m| m.get_fractional_scale(&surface, qh, surface.id()));
        let viewport = match (&self.fractional, &self.viewporter) {
            (Some(_), Some(v)) => Some(v.get_viewport(&surface, qh, ())),
            _ => None,
        };
        let role = Role::Lock(lock.create_lock_surface(surface, output, qh));
        let scale = self.outputs.info(output).map(|i| i.scale_factor as f64).unwrap_or(1.0);
        let s = ShellSurface {
            layer: role,
            adapter,
            output: Some(output.clone()),
            width: 0,
            height: 0,
            scale,
            fractional,
            viewport,
            configured: false,
            pool: None,
            bufs: Vec::new(),
            asked: (0, 0),
            pixels: Vec::new(),
            sized: (0, 0, 0.0),
        };
        Some(if let Some(free) = self.surfaces.iter().position(|s| s.is_none()) {
            self.surfaces[free] = Some(s);
            free
        } else {
            self.surfaces.push(Some(s));
            self.surfaces.len() - 1
        })
    }

    /// Lets the session go: the compositor shows the desktop again. The
    /// lock surfaces are the caller's to remove.
    pub fn unlock_session(&mut self) {
        if let Some(l) = self.lock.take() {
            l.unlock();
        }
        self.lock_state = LockState::Off;
    }

    /// The outputs there are, for a lock surface on each.
    pub fn all_outputs(&self) -> Vec<wl_output::WlOutput> {
        self.outputs.outputs().collect()
    }
    /// An output's size on the desktop, logical pixels.
    pub fn output_logical(&self, o: &wl_output::WlOutput) -> (i32, i32) {
        self.outputs.info(o).and_then(|i| i.logical_size).unwrap_or((0, 0))
    }
    /// An output's name (eDP-1), as Hyprland calls it.
    pub fn output_name(&self, o: &wl_output::WlOutput) -> String {
        self.outputs.info(o).and_then(|i| i.name).unwrap_or_default()
    }

    /// A picture surface (see Picture); its index in `pictures`.
    pub fn add_picture(&mut self, qh: &QueueHandle<Self>, output: Option<&wl_output::WlOutput>, p: &Placement) -> usize {
        let surface = self.compositor.create_surface(qh);
        let fractional = self.fractional.as_ref().map(|m| m.get_fractional_scale(&surface, qh, surface.id()));
        let viewport = match (&self.fractional, &self.viewporter) {
            (Some(_), Some(v)) => Some(v.get_viewport(&surface, qh, ())),
            _ => None,
        };
        // It takes no input: clicks on the desktop go to the panel layer or
        // nowhere.
        if let Ok(r) = smithay_client_toolkit::compositor::Region::new(&self.compositor) {
            surface.set_input_region(Some(r.wl_region()));
        }
        let layer = self.layer_shell.create_layer_surface(qh, surface, p.layer, Some(p.namespace), output);
        layer.set_anchor(p.anchor);
        layer.set_size(p.width, p.height);
        layer.set_exclusive_zone(p.exclusive);
        layer.set_keyboard_interactivity(p.keyboard);
        layer.commit();
        let scale = output.and_then(|o| self.outputs.info(o)).map(|i| i.scale_factor as f64).unwrap_or(1.0);
        self.pictures.push(Picture { layer, fractional, viewport, width: p.width, height: p.height, scale, configured: false, pool: None, buffer: None });
        self.pictures.len() - 1
    }

    /// Puts a picture on its surface: `fill` writes it, BGRA, `w`×`h`
    /// device pixels, into the buffer the compositor will read.
    pub fn set_picture(&mut self, id: usize, w: u32, h: u32, fill: impl FnOnce(&mut [u8])) {
        let shm = &self.shm;
        let Some(p) = self.pictures.get_mut(id) else { return };
        let stride = w as i32 * 4;
        let len = (stride * h as i32) as usize;
        // The last one goes first, so there is only ever the one.
        p.buffer = None;
        let pool = p.pool.get_or_insert_with(|| SlotPool::new(len, shm).expect("shm pool"));
        if pool.len() < len {
            let _ = pool.resize(len);
        }
        let Ok((buffer, canvas)) = pool.create_buffer(w as i32, h as i32, stride, wl_shm::Format::Xrgb8888) else { return };
        fill(&mut canvas[..len]);
        let surface = p.layer.wl_surface();
        if let Some(vp) = &p.viewport {
            surface.set_buffer_scale(1);
            vp.set_destination(p.width as i32, p.height as i32);
        } else {
            surface.set_buffer_scale(p.scale.round().max(1.0) as i32);
        }
        surface.damage_buffer(0, 0, w as i32, h as i32);
        if buffer.attach_to(surface).is_ok() {
            p.layer.commit();
        }
        p.buffer = Some(buffer);
    }

    fn picture_of(&self, surface: &wl_surface::WlSurface) -> Option<usize> {
        self.pictures.iter().position(|p| p.layer.wl_surface() == surface)
    }

    /// Takes a surface off the screen. Its Slint window is handed back, to
    /// be put on another later.
    pub fn remove(&mut self, id: usize) -> Option<Rc<MinimalSoftwareWindow>> {
        let mut s = self.surfaces.get_mut(id)?.take()?;
        if self.focus == Some(id) {
            self.focus = None;
        }
        if let Some(f) = &s.fractional {
            f.destroy();
        }
        if let Some(v) = &s.viewport {
            v.destroy();
        }
        s.adapter.window().dispatch_event(WindowEvent::PointerExited);
        let adapter = s.adapter.clone();
        self.kept.retain(|(a, _)| !Rc::ptr_eq(a, &adapter));
        self.kept.push((adapter.clone(), std::mem::take(&mut s.pixels)));
        drop(s);
        Some(adapter)
    }

    /// Whether a surface takes the pointer: a panel layer fading out lets
    /// clicks through to what is under it, as PanelLayer.qml's mask does.
    pub fn set_input(&mut self, id: usize, on: bool) {
        let Some(Some(s)) = self.surfaces.get(id) else { return };
        let surface = s.layer.wl_surface();
        if on {
            surface.set_input_region(None);
        } else if let Ok(r) = smithay_client_toolkit::compositor::Region::new(&self.compositor) {
            surface.set_input_region(Some(r.wl_region()));
        }
        s.layer.commit();
    }

    /// Where a surface takes the pointer, logical; None for nowhere. The
    /// dock takes it over its pill, or along the bottom edge while hidden.
    pub fn set_input_rect(&mut self, id: usize, r: Option<(i32, i32, i32, i32)>) {
        let Some(Some(s)) = self.surfaces.get(id) else { return };
        let Ok(region) = smithay_client_toolkit::compositor::Region::new(&self.compositor) else { return };
        if let Some((x, y, w, h)) = r {
            region.add(x, y, w.max(0), h.max(0));
        }
        s.layer.wl_surface().set_input_region(Some(region.wl_region()));
        s.layer.commit();
    }

    /// Over fullscreen windows (Overlay) or not (Top), and the room it keeps.
    pub fn set_layer(&mut self, id: usize, layer: Layer, exclusive: i32) {
        if let Some(Some(s)) = self.surfaces.get(id) {
            s.layer.set_layer(layer);
            s.layer.set_exclusive_zone(exclusive);
            s.layer.commit();
        }
    }

    /// Whether a surface takes the keyboard.
    pub fn set_keyboard(&mut self, id: usize, k: KeyboardInteractivity) {
        if let Some(Some(s)) = self.surfaces.get(id) {
            s.layer.set_keyboard_interactivity(k);
            s.layer.commit();
        }
    }

    /// A new logical size for a surface sized to its content (the toasts).
    pub fn resize(&mut self, id: usize, width: u32, height: u32) {
        if let Some(Some(s)) = self.surfaces.get_mut(id) {
            if s.asked != (width, height) {
                s.asked = (width, height);
                s.layer.set_size(width, height);
                s.layer.commit();
            }
        }
    }

    fn index_of(&self, surface: &wl_surface::WlSurface) -> Option<usize> {
        self.surfaces.iter().position(|s| s.as_ref().is_some_and(|s| s.layer.wl_surface() == surface))
    }

    fn at(&mut self, i: usize) -> &mut ShellSurface {
        self.surfaces[i].as_mut().expect("a live surface")
    }

    /// Draws every surface whose component has changed.
    pub fn draw(&mut self) {
        let shm = &self.shm;
        for s in self.surfaces.iter_mut().flatten() {
            if !s.configured || s.width == 0 || s.height == 0 {
                continue;
            }
            let pw = (s.width as f64 * s.scale).round().max(1.0) as u32;
            let ph = (s.height as f64 * s.scale).round().max(1.0) as u32;
            if s.sized != (pw, ph, s.scale) {
                s.sized = (pw, ph, s.scale);
                s.adapter.window().dispatch_event(WindowEvent::ScaleFactorChanged { scale_factor: s.scale as f32 });
                s.adapter.set_size(PhysicalSize::new(pw, ph));
                s.adapter.request_redraw();
            }
            let len = (pw * ph) as usize;
            if s.pixels.len() != len {
                // A new size: Slint draws all of it into this.
                s.pixels = vec![Bgra::default(); len];
                s.bufs.clear();
            }
            let pixels = &mut s.pixels;
            let mut damage = (0, 0, 0, 0);
            let drew = s.adapter.draw_if_needed(|r| {
                let region = r.render(pixels.as_mut_slice(), pw as usize);
                let (o, z) = (region.bounding_box_origin(), region.bounding_box_size());
                damage = (o.x, o.y, z.width as i32, z.height as i32);
            });
            if !drew || damage.2 <= 0 || damage.3 <= 0 {
                continue;
            }
            let stride = pw as i32 * 4;
            let full = (0, 0, pw as i32, ph as i32);
            let d = (damage.0, damage.1, damage.0 + damage.2, damage.1 + damage.3);
            let union = |a: (i32, i32, i32, i32), b: (i32, i32, i32, i32)| {
                if a.2 <= a.0 { b } else { (a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3)) }
            };
            for (_, stale) in &mut s.bufs {
                *stale = union(*stale, d);
            }
            let pool = s.pool.get_or_insert_with(|| SlotPool::new((stride * ph as i32) as usize * 2, shm).expect("shm pool"));
            // One the compositor has let go of, else a new one (three at most).
            let free = s.bufs.iter().position(|(b, _)| b.canvas(pool).is_some());
            let i = match free {
                Some(i) => i,
                None if s.bufs.len() < 3 => {
                    let Ok((b, _)) = pool.create_buffer(pw as i32, ph as i32, stride, wl_shm::Format::Argb8888) else { continue };
                    s.bufs.push((b, full));
                    s.bufs.len() - 1
                }
                None => continue,
            };
            let (buffer, stale) = &mut s.bufs[i];
            let Some(canvas) = buffer.canvas(pool) else { continue };
            // SAFETY: Bgra is four u8s, repr(C), so the slice is its bytes.
            let bytes = unsafe { std::slice::from_raw_parts(s.pixels.as_ptr() as *const u8, s.pixels.len() * 4) };
            let (x0, y0, x1, y1) = (stale.0.max(0) as usize * 4, stale.1.max(0) as usize, stale.2.min(pw as i32) as usize * 4, stale.3.min(ph as i32) as usize);
            let row = stride as usize;
            for y in y0..y1 {
                let at = y * row;
                canvas[at + x0..at + x1].copy_from_slice(&bytes[at + x0..at + x1]);
            }
            *stale = (0, 0, 0, 0);
            let surface = s.layer.wl_surface();
            if let Some(vp) = &s.viewport {
                surface.set_buffer_scale(1);
                vp.set_destination(s.width as i32, s.height as i32);
            } else {
                surface.set_buffer_scale(s.scale.round().max(1.0) as i32);
            }
            // Only what Slint redrew is new to the compositor.
            surface.damage_buffer(damage.0, damage.1, damage.2, damage.3);
            if s.bufs[i].0.attach_to(surface).is_ok() {
                s.layer.commit();
            }
        }
    }

    /// Something has been put on screen: a surface has had a frame drawn.
    pub fn drawn(&self) -> bool {
        self.surfaces.iter().flatten().any(|s| !s.bufs.is_empty())
    }

    pub fn animating(&self) -> bool {
        self.surfaces.iter().flatten().any(|s| s.adapter.window().has_active_animations())
    }
}

// ── layer surfaces ──────────────────────────────────────────────────────────

impl LayerShellHandler for Shell {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface) {
        if let Some(i) = self.index_of(layer.wl_surface()) {
            self.at(i).configured = false;
        }
    }

    fn configure(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface, c: LayerSurfaceConfigure, _: u32) {
        if let Some(i) = self.picture_of(layer.wl_surface()) {
            let p = &mut self.pictures[i];
            if c.new_size.0 > 0 {
                p.width = c.new_size.0;
            }
            if c.new_size.1 > 0 {
                p.height = c.new_size.1;
            }
            p.configured = true;
            return;
        }
        let Some(i) = self.index_of(layer.wl_surface()) else { return };
        let s = self.at(i);
        if c.new_size.0 > 0 {
            s.width = c.new_size.0;
        }
        if c.new_size.1 > 0 {
            s.height = c.new_size.1;
        }
        s.configured = true;
        s.adapter.request_redraw();
    }
}

// ── the session lock ────────────────────────────────────────────────────────

impl SessionLockHandler for Shell {
    fn locked(&mut self, _: &Connection, _: &QueueHandle<Self>, _: SessionLock) {
        self.lock_state = LockState::Locked;
    }
    fn finished(&mut self, _: &Connection, _: &QueueHandle<Self>, _: SessionLock) {
        self.lock = None;
        self.lock_state = LockState::Finished;
    }
    fn configure(&mut self, _: &Connection, _: &QueueHandle<Self>, surface: SessionLockSurface, c: SessionLockSurfaceConfigure, _: u32) {
        let Some(i) = self.index_of(surface.wl_surface()) else { return };
        let s = self.at(i);
        s.width = c.new_size.0;
        s.height = c.new_size.1;
        s.configured = true;
        s.adapter.request_redraw();
    }
}

// ── scale ───────────────────────────────────────────────────────────────────

impl CompositorHandler for Shell {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, surface: &wl_surface::WlSurface, factor: i32) {
        // Only without fractional scaling: with it, preferred_scale decides.
        if let Some(i) = self.picture_of(surface) {
            if self.pictures[i].fractional.is_none() {
                self.pictures[i].scale = factor.max(1) as f64;
            }
            return;
        }
        let Some(i) = self.index_of(surface) else { return };
        let s = self.at(i);
        if s.fractional.is_none() {
            s.scale = factor.max(1) as f64;
            s.adapter.request_redraw();
        }
    }
    fn transform_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: wl_output::Transform) {}
    fn frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: u32) {}
    fn surface_enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
    fn surface_leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_surface::WlSurface, _: &wl_output::WlOutput) {}
}

impl Dispatch<wp_fractional_scale_v1::WpFractionalScaleV1, wayland_client::backend::ObjectId> for Shell {
    fn event(
        state: &mut Self,
        _: &wp_fractional_scale_v1::WpFractionalScaleV1,
        event: wp_fractional_scale_v1::Event,
        surface: &wayland_client::backend::ObjectId,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wp_fractional_scale_v1::Event::PreferredScale { scale } = event {
            if let Some(p) = state.pictures.iter_mut().find(|p| &p.layer.wl_surface().id() == surface) {
                p.scale = scale as f64 / 120.0;
            }
            if let Some(s) = state.surfaces.iter_mut().flatten().find(|s| &s.layer.wl_surface().id() == surface) {
                s.scale = scale as f64 / 120.0;
                s.adapter.request_redraw();
            }
        }
    }
}

impl Dispatch<wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1, ()> for Shell {
    fn event(_: &mut Self, _: &wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1, _: wp_fractional_scale_manager_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wp_viewporter::WpViewporter, ()> for Shell {
    fn event(_: &mut Self, _: &wp_viewporter::WpViewporter, _: wp_viewporter::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wp_viewport::WpViewport, ()> for Shell {
    fn event(_: &mut Self, _: &wp_viewport::WpViewport, _: wp_viewport::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

// ── the pointer ─────────────────────────────────────────────────────────────

impl PointerHandler for Shell {
    fn pointer_frame(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_pointer::WlPointer, events: &[PointerEvent]) {
        for ev in events {
            let Some(i) = self.index_of(&ev.surface) else { continue };
            let at = LogicalPosition::new(ev.position.0 as f32, ev.position.1 as f32);
            let adapter = self.at(i).adapter.clone();
            let window = adapter.window();
            match ev.kind {
                PointerEventKind::Enter { serial } => {
                    self.pointer_on = Some(i);
                    // The arrow, not whatever the window left behind.
                    if let Some(c) = &self.cursor {
                        c.set_shape(serial, wp_cursor_shape_device_v1::Shape::Default);
                    }
                    window.dispatch_event(WindowEvent::PointerMoved { position: at });
                }
                PointerEventKind::Motion { .. } => {
                    window.dispatch_event(WindowEvent::PointerMoved { position: at });
                }
                PointerEventKind::Leave { .. } => {
                    if self.pointer_on == Some(i) {
                        self.pointer_on = None;
                    }
                    window.dispatch_event(WindowEvent::PointerExited);
                }
                PointerEventKind::Press { button, .. } | PointerEventKind::Release { button, .. } => {
                    let button = match button {
                        0x110 => PointerEventButton::Left,
                        0x111 => PointerEventButton::Right,
                        0x112 => PointerEventButton::Middle,
                        _ => PointerEventButton::Other,
                    };
                    let pressed = matches!(ev.kind, PointerEventKind::Press { .. });
                    window.dispatch_event(if pressed {
                        WindowEvent::PointerPressed { position: at, button }
                    } else {
                        WindowEvent::PointerReleased { position: at, button }
                    });
                }
                PointerEventKind::Axis { horizontal, vertical, .. } => {
                    window.dispatch_event(WindowEvent::PointerScrolled {
                        position: at,
                        delta_x: -horizontal.absolute as f32,
                        delta_y: -vertical.absolute as f32,
                    });
                }
            }
        }
    }
}

impl SeatHandler for Shell {
    fn seat_state(&mut self) -> &mut SeatState {
        &mut self.seats
    }
    fn new_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
    fn new_capability(&mut self, _: &Connection, qh: &QueueHandle<Self>, seat: wl_seat::WlSeat, cap: Capability) {
        if cap == Capability::Pointer && self.pointer.is_none() {
            self.pointer = self.seats.get_pointer(qh, &seat).ok();
            if let (Some(m), Some(p)) = (&self.cursor_shapes, &self.pointer) {
                self.cursor = Some(m.get_pointer(p, qh, ()));
            }
        }
        // With the keymap (xkbcommon), so typing follows the layout.
        // key on every layout.
        if cap == Capability::Keyboard && self.keyboard.is_none() {
            self.keyboard = self.seats.get_keyboard(qh, &seat, None).ok();
        }
    }
    fn remove_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat, cap: Capability) {
        if cap == Capability::Pointer {
            if let Some(c) = self.cursor.take() {
                c.destroy();
            }
            if let Some(p) = self.pointer.take() {
                p.release();
            }
        }
        if cap == Capability::Keyboard {
            if let Some(k) = self.keyboard.take() {
                k.release();
            }
        }
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
}

/// What Slint calls a key: the special ones by their Key, the rest by the
/// text they type.
fn slint_key(sym: Keysym, utf8: Option<&str>) -> Option<slint::SharedString> {
    let k = match sym {
        Keysym::BackSpace => Key::Backspace,
        Keysym::Tab | Keysym::ISO_Left_Tab => Key::Tab,
        Keysym::Return | Keysym::KP_Enter => Key::Return,
        Keysym::Escape => Key::Escape,
        Keysym::Delete | Keysym::KP_Delete => Key::Delete,
        Keysym::Left | Keysym::KP_Left => Key::LeftArrow,
        Keysym::Right | Keysym::KP_Right => Key::RightArrow,
        Keysym::Up | Keysym::KP_Up => Key::UpArrow,
        Keysym::Down | Keysym::KP_Down => Key::DownArrow,
        Keysym::Home | Keysym::KP_Home => Key::Home,
        Keysym::End | Keysym::KP_End => Key::End,
        Keysym::Page_Up | Keysym::KP_Page_Up => Key::PageUp,
        Keysym::Page_Down | Keysym::KP_Page_Down => Key::PageDown,
        Keysym::Shift_L | Keysym::Shift_R => Key::Shift,
        Keysym::Control_L | Keysym::Control_R => Key::Control,
        Keysym::Alt_L | Keysym::Alt_R => Key::Alt,
        Keysym::Super_L | Keysym::Super_R => Key::Meta,
        _ => {
            let t = utf8.filter(|t| !t.is_empty() && !t.chars().any(|c| c.is_control()))?;
            return Some(t.into());
        }
    };
    Some(k.into())
}

impl Shell {
    /// Repeats the held key when it's time; when the next one is due.
    pub fn repeat_keys(&mut self) -> Option<std::time::Duration> {
        let (_, interval) = self.repeat?;
        let (_, text, at) = self.held.as_mut()?;
        let now = std::time::Instant::now();
        if now >= *at {
            *at = now + interval;
            let text = text.clone();
            if let Some(Some(s)) = self.focus.and_then(|i| self.surfaces.get(i)) {
                s.adapter.window().dispatch_event(WindowEvent::KeyPressed { text: text.clone() });
                s.adapter.window().dispatch_event(WindowEvent::KeyReleased { text });
            }
        }
        self.held.as_ref().map(|(_, _, at)| at.saturating_duration_since(now))
    }

    fn key_window(&self) -> Option<&ShellSurface> {
        self.focus.and_then(|i| self.surfaces.get(i)?.as_ref())
    }
}

impl KeyboardHandler for Shell {
    fn enter(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, surface: &wl_surface::WlSurface, _: u32, _: &[u32], _: &[Keysym]) {
        self.focus = self.index_of(surface);
        // In the log, for when typing goes somewhere it shouldn't.
        eprintln!("hyprshell-rs: the keyboard is on surface {:?}", self.focus);
        if let Some(s) = self.key_window() {
            s.adapter.window().dispatch_event(WindowEvent::WindowActiveChanged(true));
        }
    }

    fn leave(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: &wl_surface::WlSurface, _: u32) {
        eprintln!("hyprshell-rs: the keyboard left surface {:?}", self.focus);
        if let Some(s) = self.key_window() {
            s.adapter.window().dispatch_event(WindowEvent::WindowActiveChanged(false));
        }
        self.focus = None;
        self.held = None;
    }

    fn press_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, e: KeyEvent) {
        let Some(i) = self.focus else { return };
        if e.keysym == Keysym::Escape {
            self.keys.push((i, Key::Escape));
        }
        let Some(text) = slint_key(e.keysym, e.utf8.as_deref()) else { return };
        if let Some(s) = self.key_window() {
            s.adapter.window().dispatch_event(WindowEvent::KeyPressed { text: text.clone() });
        }
        // Modifiers don't repeat; everything else does, after the delay.
        let modifier = matches!(e.keysym, Keysym::Shift_L | Keysym::Shift_R | Keysym::Control_L | Keysym::Control_R
            | Keysym::Alt_L | Keysym::Alt_R | Keysym::Super_L | Keysym::Super_R);
        self.held = match (modifier, self.repeat) {
            (false, Some((delay, _))) => Some((e.raw_code, text, std::time::Instant::now() + delay)),
            _ => self.held.take().filter(|_| modifier),
        };
    }

    fn release_key(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, e: KeyEvent) {
        if self.held.as_ref().is_some_and(|(code, _, _)| *code == e.raw_code) {
            self.held = None;
        }
        let Some(text) = slint_key(e.keysym, e.utf8.as_deref().or(Some(""))) else { return };
        if let Some(s) = self.key_window() {
            s.adapter.window().dispatch_event(WindowEvent::KeyReleased { text });
        }
    }

    fn update_modifiers(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, _: u32, _: Modifiers, _: u32) {}

    fn update_repeat_info(&mut self, _: &Connection, _: &QueueHandle<Self>, _: &wl_keyboard::WlKeyboard, info: RepeatInfo) {
        self.repeat = match info {
            RepeatInfo::Repeat { rate, delay } => Some((
                std::time::Duration::from_millis(delay as u64),
                std::time::Duration::from_micros(1_000_000 / rate.get() as u64),
            )),
            RepeatInfo::Disable => None,
        };
    }
}

impl Dispatch<wp_cursor_shape_manager_v1::WpCursorShapeManagerV1, ()> for Shell {
    fn event(_: &mut Self, _: &wp_cursor_shape_manager_v1::WpCursorShapeManagerV1, _: wp_cursor_shape_manager_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wp_cursor_shape_device_v1::WpCursorShapeDeviceV1, ()> for Shell {
    fn event(_: &mut Self, _: &wp_cursor_shape_device_v1::WpCursorShapeDeviceV1, _: wp_cursor_shape_device_v1::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

// ── the rest SCTK asks for ──────────────────────────────────────────────────

impl OutputHandler for Shell {
    fn output_state(&mut self) -> &mut OutputState {
        &mut self.outputs
    }
    fn new_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn update_output(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
    fn output_destroyed(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_output::WlOutput) {}
}

impl ShmHandler for Shell {
    fn shm_state(&mut self) -> &mut Shm {
        &mut self.shm
    }
}

impl ProvidesRegistryState for Shell {
    fn registry(&mut self) -> &mut RegistryState {
        &mut self.registry
    }
    registry_handlers![OutputState, SeatState];
}

delegate_compositor!(Shell);
delegate_output!(Shell);
delegate_shm!(Shell);
delegate_seat!(Shell);
delegate_pointer!(Shell);
delegate_keyboard!(Shell);
delegate_layer!(Shell);
delegate_session_lock!(Shell);
delegate_registry!(Shell);
