import QtQuick
import "../../config" as Config

// A slider with its rest point in the middle — balance, fade, a delay that
// can go either way. `value` runs -1 to 1; the fill grows out from the
// centre towards it. A double-click puts it back in the middle.
Item {
    id: root

    property real value: 0
    signal moved(real value)

    implicitHeight: 14
    implicitWidth: 200

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rSm
        color: Config.Appearance.ground
        border.width: 1
        border.color: Config.Appearance.rule
    }
    Rectangle {
        readonly property real c: root.width / 2
        readonly property real v: Math.max(-1, Math.min(1, root.value))
        x: v < 0 ? c + v * c : c
        width: Math.max(2, Math.abs(v) * c)
        height: parent.height
        radius: Config.Appearance.rSm
        color: Config.Appearance.accent
    }
    Rectangle {
        x: parent.width / 2 - 1
        width: 2; height: parent.height
        color: Config.Appearance.ink3
    }
    MouseArea {
        anchors.fill: parent
        anchors.topMargin: -6
        anchors.bottomMargin: -6
        cursorShape: Qt.PointingHandCursor
        preventStealing: true
        function set(x) { root.moved(Math.max(-1, Math.min(1, (x / width) * 2 - 1))); }
        onPressed: mouse => set(mouse.x)
        onPositionChanged: mouse => { if (pressed) set(mouse.x); }
        onDoubleClicked: root.moved(0)
    }
}
