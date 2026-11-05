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
- `src/theme.rs` — theme.json, worked out as config/Appearance.qml does.
- `src/daemon.rs` — hyprshell-daemon (the same one the Quickshell shell
  runs) for the network and the sound.
- `src/mpris.rs` — what's playing, over D-Bus.
- `src/sys.rs` — the battery, from /sys.
- `ui/` — the components. `ui/icons.slint` is generated from the shell's own
  glyphs by `node tools/gen-icons.js`, so both shells draw the same icons.

One thread runs Slint and Wayland, asleep in poll() on the Wayland
connection, the Hyprland event pipe and Slint's next timer.

## Done

1. The layer-shell platform, and the top bar as modules/bar/Bar.qml lays
   it out: the workspace capsule (focused and hovered pills open to their
   number, dots and rings, urgent; click, scroll), the focused app with
   its underline, Window, the title, the media pill (MPRIS: title, artist,
   equaliser, previous / play-pause / next, seek line), notifications, the
   status capsule (Wi-Fi name, volume — scroll to change — and battery),
   the clock and power. Colours, accent, translucency, rounding, text size,
   the bar's sizes, the 24-hour clock and the per-monitor shell scale come
   from theme.json, read again when it changes.

   Still to come for the bar: the tray, the indicators (recording,
   privacy, timers, updates, mail, drives), the notification count (when
   notifications are ported), album art, auto-hide, and the panels its
   buttons open.

## Next

2. The dock / taskbar, and the hyprshell-daemon connection (volume, Wi-Fi
   name, notifications count, ROG).
3. Launcher, control center, notifications, OSD.
4. Lock screen and face unlock.
5. Settings, overview, Alt+Tab.
6. Files, Task Manager, Terminal and Mail in Slint.
