import QtQuick
import QtQuick.Shapes
import "../../config" as Config
import "../icons/Compose.js" as Compose

// The 24x24 grid, drawn big enough to work on.
//
// Everything inside is in authored units and scaled up as a whole, the
// same way MonoIcon scales a glyph down — so what is on this canvas is
// the glyph, at a different size, and not a second drawing of it that
// could disagree.
//
// Handles are the exception. They live outside the scaled item and are
// placed in pixels, because a handle is a thing you grab with a pointer
// and wants to be the same size whatever the zoom: scaled along with the
// artwork they would be specks at 12x and slabs at 40x.
Item {
    id: canvas

    required property var model
    // "select", or one of Compose's kinds.
    property string tool: "select"
    // Fractions of a unit. Quarter is fine enough for anything in the
    // pack and coarse enough that two shapes meant to meet actually do.
    property real snap: 0.5
    property color ink: Config.Appearance.ink
    property color accent: Config.Appearance.accent
    // The next shape's attributes, so a tool draws in what is selected
    // in the properties panel rather than always in ink at weight 2.
    property string nextColour: "ink"
    property int nextWeight: 2

    readonly property real px: Math.min(width, height) / canvas.model.units

    function toUnits(v) { return v / canvas.px; }
    function toPixels(v) { return v * canvas.px; }
    function snapped(v) {
        return canvas.snap > 0 ? Math.round(v / canvas.snap) * canvas.snap : v;
    }

    // ── the drawing ───────────────────────────────────────────────────
    Rectangle {
        anchors.fill: parent
        color: Config.Appearance.ground
        radius: Config.Appearance.rSm
        border.width: 1
        border.color: Config.Appearance.edge
    }

    // A line every unit, heavier every four, and heavier again on the
    // centre lines. Icons in this pack are built on halves and quarters
    // of the grid, so the grid has to be readable enough to aim at.
    Canvas {
        id: grid
        anchors.fill: parent
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const n = canvas.model.units, p = canvas.px;
            for (let i = 0; i <= n; i++) {
                const major = i % 4 === 0;
                const centre = i === n / 2;
                ctx.strokeStyle = centre ? Qt.rgba(1, 1, 1, 0.16)
                                         : (major ? Qt.rgba(1, 1, 1, 0.10)
                                                  : Qt.rgba(1, 1, 1, 0.045));
                ctx.lineWidth = 1;
                ctx.beginPath();
                ctx.moveTo(Math.round(i * p) + 0.5, 0);
                ctx.lineTo(Math.round(i * p) + 0.5, n * p);
                ctx.moveTo(0, Math.round(i * p) + 0.5);
                ctx.lineTo(n * p, Math.round(i * p) + 0.5);
                ctx.stroke();
            }
        }
        Connections {
            target: canvas
            function onPxChanged() { grid.requestPaint(); }
        }
    }

    Item {
        id: artwork
        width: canvas.model.units
        height: canvas.model.units
        scale: canvas.px
        transformOrigin: Item.TopLeft
        antialiasing: true

        Repeater {
            model: canvas.model.shapes

            Item {
                id: shapeItem
                required property var modelData
                required property int index
                anchors.fill: parent

                readonly property color colour: modelData.c === "acc"
                                                ? canvas.accent : canvas.ink
                readonly property bool selected: shapeItem.index === canvas.model.selected

                // A dot is a filled disc and is drawn as one, exactly as
                // MonoIcon draws it — at a unit across, a stroked circle
                // is a grey smudge and a filled one is a dot.
                Rectangle {
                    visible: shapeItem.modelData.kind === "dot"
                    x: (shapeItem.modelData.cx || 0) - (shapeItem.modelData.r || 0)
                    y: (shapeItem.modelData.cy || 0) - (shapeItem.modelData.r || 0)
                    width: (shapeItem.modelData.r || 0) * 2
                    height: (shapeItem.modelData.r || 0) * 2
                    radius: width / 2
                    antialiasing: true
                    color: shapeItem.colour
                }

                Shape {
                    visible: shapeItem.modelData.kind !== "dot"
                    anchors.fill: parent
                    preferredRendererType: Shape.GeometryRenderer
                    ShapePath {
                        strokeColor: shapeItem.modelData.fill ? "transparent"
                                                              : shapeItem.colour
                        // fill is accent-only in MonoIcon, so it is
                        // accent-only here: a canvas that showed an ink
                        // fill would be showing something that cannot be
                        // saved.
                        fillColor: shapeItem.modelData.fill ? canvas.accent : "transparent"
                        strokeWidth: shapeItem.modelData.sw || 2
                        capStyle: ShapePath.RoundCap
                        joinStyle: ShapePath.RoundJoin
                        PathSvg { path: Compose.pathFor(shapeItem.modelData) }
                    }
                }
            }
        }

        // The lasso, while it is being drawn.
        Shape {
            visible: canvas.lassoPts.length > 1
            anchors.fill: parent
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                strokeColor: canvas.accent
                fillColor: Qt.rgba(canvas.accent.r, canvas.accent.g,
                                   canvas.accent.b, 0.12)
                strokeWidth: 1.5 / canvas.px
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg {
                    path: {
                        const p = canvas.lassoPts;
                        if (p.length < 2) return "";
                        let d = "M" + p[0].x + " " + p[0].y;
                        for (let i = 1; i < p.length; i++)
                            d += "L" + p[i].x + " " + p[i].y;
                        return d + "Z";
                    }
                }
            }
        }

        // The shape being dragged out, before it is committed.
        Shape {
            visible: !!canvas.draft && canvas.draft.kind !== "dot"
            // A pen draft is filled in nothing, whatever the shape's own
            // fill will be: an outline being drawn is easier to place
            // than a solid growing under the pointer.
            anchors.fill: parent
            preferredRendererType: Shape.GeometryRenderer
            ShapePath {
                strokeColor: canvas.accent
                fillColor: "transparent"
                strokeWidth: (canvas.draft && canvas.draft.sw) || 2
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: canvas.draft ? Compose.pathFor(canvas.draft) : "" }
            }
        }
    }

    // ── selection ─────────────────────────────────────────────────────
    //
    // A halo around the selected shape rather than a box: a bounding box
    // on a 24-grid covers most of the canvas and tells you very little.
    Shape {
        id: halo
        visible: !!canvas.model.current && canvas.model.current.kind !== "dot"
        anchors.fill: parent
        preferredRendererType: Shape.GeometryRenderer
        ShapePath {
            strokeColor: Qt.rgba(canvas.accent.r, canvas.accent.g, canvas.accent.b, 0.55)
            fillColor: "transparent"
            strokeWidth: ((canvas.model.current && canvas.model.current.sw) || 2)
                         * canvas.px + 6
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            // Drawn in pixels, not units, so the halo keeps the same
            // thickness as the zoom changes.
            PathSvg {
                path: canvas.model.current
                      ? Compose.pathFor(canvas.scaleShape(canvas.model.current, canvas.px))
                      : ""
            }
        }
        opacity: 0.35
    }

    // Copies a shape with every coordinate multiplied, for drawing in
    // pixel space. Only the fields each kind actually uses, which is why
    // this is not a loop over the object.
    function scaleShape(s, k) {
        const o = { kind: s.kind, sw: s.sw, c: s.c, fill: s.fill, closed: s.closed };
        switch (s.kind) {
        case "line": o.x1 = s.x1 * k; o.y1 = s.y1 * k; o.x2 = s.x2 * k; o.y2 = s.y2 * k; break;
        case "rect": o.x = s.x * k; o.y = s.y * k; o.w = s.w * k; o.h = s.h * k;
                     o.r = (s.r || 0) * k; break;
        case "circle": o.cx = s.cx * k; o.cy = s.cy * k; o.r = s.r * k; break;
        case "ellipse": o.cx = s.cx * k; o.cy = s.cy * k; o.rx = s.rx * k; o.ry = s.ry * k; break;
        case "arc": o.cx = s.cx * k; o.cy = s.cy * k; o.r = s.r * k;
                    o.a0 = s.a0; o.a1 = s.a1; break;
        case "dot": o.cx = s.cx * k; o.cy = s.cy * k; o.r = s.r * k; break;
        case "poly": o.pts = s.pts.map(v => v * k); break;
        }
        return o;
    }

    // ── handles ───────────────────────────────────────────────────────
    Repeater {
        model: canvas.model.handlesFor(canvas.model.current)

        Item {
            id: handle
            required property var modelData
            anchors.fill: parent

            readonly property bool bezier: modelData.role === "bezier"
            readonly property bool knob: modelData.role === "rot"
            readonly property real hx: canvas.toPixels(modelData.x)
            readonly property real hy: canvas.toPixels(modelData.y)

            // The stalk back to whatever the handle belongs to. Two
            // bezier handles from neighbouring nodes end up side by side
            // often enough that without this there is no telling which
            // curve you are about to change.
            Rectangle {
                visible: handle.modelData.hasStalk
                antialiasing: true
                color: Qt.rgba(canvas.accent.r, canvas.accent.g, canvas.accent.b, 0.5)
                height: 1
                width: Math.hypot(handle.hx - canvas.toPixels(handle.modelData.fromX),
                                  handle.hy - canvas.toPixels(handle.modelData.fromY))
                x: canvas.toPixels(handle.modelData.fromX)
                y: canvas.toPixels(handle.modelData.fromY)
                transformOrigin: Item.TopLeft
                rotation: Math.atan2(handle.hy - canvas.toPixels(handle.modelData.fromY),
                                     handle.hx - canvas.toPixels(handle.modelData.fromX))
                          * 180 / Math.PI
            }

            Rectangle {
                id: grip
                width: handle.bezier ? 9 : 11
                height: width
                // Round for a curve handle, square for a point, so the
                // two are told apart at a glance rather than by aiming
                // at them and seeing what moves.
                radius: (handle.bezier || handle.knob) ? width / 2 : 3
                x: handle.hx - width / 2
                y: handle.hy - height / 2
                color: handleDrag.active || handleHover.hovered
                       ? canvas.accent
                       : (handle.bezier ? Config.Appearance.ground
                                        : Config.Appearance.panel)
                border.width: 1.5
                border.color: canvas.accent

                HoverHandler {
                    id: handleHover
                    cursorShape: handle.knob ? Qt.CrossCursor : Qt.SizeAllCursor
                }
                DragHandler {
                    id: handleDrag
                    target: null
                    onActiveChanged: {
                        if (!active) return;
                        // One undo step for the whole drag, taken as it
                        // starts and nothing written during it.
                        canvas.model.snapshot();
                        const m = /^n(\d+)/.exec(handle.modelData.id);
                        if (m) canvas.model.selectedNode = parseInt(m[1], 10);
                    }
                    onCentroidChanged: {
                        if (!active) return;
                        const p = handleDrag.centroid.scenePosition;
                        const local = canvas.mapFromItem(null, p.x, p.y);
                        // The rotation knob is not snapped to the grid —
                        // it is an angle, and quarter-unit steps along a
                        // stalk make it jump about.
                        const gx = handle.knob ? canvas.toUnits(local.x)
                                               : canvas.snapped(canvas.toUnits(local.x));
                        const gy = handle.knob ? canvas.toUnits(local.y)
                                               : canvas.snapped(canvas.toUnits(local.y));
                        canvas.model.update(
                            canvas.model.dragHandle(canvas.model.current,
                                                    handle.modelData.id, gx, gy),
                            true);
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    // Right-clicking a node is how it stops being a
                    // corner, or starts being one.
                    onClicked: {
                        const m = /^n(\d+)$/.exec(handle.modelData.id);
                        if (m) canvas.model.pathNodeOp("corner", parseInt(m[1], 10));
                    }
                }
            }
        }
    }

    // ── pointer ───────────────────────────────────────────────────────
    property var draft: null
    property real pressX: 0
    property real pressY: 0
    property bool movingShape: false

    // Points collected for a polyline, which is the one tool that takes
    // several clicks rather than one drag.
    property var polyPts: []

    // ── the pen ───────────────────────────────────────────────────────
    //
    // Nodes gathered one click at a time, the way every vector program
    // does it: a click is a corner, a click held and dragged is a curve
    // whose handle you are pulling out as you go. Nothing else here can
    // draw a leaf or a teardrop, and the primitives were never going to.
    // ── the lasso ─────────────────────────────────────────────────────
    //
    // Freehand, and not snapped: a region drawn round part of a shape is
    // a gesture, not geometry, and quarter-unit steps make it jerk about
    // under the pointer for no benefit at all — nothing is kept from it
    // but which side of it things fell on.
    property var lassoPts: []

    property var penNodes: []
    property bool penDragging: false
    // Where the pointer went down, which is the node; the drag from it
    // is the handle.
    property real penX: 0
    property real penY: 0

    function penDraft(extra) {
        const nodes = canvas.penNodes.concat(extra ? [extra] : []);
        if (nodes.length < 2) return null;
        return { kind: "path", c: canvas.nextColour, sw: canvas.nextWeight,
                 nodes: nodes, closed: false };
    }

    function finishPen(closed) {
        if (canvas.penNodes.length >= 2)
            canvas.model.add({ kind: "path", c: canvas.nextColour,
                               sw: canvas.nextWeight,
                               nodes: JSON.parse(JSON.stringify(canvas.penNodes)),
                               closed: closed === true });
        canvas.penNodes = [];
        canvas.penDragging = false;
        canvas.draft = null;
    }

    function finishPoly() {
        if (canvas.polyPts.length >= 4)
            canvas.model.add({ kind: "poly", c: canvas.nextColour, sw: canvas.nextWeight,
                               pts: canvas.polyPts.slice(), closed: false });
        canvas.polyPts = [];
        canvas.draft = null;
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: true

        function ux(p) { return canvas.snapped(canvas.toUnits(p)); }

        onPressed: mouse => {
            canvas.forceActiveFocus();
            const x = ux(mouse.x), y = ux(mouse.y);

            if (mouse.button === Qt.RightButton) {
                // Right-click ends a polyline, which otherwise has no end.
                if (canvas.tool === "poly") canvas.finishPoly();
                else if (canvas.tool === "pen") canvas.finishPen(false);
                return;
            }

            if (canvas.tool === "select") {
                // Slack in units, from a fixed number of pixels: picking
                // things up should feel the same at every zoom.
                const hit = canvas.model.hitTest(x, y, canvas.toUnits(7));
                canvas.model.selected = hit;
                canvas.movingShape = hit >= 0;
                if (hit >= 0) canvas.model.snapshot();
                canvas.pressX = x;
                canvas.pressY = y;
                return;
            }

            if (canvas.tool === "lasso") {
                canvas.lassoPts = [{ x: canvas.toUnits(mouse.x),
                                     y: canvas.toUnits(mouse.y) }];
                return;
            }

            if (canvas.tool === "pen") {
                // Back on the first node closes the shape, which is how
                // you say "that is the outline" rather than hunting for
                // a button.
                if (canvas.penNodes.length >= 2) {
                    const first = canvas.penNodes[0];
                    if (Math.hypot(x - first.x, y - first.y) <= canvas.toUnits(10)) {
                        canvas.finishPen(true);
                        return;
                    }
                }
                canvas.penX = x;
                canvas.penY = y;
                canvas.penDragging = true;
                // Placed as a corner. If the press turns into a drag it
                // grows handles below, which is the difference between
                // the two gestures.
                const nodes = canvas.penNodes.slice();
                nodes.push({ x: x, y: y, corner: true });
                canvas.penNodes = nodes;
                canvas.draft = canvas.penDraft(null);
                return;
            }

            if (canvas.tool === "poly") {
                const pts = canvas.polyPts.slice();
                pts.push(x, y);
                canvas.polyPts = pts;
                canvas.draft = { kind: "poly", c: canvas.nextColour,
                                 sw: canvas.nextWeight, pts: pts };
                return;
            }

            if (canvas.tool === "dot") {
                canvas.model.add({ kind: "dot", c: canvas.nextColour, cx: x, cy: y, r: 1 });
                return;
            }

            canvas.pressX = x;
            canvas.pressY = y;
            canvas.draft = canvas.shapeFrom(canvas.tool, x, y, x, y);
        }

        onPositionChanged: mouse => {
            const x = ux(mouse.x), y = ux(mouse.y);

            if (canvas.tool === "lasso") {
                if (canvas.lassoPts.length === 0) return;
                const ux2 = canvas.toUnits(mouse.x), uy2 = canvas.toUnits(mouse.y);
                const last = canvas.lassoPts[canvas.lassoPts.length - 1];
                // Only when it has moved enough to matter: a point per
                // mouse event is thousands of them for one gesture, and
                // the region is the same shape without them.
                if (Math.hypot(ux2 - last.x, uy2 - last.y) < 0.15) return;
                canvas.lassoPts = canvas.lassoPts.concat([{ x: ux2, y: uy2 }]);
                return;
            }

            if (canvas.tool === "pen") {
                if (canvas.penDragging) {
                    // Pulling a handle out of the node just placed. The
                    // incoming one is its mirror, so the curve runs
                    // through the node rather than turning a corner at
                    // it — which is what a drag is asking for.
                    const nodes = JSON.parse(JSON.stringify(canvas.penNodes));
                    const nd = nodes[nodes.length - 1];
                    if (Math.hypot(x - nd.x, y - nd.y) >= canvas.snap) {
                        nd.corner = false;
                        nd.ho = { x: x, y: y };
                        nd.hi = { x: 2 * nd.x - x, y: 2 * nd.y - y };
                        canvas.penNodes = nodes;
                    }
                    canvas.draft = canvas.penDraft(null);
                } else if (canvas.penNodes.length >= 1) {
                    // The segment that would be added, following the
                    // pointer, so the shape can be seen before it is
                    // committed to.
                    canvas.draft = canvas.penDraft({ x: x, y: y, corner: true });
                }
                return;
            }

            if (canvas.draft && canvas.tool === "poly") {
                // The segment that would be added, following the pointer.
                const pts = canvas.polyPts.concat([x, y]);
                canvas.draft = { kind: "poly", c: canvas.nextColour,
                                 sw: canvas.nextWeight, pts: pts };
                return;
            }
            if (canvas.draft) {
                canvas.draft = canvas.shapeFrom(canvas.tool, canvas.pressX, canvas.pressY, x, y);
                return;
            }
            if (canvas.movingShape && canvas.model.current) {
                canvas.model.moveSelected(x - canvas.pressX, y - canvas.pressY, true);
                canvas.pressX = x;
                canvas.pressY = y;
            }
        }

        onReleased: {
            canvas.movingShape = false;
            if (canvas.tool === "lasso") {
                const pts = canvas.lassoPts;
                canvas.lassoPts = [];
                if (pts.length >= 3) canvas.model.splitByLasso(pts);
                return;
            }
            if (canvas.tool === "pen") { canvas.penDragging = false; return; }
            if (!canvas.draft || canvas.tool === "poly") return;
            // A click with no drag is not a shape. Committing one gives a
            // zero-sized thing that draws nothing and cannot be grabbed
            // again — an invisible entry in the list.
            const b = canvas.model.boundsOf(canvas.draft);
            if (b.w >= canvas.snap || b.h >= canvas.snap) canvas.model.add(canvas.draft);
            canvas.draft = null;
        }

        onDoubleClicked: {
            if (canvas.tool === "poly") canvas.finishPoly();
            else if (canvas.tool === "pen") canvas.finishPen(false);
        }
    }

    function turn(by) {
        if (!canvas.model.current) return;
        let deg = (canvas.model.current.rot || 0) + by;
        while (deg <= -180) deg += 360;
        while (deg > 180) deg -= 360;
        canvas.model.update({ rot: deg });
    }

    // A shape from the two corners of a drag.
    function shapeFrom(kind, x0, y0, x1, y1) {
        const c = canvas.nextColour, sw = canvas.nextWeight;
        switch (kind) {
        case "line":
            return { kind: "line", c: c, sw: sw, x1: x0, y1: y0, x2: x1, y2: y1 };
        case "rect":
            return { kind: "rect", c: c, sw: sw,
                     x: Math.min(x0, x1), y: Math.min(y0, y1),
                     w: Math.abs(x1 - x0), h: Math.abs(y1 - y0), r: 0 };
        case "circle":
            // From the centre out, which is how you place a circle on a
            // grid: the middle is the part you are aiming at.
            return { kind: "circle", c: c, sw: sw, cx: x0, cy: y0,
                     r: Math.max(canvas.snap, Math.hypot(x1 - x0, y1 - y0)) };
        case "ellipse":
            return { kind: "ellipse", c: c, sw: sw, cx: x0, cy: y0,
                     rx: Math.max(canvas.snap, Math.abs(x1 - x0)),
                     ry: Math.max(canvas.snap, Math.abs(y1 - y0)) };
        case "arc":
            // Half a circle to begin with, because an arc of no sweep is
            // invisible and there would be nothing to grab.
            return { kind: "arc", c: c, sw: sw, cx: x0, cy: y0,
                     r: Math.max(canvas.snap, Math.hypot(x1 - x0, y1 - y0)),
                     a0: 180, a1: 360 };
        }
        return null;
    }

    // ── keys ──────────────────────────────────────────────────────────
    focus: true
    Keys.onPressed: event => {
        const step = (event.modifiers & Qt.ShiftModifier) ? 1 : canvas.snap;
        switch (event.key) {
        case Qt.Key_Delete:
        case Qt.Key_Backspace:
            canvas.model.removeSelected(); event.accepted = true; return;
        case Qt.Key_Escape:
            if (canvas.lassoPts.length > 0) { canvas.lassoPts = []; }
            else if (canvas.penNodes.length > 0) {
                canvas.penNodes = []; canvas.penDragging = false; canvas.draft = null;
            } else if (canvas.polyPts.length > 0) {
                canvas.polyPts = []; canvas.draft = null;
            } else canvas.model.selected = -1;
            event.accepted = true; return;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (canvas.tool === "poly") canvas.finishPoly();
            else if (canvas.tool === "pen") canvas.finishPen(false);
            event.accepted = true; return;
        // Turning, in steps, because dragging a knob to exactly 45 is
        // not something a pointer is good at.
        case Qt.Key_BracketLeft:
            canvas.turn(-(event.modifiers & Qt.ShiftModifier ? 1 : 15));
            event.accepted = true; return;
        case Qt.Key_BracketRight:
            canvas.turn(event.modifiers & Qt.ShiftModifier ? 1 : 15);
            event.accepted = true; return;
        case Qt.Key_Left:  canvas.model.moveSelected(-step, 0); event.accepted = true; return;
        case Qt.Key_Right: canvas.model.moveSelected(step, 0);  event.accepted = true; return;
        case Qt.Key_Up:    canvas.model.moveSelected(0, -step); event.accepted = true; return;
        case Qt.Key_Down:  canvas.model.moveSelected(0, step);  event.accepted = true; return;
        }
        if (event.modifiers & Qt.ControlModifier) {
            if (event.key === Qt.Key_Z) {
                if (event.modifiers & Qt.ShiftModifier) canvas.model.redo();
                else canvas.model.undo();
                event.accepted = true;
            } else if (event.key === Qt.Key_Y) {
                canvas.model.redo(); event.accepted = true;
            } else if (event.key === Qt.Key_D) {
                canvas.model.duplicateSelected(); event.accepted = true;
            }
        }
    }
}
