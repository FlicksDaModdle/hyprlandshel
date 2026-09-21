import QtQuick
import "../../config" as Config

// 40x22 pill switch — the mockup's toggle, used in Settings rows and the
// control center's drill-down header.
Item {
    id: root

    // Bound by the caller to live state; never written from in here, so
    // that binding survives being clicked.
    property bool checked: false
    signal toggled(bool checked)

    implicitWidth: 40
    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Config.Appearance.accent : Config.Appearance.sel
        opacity: root.enabled ? 1 : 0.45
        Behavior on color { ColorAnimation { duration: 160 } }

        Rectangle {
            width: parent.height - 4
            height: width
            radius: width / 2
            y: 2
            x: root.checked ? parent.width - width - 2 : 2
            color: root.checked ? Config.Appearance.onAccent : Config.Appearance.ink2
            Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 160 } }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
