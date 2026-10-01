.pragma library

// The shell's cursor set, drawn the way the app icons are (modules/icons/
// IconPaths.js): on a 24-unit grid, in 2px monoline with round caps and
// joins, ink for the drawing and exactly one accent element — the arrow's
// tail, an arrowhead pair, a badge's mark, the spinner's arc.
//
// A cursor has to stand out on anything, where an icon sits on a tile, so
// each shape carries its tile with it: the body filled in the surface
// colour, and a halo of the same colour round every line, wider than the
// line, so the ink is framed on both sides whatever is underneath. Then a
// faint shadow, for depth on a background of the body's own colour.
//
// Plain SVG only (paths, circles, strokes, transforms) so QtSvg — the
// XCursor sizes — and librsvg — Hyprland's, at any size — draw it alike.
// Authored at 24 and scaled into the 32-unit square the theme uses, so the
// line is 2px at the usual 24px cursor size, as an icon's is at 24.

const S = 32 / 24;

function svg(body) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">'
         + '<g transform="scale(' + S + ')">' + body + '</g></svg>';
}

// A shape as the icon pack spells one: { fill, ink, acc, dots }, each path
// data (dots are [{ cx, cy, r, c: "ink" | "acc" | "base" }]).
function draw(g, c) {
    const fill = g.fill || "", ink = g.ink || "", acc = g.acc || "";
    const lines = [ink, acc].filter(p => p).join(" ");
    const all = [fill, lines].filter(p => p).join(" ");
    const dots = g.dots || [];
    let out = "";
    // shadow
    out += '<g transform="translate(0.35 0.7)" fill="#000" fill-opacity="0.2" stroke="#000" stroke-opacity="0.2" '
         + 'stroke-width="5" stroke-linecap="round" stroke-linejoin="round">'
         + (fill ? '<path d="' + fill + '"/>' : '')
         + (lines ? '<path d="' + lines + '" fill="none"/>' : '')
         + dots.map(d => '<circle cx="' + d.cx + '" cy="' + d.cy + '" r="' + d.r + '"/>').join("")
         + '</g>';
    // the tile: halo round everything, and the body filled
    out += '<g stroke="' + c.base + '" stroke-width="4.6" stroke-linecap="round" stroke-linejoin="round">'
         + (fill ? '<path d="' + fill + '" fill="' + c.base + '"/>' : '')
         + (lines ? '<path d="' + lines + '" fill="none"/>' : '')
         + dots.map(d => '<circle cx="' + d.cx + '" cy="' + d.cy + '" r="' + d.r + '" fill="' + c.base + '"/>').join("")
         + '</g>';
    // the drawing
    if (fill) out += '<path d="' + fill + '" fill="none" stroke="' + c.ink + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>';
    if (ink) out += '<path d="' + ink + '" fill="none" stroke="' + c.ink + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>';
    if (acc) out += '<path d="' + acc + '" fill="none" stroke="' + c.acc + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>';
    for (const d of dots)
        out += '<circle cx="' + d.cx + '" cy="' + d.cy + '" r="' + d.r + '" fill="'
             + (d.c === "acc" ? c.acc : d.c === "base" ? c.base : c.ink) + '"/>';
    return out;
}

function circle(cx, cy, r) {
    return "M" + (cx - r) + " " + cy + "A" + r + " " + r + " 0 1 0 " + (cx + r) + " " + cy
         + "A" + r + " " + r + " 0 1 0 " + (cx - r) + " " + cy + "Z";
}
function g(transform, body) { return '<g transform="' + transform + '">' + body + '</g>'; }

// The icon pack's own `cursor` glyph, with its tail picked out in accent.
const ARROW = "M6 3 L6 17.5 L9.6 14.2 L12 19.8 L14.4 18.8 L12 13.4 L17.5 12.8 Z";
const ARROW_HOT = [6 / 24, 3 / 24];
function arrow(c) {
    return draw({ fill: ARROW, acc: "M9.6 14.2 L12 19.8 L14.4 18.8 L12 13.4" }, c);
}
// Smaller, in the corner, leaving room for a badge; the badge's mark is
// the accent then, so the arrow is plain ink.
const SMALL = "translate(0.6 0.2) scale(0.82)";
const SMALL_HOT = [(0.6 + 6 * 0.82) / 24, (0.2 + 3 * 0.82) / 24];
function smallArrow(c) { return g(SMALL, draw({ fill: ARROW }, c)); }
function badge(c, mark, dots) {
    return draw({ fill: circle(17.5, 17.5, 4.6), acc: mark, dots: dots || [] }, c);
}

// A pointing hand: the index finger up, three folded behind it, the thumb
// along the side — one outline, as the icons' shapes are.
const HAND = "M9.2 12.2 V4.6 A1.55 1.55 0 0 1 12.3 4.6 V10.6 "
           + "A1.5 1.5 0 0 1 15.3 10.6 V11.3 A1.5 1.5 0 0 1 18.3 11.3 V12 A1.45 1.45 0 0 1 21.2 12 "
           + "V15.6 A5.6 5.6 0 0 1 15.6 21.2 H13.4 A5 5 0 0 1 9.4 19.2 L5.6 14.6 "
           + "A1.55 1.55 0 0 1 7.9 12.5 L9.2 13.9 Z";
function hand(c) {
    return draw({ fill: HAND, ink: "M12.3 10.6 V13 M15.3 11.3 V13 M18.3 12 V13.4",
                  acc: "M10.75 4.2 V6.2" }, c);
}
const OPEN_HAND = "M8.6 12.6 V6.6 A1.45 1.45 0 0 1 11.5 6.6 V11.2 V4.8 A1.45 1.45 0 0 1 14.4 4.8 V11.2 "
                + "V5.8 A1.45 1.45 0 0 1 17.3 5.8 V11.6 V8.2 A1.4 1.4 0 0 1 20.1 8.2 V15.4 "
                + "A5.8 5.8 0 0 1 14.3 21.2 H13.2 A5 5 0 0 1 9.2 19.2 L5.2 14.2 "
                + "A1.5 1.5 0 0 1 7.4 12.2 L8.6 13.4 Z";
function openHand(c) {
    return draw({ fill: OPEN_HAND, ink: "M11.5 11.2 V12.6 M14.4 11.2 V12.6 M17.3 11.6 V12.8",
                  acc: "M9.2 20 H15" }, c);
}
const FIST = "M8.6 13 V10.4 A1.45 1.45 0 0 1 11.5 10.4 V9.4 A1.45 1.45 0 0 1 14.4 9.4 V9.8 "
           + "A1.45 1.45 0 0 1 17.3 9.8 V10.4 A1.4 1.4 0 0 1 20.1 10.4 V15.4 "
           + "A5.8 5.8 0 0 1 14.3 21.2 H13.2 A5 5 0 0 1 9.2 19.2 L7.2 16.4 A1.5 1.5 0 0 1 8.6 14.2 Z";
function fist(c) {
    return draw({ fill: FIST, ink: "M11.5 10.4 V12.6 M14.4 9.8 V12.6 M17.3 10.4 V12.6",
                  acc: "M9.2 20 H15" }, c);
}

const IBEAM = "M9 4.5 C10.8 4.5 12 5.2 12 7 V17 C12 18.8 10.8 19.5 9 19.5 "
            + "M15 4.5 C13.2 4.5 12 5.2 12 7 M15 19.5 C13.2 19.5 12 18.8 12 17";
function ibeam(c) { return draw({ ink: IBEAM, acc: "M10.2 12 H13.8" }, c); }

// A ring with an accent arc turning round it, frame f of n.
function spinnerParts(cx, cy, r, f, n) {
    const a0 = (f / n) * Math.PI * 2 - Math.PI / 2;
    const a1 = a0 + Math.PI * 0.6;
    const p = a => [(cx + r * Math.cos(a)).toFixed(2), (cy + r * Math.sin(a)).toFixed(2)];
    const s = p(a0), e = p(a1);
    return { ring: circle(cx, cy, r), arc: "M" + s[0] + " " + s[1] + " A" + r + " " + r + " 0 0 1 " + e[0] + " " + e[1] };
}
function spinner(c, f, n) {
    const sp = spinnerParts(12, 12, 7, f, n);
    return draw({ fill: sp.ring, acc: sp.arc }, c);
}
function progress(c, f, n) {
    const sp = spinnerParts(17.6, 17.6, 3.6, f, n);
    return g(SMALL, draw({ fill: ARROW }, c)) + draw({ fill: sp.ring, acc: sp.arc }, c);
}

// Double arrows: the shaft in ink, the heads — the part that says which
// way — in accent.
const NS = { ink: "M12 4.5 V19.5", acc: "M8.6 7.9 L12 4.5 L15.4 7.9 M8.6 16.1 L12 19.5 L15.4 16.1" };
const SPLIT = { ink: "M12 4 V20 M4.5 12 H9.5 M14.5 12 H19.5",
                acc: "M6.8 9.7 L4.5 12 L6.8 14.3 M17.2 9.7 L19.5 12 L17.2 14.3" };
const MOVE = { ink: "M12 4.5 V19.5 M4.5 12 H19.5",
               acc: "M9.8 6.7 L12 4.5 L14.2 6.7 M9.8 17.3 L12 19.5 L14.2 17.3 M6.7 9.8 L4.5 12 L6.7 14.2 M17.3 9.8 L19.5 12 L17.3 14.2" };

function magnifier(c, plus) {
    return draw({ fill: circle(10.5, 10.5, 6), ink: "M15 15 L19.5 19.5",
                  acc: "M8 10.5 H13" + (plus ? " M10.5 8 V13" : "") }, c);
}

const CENTER = [0.5, 0.5];

// [{ name, aliases, hot, delay, frames }], with { base, ink, acc } colours:
// base the body and halo, ink the drawing, acc the accent element.
function shapes(base, ink, acc) {
    const c = { base: base, ink: ink, acc: acc };
    const spinFrames = [], progFrames = [];
    for (let f = 0; f < 12; f++) {
        spinFrames.push(svg(spinner(c, f, 12)));
        progFrames.push(svg(progress(c, f, 12)));
    }
    return [
        { name: "default", hot: ARROW_HOT, frames: [svg(arrow(c))],
          aliases: ["left_ptr", "arrow", "top_left_arrow", "left_arrow"] },
        { name: "pointer", hot: [10.75 / 24, 3.2 / 24], frames: [svg(hand(c))],
          aliases: ["hand", "hand1", "hand2", "pointing_hand",
                    "9d800788f1b08800ae810202380a0822", "e29285e634086352946a0e7090d73106"] },
        { name: "text", hot: CENTER, frames: [svg(ibeam(c))], aliases: ["xterm", "ibeam"] },
        { name: "vertical-text", hot: CENTER, frames: [svg(g("rotate(90 12 12)", ibeam(c)))], aliases: [] },
        { name: "wait", hot: CENTER, delay: 60, frames: spinFrames, aliases: ["watch"] },
        { name: "progress", hot: SMALL_HOT, delay: 60, frames: progFrames,
          aliases: ["left_ptr_watch", "half-busy",
                    "08e8e1c95fe2fc01f976f1e063a24ccd", "3ecb610c1bf2410f44200f48c40d3599"] },
        { name: "crosshair", hot: CENTER,
          frames: [svg(draw({ ink: "M12 4 V9.5 M12 14.5 V20 M4 12 H9.5 M14.5 12 H20",
                              dots: [{ cx: 12, cy: 12, r: 1.2, c: "acc" }] }, c))],
          aliases: ["cross", "tcross", "cross_reverse", "diamond_cross"] },
        { name: "cell", hot: CENTER,
          frames: [svg(draw({ ink: "M12 5 V19 M5 12 H19", dots: [{ cx: 12, cy: 12, r: 2, c: "acc" }] }, c))],
          aliases: ["plus"] },
        { name: "move", hot: CENTER, frames: [svg(draw(MOVE, c))],
          aliases: ["fleur", "size_all", "all-scroll", "dnd-move",
                    "4498f0e0c1937ffe01fd06f973665830", "9081237383d90e509aa00f00170e968f"] },
        { name: "grab", hot: CENTER, frames: [svg(openHand(c))],
          aliases: ["openhand", "5aca4d189052212118709018842178c0", "9141b49c8149039304290b508d208c40"] },
        { name: "grabbing", hot: CENTER, frames: [svg(fist(c))],
          aliases: ["closedhand", "dnd-none", "208530c400c041818281048008011002", "fcf21c00b30f7e3f83fe0dfd12e71cff"] },
        { name: "ns-resize", hot: CENTER, frames: [svg(draw(NS, c))],
          aliases: ["n-resize", "s-resize", "top_side", "bottom_side", "sb_v_double_arrow", "v_double_arrow",
                    "size_ver", "00008160000006810000408080010102"] },
        { name: "ew-resize", hot: CENTER, frames: [svg(g("rotate(90 12 12)", draw(NS, c)))],
          aliases: ["e-resize", "w-resize", "left_side", "right_side", "sb_h_double_arrow", "h_double_arrow",
                    "size_hor", "028006030e0e7ebffc7f7070c0600140"] },
        { name: "nwse-resize", hot: CENTER, frames: [svg(g("rotate(-45 12 12)", draw(NS, c)))],
          aliases: ["nw-resize", "se-resize", "top_left_corner", "bottom_right_corner", "bd_double_arrow",
                    "size_fdiag", "c7088f0f3e6c8088236ef8e1e3e70000"] },
        { name: "nesw-resize", hot: CENTER, frames: [svg(g("rotate(45 12 12)", draw(NS, c)))],
          aliases: ["ne-resize", "sw-resize", "top_right_corner", "bottom_left_corner", "fd_double_arrow",
                    "size_bdiag", "fcf1c3c7cd4491d801f1e1c78f100000"] },
        { name: "col-resize", hot: CENTER, frames: [svg(draw(SPLIT, c))],
          aliases: ["split_h", "14fef782d02440884392942c11205230"] },
        { name: "row-resize", hot: CENTER, frames: [svg(g("rotate(90 12 12)", draw(SPLIT, c)))],
          aliases: ["split_v", "2870a09082c103050810ffdffffe0204"] },
        { name: "not-allowed", hot: CENTER,
          frames: [svg(draw({ fill: circle(12, 12, 7), acc: "M7.1 7.1 L16.9 16.9" }, c))],
          aliases: ["crossed_circle", "forbidden", "circle", "03b6e0fcb3499374a867c041f52298f0"] },
        { name: "no-drop", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M15.4 15.4 L19.6 19.6"))],
          aliases: ["dnd-no-drop"] },
        { name: "help", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M16 16.6 A1.55 1.55 0 1 1 18.4 17.9 C17.7 18.3 17.5 18.6 17.5 19.1",
                                              [{ cx: 17.5, cy: 20.7, r: 0.75, c: "acc" }]))],
          aliases: ["question_arrow", "whats_this", "left_ptr_help",
                    "d9ce0ab605698f320427677b458ad60b", "5c6cd98b3f3ebcb1f9c7f1c204630408"] },
        { name: "copy", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M17.5 15.4 V19.6 M15.4 17.5 H19.6"))],
          aliases: ["dnd-copy", "1081e37283d90000800003c07f3ef6bf", "6407b0e94181790501fd1e167b474872",
                    "b66166c04f8c3109214a4fbd64a50fc8"] },
        { name: "alias", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M15.6 19.4 L19.2 15.8 M16.6 15.6 H19.4 V18.4"))],
          aliases: ["dnd-link", "link", "640fb0e74195791501fd1ed57b41487f", "3085a0e285430894940527032f8b26df",
                    "a2a266d0498c3104214a47bd64ab0fc8"] },
        { name: "context-menu", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M15.6 16.2 H19.4 M15.6 18.8 H19.4"))],
          aliases: [] },
        { name: "zoom-in", hot: [10.5 / 24, 10.5 / 24], frames: [svg(magnifier(c, true))], aliases: [] },
        { name: "zoom-out", hot: [10.5 / 24, 10.5 / 24], frames: [svg(magnifier(c, false))], aliases: [] }
    ];
}
