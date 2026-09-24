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

# The bus has to be told the backend exists.
#
# A bus daemon lists its activatable services when it starts and watches
# the directories it found then — so an install that *creates*
# ~/.local/share/dbus-1/services, which this one does on a first run,
# leaves the file in a directory nothing is watching. The name stays
# unknown however correct the file is, and every file dialog fails with
# "The name is not activatable", which reads like a broken service
# rather than an unread one. Asking for a reload here costs nothing and
# saves that entire diagnosis.
SVC=org.freedesktop.impl.portal.desktop.hyprshell
if command -v gdbus >/dev/null 2>&1 && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    gdbus call --session --dest org.freedesktop.DBus \
          --object-path /org/freedesktop/DBus \
          --method org.freedesktop.DBus.ReloadConfig >/dev/null 2>&1
    case "$(gdbus call --session --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.ListActivatableNames 2>/dev/null)" in
        *"$SVC"*) ok "session bus" "can start the backend on demand" ;;
        *)        warn "session bus" "does not list $SVC yet"
                  printf '  %sa fresh login will pick it up; or:%s\n' "$DIM" "$RST"
                  printf '  %s  systemctl --user reload dbus.service%s\n' "$DIM" "$RST" ;;
    esac
elif [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    warn "session bus" "not reachable from here, so it was not told to re-read"
    printf '  %srun this inside the session, or log out and back in%s\n' "$DIM" "$RST"
fi

# Anything the bus starts inherits the bus daemon's environment, which was
# fixed before this session existed. Without WAYLAND_DISPLAY in it a Qt
# program cannot find a display at all and dies during startup, and the
# caller is told only that activation failed. The backend is registered
# through systemd for that reason, so what matters is whether the *user
# manager* has the session's environment.
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null \
        && ok "systemd" "reloaded user units"
    if systemctl --user show-environment 2>/dev/null | grep -q '^WAYLAND_DISPLAY='; then
        ok "session environment" "the user manager knows WAYLAND_DISPLAY"
    else
        warn "session environment" "the user manager has no WAYLAND_DISPLAY"
        printf '  %sanything the bus starts will have no display to open on. The%s\n' "$DIM" "$RST"
        printf '  %sshell'"'"'s hyprland.lua does this at login; for now:%s\n' "$DIM" "$RST"
        printf '  %s  dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP%s\n' "$DIM" "$RST"
    fi
fi

# Which program opens a folder.
#
# A different question from the one above, and answered somewhere else
# entirely: FileManager1 is asked to *show a particular file*, while
# opening a folder — from a downloads list, from xdg-open, from a
# portal's OpenDirectory — goes to whatever the MIME database says
# handles inode/directory. A machine with Dolphin installed usually says
# Dolphin, and that setting is why a folder kept opening there while
# everything else was pointed here.
if command -v xdg-mime >/dev/null 2>&1; then
    FOLDER_CUR=$(xdg-mime query default inode/directory 2>/dev/null)
    if [ "$FOLDER_CUR" = hyprshell-files.desktop ]; then
        ok "folder handler" "already hyprshell-files.desktop"
    elif [ "$MODE" = check ]; then
        warn "folder handler" "is ${FOLDER_CUR:-unset} — would be set to hyprshell-files.desktop"
    elif xdg-mime default hyprshell-files.desktop inode/directory 2>/dev/null; then
        # x-directory/normal is the same thing under an older name, and
        # enough programs still ask for it that leaving it pointing
        # elsewhere splits the behaviour in two.
        xdg-mime default hyprshell-files.desktop x-directory/normal 2>/dev/null
        ok "folder handler" "hyprshell-files.desktop${FOLDER_CUR:+ (was $FOLDER_CUR)}"
        [ -n "$FOLDER_CUR" ] && printf '  %sto put it back: xdg-mime default %s inode/directory%s\n' \
                                       "$DIM" "$FOLDER_CUR" "$RST"
    else
        warn "folder handler" "could not be set"
    fi
fi

# Firefox has to be told to ask at all. Its own GTK dialog is the default
# for an unsandboxed build — widget.use-xdg-desktop-portal.file-picker is
# 2, "auto", which means the portal only when sandboxed. At 2 none of the
# above is ever consulted, and the dialog that opens is Firefox's own.
# Not written for you: prefs.js belongs to the browser, and editing it
# under a running Firefox is undone the moment it exits.
warn "firefox" "about:config → widget.use-xdg-desktop-portal.file-picker → 1"

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

  If a dialog still opens in something else:  ./portal-doctor.sh

  It follows the shell's theme.json when that is installed, and keeps its
  own settings in \$XDG_CONFIG_HOME/hyprshell-files/settings.json.
EOF
