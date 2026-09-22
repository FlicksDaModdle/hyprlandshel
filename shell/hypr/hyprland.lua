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

-- Everything the shell owns is reached over Quickshell's IPC socket.
-- `qs ipc call <target> <function> [args]` lands on the IpcHandler in
-- shell.qml, so the compositor never needs to know how the shell is built.
-- Dispatchers without a typed `hl.dsp.*` helper in this config go through
-- hyprctl, which accepts every dispatcher name Hyprland has.
local function dispatch(cmd)
    return "hyprctl dispatch " .. cmd
end

-- Shell shortcuts call the shell's own IPC function, because that is the
-- route that actually works here.
--
-- They went through hyprland-global-shortcuts-v1 for a while: the shell
-- registers "hyprshell:<name>", and `global` dispatches straight to it over
-- the Wayland connection it already holds. Fewer moving parts on paper. But
-- the protocol sits behind a Quickshell build flag, and on a build without
-- it `hyprctl globalshortcuts` lists nothing and every bind pointing at one
-- is a no-op that says nothing. That is this machine. The same actions
-- answer instantly over IPC from a terminal.
--
-- So the binds go where the working call goes. They still register as global
-- shortcuts — other clients can dispatch to them, and `hyprctl
-- globalshortcuts` is still worth a look — but nothing here depends on it.
--
-- hyprshellctl is the one place that knows how to make the call: Quickshell
-- has moved its config selector between releases, so it tries each form
-- until one answers and remembers which. Called by absolute path, because
-- Hyprland runs binds through /bin/sh with the session's PATH, which need
-- not have ~/.local/bin on it.
local ctl = (os.getenv("HOME") or "") .. "/.config/quickshell/hyprshell/hyprshellctl"

local function shell(fn, arg)
    if arg then
        return ctl .. " " .. fn .. " " .. arg
    end
    return ctl .. " " .. fn
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

hl.on("hyprland.start", function()
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
hl.bind(mainMod .. " + E",      hl.dsp.exec_cmd(fileManager))
hl.bind(mainMod .. " + B",      hl.dsp.exec_cmd(browser))

-- Window management
hl.bind(mainMod .. " + Q",           hl.dsp.window.close())
hl.bind(mainMod .. " + V",           hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + F",           hl.dsp.exec_cmd(dispatch("fullscreen 0")))
hl.bind(mainMod .. " + SHIFT + F",   hl.dsp.exec_cmd(dispatch("fullscreen 1")))
hl.bind(mainMod .. " + SHIFT + P",   hl.dsp.exec_cmd(dispatch("pin")))
hl.bind(mainMod .. " + P",           hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J",           hl.dsp.layout("togglesplit"))

-- The launcher. An ordinary chord, using only the dispatcher forms that
-- Hyprland's own example config uses.
--
-- There was a tap-to-open here that passed a Lua *function* to hl.bind and
-- called hl.dispatch from inside it. Neither appears anywhere in upstream's
-- example config, and every Super bind in this file was wrapped in it — so
-- when it turned out not to work, it did not break the tap, it broke all of
-- them at once. Tap-to-open is not worth that; if Hyprland grows a real tap
-- bind it can come back.
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
