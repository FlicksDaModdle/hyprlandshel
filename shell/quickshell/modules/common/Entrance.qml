import QtQuick
import "../../config" as Config

// How a dropdown arrives and leaves.
//
// The way Liquid Glass does it: a panel grows out of the control that
// opened it, like a drop drawn out of the bar. Its width leads and its
// height follows, so it stretches out sideways, drops down, overshoots a
// little and settles. Leaving, it draws back into the same spot. There is
// hardly any fade: it is visible from the first frame, small, and it is
// the movement that says where it came from.
//
// Opened from anywhere but a bar control (a shortcut, the launcher) it
// grows from its own top edge, centred. With Motion set to Smooth it only
// drops a short way and eases in, as it used to.
Item {
    id: root

    property bool shown: false
    // Which edge it hangs off, so it comes from the right direction.
    property real fromY: -10
    property real fromX: 0

    default property alias content: holder.data

    implicitWidth: holder.childrenRect.width
    implicitHeight: holder.childrenRect.height

    readonly property bool liquid: Config.Appearance.springy && Config.Appearance.animated

    // Where across it to grow from, fixed when it opens so leaving goes
    // back to the same place.
    property real originX: width / 2
    onShownChanged: if (shown) {
        const ui = Config.UiState;
        const fresh = ui.panelOriginX >= 0 && Date.now() - ui.panelOriginAt < 700;
        originX = fresh ? Math.max(0, Math.min(width, ui.panelOriginX - x)) : width / 2;
    }

    // Held on screen until the exit has played out.
    visible: shown || opacity > 0.01
    // Only the first and last few frames are faded — enough that it never
    // pops, not enough to read as a fade.
    opacity: shown ? 1 : 0
    Behavior on opacity {
        NumberAnimation { duration: Config.Appearance.anim(root.shown ? 70 : 210); easing.type: Easing.InQuad }
    }

    property real sx: shown ? 1 : (liquid ? 0.42 : 0.985)
    property real sy: shown ? 1 : (liquid ? 0.12 : 0.985)
    Behavior on sx { Spring { ms: root.shown ? 520 : 240; bounce: root.shown ? 1.2 : 0 } }
    Behavior on sy { Spring { ms: root.shown ? 640 : 220; bounce: root.shown ? 1.0 : 0 } }
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
        // Smooth motion drops it in; liquid motion grows it in place.
        readonly property real travel: root.liquid ? 0 : 1
        y: root.shown ? 0 : root.fromY * travel
        x: root.shown ? 0 : root.fromX * travel
        Behavior on y { Spring { ms: root.shown ? 420 : 140; bounce: 0 } }
        Behavior on x { Spring { ms: root.shown ? 420 : 140; bounce: 0 } }
        // The contents arrive a beat behind the glass around them, so the
        // shape is mostly there before what is in it shows.
        opacity: root.shown ? 1 : 0
        Behavior on opacity {
            NumberAnimation { duration: Config.Appearance.anim(root.shown ? 180 : 90); easing.type: Easing.OutQuad }
        }
    }
}
