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

    // 6px of padding above and below a 34px plate.
    implicitHeight: 46
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        color: row.selected ? Appearance.sel
             : (area.containsMouse ? Appearance.hover : "transparent")

        // A hairline under every row, not only the selected one: the
        // concept rules the list, and the selection is carried by the fill
        // alone. A rail here as well would have been two marks for one
        // thing.
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Appearance.rule
        }
    }

    // The same plate the grid gives a file, at row size — which is what
    // stops the two views looking like different applications.
    Rectangle {
        id: plate
        anchors.left: parent.left
        anchors.leftMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        width: 34
        height: 34
        radius: Appearance.rSm
        color: row.selected ? Appearance.sel : Appearance.hover
        border.width: 1
        border.color: Appearance.rule

        MonoIcon {
            anchors.centerIn: parent
            name: row.svc.iconFor(row.entry)
            size: 22
            inkColor: Appearance.ink2
            accentColor: Appearance.accent
        }
    }

    StyledText {
        id: name
        visible: !row.renaming
        anchors.left: plate.right
        anchors.leftMargin: 11
        anchors.right: sizeLabel.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        text: row.entry.name
        elide: Text.ElideMiddle
        font.pixelSize: Appearance.fs(12)
        font.weight: Font.Medium
        color: row.entry.broken ? Appearance.ink3 : Appearance.ink
    }

    // The whole name, when the column was too narrow for it. Anchored to
    // the label so it sits under the thing it explains.
    NameTip {
        anchors.left: name.left
        anchors.top: name.bottom
        anchors.topMargin: 2
        label: name
        hovered: area.containsMouse && !row.renaming
        text: row.entry.name
    }

    NameField {
        visible: row.renaming
        anchors.left: plate.right
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
        // A gap that is always there, so a long type label elides against
        // air rather than running into the size — "0 BComma-separated v…"
        // was one string as far as the eye was concerned.
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        width: row.app.inTrash ? 0 : row.sizeWidth
        visible: !row.app.inTrash
        text: row.entry.dir ? "—" : row.svc.humanSize(row.entry.size)
        font.pixelSize: Appearance.fs(11)
        font.weight: Font.Normal
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
        font.pixelSize: Appearance.fs(11)
        font.weight: Font.Normal
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
        font.pixelSize: Appearance.fs(11)
        font.weight: Font.Normal
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
            // The keyboard back to the window's shortcuts, from any field.
            row.app.takeFocus();
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
            if (plain && !row.app.isSelected(row.entry.name))
                row.app.select(row.entry.name, false);

            dragProxy.x = mouse.x;
            dragProxy.y = mouse.y;
            dragProxy.Drag.mimeData = { "text/uri-list": row.app.selectedUris() };

            // The picture is DragBadge's, not this delegate's. Grabbing the
            // delegate gave a neat square in the grid and a full-width
            // strip in the list, so the same gesture looked like two
            // different things.
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
        Drag.imageSource: row.app.dragImage
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction
    }
}
