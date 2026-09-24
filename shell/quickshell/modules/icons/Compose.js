.pragma library

// Shapes → the path strings MonoIcon draws.
//
// The icon maker works in shapes: a line has two ends, a circle has a
// centre and a radius, and both can be dragged. MonoIcon does not — it
// paints five merged path strings and a list of dots, which is the right
// thing for something drawing eighty glyphs a frame and the wrong thing
// for something you are editing. This is the one-way street between
// them, and it runs on save.
//
// One-way is why a saved glyph keeps its shapes as well as its paths:
// nothing here can be undone. Given "M4 4 L20 20" there is no way back
// to the line that made it, let alone to which end you dragged.
//
// A shape is:
//
//   { kind, c, w, fill, … geometry }
//
//     kind   line | rect | circle | ellipse | arc | poly | dot
//     c      "ink" | "acc"          which colour it takes
//     sw     2 | 3                  stroke weight, as the pack uses
//
// The weight is `sw` and not `w` because a rect's width is `w`: one
// letter shared between "this shape is 14 units across" and "draw it
// with a 14-wide pen" is a bug with a long fuse.
//     fill   true on a filled shape, which MonoIcon only draws in accent
//
// Geometry is in the pack's authored units: a 24x24 grid, origin top
// left, y downwards.

// Two decimals. The grid snaps to halves and quarters, so this is exact
// for anything the maker can draw — and it keeps a dragged arc from
// writing seventeen digits of floating point into the file.
function n(v) {
    return Math.round(v * 100) / 100;
}

function polar(cx, cy, r, deg) {
    var a = deg * Math.PI / 180;
    return { x: cx + r * Math.cos(a), y: cy + r * Math.sin(a) };
}

// A full circle needs two half-arcs: one arc command cannot close on its
// own start point, because the start and end are then the same point and
// there is no way to say which way round. Same trick the pack uses.
function circlePath(cx, cy, r) {
    return "M" + n(cx - r) + " " + n(cy)
        + "A" + n(r) + " " + n(r) + " 0 1 0 " + n(cx + r) + " " + n(cy)
        + "A" + n(r) + " " + n(r) + " 0 1 0 " + n(cx - r) + " " + n(cy) + "Z";
}

function ellipsePath(cx, cy, rx, ry) {
    return "M" + n(cx - rx) + " " + n(cy)
        + "A" + n(rx) + " " + n(ry) + " 0 1 0 " + n(cx + rx) + " " + n(cy)
        + "A" + n(rx) + " " + n(ry) + " 0 1 0 " + n(cx - rx) + " " + n(cy) + "Z";
}

function rectPath(x, y, w, h, r) {
    var x2 = x + w, y2 = y + h;
    r = Math.max(0, Math.min(r, Math.min(w, h) / 2));
    if (r <= 0)
        return "M" + n(x) + " " + n(y) + "H" + n(x2) + "V" + n(y2) + "H" + n(x) + "Z";
    return "M" + n(x + r) + " " + n(y)
        + "H" + n(x2 - r) + "A" + n(r) + " " + n(r) + " 0 0 1 " + n(x2) + " " + n(y + r)
        + "V" + n(y2 - r) + "A" + n(r) + " " + n(r) + " 0 0 1 " + n(x2 - r) + " " + n(y2)
        + "H" + n(x + r) + "A" + n(r) + " " + n(r) + " 0 0 1 " + n(x) + " " + n(y2 - r)
        + "V" + n(y + r) + "A" + n(r) + " " + n(r) + " 0 0 1 " + n(x + r) + " " + n(y) + "Z";
}

// Angles in degrees, 0 pointing right and growing clockwise, because y
// runs down the grid. A sweep of 360 or more is a circle and is drawn as
// one, since an arc that ends where it starts draws nothing at all.
function arcPath(cx, cy, r, a0, a1) {
    var sweep = a1 - a0;
    if (Math.abs(sweep) >= 359.9) return circlePath(cx, cy, r);
    var p0 = polar(cx, cy, r, a0), p1 = polar(cx, cy, r, a1);
    var large = Math.abs(sweep) > 180 ? 1 : 0;
    var dir = sweep >= 0 ? 1 : 0;
    return "M" + n(p0.x) + " " + n(p0.y)
        + "A" + n(r) + " " + n(r) + " 0 " + large + " " + dir + " "
        + n(p1.x) + " " + n(p1.y);
}

function polyPath(pts, closed) {
    if (!pts || pts.length < 4) return "";
    var d = "M" + n(pts[0]) + " " + n(pts[1]);
    for (var i = 2; i + 1 < pts.length; i += 2)
        d += "L" + n(pts[i]) + " " + n(pts[i + 1]);
    return closed ? d + "Z" : d;
}

function pathFor(s) {
    if (!s) return "";
    switch (s.kind) {
    case "line":    return "M" + n(s.x1) + " " + n(s.y1) + "L" + n(s.x2) + " " + n(s.y2);
    case "rect":    return rectPath(s.x, s.y, s.w, s.h, s.r || 0);
    case "circle":  return circlePath(s.cx, s.cy, s.r);
    case "ellipse": return ellipsePath(s.cx, s.cy, s.rx, s.ry);
    case "arc":     return arcPath(s.cx, s.cy, s.r, s.a0, s.a1);
    case "poly":    return polyPath(s.pts, s.closed === true);
    // A dot is not a path. It is a filled disc, and MonoIcon draws those
    // as rectangles with a radius rather than as geometry, because at
    // 1px across a stroked circle is a smudge and a filled one is a dot.
    case "dot":     return "";
    }
    return "";
}

// Which of MonoIcon's five path buckets a shape belongs in.
//
// `fill` is accent-only there, so a filled shape is an accent shape
// whatever colour it was given — the maker greys the choice out rather
// than letting it lie.
function bucketFor(s) {
    if (s.kind === "dot") return "dots";
    if (s.fill) return "fill";
    var base = s.c === "acc" ? "acc" : "ink";
    return s.sw === 3 ? base + "W" : base;
}

// The whole drawing, as a glyph. `shapes` rides along so the maker can
// open it again; see UserIcons.qml.
function compose(shapes) {
    var out = { shapes: shapes ? shapes.slice() : [] };
    var parts = { ink: [], acc: [], inkW: [], accW: [], fill: [] };
    var dots = [];

    for (var i = 0; i < (shapes || []).length; i++) {
        var s = shapes[i];
        if (!s) continue;
        if (s.kind === "dot") {
            if (s.r > 0)
                dots.push({ cx: n(s.cx), cy: n(s.cy), r: n(s.r),
                            c: s.c === "acc" ? "acc" : "ink" });
            continue;
        }
        var d = pathFor(s);
        if (d !== "") parts[bucketFor(s)].push(d);
    }

    for (var k in parts)
        if (parts[k].length > 0) out[k] = parts[k].join(" ");
    if (dots.length > 0) out.dots = dots;
    return out;
}

// Is there anything to save? A glyph of nothing is refused by the store,
// so the maker should say so before it gets that far.
function draws(shapes) {
    var g = compose(shapes);
    return !!(g.ink || g.acc || g.inkW || g.accW || g.fill
              || (g.dots && g.dots.length > 0));
}
