.pragma library

// Bespoke 24x24 monoline icon pack, ported from the Claude Design mockup's
// ART table (Hyprshell Live.dc.html) and extended with same-style glyphs for
// everything the mockup pulled from Lucide.
//
// Each entry is an object of *pre-merged* path groups rather than a list of
// individual ops, so MonoIcon can draw a whole glyph with two or three Qt
// Quick Shapes instead of one per stroke — dozens of icons are on screen at
// once (dock, launcher grid, control center, settings sidebar) and a Shape
// per stroke adds up fast.
//
//   ink   stroke-width 2, ink color        acc   stroke-width 2, accent
//   inkW  stroke-width 3, ink color        accW  stroke-width 3, accent
//   fill  filled path, accent color
//   dots  [{ cx, cy, r, c }]  filled discs ("acc" | "ink")
//
// SVG rect/circle/ellipse primitives are expanded to path data below, since
// PathSvg only speaks paths.

// --- path builders --------------------------------------------------------

function circle(cx, cy, r) {
    // Two half-arcs: a single arc command can't close a full circle.
    return "M" + (cx - r) + " " + cy
        + "A" + r + " " + r + " 0 1 0 " + (cx + r) + " " + cy
        + "A" + r + " " + r + " 0 1 0 " + (cx - r) + " " + cy + "Z";
}

function ellipse(cx, cy, rx, ry) {
    return "M" + (cx - rx) + " " + cy
        + "A" + rx + " " + ry + " 0 1 0 " + (cx + rx) + " " + cy
        + "A" + rx + " " + ry + " 0 1 0 " + (cx - rx) + " " + cy + "Z";
}

function rrect(x, y, w, h, r) {
    var x2 = x + w, y2 = y + h;
    return "M" + (x + r) + " " + y
        + "H" + (x2 - r) + "A" + r + " " + r + " 0 0 1 " + x2 + " " + (y + r)
        + "V" + (y2 - r) + "A" + r + " " + r + " 0 0 1 " + (x2 - r) + " " + y2
        + "H" + (x + r) + "A" + r + " " + r + " 0 0 1 " + x + " " + (y2 - r)
        + "V" + (y + r) + "A" + r + " " + r + " 0 0 1 " + (x + r) + " " + y + "Z";
}

// Concatenating subpaths is safe because every builder above emits an
// absolute moveto first.
function join() {
    var parts = [];
    for (var i = 0; i < arguments.length; i++) {
        if (arguments[i]) parts.push(arguments[i]);
    }
    return parts.join(" ");
}

var icons = {

    // ══ App pack — bespoke, one accent element each ═══════════════════════

    terminal: {
        ink: "M4 7.5H20 M7.5 11.5L10 14L7.5 16.5",
        acc: "M13 16.5H17"
    },
    folder: {
        acc: "M4 6.5H10L12 9.5H20",
        ink: rrect(4, 9.5, 16, 10, 2)
    },
    globe: {
        ink: join(circle(12, 12, 8.5), ellipse(12, 12, 4, 8.5)),
        acc: "M3.5 12H20.5"
    },
    code: {
        ink: "M8.5 7.5L3.5 12L8.5 16.5 M15.5 7.5L20.5 12L15.5 16.5",
        acc: "M13.5 6L10.5 18"
    },
    stickyNote: {
        ink: join(rrect(4, 4, 16, 16, 2), "M8 14.5H13"),
        acc: "M8 10H16"
    },
    music: {
        ink: "M6 14.5V9.5 M10 17.5V6.5 M18 13.5V10.5",
        acc: "M14 16V8"
    },
    settings: {
        ink: join("M4 8.5H12.5 M17.5 8.5H20 M4 15.5H7.5 M12.5 15.5H20", circle(10, 15.5, 2.5)),
        dots: [{ cx: 15, cy: 8.5, r: 2.5, c: "acc" }]
    },
    monitor: {
        ink: join(rrect(3, 5, 18, 11.5, 2), "M12 16.5V20"),
        acc: "M9 20H15"
    },
    camera: {
        ink: "M4.5 8.5V5.5H7.5 M19.5 8.5V5.5H16.5 M4.5 15.5V18.5H7.5 M19.5 15.5V18.5H16.5",
        dots: [{ cx: 12, cy: 12, r: 3, c: "acc" }]
    },
    palette: {
        ink: circle(12, 12, 8.5),
        // Right half filled — the mockup's one solid-accent glyph.
        fill: "M12 3.5A8.5 8.5 0 0 1 12 20.5Z"
    },
    keyboard: {
        ink: rrect(3, 7, 18, 10, 2),
        acc: "M8 14H16",
        dots: [
            { cx: 7, cy: 10.8, r: 1, c: "ink" },
            { cx: 11, cy: 10.8, r: 1, c: "ink" },
            { cx: 15, cy: 10.8, r: 1, c: "ink" }
        ]
    },
    package: {
        ink: "M12 3.5L20 8V16L12 20.5L4 16V8L12 3.5Z M12 12.5V20.5",
        acc: "M4 8L12 12.5L20 8"
    },

    // ── pointing devices ──────────────────────────────────────────────────
    // A mouse is the body capsule with the wheel marked in accent; a touchpad
    // is the slab with its click strip along the bottom edge. Same 2px
    // monoline weight and 24x24 box as everything else here.
    mouse: {
        ink: rrect(7, 2.5, 10, 19, 5),
        acc: "M12 6.5V9.5"
    },
    touchpad: {
        ink: rrect(3, 4.5, 18, 15, 2),
        acc: "M3 14.5H21"
    },

    cpu: {
        ink: "M4 19.5H20",
        inkW: "M7.5 17V12.5 M16.5 17V10.5",
        accW: "M12 17V7.5"
    },
    download: {
        ink: "M12 4.5V13.5 M4.5 17V19.5H19.5V17",
        acc: "M8.5 10.5L12 14L15.5 10.5"
    },
    upload: {
        ink: "M12 14.5V5.5 M4.5 17V19.5H19.5V17",
        acc: "M8.5 9L12 5.5L15.5 9"
    },
    bluetooth: {
        ink: join(rrect(3.5, 7, 6, 10, 1.5), rrect(14.5, 9, 6, 6, 1.5)),
        acc: "M9.5 12H14.5"
    },
    image: {
        ink: join(rrect(3.5, 5, 17, 14, 2), "M3.5 15.5L8.5 11.5L12.5 15L15.5 12.5L20.5 16.5"),
        dots: [{ cx: 8.5, cy: 9.5, r: 1.75, c: "acc" }]
    },
    folderOpen: {
        ink: "M4 11L12 4.5L20 11 M6.5 10.5V19.5H17.5V10.5",
        acc: "M10.5 19.5V14.5H13.5V19.5"
    },
    file: {
        ink: join(rrect(5, 3.5, 14, 17, 2), "M12 10H16 M12 14.5H16"),
        acc: "M9.5 9.5L8 12L9.5 14.5"
    },
    refresh: {
        ink: "M20 12A8 8 0 1 1 16.8 5.6",
        acc: "M20 4.5V10H14.5"
    },
    trash: {
        ink: "M9.5 7.5V5H14.5V7.5 M6.5 7.5L7.5 19.5H16.5L17.5 7.5",
        acc: "M4.5 7.5H19.5"
    },
    // The launcher's calculator.
    calculator: {
        ink: join(rrect(5, 3, 14, 18, 2.5), "M9 12H9.01 M12 12H12.01 M15 12H15.01 M9 15.5H9.01 M12 15.5H12.01 M9 19H12"),
        acc: "M8.5 7H15.5 M15 15.5V19"
    },
    // Clipboard history.
    clipboard: {
        ink: join(rrect(5, 4.5, 14, 16, 2), "M9 12H15 M9 15.5H13"),
        acc: rrect(9, 3, 6, 3.5, 1)
    },

    // Added for the file manager: the house its sidebar opens in, the glyph
    // for a video file, and the mark for a bookmarked folder.
    star: {
        ink: "M12 4L14.5 9.3L20.3 10.1L16.1 14.1L17.1 19.8L12 17.1L6.9 19.8L7.9 14.1L3.7 10.1L9.5 9.3Z"
    },
    home: {
        ink: "M4 10.5L12 4L20 10.5V19.5H4Z",
        acc: "M9.5 19.5V13.5H14.5V19.5"
    },
    film: {
        ink: join(rrect(3.5, 5, 17, 14, 2), "M8 5V19 M16 19V5"),
        acc: "M3.5 12H20.5"
    },
    lock: {
        ink: join("M8 10.5V7.5A4 4 0 0 1 16 7.5V10.5", rrect(4.5, 10.5, 15, 9, 2)),
        dots: [{ cx: 12, cy: 15, r: 1.5, c: "acc" }]
    },
    panelsTopLeft: {
        ink: join(rrect(3.5, 4.5, 17, 15, 2), "M9.5 4.5V19.5"),
        acc: "M9.5 12H20.5"
    },
    moon: {
        ink: "M19 14.5A8 8 0 0 1 9.5 5A8.5 8.5 0 1 0 19 14.5Z",
        dots: [{ cx: 17.5, cy: 6.5, r: 1.5, c: "acc" }]
    },
    user: {
        ink: circle(12, 8.5, 3.75),
        acc: "M5 19.5A7 7 0 0 1 19 19.5"
    },

    // ══ Chrome glyphs ════════════════════════════════════════════════════
    // The mockup falls back to stock single-color Lucide for shell chrome
    // (bar affordances, arrows, tickmarks), so these carry no accent element
    // — MonoIcon paints them entirely in `inkColor`.

    grid: {
        ink: join(
            rrect(3, 3, 7.5, 7.5, 1.5), rrect(13.5, 3, 7.5, 7.5, 1.5),
            rrect(3, 13.5, 7.5, 7.5, 1.5), rrect(13.5, 13.5, 7.5, 7.5, 1.5)
        )
    },
    layoutDashboard: {
        ink: join(
            rrect(3, 3, 8, 10, 1.5), rrect(13, 3, 8, 6, 1.5),
            rrect(13, 11, 8, 10, 1.5), rrect(3, 15, 8, 6, 1.5)
        )
    },
    dock: {
        ink: join(rrect(2.5, 8.5, 19, 9, 2.5), "M7 12.5V13.5 M12 12.5V13.5 M17 12.5V13.5")
    },
    search: {
        ink: join(circle(10.5, 10.5, 6.5), "M15.4 15.4L20.5 20.5")
    },
    bell: {
        ink: "M6.5 16.5V11a5.5 5.5 0 0 1 11 0v5.5H6.5Z M4.5 16.5h15 M10 19.5a2.2 2.2 0 0 0 4 0"
    },
    bellOff: {
        ink: "M8 7.2A5.5 5.5 0 0 1 17.5 11v5.5 M6.5 11.5v5H16 M4.5 16.5h2 M10 19.5a2.2 2.2 0 0 0 4 0 M4 4l16 16"
    },
    power: {
        ink: "M12 3.5V11.5 M6.8 6.6a7.5 7.5 0 1 0 10.4 0"
    },
    logOut: {
        ink: "M10 4.5H5.5v15H10 M13 8l4 4-4 4 M8.5 12H17"
    },
    rotateCw: {
        ink: "M20 12a8 8 0 1 1-2.6-5.9 M20 3.5V9h-5.5"
    },
    cornerDownLeft: {
        ink: "M19.5 4.5v7.5a3 3 0 0 1-3 3H5.5 M9.5 11L5 15l4.5 4"
    },
    check: {
        ink: "M4.5 12.5L9.5 17.5L19.5 6.5"
    },
    x: {
        ink: "M5.5 5.5L18.5 18.5 M18.5 5.5L5.5 18.5"
    },
    minus: {
        ink: "M5 12H19"
    },
    plus: {
        ink: "M12 5V19 M5 12H19"
    },
    square: {
        ink: rrect(5, 5, 14, 14, 2)
    },
    chevronLeft: { ink: "M15 4.5L7.5 12L15 19.5" },
    chevronRight: { ink: "M9 4.5L16.5 12L9 19.5" },
    chevronDown: { ink: "M4.5 9L12 16.5L19.5 9" },
    chevronUp: { ink: "M4.5 15L12 7.5L19.5 15" },
    moreHorizontal: {
        dots: [
            { cx: 5.5, cy: 12, r: 1.5, c: "ink" },
            { cx: 12, cy: 12, r: 1.5, c: "ink" },
            { cx: 18.5, cy: 12, r: 1.5, c: "ink" }
        ]
    },

    // Signal / radio
    wifi: {
        ink: "M2.5 8.8a14 14 0 0 1 19 0 M5.8 12.3a9.4 9.4 0 0 1 12.4 0 M9 15.8a4.8 4.8 0 0 1 6 0",
        dots: [{ cx: 12, cy: 19.3, r: 1.4, c: "ink" }]
    },
    wifiOff: {
        ink: "M2.5 8.8a14 14 0 0 1 5-3.4 M16.5 5.4a14 14 0 0 1 5 3.4 M18.2 12.3a9.4 9.4 0 0 0-3-2 M9 15.8a4.8 4.8 0 0 1 4.6-.6 M3.5 3.5l17 17",
        dots: [{ cx: 12, cy: 19.3, r: 1.4, c: "ink" }]
    },
    plane: {
        ink: "M12 3.2c.8 0 1.3.8 1.3 1.7v4.4l7.2 4.2v2l-7.2-2.2v4l2.4 1.7v1.6L12 19.6l-3.7 1H8v-1.6l2.4-1.7v-4L3.2 15.5v-2l7.2-4.2V4.9c0-.9.5-1.7 1.3-1.7Z"
    },
    gamepad: {
        ink: join(
            "M7.5 9.5H16.5a4.5 4.5 0 0 1 4.4 5.4l-.4 2a2.6 2.6 0 0 1-4.5 1.2l-1.4-1.6H9.3l-1.4 1.6a2.6 2.6 0 0 1-4.5-1.2l-.4-2A4.5 4.5 0 0 1 7.5 9.5Z",
            "M6 12.5v3 M4.5 14h3"
        ),
        dots: [{ cx: 17, cy: 13.2, r: 1.1, c: "ink" }, { cx: 14.6, cy: 15.2, r: 1.1, c: "ink" }]
    },
    shield: {
        ink: "M12 3.2l7 2.6v5.6c0 4.3-2.8 7.6-7 9.4-4.2-1.8-7-5.1-7-9.4V5.8l7-2.6Z M9 12l2.2 2.2L15.2 10"
    },

    // Audio
    volume: {
        ink: "M4.5 9.5h3l4-3.4v11.8l-4-3.4h-3V9.5Z M14.8 9.4a3.6 3.6 0 0 1 0 5.2 M17.6 6.8a7.4 7.4 0 0 1 0 10.4"
    },
    volumeLow: {
        ink: "M4.5 9.5h3l4-3.4v11.8l-4-3.4h-3V9.5Z M14.8 9.4a3.6 3.6 0 0 1 0 5.2"
    },
    volumeX: {
        ink: "M4.5 9.5h3l4-3.4v11.8l-4-3.4h-3V9.5Z M15.5 10L20 14.5 M20 10L15.5 14.5"
    },
    mic: {
        ink: join(rrect(9.5, 2.8, 5, 10.4, 2.5), "M5.8 11.5a6.2 6.2 0 0 0 12.4 0 M12 17.7V21 M9 21h6")
    },
    micOff: {
        ink: "M9.5 5.3a2.5 2.5 0 0 1 5 0v4 M14.5 13a2.5 2.5 0 0 1-5-1.4V9 M5.8 11.5a6.2 6.2 0 0 0 9.6 5.2 M18.2 11.5a6.2 6.2 0 0 1-.4 2.2 M12 17.7V21 M9 21h6 M3.5 3.5l17 17"
    },
    headphones: {
        ink: join("M4.5 15.5v-3a7.5 7.5 0 0 1 15 0v3", rrect(2.8, 14, 4.2, 6, 1.8), rrect(17, 14, 4.2, 6, 1.8))
    },
    speaker: {
        ink: join(rrect(5.5, 2.8, 13, 18.4, 2.5), circle(12, 14.5, 3.5)),
        dots: [{ cx: 12, cy: 7, r: 1.2, c: "ink" }]
    },
    play: { ink: "M7.5 5.2l11 6.8-11 6.8V5.2Z" },
    pause: { ink: "M9 5.5v13 M15 5.5v13" },
    skipBack: { ink: "M18.5 5.5l-9 6.5 9 6.5V5.5Z M6 5.5v13" },
    skipForward: { ink: "M5.5 5.5l9 6.5-9 6.5V5.5Z M18 5.5v13" },

    // Two routes crossing, one of them the accent — which is the whole
    // idea of shuffle, and reads at 15px where a pair of tangled arrows
    // does not.
    shuffle: {
        ink: "M4 6h3.2l9.6 12H20 M17.5 15.5L20 18l-2.5 2.5",
        acc: "M4 18h3.2l9.6-12H20 M17.5 3.5L20 6l-2.5 2.5"
    },
    // A loop drawn as two half-tracks so the accent can carry the return
    // leg. repeatOne is the same loop with a mark in the middle: this pack
    // has no numerals, and a "1" at 15px would be a smudge anyway.
    repeat: {
        ink: "M4 12.5V11a3.5 3.5 0 0 1 3.5-3.5H19 M16.5 4.5L19.5 7.5 16.5 10.5",
        acc: "M20 11.5V13a3.5 3.5 0 0 1-3.5 3.5H5 M7.5 13.5L4.5 16.5 7.5 19.5"
    },
    repeatOne: {
        ink: "M4 12.5V11a3.5 3.5 0 0 1 3.5-3.5H19 M16.5 4.5L19.5 7.5 16.5 10.5",
        acc: "M20 11.5V13a3.5 3.5 0 0 1-3.5 3.5H5 M7.5 13.5L4.5 16.5 7.5 19.5",
        dots: [{ cx: 12, cy: 12, r: 1.6, c: "acc" }]
    },

    // Power / battery
    battery: {
        ink: join(rrect(2.5, 7.5, 16.5, 9, 2.5), "M21.5 10.8v2.4"),
        // Fill level is drawn separately by callers that want it; the static
        // glyph shows a "medium" bar like the mockup's battery-medium.
        dots: []
    },
    batteryCharging: {
        ink: join(rrect(2.5, 7.5, 16.5, 9, 2.5), "M21.5 10.8v2.4"),
        acc: "M11.8 9.2L9 12.4h3.2l-.8 2.6 3-3.4h-3.2l.6-2.4Z"
    },
    sun: {
        ink: join(circle(12, 12, 4.2),
            "M12 2.5v2 M12 19.5v2 M2.5 12h2 M19.5 12h2 M5.3 5.3l1.4 1.4 M17.3 17.3l1.4 1.4 M18.7 5.3l-1.4 1.4 M6.7 17.3l-1.4 1.4")
    },
    sunMoon: {
        ink: join("M12 2.5v2 M2.5 12h2 M5.3 5.3l1.4 1.4 M18.7 5.3l-1.4 1.4 M19.5 12h2",
            "M18.5 14.2A7 7 0 0 1 9.8 5.5a7.4 7.4 0 1 0 8.7 8.7Z")
    },
    zap: {
        ink: "M13.5 2.5L4.5 13.5h6l-1 8 9-11h-6l1-8Z"
    },
    info: {
        ink: join(circle(12, 12, 8.5), "M12 11v5.5"),
        dots: [{ cx: 12, cy: 7.8, r: 1.1, c: "ink" }]
    },
    sliders: {
        ink: join("M4 7.5h4.5 M13.5 7.5H20 M4 16.5h9.5 M18.5 16.5H20",
            circle(11, 7.5, 2.5), circle(16, 16.5, 2.5))
    },
    eye: {
        ink: join("M2.5 12s3.6-6 9.5-6 9.5 6 9.5 6-3.6 6-9.5 6-9.5-6-9.5-6Z", circle(12, 12, 3))
    },

    // Shared with the file manager's copy of this pack, so the two do not
    // drift. The file-kind glyphs it adds on top stay over there.
    list: {
        ink: "M9 6.5H20 M9 12H20 M9 17.5H20",
        dots: [{ cx: 4.75, cy: 6.5, r: 1.4, c: "ink" },
               { cx: 4.75, cy: 12, r: 1.4, c: "ink" },
               { cx: 4.75, cy: 17.5, r: 1.4, c: "ink" }]
    },
    font: {
        ink: "M6.5 16.5L11.25 5.5L16 16.5 M8.4 12.75H14.1",
        acc: "M5 20H19"
    },

    // ── the icon maker's own tools ────────────────────────────────────
    //
    // Same 24 grid and same monoline weight as everything above, so the
    // tool rail reads as part of the shell rather than as a toolbar
    // borrowed from somewhere else.
    cursor: {
        ink: "M6 3 L6 17.5 L9.6 14.2 L12 19.8 L14.4 18.8 L12 13.4 L17.5 12.8 Z"
    },
    circle: {
        ink: circle(12, 12, 7)
    },
    ellipse: {
        ink: ellipse(12, 12, 8.5, 5.5)
    },
    arc: {
        ink: "M4 16 A8 8 0 0 1 20 16",
        dots: [{ cx: 4, cy: 16, r: 1.2, c: "acc" },
               { cx: 20, cy: 16, r: 1.2, c: "acc" }]
    },
    poly: {
        ink: "M4 18 L9.5 9 L14 13.5 L20 5",
        dots: [{ cx: 9.5, cy: 9, r: 1.2, c: "acc" },
               { cx: 14, cy: 13.5, r: 1.2, c: "acc" }]
    },
    dot: {
        dots: [{ cx: 12, cy: 12, r: 4.5, c: "ink" }]
    },
    lasso: {
        // A dashed loop with a tail, the way every selection tool draws
        // itself.
        ink: "M12 4.2 A7.8 5.6 0 0 1 19.8 9.8 M19.8 9.8 A7.8 5.6 0 0 1 15 15.1"
             + " M9 15.1 A7.8 5.6 0 0 1 4.2 9.8 M4.2 9.8 A7.8 5.6 0 0 1 12 4.2",
        acc: "M9 15.1 C9 18 10.5 19 12 19.8",
        dots: [{ cx: 12, cy: 20.4, r: 1.3, c: "acc" }]
    },
    pen: {
        // A nib with a node on its point, which is what the tool does:
        // it puts points down.
        ink: "M4 20 L6.5 13.5 L15 5 A2.12 2.12 0 0 1 19 9 L10.5 17.5 Z",
        acc: "M6.5 13.5 L10.5 17.5",
        dots: [{ cx: 4, cy: 20, r: 1.3, c: "acc" }]
    }

};

// Every glyph the pack really has, captured before the aliases below are
// added — those are second names for icons already in this list, and a
// picker that showed them would offer the same drawing eight times.
var canonical = Object.keys(icons);

function names() {
    return canonical.slice();
}


// Aliases so callers can use either the mockup's ICONS keys or plain names.
icons.appTerm = icons.terminal;
icons.appFiles = icons.folder;
icons.appWeb = icons.globe;
icons.appCode = icons.code;
icons.appNotes = icons.stickyNote;
icons.appMusic = icons.music;
icons.appSettings = icons.settings;
icons.panels = icons.panelsTopLeft;
icons.pkg = icons.package;
icons.reboot = icons.rotateCw;
icons.logout = icons.logOut;
icons.enter = icons.cornerDownLeft;
icons.chevL = icons.chevronLeft;
icons.chevR = icons.chevronRight;
icons.chevD = icons.chevronDown;
icons.chevU = icons.chevronUp;
icons.sq = icons.square;
icons.prev = icons.skipBack;
icons.next = icons.skipForward;
icons.layout = icons.layoutDashboard;
icons.dockIcon = icons.dock;
icons.vpn = icons.shield;

function has(name) {
    return icons[name] !== undefined;
}
