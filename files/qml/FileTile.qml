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

    // 12 above the plate, 9 between plate and label, 11 below it — the
    // concept's own padding, scaled by the zoom.
    implicitHeight: Math.round((12 + 52 + 9 + 14 + 11) * zoom)
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        radius: Appearance.rSm
        color: tile.selected ? Appearance.sel
             : (area.containsMouse ? Appearance.hover : "transparent")

        // Inset from both edges and lifted off the bottom, so it marks the
        // tile rather than underlining it.
        Rectangle {
            visible: tile.selected
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

    // The icon plate. An image shows itself; everything else gets its glyph.
    Rectangle {
        id: plate
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Math.round(12 * tile.zoom)
        width: Math.round(52 * tile.zoom)
        height: Math.round(52 * tile.zoom)
        radius: Appearance.rSm
        // The plate follows the row rather than being a fixed surface: it
        // lifts with the selection, which is what gives a picked tile its
        // weight without a second colour.
        color: tile.selected ? Appearance.sel : Appearance.hover
        border.width: 1
        border.color: Appearance.rule
        clip: true

        MonoIcon {
            anchors.centerIn: parent
            visible: !preview.visible
            name: tile.svc.iconFor(tile.entry)
            size: Math.round(30 * tile.zoom)
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
        anchors.topMargin: Math.round(9 * tile.zoom)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        text: tile.entry.name
        horizontalAlignment: Text.AlignHCenter
        // One line, elided. Two wrapped lines made the tiles different
        // heights and the grid stopped reading as a grid.
        elide: Text.ElideMiddle
        maximumLineCount: 1
        font.pixelSize: Appearance.fs(11)
        font.weight: Font.Medium
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

    // The whole name. A tile is narrower than a row, so this earns its
    // keep here more than anywhere: most names of any length are elided.
    NameTip {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: label.bottom
        anchors.topMargin: 2
        label: label
        hovered: area.containsMouse && !tile.renaming
        text: tile.entry.name
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
            // The keyboard back to the window's shortcuts, from any field.
            tile.app.takeFocus();
            if (mouse.button !== Qt.LeftButton) return;

            // Only claim the item when no modifier is held. Selecting it
            // here unconditionally is what broke shift-clicking: the press
            // collapsed the selection to this one row and moved the anchor
            // onto it, so by the time the click arrived with Shift the
            // range it extended was from here to here. Ctrl was the same
            // story. With a modifier down, the press does nothing and the
            // click below decides.
            const plain = (mouse.modifiers
                           & (Qt.ShiftModifier | Qt.ControlModifier)) === 0;
            if (plain && !tile.app.isSelected(tile.entry.name))
                tile.app.select(tile.entry.name, false);

            dragProxy.x = mouse.x;
            dragProxy.y = mouse.y;
            dragProxy.Drag.mimeData = { "text/uri-list": tile.app.selectedUris() };

            // The picture is DragBadge's, not this delegate's. Grabbing the
            // delegate gave a neat square in the grid and a full-width
            // strip in the list, so the same gesture looked like two
            // different things.
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
        Drag.imageSource: tile.app.dragImage
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    }
}
