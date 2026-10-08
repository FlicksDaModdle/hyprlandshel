import QtQuick
import "../../config" as Config

// How a dropdown arrives and leaves.
//
// The way Liquid Glass does it: a panel grows out of the control that
// opened it, like a drop drawn out of the bar. Its width leads and its
// height follows, so it stretches out sideways, drops down, swings a
// little past and settles. Leaving, it draws back into the same spot.
// There is hardly any fade: the glass is there from the first frame, and
// its contents come in a beat behind it.
//
// Opened from anywhere but a bar control (a shortcut, the launcher) it
// grows from its own top edge, centred. With "Panels grow from their
// button" off, or Motion set to Smooth, it drops a short way and settles.
//
// Played explicitly on every change of `shown`, from wherever it stands,
// rather than left to Behaviors on bound values: those keep their last
// state, and an exit frozen part-way (the layer hidden under it) left the
// next opening with nothing to animate.
Item {
    id: root

    property bool shown: false
    // Which edge it hangs off, so it comes from the right direction.
    property real fromY: -10
    property real fromX: 0

    default property alias content: holder.data

    implicitWidth: holder.childrenRect.width
    implicitHeight: holder.childrenRect.height

    readonly property var ap: Config.Appearance
    readonly property bool grows: ap.springy && ap.panelsGrow && ap.animated
    readonly property real startX: grows ? 0.4 : 0.97
    readonly property real startY: grows ? 0.1 : 0.97
    readonly property real startLift: grows ? 0 : fromY * 1.6
    readonly property real startShift: grows ? 0 : fromX * 1.6

    // Where across it to grow from, fixed when it opens so leaving goes
    // back to the same place.
    property real originX: width / 2

    property real sx: startX
    property real sy: startY
    property real lift: startLift
    property real shift: startShift
    opacity: 0
    visible: shown || opacity > 0.001

    Component.onCompleted: if (shown) { sx = 1; sy = 1; lift = 0; shift = 0; opacity = 1; holder.opacity = 1; }
    onShownChanged: shown ? arrive() : leave()

    function arrive() {
        leaving.stop();
        const ui = Config.UiState;
        const fresh = ui.panelOriginX >= 0 && Date.now() - ui.panelOriginAt < 700;
        // Mid-exit it turns round from where it is; otherwise it starts
        // from the bud.
        if (opacity < 0.05) {
            originX = fresh ? Math.max(0, Math.min(width, ui.panelOriginX - x)) : width / 2;
            sx = startX; sy = startY; lift = startLift; shift = startShift;
            holder.opacity = 0;
        }
        arriving.restart();
    }
    function leave() {
        arriving.stop();
        leaving.restart();
    }

    ParallelAnimation {
        id: arriving
        NumberAnimation { target: root; property: "opacity"; to: 1; duration: root.ap.anim(50) }
        // Width first, height a beat behind: stretched, then full.
        Spring { target: root; property: "sx"; to: 1; ms: 360; bounce: 1.1 }
        Spring { target: root; property: "sy"; to: 1; ms: 440; bounce: 0.9 }
        Spring { target: root; property: "lift"; to: 0; ms: 360 }
        Spring { target: root; property: "shift"; to: 0; ms: 360 }
        SequentialAnimation {
            PauseAnimation { duration: root.ap.anim(root.grows ? 50 : 0) }
            NumberAnimation { target: holder; property: "opacity"; to: 1; duration: root.ap.anim(110); easing.type: Easing.OutQuad }
        }
    }
    ParallelAnimation {
        id: leaving
        NumberAnimation { target: holder; property: "opacity"; to: 0; duration: root.ap.anim(70) }
        Spring { target: root; property: "sx"; to: root.startX; ms: 220; bounce: 0 }
        Spring { target: root; property: "sy"; to: root.startY; ms: 200; bounce: 0 }
        Spring { target: root; property: "lift"; to: root.startLift; ms: 200; bounce: 0 }
        Spring { target: root; property: "shift"; to: root.startShift; ms: 200; bounce: 0 }
        SequentialAnimation {
            PauseAnimation { duration: root.ap.anim(90) }
            NumberAnimation { target: root; property: "opacity"; to: 0; duration: root.ap.anim(100); easing.type: Easing.InQuad }
        }
    }

    transform: Scale {
        origin.x: root.originX
        origin.y: root.fromY > 0 ? root.height : 0
        xScale: root.sx
        yScale: root.sy
    }

    Item {
        id: holder
        width: parent.width
        height: parent.height
        y: root.lift
        x: root.shift
        opacity: 0
    }
}
