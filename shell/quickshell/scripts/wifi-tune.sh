#!/bin/bash
# Wi-Fi speed and steadiness (Settings → Wi-Fi & network → Wi-Fi performance).
#
#   wifi-tune.sh --status          what's set: backend, iwd installed, power saving
#   wifi-tune.sh --iwd on|off      NetworkManager's Wi-Fi through iwd, or back to
#                                  wpa_supplicant (root; installs iwd if needed)
#   wifi-tune.sh --powersave on|off  the card's power saving (root)
#
# Both are a file of the shell's own in /etc/NetworkManager/conf.d, and
# undoing one removes its file: nothing else of NetworkManager's is touched,
# and your saved networks stay where they are.
#
# iwd scans and joins faster than wpa_supplicant; NetworkManager starts it
# itself (D-Bus activation), so iwd.service is not enabled. Power saving
# off is the usual cure for dropouts and slow wake-ups on MediaTek cards
# (the G14's), at a little battery.
set -u

CONF=/etc/NetworkManager/conf.d
BACKEND=$CONF/90-hyprshell-wifi-backend.conf
POWER=$CONF/90-hyprshell-wifi-powersave.conf

die() { printf 'wifi-tune: %s\n' "$*" >&2; exit 1; }

backend() {
    if grep -qsE '^\s*wifi\.backend\s*=\s*iwd' /etc/NetworkManager/NetworkManager.conf "$CONF"/*.conf; then
        echo iwd
    else
        echo wpa_supplicant
    fi
}
powersave() {
    # 2 is off, 3 on; the last file read wins, as NetworkManager reads them.
    local v
    v=$(cat /etc/NetworkManager/NetworkManager.conf "$CONF"/*.conf 2>/dev/null \
        | sed -n 's/^\s*wifi\.powersave\s*=\s*\([0-9]\).*/\1/p' | tail -n 1)
    case $v in
        2) echo off ;;
        3) echo on ;;
        *) echo default ;;
    esac
}
wifi_device() {
    nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" { print $1; exit }'
}

case ${1:-} in
    --status)
        printf 'backend\t%s\n' "$(backend)"
        command -v iwctl >/dev/null 2>&1 || [ -x /usr/lib/iwd/iwd ] || [ -x /usr/libexec/iwd ] \
            && printf 'iwd\tyes\n' || printf 'iwd\tno\n'
        printf 'powersave\t%s\n' "$(powersave)"
        dev=$(wifi_device)
        [ -n "$dev" ] && printf 'device\t%s\n' "$dev"
        exit 0 ;;

    --iwd)
        [ "$(id -u)" = 0 ] || die "needs root (Settings asks for your password)"
        mkdir -p "$CONF"
        case ${2:-} in
            on)
                if ! command -v iwctl >/dev/null 2>&1 && ! [ -x /usr/lib/iwd/iwd ]; then
                    command -v pacman >/dev/null 2>&1 || die "iwd isn't installed: install it with your package manager, then try again"
                    echo "Installing iwd…"
                    pacman -S --needed --noconfirm iwd >/dev/null || die "couldn't install iwd (pacman -S iwd)"
                fi
                printf '%s\n' "# Hyprshell: Wi-Fi through iwd (Settings → Wi-Fi & network)" "[device]" "wifi.backend=iwd" > "$BACKEND"
                # wpa_supplicant would hold the card: stopped. NetworkManager
                # starts iwd itself.
                systemctl stop wpa_supplicant.service 2>/dev/null
                systemctl restart NetworkManager.service || die "NetworkManager wouldn't restart"
                echo "iwd" ;;
            off)
                rm -f "$BACKEND"
                systemctl stop iwd.service 2>/dev/null
                systemctl restart NetworkManager.service || die "NetworkManager wouldn't restart"
                echo "wpa_supplicant" ;;
            *) die "--iwd on|off" ;;
        esac
        exit 0 ;;

    --powersave)
        [ "$(id -u)" = 0 ] || die "needs root (Settings asks for your password)"
        mkdir -p "$CONF"
        case ${2:-} in
            off)
                printf '%s\n' "# Hyprshell: Wi-Fi power saving off (Settings → Wi-Fi & network)" "[connection]" "wifi.powersave=2" > "$POWER" ;;
            on)
                rm -f "$POWER" ;;
            *) die "--powersave on|off" ;;
        esac
        nmcli general reload conf 2>/dev/null || systemctl reload NetworkManager.service 2>/dev/null
        # Now, too, not only from the next connection.
        dev=$(wifi_device)
        if [ -n "$dev" ] && command -v iw >/dev/null 2>&1; then
            iw dev "$dev" set power_save "$([ "$2" = on ] && echo on || echo off)" 2>/dev/null
        fi
        echo "$(powersave)"
        exit 0 ;;

    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
