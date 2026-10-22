#!/bin/bash
# The minimise plugin (main.cpp): an app's own minimise button passed on
# to the shell, which Hyprland otherwise drops.
#
#   ./install.sh             build it against this Hyprland and load it
#   ./install.sh --if-stale  only when Hyprland has changed since it was
#                            built (the shell runs this as it starts)
#   ./install.sh --remove    unload and delete it
#
# Nothing here needs root: it is built from Hyprland's own headers, which
# its package installs (or `hyprpm update` puts in /var/cache/hyprpm), into
# ~/.local/share/hyprshell/hyprplugin, and hyprland.lua loads it from there
# when the session starts. A Hyprland update makes it stale: Hyprland then
# refuses to load it, and the shell builds it again — nothing breaks
# meanwhile, the minimise buttons just do nothing until then.
set -uo pipefail

here=$(cd "${0%/*}" && pwd)
dest=${XDG_DATA_HOME:-$HOME/.local/share}/hyprshell/hyprplugin
so=$dest/hyprshell-minimize.so
stamp=$dest/built-for
mode=${1:-}

say() { [ "$mode" = --if-stale ] || printf '%s\n' "$*"; }
die() { printf 'hyprplugin: %s\n' "$*" >&2; exit 1; }

# Which Hyprland is installed: its binary, as hyprland.lua checks it too.
hypr_id() {
    local b
    b=$(command -v Hyprland 2>/dev/null || command -v hyprland 2>/dev/null) || return 1
    stat -Lc '%s %Y' "$b" 2>/dev/null
}
# The commit the running Hyprland was built from, and the headers'.
running_commit() {
    hyprctl version -j 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("commit",""))
except Exception: pass' 2>/dev/null
}
headers_commit() {
    local inc
    inc=$(pkg-config --variable=prefix hyprland 2>/dev/null) || return 0
    sed -n 's/^#define GIT_COMMIT_HASH *"\(.*\)"/\1/p' "$inc/hyprland/src/version.h" 2>/dev/null | head -1
}
load() {
    command -v hyprctl >/dev/null 2>&1 && [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] || return 0
    if hyprctl plugin list 2>/dev/null | grep -q "hyprshell-minimize"; then
        say "Already loaded in this session; the new build is used from the next login."
        return 0
    fi
    local rc hc
    rc=$(running_commit); hc=$(headers_commit)
    if [ -n "$rc" ] && [ -n "$hc" ] && [ "$rc" != "$hc" ]; then
        say "Hyprland was updated since this session started: it loads at the next login."
        return 0
    fi
    if hyprctl plugin load "$so" >/dev/null 2>&1; then say "Loaded: minimise buttons work now."
    else say "Built, but this Hyprland wouldn't load it yet; it loads at the next login."; fi
}

case $mode in
    --remove)
        [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && hyprctl plugin unload "$so" >/dev/null 2>&1
        rm -f "$so" "$stamp" "$dest/main.cpp" "$dest/install.sh"
        rmdir "$dest" 2>/dev/null
        echo "Removed."
        exit 0 ;;
    --if-stale)
        [ -f "$so" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$(hypr_id)" ] && exit 0 ;;
    "") ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

# Hyprland's headers: from its package, else from hyprpm.
for pc in /var/cache/hyprpm/"$(id -un)"/headersRoot/share/pkgconfig; do
    pkg-config --exists hyprland 2>/dev/null && break
    [ -f "$pc/hyprland.pc" ] && export PKG_CONFIG_PATH="$pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
done
pkg-config --exists hyprland 2>/dev/null \
    || die "Hyprland's headers aren't installed: run 'hyprpm update' once (it asks for your password), then this again"
command -v g++ >/dev/null 2>&1 || die "g++ isn't installed (sudo pacman -S --needed gcc)"

src=$here/main.cpp
[ -f "$src" ] || src=$dest/main.cpp
[ -f "$src" ] || die "main.cpp isn't here"

mkdir -p "$dest"
say "Building the minimise plugin against Hyprland $(pkg-config --modversion hyprland)…"
# The same flags hyprpm builds plugins with.
flags=$(pkg-config --cflags pixman-1 libdrm hyprland 2>/dev/null) \
    || die "pkg-config couldn't give Hyprland's build flags (pixman and libdrm are needed too)"
std=-std=c++26
echo 'int main(){}' | g++ -x c++ "$std" -fsyntax-only - 2>/dev/null || std=-std=c++2b
# shellcheck disable=SC2086
if ! g++ -shared -fPIC --no-gnu-unique -O2 "$std" $flags "$src" -o "$so.new" 2>"$dest/build.log"; then
    rm -f "$so.new"
    [ "$mode" = --if-stale ] && exit 1
    tail -n 20 "$dest/build.log" >&2
    die "it didn't build (the whole log is in $dest/build.log)"
fi
mv -f "$so.new" "$so"
# Kept beside it, so the shell can rebuild it after an update without
# needing the hyprshell folder.
[ "$src" = "$dest/main.cpp" ] || cp -f "$src" "$dest/main.cpp"
[ "$0" -ef "$dest/install.sh" ] || cp -f "$0" "$dest/install.sh"
hypr_id >"$stamp"
say "Built: $so"
load
exit 0
