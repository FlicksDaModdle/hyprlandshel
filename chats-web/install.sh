#!/bin/sh
# Install Chats Web: WhatsApp Web in a window of its own, in Hyprshell's colours.
# (The native client is Chats, in apps/; this is for calls, which only
# WhatsApp Web can make.)
#
#   ./install.sh              install it for you (~/.local)
#   ./install.sh --check      say what's missing, install nothing
#   ./install.sh --uninstall  take it out again; add --purge to also sign out
#                             (deletes its saved session in ~/.config/hyprshell-chats-web)
#
# It runs on the system's Electron (sudo pacman -S --needed electron), so it
# gets Chromium's security updates with the rest of the system and there is
# nothing here to download or build.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
SHARE="$DATA/hyprshell-chats-web"
BIN="$HOME/.local/bin"
APPS="$DATA/applications"
ICONS="$DATA/icons/hicolor/scalable/apps"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}/hyprshell-chats-web"

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RST=$(printf '\033[0m')
    GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m'); RED=$(printf '\033[31m')
else
    BOLD= DIM= RST= GRN= YEL= RED=
fi
did()  { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
note() { printf '    %s·%s %s\n' "$YEL" "$RST" "$1"; }
die()  { printf '    %s✗%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

mode=install purge=0
for a in "$@"; do
    case "$a" in
        --check)     mode=check ;;
        --uninstall|--remove) mode=uninstall ;;
        --purge)     purge=1 ;;
        -h|--help)   sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $a" ;;
    esac
done

printf '%sChats Web%s\n' "$BOLD" "$RST"

if [ "$mode" = uninstall ]; then
    rm -f "$BIN/hyprshell-chats-web" "$APPS/hyprshell-chats-web.desktop" "$ICONS/hyprshell-chats-web.svg"
    rm -rf "${SHARE:?}/app"
    rmdir "$SHARE" 2>/dev/null || true
    did "removed"
    if [ "$purge" = 1 ]; then
        rm -rf "${CONF:?}"
        did "signed out (its session and settings are gone)"
    else
        note "your session stays in $CONF (--purge removes it)"
    fi
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null || true
    exit 0
fi

# The same search the launcher below does at every start.
find_electron() {
    if [ -n "${HYPRSHELL_ELECTRON:-}" ] && command -v "$HYPRSHELL_ELECTRON" >/dev/null 2>&1; then
        command -v "$HYPRSHELL_ELECTRON"; return 0
    fi
    command -v electron 2>/dev/null && return 0
    for d in /usr/bin /usr/local/bin "$HOME/.local/bin"; do
        ls "$d"/electron[0-9]* 2>/dev/null
    done | sort -V | tail -n 1 | grep . && return 0
    return 1
}

if e=$(find_electron); then
    v=$("$e" --version 2>/dev/null || true)
    did "Electron ${v:-found} ${DIM}($e)${RST}"
else
    [ "$mode" = check ] && { note "Electron is missing — sudo pacman -S --needed electron"; exit 1; }
    die "Electron is missing — sudo pacman -S --needed electron (then run this again)"
fi
[ "$mode" = check ] && exit 0

mkdir -p "$SHARE/app" "$BIN" "$APPS" "$ICONS"
for f in package.json main.js theme.js icon.js preload-web.js preload-ui.js titlebar.html offline.html; do
    install -m 644 "$HERE/$f" "$SHARE/app/$f"
done
install -m 644 "$HERE/hyprshell-chats-web.svg" "$ICONS/hyprshell-chats-web.svg"
did "app in $SHARE/app"

cat > "$BIN/hyprshell-chats-web.new" <<'EOF'
#!/bin/sh
# Chats Web (hyprshell/chats-web). Finds the system's Electron at every start, so an
# upgrade from electron37 to electron38 doesn't leave it pointing at nothing.
APP="${XDG_DATA_HOME:-$HOME/.local/share}/hyprshell-chats-web/app"
E="${HYPRSHELL_ELECTRON:-}"
[ -n "$E" ] && ! command -v "$E" >/dev/null 2>&1 && E=
[ -z "$E" ] && E=$(command -v electron 2>/dev/null)
if [ -z "$E" ]; then
    E=$(for d in /usr/bin /usr/local/bin "$HOME/.local/bin"; do ls "$d"/electron[0-9]* 2>/dev/null; done | sort -V | tail -n 1)
fi
if [ -z "$E" ]; then
    notify-send "Chats Web" "Electron is not installed — sudo pacman -S electron" 2>/dev/null
    exit 127
fi
# Wayland whenever there is one: "auto" goes by XDG_SESSION_TYPE, which a
# session started some ways doesn't set, and then it looks for X instead.
PLATFORM=--ozone-platform-hint=auto
[ -n "${WAYLAND_DISPLAY:-}" ] && PLATFORM=--ozone-platform=wayland
exec "$E" "$PLATFORM" --enable-wayland-ime --class=hyprshell-chats-web "$APP" "$@"
EOF
chmod 755 "$BIN/hyprshell-chats-web.new"
mv -f "$BIN/hyprshell-chats-web.new" "$BIN/hyprshell-chats-web"
did "launcher $BIN/hyprshell-chats-web"

cat > "$APPS/hyprshell-chats-web.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Chats Web
GenericName=Messaging
Comment=WhatsApp Web in a window, for calls and anything Chats can't do yet
Exec=$BIN/hyprshell-chats-web %U
Icon=hyprshell-chats-web
Terminal=false
Categories=Network;InstantMessaging;Chat;
Keywords=WhatsApp;Messages;Chat;Calls;
StartupWMClass=hyprshell-chats-web
StartupNotify=true
EOF
did "desktop entry"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null || true

case ":$PATH:" in
    *":$BIN:"*) ;;
    *) note "$BIN is not on your PATH; the launcher finds Chats Web anyway" ;;
esac
printf '\n    Open %sChats Web%s from the launcher and scan the code with WhatsApp on your phone\n' "$BOLD" "$RST"
printf '    (Settings → Linked devices → Link a device).\n'
