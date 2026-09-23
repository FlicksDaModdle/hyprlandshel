import QtQuick
import Hyprshell

// A footer button. Primary is the accent one you are expected to press.
Rectangle {
    id: btn

    property alias text: label.text
    property bool primary: false
    signal triggered()

    implicitWidth: Math.max(84, label.implicitWidth + 28)
    implicitHeight: 32
    radius: Appearance.rSm
    opacity: btn.enabled ? 1 : 0.45
    color: btn.primary
           ? (area.containsMouse ? Qt.lighter(Appearance.accent, 1.12) : Appearance.accent)
           : (area.containsMouse ? Appearance.sel : Appearance.hover)
    border.width: btn.primary ? 0 : 1
    border.color: Appearance.rule

    StyledText {
        id: label
        anchors.centerIn: parent
        font.pixelSize: Appearance.fs(12.5)
        font.weight: Font.DemiBold
        color: btn.primary ? Appearance.inkOnAccent : Appearance.ink
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: btn.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.triggered()
    }
}
