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
use std::rc::Rc;
use wayland_client::{
    globals::GlobalList,
    protocol::{wl_output, wl_pointer, wl_seat, wl_shm, wl_surface},
    Connection, Dispatch, Proxy, QueueHandle,
};
use wayland_protocols::wp::fractional_scale::v1::client::{wp_fractional_scale_manager_v1, wp_fractional_scale_v1};
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
    pub surfaces: Vec<ShellSurface>,
    pointer: Option<wl_pointer::WlPointer>,
    /// The surface under the pointer, and where on it (logical).
    hover: Option<(usize, LogicalPosition)>,
    pub closed: bool,
}

impl Shell {
    pub fn new(globals: &GlobalList, qh: &QueueHandle<Self>) -> Result<Self, String> {
        let compositor = CompositorState::bind(globals, qh).map_err(|e| format!("wl_compositor: {e}"))?;
        let layer_shell = LayerShell::bind(globals, qh).map_err(|e| format!("layer shell (is this Hyprland?): {e}"))?;
        let shm = Shm::bind(globals, qh).map_err(|e| format!("wl_shm: {e}"))?;
        let fractional = globals.bind::<wp_fractional_scale_manager_v1::WpFractionalScaleManagerV1, _, _>(qh, 1..=1, ()).ok();
        let viewporter = globals.bind::<wp_viewporter::WpViewporter, _, _>(qh, 1..=1, ()).ok();
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
            hover: None,
            closed: false,
        })
    }

    /// Puts the Slint window made last on a new layer surface.
    pub fn add(&mut self, qh: &QueueHandle<Self>, output: Option<&wl_output::WlOutput>, p: &Placement) -> usize {
        let adapter = platform::take_adapter().expect("a Slint window is made before it is placed");
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
        self.surfaces.push(ShellSurface {
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
            pixels: Vec::new(),
            sized: (0, 0, 0.0),
        });
        self.surfaces.len() - 1
    }

    fn index_of(&self, surface: &wl_surface::WlSurface) -> Option<usize> {
        self.surfaces.iter().position(|s| s.layer.wl_surface() == surface)
    }

    /// Draws every surface whose component has changed.
    pub fn draw(&mut self) {
        let shm = &self.shm;
        for s in &mut self.surfaces {
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
        self.surfaces.iter().any(|s| s.adapter.window().has_active_animations())
    }
}

// ── layer surfaces ──────────────────────────────────────────────────────────

impl LayerShellHandler for Shell {
    fn closed(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface) {
        if let Some(i) = self.index_of(layer.wl_surface()) {
            self.surfaces[i].configured = false;
        }
    }

    fn configure(&mut self, _: &Connection, _: &QueueHandle<Self>, layer: &LayerSurface, c: LayerSurfaceConfigure, _: u32) {
        let Some(i) = self.index_of(layer.wl_surface()) else { return };
        let s = &mut self.surfaces[i];
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
        if self.surfaces[i].fractional.is_none() {
            self.surfaces[i].scale = factor.max(1) as f64;
            self.surfaces[i].adapter.request_redraw();
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
            if let Some(s) = state.surfaces.iter_mut().find(|s| &s.layer.wl_surface().id() == surface) {
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
            let window = self.surfaces[i].adapter.window();
            match ev.kind {
                PointerEventKind::Enter { .. } | PointerEventKind::Motion { .. } => {
                    self.hover = Some((i, at));
                    window.dispatch_event(WindowEvent::PointerMoved { position: at });
                }
                PointerEventKind::Leave { .. } => {
                    self.hover = None;
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
        }
    }
    fn remove_capability(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat, cap: Capability) {
        if cap == Capability::Pointer {
            if let Some(p) = self.pointer.take() {
                p.release();
            }
        }
    }
    fn remove_seat(&mut self, _: &Connection, _: &QueueHandle<Self>, _: wl_seat::WlSeat) {}
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
