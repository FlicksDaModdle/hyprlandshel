#!/bin/bash
# Checks the shell before it's installed (install.sh runs this, and so
# should anyone about to push):
#
#   every QML file   a property or handler set twice in one object
#                    (tools/qml-dupcheck.py), and qmllint's syntax errors
#                    where qmllint is installed
#   every script     bash -n, python3 -m py_compile (in a throwaway folder)
#   hyprland.lua     luac -p, where there's a Lua compiler
#
# Exit status 0 when all is well; 1, with what's wrong, otherwise. Quiet
# unless something is wrong, or -v.
set -u

here=$(cd "${0%/*}" && pwd)
shell=$(cd "$here/.." && pwd)
verbose=0
[ "${1:-}" = -v ] && verbose=1
bad=0
fail() { printf '  ✗ %s\n' "$*" >&2; bad=1; }
ok() { [ "$verbose" = 1 ] && printf '  ✓ %s\n' "$*"; return 0; }

# QML: the error that keeps a file from loading at all.
mapfile -t qml < <(find "$shell/quickshell" -name '*.qml' -not -path '*/.*')
if out=$(python3 "$here/qml-dupcheck.py" "${qml[@]}"); then
    ok "${#qml[@]} QML files: nothing set twice"
else
    fail "QML: something set twice in one object:"
    printf '%s\n' "$out" | sed "s|$shell/||; s|^|      |" >&2
fi

# qmllint's syntax errors (not its warnings: it can't see Quickshell's
# types, and says so about every file).
lint=""
for c in /usr/lib/qt6/bin/qmllint /usr/lib64/qt6/bin/qmllint "$(command -v qmllint6 2>/dev/null)" "$(command -v qmllint 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { lint=$c; break; }
done
if [ -n "$lint" ]; then
    syn=$("$lint" "${qml[@]}" 2>&1 | grep -E "\.qml:[0-9]+:[0-9]+: (Expected token|Unexpected token|Syntax error|Expected a|Unexpected)" || true)
    if [ -n "$syn" ]; then
        fail "QML syntax:"
        printf '%s\n' "$syn" | sed "s|$shell/||; s|^|      |" | head -20 >&2
    else
        ok "qmllint: no syntax errors"
    fi
fi

# Scripts.
while IFS= read -r f; do
    bash -n "$f" 2>/dev/null || fail "bash syntax: ${f#"$shell"/}"
done < <(find "$shell" -name '*.sh' -not -path '*/target/*' -not -path '*/.*')
ok "shell scripts parse"

tmp=$(mktemp -d) || exit 1
trap 'rm -rf -- "${tmp:?}"' EXIT
while IFS= read -r f; do
    PYTHONPYCACHEPREFIX="$tmp" python3 -m py_compile "$f" 2>/dev/null || fail "python syntax: ${f#"$shell"/}"
done < <(find "$shell" -name '*.py' -not -path '*/target/*' -not -path '*/.*')
ok "python scripts compile"

# hyprland.lua.
luac=""
for c in luac luac5.4 luac5.3 luajit; do command -v "$c" >/dev/null 2>&1 && { luac=$c; break; }; done
if [ -n "$luac" ]; then
    if [ "$luac" = luajit ]; then "$luac" -bl "$shell/hypr/hyprland.lua" >/dev/null 2>&1; else "$luac" -p "$shell/hypr/hyprland.lua" 2>/dev/null; fi \
        && ok "hyprland.lua parses" || fail "hyprland.lua doesn't parse"
fi

exit "$bad"
