import QtQuick
import "../../config" as Config

// How a dropdown arrives and leaves.
//
// The way Liquid Glass does it: a panel grows out of the control that
// opened it. Its width leads and its height follows a beat behind, each on
// its own spring, so it swells out of the button, settles with a touch of
// give and is still. Leaving, it draws back into the same spot, without
// any swing. The glass is there almost at once; its contents come in a
// moment behind it, into a shape that has nearly stopped.
//
// Opened from anywhere but a bar control (a shortcut, the launcher) it
// grows from its own top edge, centred. With "Panels grow from their
// button" off, or Motion set to Smooth, it drops a short way and settles.
//
// Every number is a Spring (common/Spring.qml), so opening it again while
// it is still closing turns it round from where it is, at the speed it
// has, rather than starting over.
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
    // Where it starts from (and goes back to): a smaller, flatter copy of
    // itself at the button, or — not growing — itself, a little short of
    // its place.
    readonly property real startX: grows ? 0.74 : 0.97
    readonly property real startY: grows ? 0.5 : 0.97
    readonly property real startLift: grows ? fromY * 0.4 : fromY * 1.2
    readonly property real startShift: grows ? fromX * 0.4 : fromX * 1.2

    // Where across it to grow from, fixed when it opens so leaving goes
    // back to the same place.
    property real originX: width / 2

    Spring { id: sx; to: root.shown ? 1 : root.startX; response: root.shown ? 340 : 230; bounce: root.shown ? 0.9 : 0 }
    Spring { id: sy; to: root.shown ? 1 : root.startY; response: root.shown ? 400 : 210; bounce: root.shown ? 0.8 : 0 }
    Spring { id: lift; to: root.shown ? 0 : root.startLift; response: root.shown ? 360 : 210; bounce: root.shown ? 0.8 : 0 }
    Spring { id: shift; to: root.shown ? 0 : root.startShift; response: root.shown ? 360 : 210; bounce: root.shown ? 0.8 : 0 }
    // The glass: nearly at once, and never past 1.
    Spring { id: glass; to: root.shown ? 1 : 0; response: root.shown ? 150 : 170; bounce: 0 }
    // The contents start below zero so they only show once the shape is
    // most of the way out — a delay with no timer, which turning round
    // mid-way cannot get out of step with.
    Spring { id: inner; to: root.shown ? 1 : 0; response: root.shown ? 260 : 120; bounce: 0 }

    opacity: Math.max(0, Math.min(1, glass.value))
    visible: shown || opacity > 0.004

    Component.onCompleted: {
        const v = shown ? 1 : 0;
        sx.snap(shown ? 1 : startX); sy.snap(shown ? 1 : startY);
        lift.snap(shown ? 0 : startLift); shift.snap(shown ? 0 : startShift);
        glass.snap(v); inner.snap(v);
    }
    onShownChanged: {
        if (!shown || glass.value > 0.05) return;
        // From closed: start from the bud at the button that opened it,
        // whatever the last closing left behind.
        const ui = Config.UiState;
        const fresh = ui.panelOriginX >= 0 && Date.now() - ui.panelOriginAt < 700;
        originX = fresh ? Math.max(0, Math.min(width, ui.panelOriginX - x)) : width / 2;
        sx.snap(startX); sy.snap(startY); lift.snap(startLift); shift.snap(startShift);
        inner.snap(-0.45);
        sx.wake(); sy.wake(); lift.wake(); shift.wake(); inner.wake();
    }

    transform: Scale {
        origin.x: root.originX
        origin.y: root.fromY > 0 ? root.height : 0
        xScale: sx.value
        yScale: sy.value
    }

    Item {
        id: holder
        width: parent.width
        height: parent.height
        y: lift.value
        x: shift.value
        opacity: Math.max(0, Math.min(1, inner.value))
    }
}
