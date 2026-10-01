import QtQuick
import Hyprshell

// A level, 0 to 1: a track and a fill that glides to its value.
Rectangle {
    id: meter
    property real value: 0
    property color fillColor: Appearance.accent
    implicitHeight: 6
    radius: height / 2
    color: Appearance.sel
    clip: true
    Rectangle {
        height: parent.height
        radius: parent.radius
        width: parent.width * Math.max(0, Math.min(1, meter.value))
        color: meter.fillColor
        Behavior on width { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
    }
}
