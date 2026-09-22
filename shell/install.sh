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
#   ./install.sh --debug        trace every command (for reporting a bug here)
#
# Deliberately NOT `set -e`. Most of this script probes for things that are
# expected to be missing, and under `set -e` a probe that comes back negative
# can take the whole script down mid-report with no output — which is exactly
# what an earlier version of this file did. Failures that actually matter (the
# copies and backups at the end) are checked explicitly instead.

set -u

usage() {
    cat <<'EOF'
Hyprshell installer.

  ./install.sh --check        report only, change nothing
  ./install.sh                install (prompts before touching anything)
  ./install.sh --shell-only   install only the Quickshell tree, and print
                              the lines to add to an existing Hyprland config
  ./install.sh --force        don't prompt
  ./install.sh --debug        trace every command
EOF
}

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
HYPR_DIR="$CONFIG_HOME/hypr"
QS_DIR="$CONFIG_HOME/quickshell/hyprshell"
KITTY_DIR="$CONFIG_HOME/kitty"
STAMP="$(date +%Y%m%d-%H%M%S)"

MODE=install
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --check)      MODE=check ;;
        --shell-only) MODE=shell-only ;;
        --force)      FORCE=1 ;;
        --debug)      set -x ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

die() { printf '\n%serror:%s %s\n' "${RED-}" "${RST-}" "$1" >&2; exit 1; }

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
MISSING_PKGS=""

add_pkg() {
    [ -n "${1:-}" ] || return 0
    case " $MISSING_PKGS " in
        *" $1 "*) ;;
        *) MISSING_PKGS="$MISSING_PKGS $1" ;;
    esac
    return 0
}

# ── distro package names ─────────────────────────────────────────────────────
distro_id() {
    if [ -r /etc/os-release ]; then
        # Read it in a subshell so its variables don't leak into ours.
        ( . /etc/os-release 2>/dev/null
          case "${ID:-}${ID_LIKE:-}" in
              *arch*)            echo arch ;;
              *debian*|*ubuntu*) echo debian ;;
              *fedora*|*rhel*)   echo fedora ;;
              *suse*)            echo suse ;;
              *)                 echo unknown ;;
          esac )
    else
        echo unknown
    fi
}
DISTRO="$(distro_id)"
[ -n "$DISTRO" ] || DISTRO=unknown

# pkg <arch> <debian> <fedora> <suse>
pkg() {
    case "$DISTRO" in
        arch)   printf '%s' "$1" ;;
        debian) printf '%s' "$2" ;;
        fedora) printf '%s' "$3" ;;
        suse)   printf '%s' "$4" ;;
        *)      printf '%s' "$1" ;;
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

# need <command> <required|optional> <purpose> <arch> <deb> <fedora> <suse>
need() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1" "$3"
        return 0
    fi
    if [ "$2" = required ]; then
        fail "$1" "$3"
        MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    else
        warn "$1" "$3"
    fi
    add_pkg "$(pkg "${4-}" "${5-}" "${6-}" "${7-}")"
    return 0
}

# ── version helpers ──────────────────────────────────────────────────────────
# `hyprctl version` has had two shapes over the years:
#     Hyprland 0.51.1 built from branch ...
#     Hyprland, built from branch main at commit ...      <- version is in Tag:
#     Tag: v0.41.2, commits: 5821
# so both are tried. Every pipeline here uses `sed -n 1p` rather than `head`,
# because `head` closes the pipe early and the writer upstream dies on SIGPIPE.
hypr_version() {
    local raw tag
    raw="$(hyprctl version 2>/dev/null)"
    [ -n "$raw" ] || raw="$(Hyprland --version 2>/dev/null)"
    [ -n "$raw" ] || raw="$(hyprland --version 2>/dev/null)"
    [ -n "$raw" ] || return 0

    tag="$(printf '%s\n' "$raw" | sed -n 's/^Hyprland v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | sed -n 1p)"
    [ -n "$tag" ] || tag="$(printf '%s\n' "$raw" | sed -n 's/^Tag: v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | sed -n 1p)"
    printf '%s' "$tag"
}

# ver_lt <have> <want> -> 0 when have < want. An unparseable version returns
# 1 (not less than), so a version we can't read never blocks the install.
ver_lt() {
    local h="${1:-}" w="${2:-}" h1 h2 w1 w2 rest
    [ -n "$h" ] || return 1
    h1="${h%%.*}"; rest="${h#*.}"; [ "$rest" = "$h" ] && rest=0; h2="${rest%%.*}"
    w1="${w%%.*}"; rest="${w#*.}"; [ "$rest" = "$w" ] && rest=0; w2="${rest%%.*}"
    case "${h1}${h2}${w1}${w2}" in ''|*[!0-9]*) return 1 ;; esac
    [ "$h1" -lt "$w1" ] && return 0
    [ "$h1" -gt "$w1" ] && return 1
    [ "$h2" -lt "$w2" ]
}

# ── checks ───────────────────────────────────────────────────────────────────
head1 "Required"

if command -v hyprctl >/dev/null 2>&1 || command -v Hyprland >/dev/null 2>&1 \
   || command -v hyprland >/dev/null 2>&1; then
    HVER="$(hypr_version)"
    if [ -z "$HVER" ]; then
        # Installed, but the version could not be read — commonly because
        # hyprctl needs a running session. Not a reason to refuse.
        warn "Hyprland" "installed; version unreadable (needs 0.55+ for the Lua config)"
    elif ver_lt "$HVER" 0.55; then
        fail "Hyprland" "found $HVER — the Lua config needs 0.55 or newer"
        MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    else
        ok "Hyprland" "$HVER"
    fi
else
    fail "Hyprland" "not installed"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
    add_pkg "$(pkg hyprland hyprland hyprland hyprland)"
fi

if command -v qs >/dev/null 2>&1; then
    QSVER="$(qs --version 2>/dev/null | sed -n 1p)"
    ok "quickshell (qs)" "${QSVER:-installed}"
else
    fail "quickshell (qs)" "not installed — see https://quickshell.org/docs/guide/install"
    MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
fi

if command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -qi inter; then
    ok "Inter font" "text renders as designed"
else
    warn "Inter font" "the shell falls back to the system sans"
    add_pkg "$(pkg inter-font fonts-inter rsms-inter-fonts inter-fonts)"
fi

# Not conditional on kitty: this is Appearance.monoFamily too, so the shell's
# own monospaced text wants it whether or not the terminal is installed.
if command -v fc-list >/dev/null 2>&1 && fc-list 2>/dev/null | grep -qi 'jetbrains mono'; then
    ok "JetBrains Mono" "monospaced text in the shell and the terminal"
else
    warn "JetBrains Mono" "falls back to the system monospace"
    add_pkg "$(pkg ttf-jetbrains-mono fonts-jetbrains-mono jetbrains-mono-fonts jetbrains-mono-fonts)"
fi

head1 "Optional — each one only affects the feature named"
need nmcli         optional "Wi-Fi tile, Network pane"   networkmanager network-manager NetworkManager NetworkManager
need bluetoothctl  optional "Bluetooth tile and pane"    bluez-utils bluez bluez bluez
need brightnessctl optional "brightness slider and keys" brightnessctl brightnessctl brightnessctl brightnessctl
need grim          optional "screenshots"                grim grim grim grim
need slurp         optional "screenshot region picker"   slurp slurp slurp slurp
need wl-copy       optional "screenshot to clipboard"    wl-clipboard wl-clipboard wl-clipboard wl-clipboard
need notify-send   optional "screenshot confirmations"   libnotify libnotify-bin libnotify libnotify-tools
need playerctl     optional "media transport keys"       playerctl playerctl playerctl playerctl
need kitty         optional "the themed terminal"        kitty kitty kitty kitty
need hypridle      optional "idle timeout to lock"       hypridle "" "" ""
need loginctl      optional "suspend, reboot, power off" systemd systemd systemd systemd

if command -v hyprsunset >/dev/null 2>&1 || command -v wlsunset >/dev/null 2>&1; then
    ok "hyprsunset/wlsunset" "Night light"
else
    warn "hyprsunset/wlsunset" "Night light tile reports 'not installed'"
    add_pkg "$(pkg hyprsunset wlsunset wlsunset wlsunset)"
fi

if command -v powerprofilesctl >/dev/null 2>&1; then
    ok "power-profiles-daemon" "power profiles, Game mode"
else
    warn "power-profiles-daemon" "power profile row is inert"
    add_pkg power-profiles-daemon
fi

if command -v zenity >/dev/null 2>&1 || command -v kdialog >/dev/null 2>&1; then
    ok "zenity/kdialog" "wallpaper file picker"
else
    warn "zenity/kdialog" "set the wallpaper path in theme.json by hand instead"
    add_pkg "$(pkg zenity zenity zenity zenity)"
fi

head1 "Session — checked as this shell sees it, not as root"
# Both of these are invisible until the shell fails, and they fail loudly but
# unhelpfully: a shell on X11 loses every layer-shell surface it has, and one
# that can't reach Hyprland has no workspaces, no window list and no keybinds.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "${QT_QPA_PLATFORM:-}" in
        "")        ok   "QT_QPA_PLATFORM" "unset — Qt picks Wayland on its own" ;;
        *wayland*) ok   "QT_QPA_PLATFORM" "${QT_QPA_PLATFORM}" ;;
        *)         warn "QT_QPA_PLATFORM" "is '${QT_QPA_PLATFORM}' — no layer shell, so no bar/dock/wallpaper"
                   printf '      the installed hyprland.lua launches the shell with\n'
                   printf '      QT_QPA_PLATFORM=wayland regardless, so this only bites a shell\n'
                   printf '      you start by hand. Use run.sh, which sets it for you:\n'
                   printf '          %s/run.sh\n' "$QS_DIR" 
                   printf '      To find what sets it: grep -rn QT_QPA_PLATFORM ~/.profile\n'
                   printf '          ~/.bashrc ~/.zshrc ~/.zshenv /etc/environment 2>/dev/null\n' ;;
    esac
else
    warn "WAYLAND_DISPLAY" "unset — this is not a Wayland session"
fi

if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    ok "HYPRLAND_INSTANCE_SIGNATURE" "set — the shell can reach Hyprland"
else
    warn "HYPRLAND_INSTANCE_SIGNATURE" "unset — no workspaces, window list or keybinds"
    if [ -d "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" ]; then
        printf '      Hyprland IS running:\n'
        for _i in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr"/*; do
            [ -d "$_i" ] && printf '          %s\n' "$(basename -- "$_i")"
        done
        printf '      so this terminal was started outside that session. run.sh\n'
        printf '      finds the live one and exports it for you:\n'
        printf '          %s/run.sh\n' "$QS_DIR"
    else
        printf '      and no Hyprland instance is running at all.\n'
    fi
fi

if [ -x "$QS_DIR/hyprshellctl" ]; then
    if command -v hyprshellctl >/dev/null 2>&1; then
        ok "hyprshellctl" "on PATH — run 'hyprshellctl doctor'"
    else
        ok "hyprshellctl" "installed (not on PATH; run $QS_DIR/hyprshellctl)"
    fi
else
    warn "hyprshellctl" "missing from $QS_DIR — shortcuts still work; this is"
    printf '      the diagnostic (hyprshellctl doctor)\n'
fi

head1 "Lock screen"
if [ -r /etc/pam.d/login ]; then
    ok "/etc/pam.d/login" "PAM stack the lock authenticates against"
else
    fail "/etc/pam.d/login" "missing — the lock screen cannot authenticate"
fi

# ── suggested install line ───────────────────────────────────────────────────
if [ -n "${MISSING_PKGS# }" ]; then
    head1 "To install what's missing"
    # shellcheck disable=SC2086
    printf '  %s %s\n' "$(install_hint)" "$(printf '%s\n' $MISSING_PKGS | sort -u | tr '\n' ' ')"
    [ "$DISTRO" = unknown ] && \
        printf '  %s(package names are Arch'\''s — adjust for your distro)%s\n' "$DIM" "$RST"
fi

# ── existing config ──────────────────────────────────────────────────────────
head1 "Current config"
if [ -e "$HYPR_DIR/hyprland.lua" ]; then warn "hyprland.lua" "exists — would be backed up"
                                    else ok   "hyprland.lua" "not present"; fi
if [ -e "$HYPR_DIR/hyprland.conf" ]; then warn "hyprland.conf" "exists — see the note below"
                                     else ok   "hyprland.conf" "not present"; fi
if [ -e "$QS_DIR" ]; then warn "quickshell/hyprshell" "exists — would be backed up"
                     else ok   "quickshell/hyprshell" "not present"; fi
if command -v kitty >/dev/null 2>&1; then
    if [ -e "$KITTY_DIR/kitty.conf" ]; then warn "kitty.conf" "exists — would be backed up"
                                       else ok   "kitty.conf" "not present"; fi
fi

if [ "$MODE" = check ]; then
    head1 "Check only — nothing was changed."
    [ "$MISSING_REQUIRED" -gt 0 ] && exit 1
    exit 0
fi

if [ "$MISSING_REQUIRED" -gt 0 ]; then
    printf '\n%s%d required item(s) missing.%s Install them, then re-run.\n' \
        "$RED" "$MISSING_REQUIRED" "$RST"
    exit 1
fi

# ── confirm ──────────────────────────────────────────────────────────────────
head1 "About to install"
printf '  %s  <- the Quickshell tree\n' "$QS_DIR"
if command -v kitty >/dev/null 2>&1; then
    printf '  %s  <- kitty.conf and the two palettes\n' "$KITTY_DIR"
fi
if [ "$MODE" = shell-only ]; then
    printf '  %s(your Hyprland config is left alone)%s\n' "$DIM" "$RST"
else
    printf '  %s/hyprland.lua  <- the compositor config\n' "$HYPR_DIR"
fi
printf '  %sAnything already there is moved to <name>.bak.%s, not deleted.%s\n' \
    "$DIM" "$STAMP" "$RST"

if [ "$FORCE" -ne 1 ]; then
    printf '\nProceed? [y/N] '
    if ! read -r reply; then reply=""; fi
    case "$reply" in [yY]*) ;; *) echo "Cancelled."; exit 0 ;; esac
fi

backup() {
    [ -e "$1" ] || return 0
    mv -- "$1" "$1.bak.$STAMP" || die "could not back up $1"
    printf '  backed up %s -> %s.bak.%s\n' "$1" "$1" "$STAMP"
}

head1 "Installing"

mkdir -p "$(dirname "$QS_DIR")" || die "could not create $(dirname "$QS_DIR")"
backup "$QS_DIR"
cp -r -- "$SRC/quickshell" "$QS_DIR" || die "could not copy the Quickshell tree to $QS_DIR"
printf '  installed %s\n' "$QS_DIR"

cp -- "$SRC/run.sh" "$QS_DIR/run.sh" 2>/dev/null && chmod +x "$QS_DIR/run.sh" \
    && printf '  installed %s/run.sh\n' "$QS_DIR"
cp -- "$SRC/hyprshellctl" "$QS_DIR/hyprshellctl" 2>/dev/null \
    && chmod +x "$QS_DIR/hyprshellctl" \
    && printf '  installed %s/hyprshellctl\n' "$QS_DIR"

# ...and onto PATH, because a diagnostic you have to type the full path to
# is a diagnostic nobody runs. ~/.local/bin is the XDG user location and is
# already on PATH on most distributions.
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
if mkdir -p "$BIN_DIR" 2>/dev/null; then
    ln -sf "$QS_DIR/hyprshellctl" "$BIN_DIR/hyprshellctl" 2>/dev/null \
        && printf '  linked    %s/hyprshellctl\n' "$BIN_DIR"
    case ":${PATH}:" in
        *":$BIN_DIR:"*) : ;;
        *) printf '  note      %s is not on your PATH; add it, or run the copy\n' "$BIN_DIR"
           printf '            at %s/hyprshellctl\n' "$QS_DIR" ;;
    esac
fi

# theme.json lives *inside* the tree that was just moved aside, so without
# this every preference you have set would be lost to a reinstall. It is your
# data, not ours — carry it across.
if [ -e "$QS_DIR.bak.$STAMP/theme.json" ]; then
    cp -- "$QS_DIR.bak.$STAMP/theme.json" "$QS_DIR/theme.json" \
        && printf '  kept your theme.json\n'
fi

if command -v kitty >/dev/null 2>&1; then
    mkdir -p "$KITTY_DIR" || die "could not create $KITTY_DIR"
    backup "$KITTY_DIR/kitty.conf"
    for f in kitty.conf colors-light.conf colors-dark.conf; do
        cp -- "$SRC/kitty/$f" "$KITTY_DIR/$f" || die "could not copy $f to $KITTY_DIR"
    done

    # hyprshell-colors.conf names the live palette. An existing one is the
    # running shell's own choice, so a reinstall leaves it alone.
    #
    # A new one must not be the file's shipped default. That default is light,
    # and installing it under a dark shell is how you end up with one blinding
    # white terminal on a dark desktop until something happens to resync. So
    # derive it from the theme you actually have.
    if [ ! -e "$KITTY_DIR/hyprshell-colors.conf" ]; then
        _theme=light
        _json="$QS_DIR/theme.json"
        if [ -r "$_json" ]; then
            _theme="$(sed -n 's/.*"theme"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$_json" \
                      | head -n1)"
            [ -n "$_theme" ] || _theme=light
        fi
        # "auto" is dark from 19:00 to 07:00 — the same rule Appearance.qml uses.
        if [ "$_theme" = auto ]; then
            _hour="$(date +%H)"
            _hour="${_hour#0}"
            if [ "${_hour:-0}" -ge 19 ] || [ "${_hour:-0}" -lt 7 ]
                then _theme=dark; else _theme=light; fi
        fi
        [ "$_theme" = dark ] || _theme=light
        sed "s/^include colors-.*/include colors-$_theme.conf/" \
            "$SRC/kitty/hyprshell-colors.conf" > "$KITTY_DIR/hyprshell-colors.conf" \
            || die "could not write $KITTY_DIR/hyprshell-colors.conf"
        printf '  kitty palette set to %s, from your theme.json\n' "$_theme"
    fi

    printf '  installed %s/kitty.conf and its palettes\n' "$KITTY_DIR"
    # Recolour any kitty already running, and tell a running shell to re-read
    # the file it now shares with us. Both are best-effort.
    pkill -USR1 -x kitty 2>/dev/null || true
    qs -c hyprshell ipc call shell syncTheming >/dev/null 2>&1 || true
fi

if [ "$MODE" != shell-only ]; then
    mkdir -p "$HYPR_DIR" || die "could not create $HYPR_DIR"
    backup "$HYPR_DIR/hyprland.lua"
    cp -- "$SRC/hypr/hyprland.lua" "$HYPR_DIR/hyprland.lua" \
        || die "could not copy hyprland.lua to $HYPR_DIR"
    printf '  installed %s/hyprland.lua\n' "$HYPR_DIR"

    if [ -e "$HYPR_DIR/hyprland.conf" ]; then
        printf '\n  %sNote:%s hyprland.conf is still there alongside hyprland.lua.\n' "$YEL" "$RST"
        printf '  Hyprland loads one config, and which one wins with both present is\n'
        printf '  not something to leave to chance. Move it aside when you are ready:\n'
        printf '      mv %s/hyprland.conf %s/hyprland.conf.bak.%s\n' \
            "$HYPR_DIR" "$HYPR_DIR" "$STAMP"
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

     Written the moment you change something in Settings (super + ,), and
     re-read if you edit it by hand.

  4. Edit the pinned apps to what you actually run:

         $QS_DIR/config/Apps.qml
EOF

if [ "$MODE" = shell-only ]; then
    cat <<EOF

  Your Hyprland config was left alone, so add these to it to reach the shell.
  The full set of bindings is in $SRC/hypr/hyprland.lua.

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
