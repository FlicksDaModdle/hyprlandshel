.pragma library

// Cutting a shape in two with a lasso.
//
// The point of it is colour. A logo that arrives as one silhouette can
// only be one colour, and "make that bit the accent" is the first thing
// anyone wants — so a region is drawn round and what is inside becomes a
// shape of its own, to be given ink or accent like any other.
//
// Two quite different jobs, depending on what is being cut:
//
//   A filled shape is an area, and cutting an area means intersecting
//   it with the lasso. Rather than a polygon boolean — which is a great
//   deal of code to get subtly wrong on self-touching outlines, and a
//   traced logo is full of those — the shape is rasterised on a fine
//   grid, the two halves are masked apart, and each is traced back with
//   the tracer that is already here and already tested. The pieces come
//   back as smooth editable paths, in the same coordinates they went in.
//
//   An outline is a line, and cutting a line means cutting its list of
//   nodes: the run that falls inside the lasso becomes one path and the
//   rest becomes another. No raster, and the curves survive exactly.

function pointInPoly(x, y, pts) {
    var inside = false;
    for (var i = 0, j = pts.length - 1; i < pts.length; j = i++) {
        var a = pts[i], b = pts[j];
        if ((a.y > y) !== (b.y > y)
            && x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x)
            inside = !inside;
    }
    return inside;
}

// A node list, flattened to straight segments. Curves are walked at
// twelve steps, which on a 24-unit grid is finer than anything that can
// be seen.
function flatten(nodes, closed) {
    var out = [];
    if (!nodes || nodes.length === 0) return out;
    var seg = function (a, b) {
        if (!a.ho && !b.hi) { out.push({ x: b.x, y: b.y }); return; }
        var c1 = a.ho || { x: a.x, y: a.y };
        var c2 = b.hi || { x: b.x, y: b.y };
        for (var k = 1; k <= 12; k++) {
            var t = k / 12, u = 1 - t;
            out.push({
                x: u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x,
                y: u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y
            });
        }
    };
    out.push({ x: nodes[0].x, y: nodes[0].y });
    for (var i = 1; i < nodes.length; i++) seg(nodes[i - 1], nodes[i]);
    if (closed && nodes.length > 2) seg(nodes[nodes.length - 1], nodes[0]);
    return out;
}

function ringsOf(shape) {
    var rings = [flatten(shape.nodes, true)];
    for (var i = 0; i < (shape.holes || []).length; i++)
        rings.push(flatten(shape.holes[i], true));
    return rings;
}

// Odd-even against every ring, which is the rule the renderer fills by:
// a point inside a hole is outside the shape.
function insideRings(x, y, rings) {
    var n = 0;
    for (var i = 0; i < rings.length; i++)
        if (pointInPoly(x, y, rings[i])) n++;
    return (n % 2) === 1;
}

// Carries everything about a shape except where it is.
function like(shape, extra) {
    var out = { kind: "path", c: shape.c, sw: shape.sw, closed: true };
    if (shape.fill) out.fill = true;
    if (shape.rot) out.rot = shape.rot;
    for (var k in extra) out[k] = extra[k];
    return out;
}

// ── the filled case ───────────────────────────────────────────────────

function splitFilled(shape, lasso, Trace, opts) {
    opts = opts || {};
    var units = opts.units || 24;
    // Cells per grid unit. Six is 144 across, which resolves a tenth of
    // a unit — finer than the quarter the grid itself snaps to.
    var S = opts.cells || 6;
    var n = units * S;

    // How far each half reaches past the cut, in cells. Two is a third
    // of a unit at six cells to the unit, which covers the slack the
    // tracer's smoothing introduces on both sides at once.
    var bleed = opts.bleed === undefined ? 2 : opts.bleed;

    var rings = ringsOf(shape);
    var inMask = new Array(n * n), outMask = new Array(n * n);
    var shapeMask = new Array(n * n);
    var anyIn = false, anyOut = false;

    for (var j = 0; j < n; j++) {
        for (var i = 0; i < n; i++) {
            // The centre of the cell, so a boundary running along a
            // grid line does not land ambiguously on it.
            var x = (i + 0.5) / S, y = (j + 0.5) / S;
            var at = j * n + i;
            if (!insideRings(x, y, rings)) {
                inMask[at] = 0; outMask[at] = 0; shapeMask[at] = 0;
                continue;
            }
            shapeMask[at] = 255;
            if (pointInPoly(x, y, lasso)) { inMask[at] = 255; outMask[at] = 0; anyIn = true; }
            else { inMask[at] = 0; outMask[at] = 255; anyOut = true; }
        }
    }

    if (!anyIn) return { error: "That lasso did not catch any of the shape." };
    if (!anyOut) return { error: "That lasso caught the whole shape — nothing to split off." };

    // The two halves are grown back into each other along the cut.
    //
    // Traced separately, each piece's boundary is pulled off the seam by
    // its own simplification and corner-rounding — a fifth of a unit
    // each way — so the two came apart and the background showed through
    // between them. An overlap cannot show: one piece is painted over
    // the other and the join disappears. A gap always shows.
    //
    // Only into cells the shape itself covers, so the silhouette's own
    // outline is untouched and only the seam moves.
    var grow = function (mask) {
        var from = mask.slice();
        for (var pass = 0; pass < bleed; pass++) {
            var prev = from.slice();
            for (var y = 0; y < n; y++) {
                for (var x = 0; x < n; x++) {
                    var at = y * n + x;
                    if (prev[at]) continue;
                    if (!shapeMask[at]) continue;     // never past the outline
                    if ((x > 0 && prev[at - 1]) || (x < n - 1 && prev[at + 1])
                        || (y > 0 && prev[at - n]) || (y < n - 1 && prev[at + n]))
                        from[at] = 255;
                }
            }
        }
        return from;
    };
    inMask = grow(inMask);
    outMask = grow(outMask);

    var map = function (p) { return { x: p.x / S, y: p.y / S }; };
    var traceOpts = { map: map, detail: opts.detail || 1,
                      // Smaller than the tracer's default, because a
                      // sliver deliberately lassoed off a logo is
                      // supposed to survive.
                      minArea: 0.00005 };

    var inside = Trace.trace(inMask, n, n, traceOpts);
    var outside = Trace.trace(outMask, n, n, traceOpts);
    if (inside.error || !inside.shapes.length) return { error: "Nothing came out of the lasso." };
    if (outside.error || !outside.shapes.length) return { error: "Nothing was left outside it." };

    var dress = function (list) {
        var out = [];
        for (var i = 0; i < list.length; i++)
            out.push(like(shape, { nodes: list[i].nodes, holes: list[i].holes }));
        return out;
    };
    return { inside: dress(inside.shapes), outside: dress(outside.shapes) };
}

// ── the outline case ──────────────────────────────────────────────────

function splitOutline(shape, lasso) {
    var nodes = shape.nodes || [];
    if (nodes.length < 2) return { error: "There is nothing to split." };

    var flags = [];
    var anyIn = false, anyOut = false;
    for (var i = 0; i < nodes.length; i++) {
        flags.push(pointInPoly(nodes[i].x, nodes[i].y, lasso));
        if (flags[i]) anyIn = true; else anyOut = true;
    }
    if (!anyIn) return { error: "That lasso did not catch any of the line." };
    if (!anyOut) return { error: "That lasso caught the whole line — nothing to split off." };

    // Runs of consecutive nodes on the same side. A closed path is
    // walked round, so a run may wrap past the end.
    var runs = [];
    var start = 0;
    if (shape.closed) {
        while (start < nodes.length && flags[start] === flags[nodes.length - 1]) start++;
        if (start >= nodes.length) start = 0;
    }
    var cur = null;
    for (var k = 0; k < nodes.length; k++) {
        var at = (start + k) % nodes.length;
        if (!cur || cur.inside !== flags[at]) {
            cur = { inside: flags[at], nodes: [] };
            runs.push(cur);
        }
        cur.nodes.push(nodes[at]);
    }

    // A run of one node draws nothing, so it joins its neighbour rather
    // than becoming a shape with no length.
    for (var r = runs.length - 1; r >= 1; r--)
        if (runs[r].nodes.length < 2) {
            runs[r - 1].nodes = runs[r - 1].nodes.concat(runs[r].nodes);
            runs.splice(r, 1);
        }

    var inside = [], outside = [];
    for (var q = 0; q < runs.length; q++) {
        if (runs[q].nodes.length < 2) continue;
        var piece = like(shape, { nodes: runs[q].nodes, closed: false });
        delete piece.fill;
        (runs[q].inside ? inside : outside).push(piece);
    }
    if (inside.length === 0 || outside.length === 0)
        return { error: "There was not enough on one side of that lasso to split." };
    return { inside: inside, outside: outside };
}

// `Trace` is passed in rather than imported: a .pragma library cannot
// import another one, and this needs the tracer for the filled case.
function split(shape, lasso, Trace, opts) {
    if (!shape) return { error: "Nothing selected to split." };
    if (!lasso || lasso.length < 3) return { error: "Draw a region to split with." };
    if (shape.kind === "dot") return { error: "A dot cannot be split." };

    // Anything that is not a path is turned into one first, so the two
    // halves are the same kind of thing whatever went in.
    if (shape.kind !== "path" && !shape.fill)
        return { error: "Only paths and filled shapes can be split — "
                        + "the pen tool makes paths out of anything." };

    return (shape.fill && shape.closed !== false)
           ? splitFilled(shape, lasso, Trace, opts)
           : splitOutline(shape, lasso);
}
