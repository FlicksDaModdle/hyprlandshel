# The lock screen (rshell/src/lock.rs, ui/lock.slint), with the stand-in PAM
# (fakes/pam-helper: the password is "testpw") and, where said, face unlock.

# Where the lock's buttons are, on a TT_W×TT_H screen at scale 1.
SLEEP_BTN="1394 912"

test_locks_and_shows() {
    start_shell
    cmd lock
    sleep 1.2
    shot locked
}

test_wrong_password_refused() {
    start_shell
    cmd lock
    sleep 1
    keys "nope" enter
    wait_for 5 in_log pam.log '^login$' || fail "no password check was started"
    sleep 1.5
    shot refused
    check "a PAM attempt was left running" sh -c '! pgrep -f "[f]akes/pam-helper"'
    alive hyprshell-rs || fail "the shell went away"
}

test_right_password_unlocks() {
    start_shell
    cmd lock
    sleep 1
    keys "testpw" enter
    sleep 2.5
    shot unlocked
    check "a PAM attempt was left running" sh -c '! pgrep -f "[f]akes/pam-helper"'
}

test_escape_empties_field() {
    start_shell
    cmd lock
    sleep 1
    keys "abc" esc
    sleep 0.5
    shot emptied
}

test_face_found_unlocks() {
    export HYPRSHELL_TEST_FACE=1 TT_FACE=found
    start_shell
    cmd lock
    wait_for 5 in_log pam.log '^hyprshell-lock$' || fail "the face wasn't looked for"
    sleep 3.5
    shot unlocked
}

test_face_missed_then_password() {
    export HYPRSHELL_TEST_FACE=1 TT_FACE=missed
    start_shell
    cmd lock
    sleep 3.5
    shot missed
    keys "testpw" enter
    sleep 2.5
    shot unlocked
}

test_sleep_button() {
    start_shell
    cmd lock
    sleep 1
    # shellcheck disable=SC2086
    click $SLEEP_BTN
    wait_for 3 in_log systemctl.log suspend || fail "Sleep didn't suspend"
}

test_second_lock_ignored() {
    start_shell
    cmd lock
    sleep 1
    cmd lock
    sleep 0.5
    keys "testpw" enter
    sleep 2.5
    shot unlocked
}
