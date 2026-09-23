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
    scale: shown ? 1 : 0.985
    transformOrigin: Item.Top

    Behavior on opacity {
        NumberAnimation {
            duration: Config.Appearance.anim(root.shown ? 180 : 120)
            easing.type: Easing.OutCubic
        }
    }
    Behavior on scale {
        NumberAnimation {
            duration: Config.Appearance.anim(220)
            easing.type: Easing.OutQuint
        }
    }

    Item {
        id: holder
        width: parent.width
        height: parent.height
        y: root.shown ? 0 : root.fromY
        x: root.shown ? 0 : root.fromX
        Behavior on y {
            NumberAnimation {
                duration: Config.Appearance.anim(root.shown ? 260 : 140)
                easing.type: Easing.OutQuint
            }
        }
        Behavior on x {
            NumberAnimation {
                duration: Config.Appearance.anim(root.shown ? 260 : 140)
                easing.type: Easing.OutQuint
            }
        }
    }
}
