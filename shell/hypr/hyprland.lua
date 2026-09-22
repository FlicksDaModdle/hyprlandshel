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

local terminal    = "foot"
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

local function shell(fn, arg)
    if arg then
        return "qs -c hyprshell ipc call shell " .. fn .. " " .. arg
    end
    return "qs -c hyprshell ipc call shell " .. fn
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

hl.on("hyprland.start", function()
    hl.exec_cmd("qs -c hyprshell")
    -- The shell draws its own lock screen; hypridle just decides when to ask
    -- for it. Safe to drop if hypridle isn't installed.
    hl.exec_cmd("hypridle")
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
hl.curve("easy",         { type = "spring", mass = 1, stiffness = 238.1191, damping = 24.21279333 })

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

-- Shell surfaces — routed into Quickshell over its IPC socket.
-- Tap-only Super (matching the design's "Start — super" hint): fires on
-- release of the bare modifier, not when it's paired with another key.
hl.bind("SUPER_L",                   hl.dsp.exec_cmd(shell("toggleLauncher")), { release = true })
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

hl.window_rule({
    name  = "float-pavucontrol",
    match = { class = "^(org.pulseaudio.pavucontrol|pavucontrol)$" },
    float = true,
})
