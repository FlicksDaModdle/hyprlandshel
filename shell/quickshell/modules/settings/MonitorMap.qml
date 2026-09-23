import QtQuick
import "../../config" as Config
import "../common"

// Drag your screens into the arrangement you actually have.
//
// Hyprland places outputs on one plane by top-left corner in logical
// pixels, and until now this panel could only report those numbers. This
// draws the plane to scale, lets you move a screen on it, and writes the
// position back.
//
// Dropping snaps: a screen released within a few pixels of touching
// another lands exactly flush against it. Positions in Hyprland are
// absolute and unforgiving — a one-pixel gap between two outputs is a
// column of desktop the pointer cannot cross — so "nearly aligned" is
// never what is wanted.
Item {
    id: map

    // [{ name, x, y, width, height, scale, focused }] in logical pixels.
    required property var monitors
    property string selected: ""
    signal moved(string name, int x, int y)
    signal picked(string name)

    // How close counts as touching, in logical pixels of the real desktop.
    readonly property int snap: 60

    implicitHeight: 190

    // ── the plane, scaled to fit ──────────────────────────────────────────
    readonly property var bounds: {
        let x0 = 0, y0 = 0, x1 = 0, y1 = 0, first = true;
        for (const m of map.monitors) {
            const w = m.width / (m.scale || 1), h = m.height / (m.scale || 1);
            if (first) { x0 = m.x; y0 = m.y; x1 = m.x + w; y1 = m.y + h; first = false; }
            else {
                x0 = Math.min(x0, m.x); y0 = Math.min(y0, m.y);
                x1 = Math.max(x1, m.x + w); y1 = Math.max(y1, m.y + h);
            }
        }
        // A margin of one screen-width all round, so there is somewhere to
        // drag to rather than the arrangement filling the box exactly.
        const padX = (x1 - x0) * 0.25 + 200, padY = (y1 - y0) * 0.25 + 200;
        return ({ x: x0 - padX, y: y0 - padY,
                  w: (x1 - x0) + padX * 2, h: (y1 - y0) + padY * 2 });
    }

    readonly property real k: {
        if (map.bounds.w <= 0 || map.bounds.h <= 0) return 0.05;
        return Math.min(width / map.bounds.w, height / map.bounds.h);
    }
    function px(v) { return v * map.k; }

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rSm
        color: Config.Appearance.surface
        border.width: 1
        border.color: Config.Appearance.rule
        clip: true

        Repeater {
            model: map.monitors

            Rectangle {
                id: screen
                required property var modelData

                readonly property real lw: modelData.width / (modelData.scale || 1)
                readonly property real lh: modelData.height / (modelData.scale || 1)
                readonly property bool isSelected: map.selected === modelData.name

                width: Math.max(18, map.px(lw))
                height: Math.max(14, map.px(lh))
                x: map.px(modelData.x - map.bounds.x)
                y: map.px(modelData.y - map.bounds.y)
                radius: Config.Appearance.rSm
                color: isSelected ? Config.Appearance.sel : Config.Appearance.hover
                border.width: isSelected ? 2 : 1
                border.color: isSelected ? Config.Appearance.accent
                                         : Config.Appearance.seam

                // Not while being dragged: the drag owns x and y then, and
                // a binding fighting the drag is a screen that will not move.
                Binding on x {
                    when: !drag.active
                    value: map.px(screen.modelData.x - map.bounds.x)
                }
                Binding on y {
                    when: !drag.active
                    value: map.px(screen.modelData.y - map.bounds.y)
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 1
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: screen.modelData.name
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.DemiBold
                        color: screen.isSelected ? Config.Appearance.ink
                                                 : Config.Appearance.ink2
                    }
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: screen.height > 34
                        text: Math.round(screen.lw) + " × " + Math.round(screen.lh)
                        font.pixelSize: Config.Appearance.fs(9.5)
                        color: Config.Appearance.ink3
                    }
                }

                MouseArea {
                    id: drag
                    anchors.fill: parent
                    cursorShape: Qt.SizeAllCursor
                    drag.target: screen
                    drag.threshold: 3
                    property bool active: drag.drag.active

                    onPressed: map.picked(screen.modelData.name)
                    onReleased: {
                        if (map.k <= 0) return;
                        // Back to desktop coordinates, then snapped.
                        let nx = Math.round(screen.x / map.k + map.bounds.x);
                        let ny = Math.round(screen.y / map.k + map.bounds.y);
                        const snapped = map.snapTo(screen.modelData.name, nx, ny,
                                                   screen.lw, screen.lh);
                        map.moved(screen.modelData.name, snapped.x, snapped.y);
                    }
                }
            }
        }
    }

    // Flush against a neighbour on whichever axis is closest, and aligned
    // on the other if it is near enough to have been meant.
    function snapTo(name, x, y, w, h) {
        let bx = x, by = y;
        let bestX = map.snap, bestY = map.snap;
        for (const o of map.monitors) {
            if (o.name === name) continue;
            const ow = o.width / (o.scale || 1), oh = o.height / (o.scale || 1);
            // Edges that make two screens touch.
            for (const [cand, ref] of [[o.x + ow, x], [o.x - w, x],
                                       [o.x, x], [o.x + ow - w, x]]) {
                const d = Math.abs(cand - ref);
                if (d < bestX) { bestX = d; bx = cand; }
            }
            for (const [cand, ref] of [[o.y + oh, y], [o.y - h, y],
                                       [o.y, y], [o.y + oh - h, y]]) {
                const d = Math.abs(cand - ref);
                if (d < bestY) { bestY = d; by = cand; }
            }
        }
        return ({ x: bx, y: by });
    }
}
