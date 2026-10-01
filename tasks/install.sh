#!/usr/bin/env bash
#
# Builds and installs the Hyprshell task manager.
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
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
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

# Qt 6 is probed by configuring a throwaway project that asks for exactly
# the components this one needs — the same way files/install.sh does, for
# the same reasons (find-package is deprecated, qmake6 moves about).
QT_PROBE_LOG="$(mktemp)"
qt6_present() {
    local d rc
    d="$(mktemp -d)" || return 1
    cat > "$d/CMakeLists.txt" <<'PROBE'
cmake_minimum_required(VERSION 3.16)
project(probe LANGUAGES CXX)
find_package(Qt6 6.2 REQUIRED COMPONENTS Core Gui Qml Quick Network DBus)
PROBE
    cmake -S "$d" -B "$d/b" > "$QT_PROBE_LOG" 2>&1
    rc=$?
    rm -rf "$d"
    return $rc
}
if qt6_present; then
    ok "Qt 6" "6.2 or newer, with Quick and D-Bus"
else
    bad "Qt 6" "on Arch/CachyOS: sudo pacman -S --needed qt6-base qt6-declarative"
    MISSING=$((MISSING + 1))
    sed -n '/CMake Error/,$p' "$QT_PROBE_LOG" | head -n 12 | sed 's/^/      /'
fi
rm -f "$QT_PROBE_LOG"

# Everything below is read when present and skipped when not; each line
# says what goes missing without it.
head1 "To run — each one only affects the feature named"
command -v systemctl >/dev/null 2>&1 && ok "systemctl" "services, startup apps, flight recorder" \
    || warn "systemctl" "no Services view and no flight recorder"
command -v pkexec >/dev/null 2>&1 && ok "pkexec" "acting on other users' processes and system services" \
    || warn "pkexec" "\"as administrator\" actions are unavailable (polkit)"
command -v pacman >/dev/null 2>&1 && ok "pacman" "installed apps" \
    || warn "pacman" "installed apps lists Flatpak only"
command -v flatpak >/dev/null 2>&1 && ok "flatpak" "Flatpak apps in Installed apps" \
    || warn "flatpak" "not installed — fine"
command -v nvidia-smi >/dev/null 2>&1 && ok "nvidia-smi" "NVIDIA load and memory, while the card is awake" \
    || warn "nvidia-smi" "no NVIDIA card, or its tools aren't installed"
command -v du >/dev/null 2>&1 && ok "du" "disk space" || warn "du" "no Disk space view"
command -v modinfo >/dev/null 2>&1 && ok "modinfo" "driver details" || warn "modinfo" "drivers listed without details"
if [ -r /usr/share/hwdata/pci.ids ] || [ -r /usr/share/misc/pci.ids ]; then
    ok "pci.ids" "devices by name"
else
    warn "pci.ids" "devices shown by number — install hwdata"
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
ok "program" "$PREFIX/bin/hyprshell-tasks"
ok "desktop entry" "$PREFIX/share/applications/hyprshell-tasks.desktop"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$PREFIX/share/applications" 2>/dev/null
fi

# A running flight recorder is the previous build; its unit points at the
# same path, so a restart is all it takes to pick the new one up.
if systemctl --user is-active --quiet hyprshell-tasks-recorder.service 2>/dev/null; then
    systemctl --user restart hyprshell-tasks-recorder.service \
        && ok "flight recorder" "restarted on the new build"
fi

case ":${PATH}:" in
    *":$PREFIX/bin:"*) ;;
    *) printf '\n  %snote%s %s/bin is not on your PATH.\n' "$YEL" "$RST" "$PREFIX" ;;
esac

cat <<EOF

  Run it:   hyprshell-tasks            (or Ctrl+Shift+Esc with the shell's config)
            hyprshell-tasks --view performance
  Measure:  hyprshell-tasks --bench cpu|memory|disk [folder]

  Its settings live in \$XDG_CONFIG_HOME/hyprshell-tasks/settings.json, and
  what it records in ~/.local/share/hyprshell-tasks/.

  "As administrator" actions ask through polkit. The shell carries its own
  polkit agent for that — re-run ../shell/install.sh if a password prompt
  never appears.
EOF
