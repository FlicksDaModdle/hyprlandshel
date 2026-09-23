import QtQuick
import Hyprshell

// One file in the list view: glyph, name, size, and when it changed. The
// trash shows where a thing came from instead of its size, because that is
// the only question worth asking about something you have deleted.
Item {
    id: row

    required property var entry
    required property var app

    readonly property var svc: FilesService
    readonly property bool selected: row.app.isSelected(row.entry.name)
    readonly property bool renaming: row.app.renaming === row.entry.name

    implicitHeight: 34
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        anchors.bottomMargin: 1
        radius: Appearance.rSm
        color: row.selected ? Appearance.sel
             : (area.containsMouse ? Appearance.hover : "transparent")

        Rectangle {
            visible: row.selected
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

    MonoIcon {
        id: glyph
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        name: row.svc.iconFor(row.entry)
        size: 17
        inkColor: Appearance.ink2
        accentColor: Appearance.accent
    }

    StyledText {
        id: name
        visible: !row.renaming
        anchors.left: glyph.right
        anchors.leftMargin: 11
        anchors.right: sizeLabel.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: row.entry.name
        elide: Text.ElideMiddle
        font.pixelSize: Appearance.fs(13)
        font.weight: row.selected ? Font.DemiBold : Font.Medium
        color: row.entry.broken ? Appearance.ink3 : Appearance.ink
    }

    NameField {
        visible: row.renaming
        anchors.left: glyph.right
        anchors.leftMargin: 9
        anchors.verticalCenter: parent.verticalCenter
        width: 260
        start: row.entry.name
        active: row.renaming
        onCommitted: n => row.app.renameTo(n)
        onCancelled: row.app.renaming = ""
    }

    // The column widths come from the header, so the two cannot drift into
    // a heading that sits over the wrong column.
    property real sizeWidth: 88
    property real typeWidth: 124
    property real timeWidth: 104

    StyledText {
        id: sizeLabel
        anchors.right: typeLabel.left
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        width: row.app.inTrash ? 0 : row.sizeWidth
        visible: !row.app.inTrash
        text: row.entry.dir ? "--" : row.svc.humanSize(row.entry.size)
        font.pixelSize: Appearance.fs(12)
        color: Appearance.ink3
    }

    StyledText {
        id: typeLabel
        anchors.right: timeLabel.left
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        width: row.app.inTrash ? 0 : row.typeWidth
        visible: !row.app.inTrash
        elide: Text.ElideRight
        text: row.svc.typeLabel(row.entry)
        font.pixelSize: Appearance.fs(12)
        color: Appearance.ink3
    }

    StyledText {
        id: timeLabel
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        width: row.app.inTrash ? 280 : row.timeWidth
        elide: Text.ElideLeft
        // In the trash, where a thing came from is the only question worth
        // asking about it, so that replaces the three columns.
        text: row.app.inTrash
              ? (row.svc.trashOrigins[row.entry.name]
                 ? row.svc.pretty(row.svc.parent(row.svc.trashOrigins[row.entry.name]))
                 : "")
              : row.svc.humanTime(row.entry.mtime)
        font.pixelSize: Appearance.fs(12)
        color: Appearance.ink3
    }

    property bool dropTarget: false

    DropArea {
        anchors.fill: fill
        enabled: row.entry.dir
        keys: ["text/uri-list"]
        onEntered: row.dropTarget = true
        onExited: row.dropTarget = false
        onDropped: drop => {
            row.dropTarget = false;
            row.app.dropOnto(drop, row.svc.join(row.app.cwd, row.entry.name));
        }
    }

    Rectangle {
        visible: row.dropTarget
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

        drag.target: dragProxy
        onPressed: mouse => {
            if (mouse.button !== Qt.LeftButton) return;
            if (!row.app.isSelected(row.entry.name))
                row.app.select(row.entry.name, false);
            dragProxy.x = mouse.x;
            dragProxy.y = mouse.y;
            dragProxy.Drag.mimeData = { "text/uri-list": row.app.selectedUris() };

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
            row.grabToImage(function (result) {
                dragProxy.Drag.imageSource = result.url;
            });
        }
        onReleased: dragProxy.Drag.drop()

        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
                const p = mapToItem(row.app.menuLayer, mouse.x, mouse.y);
                row.app.openMenu(p.x, p.y, row.entry);
                return;
            }
            row.app.clickSelect(row.entry.name, mouse.modifiers);
        }
        onDoubleClicked: mouse => {
            if (mouse.button === Qt.LeftButton) row.app.activate(row.entry);
        }
    }

    Item {
        id: dragProxy
        Drag.active: area.drag.active
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    }
}
