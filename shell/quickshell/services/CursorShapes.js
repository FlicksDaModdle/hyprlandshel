.pragma library

// The shell's cursor set, as SVG, for services/Cursor.qml to hand to
// hyprshell-cursors.
//
// Every shape is drawn on a 32-unit square in three passes: a soft shadow
// (the outline, offset and faint), the outline (the same shapes stroked
// wide in `line`), then the shapes filled with `fill` on top — which
// leaves one clean outline round the union of the pieces, however many
// overlap. Plain SVG only — paths, rects, circles, strokes, transforms — so
// QtSvg (the XCursor sizes) and librsvg (Hyprland's, at any size) draw it
// the same.

function svg(body) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">' + body + '</svg>';
}

// A filled shape: the union of `prims`, outlined.
function solid(prims, c, w) {
    const ow = w || 2.4;
    return '<g transform="translate(0.45 0.9)" fill="#000" fill-opacity="0.22" stroke="#000" stroke-opacity="0.22" '
         + 'stroke-width="' + (ow + 0.8) + '" stroke-linejoin="round" stroke-linecap="round">' + prims + '</g>'
         + '<g fill="' + c.line + '" stroke="' + c.line + '" stroke-width="' + ow + '" stroke-linejoin="round" '
         + 'stroke-linecap="round">' + prims + '</g>'
         + '<g fill="' + c.fill + '" stroke="none">' + prims + '</g>';
}

// Stroked lines: `thick` wide in the fill colour, outlined.
function lines(paths, c, thick) {
    const t = thick || 2;
    const ow = t + 2.6;
    return '<g transform="translate(0.45 0.9)" fill="none" stroke="#000" stroke-opacity="0.22" stroke-width="' + (ow + 0.6)
         + '" stroke-linecap="round" stroke-linejoin="round">' + paths + '</g>'
         + '<g fill="none" stroke="' + c.line + '" stroke-width="' + ow + '" stroke-linecap="round" stroke-linejoin="round">'
         + paths + '</g>'
         + '<g fill="none" stroke="' + c.fill + '" stroke-width="' + t + '" stroke-linecap="round" stroke-linejoin="round">'
         + paths + '</g>';
}

function g(transform, body) { return '<g transform="' + transform + '">' + body + '</g>'; }

const ARROW = '<path d="M6.5 3.5 L6.5 24.6 L11.7 19.8 L15.2 27.4 L18.9 25.7 L15.5 18.3 L22.4 18.3 Z"/>';
const ARROW_HOT = [6.5 / 32, 3.5 / 32];

function arrow(c) { return solid(ARROW, c, 2.4); }
// The arrow, smaller and up in the corner, leaving room for a badge.
function smallArrow(c) { return g("translate(1.2 0.7) scale(0.84)", solid(ARROW, c, 2.6)); }
const SMALL_HOT = [(1.2 + 6.5 * 0.84) / 32, (0.7 + 3.5 * 0.84) / 32];

// A round badge at the lower right, with a mark drawn in the outline colour.
function badge(c, mark) {
    return solid('<circle cx="23.5" cy="23.5" r="6.2"/>', c, 2.2)
         + '<g fill="none" stroke="' + c.line + '" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">'
         + mark + '</g>';
}

function hand(c) {
    const prims = '<rect x="11.6" y="3" width="4.4" height="16" rx="2.2"/>'
                + '<rect x="15.6" y="11.4" width="4" height="9" rx="2"/>'
                + '<rect x="19.2" y="12.4" width="3.8" height="8" rx="1.9"/>'
                + '<rect x="22.6" y="14" width="3.4" height="6.5" rx="1.7"/>'
                + '<rect x="11.6" y="15.5" width="14.4" height="12.5" rx="4.5"/>'
                + '<rect x="7" y="14.5" width="4.6" height="9" rx="2.3" transform="rotate(-38 11 21)"/>';
    return solid(prims, c, 2.3) + knuckles(c, [15.6, 19.2, 22.6], 15.2, 18.6);
}
function openHand(c) {
    const prims = '<rect x="11.2" y="5" width="3.8" height="14" rx="1.9"/>'
                + '<rect x="14.8" y="3.4" width="3.8" height="15" rx="1.9"/>'
                + '<rect x="18.4" y="4.4" width="3.6" height="14" rx="1.8"/>'
                + '<rect x="21.8" y="7" width="3.3" height="12" rx="1.65"/>'
                + '<rect x="11.2" y="14" width="13.9" height="13.5" rx="4.5"/>'
                + '<rect x="6.6" y="13.5" width="4.6" height="9" rx="2.3" transform="rotate(-38 10.6 20)"/>';
    return solid(prims, c, 2.3) + knuckles(c, [14.8, 18.4, 21.8], 9, 15.5);
}
function fist(c) {
    const prims = '<rect x="11.2" y="10.5" width="3.8" height="8" rx="1.9"/>'
                + '<rect x="14.8" y="10" width="3.8" height="8.5" rx="1.9"/>'
                + '<rect x="18.4" y="10.5" width="3.6" height="8" rx="1.8"/>'
                + '<rect x="21.8" y="11.5" width="3.3" height="7" rx="1.65"/>'
                + '<rect x="11.2" y="14" width="13.9" height="13" rx="4.5"/>'
                + '<rect x="8.4" y="16.4" width="9" height="4.2" rx="2.1"/>';
    return solid(prims, c, 2.3) + knuckles(c, [14.8, 18.4, 21.8], 12, 15.5);
}
// The lines between fingers, a shade darker than the fill.
function knuckles(c, xs, y0, y1) {
    let d = "";
    for (const x of xs) d += "M" + x + " " + y0 + " V" + y1 + " ";
    return '<path d="' + d + '" fill="none" stroke="#000" stroke-opacity="0.28" stroke-width="0.8" stroke-linecap="round"/>';
}

const IBEAM = '<path d="M12.3 6.2 C14.6 6.2 16 7 16 9.2 V22.8 C16 25 14.6 25.8 12.3 25.8 '
            + 'M19.7 6.2 C17.4 6.2 16 7 16 9.2 M19.7 25.8 C17.4 25.8 16 25 16 22.8"/>';

// A ring with a turning arc, frame `f` of `n`.
function spinner(c, cx, cy, r, w, f, n) {
    const a0 = (f / n) * Math.PI * 2 - Math.PI / 2;
    const a1 = a0 + Math.PI * 0.62;
    const x0 = (cx + r * Math.cos(a0)).toFixed(2), y0 = (cy + r * Math.sin(a0)).toFixed(2);
    const x1 = (cx + r * Math.cos(a1)).toFixed(2), y1 = (cy + r * Math.sin(a1)).toFixed(2);
    return '<circle cx="' + (cx + 0.45) + '" cy="' + (cy + 0.9) + '" r="' + r + '" fill="none" stroke="#000" stroke-opacity="0.22" stroke-width="' + (w + 3.2) + '"/>'
         + '<circle cx="' + cx + '" cy="' + cy + '" r="' + r + '" fill="none" stroke="' + c.line + '" stroke-width="' + (w + 2.6) + '"/>'
         + '<circle cx="' + cx + '" cy="' + cy + '" r="' + r + '" fill="none" stroke="' + c.fill + '" stroke-opacity="0.35" stroke-width="' + w + '"/>'
         + '<path d="M' + x0 + ' ' + y0 + ' A' + r + ' ' + r + ' 0 0 1 ' + x1 + ' ' + y1 + '" fill="none" stroke="'
         + c.fill + '" stroke-width="' + w + '" stroke-linecap="round"/>';
}

const DOUBLE = '<path d="M16 3 L22.2 10.2 L18.1 10.2 L18.1 21.8 L22.2 21.8 L16 29 L9.8 21.8 L13.9 21.8 L13.9 10.2 L9.8 10.2 Z"/>';
const SPLIT = '<path d="M3 16 L9.2 10 L9.2 13.7 L13 13.7 L13 18.3 L9.2 18.3 L9.2 22 Z"/>'
            + '<path d="M29 16 L22.8 10 L22.8 13.7 L19 13.7 L19 18.3 L22.8 18.3 L22.8 22 Z"/>'
            + '<rect x="14.6" y="5.5" width="2.8" height="21" rx="1.2"/>';
const FOUR = '<path d="M16 2.8 L20.8 8.2 L17.5 8.2 L17.5 14.5 L23.8 14.5 L23.8 11.2 L29.2 16 L23.8 20.8 L23.8 17.5 '
           + 'L17.5 17.5 L17.5 23.8 L20.8 23.8 L16 29.2 L11.2 23.8 L14.5 23.8 L14.5 17.5 L8.2 17.5 L8.2 20.8 L2.8 16 '
           + 'L8.2 11.2 L8.2 14.5 L14.5 14.5 L14.5 8.2 L11.2 8.2 Z"/>';

function magnifier(c, plus) {
    return lines('<circle cx="13.5" cy="13.5" r="7.5"/><path d="M19.2 19.2 L26.5 26.5"/>', c, 2.6)
         + '<g fill="none" stroke="' + c.fill + '" stroke-width="2" stroke-linecap="round">'
         + '<path d="M10 13.5 H17' + (plus ? ' M13.5 10 V17' : '') + '"/></g>';
}

const CENTER = [0.5, 0.5];

// [{ name, aliases, hot, delay, frames }], in `fill` with a `line` outline.
function shapes(fill, line) {
    const c = { fill: fill, line: line };
    const spinFrames = [], progFrames = [];
    for (let f = 0; f < 12; f++) {
        spinFrames.push(svg(spinner(c, 16, 16, 8.5, 3, f, 12)));
        progFrames.push(svg(arrow(c) + spinner(c, 24, 24, 4.4, 2.2, f, 12)));
    }
    return [
        { name: "default", hot: ARROW_HOT, frames: [svg(arrow(c))],
          aliases: ["left_ptr", "arrow", "top_left_arrow", "left_arrow"] },
        { name: "pointer", hot: [13.8 / 32, 3 / 32], frames: [svg(hand(c))],
          aliases: ["hand", "hand1", "hand2", "pointing_hand",
                    "9d800788f1b08800ae810202380a0822", "e29285e634086352946a0e7090d73106"] },
        { name: "text", hot: CENTER, frames: [svg(lines(IBEAM, c, 1.9))], aliases: ["xterm", "ibeam"] },
        { name: "vertical-text", hot: CENTER, frames: [svg(g("rotate(90 16 16)", lines(IBEAM, c, 1.9)))], aliases: [] },
        { name: "wait", hot: CENTER, delay: 60, frames: spinFrames, aliases: ["watch"] },
        { name: "progress", hot: ARROW_HOT, delay: 60, frames: progFrames,
          aliases: ["left_ptr_watch", "half-busy",
                    "08e8e1c95fe2fc01f976f1e063a24ccd", "3ecb610c1bf2410f44200f48c40d3599"] },
        { name: "crosshair", hot: CENTER,
          frames: [svg(lines('<path d="M16 4 V12 M16 20 V28 M4 16 H12 M20 16 H28"/>', c, 1.8)
                       + solid('<circle cx="16" cy="16" r="1.4"/>', c, 1.8))],
          aliases: ["cross", "tcross", "cross_reverse", "diamond_cross"] },
        { name: "cell", hot: CENTER,
          frames: [svg(solid('<rect x="12.8" y="5" width="6.4" height="22" rx="1.6"/>'
                             + '<rect x="5" y="12.8" width="22" height="6.4" rx="1.6"/>', c, 2.2))],
          aliases: ["plus"] },
        { name: "move", hot: CENTER, frames: [svg(solid(FOUR, c, 2.2))],
          aliases: ["fleur", "size_all", "all-scroll", "dnd-move",
                    "4498f0e0c1937ffe01fd06f973665830", "9081237383d90e509aa00f00170e968f"] },
        { name: "grab", hot: CENTER, frames: [svg(openHand(c))],
          aliases: ["openhand", "5aca4d189052212118709018842178c0", "9141b49c8149039304290b508d208c40"] },
        { name: "grabbing", hot: CENTER, frames: [svg(fist(c))],
          aliases: ["closedhand", "dnd-none", "208530c400c041818281048008011002", "fcf21c00b30f7e3f83fe0dfd12e71cff"] },
        { name: "ns-resize", hot: CENTER, frames: [svg(solid(DOUBLE, c, 2.2))],
          aliases: ["n-resize", "s-resize", "top_side", "bottom_side", "sb_v_double_arrow", "v_double_arrow",
                    "size_ver", "00008160000006810000408080010102"] },
        { name: "ew-resize", hot: CENTER, frames: [svg(g("rotate(90 16 16)", solid(DOUBLE, c, 2.2)))],
          aliases: ["e-resize", "w-resize", "left_side", "right_side", "sb_h_double_arrow", "h_double_arrow",
                    "size_hor", "028006030e0e7ebffc7f7070c0600140"] },
        { name: "nwse-resize", hot: CENTER, frames: [svg(g("rotate(-45 16 16)", solid(DOUBLE, c, 2.2)))],
          aliases: ["nw-resize", "se-resize", "top_left_corner", "bottom_right_corner", "bd_double_arrow",
                    "size_fdiag", "c7088f0f3e6c8088236ef8e1e3e70000"] },
        { name: "nesw-resize", hot: CENTER, frames: [svg(g("rotate(45 16 16)", solid(DOUBLE, c, 2.2)))],
          aliases: ["ne-resize", "sw-resize", "top_right_corner", "bottom_left_corner", "fd_double_arrow",
                    "size_bdiag", "fcf1c3c7cd4491d801f1e1c78f100000"] },
        { name: "col-resize", hot: CENTER, frames: [svg(solid(SPLIT, c, 2.2))],
          aliases: ["split_h", "14fef782d02440884392942c11205230"] },
        { name: "row-resize", hot: CENTER, frames: [svg(g("rotate(90 16 16)", solid(SPLIT, c, 2.2)))],
          aliases: ["split_v", "2870a09082c103050810ffdffffe0204"] },
        { name: "not-allowed", hot: CENTER,
          frames: [svg(lines('<circle cx="16" cy="16" r="9"/><path d="M9.8 9.8 L22.2 22.2"/>', c, 3))],
          aliases: ["crossed_circle", "forbidden", "circle", "03b6e0fcb3499374a867c041f52298f0"] },
        { name: "no-drop", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, '<circle cx="23.5" cy="23.5" r="3.2"/><path d="M21.3 21.3 L25.7 25.7"/>'))],
          aliases: ["dnd-no-drop"] },
        { name: "help", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, '<path d="M21.6 22 C21.6 20.5 22.6 19.8 23.6 19.8 C24.8 19.8 25.6 20.6 25.6 21.6 '
                                                + 'C25.6 23 23.6 23.2 23.6 24.8"/><path d="M23.6 27.2 V27.3"/>'))],
          aliases: ["question_arrow", "whats_this", "left_ptr_help",
                    "d9ce0ab605698f320427677b458ad60b", "5c6cd98b3f3ebcb1f9c7f1c204630408"] },
        { name: "copy", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, '<path d="M23.5 20.3 V26.7 M20.3 23.5 H26.7"/>'))],
          aliases: ["dnd-copy", "1081e37283d90000800003c07f3ef6bf", "6407b0e94181790501fd1e167b474872",
                    "b66166c04f8c3109214a4fbd64a50fc8"] },
        { name: "alias", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, '<path d="M20.8 26.2 L26.2 20.8 M22.4 20.8 H26.2 V24.6"/>'))],
          aliases: ["dnd-link", "link", "640fb0e74195791501fd1ed57b41487f", "3085a0e285430894940527032f8b26df",
                    "a2a266d0498c3104214a47bd64ab0fc8"] },
        { name: "context-menu", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, '<path d="M20.6 21.4 H26.4 M20.6 23.5 H26.4 M20.6 25.6 H26.4"/>'))],
          aliases: [] },
        { name: "zoom-in", hot: [13.5 / 32, 13.5 / 32], frames: [svg(magnifier(c, true))], aliases: [] },
        { name: "zoom-out", hot: [13.5 / 32, 13.5 / 32], frames: [svg(magnifier(c, false))], aliases: [] }
    ];
}
