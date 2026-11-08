#!/bin/sh
# Starts the shell, and keeps a copy of the last version of it that
# loaded: if this one doesn't (an error in it — no bar, no dock, no lock
# screen), that copy starts instead, and a notification says what was
# wrong. Installed by install.sh to ~/.local/share/hyprshell/, outside the
# shell's own folder, so a broken shell can't take this with it;
# hyprland.lua starts the shell through it.
#
# "Loaded" is the shell saying so: shell.qml touches $XDG_RUNTIME_DIR/
# hyprshell-ready a moment after everything in it is up. Until then its
# output is watched for Quickshell's "Failed to load configuration", or it
# exiting.
set -u

# The environment the shell needs, however this was started — from
# hyprland.lua, which sets it too, or by hand, which didn't, and left a shell
# with NVIDIA's EGL driver loaded and glibc keeping every freed page:
#   memory      two glibc arenas
#   GPU         Mesa's EGL, Vulkan ICD and VA-API rather than NVIDIA's,
#               wherever Mesa has a GPU — NVIDIA's switched off included,
#               which glvnd would otherwise still load (not NVIDIA-only)
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
# Quickshell allocates with jemalloc, which by default keeps freed memory
# for ten seconds in up to 4 arenas per CPU thread: a few arenas here, and
# what's freed handed back after a second by a background thread.
export MALLOC_CONF="${MALLOC_CONF:-background_thread:true,narenas:4,dirty_decay_ms:1000,muzzy_decay_ms:0}"
_mesa=/usr/share/glvnd/egl_vendor.d/50_mesa.json
if [ -f "$_mesa" ] && [ -z "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" ]; then
    _nv= _other= _amd=
    for _u in /sys/class/drm/renderD*/device/uevent; do
        [ -r "$_u" ] || continue
        case "$(sed -n 's/^DRIVER=//p' "$_u")" in
            nvidia) _nv=1 ;;
            amdgpu) _other=1 _amd=1 ;;
            i915|xe|radeon) _other=1 ;;
        esac
    done
    if [ -n "$_other" ]; then
        export __EGL_VENDOR_LIBRARY_FILENAMES="$_mesa" __GLX_VENDOR_LIBRARY_NAME=mesa
        for _icd in /usr/share/vulkan/icd.d/radeon_icd.x86_64.json /usr/share/vulkan/icd.d/intel_icd.x86_64.json; do
            [ -f "$_icd" ] && { export VK_DRIVER_FILES="$_icd" VK_ICD_FILENAMES="$_icd"; break; }
        done
        export QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi
        # AMD: shaders compiled by Mesa's ACO rather than LLVM, the biggest
        # library the shell would otherwise page in.
        [ -n "$_amd" ] && export AMD_DEBUG="${AMD_DEBUG:-useaco}"
    fi
fi
export QT_QPA_PLATFORM=wayland
case ";${QT_LOGGING_RULES:-};" in
    *quickshell.io.socket.warning*) ;;
    *) export QT_LOGGING_RULES="${QT_LOGGING_RULES:+$QT_LOGGING_RULES;}quickshell.io.socket.warning=false" ;;
esac

# One of these at a time. Hyprland starts this on a reload as well as at login, and a
# guard that only looked for `qs` let the Rust shell be started again and again: three
# shells, each with its own launcher, so Escape closed one of three.
LOCKD=${XDG_RUNTIME_DIR:-/tmp}/hyprshell-start.d

# --restart: the running shell goes first (either of them), and the copy of this that
# was looking after it.
if [ "${1:-}" = "--restart" ]; then
    old=$(cat "$LOCKD/pid" 2>/dev/null)
    if [ -n "$old" ] && [ "$old" != "$$" ] && [ -r "/proc/$old/cmdline" ] && tr '\0' ' ' <"/proc/$old/cmdline" 2>/dev/null | grep -q 'start-shell\.sh'; then
        kill "$old" 2>/dev/null
    fi
    stopped=0
    pkill -x qs 2>/dev/null && stopped=1
    pkill -x hyprshell-rs 2>/dev/null && stopped=1
    [ "$stopped" = 1 ] && sleep 0.4
fi

# The lock is a directory (mkdir is atomic) holding this one's pid, rather than a file lock:
# a lock fd is inherited by whatever this starts, and one browser would hold it for good.
# A directory left by a copy that is no longer running is taken over.
tries=0
until mkdir "$LOCKD" 2>/dev/null; do
    old=$(cat "$LOCKD/pid" 2>/dev/null)
    if [ -n "$old" ] && [ "$old" != "$$" ] && [ -r "/proc/$old/cmdline" ] && tr '\0' ' ' <"/proc/$old/cmdline" 2>/dev/null | grep -q 'start-shell\.sh'; then
        exit 0
    fi
    tries=$((tries + 1))
    if [ -z "$old" ] && [ "$tries" -lt 10 ]; then
        sleep 0.05
        continue
    fi
    [ "$(cat "$LOCKD/pid" 2>/dev/null)" = "$old" ] && rm -rf "$LOCKD"
    [ "$tries" -ge 30 ] && exit 0
done
echo $$ >"$LOCKD/pid"
trap 'rm -rf "$LOCKD"' EXIT

# Which shell: the Quickshell one, or the Rust rewrite (rshell/), as
# tools/hyprshell-dev sets it in ~/.config/hyprshell/engine:
#
#   shell=rust        this starts the Rust shell instead of Quickshell
#   settings=rust     the Quickshell shell opens the Rust Settings app
#
# The Rust shell is restarted if it crashes; if it crashes three times in
# two minutes, the Quickshell one takes over and a notification says so.
ENGINE=${XDG_CONFIG_HOME:-$HOME/.config}/hyprshell/engine
RUSTBIN=${XDG_DATA_HOME:-$HOME/.local/share}/hyprshell/rust/bin
if grep -qs '^shell=rust$' "$ENGINE" && [ -x "$RUSTBIN/hyprshell-rs" ]; then
    RLOG=${XDG_RUNTIME_DIR:-/tmp}/hyprshell-rs.log
    [ -x "$RUSTBIN/hyprshell-daemon" ] && export HYPRSHELL_DAEMON="$RUSTBIN/hyprshell-daemon"
    export PATH="$RUSTBIN:$PATH"
    crashes=""
    while :; do
        # The last run's log is kept (and how it ended), or a crash is gone with the restart.
        [ -s "$RLOG" ] && cp -f "$RLOG" "$RLOG.prev"
        : >"$RLOG"
        start=$(date +%s)
        "$RUSTBIN/hyprshell-rs" >>"$RLOG" 2>&1
        code=$?
        [ "$code" = 0 ] || [ "$code" = 143 ] || [ "$code" = 130 ] || echo "$(date +%T) hyprshell-rs ended with status $code (signal $((code - 128)))" >>"$RLOG"
        # Ended on purpose (switched back, or the session ending).
        [ "$code" = 0 ] || [ "$code" = 143 ] || [ "$code" = 130 ] && exit 0
        grep -qs '^shell=rust$' "$ENGINE" || break
        now=$(date +%s)
        crashes="$crashes $now"
        recent=0
        for t in $crashes; do [ $((now - t)) -lt 120 ] && recent=$((recent + 1)); done
        if [ "$recent" -ge 3 ]; then
            notify-send -u critical -a Hyprshell "The Rust shell keeps crashing: back to the Quickshell one" \
                "$(tail -n 6 "$RLOG")

The full log: $RLOG. Switch back with: tools/hyprshell-dev use rust" 2>/dev/null &
            break
        fi
        # Crashed straight away: a moment before the next try.
        [ $((now - start)) -lt 5 ] && sleep 2
    done
fi

RT=${XDG_RUNTIME_DIR:-/tmp}
CFG=${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/hyprshell
GOOD=${XDG_DATA_HOME:-$HOME/.local/share}/hyprshell/last-good
READY=$RT/hyprshell-ready
LOG=$RT/hyprshell.log

rm -f "$READY"
: >"$LOG"
qs -c hyprshell >>"$LOG" 2>&1 &
pid=$!

broken=0
i=0
while [ $i -lt 60 ]; do
    if [ -e "$READY" ]; then break; fi
    if ! kill -0 "$pid" 2>/dev/null || grep -q "Failed to load configuration" "$LOG"; then
        broken=1
        break
    fi
    sleep 0.5
    i=$((i + 1))
done

if [ "$broken" = 0 ] && [ -e "$READY" ]; then
    # Loaded: this is now the version to fall back to. Copied aside and
    # swapped in, so a copy cut short never replaces a whole one.
    if mkdir -p "${GOOD%/*}" && rm -rf -- "${GOOD:?}.new" && cp -a -- "$CFG" "$GOOD.new" 2>/dev/null; then
        rm -rf -- "${GOOD:?}.old"
        [ -d "$GOOD" ] && mv -- "$GOOD" "$GOOD.old"
        mv -- "$GOOD.new" "$GOOD" && rm -rf -- "${GOOD:?}.old"
    fi
    # The log is in memory ($XDG_RUNTIME_DIR): kept from growing without end.
    (
        while kill -0 "$pid" 2>/dev/null; do
            sleep 300
            [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 4000000 ] && : >"$LOG"
        done
    ) &
    wait "$pid"
    exit $?
fi

if [ "$broken" = 0 ]; then
    # Neither loaded nor failed in half a minute: left to run.
    wait "$pid"
    exit $?
fi

# Didn't load.
kill "$pid" 2>/dev/null
why=$(grep -A4 "Failed to load configuration" "$LOG" | head -n 5 | sed 's/^[[:space:]]*//')
[ -n "$why" ] || why=$(tail -n 5 "$LOG")
if [ -d "$GOOD" ] && [ -f "$GOOD/shell.qml" ]; then
    notify-send -u critical -a Hyprshell "Hyprshell didn't start: running the last version that worked" \
        "$why

The full log: $LOG" 2>/dev/null &
    sleep 0.3
    exec qs -p "$GOOD" >>"$LOG" 2>&1
fi
notify-send -u critical -a Hyprshell "Hyprshell didn't start" "$why

The full log: $LOG" 2>/dev/null
exit 1
