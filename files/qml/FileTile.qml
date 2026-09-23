import QtQuick
import Hyprshell

// One file in the grid: a rounded icon plate with the name under it.
// Selected is a quiet fill with an accent rule beneath, the same mark the
// sidebar and the design's own tiles use.
Item {
    id: tile

    required property var entry
    required property var app

    readonly property var svc: FilesService
    // Whether this tile is anywhere near the visible part of the view. A
    // folder of screenshots would otherwise decode every image in it the
    // moment you opened the folder — hundreds of full-resolution PNGs, for
    // the sake of the six thumbnails actually on screen.
    property bool inView: true
    readonly property bool selected: tile.app.isSelected(tile.entry.name)
    readonly property bool renaming: tile.app.renaming === tile.entry.name
    // Not `scale`: that is Item's own transform, and setting it would
    // literally shrink the tile rather than size its contents.
    readonly property real zoom: FilesService.iconSize / 100

    implicitHeight: Math.round(118 * zoom)
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        anchors.margins: 4
        radius: Appearance.rSm
        color: tile.selected ? Appearance.sel
             : (area.containsMouse ? Appearance.hover : "transparent")

        Rectangle {
            visible: tile.selected
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            height: 2
            radius: 1
            color: Appearance.accent
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
        radius: Appearance.rSm
        color: Appearance.surface
        clip: true

        MonoIcon {
            anchors.centerIn: parent
            visible: !preview.visible
            name: tile.svc.iconFor(tile.entry)
            size: Math.round(24 * tile.zoom)
            inkColor: Appearance.ink2
            accentColor: Appearance.accent
        }

        // Only images, only while on screen, and only at the size actually
        // drawn — a directory of camera files would otherwise decode tens of
        // megapixels apiece to fill a 58-pixel box.
        //
        // encodeURIComponent on each segment, not on the whole path: a file
        // called "a#b.png" or "100% done.png" is a perfectly legal name and
        // an entirely different URL, and Qt reads the '#' as a fragment.
        Image {
            id: preview
            anchors.fill: parent
            visible: status === Image.Ready
            source: (tile.inView && tile.svc.canPreview(tile.entry))
                    ? tile.svc.fileUrl(tile.svc.join(tile.app.cwd, tile.entry.name))
                    : ""
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
        font.pixelSize: Appearance.fs(12)
        font.weight: tile.selected ? Font.DemiBold : Font.Medium
        color: tile.entry.broken ? Appearance.ink3 : Appearance.ink
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

    // Dropping onto a folder moves into it, which is the one gesture a file
    // manager is expected to have. The tile reports the hover so it can
    // light up; the frame does the moving, because it knows the paths.
    signal dropRequested(string targetDir)
    property bool dropTarget: false

    DropArea {
        anchors.fill: fill
        enabled: tile.entry.dir
        keys: ["text/uri-list"]
        onEntered: tile.dropTarget = true
        onExited: tile.dropTarget = false
        onDropped: drop => {
            tile.dropTarget = false;
            tile.app.dropOnto(drop, tile.svc.join(tile.app.cwd, tile.entry.name));
        }
    }

    Rectangle {
        visible: tile.dropTarget
        anchors.fill: fill
        radius: Appearance.rSm
        color: "transparent"
        border.width: 2
        border.color: Appearance.accent
    }

    MouseArea {
        id: area
        anchors.fill: fill
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        // Dragging out carries the selection as text/uri-list, which is what
        // every other application expects a dragged file to be.
        drag.target: dragProxy
        onPressed: mouse => {
            if (mouse.button !== Qt.LeftButton) return;
            if (!tile.app.isSelected(tile.entry.name))
                tile.app.select(tile.entry.name, false);
            dragProxy.x = mouse.x;
            dragProxy.y = mouse.y;
            dragProxy.Drag.mimeData = { "text/uri-list": tile.app.selectedUris() };

            // What the cursor carries. Without an imageSource a drag has no
            // picture at all — the file moves, but you are dragging nothing
            // you can see. Grabbed on press rather than kept around,
            // because a live grab per tile would cost one render target per
            // file in the folder.
            //
            // The grab is asynchronous and the drag does not begin until
            // the pointer has moved its threshold, which is the slack this
            // relies on; if the image is late the drag still works, it is
            // just briefly invisible.
            tile.grabToImage(function (result) {
                dragProxy.Drag.imageSource = result.url;
            });
        }
        onReleased: dragProxy.Drag.drop()

        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
                const p = mapToItem(tile.app.menuLayer, mouse.x, mouse.y);
                tile.app.openMenu(p.x, p.y, tile.entry);
                return;
            }
            tile.app.clickSelect(tile.entry.name, mouse.modifiers);
        }
        onDoubleClicked: mouse => {
            if (mouse.button === Qt.LeftButton) tile.app.activate(tile.entry);
        }
    }

    // What is actually dragged. Invisible and zero-sized: the point is the
    // mime data, not a picture of it.
    Item {
        id: dragProxy
        Drag.active: area.drag.active
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    }
}
