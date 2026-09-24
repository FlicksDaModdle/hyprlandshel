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

# ── the palette the stylesheets import ────────────────────────────────
#
# Normally the shell has already written this. If it has not — the shell
# is not running, or has not reached its first theme pass — a default one
# goes in, so the browser is themed rather than half-themed. The shell
# overwrites it the moment it next runs.
if [ "$MODE" = install ] && [ ! -f "$COLORS" ]; then
    mkdir -p "$(dirname "$COLORS")"
    cat > "$COLORS" <<'DEFAULTS'
/* Placeholder, written by firefox/install.sh because the shell had not
 * written one yet. The shell replaces this whenever the theme changes. */
:root {
  --hs-frame: #f3f2f2;
  --hs-chrome: #fbfafa;
  --hs-field: #eae9e9;
  --hs-menu: #fbfafa;
  --hs-sel-tab: #eae9e9;

  --hs-ink: #201e1d;
  --hs-ink2: #605d5d;
  --hs-ink3: #6b6868;

  --hs-accent: #ec3013;
  --hs-on-accent: #ffffff;
  --hs-seam: rgba(236,48,19,0.18);

  --hs-edge: rgba(32,30,29,0.14);
  --hs-rule: rgba(32,30,29,0.09);
  --hs-div: rgba(32,30,29,0.18);
  --hs-hover: rgba(32,30,29,0.07);
  --hs-sel: rgba(32,30,29,0.1);

  --hs-r: 14px;
  --hs-r-sm: 9px;

  --hs-font: "Inter";
  --hs-mono: "JetBrains Mono";

  color-scheme: light;
}
DEFAULTS
    printf '  wrote a placeholder palette at\n    %s%s%s\n' "$DIM" "$COLORS" "$RST"
    printf '  %s(the shell replaces it on its next theme pass)%s\n\n' "$DIM" "$RST"
fi

# user.js, merged rather than replaced: it is a file people keep their own
# settings in, and this owns exactly one line of it.
set_pref() {
    js="$1/user.js"
    key='toolkit.legacyUserProfileCustomizations.stylesheets'
    touch "$js"
    if [ "$MODE" = uninstall ]; then
        if grep -q "$key" "$js" 2>/dev/null; then
            sed -i "/$key/d;/Hyprshell chrome:/d" "$js"
            did "user.js — removed the stylesheets pref"
        fi
        return
    fi
    if grep -q "user_pref(\"$key\", *true)" "$js" 2>/dev/null; then
        skip "user.js — already set"
    else
        sed -i "/$key/d;/Hyprshell chrome:/d" "$js"
        printf '// Hyprshell chrome: lets Firefox read chrome/userChrome.css\nuser_pref("%s", true);\n' \
               "$key" >> "$js"
        did "user.js — set the stylesheets pref"
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
