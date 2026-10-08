-- Hyprshell greeter — the compositor greetd runs the login screen in.
--
-- greetd starts Hyprland with this file as the `greeter` user; Hyprland
-- starts the greeter; when you log in the greeter hands your session to
-- greetd and quits, and the line after it ends this Hyprland so greetd can
-- start yours on the same seat.
--
-- install.sh writes this to /etc/hyprshell-greeter/hyprland.lua with the
-- @…@ values filled in. Edit it there (the keyboard layout, say); it is only
-- rewritten when install.sh is run again.
--
-- No keybinds, on purpose: nothing can be launched from a login screen.

-- Where the greeter's copy of your theme.json lives (see install.sh).
hl.env("XDG_CONFIG_HOME", "@STATE@/config")
hl.env("QT_QPA_PLATFORM", "wayland")
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
-- Where GreeterLook.qml links the cursor theme of the person picked (your
-- accent cursor lives in your home, which the greeter cannot read), ahead
-- of the system's themes, so `hyprctl setcursor` finds it by name.
hl.env("XCURSOR_PATH", "@CACHE@/data/icons:/usr/local/share/icons:/usr/share/icons:/usr/share/pixmaps")
hl.env("XDG_DATA_DIRS", "@CACHE@/data:/usr/local/share:/usr/share")

hl.config({
    input = {
        kb_layout          = "@KB_LAYOUT@",
        kb_variant         = "@KB_VARIANT@",
        numlock_by_default = true,
    },
    general = {
        border_size = 0,
        gaps_in     = 0,
        gaps_out    = 0,
    },
    misc = {
        disable_hyprland_logo    = true,
        disable_splash_rendering = true,
        force_default_wallpaper  = 0,
    },
    ecosystem = {
        no_update_news   = true,
        no_donation_nag  = true,
    },
})

hl.on("hyprland.start", function()
    hl.exec_cmd("@QS@ -p @SHARE@/shell.qml; hyprctl dispatch 'hl.dsp.exit()'")
end)
