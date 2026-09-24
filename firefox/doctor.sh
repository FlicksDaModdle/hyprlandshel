#!/usr/bin/env bash
#
# Why is Firefox still not themed?
#
# Between installing these files and a themed browser there are six
# things that each have to be true, and every one of them fails the same
# way from the outside — a browser that looks exactly like stock Firefox.
# There is no error anywhere, in any log, for any of them. This walks the
# chain and says which link is broken.
#
#   ./doctor.sh
#
# Not `set -e`: every check here is allowed to come back negative, and
# that is the whole point of running it.

set -u

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YEL=$'\033[33m'; RST=$'\033[0m'
else
    BOLD=; DIM=; RED=; GRN=; YEL=; RST=
fi
ok()   { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$1"; BROKEN=$((BROKEN + 1)); }
warn() { printf '  %s•%s %s\n' "$YEL" "$RST" "$1"; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$RST"; }
head1(){ printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

BROKEN=0
SRC="$(cd "$(dirname "$0")" && pwd)"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
COLORS="$CONF/quickshell/hyprshell/firefox-colors.css"
PREF='toolkit.legacyUserProfileCustomizations.stylesheets'

# ── 1. the palette the shell writes ───────────────────────────────────
head1 "The palette"
if [ -f "$COLORS" ]; then
    ok "$COLORS"
    if grep -q -- '--hs-accent' "$COLORS"; then
        note "accent is $(sed -n 's/.*--hs-accent: *\([^;]*\);.*/\1/p' "$COLORS" | head -1)"
        note "scheme is $(sed -n 's/.*color-scheme: *\([^;]*\);.*/\1/p' "$COLORS" | head -1)"
    else
        bad "it has no --hs-accent in it — is it the file the shell writes?"
    fi
else
    bad "no palette at $COLORS"
    note "the shell writes this; run:  qs -c hyprshell ipc call shell syncTheming"
    note "or just ./install.sh, which drops a placeholder in"
fi

# ── 2. which profiles exist ───────────────────────────────────────────
head1 "Profiles"
XDG="$CONF"
roots="$HOME/.mozilla/firefox
$XDG/mozilla/firefox
$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox
$HOME/snap/firefox/common/.mozilla/firefox"

profiles=""
for root in $roots; do
    ini="$root/profiles.ini"
    [ -f "$ini" ] || continue
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
            /*) dir="$rel" ;;
            *)  dir="$root/$rel" ;;
        esac
        [ -d "$dir" ] && profiles="$profiles
$dir"
    done <<< "$(sed -n 's/^[Pp]ath=//p' "$ini" | tr -d '\r')"
done
profiles=$(printf '%s\n' "$profiles" | sed '/^$/d')

if [ -z "$profiles" ]; then
    bad "no profiles found"
    note "open about:profiles and read the Root Directory row"
    printf '\n%s%d thing(s) to fix.%s\n\n' "$RED" "$BROKEN" "$RST"
    exit 1
fi

# Which one is Firefox actually using? The Default= line of the
# [Install...] section wins over a [Profile] marked Default=1, and that
# distinction is exactly how you end up theming the profile you are not
# looking at.
default=""
for root in $roots; do
    ini="$root/profiles.ini"
    [ -f "$ini" ] || continue
    d=$(awk '/^\[Install/{ins=1; next} /^\[/{ins=0} ins && /^Default=/{sub(/^Default=/,""); print; exit}' "$ini")
    [ -n "$d" ] && default="$root/$d"
done

while IFS= read -r prof; do
    [ -n "$prof" ] || continue
    mark=""
    [ "$prof" = "$default" ] && mark="  ${BOLD}← the one in use${RST}"
    printf '\n  %s%s%s%s\n' "$BOLD" "$(basename "$prof")" "$RST" "$mark"
    note "$prof"

    # ── 3. is the stylesheet there ────────────────────────────────────
    uc="$prof/chrome/userChrome.css"
    if [ ! -f "$uc" ]; then
        bad "no chrome/userChrome.css"
        note "run ./install.sh"
        continue
    fi
    if ! grep -q 'Hyprshell' "$uc"; then
        warn "chrome/userChrome.css is there but is not ours"
        note "something else is managing it; ./install.sh keeps a backup"
        continue
    fi
    ok "chrome/userChrome.css is ours"

    if [ -f "$prof/chrome/hyprshell-defaults.css" ]; then
        ok "chrome/hyprshell-defaults.css is there"
    else
        bad "no chrome/hyprshell-defaults.css beside it"
        note "without it, a missing palette falls back to light whatever the"
        note "browser is set to. run ./install.sh"
    fi

    # ── 4. does its @import point at a file that exists ───────────────
    # The shell's palette, which is the second import — the first is the
    # defaults sitting beside this file. Taking the first was how this
    # started reporting on the wrong one the moment there were two.
    imp=$(sed -n 's/^@import url("\(.*\)");$/\1/p' "$uc" \
          | grep -v 'hyprshell-defaults\.css' | head -1)
    if [ -z "$imp" ]; then
        bad "it has no @import line at all"
    elif [ "$imp" = "HYPRSHELL_COLORS_PATH" ]; then
        bad "the @import still says HYPRSHELL_COLORS_PATH"
        note "it was copied by hand rather than installed; run ./install.sh"
    elif [ -f "${imp#file://}" ]; then
        ok "its @import points at a palette that exists"
    else
        warn "its @import points at ${imp#file://}, which is not there"
        note "not fatal — the stylesheet falls back to the default palette"
    fi

    # ── 5. the pref ───────────────────────────────────────────────────
    #
    # user.js is applied over prefs.js at every startup, so user.js wins
    # if both name it. Both are checked because a false in user.js is the
    # one that would actually stop this working.
    js="$prof/user.js"
    pj="$prof/prefs.js"
    ujs=$(grep -h "$PREF" "$js" 2>/dev/null | tail -1)
    pjs=$(grep -h "$PREF" "$pj" 2>/dev/null | tail -1)
    if printf '%s' "$ujs" | grep -q 'true'; then
        ok "user.js sets the stylesheets pref"
    elif printf '%s' "$ujs" | grep -q 'false'; then
        bad "user.js sets the stylesheets pref to FALSE"
        note "remove that line, or run ./install.sh"
    elif printf '%s' "$pjs" | grep -q 'true'; then
        ok "prefs.js has the stylesheets pref (set by hand, that is fine)"
    else
        bad "the stylesheets pref is not set in this profile"
        note "run ./install.sh, or set it in about:config:"
        note "  $PREF = true"
    fi
done <<< "$profiles"

# ── 6. has it been restarted since ────────────────────────────────────
head1 "Restarting"
if pgrep -x firefox >/dev/null 2>&1 || pgrep -x firefox-bin >/dev/null 2>&1; then
    # The process start time against the file's, which is the only way to
    # tell "restarted since installing" from "still the same window".
    pid=$(pgrep -x firefox | head -1)
    started=$(stat -c %Y "/proc/$pid" 2>/dev/null || echo 0)
    installed=0
    while IFS= read -r prof; do
        [ -n "$prof" ] || continue
        f="$prof/chrome/userChrome.css"
        [ -f "$f" ] || continue
        t=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        [ "$t" -gt "$installed" ] && installed=$t
    done <<< "$profiles"

    if [ "$started" -gt "$installed" ] && [ "$installed" -gt 0 ]; then
        ok "Firefox has been started since the stylesheet was installed"
    else
        bad "Firefox has been running since before the stylesheet was installed"
        note "it reads chrome CSS once, at startup — quit it fully and start it again"
        note "closing the window is not always enough; check with: pgrep -x firefox"
    fi
else
    warn "Firefox is not running"
    note "start it, and it will read the stylesheet on the way up"
fi

# ── light against dark ────────────────────────────────────────────────
#
# The one that produces the most confusing result of all, because
# nothing is broken: the chrome is exactly the colour it was told to be,
# and it is the wrong one. A light palette under a dark GTK gives a menu
# with the platform's dark box and this theme's dark-on-dark text, which
# reads as "the theme is broken" rather than as "these two disagree".
head1 "Light against dark"

palette_scheme=""
[ -f "$COLORS" ] && palette_scheme=$(sed -n 's/.*color-scheme: *\([a-z]*\);.*/\1/p' "$COLORS" | head -1)

shell_theme=""
tj="$CONF/quickshell/hyprshell/theme.json"
[ -f "$tj" ] && shell_theme=$(sed -n 's/.*"theme" *: *"\([a-z]*\)".*/\1/p' "$tj" | head -1)

gtk_scheme=""
if command -v gsettings >/dev/null 2>&1; then
    gtk_scheme=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null \
                 | tr -d "'")
fi

ff_theme=""
while IFS= read -r prof; do
    [ -n "$prof" ] || continue
    # 0 is dark, 1 is light, 2 is follow the system.
    t=$(grep -h 'browser.theme.toolbar-theme' "$prof/prefs.js" 2>/dev/null \
        | sed -n 's/.*, *\([0-9]*\));.*/\1/p' | tail -1)
    [ -n "$t" ] && ff_theme="$t"
done <<< "$profiles"
case "$ff_theme" in
    0) ff_theme=dark ;; 1) ff_theme=light ;; 2) ff_theme="follows the system" ;;
    *) ff_theme="" ;;
esac

printf '  %-22s %s\n' "this theme's palette" "${palette_scheme:-unknown}"
printf '  %-22s %s\n' "the shell" "${shell_theme:-unknown}"
printf '  %-22s %s\n' "GTK / the portal" "${gtk_scheme:-unknown}"
printf '  %-22s %s\n' "Firefox's own theme" "${ff_theme:-unknown}"
printf '\n'

if [ -z "$palette_scheme" ]; then
    warn "no palette, so the defaults are in force and follow the system"
elif [ "$palette_scheme" = "light" ] && \
     { [ "${gtk_scheme}" = "prefer-dark" ] || [ "$ff_theme" = "dark" ]; }; then
    bad "the palette is LIGHT and the browser around it is DARK"
    note "the chrome is doing what it was told — it was told the wrong thing."
    note "the palette follows the SHELL, so either put the shell in dark mode"
    note "(Settings → Appearance) and it will follow, or put Firefox in light."
elif [ "$palette_scheme" = "dark" ] && \
     { [ "${gtk_scheme}" = "default" ] || [ "$ff_theme" = "light" ]; }; then
    bad "the palette is DARK and the browser around it is LIGHT"
    note "set Firefox to dark in about:addons → Themes, or the shell to light."
else
    ok "nothing obviously disagreeing"
fi

if [ -n "$shell_theme" ] && [ -n "$palette_scheme" ] \
   && [ "$shell_theme" != "$palette_scheme" ] && [ "$shell_theme" != "auto" ]; then
    bad "the shell is $shell_theme but the palette says $palette_scheme"
    note "the shell has not rewritten it. run:"
    note "  qs -c hyprshell ipc call shell syncTheming"
fi

if [ "$BROKEN" -eq 0 ]; then
    printf '\n%sEverything this can check is in order.%s\n' "$GRN" "$RST"
    printf 'If the chrome still looks stock, the rules are matching element\n'
    printf 'ids this Firefox no longer uses — see the README for how to find\n'
    printf 'the new ones, and send a screenshot.\n\n'
else
    printf '\n%s%d thing(s) to fix.%s\n\n' "$RED" "$BROKEN" "$RST"
fi
exit 0
