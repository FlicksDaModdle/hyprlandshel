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

    // What each column is worth. Name takes whatever is left.
    // The concept's own column widths, and a Type column beside them.
    readonly property real sizeWidth: 96
    readonly property real typeWidth: 116
    readonly property real timeWidth: 104
    readonly property real gutter: 14

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
                        size: 13
                        inkColor: Appearance.accent
                        monochrome: true
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: header.sortByKey(col.modelData.key)
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
            size: 13
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
    function sortByKey(key) {
        if (FilesService.sortBy === key) FilesService.sortReverse = !FilesService.sortReverse;
        else { FilesService.sortBy = key; FilesService.sortReverse = false; }
    }
}
