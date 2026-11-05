#!/usr/bin/env python3
"""Reads the Quickshell shell's config/Appearance.qml and writes
src/prefs.json: every theme.json key with its default, and the names
Settings.qml uses for them (its aliases). Run again when Appearance.qml
gains a setting: python3 tools/gen-prefs.py"""
import json, pathlib, re

HERE = pathlib.Path(__file__).resolve().parent.parent
QML = HERE.parent.parent / "shell/quickshell/config/Appearance.qml"
src = QML.read_text()

defaults = {}
for m in re.finditer(r"^\s*property (int|bool|string|real) (\w+):\s*(.+?)\s*(?://.*)?$", src, re.M):
    kind, name, val = m.groups()
    if name in defaults:
        continue
    try:
        if kind == "bool":
            if val not in ("true", "false"):
                continue
            defaults[name] = val == "true"
        elif kind == "string":
            mm = re.match(r'^"((?:[^"\\]|\\.)*)"', val)
            if not mm:
                continue
            defaults[name] = json.loads('"' + mm.group(1) + '"')
        elif kind == "int":
            defaults[name] = int(val)
        else:
            defaults[name] = float(val)
    except ValueError:
        pass

aliases = {}
for m in re.finditer(r"property alias (\w+): prefs\.(\w+)", src):
    aliases[m.group(1)] = m.group(2)

out = HERE / "src/prefs.json"
out.write_text(json.dumps({"defaults": defaults, "aliases": aliases}, indent=1, sort_keys=True) + "\n")
print(f"{len(defaults)} keys, {len(aliases)} aliases -> {out}")
