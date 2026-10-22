#!/bin/bash
# Hyprshell's face unlock service: the IR camera, two small face models,
# kept loaded (see README.md). Howdy stays as its fallback.
#
#   sudo ./install.sh              build, install, start, and put it in
#                                  front of Howdy at the lock and login screens
#   sudo ./install.sh --uninstall  take it out again (Howdy alone, as before)
#   ./install.sh --status          what's installed and running
#
# It's built as you (your Rust toolchain), installed as root:
#
#   /usr/local/libexec/hyprshell-faced     the service
#   /usr/local/bin/hyprshell-face          its command line
#   /usr/lib/security/pam_hyprshell_face.so
#   /usr/local/share/hyprshell-face/       the models (downloaded, checked)
#   /etc/hyprshell-face.conf               its settings (Settings → Login screen)
#   /etc/systemd/system/hyprshell-faced.service
#   /var/lib/hyprshell-face/               your faces, root only
#
# Then add your face again in Settings → Login screen: this service keeps
# its own (Howdy's stay, for the fallback).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SETUP="$HERE/../quickshell/scripts/howdy-setup.sh"
SHARE=/usr/local/share/hyprshell-face
PAMDIR=/usr/lib/security
UNIT=/etc/systemd/system/hyprshell-faced.service
CONF=/etc/hyprshell-face.conf

# The models, from OpenCV's model zoo, checked against these.
YUNET_URL=https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx
YUNET_SHA=8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4
SFACE_URL=https://media.githubusercontent.com/media/opencv/opencv_zoo/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
SFACE_SHA=0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79

say() { printf '  %s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = --status ]; then
    for f in /usr/local/libexec/hyprshell-faced /usr/local/bin/hyprshell-face "$PAMDIR/pam_hyprshell_face.so" "$SHARE/yunet.onnx" "$SHARE/sface.onnx" "$CONF" "$UNIT"; do
        say "$([ -e "$f" ] && echo "✓" || echo "✗") $f"
    done
    say "service: $(systemctl is-active hyprshell-faced.service 2>/dev/null || true)"
    command -v hyprshell-face >/dev/null && say "$(hyprshell-face status 2>&1)"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "run it with sudo: sudo $0 $*"
PERSON=${SUDO_USER:-}

if [ "${1:-}" = --uninstall ]; then
    systemctl disable --now hyprshell-faced.service 2>/dev/null || true
    rm -f "$UNIT" /usr/local/libexec/hyprshell-faced /usr/local/bin/hyprshell-face "$PAMDIR/pam_hyprshell_face.so"
    rm -f "$SHARE/yunet.onnx" "$SHARE/sface.onnx" "$SHARE/README.md"
    rmdir "$SHARE" 2>/dev/null || true
    systemctl daemon-reload
    # The lock and login screens back to Howdy alone (or the password).
    if [ -f "$SETUP" ] && command -v howdy >/dev/null 2>&1; then bash "$SETUP" >/dev/null || true
    elif [ -f "$SETUP" ]; then bash "$SETUP" --remove >/dev/null || true; fi
    say "Removed. Your faces stay in /var/lib/hyprshell-face until you delete it (sudo rm -r /var/lib/hyprshell-face)."
    exit 0
fi

[ -n "$PERSON" ] && [ "$PERSON" != root ] || die "run it as yourself with sudo (it builds with your Rust toolchain)"
as_person() { sudo -u "$PERSON" -H "$@"; }

# ── build, as you ───────────────────────────────────────────────────────
as_person bash -lc 'command -v cargo >/dev/null && cargo --version >/dev/null && rustc --version >/dev/null' \
    || die "Rust isn't ready: sudo pacman -S rustup && rustup default stable"
cache=$(as_person bash -c 'echo "${XDG_CACHE_HOME:-$HOME/.cache}/hyprshell/face"')
as_person mkdir -p "$cache"
say "building (the first time takes a few minutes)…"
as_person bash -lc "cd '$HERE' && CARGO_TARGET_DIR='$cache/target' cargo build --release --locked 2>'$cache/build.log' \
    || CARGO_TARGET_DIR='$cache/target' cargo build --release 2>>'$cache/build.log'" \
    || die "the build failed: $cache/build.log"
out="$cache/target/release"

# ── the models, checked ─────────────────────────────────────────────────
fetch() {
    local url=$1 sha=$2 file="$cache/$3"
    if ! printf '%s  %s\n' "$sha" "$file" | sha256sum -c --quiet 2>/dev/null; then
        say "downloading $3…"
        as_person curl -fsSL --retry 3 -o "$file.part" "$url" || die "couldn't download $url"
        printf '%s  %s\n' "$sha" "$file.part" | sha256sum -c --quiet || die "$3 isn't the file it should be (checksum)"
        as_person mv -f "$file.part" "$file"
    fi
}
fetch "$YUNET_URL" "$YUNET_SHA" yunet.onnx
fetch "$SFACE_URL" "$SFACE_SHA" sface.onnx

# ── install, as root ────────────────────────────────────────────────────
install -D -m 755 -o root -g root "$out/hyprshell-faced" /usr/local/libexec/hyprshell-faced
install -D -m 755 -o root -g root "$out/hyprshell-face" /usr/local/bin/hyprshell-face
install -D -m 644 -o root -g root "$out/libpam_hyprshell_face.so" "$PAMDIR/pam_hyprshell_face.so"
install -D -m 644 -o root -g root "$cache/yunet.onnx" "$SHARE/yunet.onnx"
install -D -m 644 -o root -g root "$cache/sface.onnx" "$SHARE/sface.onnx"
install -D -m 644 -o root -g root "$HERE/README.md" "$SHARE/README.md"
install -D -m 644 -o root -g root "$HERE/hyprshell-faced.service" "$UNIT"

# Settings, the first time: the cameras Howdy uses, if it's set up.
if [ ! -f "$CONF" ]; then
    ir=$(sed -n -E 's/^[[:space:]]*device_path[[:space:]]*=[[:space:]]*(\/dev\/video[0-9]+).*$/\1/p' /etc/howdy/config.ini 2>/dev/null | head -n1 || true)
    web=$(sed -n -E 's/^.*hyprshell_webcam.*device=(\/dev\/video[0-9]+).*$/\1/p' /etc/howdy/config.ini 2>/dev/null | head -n1 || true)
    {
        echo "# Hyprshell's face unlock service (shell/face). Settings → Login screen"
        echo "# changes these; they're read at each unlock."
        echo "ir_device = ${ir}"
        echo "webcam_device = ${web}"
        echo "webcam_check = $([ -n "$web" ] && grep -q '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true' <(sed -n '/^\[rubberstamps\]/,/^\[/p' /etc/howdy/config.ini 2>/dev/null) && echo true || echo false)"
        echo "threshold = 0.45"
        echo "webcam_threshold = 0.40"
        echo "timeout = 4"
    } > "$CONF"
    chmod 644 "$CONF"
    [ -n "$ir" ] || say "no IR camera set yet: pick it in Settings → Login screen → Camera"
fi

systemctl daemon-reload
systemctl enable --now hyprshell-faced.service
systemctl restart hyprshell-faced.service
for _ in 1 2 3 4 5 6 7 8 9 10; do
    /usr/local/bin/hyprshell-face status >/dev/null 2>&1 && break
    sleep 0.5
done
/usr/local/bin/hyprshell-face status >/dev/null 2>&1 || die "the service didn't start: journalctl -u hyprshell-faced"

# The lock and login screens: this first, Howdy after it.
if [ -f "$SETUP" ]; then
    PKEXEC_UID=$(id -u "$PERSON") bash "$SETUP" | sed 's/^/  /'
fi

say "Installed. Add your face again in Settings → Login screen: this service keeps its own."
say "Then lock the screen (Super+L) or press Try it; journalctl -u hyprshell-faced says how long it took."
