.pragma library

// A transparent image → shapes you can edit and colour.
//
// The idea is that a logo you already have should not have to be
// redrawn. What comes back is not a picture pasted into the icon: it is
// ordinary `path` shapes in the same 24-unit grid as everything else, so
// they rotate, they take ink or accent like any other shape, and they
// follow the shell's accent for ever after — which is the whole point,
// and the thing an imported PNG could never do.
//
// The method is the oldest one there is, and the one that suits a flat
// logo: threshold the alpha, walk the boundary between inside and
// outside, then throw away the points that were only there because
// pixels are square.
//
//   1. alpha ≥ threshold is "inside"
//   2. every edge between an inside pixel and an outside one is a piece
//      of boundary; stitched end to end they form closed loops
//   3. Douglas–Peucker drops the points that lie on a line anyway,
//      which is most of them — a staircase becomes the diagonal it was
//      always meant to be
//   4. loops are grouped: an outer loop plus whatever loops sit inside
//      it are one shape, so the hole in a letter O is a hole and not a
//      second blob
//
// Then the points are joined with curves rather than straight lines,
// because a polygon is never smooth: the circle in a logo came back
// visibly faceted at every tolerance that was not also fine enough to
// keep the staircase. Where three points turn gently the middle one is
// given a pair of bezier handles along the line between its neighbours,
// which is the standard Catmull-Rom fit; where they turn sharply it is
// left a corner, so the square end of a bar stays square.
//
// The result is ordinary `path` shapes — the same ones the pen tool
// makes — so every node and every handle can be dragged afterwards.

// ── loops ─────────────────────────────────────────────────────────────

// Every boundary edge, as a directed segment, wound so that the inside
// is consistently on one side. Consistency is what lets the loops be
// told apart later: outer loops come out one way round and holes the
// other, and their signed areas say which is which.
function boundaryEdges(inside, w, h) {
    var edges = {};
    var key = function (x, y) { return x + "," + y; };
    var add = function (x0, y0, x1, y1) {
        var k = key(x0, y0);
        if (!edges[k]) edges[k] = [];
        edges[k].push({ x: x1, y: y1 });
    };
    var at = function (x, y) {
        return x >= 0 && y >= 0 && x < w && y < h && inside[y * w + x];
    };

    for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
            if (!at(x, y)) continue;
            // Clockwise around a filled cell, so an outer boundary is
            // clockwise and a hole, walked with the inside still on the
            // same hand, comes out anticlockwise.
            if (!at(x, y - 1)) add(x, y, x + 1, y);
            if (!at(x + 1, y)) add(x + 1, y, x + 1, y + 1);
            if (!at(x, y + 1)) add(x + 1, y + 1, x, y + 1);
            if (!at(x - 1, y)) add(x, y + 1, x, y);
        }
    }
    return edges;
}

function stitch(edges) {
    var loops = [];
    for (var start in edges) {
        while (edges[start] && edges[start].length > 0) {
            var loop = [];
            var parts = start.split(",");
            var cx = parseInt(parts[0], 10), cy = parseInt(parts[1], 10);
            var guard = 0;
            while (guard++ < 1000000) {
                var k = cx + "," + cy;
                var outs = edges[k];
                if (!outs || outs.length === 0) break;
                var next = outs.pop();
                loop.push({ x: cx, y: cy });
                cx = next.x; cy = next.y;
                if (cx + "," + cy === start) break;
            }
            if (loop.length >= 4) loops.push(loop);
        }
    }
    return loops;
}

// ── simplification ────────────────────────────────────────────────────

function perpDistance(p, a, b) {
    var vx = b.x - a.x, vy = b.y - a.y;
    var len = Math.hypot(vx, vy);
    if (len === 0) return Math.hypot(p.x - a.x, p.y - a.y);
    return Math.abs((p.x - a.x) * vy - (p.y - a.y) * vx) / len;
}

// Douglas–Peucker, iterative rather than recursive: a traced loop can be
// thousands of points long and a recursion that deep is a stack
// overflow on some of them and not on others, which is the worst kind of
// bug to have in something that runs on whatever image you hand it.
function simplify(points, eps) {
    if (points.length < 3) return points.slice();
    var keep = new Array(points.length);
    for (var i = 0; i < points.length; i++) keep[i] = false;
    keep[0] = keep[points.length - 1] = true;

    var stack = [[0, points.length - 1]];
    while (stack.length > 0) {
        var range = stack.pop();
        var first = range[0], last = range[1];
        var worst = 0, at = -1;
        for (var j = first + 1; j < last; j++) {
            var d = perpDistance(points[j], points[first], points[last]);
            if (d > worst) { worst = d; at = j; }
        }
        if (worst > eps && at > 0) {
            keep[at] = true;
            stack.push([first, at]);
            stack.push([at, last]);
        }
    }

    var out = [];
    for (var k = 0; k < points.length; k++) if (keep[k]) out.push(points[k]);
    return out;
}

// Douglas–Peucker pins the first and last point, which on a loop are
// the same place — so whatever corner the walk happened to start at
// survives even when it is in the middle of a straight run, and so does
// its duplicate. A square came out with five nodes and two of them on
// top of each other. This walks the closed ring afterwards and drops any
// point its neighbours already imply.
function pruneClosed(pts, eps) {
    var out = pts.slice();
    // The loop returns to its start; keep one of them.
    if (out.length > 1) {
        var a = out[0], b = out[out.length - 1];
        if (Math.abs(a.x - b.x) < 1e-9 && Math.abs(a.y - b.y) < 1e-9) out.pop();
    }
    var changed = true;
    while (changed && out.length > 3) {
        changed = false;
        for (var i = 0; i < out.length; i++) {
            var prev = out[(i - 1 + out.length) % out.length];
            var next = out[(i + 1) % out.length];
            if (perpDistance(out[i], prev, next) <= eps) {
                out.splice(i, 1);
                changed = true;
                break;
            }
        }
    }
    return out;
}

// Straight lines through the simplified points, turned into curves.
//
// Each node gets handles pointing along the line between its
// neighbours, a third of the way to each — the usual Catmull-Rom to
// bezier conversion, which passes exactly through every point rather
// than near them. A node whose two segments turn by more than
// `cornerDeg` keeps its corner: that is the difference between the
// round end of a logo and the square end of a bar, and smoothing both
// would lose it.
function smoothLoop(pts, closed, cornerDeg) {
    var n = pts.length;
    var out = [];
    for (var i = 0; i < n; i++) {
        var p = pts[i];
        var prev = closed ? pts[(i - 1 + n) % n] : pts[Math.max(0, i - 1)];
        var next = closed ? pts[(i + 1) % n] : pts[Math.min(n - 1, i + 1)];
        var node = { x: p.x, y: p.y };

        var ends = !closed && (i === 0 || i === n - 1);
        if (ends) { node.corner = true; out.push(node); continue; }

        var ax = p.x - prev.x, ay = p.y - prev.y;
        var bx = next.x - p.x, by = next.y - p.y;
        var la = Math.hypot(ax, ay), lb = Math.hypot(bx, by);
        if (la === 0 || lb === 0) { node.corner = true; out.push(node); continue; }

        // The angle between coming in and going out. Zero is straight
        // on; 180 is doubling back.
        var cosT = (ax * bx + ay * by) / (la * lb);
        cosT = Math.max(-1, Math.min(1, cosT));
        var turn = Math.acos(cosT) * 180 / Math.PI;
        if (turn > cornerDeg) { node.corner = true; out.push(node); continue; }

        // Along prev → next, scaled to each side's own segment so a
        // short segment does not get a handle longer than itself, which
        // is what makes a curve loop back on itself.
        var dx = next.x - prev.x, dy = next.y - prev.y;
        var dl = Math.hypot(dx, dy) || 1;
        dx /= dl; dy /= dl;
        node.hi = { x: p.x - dx * la / 3, y: p.y - dy * la / 3 };
        node.ho = { x: p.x + dx * lb / 3, y: p.y + dy * lb / 3 };
        out.push(node);
    }
    return out;
}

function signedArea(loop) {
    var a = 0;
    for (var i = 0, j = loop.length - 1; i < loop.length; j = i++)
        a += (loop[j].x * loop[i].y) - (loop[i].x * loop[j].y);
    return a / 2;
}

function pointInLoop(p, loop) {
    var inside = false;
    for (var i = 0, j = loop.length - 1; i < loop.length; j = i++) {
        var a = loop[i], b = loop[j];
        if ((a.y > p.y) !== (b.y > p.y)
            && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x)
            inside = !inside;
    }
    return inside;
}

// ── the whole thing ───────────────────────────────────────────────────

// `alpha` is one byte per pixel, row major. Returns shapes in grid
// units, centred and scaled to fit, or an empty list with a reason.
function trace(alpha, w, h, opts) {
    opts = opts || {};
    var threshold = opts.threshold === undefined ? 128 : opts.threshold;
    var units = opts.units || 24;
    // The pack leaves about two units of air around a glyph; a logo
    // traced flush to the edge sits noticeably larger than everything
    // beside it in the dock.
    var margin = opts.margin === undefined ? 2 : opts.margin;
    var detail = opts.detail === undefined ? 1 : opts.detail;
    // The smallest blob worth keeping, as a fraction of the image. Below
    // this it is a stray pixel, a compression artefact or a shadow, and
    // it would come out as a speck nobody can select.
    var minArea = opts.minArea === undefined ? 0.0006 : opts.minArea;
    // How sharp a turn has to be to stay a corner. 42° keeps the
    // corners of a box and rounds everything a circle is made of.
    var cornerDeg = opts.cornerDeg === undefined ? 42 : opts.cornerDeg;
    var smooth = opts.smooth !== false;

    var inside = new Array(w * h);
    var any = false;
    var x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (var i = 0; i < w * h; i++) {
        var on = alpha[i] >= threshold;
        inside[i] = on;
        if (on) {
            any = true;
            var px = i % w, py = (i - px) / w;
            if (px < x0) x0 = px;
            if (px > x1) x1 = px;
            if (py < y0) y0 = py;
            if (py > y1) y1 = py;
        }
    }
    if (!any)
        return { shapes: [], error: "Every pixel is transparent — is this the right image?" };

    var loops = stitch(boundaryEdges(inside, w, h));
    if (loops.length === 0) return { shapes: [], error: "Nothing to trace." };

    // A caller that already knows where these pixels belong says so.
    // `opts.map` takes a point — { x, y } in pixels — and returns one in
    // whatever coordinates it wants, exactly like the fitting map below.
    // and nothing is fitted or recentred. The lasso split works this
    // way: it rasterises a shape that is already on the grid, cuts it,
    // and traces the pieces back — and a piece that was refitted to
    // fill the grid would no longer line up with the shape it came out
    // of, which is the one thing it has to do.
    if (opts.map) return { shapes: tracePieces(loops, opts.map, w, h, opts) };

    // Fit the drawing into the grid, keeping its proportions.
    var bw = (x1 - x0 + 1), bh = (y1 - y0 + 1);
    var span = units - margin * 2;
    var scale = span / Math.max(bw, bh);
    var offX = (units - bw * scale) / 2 - x0 * scale;
    var offY = (units - bh * scale) / 2 - y0 * scale;
    var toGrid = function (p) {
        return { x: Math.round((p.x * scale + offX) * 100) / 100,
                 y: Math.round((p.y * scale + offY) * 100) / 100 };
    };

    return { shapes: tracePieces(loops, toGrid, w, h, opts) };
}

// Loops in pixels → shapes in whatever coordinates `toGrid` maps to.
function tracePieces(loops, toGrid, w, h, opts) {
    var detail = opts.detail === undefined ? 1 : opts.detail;
    var minArea = opts.minArea === undefined ? 0.0006 : opts.minArea;
    var cornerDeg = opts.cornerDeg === undefined ? 42 : opts.cornerDeg;
    var smooth = opts.smooth !== false;
    // 1.2, with curves fitted afterwards. Straight lines needed a finer
    // tolerance than this to look smooth and a coarser one to be
    // editable, and there was no value that was both: at 0.75 a traced
    // circle was 64 nodes with visible steps, at 1.4 it was 21 nodes and
    // visibly a polygon. Curves make the node count a question of how
    // much of the shape you want to be able to grab, which is what it
    // should have been.
    var eps = 1.2 / Math.max(0.1, detail);
    var area = w * h;
    var outers = [], holes = [];
    for (var l = 0; l < loops.length; l++) {
        var a = signedArea(loops[l]);
        if (Math.abs(a) < area * minArea) continue;
        var pts = pruneClosed(simplify(loops[l], eps), eps);
        if (pts.length < 3) continue;
        (a > 0 ? outers : holes).push({ pts: pts, area: Math.abs(a) });
    }
    if (outers.length === 0)
        return [];

    // Biggest first, so the shape list reads outside in and the largest
    // part of a logo is the one selected first.
    outers.sort(function (p, q) { return q.area - p.area; });

    var shapes = [];
    for (var o = 0; o < outers.length; o++) {
        var outer = outers[o];
        var mine = [];
        for (var hI = 0; hI < holes.length; hI++) {
            var hole = holes[hI];
            if (hole.used) continue;
            if (!pointInLoop(hole.pts[0], outer.pts)) continue;
            hole.used = true;
            var hn = hole.pts.map(toGrid).map(function (p) {
                return { x: p.x, y: p.y, corner: true };
            });
            mine.push(smooth ? smoothLoop(hn, true, cornerDeg) : hn);
        }
        shapes.push({
            kind: "path",
            c: "ink",
            sw: 2,
            closed: true,
            fill: true,
            nodes: (function () {
                var pts = outer.pts.map(toGrid).map(function (p) {
                    return { x: p.x, y: p.y, corner: true };
                });
                return smooth ? smoothLoop(pts, true, cornerDeg) : pts;
            })(),
            holes: mine.length > 0 ? mine : undefined
        });
    }
    return shapes;
}
