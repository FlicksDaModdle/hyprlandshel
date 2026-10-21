#!/bin/bash
# Your face at the lock screen and the login screen, with Howdy.
#
#   sudo ./howdy-setup.sh                  set it up
#   sudo ./howdy-setup.sh --check          say what is there
#   sudo ./howdy-setup.sh --remove         take it out again
#   sudo ./howdy-setup.sh --camera DEVICE  use that camera (/dev/videoN)
#   sudo ./howdy-setup.sh --add-face       enrol your face (look at the camera)
#   sudo ./howdy-setup.sh --add-face --alt …as an alternative look (glasses, a beard)
#   sudo ./howdy-setup.sh --add-face --stills DIR   …with webcam pictures taken meanwhile
#   sudo ./howdy-setup.sh --webcam-check on DEVICE  the webcam has to know you too
#   sudo ./howdy-setup.sh --webcam-check off        the infrared camera alone
#   sudo ./howdy-setup.sh --set video.certainty=3.2 …  Howdy's settings (scripts/howdy-config.py)
#   sudo ./howdy-setup.sh --remove-face ID forget one look (the ID from --list-faces)
#   sudo ./howdy-setup.sh --clear-faces    forget every face of yours
#   sudo ./howdy-setup.sh --list-faces     the faces enrolled for you
#
# Settings → Login screen runs these through pkexec. Faces are always the
# ones of the person who ran it (pkexec's or sudo's caller), never anyone
# named on the command line.
#
# Howdy itself comes first (it is not part of Hyprshell):
#
#   paru -S howdy-git                       Howdy 3, with pam_howdy.so
#   paru -S linux-enable-ir-emitter         if the IR camera's light stays off
#   sudo linux-enable-ir-emitter configure  …and set it up
#   sudo howdy config                       device_path = your IR camera
#   sudo howdy add                          your face, once or twice
#
# What this changes:
#
#   /etc/pam.d/hyprshell-lock   new: the lock screen's face-only service.
#                               Your password still goes through `login`,
#                               exactly as before; this is only the face.
#   /etc/pam.d/greetd           one line, marked "# hyprshell-face", just before
#                               the password is asked for: your face first, and if
#                               Howdy doesn't find you, the password as before.
#                               The file as it was is kept beside it, as
#                               greetd.before-hyprshell-face.
#
# Logging in with your face can't unlock the keyring: that needs the
# password itself. After a face login, the first thing that wants the
# keyring asks for it once.
set -euo pipefail

LOCK=/etc/pam.d/hyprshell-lock
GREETD=/etc/pam.d/greetd
MARK="# hyprshell-face"

say() { printf '  %s\n' "$*"; }
die() { printf 'howdy-setup.sh: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run it with sudo"

mode=install camera="" alt=0 id="" stills="" webcam=""
settings=()
case ${1:-} in
    --check) mode=check ;;
    --remove) mode=remove ;;
    --add-face)
        mode=add; shift
        while [ $# -gt 0 ]; do
            case $1 in
                --alt) alt=1 ;;
                --stills) stills=${2:-}; shift ;;
                *) die "unknown option: $1" ;;
            esac
            shift
        done
        ;;
    --set)
        mode=set; shift
        settings=("$@")
        [ ${#settings[@]} -gt 0 ] || die "--set section.key=value …"
        ;;
    --webcam-check)
        mode=webcam; webcam=${2:-}
        case $webcam in
            on)
                camera=${3:-}
                [[ $camera =~ ^/dev/video[0-9]{1,3}$ ]] || die "not a camera device: $camera"
                [ -c "$camera" ] || die "no such camera: $camera" ;;
            off) ;;
            *) die "--webcam-check on DEVICE, or off" ;;
        esac
        ;;
    --remove-face)
        mode=forget; id=${2:-}
        [[ $id =~ ^[0-9]{1,5}$ ]] || die "not a face ID: $id"
        ;;
    --clear-faces) mode=clear ;;
    --list-faces) mode=list ;;
    --camera)
        mode=camera; camera=${2:-}
        [[ $camera =~ ^/dev/video[0-9]{1,3}$ || $camera =~ ^/dev/v4l/by-(id|path)/[A-Za-z0-9._:-]{1,200}$ ]] \
            || die "not a camera device: $camera"
        [ -c "$camera" ] || die "no such camera: $camera"
        ;;
    "") ;;
    *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

# Whose faces: the person behind pkexec or sudo.
person=""
if [ -n "${PKEXEC_UID:-}" ]; then person=$(id -nu "$PKEXEC_UID")
elif [ -n "${SUDO_USER:-}" ]; then person=$SUDO_USER
fi
need_person() { [ -n "$person" ] && [ "$person" != root ] || die "run it as yourself, through sudo or pkexec"; }
need_howdy() { command -v howdy >/dev/null 2>&1 || die "Howdy isn't installed — paru -S howdy-git"; }
CONFIG=""
for c in /etc/howdy/config.ini /usr/lib/security/howdy/config.ini /lib/security/howdy/config.ini; do
    [ -f "$c" ] && { CONFIG=$c; break; }
done

# Howdy's own folder (compare.py and its rubberstamps), wherever the
# package put it.
howdy_dir() {
    local d c
    d=$(readlink -f "$(command -v howdy 2>/dev/null)" 2>/dev/null) && d=${d%/*}
    for c in "$d" /usr/lib/howdy /usr/lib/security/howdy /lib/security/howdy /usr/share/howdy; do
        [ -n "$c" ] && [ -f "$c/compare.py" ] && [ -d "$c/rubberstamps" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}
here=$(cd "${0%/*}" && pwd)
STAMP=hyprshell_webcam.py
webcam_py() { python3 -I "$here/howdy-webcam.py" "$@"; }

case $mode in
    camera)
        need_howdy
        [ -n "$CONFIG" ] || die "Howdy's config.ini wasn't found"
        if grep -Eq '^[[:space:]]*device_path[[:space:]]*=' "$CONFIG"; then
            sed -i -E "s|^[[:space:]]*device_path[[:space:]]*=.*|device_path = $camera|" "$CONFIG"
        else
            die "no device_path in $CONFIG"
        fi
        say "Howdy uses $camera"
        exit 0 ;;
    add)
        need_person; need_howdy
        # Howdy asks for a name for the new face (24 characters at most);
        # this gives it one.
        if [ "$alt" = 1 ]; then label="Alt look $(date +%Y-%m-%d)"; else label="Face $(date +%Y-%m-%d)"; fi
        # Webcam pictures from Settings, taken while you lined up: only
        # from your own runtime folder, where Settings puts them.
        if [ -n "$stills" ]; then
            uid=$(id -u "$person")
            [ "$stills" = "/run/user/$uid/hyprshell-face-stills" ] && [ -d "$stills" ] && [ ! -L "$stills" ] \
                || die "webcam pictures aren't where Settings keeps them: $stills"
        fi
        # (For Settings: the camera is being recorded from now.)
        echo recording
        printf '%s\n' "$label" | howdy -U "$person" add || exit $?
        if [ -n "$stills" ]; then
            hdir=$(howdy_dir) && webcam_py enrol "$hdir" "$person" "$label" "$stills" \
                || echo "webcam: the webcam pictures couldn't be kept; the infrared camera decides alone for this look"
        fi
        exit 0 ;;
    forget)
        need_person; need_howdy
        howdy -U "$person" -y remove "$id" || exit $?
        { hdir=$(howdy_dir) && webcam_py forget "$hdir" "$person" "$id"; } || true
        exit 0 ;;
    clear)
        need_person; need_howdy
        howdy -U "$person" -y clear || exit $?
        { hdir=$(howdy_dir) && webcam_py clear "$hdir" "$person"; } || true
        exit 0 ;;
    set)
        need_howdy
        [ -n "$CONFIG" ] || die "Howdy's config.ini wasn't found"
        # Checked there, every one, before anything is written.
        python3 -I "$here/howdy-config.py" "$CONFIG" "${settings[@]}" || exit 1
        exit 0 ;;
    webcam)
        need_howdy
        [ -n "$CONFIG" ] || die "Howdy's config.ini wasn't found"
        hdir=$(howdy_dir) || die "Howdy's rubberstamps folder wasn't found"
        if [ "$webcam" = on ]; then
            install -m 644 -o root -g root "$here/$STAMP" "$hdir/rubberstamps/$STAMP"
            webcam_py rule "$CONFIG" on "$camera"
            say "The webcam has to recognise you too ($camera); in low light the infrared camera decides alone"
        else
            webcam_py rule "$CONFIG" off
            rm -f "$hdir/rubberstamps/$STAMP"
            say "The infrared camera decides alone"
        fi
        exit 0 ;;
    list)
        need_person; need_howdy
        howdy -U "$person" list
        exit $? ;;
esac

module=""
for d in /usr/lib/security /lib/security /usr/lib64/security /lib64/security /usr/lib/x86_64-linux-gnu/security; do
    [ -f "$d/pam_howdy.so" ] && { module="$d/pam_howdy.so"; break; }
done

if [ "$mode" = check ]; then
    say "Howdy's PAM module: ${module:-not found (install howdy-git: Howdy 3)}"
    say "lock screen service: $([ -f "$LOCK" ] && echo "$LOCK" || echo "not set up")"
    say "login screen: $(grep -q "$MARK" "$GREETD" 2>/dev/null && echo "face first" || echo "password only")"
    command -v howdy >/dev/null 2>&1 && say "faces enrolled for ${SUDO_USER:-root}: $(howdy -U "${SUDO_USER:-root}" list 2>/dev/null | tail -n +2 | wc -l)"
    exit 0
fi

if [ "$mode" = remove ]; then
    rm -f "$LOCK"
    if [ -n "$CONFIG" ] && hdir=$(howdy_dir) && [ -f "$hdir/rubberstamps/$STAMP" ]; then
        webcam_py rule "$CONFIG" off || true
        rm -f "$hdir/rubberstamps/$STAMP"
    fi
    if [ -f "$GREETD" ] && grep -q "$MARK" "$GREETD"; then
        grep -v "$MARK" "$GREETD" > "$GREETD.new"
        chmod --reference="$GREETD" "$GREETD.new"
        mv -f "$GREETD.new" "$GREETD"
    fi
    say "Face login is off: the lock screen and the login screen ask for your password only."
    exit 0
fi

[ -n "$module" ] || die "Howdy 3's pam_howdy.so isn't installed — paru -S howdy-git (see the top of this file)"

cat > "$LOCK" <<PAM
#%PAM-1.0
# Hyprshell's lock screen: your face, with Howdy (scripts/howdy-setup.sh).
# Only the face: the password goes through \`login\`, as before.
auth      required     pam_howdy.so
account   include      login
PAM
chmod 644 "$LOCK"
say "lock screen: looks for your face as it locks ($LOCK)"

if [ ! -f "$GREETD" ]; then
    say "no $GREETD (is greetd installed?) — the login screen is left as it is"
elif grep -q "$MARK" "$GREETD"; then
    say "login screen: already face first"
else
    [ -f "$GREETD.before-hyprshell-face" ] || cp -p "$GREETD" "$GREETD.before-hyprshell-face"
    # Just before the password: after the checks that come first (no
    # logins during maintenance, root only on secure terminals), which a
    # face must not skip either.
    awk -v line="auth       sufficient   pam_howdy.so $MARK" '
        { lines[NR] = $0 }
        /^[[:space:]]*-?auth[[:space:]]/ {
            if (!first) first = NR
            if (!at && ($0 ~ /[[:space:]](include|substack)[[:space:]]/ || $0 ~ /pam_unix/)) at = NR
        }
        END {
            if (!at) at = first
            for (i = 1; i <= NR; i++) { if (i == at) print line; print lines[i] }
            if (!at) print line
        }' "$GREETD" > "$GREETD.new"
    chmod --reference="$GREETD" "$GREETD.new"
    mv -f "$GREETD.new" "$GREETD"
    say "login screen: your face first, then the password ($GREETD; the old file is greetd.before-hyprshell-face)"
fi

if command -v howdy >/dev/null 2>&1 && [ -n "${SUDO_USER:-}" ]; then
    n=$(howdy -U "$SUDO_USER" list 2>/dev/null | tail -n +2 | wc -l || echo 0)
    [ "$n" -gt 0 ] || say "no face enrolled for $SUDO_USER yet: sudo howdy add"
fi
say "Lock the screen (Super+L) to try it. Logging in with your face can't unlock the keyring;"
say "the first thing that needs it after a face login asks for your password once."
