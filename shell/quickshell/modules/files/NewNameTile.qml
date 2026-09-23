import QtQuick
import "../../config" as Config
import "../common"
import "../icons"

// The new folder, before it has a name. It sits in the view as a tile or a
// row like any other, with the name field already focused — so a folder is
// never created as "Untitled folder" and then renamed, which is two steps
// for something that should be one.
Item {
    id: pending

    required property var app
    // Which view it is sitting in; the two have different shapes.
    //
    // Not called `grid`: the grid itself is an id in FilesFrame, and a
    // property of that name shadows it inside this component's own
    // bindings — `width: grid.tileWidth` would read this boolean.
    property bool gridView: true

    implicitHeight: pending.gridView
                    ? Math.round(118 * Config.Appearance.filesIconSize / 100)
                    : 34
    height: implicitHeight

    Rectangle {
        anchors.fill: parent
        anchors.margins: pending.gridView ? 4 : 0
        anchors.bottomMargin: pending.gridView ? 4 : 1
        radius: Config.Appearance.rSm
        color: Config.Appearance.hover
    }

    // Grid: the plate, with the field under it.
    Rectangle {
        id: plate
        visible: pending.gridView
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Math.round(14 * Config.Appearance.filesIconSize / 100)
        width: Math.round(58 * Config.Appearance.filesIconSize / 100)
        height: Math.round(52 * Config.Appearance.filesIconSize / 100)
        radius: Config.Appearance.rSm
        color: Config.Appearance.surface

        MonoIcon {
            anchors.centerIn: parent
            name: "folder"
            size: Math.round(24 * Config.Appearance.filesIconSize / 100)
            inkColor: Config.Appearance.ink2
            accentColor: Config.Appearance.accent
        }
    }

    // List: the glyph on the left.
    MonoIcon {
        id: rowGlyph
        visible: !pending.gridView
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        name: "folder"
        size: 17
        inkColor: Config.Appearance.ink2
        accentColor: Config.Appearance.accent
    }

    NameField {
        anchors.top: pending.gridView ? plate.bottom : undefined
        anchors.topMargin: pending.gridView ? 6 : 0
        anchors.verticalCenter: pending.gridView ? undefined : parent.verticalCenter
        anchors.left: parent.left
        anchors.leftMargin: pending.gridView ? 6 : 38
        anchors.right: pending.gridView ? parent.right : undefined
        anchors.rightMargin: pending.gridView ? 6 : 0
        width: pending.gridView ? undefined : 260
        start: "New folder"
        active: pending.app.creatingFolder
        centred: pending.gridView
        onCommitted: name => pending.app.createFolder(name)
        onCancelled: pending.app.creatingFolder = false
    }
}
