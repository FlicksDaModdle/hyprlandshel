#!/bin/bash
# Your keyring, unlocked after you log in with your face
# (Settings → Login screen → Keyring; services/FaceKeyring.qml).
#
#   face-keyring.sh --check    what there is: TPM, systemd-creds, a stored password
#   face-keyring.sh --store    the keyring's password, on stdin: checked against
#                              the keyring itself, then sealed and stored
#   face-keyring.sh --unlock   unseal it and unlock the login keyring
#   face-keyring.sh --forget   remove it
#
# A face login has no password to give the keyring, so this keeps one for
# it: sealed with systemd-creds as a credential of yours alone (--user),
# with a key from this laptop's TPM and the system's own (host+tpm2). The
# file is useless off this machine — a copied disk, a backup — and only
# you can unseal it on it. Anything running as you can, though, which is
# no more than it can already do with the keyring once it's open.
#
# The password goes through pipes only, never a command line. It reaches
# the keyring the way pam_gnome_keyring does it (scripts/keyring-unlock.py).
#
# Exit status: 0 done, 3 the keyring refused the password (changed since?),
# 4 failed, 5 no keyring daemon, 6 couldn't unseal it (TPM or system changed).
set -uo pipefail

here=$(cd "${0%/*}" && pwd)
file=${XDG_DATA_HOME:-$HOME/.local/share}/hyprshell/keyring.cred
name=hyprshell-keyring

log=${XDG_STATE_HOME:-$HOME/.local/state}/hyprshell/face-keyring.log

die() { printf 'face-keyring.sh: %s\n' "$2" >&2; note "$2"; exit "$1"; }
# What each unlock came to, with the time, for when it didn't work (never
# the password). The last hundred lines are kept.
note() {
    [ "${mode:-}" = --unlock ] || return 0
    mkdir -p "${log%/*}" 2>/dev/null || return 0
    printf '%s %s\n' "$(date '+%F %T')" "$1" >>"$log" 2>/dev/null
    [ "$(wc -l <"$log" 2>/dev/null || echo 0)" -gt 200 ] && { tail -n 100 "$log" >"$log.new" && mv -f "$log.new" "$log"; }
    return 0
}
unlock_with() { python3 -I "$here/keyring-unlock.py"; }
# The keyring's daemon, started if it isn't yet (D-Bus starts it).
wake_keyring() {
    gdbus call --session --dest org.freedesktop.secrets --object-path /org/freedesktop/secrets \
        --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1 &
}
# Unlock with the password on stdin, waiting up to ten seconds for a
# daemon that is only just starting (at login).
unlock_waiting() {
    local pw rc i
    pw=$(cat)
    for i in $(seq 1 20); do
        printf '%s' "$pw" | unlock_with
        rc=$?
        [ "$rc" = 5 ] || return "$rc"
        [ "$i" = 1 ] && wake_keyring
        sleep 0.5
    done
    return 5
}

mode=${1:-}
case $mode in
    --check)
        v=$(systemd-creds --version 2>/dev/null | sed -n '1s/^systemd \([0-9]*\).*/\1/p')
        printf 'creds\t%s\n' "${v:-0}"
        systemd-creds has-tpm2 >/dev/null 2>&1 && printf 'tpm\tyes\n' || printf 'tpm\tno\n'
        command -v gnome-keyring-daemon >/dev/null 2>&1 && printf 'keyring\tyes\n'
        [ -s "$file" ] && printf 'stored\tyes\n'
        exit 0 ;;

    --store)
        command -v systemd-creds >/dev/null 2>&1 || die 4 "systemd-creds isn't installed"
        pw=$(cat)
        [ -n "$pw" ] || die 4 "no password given"
        # The keyring's own password, or nothing is stored: it says no to
        # a wrong one even while it's open.
        printf '%s' "$pw" | unlock_waiting
        case $? in
            0) ;;
            3) die 3 "That isn't your keyring's password" ;;
            5) die 5 "The keyring isn't running" ;;
            *) die 4 "Couldn't reach the keyring" ;;
        esac
        umask 077
        mkdir -p "${file%/*}"
        printf '%s' "$pw" | systemd-creds encrypt --user --with-key=host+tpm2 --name="$name" - "$file.new" \
            || { rm -f "$file.new"; die 4 "Couldn't seal it with the TPM (systemd 256 or newer, and a TPM, are needed)"; }
        # Unsealed again before it's kept, to be sure it will be.
        [ "$(systemd-creds decrypt --user --name="$name" "$file.new" - 2>/dev/null)" = "$pw" ] \
            || { rm -f "$file.new"; die 6 "Sealed, but it couldn't be unsealed again"; }
        mv -f "$file.new" "$file"
        echo stored
        exit 0 ;;

    --unlock)
        [ -s "$file" ] || exit 0
        # One at a time: the session's start and the shell both ask.
        if command -v flock >/dev/null 2>&1; then
            exec 9>"${XDG_RUNTIME_DIR:-/tmp}/hyprshell-face-keyring.lock" && flock -w 30 9
        fi
        # At login the TPM and systemd's credential service can still be
        # starting: tried for a few seconds before giving up.
        for i in 1 2 3 4 5 6; do
            pw=$(systemd-creds decrypt --user --name="$name" "$file" - 2>"${XDG_RUNTIME_DIR:-/tmp}/hyprshell-face-keyring.err") && break
            pw=""
            sleep 1
        done
        if [ -z "$pw" ]; then
            why=$(tail -n 1 "${XDG_RUNTIME_DIR:-/tmp}/hyprshell-face-keyring.err" 2>/dev/null)
            rm -f "${XDG_RUNTIME_DIR:-/tmp}/hyprshell-face-keyring.err"
            die 6 "Couldn't unseal the keyring's password (${why:-systemd-creds failed}): store it again in Settings"
        fi
        rm -f "${XDG_RUNTIME_DIR:-/tmp}/hyprshell-face-keyring.err"
        printf '%s' "$pw" | unlock_waiting
        case $? in
            0) note unlocked; echo unlocked; exit 0 ;;
            3) die 3 "The keyring's password has changed: store it again" ;;
            5) die 5 "The keyring isn't running" ;;
            *) die 4 "Couldn't reach the keyring" ;;
        esac ;;

    --forget)
        rm -f "$file" "$file.new"
        echo forgotten
        exit 0 ;;

    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
