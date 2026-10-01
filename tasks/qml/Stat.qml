import QtQuick
import Hyprshell

// A label over a value, as the Performance pages list their figures.
Column {
    id: stat
    property string label: ""
    property string value: ""
    property bool big: false
    property color valueColor: Appearance.ink
    spacing: 1
    StyledText {
        text: stat.label
        font.pixelSize: Appearance.fs(11)
        color: Appearance.ink3
    }
    StyledText {
        text: stat.value
        font.pixelSize: Appearance.fs(stat.big ? 20 : 13)
        font.weight: stat.big ? Font.DemiBold : Font.Medium
        color: stat.valueColor
    }
}
