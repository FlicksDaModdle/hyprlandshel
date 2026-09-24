#!/usr/bin/env bash
#
# Why is a file dialog still not this one?
#
# Between pressing "Open" in a browser and a dialog appearing there are
# six separate things that each have to be true, and all but one of them
# fail silently — the dialog opens, it is simply someone else's. This
# walks the chain and says which link is broken.
#
#   ./portal-doctor.sh
#
# Not `set -e`: every check here is allowed to come back negative, and
# that is the point of running it.

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

# ── 1. the browser has to ask ────────────────────────────────────────────
#
# Firefox's own GTK dialog is the default on a plain desktop:
# widget.use-xdg-desktop-portal.file-picker is 2, "auto", which means the
# portal only for sandboxed builds. Set to 1 it always asks, and only
# then does anything below this line matter.
head1 "Does the browser ask the portal at all?"
FFPREF=widget.use-xdg-desktop-portal.file-picker
FOUND=
for prefs in "$HOME"/.mozilla/firefox/*/prefs.js "$HOME"/.mozilla/firefox/*/user.js \
             "$HOME"/snap/firefox/common/.mozilla/firefox/*/prefs.js \
             "$HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/*/prefs.js; do
    [ -r "$prefs" ] || continue
    line=$(grep -h "$FFPREF" "$prefs" 2>/dev/null | tail -1)
    [ -n "$line" ] || continue
    FOUND=yes
    case "$line" in
        *", 1)"*) ok "firefox: $FFPREF is 1  ${DIM}($(basename "$(dirname "$prefs")"))${RST}" ;;
        *", 0)"*) bad "firefox: $FFPREF is 0 — it will never use a portal"
                  note "about:config → $FFPREF → 1" ;;
        *)        bad "firefox: $FFPREF is ${line##*, }"
                  note "2 is \"auto\", which for an unsandboxed Firefox means its own GTK dialog."
                  note "about:config → $FFPREF → 1" ;;
    esac
done
if [ -z "$FOUND" ]; then
    bad "firefox: $FFPREF is not set, so it defaults to 2 (\"auto\")"
    note "An unsandboxed Firefox reads that as \"use my own GTK dialog\", and"
    note "never asks the portal. about:config → $FFPREF → 1, then restart it."
    note "Nothing else below can take effect until this is 1."
fi

# ── 2. the backend has to be installed where the portal looks ────────────
head1 "Is the backend where xdg-desktop-portal looks?"
DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
MINE=
IFS=: read -ra DLIST <<< "$DIRS"
for d in "${DLIST[@]}"; do
    [ -f "$d/xdg-desktop-portal/portals/hyprshell.portal" ] || continue
    MINE="$d/xdg-desktop-portal/portals/hyprshell.portal"
    break
done
if [ -n "$MINE" ]; then
    ok "hyprshell.portal: $MINE"
else
    bad "hyprshell.portal is not on XDG_DATA_DIRS"
    note "XDG_DATA_DIRS=$DIRS"
    for d in "$HOME/.local/share" /usr/local/share /usr/share; do
        [ -f "$d/xdg-desktop-portal/portals/hyprshell.portal" ] \
            && note "it is installed at $d/... — that prefix is not on the list"
    done
    note "./install.sh writes an environment.d file for this; it needs a re-login."
    note "To skip all of that, put the file where the search always looks:"
    note "  sudo ln -sfn \"\$HOME/.local/share/xdg-desktop-portal/portals/hyprshell.portal\" \\"
    note "       /usr/share/xdg-desktop-portal/portals/hyprshell.portal"
    note "  systemctl --user restart xdg-desktop-portal"
fi

# UseIn has to match the session, or the file is read and discarded.
if [ -n "$MINE" ]; then
    USEIN=$(sed -n 's/^UseIn=//p' "$MINE" | tr -d ' ')
    DESK="${XDG_CURRENT_DESKTOP:-}"
    if [ -z "$DESK" ]; then
        warn "XDG_CURRENT_DESKTOP is unset — the portal cannot match UseIn=$USEIN"
    elif printf '%s' ":$DESK:" | grep -qi ":${USEIN%%;*}:"; then
        ok "UseIn=$USEIN matches XDG_CURRENT_DESKTOP=$DESK"
    else
        bad "UseIn=$USEIN does not match XDG_CURRENT_DESKTOP=$DESK"
        note "Edit UseIn= in $MINE to name this desktop."
    fi
fi

# ── 3. and the bus has to be able to start it ────────────────────────────
head1 "Can the bus start it?"
SVC=org.freedesktop.impl.portal.desktop.hyprshell
SVCFILE=
for d in "${DLIST[@]}" "$HOME/.local/share"; do
    [ -f "$d/dbus-1/services/$SVC.service" ] && { SVCFILE="$d/dbus-1/services/$SVC.service"; break; }
done
if [ -n "$SVCFILE" ]; then
    ok "service file: $SVCFILE"
    EXEC=$(sed -n 's/^Exec=//p' "$SVCFILE" | cut -d' ' -f1)
    if [ -x "$EXEC" ]; then ok "it points at $EXEC"
    else bad "it points at $EXEC, which is not there"; fi
else
    bad "no D-Bus service file for $SVC"
    note "Run ./install.sh — without this the bus cannot start the backend on demand."
fi

# The bus hands this to systemd, so the unit has to be one it knows, and
# the environment that matters is the user manager's. A Qt program with no
# WAYLAND_DISPLAY cannot open a display and dies during startup — which the
# caller sees only as "activation failed".
UNIT=hyprshell-files-portal.service
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    if systemctl --user cat "$UNIT" >/dev/null 2>&1; then
        ok "systemd knows $UNIT"
    else
        bad "systemd does not know $UNIT"
        note "Run ./install.sh, then: systemctl --user daemon-reload"
    fi
    if systemctl --user show-environment 2>/dev/null | grep -q '^WAYLAND_DISPLAY='; then
        ok "the user manager has WAYLAND_DISPLAY"
    else
        bad "the user manager has no WAYLAND_DISPLAY"
        note "Anything the bus starts then has no display to open on, and dies."
        note "dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP"
        note "The shell's hyprland.lua does this at login; this session started before it did."
    fi
fi

# Having the file on disk is not the same as the bus having read it.
#
# A bus daemon lists its activatable services when it starts, and watches
# the directories it found then. An install that *creates*
# ~/.local/share/dbus-1/services leaves a directory nothing is watching,
# so the name stays unknown however correct the file is — and what a
# caller is told is "The name is not activatable", which reads like the
# service is broken rather than unseen.
if command -v gdbus >/dev/null 2>&1; then
    ACT=$(timeout 10 gdbus call --session --dest org.freedesktop.DBus \
          --object-path /org/freedesktop/DBus \
          --method org.freedesktop.DBus.ListActivatableNames 2>/dev/null)
    case "$ACT" in
        *"$SVC"*) ok "the bus lists it as activatable" ;;
        "")       warn "could not ask the bus what it can activate" ;;
        *)        bad "the bus does not list $SVC as activatable"
                  if [ -n "$SVCFILE" ]; then
                      note "The file is there; the bus has not read it. Ask it to:"
                  else
                      note "Install it (./install.sh), then ask the bus to re-read:"
                  fi
                  note "  systemctl --user reload dbus.service"
                  note "or, on a bus without that unit:"
                  note "  gdbus call --session --dest org.freedesktop.DBus \\"
                  note "    --object-path /org/freedesktop/DBus \\"
                  note "    --method org.freedesktop.DBus.ReloadConfig"
                  note "If it is still unknown after that, log out and back in." ;;
    esac
fi

if command -v gdbus >/dev/null 2>&1; then
    if timeout 10 gdbus call --session --dest "$SVC" \
         --object-path /org/freedesktop/portal/desktop \
         --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
        ok "the bus started it and it answered"
        XML=$(timeout 10 gdbus introspect --session --dest "$SVC" \
              --object-path /org/freedesktop/portal/desktop 2>/dev/null)
        MISS=
        for m in OpenFile SaveFile SaveFiles; do
            printf '%s' "$XML" | grep -q "$m(" || MISS="$MISS $m"
        done
        if [ -z "$MISS" ]; then ok "it exports OpenFile, SaveFile and SaveFiles"
        else bad "it is missing:$MISS"; fi
    else
        bad "the bus could not start $SVC"
        note "What it said on the way down:"
        note "  journalctl --user -u $UNIT -n 20 --no-pager"
        note "Or run it yourself, which shows the same thing:"
        note "  hyprshell-files --portal"
    fi
else
    warn "gdbus is not installed, so the backend could not be called (glib2)"
fi

# ── 4. and the portal has to choose it ───────────────────────────────────
head1 "Is it the one chosen for file dialogs?"
KEY=org.freedesktop.impl.portal.FileChooser
CONF=
for c in "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal/$(printf '%s' "${XDG_CURRENT_DESKTOP:-hyprland}" | cut -d: -f1 | tr '[:upper:]' '[:lower:]')-portals.conf" \
         "${XDG_CONFIG_HOME:-$HOME/.config}/xdg-desktop-portal/portals.conf"; do
    [ -r "$c" ] && { CONF="$c"; break; }
done
if [ -z "$CONF" ]; then
    bad "no portals.conf — whichever backend answers first wins, and several may"
    note "./install.sh writes one."
else
    LINE=$(grep -h "^[[:space:]]*$KEY[[:space:]]*=" "$CONF" | tail -1)
    case "$LINE" in
        *=hyprshell*) ok "$CONF: $LINE" ;;
        "")           bad "$CONF names no backend for file dialogs"
                      note "Add:  $KEY=hyprshell" ;;
        *)            bad "$CONF: $LINE"
                      note "Change it to:  $KEY=hyprshell" ;;
    esac
fi

# Which other backends are installed, because that is what it is losing to.
OTHERS=
for d in "${DLIST[@]}"; do
    [ -d "$d/xdg-desktop-portal/portals" ] || continue
    for p in "$d"/xdg-desktop-portal/portals/*.portal; do
        [ -r "$p" ] || continue
        grep -q "$KEY" "$p" || continue
        b=$(basename "$p" .portal)
        [ "$b" = hyprshell ] || OTHERS="$OTHERS $b"
    done
done
[ -n "$OTHERS" ] && note "others offering file dialogs:$OTHERS"

# ── 5. and it has to have been read ──────────────────────────────────────
head1 "Has xdg-desktop-portal read any of this?"
XPID=
if command -v systemctl >/dev/null 2>&1 \
   && systemctl --user is-active xdg-desktop-portal >/dev/null 2>&1; then
    SINCE=$(systemctl --user show -p ActiveEnterTimestamp --value xdg-desktop-portal)
    XPID=$(systemctl --user show -p MainPID --value xdg-desktop-portal 2>/dev/null)
    ok "xdg-desktop-portal is running ${DIM}(since $SINCE)${RST}"
else
    # Not pgrep -x: the kernel truncates a process name to 15 characters
    # and "xdg-desktop-portal" is 18, so an exact match on the name never
    # finds it. The command line is whole.
    XPID=$(pgrep -f '/xdg-desktop-portal([[:space:]]|$)' 2>/dev/null | head -1)
    [ -n "$XPID" ] && warn "xdg-desktop-portal is running, but not as a user unit" \
                   || warn "xdg-desktop-portal is not running"
fi

# The environment that decides what it can see is *its* environment, not
# this shell's. They are routinely different: exporting XDG_DATA_DIRS in a
# terminal, or setting it on the user manager, changes nothing for a
# process that was already running when you did it.
if [ -n "${XPID:-}" ] && [ -r "/proc/$XPID/environ" ]; then
    XDIRS=$(tr '\0' '\n' < "/proc/$XPID/environ" | sed -n 's/^XDG_DATA_DIRS=//p')
    XOVR=$(tr '\0' '\n' < "/proc/$XPID/environ" | sed -n 's/^XDG_DESKTOP_PORTAL_DIR=//p')
    SEEN=
    if [ -n "$XOVR" ]; then
        warn "it was started with XDG_DESKTOP_PORTAL_DIR=$XOVR"
        note "That overrides the search entirely; only backends in there are read."
        [ -f "$XOVR/hyprshell.portal" ] && SEEN=yes
    else
        IFS=: read -ra XLIST <<< "${XDIRS:-/usr/local/share:/usr/share}"
        for d in "${XLIST[@]}"; do
            [ -f "$d/xdg-desktop-portal/portals/hyprshell.portal" ] && { SEEN=yes; break; }
        done
    fi
    if [ -n "$SEEN" ]; then
        ok "the running process can see hyprshell.portal"
    else
        bad "the running process cannot see hyprshell.portal"
        note "its XDG_DATA_DIRS=${XDIRS:-<unset, so the default>}"
        note "Setting this in a shell, or on the user manager, does not reach a"
        note "process that is already running. It has to be restarted after:"
        note "  systemctl --user restart xdg-desktop-portal"
    fi
fi

if [ -n "$CONF" ] && [ -n "${XPID:-}" ] && [ -e "/proc/$XPID" ]; then
    if [ "$CONF" -nt "/proc/$XPID" ]; then
        bad "the config is newer than the running process — it has not read it"
        note "systemctl --user restart xdg-desktop-portal"
    else
        ok "it has been restarted since the config was written"
    fi
fi

# ── 6. "show in file manager" is a different question ────────────────────
#
# Nothing above decides what happens when a browser's downloads list
# points at a file. That goes one of two ways — the FileManager1
# interface, or the MIME default for a folder — and they are configured
# in different places, so one can be right while the other is not.
head1 "And \"show in file manager\"?"
FM1=org.freedesktop.FileManager1

# Who would answer it. $XDG_DATA_HOME wins over $XDG_DATA_DIRS — tested,
# not assumed — so an entry of ours under ~/.local/share beats Dolphin's
# under /usr/share. Provided the bus has read it.
CLAIMS=
for d in "${XDG_DATA_HOME:-$HOME/.local/share}" "${DLIST[@]}"; do
    f="$d/dbus-1/services/$FM1.service"
    [ -r "$f" ] || continue
    who=$(sed -n 's/^Exec=//p' "$f" | cut -d' ' -f1)
    if [ -z "$CLAIMS" ]; then
        case "$who" in
            *hyprshell-files) ok "first claim on $FM1 is ours ${DIM}($f)${RST}" ;;
            *) bad "first claim on $FM1 is $who"
               note "$f is read before ours, so that is what gets started." ;;
        esac
        CLAIMS=yes
    else
        note "also claimed by $who ${DIM}($f)${RST}"
    fi
done
[ -z "$CLAIMS" ] && bad "nothing claims $FM1 — run ./install.sh"

# A name already owned is never activated, so a running Dolphin keeps it
# whatever the service files say.
if command -v gdbus >/dev/null 2>&1; then
    OWNER=$(timeout 5 gdbus call --session --dest org.freedesktop.DBus \
            --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.GetNameOwner "$FM1" 2>/dev/null \
            | tr -d "(,')")
    if [ -n "$OWNER" ]; then
        OPID=$(timeout 5 gdbus call --session --dest org.freedesktop.DBus \
               --object-path /org/freedesktop/DBus \
               --method org.freedesktop.DBus.GetConnectionUnixProcessID "$OWNER" \
               2>/dev/null | sed -n 's/.*uint32 \([0-9][0-9]*\).*/\1/p')
        WHO=$([ -n "$OPID" ] && cat "/proc/$OPID/comm" 2>/dev/null)
        case "$WHO" in
            hyprshell-file*) ok "it is held right now by $WHO ${DIM}(pid $OPID)${RST}" ;;
            "")              warn "it is held by $OWNER" ;;
            *)               bad "it is held right now by $WHO ${DIM}(pid $OPID)${RST}"
                             note "A name already owned is never activated, so this keeps it"
                             note "until it exits. Close it and try again." ;;
        esac
    fi
fi

# The other route: opening the folder itself.
if command -v xdg-mime >/dev/null 2>&1; then
    FOLDER=$(xdg-mime query default inode/directory 2>/dev/null)
    case "$FOLDER" in
        hyprshell-files.desktop) ok "folders open with hyprshell-files.desktop" ;;
        "")  bad "nothing is set to open folders"
             note "xdg-mime default hyprshell-files.desktop inode/directory" ;;
        *)   bad "folders open with $FOLDER"
             note "xdg-mime default hyprshell-files.desktop inode/directory" ;;
    esac
fi

head1 "The one test that settles it"
cat <<TESTEOF
  Ask the *frontend* portal for a dialog, exactly as a browser would.
  Whatever opens is what a browser would get:

    gdbus call --session --dest org.freedesktop.portal.Desktop \\
      --object-path /org/freedesktop/portal/desktop \\
      --method org.freedesktop.portal.FileChooser.OpenFile \\
      "" "Test" "{}"

  If that opens Files and the browser does not, the browser is not asking
  the portal — check 1 above.

  And if it opens something else, stop guessing which backend it chose and
  watch it choose. Run the portal in the foreground, with its own logging
  turned up, and make that call again in another terminal:

    systemctl --user stop xdg-desktop-portal
    G_MESSAGES_DEBUG=all /usr/lib/xdg-desktop-portal -r -v

  It names the backend it picks for each interface, and says why it
  skipped the ones it skipped. That line is the answer.

  For "show in file manager", the equivalent is to ask for it directly.
  Whatever opens is what a browser's downloads list would get:

    gdbus call --session --dest org.freedesktop.FileManager1 \\
      --object-path /org/freedesktop/FileManager1 \\
      --method org.freedesktop.FileManager1.ShowItems \\
      "['file://\$HOME/Downloads']" ""

  If that opens Files and the downloads list opens something else, the
  browser is going through the folder handler instead — the line above.
TESTEOF

if [ "$BROKEN" -gt 0 ]; then
    printf '\n%s%d link(s) broken.%s\n' "$RED" "$BROKEN" "$RST"
    exit 1
fi
printf '\n%sEvery link checks out.%s\n' "$GRN" "$RST"
