-- Hyprland config for the "Hyprshell" desktop (Lua config, Hyprland 0.55+).
-- Place at ~/.config/hypr/hyprland.lua
--
-- This is the base compositor config the Quickshell shell (../quickshell/)
-- runs on top of. It intentionally stays out of the shell's way: the bar,
-- dock, launcher etc. are all drawn by Quickshell as layer-shell surfaces,
-- not by Hyprland itself.

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
local menu        = "qs ipc call shell toggleLauncher"

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-------------------
---- AUTOSTART ----
-------------------

hl.on("hyprland.start", function()
    hl.exec_cmd("qs -c hyprshell")
end)

-----------------------
---- LOOK AND FEEL ----
-----------------------
-- Gaps/rounding/border here style Hyprland's own client windows (real
-- terminals, browsers, etc.) — kept close to the shell's own design tokens
-- (14px family rounding, thin hairline borders, restrained shadow) so real
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
    },
})

hl.curve("easeOutQuint", { type = "bezier", points = { {0.23, 1}, {0.32, 1} } })
hl.curve("easy",         { type = "spring", mass = 1, stiffness = 238.1191, damping = 24.21279333 })

hl.animation({ leaf = "windows",  enabled = true, speed = 4.5, spring = "easy" })
hl.animation({ leaf = "border",   enabled = true, speed = 5,   bezier = "easeOutQuint" })
hl.animation({ leaf = "fade",     enabled = true, speed = 3,   bezier = "easeOutQuint" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 3, bezier = "easeOutQuint", style = "slide" })

-- The shell's own layer-shell surfaces (bar/dock/launcher/panels) get real
-- compositor blur-behind here, matched by namespace to what Dock.qml (and
-- later Bar.qml, Launcher.qml, ...) sets via WlrLayershell.namespace.
hl.layer_rule({ name = "blur-quickshell-dock",  match = { namespace = "^quickshell:dock$" },  blur = true, ignore_alpha = 0.15 })
hl.layer_rule({ name = "blur-quickshell-bar",   match = { namespace = "^quickshell:bar$" },   blur = true, ignore_alpha = 0.15 })
hl.layer_rule({ name = "blur-quickshell-panel", match = { namespace = "^quickshell:panel$" }, blur = true, ignore_alpha = 0.15 })

---------------
---- INPUT ----
---------------

hl.config({
    input = {
        kb_layout = "us",
        follow_mouse = 1,
        sensitivity  = 0,

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
hl.bind(mainMod .. " + Q",      hl.dsp.window.close())
hl.bind(mainMod .. " + V",      hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + P",      hl.dsp.window.pseudo())
hl.bind(mainMod .. " + J",      hl.dsp.layout("togglesplit"))

-- Shell surfaces — routed into Quickshell over its IPC socket.
-- `qs ipc call <target> <function>` reaches the IpcHandler in shell.qml.
-- Tap-only Super (matches the design's "Launcher — super" hint): fires on
-- release of the bare modifier key, not paired with another key.
hl.bind("SUPER_L", hl.dsp.exec_cmd(menu), { release = true })
hl.bind(mainMod .. " + Tab",                hl.dsp.exec_cmd("qs ipc call shell toggleOverview"))
hl.bind(mainMod .. " + SHIFT + T",          hl.dsp.exec_cmd("qs ipc call shell toggleTheme"))
hl.bind(mainMod .. " + SHIFT + S",          hl.dsp.exec_cmd("qs ipc call shell toggleSnapLayout"))
hl.bind(mainMod .. " + SHIFT + R",          hl.dsp.exec_cmd("qs -c hyprshell kill; qs -c hyprshell &"))
hl.bind(mainMod .. " + L",                  hl.dsp.exec_cmd("hyprlock"))

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

-- Media keys
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true, repeating = true })
hl.bind("XF86MonBrightnessUp",  hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%+"),                  { locked = true, repeating = true })
hl.bind("XF86MonBrightnessDown",hl.dsp.exec_cmd("brightnessctl -e4 -n2 set 5%-"),                  { locked = true, repeating = true })

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
