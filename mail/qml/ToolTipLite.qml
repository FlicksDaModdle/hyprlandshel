import QtQuick
import Hyprshell

// A small label above its parent while `shown`.
PanelSurface {
    id: tip
    property string text: ""
    property bool shown: false
    showSeam: false
    color: Appearance.dialog
    visible: shown && text !== ""
    z: 200
    width: t.implicitWidth + 16
    height: 24
    x: (parent ? parent.width - width : 0) / 2
    y: -height - 4
    StyledText { id: t; anchors.centerIn: parent; text: tip.text; font.pixelSize: Appearance.fs(11.5) }
}
