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
    delegate_compositor, delegate_layer, delegate_output, delegate_pointer, delegate_registry, delegate_seat,
    delegate_shm,
    output::{OutputHandler, OutputState},
    registry::{ProvidesRegistryState, RegistryState},
    registry_handlers,
    seat::{
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

pub struct ShellSurface {
    pub layer: LayerSurface,
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
    /// The size last asked of the compositor.
    asked: (u32, u32),
    pixels: Vec<Bgra>,
    sized: (u32, u32, f64),
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
    /// By id: a removed surface leaves a hole, so the ids of the rest hold.
    pub surfaces: Vec<Option<ShellSurface>>,
    pointer: Option<wl_pointer::WlPointer>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    cursor_shapes: Option<wp_cursor_shape_manager_v1::WpCursorShapeManagerV1>,
    cursor: Option<wp_cursor_shape_device_v1::WpCursorShapeDeviceV1>,
    /// The surface with the keyboard, when one has it.
    focus: Option<usize>,
    /// Keys pressed on a surface that wants them (Esc, for now), by id.
    pub keys: Vec<(usize, Key)>,
    pub closed: bool,
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
            pointer: None,
            keyboard: None,
            cursor_shapes,
            cursor: None,
            focus: None,
            keys: Vec::new(),
            closed: false,
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
        // The output's integer scale until it says otherwise: right for a
        // whole-number scale, and only the first frame's guess for 5/3.
        let scale = output
            .and_then(|o| self.outputs.info(o))
            .map(|i| i.scale_factor as f64)
            .unwrap_or(1.0);
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
            asked: (p.width, p.height),
            pixels: Vec::new(),
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

    /// Takes a surface off the screen. Its Slint window is handed back, to
    /// be put on another later.
    pub fn remove(&mut self, id: usize) -> Option<Rc<MinimalSoftwareWindow>> {
        let s = self.surfaces.get_mut(id)?.take()?;
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
        drop(s);
        Some(adapter)
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
                s.pixels = vec![Bgra::default(); len];
            }
            let pixels = &mut s.pixels;
            let drew = s.adapter.draw_if_needed(|r| {
                r.render(pixels.as_mut_slice(), pw as usize);
            });
            if !drew {
                continue;
            }
            let stride = pw as i32 * 4;
            let pool = s.pool.get_or_insert_with(|| SlotPool::new((stride * ph as i32) as usize, shm).expect("shm pool"));
            let Ok((buffer, canvas)) = pool.create_buffer(pw as i32, ph as i32, stride, wl_shm::Format::Argb8888) else {
                continue;
            };
            // SAFETY: Bgra is four u8s, repr(C), so the slice is its bytes.
            let bytes = unsafe { std::slice::from_raw_parts(s.pixels.as_ptr() as *const u8, s.pixels.len() * 4) };
            canvas[..bytes.len()].copy_from_slice(bytes);
            let surface = s.layer.wl_surface();
            if let Some(vp) = &s.viewport {
                surface.set_buffer_scale(1);
                vp.set_destination(s.width as i32, s.height as i32);
            } else {
                surface.set_buffer_scale(s.scale.round().max(1.0) as i32);
            }
            surface.damage_buffer(0, 0, pw as i32, ph as i32);
            if buffer.attach_to(surface).is_ok() {
                s.layer.commit();
            }
        }
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

// ── scale ───────────────────────────────────────────────────────────────────

impl CompositorHandler for Shell {
    fn scale_factor_changed(&mut self, _: &Connection, _: &QueueHandle<Self>, surface: &wl_surface::WlSurface, factor: i32) {
        // Only without fractional scaling: with it, preferred_scale decides.
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
        // Raw keys, no keymap: all a panel needs is Esc, which is the same
        // key on every layout.
        if cap == Capability::Keyboard && self.keyboard.is_none() {
            self.keyboard = Some(seat.get_keyboard(qh, ()));
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

impl Dispatch<wl_keyboard::WlKeyboard, ()> for Shell {
    fn event(state: &mut Self, _: &wl_keyboard::WlKeyboard, event: wl_keyboard::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {
        match event {
            wl_keyboard::Event::Enter { surface, .. } => state.focus = state.index_of(&surface),
            wl_keyboard::Event::Leave { .. } => state.focus = None,
            wl_keyboard::Event::Key { key, state: wayland_client::WEnum::Value(wl_keyboard::KeyState::Pressed), .. } => {
                // evdev codes: 1 is Esc.
                if let (Some(i), 1) = (state.focus, key) {
                    state.keys.push((i, Key::Escape));
                }
            }
            _ => {}
        }
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
delegate_layer!(Shell);
delegate_registry!(Shell);
