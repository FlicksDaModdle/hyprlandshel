#!/bin/sh
# Lets the shell set external monitors' brightness over DDC/CI (the
# monitor's own backlight, the way its on-screen menu sets it). Run with
# sudo, once; ./install.sh --monitors does.
#
#   i2c-dev       the kernel module that makes the monitors' buses usable,
#                 loaded now and at every boot
#   udev rule     read-write access to those buses for whoever is logged in
#                 at the seat (uaccess) — only buses on a graphics card, the
#                 way ddcutil's own rule does it, never the motherboard's
#                 SMBus where the memory modules sit
#
#   sudo sh shell/monitors.sh            set it up
#   sudo sh shell/monitors.sh --remove   undo it

set -u
MOD=/etc/modules-load.d/hyprshell-i2c.conf
RULE=/etc/udev/rules.d/60-hyprshell-ddc.rules

if [ "$(id -u)" != 0 ]; then
    echo "needs root: sudo sh $0 $*" >&2
    exit 1
fi

if [ "${1:-}" = "--remove" ]; then
    rm -f "$MOD" "$RULE"
    udevadm control --reload-rules 2>/dev/null
    echo "Removed. i2c-dev stays loaded until the next boot."
    exit 0
fi

printf '%s\n' "# Hyprshell: monitors' DDC/CI buses, for their brightness" "i2c-dev" > "$MOD"
cat > "$RULE" <<'RULES'
# Hyprshell: external monitors' brightness over DDC/CI. The buses of display
# adapters only (PCI class 0x03xxxx), for the user at the seat.
SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x030000", TAG+="uaccess"
SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x030200", TAG+="uaccess"
SUBSYSTEM=="i2c-dev", KERNEL=="i2c-[0-9]*", ATTRS{class}=="0x038000", TAG+="uaccess"
RULES
modprobe i2c-dev 2>/dev/null || echo "couldn't load i2c-dev now; it loads at the next boot"
udevadm control --reload-rules 2>/dev/null
udevadm trigger --subsystem-match=i2c-dev 2>/dev/null
echo "Done. The shell picks the monitors up within a few seconds (or after Super+Shift+R)."
