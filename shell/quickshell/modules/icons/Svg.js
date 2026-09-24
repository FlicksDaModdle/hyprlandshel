.pragma library

// An SVG, read as what it already is.
//
// Tracing an SVG is throwing away the answer. The file is a list of
// curves; rasterising it to 96 pixels and walking the staircase back out
// gives an approximation of something that was exact to begin with, and
// every logo imported that way came out soft in the places it should be
// crisp. So SVG files are read, and only bitmaps are traced.
//
// What comes out is the same `path` shapes the pen tool makes: nodes
// with bezier handles, holes as further subpaths. So an imported logo is
// editable, takes ink or accent per piece, and follows the accent
// afterwards, exactly like one drawn by hand.
//
// This is not a browser. It understands the shapes a logo is actually
// made of — path, rect, circle, ellipse, line, polyline, polygon —
// inside groups, with transforms, and it ignores everything else rather
// than pretending. Text is the notable omission: a logo with live text
// in it has to be converted to outlines first, and is told so.

// ── numbers ───────────────────────────────────────────────────────────

function round(v) { return Math.round(v * 1000) / 1000; }

// SVG number lists are separated by commas, spaces, or nothing at all
// when the sign does the separating: "10-20" is two numbers, and so is
// "1e-3-4". Splitting on punctuation gets both wrong.
function numbers(str) {
    var out = [];
    var re = /[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?/g;
    var m;
    while ((m = re.exec(str)) !== null) out.push(parseFloat(m[0]));
    return out;
}

// ── transforms ────────────────────────────────────────────────────────
//
// Matrices as [a, b, c, d, e, f], the same six SVG uses.

function identity() { return [1, 0, 0, 1, 0, 0]; }

function multiply(m, n) {
    return [
        m[0] * n[0] + m[2] * n[1],
        m[1] * n[0] + m[3] * n[1],
        m[0] * n[2] + m[2] * n[3],
        m[1] * n[2] + m[3] * n[3],
        m[0] * n[4] + m[2] * n[5] + m[4],
        m[1] * n[4] + m[3] * n[5] + m[5]
    ];
}

function applyM(m, x, y) {
    return { x: m[0] * x + m[2] * y + m[4], y: m[1] * x + m[3] * y + m[5] };
}

function parseTransform(str) {
    var m = identity();
    if (!str) return m;
    var re = /(matrix|translate|scale|rotate|skewX|skewY)\s*\(([^)]*)\)/g;
    var t;
    while ((t = re.exec(str)) !== null) {
        var a = numbers(t[2]);
        switch (t[1]) {
        case "matrix":
            if (a.length >= 6) m = multiply(m, [a[0], a[1], a[2], a[3], a[4], a[5]]);
            break;
        case "translate":
            m = multiply(m, [1, 0, 0, 1, a[0] || 0, a.length > 1 ? a[1] : 0]);
            break;
        case "scale": {
            var sx = a.length > 0 ? a[0] : 1;
            var sy = a.length > 1 ? a[1] : sx;
            m = multiply(m, [sx, 0, 0, sy, 0, 0]);
            break;
        }
        case "rotate": {
            var r = (a[0] || 0) * Math.PI / 180;
            var cos = Math.cos(r), sin = Math.sin(r);
            if (a.length >= 3) {
                m = multiply(m, [1, 0, 0, 1, a[1], a[2]]);
                m = multiply(m, [cos, sin, -sin, cos, 0, 0]);
                m = multiply(m, [1, 0, 0, 1, -a[1], -a[2]]);
            } else {
                m = multiply(m, [cos, sin, -sin, cos, 0, 0]);
            }
            break;
        }
        case "skewX": m = multiply(m, [1, 0, Math.tan((a[0] || 0) * Math.PI / 180), 1, 0, 0]); break;
        case "skewY": m = multiply(m, [1, Math.tan((a[0] || 0) * Math.PI / 180), 0, 1, 0, 0]); break;
        }
    }
    return m;
}

// ── arcs ──────────────────────────────────────────────────────────────
//
// SVG's elliptical arc, turned into cubics. Nothing downstream speaks
// arc-with-flags, and a logo's rounded corner is usually written as one.
function arcToCubics(x0, y0, rx, ry, deg, large, sweep, x1, y1) {
    var out = [];
    if (rx === 0 || ry === 0) return out;
    rx = Math.abs(rx); ry = Math.abs(ry);
    var phi = deg * Math.PI / 180;
    var cosP = Math.cos(phi), sinP = Math.sin(phi);

    var dx2 = (x0 - x1) / 2, dy2 = (y0 - y1) / 2;
    var x1p = cosP * dx2 + sinP * dy2;
    var y1p = -sinP * dx2 + cosP * dy2;

    // An arc whose radii are too small to reach is grown until it does,
    // which is what the specification says to do rather than give up.
    var lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if (lambda > 1) {
        var s = Math.sqrt(lambda);
        rx *= s; ry *= s;
    }

    var sign = (large !== sweep) ? 1 : -1;
    var num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
    var den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    var co = sign * Math.sqrt(Math.max(0, num / den));
    var cxp = co * rx * y1p / ry;
    var cyp = -co * ry * x1p / rx;

    var cx = cosP * cxp - sinP * cyp + (x0 + x1) / 2;
    var cy = sinP * cxp + cosP * cyp + (y0 + y1) / 2;

    var angle = function (ux, uy, vx, vy) {
        var dot = ux * vx + uy * vy;
        var len = Math.sqrt(ux * ux + uy * uy) * Math.sqrt(vx * vx + vy * vy);
        var a = Math.acos(Math.max(-1, Math.min(1, dot / (len || 1))));
        return (ux * vy - uy * vx < 0) ? -a : a;
    };

    var theta = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
    var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                      (-x1p - cxp) / rx, (-y1p - cyp) / ry);
    if (!sweep && delta > 0) delta -= 2 * Math.PI;
    if (sweep && delta < 0) delta += 2 * Math.PI;

    // A quarter turn at a time: beyond that a cubic cannot follow an
    // ellipse closely enough to matter at any size this is drawn at.
    var segs = Math.ceil(Math.abs(delta / (Math.PI / 2)));
    var step = delta / segs;
    var t = 4 / 3 * Math.tan(step / 4);

    var from = theta;
    for (var i = 0; i < segs; i++) {
        var to = from + step;
        var cosA = Math.cos(from), sinA = Math.sin(from);
        var cosB = Math.cos(to), sinB = Math.sin(to);

        var p = function (ca, sa) {
            return { x: cx + rx * cosP * ca - ry * sinP * sa,
                     y: cy + rx * sinP * ca + ry * cosP * sa };
        };
        var d = function (ca, sa) {
            return { x: -rx * cosP * sa - ry * sinP * ca,
                     y: -rx * sinP * sa + ry * cosP * ca };
        };

        var pa = p(cosA, sinA), pb = p(cosB, sinB);
        var da = d(cosA, sinA), db = d(cosB, sinB);
        out.push({ c1: { x: pa.x + t * da.x, y: pa.y + t * da.y },
                   c2: { x: pb.x - t * db.x, y: pb.y - t * db.y },
                   p: pb });
        from = to;
    }
    return out;
}

// ── path data ─────────────────────────────────────────────────────────
//
// Returns a list of subpaths, each { nodes, closed }, in the file's own
// coordinates. Nodes carry absolute handles, like everything else here.
function parsePathData(d) {
    var subs = [];
    var nodes = [];
    var closed = false;
    var cx = 0, cy = 0, sx = 0, sy = 0;
    var lastC = null, lastQ = null;

    var flush = function () {
        if (nodes.length >= 2) subs.push({ nodes: nodes, closed: closed });
        nodes = [];
        closed = false;
    };
    var moveTo = function (x, y) {
        flush();
        cx = sx = x; cy = sy = y;
        nodes.push({ x: x, y: y, corner: true });
    };
    var lineTo = function (x, y) {
        cx = x; cy = y;
        nodes.push({ x: x, y: y, corner: true });
    };
    var curveTo = function (c1, c2, x, y) {
        if (nodes.length === 0) nodes.push({ x: cx, y: cy, corner: true });
        var from = nodes[nodes.length - 1];
        from.ho = { x: c1.x, y: c1.y };
        if (from.hi === undefined && from.corner !== false) from.corner = true;
        nodes.push({ x: x, y: y, hi: { x: c2.x, y: c2.y }, corner: true });
        cx = x; cy = y;
    };

    var re = /([MmLlHhVvCcSsQqTtAaZz])([^MmLlHhVvCcSsQqTtAaZz]*)/g;
    var seg;
    while ((seg = re.exec(d)) !== null) {
        var cmd = seg[1];
        var a = numbers(seg[2]);
        var rel = cmd === cmd.toLowerCase();
        var up = cmd.toUpperCase();
        var i = 0;

        if (up === "Z") {
            closed = true;
            cx = sx; cy = sy;
            flush();
            continue;
        }

        // A command may carry several sets of arguments; after the first,
        // M becomes L and m becomes l, which is easy to forget and shows
        // up as a logo made of disconnected pieces.
        var first = true;
        while (i < a.length) {
            switch (up) {
            case "M":
                if (first) {
                    moveTo(rel ? cx + a[i] : a[i], rel ? cy + a[i + 1] : a[i + 1]);
                } else {
                    lineTo(rel ? cx + a[i] : a[i], rel ? cy + a[i + 1] : a[i + 1]);
                }
                i += 2;
                break;
            case "L":
                lineTo(rel ? cx + a[i] : a[i], rel ? cy + a[i + 1] : a[i + 1]);
                i += 2;
                break;
            case "H":
                lineTo(rel ? cx + a[i] : a[i], cy);
                i += 1;
                break;
            case "V":
                lineTo(cx, rel ? cy + a[i] : a[i]);
                i += 1;
                break;
            case "C": {
                var c1 = { x: rel ? cx + a[i] : a[i], y: rel ? cy + a[i + 1] : a[i + 1] };
                var c2 = { x: rel ? cx + a[i + 2] : a[i + 2], y: rel ? cy + a[i + 3] : a[i + 3] };
                var ex = rel ? cx + a[i + 4] : a[i + 4], ey = rel ? cy + a[i + 5] : a[i + 5];
                curveTo(c1, c2, ex, ey);
                lastC = c2; lastQ = null;
                i += 6;
                break;
            }
            case "S": {
                // The reflection of the previous second control point,
                // or the current point when the last command was not a
                // cubic. Getting that fallback wrong bends every smooth
                // join in the file.
                var r1 = lastC ? { x: 2 * cx - lastC.x, y: 2 * cy - lastC.y }
                               : { x: cx, y: cy };
                var s2 = { x: rel ? cx + a[i] : a[i], y: rel ? cy + a[i + 1] : a[i + 1] };
                var sx2 = rel ? cx + a[i + 2] : a[i + 2], sy2 = rel ? cy + a[i + 3] : a[i + 3];
                curveTo(r1, s2, sx2, sy2);
                lastC = s2; lastQ = null;
                i += 4;
                break;
            }
            case "Q": {
                var q = { x: rel ? cx + a[i] : a[i], y: rel ? cy + a[i + 1] : a[i + 1] };
                var qx = rel ? cx + a[i + 2] : a[i + 2], qy = rel ? cy + a[i + 3] : a[i + 3];
                // A quadratic is a cubic whose controls sit two thirds
                // of the way to the single one.
                curveTo({ x: cx + 2 / 3 * (q.x - cx), y: cy + 2 / 3 * (q.y - cy) },
                        { x: qx + 2 / 3 * (q.x - qx), y: qy + 2 / 3 * (q.y - qy) },
                        qx, qy);
                lastQ = q; lastC = null;
                i += 4;
                break;
            }
            case "T": {
                var rq = lastQ ? { x: 2 * cx - lastQ.x, y: 2 * cy - lastQ.y }
                               : { x: cx, y: cy };
                var tx = rel ? cx + a[i] : a[i], ty = rel ? cy + a[i + 1] : a[i + 1];
                var px = cx, py = cy;
                curveTo({ x: px + 2 / 3 * (rq.x - px), y: py + 2 / 3 * (rq.y - py) },
                        { x: tx + 2 / 3 * (rq.x - tx), y: ty + 2 / 3 * (rq.y - ty) },
                        tx, ty);
                lastQ = rq; lastC = null;
                i += 2;
                break;
            }
            case "A": {
                var ax = rel ? cx + a[i + 5] : a[i + 5];
                var ay = rel ? cy + a[i + 6] : a[i + 6];
                var cubics = arcToCubics(cx, cy, a[i], a[i + 1], a[i + 2],
                                         a[i + 3] !== 0, a[i + 4] !== 0, ax, ay);
                for (var k = 0; k < cubics.length; k++)
                    curveTo(cubics[k].c1, cubics[k].c2, cubics[k].p.x, cubics[k].p.y);
                if (cubics.length === 0) lineTo(ax, ay);
                lastC = null; lastQ = null;
                i += 7;
                break;
            }
            default:
                i = a.length;
            }
            if (up !== "C" && up !== "S" && up !== "Q" && up !== "T") {
                lastC = null; lastQ = null;
            }
            first = false;
        }
    }
    flush();
    return subs;
}

// ── elements ──────────────────────────────────────────────────────────

function attrs(tag) {
    var out = {};
    var re = /([:\w-]+)\s*=\s*"([^"]*)"|([:\w-]+)\s*=\s*'([^']*)'/g;
    var m;
    while ((m = re.exec(tag)) !== null) {
        if (m[1] !== undefined) out[m[1]] = m[2];
        else out[m[3]] = m[4];
    }
    return out;
}

// Presentation attributes and the style attribute both set fill; style
// wins, because that is the cascade and because an exporter that writes
// both means the one in style.
// How light a colour is, 0..1, or -1 when it cannot be told. Used only
// to spot a knockout: a shape filled white and drawn over another is how
// a hole is very often cut in a logo, and in a one-colour icon it has to
// become a real hole or it disappears and takes the hole with it.
function luma(c) {
    if (!c) return -1;
    c = String(c).trim().toLowerCase();
    if (c === "white") return 1;
    if (c === "black") return 0;
    var hex = /^#([0-9a-f]{3}|[0-9a-f]{6})$/.exec(c);
    if (hex) {
        var h = hex[1];
        if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2];
        var r = parseInt(h.slice(0, 2), 16), g = parseInt(h.slice(2, 4), 16),
            b = parseInt(h.slice(4, 6), 16);
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    }
    var rgb = /^rgba?\(([^)]*)\)/.exec(c);
    if (rgb) {
        var n = numbers(rgb[1]);
        if (n.length >= 3) return (0.299 * n[0] + 0.587 * n[1] + 0.114 * n[2]) / 255;
    }
    return -1;
}

function styleOf(a) {
    var out = { fill: a.fill, stroke: a.stroke, strokeWidth: a["stroke-width"] };
    if (a.style) {
        var re = /([\w-]+)\s*:\s*([^;]+)/g, m;
        while ((m = re.exec(a.style)) !== null) {
            var k = m[1].trim(), v = m[2].trim();
            if (k === "fill") out.fill = v;
            else if (k === "stroke") out.stroke = v;
            else if (k === "stroke-width") out.strokeWidth = v;
        }
    }
    return out;
}

function ellipseSubpath(cx, cy, rx, ry) {
    // Four arcs, as cubics, which is what every other ellipse in this
    // file ends up as anyway.
    var k = 0.5522847498 ;
    return { closed: true, nodes: [
        { x: cx, y: cy - ry, hi: { x: cx + rx * k, y: cy - ry }, ho: { x: cx - rx * k, y: cy - ry } },
        { x: cx - rx, y: cy, hi: { x: cx - rx, y: cy - ry * k }, ho: { x: cx - rx, y: cy + ry * k } },
        { x: cx, y: cy + ry, hi: { x: cx - rx * k, y: cy + ry }, ho: { x: cx + rx * k, y: cy + ry } },
        { x: cx + rx, y: cy, hi: { x: cx + rx, y: cy + ry * k }, ho: { x: cx + rx, y: cy - ry * k } }
    ] };
}

function rectSubpath(x, y, w, h, rx, ry) {
    if (!(rx > 0) && !(ry > 0))
        return { closed: true, nodes: [
            { x: x, y: y, corner: true }, { x: x + w, y: y, corner: true },
            { x: x + w, y: y + h, corner: true }, { x: x, y: y + h, corner: true } ] };
    rx = Math.min(rx > 0 ? rx : ry, w / 2);
    ry = Math.min(ry > 0 ? ry : rx, h / 2);
    var k = 0.5522847498;
    var x2 = x + w, y2 = y + h;
    return { closed: true, nodes: [
        { x: x + rx, y: y, corner: true, ho: undefined },
        { x: x2 - rx, y: y, corner: true, ho: { x: x2 - rx + rx * k, y: y } },
        { x: x2, y: y + ry, corner: true, hi: { x: x2, y: y + ry - ry * k } },
        { x: x2, y: y2 - ry, corner: true, ho: { x: x2, y: y2 - ry + ry * k } },
        { x: x2 - rx, y: y2, corner: true, hi: { x: x2 - rx + rx * k, y: y2 } },
        { x: x + rx, y: y2, corner: true, ho: { x: x + rx - rx * k, y: y2 } },
        { x: x, y: y2 - ry, corner: true, hi: { x: x, y: y2 - ry + ry * k } },
        { x: x, y: y + ry, corner: true, ho: { x: x, y: y + ry - ry * k } }
    ] };
}

function pointsSubpath(str, closed) {
    var a = numbers(str);
    var nodes = [];
    for (var i = 0; i + 1 < a.length; i += 2)
        nodes.push({ x: a[i], y: a[i + 1], corner: true });
    return nodes.length >= 2 ? { closed: closed, nodes: nodes } : null;
}

// Subpaths for one element, in its own coordinates, or null.
function subpathsFor(name, a) {
    switch (name) {
    case "path":     return a.d ? parsePathData(a.d) : null;
    case "rect": {
        var w = parseFloat(a.width), h = parseFloat(a.height);
        if (!(w > 0) || !(h > 0)) return null;
        return [rectSubpath(parseFloat(a.x) || 0, parseFloat(a.y) || 0, w, h,
                            parseFloat(a.rx) || 0, parseFloat(a.ry) || 0)];
    }
    case "circle": {
        var r = parseFloat(a.r);
        if (!(r > 0)) return null;
        return [ellipseSubpath(parseFloat(a.cx) || 0, parseFloat(a.cy) || 0, r, r)];
    }
    case "ellipse": {
        var rx = parseFloat(a.rx), ry = parseFloat(a.ry);
        if (!(rx > 0) || !(ry > 0)) return null;
        return [ellipseSubpath(parseFloat(a.cx) || 0, parseFloat(a.cy) || 0, rx, ry)];
    }
    case "line":
        return [{ closed: false, nodes: [
            { x: parseFloat(a.x1) || 0, y: parseFloat(a.y1) || 0, corner: true },
            { x: parseFloat(a.x2) || 0, y: parseFloat(a.y2) || 0, corner: true } ] }];
    case "polygon": {
        var pg = pointsSubpath(a.points || "", true);
        return pg ? [pg] : null;
    }
    case "polyline": {
        var pl = pointsSubpath(a.points || "", false);
        return pl ? [pl] : null;
    }
    }
    return null;
}

// ── the document ──────────────────────────────────────────────────────

function mapNodes(nodes, fn) {
    var out = [];
    for (var i = 0; i < nodes.length; i++) {
        var n = nodes[i];
        var p = fn(n.x, n.y);
        var o = { x: round(p.x), y: round(p.y) };
        if (n.corner) o.corner = true;
        if (n.hi) { var hi = fn(n.hi.x, n.hi.y); o.hi = { x: round(hi.x), y: round(hi.y) }; }
        if (n.ho) { var ho = fn(n.ho.x, n.ho.y); o.ho = { x: round(ho.x), y: round(ho.y) }; }
        out.push(o);
    }
    return out;
}

function boundsOfNodes(nodes) {
    var b = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
    for (var i = 0; i < nodes.length; i++) {
        // Handles count: a curve bulges past its nodes, and a logo
        // measured by its nodes alone is fitted slightly too large and
        // clipped at the edge of the grid.
        var pts = [nodes[i]];
        if (nodes[i].hi) pts.push(nodes[i].hi);
        if (nodes[i].ho) pts.push(nodes[i].ho);
        for (var j = 0; j < pts.length; j++) {
            b.x0 = Math.min(b.x0, pts[j].x); b.x1 = Math.max(b.x1, pts[j].x);
            b.y0 = Math.min(b.y0, pts[j].y); b.y1 = Math.max(b.y1, pts[j].y);
        }
    }
    return b;
}

function insideRing(p, nodes) {
    var hit = false;
    for (var i = 0, j = nodes.length - 1; i < nodes.length; j = i++) {
        var a = nodes[i], b = nodes[j];
        if ((a.y > p.y) !== (b.y > p.y)
            && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x)
            hit = !hit;
    }
    return hit;
}

function ringArea(nodes) {
    var s = 0;
    for (var i = 0, j = nodes.length - 1; i < nodes.length; j = i++)
        s += nodes[j].x * nodes[i].y - nodes[i].x * nodes[j].y;
    return Math.abs(s / 2);
}

// text: the one thing worth naming rather than silently dropping, since
// a logo that is half a wordmark comes back as half a logo.
function parse(text, opts) {
    opts = opts || {};
    var units = opts.units || 24;
    var margin = opts.margin === undefined ? 2 : opts.margin;

    if (!text || text.indexOf("<svg") < 0)
        return { shapes: [], error: "That does not look like an SVG." };

    // Comments out first, or a shape inside one is imported.
    var doc = text.replace(/<!--[\s\S]*?-->/g, " ");

    var stack = [identity()];
    var pieces = [];          // { subpaths, filled, evenodd }
    var sawText = false;

    var re = /<\s*(\/?)\s*([a-zA-Z][\w:-]*)([^>]*?)(\/?)>/g;
    var m;
    while ((m = re.exec(doc)) !== null) {
        var closing = m[1] === "/";
        var name = m[2].replace(/^.*:/, "");      // drop any namespace
        var body = m[3];
        var selfClosing = m[4] === "/";

        if (name === "text" || name === "tspan") { sawText = true; continue; }
        if (name === "svg") continue;

        if (name === "g") {
            if (closing) { if (stack.length > 1) stack.pop(); }
            else {
                var gm = multiply(stack[stack.length - 1],
                                  parseTransform(attrs(body).transform));
                stack.push(gm);
                // A self-closing group has no children and no end tag.
                if (selfClosing) stack.pop();
            }
            continue;
        }
        if (closing) continue;

        var a = attrs(body);
        var subs = subpathsFor(name, a);
        if (!subs || subs.length === 0) continue;

        var here = multiply(stack[stack.length - 1], parseTransform(a.transform));
        var st = styleOf(a);
        // No fill attribute at all means black in SVG, which is filled.
        var filled = !(st.fill === "none")
                     && !(st.fill === undefined && st.stroke && st.stroke !== "none");

        for (var s = 0; s < subs.length; s++) {
            subs[s].nodes = mapNodes(subs[s].nodes, function (x, y) {
                return applyM(here, x, y);
            });
        }
        pieces.push({ subpaths: subs, filled: filled,
                      luma: luma(st.fill),
                      evenodd: (a["fill-rule"] || st.fillRule) === "evenodd" });
    }

    if (pieces.length === 0) {
        return { shapes: [], error: sawText
                 ? "That SVG is mostly text — convert the text to outlines and try again."
                 : "No shapes in that SVG that this understands." };
    }

    // One scale for the whole drawing, so the pieces keep their
    // relationship to each other.
    var all = { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
    for (var p1 = 0; p1 < pieces.length; p1++)
        for (var s1 = 0; s1 < pieces[p1].subpaths.length; s1++) {
            var b = boundsOfNodes(pieces[p1].subpaths[s1].nodes);
            all.x0 = Math.min(all.x0, b.x0); all.x1 = Math.max(all.x1, b.x1);
            all.y0 = Math.min(all.y0, b.y0); all.y1 = Math.max(all.y1, b.y1);
        }
    var bw = all.x1 - all.x0, bh = all.y1 - all.y0;
    if (!(bw > 0) && !(bh > 0))
        return { shapes: [], error: "That SVG has no size." };

    var span = units - margin * 2;
    var k = span / Math.max(bw, bh);
    var offX = (units - bw * k) / 2 - all.x0 * k;
    var offY = (units - bh * k) / 2 - all.y0 * k;
    var fit = function (x, y) { return { x: x * k + offX, y: y * k + offY }; };

    // Fitted, then grouped: within one element, a subpath inside
    // another is a hole, which is how a letter O and a ring are drawn.
    var shapes = [];
    for (var p2 = 0; p2 < pieces.length; p2++) {
        var piece = pieces[p2];
        var rings = [];
        for (var s2 = 0; s2 < piece.subpaths.length; s2++) {
            var sp = piece.subpaths[s2];
            rings.push({ nodes: mapNodes(sp.nodes, fit), closed: sp.closed });
        }
        rings.sort(function (u, v) { return ringArea(v.nodes) - ringArea(u.nodes); });

        var used = [];
        for (var r1 = 0; r1 < rings.length; r1++) {
            if (used[r1]) continue;
            var holes = [];
            if (piece.filled) {
                for (var r2 = r1 + 1; r2 < rings.length; r2++) {
                    if (used[r2]) continue;
                    if (!insideRing(rings[r2].nodes[0], rings[r1].nodes)) continue;
                    used[r2] = true;
                    holes.push(rings[r2].nodes);
                }
            }
            var shape = { kind: "path", c: "ink", sw: 2,
                          closed: piece.filled ? true : rings[r1].closed,
                          nodes: rings[r1].nodes };
            if (piece.filled) shape.fill = true;
            shape.svgLuma = piece.luma;
            if (holes.length > 0) shape.holes = holes;
            shapes.push(shape);
        }
    }

    // Knockouts: a filled shape sitting entirely inside an earlier one
    // and painted in something pale is a hole that was cut by covering
    // it up. That works on a white page and not at all in an icon that
    // takes its colours from the theme — drawn as its own shape it
    // would be ink on ink and simply vanish, taking the hole with it.
    // So it becomes a hole in the shape it sits in.
    for (var c1 = shapes.length - 1; c1 >= 1; c1--) {
        var inner = shapes[c1];
        if (!inner.fill || inner.holes) continue;
        if (!(inner.svgLuma > 0.75)) continue;
        for (var c2 = c1 - 1; c2 >= 0; c2--) {
            var outerShape = shapes[c2];
            if (!outerShape.fill) continue;
            if (!insideRing(inner.nodes[0], outerShape.nodes)) continue;
            if (!(outerShape.svgLuma < 0.75)) continue;
            outerShape.holes = (outerShape.holes || []).concat([inner.nodes]);
            shapes.splice(c1, 1);
            break;
        }
    }
    for (var c3 = 0; c3 < shapes.length; c3++) delete shapes[c3].svgLuma;

    return { shapes: shapes, note: sawText
             ? "Some text in that SVG was skipped — convert text to outlines to keep it."
             : "" };
}
