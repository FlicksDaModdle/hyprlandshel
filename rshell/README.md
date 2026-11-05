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
  runs): network, sound and microphone, backlight, Bluetooth, USB drives,
  the camera, ROG, and the keybinds' commands from hyprshell.cmd.
- `src/mpris.rs` — what's playing, over D-Bus; `src/art.rs` decodes the
  album art (files, or web addresses fetched once into ~/.cache) and every
  other picture: PNG, JPEG, WebP, and SVG drawn at its shown size.
- `src/tray.rs` — the system tray: this shell is the StatusNotifierWatcher
  apps register with and the host that shows them, and their menus come
  over com.canonical.dbusmenu. `src/icons.rs` finds icons in the icon theme.
- `src/notify.rs` — the notification server (org.freedesktop.Notifications).
- `src/extras.rs` — updates (checkupdates, paru/yay), Mail's unread count,
  timers.
- `src/sys.rs` — the battery, from /sys.
- `src/launcher.rs`, `src/launch_ui.rs` — the launcher: desktop entries,
  pinned apps (theme.json's dockPinned), ranking, launching; and driving
  `ui/launcher.slint`. `src/glyphs.rs` (generated) names the glyphs.
- `src/dock.rs`, `ui/dock.slint` — the dock: Hyprland's windows, which
  pinned app each is, the tiles, and what clicking one does.
- `src/switch_ui.rs`, `ui/switcher.slint` — Alt+Tab; `ui/osd.slint` — the
  volume / brightness popup.
- `src/ground.rs` — the wallpaper and mpvpaper; `src/polkit.rs`,
  `ui/polkit.slint` — the polkit agent and its prompt.
- `src/spring.rs` — common/Spring.qml's springs, for every animation that
  bounces.
- `src/app.rs` — the shell: bars, panels, banners, and what each click does.
- `ui/` — the components: `bar.slint`, `panels.slint`, `toasts.slint`, and
  `widgets.slint` for what they share. `ui/icons.slint` is generated from
  the shell's own glyphs by `node tools/gen-icons.js`, so both shells draw
  the same icons.

Dispatches to Hyprland go as Lua (`hl.dsp.focus({ workspace = 3 })`), as a
Lua-config Hyprland wants them, with the old hyprlang words as the fallback.

One thread runs Slint and Wayland, asleep in poll() on the Wayland
connection, the Hyprland event pipe and Slint's next timer.

## Done

1. The layer-shell platform, and the top bar as modules/bar/Bar.qml lays
   it out: the workspace capsule, the focused app and its underline, the
   title, the media pill (with album art), notifications, the status
   capsule, the clock and power — and the tray, privacy (microphone,
   camera, screen sharing), timers, updates, Mail and drives indicators.
   Look and sizes from theme.json, read again when it changes.
2. Every bar button opens what it opens in the Quickshell shell, on an
   overlay that closes on a click anywhere else or Esc:
   - Window: fullscreen, maximize, float, pin, center, split, move to
     workspace, close, and the six snap layouts.
   - Media: art, title, artist, player, seek bar with times, controls.
   - Notifications: the list with actions, dismiss, Clear, Do not disturb
     (also the bell's right click).
   - Control center: theme (Light / Dark / Auto), Wi-Fi, Bluetooth,
     Airplane, Do not disturb, Performance and Keyboard light (ROG), and
     the volume, brightness and microphone sliders (click the icon to mute).
     The Wi-Fi and Bluetooth tiles' arrows open their lists: join a
     network (asking for its password under it), disconnect, forget (right
     click); pair, connect and disconnect devices, with the pairing code to
     confirm.
   - Calendar: the month, with previous / next.
   - Power: Lock (hyprlock), Suspend, Log out, Restart, Shut down; uptime.
   - Tray menus (submenus, checks, separators), drives (open, mount,
     eject), timers, updates (install in a terminal), privacy.
3. Notifications: the server, banners at the top right (held while the
   pointer is on them, urgent ones until dismissed), the count on the bell,
   and the daemon's history.
4. The launcher (Super): pinned apps in pages, recent files, All apps, and
   search over apps, the shell's commands, files (the daemon's index) and
   the calculator; arrows, Tab, Return, Esc as in Launcher.qml; the user
   and the session menu at the foot. Typing goes through the keymap
   (xkbcommon), with key repeat. It grows out of the bottom of the screen
   with Launcher.qml's springs; the morph out of the dock comes with the
   dock.
5. The dock: Start, the pinned apps (theme.json's dockPinned, matched to
   windows by their patterns), the running apps not pinned, show desktop;
   a pip per window, the focused app tinted and named, a tooltip on hover.
   Click launches, focuses or cycles (minimises in the Windows window
   mode); middle click closes; right click opens its menu (open, move
   left / right, pin, unpin, close), rising from the dock. Hides when set
   to or over a fullscreen window, back from the bottom edge, with the
   QML dock's springs; it only takes the pointer over its pill.
6. The volume / brightness popup (Osd.qml): above the dock for 1.6 s after
   the keys or a scroll on the status capsule change the level, with its
   springs; it never takes the pointer.
7. Alt+Tab (AltTab.qml, SwitcherCard.qml): the windows most recently used
   first, in the chosen scope, grouped if asked, workspace tags when they
   differ; Alt+Tab / Shift+Tab, arrows, Home, End, Return, Esc, Delete or
   the X to close one, click to pick. Letting go of Alt switches (asked of
   Hyprland every 50 ms, as the QML one does); a quick Alt+Tab switches
   without showing it. Live window pictures come later: each tile shows
   the app's glyph for now.
8. The wallpaper (Wallpaper.qml): the chosen picture, cropped to fill, or
   the theme's tinted gradient, drawn once per screen at its own pixel size
   straight into the compositor's buffer (no drawing buffer kept). A live
   wallpaper is mpvpaper, kept running as LiveWallpaper.qml does and ended
   with the shell. The shader styles show as the gradient for now.
9. The polkit agent (PolkitPrompt.qml): the password prompt for whatever
   asks for admin rights. The password goes only to polkit's helper, over
   its socket (polkit 126 on) or to the setuid helper's input.
10. The keybinds: hyprshell.cmd's launcher and panel toggles, volume, mute, microphone,
   brightness, theme, Do not disturb, lock, Mail, updates; `showWifi` and
   `showBluetooth` (the control center open on that list) and
   `openSettings [page]`.
11. Settings: its own app, apps/settings (`hyprshell-settings [pane]`,
   installed by apps/install.sh): the Quickshell Settings rewritten — the
   same nine categories down the side, search over every row, category
   pages, panes as cards with "Show advanced settings", and the same rows
   and wording. Appearance, Wallpaper, Icons, App theming, Bar, Dock,
   Launcher, Alt+Tab, Keybinds (binds.lua written as Keybinds.qml did),
   Fonts, Clipboard, Screenshots, Notifications, Power, Display
   (resolution, rate, scale, VRR), Hyprland, Keyboard, Mouse, Touchpad and
   About. It writes theme.json (every other key kept) and applies the
   Hyprland ones live; the shell runs `hyprshell-settings --apply` at login
   to put them back, as Devices.qml did. Still to come: the full-width
   panels — the Wi-Fi and Bluetooth lists (they open the control center's
   for now), Sound, Focus, the apps that notify, shell updates, face
   unlock, the appearance preview, the wallpaper galleries, the monitor
   map and HDR — and the colour picker (a hex field for now).

Not yet: the per-app mixer, night light.

## Next

3. The dock's window previews, drag to reorder, the left-side and
   taskbar layouts, and the launcher's morph out of it.
4. The overview, Alt+Tab's live window pictures; the launcher's right-click menus (pin, unpin).
5. Lock screen and face unlock.
6. Settings' remaining pages: displays, input, keybinds, fonts, Hyprland.
