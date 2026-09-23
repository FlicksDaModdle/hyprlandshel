#!/usr/bin/env bash
#
# Builds and installs Hyprshell Files.
#
#   ./install.sh            build and install to ~/.local
#   ./install.sh --check    report what's missing, build nothing
#   ./install.sh --prefix /usr/local
#
# Not `set -e`: most of this probes for things that may legitimately be
# absent, and a probe coming back negative should not take the script down
# mid-report.

set -u

PREFIX="${HOME}/.local"
MODE=install

while [ $# -gt 0 ]; do
    case "$1" in
        --check)  MODE=check ;;
        --prefix) shift; PREFIX="${1:-$PREFIX}" ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YEL=$'\033[33m'; RST=$'\033[0m'
else
    BOLD=; DIM=; RED=; GRN=; YEL=; RST=
fi
ok()   { printf '  %s✓%s %-22s %s%s%s\n' "$GRN" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
warn() { printf '  %s•%s %-22s %s%s%s\n' "$YEL" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
bad()  { printf '  %s✗%s %-22s %s%s%s\n' "$RED" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
head1(){ printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MISSING=0

head1 "To build"
for t in cmake make g++; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"
    else bad "$t" "required"; MISSING=$((MISSING + 1)); fi
done

# Which distribution, so the package names printed below are the ones you
# can actually type.
distro_id() {
    if [ -r /etc/os-release ]; then
        ( . /etc/os-release 2>/dev/null
          case "${ID:-}${ID_LIKE:-}" in
              *arch*)            echo arch ;;
              *debian*|*ubuntu*) echo debian ;;
              *fedora*|*rhel*)   echo fedora ;;
              *suse*)            echo suse ;;
              *)                 echo unknown ;;
          esac )
    else
        echo unknown
    fi
}
DISTRO="$(distro_id)"
# pkg <arch> <debian> <fedora> <suse>
pkg() {
    case "$DISTRO" in
        arch) printf '%s' "$1" ;; debian) printf '%s' "$2" ;;
        fedora) printf '%s' "$3" ;; suse) printf '%s' "$4" ;;
        *) printf '%s' "$1" ;;
    esac
}

# Qt 6 is probed by actually configuring a throwaway project that asks for
# the components this one needs. `cmake --find-package` is deprecated and
# answers "no" even where Qt 6 is plainly installed, and looking for qmake6
# is no better — distributions put it in different places and some omit it.
#
# The output is kept rather than thrown away: when this fails it is the only
# thing that says why, and "install qt6-base" on its own has sent people
# looking in the wrong place.
QT_PROBE_LOG="$(mktemp)"
qt6_present() {
    local d rc
    d="$(mktemp -d)" || return 1
    cat > "$d/CMakeLists.txt" <<'PROBE'
cmake_minimum_required(VERSION 3.16)
project(probe LANGUAGES CXX)
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick)
PROBE
    cmake -S "$d" -B "$d/b" > "$QT_PROBE_LOG" 2>&1
    rc=$?
    rm -rf "$d"
    return $rc
}

if qt6_present; then
    ok "Qt 6" "6.2 or newer, with Quick"
else
    bad "Qt 6" "install $(pkg 'qt6-base qt6-declarative' \
                              'qt6-base-dev qt6-declarative-dev' \
                              'qt6-qtbase-devel qt6-qtdeclarative-devel' \
                              'qt6-base-devel qt6-declarative-devel')"
    MISSING=$((MISSING + 1))
    printf '      %sthe probe said:%s\n' "$DIM" "$RST"
    sed -n '/CMake Error/,$p' "$QT_PROBE_LOG" | head -n 12 | sed 's/^/      /'
fi

# Qt 6 Gui asks CMake for the Vulkan headers whether or not anything uses
# Vulkan, and prints "Could NOT find WrapVulkanHeaders" when they are
# absent. On most builds of Qt that is a status line and nothing more —
# this program does not touch Vulkan and builds and runs perfectly without
# it. On a Qt that marks the dependency required it stops the configure
# dead, and the message looks the same either way, so it is worth saying
# which one you are looking at.
if grep -rqls "Could NOT find WrapVulkanHeaders" "$QT_PROBE_LOG" 2>/dev/null; then
    warn "Vulkan headers" "absent — Qt mentions it; harmless here, see below"
    VULKAN_NOTE=1
else
    VULKAN_NOTE=0
fi

head1 "To run — each one only affects the feature named"
if command -v gio >/dev/null 2>&1; then ok "gio" "trash, change watching, opening"
else bad "gio" "required: it is the trash and the change feed"; MISSING=$((MISSING + 1)); fi
command -v xdg-open >/dev/null 2>&1 && ok "xdg-open" "opening files" \
    || warn "xdg-open" "gio open is tried first, so this is the fallback"
command -v wl-copy  >/dev/null 2>&1 && ok "wl-copy" "copy path" \
    || warn "wl-copy" "\"Copy path\" needs wl-clipboard (or xclip)"
if command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -qi inter; then
    ok "Inter font" "text as designed"
else
    warn "Inter font" "falls back to the system sans"
fi

if [ "${VULKAN_NOTE:-0}" -eq 1 ]; then
    head1 "About \"Could NOT find WrapVulkanHeaders\""
    cat <<EOF
  Qt 6 Gui asks CMake for the Vulkan headers whether or not anything uses
  them. Nothing here does, and the build works without them — the line is
  a status message, not a failure. If the configure actually stopped at
  that point, your Qt marks the dependency required; install the headers
  and it goes away either way:

      $(pkg 'sudo pacman -S --needed vulkan-headers' \
            'sudo apt install libvulkan-dev' \
            'sudo dnf install vulkan-headers' \
            'sudo zypper install vulkan-devel')
EOF
fi

if [ "$MODE" = check ]; then
    head1 "Check only — nothing was built."
    [ "$MISSING" -gt 0 ] && exit 1
    exit 0
fi

if [ "$MISSING" -gt 0 ]; then
    printf '\n%s%d required item(s) missing.%s\n' "$RED" "$MISSING" "$RST"
    exit 1
fi

head1 "Building"
BUILD="$SRC/build"
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" || { echo "configure failed" >&2; exit 1; }
cmake --build "$BUILD" --parallel || { echo "build failed" >&2; exit 1; }

head1 "Installing"
cmake --install "$BUILD" || { echo "install failed" >&2; exit 1; }
printf '  installed %s/bin/hyprshell-files\n' "$PREFIX"
printf '  installed %s/share/applications/hyprshell-files.desktop\n' "$PREFIX"

# A desktop entry nothing knows about is a desktop entry that does not open
# folders, so refresh the cache if the tool is there.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$PREFIX/share/applications" 2>/dev/null \
        && printf '  refreshed the desktop database\n'
fi

# ── file dialogs ─────────────────────────────────────────────────────────
#
# Which program shows a "Save as…" is not decided by the MIME database and
# not by the browser. Firefox asks xdg-desktop-portal, which picks a
# *backend* per interface from its own configuration, and on a machine with
# the KDE backend installed the one answering FileChooser is Dolphin's.
# That is why saving a download kept opening Dolphin however `xdg-mime
# default` was set: the choice was never in that file.
#
# This points FileChooser at the backend just installed, and leaves every
# other interface — screenshot, screencast, the rest — exactly as it was.
head1 "File dialogs"

# The config xdg-desktop-portal reads is named after the desktop, so ask
# the session rather than assuming. Run from a bare TTY there is nothing to
# ask, and hyprland is the right guess for this shell.
DESK="$(printf '%s' "${XDG_CURRENT_DESKTOP:-hyprland}" | cut -d: -f1 | tr '[:upper:]' '[:lower:]')"
PORTAL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal"
PORTAL_CONF="$PORTAL_DIR/${DESK}-portals.conf"
PORTAL_KEY="org.freedesktop.impl.portal.FileChooser"
PORTAL_LINE="$PORTAL_KEY=hyprshell"

if ! command -v xdg-desktop-portal >/dev/null 2>&1 \
   && [ ! -e /usr/libexec/xdg-desktop-portal ] \
   && [ ! -e /usr/lib/xdg-desktop-portal ]; then
    warn "xdg-desktop-portal" "not installed — browsers will use their own dialogs"
elif [ "$MODE" = check ]; then
    if [ -r "$PORTAL_CONF" ] && grep -q "^[[:space:]]*$PORTAL_LINE" "$PORTAL_CONF"; then
        ok "portal config" "already points at hyprshell"
    else
        warn "portal config" "would set $PORTAL_KEY in $PORTAL_CONF"
    fi
elif [ -r "$PORTAL_CONF" ] && grep -q "^[[:space:]]*$PORTAL_LINE" "$PORTAL_CONF"; then
    ok "portal config" "already points at hyprshell"
else
    mkdir -p "$PORTAL_DIR"
    if [ ! -e "$PORTAL_CONF" ]; then
        # default= is what answers every interface this does not
        # implement, and leaving it out would answer none of them.
        cat > "$PORTAL_CONF" <<PORTALEOF
[preferred]
default=$DESK;gtk
$PORTAL_LINE
PORTALEOF
        ok "portal config" "wrote $PORTAL_CONF"
    else
        cp -p "$PORTAL_CONF" "$PORTAL_CONF.before-hyprshell"
        if grep -q "^[[:space:]]*$PORTAL_KEY[[:space:]]*=" "$PORTAL_CONF"; then
            sed -i "s|^[[:space:]]*$PORTAL_KEY[[:space:]]*=.*|$PORTAL_LINE|" "$PORTAL_CONF"
        elif grep -q '^\[preferred\]' "$PORTAL_CONF"; then
            sed -i "0,/^\[preferred\]/s||[preferred]\n$PORTAL_LINE|" "$PORTAL_CONF"
        else
            printf '\n[preferred]\n%s\n' "$PORTAL_LINE" >> "$PORTAL_CONF"
        fi
        ok "portal config" "updated $PORTAL_CONF"
        printf '  %skept the previous one as %s.before-hyprshell%s\n' \
               "$DIM" "$PORTAL_CONF" "$RST"
    fi
    printf '  %sxdg-desktop-portal reads this once, at start:%s\n' "$DIM" "$RST"
    printf '  %s  systemctl --user restart xdg-desktop-portal%s\n' "$DIM" "$RST"
fi

# Where xdg-desktop-portal looks for backends at all.
#
# It reads the list from XDG_DATA_DIRS, whose default is /usr/local/share
# and /usr/share — and *not* ~/.local/share, which is where this installs
# by default. The .portal file just installed would then never be read:
# the backend would sit on the bus, correctly registered, and nothing
# would ever ask it for a dialog. No error anywhere, dialogs simply
# keep opening in whatever was answering before.
SHARE="$PREFIX/share"
case ":${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:" in
    *":$SHARE:"*)
        [ "$MODE" = check ] || ok "portal search path" "$SHARE is on XDG_DATA_DIRS" ;;
    *)
        if [ "$MODE" = check ]; then
            warn "portal search path" "$SHARE is not on XDG_DATA_DIRS"
        else
            ENVD="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d"
            mkdir -p "$ENVD"
            # The value is written out in full rather than as
            # $SHARE:${XDG_DATA_DIRS}: environment.d expands an unset
            # variable to nothing, and the trailing colon that leaves
            # behind means "the current directory" to some readers of
            # this list.
            cat > "$ENVD/50-hyprshell-files.conf" <<ENVEOF
# Written by hyprshell-files' install.sh.
#
# xdg-desktop-portal finds file-dialog backends under XDG_DATA_DIRS, which
# does not include this prefix by default.
XDG_DATA_DIRS=$SHARE:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}
ENVEOF
            warn "portal search path" "$SHARE was not on XDG_DATA_DIRS"
            printf '  %swrote %s/50-hyprshell-files.conf%s\n' \
                   "$DIM" "$ENVD" "$RST"
            printf '  %sit applies at the next login, or now with:%s\n' "$DIM" "$RST"
            printf '  %s  systemctl --user set-environment XDG_DATA_DIRS=%s:%s%s\n' \
                   "$DIM" "$SHARE" "${XDG_DATA_DIRS:-/usr/local/share:/usr/share}" "$RST"
            printf '  %s  systemctl --user restart xdg-desktop-portal%s\n' "$DIM" "$RST"
        fi ;;
esac

case ":${PATH}:" in
    *":$PREFIX/bin:"*) ;;
    *) printf '\n  %snote%s %s/bin is not on your PATH.\n' "$YEL" "$RST" "$PREFIX" ;;
esac

cat <<EOF

  Run it:      hyprshell-files [directory]
  Default it:  xdg-mime default hyprshell-files.desktop inode/directory

  It also answers two things the desktop asks of a file manager: "show in
  file manager" (org.freedesktop.FileManager1), and the file dialogs
  browsers put up when saving or attaching (the FileChooser portal). Both
  start it on demand through the session bus — there is nothing to leave
  running.

  It follows the shell's theme.json when that is installed, and keeps its
  own settings in \$XDG_CONFIG_HOME/hyprshell-files/settings.json.
EOF
