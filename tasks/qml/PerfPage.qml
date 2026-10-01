import QtQuick
import Hyprshell

// The frame every device page shares: name and model across the top, then
// whatever the page puts in it, scrolled.
Item {
    id: page
    property string title: ""
    property string model: ""
    default property alias content: body.data
    SmoothScroll { target: flick; anchors.fill: flick; z: 5 }
    ScrollBar { target: flick; anchors.top: flick.top; anchors.bottom: flick.bottom; anchors.right: parent.right; z: 6 }
    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: head.height + body.childrenRect.height + 40
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        Item {
            id: head
            x: 24
            y: 14
            width: flick.width - 48
            height: 44
            StyledText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: page.title
                font.pixelSize: Appearance.fs(22)
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, parent.width * 0.6)
                horizontalAlignment: Text.AlignRight
                elide: Text.ElideMiddle
                text: page.model
                font.pixelSize: Appearance.fs(13)
                color: Appearance.ink2
            }
        }
        Column {
            id: body
            x: 24
            y: head.y + head.height + 8
            width: flick.width - 48
            spacing: 16
        }
    }
}
