#!/bin/sh
# When a site works in Firefox and not in Hyprshell Browser: which of the
# two it is.
#
#   ./doctor.sh                 a report of what differs between them, to
#                               paste into a bug report
#   ./doctor.sh --ab [URL]      open URL (Gemini by default) in both at once,
#                               each with a brand new throwaway profile, and
#                               Hyprshell Browser without its interface layer
#
# The side-by-side takes everything else out of the question: no profile,
# no extensions, no cookies, no interface code — the two differ only in how
# they are installed. If the site works in one and not the other, that is
# where the difference is; if it fails in both, it is not this browser.
set -u

DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
SHARE="$DATA/hyprshell-browser"
LIB="${HYPRSHELL_BROWSER_LIB:-$HOME/.local/lib/hyprshell-browser}"
XDG="${XDG_CONFIG_HOME:-$HOME/.config}"

# The Firefox this is compared against: the one on PATH.
FIREFOX=$(command -v firefox 2>/dev/null || true)

if [ "${1:-}" = "--ab" ]; then
    url="${2:-https://gemini.google.com/app}"
    [ -x "$LIB/firefox" ] || { echo "Hyprshell Browser is not installed ($LIB/firefox)"; exit 1; }
    [ -n "$FIREFOX" ] || { echo "no firefox on PATH to compare with"; exit 1; }
    a=$(mktemp -d "${TMPDIR:-/tmp}/ff-plain.XXXXXX")
    b=$(mktemp -d "${TMPDIR:-/tmp}/hs-plain.XXXXXX")
    # --no-remote, so neither hands the URL to a copy already running.
    "$FIREFOX" --no-remote --profile "$a" --name ab-firefox --class ab-firefox "$url" >/dev/null 2>&1 &
    HYPRSHELL_BROWSER_PLAIN=1 "$LIB/firefox" --no-remote --profile "$b" \
        --name ab-hyprshell --class ab-hyprshell "$url" >/dev/null 2>&1 &
    echo "Opened $url in:"
    echo "  Firefox             ($FIREFOX), fresh profile"
    echo "  Hyprshell Browser   ($LIB/firefox), fresh profile, interface layer off"
    echo "Both will show Firefox's welcome dialogs first. Throwaway profiles:"
    echo "  $a"
    echo "  $b"
    exit 0
fi

say() { printf '%s\n' "$*"; }
sec() { printf '\n== %s\n' "$*"; }

sec "installs"
mode=$(cat "$SHARE/mode" 2>/dev/null || echo "?")
base=$(cat "$SHARE/base" 2>/dev/null || echo "")
say "hyprshell-browser: mode=$mode base=${base:-—} lib=$LIB"
say "  version: $("$LIB/firefox" --version 2>/dev/null || echo 'did not run')"
if [ -n "$FIREFOX" ]; then
    say "firefox on PATH: $FIREFOX -> $(readlink -f "$FIREFOX")"
    say "  version: $("$FIREFOX" --version 2>/dev/null || echo 'did not run')"
else
    say "firefox on PATH: none"
fi
if [ "$mode" = system ] && [ -n "$base" ]; then
    if cmp -s "$base/firefox" "$LIB/firefox"; then say "executable: identical to $base/firefox"
    else say "executable: DIFFERS from $base/firefox"; fi
    broken=$(find "$LIB" -maxdepth 3 -xtype l 2>/dev/null | head -n 5)
    say "broken links in the overlay: ${broken:-none}"
    say "only in the overlay: $(cd "$LIB" && for f in * .[!.]*; do [ -e "$f" ] && [ ! -e "$base/$f" ] && printf '%s ' "$f"; done)"
    say "only in $base: $(cd "$base" && for f in * .[!.]*; do [ -e "$f" ] && [ ! -e "$LIB/$f" ] && printf '%s ' "$f"; done)"
fi
say "defaults/pref: $(ls "$LIB/defaults/pref" 2>/dev/null | tr '\n' ' ')"
[ -n "$base" ] && say "distribution: $(ls "$base/distribution" 2>/dev/null | tr '\n' ' ')"

firefox_profile() {
    for root in "$XDG/mozilla/firefox" "$HOME/.mozilla/firefox"; do
        ini="$root/profiles.ini"
        [ -f "$ini" ] || continue
        p=$(awk -F= '/^\[Install/{i=1;next} /^\[/{i=0} i&&$1=="Default"{print $2; exit}' "$ini" | tr -d '\r')
        [ -n "$p" ] || p=$(sed -n 's/^Path=//p' "$ini" | head -1 | tr -d '\r')
        [ -n "$p" ] || continue
        case "$p" in /*) ;; *) p="$root/$p" ;; esac
        [ -d "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

prefs() {  # key<TAB>value for every user_pref, sorted
    sed -n 's/^user_pref("\([^"]*\)", \(.*\));$/\1\t\2/p' "$1/prefs.js" 2>/dev/null | sort
}
addons() {  # active add-on ids
    tr ',' '\n' < "$1/extensions.json" 2>/dev/null | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | sort -u
}

ours="$SHARE/profile"
theirs=$(firefox_profile || true)
sec "profiles"
say "hyprshell-browser: $ours"
say "firefox: ${theirs:-not found}"
if [ -n "$theirs" ] && [ -f "$ours/prefs.js" ]; then
    # Only the prefs that can change how a page runs or draws — the rest
    # (window sizes, telemetry dates, session counters) always differ.
    interesting='^(layout|gfx|dom|javascript|webgl|media|privacy|network|security|browser\.display|widget|font|intl|image|content|webgpu|extensions\.webcompat|ui\.)'
    prefs "$ours" | grep -E "$interesting" > /tmp/.hsd-ours.$$
    prefs "$theirs" | grep -E "$interesting" > /tmp/.hsd-theirs.$$
    sec "prefs that differ (only in hyprshell-browser: >, only in firefox: <)"
    diff /tmp/.hsd-theirs.$$ /tmp/.hsd-ours.$$ | grep '^[<>]' | head -n 60 || say "none"
    sec "add-ons (only in hyprshell-browser: >, only in firefox: <)"
    addons "$theirs" > /tmp/.hsd-theirs.$$; addons "$ours" > /tmp/.hsd-ours.$$
    diff /tmp/.hsd-theirs.$$ /tmp/.hsd-ours.$$ | grep '^[<>]' || say "the same"
    rm -f /tmp/.hsd-ours.$$ /tmp/.hsd-theirs.$$
fi
