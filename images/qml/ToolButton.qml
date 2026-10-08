import QtQuick
import Hyprshell

// A glyph in the title bar or on the filmstrip: lights up under the
// pointer, gives a little under a press.
Rectangle {
    id: btn
    property string icon: ""
    property bool danger: false
    property bool checked: false
    property string tip: ""
    property real glyph: 17
    property bool mirrored: false
    signal clicked

    width: 32; height: 32
    radius: Appearance.rSm
    opacity: enabled ? 1 : 0.4
    color: checked ? Appearance.sel
         : !area.containsMouse ? "transparent"
         : danger ? Appearance.accent : Appearance.hover
    scale: area.pressed ? 0.9 : 1
    Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 2 } }
    Behavior on color { ColorAnimation { duration: 110 } }

    MonoIcon {
        anchors.centerIn: parent
        name: btn.icon
        size: btn.glyph
        monochrome: true
        inkColor: area.containsMouse && btn.danger ? Appearance.inkOnAccent
                : btn.checked ? Appearance.accent : Appearance.ink2
        transform: Scale { origin.x: btn.glyph / 2; xScale: btn.mirrored ? -1 : 1 }
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
