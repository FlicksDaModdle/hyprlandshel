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
        switch (s.kind) {
        case "line":
            return [{ id: "p1", x: s.x1, y: s.y1 }, { id: "p2", x: s.x2, y: s.y2 }];
        case "rect":
            return [{ id: "tl", x: s.x, y: s.y },
                    { id: "br", x: s.x + s.w, y: s.y + s.h }];
        case "circle":
        case "dot":
            return [{ id: "r", x: s.cx + s.r, y: s.cy }];
        case "ellipse":
            return [{ id: "rx", x: s.cx + s.rx, y: s.cy },
                    { id: "ry", x: s.cx, y: s.cy + s.ry }];
        case "arc": {
            const a = deg => ({ x: s.cx + s.r * Math.cos(deg * Math.PI / 180),
                                y: s.cy + s.r * Math.sin(deg * Math.PI / 180) });
            const p0 = a(s.a0), p1 = a(s.a1);
            return [{ id: "a0", x: p0.x, y: p0.y },
                    { id: "a1", x: p1.x, y: p1.y },
                    { id: "r", x: s.cx, y: s.cy + s.r }];
        }
        case "poly": {
            const out = [];
            for (let i = 0; i + 1 < s.pts.length; i += 2)
                out.push({ id: "p" + (i / 2), x: s.pts[i], y: s.pts[i + 1] });
            return out;
        }
        }
        return [];
    }

    // Moving handle `id` to (x, y). Returns the fields to write.
    function dragHandle(s, id, x, y) {
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
        }
        return {};
    }

    // ── saving ────────────────────────────────────────────────────────
    function glyph() { return Compose.compose(model.shapes); }
    function draws() { return Compose.draws(model.shapes); }
}
