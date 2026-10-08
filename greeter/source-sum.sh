#!/bin/sh
# A checksum of everything greeter/install.sh copies into
# /usr/share/hyprshell-greeter: the greeter's own files and the parts of
# the shell it is drawn with. install.sh keeps it there as .source, and the
# shell's install.sh compares the two to say when the installed greeter is
# older than this checkout.
REPO=$(cd "$(dirname "$0")/.." && pwd)
cd "$REPO" || exit 1
{
    find greeter -maxdepth 1 -name '*.qml' -type f
    find shell/quickshell/config shell/quickshell/modules/common \
         shell/quickshell/modules/icons shell/quickshell/modules/background -type f
} | LC_ALL=C sort | while IFS= read -r f; do cat "$f"; done | cksum | cut -d' ' -f1
