#!/bin/bash
# Records where the shell's memory is allocated, for cutting it down.
#
#   bash shell/tools/heap-profile.sh        record for 10 minutes
#   bash shell/tools/heap-profile.sh 5      record for 5
#
# The shell is restarted under heaptrack with the environment it was
# running with, used as usual for that long, then restarted normally. The
# summary is written to ~/heap.txt; the full recording is kept beside it.
set -u

mins=${1:-10}
command -v heaptrack >/dev/null && command -v heaptrack_print >/dev/null || {
    echo "heaptrack isn't installed: sudo pacman -S heaptrack, then run this again."
    exit 1
}

# The environment the running shell has (Mesa EGL, malloc arenas, ...).
if pid=$(pgrep -xo qs); then
    while IFS= read -r kv; do export "$kv"; done < <(tr '\0' '\n' <"/proc/$pid/environ" \
        | grep -E '^(MALLOC_ARENA_MAX|__EGL_VENDOR_LIBRARY_FILENAMES|__GLX_VENDOR_LIBRARY_NAME|VK_DRIVER_FILES|VK_ICD_FILENAMES|QT_[A-Z_]+)=')
    pkill -x qs
    sleep 0.5
fi

dir=$HOME/heaptrack-hyprshell
mkdir -p "$dir"
rm -f -- "$dir"/heaptrack.qs.*
echo "Recording for $mins minutes. Use the laptop as usual (open the launcher,"
echo "control centre, settings, overview, notifications...). Keep this terminal open."
( cd "$dir" && heaptrack qs -c hyprshell >"$dir/run.log" 2>&1 ) &
hp=$!

sleep "$((mins * 60))"
echo "Stopping and restarting the shell normally..."
pkill -INT -x qs
wait "$hp"
setsid -f "$HOME/.local/share/hyprshell/start-shell.sh" >/dev/null 2>&1

file=$(find "$dir" -maxdepth 1 -name 'heaptrack.qs.*' | head -n 1)
[ -n "$file" ] || { echo "No recording was written; see $dir/run.log"; exit 1; }
heaptrack_print -f "$file" -n 15 -s 3 >"$HOME/heap.txt" 2>&1
echo "Done: $HOME/heap.txt ($(wc -l <"$HOME/heap.txt") lines). The recording: $file"
