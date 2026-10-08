import QtQuick
import "../../config" as Config

// How a dropdown arrives and leaves.
//
// The panels used to do neither: `visible` flipped and they were simply
// there, which is the one transition a shell cannot get away with, because
// nothing tells you where the thing came from. This drops them a short way
// out of the edge they hang off, with a slight scale so the movement has
// somewhere to come from, and takes them back the same way.
//
// Leaving is quicker than arriving and skips the scale. A panel you have
// dismissed should get out of the way; only the arrival needs to be
// explained.
Item {
    id: root

    property bool shown: false
    // Which edge it hangs off, so it comes from the right direction.
    property real fromY: -10
    property real fromX: 0

    default property alias content: holder.data

    implicitWidth: holder.childrenRect.width
    implicitHeight: holder.childrenRect.height

    // Held on screen until the exit has played out.
    visible: shown || opacity > 0.01
    opacity: shown ? 1 : 0
    // Springy motion starts it smaller, so the overshoot has something
    // to land from.
    scale: shown ? 1 : (Config.Appearance.springy ? 0.9 : 0.985)
    transformOrigin: root.fromX < 0 ? Item.TopLeft : root.fromX > 0 ? Item.TopRight : Item.Top

    Behavior on opacity {
        NumberAnimation {
            duration: Config.Appearance.anim(root.shown ? 160 : 120)
            easing.type: Easing.OutCubic
        }
    }
    Behavior on scale { Spring { ms: root.shown ? 480 : 140; bounce: root.shown ? 1.4 : 0 } }

    Item {
        id: holder
        width: parent.width
        height: parent.height
        // Further to travel when it springs, so the landing shows.
        readonly property real travel: Config.Appearance.springy ? 1.8 : 1
        y: root.shown ? 0 : root.fromY * travel
        x: root.shown ? 0 : root.fromX * travel
        Behavior on y { Spring { ms: root.shown ? 480 : 140; bounce: root.shown ? 1.2 : 0 } }
        Behavior on x { Spring { ms: root.shown ? 480 : 140; bounce: root.shown ? 1.2 : 0 } }
    }
}
