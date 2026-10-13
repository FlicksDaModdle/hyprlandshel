.pragma library

// The shell's cursor set.
//
// Drawn the way a system pointer is, not the way an icon is: each shape is
// a solid silhouette — the body — inside a crisp, thin outline, over a soft
// shadow. Dark is a near-black body with a white outline (macOS); light is
// a white body with a dark outline (Windows); either reads on anything,
// because the outline frames the body against whatever is underneath.
//
// The accent runs round every shape as a fine keyline, between the body
// and the outline — dark body, a thread of accent, then the white edge —
// so the pointer is unmistakably the shell's without being loud about it.
// It is the whole colour of the busy ring's turning arc and of the badge
// on copy, link and the rest.
//
// Plain SVG only — paths, circles, strokes, transforms, opacity, no filters
// — so every renderer draws it alike: resvg (hyprshell-cursors, the XCursor
// sizes), librsvg (Hyprland, any size) and QtSvg (the fallback builder).
// The shadow is a few stacked strokes of falling opacity rather than a
// blur filter, for the same reason.
//
// Authored on a 24-unit grid and scaled into the theme's 32-unit square,
// so the outline is about 1.4px at the usual 24px size.

const S = 32 / 24;

function svg(body) {
    return '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">'
         + '<g transform="scale(' + S + ')">' + body + '</g></svg>';
}

const OUTLINE = 1.3;
// The accent keyline, between the body and the outline.
const RIM = 0.65;

// A shadow under some geometry: offset down a little, built from widening
// strokes that fade, which reads as a soft edge at cursor sizes.
function shadow(fills, lines, lineWidth) {
    let out = '<g transform="translate(0 0.9)" stroke-linecap="round" stroke-linejoin="round">';
    const layers = [[3.4, 0.05], [2.4, 0.07], [1.4, 0.1]];
    for (const [w, o] of layers) {
        out += '<g stroke="#000" stroke-opacity="' + o + '" fill="none">';
        for (const f of fills) out += '<path d="' + f + '" stroke-width="' + (OUTLINE + RIM + w) + '"/>';
        for (const l of lines) out += '<path d="' + l + '" stroke-width="' + (lineWidth + 2 * OUTLINE + w) + '"/>';
        out += '</g>';
    }
    out += '<g fill="#000" fill-opacity="0.18" fill-rule="evenodd">';
    for (const f of fills) out += '<path d="' + f + '"/>';
    out += '</g></g>';
    return out;
}

// A shape: { fills: [path], lines: [path], lineWidth, details: [path],
// accent: [path] (lines in the accent), accentFill: [path] }.
//   fills    solid areas: body colour, outlined
//   lines    strokes drawn as the body, outlined (an I-beam, a crosshair)
//   details  thin outline-coloured strokes on top of the body (the gaps
//            between fingers)
function draw(sh, c) {
    const fills = sh.fills || [], lines = sh.lines || [], details = sh.details || [];
    const lw = sh.lineWidth || 1.6;
    let out = shadow(fills, lines, lw);
    // Outward from the body's edge: the accent keyline, then the outline.
    // Both are strokes centred on the edge, drawn under the body, so the
    // body covers their inner halves and what shows is two clean rings.
    const ring = (colour, reach, withLines) => {
        let r = '<g stroke="' + colour + '" stroke-linecap="round" stroke-linejoin="round" fill="' + colour + '" fill-rule="evenodd">';
        for (const f of fills) r += '<path d="' + f + '" stroke-width="' + (reach * 2) + '"/>';
        if (withLines)
            for (const l of lines) r += '<path d="' + l + '" fill="none" stroke-width="' + (lw + 2 * reach) + '"/>';
        return r + '</g>';
    };
    // Lines (an I-beam, a crosshair) are too fine to frame in colour: they
    // keep a plain outline, and only solid shapes carry the keyline.
    out += ring(c.ink, OUTLINE + RIM, false);
    out += ring(c.ink, OUTLINE, true);
    out += ring(c.acc, RIM, false);
    // body
    for (const f of fills) out += '<path d="' + f + '" fill="' + c.base + '" fill-rule="evenodd"/>';
    for (const l of lines)
        out += '<path d="' + l + '" fill="none" stroke="' + c.base + '" stroke-width="' + lw
             + '" stroke-linecap="round" stroke-linejoin="round"/>';
    for (const d of details)
        out += '<path d="' + d + '" fill="none" stroke="' + c.ink + '" stroke-width="1" stroke-linecap="round"/>';
    for (const a of (sh.accent || []))
        out += '<path d="' + a + '" fill="none" stroke="' + c.acc + '" stroke-width="' + (sh.accentWidth || 2)
             + '" stroke-linecap="round"/>';
    return out;
}

function circle(cx, cy, r) {
    return "M" + (cx - r) + " " + cy + "A" + r + " " + r + " 0 1 0 " + (cx + r) + " " + cy
         + "A" + r + " " + r + " 0 1 0 " + (cx - r) + " " + cy + "Z";
}
function g(transform, body) { return '<g transform="' + transform + '">' + body + '</g>'; }

// ── the arrow ───────────────────────────────────────────────────────────
// Classic proportions: a straight left edge, the tail kinked out to the
// lower right, the wing level with where the tail leaves.
const ARROW = "M5.5 2.8 L5.5 19.4 L9.4 15.7 L11.9 21.5 L14.7 20.3 L12.2 14.6 L17.6 14.6 Z";
const ARROW_HOT = [5.5 / 24, 2.8 / 24];
function arrow(c) { return draw({ fills: [ARROW] }, c); }

// Smaller, up in the corner, leaving room for a badge below right.
const SMALL = "translate(0.4 0.2) scale(0.84)";
const SMALL_HOT = [(0.4 + 5.5 * 0.84) / 24, (0.2 + 2.8 * 0.84) / 24];
function smallArrow(c) { return g(SMALL, arrow(c)); }

// A badge: a disc in the accent with a white mark, outlined like the rest.
function badge(c, mark, dot) {
    const cx = 17.6, cy = 17.6, r = 4.5;
    let out = shadow([circle(cx, cy, r)], [], 0);
    out += '<path d="' + circle(cx, cy, r + OUTLINE * 0.75) + '" fill="' + c.ink + '"/>';
    out += '<path d="' + circle(cx, cy, r) + '" fill="' + c.acc + '"/>';
    if (mark) out += '<path d="' + mark + '" fill="none" stroke="#fff" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>';
    if (dot) out += '<circle cx="' + dot[0] + '" cy="' + dot[1] + '" r="0.8" fill="#fff"/>';
    return out;
}

// ── hands ───────────────────────────────────────────────────────────────
// The index finger up, three folded behind it, the thumb along the side —
// one silhouette, with the gaps between the folded fingers drawn in.
const HAND = "M9.2 12.2 V4.6 A1.55 1.55 0 0 1 12.3 4.6 V10.6 "
           + "A1.5 1.5 0 0 1 15.3 10.6 V11.3 A1.5 1.5 0 0 1 18.3 11.3 V12 A1.45 1.45 0 0 1 21.2 12 "
           + "V15.6 A5.6 5.6 0 0 1 15.6 21.2 H13.4 A5 5 0 0 1 9.4 19.2 L5.6 14.6 "
           + "A1.55 1.55 0 0 1 7.9 12.5 L9.2 13.9 Z";
function hand(c) {
    return draw({ fills: [HAND], details: ["M12.3 10.8 V13.4", "M15.3 11.5 V13.4", "M18.3 12.2 V13.6"] }, c);
}
const OPEN_HAND = "M8.6 12.6 V6.6 A1.45 1.45 0 0 1 11.5 6.6 V11.2 V4.8 A1.45 1.45 0 0 1 14.4 4.8 V11.2 "
                + "V5.8 A1.45 1.45 0 0 1 17.3 5.8 V11.6 V8.2 A1.4 1.4 0 0 1 20.1 8.2 V15.4 "
                + "A5.8 5.8 0 0 1 14.3 21.2 H13.2 A5 5 0 0 1 9.2 19.2 L5.2 14.2 "
                + "A1.5 1.5 0 0 1 7.4 12.2 L8.6 13.4 Z";
function openHand(c) {
    return draw({ fills: [OPEN_HAND], details: ["M11.5 7 V12.6", "M14.4 5.4 V12.6", "M17.3 6.4 V12.8"] }, c);
}
const FIST = "M8.6 13 V10.4 A1.45 1.45 0 0 1 11.5 10.4 V9.4 A1.45 1.45 0 0 1 14.4 9.4 V9.8 "
           + "A1.45 1.45 0 0 1 17.3 9.8 V10.4 A1.4 1.4 0 0 1 20.1 10.4 V15.4 "
           + "A5.8 5.8 0 0 1 14.3 21.2 H13.2 A5 5 0 0 1 9.2 19.2 L7.2 16.4 A1.5 1.5 0 0 1 8.6 14.2 Z";
function fist(c) {
    return draw({ fills: [FIST], details: ["M11.5 10.6 V12.8", "M14.4 10 V12.8", "M17.3 10.6 V12.8"] }, c);
}

// ── text ────────────────────────────────────────────────────────────────
// A slim I-beam with small serifs, the way type cursors are drawn.
const IBEAM = "M9.4 4.6 C11 4.6 12 5.3 12 6.8 V17.2 C12 18.7 11 19.4 9.4 19.4 "
            + "M14.6 4.6 C13 4.6 12 5.3 12 6.8 M14.6 19.4 C13 19.4 12 18.7 12 17.2";
function ibeam(c) { return draw({ lines: [IBEAM, "M10.4 12 H13.6"], lineWidth: 1.3 }, c); }

// ── busy ────────────────────────────────────────────────────────────────
// A disc with a faint track and an accent arc turning round it.
function arcPath(cx, cy, r, f, n, sweep) {
    const a0 = (f / n) * Math.PI * 2 - Math.PI / 2;
    const a1 = a0 + Math.PI * sweep;
    const p = a => [(cx + r * Math.cos(a)).toFixed(2), (cy + r * Math.sin(a)).toFixed(2)];
    const s = p(a0), e = p(a1);
    return "M" + s[0] + " " + s[1] + " A" + r + " " + r + " 0 " + (sweep > 1 ? 1 : 0) + " 1 " + e[0] + " " + e[1];
}
function spinnerAt(c, cx, cy, r, f, n) {
    let out = draw({ fills: [circle(cx, cy, r)] }, c);
    const tr = r * 0.62;
    out += '<path d="' + circle(cx, cy, tr) + '" fill="none" stroke="' + c.ink + '" stroke-opacity="0.22" stroke-width="' + (r * 0.3).toFixed(2) + '"/>';
    out += '<path d="' + arcPath(cx, cy, tr, f, n, 0.55) + '" fill="none" stroke="' + c.acc
         + '" stroke-width="' + (r * 0.3).toFixed(2) + '" stroke-linecap="round"/>';
    return out;
}
function spinner(c, f, n) { return spinnerAt(c, 12, 12, 7.2, f, n); }
function progress(c, f, n) { return smallArrow(c) + spinnerAt(c, 17.6, 17.6, 4.6, f, n); }

// ── resizing and moving ─────────────────────────────────────────────────
// Solid double arrows: a slim shaft between two broad heads.
const NS = "M12 3.4 L16.4 8.4 H13.15 V15.6 H16.4 L12 20.6 L7.6 15.6 H10.85 V8.4 H7.6 Z";
// Column / row splitters: two bars with a head pointing out from each.
const SPLIT = ["M10.6 5 V19 H13.4 V5 Z",
               "M3.2 12 L7.9 7.6 V16.4 Z",
               "M20.8 12 L16.1 7.6 V16.4 Z"];
// Four heads on a cross.
const MOVE = "M12 2.8 L15.6 6.8 H13.15 V10.85 H17.2 V8.4 L21.2 12 L17.2 15.6 V13.15 H13.15 V17.2 H15.6 "
           + "L12 21.2 L8.4 17.2 H10.85 V13.15 H6.8 V15.6 L2.8 12 L6.8 8.4 V10.85 H10.85 V6.8 H8.4 Z";
// A thick plus, for picking cells.
const CELL = "M10.2 4.8 H13.8 V10.2 H19.2 V13.8 H13.8 V19.2 H10.2 V13.8 H4.8 V10.2 H10.2 Z";

function magnifier(c, plus) {
    let out = draw({ lines: ["M14.6 14.6 L19.8 19.8"], lineWidth: 2.6 }, c);
    out += draw({ fills: [circle(10.4, 10.4, 6.2)] }, c);
    out += '<path d="M7.6 10.4 H13.2' + (plus ? ' M10.4 7.6 V13.2' : '') + '" fill="none" stroke="' + c.ink
         + '" stroke-width="1.6" stroke-linecap="round"/>';
    return out;
}

function notAllowed(c) {
    const ring = circle(12, 12, 7.4), hole = circle(12, 12, 5.4);
    let out = draw({ fills: [ring + " " + hole] }, c);
    out += draw({ lines: ["M8.2 8.2 L15.8 15.8"], lineWidth: 2 }, c);
    return out;
}

const CENTER = [0.5, 0.5];

// [{ name, aliases, hot, delay, frames }], with { base, ink, acc } colours:
// base the body, ink the outline and details, acc the accent.
function shapes(base, ink, acc) {
    const c = { base: base, ink: ink, acc: acc };
    const spinFrames = [], progFrames = [];
    const n = 20;
    for (let f = 0; f < n; f++) {
        spinFrames.push(svg(spinner(c, f, n)));
        progFrames.push(svg(progress(c, f, n)));
    }
    return [
        { name: "default", hot: ARROW_HOT, frames: [svg(arrow(c))],
          aliases: ["left_ptr", "arrow", "top_left_arrow", "left_arrow"] },
        { name: "pointer", hot: [10.75 / 24, 3.1 / 24], frames: [svg(hand(c))],
          aliases: ["hand", "hand1", "hand2", "pointing_hand",
                    "9d800788f1b08800ae810202380a0822", "e29285e634086352946a0e7090d73106"] },
        { name: "text", hot: CENTER, frames: [svg(ibeam(c))], aliases: ["xterm", "ibeam"] },
        { name: "vertical-text", hot: CENTER, frames: [svg(g("rotate(90 12 12)", ibeam(c)))], aliases: [] },
        { name: "wait", hot: CENTER, delay: 40, frames: spinFrames, aliases: ["watch"] },
        { name: "progress", hot: SMALL_HOT, delay: 40, frames: progFrames,
          aliases: ["left_ptr_watch", "half-busy",
                    "08e8e1c95fe2fc01f976f1e063a24ccd", "3ecb610c1bf2410f44200f48c40d3599"] },
        { name: "crosshair", hot: CENTER,
          frames: [svg(draw({ lines: ["M12 3.8 V9.6", "M12 14.4 V20.2", "M3.8 12 H9.6", "M14.4 12 H20.2"],
                              lineWidth: 1.4 }, c))],
          aliases: ["cross", "tcross", "cross_reverse", "diamond_cross"] },
        { name: "cell", hot: CENTER, frames: [svg(draw({ fills: [CELL] }, c))], aliases: ["plus"] },
        { name: "move", hot: CENTER, frames: [svg(draw({ fills: [MOVE] }, c))],
          aliases: ["fleur", "size_all", "all-scroll", "dnd-move",
                    "4498f0e0c1937ffe01fd06f973665830", "9081237383d90e509aa00f00170e968f"] },
        { name: "grab", hot: CENTER, frames: [svg(openHand(c))],
          aliases: ["openhand", "5aca4d189052212118709018842178c0", "9141b49c8149039304290b508d208c40"] },
        { name: "grabbing", hot: CENTER, frames: [svg(fist(c))],
          aliases: ["closedhand", "dnd-none", "208530c400c041818281048008011002", "fcf21c00b30f7e3f83fe0dfd12e71cff"] },
        { name: "ns-resize", hot: CENTER, frames: [svg(draw({ fills: [NS] }, c))],
          aliases: ["n-resize", "s-resize", "top_side", "bottom_side", "sb_v_double_arrow", "v_double_arrow",
                    "size_ver", "00008160000006810000408080010102"] },
        { name: "ew-resize", hot: CENTER, frames: [svg(g("rotate(90 12 12)", draw({ fills: [NS] }, c)))],
          aliases: ["e-resize", "w-resize", "left_side", "right_side", "sb_h_double_arrow", "h_double_arrow",
                    "size_hor", "028006030e0e7ebffc7f7070c0600140"] },
        { name: "nwse-resize", hot: CENTER, frames: [svg(g("rotate(-45 12 12)", draw({ fills: [NS] }, c)))],
          aliases: ["nw-resize", "se-resize", "top_left_corner", "bottom_right_corner", "bd_double_arrow",
                    "size_fdiag", "c7088f0f3e6c8088236ef8e1e3e70000"] },
        { name: "nesw-resize", hot: CENTER, frames: [svg(g("rotate(45 12 12)", draw({ fills: [NS] }, c)))],
          aliases: ["ne-resize", "sw-resize", "top_right_corner", "bottom_left_corner", "fd_double_arrow",
                    "size_bdiag", "fcf1c3c7cd4491d801f1e1c78f100000"] },
        { name: "col-resize", hot: CENTER, frames: [svg(draw({ fills: SPLIT }, c))],
          aliases: ["split_h", "14fef782d02440884392942c11205230"] },
        { name: "row-resize", hot: CENTER, frames: [svg(g("rotate(90 12 12)", draw({ fills: SPLIT }, c)))],
          aliases: ["split_v", "2870a09082c103050810ffdffffe0204"] },
        { name: "not-allowed", hot: CENTER, frames: [svg(notAllowed(c))],
          aliases: ["crossed_circle", "forbidden", "circle", "03b6e0fcb3499374a867c041f52298f0"] },
        { name: "no-drop", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M15.9 15.9 L19.3 19.3 M19.3 15.9 L15.9 19.3"))],
          aliases: ["dnd-no-drop"] },
        { name: "help", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M16.2 16.5 A1.45 1.45 0 1 1 18.5 17.6 C17.9 18 17.6 18.3 17.6 18.8",
                                              [17.6, 20.3]))],
          aliases: ["question_arrow", "whats_this", "left_ptr_help",
                    "d9ce0ab605698f320427677b458ad60b", "5c6cd98b3f3ebcb1f9c7f1c204630408"] },
        { name: "copy", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M17.6 15.5 V19.7 M15.5 17.6 H19.7"))],
          aliases: ["dnd-copy", "1081e37283d90000800003c07f3ef6bf", "6407b0e94181790501fd1e167b474872",
                    "b66166c04f8c3109214a4fbd64a50fc8"] },
        { name: "alias", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M15.8 19.4 L19.2 16 M16.8 15.8 H19.4 V18.4"))],
          aliases: ["dnd-link", "link", "640fb0e74195791501fd1ed57b41487f", "3085a0e285430894940527032f8b26df",
                    "a2a266d0498c3104214a47bd64ab0fc8"] },
        { name: "context-menu", hot: SMALL_HOT,
          frames: [svg(smallArrow(c) + badge(c, "M15.7 16.3 H19.5 M15.7 18.9 H19.5"))],
          aliases: [] },
        { name: "zoom-in", hot: [10.4 / 24, 10.4 / 24], frames: [svg(magnifier(c, true))], aliases: [] },
        { name: "zoom-out", hot: [10.4 / 24, 10.4 / 24], frames: [svg(magnifier(c, false))], aliases: [] }
    ];
}
