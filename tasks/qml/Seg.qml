import QtQuick
import Hyprshell

// A segmented choice: [{ label, value }].
Rectangle {
    id: seg
    property var options: []
    property var value
    signal picked(var value)
    implicitWidth: row.implicitWidth + 6
    implicitHeight: 30
    radius: Appearance.rSm
    color: Appearance.hover
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 2
        Repeater {
            model: seg.options
            Rectangle {
                required property var modelData
                readonly property bool on: modelData.value === seg.value
                width: label.implicitWidth + 22
                height: 24
                radius: Appearance.rSm - 2
                color: on ? Appearance.accent : area.containsMouse ? Appearance.hover : "transparent"
                StyledText {
                    id: label
                    anchors.centerIn: parent
                    text: modelData.label
                    font.pixelSize: Appearance.fs(12)
                    font.weight: Font.Medium
                    color: parent.on ? Appearance.inkOnAccent : Appearance.ink2
                }
                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.picked(modelData.value)
                }
            }
        }
    }
}
