#!/usr/bin/env bash
#
# Builds and installs Hyprshell Terminal.
#
#   ./install.sh            build and install to ~/.local
#   ./install.sh --check    report what's missing, build nothing
#   ./install.sh --prefix /usr/local
#
# Not `set -e`: most of this probes for things that may legitimately be
# absent, and a probe coming back negative should not take the script
# down mid-report.

set -u

PREFIX="${HOME}/.local"
MODE=install

while [ $# -gt 0 ]; do
    case "$1" in
        --check)  MODE=check ;;
        --prefix) shift; PREFIX="${1:-$PREFIX}" ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
for t in cmake make g++ pkg-config; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"
    else bad "$t" "required"; MISSING=$((MISSING + 1)); fi
done

# libvterm is the terminal emulation itself. Without it there is nothing
# to build: this program is a window around it.
if pkg-config --exists vterm 2>/dev/null; then
    ok "libvterm" "$(pkg-config --modversion vterm)"
else
    bad "libvterm" "required — the terminal emulation"
    MISSING=$((MISSING + 1))
    if [ -r /etc/os-release ]; then
        case "$( . /etc/os-release 2>/dev/null; echo "${ID:-}${ID_LIKE:-}" )" in
            *arch*)            printf '      sudo pacman -S libvterm\n' ;;
            *debian*|*ubuntu*) printf '      sudo apt install libvterm-dev\n' ;;
            *fedora*|*rhel*)   printf '      sudo dnf install libvterm-devel\n' ;;
            *suse*)            printf '      sudo zypper install libvterm-devel\n' ;;
        esac
    fi
fi

# Qt 6, probed by configuring a throwaway project rather than by guessing
# at file names — see files/install.sh for the long version of why.
TMP="$(mktemp -d)"
cat > "$TMP/CMakeLists.txt" <<'PROBE'
cmake_minimum_required(VERSION 3.21)
project(probe LANGUAGES CXX)
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick)
PROBE
if cmake -S "$TMP" -B "$TMP/b" >"$TMP/log" 2>&1; then
    ok "Qt 6" "$(sed -n 's/.*Found Qt6.*version \([0-9.]*\).*/\1/p' "$TMP/log" | head -1)"
else
    bad "Qt 6" "required (Core, Gui, Qml, Quick)"
    MISSING=$((MISSING + 1))
    printf '      %sthe probe said:%s\n' "$DIM" "$RST"
    sed -n 's/^/      /p' "$TMP/log" | tail -4
fi

head1 "Optional"
if fc-list 2>/dev/null | grep -qi "JetBrainsMono\|JetBrains Mono"; then
    ok "JetBrains Mono" "the default grid font"
else
    warn "JetBrains Mono" "not installed — set monoFamily in theme.json, or install it"
fi

if [ "$MODE" = check ]; then
    head1 "Check only — nothing was built."
    [ "$MISSING" -gt 0 ] && exit 1
    exit 0
fi
[ "$MISSING" -gt 0 ] && { printf '\n%s%d required item(s) missing.%s\n' "$RED" "$MISSING" "$RST"; exit 1; }

head1 "Building"
BUILD="$SRC/build"
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" || { echo "configure failed" >&2; exit 1; }
cmake --build "$BUILD" --parallel || { echo "build failed" >&2; exit 1; }

head1 "Installing"
cmake --install "$BUILD" || { echo "install failed" >&2; exit 1; }
printf '  installed %s/bin/hyprshell-term\n' "$PREFIX"
command -v update-desktop-database >/dev/null 2>&1 \
    && update-desktop-database "$PREFIX/share/applications" 2>/dev/null \
    && printf '  refreshed the desktop database\n'

# Make it the terminal the rest of the desktop opens, unless told not to.
#
# Offered rather than assumed when there is someone to ask: this changes
# settings outside this program's own, and a build script that quietly
# repoints the desktop's default terminal is not a good guest.
if [ "${NO_DEFAULT:-}" = 1 ]; then
    printf '  skipped making it the default terminal (NO_DEFAULT=1)\n'
elif [ -t 0 ]; then
    printf '\n  Make it the default terminal for the whole desktop? [Y/n] '
    read -r answer
    case "$answer" in
        [Nn]*) printf '  left alone — run ./set-default-terminal.sh later\n' ;;
        *)     sh "$SRC/set-default-terminal.sh" ;;
    esac
else
    printf '\n  To make it the desktop default:  ./set-default-terminal.sh\n'
fi

cat <<EOS

  Run it:  hyprshell-term
           hyprshell-term -e <command>
           hyprshell-term --working-directory ~/src

  The shell already opens this one: the dock's Terminal tile, super+Return,
  "Open terminal here" and the Files app all look for it first and fall
  back to whatever else you have. The shell's Hyprland config carries a
  size rule for it and sets \$TERMINAL.

  It reads the shell's theme.json for its palette, and takes the grid
  font from monoFamily there.
EOS
