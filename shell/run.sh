#!/bin/sh
# Starts the shell with the environment it cannot do without, from any
# terminal — including one that was started outside the Hyprland session.
#
# Two variables decide whether this shell works at all, and neither is
# obvious when it's missing:
#
#   QT_QPA_PLATFORM             must give Qt the Wayland backend. On X11
#                               there is no wlr-layer-shell, so every
#                               surface this shell has — bar, dock,
#                               wallpaper, panels — fails to build.
#   HYPRLAND_INSTANCE_SIGNATURE names the compositor's IPC socket. Without
#                               it there are no workspaces, no window list
#                               and no keybinds.
#
# Hyprland sets both for its own children, so the autostart in hyprland.lua
# needs none of this. A terminal started before or outside the session
# doesn't have them, and that is what this script is for.
set -u

RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
note() { printf '  %s\n' "$*" >&2; }
die()  { printf '\nrun.sh: %s\n' "$*" >&2; exit 1; }

# ── Qt platform ───────────────────────────────────────────────────────────
# Forced, not defaulted: a login shell that pins this to xcb is exactly the
# case this script exists to undo.
case "${QT_QPA_PLATFORM:-}" in
    *wayland*) : ;;
    "")        note "QT_QPA_PLATFORM: unset -> wayland" ;;
    *)         note "QT_QPA_PLATFORM: was '$QT_QPA_PLATFORM' -> wayland" ;;
esac
QT_QPA_PLATFORM=wayland
export QT_QPA_PLATFORM

# ── Wayland socket ────────────────────────────────────────────────────────
if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for _s in "$RT"/wayland-*; do
        case "$_s" in *.lock|*'wayland-*') continue ;; esac
        [ -S "$_s" ] || continue
        WAYLAND_DISPLAY="$(basename -- "$_s")"
        export WAYLAND_DISPLAY
        note "WAYLAND_DISPLAY: unset -> $WAYLAND_DISPLAY"
        break
    done
    [ -n "${WAYLAND_DISPLAY:-}" ] \
        || die "no Wayland socket in $RT — is a Wayland session running?"
fi

# ── Hyprland instance ─────────────────────────────────────────────────────
# Several can be live at once (a nested session, a leftover from a crash),
# so prefer the one whose socket actually answers, newest first.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    [ -d "$RT/hypr" ] || die "no Hyprland instance is running ($RT/hypr does not exist).
        This shell is a Hyprland shell: the bar's workspaces, the window
        menu, the overview and every keybind are the compositor's, over
        its IPC. Nothing replaces that on another compositor."

    _found=
    for _i in $(ls -1t "$RT/hypr" 2>/dev/null); do
        [ -S "$RT/hypr/$_i/.socket.sock" ] || continue
        if HYPRLAND_INSTANCE_SIGNATURE="$_i" hyprctl version >/dev/null 2>&1; then
            _found="$_i"; break
        fi
    done
    [ -n "$_found" ] || die "found $RT/hypr but no instance answered on its socket.
        Stale directories from an earlier session look like this; start the
        shell from a terminal inside the running Hyprland session instead."

    HYPRLAND_INSTANCE_SIGNATURE="$_found"
    export HYPRLAND_INSTANCE_SIGNATURE
    note "HYPRLAND_INSTANCE_SIGNATURE: unset -> $_found"
fi

command -v qs >/dev/null 2>&1 || die "quickshell (qs) is not on PATH."

# --restart replaces a running shell rather than adding a second one, which
# is the usual reason for running this by hand twice.
if [ "${1:-}" = "--restart" ]; then
    shift
    if pkill -x qs 2>/dev/null; then
        note "stopped the running shell"
        # Give the compositor a moment to drop its layer surfaces, or the new
        # instance races the old one's teardown.
        sleep 0.4
    fi
fi

# Memory, as hyprland.lua starts it: two glibc arenas rather than one per
# thread, and on a hybrid laptop Mesa's EGL driver rather than NVIDIA's —
# only where Mesa has a GPU to drive (not with the MUX on NVIDIA alone).
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
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
        note "hybrid graphics: the shell draws with Mesa, leaving the NVIDIA GPU asleep"
    fi
fi

# Hyprland hangs up after each request on its socket, which Quickshell
# would log as a warning every time (services/HyprIpc.qml).
export QT_LOGGING_RULES="${QT_LOGGING_RULES:+$QT_LOGGING_RULES;}quickshell.io.socket.warning=false"
exec qs -c hyprshell "$@"
