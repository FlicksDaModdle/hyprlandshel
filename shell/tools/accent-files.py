#!/usr/bin/env python3
"""Write the files that carry the shell's accent out to other programs.

The shell writes these itself whenever the accent changes — see
services/Theming.qml. This does the same thing from outside it, so that
they exist the moment the shell is installed rather than the next time it
runs, and so that a machine where the shell is not running can still have
them.

  ~/.config/fastfetch/presets/hyprshell.jsonc   a fastfetch preset
  ~/.config/hyprshell/accent                    the accent, one line of hex

The accent is resolved exactly as config/Appearance.qml resolves it, and
the preset list is read out of that file rather than copied here: a
palette in two places is a palette that will disagree with itself.
"""

import json
import os
import re
import sys


def presets_from_qml(path):
    """The accent presets, as Appearance.qml lists them."""
    src = open(path, encoding="utf-8").read()
    m = re.search(r"readonly property var accentPresets:\s*\[(.*?)\]", src, re.S)
    if not m:
        raise SystemExit("accent-files: no accentPresets in " + path)
    out = []
    for light, dark in re.findall(
            r'light:\s*"(#[0-9a-fA-F]{6})"\s*,\s*dark:\s*"(#[0-9a-fA-F]{6})"', m.group(1)):
        out.append({"light": light, "dark": dark})
    if not out:
        raise SystemExit("accent-files: accentPresets is empty in " + path)
    return out


def qml_default(path, name, kind):
    """A JsonAdapter default, for the keys theme.json may leave out."""
    src = open(path, encoding="utf-8").read()
    pattern = {
        "int": r"property int %s:\s*(-?\d+)" % name,
        "string": r'property string %s:\s*"([^"]*)"' % name,
    }[kind]
    m = re.search(pattern, src)
    if not m:
        raise SystemExit("accent-files: no default for " + name)
    return int(m.group(1)) if kind == "int" else m.group(1)


def accent_hex(theme, presets, defaults):
    index = theme.get("accent", defaults["accent"])
    if index == -1:
        return theme.get("customAccent", defaults["customAccent"])
    mode = theme.get("theme", defaults["theme"])
    # "auto" follows the system, which only the running shell can know.
    # Dark is the assumption, and the shell corrects it the moment it
    # starts — it rewrites both files on the way up.
    dark = mode != "light"
    preset = presets[max(0, min(len(presets) - 1, index))]
    return preset["dark"] if dark else preset["light"]


def preset_text(accent, ff_dir):
    """Byte for byte what services/Theming.qml writes."""
    return (
        '{\n'
        '  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",\n'
        '\n'
        '  // Written by the shell (services/Theming.qml) whenever the accent\n'
        '  // or the theme changes. Edits here are overwritten; put your own\n'
        '  // settings in config.jsonc and use --color-keys instead, with the\n'
        '  // hex in ~/.config/hyprshell/accent.\n'
        '  //\n'
        '  //   fastfetch --config ' + ff_dir + '/hyprshell.jsonc\n'
        '\n'
        '  "logo": { "type": "none" },\n'
        '  "display": {\n'
        '    "color": {\n'
        '      "keys": "' + accent + '",\n'
        '      "title": "' + accent + '"\n'
        '    },\n'
        '    "separator": ": "\n'
        '  }\n'
        '}\n'
    )


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: accent-files.py <path to Appearance.qml> [config home]")
    appearance = sys.argv[1]
    config_home = (sys.argv[2] if len(sys.argv) > 2
                   else os.environ.get("XDG_CONFIG_HOME")
                   or os.path.expanduser("~/.config"))

    presets = presets_from_qml(appearance)
    defaults = {
        "accent": qml_default(appearance, "accent", "int"),
        "customAccent": qml_default(appearance, "customAccent", "string"),
        "theme": qml_default(appearance, "theme", "string"),
    }

    theme = {}
    theme_path = os.path.join(config_home, "quickshell", "hyprshell", "theme.json")
    try:
        with open(theme_path, encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            theme = loaded
    except (OSError, ValueError):
        # No theme yet, or one that cannot be read: the defaults are the
        # right answer and are what the shell would use as well.
        pass

    accent = accent_hex(theme, presets, defaults)
    ff_dir = os.path.join(config_home, "fastfetch", "presets")
    os.makedirs(ff_dir, exist_ok=True)
    os.makedirs(os.path.join(config_home, "hyprshell"), exist_ok=True)

    with open(os.path.join(ff_dir, "hyprshell.jsonc"), "w", encoding="utf-8") as f:
        f.write(preset_text(accent, ff_dir))
    with open(os.path.join(config_home, "hyprshell", "accent"), "w", encoding="utf-8") as f:
        f.write(accent + "\n")

    print(accent)


if __name__ == "__main__":
    main()
