# hyprshell-rs

Hyprshell's shell in Rust, on Hyprland: the same bar, dock, launcher and
panels as the Quickshell one (`shell/quickshell`), drawn with Slint, with no
QML and no Quickshell. Being built a piece at a time on the `claude/rust-shell`
branch; the Quickshell shell stays the one in use until this has caught up.

    bash rshell/try.sh        build it, stop the Quickshell shell, run this
                              instead; Ctrl+C puts the usual shell back

## How it's put together

- `src/platform.rs`, `src/wl.rs` — Slint on Wayland layer-shell surfaces.
  Slint has no layer-shell backend, so this is one: its software renderer
  draws each component at the output's exact scale (fractional too, through
  wp_fractional_scale_v1 and wp_viewporter) into a shared-memory buffer, and
  pointer events go back to Slint.
- `src/hypr.rs` — Hyprland straight from its sockets: requests on
  `.socket.sock`, events from `.socket2.sock`. No `hyprctl` per question.
- `src/sys.rs` — the battery and network from /sys.
- `ui/` — the components. `ui/icons.slint` is generated from the shell's own
  glyphs by `node tools/gen-icons.js`, so both shells draw the same icons.

One thread runs Slint and Wayland, asleep in poll() on the Wayland
connection, the Hyprland event pipe and Slint's next timer.

## Done

1. The layer-shell platform, and the top bar: workspaces (click, scroll),
   the focused window's title, network, battery, clock.

## Next

2. The dock / taskbar, and the hyprshell-daemon connection (volume, Wi-Fi
   name, notifications count, ROG).
3. Launcher, control center, notifications, OSD.
4. Lock screen and face unlock.
5. Settings, overview, Alt+Tab.
6. Files, Task Manager, Terminal and Mail in Slint.
