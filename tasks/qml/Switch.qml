import QtQuick
import Hyprshell

// An on/off switch.
Item {
    id: sw
    property bool checked: false
    property bool active: true
    signal toggled(bool on)
    implicitWidth: 38
    implicitHeight: 22
    opacity: sw.active ? 1 : 0.4
    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: sw.checked ? Appearance.accent : Appearance.sel
        Rectangle {
            width: parent.height - 6
            height: width
            radius: width / 2
            y: 3
            x: sw.checked ? parent.width - width - 3 : 3
            color: sw.checked ? Appearance.inkOnAccent : Appearance.ink2
            Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        }
    }
    MouseArea {
        anchors.fill: parent
        enabled: sw.active
        cursorShape: Qt.PointingHandCursor
        onClicked: sw.toggled(!sw.checked)
    }
}
