import QtQuick
import Hyprshell

// One entry in the side rail: a glyph, a name, and the rail mark when it is
// the view showing — the same row the file manager's places use.
Item {
    id: row
    property string icon: ""
    property string label: ""
    property string viewId: ""
    property bool collapsed: false
    property string badge: ""
    readonly property bool current: Tasks.view === row.viewId
    signal picked()
    implicitHeight: 34
    height: implicitHeight
    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        radius: Appearance.rSm
        color: row.current ? Appearance.sel : area.containsMouse ? Appearance.hover : "transparent"
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
        x: row.collapsed ? (row.width - width) / 2 : 22
        anchors.verticalCenter: parent.verticalCenter
        name: row.icon
        size: 19
        inkColor: row.current ? Appearance.accent : Appearance.ink2
        accentColor: Appearance.accent
    }
    StyledText {
        visible: !row.collapsed
        anchors.left: glyph.right
        anchors.leftMargin: 11
        anchors.right: badgeText.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: row.label
        font.pixelSize: Appearance.fs(12.5)
        font.weight: Font.Medium
    }
    StyledText {
        id: badgeText
        visible: !row.collapsed && row.badge !== ""
        anchors.right: parent.right
        anchors.rightMargin: 18
        anchors.verticalCenter: parent.verticalCenter
        text: row.badge
        font.pixelSize: Appearance.fs(11)
        font.weight: Font.DemiBold
        color: Appearance.accent
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.picked()
    }
}
