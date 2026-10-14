'use strict';
// The shell's palette, and WhatsApp Web recoloured into it.
//
// The palette comes from ~/.config/quickshell/hyprshell/theme.json — the same
// file and the same rules as the shell's Appearance.qml and the Rust apps'
// kit (apps/kit/src/theme.rs), so Chats beside any of them is the same
// colours.
//
// WhatsApp's own stylesheets are not edited or replaced. Every colour in them
// is read, mapped, and the mapped value laid over the original as a
// user-origin !important rule with the same selector (main.js inserts it with
// insertCSS), so its light and dark themes, its media queries and its own
// variables all keep working, just in these colours:
//
//   greys       WhatsApp's blue-greys become the shell's warm greys, at the
//               same lightness
//   its green   becomes the accent, lighter or darker as the green was
//   the rest    (blue links, red warnings, avatars' colours) stay as they are
//
// That is done by colour, not by class or variable name, because WhatsApp's
// class names are generated and its variable names change between releases;
// what a release cannot change without changing how it looks is its colours.

const fs = require('fs');
const os = require('os');
const path = require('path');

function configDir() {
    return process.env.XDG_CONFIG_HOME || path.join(os.homedir(), '.config');
}
const THEME = path.join(configDir(), 'quickshell', 'hyprshell', 'theme.json');

// ── colours ──────────────────────────────────────────────────────────────────

function hex(s) {
    const m = /^#?([0-9a-f]{3,8})$/i.exec(String(s || '').trim());
    if (!m) return null;
    let h = m[1];
    if (h.length === 3 || h.length === 4) h = h.split('').map(c => c + c).join('');
    if (h.length !== 6 && h.length !== 8) return null;
    const v = n => parseInt(h.slice(n, n + 2), 16);
    return { r: v(0), g: v(2), b: v(4), a: h.length === 8 ? v(6) / 255 : 1 };
}

function rgbToHsl({ r, g, b }) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    const l = (max + min) / 2, c = max - min;
    let h = 0, s = 0;
    if (c > 0) {
        s = c / (1 - Math.abs(2 * l - 1));
        if (max === r) h = ((g - b) / c) % 6;
        else if (max === g) h = (b - r) / c + 2;
        else h = (r - g) / c + 4;
        h *= 60;
        if (h < 0) h += 360;
    }
    return { h, s: Math.min(1, s), l, c };
}

function hslToRgb(h, s, l) {
    const c = (1 - Math.abs(2 * l - 1)) * s;
    const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
    const m = l - c / 2;
    const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
        : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
    const k = v => Math.max(0, Math.min(255, Math.round((v + m) * 255)));
    return { r: k(r), g: k(g), b: k(b) };
}

const h2 = n => n.toString(16).padStart(2, '0');
function fmt(c) {
    if (c.a >= 1) return '#' + h2(c.r) + h2(c.g) + h2(c.b);
    return `rgba(${c.r},${c.g},${c.b},${+c.a.toFixed(3)})`;
}
function rgba(c, a) { return `rgba(${c.r},${c.g},${c.b},${a})`; }

// ── the palette ──────────────────────────────────────────────────────────────

const PRESETS = [['#ec3013', '#ff563c'], ['#ae1800', '#e8452b'], ['#2d2b2b', '#d7d3d3'], ['#7c1405', '#c94b39']];

function palette(v) {
    v = v && typeof v === 'object' ? v : {};
    const mode = v.theme || 'dark';
    const hour = new Date().getHours();
    const dark = mode === 'light' ? false : mode === 'dark' ? true : !(hour >= 7 && hour < 19);
    let accent;
    if (v.accentFromWallpaper && v.wallAccentLight && v.wallAccentDark) {
        accent = hex(dark ? v.wallAccentDark : v.wallAccentLight);
    } else if (v.accent === -1) {
        accent = hex(v.customAccent);
    } else {
        const n = Math.max(0, Math.min(PRESETS.length - 1, Number.isInteger(v.accent) ? v.accent : 0));
        accent = hex(PRESETS[n][dark ? 1 : 0]);
    }
    accent = accent || hex('#ec3013');
    const lum = (0.2126 * accent.r + 0.7152 * accent.g + 0.0722 * accent.b) / 255;
    const num = (k, d) => (typeof v[k] === 'number' ? v[k] : d);
    const rounding = num('rounding', 100) / 100;
    const ink = hex(dark ? '#f8f4f4' : '#201e1d');
    return {
        dark,
        accent: fmt(accent),
        inkOnAccent: lum > 0.6 ? '#201e1d' : '#ffffff',
        ground: dark ? '#201e1d' : '#f3f2f2',
        surface: dark ? '#2d2b2b' : '#eae9e9',
        dialog: dark ? '#252322' : '#faf9f9',
        ink: fmt(ink),
        ink2: dark ? '#bab6b6' : '#605d5d',
        ink3: dark ? '#8a8686' : '#6b6868',
        edge: rgba(ink, dark ? 0.16 : 0.14),
        rule: rgba(ink, dark ? 0.10 : 0.09),
        hover: rgba(ink, dark ? 0.09 : 0.07),
        sel: rgba(ink, dark ? 0.14 : 0.10),
        danger: dark ? '#ff6b61' : '#d42c1f',
        r: Math.round(14 * rounding),
        rSm: Math.round(9 * rounding),
        fontScale: Math.max(0.75, Math.min(1.5, num('fontScale', 100) / 100)),
    };
}

function load() {
    try { return palette(JSON.parse(fs.readFileSync(THEME, 'utf8'))); }
    catch { return palette(null); }
}

// ── mapping one colour ───────────────────────────────────────────────────────

// What the mapping needs from a palette, worked out once per palette.
function mapper(P) {
    const acc = rgbToHsl(hex(P.accent));
    const ground = rgbToHsl(hex(P.ground));
    // WhatsApp's greens between these lightnesses are its primary colour
    // (#008069, #00a884, #25d366 and their kin): those become the accent
    // itself. Darker ones are backgrounds — the dark theme's own bubbles and
    // headers — and become a muted tint of it; lighter ones, pale tints.
    const LO = 0.24, HI = 0.52;
    const cache = new Map();
    return function map(c) {
        const key = (c.r << 16) | (c.g << 8) | c.b;
        let out = cache.get(key);
        if (!out) {
            const { h, s, l, c: chroma } = rgbToHsl(c);
            if (chroma < 0.13) {
                // A grey. Same lightness, a little lifted at the dark end the
                // way the shell's own ground is, and tinted the shell's way.
                const L = l < 0.5 ? 0.045 + l * 0.91 : 0.5 + (l - 0.5) * 0.94;
                const room = 1 - Math.abs(2 * L - 1);
                const S = room > 0 ? Math.min(1, 0.012 / room) : 0;
                out = hslToRgb(ground.h, S, L);
            } else if (h >= 85 && h <= 185) {
                // Its green, as the accent.
                if (l >= LO && l <= HI) {
                    out = hslToRgb(acc.h, acc.s, acc.l);
                } else if (l < LO) {
                    out = hslToRgb(acc.h, Math.min(1, s * acc.s) * 0.5, (l / LO) * acc.l * 0.62);
                } else {
                    out = hslToRgb(acc.h, Math.min(1, s * acc.s), acc.l + ((l - HI) / (1 - HI)) * (1 - acc.l));
                }
            } else {
                out = null;
            }
            cache.set(key, out || false);
        }
        return out ? { r: out.r, g: out.g, b: out.b, a: c.a } : null;
    };
}

function parseFunc(tok) {
    const m = /^(rgba?|hsla?)\(([^()]*)\)$/i.exec(tok);
    if (!m) return null;
    const parts = m[2].trim().split(/\s*[,/]\s*|\s+/).filter(Boolean);
    if (parts.length < 3 || parts.length > 4) return null;
    const num = (p, scale) => {
        if (!/^-?[\d.]+%?$/.test(p)) return NaN;
        return p.endsWith('%') ? parseFloat(p) / 100 * scale : parseFloat(p);
    };
    const a = parts.length === 4 ? num(parts[3], 1) : 1;
    if (m[1].toLowerCase().startsWith('rgb')) {
        const [r, g, b] = parts.slice(0, 3).map(p => num(p, 255));
        if ([r, g, b, a].some(Number.isNaN)) return null;
        return { r: Math.round(r), g: Math.round(g), b: Math.round(b), a };
    }
    const h = parseFloat(parts[0]);
    const s = num(parts[1], 1), l = num(parts[2], 1);
    if ([h, s, l, a].some(Number.isNaN)) return null;
    return { ...hslToRgb(((h % 360) + 360) % 360, s, l), a };
}

const NAMED = { white: { r: 255, g: 255, b: 255, a: 1 }, black: { r: 0, g: 0, b: 0, a: 1 } };
const COLOR_RE = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?)\([^()]*\)|\b(?:white|black)\b/g;

// Every colour in a declaration's value, mapped; null when nothing changed.
function mapValue(value, map) {
    let changed = false;
    // Never inside url(…): "#abc" there is a fragment, not a colour.
    const out = value.split(/(url\([^)]*\))/i).map((part, i) => {
        if (i % 2 === 1) return part;
        return part.replace(COLOR_RE, tok => {
            const c = tok[0] === '#' ? hex(tok) : NAMED[tok.toLowerCase()] || parseFunc(tok);
            if (!c) return tok;
            const m = map(c);
            if (!m) return tok;
            changed = true;
            return fmt(m);
        });
    }).join('');
    return changed ? out : null;
}

const COLOR_PROPS = /^(?:color|background(?:-color|-image)?|border(?:-(?:top|right|bottom|left|block|inline)(?:-start|-end)?)?(?:-color)?|outline(?:-color)?|fill|stroke|box-shadow|text-shadow|caret-color|text-decoration(?:-color)?|column-rule(?:-color)?|-webkit-text-fill-color|accent-color|stop-color|flood-color|scrollbar-color)$/i;
const TRIPLET = /^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*$/;
const FONT = '"Inter"';

function mapDecl(prop, value, map) {
    const custom = prop.startsWith('--');
    if (custom) {
        // "11,20,26": a colour kept in parts for rgba(var(--x), .5).
        const t = TRIPLET.exec(value);
        if (t) {
            const m = map({ r: +t[1], g: +t[2], b: +t[3], a: 1 });
            return m ? `${m.r},${m.g},${m.b}` : null;
        }
    }
    // The shell's typeface first, theirs after it as the fallback.
    if (prop === 'font-family' || (custom && /font/i.test(prop) && /sans-serif/i.test(value))) {
        if (/mono|emoji/i.test(value) || /inter\b/i.test(value)) return null;
        return `${FONT}, ${value}`;
    }
    if (!custom && !COLOR_PROPS.test(prop)) return null;
    return mapValue(value, map);
}

// ── walking a stylesheet ─────────────────────────────────────────────────────

// Index of the `}` that closes the block opened at `open`, minding strings.
function closeOf(css, open) {
    let depth = 0;
    for (let i = open; i < css.length; i++) {
        const ch = css[i];
        if (ch === '"' || ch === "'") {
            const end = css.indexOf(ch, i + 1);
            if (end < 0) return css.length;
            i = end;
        } else if (ch === '{') depth++;
        else if (ch === '}') { if (--depth === 0) return i; }
    }
    return css.length;
}

// A block's declarations, split at `;` outside strings and brackets
// (data: URLs have semicolons in them).
function declarations(body) {
    const out = [];
    let depth = 0, start = 0;
    for (let i = 0; i <= body.length; i++) {
        const ch = body[i];
        if (ch === '"' || ch === "'") {
            const end = body.indexOf(ch, i + 1);
            if (end < 0) break;
            i = end;
        } else if (ch === '(' ) depth++;
        else if (ch === ')') depth = Math.max(0, depth - 1);
        else if ((ch === ';' && depth === 0) || i === body.length) {
            const d = body.slice(start, i);
            const colon = d.indexOf(':');
            if (colon > 0) {
                const prop = d.slice(0, colon).trim();
                const value = d.slice(colon + 1).replace(/!\s*important\s*$/i, '').trim();
                if (prop && !prop.includes('{')) out.push([prop.toLowerCase().startsWith('--') ? prop : prop.toLowerCase(), value]);
            }
            start = i + 1;
        }
    }
    return out;
}

function walk(css, map, out) {
    let i = 0;
    while (i < css.length) {
        const open = css.indexOf('{', i);
        const semi = css.indexOf(';', i);
        // A statement with no block (@import, @charset): step over it.
        if (semi >= 0 && (open < 0 || semi < open)) { i = semi + 1; continue; }
        if (open < 0) break;
        const prelude = css.slice(i, open).trim();
        const close = closeOf(css, open);
        const body = css.slice(open + 1, close);
        i = close + 1;
        if (prelude.startsWith('@')) {
            const kw = /^@[\w-]+/.exec(prelude)[0].toLowerCase();
            if (kw === '@media' || kw === '@supports' || kw === '@container' || kw === '@layer' || kw === '@scope' || kw === '@document') {
                const inner = [];
                walk(body, map, inner);
                if (inner.length === 0) continue;
                // Layers mean nothing to a user-origin sheet; the rest keep
                // their condition.
                if (kw === '@layer') out.push(...inner);
                else out.push(`${prelude}{${inner.join('')}}`);
            }
            // @font-face, @keyframes, @page: nothing to recolour.
            continue;
        }
        if (!prelude) continue;
        const changed = [];
        for (const [prop, value] of declarations(body.includes('{') ? body.slice(0, body.indexOf('{')) : body)) {
            const v = mapDecl(prop, value, map);
            if (v !== null) changed.push(`${prop}:${v} !important`);
        }
        if (changed.length) out.push(`${prelude}{${changed.join(';')}}`);
        // Nested rules (CSS nesting) are rare here and left alone.
    }
}

// The overrides for one stylesheet's text.
function recolor(css, map) {
    const out = [];
    walk(String(css).replace(/\/\*[\s\S]*?\*\//g, ''), map, out);
    return out.join('\n');
}

// What goes on top regardless of WhatsApp's own sheets: the shell's
// scrollbars, selection and focus ring.
function base(P) {
    return `
::selection { background: color-mix(in srgb, ${P.accent} 38%, transparent) !important; }
::-webkit-scrollbar { width: 10px !important; height: 10px !important; background: transparent !important; }
::-webkit-scrollbar-track { background: transparent !important; }
::-webkit-scrollbar-thumb { background: ${P.sel} !important; border-radius: 10px !important; border: 3px solid transparent !important; background-clip: content-box !important; }
::-webkit-scrollbar-thumb:hover { background: ${P.edge} !important; background-clip: content-box !important; border: 3px solid transparent !important; }
:focus-visible { outline-color: ${P.accent} !important; }
`;
}

module.exports = { THEME, load, palette, mapper, recolor, base, hex, fmt, rgbToHsl, mapValue };
