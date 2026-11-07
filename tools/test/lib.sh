# What tools/test/run.sh and its scenarios are written with. Sourced, not run.
#
# In a scenario, each test is a function named test_…, run in turn, each
# from a clean start (whatever the last one left running is stopped):
#
#   start_shell               the Rust shell, as on a desktop
#   start_settings [PANE]     the Settings app
#   start_greeter [FACE]      the login screen, against the fake greetd
#   cmd LINE                  a line to the shell, as a keybind sends it
#   click X Y [right|move…]   the pointer (logical pixels, TT_W×TT_H)
#   drag X Y X2 Y2
#   keys "text" [enter esc tab up down …]
#   wait_for SECONDS COMMAND… until the command succeeds (else the test fails)
#   shot NAME                 a screenshot, compared with its reference
#   check "what" COMMAND…     fails the test, saying what, unless it succeeds
#   in_log FILE PATTERN       the fake's log FILE has a line matching PATTERN
#   alive PROGRAM / gone PROGRAM
#   fail "why"
#
# Logs and stand-ins' records are in $TT_LOGS; a test's own folder is $TT_DIR.

TT_W=${TT_W:-1536}
TT_H=${TT_H:-960}
export TT_W TT_H
TT_FAILED=0
TT_PASSED=0
TT_NEW=0
TT_KEEP=0
TT_ROWS=()

say() { printf '%s\n' "$*"; }

# ── setting up ──────────────────────────────────────────────────────────────
tt_need() {
    local missing=()
    for p in cargo sway grim python3; do command -v "$p" >/dev/null 2>&1 || missing+=("$p"); done
    if [ ${#missing[@]} -gt 0 ]; then
        say "The tests need: ${missing[*]} (sudo pacman -S --needed ${missing[*]/cargo/rust})"
        return 1
    fi
}

tt_build() {
    local t="$TT_CACHE/target"
    say "Building (the first time takes a while)…"
    ( cd "$REPO/rshell" && CARGO_TARGET_DIR="$t" cargo build --release -q --features test-hooks ) || { say "the Rust shell didn't build"; return 1; }
    ( cd "$REPO/apps" && CARGO_TARGET_DIR="$t" cargo build --release -q -p hyprshell-settings ) || { say "Settings didn't build"; return 1; }
    ( cd "$REPO/tools/test/harness" && CARGO_TARGET_DIR="$t" cargo build --release -q ) || { say "the test tools didn't build"; return 1; }
    BIN="$t/release"
    export BIN
}

tt_setup() {
    tt_need || return 1
    TT_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/hyprshell-test
    TT_REF=${XDG_DATA_HOME:-$HOME/.local/share}/hyprshell/test-ref
    mkdir -p "$TT_CACHE" "$TT_REF"
    tt_build || return 1
    TT_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hyprshell-test.XXXXXX")
    chmod 700 "$TT_ROOT"
    TT_OUT=${XDG_RUNTIME_DIR:-/tmp}/hyprshell-test
    rm -rf "${TT_OUT:?}"
    mkdir -p "$TT_OUT"
    # A world of its own: HOME, config, runtime folder, the stand-ins first
    # on PATH. Nothing of yours is read or written.
    export TT_LOGS="$TT_ROOT/logs"
    export HOME="$TT_ROOT/home"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
    export XDG_RUNTIME_DIR="$TT_ROOT/run"
    mkdir -p "$TT_LOGS" "$XDG_CONFIG_HOME/quickshell/hyprshell" "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    export PATH="$REPO/tools/test/fakes/bin:$BIN:$PATH"
    export HYPRSHELL_DAEMON="$REPO/tools/test/fakes/hyprshell-daemon"
    export HYPRSHELL_TEST_PAM="$REPO/tools/test/fakes/pam-helper"
    # Friday 6 November 2026, 09:41, wherever the tests run.
    export TZ=UTC HYPRSHELL_TEST_CLOCK=1793958060
    export USER=tester SLINT_BACKEND=winit-software
    unset HYPRLAND_INSTANCE_SIGNATURE DBUS_SESSION_BUS_ADDRESS WAYLAND_DISPLAY DISPLAY
    # A private session bus, when there's dbus-daemon to make one.
    if command -v dbus-daemon >/dev/null 2>&1; then
        DBUS_SESSION_BUS_ADDRESS=$(dbus-daemon --session --fork --print-address 1 --address="unix:path=$XDG_RUNTIME_DIR/bus" 2>/dev/null | head -n1)
        export DBUS_SESSION_BUS_ADDRESS
    fi
    tt_sway || return 1
    say "Testing in $TT_ROOT"
}

# A headless sway at TT_W×TT_H, scale 1.
tt_sway() {
    printf 'default_border none\nbar { mode invisible }\n' > "$TT_ROOT/sway.conf"
    WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
        setsid sway -c "$TT_ROOT/sway.conf" > "$TT_LOGS/sway.log" 2>&1 < /dev/null &
    TT_SWAY=$!
    local i=0
    while [ $i -lt 50 ]; do
        WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" 2>/dev/null | grep -m1 '^wayland-[0-9]*$')
        SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -n1)
        [ -n "$WAYLAND_DISPLAY" ] && [ -n "$SWAYSOCK" ] && break
        sleep 0.1; i=$((i + 1))
    done
    [ -n "$WAYLAND_DISPLAY" ] || { say "sway didn't start: $(tail -n 3 "$TT_LOGS/sway.log")"; return 1; }
    export WAYLAND_DISPLAY SWAYSOCK
    swaymsg -q -s "$SWAYSOCK" -- output HEADLESS-1 mode --custom "${TT_W}x${TT_H}" >/dev/null
    swaymsg -q -s "$SWAYSOCK" -- output HEADLESS-1 scale 1 >/dev/null
}

tt_teardown() {
    tt_stop_all
    [ -n "${TT_SWAY:-}" ] && kill "$TT_SWAY" 2>/dev/null
    pkill -f "greetd.py $TT_ROOT" 2>/dev/null
    if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        pkill -f "address=unix:path=$XDG_RUNTIME_DIR/bus" 2>/dev/null
    fi
    if [ "${TT_KEEP:-0}" = 1 ]; then
        say "Kept: $TT_ROOT"
    else
        rm -rf "${TT_ROOT:?}"
    fi
}

# ── running ─────────────────────────────────────────────────────────────────
# What the tests start is known by its environment: everything started in
# here, and everything that starts in turn (Settings from the shell, which
# gives it a session of its own), carries TT_LOGS=<this run's folder>. Only
# those are looked for, and stopped — never by name — so a shell of yours
# that happens to be running is never touched.
tt_spawn() { setsid "$@" & }
# This run's processes: "pid name" lines.
tt_ours() {
    local p
    for p in /proc/[0-9]*; do
        [ "${p#/proc/}" = "$$" ] && continue
        grep -qzx "TT_LOGS=$TT_LOGS" "$p/environ" 2>/dev/null || continue
        printf '%s %s\n' "${p#/proc/}" "$(cat "$p/comm" 2>/dev/null)"
    done
}
tt_stop_all() {
    local pids
    # Not this script, nor the subshells it runs tests in.
    pids=$(tt_ours | awk '$2 != "bash" && $2 != "sh" && $2 != "sleep" && $2 != "sway" && $2 != "dbus-daemon" && $2 != "swaybg" { print $1 }')
    if [ -n "$pids" ]; then
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null
        sleep 0.3
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null
    fi
    sleep 0.2
}

tt_area() { say ""; say "── $1"; TT_ROWS+=("" "### $1"); }

tt_run() {
    local area=$1 t=$2
    TT_DIR="$TT_ROOT/$area/${t#test_}"
    mkdir -p "$TT_DIR"
    TT_TEST="$area/${t#test_}"
    TT_WHY=""
    tt_stop_all
    # Each test from the same start: the fixture theme, no remembered state.
    rm -rf "${XDG_CONFIG_HOME:?}/quickshell/hyprshell" "$TT_LOGS"/*.log "${TT_ROOT:?}/greeter-state"
    unset HYPRSHELL_TEST_FACE TT_FACE FAKE_SCREENS FAKE_HDR
    # Face unlock off unless a test says otherwise: not whatever this machine's
    # own /etc/pam.d/hyprshell-lock happens to say.
    export HYPRSHELL_TEST_FACE=0
    mkdir -p "$XDG_CONFIG_HOME/quickshell/hyprshell"
    cp "$REPO/tools/test/fixtures/theme.json" "$XDG_CONFIG_HOME/quickshell/hyprshell/theme.json"
    local start=$SECONDS
    ( set +e; "$t" ) > "$TT_DIR/out.txt" 2>&1
    # Its logs beside it, before the next test starts afresh.
    mkdir -p "$TT_DIR/logs" && cp "$TT_LOGS"/*.log "$TT_DIR/logs/" 2>/dev/null
    local why
    why=$(cat "$TT_DIR/why" 2>/dev/null)
    # A test that couldn't even keep its own record didn't pass.
    [ -f "$TT_DIR/out.txt" ] || why="the test's own folder went missing (it can't be judged)"
    # Whatever crashed along the way fails it too.
    local crash
    crash=$(grep -h -m1 -E "panicked at|SIGSEGV|core dumped" "$TT_LOGS"/*.log "$TT_DIR/out.txt" 2>/dev/null | head -n1)
    [ -z "$why" ] && [ -n "$crash" ] && why="crashed: $crash"
    if [ -n "$why" ]; then
        TT_FAILED=$((TT_FAILED + 1))
        printf '  ✗ %-34s %s\n' "${t#test_}" "$why"
        TT_ROWS+=("- ✗ **${t#test_}** — $why  (logs: \`$TT_DIR\`)")
        cp -r "$TT_DIR" "$TT_OUT/${area}-${t#test_}" 2>/dev/null
        cp "$TT_LOGS"/*.log "$TT_OUT/${area}-${t#test_}/" 2>/dev/null
    else
        TT_PASSED=$((TT_PASSED + 1))
        local note=""
        if [ -f "$TT_DIR/new" ]; then
            note=" (new reference screenshots: $(tr '\n' ' ' < "$TT_DIR/new"))"
            TT_NEW=$((TT_NEW + $(wc -l < "$TT_DIR/new")))
        fi
        printf '  ✓ %-34s %ss%s\n' "${t#test_}" "$((SECONDS - start))" "$note"
        TT_ROWS+=("- ✓ ${t#test_}$note")
    fi
}

tt_report() {
    local r="$TT_OUT/report.md"
    {
        echo "# Hyprshell test report"
        echo
        echo "$TT_PASSED passed, $TT_FAILED failed$( [ "$TT_NEW" -gt 0 ] && echo ", $TT_NEW new reference screenshots")."
        printf '%s\n' "${TT_ROWS[@]}"
        echo
        [ "$TT_FAILED" -gt 0 ] && echo "Each failure's screenshots, differences (red) and logs are beside this file."
    } > "$r"
    say ""
    say "$TT_PASSED passed, $TT_FAILED failed. Report: $r"
}

# ── what tests use ──────────────────────────────────────────────────────────
fail() {
    [ -s "$TT_DIR/why" ] || printf '%s' "$*" > "$TT_DIR/why"
    return 1
}
check() {
    local what=$1; shift
    "$@" >/dev/null 2>&1 || fail "$what"
}
wait_for() {
    local secs=$1; shift
    local end=$((SECONDS + secs))
    while [ $SECONDS -le $end ]; do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}
in_log() { grep -qE -- "$2" "$TT_LOGS/$1" 2>/dev/null; }
# A program of this run's is running (and not just a zombie waiting to be
# reaped). Names as the kernel keeps them: at most 15 characters.
alive() {
    local pid name
    while read -r pid name; do
        [ "$name" = "${1:0:15}" ] || continue
        grep -q '^State:.*Z' "/proc/$pid/status" 2>/dev/null || return 0
    done < <(tt_ours)
    return 1
}
gone() { ! alive "$1"; }

click() { tt-ptr "$@" >/dev/null 2>&1; sleep 0.25; }
drag() { tt-ptr "$1" "$2" drag "$3" "$4" >/dev/null 2>&1; sleep 0.3; }
keys() { tt-kbd "$@" >/dev/null 2>&1; sleep 0.25; }

start_shell() {
    rm -f "$XDG_RUNTIME_DIR/hyprshell-ready"
    tt_spawn hyprshell-rs > "$TT_LOGS/shell.log" 2>&1 < /dev/null
    # Up when it says so (its first frame on screen), then a moment for the
    # wallpaper, drawn on a thread of its own.
    wait_for 15 test -e "$XDG_RUNTIME_DIR/hyprshell-ready" || fail "the shell didn't come up: $(tail -n 2 "$TT_LOGS/shell.log")"
    sleep 1
    alive hyprshell-rs || fail "the shell didn't start: $(tail -n 2 "$TT_LOGS/shell.log")"
}
cmd() {
    echo "$*" >> "$XDG_RUNTIME_DIR/hyprshell.cmd"
    sleep 0.6
}
start_settings() {
    tt_spawn hyprshell-settings "$@" > "$TT_LOGS/settings.log" 2>&1 < /dev/null
    sleep 2
    alive hyprshell-setti || fail "Settings didn't start: $(tail -n 2 "$TT_LOGS/settings.log")"
}
# The login screen against the fake greetd, with its people and sessions.
start_greeter() {
    local g="$TT_ROOT/greeter-state"
    mkdir -p "$g/sessions" "$g/users" "$g/cache"
    cp "$REPO/tools/test/fixtures/passwd" "$g/passwd"
    cp "$REPO"/tools/test/fixtures/sessions/*.desktop "$g/sessions/"
    pkill -f "greetd.py $TT_ROOT" 2>/dev/null
    tt_spawn python3 "$REPO/tools/test/fakes/greetd.py" "$g/sock" "$TT_LOGS/greetd.log" > /dev/null 2>&1
    sleep 0.4
    GREETD_SOCK="$g/sock" HYPRSHELL_GREETER_PASSWD="$g/passwd" HYPRSHELL_GREETER_SESSIONS="$g/sessions" \
        HYPRSHELL_GREETER_USERS="$g/users" HYPRSHELL_GREETER_STATE="$g/cache/state.json" HYPRSHELL_GREETER_ICONS="$g/icons" \
        HYPRSHELL_TEST_FACE="${1:-0}" tt_spawn hyprshell-rs --greeter > "$TT_LOGS/greeter.log" 2>&1 < /dev/null
    sleep 1.5
}

# A screenshot, compared with this machine's reference of the same name.
# No reference yet: this one becomes it (and the report says so).
shot() {
    local name=${TT_TEST//\//-}-$1
    local png="$TT_DIR/$1.png" ref="$TT_REF/$name.png"
    sleep 0.3
    grim "$png" 2>/dev/null || { fail "no screenshot ($1)"; return 1; }
    if [ ! -f "$ref" ] || [ "${TT_ACCEPT:-0}" = 1 ]; then
        cp "$png" "$ref"
        echo "$1" >> "$TT_DIR/new"
        return 0
    fi
    local pct
    pct=$(tt-diff "$ref" "$png" "$TT_DIR/$1.diff.png" "${TT_TOLERANCE:-0.5}")
    case $? in
        0) return 0 ;;
        1) cp "$ref" "$TT_DIR/$1.reference.png"; fail "screenshot $1 differs from the reference ($pct of it)" ;;
        *) fail "screenshot $1 can't be compared ($pct)" ;;
    esac
}
