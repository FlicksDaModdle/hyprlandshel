-- Hyprland config for the "Hyprshell" desktop (Lua config, Hyprland 0.55+).
-- Place at ~/.config/hypr/hyprland.lua
--
-- This is the base compositor config the Quickshell shell (../quickshell/)
-- runs on top of. It intentionally stays out of the shell's way: the bar,
-- dock, launcher, panels, overview, OSD and lock screen are all drawn by
-- Quickshell as layer-shell surfaces, not by Hyprland itself.

------------------
---- MONITORS ----
------------------

hl.monitor({
    output   = "",
    mode     = "preferred",
    position = "auto",
    scale    = "auto",
})

---------------------
---- MY PROGRAMS ----
---------------------
-- Edit these to match what's actually installed. Quickshell's dock reads
-- the same set from quickshell/config/Apps.qml — keep the two in sync.

local terminal    = "kitty"
local fileManager = "nautilus"
local browser     = "firefox"

-- Shell shortcuts write a line to a file the shell is reading.
--
-- That is the fourth mechanism tried here, and the first with nothing in it
-- that can fail to find anything:
--
--   global shortcuts     need a Quickshell built with
--                        hyprland-global-shortcuts-v1. This one is not, so
--                        nothing registered and every bind was a silent
--                        no-op.
--
--   qs ipc call          has to find the running shell first. Naming the
--                        config makes it hash the config file path, read
--                        $XDG_RUNTIME_DIR/quickshell/by-path/<hash> and
--                        filter what it finds by display connection. On this
--                        machine that came back "No running instances for
--                        ~/.config/quickshell/hyprshell/shell.qml" while
--                        `qs list --all` printed the instance, its pid and
--                        that exact config path.
--
--   by pid, by id        the same call addressed differently — the route
--                        DankMaterialShell's helper takes. No better here.
--
-- So the shortcuts stop trying to find the shell. The shell opens
-- $XDG_RUNTIME_DIR/hyprshell.cmd and reads it (services/Commands.qml); a
-- shortcut appends one line to it. There is no binary to locate, no socket,
-- no protocol, no instance lookup and no agreement needed about how the
-- shell was started — only that both ends see the same $XDG_RUNTIME_DIR,
-- which these binds had already proven, because their own log has been
-- landing in it the whole time.
--
-- Nothing may *start* with "[", which Hyprland reads as an exec rule.
--
-- Tracing: Hyprland sends a spawned command's output to /dev/null, so a
-- failing shortcut is otherwise silent. Each one appends what it asked for
-- and whether the shell's watcher was alive to $XDG_RUNTIME_DIR/
-- hyprshell-bind.log, and writes down what it could see when it was not.
-- `hyprshellctl trace` prints it. Set this to false to stop.
local traceBinds = true
local bindLog = '"$XDG_RUNTIME_DIR/hyprshell-bind.log"'

local function shell(fn, arg)
    local call = fn .. (arg and (" " .. arg) or "")

    local head = [[f="${XDG_RUNTIME_DIR:-/tmp}/hyprshell.cmd"; ]]
    local write = "echo '" .. call .. "' >> \"$f\""

    if not traceBinds then
        return head .. write .. " 2>/dev/null"
    end

    -- The watcher writes its pid into hyprshell.cmd.status when the shell
    -- starts, so "did anything hear that" is answerable without waiting for
    -- a reply that a one-way channel cannot give.
    local alive = [[w=$(sed -n 's/^watcher //p' "$f.status" 2>/dev/null); ]]
        .. [[if [ -n "$w" ] && kill -0 "$w" 2>/dev/null; then s=0; else s=1; fi; ]]

    local facts = '{ echo "  no watcher — the shell is not reading '
        .. 'commands"; if [ -f "$f.status" ]; then sed "s/^/    /" '
        .. '"$f.status"; else echo "    (no status file: no shell has '
        .. 'started a watcher since boot)"; fi; '
        .. [[echo "  qs running: $(pgrep -x qs | tr '\n' ' ')"; } >>]]
        .. bindLog .. " 2>&1"

    return head .. write .. " 2>>" .. bindLog .. "; " .. alive
        .. 'printf "%s %s -> %s\\n" "$(date +%T)" ' .. "'" .. call .. "' "
        .. '"$s" >>' .. bindLog .. '; test "$s" = 0 || ' .. facts
end

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
-- Qt apps pick up the Wayland backend and drop their own window decorations,
-- so client windows match the shell's own chrome instead of doubling it.
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")

-------------------
---- AUTOSTART ----
-------------------

-- Starting the shell.
--
-- Two paths, because one is not enough:
--
--   login   the body of this file runs during the very first config parse,
--           which Hyprland does in initManagers(STAGE_PRIORITY) — before
--           initServer has created the Wayland socket. hl.exec_cmd forks
--           right then (it is not deferred the way exec-once was), so the
--           child has no display to connect to and the shell dies on the
--           spot. The login launch therefore lives in the hyprland.start
--           hook, which fires on the first rendered frame.
--
--   reload  hyprland.start fires once per compositor run, so the hook alone
--           can never bring the shell back after `hyprctl reload`. That is
--           the body's job — but only on a reload, and the body has to tell
--           the two apart by itself.
--
-- It tells them apart by WAYLAND_DISPLAY. Hyprland sets that in every
-- process it spawns, from the socket name it has at the time: empty during
-- the first parse, because the socket does not exist yet, and the real name
-- on every reload after. So an empty one *is* "too early to launch
-- anything", which is the exact condition that made the login launch fail.
--
-- This used to be a marker file the start hook dropped. It worked, but only
-- from the next login: a session whose hook had already run under an older
-- config had no marker, so reload-restart stayed dead until you logged out.
-- Nothing is remembered now, so there is nothing to be stale.
--
-- The pgrep guard makes both paths safe: with the shell already running,
-- either is a no-op rather than a second instance.
--
-- QT_QPA_PLATFORM is forced on the launch rather than left to hl.env above,
-- because a login shell that pins it (plenty of setups pin it to "xcb" for
-- legacy Qt apps) wins over the session env, and the shell comes up on X11.
-- On X11 there is no wlr-layer-shell, so every WlrLayershell attached
-- property fails to build, every surface holding one is "not ready", and
-- the bar, dock, wallpaper and panel layer are never created. Setting it
-- here leaves every other Qt app on the session default.
--
-- Nothing here is wrapped in `sh -c`: Hyprland already runs exec commands
-- through /bin/sh. They just must not *start* with "[", which Hyprland
-- would read as an exec rule.
local launch = "pgrep -x qs >/dev/null 2>&1 || "
    .. "exec env QT_QPA_PLATFORM=wayland qs -c hyprshell"

-- Reload only: WAYLAND_DISPLAY is empty on the first parse, so this does
-- nothing then and the hook below does the real work.
hl.exec_cmd('test -n "$WAYLAND_DISPLAY" && { ' .. launch .. "; }")

-- Hand the session's environment to D-Bus and systemd.
--
-- Anything started *by the bus* rather than by the compositor inherits the
-- bus daemon's environment, which was set before this session existed: no
-- WAYLAND_DISPLAY, no XDG_CURRENT_DESKTOP. A Qt or GTK program activated
-- that way cannot find a display at all and dies during startup, and what
-- the caller sees is an activation that failed for no stated reason. The
-- file manager answering "show in file manager" and the file-dialog portal
-- are both started exactly that way, so both need this.
--
-- XDG_CURRENT_DESKTOP is in the list for a second reason: xdg-desktop-portal
-- matches it against each backend's UseIn= line, and with it unset every
-- backend is skipped.
local shareEnv = "dbus-update-activation-environment --systemd "
    .. "WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE "
    .. "HYPRLAND_INSTANCE_SIGNATURE XDG_SESSION_DESKTOP 2>/dev/null"

hl.on("hyprland.start", function()
    -- Before the shell, and before anything that might ask the bus for a
    -- program: an activation that happens first gets the old environment.
    hl.exec_cmd(shareEnv)
    hl.exec_cmd(launch)
    -- The shell draws its own lock screen; hypridle just decides when to ask
    -- for it. Safe to drop if hypridle isn't installed.
    hl.exec_cmd("pgrep -x hypridle >/dev/null 2>&1 || exec hypridle")
end)

-----------------------
---- LOOK AND FEEL ----
-----------------------
-- Gaps/rounding/border here style Hyprland's own client windows (real
-- terminals, browsers, etc.) — kept close to the shell's design tokens
-- (14px family rounding, hairline borders, restrained shadow) so real
-- windows read as part of the same system as the shell chrome.

hl.config({
    general = {
        gaps_in  = 4,
        gaps_out = 8,

        border_size = 1,

        col = {
            active_border   = "rgba(ec3013ee)",
            inactive_border = "rgba(32302eaa)",
        },

        resize_on_border = true,
        allow_tearing    = false,
        layout           = "dwindle",
    },

    decoration = {
        rounding       = 12,
        rounding_power = 2,

        active_opacity   = 1.0,
        inactive_opacity = 0.97,

        shadow = {
            enabled      = true,
            range        = 12,
            render_power = 2,
            color        = 0x66000000,
        },

        blur = {
            enabled  = true,
            size     = 4,
            passes   = 2,
            vibrancy = 0.16,
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
    },

    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
        -- The shell paints the desktop ground on the background layer, so
        -- Hyprland never needs to render its own.
        background_color        = "rgb(201e1d)",
        -- Adaptive sync is toggled at runtime by the control center's
        -- "Game mode" tile; 0 is the resting state.
        vrr                     = 0,
    },
})

hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })
-- The spring's third field is `dampening` on Hyprland 0.55, which is this
-- config's minimum. Upstream's own example currently spells it `damping`,
-- so it was renamed at some point: if your Hyprland reports
--   hl.curve("easy"): unknown field 'dampening'
-- change it to `damping` and nothing else. Getting it wrong is quiet but
-- not harmless — Hyprland reads nil, rejects the curve, and then the
-- windows animation below fails too with `no such spring "easy"`.
hl.curve("easy",         { type = "spring", mass = 1, stiffness = 238.1191, dampening = 24.21279333 })

hl.animation({ leaf = "windows",    enabled = true, speed = 4.5, spring = "easy" })
hl.animation({ leaf = "border",     enabled = true, speed = 5,   bezier = "easeOutQuint" })
hl.animation({ leaf = "fade",       enabled = true, speed = 3,   bezier = "easeOutQuint" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 3,   bezier = "easeOutQuint", style = "slide" })
hl.animation({ leaf = "layers",     enabled = true, speed = 3.5, bezier = "easeOutQuint", style = "fade" })

-- The shell's layer-shell surfaces get real compositor blur-behind here,
-- matched by the namespaces each module sets via WlrLayershell.namespace.
-- Without these rules the panel/sheet tints still read correctly — just
-- flatter, since there's nothing blurred behind them.
local shell_layers = {
    "bar", "dock", "panel", "overview",
}
for _, name in ipairs(shell_layers) do
    hl.layer_rule({
        name         = "blur-quickshell-" .. name,
        match        = { namespace = "^quickshell:" .. name .. "$" },
        blur         = true,
        ignore_alpha = 0.15,
    })
end

-- The wallpaper layer is the ground itself; blurring it would be blurring
-- nothing, and it must not animate on every reload.
hl.layer_rule({
    name     = "wallpaper-no-anim",
    match    = { namespace = "^quickshell:wallpaper$" },
    animation = "fade",
})

---------------
---- INPUT ----
---------------
-- Settings → Input writes these live with `hyprctl keyword`; the values
-- here are what the session starts from.

hl.config({
    input = {
        kb_layout    = "us",
        follow_mouse = 1,
        sensitivity  = 0,
        repeat_rate  = 25,
        repeat_delay = 600,

        touchpad = {
            natural_scroll = true,
            tap_to_click   = true,
        },
    },
})

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })

---------------------
---- KEYBINDINGS ----
---------------------

local mainMod = "SUPER"

-- Apps
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
-- The file manager is its own application, so this launches it directly
-- rather than going through the shell. `fileManager` at the top of this
-- file is the second opinion, on SHIFT.
--
-- Not a bare name: Hyprland's PATH is the session's, not your terminal's,
-- and ~/.local/bin — where files/install.sh puts it by default — is
-- routinely missing from it. A bare name there is a bind that silently does
-- nothing while the same command works when you type it.
local filesApp = 'command -v hyprshell-files >/dev/null 2>&1 && exec hyprshell-files; '
    .. 'for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do '
    .. '[ -x "$d/hyprshell-files" ] && exec "$d/hyprshell-files"; done; '
    .. 'notify-send "Files" "hyprshell-files is not installed" 2>/dev/null'

hl.bind(mainMod .. " + E",      hl.dsp.exec_cmd(filesApp))
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + B",      hl.dsp.exec_cmd(browser))

-- Window management
hl.bind(mainMod .. " + Q",           hl.dsp.window.close())
hl.bind(mainMod .. " + V",           hl.dsp.window.float({ action = "toggle" }))
-- Native dispatchers rather than `hyprctl dispatch fullscreen 0`: under a
-- Lua config hyprctl evaluates its argument as Lua — it is a wrapper for
-- hl.dispatch(...) — so the old hyprlang wording is a syntax error, and the
-- only sign of it is a line in a log nobody reads.
hl.bind(mainMod .. " + F",
    hl.dsp.window.fullscreen({ mode = "fullscreen", action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + F",
    hl.dsp.window.fullscreen({ mode = "maximized", action = "toggle" }))
hl.bind(mainMod .. " + SHIFT + P",   hl.dsp.window.pin())
hl.bind(mainMod .. " + P",           hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J",           hl.dsp.layout("togglesplit"))

-- The launcher, on Super by itself.
--
-- A bare modifier cannot be an ordinary bind, so this is a *release* bind on
-- the Super key: it fires when you let the key go. It does not fire at the
-- end of SUPER+C, because Hyprland shadows a release bind whose key took
-- part in a chord (shadowBinds, src/keybinds/Manager.cpp).
--
-- There are two ways to spell this key, and they are the *same physical
-- key*, not alternatives:
--
--   Super_L    the keysym. On current Hyprland this is also in
--              SIDED_MODIFIER_NAMES, so naming it sets the SUPER bit in the
--              mask as well as binding the key.
--   code:133   the keycode — evdev KEY_LEFTMETA (125) plus the 8 that xkb
--              adds. Independent of layout and of keysym naming entirely.
--
-- This used to bind both, on the theory that whichever one worked would win
-- and the shell's duplicate filter would absorb the other. That was wrong,
-- and it is what made the tap unreliable: when both spellings register, one
-- press fires *two* commands, and any time the second arrives more than a
-- moment after the first it toggles the launcher straight back shut. A
-- filter cannot fix that — the right number of binds is one.
--
-- So pick one. "name" is the default because it is what Hyprland documents;
-- if the tap does nothing at all on your keyboard, change this to "code".
-- `hyprshellctl doctor` step 5 prints what Hyprland actually registered.
local superSpelling = "name"   -- "name" | "code"

if superSpelling == "code" then
    hl.bind("SUPER + code:133", hl.dsp.exec_cmd(shell("toggleLauncher")),
        { release = true })
    hl.bind("SUPER + code:134", hl.dsp.exec_cmd(shell("toggleLauncher")),
        { release = true })
else
    hl.bind("SUPER + Super_L", hl.dsp.exec_cmd(shell("toggleLauncher")),
        { release = true })
    hl.bind("SUPER + Super_R", hl.dsp.exec_cmd(shell("toggleLauncher")),
        { release = true })
end

-- Kept until the tap above is confirmed working on your keyboard, so there
-- is always a way to open the launcher. Delete this line once it is.
hl.bind("SUPER + SPACE", hl.dsp.exec_cmd(shell("toggleLauncher")))

-- Shell surfaces — routed into Quickshell over its IPC socket.
hl.bind(mainMod .. " + Tab",         hl.dsp.exec_cmd(shell("toggleOverview")))
hl.bind(mainMod .. " + C",           hl.dsp.exec_cmd(shell("toggleControlCenter")))
hl.bind(mainMod .. " + N",           hl.dsp.exec_cmd(shell("toggleNotifications")))
hl.bind(mainMod .. " + SHIFT + N",   hl.dsp.exec_cmd(shell("toggleDnd")))
hl.bind(mainMod .. " + comma",       hl.dsp.exec_cmd(shell("openSettings", "Appearance")))
hl.bind(mainMod .. " + SHIFT + T",   hl.dsp.exec_cmd(shell("toggleTheme")))
hl.bind(mainMod .. " + SHIFT + R",   hl.dsp.exec_cmd(shell("reloadShell")))
hl.bind(mainMod .. " + L",           hl.dsp.exec_cmd(shell("lock")))
hl.bind(mainMod .. " + D",           hl.dsp.exec_cmd(shell("showDesktop")))

-- Screenshots: region to ~/Pictures and the clipboard, matching what the
-- control center's Capture tile and the launcher's Screenshot command do.
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.exec_cmd(
    "f=\"$HOME/Pictures/$(date +%Y-%m-%d-%H%M%S).png\"; mkdir -p \"$HOME/Pictures\"; "
    .. "grim -g \"$(slurp)\" \"$f\" && wl-copy < \"$f\" && "
    .. "notify-send -a Screenshot 'Region saved' \"$f\""))
hl.bind("Print", hl.dsp.exec_cmd(
    "f=\"$HOME/Pictures/$(date +%Y-%m-%d-%H%M%S).png\"; mkdir -p \"$HOME/Pictures\"; "
    .. "grim \"$f\" && wl-copy < \"$f\" && "
    .. "notify-send -a Screenshot 'Screen saved' \"$f\""))

-- Focus movement
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))

-- Workspaces 1-10, and moving windows to them
for i = 1, 10 do
    local key = i % 10
    hl.bind(mainMod .. " + " .. key,         hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Move/resize with mouse
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Media and backlight keys go through the shell so its OSD is what appears,
-- rather than each key silently poking wpctl with nothing on screen.
hl.bind("XF86AudioRaiseVolume",  hl.dsp.exec_cmd(shell("volumeUp")),       { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume",  hl.dsp.exec_cmd(shell("volumeDown")),     { locked = true, repeating = true })
hl.bind("XF86AudioMute",         hl.dsp.exec_cmd(shell("volumeMute")),     { locked = true })
hl.bind("XF86AudioMicMute",      hl.dsp.exec_cmd(shell("micMute")),        { locked = true })
hl.bind("XF86MonBrightnessUp",   hl.dsp.exec_cmd(shell("brightnessUp")),   { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd(shell("brightnessDown")), { locked = true, repeating = true })

-- Transport keys are the player's business, not the shell's.
hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("playerctl previous"),   { locked = true })

--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

-- No blur rule for kitty. Windows are not layer surfaces: decoration.blur
-- above already blurs behind any window with transparency, so kitty's
-- background_opacity reads as the mockup's translucent sheet on its own.
-- Window rules only have the opt-*out* (no_blur) — there is no positive
-- `blur` field for them, unlike the layer rules above, where the opt-in is
-- required.

hl.window_rule({
    name  = "float-pavucontrol",
    match = { class = "^(org.pulseaudio.pavucontrol|pavucontrol)$" },
    float = true,
})

-- The shell's own toplevels. Both Settings and Files are Quickshell
-- FloatingWindows when set to tiled, so they carry Quickshell's app id and
-- are told apart by title. Giving Files a decent opening size matters
-- because Hyprland only uses it in a floating layout; tiled, the layout
-- decides and this is ignored.
-- The file manager. Its own application now, so it carries its own app id
-- rather than Quickshell's, and the size only applies in a floating layout
-- — tiled, the layout decides and this is ignored.
hl.window_rule({
    name  = "hyprshell-files",
    match = { class = "^(hyprshell-files)$" },
    size  = { 1100, 700 },
})

-- The file dialogs it puts up for the rest of the desktop — a browser
-- saving a download, anything attaching a file.
--
-- Tiled, a "Save as…" rearranges every window on the workspace and then
-- puts them back when it closes, which is not what a dialog is for. It
-- floats instead.
--
-- Matched by title rather than class: it is the same program as the
-- window above, so the app id is the same, and Wayland has no window type
-- that says "dialog". The three titles are fixed in qml/FileDialog.qml
-- for this rule to match; both sides have to change together.
hl.window_rule({
    name  = "hyprshell-files-dialog",
    match = {
        class = "^(hyprshell-files)$",
        title = "^(Save a file|Open a file|Choose a folder) — Files$",
    },
    float = true,
    size  = { 940, 620 },
})

-------------------------------------
---- SHELL-MANAGED KEYBINDS (last) ---
-------------------------------------
-- Settings → Keybinds writes ~/.config/hypr/binds.lua and reloads. It is
-- read here, at the very end, so anything it defines replaces the default
-- bound above rather than the other way round.
--
-- Nothing in this file is ever rewritten by the shell: your comments and
-- your own binds stay exactly as you left them. Delete binds.lua to go back
-- to the defaults above.
--
-- pcall, because a missing file is the normal case on a fresh install and
-- should not take the whole config down with it.
--
-- The generated file calls back into `shell` above rather than carrying its
-- own copy of that command. One definition means a rebound shortcut cannot
-- drift from the default it replaced — which it did once already, when the
-- generated file shadowed working binds with a worse version of the same
-- thing.
_G.hyprshellCall = shell

do
    local home = os.getenv("HOME") or ""
    local generated = home .. "/.config/hypr/binds.lua"
    local f = io.open(generated, "r")
    if f then
        f:close()
        local ok, err = pcall(dofile, generated)
        if not ok then
            print("hyprshell: binds.lua failed to load: " .. tostring(err))
        end
    end
end
