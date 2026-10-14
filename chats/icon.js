'use strict';
// The tray icon and the window icon, drawn here in the accent colour so they
// follow the theme like everything else, and encoded as PNG (Electron's tray
// takes no SVG on Linux). A speech bubble; with unread messages, a dot.

const zlib = require('zlib');

const CRC = new Uint32Array(256).map((_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
});
function crc32(buf) {
    let c = 0xffffffff;
    for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
    return Buffer.concat([len, td, crc]);
}
function png(w, h, rgba) {
    const raw = Buffer.alloc((w * 4 + 1) * h);
    for (let y = 0; y < h; y++) {
        raw[y * (w * 4 + 1)] = 0;
        rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
    }
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
    ihdr[8] = 8; ihdr[9] = 6; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0)),
    ]);
}

function rgb(hex) {
    const h = hex.replace('#', '');
    return [0, 2, 4].map(i => parseInt(h.slice(i, i + 2), 16));
}

// Coverage of the bubble at (x, y) in a 0..1 square: a circle with a tail
// out of its lower left, and the dot's.
function bubble(x, y) {
    const dx = x - 0.5, dy = y - 0.48;
    if (dx * dx + dy * dy <= 0.36 * 0.36) return true;
    // The tail: a triangle from inside the circle to the lower-left corner.
    const ax = 0.2, ay = 0.62, bx = 0.38, by = 0.8, cx = 0.13, cy = 0.9;
    const s = (px, py, qx, qy, rx, ry) => (px - rx) * (qy - ry) - (qx - rx) * (py - ry);
    const d1 = s(x, y, ax, ay, bx, by), d2 = s(x, y, bx, by, cx, cy), d3 = s(x, y, cx, cy, ax, ay);
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0));
}
function dot(x, y, r) {
    const dx = x - 0.78, dy = y - 0.22;
    return dx * dx + dy * dy <= r * r;
}

// `size` px square: an accent bubble with three dots on it in `onAccent`,
// and with `unread` a dot in `badge` (the bar's ink) at the top right, cut
// out of the bubble by a clear ring.
function draw(size, accent, onAccent, badge, unread) {
    const out = Buffer.alloc(size * size * 4);
    const A = rgb(accent), I = rgb(onAccent), B = rgb(badge);
    const SS = 4;
    for (let py = 0; py < size; py++) {
        for (let px = 0; px < size; px++) {
            let r = 0, g = 0, b = 0, a = 0;
            for (let sy = 0; sy < SS; sy++) {
                for (let sx = 0; sx < SS; sx++) {
                    const x = (px + (sx + 0.5) / SS) / size, y = (py + (sy + 0.5) / SS) / size;
                    let c = null;
                    if (unread && dot(x, y, 0.2)) c = dot(x, y, 0.14) ? B : null;
                    else if (bubble(x, y)) {
                        // The three dots of a message being typed.
                        const on = [0.34, 0.5, 0.66].some(cx => (x - cx) ** 2 + (y - 0.48) ** 2 <= 0.055 ** 2);
                        c = on ? I : A;
                    }
                    if (c) { r += c[0]; g += c[1]; b += c[2]; a += 1; }
                }
            }
            const o = (py * size + px) * 4;
            const n = SS * SS;
            if (a > 0) { out[o] = r / a; out[o + 1] = g / a; out[o + 2] = b / a; }
            out[o + 3] = Math.round((a / n) * 255);
        }
    }
    return png(size, size, out);
}

module.exports = { draw, png };
