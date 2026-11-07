# The Rust shell itself (rshell): it starts, draws its bar and dock, and
# each of its surfaces opens from the command a keybind sends.

test_starts() {
    start_shell
    sleep 1
    shot desktop
}

panel() {
    start_shell
    cmd "$1"
    sleep 0.8
    shot open
    alive hyprshell-rs || fail "the shell went away opening $1"
    cmd closePanels
    sleep 0.6
    shot closed
}
test_control_center() { panel toggleControlCenter; }
test_notifications() { panel toggleNotifications; }
test_calendar() { panel toggleCalendar; }
test_power_menu() { panel togglePower; }
test_timers() { panel toggleTimers; }
test_updates() { panel toggleUpdates; }

test_launcher() {
    start_shell
    cmd toggleLauncher
    sleep 0.8
    shot open
    keys "term"
    sleep 0.6
    shot searched
    keys "" esc
    sleep 0.6
    shot closed
}

test_identify() {
    start_shell
    cmd "identify HEADLESS-1"
    sleep 0.6
    shot numbered
}

test_volume_keys() {
    start_shell
    cmd volumeUp
    wait_for 3 in_log daemon.log 'pa-volume' || fail "volume up didn't reach the sound service"
    sleep 0.4
    shot osd
}

test_settings_command() {
    start_shell
    cmd "openSettings Sound"
    wait_for 5 alive hyprshell-setti || fail "openSettings didn't start Settings"
}

# Settings → Appearance → Corner rounding, changed while the shell runs:
# the panels and dock go square at 0%.
set_theme() {
    python3 - "$XDG_CONFIG_HOME/quickshell/hyprshell/theme.json" "$1" "$2" <<'PY'
import json, sys
p, k, v = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
d = json.load(open(p)); d[k] = v; json.dump(d, open(p, "w"), indent=2)
PY
}
test_rounding_follows() {
    start_shell
    set_theme rounding 0
    sleep 1.5
    cmd toggleControlCenter
    sleep 0.8
    shot square
    cmd closePanels
    cmd toggleLauncher
    sleep 0.8
    shot launcher-square
}

# Settings → Bar → Auto-hide: away until the pointer rests on the top edge,
# back away a moment after it leaves.
test_bar_autohide() {
    start_shell
    set_theme barHide true
    sleep 1
    shot hidden
    # Resting on the top edge (held there while the screenshot is taken).
    tt-ptr 700 1 hover 2.5 &
    local held=$!
    sleep 1.5
    shot revealed
    # That one only: a bare `wait` would wait for the shell too.
    wait "$held"
    click 700 500 move
    sleep 1.2
    shot hidden-again
}

# A setting changed in Settings shows at once, not at the next once-a-second
# look: the dock hides within half a second of being told to.
test_dock_autohide_prompt() {
    start_shell
    click 700 400 move
    set_theme dockHide true
    sleep 0.5
    shot dock-hidden
}

# The launcher, opened a second time, still takes what's typed.
test_launcher_reopened_types() {
    start_shell
    cmd toggleLauncher
    sleep 0.6
    keys "" esc
    sleep 0.8
    cmd toggleLauncher
    sleep 0.6
    keys "files"
    sleep 0.6
    shot searched-again
}

# Settings → Appearance → Screen corners: black rounded corners, all four,
# on every screen (the test's isn't a built-in panel); one turned off.
test_screen_corners() {
    start_shell
    set_theme screenCornerScreens '"all"'
    set_theme screenCornerRadius 40
    set_theme screenCorners true
    sleep 0.8
    shot four
    set_theme screenCornerBR false
    sleep 0.8
    shot three
}

# Super+Shift+S: the screen freezes, a rectangle dragged over it is saved
# to ~/Pictures/Screenshots at its own size, put on the clipboard and
# announced, and the frozen screen goes.
test_screenshot_region() {
    start_shell
    rm -rf "${HOME:?}/Pictures/Screenshots"
    cmd "screenshot region"
    sleep 1.2
    tt-ptr 100 100 hover 0.4 >/dev/null 2>&1
    tt-ptr 300 250 hover 0.6 >/dev/null 2>&1
    shot frozen
    drag 200 200 600 500
    wait_for 5 sh -c 'ls "$HOME"/Pictures/Screenshots/Screenshot_*.png' >/dev/null 2>&1 || fail "no screenshot was saved: $(tail -n 3 "$TT_LOGS/shell.log")"
    local f
    f=$(ls "$HOME"/Pictures/Screenshots/Screenshot_*.png 2>/dev/null | head -n 1)
    [ -n "$f" ] || return
    local size
    size=$(python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24]))' "$f")
    [ "$size" = 400x300 ] || fail "the screenshot is $size, not the 400x300 dragged"
    wait_for 3 in_log wl-copy.log 'image/png' || fail "the screenshot wasn't put on the clipboard"
    wait_for 3 in_log notify-send.log 'Screenshot saved' || fail "the screenshot wasn't announced"
    sleep 0.5
    shot after
}

# Esc puts everything back, and nothing is saved.
test_screenshot_cancel() {
    start_shell
    rm -rf "${HOME:?}/Pictures/Screenshots"
    cmd "screenshot region"
    sleep 1.2
    # Letting go of Super+Shift+S is a Super release: no launcher for it.
    cmd toggleLauncher
    keys "" esc
    sleep 0.6
    shot cancelled
    ! ls "$HOME"/Pictures/Screenshots/Screenshot_*.png >/dev/null 2>&1 || fail "a cancelled screenshot was saved"
    alive hyprshell-rs || fail "the shell went away"
}

# Shift+Print: the whole screen, at once.
test_screenshot_screen() {
    start_shell
    rm -rf "${HOME:?}/Pictures/Screenshots"
    cmd "screenshot screen"
    wait_for 5 sh -c 'ls "$HOME"/Pictures/Screenshots/Screenshot_*.png' >/dev/null 2>&1 || fail "no screenshot was saved: $(tail -n 3 "$TT_LOGS/shell.log")"
}

# Right-click a dock tile: its menu; Change icon… opens the icon picker, which
# takes what is typed, and a click on a glyph changes the tile.
test_dock_menu_icon_picker() {
    start_shell
    sleep 1
    click 701 918 right
    sleep 0.8
    shot menu
    click 668 781
    sleep 0.8
    keys "cam"
    sleep 0.5
    shot picker
    # The first glyph found for "cam" is the one Return takes.
    keys "" enter
    sleep 0.6
    shot changed
    grep -q '"icon": *"camera"\|\\"icon\\":\\"camera' "$XDG_CONFIG_HOME/quickshell/hyprshell/theme.json" || fail "the tile didn't take the icon"
}

# Choose application… opens the launcher as a chooser; what is picked takes
# the tile's slot instead of starting.
test_dock_menu_choose_app() {
    start_shell
    sleep 1
    click 746 918 right
    sleep 0.8
    click 732 781
    sleep 1
    shot chooser
    keys "task"
    sleep 0.5
    keys "" enter
    sleep 0.8
    grep -q 'Task Manager' "$XDG_CONFIG_HOME/quickshell/hyprshell/theme.json" || fail "the tile didn't take the chosen entry"
    shot chosen
}
