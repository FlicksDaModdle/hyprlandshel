import QtQuick
import Hyprshell

// One line of a key–value list: the key dim on the left, the value right.
Item {
    id: kv
    property string label: ""
    property string value: ""
    property real labelWidth: 150
    width: parent ? parent.width : 300
    implicitHeight: Math.max(22, valueText.implicitHeight + 4)
    StyledText {
        width: kv.labelWidth - 10
        elide: Text.ElideRight
        text: kv.label
        font.pixelSize: Appearance.fs(12)
        color: Appearance.ink3
    }
    StyledText {
        id: valueText
        x: kv.labelWidth
        width: kv.width - kv.labelWidth
        wrapMode: Text.WrapAnywhere
        text: kv.value === "" ? "—" : kv.value
        font.pixelSize: Appearance.fs(12)
    }
}
