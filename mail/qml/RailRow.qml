import QtQuick
import Hyprshell

// One entry in the rail: a glyph, a name, a count, and the rail mark when
// it is the one showing. A drop target too: messages dragged onto a folder
// move there.
Item {
    id: row
    property string icon: ""
    property string label: ""
    property string count: ""
    property bool current: false
    property bool bold: false
    property int indent: 0
    property color dot: "transparent"
    property bool warn: false
    property bool dropTarget: false
    signal picked()
    signal menu(real x, real y)
    signal dropped(var ids)
    implicitHeight: 32
    height: implicitHeight

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        radius: Appearance.rSm
        color: drop.containsDrag ? Appearance.sel : row.current ? Appearance.sel : area.containsMouse ? Appearance.hover : "transparent"
        border.width: drop.containsDrag ? 1 : 0
        border.color: Appearance.accent
        Rectangle {
            visible: row.current
            anchors.left: parent.left
            anchors.leftMargin: 3
            anchors.verticalCenter: parent.verticalCenter
            width: 3
            height: 16
            radius: 2
            color: Appearance.accent
        }
    }
    MonoIcon {
        id: glyph
        x: 22 + row.indent * 14
        anchors.verticalCenter: parent.verticalCenter
        name: row.icon
        visible: row.icon !== ""
        size: 18
        inkColor: row.current ? Appearance.accent : Appearance.ink2
        accentColor: Appearance.accent
    }
    Rectangle {
        visible: row.icon === ""
        x: 27 + row.indent * 14
        anchors.verticalCenter: parent.verticalCenter
        width: 8; height: 8; radius: 4
        color: row.dot
    }
    StyledText {
        anchors.left: parent.left
        anchors.leftMargin: 22 + row.indent * 14 + 29
        anchors.right: countText.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: row.label
        font.pixelSize: Appearance.fs(12.5)
        font.weight: row.bold ? Font.DemiBold : Font.Medium
        color: Appearance.ink
    }
    MonoIcon {
        visible: row.warn
        anchors.right: countText.left
        anchors.rightMargin: 4
        anchors.verticalCenter: parent.verticalCenter
        name: "alert"
        size: 14
        inkColor: Appearance.accent
        accentColor: Appearance.accent
    }
    StyledText {
        id: countText
        anchors.right: parent.right
        anchors.rightMargin: 18
        anchors.verticalCenter: parent.verticalCenter
        text: row.count
        font.pixelSize: Appearance.fs(11.5)
        font.weight: Font.DemiBold
        color: row.current ? Appearance.accent : Appearance.ink2
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: m => {
            if (m.button === Qt.RightButton) { const p = mapToItem(null, m.x, m.y); row.menu(p.x, p.y); }
            else row.picked();
        }
    }
    DropArea {
        id: drop
        anchors.fill: parent
        enabled: row.dropTarget
        keys: ["hyprshell-mail-ids"]
        onDropped: d => { row.dropped(d.source ? d.source.dragIds : []); d.accept(); }
    }
}
