#!/usr/bin/env python3
"""Checks the Rust Settings against the Quickshell one: every row name
Settings.qml can show, pane by pane, that `hyprshell-settings --dump`
doesn't, and the other way round. Names built from data (a display's,
a device's) are skipped. Usage: python3 tools/parity.py <dump file>"""
import pathlib, re, sys

HERE = pathlib.Path(__file__).resolve().parent.parent
QML = (HERE.parent.parent / "shell/quickshell/modules/settings/Settings.qml").read_text()

# Each pane's source: its case block, plus the helpers it calls.
helpers = {}
for m in re.finditer(r"\n    function (\w+)\([^)]*\) \{\n(.*?)\n    \}\n", QML, re.S):
    helpers[m.group(1)] = m.group(2)
cases = {}
for m in re.finditer(r'\n        case "([^"]+)":(.*?)(?=\n        case "|\n        \}\n        return \[\];)', QML, re.S):
    cases[m.group(1)] = m.group(2)
calls = {"Wallpaper": ["wallpaperRows", "animRows", "motionRows", "liveWallpaperRows", "topoRows", "bootRows"],
         "Login screen": ["loginRows", "serviceRows", "howdyRows", "keyringRows"],
         "Appearance": ["cornerRows", "cursorRows"], "Power": ["nightRows"]}

def names(src):
    out = set()
    for m in re.finditer(r'\bn:\s*((?:"[^"]*"\s*(?:\?|:)?\s*)+)', src):
        for s in re.findall(r'"([^"]*)"', m.group(1)):
            if s and len(s) > 1:
                out.add(s)
    return out

rust = {}
for line in open(sys.argv[1]):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 3 and f[2]:
        rust.setdefault(f[0], set()).add(f[2])

for pane, src in cases.items():
    full = src + "".join(helpers.get(h, "") for h in calls.get(pane, []))
    q = names(full)
    r = rust.get(pane, set())
    missing = sorted(q - r - {"Advanced", "Show advanced settings"})
    extra = sorted(r - q - {"Advanced", "Show advanced settings"})
    if missing or extra:
        print(f"== {pane}")
        for n in missing:
            print(f"   missing: {n}")
        for n in extra:
            print(f"   extra:   {n}")

# Descriptions: every plain one-string description in a pane's source
# that no row of that pane shows.
rust_s = {}
for line in open(sys.argv[1]):
    f = line.rstrip("\n").split("\t")
    if len(f) >= 4:
        rust_s.setdefault(f[0], set()).add(f[3])
for pane, src in cases.items():
    full = src + "".join(helpers.get(h, "") for h in calls.get(pane, []))
    want = set()
    for m in re.finditer(r'\bs:\s*"((?:[^"\\]|\\.)*)"\s*,', full):
        want.add(m.group(1).replace('\\u2019', '’').replace('\\u201C', '“').replace('\\u201D', '”'))
    have = rust_s.get(pane, set())
    off = sorted(w for w in want if w and w not in have)
    if off:
        print(f"== {pane} (descriptions)")
        for w in off:
            print(f"   not shown: {w}")
