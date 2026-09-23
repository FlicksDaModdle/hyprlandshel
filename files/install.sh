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

case ":${PATH}:" in
    *":$PREFIX/bin:"*) ;;
    *) printf '\n  %snote%s %s/bin is not on your PATH.\n' "$YEL" "$RST" "$PREFIX" ;;
esac

cat <<EOF

  Run it:      hyprshell-files [directory]
  Default it:  xdg-mime default hyprshell-files.desktop inode/directory

  It follows the shell's theme.json when that is installed, and keeps its
  own settings in \$XDG_CONFIG_HOME/hyprshell-files/settings.json.
EOF
