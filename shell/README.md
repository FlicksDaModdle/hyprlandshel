# Hyprshell

A QML/Quickshell implementation of the "Hyprshell" desktop designed in
Claude Design. Every module is wired to real system state rather than the
mockup's demo data — the workspace pills are your workspaces, the bell badge
counts your notifications, and the Wi-Fi tile turns your radio off.

## Layout

```
shell/
  hypr/
    hyprland.lua           Hyprland 0.55+ Lua config (compositor + keybinds)
  quickshell/
    shell.qml              Entry point: every surface, plus the IPC handler
                           Hyprland's keybinds call into
    config/
      Appearance.qml       Design tokens + every persisted preference
                           (theme.json, written live via JsonAdapter)
      Apps.qml             Pinned apps, and the window-class → glyph map the
                           dock, task buttons and overview share
      Commands.qml         Shell commands the launcher can run
      UiState.qml          Which panel is open, OSD state, lock state
    services/
      Audio.qml            PipeWire sink/source volume, mute, device list
      Bluetooth.qml        bluetoothctl: radio, paired devices, scanning
      Brightness.qml       brightnessctl backlight, debounced
      Compositor.qml       Hyprland workspaces, windows and their geometry
      Network.qml          nmcli: Wi-Fi, access points, VPN, IP
      NightLight.qml       hyprsunset / wlsunset colour temperature
      Notifications.qml    The org.freedesktop.Notifications server
      Session.qml          Lock / suspend / reboot / log out / reload
      SysInfo.qml          Host, CPU, memory, disk, uptime, compositor
    modules/
      background/          The desktop ground + its right-click menu
      bar/                 Top bar: workspaces, window menu, tasks, tray,
                           bell, status capsule, clock, power
      common/              Shared primitives (panel chrome, slider, toggle,
                           segmented control, bar button, styled text)
      dock/                The floating dock and its tiles
      icons/               The bespoke 24×24 monoline pack + its renderer
      launcher/            Start menu / Launchpad hybrid
      lock/                Session lock with PAM authentication
      notifications/       Banner toasts
      osd/                 Volume / mic / brightness readout
      overview/            Workspace grid with real window thumbnails
      panels/              Control center, notification center, calendar,
                           power menu, desktop context menu, and the overlay
                           surface that hosts them
      settings/            The Settings window and its row renderer
```

## Install

```sh
./shell/install.sh --check     # report what's present, change nothing
./shell/install.sh             # install, backing up anything it replaces
```

The installer never deletes: an existing `hyprland.lua` or `quickshell/hyprshell`
is moved to `<name>.bak.<timestamp>` first, so you can always put it back. It
also refuses to run if Hyprland or Quickshell are missing, and prints the right
package line for your distribution for everything else.

If you already have a Hyprland config you'd rather keep, use:

```sh
./shell/install.sh --shell-only
```

which installs only the Quickshell tree and prints the handful of `exec-once`,
`bind` and `layerrule` lines to paste into your own config.

By hand, it's just two copies:

```sh
mkdir -p ~/.config/hypr ~/.config/quickshell
cp shell/hypr/hyprland.lua ~/.config/hypr/hyprland.lua
cp -r shell/quickshell ~/.config/quickshell/hyprshell
```

`hyprland.lua` autostarts the shell (`qs -c hyprshell`) and routes its
keybinds into it over Quickshell's IPC socket, so the directory name matters.

Run `qs -c hyprshell` in a terminal the first time, so any errors are visible
before you hand the session over to it.

> **If you already have `~/.config/hypr/hyprland.conf`**, move it aside before
> logging out. Hyprland loads one config file, and which one wins with both a
> `.conf` and a `.lua` present is not worth leaving to chance.

### Requirements

Hard requirements: **Hyprland ≥ 0.55** (Lua config) and **Quickshell** built
with the PipeWire, UPower, PAM and StatusNotifier features — the defaults in
every packaged build.

Everything else degrades rather than breaking. A machine with no backlight
hides the brightness controls; with no `hyprsunset` the Night light tile says
so; with no `nmcli` the Wi-Fi readout goes quiet.

| Used for | Needs |
| --- | --- |
| Wi-Fi tile, network pane | `nmcli` (NetworkManager) |
| Bluetooth tile and pane | `bluetoothctl` (BlueZ) |
| Brightness slider and keys | `brightnessctl` |
| Night light | `hyprsunset` or `wlsunset` |
| Screenshots | `grim`, `slurp`, `wl-clipboard` |
| Power profiles, Game mode | `power-profiles-daemon` |
| Suspend / reboot / power off | `systemd` (`loginctl`) |
| Idle → lock | `hypridle` |
| Media keys | `playerctl` |
| Wallpaper picker | `zenity` or `kdialog` |

Text is Inter throughout; install an `inter-font` / `fonts-inter` package.

The pinned apps in `config/Apps.qml` assume `foot`, `nautilus`, `firefox`,
`neovide`, `obsidian` and `ncmpcpp`, with `match` patterns covering the
common alternatives. Edit `exec` and `match` to what you actually run —
`match` is tested against each window's Hyprland class.

## What each part does

**Top bar.** Workspace pills that expand to their number when focused or
hovered and collapse to a bead otherwise — filled when the workspace has
windows, hollow when it's empty. The focused app's name with an accent
underline, a Window menu of real compositor actions (fullscreen, float, pin,
move, snap layouts) and the live window title. Optionally a task list.
On the right: the StatusNotifier tray, the notification bell with its count,
a status capsule showing SSID / volume / battery that opens the control
center, a clock that opens the calendar, and the power button.

**Dock.** Start and overview, pinned apps, then any unpinned app that
happens to be running, then Settings and show-desktop. Pips under each tile
count that app's windows and the focused app's first pip stretches into a
bar. Left click focuses or launches and cycles through an app's windows,
right click always opens a new instance, middle click closes one. Bottom or
left edge, with optional auto-hide.

**Launcher.** Opens on a bare Super tap. The pinned grid is paginated; typing
searches every installed `.desktop` entry plus the shell's own commands, with
prefix matches ranked first; arrow keys and Return drive it from the
keyboard; anything with no match runs as a shell command. "Recommended" is
your real recently-used files.

**Control center.** Account header with the theme cycler, six live tiles
(Wi-Fi, Bluetooth, Night light, Airplane, Capture, Game mode) and volume,
brightness and microphone sliders. Wi-Fi and Bluetooth drill down into a real
list — pick a network or a paired device from the panel.

**Notifications.** A full notification server: banners under the bar, a
center behind the bell, the sender's own action buttons, do-not-disturb that
silences banners while still filing everything, and grouping by app or time.

**Overview.** Workspace cards drawn from real window geometry, so a card is a
recognisable picture of that workspace. Click a window to focus it, middle
click to close it, number keys to jump, Escape to dismiss.

**Settings.** Draws its own title bar — bead, icon, title, and the mockup's
three window buttons — on a shell surface rather than taking a toplevel's.
As a real toplevel it got whatever decoration Qt drew, which on Wayland is a
client-side title bar that looks nothing like the design and is only
suppressed by an environment variable set before Qt starts. The trade is that
it floats above the desktop instead of tiling with real windows; move it by
its title bar. Minimise hides it with its place and pane kept, so reopening
from the dock or `super + ,` restores exactly where you were.

Shell panes write `theme.json` as you drag; device panes act on the system
through PipeWire, UPower, `nmcli`, `bluetoothctl` and `hyprctl keyword`.

**Lock screen.** A Wayland session-lock surface authenticating against PAM.
The compositor guarantees nothing behind it is visible and nothing else takes
input while it's up.

## Preferences

Everything the Settings window changes is persisted to
`~/.config/quickshell/hyprshell/theme.json`, written the moment you change it
and watched for external edits — editing the file by hand repaints the shell
without a reload.

## Two things the mockup has that this doesn't

**Per-app menu bars.** The mockup's bar carries File / Edit / View / Window
menus for the focused app. That needs a global menu protocol, and Wayland has
none — no client on Hyprland exports its menus, so those would be buttons
that can't do anything. The bar keeps the affordance and fills it with the
compositor's own window actions, which is the part that can actually run.

**Interface scale.** The mockup has a master scale slider for the whole
shell. Doing that properly means a scale transform on every layer surface
plus recomputing each surface's size, which fights layer-shell's own sizing;
a slider that moved some numbers and not the text would be worse than not
having one. Bar height, dock size and corner rounding each scale on their
own, which covers most of what it was for.

## If the lock screen ever traps you

It's a session lock, so by design nothing dismisses it but a successful
password. If it does misbehave, switch to a TTY (`Ctrl+Alt+F2`), log in, and
`pkill qs` — Hyprland drops the lock when the client holding it exits.
