#!/bin/bash
# The Limine boot menu in your wallpaper and colours: installs the small
# root helper the shell uses for it, and its polkit rule.
#
#   sudo ./install.sh              install
#   sudo ./install.sh --check      say what it would write to, change nothing
#   sudo ./install.sh --uninstall  take the wallpaper back out of the boot
#                                  menu and remove the helper
#
# Then Settings → Wallpaper → Boot menu → Update. See
# README.md here for what is written where.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
helper=/usr/local/libexec/hyprshell-limine-theme
policy=/usr/share/polkit-1/actions/org.hyprshell.limine-theme.policy
fontdir=/usr/local/share/hyprshell/limine

[ "$(id -u)" -eq 0 ] || { echo "Run it with sudo: sudo $0 $*" >&2; exit 1; }

case ${1:-} in
    --check)
        bash "$here/hyprshell-limine-theme" --check
        ;;
    --uninstall)
        [ -x "$helper" ] && "$helper" --remove || true
        rm -f "$helper" "$policy"
        rm -rf -- "${fontdir:?}"
        echo "Removed. limine.conf as it was before the first change: limine.conf.hyprshell-orig beside it."
        ;;
    "")
        # Refuses here, before anything is installed, on a set-up it can't
        # safely edit.
        bash "$here/hyprshell-limine-theme" --check
        command -v pkexec >/dev/null 2>&1 || { echo "pkexec (polkit) is needed: sudo pacman -S polkit" >&2; exit 1; }
        install -D -m 755 -o root -g root "$here/hyprshell-limine-theme" "$helper"
        install -D -m 644 -o root -g root "$here/fonts/hyprshell-boot-8x16.bin" "$fontdir/hyprshell-boot-8x16.bin"
        install -D -m 644 -o root -g root "$here/fonts/OFL.txt" "$fontdir/OFL.txt"
        install -D -m 644 -o root -g root "$here/org.hyprshell.limine-theme.policy" "$policy"
        echo "Installed. Then Settings → Wallpaper → Boot menu → Update."
        ;;
    *)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
