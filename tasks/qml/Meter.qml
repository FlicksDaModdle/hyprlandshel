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
        width: parent.width * Math.max(0, fill.value)
        color: meter.fillColor
        Spring { id: fill; to: Math.max(0, Math.min(1, meter.value)); response: 400; bounce: 0 }
    }
}
