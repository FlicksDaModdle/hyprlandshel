import QtQuick
import Hyprshell

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
                    ? Math.round(118 * FilesService.iconSize / 100)
                    : 34
    height: implicitHeight

    Rectangle {
        anchors.fill: parent
        anchors.margins: pending.gridView ? 4 : 0
        anchors.bottomMargin: pending.gridView ? 4 : 1
        radius: Appearance.rSm
        color: Appearance.hover
    }

    // Grid: the plate, with the field under it.
    Rectangle {
        id: plate
        visible: pending.gridView
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Math.round(14 * FilesService.iconSize / 100)
        width: Math.round(58 * FilesService.iconSize / 100)
        height: Math.round(52 * FilesService.iconSize / 100)
        radius: Appearance.rSm
        color: Appearance.surface

        MonoIcon {
            anchors.centerIn: parent
            name: pending.app.creatingFile ? "file" : "folder"
            size: Math.round(24 * FilesService.iconSize / 100)
            inkColor: Appearance.ink2
            accentColor: Appearance.accent
        }
    }

    // List: the glyph on the left.
    MonoIcon {
        id: rowGlyph
        visible: !pending.gridView
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        name: pending.app.creatingFile ? "file" : "folder"
        size: 19
        inkColor: Appearance.ink2
        accentColor: Appearance.accent
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
        start: pending.app.creatingFile ? "New file.txt" : "New folder"
        active: pending.app.creatingSomething
        centred: pending.gridView
        onCommitted: name => pending.app.createNamed(name)
        onCancelled: {
            pending.app.creatingFolder = false;
            pending.app.creatingFile = false;
        }
    }
}
