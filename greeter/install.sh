#!/bin/sh
# Install the Hyprshell greeter — the login screen, in the shell's design,
# run by greetd.
#
#   sudo ./install.sh              install it, and point greetd at it
#   sudo ./install.sh --enable     …and make greetd the display manager,
#                                  turning off sddm/gdm/lightdm/ly if one is on
#   sudo ./install.sh --theme      only copy your current theme to it again
#   ./install.sh --status          what greetd will start, and if it is this
#   sudo ./install.sh --uninstall  put greetd's previous config back and
#                                  remove the greeter
#   sudo ./install.sh --no-keyring  install without having your login unlock
#                                  the keyring
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
# copy the .before-hyprshell file in /etc/greetd back over the one it was.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

# Everything below is under $ROOT, which is / unless --root is given (for
# trying the install out on a scratch directory).
ROOT=""
enable=0 uninstall=0 themeonly=0 status=0 keyring=1
while [ $# -gt 0 ]; do
    case "$1" in
        --enable)    enable=1 ;;
        --uninstall) uninstall=1 ;;
        --theme)     themeonly=1 ;;
        --status)    status=1 ;;
        --no-keyring) keyring=0 ;;
        --root)      shift; ROOT="${1%/}" ;;
        -h|--help)   sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

SHARE="$ROOT/usr/share/hyprshell-greeter"
ETC="$ROOT/etc/hyprshell-greeter"
STATE="$ROOT/var/lib/hyprshell-greeter"
CACHE="$ROOT/var/cache/hyprshell-greeter"
ICONS="$ROOT/var/lib/AccountsService/icons"
# The config greetd reads — in greetd's own order (greetd/src/config/mod.rs):
# the file its service names with --config / -c, if any; otherwise
# /etc/greetd/greetd.conf when it exists, and only then config.toml.
# Noctalia's greeter setup writes greetd.conf, which is why writing
# config.toml alone changed nothing.
greetd_config() {
    if [ -z "$ROOT" ]; then
        cmd=$(systemctl show -p ExecStart --value greetd.service 2>/dev/null | sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p' | head -n1)
        c=$(printf '%s\n' "$cmd" | sed -n 's/.*\(--config\|-c\)[= ]\([^ ]*\).*/\2/p' | head -n1)
        [ -n "$c" ] && { printf '%s\n' "$c"; return; }
    fi
    if [ -f "$ROOT/etc/greetd/greetd.conf" ]; then printf '%s\n' "$ROOT/etc/greetd/greetd.conf"
    else printf '%s\n' "$ROOT/etc/greetd/config.toml"; fi
}
CONF=$(greetd_config)
GREETD=$(dirname "$CONF")
BACKUP="$CONF.before-hyprshell"

if [ -t 1 ]; then
    GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m'); RED=$(printf '\033[31m'); RST=$(printf '\033[0m')
else
    GRN= YEL= RED= RST=
fi
did()  { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
note() { printf '    %s·%s %s\n' "$YEL" "$RST" "$1"; }
die()  { printf '    %s✗%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

# ── status: what greetd will start, and why it might not be this ─────────
if [ "$status" = 1 ]; then
    say() { printf '    %s\n' "$1"; }
    say "greetd reads:     $CONF"
    cmd=$(awk '/^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[default_session\]/) }
               s && /^[[:space:]]*command[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print }' "$CONF" 2>/dev/null | tail -n1)
    say "it starts:        ${cmd:-(nothing found)}"
    if printf '%s' "$cmd" | grep -q hyprshell-greeter; then did "that is this greeter"
    else note "that is not this greeter — run: sudo ./install.sh"; fi
    en=$(systemctl is-enabled greetd.service 2>/dev/null || true)
    ac=$(systemctl is-active greetd.service 2>/dev/null || true)
    say "greetd:           ${en:-unknown}, ${ac:-unknown}"
    if [ "$ac" = active ] && [ -f "$CONF" ]; then
        since=$(systemctl show -p ActiveEnterTimestamp --value greetd.service 2>/dev/null)
        started=$(date -d "$since" +%s 2>/dev/null || echo 0)
        changed=$(stat -c %Y "$CONF" 2>/dev/null || echo 0)
        if [ "$changed" -gt "$started" ] && [ "$started" -gt 0 ]; then
            note "the config changed after greetd started ($since) — greetd still has the old one: reboot to use the new one"
        fi
    fi
    for dm in sddm gdm lightdm ly lemurs; do
        systemctl is-enabled "$dm.service" >/dev/null 2>&1 && note "$dm is enabled too — only one display manager should be"
    done
    found=$(grep -rl -i noctalia "$GREETD" 2>/dev/null | grep -v before-hyprshell || true)
    [ -n "$found" ] && note "greetd's folder still mentions Noctalia: $(printf '%s' "$found" | tr '\n' ' ')"
    # Noctalia's shell starting in your own session, after you log in —
    # a different thing from its greeter, and not greetd's doing.
    who="${SUDO_USER:-$(id -un)}"
    home=$(getent passwd "$who" | cut -d: -f6)
    if [ -n "$home" ]; then
        # Not an editor's swap and backup files, which only remember text.
        found=$(grep -rl -i noctalia "$home/.config/hypr" "$home/.config/autostart" \
                    "$home/.config/systemd/user" 2>/dev/null \
                | grep -Ev '(\.kate-swp|\.sw[a-p]|~|\.bak|\.orig)$|/\.#' || true)
        [ -n "$found" ] && note "your session still starts Noctalia from: $(printf '%s' "$found" | tr '\n' ' ')"
        on=$(systemctl --machine="$who@" --user list-unit-files --state=enabled 2>/dev/null | grep -i noctalia | awk '{print $1}' | tr '\n' ' ')
        [ -n "$on" ] && note "enabled user services: $on— systemctl --user disable --now $on"
    fi
    exit 0
fi

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
    # so it is the greeter's — that part only: users/ below is each
    # person's own.
    chown -R "$gu" "$STATE/config"
}

# Each person's folder, where their shell keeps the greeter's copy of their
# theme, wallpaper and picture (services/GreeterSync.qml): theirs to write,
# everyone's to read.
user_folder() {
    p=$1
    mkdir -p "$STATE/users"
    chmod 755 "$STATE" "$STATE/users"
    mkdir -p "$STATE/users/$p"
    chown "$p" "$STATE/users/$p"
    chmod 755 "$STATE/users/$p"
    did "a folder for your shell to keep the greeter dressed like your desktop: ${STATE#$ROOT}/users/$p"
    note "your shell fills it within a minute, and again whenever the theme or wallpaper changes"
}

# Your login unlocking the keyring — the Secret Service, where Mail, the
# browser and Wi-Fi keep passwords — with the password you just typed:
# pam_gnome_keyring in greetd's PAM file, which a greetd login reads.
PAM="$ROOT/etc/pam.d/greetd"
pam_module() {
    for d in /usr/lib/security /lib/security /usr/lib64/security /usr/lib/x86_64-linux-gnu/security; do
        [ -f "$ROOT$d/pam_gnome_keyring.so" ] && return 0
    done
    return 1
}
setup_keyring() {
    if [ ! -f "$PAM" ]; then
        note "no $PAM — greetd's package normally installs it; the keyring will not unlock at login"
        return
    fi
    if ! pam_module; then
        note "gnome-keyring is not installed, so there is no keyring for the login to unlock (pacman -S gnome-keyring)"
        return
    fi
    if grep -q pam_gnome_keyring "$PAM"; then
        did "logging in unlocks the keyring (already set in ${PAM#$ROOT})"
    else
        [ -f "$PAM.before-hyprshell" ] || cp -p "$PAM" "$PAM.before-hyprshell"
        # The auth line after every other auth line — it takes the password
        # once it has been checked — and the session line at the end.
        awk '
            { lines[NR] = $0 }
            /^[[:space:]]*-?auth[[:space:]]/ { last = NR }
            END {
                for (i = 1; i <= NR; i++) {
                    print lines[i]
                    if (i == last) print "auth       optional     pam_gnome_keyring.so"
                }
                if (!last) print "auth       optional     pam_gnome_keyring.so"
                print "session    optional     pam_gnome_keyring.so auto_start"
            }' "$PAM" > "$PAM.new" && mv -f "$PAM.new" "$PAM"
        chmod 644 "$PAM"
        did "logging in now unlocks the keyring (${PAM#$ROOT}; the old file is kept as greetd.before-hyprshell)"
    fi
    note "for that, the keyring's password has to be your login password — if it isn't, change it in"
    note "Passwords and Keys (seahorse): right-click Login → Change Password"
}

# ── uninstall ─────────────────────────────────────────────────────────────
if [ "$uninstall" = 1 ]; then
    # Every config an install replaced — greetd.conf, and config.toml from
    # an install made before this one knew greetd.conf came first.
    for b in "$GREETD"/*.before-hyprshell; do
        [ -f "$b" ] || continue
        mv -f "$b" "${b%.before-hyprshell}"
        did "greetd's previous $(basename "${b%.before-hyprshell}") put back"
    done
    if [ -f "$CONF" ] && grep -q hyprshell-greeter "$CONF"; then
        note "no backup of greetd's previous config — $CONF still points at the greeter; edit it by hand"
    fi
    if [ -f "$PAM.before-hyprshell" ]; then
        mv -f "$PAM.before-hyprshell" "$PAM"
        did "greetd's previous PAM file put back"
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
    [ -n "$PERSON" ] && user_folder "$PERSON"
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
# The wallpaper's animations and contour map, which the login screen draws
# under the card exactly as the desktop does.
cp -R "$REPO/shell/quickshell/modules/background" "$SHARE.new/shell/modules/background"
rm -rf "$SHARE"
mv "$SHARE.new" "$SHARE"
chmod -R a+rX "$SHARE"
did "greeter in ${SHARE#$ROOT}"

copy_theme "$GU"
[ -n "$PERSON" ] && user_folder "$PERSON"
[ "$keyring" = 1 ] && setup_keyring

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
# $(basename "$BACKUP"); \`install.sh --uninstall\` puts it back.

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
    systemctl enable greetd.service >/dev/null 2>&1 && did "greetd enabled — the greeter appears at the next boot (reboot to see it)"
elif systemctl is-enabled greetd.service >/dev/null 2>&1; then
    did "greetd is already the display manager"
    # greetd reads its config when it starts and keeps it: logging out
    # brings back whichever greeter it started with.
    note "greetd keeps the config it started with, so logging out still shows the old greeter —"
    note "reboot to see this one (or from a text console, Ctrl+Alt+F2: sudo systemctl restart greetd)"
else
    note "greetd is not enabled${others:+ (${others# } is)} — run again with --enable, or: sudo systemctl enable greetd"
fi
note "to see it without logging out: qs -p $HERE/shell.qml  (Escape leaves)"
