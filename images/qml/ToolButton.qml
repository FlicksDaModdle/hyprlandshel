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
    color: tint1.value
    scale: scaleSpring.value
    Spring { id: scaleSpring; to: area.pressed ? 0.9 : 1; response: 260 }
    ColorSpring { id: tint1; to: btn.checked ? Appearance.sel
             : !area.containsMouse ? "transparent"
             : btn.danger ? Appearance.accent : Appearance.hover }

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
