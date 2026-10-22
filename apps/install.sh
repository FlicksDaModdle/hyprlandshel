#!/usr/bin/env bash
#
# Builds and installs Hyprshell's Rust apps: ROG Control Center, Notes,
# Snapshots, Disks, Passwords and Keys, Documents, Music, Videos, Sound
# Recorder, Chats and Weather — with their desktop entries, so the launcher and the
# dock find them. (Chats' WhatsApp side is in Go, chats/daemon, and needs
# Go to build.)
#
#   ./install.sh                    build and install all of them to ~/.local
#   ./install.sh --only music,video just those (names below)
#   ./install.sh --no-default       don't make Documents, Music and Videos
#                                   what opens their files
#   ./install.sh --check            report what's missing, build nothing
#   ./install.sh --prefix /usr/local
#   ./install.sh --remove           take them out again
#
# Names: rog notes snapshots disks keys docs music video recorder chats weather
#
# Not `set -e`: most of this probes for things that may be absent, and a
# probe saying "no" must not end the run.

set -u

PREFIX="${HOME}/.local"
MODE=install
DEFAULT=1
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --check)      MODE=check ;;
        --remove)     MODE=remove ;;
        --no-default) DEFAULT=0 ;;
        --only)       shift; ONLY="${1:-}" ;;
        --prefix)     shift; PREFIX="${1:-$PREFIX}" ;;
        -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YEL=$'\033[33m'; RST=$'\033[0m'
else
    BOLD=; DIM=; RED=; GRN=; YEL=; RST=
fi
ok()   { printf '  %s✓%s %-22s %s%s%s\n' "$GRN" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
warn() { printf '  %s•%s %-22s %s%s%s\n' "$YEL" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
bad()  { printf '  %s✗%s %-22s %s%s%s\n' "$RED" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
head1(){ printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS="$PREFIX/share/applications"
BIN="$PREFIX/bin"

# ── the apps ───────────────────────────────────────────────────────────────
# key | name | generic name | comment | icon | categories | Exec args | mime types | keywords
LIST=(
    "rog|ROG Control Center|System Settings|Performance, fans, keyboard lighting, battery and graphics|computer-laptop|Settings;HardwareSettings;||"
    "notes|Notes|Notes|Notes in Markdown, kept as files in ~/Notes|accessories-text-editor|Utility;TextEditor;||"
    "snapshots|Snapshots|System Snapshots|Go back to an earlier state of the system (snapper, btrfs)|document-revert|System;||"
    "disks|Disks|Disk Utility|Drives and volumes: mount, unlock, format, check health and speed|drive-harddisk|System;||"
    "keys|Passwords and Keys|Password Manager|Saved passwords, SSH keys and GPG keys|dialog-password|System;Security;||"
    "docs|Documents|Document Viewer|PDFs, comic books and e-books|x-office-document|Office;Viewer;|%f|application/pdf;application/x-pdf;application/epub+zip;application/vnd.comicbook+zip;application/x-cbz;"
    "music|Music|Music Player|Your music library, by album, artist and song|audio-x-generic|AudioVideo;Audio;Player;|%U|audio/mpeg;audio/mp3;audio/flac;audio/x-flac;audio/ogg;audio/x-vorbis+ogg;audio/vorbis;audio/wav;audio/x-wav;audio/mp4;audio/aac;audio/x-m4a;"
    "video|Videos|Video Player|Films and clips, picked up where you stopped|video-x-generic|AudioVideo;Video;Player;|%U|video/mp4;video/x-matroska;video/webm;video/quicktime;video/x-msvideo;video/mpeg;video/ogg;video/x-flv;video/3gpp;video/mp2t;video/x-ms-wmv;video/x-m4v;"
    "recorder|Sound Recorder|Audio Recorder|Voice memos, and what the computer is playing|audio-input-microphone|AudioVideo;Audio;Recorder;||"
    "chats|Chats|Messaging|WhatsApp on this computer, as a linked device|internet-chat|Network;InstantMessaging;Chat;|||WhatsApp;Messages;"
    "weather|Weather|Weather Forecast|The weather now, by the hour and ten days ahead, for the places you keep|weather-few-clouds|Utility;|||Forecast;Temperature;Rain;"
)
field() { local n=$2 IFS='|'; local f=($1); printf '%s' "${f[$((n - 1))]:-}"; }
SKIP=""
wanted() {
    case ",$SKIP," in *",$1,"*) return 1 ;; esac
    [ -z "$ONLY" ] && return 0
    case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

if [ -n "$ONLY" ]; then
    for k in ${ONLY//,/ }; do
        known=0
        for a in "${LIST[@]}"; do [ "$(field "$a" 1)" = "$k" ] && known=1; done
        [ "$known" = 1 ] || { echo "no app called '$k' (rog notes snapshots disks keys docs music video recorder chats weather)" >&2; exit 2; }
    done
fi

# ── taking them out ────────────────────────────────────────────────────────
if [ "$MODE" = remove ]; then
    head1 "Removing"
    for a in "${LIST[@]}"; do
        k=$(field "$a" 1); wanted "$k" || continue
        rm -f "$BIN/hyprshell-$k" "$APPS/hyprshell-$k.desktop"
        if [ "$k" = chats ]; then
            if command -v systemctl >/dev/null 2>&1; then
                systemctl --user disable --now hyprshell-chatsd.service >/dev/null 2>&1
            fi
            rm -f "$BIN/hyprshell-chatsd" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/hyprshell-chatsd.service"
            ok "Chats" "removed; it's still a linked device until you unlink it on your phone, and its messages stay in ~/.local/share/hyprshell-chats"
            continue
        fi
        ok "$(field "$a" 2)" "removed (your notes, recordings and settings stay)"
    done
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null
    exit 0
fi

# ── what they need ─────────────────────────────────────────────────────────
MISSING=0
head1 "To build"
if command -v cargo >/dev/null 2>&1; then
    ok "Rust" "$(cargo --version 2>/dev/null | cut -d' ' -f2)"
else
    bad "Rust" "required — sudo pacman -S --needed rust"
    MISSING=$((MISSING + 1))
fi
if command -v cc >/dev/null 2>&1; then ok "C compiler" "for a few crates' build steps"
else bad "C compiler" "required — sudo pacman -S --needed base-devel"; MISSING=$((MISSING + 1)); fi
if wanted chats; then
    if command -v go >/dev/null 2>&1; then
        ok "Go" "$(go version 2>/dev/null | cut -d' ' -f3) — Chats' WhatsApp side"
    else
        warn "Go" "Chats needs it to build — sudo pacman -S --needed go (the other apps install without it)"
        SKIP="chats"
    fi
fi

head1 "To run — each only matters for the app named"
has_lib() { ldconfig -p 2>/dev/null | grep -q "$1" || ls /usr/lib/"$1"* >/dev/null 2>&1; }
if has_lib "libmpv.so"; then ok "mpv" "Videos plays through it"
else warn "mpv" "Videos needs it — sudo pacman -S --needed mpv"; fi
if [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native" ] || command -v pipewire-pulse >/dev/null 2>&1; then
    ok "sound server" "Music, Sound Recorder (PipeWire's pulse server)"
else
    warn "sound server" "Music and Sound Recorder need pipewire-pulse — sudo pacman -S --needed pipewire-pulse"
fi
if command -v udisksctl >/dev/null 2>&1 || [ -e /usr/lib/udisks2/udisksd ]; then ok "UDisks" "Disks"
else warn "UDisks" "Disks needs it — sudo pacman -S --needed udisks2"; fi
if command -v snapper >/dev/null 2>&1; then ok "snapper" "Snapshots"
else warn "snapper" "Snapshots needs it (and a btrfs root) — sudo pacman -S --needed snapper"; fi
if command -v gnome-keyring-daemon >/dev/null 2>&1 || command -v kwalletd6 >/dev/null 2>&1 || command -v keepassxc >/dev/null 2>&1; then
    ok "Secret Service" "Passwords and Keys"
else
    warn "Secret Service" "Passwords and Keys needs a keyring — sudo pacman -S --needed gnome-keyring"
fi
if has_lib "libopus.so"; then ok "Opus" "Chats' voice messages"
else warn "Opus" "Chats needs it for voice messages — sudo pacman -S --needed opus"; fi
if fc-list :charset=1f600 family 2>/dev/null | grep -qi "color emoji\|twemoji\|joypixels"; then ok "colour emoji" "Chats"
else warn "colour emoji" "Chats shows emoji in colour with one — sudo pacman -S --needed noto-fonts-emoji"; fi
if command -v curl >/dev/null 2>&1; then ok "curl" "Weather fetches forecasts with it"
else warn "curl" "Weather needs it — sudo pacman -S --needed curl"; fi
if command -v asusd >/dev/null 2>&1 || [ -e /usr/bin/asusd ]; then ok "asusd" "ROG Control Center"
else warn "asusd" "ROG Control Center needs asusctl (ASUS laptops; from the g14 repository or the AUR)"; fi

if [ "$MODE" = check ]; then
    [ "$MISSING" -gt 0 ] && exit 1
    exit 0
fi
if [ "$MISSING" -gt 0 ]; then
    printf '\n%s%d required item(s) missing.%s\n' "$RED" "$MISSING" "$RST"
    exit 1
fi

# ── building ───────────────────────────────────────────────────────────────
head1 "Building"
pkgs=()
for a in "${LIST[@]}"; do k=$(field "$a" 1); wanted "$k" && pkgs+=(-p "hyprshell-$k"); done
note_time="the first build takes a few minutes; later ones only redo what changed"
printf '  %s%s%s\n' "$DIM" "$note_time" "$RST"
locked=--locked
[ -f "$SRC/Cargo.lock" ] || locked=
(cd "$SRC" && cargo build --release $locked "${pkgs[@]}") || { bad "build" "cargo failed (see above)"; exit 1; }
if wanted chats; then
    # Go fetches a newer toolchain by itself if the module asks for one.
    (cd "$SRC/chats/daemon" && CGO_ENABLED=1 GOTOOLCHAIN=auto go build -trimpath -ldflags "-s -w" -o "$SRC/target/release/hyprshell-chatsd" .) \
        || { bad "build" "go build of Chats' service failed (see above)"; exit 1; }
fi
ok "built"

# ── installing ─────────────────────────────────────────────────────────────
head1 "Installing"
mkdir -p "$BIN" "$APPS" || exit 1
for a in "${LIST[@]}"; do
    k=$(field "$a" 1); wanted "$k" || continue
    name=$(field "$a" 2); generic=$(field "$a" 3); comment=$(field "$a" 4)
    icon=$(field "$a" 5); cats=$(field "$a" 6); args=$(field "$a" 7); mime=$(field "$a" 8); keys=$(field "$a" 9)
    exe="$BIN/hyprshell-$k"
    # Copied to a new file and moved over the old: a running copy keeps
    # its own, and is never half-written under it.
    if ! install -m 755 "$SRC/target/release/hyprshell-$k" "$exe.new" || ! mv -f "$exe.new" "$exe"; then
        bad "$name" "could not write $exe"; continue
    fi
    {
        echo "[Desktop Entry]"
        echo "Type=Application"
        echo "Name=$name"
        echo "GenericName=$generic"
        echo "Comment=$comment"
        echo "Exec=$exe${args:+ $args}"
        echo "Icon=$icon"
        echo "Terminal=false"
        echo "Categories=$cats"
        [ -n "$mime" ] && echo "MimeType=$mime"
        [ -n "$keys" ] && echo "Keywords=$keys"
        echo "StartupWMClass=hyprshell-$k"
        echo "StartupNotify=true"
    } > "$APPS/hyprshell-$k.desktop"
    ok "$name" "$exe"
done
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS" 2>/dev/null

# Chats' WhatsApp side: its own program, and a systemd user unit so
# messages (and their notifications) arrive with the window closed.
if wanted chats && [ -x "$SRC/target/release/hyprshell-chatsd" ]; then
    d="$BIN/hyprshell-chatsd"
    if install -m 755 "$SRC/target/release/hyprshell-chatsd" "$d.new" && mv -f "$d.new" "$d"; then
        ok "Chats service" "$d"
        UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        mkdir -p "$UNIT_DIR"
        cat > "$UNIT_DIR/hyprshell-chatsd.service" <<UNIT
[Unit]
Description=Hyprshell Chats service (WhatsApp, as a linked device)
After=graphical-session.target

[Service]
ExecStart=$d
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
        if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null; then
            systemctl --user enable hyprshell-chatsd.service >/dev/null 2>&1
            if systemctl --user is-active --quiet hyprshell-chatsd.service; then
                systemctl --user restart hyprshell-chatsd.service && ok "Chats service" "restarted on the new build"
            else
                ok "Chats service" "starts with each session once you've linked Chats"
            fi
        else
            warn "Chats service" "no systemd user session — Chats starts it when it opens"
        fi
    else
        bad "Chats service" "could not write $d"
    fi
fi

# What opens documents, music and videos.
if [ "$DEFAULT" = 1 ]; then
    if command -v xdg-mime >/dev/null 2>&1; then
        for k in docs music video; do
            wanted "$k" || continue
            f="$APPS/hyprshell-$k.desktop"
            [ -f "$f" ] || continue
            types=$(sed -n 's/^MimeType=//p' "$f" | tr ';' ' ')
            # shellcheck disable=SC2086
            xdg-mime default "hyprshell-$k.desktop" $types && ok "default for" "$(sed -n 's/^Name=//p' "$f")'s files"
        done
    else
        warn "defaults" "xdg-mime is missing (xdg-utils); set them in your file manager"
    fi
fi

case ":${PATH}:" in
    *":$BIN:"*) ;;
    *) warn "PATH" "$BIN is not on your PATH; the launcher finds the apps anyway" ;;
esac
exit 0
