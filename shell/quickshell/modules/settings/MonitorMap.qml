import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../common"

// Drag your screens into the arrangement you actually have.
//
// Hyprland places outputs on one plane by top-left corner in logical
// pixels. This draws the plane to scale, numbered, lets you move a screen
// on it and writes the position back.
//
// It snaps while you drag — the outline where it will land is drawn — and
// on release a screen lands exactly flush against its neighbour, never
// over it. Positions in Hyprland are absolute and unforgiving: a one-pixel
// gap between two outputs is a column the pointer cannot cross, and two
// outputs overlapping show the same part of the desktop twice.
//
// Identify puts each screen's number on the screen itself for a moment.
Item {
    id: map

    // [{ name, x, y, width, height, scale, focused, main }] in logical pixels.
    required property var monitors
    property string selected: ""
    signal moved(string name, int x, int y)
    signal picked(string name)

    // How close counts as touching, in logical pixels of the real desktop.
    readonly property int snap: 80

    implicitHeight: 240

    function numberOf(name) {
        const i = map.monitors.findIndex(m => m.name === name);
        return i >= 0 ? i + 1 : 0;
    }

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
        // Room all round to drag a screen to any side of the others.
        const padX = (x1 - x0) * 0.35 + 300, padY = (y1 - y0) * 0.35 + 300;
        return ({ x: x0 - padX, y: y0 - padY,
                  w: (x1 - x0) + padX * 2, h: (y1 - y0) + padY * 2 });
    }

    readonly property real k: {
        if (map.bounds.w <= 0 || map.bounds.h <= 0) return 0.05;
        return Math.min(width / map.bounds.w, (height - 8) / map.bounds.h);
    }
    // The plane centred in the box.
    readonly property real ox: (width - map.bounds.w * map.k) / 2
    readonly property real oy: (height - map.bounds.h * map.k) / 2
    function px(v) { return v * map.k; }

    // Where the screen being dragged would land, in desktop coordinates.
    property string dragging: ""
    property point landing: Qt.point(0, 0)
    property size landingSize: Qt.size(0, 0)

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.r
        color: Config.Appearance.surface
        border.width: 1
        border.color: Config.Appearance.rule
        clip: true

        // The outline of where it will land.
        Rectangle {
            visible: map.dragging !== ""
            x: map.ox + map.px(map.landing.x - map.bounds.x)
            y: map.oy + map.px(map.landing.y - map.bounds.y)
            width: map.px(map.landingSize.width)
            height: map.px(map.landingSize.height)
            radius: Config.Appearance.rSm
            color: "transparent"
            border.width: 2
            border.color: Config.Appearance.accent
            opacity: 0.7
        }

        Repeater {
            model: map.monitors

            Rectangle {
                id: screen
                required property var modelData
                required property int index

                readonly property real lw: modelData.width / (modelData.scale || 1)
                readonly property real lh: modelData.height / (modelData.scale || 1)
                readonly property bool isSelected: map.selected === modelData.name

                width: Math.max(24, map.px(lw))
                height: Math.max(18, map.px(lh))
                radius: Config.Appearance.rSm
                color: isSelected ? Config.Appearance.sel : Config.Appearance.hover
                border.width: isSelected ? 2 : 1
                border.color: isSelected ? Config.Appearance.accent : Config.Appearance.seam
                z: drag.active ? 2 : 1
                opacity: drag.active ? 0.85 : 1

                // Not while being dragged: the drag owns x and y then.
                Binding on x {
                    when: !drag.active
                    value: map.ox + map.px(screen.modelData.x - map.bounds.x)
                }
                Binding on y {
                    when: !drag.active
                    value: map.oy + map.px(screen.modelData.y - map.bounds.y)
                }

                function desktopPos() {
                    return Qt.point(Math.round((screen.x - map.ox) / map.k + map.bounds.x),
                                    Math.round((screen.y - map.oy) / map.k + map.bounds.y));
                }
                onXChanged: if (drag.active) map.track(screen)
                onYChanged: if (drag.active) map.track(screen)

                Column {
                    anchors.centerIn: parent
                    spacing: 2
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: (screen.index + 1) + (screen.modelData.main ? " ★" : "")
                        font.pixelSize: Config.Appearance.fs(screen.height > 60 ? 20 : 13)
                        font.weight: Font.Bold
                        color: screen.isSelected ? Config.Appearance.accent : Config.Appearance.ink
                    }
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: screen.height > 44
                        text: screen.modelData.name
                        font.pixelSize: Config.Appearance.fs(10.5)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink2
                    }
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: screen.height > 62
                        text: Math.round(screen.lw) + " × " + Math.round(screen.lh)
                        font.pixelSize: Config.Appearance.fs(9.5)
                        color: Config.Appearance.ink3
                    }
                }

                MouseArea {
                    id: drag
                    anchors.fill: parent
                    cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    drag.target: map.monitors.length > 1 ? screen : null
                    drag.threshold: 3
                    readonly property bool active: drag.drag.active

                    onPressed: map.picked(screen.modelData.name)
                    onReleased: {
                        if (map.dragging === "" || map.k <= 0) return;
                        const p = map.landing;
                        map.dragging = "";
                        if (p.x !== screen.modelData.x || p.y !== screen.modelData.y)
                            map.moved(screen.modelData.name, p.x, p.y);
                    }
                }
            }
        }

        // Identify: each screen's number, on the screen itself.
        Rectangle {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 8
            width: idText.implicitWidth + 22
            height: 26
            radius: height / 2
            color: idHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
            border.width: 1
            border.color: Config.Appearance.seam
            StyledText {
                id: idText
                anchors.centerIn: parent
                text: identifyTimer.running ? "Showing…" : "Identify"
                font.pixelSize: Config.Appearance.fs(11)
                font.weight: Font.DemiBold
                color: Config.Appearance.ink
            }
            HoverHandler { id: idHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: identifyTimer.restart() }
        }
    }

    // While a screen is dragged: where it would land, snapped and clear of
    // the others.
    function track(screen) {
        const p = screen.desktopPos();
        const s = map.snapTo(screen.modelData.name, p.x, p.y, screen.lw, screen.lh);
        const c = map.clear(screen.modelData.name, s.x, s.y, screen.lw, screen.lh);
        map.dragging = screen.modelData.name;
        map.landing = Qt.point(Math.round(c.x), Math.round(c.y));
        map.landingSize = Qt.size(screen.lw, screen.lh);
    }

    function sizeOf(o) { return { w: o.width / (o.scale || 1), h: o.height / (o.scale || 1) }; }

    // Flush against a neighbour on whichever axis is closest, and aligned
    // on the other if it is near enough to have been meant.
    function snapTo(name, x, y, w, h) {
        let bx = x, by = y;
        let bestX = map.snap, bestY = map.snap;
        for (const o of map.monitors) {
            if (o.name === name) continue;
            const os = map.sizeOf(o);
            for (const cand of [o.x + os.w, o.x - w, o.x, o.x + os.w - w, o.x + (os.w - w) / 2]) {
                const d = Math.abs(cand - x);
                if (d < bestX) { bestX = d; bx = cand; }
            }
            for (const cand of [o.y + os.h, o.y - h, o.y, o.y + os.h - h, o.y + (os.h - h) / 2]) {
                const d = Math.abs(cand - y);
                if (d < bestY) { bestY = d; by = cand; }
            }
        }
        return ({ x: bx, y: by });
    }

    // Never on top of another screen: moved the least way out of any it
    // overlaps, to lie against it. And never floating free: one with no
    // neighbour touching is pulled in against the nearest.
    function overlaps(name, x, y, w, h) {
        return map.monitors.find(o => {
            if (o.name === name) return false;
            const os = map.sizeOf(o);
            return x < o.x + os.w && x + w > o.x && y < o.y + os.h && y + h > o.y;
        }) || null;
    }
    function clear(name, x, y, w, h) {
        for (let tries = 0; tries < 6; tries++) {
            const o = map.overlaps(name, x, y, w, h);
            if (!o) break;
            const os = map.sizeOf(o);
            const ways = [
                { x: o.x - w, y: y }, { x: o.x + os.w, y: y },
                { x: x, y: o.y - h }, { x: x, y: o.y + os.h }
            ];
            ways.sort((a, b) => (Math.abs(a.x - x) + Math.abs(a.y - y)) - (Math.abs(b.x - x) + Math.abs(b.y - y)));
            x = ways[0].x; y = ways[0].y;
        }
        // Touching something?
        const others = map.monitors.filter(o => o.name !== name);
        if (others.length === 0) return ({ x: x, y: y });
        const touches = others.some(o => {
            const os = map.sizeOf(o);
            const xTouch = (Math.abs(x + w - o.x) < 1 || Math.abs(o.x + os.w - x) < 1) && y < o.y + os.h && y + h > o.y;
            const yTouch = (Math.abs(y + h - o.y) < 1 || Math.abs(o.y + os.h - y) < 1) && x < o.x + os.w && x + w > o.x;
            return xTouch || yTouch;
        });
        if (touches) return ({ x: x, y: y });
        // The nearest side of the nearest screen, keeping the other axis
        // within its span.
        let best = null, bestD = Infinity;
        for (const o of others) {
            const os = map.sizeOf(o);
            // Lined up with it: anywhere from top edges level to bottom
            // edges level (left to right for above and below).
            const cy = Math.max(Math.min(o.y, o.y + os.h - h), Math.min(y, Math.max(o.y, o.y + os.h - h)));
            const cx = Math.max(Math.min(o.x, o.x + os.w - w), Math.min(x, Math.max(o.x, o.x + os.w - w)));
            for (const c of [{ x: o.x - w, y: cy }, { x: o.x + os.w, y: cy },
                             { x: cx, y: o.y - h }, { x: cx, y: o.y + os.h }]) {
                if (map.overlaps(name, c.x, c.y, w, h)) continue;
                const d = Math.hypot(c.x - x, c.y - y);
                if (d < bestD) { bestD = d; best = c; }
            }
        }
        return best || ({ x: x, y: y });
    }

    Timer { id: identifyTimer; interval: 2500 }

    LazyLoader {
        active: identifyTimer.running
        Variants {
            model: Quickshell.screens
            PanelWindow {
                id: badge
                required property var modelData
                screen: modelData
                readonly property int number: map.numberOf(modelData.name)
                anchors.top: true
                anchors.left: true
                margins.top: 40
                margins.left: 40
                implicitWidth: 180
                implicitHeight: 180
                color: "transparent"
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.namespace: "quickshell:panel"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                mask: Region {}
                Rectangle {
                    anchors.fill: parent
                    radius: Config.Appearance.r * 2
                    color: Config.Appearance.surface
                    border.width: 2
                    border.color: Config.Appearance.accent
                    Column {
                        anchors.centerIn: parent
                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: badge.number > 0 ? String(badge.number) : "?"
                            font.pixelSize: 96
                            font.weight: Font.Bold
                            color: Config.Appearance.accent
                        }
                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: badge.modelData.name
                            font.pixelSize: 14
                            color: Config.Appearance.ink2
                        }
                    }
                }
            }
        }
    }
}
