import QtQuick
import "../../config" as Config
import "../common"
import "../icons"

// A settings-style row in the capture panel: what it is on the left, its
// control on the right.
Item {
    id: optRow
    property string label: ""
    property string hint: ""
    default property alias control: slot.data
    width: parent ? parent.width : 0
    height: 44
    Column {
        anchors.left: parent.left
        anchors.leftMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        anchors.right: slot.left
        anchors.rightMargin: 10
        spacing: 1
        StyledText {
            text: optRow.label
            font.pixelSize: Config.Appearance.fs(13)
            color: Config.Appearance.ink
            elide: Text.ElideRight
            width: parent.width
        }
        StyledText {
            visible: optRow.hint !== ""
            text: optRow.hint
            font.pixelSize: Config.Appearance.fs(11)
            color: Config.Appearance.ink3
            elide: Text.ElideRight
            width: parent.width
        }
    }
    Item {
        id: slot
        anchors.right: parent.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        width: childrenRect.width
        height: childrenRect.height
    }
}
