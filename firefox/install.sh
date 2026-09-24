#!/bin/sh
# Put the Hyprshell chrome into your Firefox profiles.
#
# Three things have to be true before a userChrome.css does anything, and
# missing any one of them looks identical from the outside — a browser
# that ignored you:
#
#   1. the file is at <profile>/chrome/userChrome.css, and a profile is
#      not a directory anyone can guess: profiles.ini names them
#   2. toolkit.legacyUserProfileCustomizations.stylesheets is true, which
#      has been off by default since Firefox 69
#   3. Firefox has been restarted; it reads chrome CSS once, at startup
#
# So this does the first two for every profile it finds and tells you
# about the third.
#
#   ./install.sh                 every profile in ~/.mozilla/firefox
#   ./install.sh --profile PATH  just that one
#   ./install.sh --uninstall     take it back out
#   ./install.sh --list          show what it found, change nothing
#
# Nothing here needs root, and nothing outside your Firefox profiles and
# the shell's own config directory is touched.
set -u

SRC="$(cd "$(dirname "$0")" && pwd)"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
COLORS="$CONF/quickshell/hyprshell/firefox-colors.css"
MODE=install
ONLY=

while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) MODE=uninstall ;;
        --list)      MODE=list ;;
        --profile)   ONLY="${2:-}"; shift ;;
        -h|--help)   sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
    GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m')
    RED=$(printf '\033[31m'); RST=$(printf '\033[0m')
else
    BOLD=; DIM=; GRN=; YEL=; RED=; RST=
fi
did()  { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
skip() { printf '    %s·%s %s\n' "$YEL" "$RST" "$1"; }
bad()  { printf '    %s✗%s %s\n' "$RED" "$RST" "$1"; }

# ── where are the profiles? ───────────────────────────────────────────
#
# profiles.ini is the only authority, and there is no single place it
# lives. ~/.mozilla/firefox is the old answer; a Firefox built with XDG
# base directories — which is what Arch and its derivatives ship — puts
# it under ~/.config instead, and a Flatpak or snap keeps a tree of its
# own. Every Gecko browser downstream of Firefox has its own directory
# again.
#
# So: the known places first, and then a search, because this list will
# be out of date again.
XDG="${XDG_CONFIG_HOME:-$HOME/.config}"
roots="$HOME/.mozilla/firefox
$XDG/mozilla/firefox
$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox
$HOME/snap/firefox/common/.mozilla/firefox
$HOME/.librewolf
$XDG/librewolf
$HOME/.var/app/io.gitlab.librewolf-community/.librewolf
$HOME/.zen
$XDG/zen
$HOME/.var/app/app.zen_browser.zen/.zen
$HOME/.floorp
$XDG/floorp
$HOME/.waterfox
$XDG/waterfox
$HOME/.mullvad-browser
$HOME/.tor-browser"

read_ini() {
    root="$1"
    ini="$root/profiles.ini"
    [ -f "$ini" ] || return
    # Path= lines, resolved against the root. sed rather than a real ini
    # parser because this is the one key that matters and the format has
    # not moved in twenty years.
    sed -n 's/^[Pp]ath=//p' "$ini" | tr -d '\r' | while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            /*) dir="$rel" ;;
            *)  dir="$root/$rel" ;;
        esac
        [ -d "$dir" ] && printf '%s\n' "$dir"
    done
}

profiles=""
if [ -n "$ONLY" ]; then
    profiles="$ONLY"
else
    for root in $roots; do
        found=$(read_ini "$root")
        [ -n "$found" ] && profiles="$profiles
$found"
    done

    # Nothing in any of the known places. Rather than give up — which is
    # what sent someone to about:profiles to read the path out by hand —
    # look for profiles.ini anywhere it could reasonably be. Bounded
    # depth so this stays quick, and the cache directories are skipped
    # because Firefox keeps a *second* tree there with the same profile
    # names in it and it is not the one to install into.
    if [ -z "$(printf '%s' "$profiles" | tr -d '[:space:]')" ]; then
        printf '  %snot in any of the usual places — searching…%s\n\n' "$DIM" "$RST"
        for ini in $(find "$HOME" -maxdepth 6 -name profiles.ini \
                          -not -path "*/.cache/*" -not -path "*/Trash/*" \
                          2>/dev/null); do
            found=$(read_ini "$(dirname "$ini")")
            [ -n "$found" ] && profiles="$profiles
$found"
        done
    fi
fi

profiles=$(printf '%s\n' "$profiles" | sed '/^$/d')

printf '\n%sFirefox chrome%s\n\n' "$BOLD" "$RST"

if [ -z "$profiles" ]; then
    bad "no Firefox profiles found"
    printf '\n  Looked in each of these, then searched %s for a profiles.ini:\n' "$HOME"
    for root in $roots; do printf '    %s%s%s\n' "$DIM" "$root" "$RST"; done
    printf '\n  Firefox will tell you itself: open %sabout:profiles%s and read\n' "$BOLD" "$RST"
    printf '  the "Root Directory" row. Then:\n'
    printf '    ./install.sh --profile <that path>\n\n'
    exit 1
fi

# An earlier version of this script wrote a placeholder palette when the
# shell had not written one — hardcoded light, which gave a browser set
# to dark a light address bar. It is still on disk for anyone who ran
# that version, it still wins over the defaults because it is imported
# after them, and nothing would ever replace it but the shell.
#
# So it is cleared out here. The defaults take over immediately and the
# shell's own palette lands on top whenever it next runs.
if [ "$MODE" = install ] && [ -f "$COLORS" ] \
   && grep -q 'written by firefox/install.sh' "$COLORS" 2>/dev/null; then
    rm -f "$COLORS"
    printf '  %sremoved a stale placeholder palette%s\n' "$YEL" "$RST"
    printf '    %s%s%s\n' "$DIM" "$COLORS" "$RST"
    printf '    %sit was light whatever your browser was set to%s\n\n' "$DIM" "$RST"
fi

# The shell writes the palette. When it has not yet — the shell is not
# running, or has not reached its first theme pass — there is nothing to
# write here: hyprshell-defaults.css is installed beside the stylesheets
# and carries a light and a dark palette that follow the system, and the
# shell's file lands on top of it whenever it appears.
#
# This used to drop a placeholder palette in instead, hardcoded light,
# which gave a browser set to dark a light address bar with Firefox's own
# white icons on it.

# user.js, merged rather than replaced: it is a file people keep their own
# settings in, and this owns exactly one line of it.
# Two prefs, not one.
#
#   toolkit.legacyUserProfileCustomizations.stylesheets
#     lets Firefox read chrome/userChrome.css at all. Off by default
#     since Firefox 69.
#
#   widget.gtk.native-context-menus
#     the one that is not obvious. With this on — which is the default
#     on Linux — a right-click menu is a real GTK menu widget rather
#     than a XUL popup, so it is drawn by the toolkit and no chrome CSS
#     can touch it. Every rule for menus in userChrome.css is simply
#     inert while it is true, which looks exactly like the rules being
#     wrong. Turning it off gives the menu back to Firefox to draw, and
#     then the stylesheet reaches it.
set_pref() {
    js="$1/user.js"
    touch "$js"

    if [ "$MODE" = uninstall ]; then
        if grep -q 'Hyprshell chrome:' "$js" 2>/dev/null; then
            sed -i '/Hyprshell chrome:/,+1d' "$js"
            did "user.js — removed our prefs"
        fi
        return
    fi

    changed=0
    # key, value, why
    while IFS='|' read -r key val why; do
        [ -n "$key" ] || continue
        if grep -q "user_pref(\"$key\", *$val)" "$js" 2>/dev/null; then
            continue
        fi
        # Ours to rewrite: the comment line above it goes too.
        sed -i "\|$key|{x;/Hyprshell chrome:/d;x;d}" "$js" 2>/dev/null \
            || sed -i "\|$key|d" "$js"
        printf '// Hyprshell chrome: %s\nuser_pref("%s", %s);\n' \
               "$why" "$key" "$val" >> "$js"
        changed=$((changed + 1))
    done <<PREFS
toolkit.legacyUserProfileCustomizations.stylesheets|true|lets Firefox read chrome/userChrome.css
widget.gtk.native-context-menus|false|so chrome CSS can reach the right-click menu
PREFS

    if [ "$changed" -gt 0 ]; then
        did "user.js — set $changed pref(s)"
    else
        skip "user.js — already set"
    fi
}

count=0
printf '%s\n' "$profiles" | while IFS= read -r prof; do
    [ -n "$prof" ] || continue
    name=$(basename "$prof")
    printf '  %s%s%s\n' "$BOLD" "$name" "$RST"
    printf '    %s%s%s\n' "$DIM" "$prof" "$RST"

    if [ "$MODE" = list ]; then
        [ -f "$prof/chrome/userChrome.css" ] \
            && skip "userChrome.css is installed" \
            || skip "userChrome.css is not installed"
        printf '\n'
        continue
    fi

    if [ "$MODE" = uninstall ]; then
        [ -f "$prof/chrome/hyprshell-defaults.css" ] \
            && rm -f "$prof/chrome/hyprshell-defaults.css" \
            && did "removed hyprshell-defaults.css"
        for f in userChrome.css userContent.css; do
            if [ -f "$prof/chrome/$f" ] \
               && grep -q 'Hyprshell' "$prof/chrome/$f" 2>/dev/null; then
                rm -f "$prof/chrome/$f"
                did "removed $f"
            elif [ -f "$prof/chrome/$f" ]; then
                skip "$f is not ours — left alone"
            fi
            [ -f "$prof/chrome/$f.hyprshell-backup" ] \
                && mv "$prof/chrome/$f.hyprshell-backup" "$prof/chrome/$f" \
                && did "put back the $f you had"
        done
        set_pref "$prof"
        printf '\n'
        continue
    fi

    mkdir -p "$prof/chrome"
    # Imported by both sheets, by a relative url, so it needs no
    # substitution — only to be next to them.
    cp "$SRC/hyprshell-defaults.css" "$prof/chrome/hyprshell-defaults.css"
    did "installed hyprshell-defaults.css"
    for f in userChrome.css userContent.css; do
        # Someone else's stylesheet is not ours to throw away.
        if [ -f "$prof/chrome/$f" ] \
           && ! grep -q 'Hyprshell' "$prof/chrome/$f" 2>/dev/null \
           && [ ! -f "$prof/chrome/$f.hyprshell-backup" ]; then
            cp "$prof/chrome/$f" "$prof/chrome/$f.hyprshell-backup"
            skip "kept your $f as $f.hyprshell-backup"
        fi
        # The @import needs the real path, which is only known here.
        sed "s|HYPRSHELL_COLORS_PATH|file://$COLORS|" "$SRC/$f" \
            > "$prof/chrome/$f"
        did "installed $f"
    done
    set_pref "$prof"
    printf '\n'
done

[ "$MODE" = list ] && exit 0

if [ "$MODE" = uninstall ]; then
    printf '  Restart Firefox for it to go back to normal.\n\n'
    exit 0
fi

cat <<EOS
  ${BOLD}Restart Firefox.${RST} It reads chrome stylesheets once, when it starts —
  so does a theme change in the shell: the colours are rewritten straight
  away and the window picks them up at its next launch.

  ${DIM}Undo:   ./install.sh --uninstall
  Check:  ./install.sh --list${RST}

EOS
