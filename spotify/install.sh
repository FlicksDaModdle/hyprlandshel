#!/bin/sh
# Spotify, in the shell's theme.
#
#   ./install.sh            install Spotify and Spicetify, and dress Spotify
#                           in the shell's theme
#   ./install.sh --remove   give Spotify its own look back (Spotify stays)
#
# Spotify comes from spotify-launcher (Arch's extra repository — Spotify's
# own client, installed into your home folder by the launcher and kept up
# to date by it). Being in your home folder matters: Spicetify works by
# changing Spotify's files, and these are yours to change, where a system
# copy (/opt/spotify, a Flatpak) would have to be made writable for
# everyone first. Spicetify comes from the repositories, the AUR, or its
# own GitHub releases, in that order.
#
# The theme itself is written by the shell (services/Spicetify.qml) from
# whatever theme it is wearing, and again whenever that changes; Settings →
# App theming → Spotify theme turns that off. Run as yourself, not root:
# sudo is asked for only to install packages.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
BIN="$HOME/.local/bin"
SP="$DATA/spotify-launcher/install/usr/share/spotify"
PREFS="$CONFIG/spotify/prefs"
THEME="$CONFIG/spicetify/Themes/Hyprshell"

if [ -t 1 ]; then
    GRN=$(printf '\033[32m'); YEL=$(printf '\033[33m'); RED=$(printf '\033[31m'); RST=$(printf '\033[0m')
else
    GRN= YEL= RED= RST=
fi
did()  { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
note() { printf '    %s·%s %s\n' "$YEL" "$RST" "$1"; }
die()  { printf '    %s✗%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run this as yourself, not with sudo — it asks for sudo when it needs it"

spicetify_bin() {
    for s in spicetify "$HOME/.spicetify/spicetify" "$BIN/spicetify"; do
        command -v "$s" >/dev/null 2>&1 && { command -v "$s"; return 0; }
    done
    return 1
}

# ── putting Spotify's own look back ───────────────────────────────────────
if [ "${1:-}" = "--remove" ]; then
    if S=$(spicetify_bin); then
        "$S" -n restore </dev/null >/dev/null 2>&1 && did "Spotify's own files put back (spicetify restore)" \
            || note "spicetify restore didn't run cleanly — try it yourself: spicetify restore"
    fi
    rm -f "$DATA/applications/spotify-launcher.desktop" "$BIN/hyprshell-spotify"
    rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/hyprshell-spotify.stamp"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA/applications" 2>/dev/null || true
    did "Spotify's menu entry is its own again"
    note "Spotify and Spicetify are still installed; the theme's files stay in ${THEME#$HOME/}"
    exit 0
fi

command -v pacman >/dev/null 2>&1 || die "this is for Arch and its kin (CachyOS…): no pacman here"

# ── Spotify ───────────────────────────────────────────────────────────────
if command -v spotify-launcher >/dev/null 2>&1; then
    did "spotify-launcher is installed"
else
    [ -d /opt/spotify ] && note "a system Spotify (/opt/spotify) is installed; this sets up spotify-launcher beside it, which Spicetify can theme without making /opt/spotify writable"
    command -v flatpak >/dev/null 2>&1 && flatpak info com.spotify.Client >/dev/null 2>&1 \
        && note "the Spotify Flatpak is installed; Spicetify can't reach it, so spotify-launcher goes beside it"
    printf '    installing spotify-launcher (sudo pacman)…\n'
    sudo pacman -S --needed spotify-launcher || die "couldn't install spotify-launcher"
    did "spotify-launcher installed"
fi

# Spotify installs itself the first time the launcher runs, and writes its
# prefs once it has been opened.
if [ ! -f "$SP/spotify" ] || [ ! -f "$PREFS" ]; then
    note "open Spotify once (it downloads itself the first time), sign in if you like, close it,"
    note "then run this again: $0"
    exit 0
fi
did "Spotify is in ${SP#$HOME/}"

# ── Spicetify ─────────────────────────────────────────────────────────────
if S=$(spicetify_bin); then
    did "Spicetify is installed ($S)"
else
    if pacman -Si spicetify-cli >/dev/null 2>&1; then
        printf '    installing spicetify-cli (sudo pacman)…\n'
        sudo pacman -S --needed spicetify-cli || die "couldn't install spicetify-cli"
    elif command -v paru >/dev/null 2>&1 || command -v yay >/dev/null 2>&1; then
        h=$(command -v paru || command -v yay)
        printf '    installing spicetify-cli from the AUR (%s) — it shows the PKGBUILD first…\n' "$(basename "$h")"
        "$h" -S --needed spicetify-cli || die "couldn't install spicetify-cli"
    else
        # Its own release, as its own installer does it, without running a
        # script from the internet: the tarball for this machine, unpacked
        # into ~/.spicetify, linked from ~/.local/bin.
        command -v curl >/dev/null 2>&1 || die "no paru or yay, and no curl to fetch Spicetify with"
        case "$(uname -m)" in
            x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "no Spicetify release for $(uname -m)" ;;
        esac
        tag=$(curl -fsSL https://api.github.com/repos/spicetify/cli/releases/latest \
              | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1)
        [ -n "$tag" ] || die "couldn't find Spicetify's latest release"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        curl -fsSL -o "$tmp/spicetify.tar.gz" \
            "https://github.com/spicetify/cli/releases/download/v$tag/spicetify-$tag-linux-$arch.tar.gz" \
            || die "couldn't download Spicetify $tag"
        mkdir -p "$HOME/.spicetify" "$BIN"
        tar -xzf "$tmp/spicetify.tar.gz" -C "$HOME/.spicetify" || die "couldn't unpack Spicetify"
        chmod +x "$HOME/.spicetify/spicetify"
        ln -sf "$HOME/.spicetify/spicetify" "$BIN/spicetify"
        did "Spicetify $tag in ~/.spicetify"
    fi
    S=$(spicetify_bin) || die "Spicetify was installed but can't be found — is ~/.local/bin on your PATH?"
fi

# ── the theme ─────────────────────────────────────────────────────────────
# The shell writes it from the theme it's wearing; asked here so it's there
# now. Without the shell running, a start from its default dark theme,
# which it replaces when it next runs.
"$S" config </dev/null >/dev/null 2>&1 || true      # makes Spicetify's config the first time
ctl=$(command -v hyprshellctl 2>/dev/null || true)
[ -z "$ctl" ] && [ -x "$BIN/hyprshellctl" ] && ctl="$BIN/hyprshellctl"
if [ -n "$ctl" ]; then
    "$ctl" syncTheming >/dev/null 2>&1 || true
    sleep 1.5
fi
if [ ! -f "$THEME/color.ini" ] || [ ! -f "$THEME/user.css" ]; then
    mkdir -p "$THEME"
    {
        printf ':root {\n    --hs-r: 14px;\n    --hs-rsm: 9px;\n    --hs-font: "Inter";\n    --hs-on-accent: #ffffff;\n}\n\n'
        cat "$REPO/shell/quickshell/assets/spicetify/user.css"
    } > "$THEME/user.css"
    cat > "$THEME/color.ini" <<'INI'
; Hyprshell's default dark theme; the shell replaces this with the theme it
; is wearing when it next runs.
[shell]
text = f8f4f4
subtext = bab6b6
main = 201e1d
main-elevated = 2d2b2b
sidebar = 262423
player = 262423
card = 2d2b2b
highlight = 393736
highlight-elevated = 42403f
shadow = 000000
selected-row = f8f4f4
button = ff563c
button-active = ff6e58
button-disabled = 8a8686
tab-active = 403e3d
notification = 2d2b2b
notification-error = ff5a52
misc = 8a8686
INI
    did "theme written (the shell's default; it follows your theme once the shell is running)"
else
    did "theme written by the shell, from the theme it's wearing"
fi

"$S" config spotify_path "$SP" prefs_path "$PREFS" \
    current_theme Hyprshell color_scheme shell \
    inject_css 1 replace_colors 1 overwrite_assets 0 inject_theme_js 0 >/dev/null \
    || die "couldn't configure Spicetify"
did "Spicetify set to the Hyprshell theme"

# Into Spotify: backup first time (Spicetify keeps Spotify's own files to
# put back), apply after. Not restarted: it shows next time it starts.
if "$S" -n backup apply </dev/null >/dev/null 2>&1 || "$S" -n apply </dev/null >/dev/null 2>&1; then
    stat -c %Y "$SP/spotify" > "${XDG_CACHE_HOME:-$HOME/.cache}/hyprshell-spotify.stamp" 2>/dev/null || true
    did "theme put into Spotify"
else
    die "spicetify apply failed — run it yourself to see why: $S backup apply"
fi

# ── keeping it through Spotify's updates ──────────────────────────────────
mkdir -p "$BIN" "$DATA/applications"
install -m 755 "$HERE/hyprshell-spotify" "$BIN/hyprshell-spotify"
src=""
for d in /usr/share/applications /usr/local/share/applications; do
    [ -f "$d/spotify-launcher.desktop" ] && { src="$d/spotify-launcher.desktop"; break; }
done
if [ -n "$src" ]; then
    sed -e "s|^Exec=spotify-launcher|Exec=$BIN/hyprshell-spotify|" \
        -e '/^TryExec=/d' "$src" > "$DATA/applications/spotify-launcher.desktop"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$DATA/applications" 2>/dev/null || true
    did "Spotify's menu entry puts the theme back after Spotify updates itself"
else
    note "no spotify-launcher.desktop found to point at hyprshell-spotify; start Spotify with: hyprshell-spotify"
fi

note "close and reopen Spotify to see it"
