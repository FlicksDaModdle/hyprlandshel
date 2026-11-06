# The login screen (rshell/src/greeter.rs) against the stand-in greetd
# (fakes/greetd.py): tester's password is "testpw", then a code, 123456.

test_shows_first_person() {
    start_greeter
    shot shown
}

test_wrong_password_refused() {
    start_greeter
    keys "nope" enter
    wait_for 4 in_log greetd.log cancel_session || fail "greetd wasn't told the attempt was over"
    sleep 0.8
    shot refused
    alive hyprshell-rs || fail "the greeter went away"
}

test_password_then_code_logs_in() {
    start_greeter
    keys "testpw" enter
    wait_for 4 in_log greetd.log '"response": "<6 chars>"' || fail "the password wasn't sent"
    sleep 0.6
    shot code-asked
    keys "123456" enter
    wait_for 5 gone hyprshell-rs || fail "the greeter didn't finish"
    in_log greetd.log '"cmd": \["Hyprland"\]' || fail "no session was started"
    in_log greetd.log 'XDG_CURRENT_DESKTOP=Hyprland' || fail "the session's desktop wasn't said"
    check "the choice wasn't remembered" grep -q '"session":"hyprland"' "$TT_ROOT/greeter-state/cache/state.json"
}

test_other_session_with_tab() {
    start_greeter
    keys "" down up tab
    sleep 0.5
    shot plasma-picked
    keys "testpw" enter
    sleep 1
    keys "123456" enter
    wait_for 5 gone hyprshell-rs || fail "the greeter didn't finish"
    in_log greetd.log 'startplasma-wayland' || fail "Plasma wasn't the session started"
    in_log greetd.log 'XDG_CURRENT_DESKTOP=KDE' || fail "Plasma's desktop name wasn't passed"
    check "the choice wasn't remembered" grep -q '"session":"plasma"' "$TT_ROOT/greeter-state/cache/state.json"
}

test_down_picks_next_person() {
    start_greeter
    keys "" down
    sleep 0.6
    shot second-person
}

test_face_logs_in() {
    mkdir -p "$TT_ROOT/greeter-state/cache"
    echo '{"user":"facetest","session":"hyprland"}' > "$TT_ROOT/greeter-state/cache/state.json"
    start_greeter 1
    wait_for 3 in_log greetd.log '"username": "facetest"' || fail "the face wasn't looked for"
    wait_for 8 gone hyprshell-rs || fail "the greeter didn't let them in"
    in_log greetd.log start_session || fail "no session was started"
}

test_escape_does_not_quit_under_greetd() {
    start_greeter
    keys "" esc esc
    sleep 0.8
    alive hyprshell-rs || fail "Escape ended the greeter, under greetd"
}
