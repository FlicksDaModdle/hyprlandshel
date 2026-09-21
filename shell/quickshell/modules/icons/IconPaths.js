.pragma library

// Bespoke 24x24 monoline icon pack — one accent-colored element per glyph,
// ported from the Claude Design mockup's ART table (Hyprshell Live.dc.html).
// Each entry is a list of draw ops consumed by MonoIcon.qml:
//   { d: "<svg path data>", c: "ink" | "accent" }        -> stroked path
//   { type: "circle", cx, cy, r, fill: "accent" | "none", stroke: "ink" | "none" }
//
// Rect/circle/ellipse primitives from the original SVG were converted to
// path data (two-arc technique for full circles/ellipses) so everything
// can be drawn with a single Qt Quick Shape per icon.

var icons = {
    terminal: [
        { d: "M4 7.5 H20", c: "ink" },
        { d: "M7.5 11.5 L10 14 L7.5 16.5", c: "ink" },
        { d: "M13 16.5 H17", c: "accent" }
    ],
    folder: [
        { d: "M4 6.5 H10 L12 9.5 H20", c: "accent" },
        { d: "M6 9.5 H18 A 2 2 0 0 1 20 11.5 V 17.5 A 2 2 0 0 1 18 19.5 H 6 A 2 2 0 0 1 4 17.5 V 11.5 A 2 2 0 0 1 6 9.5 Z", c: "ink" }
    ],
    globe: [
        { d: "M3.5 12 A 8.5 8.5 0 1 0 20.5 12 A 8.5 8.5 0 1 0 3.5 12 Z", c: "ink" },
        { d: "M3.5 12 H 20.5", c: "accent" },
        { d: "M8 12 A 4 8.5 0 1 0 16 12 A 4 8.5 0 1 0 8 12 Z", c: "ink" }
    ],
    code: [
        { d: "M8.5 7.5 L3.5 12 L8.5 16.5", c: "ink" },
        { d: "M15.5 7.5 L20.5 12 L15.5 16.5", c: "ink" },
        { d: "M13.5 6 L10.5 18", c: "accent" }
    ],
    stickyNote: [
        { d: "M6 4 H18 A 2 2 0 0 1 20 6 V 18 A 2 2 0 0 1 18 20 H 6 A 2 2 0 0 1 4 18 V 6 A 2 2 0 0 1 6 4 Z", c: "ink" },
        { d: "M8 10 H 16", c: "accent" },
        { d: "M8 14.5 H 13", c: "ink" }
    ],
    music: [
        { d: "M6 14.5 V 9.5", c: "ink" },
        { d: "M10 17.5 V 6.5", c: "ink" },
        { d: "M14 16 V 8", c: "accent" },
        { d: "M18 13.5 V 10.5", c: "ink" }
    ],
    settings: [
        { d: "M4 8.5 H 12.5", c: "ink" },
        { d: "M17.5 8.5 H 20", c: "ink" },
        { type: "circle", cx: 15, cy: 8.5, r: 2.5, fill: "accent" },
        { d: "M4 15.5 H 7.5", c: "ink" },
        { d: "M12.5 15.5 H 20", c: "ink" },
        { type: "circle", cx: 10, cy: 15.5, r: 2.5, fill: "none", stroke: "ink" }
    ],
    panelsTopLeft: [
        { d: "M5.5 4.5 H18.5 A 2 2 0 0 1 20.5 6.5 V 17.5 A 2 2 0 0 1 18.5 19.5 H 5.5 A 2 2 0 0 1 3.5 17.5 V 6.5 A 2 2 0 0 1 5.5 4.5 Z", c: "ink" },
        { d: "M9.5 4.5 V 19.5", c: "ink" },
        { d: "M9.5 12 H 20.5", c: "accent" }
    ],
    grid: [
        { d: "M4.5 3 H9 A 1.5 1.5 0 0 1 10.5 4.5 V 9 A 1.5 1.5 0 0 1 9 10.5 H 4.5 A 1.5 1.5 0 0 1 3 9 V 4.5 A 1.5 1.5 0 0 1 4.5 3 Z", c: "ink" },
        { d: "M15 3 H19.5 A 1.5 1.5 0 0 1 21 4.5 V 9 A 1.5 1.5 0 0 1 19.5 10.5 H 15 A 1.5 1.5 0 0 1 13.5 9 V 4.5 A 1.5 1.5 0 0 1 15 3 Z", c: "ink" },
        { d: "M4.5 13.5 H9 A 1.5 1.5 0 0 1 10.5 15 V 19.5 A 1.5 1.5 0 0 1 9 21 H 4.5 A 1.5 1.5 0 0 1 3 19.5 V 15 A 1.5 1.5 0 0 1 4.5 13.5 Z", c: "ink" },
        { d: "M15 13.5 H19.5 A 1.5 1.5 0 0 1 21 15 V 19.5 A 1.5 1.5 0 0 1 19.5 21 H 15 A 1.5 1.5 0 0 1 13.5 19.5 V 15 A 1.5 1.5 0 0 1 15 13.5 Z", c: "ink" }
    ],
    minus: [
        { d: "M5 12 H 19", c: "ink" }
    ],
    // Generic fallback for unpinned-but-running apps (mockup uses this for
    // its one demo case, Pavucontrol) — three bars on a baseline, thicker
    // strokes than the rest of the pack, accent middle bar.
    cpu: [
        { d: "M4 19.5 H 20", c: "ink" },
        { d: "M7.5 17 V 12.5", c: "ink", w: 3 },
        { d: "M12 17 V 7.5", c: "accent", w: 3 },
        { d: "M16.5 17 V 10.5", c: "ink", w: 3 }
    ],

    // Plain single-color chrome glyphs (search field, back/forward) — the
    // mockup keeps these as stock Lucide rather than the bespoke app pack,
    // so no accent element here, just ink strokes.
    search: [
        { d: "M17 17 L 21 21", c: "ink" },
        { d: "M10 16.5 A 6.5 6.5 0 1 0 10 3.5 A 6.5 6.5 0 1 0 10 16.5 Z", c: "ink" }
    ],
    chevronLeft: [
        { d: "M14.5 5 L 8 12 L 14.5 19", c: "ink" }
    ],
    chevronRight: [
        { d: "M9.5 5 L 16 12 L 9.5 19", c: "ink" }
    ],

    lock: [
        { d: "M8 10.5 V 7.5 A 4 4 0 0 1 16 7.5 V 10.5", c: "ink" },
        { d: "M6.5 10.5 H 17.5 A 2 2 0 0 1 19.5 12.5 V 17.5 A 2 2 0 0 1 17.5 19.5 H 6.5 A 2 2 0 0 1 4.5 17.5 V 12.5 A 2 2 0 0 1 6.5 10.5 Z", c: "ink" },
        { type: "circle", cx: 12, cy: 15, r: 1.5, fill: "accent" }
    ],
    moon: [
        { d: "M19 14.5 A 8 8 0 0 1 9.5 5 A 8.5 8.5 0 1 0 19 14.5 Z", c: "ink" },
        { type: "circle", cx: 17.5, cy: 6.5, r: 1.5, fill: "accent" }
    ],
    refresh: [
        { d: "M20 12 A 8 8 0 1 1 16.8 5.6", c: "ink" },
        { d: "M20 4.5 V 10 H 14.5", c: "accent" }
    ],
    file: [
        { d: "M7 3.5 H17 A 2 2 0 0 1 19 5.5 V 18.5 A 2 2 0 0 1 17 20.5 H 7 A 2 2 0 0 1 5 18.5 V 5.5 A 2 2 0 0 1 7 3.5 Z", c: "ink" },
        { d: "M9.5 9.5 L 8 12 L 9.5 14.5", c: "accent" },
        { d: "M12 10 H 16", c: "ink" },
        { d: "M12 14.5 H 16", c: "ink" }
    ],
    image: [
        { d: "M5.5 5 H18.5 A 2 2 0 0 1 20.5 7 V 17 A 2 2 0 0 1 18.5 19 H 5.5 A 2 2 0 0 1 3.5 17 V 7 A 2 2 0 0 1 5.5 5 Z", c: "ink" },
        { d: "M3.5 15.5 L 8.5 11.5 L 12.5 15 L 15.5 12.5 L 20.5 16.5", c: "ink" },
        { type: "circle", cx: 8.5, cy: 9.5, r: 1.75, fill: "accent" }
    ]
};
