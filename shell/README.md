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
      Agent.qml            BlueZ + NM agents (hyprshell-daemon's)
      Audio.qml            PipeWire sink/source volume, mute, device list
      Bluetooth.qml        Devices, pairing and its prompts (bluetoothctl fallback)
      Brightness.qml       brightnessctl backlight, debounced
      Compositor.qml       Hyprland workspaces, windows and their geometry
      Cursor.qml           The accent-coloured pointer (CursorShapes.js draws it)
      Kvantum.qml          Generates a Kvantum widget theme from the palette
      Network.qml          Wi-Fi, university sign-in, saved networks (daemon; nmcli without)
      NightLight.qml       night light: built in (daemon), or hyprsunset / wlsunset
      Notifications.qml    The org.freedesktop.Notifications server
      Session.qml          Lock / suspend / reboot / log out / reload
      SysInfo.qml          Host, CPU, memory, disk, uptime, compositor
      Theming.qml          Follows the theme out into kitty, kdeglobals
                           and fontconfig
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
| Pairing prompts, Wi-Fi password requests | `cargo` (hyprshell-daemon) |
| Brightness slider and keys | `brightnessctl` |
| Night light | `cargo` (built in), or `hyprsunset` / `wlsunset` |
| Screenshots | `grim`, `slurp`, `wl-clipboard` |
| Power profiles, Game mode | `power-profiles-daemon` |
| Suspend / reboot / power off | `systemd` (`loginctl`) |
| Idle → lock | `cargo` (built in), or `hypridle` |
| Media keys | `playerctl` |
| Wallpaper picker | `zenity` or `kdialog` |
| Live wallpapers | `mpvpaper` (AUR), `ffmpeg` for thumbnails |

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

Right-clicking a tray icon opens the app's menu drawn by the shell — the
same surface, rows and accent hover as the shell's own menus, whatever
toolkit the app uses — with its submenus beside it, its checkboxes and
radio items, its disabled entries greyed, and arrows / Enter / Escape.

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

The shell's own look is four panes rather than one long one: Appearance
(theme, accent, translucency, corners, motion, and how Settings itself is
shown), Wallpaper (the tint, an image, and live wallpapers), Icons (every
icon size in one list) and App theming (KDE colours and Kvantum).

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

The shell reads that file — `hyprshell-daemon` follows it with inotify and
hands each line to `services/Commands.qml` (a shell loop around `tail -n 0
-F` does it where the daemon isn't built) — and runs the matching entry
from its command table. That table is the
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

Tapping Super on its own opens it. A bare modifier cannot be an ordinary
bind, so this is a *release* bind on the Super key — it fires when you let
go.

It is written as the bare key, `hl.bind("Super_L", …, { release = true })`,
not `"SUPER + Super_L"`. On current Hyprland the two are identical: Super_L
is in `SIDED_MODIFIER_NAMES`, so naming it sets the SUPER bit in the mask as
well as binding the key (`CBind::make`, `src/keybinds/Bind.cpp`). They differ
on a build without that list, where the `SUPER +` form needs the modifier to
already be set at the instant Super itself is pressed — the bare key does not
care either way.

It does not fire at the end of `SUPER`+`C`: Hyprland shadows a release bind
whose key took part in a chord (`shadowBinds`, same file).

`SUPER` + `SPACE` is still bound as well, so there is always a way in. Delete
that line in `hyprland.lua` once the tap is working for you.

If tapping Super does nothing, `hyprshellctl doctor` step 5 says whether
Hyprland took the bind at all, which splits the two possible faults: the
build rejected the key name (`hyprctl configerrors` will say so), or the bind
is registered and not matching.

Changing the modifier in Settings → Keybinds moves the tap: pick Alt and it
becomes `Alt_L`. Rebinding the launcher to an ordinary chord drops the
release flag, which is right — a chord should fire on the way down.

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

## Dispatching to Hyprland from the shell

Under a Lua config, `hyprctl dispatch X` is not a dispatcher call — it is
evaluated as `return hl.dispatch(X)` (`dispatchRequest`, `src/ipc/s1/
Commands.cpp`). So the old hyprlang wording is Lua:

```
dispatch workspace 1      ->  return hl.dispatch(workspace 1)   -- syntax error
```

which the compositor rejects with a line in the shell's log and nothing
else. That is what made the workspace pills look dead: the click worked, the
request went out, and Hyprland threw it away.

Everything the shell dispatches is a Lua call now, and so is everything in
`hyprland.lua`:

```lua
hl.dsp.focus({ workspace = 3 })
hl.dsp.focus({ window = "address:0x55d1c0" })
hl.dsp.window.move({ workspace = 4, follow = false, window = "address:…" })
hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" })
```

Note that switching workspace is `hl.dsp.focus`. There is a `workspace`
subtable, but it is for renaming and moving workspaces, not entering them.

## The Settings window, floating or tiled

Settings → Appearance → Window mode switches between two kinds of window
that show the same panes:

- **Floating** (the default) is a layer-shell surface: the title bar you see
  is the shell's own, it sits above the desktop, and it can be dragged
  between monitors.
- **Tiled** is an ordinary toplevel, so Hyprland gives it a slot in the
  layout and your window binds and rules apply to it like any other
  application.

Both mount `SettingsFrame.qml`, which is the chrome — title bar, sidebar,
scroll area, geometry — and reads everything it shows from `Settings.qml`.
The host provides `width`, `height`, `tiled`, `maximised`, `normalWidth`,
`normalHeight`, `workTop`, `workBottom` and `moveTo(x, y)`; tiled, the
compositor owns the geometry and the last few are constants nothing acts on.

Tiled mode works because the shell sets `QT_WAYLAND_DISABLE_WINDOWDECORATION`
for the session, so Qt draws no title bar of its own and the chrome is still
the designed one. The window carries Quickshell's app id, `org.quickshell`,
which is what a Hyprland window rule would match on.

## The file manager

`Super + E`. It is not part of this shell: it is a separate application,
`hyprshell-files`, in `../files`. The shell only launches it.

That is deliberate. A file manager is an ordinary window — the compositor
should tile it, focus it and apply window rules to it like anything else,
and a drag out of it should reach other applications. A shell surface is
none of those things, and a layer-shell surface is not a drag source at all.
So the window moved out, keeping the same QML, the same icon pack and the
same treatment of a selected thing.

It follows this shell's `theme.json`, so it matches the desktop without
being part of it, and keeps its own settings in
`~/.config/hyprshell-files/`. See `../files/README.md`.

`Super + Shift + E` still opens whatever `fileManager` names in
`hyprland.lua`, if you want a second opinion.

## Wi-Fi and Bluetooth

Settings → Network and Settings → Bluetooth are laid out like KDE's and
Windows': the switch and what is connected at the top, then one list, each
entry opening in place to what it needs.

Both lean on an agent that does what KDE's background services do and a
bare Hyprland session lacks. It is part of `hyprshell-daemon` (`rust/`,
below):

- **A Bluetooth pairing agent.** Phones, most keyboards and many newer
  headphones ask a question while pairing — "does this code match?",
  "type this code on the keyboard". With nobody to answer, pairing fails
  with `org.bluez.Error.AuthenticationFailed`. The agent puts the question
  at the top of Settings → Bluetooth (opening it if need be) and answers
  with what you choose. It also drives BlueZ directly, so the device list
  is live rather than polled.
- **A NetworkManager secret agent.** When NetworkManager needs a password
  it has not got — a saved one that stopped working, or a network set up
  in KDE, which keeps passwords per user in KWallet — it asks the agents in
  the session. Without one, connecting fails with "Secrets were required,
  but not provided". The question comes up in Settings → Network, and the
  answer can be saved into the profile so it is not asked again.

University and office networks (WPA-Enterprise / 802.1X, eduroam) take the
options KDE's dialog has, under **More options**: the sign-in method (PEAP,
TTLS, PWD), the inner authentication (MSCHAPv2, PAP, GTC, …), which
certificate to trust, a domain to check the server against, and an
anonymous identity. A username and password that are right will still be
refused if one of these differs from what the network expects; the
university's IT pages list them. A saved network shows what it signs in
with, and **Change sign-in** edits it in place.

Without it, Bluetooth falls back to `bluetoothctl`, which pairs what asks no
questions, and NetworkManager's password requests go unanswered.

## Sound

Settings → Sound opens on the output and microphone in use, each with its
level, mute and a live meter, and four tabs below:

- **Output** — every output with its own level and mute in its row, and
  "Use" to switch. Click any one to open it in full: volume, balance, fade
  (surround), each channel on its own, a live meter, test sounds for each
  speaker, the connector (speakers or headphones), the card's mode
  (Bluetooth music/headset and codec, HDMI layouts, off), a **delay** to put
  sound back in step with the picture (Bluetooth), its format, sample rate,
  latency and codec, and a name and place in the list of your choosing.
  Then the **equalizer**: ten bands and a preamp, presets (bass boost,
  vocal, laptop speakers, …), heard as you drag.
- **Input** — the same for microphones, plus **noise suppression** (RNNoise;
  needs `noise-suppression-for-voice`) with its strictness, and **listen to
  this microphone** to hear yourself through headphones.
- **Apps** — every app playing, with its level, mute, balance and the
  output it plays through; every app recording, with its level and the
  microphone it listens to.
- **Options** — volume key step, a maximum volume (a hearing limit below
  100%, software boost up to 150%), a tick on key presses, switching to
  Bluetooth/USB devices as they connect, and "Restart sound" for when it
  has stopped altogether.

The equalizer and noise suppression are PipeWire filter-chains the shell
runs itself (`services/AudioFx.qml`): a virtual output or microphone that
becomes the default and passes the sound on to the real device. They are
loaded into `hyprshell-daemon` (which opens libpipewire when it runs, so
building it needs no PipeWire headers), or without the daemon each runs as
`pipewire -c` on a file in `~/.cache/hyprshell`. Nothing is written into
PipeWire's own configuration, and quitting the shell takes them away.
Connectors, modes, delays and moving apps use `pactl` (pipewire-pulse); the
live meters need Quickshell 0.3.1 (0.3.0's can crash the shell, so they
stay off there).

## ASUS ROG laptops

On an ASUS laptop with asusctl's service running (`systemctl enable --now
asusd`), Settings gains a **Laptop** pane and the control center two tiles:

- **Performance** — Quiet, Balanced or Performance: the firmware's fan and
  power limits. The tile moves one along per press.
- **Charge limit** — charging stops at 20–100%; 80% keeps a mostly-plugged-in
  battery healthy for years. "Charge to full once" lifts it for one charge.
- **Keyboard light** — brightness (also a tile), the effect (Static,
  Breathe, Rainbow …), and optionally the colour following the shell's
  accent: a new swatch, the wallpaper's colour, light or dark.
- **GPU mode** — Integrated (the NVIDIA GPU off, longest battery), Hybrid,
  or Ultimate (the NVIDIA GPU driving the screen). asusd applies it at the
  next restart; the pane says what is pending.
- **Panel and firmware** — panel overdrive, MiniLED dimming, boot sound,
  low-power standby: whichever this model has.

`hyprshell-daemon` reads all of it from asusd over D-Bus and finds what the
model offers rather than assuming, so a part a laptop lacks is simply not
shown. Without asusd the pane and tiles do not appear.

## Accent from the wallpaper

Off unless chosen: Settings → Appearance → "Accent from wallpaper" takes the
most vivid colour in the picture on the desktop — in a darker shade for the
light theme and a lighter one for the dark theme — and follows the wallpaper
when it changes (a live wallpaper is read from its gallery thumbnail).
`hyprshell-daemon` does the reading, in a few milliseconds for most
pictures and ~50 ms for a 4K JPEG. Your own accent is kept underneath: turn
the switch off, or pick a swatch, and it is back. A picture with no real
colour in it (black and white, grey), or no picture at all (the gradient,
the contour map), leaves your own accent in place.

## Files in the launcher

Typing in the launcher also finds files and folders in your home folder by
name — fuzzy, so "taxret" finds `tax-return-2025.pdf` — listed after the
apps and commands; Enter opens a file in its default app and a folder in
Files. A space or a `/` matches across the whole path ("taxes 2025").
Hidden folders, `node_modules`, Python environments and folders marked as
caches (Cargo's `target/`) are left out.

`hyprshell-daemon` indexes when the launcher opens (about a second for
150,000 files), keeps up with changes through inotify, and lets the index
go after ten minutes without a search, so it holds no memory while unused.
Settings → Launcher → "Search files" turns it off.

## USB drives and SD cards

Plug one in and it is mounted (Settings in its panel: "Open on plug-in")
and announced, with **Open** (in Files) and **Eject** on the notification.
While one is connected a drive button sits in the bar; its panel lists each
drive and its filesystems, Open, and Eject — which unmounts everything on
the drive and then powers it off, so it is safe to pull. If something still
has a file open on it, it says so instead of failing quietly.
`hyprshell-daemon` does it through UDisks2; internal disks are never shown.

## Notification history

The notification center has a **History** beside Notifications: everything
shown, still there after it is dismissed, by day, with a search over the
app, title and text. Clear asks once more before it forgets. A notification
its sender marks transient (a volume change) is never kept, and markup is
kept as the text it reads as.

`hyprshell-daemon` keeps it in `~/.local/state/hyprshell/notifications.json`,
readable by you alone, for 1, 7 or 30 days (Settings → Notifications), at
most 1000. Turning it off forgets everything.

## Screenshots, recordings and text from the screen

**Print** opens the capture toolbar: a picture or a video, of a region, a
window (the windows on screen are offered to snap to), the screen or every
screen, with a delay and the pointer, sound for a video (the desktop's or
the microphone), and **Text**, which reads a region's words onto the
clipboard (tesseract). **Super+Shift+S** grabs a region straight away,
**Shift+Print** the screen, and **Super+Shift+Print** starts or stops a
recording; the bar shows a red timer while one runs — click it to stop.

Shots go to `~/Pictures/Screenshots` and the clipboard, and the
notification (with the shot in it) has **Edit**: pen, arrow, box,
highlighter, pixelate for what should not be shared, text, crop, undo,
Copy and Save. Choose "Edit after" in the toolbar to go straight there.
Recordings (wf-recorder) go to `~/Videos/Recordings`. All of it is in
Settings → Keybinds to rebind, and in the launcher.

## Updates

The bar shows a package button with a count while updates are waiting;
its panel lists them — official repositories, AUR and Flatpak — with
versions and download sizes, says when a new kernel is among them (or when
the running one has already been replaced and a restart is due), and
**Update now** runs the update in a terminal (`paru -Syu` or `yay -Syu`
when installed, so the AUR comes too, else `sudo pacman -Syu`; then
`flatpak update`) and checks again when it closes. Checking uses
`checkupdates` from pacman-contrib, which syncs a private copy of the
databases — nothing on the system changes and no password is asked.
Settings → About → Updates: how often, the notification, the bar button.

## Microphone, camera and screen in use

While anything records the microphone, uses the camera or captures the
screen, the bar shows an accent badge for each; click it to see which apps
(and mute the microphone from there). The microphone and PipeWire cameras
are read from PipeWire — not counting visualisers that record the speakers,
or the shell's own meters. Apps that open the camera directly, as most
browsers do, are found by `hyprshell-daemon` watching `/dev/video*`. Screen
sharing comes from Hyprland's own screencast event and the portal's
PipeWire streams.

## Focus: quiet hours and per-app rules

Settings → Notifications → Focus sets quiet hours — Do not disturb on a
schedule, as many as you like, each with its days (a window past midnight
belongs to the day it starts). The bell turns the current window off until
it ends; pressed again, it comes back. Each app that has sent anything can
be **Always** (a banner even while quiet), **Normal**, **Silent** (no
banner, still in the center) or **Mute** (only the history keeps it).
Urgent notifications — alarms, a battery about to run out — still show
while quiet unless "Let urgent ones through" is off.

## Timers, pomodoro and alarms

The bar shows a countdown while a timer or the pomodoro runs; click it for
the panel (or "Timers" in the launcher). Start a timer from a preset, any
length (`45`, `1h30`, `90s`, `2:30`, with `, a name` after), or straight
from the launcher by typing `timer 10m` or `timer 1h, laundry`. The pomodoro
runs focus and breaks on repeat with the lengths you choose and counts
today's sessions. Alarms ring at a time, once or on chosen days, with
Snooze; they ring through Do not disturb.

Everything is kept in `~/.local/state/hyprshell/timers.json` with absolute
end times, so a running timer survives the shell restarting, and one that
ran out meanwhile rings when the shell is back. `hyprshellctl timer 5m`
and `hyprshellctl pomodoro` work from scripts and keybinds.

## Night light

Settings → Display → Night light: **Off**, **On**, **Sunset to sunrise** or
**Set times**, and how warm (1900–6500 K). `hyprshell-daemon` sets the
screens' colour through the compositor's gamma control, so there is nothing
to install and no program left running; changes fade, and a display plugged
in later is warmed too. Sunset and sunrise are worked out on the machine for
your time zone's city, or for a latitude/longitude you give — nothing is
looked up online. The control center's tile switches it; on a schedule, the
tile's choice lasts until the next scheduled change.

If hyprsunset or wlsunset is already running it is stopped (two programs
cannot both own the screen's colours). Where the compositor will not hand
the colours over, the shell falls back to hyprsunset, if installed.

## Calculator in the launcher

Type a sum or a conversion in the launcher and the answer is the first
result; Enter copies the number.

    12*7.5          2^10 / 3        sqrt(2)*pi      (4+5)%4
    15% of 80       80 + 15%        5 km in miles   72f in c
    3 GB in MiB     90 min in h     2 cups in ml    5 km + 300 m
    60 mph in km/h  1.5 kWh in J    sin(90 deg)

Lengths, weights, times, data sizes (kB/MB/GB and KiB/MiB/GiB), speeds,
volumes, energy, angles and temperatures. Anything that is not a
calculation — "firefox", a bare "2048" — is left to the app search.
`hyprshell-daemon` works it out (`rust/daemon/src/calc.rs`).

## Clipboard history

**Super+Shift+V** (or "Clipboard history" in the launcher) lists what was
copied, newest first — text and images. Click one, or arrows and Enter, and
it is on the clipboard again; Delete forgets one, **Clear** forgets all.

`hyprshell-daemon` keeps it, from the compositor's clipboard-manager
protocol (wlr-data-control), in `$XDG_RUNTIME_DIR` — memory, this login
only, readable by you alone — so a shell reload keeps it and logging out
ends it. What a password manager marks as secret
(`x-kde-passwordManagerHint`, which KeePassXC and others set) is never
kept. When the program you copied from closes, Wayland's clipboard would go
empty with it; the newest entry is offered instead, so the paste still
works. Settings → Clipboard turns it off (which forgets everything) and
sets how many entries it keeps.

## Battery and performance

**Battery saver** (Settings → Power) switches off the desktop's costliest
effects on battery, below a charge you choose, always, or never: Hyprland's
blur, window shadows and see-through inactive windows by default, and
optionally window animations, the shell's own motion, and the power profile
(set to Power saver and put back afterwards). Hyprland's own values are
read before anything changes and are what it gets back.

Beyond that, the shell only works when someone can see the result:

- the network follows NetworkManager's events (`nmcli monitor`) instead
  of polling, and only scans for Wi-Fi while a Wi-Fi list is on screen —
  it used to trigger a scan twice a minute all day
- machine facts, brightness, night light and display checks are read
  rarely, or only while the page showing them is open
- Settings and the Icon Maker are built when opened and let go after,
  and Settings' rows stop recomputing while it is closed
- the bar's music bars step at 12 frames a second instead of redrawing
  the bar at the display's refresh rate for as long as music plays
- the screen corners step aside for fullscreen windows, and fullscreen
  games can be scanned straight out to the display
- the animated wallpapers hold still behind windows, on battery and under Battery saver

The task manager's smooth graphs step once a sample on battery, and it
samples less often while in the background.

**Fewer processes.** The shell talks to Hyprland over its socket
(`services/HyprIpc.qml`) instead of starting `hyprctl` on every window event
and settings change, and reads `/proc` itself for Settings → About.

**hyprshell-daemon** (`rust/daemon`, built by install.sh when `cargo` is
installed) supplies the rest without polling. It reads and drives
NetworkManager over D-Bus and is told when anything changes — joining a
network, a university sign-in, forgetting one: the password goes to
NetworkManager directly, never onto a command line, where nmcli has to put
it — the backlight from sysfs with the
kernel's change events (set through logind), audio devices through
PulseAudio's own protocol (cards, modes, connectors, which app plays where),
and whether a night-light program runs, from `/proc`. It is also the
Bluetooth backend and pairing agent and the Wi-Fi password agent, runs the
equalizer and noise
suppression, keeps the clipboard history, finds files for the launcher and (when
asked) takes the accent from the wallpaper, and on ASUS laptops talks to
asusd. It talks to the shell in JSON lines,
uses about 8 MB, and each part falls
back on its own: without the daemon, or where a part can't reach what it
reads, the shell goes back to `nmcli`, `brightnessctl`, `pactl` and `pgrep`.

## Passwords for administrator actions

The shell is the session's polkit agent: when something asks to act as
administrator — `pkexec`, a system service started from the task manager,
a mount — the password prompt comes up on the focused screen. If another
agent (hyprpolkitagent, polkit-gnome) is already running it keeps the job,
and on a Quickshell built without polkit support the prompt simply never
loads.

## Apps that start at login

Hyprland doesn't run `~/.config/autostart` or `/etc/xdg/autostart` the way
GNOME and KDE do, so `hyprland.lua` starts systemd's
`xdg-desktop-autostart.target`, which does. The task manager's
*Startup apps* view turns each one on or off.

## The pointer

Settings → Appearance → Pointer: the shell draws its own cursor set (arrow,
hand, text beam, spinners, resize arrows, … — `services/CursorShapes.js`)
filled with the accent colour and outlined so it stays visible on anything,
and rebuilds it whenever the accent or the theme changes. Fill (accent,
white, black), outline and size are settings; **System** goes back to a
cursor theme of your choosing (Adwaita by default).

`hyprshell-cursors` turns the drawing into `~/.local/share/icons/Hyprshell`.
install.sh builds it from `rust/cursors` (drawn with resvg; needs cargo).
It holds two themes at once:

- **hyprcursor** — the SVGs themselves, which Hyprland draws at whatever size
  is asked, so the pointer is sharp at any scale. Used for Hyprland's own
  pointer and by every app that asks Hyprland for a cursor by name
  (cursor-shape-v1: most native Wayland apps).
- **XCursor** — rendered at the size you chose, the sizes a scaled display
  multiplies it to, and the usual 24–96 px, for anything that loads a cursor
  theme itself: XWayland apps (MuseScore, Steam, games), GTK 3, and Qt for
  any shape it draws on its own. Exact sizes matter: an app asking for 28
  from a theme that only has 24 and 32 gets 32.

It is put in use with `hyprctl setcursor`, GTK's `cursor-theme` setting, and
`~/.icons/default/index.theme` — the fallback for apps that name no theme —
which is only written when it is not there already or is the shell's own.

**One size everywhere.** An app that draws its own pointer takes its size
from `XCURSOR_SIZE`, not from Hyprland, so if the two disagree the pointer
changes size as it moves between parts of a window — the app's own cursor
in one place, Hyprland's in the next. The theme and size are therefore
also written to `~/.local/state/hyprshell/session.env` and pushed to:
Hyprland's environment (`hl.env`, and `hyprland.lua` reads the file at
login), systemd and D-Bus activation, XWayland's resources (`xrdb`),
KDE's `kcminputrc` for Qt apps on KDE's platform theme, and every app
started from the launcher, dock or app menu. Apps already running keep the
size they started with; restart one after changing it.

## Screen corners

Settings → Appearance → **Screen corners** lays pure black, rounded corners
over the display's own, for a laptop panel whose corners are square inside a
bezel that is not. The radius (2–64 px), which of the four corners, and
whether only the built-in panel (`eDP`/`LVDS`/`DSI`) or every display gets
them are all settings. They are four tiny surfaces on the overlay layer, one
per corner, so they sit over fullscreen games and video and ignore the bar's
reserved space. They are bezel to the pointer as well: it cannot rest in the
black. Wayland gives a program no way to fence the pointer in, so a corner
takes input only on its black part, and when the cursor comes into it the
shell moves it back to the edge of the curve with Hyprland's
`hl.dsp.cursor.move` — it meets the curve as a wall. Just inside the curve,
hover and clicks reach whatever is there as usual. The lock screen draws the
same corners itself, since it is above every layer.

## Animated wallpapers

Settings → Wallpaper → **Animated** draws the desktop with the shell's own
shaders — no video, no extra program — in seven styles, each shown as a
small live preview to pick from:

- **Topographic** — a contour map of a made-up terrain whose lines flow up
  the slopes (the Wallpaper Engine look), over terrain that slowly wanders,
  or both, with an optional glow
- **Aurora** — curtains of light over a night sky
- **Blobs** — soft pools of colour drifting over each other
- **Waves** — many fine lines rolling across the screen
- **Starfield** — layers of drifting, twinkling stars over a nebula
- **Synthwave** — a striped sun over a neon grid rolling towards you
- **Cells** — a shifting mosaic with glowing edges

Colours come from a palette: the theme's own (it follows light and dark and
the accent), one of ten presets (Aurora, Sunset, Ocean, Forest, Neon, Ember,
Rosé, Mono, Paper, Mint), or five of your own. Each style also has size,
density (curtains, pools, lines, stars, grid, cells), glow, brightness, a
variation to step through, and speed; the map keeps its own detailed
settings (hills, roughness, flow, contour count and width, index lines,
shading in flat, smooth or bands). Monitors side by side show one
continuous picture.

They move at 15, 30 or 60 frames a second and hold still while a window
covers the screen, under Battery saver, and on battery unless "Keep moving
on battery" is on. Still, they cost nothing.

The shaders are compiled with Qt's `qsb`; after changing one:

```
cd modules/background/shaders
qsb --glsl "100 es,120,150,300 es" --hlsl 50 --msl 12 -o waves.frag.qsb waves.frag
```

(`qsb` is in `qt6-shadertools`, under `/usr/lib/qt6/bin`.)

## Live wallpapers

Settings → Wallpaper starts with one choice — **Gradient**, **Animated**,
**Image** or **Live** — and shows only what that one needs; switching away and back
brings the last image or live wallpaper with it. Live plays a video as the
wallpaper, with [mpvpaper](https://github.com/GhostNaN/mpvpaper)
(`paru -S mpvpaper`): mpv on a layer surface, decoding on the graphics
card's own video engine, so a looping clip costs a few percent of one core
and hardly touches the GPU — a video wallpaper is cheap in a way a scene
drawn every frame is not.

The videos are the ones in `~/Videos/Wallpapers` (and a level of
subfolders), plus any folder or single file added under **Folders**. mp4,
webm, mkv, mov, avi, ogv and gif all play. Wallpaper Engine's video
wallpapers are plain video files, so adding
`…/steamapps/workshop/content/431960` lists those too — its scene and web
wallpapers are not videos and do not appear. The gallery shows a still of
each, taken with ffmpeg and kept in `~/.cache/hyprshell/live/thumbs`.

It is mpvpaper's own surface, one layer above the shell's ground, which
stays underneath — what you see while a video loads, and what comes back if
it stops. It takes no input, so right-clicking the desktop still opens the
shell's menu. The shell restarts it if it dies after running a while, and
leaves it stopped with what it said if it dies straight away (a file it
cannot play); that message is on the Wallpaper row.

With more than one screen, **Screens** chooses the same video on each — one
mpvpaper decoding once and drawing to every screen, a monitor plugged in
later included — or each its own: pick the screen under "Picking for", then
its video.

Under **Playback**: scaling (fill, fit or stretch), sound and its volume
(off by default), rotating to another video on a timer in order or
shuffled, and pausing. **Pause behind windows** stops mpvpaper outright
(SIGSTOP, costing nothing) while every screen is covered — by a tiled,
maximised or fullscreen window, or with "Any window", any at all — and
continues it the moment one is not; **Pause on battery** holds it while
unplugged.

From a script: `qs -c hyprshell ipc call shell setLiveWallpaper <video>`
(an empty argument turns it off), and `nextLiveWallpaper` for the next one —
bind it to a key.

## Theming KDE applications

Settings → App theming → Theme KDE applications writes this theme's palette
into `~/.config/kdeglobals`, so Dolphin, Ark, Okular and the rest take their
colours from the same place the shell does: the same charcoal, the same
accent on a selected row. Running apps re-read that file, so it lands
without restarting anything.

Be clear about what it does and does not do. It is **colours only**. It
cannot move Dolphin's toolbar, change its icons, or give it the shell's
rounded chrome — a KDE app themed this way reads as the same *palette* with
KDE's own layout. To change how the widgets themselves are *drawn*, turn on
the Kvantum theme below as well; the two are meant to be used together.

`kdeglobals` is not this shell's file — it is where KDE keeps single-click,
the icon theme and the rest — so the groups the shell owns (`[Colors:*]`,
`[WM]`, and two keys in `[General]`) are replaced and every other group is
carried across untouched. The setting is off by default, because writing
outside the shell's own config should be something you ask for.

## The Kvantum widget theme

Colours in `kdeglobals` only repaint what KDE's own style already draws.
Kvantum is a Qt style that draws every widget from an SVG instead, so it is
the layer where a button's radius, a hairline border or a flat toolbar is
decided. Settings → App theming → **Kvantum widget theme** generates one from
whatever theme the shell is currently wearing and selects it.

It needs the `kvantum` package (`qt6-style-kvantum` on Debian and Ubuntu,
where older releases such as 24.04 carry only the Qt5 build, which Qt6
applications ignore). The installer reports whether it's there, and whether
the build you have matches the Qt your applications use.

It stands on its own: turning it on writes `widgetStyle=kvantum` into
`kdeglobals` whether or not "Theme KDE applications" is also on. Turning both
on is still the better pairing — Kvantum draws the widgets, the palette gives
it the colours to draw them in.

What gets written, all under `~/.config/Kvantum/`:

    Hyprshell/Hyprshell.svg        every widget, drawn from the live palette
    Hyprshell/Hyprshell.kvconfig   which SVG element each widget uses
    kvantum.kvconfig               `theme=Hyprshell` — only that one key

and `widgetStyle=kvantum` in `kdeglobals`, which is what actually puts Qt on
this style. Turning the setting back off removes that key again, so "off"
means off rather than a theme that is still selected. If you had set
`widgetStyle` to something else by hand, that value is left alone.

The SVG is generated, not hand-drawn. Most elements are a nine-slice: four
corner arcs, four edges and an interior, so a widget of any size keeps a
1px border and the shell's corner radius. Buttons, entries, combo boxes,
scrollbars and sliders each get the five states Kvantum asks for (normal,
focused, pressed, toggled, inactive); frames, menus, tooltips, headers and
progress bars get one.

A selected row or tab is marked the way the design marks it — a quiet fill
with an accent rule underneath — rather than by filling it with accent,
which reads as a warning rather than a selection.

Check boxes and radios are the exception to the nine-slice, because Kvantum
draws them from a single element painted into the whole indicator rect, and
from the *interior* element's name rather than the indicator's: it asks for
`checkbox-checked-normal`, not for whatever `indicator.element` says. So each
state of each control is drawn whole, box and mark together.

It regenerates whenever the palette does — switch light to dark and both
files are rewritten. **Applications pick it up when they next start**, not
live: unlike `kdeglobals`, Qt reads its style once at startup. Restart
Dolphin to see the change.

This gets a KDE app much closer to the concept than colours alone, and it is
still not the concept's file manager. Kvantum decides how widgets are drawn;
it cannot move Dolphin's toolbar, replace its sidebar or change its icons,
because those are Dolphin's layout rather than its style.

## The icon pack

`modules/icons/IconPaths.js` — a 24-unit grid, a 2-unit ink stroke, and
zero or more accent elements. Nothing comes from an icon theme, so the
shell looks the same on any machine, and `MonoIcon` draws a whole glyph in
two or three `Shape`s rather than one per stroke, which matters when the
dock, launcher and control center are all on screen at once.

These are vectors, not bitmaps — `PathSvg` inside a `Shape` — so scaling
costs nothing and there is no `.svg` file to load. What did cost something
was the stroke width. At 2 authored units on a 24 grid, a glyph at size S
draws a stroke of S/12 device pixels: 1.08px at 13, 1.42px at 17. A stroke
thinner than two pixels lands across two pixel rows at partial coverage and
reads as a smudge, whatever renderer draws it.

`MonoIcon` compensates, widening the authored stroke as the glyph shrinks so
every glyph lands 2 device pixels wide at any size, and keeping the authored
proportion above size 24. Settings' chrome went up with it, from 11–15px to
17–20 in 30px buttons. `monocheck.sh` asserts the 2px floor across ten sizes
in both this pack and the file manager's copy.

### The launcher grows out of the dock

Settings → Shell → Launcher → "Grow out of the dock", on by default. The
start menu is the dock's own pill stretching into it rather than a separate
panel appearing above it, and it shrinks back on the way out. With
auto-hide on, the dock slides out first and the menu grows from it — that
part was already there, since the dock counts the launcher being open as a
reason to be revealed.

The motion is three numbers chasing the same target at different rates —
width over 340ms, height over 460ms, the contents' fade over 260ms after a
150ms wait. One number would move every edge in lockstep, which is a box
being scaled. Letting the width arrive first means the shape stretches
wide, then rises, then settles, and the corner radius travels with it from
the pill's lozenge to the panel's. Opening, the contents fade in once the
shape has nearly stopped; closing, they go first, so it never shrinks
around text you can still read.

How it works: the focused screen's dock publishes its pill's width and
height to `UiState`, the launcher covers the whole screen so it works the
position out itself, and one number — `morph`, 0 at the pill and 1 at the
panel — drives every part of the shape. The contents are laid out at the
finished size throughout and clipped, rather than reflowed each frame, so
the panel opens like a shutter and the text does not rewrap twenty times on
the way up; they fade in over the back half, when there is something to
see through. The dock's pill fades out as it goes, since two of them on
screen at once would give it away.

### Shell size per display, and why it is needed

A layer-shell surface is specified in logical pixels, so the compositor's
own scale multiplies everything on that output — the shell along with the
applications. Running a laptop panel at a scale that makes applications
legible therefore makes the bar large to match, and there was no way to
say otherwise.

Settings → Display → "Shell size on this display" is the shell's own
correction, per output: a 150% laptop can carry an 85% bar while the
monitor beside it stays at 100. It is applied to the numbers rather than
by scaling the bar with a transform, which would resample the text.

Kept as `name=percent` lines in theme.json, one per output, so an output
named by its description — "Dell Inc. DELL U2720Q" — survives being a key.

Separately: every per-screen surface now draws nothing until it has a real
screen. `screen: modelData ?? null` means "the default screen" to
setScreen, so during an output change — plugging a monitor in, or changing
a scale, which makes Hyprland re-enumerate — a surface whose modelData had
momentarily gone would land on the default output instead. Two bars on one
monitor is what that looks like.

### Which surfaces reserve space, and which ignore it

Only two reserve: the bar and, when it is not set to auto-hide, the dock.
Both are pinned to `ExclusionMode.Normal` explicitly, because `Auto` —
the default — reserves space for the *whole surface* when exactly three
anchors are set, and both are anchored on three. The dock's surface spans
the screen edge and carries tooltip headroom above the pill, so on `Auto`
it would reserve all of that and push every window down by a tooltip's
height.

Everything that covers the screen sets `ExclusionMode.Ignore`: the
wallpaper, the launcher, the panel layer and the overview. A reservation
shrinks other layer surfaces too, not just windows, and that is almost
never what is meant. Left respecting it, the wallpaper stopped at the dock
and what showed behind and beside the dock was the compositor's own
background rather than the desktop; the launcher's bottom edge lifted off
the screen edge, which is the one place it must stay anchored when it grows
out of the dock; and its click-away target lifted with it, so the desktop
beside the dock stopped dismissing it. Reserving space is for windows.

### Space for the dock

The gap above the dock and the gap below it are the same number, and it is
Settings → Shell → Dock → Spacing.

Below is geometry — the pill sits `tooltipRoom` down a surface that is
`tooltipRoom + panelBreadth + edgeGap` tall and anchored to the bottom, so
what is left under it is the gap. Above is the exclusive zone, which is
where tiled windows stop. Those two live in different files and used to
disagree: the zone covered the pill and the bottom gap only, so windows sat
flush against the dock's top edge while it floated clear of the bottom.

The zone is the pill, plus a gap on each side, **less `general:gaps_out`**.
That last term is the one that is easy to miss: a tiled window does not sit
on the edge of the usable area, the compositor holds it off by its own
outer gap, so reserving two gaps put `edgeGap + gaps_out` above against
`edgeGap` below — even in the arithmetic and visibly uneven on screen, and
worse the wider the gaps. Subtracting it hands that part back to the
compositor, which was already doing it. Floored at the pill: with gaps
wider than twice the dock's spacing there is nothing left to give back, and
a window is never allowed to reach the dock.

`dockgap.js` lifts the zone expression out of Dock.qml and *runs* it,
rather than matching its shape, and checks above equals below across five
spacings, two dock sizes and four gap settings. It was written by breaking
it: drop the `gaps_out` term and it reports 22 failures, all "above 8,
below 4"; drop the doubling and it reports 28, all "above 0".



An always-visible dock reserves its strip, so windows tile above it rather
than under it. An auto-hiding one reserves nothing — a hidden dock holding
a band of unusable desktop would be the worst of both. Only the pill and
its edge gap are reserved, not the tooltip headroom above it, which is part
of the surface but not part of the dock.

### Idle timers

Settings → Display → "When you leave it alone": screen off, sleep, lock.
`hyprshell-daemon` keeps the timers (the compositor's own idle
notifications), so an app that keeps the screen on — a video, a call —
holds them too; so do media playing and a fullscreen window, if those
switches are on, and the control center's **Keep awake** tile. Lock brings
up the shell's lock screen, and the screen is locked before any sleep
(logind waits for it) and on `loginctl lock-session`. Moving over from
hypridle takes its timings from the block below, removes the block, and
stops hypridle unless your own listeners are left in the file.

Without the daemon it is hypridle's, configured by a file rather than any
control interface, so `services/Idle.qml` reads and writes
`~/.config/hypr/hypridle.conf` and restarts it.

The file is not ours — people put their own listeners in it — so the three
this panel manages live inside a marked block and everything outside it is
carried across untouched. `idletest.js` covers that, and that saving twice
produces the same file: joining "whatever was left" to the block grew it by
a newline on every save, which is what the Kvantum config used to do, and
the reason anything here that rewrites a file gets a fixpoint test.

### Arranging displays

Settings → Display → Arrangement draws the desktop plane to scale and lets
you drag a screen to where it actually is. Released within 60 logical
pixels of touching another, it lands exactly flush: Hyprland's positions
are absolute, and a one-pixel gap between two outputs is a column of
desktop the pointer cannot cross, so "nearly aligned" is never what was
meant. `snaptest.js` covers the eight cases, including a scaled laptop,
which snaps by its logical size rather than its pixels.

### Refresh rate on battery

A rate chosen in Settings → Display is held. Hyprland sets an output up
again from `hyprland.lua`'s rule whenever it re-initialises it — a laptop
panel as the power source changes, a monitor re-plugged — and that rule is
`"preferred"`, which on many laptop panels is 60 Hz; asusd can also run a
`bat_command` on unplugging. The shell checks the rate after the power
source changes, after an output comes or goes, and every half minute, and
puts the chosen one back.

Putting it back takes two steps. Hyprland keeps the rule it was last
asked for, not the mode it ended up on, and skips a rule identical to that
one — so once an output has fallen to 60 Hz with its rule still saying 120,
asking for 120 again changes nothing. The shell sends the rule for what the
output is running first, then the one it wants, which Hyprland then applies.

**On battery** (laptops) chooses the rate unplugged: the same as plugged
in, which is the default, or a lower one to save power. It changes back
when you plug in.

If it goes back three times inside a minute, the shell stops rather than
flicker, and the On battery row says so. Either something else sets it —
on an ASUS laptop, a `bat_command` in `/etc/asusd/asusd.ron` — or the
driver refuses the rate at that moment, which Hyprland's log records as a
mode that failed and a fallback to the preferred one.

### The dock's surface spans the whole edge

Not the pill. The pill is centred inside it and input is masked to the
pill plus a margin, so the slack either side stays click-through.

It used to be cut to the pill exactly, which meant every animation that
changes a tile's width — the active app's label sliding out, or collapsing
when show desktop is pressed — resized the Wayland surface on every frame.
Each of those is a round trip with the compositor, so the collapse was
visibly coarser than the animation driving it, the surface's right edge
showed as a square of unpainted space while it caught up, and the last
tile's hover fill sat flush against the boundary where it clipped. All
three were the same cause.

### Why a missing import is its own check

`reachcheck.py`. QML resolves an unqualified type from the file's own
directory plus each unqualified `import "path"`, so a component added to
`modules/common` and used somewhere that never imported that directory
kills the shell at load with "X is not a type". That shipped once, with
`Entrance`.

`qmlparse.py` cannot catch it. It runs Qt's real parser, but Quickshell's
own types are not installed in the repository, so "is not a type" has to be
ignored there or every file fails. `reachcheck.py` looks only at types that
*are* a .qml file in this repository — which Quickshell's are not — so it
has nothing to ignore and no false positives to tune. It is
regression-tested by deleting that import and watching it name the file,
the type, and the directory the type actually lives in.

### When a glyph is missing

Run the icon sheet on the machine that shows it:

    qs -p ~/.config/quickshell/hyprshell/tools/iconsheet.qml

Every glyph in the pack, twice: left with Qt's default Shape renderer,
right with the analytic one (`Shape.CurveRenderer`). A name whose left
square is filled and whose right one is empty is a glyph the curve renderer
drops on that GPU — which looks, in the dock, like a tile with a fill and
nothing on it.

The curve renderer is off by default for exactly that reason. It is the one
thing about these glyphs that cannot be tested here: every offscreen render
used to check this shell runs on the software backend, which ignores the
request and uses its own rasteriser, so it looked correct in every check
while shipping untested on real hardware. Settings → Icons → Icon edge
smoothing turns it on.

`MonoIcon` renders an unknown name as nothing at all and reports nothing,
so `iconcheck.js` asserts that every name the shell and the file manager
ask for exists in their pack — including the ones that only appear as a
bare string in a pane's `icon:` field.

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

By default those rules set `xray`: the shell's surfaces blur the wallpaper,
which Hyprland blurs once and keeps, rather than whatever is behind them.
The menus, the launcher and floating Settings are full-screen surfaces that
Qt redraws whole on every frame of an animation, so live blur meant blurring
the entire screen again on every frame — visible as menus dropping frames,
worst at 240 Hz. Settings → Hyprland → **Blur behind the shell** → Live
brings the old look back at that cost.

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
