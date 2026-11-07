# The Settings app (apps/settings): every pane opens, draws and stays up;
# a few controls do what they say, checked in what the stand-ins were asked.

PANES=(Appearance Wallpaper Icons "App theming" Bar "Alt+Tab" Dock Launcher Keybinds Fonts Clipboard Screenshots
       Notifications Display Network Bluetooth Sound Power Laptop Hyprland Keyboard Mouse Touchpad
       "Login screen" Updates About)

# One test per pane, so a broken one names itself.
for p in "${PANES[@]}"; do
    n=$(printf '%s' "$p" | tr 'A-Z +&' 'a-z___' | tr -s _)
    eval "test_pane_$n() { start_settings \"$p\"; sleep 1; shot pane; alive hyprshell-setti || fail \"Settings closed on $p\"; }"
    TT_TESTS+=("test_pane_$n")
done

test_laptop_profile_click() {
    start_settings Laptop
    sleep 1
    # "Quiet" in the Profile row.
    click 1242 236
    wait_for 3 in_log daemon.log '"rog-profile".*"profile": ?2' || fail "Quiet wasn't sent to asusd"
}
TT_TESTS+=(test_laptop_profile_click)

test_two_screens_map() {
    export FAKE_SCREENS=2
    start_settings Display
    sleep 1
    shot two-screens
}
TT_TESTS+=(test_two_screens_map)

# Settings → Login screen: face unlock, against a fixture folder standing in
# for the machine (Howdy, two cameras, a face enrolled) and a stand-in for the
# helper pkexec starts. Nothing of the real PAM, camera or password is touched.
face_fixture() {
    local d="$TT_ROOT/face" s="$XDG_CONFIG_HOME/quickshell/hyprshell/scripts"
    mkdir -p "$d" "$s"
    cat > "$d/config.ini" <<'INI'
[core]
use_cnn = false
abort_if_ssh = true
[video]
certainty = 3.5
timeout = 4
device_path = /dev/video2
INI
    printf '[{"id":0,"label":"Face 2026-11-01","time":1793500000}]' > "$d/models.dat"
    printf 'howdy\npam\ngreeter\ncam\t/dev/video0\tIntegrated Camera\t0\ncam\t/dev/video2\tIntegrated IR Camera\t1\nconfig\t%s\ndevice\t/dev/video2\nmodels\t%s\nfaces\t1\n' "$d/config.ini" "$d/models.dat" > "$d/probe.txt"
    echo 'auth sufficient pam_howdy.so' > "$d/pam-lock"
    echo '# hyprshell-face' > "$d/greetd"
    # What pkexec would start as root: the same words, answering "done".
    cat > "$s/howdy-setup.sh" <<'SH'
printf '\037READY\n'
while IFS=$'\t' read -r -a a; do
    printf '%s\n' "${a[*]}" >> "$TT_LOGS/face-requests.log"
    printf '\037EXIT 0\n'
done
SH
    export HYPRSHELL_FACE_FIXTURE="$d"
}

test_face_unlock_page() {
    face_fixture
    start_settings "Login screen"
    sleep 1.5
    shot page
    alive hyprshell-setti || fail "Settings closed on the login screen page"
    # Turning it off goes to the helper, which was started (and asked for
    # its password) by pkexec, here the stand-in.
    click 1477 274
    wait_for 5 grep -q -- '--remove' "$TT_LOGS/face-requests.log" || fail "Turning face unlock off wasn't sent to the helper"
    # Adding a face: the webcam (none here) is waited for a few seconds, then
    # the helper is asked to record.
    click 302 878
    wait_for 12 grep -q -- '--add-face' "$TT_LOGS/face-requests.log" || fail "Adding a face wasn't sent to the helper"
    sleep 1
    shot after-add
    alive hyprshell-setti || fail "Settings closed adding a face"
}
TT_TESTS+=(test_face_unlock_page)

# A switch flips when its setting changes ("Frosted menus", on then clicked off).
# (The slide itself can't be seen in the headless run: by the time a frame is
# taken it has settled. The rows are written in place when a setting changes
# so a switch keeps its place and slides, rather than being re-made.)
test_switch_flips() {
    start_settings "Appearance"
    sleep 1.5
    sw() { magick "$TT_DIR/$1.png" -crop 70x34+1445+845 +repage "$TT_DIR/$1-sw.png"; }
    grim "$TT_DIR/before.png" 2>/dev/null; sw before
    click 1477 862
    sleep 1
    grim "$TT_DIR/after.png" 2>/dev/null; sw after
    cmp -s "$TT_DIR/before-sw.png" "$TT_DIR/after-sw.png" && fail "the switch didn't change"
    true
}
TT_TESTS+=(test_switch_flips)

# A frosted dropdown: the menu opens over the page with the blurred page
# behind its tint (Settings → Appearance → Frosted menus).
test_dropdown_frost() {
    face_fixture
    start_settings "Login screen"
    sleep 1.5
    click 1375 337
    sleep 0.8
    shot open
    alive hyprshell-setti || fail "Settings closed opening a dropdown"
}
TT_TESTS+=(test_dropdown_frost)
