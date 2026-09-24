#!/bin/sh
# Make hyprshell-term the terminal the rest of the desktop opens.
#
# There is no single switch for this. "The default terminal" is four or
# five different mechanisms depending on which program is asking, and a
# setup that covers one of them looks like it worked right up until
# something that reads a different one opens kitty instead. So this sets
# all of them, and prints what it did.
#
#   ~/.config/xdg-terminals.list     the freedesktop default-terminal
#                                    proposal, read by xdg-terminal-exec
#                                    and by recent GLib
#   x-scheme-handler/terminal        asked by some file managers
#   gsettings                        GNOME's older setting, still read by
#                                    a fair amount of GTK software
#   kdeglobals TerminalApplication   the same question, KDE's answer
#   $TERMINAL                        the oldest one, and still the most
#                                    widely honoured; the session sets it
#                                    (see shell/hypr/hyprland.lua)
#
#   --undo   puts back what was there before, where that is knowable.
#
# Nothing here needs root and nothing touches a file outside your own
# config.
set -u

ENTRY=hyprshell-term.desktop
BIN=hyprshell-term
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"
UNDO=no
[ "${1:-}" = "--undo" ] && UNDO=yes

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m')
    GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m'); RST=$(printf '\033[0m')
else
    BOLD=; DIM=; GRN=; YEL=; RST=
fi
did()  { printf '  %s✓%s %s\n' "$GRN" "$RST" "$1"; }
skip() { printf '  %s·%s %s %s(%s)%s\n' "$YEL" "$RST" "$1" "$DIM" "$2" "$RST"; }

printf '\n%sDefault terminal%s\n\n' "$BOLD" "$RST"

# Is it actually installed? Setting the desktop's default to something
# that is not there is worse than leaving it alone.
if [ "$UNDO" = no ]; then
    found=
    command -v "$BIN" >/dev/null 2>&1 && found=$(command -v "$BIN")
    for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do
        [ -n "$found" ] && break
        [ -x "$d/$BIN" ] && found="$d/$BIN"
    done
    if [ -z "$found" ]; then
        printf '  %s is not installed. Run ./install.sh first.\n\n' "$BIN"
        exit 1
    fi
    did "found $found"

    # And the desktop entry, which every mechanism below names rather
    # than pointing at the binary.
    entrypath=
    for d in "$CONF/../local/share" "$HOME/.local/share" /usr/local/share /usr/share; do
        [ -n "$entrypath" ] && break
        [ -f "$d/applications/$ENTRY" ] && entrypath="$d/applications/$ENTRY"
    done
    if [ -z "$entrypath" ]; then
        printf '  %s%s is not in any applications directory.%s\n' "$YEL" "$ENTRY" "$RST"
        printf '  Run ./install.sh so the desktop can find it, then run this again.\n\n'
        exit 1
    fi
    did "found $entrypath"
fi

# ── the freedesktop one ───────────────────────────────────────────────
#
# A list, most-preferred first. The desktop-suffixed file wins over the
# plain one when $XDG_CURRENT_DESKTOP names a desktop, so both are
# written — otherwise this works everywhere except under Hyprland, which
# is the one place it has to.
mkdir -p "$CONF"
for name in xdg-terminals.list Hyprland-xdg-terminals.list; do
    f="$CONF/$name"
    if [ "$UNDO" = yes ]; then
        if [ -f "$f.hyprshell-backup" ]; then
            mv "$f.hyprshell-backup" "$f"; did "put back $name"
        elif [ -f "$f" ] && [ "$(cat "$f")" = "$ENTRY" ]; then
            rm -f "$f"; did "removed $name"
        else
            skip "$name" "not ours to undo"
        fi
        continue
    fi
    # Keep whatever was there as a second choice rather than dropping it.
    if [ -f "$f" ] && ! grep -qx "$ENTRY" "$f" 2>/dev/null; then
        [ -f "$f.hyprshell-backup" ] || cp "$f" "$f.hyprshell-backup"
        printf '%s\n%s' "$ENTRY" "$(cat "$f")" > "$f.new" && mv "$f.new" "$f"
        did "$name — added at the top, kept what was there"
    elif [ -f "$f" ]; then
        # Already listed; make sure it is first.
        rest=$(grep -vx "$ENTRY" "$f" 2>/dev/null)
        { printf '%s\n' "$ENTRY"; [ -n "$rest" ] && printf '%s\n' "$rest"; } > "$f.new"
        mv "$f.new" "$f"
        did "$name — moved to the top"
    else
        printf '%s\n' "$ENTRY" > "$f"
        did "$name"
    fi
done

# ── x-scheme-handler/terminal ─────────────────────────────────────────
if command -v xdg-mime >/dev/null 2>&1; then
    if [ "$UNDO" = yes ]; then
        skip "x-scheme-handler/terminal" "left as it is; set it by hand if you had one"
    else
        xdg-mime default "$ENTRY" x-scheme-handler/terminal 2>/dev/null \
            && did "x-scheme-handler/terminal" \
            || skip "x-scheme-handler/terminal" "xdg-mime would not take it"
    fi
else
    skip "x-scheme-handler/terminal" "no xdg-mime"
fi

# ── GNOME's setting ───────────────────────────────────────────────────
GS=org.gnome.desktop.default-applications.terminal
if command -v gsettings >/dev/null 2>&1 \
   && gsettings writable "$GS" exec >/dev/null 2>&1; then
    if [ "$UNDO" = yes ]; then
        gsettings reset "$GS" exec 2>/dev/null
        gsettings reset "$GS" exec-arg 2>/dev/null
        did "gsettings reset"
    else
        gsettings set "$GS" exec "$BIN" 2>/dev/null
        gsettings set "$GS" exec-arg "-e" 2>/dev/null
        did "gsettings $GS exec"
    fi
else
    skip "gsettings" "no gsettings, or the schema is not installed"
fi

# ── KDE's ─────────────────────────────────────────────────────────────
#
# Edited in place rather than rewritten: kdeglobals carries the colour
# scheme the shell generates, and replacing the file would take it with
# it. The key goes into [General], which is where KDE reads it.
KG="$CONF/kdeglobals"
if [ "$UNDO" = yes ]; then
    if [ -f "$KG" ] && grep -q '^TerminalApplication=' "$KG" 2>/dev/null; then
        sed -i '/^TerminalApplication=/d;/^TerminalService=/d' "$KG"
        did "removed TerminalApplication from kdeglobals"
    else
        skip "kdeglobals" "nothing to remove"
    fi
elif command -v kwriteconfig6 >/dev/null 2>&1; then
    kwriteconfig6 --file kdeglobals --group General --key TerminalApplication "$BIN"
    kwriteconfig6 --file kdeglobals --group General --key TerminalService "$ENTRY"
    did "kdeglobals (kwriteconfig6)"
elif command -v kwriteconfig5 >/dev/null 2>&1; then
    kwriteconfig5 --file kdeglobals --group General --key TerminalApplication "$BIN"
    kwriteconfig5 --file kdeglobals --group General --key TerminalService "$ENTRY"
    did "kdeglobals (kwriteconfig5)"
else
    # By hand. Append to [General] if it is there, add the group if not.
    touch "$KG"
    sed -i '/^TerminalApplication=/d;/^TerminalService=/d' "$KG"
    if grep -q '^\[General\]' "$KG"; then
        sed -i "0,/^\[General\]/s//[General]\nTerminalApplication=$BIN\nTerminalService=$ENTRY/" "$KG"
    else
        printf '\n[General]\nTerminalApplication=%s\nTerminalService=%s\n' \
               "$BIN" "$ENTRY" >> "$KG"
    fi
    did "kdeglobals (written by hand)"
fi

# ── the desktop database, so choosers see the entry ───────────────────
if command -v update-desktop-database >/dev/null 2>&1; then
    for d in "$HOME/.local/share/applications" /usr/local/share/applications \
             /usr/share/applications; do
        [ -d "$d" ] && [ -w "$d" ] && update-desktop-database "$d" 2>/dev/null
    done
    did "refreshed the desktop database"
fi

if [ "$UNDO" = yes ]; then
    printf '\n  Undone. $TERMINAL is set by the session — remove the hl.env line\n'
    printf '  in shell/hypr/hyprland.lua if you want that gone too.\n\n'
    exit 0
fi

cat <<EOS

  ${DIM}\$TERMINAL is set by the session, in shell/hypr/hyprland.lua.
  Log out and back in, or run:  hyprctl keyword env TERMINAL,$BIN${RST}

  Check it:   xdg-terminal-exec        ${DIM}# if you have it${RST}
              gio open terminal://     ${DIM}# if you have gio${RST}

  Undo it:    ./set-default-terminal.sh --undo

EOS
