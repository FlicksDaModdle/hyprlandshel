import QtQuick
import Hyprshell

// One row in the places sidebar.
//
// The measurements are the concept's: 8×10 padding, a 10px gap, a 15px
// glyph that turns accent when this is where you are, a 12.5px label and a
// small bold tabular count. The mark for "you are here" is a rule inset
// 10px from each side, sitting 3px off the bottom — not a full-width
// underline, which is what this had and which read as a divider.
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

    implicitHeight: 31
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        radius: Appearance.rSm
        color: row.current ? Appearance.sel
             : (area.containsMouse ? Appearance.hover : "transparent")

        // The rail. Inset from both edges and lifted off the bottom, so it
        // reads as a mark on this row rather than a line between rows.
        Rectangle {
            visible: row.current
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 3
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            height: 2
            radius: 2
            color: Appearance.accent
        }
    }

    MonoIcon {
        id: glyph
        anchors.left: fill.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        name: row.place.icon
        size: 15
        // Accent, not just brighter ink: the colour is how the concept says
        // "this one", and the rail underneath agrees with it.
        inkColor: row.current ? Appearance.accent
                : (row.inside ? Appearance.ink : Appearance.ink2)
        accentColor: row.current ? Appearance.accent : Appearance.accent
    }

    StyledText {
        anchors.left: glyph.right
        anchors.leftMargin: 10
        anchors.right: countLabel.left
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: row.place.label
        elide: Text.ElideRight
        font.pixelSize: Appearance.fs(12.5)
        font.weight: Font.Medium
        color: Appearance.ink
    }

    StyledText {
        id: countLabel
        anchors.right: fill.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        // Undefined until the count comes back, and an empty place shows
        // nothing rather than a nought.
        visible: !removeBtn.visible
        text: (row.count === undefined || row.count === 0) ? "" : String(row.count)
        font.pixelSize: Appearance.fs(10.5)
        font.weight: Font.DemiBold
        color: Appearance.ink3
    }

    // Taking a bookmark out again, from the row itself. Only on bookmarks:
    // the standard places are not yours to remove, and a cross on Home
    // would be a trap.
    Rectangle {
        id: removeBtn
        visible: row.place.removable === true && (area.containsMouse || removeArea.containsMouse)
        anchors.right: fill.right
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        width: 19
        height: 19
        radius: Appearance.rSm
        color: removeArea.containsMouse ? Appearance.accent : Appearance.sel

        MonoIcon {
            anchors.centerIn: parent
            name: "x"
            size: 11
            inkColor: removeArea.containsMouse ? Appearance.onAccent : Appearance.ink2
            monochrome: true
        }

        MouseArea {
            id: removeArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: FilesService.toggleBookmark(row.place.path)
        }
    }

    MouseArea {
        id: area
        anchors.fill: fill
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.app.go(row.place.path)
    }

    // A folder dropped on a place goes into it, the same as dropping on a
    // folder in the view.
    DropArea {
        anchors.fill: fill
        keys: ["text/uri-list"]
        onEntered: dropRing.visible = true
        onExited: dropRing.visible = false
        onDropped: drop => {
            dropRing.visible = false;
            row.app.dropOnto(drop, row.place.path);
        }
    }

    Rectangle {
        id: dropRing
        visible: false
        anchors.fill: fill
        radius: Appearance.rSm
        color: "transparent"
        border.width: 2
        border.color: Appearance.accent
    }
}
