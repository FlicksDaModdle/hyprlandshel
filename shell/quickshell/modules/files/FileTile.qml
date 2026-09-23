import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// One file in the grid: a rounded icon plate with the name under it.
// Selected is a quiet fill with an accent rule beneath, the same mark the
// sidebar and the design's own tiles use.
Item {
    id: tile

    required property var entry
    required property var app

    readonly property var svc: Services.Files
    readonly property bool selected: tile.app.isSelected(tile.entry.name)
    readonly property bool renaming: tile.app.renaming === tile.entry.name
    // Not `scale`: that is Item's own transform, and setting it would
    // literally shrink the tile rather than size its contents.
    readonly property real zoom: Config.Appearance.filesIconSize / 100

    implicitHeight: Math.round(118 * zoom)
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        anchors.margins: 4
        radius: Config.Appearance.rSm
        color: tile.selected ? Config.Appearance.sel
             : (area.containsMouse ? Config.Appearance.hover : "transparent")

        Rectangle {
            visible: tile.selected
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            height: 2
            radius: 1
            color: Config.Appearance.accent
        }
    }

    // The icon plate. An image shows itself; everything else gets its glyph.
    Rectangle {
        id: plate
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Math.round(14 * tile.zoom)
        width: Math.round(58 * tile.zoom)
        height: Math.round(52 * tile.zoom)
        radius: Config.Appearance.rSm
        color: Config.Appearance.surface
        clip: true

        MonoIcon {
            anchors.centerIn: parent
            visible: !preview.visible
            name: tile.svc.iconFor(tile.entry)
            size: Math.round(24 * tile.zoom)
            inkColor: Config.Appearance.ink2
            accentColor: Config.Appearance.accent
        }

        // Only images, and only at the size actually drawn — a directory of
        // camera files would otherwise decode tens of megapixels apiece to
        // fill a 58-pixel box.
        Image {
            id: preview
            anchors.fill: parent
            visible: status === Image.Ready
            source: tile.svc.canPreview(tile.entry)
                    ? "file://" + tile.svc.join(tile.app.cwd, tile.entry.name) : ""
            sourceSize.width: plate.width * 2
            sourceSize.height: plate.height * 2
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
        }
    }

    // The name, or the field that renames it.
    StyledText {
        id: label
        visible: !tile.renaming
        anchors.top: plate.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        text: tile.entry.name
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideMiddle
        maximumLineCount: 2
        wrapMode: Text.Wrap
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: tile.selected ? Font.DemiBold : Font.Medium
        color: tile.entry.broken ? Config.Appearance.ink3 : Config.Appearance.ink
    }

    NameField {
        visible: tile.renaming
        anchors.top: plate.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        start: tile.entry.name
        active: tile.renaming
        centred: true
        onCommitted: name => tile.app.renameTo(name)
        onCancelled: tile.app.renaming = ""
    }

    MouseArea {
        id: area
        anchors.fill: fill
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton
        onClicked: mouse => tile.app.select(tile.entry.name,
                                            (mouse.modifiers & Qt.ControlModifier) !== 0)
        onDoubleClicked: tile.app.activate(tile.entry)
    }
}
