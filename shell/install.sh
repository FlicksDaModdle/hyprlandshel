#!/usr/bin/env bash
#
# Hyprshell installer.
#
# Checks what's present, backs up anything it would overwrite, and copies the
# shell into place. It never deletes: existing configs are moved aside with a
# timestamped suffix so you can always put them back.
#
#   ./install.sh --check        report only, change nothing
#   ./install.sh                install (prompts before touching anything)
#   ./install.sh --shell-only   install only the Quickshell tree, and print
#                               the lines to add to an existing Hyprland config
#   ./install.sh --force        don't prompt
#
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
HYPR_DIR="$CONFIG_HOME/hypr"
QS_DIR="$CONFIG_HOME/quickshell/hyprshell"
STAMP="$(date +%Y%m%d-%H%M%S)"

MODE=install
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --check)      MODE=check ;;
        --shell-only) MODE=shell-only ;;
        --force)      FORCE=1 ;;
        -h|--help)    sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'; exit 0 ;;
        *)            echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

# ── output helpers ───────────────────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YEL=$'\033[33m'; RST=$'\033[0m'
else
    BOLD=; DIM=; RED=; GRN=; YEL=; RST=
fi

ok()    { printf '  %s✓%s %-22s %s%s%s\n' "$GRN" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
warn()  { printf '  %s•%s %-22s %s%s%s\n' "$YEL" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
fail()  { printf '  %s✗%s %-22s %s%s%s\n' "$RED" "$RST" "$1" "$DIM" "${2-}" "$RST"; }
head1() { printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }

MISSING_REQUIRED=0
declare -a MISSING_PKGS=()

# ── distro package names ─────────────────────────────────────────────────────
distro_id() {
    [ -r /etc/os-release ] || { echo unknown; return; }
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}${ID_LIKE:-}" in
        *arch*)             echo arch ;;
        *debian*|*ubuntu*)  echo debian ;;
        *fedora*|*rhel*)    echo fedora ;;
        *suse*)             echo suse ;;
        *)                  echo unknown ;;
    esac
}
DISTRO="$(distro_id)"

# pkg <arch> <debian> <fedora> <suse>
pkg() {
    case "$DISTRO" in
        arch)   echo "$1" ;;
        debian) echo "$2" ;;
        fedora) echo "$3" ;;
        suse)   echo "$4" ;;
        *)      echo "$1" ;;
    esac
}

install_hint() {
    case "$DISTRO" in
        arch)   echo "sudo pacman -S --needed" ;;
        debian) echo "sudo apt install" ;;
        fedora) echo "sudo dnf install" ;;
        suse)   echo "sudo zypper install" ;;
        *)      echo "install with your package manager:" ;;
    esac
}

# need <command> <required|optional> <what it's for> <arch> <deb> <fedora> <suse>
need() {
    local cmd="$1" level="$2" purpose="$3"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd" "$purpose"
        return
    fi
    local p; p="$(pkg "$4" "$5" "$6" "$7")"
    if [ "$level" = required ]; then
        fail "$cmd" "$purpose"
        MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    else
        warn "$cmd" "$purpose"
    fi
    # Not every tool is packaged on every distro, so an empty name here is
    # normal. It must not become this function's exit status, or `set -e`
    # takes the whole script down on the first such entry.
    if [ -n "$p" ]; then MISSING_PKGS+=("$p"); fi
    return 0
}

# ── checks ───────────────────────────────────────────────────────────────────
head1 "Required"

if command -v Hyprland >/dev/null 2>&1 || command -v hyprctl >/dev/null 2>&1; then
    HVER="$(hyprctl version 2>/dev/null | sed -n 's/^Hyprland \([^ ]*\).*/\1/p' | head -1)"
    [ -z "$HVER" ] && HVER="$(Hyprland --version 2>/dev/null | sed -n 's/^Hyprland \([^ ]*\).*/\1/p' | head -1)"
    HNUM="$(printf '%s' "${HVER:-0}" | sed 's/^v//' | cut -d- -f1)"
    HMAJ="${HNUM%%.*}"; HREST="${HNUM#*.}"; HMIN="${HREST%%.*}"
    if [ "${HMAJ:-0}" -eq 0 ] 2>/dev/null && [ "${HMIN:-0}" -lt 55 ] 2>/dev/null; then
        fail "Hyprland" "found ${HVER:-?} — the Lua config needs 0.55 or newer"
        MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    else
        ok "Hyprland" "${HVER:-version unknown}"
    fi
else
    fail "Hyprland" "not installed"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    MISSING_PKGS+=("$(pkg hyprland hyprland hyprland hyprland)")
fi

if command -v qs >/dev/null 2>&1; then
    ok "quickshell (qs)" "$(qs --version 2>/dev/null | head -1)"
else
    fail "quickshell (qs)" "not installed — see https://quickshell.org/docs/guide/install"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
fi

if fc-list 2>/dev/null | grep -qi 'inter'; then
    ok "Inter font" "text renders as designed"
else
    warn "Inter font" "the shell falls back to the system sans"
    MISSING_PKGS+=("$(pkg inter-font fonts-inter rsms-inter-fonts inter-fonts)")
fi

head1 "Optional — each one only affects the feature named"
need nmcli         optional "Wi-Fi tile, Network pane"  networkmanager network-manager NetworkManager NetworkManager
need bluetoothctl  optional "Bluetooth tile and pane"   bluez-utils bluez bluez bluez
need brightnessctl optional "brightness slider and keys" brightnessctl brightnessctl brightnessctl brightnessctl
need grim          optional "screenshots"               grim grim grim grim
need slurp         optional "screenshot region picker"  slurp slurp slurp slurp
need wl-copy       optional "screenshot to clipboard"   wl-clipboard wl-clipboard wl-clipboard wl-clipboard
need notify-send   optional "screenshot confirmations"  libnotify libnotify-bin libnotify libnotify-tools
need playerctl     optional "media transport keys"      playerctl playerctl playerctl playerctl
need hypridle      optional "idle timeout to lock"      hypridle "" "" ""
need loginctl      optional "suspend, reboot, power off" systemd systemd systemd systemd

if command -v hyprsunset >/dev/null 2>&1 || command -v wlsunset >/dev/null 2>&1; then
    ok "hyprsunset/wlsunset" "Night light"
else
    warn "hyprsunset/wlsunset" "Night light tile reports 'not installed'"
    MISSING_PKGS+=("$(pkg hyprsunset wlsunset wlsunset wlsunset)")
fi

if command -v powerprofilesctl >/dev/null 2>&1 || systemctl is-active --quiet power-profiles-daemon 2>/dev/null; then
    ok "power-profiles-daemon" "power profiles, Game mode"
else
    warn "power-profiles-daemon" "power profile row is inert"
    MISSING_PKGS+=("power-profiles-daemon")
fi

if command -v zenity >/dev/null 2>&1 || command -v kdialog >/dev/null 2>&1; then
    ok "zenity/kdialog" "wallpaper file picker"
else
    warn "zenity/kdialog" "set the wallpaper path in theme.json by hand instead"
    MISSING_PKGS+=("$(pkg zenity zenity zenity zenity)")
fi

head1 "Lock screen"
if [ -r /etc/pam.d/login ]; then
    ok "/etc/pam.d/login" "PAM stack the lock authenticates against"
else
    fail "/etc/pam.d/login" "missing — the lock screen will not be able to authenticate"
fi

# ── suggested install line ───────────────────────────────────────────────────
if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    mapfile -t UNIQ < <(printf '%s\n' "${MISSING_PKGS[@]}" | grep -v '^$' | sort -u)
    if [ ${#UNIQ[@]} -gt 0 ]; then
        head1 "To install what's missing"
        printf '  %s %s\n' "$(install_hint)" "${UNIQ[*]}"
        [ "$DISTRO" = unknown ] && printf '  %s(package names are Arch\x27s — adjust for your distro)%s\n' "$DIM" "$RST"
    fi
fi

# ── existing config ──────────────────────────────────────────────────────────
head1 "Current config"
[ -e "$HYPR_DIR/hyprland.lua" ]  && warn "hyprland.lua"  "exists — would be backed up" || ok "hyprland.lua" "not present"
[ -e "$HYPR_DIR/hyprland.conf" ] && warn "hyprland.conf" "exists — see the note below"  || ok "hyprland.conf" "not present"
[ -e "$QS_DIR" ]                 && warn "$QS_DIR" "exists — would be backed up"        || ok "quickshell/hyprshell" "not present"

if [ "$MODE" = check ]; then
    head1 "Check only — nothing was changed."
    [ "$MISSING_REQUIRED" -gt 0 ] && exit 1
    exit 0
fi

if [ "$MISSING_REQUIRED" -gt 0 ]; then
    printf '\n%s%d required item(s) missing.%s Install them first, then re-run.\n' \
        "$RED" "$MISSING_REQUIRED" "$RST"
    exit 1
fi

# ── confirm ──────────────────────────────────────────────────────────────────
head1 "About to install"
if [ "$MODE" = shell-only ]; then
    printf '  %s  <- the Quickshell tree\n' "$QS_DIR"
    printf '  %s(your Hyprland config is left alone)%s\n' "$DIM" "$RST"
else
    printf '  %s  <- the Quickshell tree\n' "$QS_DIR"
    printf '  %s/hyprland.lua  <- the compositor config\n' "$HYPR_DIR"
fi
printf '  %sAnything already there is moved to <name>.bak.%s, not deleted.%s\n' "$DIM" "$STAMP" "$RST"

if [ "$FORCE" -ne 1 ]; then
    printf '\nProceed? [y/N] '
    read -r reply
    case "$reply" in [yY]*) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

backup() {
    [ -e "$1" ] || return 0
    mv -- "$1" "$1.bak.$STAMP"
    printf '  backed up %s -> %s.bak.%s\n' "$1" "$1" "$STAMP"
}

head1 "Installing"

mkdir -p "$(dirname "$QS_DIR")"
backup "$QS_DIR"
cp -r -- "$SRC/quickshell" "$QS_DIR"
printf '  installed %s\n' "$QS_DIR"

if [ "$MODE" != shell-only ]; then
    mkdir -p "$HYPR_DIR"
    backup "$HYPR_DIR/hyprland.lua"
    cp -- "$SRC/hypr/hyprland.lua" "$HYPR_DIR/hyprland.lua"
    printf '  installed %s/hyprland.lua\n' "$HYPR_DIR"

    if [ -e "$HYPR_DIR/hyprland.conf" ]; then
        printf '\n  %sNote:%s hyprland.conf is still there alongside hyprland.lua.\n' "$YEL" "$RST"
        printf '  Hyprland loads one config, and which one wins with both present is\n'
        printf '  not something to leave to chance. Move it aside when you are ready:\n'
        printf '      mv %s/hyprland.conf %s/hyprland.conf.bak.%s\n' "$HYPR_DIR" "$HYPR_DIR" "$STAMP"
    fi
fi

# ── next steps ───────────────────────────────────────────────────────────────
head1 "Next"
cat <<EOF
  1. Start the shell by hand first, so you can read any errors:

         qs -c hyprshell

     Leave it running in a terminal. The bar, dock and wallpaper should
     appear. Ctrl-C to stop it.

  2. If that looks right, log out and back in — hyprland.lua autostarts it.

  3. Preferences live in:

         $QS_DIR/theme.json

     It is written the moment you change something in Settings (super + ,)
     and re-read if you edit it by hand.

  4. Edit the pinned apps to what you actually run:

         $QS_DIR/config/Apps.qml
EOF

if [ "$MODE" = shell-only ]; then
    cat <<EOF

  Since your Hyprland config was left alone, add these to it to reach the
  shell. The full set of bindings is in $SRC/hypr/hyprland.lua.

      exec-once = qs -c hyprshell

      bind = SUPER, Tab,    exec, qs -c hyprshell ipc call shell toggleOverview
      bind = SUPER, C,      exec, qs -c hyprshell ipc call shell toggleControlCenter
      bind = SUPER, N,      exec, qs -c hyprshell ipc call shell toggleNotifications
      bind = SUPER, L,      exec, qs -c hyprshell ipc call shell lock
      bind = SUPER, comma,  exec, qs -c hyprshell ipc call shell openSettings Appearance
      bindr = SUPER, SUPER_L, exec, qs -c hyprshell ipc call shell toggleLauncher

      # Media keys through the shell, so its OSD is what appears
      bindl = , XF86AudioRaiseVolume,  exec, qs -c hyprshell ipc call shell volumeUp
      bindl = , XF86AudioLowerVolume,  exec, qs -c hyprshell ipc call shell volumeDown
      bindl = , XF86AudioMute,         exec, qs -c hyprshell ipc call shell volumeMute
      bindl = , XF86MonBrightnessUp,   exec, qs -c hyprshell ipc call shell brightnessUp
      bindl = , XF86MonBrightnessDown, exec, qs -c hyprshell ipc call shell brightnessDown

      # Compositor blur behind the shell's surfaces
      layerrule = blur, ^(quickshell:bar)\$
      layerrule = blur, ^(quickshell:dock)\$
      layerrule = blur, ^(quickshell:panel)\$
      layerrule = blur, ^(quickshell:overview)\$
EOF
fi

cat <<EOF

  If the lock screen ever traps you: Ctrl+Alt+F2, log in, ${BOLD}pkill qs${RST}.
  Hyprland drops the lock when the client holding it exits.

  To undo all of this, move the .bak.$STAMP files back.
EOF
