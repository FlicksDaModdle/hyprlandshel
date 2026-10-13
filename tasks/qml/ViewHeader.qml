import QtQuick
import Hyprshell

// A view's title, with what it is, and room on the right for its tools.
//
// When the window is too narrow for both on one line, the tools move to a
// line of their own under the title rather than being drawn over it.
Item {
    id: head
    property string title: ""
    property string subtitle: ""
    default property alias tools: toolRow.data

    // The title's own width, from the texts (the column's width is set
    // from this, so it cannot be asked).
    readonly property real titleWidth: Math.max(titleText.implicitWidth, subText.visible ? subText.implicitWidth : 0)
    readonly property bool stacked: titleWidth + 24 + toolRow.implicitWidth > width
    implicitHeight: stacked ? titleCol.implicitHeight + 16 + toolRow.implicitHeight + 6 : 52

    Column {
        id: titleCol
        anchors.left: parent.left
        y: head.stacked ? 6 : Math.round((52 - implicitHeight) / 2)
        width: head.stacked ? parent.width : Math.min(head.titleWidth, parent.width - toolRow.implicitWidth - 24)
        spacing: 1
        StyledText {
            id: titleText
            width: parent.width
            text: head.title
            font.pixelSize: Appearance.fs(17)
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        StyledText {
            id: subText
            width: parent.width
            visible: text !== ""
            text: head.subtitle
            font.pixelSize: Appearance.fs(11.5)
            color: Appearance.ink3
            elide: Text.ElideRight
        }
    }
    Row {
        id: toolRow
        anchors.right: parent.right
        y: head.stacked ? titleCol.y + titleCol.implicitHeight + 10 : Math.round((52 - height) / 2)
        spacing: 6
    }
}
