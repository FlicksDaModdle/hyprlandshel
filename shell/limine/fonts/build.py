#!/usr/bin/env python3
# Builds hyprshell-boot-8x16.bin, the boot menu's font, from Terminus Bold 16
# as a Linux console font (console-setup's Uni2-TerminusBold16.psf.gz):
#
#   python3 build.py Uni2-TerminusBold16.psf.gz hyprshell-boot-8x16.bin
#
# Limine wants 256 glyphs, 8 pixels wide, one byte a row, in the order of
# the old PC character set (code page 437): its menu draws its tree with
# that set's box-drawing characters. The console font is in its own order
# with a table saying which character each glyph is, so each of the 256 is
# looked up by the character it stands for. A few Terminus does not draw
# take the nearest it does (▶ for ►), the half blocks are drawn here, and
# the rest stay blank.
import gzip, struct, sys

data = gzip.open(sys.argv[1]).read()
assert data[:2] == b'\x36\x04', "not a PSF1 font"
mode, size = data[2], data[3]
assert size == 16, "not 16 pixels tall"
n = 512 if mode & 1 else 256
glyphs = data[4:4 + n * size]
table = data[4 + n * size:]

uni = {}
i = g = 0
while g < n and i + 1 < len(table):
    (v,) = struct.unpack_from('<H', table, i)
    i += 2
    if v == 0xFFFF:
        g += 1
    elif v == 0xFFFE:            # a sequence follows; skip it
        while i + 1 < len(table) and struct.unpack_from('<H', table, i)[0] != 0xFFFF:
            i += 2
    else:
        uni.setdefault(v, g)

low = "\u0000☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼"
nearest = {"►": "▶▸", "◄": "◀◂", "▬": "▬■"}
drawn = {
    220: bytes([0] * 8 + [0xFF] * 8),    # ▄
    221: bytes([0xF0] * 16),             # ▌
    222: bytes([0x0F] * 16),             # ▐
    223: bytes([0xFF] * 8 + [0] * 8),    # ▀
}

out = bytearray()
for c in range(256):
    if c in drawn:
        out += drawn[c]
        continue
    ch = low[c] if c < 32 else ("⌂" if c == 127 else bytes([c]).decode("cp437"))
    gi = uni.get(ord(ch))
    for alt in nearest.get(ch, ""):
        if gi is None:
            gi = uni.get(ord(alt))
    out += glyphs[gi * size:(gi + 1) * size] if gi is not None else bytes(size)

open(sys.argv[2], "wb").write(out)
