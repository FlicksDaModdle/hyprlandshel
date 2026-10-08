#!/usr/bin/env bash
#
# Hyprshell — one installer for the whole setup, or any part of it.
#
#   ./install.sh                  pick what to install from a menu
#   ./install.sh --all            everything
#   ./install.sh --shell          just the shell (bar, dock, panels, settings)
#   ./install.sh --shell --terminal --files
#                                 any mix of parts; see the list below
#   ./install.sh --check --all    report what each part is missing, change nothing
#   ./install.sh --list           the parts, and whether each is installed
#
# The parts:
#
#   --shell        the desktop shell and its Hyprland config
#   --shell-only   the shell, keeping your own Hyprland config (prints the
#                  lines to add to it instead)
#   --terminal     Hyprshell Terminal
#   --files        Hyprshell Files
#   --images       Hyprshell Images — the image viewer, made the default for
#                  pictures
#   --mail         Hyprshell Mail and its background service
#   --tasks        the task manager
#   --browser      Hyprshell Browser (Firefox underneath, its own profile)
#   --greeter      the login screen (greetd; asks for sudo)
#   --all          all of the above except --shell-only
#
# And how:
#
#   --deps         install the packages the chosen parts need first (Arch and
#                  CachyOS: pacman, and paru or yay for quickshell if it is
#                  not in your repositories). Without it, each part reports
#                  what is missing and the exact command to get it.
#   --yes          don't ask; take the defaults
#   --default-browser   make Hyprshell Browser the default browser
#   --prefix DIR   where the apps go (default ~/.local)
#
# Each part has its own installer in its folder (shell/install.sh and so on),
# which this runs; they can still be run on their own. A part that fails does
# not stop the rest: everything chosen is tried, and the summary at the end
# says what happened to each.
#
# Not `set -e`, for the same reason as the parts' installers: much of this
# probes for things that may be missing, and a probe saying "no" must not
# end the run.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YEL=$'\033[33m'; ACC=$'\033[38;5;209m'; RST=$'\033[0m'
else
    BOLD=; DIM=; RED=; GRN=; YEL=; ACC=; RST=
fi
say()  { printf '%s\n' "$*"; }
head1(){ printf '\n%s%s%s\n' "$BOLD" "$1" "$RST"; }
note() { printf '  %s%s%s\n' "$DIM" "$1" "$RST"; }

# ── the parts ──────────────────────────────────────────────────────────────
# key | folder | name | what it is | rough time to build
PARTS=(
    "shell|shell|Shell|bar, dock, launcher, panels, settings, wallpapers|a minute"
    "terminal|term|Terminal|the terminal, in the shell's design|2–4 minutes (Rust + Qt)"
    "files|files|Files|the file manager|1–2 minutes"
    "images|images|Images|the image viewer, default for pictures|under a minute"
    "mail|mail|Mail|mail app and background service|3–5 minutes (Rust + Qt)"
    "tasks|tasks|Task manager|processes, performance, startup apps|1–2 minutes"
    "browser|browser|Browser|Firefox underneath, its own look and profile|a minute (uses your Firefox)"
    "greeter|greeter|Login screen|greetd greeter in the shell's design (sudo)|seconds"
)
part_field() { local n=$2 IFS='|'; local f=($1); printf '%s' "${f[$((n - 1))]}"; }
part_key()   { part_field "$1" 1; }
part_dir()   { part_field "$1" 2; }
part_name()  { part_field "$1" 3; }
part_what()  { part_field "$1" 4; }
part_time()  { part_field "$1" 5; }
part_exists(){ [ -x "$ROOT/$(part_dir "$1")/install.sh" ] || [ -f "$ROOT/$(part_dir "$1")/install.sh" ]; }

# Is it there already? Only for the list; each installer decides for itself.
installed() {
    case "$1" in
        shell)    [ -e "${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/hyprshell/shell.qml" ] ;;
        terminal) command -v hyprshell-term >/dev/null 2>&1 || [ -x "$PREFIX/bin/hyprshell-term" ] ;;
        files)    command -v hyprshell-files >/dev/null 2>&1 || [ -x "$PREFIX/bin/hyprshell-files" ] ;;
        images)   command -v hyprshell-images >/dev/null 2>&1 || [ -x "$PREFIX/bin/hyprshell-images" ] ;;
        mail)     command -v hyprshell-mail >/dev/null 2>&1 || [ -x "$PREFIX/bin/hyprshell-mail" ] ;;
        tasks)    command -v hyprshell-tasks >/dev/null 2>&1 || [ -x "$PREFIX/bin/hyprshell-tasks" ] ;;
        browser)  command -v hyprshell-browser >/dev/null 2>&1 || [ -x "$PREFIX/bin/hyprshell-browser" ] ;;
        greeter)  [ -d /usr/share/hyprshell-greeter ] ;;
        *) return 1 ;;
    esac
}

# ── options ────────────────────────────────────────────────────────────────
PREFIX="$HOME/.local"
CHECK=0; DEPS=0; YES=0; LIST=0; SHELL_ONLY=0; DEFAULT_BROWSER=0
declare -A WANT=()
picked_any=0
usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --all)        for p in "${PARTS[@]}"; do part_exists "$p" && WANT[$(part_key "$p")]=1; done; picked_any=1 ;;
        --shell)      WANT[shell]=1; picked_any=1 ;;
        --shell-only) WANT[shell]=1; SHELL_ONLY=1; picked_any=1 ;;
        --terminal|--term) WANT[terminal]=1; picked_any=1 ;;
        --files)      WANT[files]=1; picked_any=1 ;;
        --images)     WANT[images]=1; picked_any=1 ;;
        --mail)       WANT[mail]=1; picked_any=1 ;;
        --tasks)      WANT[tasks]=1; picked_any=1 ;;
        --browser)    WANT[browser]=1; picked_any=1 ;;
        --greeter)    WANT[greeter]=1; picked_any=1 ;;
        --deps)       DEPS=1 ;;
        --check)      CHECK=1 ;;
        --yes|-y)     YES=1 ;;
        --list)       LIST=1 ;;
        --default-browser) DEFAULT_BROWSER=1 ;;
        --prefix)     shift; PREFIX="${1:-$PREFIX}" ;;
        -h|--help)    usage; exit 0 ;;
        *) say "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

banner() {
    printf '\n%s  ◆ Hyprshell%s  %sinstaller%s\n' "$ACC$BOLD" "$RST" "$DIM" "$RST"
}

list_parts() {
    head1 "Parts"
    for p in "${PARTS[@]}"; do
        local k; k=$(part_key "$p")
        part_exists "$p" || continue
        if installed "$k"; then mark="${GRN}installed${RST}"; else mark="${DIM}not installed${RST}"; fi
        printf '  %-14s %-52s %s\n' "$(part_name "$p")" "$(part_what "$p")" "$mark"
    done
}

if [ "$LIST" = 1 ]; then banner; list_parts; exit 0; fi

# ── the menu ───────────────────────────────────────────────────────────────
# Shown when nothing was chosen on the command line and there is someone to
# ask. Numbers toggle a part; a and s are the two common choices.
menu() {
    local keys=() p
    for p in "${PARTS[@]}"; do part_exists "$p" && keys+=("$p"); done
    # A fresh machine starts with everything ticked except the login
    # screen, which changes how the computer starts and should be a choice.
    if [ "$picked_any" = 0 ]; then
        for p in "${keys[@]}"; do
            local k; k=$(part_key "$p")
            [ "$k" = greeter ] || WANT[$k]=1
        done
    fi
    while :; do
        clear 2>/dev/null || true
        banner
        say ""
        say "  Choose what to install. Type a number to tick or untick it."
        say ""
        local i=1
        for p in "${keys[@]}"; do
            local k; k=$(part_key "$p")
            local box="[ ]"; [ "${WANT[$k]:-0}" = 1 ] && box="${ACC}[✓]${RST}"
            local inst=""; installed "$k" && inst=" ${GRN}· installed${RST}"
            printf '   %s%d%s  %s  %-13s %s%s%s%s\n' "$BOLD" "$i" "$RST" "$box" "$(part_name "$p")" \
                "$DIM" "$(part_what "$p")" "$RST" "$inst"
            i=$((i + 1))
        done
        say ""
        local dmark="[ ]"; [ "$DEPS" = 1 ] && dmark="${ACC}[✓]${RST}"
        local omark="[ ]"; [ "$SHELL_ONLY" = 1 ] && omark="${ACC}[✓]${RST}"
        printf '   %sd%s  %s  Install the packages they need first (pacman)\n' "$BOLD" "$RST" "$dmark"
        printf '   %sk%s  %s  Keep my own Hyprland config (the shell only adds itself)\n' "$BOLD" "$RST" "$omark"
        say ""
        printf '   %sa%s all   %ss%s shell only   %sn%s none   %sEnter%s install   %sq%s quit\n' \
            "$BOLD" "$RST" "$BOLD" "$RST" "$BOLD" "$RST" "$BOLD" "$RST" "$BOLD" "$RST"
        say ""
        printf '  > '
        local ans; IFS= read -r ans || exit 1
        case "$ans" in
            "") break ;;
            q|Q) exit 0 ;;
            a|A) for p in "${keys[@]}"; do WANT[$(part_key "$p")]=1; done ;;
            n|N) WANT=() ;;
            s|S) WANT=(); WANT[shell]=1 ;;
            d|D) DEPS=$((1 - DEPS)) ;;
            k|K) SHELL_ONLY=$((1 - SHELL_ONLY)) ;;
            *[!0-9\ ]*) ;;
            *) for n in $ans; do
                   if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#keys[@]}" ]; then
                       local k; k=$(part_key "${keys[$((n - 1))]}")
                       if [ "${WANT[$k]:-0}" = 1 ]; then unset "WANT[$k]"; else WANT[$k]=1; fi
                   fi
               done ;;
        esac
    done
}

if [ "$picked_any" = 0 ]; then
    if [ -t 0 ] && [ "$YES" = 0 ]; then menu
    else usage; exit 2; fi
fi

CHOSEN=()
for p in "${PARTS[@]}"; do
    k=$(part_key "$p")
    [ "${WANT[$k]:-0}" = 1 ] || continue
    if ! part_exists "$p"; then say "${YEL}skipping $(part_name "$p"): $(part_dir "$p")/install.sh is not in this copy${RST}"; continue; fi
    CHOSEN+=("$p")
done
if [ ${#CHOSEN[@]} -eq 0 ]; then say "Nothing chosen."; exit 0; fi

banner
head1 "$([ "$CHECK" = 1 ] && echo "Checking" || echo "Installing")"
for p in "${CHOSEN[@]}"; do
    printf '  %s·%s %-14s %s%s%s\n' "$ACC" "$RST" "$(part_name "$p")" "$DIM" "$(part_time "$p")" "$RST"
done

if [ "$CHECK" = 0 ] && [ "$YES" = 0 ] && [ -t 0 ]; then
    printf '\n  Go ahead? [Y/n] '
    read -r go || exit 1
    case "$go" in n|N|no|NO) exit 0 ;; esac
fi

# ── packages ───────────────────────────────────────────────────────────────
is_arch() { [ -r /etc/os-release ] && ( . /etc/os-release; case "${ID:-}${ID_LIKE:-}" in *arch*) exit 0 ;; *) exit 1 ;; esac ); }

pkgs_for() {
    case "$1" in
        shell)    echo "hyprland quickshell inter-font ttf-jetbrains-mono networkmanager bluez-utils rust brightnessctl grim slurp wl-clipboard wf-recorder tesseract tesseract-data-eng libnotify playerctl pacman-contrib kvantum" ;;
        terminal) echo "base-devel cmake rust qt6-base qt6-declarative" ;;
        files)    echo "base-devel cmake qt6-base qt6-declarative vulkan-headers" ;;
        images)   echo "base-devel cmake qt6-base qt6-declarative qt6-imageformats qt6-svg kimageformats" ;;
        mail)     echo "base-devel cmake rust qt6-base qt6-declarative qt6-webengine gnome-keyring libnotify xdg-utils" ;;
        tasks)    echo "base-devel cmake qt6-base qt6-declarative" ;;
        browser)  echo "firefox" ;;
        greeter)  echo "greetd gnome-keyring" ;;
    esac
}

if [ "$DEPS" = 1 ] && [ "$CHECK" = 0 ]; then
    head1 "Packages"
    if ! is_arch; then
        note "Only Arch and CachyOS are installed for automatically. Each part below says what it is missing."
    else
        all=""
        for p in "${CHOSEN[@]}"; do all="$all $(pkgs_for "$(part_key "$p")")"; done
        # One each, in the order first wanted.
        want=$(printf '%s\n' $all | awk '!seen[$0]++' | tr '\n' ' ')
        repo=""; aur=""
        for pk in $want; do
            if pacman -Qq "$pk" >/dev/null 2>&1; then continue; fi
            if pacman -Si "$pk" >/dev/null 2>&1; then repo="$repo $pk"; else aur="$aur $pk"; fi
        done
        if [ -n "$repo" ]; then
            note "From your repositories:$repo"
            sudo pacman -S --needed $([ "$YES" = 1 ] && echo --noconfirm) $repo || say "  ${YEL}pacman did not finish; the parts below will say what is still missing${RST}"
        else
            note "Everything from the repositories is already here."
        fi
        if [ -n "$aur" ]; then
            helper=""
            for h in paru yay; do command -v "$h" >/dev/null 2>&1 && { helper=$h; break; }; done
            if [ -n "$helper" ]; then
                note "From the AUR, with $helper:$aur"
                "$helper" -S --needed $([ "$YES" = 1 ] && echo --noconfirm) $aur || say "  ${YEL}$helper did not finish${RST}"
            else
                say "  ${YEL}Not in your repositories:$aur${RST}"
                note "Install them from the AUR (with paru or yay), then run this again."
            fi
        fi
    fi
fi

# ── the parts ──────────────────────────────────────────────────────────────
declare -A RESULT=()
run_part() {
    local p=$1 k dir args=()
    k=$(part_key "$p"); dir="$ROOT/$(part_dir "$p")"
    head1 "$(part_name "$p")"
    case "$k" in
        shell)
            [ "$CHECK" = 1 ] && args+=(--check)
            [ "$SHELL_ONLY" = 1 ] && [ "$CHECK" = 0 ] && args+=(--shell-only)
            [ "$YES" = 1 ] && args+=(--force) ;;
        browser)
            if [ "$CHECK" = 1 ]; then
                [ -x "$dir/doctor.sh" ] && { (cd "$dir" && bash ./doctor.sh); return $?; }
                note "nothing to check before it is installed"; return 0
            fi
            [ "$DEFAULT_BROWSER" = 1 ] && args+=(--default) ;;
        greeter)
            if [ "$CHECK" = 1 ]; then (cd "$dir" && sh ./install.sh --status); return $?; fi
            (cd "$dir" && sudo sh ./install.sh); return $? ;;
        *)
            [ "$CHECK" = 1 ] && args+=(--check)
            args+=(--prefix "$PREFIX") ;;
    esac
    case "$(head -1 "$dir/install.sh")" in
        *bash*) (cd "$dir" && bash ./install.sh "${args[@]}") ;;
        *)      (cd "$dir" && sh ./install.sh "${args[@]}") ;;
    esac
}

for p in "${CHOSEN[@]}"; do
    run_part "$p"
    RESULT[$(part_key "$p")]=$?
done

# ── what happened ──────────────────────────────────────────────────────────
head1 "Summary"
failed=0
for p in "${CHOSEN[@]}"; do
    k=$(part_key "$p")
    if [ "${RESULT[$k]}" = 0 ]; then
        printf '  %s✓%s %-14s %s\n' "$GRN" "$RST" "$(part_name "$p")" "$([ "$CHECK" = 1 ] && echo "ready" || echo "installed")"
    else
        failed=$((failed + 1))
        printf '  %s✗%s %-14s %s\n' "$RED" "$RST" "$(part_name "$p")" "see its messages above (exit ${RESULT[$k]})"
    fi
done
if [ "$CHECK" = 0 ] && [ "${RESULT[shell]:-1}" = 0 ]; then
    say ""
    note "Log out and pick Hyprland, or press Super+Shift+R if Hyprshell is already running."
fi
[ "$failed" = 0 ]
