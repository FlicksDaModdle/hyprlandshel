#!/bin/sh
# CPU use over a second, from /proc/stat. Prints JSON so the label can be
# tinted: warn past 60 %, crit past 90 %.
read -r _ u1 n1 s1 i1 w1 q1 f1 _ < /proc/stat
sleep 1
read -r _ u2 n2 s2 i2 w2 q2 f2 _ < /proc/stat
busy=$(( (u2+n2+s2+q2+f2) - (u1+n1+s1+q1+f1) ))
total=$(( busy + (i2+w2) - (i1+w1) ))
pct=$(( total > 0 ? 100 * busy / total : 0 ))
class=""; [ "$pct" -ge 60 ] && class="warn"; [ "$pct" -ge 90 ] && class="crit"
printf '{"text": "%s%%", "tooltip": "CPU %s%% busy", "class": "%s"}\n' "$pct" "$pct" "$class"
