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

# Qt 6 is probed by actually configuring a throwaway project that asks for
# the components this one needs. `cmake --find-package` is deprecated and
# answers "no" even where Qt 6 is plainly installed, and looking for qmake6
# is no better — distributions put it in different places and some omit it.
qt6_present() {
    local d
    d="$(mktemp -d)" || return 1
    cat > "$d/CMakeLists.txt" <<'PROBE'
cmake_minimum_required(VERSION 3.16)
project(probe LANGUAGES CXX)
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick)
PROBE
    cmake -S "$d" -B "$d/b" >/dev/null 2>&1
    local rc=$?
    rm -rf "$d"
    return $rc
}

if qt6_present; then
    ok "Qt 6" "6.2 or newer, with Quick"
else
    bad "Qt 6" "install qt6-base and qt6-declarative (with their -dev/-devel parts)"
    MISSING=$((MISSING + 1))
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
