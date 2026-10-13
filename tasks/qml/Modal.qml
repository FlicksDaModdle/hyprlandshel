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
    visible: open || modalFade.value > 0.004
    enabled: open
    z: 2000
    Spring { id: modalFade; to: modal.open ? 1 : 0; response: modal.open ? 180 : 170; bounce: 0 }
    Spring { id: modalGrow; to: modal.open ? 1 : 0.92; response: modal.open ? 360 : 200; bounce: modal.open ? 1 : 0 }
    Rectangle {
        anchors.fill: parent
        opacity: Math.max(0, Math.min(1, modalFade.value))
        color: Qt.rgba(0, 0, 0, 0.35)
        MouseArea { anchors.fill: parent; onClicked: modal.open = false; onWheel: w => w.accepted = true }
    }
    PanelSurface {
        anchors.centerIn: parent
        opacity: Math.max(0, Math.min(1, modalFade.value))
        scale: modalGrow.value
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
