import QtQuick
import Hyprshell

// One row in the places sidebar: glyph, label, and how many things are in
// it. Selected is a quiet fill with an accent rule under it, which is how
// the design marks the place you are in.
Item {
    id: row

    required property var place
    required property var app
    property var count: undefined

    readonly property bool current: row.app.cwd === row.place.path
    // A place is also "current" for anything inside it, but only the
    // deepest one should light up, or Home would be lit the whole time.
    readonly property bool inside:
        !current && row.place.path !== FilesService.home
        && row.app.cwd.indexOf(row.place.path + "/") === 0

    implicitHeight: 38
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        radius: Appearance.rSm
        color: row.current ? Appearance.sel
             : (area.containsMouse ? Appearance.hover : "transparent")

        Rectangle {
            visible: row.current
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 2
            anchors.rightMargin: 2
            height: 2
            radius: 1
            color: Appearance.accent
        }
    }

    MonoIcon {
        id: glyph
        anchors.left: fill.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        name: row.place.icon
        size: 17
        inkColor: row.current || row.inside ? Appearance.ink : Appearance.ink2
        accentColor: Appearance.accent
    }

    StyledText {
        anchors.left: glyph.right
        anchors.leftMargin: 11
        anchors.right: countLabel.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: row.place.label
        elide: Text.ElideRight
        font.pixelSize: Appearance.fs(13)
        font.weight: row.current ? Font.DemiBold : Font.Medium
        color: row.current ? Appearance.ink : Appearance.ink2
    }

    StyledText {
        id: countLabel
        anchors.right: fill.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        // Undefined until the count comes back, and an empty place shows
        // nothing rather than a nought.
        text: (row.count === undefined || row.count === 0) ? "" : String(row.count)
        font.pixelSize: Appearance.fs(12)
        color: Appearance.ink3
    }

    MouseArea {
        id: area
        anchors.fill: fill
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.app.go(row.place.path)
    }
}
