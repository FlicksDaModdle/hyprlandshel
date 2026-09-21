import QtQuick
import "../../config" as Config

// Hairline between dock sections. Flow top-aligns children of unequal size,
// so the divider claims a tile-sized box and centres the actual line in it.
Item {
    id: root

    property bool isLeft: false
    property real tileSize: 42

    width: isLeft ? tileSize : 7
    height: isLeft ? 7 : tileSize

    Rectangle {
        anchors.centerIn: parent
        width: root.isLeft ? 26 : 1
        height: root.isLeft ? 1 : 26
        color: Config.Appearance.div
    }
}
