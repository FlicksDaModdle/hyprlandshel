#!/usr/bin/env python3
"""What each connected display says it can do, from its own EDID.

    edid-caps.py     JSON: { "eDP-1": { "bt2020": true, "pq": true, ... } }

For Settings → Display, which offers wide gamut, HDR and 10-bit from this.
Hyprland's own report of an output doesn't say (hyprctl has no field for
it), and Hyprland reads only the CTA-861 extension; many laptop panels —
OLEDs especially — say it in a DisplayID extension instead, which is why
Windows drives them in HDR while Hyprland says they can't. Both are read
here, so Settings can tell Hyprland what the panel really is.

Read from /sys/class/drm, which anyone may read; nothing is changed.

    bt2020   BT.2020 colorimetry (wide gamut)
    pq       HDR: the SMPTE ST 2084 (PQ) transfer function
    hlg      HDR: hybrid log-gamma
    maxLum, maxAvgLum, minLum   in cd/m² (nits), when it says
    bits     the panel's colour depth per channel, when it says
    via      where HDR was found: "cta", "displayid" or ""
"""

import glob
import json
import os


def cta_blocks(data):
    """The data blocks of CTA-861 data in `data` (tag, payload) — a CTA
    extension's own, or the ones a DisplayID block carries."""
    i = 0
    while i < len(data):
        head = data[i]
        tag, size = head >> 5, head & 0x1F
        payload = data[i + 1:i + 1 + size]
        if len(payload) < size:
            break
        yield tag, payload
        i += 1 + size


def read_cta(blocks, out, via):
    for tag, payload in blocks:
        if tag != 7 or not payload:
            continue
        ext, body = payload[0], payload[1:]
        if ext == 5 and body:
            # Colorimetry: BT2020 RGB, YCC or cYCC.
            if body[0] & 0xE0:
                out["bt2020"] = True
        elif ext == 6 and body:
            # HDR static metadata: transfer functions, then luminance.
            eotf = body[0]
            if eotf & 0x04:
                out["pq"] = True
                out["via"] = out.get("via") or via
            if eotf & 0x08:
                out["hlg"] = True
            if len(body) >= 3 and body[2]:
                out.setdefault("maxLum", round(50 * 2 ** (body[2] / 32)))
            if len(body) >= 4 and body[3]:
                out.setdefault("maxAvgLum", round(50 * 2 ** (body[3] / 32)))
            if len(body) >= 5 and body[4] and len(body) >= 3 and body[2]:
                top = 50 * 2 ** (body[2] / 32)
                out.setdefault("minLum", round(top * (body[4] / 255) ** 2 / 100, 4))


def half(b0, b1):
    """An IEEE half-precision float, little-endian, as DisplayID 2 keeps
    luminance."""
    v = b0 | (b1 << 8)
    exp, frac = (v >> 10) & 0x1F, v & 0x3FF
    if exp == 0:
        return frac * 2 ** -24
    if exp == 31:
        return 0.0
    return (1 + frac / 1024) * 2 ** (exp - 15)


def read_displayid(ext, out):
    # The section: version, payload length, product type, extension count,
    # then data blocks of tag, revision, length, payload.
    if len(ext) < 6:
        return
    length = ext[2]
    i, end = 5, min(len(ext) - 1, 5 + length)
    while i + 3 <= end:
        tag, size = ext[i], ext[i + 2]
        payload = ext[i + 3:i + 3 + size]
        if tag == 0 and size == 0:
            break
        if tag == 0x81:
            # CTA-861 data blocks inside DisplayID: where panels put HDR.
            read_cta(cta_blocks(payload), out, "displayid")
        elif tag == 0x21 and len(payload) >= 29:
            # Display parameters: luminance (half floats) and colour depth.
            full = half(payload[21], payload[22])
            if full > 0:
                out.setdefault("maxLum", round(full))
            peak = half(payload[23], payload[24])
            if peak > 0:
                out.setdefault("maxAvgLum", round(min(full, peak) if full > 0 else peak))
            low = half(payload[25], payload[26])
            if low > 0:
                out.setdefault("minLum", round(low, 4))
            depth = payload[27] & 0x07
            if depth:
                out.setdefault("bits", {1: 6, 2: 8, 3: 10, 4: 12, 5: 14, 6: 16}.get(depth, 0) or None)
        i += 3 + size


def caps(edid):
    out = {}
    if len(edid) < 128:
        return out
    # Base block: the bit depth a digital input says it takes.
    if edid[20] & 0x80:
        depth = (edid[20] >> 4) & 0x07
        bits = {1: 6, 2: 8, 3: 10, 4: 12, 5: 14, 6: 16}.get(depth)
        if bits:
            out["bits"] = bits
    for n in range(1, len(edid) // 128):
        ext = edid[n * 128:(n + 1) * 128]
        if ext[0] == 0x02 and len(ext) > 4:
            d = ext[2]
            if 4 <= d <= 127:
                read_cta(cta_blocks(ext[4:d]), out, "cta")
        elif ext[0] == 0x70:
            read_displayid(ext, out)
    out.setdefault("via", "")
    for k in ("bt2020", "pq", "hlg"):
        out.setdefault(k, False)
    return out


def main():
    result = {}
    for path in sorted(glob.glob("/sys/class/drm/card*-*")):
        name = os.path.basename(path).split("-", 1)[1]
        try:
            with open(os.path.join(path, "status")) as f:
                if f.read().strip() != "connected":
                    continue
            with open(os.path.join(path, "edid"), "rb") as f:
                edid = f.read()
        except OSError:
            continue
        if edid:
            result[name] = caps(edid)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
