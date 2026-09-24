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
//     kind   line | rect | circle | ellipse | arc | poly | path | dot
//     c      "ink" | "acc"          which colour it takes
//     sw     2 | 3                  stroke weight, as the pack uses
//
// The weight is `sw` and not `w` because a rect's width is `w`: one
// letter shared between "this shape is 14 units across" and "draw it
// with a 14-wide pen" is a bug with a long fuse.
//     fill   true on a filled shape, which MonoIcon only draws in accent
//     rot    degrees clockwise about the shape's own centre, optional
//
// `path` is the one that is not a primitive: a list of nodes, each with
// a point and optionally a pair of bezier handles, open or closed. It is
// there because the primitives run out — the pack's own `music`,
// `stickyNote` and `pdf` are shapes no combination of boxes and arcs
// makes — and because "draw the outline you actually want" is the thing
// a shape composer cannot otherwise do.
//
//   { kind: "path", closed: false, nodes: [
//       { x, y },                          a corner
//       { x, y, hi: {x,y}, ho: {x,y} }     handles in and out
//   ], holes: [ [ …nodes… ], … ] }
//
// `holes` are further closed subpaths inside the first, emitted after
// it. They exist because a traced logo has them — the middle of a
// letter O — and under the odd-even fill rule MonoIcon uses, a subpath
// inside another punches through it.
//
// Handles are absolute points, not offsets, because every one of them is
// something you drag: an offset would have to be re-derived from its
// node on every mouse event, and the node moves too.
//
// Geometry is in the pack's authored units: a 24x24 grid, origin top
// left, y downwards.

// Two decimals. The grid snaps to halves and quarters, so this is exact
// for anything the maker can draw — and it keeps a dragged arc from
// writing seventeen digits of floating point into the file.
function n(v) {
    return Math.round(v * 100) / 100;
}

// The point a shape turns about. Its own middle in every case — an icon
// on a 24 grid has no use for an arbitrary pivot, and a pivot you cannot
// see is a pivot you cannot aim.
function centreOf(s) {
    switch (s.kind) {
    case "line":   return { x: (s.x1 + s.x2) / 2, y: (s.y1 + s.y2) / 2 };
    case "rect":   return { x: s.x + s.w / 2, y: s.y + s.h / 2 };
    case "poly": {
        var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
        for (var i = 0; i + 1 < s.pts.length; i += 2) {
            x0 = Math.min(x0, s.pts[i]);     x1 = Math.max(x1, s.pts[i]);
            y0 = Math.min(y0, s.pts[i + 1]); y1 = Math.max(y1, s.pts[i + 1]);
        }
        return { x: (x0 + x1) / 2, y: (y0 + y1) / 2 };
    }
    case "path": {
        var a0 = Infinity, b0 = Infinity, a1 = -Infinity, b1 = -Infinity;
        for (var j = 0; j < (s.nodes || []).length; j++) {
            a0 = Math.min(a0, s.nodes[j].x); a1 = Math.max(a1, s.nodes[j].x);
            b0 = Math.min(b0, s.nodes[j].y); b1 = Math.max(b1, s.nodes[j].y);
        }
        if (a0 === Infinity) return { x: 12, y: 12 };
        return { x: (a0 + a1) / 2, y: (b0 + b1) / 2 };
    }
    }
    return { x: s.cx, y: s.cy };    // circle, ellipse, arc, dot
}

// Maps a point from the shape's own frame into the grid, applying its
// rotation. Identity when there is none, which is most of the time and
// keeps the emitted path for an unrotated shape exactly what it always
// was — icons already saved do not change under this.
function mapperFor(s) {
    var rot = s.rot || 0;
    if (!rot) return function (x, y) { return { x: x, y: y }; };
    var c = centreOf(s);
    var a = rot * Math.PI / 180, cos = Math.cos(a), sin = Math.sin(a);
    return function (x, y) {
        var dx = x - c.x, dy = y - c.y;
        return { x: c.x + dx * cos - dy * sin, y: c.y + dx * sin + dy * cos };
    };
}

// And back the other way, for turning a pointer position into the
// shape's own coordinates — which is how a rotated shape is hit tested
// and how its handles are dragged.
function unmapperFor(s) {
    var rot = s.rot || 0;
    if (!rot) return function (x, y) { return { x: x, y: y }; };
    var c = centreOf(s);
    var a = -rot * Math.PI / 180, cos = Math.cos(a), sin = Math.sin(a);
    return function (x, y) {
        var dx = x - c.x, dy = y - c.y;
        return { x: c.x + dx * cos - dy * sin, y: c.y + dx * sin + dy * cos };
    };
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

// An SVG arc has an x-axis-rotation of its own, so a turned ellipse is
// the same two arcs with the angle written into them — no approximation
// and no extra commands.
function ellipsePathRotated(cx, cy, rx, ry, rot, map) {
    var l = map(cx - rx, cy), r = map(cx + rx, cy);
    return "M" + n(l.x) + " " + n(l.y)
        + "A" + n(rx) + " " + n(ry) + " " + n(rot) + " 1 0 " + n(r.x) + " " + n(r.y)
        + "A" + n(rx) + " " + n(ry) + " " + n(rot) + " 1 0 " + n(l.x) + " " + n(l.y) + "Z";
}

function ellipsePath(cx, cy, rx, ry) {
    return "M" + n(cx - rx) + " " + n(cy)
        + "A" + n(rx) + " " + n(ry) + " 0 1 0 " + n(cx + rx) + " " + n(cy)
        + "A" + n(rx) + " " + n(ry) + " 0 1 0 " + n(cx - rx) + " " + n(cy) + "Z";
}

// The rotated form cannot use H and V, which mean "horizontal" and
// "vertical" and stop being either once the box is turned. The corner
// arcs stay circular under rotation, so they keep their radius and only
// their endpoints move — and the arc's own x-axis-rotation carries the
// angle for the ellipse case below, where it does matter.
function rectPathRotated(x, y, w, h, r, map, rot) {
    var x2 = x + w, y2 = y + h;
    r = Math.max(0, Math.min(r, Math.min(w, h) / 2));
    var P = function (px, py) { var q = map(px, py); return n(q.x) + " " + n(q.y); };
    if (r <= 0)
        return "M" + P(x, y) + "L" + P(x2, y) + "L" + P(x2, y2) + "L" + P(x, y2) + "Z";
    var A = " 0 0 1 ";
    return "M" + P(x + r, y)
        + "L" + P(x2 - r, y) + "A" + n(r) + " " + n(r) + A + P(x2, y + r)
        + "L" + P(x2, y2 - r) + "A" + n(r) + " " + n(r) + A + P(x2 - r, y2)
        + "L" + P(x + r, y2) + "A" + n(r) + " " + n(r) + A + P(x, y2 - r)
        + "L" + P(x, y + r) + "A" + n(r) + " " + n(r) + A + P(x + r, y) + "Z";
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

// One segment, straight or curved depending on whether the two nodes it
// joins have handles facing each other.
function segmentTo(a, b, map) {
    var pb = map(b.x, b.y);
    if (!a.ho && !b.hi) return "L" + n(pb.x) + " " + n(pb.y);
    var c1 = a.ho ? map(a.ho.x, a.ho.y) : map(a.x, a.y);
    var c2 = b.hi ? map(b.hi.x, b.hi.y) : map(b.x, b.y);
    return "C" + n(c1.x) + " " + n(c1.y) + " " + n(c2.x) + " " + n(c2.y)
               + " " + n(pb.x) + " " + n(pb.y);
}

function nodePath(nodes, closed, map) {
    if (!nodes || nodes.length < 2) return "";
    var p0 = map(nodes[0].x, nodes[0].y);
    var d = "M" + n(p0.x) + " " + n(p0.y);
    for (var i = 1; i < nodes.length; i++)
        d += segmentTo(nodes[i - 1], nodes[i], map);
    if (closed && nodes.length > 2) {
        d += segmentTo(nodes[nodes.length - 1], nodes[0], map);
        d += "Z";
    }
    return d;
}

function pathFor(s) {
    if (!s) return "";
    var rot = s.rot || 0;
    var map = mapperFor(s);
    switch (s.kind) {
    case "line": {
        var a = map(s.x1, s.y1), b = map(s.x2, s.y2);
        return "M" + n(a.x) + " " + n(a.y) + "L" + n(b.x) + " " + n(b.y);
    }
    case "rect":
        return rot ? rectPathRotated(s.x, s.y, s.w, s.h, s.r || 0, map, rot)
                   : rectPath(s.x, s.y, s.w, s.h, s.r || 0);
    // A circle turned about its own centre is the same circle.
    case "circle":  return circlePath(s.cx, s.cy, s.r);
    case "ellipse":
        return rot ? ellipsePathRotated(s.cx, s.cy, s.rx, s.ry, rot, map)
                   : ellipsePath(s.cx, s.cy, s.rx, s.ry);
    // Likewise an arc: turning it is adding to both its angles.
    case "arc":     return arcPath(s.cx, s.cy, s.r, s.a0 + rot, s.a1 + rot);
    case "poly": {
        var pts = [];
        for (var i = 0; i + 1 < s.pts.length; i += 2) {
            var q = map(s.pts[i], s.pts[i + 1]);
            pts.push(q.x, q.y);
        }
        return polyPath(pts, s.closed === true);
    }
    case "path": {
        var d = nodePath(s.nodes, s.closed === true, map);
        for (var hI = 0; hI < (s.holes || []).length; hI++) {
            var hd = nodePath(s.holes[hI], true, map);
            if (hd !== "") d += " " + hd;
        }
        return d;
    }
    // A dot is not a path. It is a filled disc, and MonoIcon draws those
    // as rectangles with a radius rather than as geometry, because at
    // 1px across a stroked circle is a smudge and a filled one is a dot.
    case "dot":     return "";
    }
    return "";
}

// Which of MonoIcon's five path buckets a shape belongs in.
//
// A filled shape goes to whichever fill bucket matches its colour. It
// used to go to `fill` regardless, because that was the only one there
// was, and the maker had to say "always accent" next to the toggle.
function bucketFor(s) {
    if (s.kind === "dot") return "dots";
    if (s.fill) return s.c === "acc" ? "fill" : "fillInk";
    var base = s.c === "acc" ? "acc" : "ink";
    return s.sw === 3 ? base + "W" : base;
}

// The whole drawing, as a glyph. `shapes` rides along so the maker can
// open it again; see UserIcons.qml.
function compose(shapes) {
    var out = { shapes: shapes ? shapes.slice() : [] };
    var parts = { ink: [], acc: [], inkW: [], accW: [], fill: [], fillInk: [] };
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
    return !!(g.ink || g.acc || g.inkW || g.accW || g.fill || g.fillInk
              || (g.dots && g.dots.length > 0));
}
