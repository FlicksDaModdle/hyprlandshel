#!/usr/bin/env bash
#
# Builds and installs Hyprshell Images, the image viewer, and makes it
# what opens pictures.
#
#   ./install.sh                build, install to ~/.local, set as default
#   ./install.sh --no-default   install, but leave the default viewer alone
#   ./install.sh --check        report what's missing, build nothing
#   ./install.sh --prefix /usr/local
#
# Not `set -e`: most of this probes for things that may legitimately be
# absent, and a probe coming back negative should not take the script down
# mid-report.

set -u

PREFIX="${HOME}/.local"
MODE=install
DEFAULT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --check)      MODE=check ;;
        --no-default) DEFAULT=0 ;;
        --prefix)     shift; PREFIX="${1:-$PREFIX}" ;;
        -h|--help)    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
    else bad "$t" "required — sudo pacman -S --needed base-devel cmake"; MISSING=$((MISSING + 1)); fi
done
[ -d "$SRC/../files/qml" ] && ok "files/" "shared theme and icons" \
    || { bad "files/" "this needs the files folder beside it (it shares its theme)"; MISSING=$((MISSING + 1)); }

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
    bad "Qt 6" "on Arch/CachyOS: sudo pacman -S --needed qt6-base qt6-declarative"
    MISSING=$((MISSING + 1))
    sed -n '/CMake Error/,$p' "$QT_PROBE_LOG" | head -n 12 | sed 's/^/      /'
fi
rm -f "$QT_PROBE_LOG"

head1 "To open more kinds of picture — each only adds the formats named"
if [ -d /usr/lib/qt6/plugins/imageformats ] && ls /usr/lib/qt6/plugins/imageformats 2>/dev/null | grep -q webp; then
    ok "qt6-imageformats" "WebP, TIFF, TGA, ICNS"
else
    warn "qt6-imageformats" "for WebP and TIFF — sudo pacman -S qt6-imageformats"
fi
if ls /usr/lib/qt6/plugins/imageformats 2>/dev/null | grep -qi -e avif -e heif -e jxl; then
    ok "kimageformats" "AVIF, HEIC, JPEG XL, RAW"
else
    warn "kimageformats" "for AVIF, HEIC and JPEG XL — sudo pacman -S kimageformats"
fi
if ls /usr/lib/qt6/plugins/imageformats 2>/dev/null | grep -qi svg; then ok "qt6-svg" "SVG"
else warn "qt6-svg" "for SVG — sudo pacman -S qt6-svg"; fi
command -v hyprshell-files >/dev/null 2>&1 && ok "hyprshell-files" "the Open dialog and Show in folder" \
    || warn "hyprshell-files" "Open… needs Hyprshell Files; drop pictures on the window instead"

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
ok "program" "$PREFIX/bin/hyprshell-images"
ok "desktop entry" "$PREFIX/share/applications/hyprshell-images.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$PREFIX/share/applications" 2>/dev/null
fi

# What opens pictures: every image type the desktop entry lists.
if [ "$DEFAULT" = 1 ]; then
    if command -v xdg-mime >/dev/null 2>&1; then
        types=$(sed -n 's/^MimeType=//p' "$PREFIX/share/applications/hyprshell-images.desktop" | tr ';' ' ')
        # shellcheck disable=SC2086
        xdg-mime default hyprshell-images.desktop $types \
            && ok "default viewer" "pictures open in Images" \
            || warn "default viewer" "xdg-mime could not set it"
    else
        warn "default viewer" "xdg-mime is missing (xdg-utils); set it in your file manager"
    fi
fi

case ":${PATH}:" in
    *":$PREFIX/bin:"*) ;;
    *) printf '\n  %snote%s %s/bin is not on your PATH.\n' "$YEL" "$RST" "$PREFIX" ;;
esac

cat <<EOT

  Run it:   hyprshell-images [picture or folder]
            or open any picture from Files.
EOT
