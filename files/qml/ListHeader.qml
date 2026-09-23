import QtQuick
import Hyprshell

// The list view's column headings, which are also its sort control: click a
// column to sort by it, click it again to reverse. The arrow shows which
// way, the way every file list has done it since they existed.
//
// The column widths live here and FileRow reads them, so the two cannot
// drift apart into a header that does not line up with its rows.
Item {
    id: header

    required property var app

    // What each column is worth. Name takes whatever is left, which is why
    // it has no width of its own: widening Size narrows Name, and that is
    // what dragging the divider between them means.
    //
    // The concept's numbers are the defaults; they are settings now,
    // dragged by the grips between the headings and kept per window.
    readonly property real sizeWidth: FilesService.sizeWidth
    readonly property real typeWidth: FilesService.typeWidth
    readonly property real timeWidth: FilesService.timeWidth
    readonly property real gutter: 14

    // Enough to still read a heading, and not so much that Name vanishes.
    readonly property real minCol: 56
    readonly property real maxCol: 280

    implicitHeight: 32
    height: implicitHeight

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Appearance.rule
    }

    Row {
        anchors.right: parent.right
        anchors.rightMargin: header.gutter
        anchors.verticalCenter: parent.verticalCenter
        spacing: 0

        Repeater {
            model: [
                { key: "name",     label: "Name",     w: 0 },
                { key: "size",     label: "Size",     w: header.sizeWidth },
                { key: "type",     label: "Type",     w: header.typeWidth },
                { key: "modified", label: "Modified", w: header.timeWidth }
            ]

            // Name is drawn separately on the left; this row is the three
            // fixed columns on the right.
            Item {
                id: col
                required property var modelData
                visible: modelData.w > 0
                width: modelData.w
                height: header.height

                readonly property bool active: header.app.sortBy === col.modelData.key

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 2
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: col.modelData.label.toUpperCase()
                        font.pixelSize: Appearance.fs(10.5)
                        font.weight: Font.DemiBold
                        font.letterSpacing: 1.05
                        color: col.active ? Appearance.ink : Appearance.ink3
                    }

                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: col.active
                        name: header.app.sortReverse ? "chevronDown" : "chevronUp"
                        size: 15
                        inkColor: Appearance.accent
                        monochrome: true
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: header.sortByKey(col.modelData.key)
                }

                // The divider on this column's left edge, dragged to
                // resize it. Six pixels wide and reaching past the
                // heading's own click area, since a two-pixel target is
                // one nobody finds.
                Rectangle {
                    anchors.left: parent.left
                    anchors.leftMargin: -3
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 6
                    color: grip.containsMouse || grip.pressed
                           ? Appearance.accent : "transparent"
                    opacity: grip.pressed ? 1 : 0.5

                    MouseArea {
                        id: grip
                        anchors.fill: parent
                        anchors.margins: -2
                        hoverEnabled: true
                        cursorShape: Qt.SizeHorCursor
                        // No drag target: nothing moves but the column's
                        // width, which is tracked from the pointer here.
                        property real startX: 0
                        property real startW: 0
                        onPressed: mouse => {
                            grip.startX = mapToItem(header, mouse.x, 0).x;
                            grip.startW = col.modelData.w;
                        }
                        onPositionChanged: mouse => {
                            if (!pressed) return;
                            const now = mapToItem(header, mouse.x, 0).x;
                            // Dragging the grip left widens the column,
                            // because the columns are laid out from the
                            // right edge inwards.
                            header.setWidth(col.modelData.key,
                                            grip.startW - (now - grip.startX));
                        }
                    }
                }
            }
        }
    }

    // Name, on the left, where the rows put it.
    Row {
        anchors.left: parent.left
        anchors.leftMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        spacing: 3

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: "NAME"
            font.pixelSize: Appearance.fs(10.5)
            font.weight: Font.DemiBold
            font.letterSpacing: 1.05
            color: header.app.sortBy === "name" ? Appearance.ink : Appearance.ink3
        }

        MonoIcon {
            anchors.verticalCenter: parent.verticalCenter
            visible: header.app.sortBy === "name"
            name: header.app.sortReverse ? "chevronDown" : "chevronUp"
            size: 15
            inkColor: Appearance.accent
            monochrome: true
        }
    }

    MouseArea {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 140
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: header.sortByKey("name")
    }

    // Clicking the column you are already sorted by reverses it, which is
    // the behaviour everyone expects and nobody is told.
    function setWidth(key, w) {
        const v = Math.round(Math.max(header.minCol, Math.min(header.maxCol, w)));
        if (key === "size") FilesService.sizeWidth = v;
        else if (key === "type") FilesService.typeWidth = v;
        else if (key === "modified") FilesService.timeWidth = v;
    }

    function sortByKey(key) {
        if (FilesService.sortBy === key) FilesService.sortReverse = !FilesService.sortReverse;
        else { FilesService.sortBy = key; FilesService.sortReverse = false; }
    }
}
