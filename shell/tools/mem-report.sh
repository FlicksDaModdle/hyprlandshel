#!/bin/bash
# What the shell's memory is made of, for when it's bigger than it should be.
#
#   bash shell/tools/mem-report.sh          the picture now
#   bash shell/tools/mem-report.sh watch    and its size once a minute for ten
#
# Reads only: /proc, /sys and Hyprland's own report. Nothing is changed.
set -u

pid=$(pgrep -xo qs) || { echo "The shell (qs) isn't running."; exit 1; }
echo "== shell processes"
pgrep -a qs
echo
echo "== size (kB)"
grep -E "^(Rss|Pss_Anon|Pss_File|Pss_Shmem)" "/proc/$pid/smaps_rollup"
echo
echo "== its environment (what it was started with)"
tr '\0' '\n' <"/proc/$pid/environ" | grep -E "^(__EGL|__GLX|VK_|GLIBC|MALLOC|AMD_DEBUG|QT_FFMPEG|QT_QPA)" || echo "(none of the shell's settings)"
echo
echo "== GPUs"
for d in /sys/class/drm/renderD*; do
    echo "$(basename "$d"): $(sed -n 's/^DRIVER=//p' "$d/device/uevent" 2>/dev/null)"
done
echo "EGL vendors: $(ls /usr/share/glvnd/egl_vendor.d/ 2>/dev/null | tr '\n' ' ')"
echo
echo "== graphics libraries loaded in it"
grep -E "libEGL|nvidia|gbm|dri|vulkan|libGL|LLVM|gallium|jemalloc" "/proc/$pid/maps" | awk '{print $6}' | sort -u
echo
echo "== the biggest mappings (kB)"
awk '/^[0-9a-f]+-[0-9a-f]+ / { name = ($6 == "" ? "[anon]" : $6) } /^Rss:/ { rss[name] += $2 }
     END { for (n in rss) print rss[n], n }' "/proc/$pid/smaps" | sort -rn | head -12
echo
echo "== Hyprland's GPU"
tr '\0' '\n' <"/proc/$(pgrep -xo Hyprland)/environ" 2>/dev/null | grep -E "^(AQ_|WLR_DRM)" || echo "(no AQ_DRM_DEVICES set)"
hyprctl monitors 2>/dev/null | grep -E "^Monitor|currentFormat|scale:"
echo
echo "== the scale the shell draws at"
grep -h "draws at" "${XDG_RUNTIME_DIR:-/tmp}/hyprshell.log" 2>/dev/null | tail -n 4 | grep . \
    || echo "(not in the log: restart the shell with start-shell.sh --restart first)"
pid=$(pgrep -xo qs) && tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -E "^QT_(SCALE|AUTO_SCREEN|ENABLE_HIGHDPI|WAYLAND)" || true

if [ "${1:-}" = watch ]; then
    echo
    echo "== size once a minute for ten minutes (use the laptop as usual)"
    for i in $(seq 10); do
        echo "$(date +%H:%M)  $(ps -o rss= -p "$pid") kB"
        [ "$i" -lt 10 ] && sleep 60
    done
fi
