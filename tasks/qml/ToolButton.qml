import QtQuick
import Hyprshell

// A flat toolbar button: a glyph and, optionally, a label.
Rectangle {
    id: btn
    property string icon: ""
    property string text: ""
    property bool active: true
    property bool checked: false
    property bool danger: false
    signal clicked()
    implicitWidth: row.implicitWidth + (btn.text === "" ? 14 : 22)
    implicitHeight: 32
    radius: Appearance.rSm
    opacity: btn.active ? 1 : 0.4
    color: btn.checked ? Appearance.sel
         : area.containsMouse && btn.active ? (btn.danger ? Appearance.accent : Appearance.hover) : "transparent"
    readonly property bool lit: area.containsMouse && btn.active && btn.danger
    Row {
        id: row
        anchors.centerIn: parent
        spacing: 7
        MonoIcon {
            visible: btn.icon !== ""
            anchors.verticalCenter: parent.verticalCenter
            name: btn.icon
            size: 17
            inkColor: btn.lit ? Appearance.inkOnAccent : Appearance.ink
            accentColor: btn.lit ? Appearance.inkOnAccent : Appearance.accent
        }
        StyledText {
            visible: btn.text !== ""
            anchors.verticalCenter: parent.verticalCenter
            text: btn.text
            font.pixelSize: Appearance.fs(12)
            font.weight: Font.Medium
            color: btn.lit ? Appearance.inkOnAccent : Appearance.ink
        }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: btn.active
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
