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
#   memory      two glibc arenas, and freed memory handed back
#   hybrid GPU  Mesa's EGL, Vulkan ICD and VA-API rather than NVIDIA's,
#               where Mesa has a GPU to drive (not with the MUX on NVIDIA)
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
export GLIBC_TUNABLES="${GLIBC_TUNABLES:-glibc.malloc.trim_threshold=131072:glibc.malloc.mmap_threshold=131072}"
_mesa=/usr/share/glvnd/egl_vendor.d/50_mesa.json
if [ -f "$_mesa" ] && [ -z "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" ]; then
    _nv= _other=
    for _u in /sys/class/drm/renderD*/device/uevent; do
        [ -r "$_u" ] || continue
        case "$(sed -n 's/^DRIVER=//p' "$_u")" in
            nvidia) _nv=1 ;;
            amdgpu|i915|xe|radeon) _other=1 ;;
        esac
    done
    if [ -n "$_nv" ] && [ -n "$_other" ]; then
        export __EGL_VENDOR_LIBRARY_FILENAMES="$_mesa" __GLX_VENDOR_LIBRARY_NAME=mesa
        for _icd in /usr/share/vulkan/icd.d/radeon_icd.x86_64.json /usr/share/vulkan/icd.d/intel_icd.x86_64.json; do
            [ -f "$_icd" ] && { export VK_DRIVER_FILES="$_icd" VK_ICD_FILENAMES="$_icd"; break; }
        done
        export QT_FFMPEG_DECODING_HW_DEVICE_TYPES=vaapi
    fi
fi
export QT_QPA_PLATFORM=wayland
case ";${QT_LOGGING_RULES:-};" in
    *quickshell.io.socket.warning*) ;;
    *) export QT_LOGGING_RULES="${QT_LOGGING_RULES:+$QT_LOGGING_RULES;}quickshell.io.socket.warning=false" ;;
esac

# --restart: the running shell goes first.
if [ "${1:-}" = "--restart" ] && pkill -x qs 2>/dev/null; then sleep 0.4; fi

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
