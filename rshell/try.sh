#!/bin/bash
# Try the Rust shell: builds it, stops the Quickshell one, runs this in its
# place, and puts Quickshell back when this ends — Ctrl+C, a crash, or the
# terminal closing.
#
#   bash ~/hyprlandshel/rshell/try.sh
#
# While it runs, only what has been ported is there: the bar for now. The
# dock, launcher, panels, notifications and the lock screen are Quickshell's
# and come back with it, so Super+L does nothing until you stop this.
set -u
cd "$(dirname "$0")" || exit 1

command -v cargo >/dev/null || { echo "cargo isn't installed: sudo pacman -S --needed rust"; exit 1; }
echo "Building…"
cargo build --release -q || exit 1

restore() {
    pkill -x hyprshell-rs 2>/dev/null
    echo "Bringing the Quickshell shell back."
    setsid -f "$HOME/.local/share/hyprshell/start-shell.sh" >/dev/null 2>&1
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

pkill -x qs 2>/dev/null && sleep 0.4
echo "Running the Rust shell. Ctrl+C here to stop it and get the usual shell back."
./target/release/hyprshell-rs
