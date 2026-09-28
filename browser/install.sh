#!/bin/sh
# Install Hyprshell Browser.
#
#   ./install.sh               build it on the Firefox already on this machine
#   ./install.sh --download    build it on Mozilla's own current release
#   ./install.sh --import      start its profile as a copy of your Firefox one
#                              (bookmarks, logins, extensions, history)
#   ./install.sh --default     make it the default browser
#   ./install.sh --uninstall   remove it; add --purge to delete its profile too
#
# Options combine: ./install.sh --import --default
#
# What it is: Firefox's engine and interface, with this repo's browser/app laid
# over it — the interface modules in hyprshell/ and the autoconfig hook that
# loads them — as an application of its own. Its own install, its own profile,
# its own name and icon, its own app id, so it sits beside Firefox rather than
# changing it.
#
# Where it comes from:
#
#   system (default, when /usr/lib/firefox is there)
#       An overlay of the system Firefox: links back to every file of it but
#       the executable. Your package manager keeps it current, and the
#       launcher re-links at every start so an upgrade never leaves it behind.
#
#   --download
#       Mozilla's release tarball, unpacked into your home. It updates itself
#       through Mozilla's signed updater, like any Firefox installed that way.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
SHARE="$DATA/hyprshell-browser"
LIB="${HYPRSHELL_BROWSER_LIB:-$HOME/.local/lib/hyprshell-browser}"
BIN="$HOME/.local/bin"
APPS="$DATA/applications"
ICONS="$DATA/icons/hicolor"
XDG="${XDG_CONFIG_HOME:-$HOME/.config}"
NAME=hyprshell-browser
SYSTEM_BASE="${HYPRSHELL_FIREFOX:-/usr/lib/firefox}"

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RST=$(printf '\033[0m')
    GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m'); RED=$(printf '\033[31m')
else
    BOLD= DIM= RST= GRN= YEL= RED=
fi
did()  { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
note() { printf '    %s·%s %s\n' "$YEL" "$RST" "$1"; }
die()  { printf '    %s✗%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

mode=""
import=0 default=0 uninstall=0 purge=0
for a in "$@"; do
    case "$a" in
        --download)  mode=download ;;
        --system)    mode=system ;;
        --import)    import=1 ;;
        --default)   default=1 ;;
        --uninstall) uninstall=1 ;;
        --purge)     purge=1 ;;
        -h|--help)   sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $a (see --help)" ;;
    esac
done

printf '\n%sHyprshell Browser%s\n\n' "$BOLD" "$RST"

# ── uninstall ───────────────────────────────────────────────────────────────
if [ "$uninstall" = 1 ]; then
    rm -rf "$LIB"
    rm -f "$BIN/$NAME" "$APPS/$NAME.desktop"
    for s in 16 32 48 64 128 256; do rm -f "$ICONS/${s}x${s}/apps/$NAME.png"; done
    rm -f "$ICONS/scalable/apps/$NAME.svg"
    if [ "$purge" = 1 ]; then
        rm -rf "$SHARE"
        did "removed, profile included"
    else
        rm -rf "$SHARE/app" "$SHARE/mode" "$SHARE/base"
        did "removed — your profile is kept in $SHARE/profile (--purge deletes it)"
    fi
    exit 0
fi

# ── where the browser comes from ────────────────────────────────────────────
if [ -z "$mode" ]; then
    if [ -x "$SYSTEM_BASE/firefox" ]; then mode=system; else mode=download; fi
fi

mkdir -p "$SHARE"

if [ "$mode" = system ]; then
    [ -x "$SYSTEM_BASE/firefox" ] || die "no Firefox at $SYSTEM_BASE — install it, or use --download"
    # The overlay needs to replace the executable with a copy, and a script
    # there would be copied instead of Firefox.
    if ! head -c 4 "$SYSTEM_BASE/firefox" | grep -q "ELF"; then
        die "$SYSTEM_BASE/firefox is a wrapper script, not Firefox itself — use --download"
    fi
    # A previous --download install is a real directory; the overlay replaces it.
    if [ -d "$LIB" ] && [ ! -L "$LIB/libxul.so" ]; then rm -rf "$LIB"; fi
    printf '%s\n' "$SYSTEM_BASE" > "$SHARE/base"
    did "built on the system Firefox, $("$SYSTEM_BASE/firefox" --version 2>/dev/null | sed 's/^Mozilla //')"
else
    command -v curl >/dev/null || die "curl is needed to download Firefox"
    lang=$(printf '%s' "${LANG:-en-US}" | sed 's/[._].*//; s/_/-/')
    case "$lang" in ""|C|POSIX) lang=en-US ;; esac
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    url="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=$lang"
    printf '    %sdownloading Firefox from mozilla.org…%s\n' "$DIM" "$RST"
    curl -fL --progress-bar -o "$tmp/firefox.tar" "$url" \
        || curl -fL --progress-bar -o "$tmp/firefox.tar" \
                "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=en-US" \
        || die "the download failed"
    tar -xf "$tmp/firefox.tar" -C "$tmp" || die "could not unpack the download"
    [ -x "$tmp/firefox/firefox" ] || die "the download did not contain Firefox"
    rm -rf "$LIB"
    mkdir -p "$(dirname "$LIB")"
    mv "$tmp/firefox" "$LIB"
    rm -f "$SHARE/base"
    did "downloaded $("$LIB/firefox" --version 2>/dev/null | sed 's/^Mozilla //'), updating itself from here on"
fi
printf '%s\n' "$mode" > "$SHARE/mode"

# ── the layer ───────────────────────────────────────────────────────────────
# Kept whole in $SHARE/app so the launcher can put it back after anything —
# an update, a reinstall of Firefox — takes it away.
rm -rf "$SHARE/app"
cp -R "$HERE/app" "$SHARE/app"
( cd "$SHARE/app" && find . -type f ! -name .stamp -exec cksum {} + | sort | cksum ) \
    | cut -d' ' -f1 > "$SHARE/app/.stamp"
did "interface installed"

# ── launcher, desktop entry, icon ───────────────────────────────────────────
mkdir -p "$BIN" "$APPS"
cp -f "$HERE/hyprshell-browser" "$BIN/$NAME"
chmod +x "$BIN/$NAME"

for s in 16 32 48 64 128 256; do
    mkdir -p "$ICONS/${s}x${s}/apps"
    cp -f "$HERE/branding/default$s.png" "$ICONS/${s}x${s}/apps/$NAME.png"
done
mkdir -p "$ICONS/scalable/apps"
cp -f "$HERE/branding/hyprshell-browser.svg" "$ICONS/scalable/apps/$NAME.svg"

cat > "$APPS/$NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Hyprshell Browser
GenericName=Web Browser
Comment=Firefox, in the shell's own design
Exec=$BIN/$NAME %u
Icon=$NAME
Terminal=false
StartupNotify=true
StartupWMClass=$NAME
Categories=Network;WebBrowser;
Keywords=web;browser;internet;firefox;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;application/pdf;
Actions=new-window;new-private-window;

[Desktop Action new-window]
Name=New Window
Exec=$BIN/$NAME --new-window %u

[Desktop Action new-private-window]
Name=New Private Window
Exec=$BIN/$NAME --private-window %u
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$APPS" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q "$ICONS" 2>/dev/null || true
did "launcher $BIN/$NAME, and a desktop entry with its own icon"
case ":$PATH:" in *":$BIN:"*) ;; *) note "$BIN is not on your PATH — the desktop entry works either way" ;; esac

# ── the first start: lay everything out once, now, so a problem shows here ─
mode_check=$("$BIN/$NAME" --version 2>&1 | head -1) || die "the browser did not start: $mode_check"
did "starts: $mode_check"

# ── profile ─────────────────────────────────────────────────────────────────
#
# A copy of your Firefox profile, not a link to it: the two browsers must
# never have the same profile open at once, or they corrupt it between them.
# The default profile is the one profiles.ini marks, in the XDG location
# Arch-built Firefox uses or the traditional one.
default_profile() {
    for root in "$XDG/mozilla/firefox" "$HOME/.mozilla/firefox"; do
        ini="$root/profiles.ini"
        [ -f "$ini" ] || continue
        # The install's own default first, then the profile marked Default=1.
        p=$(awk -F= '/^\[Install/{i=1;next} /^\[/{i=0} i&&$1=="Default"{print $2; exit}' "$ini" | tr -d '\r')
        [ -n "$p" ] || p=$(awk -F= '/^\[Profile/{path="";d=0} $1=="Path"{path=$2} $1=="Default"&&$2=="1"{d=1} d&&path{print path; exit}' "$ini" | tr -d '\r')
        [ -n "$p" ] || p=$(sed -n 's/^Path=//p' "$ini" | head -1 | tr -d '\r')
        [ -n "$p" ] || continue
        case "$p" in /*) ;; *) p="$root/$p" ;; esac
        [ -d "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

if [ "$import" = 1 ]; then
    src=$(default_profile) || die "no Firefox profile found to import"
    # Firefox keeps a lock symlink in a profile while it has it open —
    # "127.0.0.1:+PID". A clean exit removes it, but a Firefox that was
    # killed or crashed, or ended with the session, leaves it behind, and a
    # stale lock is not a reason to refuse. So, as Firefox itself does: the
    # lock only counts if the process it names is still a running Firefox.
    if [ -L "$src/lock" ]; then
        lockpid=$(readlink "$src/lock" | sed -n 's/.*:+\{0,1\}\([0-9][0-9]*\)$/\1/p')
        comm=""
        [ -n "$lockpid" ] && comm=$(cat "/proc/$lockpid/comm" 2>/dev/null || true)
        case "$comm" in
            firefox*|*Firefox*|MainThread|GeckoMain)
                die "Firefox is still running with that profile (process $lockpid) — quit it, or: kill $lockpid"
                ;;
            *)
                note "the profile had a lock left over from a Firefox that is no longer running — ignoring it"
                ;;
        esac
    fi
    if [ -d "$SHARE/profile" ] && [ -n "$(ls -A "$SHARE/profile" 2>/dev/null)" ]; then
        mv "$SHARE/profile" "$SHARE/profile.before-import.$(date +%Y%m%d%H%M%S)"
        note "the previous Hyprshell Browser profile was moved aside, not deleted"
    fi
    mkdir -p "$SHARE/profile"
    # Caches and lock files stay behind; everything that is yours comes along.
    ( cd "$src" && tar -cf - --exclude=./lock --exclude=./.parentlock \
          --exclude=./cache2 --exclude=./startupCache --exclude=./crashes \
          --exclude=./minidumps --exclude=./chrome . ) | ( cd "$SHARE/profile" && tar -xf - )
    did "profile copied from $src"
fi

# ── default browser ─────────────────────────────────────────────────────────
if [ "$default" = 1 ]; then
    if command -v xdg-settings >/dev/null; then
        xdg-settings set default-web-browser "$NAME.desktop" 2>/dev/null || true
    fi
    if command -v xdg-mime >/dev/null; then
        for t in text/html application/xhtml+xml x-scheme-handler/http x-scheme-handler/https; do
            xdg-mime default "$NAME.desktop" "$t" 2>/dev/null || true
        done
    fi
    did "set as the default browser"
fi

printf '\n  Start it from the launcher, or run %s%s%s.\n' "$BOLD" "$NAME" "$RST"
printf '  It follows the shell'"'"'s colours and accent live, without a restart.\n\n'
