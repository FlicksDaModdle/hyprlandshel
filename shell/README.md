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
  kitty/
    kitty.conf             Terminal chrome matched to the mockup's window
    colors-light.conf      The 16 ANSI colours, light
    colors-dark.conf       The 16 ANSI colours, dark
    hyprshell-colors.conf  Which of the two is live (the shell rewrites this)
  run.sh                   Launch by hand from any terminal, with the
                           environment the shell needs
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
      Theming.qml          Follows the theme out into kitty
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
is moved to `<name>.bak.<timestamp>` first, so you can always put it back. Your
`theme.json` lives inside that tree, so it is carried across to the new one —
a reinstall keeps every preference you have set. It
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

Run it in a terminal the first time, so any errors are visible before you
hand the session over to it — but use the installed launcher, not `qs`
directly:

```sh
~/.config/quickshell/hyprshell/run.sh             # start it
~/.config/quickshell/hyprshell/run.sh --restart   # replace a running one
```

`hyprctl reload` also brings the shell back if it isn't running. At login
the shell is started from `hyprland.lua`'s `hyprland.start` hook, because
the config body runs before Hyprland has a Wayland socket for it to connect
to. That hook fires once per session, so the body covers reloads — telling
a reload from that first parse by `WAYLAND_DISPLAY`, which Hyprland leaves
empty in anything it spawns before the socket exists. A `pgrep` guard makes
either path a no-op when the shell is already up.

It forces `QT_QPA_PLATFORM=wayland` and, if the terminal was started outside
the Hyprland session, finds the live instance and exports its signature. Both
are things the shell cannot work without and neither is obvious when missing
— see the troubleshooting section below. Hyprland's own autostart sets them,
so `run.sh` is only for launching by hand.

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
| The themed terminal | `kitty` |
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
Monospaced text — in the shell and in the terminal — is JetBrains Mono.

The pinned apps in `config/Apps.qml` assume `kitty`, `nautilus`, `firefox`,
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
happens to be running, then Settings and show-desktop. Right-click a tile
for its menu: open a new window, re-point the slot at a different
application (which hands off to the launcher as a chooser), or unpin it.
Right-clicking a running app that isn't pinned offers to pin it. The same
menu is on the launcher's pinned tiles. Your list persists in `theme.json`
and Settings → Dock has a reset. Pips under each tile
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

System panes come first, since those are what you open Settings for. Display
lists every connected output separately, each with its own resolution,
refresh rate and scale. Scale is a menu rather than a slider on purpose:
Hyprland refuses any scale that doesn't divide the mode into whole logical
pixels and says so only in its log, so a slider would spend most of its
travel on values that quietly don't apply. Only the ones that work on that
panel are offered — a 2560x1600 laptop screen gets 100/125/133/167/200/250%,
and no 150%, because 1600 ÷ 1.5 isn't a whole number.

Keyboard, Mouse and Touchpad cover what a desktop settings panel is expected
to: layout and key repeat, Num Lock, focus-follows-mouse; pointer speed,
acceleration profile, left-handed buttons, scroll speed, cursor hiding;
tap-to-click, tap-and-drag, drag lock, natural scrolling, disable-while-typing,
two-finger versus corner right-click, tap button map and middle-click
emulation.

System settings persist too, which takes explaining: Hyprland's config is
write-only over IPC and everything it holds comes from `hyprland.lua`, re-read
from scratch on every launch. So anything Settings changes at runtime is gone
next login unless the shell remembers it. `services/Devices.qml` does that —
your input devices and each display's mode and scale live in `theme.json` and
are pushed back once the compositor is up.

Shell panes write `theme.json` as you drag. System panes act on the machine
through PipeWire, UPower, `nmcli`, `bluetoothctl` and — for anything that is
Hyprland's own — `hyprctl eval` against the `hl.*` Lua API. Not `hyprctl
keyword`: a Lua-config Hyprland rejects that outright ("keyword can't work
with non-legacy parsers") *and still exits 0*, so every control built on it
looked like it worked and changed nothing.

**Terminal.** kitty, configured to match the mockup's terminal window: its
16/18/20 padding, its airy 1.62 line height, no client decoration (Hyprland
draws the 12px rounding and the accent focus border), and a flat tab bar that
stays hidden until there's a second tab.

The sixteen ANSI colours are generated rather than picked, laid out on one
shared OKLCH lightness scale — the same method as the shell's own design
tokens — so a green and a blue at the same step read as the same visual
weight. Red sits at the design accent's exact hue and chroma; every other hue
is pulled back to roughly a third less chroma, so the accent stays the only
loud colour on screen. Every normal colour clears WCAG AA against the
background and the brights clear 6.5:1.

Red deliberately does *not* follow your chosen accent. An ANSI colour should
mean what it says, and a blue accent must not make error text blue. The accent
drives the cursor, the selection, links and the bead before the active tab
title instead — which is kitty's nearest equivalent of the focus bead on the
mockup's window title bar.

Changing the theme in Settings recolours kitty windows that are already open.
`services/Theming.qml` rewrites the one-line include in
`~/.config/kitty/hyprshell-colors.conf` and sends kitty `SIGUSR1`, which is
kitty's own config reload — so nothing has to be enabled on kitty's side and
`allow_remote_control` stays off. A kitty that isn't running is simply not
signalled and picks the right palette up when it next starts.

A first install picks the palette from your `theme.json` rather than from a
shipped default, so a dark shell never gets a blinding white terminal. If the
shell was already running when you installed, it notices the file appearing
and reconciles on its own; `install.sh` also nudges it. If you ever want to
force it by hand:

```sh
qs -c hyprshell ipc call shell syncTheming
```

None of it depends on the shell: the palette files are plain kitty includes,
so editing that one line by hand works standalone. A reinstall never resets
your choice — `install.sh` backs up an existing `kitty.conf` but leaves
`hyprshell-colors.conf` alone.

**Keybinds are editable.** Settings → Shell → Keybinds lists every shortcut
the shell owns; click one and press the keys you want. Escape cancels,
Backspace restores the default.

Only shortcuts you have *changed* end up in the generated file, so it can
never shadow a default with a worse version of itself — everything untouched
keeps using `hyprland.lua`'s own definition. Window actions there use native
dispatchers rather than shelling out to `hyprctl`.

The shell never rewrites `hyprland.lua` — that file is hand-written, carries
comments and logic, and regenerating it would throw all of that away the
first time you changed a shortcut. Instead the shell owns
`~/.config/hypr/binds.lua`, which `hyprland.lua` reads at the very end of its
own run, so anything in it replaces the default bound above without touching
it. Delete that file to go back to the defaults. Only the shortcuts you
actually change are stored, so the defaults can move without stranding you on
an old value.

**If no Super shortcut fires at all**, the Windows key probably isn't
sending SUPER on your keyboard — a remapped xkb layout, a Mac keyboard or an
`altwin:` option puts it elsewhere, and then every `SUPER` bind matches
nothing. Settings → Keybinds has a "Windows key sends" row and a probe:
press the key and it reports the modifier it actually produced. Everything
generated, the workspace shortcuts included, follows that setting.

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

## How shell shortcuts reach the shell

A shortcut appends one line to a file:

```sh
echo toggleLauncher >> "$XDG_RUNTIME_DIR/hyprshell.cmd"
```

The shell reads that file — `services/Commands.qml` holds `tail -n 0 -F` on
it — and runs the matching entry from its command table. That table is the
same one `qs ipc call` reaches, so a shortcut and an IPC call cannot drift
into doing different things.

It is deliberately the dullest mechanism available, because three less dull
ones failed here:

- **Global shortcuts** (`hyprland-global-shortcuts-v1`) need a Quickshell
  built with the protocol. On a build without it nothing registers and every
  bind is a silent no-op.
- **`qs ipc call`** has to *find* the shell process first: it hashes the
  config file path, reads `$XDG_RUNTIME_DIR/quickshell/by-path/<hash>` and
  filters what it finds by display connection. On at least one machine that
  returns "No running instances for …/shell.qml" while `qs list --all`
  prints the instance, its pid and that exact config path.
- **By pid or by instance id** — the same call addressed differently, which
  is the route DankMaterialShell's helper takes — did no better there.

Appending to a file has nothing to discover and nothing to match: no binary
on PATH, no socket, no protocol, no instance lookup, and no agreement about
how the shell was started. Both ends only have to see the same
`$XDG_RUNTIME_DIR`, which the keybinds had already proven they do — their
own log was landing in it the whole time.

The shell writes `hyprshell.cmd.status` when it starts reading, naming the
watcher's pid, the shell's pid, and whether Quickshell's own IPC socket for
that pid exists. That makes "is anything listening" a fact to read rather
than something to infer.

## Opening the launcher with Super

Tapping Super on its own opens it. A bare modifier cannot be a keybind, so
this is a *release* bind on the Super key with Super held — it fires when
you let go.

The usual objection is that it would also fire at the end of `SUPER`+`C`.
It does not: Hyprland shadows a release bind whose key took part in a chord
(`shadowBinds`, `src/keybinds/Manager.cpp`), so a combination suppresses the
tap. If it ever misbehaves on your keyboard, delete the two `Super_L` /
`Super_R` binds in `hyprland.lua` and uncomment the `SUPER + SPACE` line
directly beneath them.

Changing the modifier in Settings → Keybinds moves the tap with it: pick Alt
and the tap becomes `Alt_L`, not Alt-held-plus-Windows-key. Rebinding the
launcher to an ordinary chord drops the release flag, which is right — a
chord should fire on the way down.

## When a shortcut does nothing

Hyprland sends a spawned command's output to `/dev/null`, so a failing
shortcut is otherwise completely silent. Each one therefore logs what it
asked for and whether the shell was listening:

```sh
hyprshellctl trace
```

- a line ending `-> 0` — the command was written and the shell was reading
  it. If nothing happened on screen, the shell received it and chose to do
  nothing.
- a line ending `-> 1` — nothing was reading the file. The lines beneath say
  what was there instead.
- **no line at all** — the bind never fired. That is the key or the
  modifier, not the shell: check `hyprctl binds`, and Settings → Keybinds →
  *Test it* reports what your Windows key actually sends.

To check the whole chain:

```sh
hyprshellctl doctor
```

It walks the shell running (printing the last run's log if not, which is
where a config that failed to load says why), a watcher reading the command
file, an actual round trip through it, the trace log, and whether
Quickshell's IPC socket is available at all on this build.

The same tool runs any command by hand, down exactly the path a keybind
takes:

```sh
hyprshellctl list
hyprshellctl toggleLauncher
hyprshellctl openSettings Display
hyprshellctl ipc toggleLauncher   # the Quickshell IPC route instead
```

`install.sh` links it into `~/.local/bin`. It is a diagnostic, not part of
the path a shortcut takes — the binds contain the whole command themselves.

The shell also still registers each shortcut as `hyprshell:<name>` over
`hyprland-global-shortcuts-v1`, so anything else on the session can dispatch
`global, hyprshell:launcher`. Nothing here depends on it.

## Text rendering, and the one file written outside this shell

Settings → Fonts → Text rendering has three controls:

- **Rasteriser.** *Sharp* hands glyphs to the platform's font engine, which
  hints each stem onto the pixel grid. *Smooth* is Qt Quick's default
  distance-field renderer: softer standing still, but it survives arbitrary
  scaling, which Sharp does not. On a display at 125% or 150%, Smooth is the
  better-looking of the two.
- **Subpixel order.** Your panel's stripe order.
- **Hinting.**

The last two are fontconfig's decision, not Qt's, and fontconfig is read by
every application on the session — so they are written to
`~/.config/fontconfig/conf.d/99-hyprshell-text.conf` rather than applied
Qt-only. Each application picks the change up when it next starts, this
shell included. Set the order back to *Leave alone*, or delete that file, to
hand the decision back to fontconfig.

**On OLED, grayscale is usually right.** Subpixel antialiasing assumes three
stripes in a straight row. OLED panels are commonly WRGB or a pentile
diamond, so a renderer that assumes RGB paints colour fringes along every
edge. Grayscale gives up a little apparent sharpness and gets rid of them.

## Why the menus frost rather than blur the desktop

Compositor blur — what the bar, dock and panels get — is a property of a
*layer surface*, and blurs what sits behind that surface on the desktop.
`hyprland.lua` has a `layer_rule` per namespace to switch it on.

A dropdown or the colour picker is drawn inside the Settings window, not as
its own surface, so Hyprland has nothing to blur there: what is behind it is
the window's own rows. `modules/common/BlurBackdrop.qml` blurs those instead,
which is what you would expect to see through a menu that belongs to a
window. Toggle it in Appearance → Frosted menus.

Getting real desktop blur would mean promoting every popup to its own
layer-shell surface, which brings its own positioning, focus and dismissal
problems — a different trade, not a setting.

That file is the only thing in the tree importing `QtQuick.Effects`, and it
is reached through a `Loader` with a URL rather than a direct import, so a Qt
without that module leaves the menus unfrosted instead of stopping the shell
from starting.

## If the shell comes up with no bar, dock or wallpaper

Almost always one of two environment problems, and the log says which.

**`WAYLAND_DISPLAY is present but QT_QPA_PLATFORM is "xcb"`.** The shell is
running on X11. There is no wlr-layer-shell there, so every
`WlrLayershell` attached property fails to build, the components holding
them are never "ready", and the bar, dock, wallpaper and panel layer are
simply not created — you get a pile of `Could not create attached
properties object` and `failed to create variant with object`.

The installed `hyprland.lua` starts the shell with `QT_QPA_PLATFORM=wayland`
on the command line, so this only bites a shell you launch by hand from a
terminal whose profile pins the variable. Either way:

```sh
~/.config/quickshell/hyprshell/run.sh    # sets it for you
grep -rn QT_QPA_PLATFORM ~/.profile ~/.bashrc ~/.zshrc ~/.zshenv /etc/environment
```

**`$HYPRLAND_INSTANCE_SIGNATURE is unset. Cannot connect to hyprland.`**
Quickshell cannot reach the compositor at all, so there are no workspaces,
no window list, no task buttons, and the workspace pills do nothing — they
have nothing to show or switch to. The variable is set by Hyprland for its
own children, so a terminal started outside the session doesn't have it:

```sh
echo $HYPRLAND_INSTANCE_SIGNATURE     # empty is the problem
ls $XDG_RUNTIME_DIR/hypr              # instances that are actually running
```

Start the shell from a terminal inside the Hyprland session, or let `run.sh`
find the live instance and export the signature for you. It refuses, with a
reason, when there is no live instance to find — this is a Hyprland shell,
and the workspaces, window menu, overview and keybinds are all the
compositor's over its IPC. Nothing replaces that on another compositor.

`./shell/install.sh --check` reports both, as the user running it.

## If the lock screen ever traps you

It's a session lock, so by design nothing dismisses it but a successful
password. If it does misbehave, switch to a TTY (`Ctrl+Alt+F2`), log in, and
`pkill qs` — Hyprland drops the lock when the client holding it exits.
