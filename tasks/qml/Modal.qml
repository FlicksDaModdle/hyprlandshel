import QtQuick
import Hyprshell

// A dialog over the view: dims what is behind and holds the box centred.
// The box's contents go in `content`.
Item {
    id: modal
    property bool open: false
    property string title: ""
    property real boxWidth: 420
    default property alias content: inner.data
    visible: open
    z: 2000
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.35)
        MouseArea { anchors.fill: parent; onClicked: modal.open = false; onWheel: w => w.accepted = true }
    }
    PanelSurface {
        anchors.centerIn: parent
        showSeam: false
        color: Appearance.dialog
        width: modal.boxWidth
        height: titleText.height + inner.childrenRect.height + 50
        MouseArea { anchors.fill: parent }
        StyledText {
            id: titleText
            x: 18; y: 16
            text: modal.title
            font.pixelSize: Appearance.fs(14)
            font.weight: Font.DemiBold
        }
        Item {
            id: inner
            x: 18
            y: titleText.y + titleText.height + 14
            width: parent.width - 36
            height: childrenRect.height
        }
    }
}
