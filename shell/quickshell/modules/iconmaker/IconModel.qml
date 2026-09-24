import QtQuick
import "../icons/Compose.js" as Compose

// The drawing being edited: a list of shapes, an undo stack, and the
// arithmetic for picking one up and moving it.
//
// Separate from the window that shows it because none of this needs a
// screen, which is the only way any of it can be checked in a repository
// with no compositor in it — see scratchpad/iconmodel.js, which runs
// these very functions.
QtObject {
    id: model

    // The grid everything is authored on, and the whole reason icons in
    // this pack look like each other. 24 units, y down.
    readonly property int units: 24

    property var shapes: []
    property int selected: -1
    // Which node of the selected path was last touched, for the
    // operations that act on one rather than on the whole shape.
    property int selectedNode: -1
    onSelectedChanged: model.selectedNode = -1

    readonly property var current: (selected >= 0 && selected < shapes.length)
                                   ? shapes[selected] : null

    signal changed()

    // ── undo ──────────────────────────────────────────────────────────
    //
    // Snapshots rather than inverse operations. A drawing is at most a
    // couple of dozen small objects, so a stack of whole copies costs
    // nothing and cannot get out of step with the thing it describes,
    // which is the failure mode of every undo built the other way.
    property var undoStack: []
    property var redoStack: []
    readonly property bool canUndo: undoStack.length > 0
    readonly property bool canRedo: redoStack.length > 0

    function snapshot() {
        const stack = model.undoStack.slice();
        stack.push(JSON.stringify(model.shapes));
        // Deep history is not worth unbounded memory; 60 steps is more
        // than anyone winds back through on a 24x24 drawing.
        if (stack.length > 60) stack.shift();
        model.undoStack = stack;
        model.redoStack = [];
    }

    function undo() {
        if (model.undoStack.length === 0) return;
        const stack = model.undoStack.slice();
        const prev = stack.pop();
        const redo = model.redoStack.slice();
        redo.push(JSON.stringify(model.shapes));
        model.undoStack = stack;
        model.redoStack = redo;
        model.shapes = JSON.parse(prev);
        model.selected = Math.min(model.selected, model.shapes.length - 1);
        model.changed();
    }

    function redo() {
        if (model.redoStack.length === 0) return;
        const redo = model.redoStack.slice();
        const next = redo.pop();
        const stack = model.undoStack.slice();
        stack.push(JSON.stringify(model.shapes));
        model.redoStack = redo;
        model.undoStack = stack;
        model.shapes = JSON.parse(next);
        model.selected = Math.min(model.selected, model.shapes.length - 1);
        model.changed();
    }

    // ── editing ───────────────────────────────────────────────────────
    function replace(list, keepUndo) {
        if (!keepUndo) model.snapshot();
        model.shapes = list;
        model.changed();
    }

    function add(shape) {
        model.snapshot();
        const next = model.shapes.slice();
        next.push(shape);
        model.shapes = next;
        model.selected = next.length - 1;
        model.changed();
    }

    // Writes fields into the selected shape. `quiet` is for the middle of
    // a drag: one undo step per gesture, not one per mouse event.
    function update(fields, quiet) {
        if (model.selected < 0) return;
        if (!quiet) model.snapshot();
        const next = model.shapes.slice();
        const s = {};
        const old = next[model.selected];
        for (const k in old) s[k] = old[k];
        for (const k in fields) s[k] = fields[k];
        next[model.selected] = s;
        model.shapes = next;
        model.changed();
    }

    function removeSelected() {
        if (model.selected < 0) return;
        model.snapshot();
        const next = model.shapes.slice();
        next.splice(model.selected, 1);
        model.shapes = next;
        model.selected = Math.min(model.selected, next.length - 1);
        model.changed();
    }

    function duplicateSelected() {
        if (!model.current) return;
        const copy = JSON.parse(JSON.stringify(model.current));
        model.nudge(copy, 1, 1);
        model.add(copy);
    }

    // Order is paint order, so "bring forward" is "move later in the list".
    function reorder(delta) {
        const at = model.selected;
        const to = at + delta;
        if (at < 0 || to < 0 || to >= model.shapes.length) return;
        model.snapshot();
        const next = model.shapes.slice();
        const s = next.splice(at, 1)[0];
        next.splice(to, 0, s);
        model.shapes = next;
        model.selected = to;
        model.changed();
    }

    function clear() {
        model.snapshot();
        model.shapes = [];
        model.selected = -1;
        model.changed();
    }

    // ── geometry ──────────────────────────────────────────────────────
    //
    // Every shape moves, and each kind keeps its position in its own
    // fields, so this is the one place that knows which those are.
    function nudge(s, dx, dy) {
        switch (s.kind) {
        case "line":
            s.x1 += dx; s.y1 += dy; s.x2 += dx; s.y2 += dy; break;
        case "rect":
            s.x += dx; s.y += dy; break;
        case "poly":
            for (let i = 0; i + 1 < s.pts.length; i += 2) {
                s.pts[i] += dx; s.pts[i + 1] += dy;
            }
            break;
        case "path":
            // The handles travel with their nodes. They are stored as
            // absolute points, so moving the node alone would leave the
            // curve behind and turn the shape inside out.
            for (const nd of s.nodes) {
                nd.x += dx; nd.y += dy;
                if (nd.hi) { nd.hi.x += dx; nd.hi.y += dy; }
                if (nd.ho) { nd.ho.x += dx; nd.ho.y += dy; }
            }
            break;
        default:
            s.cx += dx; s.cy += dy; break;   // circle, ellipse, arc, dot
        }
        return s;
    }

    function moveSelected(dx, dy, quiet) {
        if (!model.current) return;
        const s = JSON.parse(JSON.stringify(model.current));
        model.nudge(s, dx, dy);
        model.update(s, quiet);
    }

    // Where a shape is, for hit testing and for drawing handles.
    function boundsOf(s) {
        switch (s.kind) {
        case "line":
            return { x: Math.min(s.x1, s.x2), y: Math.min(s.y1, s.y2),
                     w: Math.abs(s.x2 - s.x1), h: Math.abs(s.y2 - s.y1) };
        case "rect":
            return { x: s.x, y: s.y, w: s.w, h: s.h };
        case "circle":
        case "dot":
            return { x: s.cx - s.r, y: s.cy - s.r, w: s.r * 2, h: s.r * 2 };
        case "ellipse":
            return { x: s.cx - s.rx, y: s.cy - s.ry, w: s.rx * 2, h: s.ry * 2 };
        case "arc":
            // The circle it is cut from, rather than the arc's own extent:
            // a tight box would move as the angles change, and a handle
            // that wanders while you drag a different handle is worse
            // than one that sits somewhere slightly generous.
            return { x: s.cx - s.r, y: s.cy - s.r, w: s.r * 2, h: s.r * 2 };
        case "path": {
            // The nodes, not the handles: a handle flung well outside
            // the shape would drag the bounding box — and the centre it
            // rotates about — out with it.
            let a0 = Infinity, b0 = Infinity, a1 = -Infinity, b1 = -Infinity;
            for (const nd of (s.nodes || [])) {
                a0 = Math.min(a0, nd.x); a1 = Math.max(a1, nd.x);
                b0 = Math.min(b0, nd.y); b1 = Math.max(b1, nd.y);
            }
            if (a0 === Infinity) return { x: 0, y: 0, w: 0, h: 0 };
            return { x: a0, y: b0, w: a1 - a0, h: b1 - b0 };
        }
        case "poly": {
            let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
            for (let i = 0; i + 1 < s.pts.length; i += 2) {
                x0 = Math.min(x0, s.pts[i]);   x1 = Math.max(x1, s.pts[i]);
                y0 = Math.min(y0, s.pts[i + 1]); y1 = Math.max(y1, s.pts[i + 1]);
            }
            return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
        }
        }
        return { x: 0, y: 0, w: 0, h: 0 };
    }

    // Distance from a point to a shape, in grid units. Used to pick one
    // by clicking: an outline is a thin thing, and hit testing a
    // bounding box would make the empty middle of a circle select it
    // while the ring next to it selects whatever is behind.
    function distanceTo(s, px, py) {
        // A turned shape is measured in its own frame. Rotating the
        // pointer back is one operation; rotating the geometry forward
        // would be one per segment, per kind, and would have to be got
        // right seven times.
        if (s.rot) {
            const local = Compose.unmapperFor(s)(px, py);
            px = local.x; py = local.y;
        }
        switch (s.kind) {
        case "line":
            return model.distToSegment(px, py, s.x1, s.y1, s.x2, s.y2);
        case "dot":
            return Math.max(0, Math.hypot(px - s.cx, py - s.cy) - s.r);
        case "circle":
        case "arc":
            // To the ring, not to the centre.
            return s.fill ? Math.max(0, Math.hypot(px - s.cx, py - s.cy) - s.r)
                          : Math.abs(Math.hypot(px - s.cx, py - s.cy) - s.r);
        case "ellipse": {
            const nx = (px - s.cx) / Math.max(0.01, s.rx);
            const ny = (py - s.cy) / Math.max(0.01, s.ry);
            const d = Math.hypot(nx, ny);
            return s.fill ? Math.max(0, (d - 1) * Math.min(s.rx, s.ry))
                          : Math.abs(d - 1) * Math.min(s.rx, s.ry);
        }
        case "rect": {
            if (s.fill) {
                const dx = Math.max(s.x - px, 0, px - (s.x + s.w));
                const dy = Math.max(s.y - py, 0, py - (s.y + s.h));
                return Math.hypot(dx, dy);
            }
            return model.distToRectEdge(px, py, s.x, s.y, s.w, s.h);
        }
        case "path": {
            // Curves are flattened and measured as the straight lines
            // they are drawn as anyway. Twelve steps is finer than the
            // grid this is all snapped to.
            const nodes = s.nodes || [];
            let best = Infinity;
            const seg = (a, b) => {
                if (!a.ho && !b.hi)
                    return model.distToSegment(px, py, a.x, a.y, b.x, b.y);
                const c1 = a.ho || { x: a.x, y: a.y };
                const c2 = b.hi || { x: b.x, y: b.y };
                let d = Infinity, prev = { x: a.x, y: a.y };
                for (let k = 1; k <= 12; k++) {
                    const t = k / 12, u = 1 - t;
                    const pt = {
                        x: u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x,
                        y: u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y
                    };
                    d = Math.min(d, model.distToSegment(px, py, prev.x, prev.y, pt.x, pt.y));
                    prev = pt;
                }
                return d;
            };
            for (let i = 1; i < nodes.length; i++)
                best = Math.min(best, seg(nodes[i - 1], nodes[i]));
            if (s.closed && nodes.length > 2)
                best = Math.min(best, seg(nodes[nodes.length - 1], nodes[0]));
            // A filled path is solid, so anywhere inside it is a hit.
            if (s.fill && s.closed && model.insidePath(s, px, py)) return 0;
            return best;
        }
        case "poly": {
            let best = Infinity;
            for (let i = 0; i + 3 < s.pts.length; i += 2)
                best = Math.min(best, model.distToSegment(px, py, s.pts[i], s.pts[i + 1],
                                                          s.pts[i + 2], s.pts[i + 3]));
            if (s.closed && s.pts.length >= 6) {
                const n = s.pts.length;
                best = Math.min(best, model.distToSegment(px, py, s.pts[n - 2], s.pts[n - 1],
                                                          s.pts[0], s.pts[1]));
            }
            return best;
        }
        }
        return Infinity;
    }

    // Even-odd crossing count against the node polygon. The handles are
    // ignored: this decides whether a click is inside a filled shape,
    // and being a curve's width out at the edge of one costs nothing.
    function insidePath(s, px, py) {
        const nodes = s.nodes || [];
        let inside = false;
        for (let i = 0, j = nodes.length - 1; i < nodes.length; j = i++) {
            const a = nodes[i], b = nodes[j];
            if ((a.y > py) !== (b.y > py)
                && px < (b.x - a.x) * (py - a.y) / (b.y - a.y) + a.x)
                inside = !inside;
        }
        return inside;
    }

    function distToSegment(px, py, x1, y1, x2, y2) {
        const vx = x2 - x1, vy = y2 - y1;
        const len2 = vx * vx + vy * vy;
        // A segment of no length is a point, and dividing by its length
        // would make every hit test on it NaN — which compares false
        // against everything, so the shape would simply never be
        // selectable and nothing would say why.
        if (len2 === 0) return Math.hypot(px - x1, py - y1);
        let t = ((px - x1) * vx + (py - y1) * vy) / len2;
        t = Math.max(0, Math.min(1, t));
        return Math.hypot(px - (x1 + t * vx), py - (y1 + t * vy));
    }

    function distToRectEdge(px, py, x, y, w, h) {
        return Math.min(
            model.distToSegment(px, py, x, y, x + w, y),
            model.distToSegment(px, py, x + w, y, x + w, y + h),
            model.distToSegment(px, py, x + w, y + h, x, y + h),
            model.distToSegment(px, py, x, y + h, x, y));
    }

    // The topmost shape within `slack` units of the point, or -1.
    // Topmost, because that is the one you can see there.
    function hitTest(px, py, slack) {
        for (let i = model.shapes.length - 1; i >= 0; i--)
            if (model.distanceTo(model.shapes[i], px, py) <= slack) return i;
        return -1;
    }

    // ── handles ───────────────────────────────────────────────────────
    //
    // The draggable points for the selected shape, each with the name of
    // what it changes. The canvas draws these and hands back a moved one.
    function handlesFor(s) {
        if (!s) return [];
        // Worked out in the shape's own frame and then turned, so every
        // kind below can be written as though nothing were rotated.
        const map = Compose.mapperFor(s);
        const out = [];
        // `from` is where a handle hangs off, for the stalk the canvas
        // draws back to it — a bezier handle floating on its own is
        // impossible to attribute once two nodes are close together.
        const put = (id, x, y, role, from) => {
            const p = map(x, y);
            const f = from ? map(from.x, from.y) : null;
            out.push({ id: id, role: role || "point", x: p.x, y: p.y,
                       fromX: f ? f.x : p.x, fromY: f ? f.y : p.y,
                       hasStalk: !!f });
        };

        switch (s.kind) {
        case "line":
            put("p1", s.x1, s.y1); put("p2", s.x2, s.y2); break;
        case "rect":
            put("tl", s.x, s.y); put("br", s.x + s.w, s.y + s.h); break;
        case "circle":
        case "dot":
            put("r", s.cx + s.r, s.cy); break;
        case "ellipse":
            put("rx", s.cx + s.rx, s.cy); put("ry", s.cx, s.cy + s.ry); break;
        case "arc": {
            const a = deg => ({ x: s.cx + s.r * Math.cos(deg * Math.PI / 180),
                                y: s.cy + s.r * Math.sin(deg * Math.PI / 180) });
            const p0 = a(s.a0), p1 = a(s.a1);
            put("a0", p0.x, p0.y); put("a1", p1.x, p1.y);
            put("r", s.cx, s.cy + s.r);
            break;
        }
        case "poly":
            for (let i = 0; i + 1 < s.pts.length; i += 2)
                put("p" + (i / 2), s.pts[i], s.pts[i + 1]);
            break;
        case "path":
            // The node, then its two handles where it has them, marked
            // so the canvas can draw them differently — a point you are
            // placing and a curve you are shaping are not the same
            // gesture and should not look the same.
            for (let i = 0; i < (s.nodes || []).length; i++) {
                const nd = s.nodes[i];
                put("n" + i, nd.x, nd.y, "node");
                if (nd.hi) put("n" + i + "i", nd.hi.x, nd.hi.y, "bezier", nd);
                if (nd.ho) put("n" + i + "o", nd.ho.x, nd.ho.y, "bezier", nd);
            }
            break;
        }

        // The rotation knob, above the shape, on the end of a stalk so
        // it is never sitting on top of a corner handle. A circle and a
        // dot have nothing to turn, so they do not get one.
        if (s.kind !== "circle" && s.kind !== "dot") {
            const b = model.boundsOf(s);
            put("rot", b.x + b.w / 2, b.y - 2.2, "rot",
                { x: b.x + b.w / 2, y: b.y });
        }
        return out;
    }

    // Moving handle `id` to (x, y). Returns the fields to write.
    function dragHandle(s, id, x, y) {
        // The pointer comes in grid coordinates; everything below works
        // in the shape's own, so a turned shape's handles drag the way
        // they look rather than at an angle to it.
        if (s.rot && id !== "rot") {
            const local = Compose.unmapperFor(s)(x, y);
            x = local.x; y = local.y;
        }

        if (id === "rot") {
            const c = Compose.centreOf(s);
            // The knob sits above the shape, so straight up is no
            // rotation — measured from due north rather than due east.
            let deg = Math.atan2(y - c.y, x - c.x) * 180 / Math.PI + 90;
            while (deg <= -180) deg += 360;
            while (deg > 180) deg -= 360;
            return { rot: Math.round(deg * 10) / 10 };
        }

        switch (s.kind) {
        case "line":
            return id === "p1" ? { x1: x, y1: y } : { x2: x, y2: y };
        case "rect": {
            // The opposite corner stays put, and the box is normalised so
            // dragging past it flips rather than going negative — a
            // negative width draws nothing and reads as the shape
            // vanishing.
            const ox = id === "tl" ? s.x + s.w : s.x;
            const oy = id === "tl" ? s.y + s.h : s.y;
            return { x: Math.min(x, ox), y: Math.min(y, oy),
                     w: Math.abs(ox - x), h: Math.abs(oy - y) };
        }
        case "circle":
        case "dot":
            return { r: Math.max(0.25, Math.hypot(x - s.cx, y - s.cy)) };
        case "ellipse":
            return id === "rx" ? { rx: Math.max(0.25, Math.abs(x - s.cx)) }
                               : { ry: Math.max(0.25, Math.abs(y - s.cy)) };
        case "arc": {
            if (id === "r") return { r: Math.max(0.25, Math.hypot(x - s.cx, y - s.cy)) };
            let deg = Math.atan2(y - s.cy, x - s.cx) * 180 / Math.PI;
            if (deg < 0) deg += 360;
            if (id === "a0") {
                // Keep the sweep the same side of the circle it was on,
                // rather than letting it snap the long way round when the
                // handle crosses due east.
                let a1 = s.a1;
                while (a1 < deg) a1 += 360;
                while (a1 - deg > 360) a1 -= 360;
                return { a0: deg, a1: a1 };
            }
            let a1 = deg;
            while (a1 < s.a0) a1 += 360;
            return { a1: a1 };
        }
        case "poly": {
            const i = parseInt(id.slice(1), 10) * 2;
            const pts = s.pts.slice();
            pts[i] = x; pts[i + 1] = y;
            return { pts: pts };
        }
        case "path": {
            const m = /^n(\d+)([io])?$/.exec(id);
            if (!m) return {};
            const i = parseInt(m[1], 10);
            const nodes = JSON.parse(JSON.stringify(s.nodes));
            const nd = nodes[i];
            if (!nd) return {};

            if (!m[2]) {
                // The node itself, handles in tow.
                const dx = x - nd.x, dy = y - nd.y;
                nd.x = x; nd.y = y;
                if (nd.hi) { nd.hi.x += dx; nd.hi.y += dy; }
                if (nd.ho) { nd.ho.x += dx; nd.ho.y += dy; }
                return { nodes: nodes };
            }

            const which = m[2] === "i" ? "hi" : "ho";
            const other = m[2] === "i" ? "ho" : "hi";
            nd[which] = { x: x, y: y };
            // A smooth node keeps its two handles opposite and equal, so
            // the curve runs through it rather than kinking. A corner
            // node is the one you mark when you want the kink.
            if (!nd.corner && nd[other])
                nd[other] = { x: 2 * nd.x - x, y: 2 * nd.y - y };
            return { nodes: nodes };
        }
        }
        return {};
    }

    // ── path nodes ────────────────────────────────────────────────────
    //
    // The operations a point-based shape needs that a primitive does
    // not: nodes come and go, and each one is either a corner or smooth.
    function pathNodeOp(op, index) {
        const s = model.current;
        if (!s || s.kind !== "path") return;
        const nodes = JSON.parse(JSON.stringify(s.nodes));

        if (op === "delete") {
            // Two nodes is the least that still draws a line.
            if (nodes.length <= 2) return;
            nodes.splice(index, 1);
            model.update({ nodes: nodes });
            return;
        }

        if (op === "corner") {
            const nd = nodes[index];
            if (!nd) return;
            if (nd.corner) {
                // Back to smooth: give it handles along the line between
                // its neighbours, which is what smooth means here.
                nd.corner = false;
                const prev = nodes[index - 1] || nodes[nodes.length - 1];
                const next = nodes[index + 1] || nodes[0];
                if (prev && next) {
                    const dx = (next.x - prev.x) / 4, dy = (next.y - prev.y) / 4;
                    nd.hi = { x: nd.x - dx, y: nd.y - dy };
                    nd.ho = { x: nd.x + dx, y: nd.y + dy };
                }
            } else {
                nd.corner = true;
                delete nd.hi;
                delete nd.ho;
            }
            model.update({ nodes: nodes });
            return;
        }

        if (op === "split") {
            // A node halfway along the segment that follows this one.
            const a = nodes[index], b = nodes[index + 1] || (s.closed ? nodes[0] : null);
            if (!a || !b) return;
            nodes.splice(index + 1, 0, { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2,
                                         corner: true });
            model.update({ nodes: nodes });
        }
    }

    function toggleClosed() {
        const s = model.current;
        if (!s || (s.kind !== "path" && s.kind !== "poly")) return;
        model.update({ closed: !s.closed });
    }

    // ── saving ────────────────────────────────────────────────────────
    function glyph() { return Compose.compose(model.shapes); }
    function draws() { return Compose.draws(model.shapes); }
}
