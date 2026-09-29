#!/bin/sh
# Install the Hyprshell greeter — the login screen, in the shell's design,
# run by greetd.
#
#   sudo ./install.sh              install it, and point greetd at it
#   sudo ./install.sh --enable     …and make greetd the display manager,
#                                  turning off sddm/gdm/lightdm/ly if one is on
#   sudo ./install.sh --theme      only copy your current theme to it again
#   sudo ./install.sh --uninstall  put greetd's previous config back and
#                                  remove the greeter
#
# How it fits together:
#
#   greetd  →  Hyprland, with /etc/hyprshell-greeter/hyprland.lua
#           →  quickshell -p /usr/share/hyprshell-greeter/shell.qml
#
# The greeter runs as greetd's own unprivileged user. Your password goes to
# greetd, which checks it with PAM and starts your session as you.
#
# If anything goes wrong at the login screen, switch to a text console with
# Ctrl+Alt+F2, log in there, and run `sudo ./install.sh --uninstall` — or
# copy /etc/greetd/config.toml.before-hyprshell back over config.toml.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

# Everything below is under $ROOT, which is / unless --root is given (for
# trying the install out on a scratch directory).
ROOT=""
enable=0 uninstall=0 themeonly=0
while [ $# -gt 0 ]; do
    case "$1" in
        --enable)    enable=1 ;;
        --uninstall) uninstall=1 ;;
        --theme)     themeonly=1 ;;
        --root)      shift; ROOT="${1%/}" ;;
        -h|--help)   sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

SHARE="$ROOT/usr/share/hyprshell-greeter"
ETC="$ROOT/etc/hyprshell-greeter"
STATE="$ROOT/var/lib/hyprshell-greeter"
CACHE="$ROOT/var/cache/hyprshell-greeter"
ICONS="$ROOT/var/lib/AccountsService/icons"
GREETD="$ROOT/etc/greetd"
CONF="$GREETD/config.toml"
BACKUP="$CONF.before-hyprshell"

if [ -t 1 ]; then
    GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m'); RED=$(printf '\033[31m'); RST=$(printf '\033[0m')
else
    GRN= YEL= RED= RST=
fi
did()  { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
note() { printf '    %s·%s %s\n' "$YEL" "$RST" "$1"; }
die()  { printf '    %s✗%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run it with sudo — it writes to /etc and /usr/share"

# Whose theme the greeter wears: whoever ran sudo.
PERSON="${SUDO_USER:-}"
[ -n "$PERSON" ] && [ "$PERSON" != root ] || PERSON=""
home_of() { getent passwd "$1" | cut -d: -f6; }

# greetd's own user: what its config already names, else "greeter", which is
# what greetd's packages create.
greeter_user() {
    u=""
    # From [default_session] only: an [initial_session] (auto-login) names
    # a person, not greetd's user.
    [ -f "$CONF" ] && u=$(awk '/^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[default_session\]/) }
        s && /^[[:space:]]*user[[:space:]]*=/ { sub(/^[^"]*"/, ""); sub(/".*/, ""); print }' "$CONF" | tail -n1)
    printf '%s' "${GREETER_USER:-${u:-greeter}}"
}

copy_theme() {
    gu=$1
    mkdir -p "$STATE/config/quickshell/hyprshell"
    if [ -n "$PERSON" ]; then
        src="$(home_of "$PERSON")/.config/quickshell/hyprshell/theme.json"
        if [ -f "$src" ]; then
            cp "$src" "$STATE/config/quickshell/hyprshell/theme.json"
            did "your theme (accent, light or dark, fonts, rounding) from $src"
        else
            note "no theme.json for $PERSON yet — the greeter starts with the default look"
        fi
    fi
    # The greeter writes to it (the theme code keeps the file up to date),
    # so it is the greeter's.
    chown -R "$gu" "$STATE"
}

# ── uninstall ─────────────────────────────────────────────────────────────
if [ "$uninstall" = 1 ]; then
    if [ -f "$BACKUP" ]; then
        mv -f "$BACKUP" "$CONF"
        did "greetd's previous config put back"
    elif [ -f "$CONF" ] && grep -q hyprshell-greeter "$CONF"; then
        note "no backup of greetd's previous config — $CONF still points at the greeter; edit it by hand"
    fi
    rm -rf "$SHARE" "$ETC" "$STATE" "$CACHE"
    did "greeter removed"
    exit 0
fi

GU=$(greeter_user)
id -u "$GU" >/dev/null 2>&1 || die "greetd's user '$GU' does not exist — install greetd first (pacman -S greetd)"

if [ "$themeonly" = 1 ]; then
    [ -d "$SHARE" ] || die "the greeter is not installed yet — run this without --theme"
    copy_theme "$GU"
    exit 0
fi

# ── what it needs ─────────────────────────────────────────────────────────
command -v greetd >/dev/null 2>&1 || [ -x /usr/bin/greetd ] || die "greetd is not installed (pacman -S greetd)"
QS=$(command -v qs 2>/dev/null || command -v quickshell 2>/dev/null || true)
[ -n "$QS" ] || die "quickshell is not installed"
if command -v start-hyprland >/dev/null 2>&1; then
    COMP="$(command -v start-hyprland) -- --config /etc/hyprshell-greeter/hyprland.lua"
elif command -v Hyprland >/dev/null 2>&1; then
    COMP="$(command -v Hyprland) --config /etc/hyprshell-greeter/hyprland.lua"
else
    die "Hyprland is not installed"
fi

# ── the greeter itself ────────────────────────────────────────────────────
# Its own files, and the three parts of the shell it is drawn with — the
# theme and the shared components — copied beside it: Quickshell only
# loads what is inside the folder a config lives in.
rm -rf "$SHARE.new"
mkdir -p "$SHARE.new/shell/modules"
cp "$HERE"/*.qml "$SHARE.new/"
cp -R "$REPO/shell/quickshell/config" "$SHARE.new/shell/config"
cp -R "$REPO/shell/quickshell/modules/common" "$SHARE.new/shell/modules/common"
cp -R "$REPO/shell/quickshell/modules/icons" "$SHARE.new/shell/modules/icons"
rm -rf "$SHARE"
mv "$SHARE.new" "$SHARE"
chmod -R a+rX "$SHARE"
did "greeter in ${SHARE#$ROOT}"

copy_theme "$GU"

# Your picture, where every display manager looks for one — only if you
# have a ~/.face and nothing is there already.
if [ -n "$PERSON" ] && [ ! -e "$ICONS/$PERSON" ] && [ -f "$(home_of "$PERSON")/.face" ]; then
    mkdir -p "$ICONS"
    install -m 644 "$(home_of "$PERSON")/.face" "$ICONS/$PERSON"
    did "your ~/.face as your picture"
fi

# Where it remembers who logged in last, and into what.
mkdir -p "$CACHE"
chown "$GU" "$CACHE"
chmod 700 "$CACHE"

# The keyboard layout you are typing with now, so the password is typed on
# the same one. Best effort: from the running Hyprland, else "us".
layout=us variant=""
if [ -n "$PERSON" ]; then
    uid=$(id -u "$PERSON")
    sig=$(ls "/run/user/$uid/hypr" 2>/dev/null | head -n1 || true)
    # Found here, not by sudo, whose own PATH may not be the one it is on.
    hctl=$(command -v hyprctl 2>/dev/null || true)
    if [ -n "$sig" ] && [ -n "$hctl" ]; then
        ask() {
            sudo -u "$PERSON" env XDG_RUNTIME_DIR="/run/user/$uid" HYPRLAND_INSTANCE_SIGNATURE="$sig" \
                "$hctl" getoption "$1" 2>/dev/null | sed -n 's/^str: //p' | head -n1 || true
        }
        l=$(ask input:kb_layout); v=$(ask input:kb_variant)
        [ -n "$l" ] && [ "$l" != "[[EMPTY]]" ] && layout=$l
        [ -n "$v" ] && [ "$v" != "[[EMPTY]]" ] && variant=$v
    fi
fi

mkdir -p "$ETC"
sed -e "s|@STATE@|/var/lib/hyprshell-greeter|g" \
    -e "s|@SHARE@|/usr/share/hyprshell-greeter|g" \
    -e "s|@QS@|$QS|g" \
    -e "s|@KB_LAYOUT@|$layout|g" \
    -e "s|@KB_VARIANT@|$variant|g" \
    "$HERE/hyprland.lua" > "$ETC/hyprland.lua"
chmod 644 "$ETC/hyprland.lua"
did "its compositor config in ${ETC#$ROOT}/hyprland.lua (keyboard: $layout${variant:+ $variant})"

# ── greetd ────────────────────────────────────────────────────────────────
mkdir -p "$GREETD"
# The config from before the first install is kept, and never overwritten
# by a later one — that is the one --uninstall puts back.
if [ -f "$CONF" ] && [ ! -f "$BACKUP" ] && ! grep -q hyprshell-greeter "$CONF"; then
    cp -p "$CONF" "$BACKUP"
    did "greetd's previous config kept as ${BACKUP#$ROOT}"
fi
vt=$( [ -f "$CONF" ] && sed -n 's/^[[:space:]]*vt[[:space:]]*=[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$CONF" | head -n1 || true)
cat > "$CONF" <<EOF
# Written by hyprshell's greeter/install.sh. The config from before is in
# config.toml.before-hyprshell; \`install.sh --uninstall\` puts it back.

[terminal]
vt = ${vt:-1}

[default_session]
command = "$COMP"
user = "$GU"
EOF
did "greetd now starts the greeter (${CONF#$ROOT})"

# ── which display manager runs ────────────────────────────────────────────
[ -n "$ROOT" ] && exit 0
others=""
for dm in sddm gdm lightdm ly lemurs; do
    systemctl is-enabled "$dm.service" >/dev/null 2>&1 && others="$others $dm"
done
if [ "$enable" = 1 ]; then
    for dm in $others; do systemctl disable "$dm.service" >/dev/null 2>&1 && did "turned off $dm"; done
    systemctl enable greetd.service >/dev/null 2>&1 && did "greetd enabled — the greeter appears at the next boot"
elif systemctl is-enabled greetd.service >/dev/null 2>&1; then
    did "greetd is already the display manager — log out, or reboot, to see it"
else
    note "greetd is not enabled${others:+ (${others# } is)} — run again with --enable, or: sudo systemctl enable greetd"
fi
note "to see it without logging out: qs -p $HERE/shell.qml  (Escape leaves)"
