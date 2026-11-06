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
    click 1242 276
    wait_for 3 in_log daemon.log '"rog-profile".*"profile": 2' || fail "Quiet wasn't sent to asusd"
}
TT_TESTS+=(test_laptop_profile_click)

test_two_screens_map() {
    export FAKE_SCREENS=2
    start_settings Display
    sleep 1
    shot two-screens
}
TT_TESTS+=(test_two_screens_map)
