#!/usr/bin/env bash
#
# Builds and installs Hyprshell Mail: the app (hyprshell-mail) and its
# background service (hyprshell-maild), which keeps mail arriving with the
# window closed.
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
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
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
    else bad "$t" "sudo pacman -S --needed base-devel cmake"; MISSING=$((MISSING + 1)); fi
done
if command -v cargo >/dev/null 2>&1; then ok "cargo" "$(cargo --version 2>/dev/null | cut -d' ' -f2)"
else bad "cargo" "sudo pacman -S --needed rust   (the mail service is Rust)"; MISSING=$((MISSING + 1)); fi

# Qt is probed by configuring a throwaway project that asks for exactly the
# components needed, as Files' and Tasks' installers do.
qt_probe() {
    local d rc
    d="$(mktemp -d)" || return 1
    cat > "$d/CMakeLists.txt" <<PROBE
cmake_minimum_required(VERSION 3.16)
project(probe LANGUAGES CXX)
find_package(Qt6 6.5 REQUIRED COMPONENTS $1)
PROBE
    cmake -S "$d" -B "$d/b" >/dev/null 2>&1
    rc=$?
    rm -rf "$d"
    return $rc
}
if qt_probe "Core Gui Qml Quick Network"; then
    ok "Qt 6" "6.5 or newer, with Quick"
else
    bad "Qt 6" "sudo pacman -S --needed qt6-base qt6-declarative"
    MISSING=$((MISSING + 1))
fi
if qt_probe "WebEngineQuick"; then
    ok "Qt WebEngine" "formatted (HTML) mail shown in full"
else
    warn "Qt WebEngine" "not found — HTML mail simplified. sudo pacman -S qt6-webengine, then run this again"
fi

head1 "To run"
# Passwords and sign-ins live in the desktop keyring (the Secret Service).
if command -v busctl >/dev/null 2>&1 && busctl --user list 2>/dev/null | grep -q "org.freedesktop.secrets"; then
    ok "keyring" "a Secret Service is running"
elif command -v gnome-keyring-daemon >/dev/null 2>&1; then
    warn "keyring" "gnome-keyring is installed but not running — see below"
else
    warn "keyring" "none — sudo pacman -S gnome-keyring  (Mail keeps passwords there)"
fi
command -v notify-send >/dev/null 2>&1 && ok "notify-send" "new-mail notifications" \
    || warn "notify-send" "no new-mail notifications — sudo pacman -S libnotify"
command -v xdg-open >/dev/null 2>&1 && ok "xdg-open" "opening attachments and sign-in pages" \
    || warn "xdg-open" "sudo pacman -S xdg-utils"

if [ "$MODE" = check ]; then
    [ "$MISSING" -gt 0 ] && printf '\n%s%d required item(s) missing.%s\n' "$RED" "$MISSING" "$RST"
    exit 0
fi
if [ "$MISSING" -gt 0 ]; then
    printf '\n%s%d required item(s) missing.%s\n' "$RED" "$MISSING" "$RST"
    exit 1
fi

head1 "Building (the first time takes a few minutes: the service's Rust crates)"
BUILD="$SRC/build"
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" || { echo "configure failed" >&2; exit 1; }
cmake --build "$BUILD" --parallel || { echo "build failed" >&2; exit 1; }

head1 "Installing"
cmake --install "$BUILD" || { echo "install failed" >&2; exit 1; }
ok "app" "$PREFIX/bin/hyprshell-mail"
ok "service" "$PREFIX/bin/hyprshell-maild"
ok "desktop entry" "$PREFIX/share/applications/hyprshell-mail.desktop"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$PREFIX/share/applications" 2>/dev/null
ok "icon" "$PREFIX/share/icons/hicolor/scalable/apps/hyprshell-mail.svg"
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$PREFIX/share/icons/hicolor" 2>/dev/null

# mailto: links (in the browser, anywhere) open a new message here.
if command -v xdg-mime >/dev/null 2>&1; then
    xdg-mime default hyprshell-mail.desktop x-scheme-handler/mailto && ok "mailto: links" "open in Mail"
fi

# The service, as a systemd user unit: started with the session, restarted
# if it stops, so mail keeps arriving with the window closed.
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$UNIT_DIR"
cat > "$UNIT_DIR/hyprshell-maild.service" <<UNIT
[Unit]
Description=Hyprshell Mail service (keeps mail in sync, sends scheduled mail)
After=graphical-session.target

[Service]
ExecStart=$PREFIX/bin/hyprshell-maild
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable hyprshell-maild.service >/dev/null 2>&1
    if systemctl --user is-active --quiet hyprshell-maild.service; then
        systemctl --user restart hyprshell-maild.service && ok "service" "restarted on the new build"
    else
        systemctl --user start hyprshell-maild.service && ok "service" "running, and starts with each session"
    fi
else
    warn "service" "no systemd user session — the app starts it when it opens"
fi

case ":${PATH}:" in
    *":$PREFIX/bin:"*) ;;
    *) printf '\n  %snote%s %s/bin is not on your PATH.\n' "$YEL" "$RST" "$PREFIX" ;;
esac

cat <<EOF

  Run it:     hyprshell-mail                 (or "Mail" in the launcher)
  Write:      hyprshell-mail --compose       hyprshell-mail mailto:someone@example.com

  The first time, add an account. Gmail and Outlook sign in through the
  browser once you have made a client ID for each (free, a few minutes —
  see mail/README.md); Gmail can also use an app password, and any IMAP
  account (school, work) uses its password.

  Passwords and sign-ins are kept in the desktop keyring. The shell's
  hyprland.lua starts gnome-keyring at login when it is installed and no
  other keyring is running; the first time, it asks you to choose a
  password for the new keyring.
EOF
