import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

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
        !current && row.place.path !== Services.Files.home
        && row.app.cwd.indexOf(row.place.path + "/") === 0

    implicitHeight: 38
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        radius: Config.Appearance.rSm
        color: row.current ? Config.Appearance.sel
             : (area.containsMouse ? Config.Appearance.hover : "transparent")

        Rectangle {
            visible: row.current
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 2
            anchors.rightMargin: 2
            height: 2
            radius: 1
            color: Config.Appearance.accent
        }
    }

    MonoIcon {
        id: glyph
        anchors.left: fill.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        name: row.place.icon
        size: 17
        inkColor: row.current || row.inside ? Config.Appearance.ink : Config.Appearance.ink2
        accentColor: Config.Appearance.accent
    }

    StyledText {
        anchors.left: glyph.right
        anchors.leftMargin: 11
        anchors.right: countLabel.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: row.place.label
        elide: Text.ElideRight
        font.pixelSize: Config.Appearance.fs(13)
        font.weight: row.current ? Font.DemiBold : Font.Medium
        color: row.current ? Config.Appearance.ink : Config.Appearance.ink2
    }

    StyledText {
        id: countLabel
        anchors.right: fill.right
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        // Undefined until the count comes back, and an empty place shows
        // nothing rather than a nought.
        text: (row.count === undefined || row.count === 0) ? "" : String(row.count)
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }

    MouseArea {
        id: area
        anchors.fill: fill
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.app.go(row.place.path)
    }
}
