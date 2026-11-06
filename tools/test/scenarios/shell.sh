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
