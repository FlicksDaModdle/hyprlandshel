#!/usr/bin/env python3
"""The apps' own icons, as the launcher, dock and notifications show them:
the shell's tile (as Mail's and the Browser's are) with the app's glyph
from the kit's table (icons.json, extra-icons.json) in the middle.

    python3 apps/kit/tools/gen-app-icons.py      # writes apps/icons/*.svg
"""
import json
import pathlib

KIT = pathlib.Path(__file__).resolve().parent.parent
OUT = KIT.parent / "icons"

# app key → glyph; the same ones the shell's dock uses for their windows.
APPS = {
    "rog": "zap",
    "notes": "stickyNote",
    "snapshots": "rotateCw",
    "disks": "drive",
    "keys": "key",
    "docs": "file",
    "music": "music",
    "video": "film",
    "recorder": "mic",
    "chats": "chat",
    "weather": "cloudSun",
    "calendar": "calendar",
    "fonts": "font",
    "text": "doc",
    "camera": "camera",
    "software": "package",
}

INK, ACC, TILE = "#f8f4f4", "#ff563c", "#232120"

# The tile, and its accent lip along the top: Mail's, as drawn there.
LIP = ("M74.00 16.00 L67.42 16.38 L64.70 16.75 L62.63 17.12 L60.89 17.50 L59.37 17.88 L58.00 18.25 "
       "L56.75 18.62 L55.59 19.00 L54.50 19.38 L53.48 19.75 L52.52 20.12 L51.60 20.50 L50.72 20.88 "
       "L49.89 21.25 L49.08 21.62 L48.31 22.00 L47.56 22.38 L46.84 22.75 L46.15 23.12 L45.47 23.50 "
       "L44.82 23.88 L44.18 24.25 L43.57 24.62 L42.97 25.00")
LIP_WIDE = LIP + (" L213.03 25.00 L212.43 24.62 L211.82 24.25 L211.18 23.88 L210.53 23.50 L209.85 23.12 "
                  "L209.16 22.75 L208.44 22.38 L207.69 22.00 L206.92 21.62 L206.11 21.25 L205.28 20.88 "
                  "L204.40 20.50 L203.48 20.12 L202.52 19.75 L201.50 19.38 L200.41 19.00 L199.25 18.62 "
                  "L198.00 18.25 L196.63 17.88 L195.11 17.50 L193.37 17.12 L191.30 16.75 L188.58 16.38 L182.00 16.00Z")
LIP_TICK = LIP + " L100.00 25.00 L100.00 16.00Z"


def glyph(spec):
    """The glyph's parts, as the kit's icons.rs draws them."""
    out = []
    for key, colour in (("fillInk", INK), ("fill", ACC)):
        if spec.get(key):
            out.append(f'<path d="{spec[key]}" fill="{colour}" fill-rule="evenodd" stroke="none"/>')
    for key, colour, w in (("ink", INK, 1.8), ("acc", ACC, 1.8), ("inkW", INK, 2.7), ("accW", ACC, 2.7)):
        if spec.get(key):
            out.append(f'<path d="{spec[key]}" stroke="{colour}" stroke-width="{w}"/>')
    for x, y, r, acc in spec.get("dots", []):
        out.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{ACC if acc > 0.5 else INK}" stroke="none"/>')
    return "\n    ".join(out)


def main():
    table = json.loads((KIT / "icons.json").read_text())
    table.update(json.loads((KIT / "extra-icons.json").read_text()))
    OUT.mkdir(exist_ok=True)
    for key, name in APPS.items():
        spec = table[name]
        svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect x="16" y="16" width="224" height="224" rx="58" fill="{TILE}"/>
  <path d="{LIP_WIDE}" fill="{ACC}" fill-opacity="0.22"/>
  <path d="{LIP_TICK}" fill="{ACC}"/>
  <rect x="17" y="17" width="222" height="222" rx="57" fill="none" stroke="{INK}" stroke-opacity="0.16" stroke-width="2"/>
  <!-- The shell's "{name}" glyph (apps/kit, from modules/icons/IconPaths.js). -->
  <g fill="none" stroke-linecap="round" stroke-linejoin="round" transform="translate(53 53) scale(6.25)">
    {glyph(spec)}
  </g>
</svg>
'''
        (OUT / f"hyprshell-{key}.svg").write_text(svg)
        print(f"hyprshell-{key}.svg  ({name})")


main()
