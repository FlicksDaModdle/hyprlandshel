import QtQuick
import Hyprshell

// A view's title, with what it is, and room on the right for its tools.
Item {
    id: head
    property string title: ""
    property string subtitle: ""
    default property alias tools: toolRow.data
    implicitHeight: 52
    Column {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 1
        StyledText {
            text: head.title
            font.pixelSize: Appearance.fs(17)
            font.weight: Font.DemiBold
        }
        StyledText {
            visible: text !== ""
            text: head.subtitle
            font.pixelSize: Appearance.fs(11.5)
            color: Appearance.ink3
        }
    }
    Row {
        id: toolRow
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 6
    }
}
