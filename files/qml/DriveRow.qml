import QtQuick
import Hyprshell

// One drive in the sidebar's Drives: its name, a bar of how full it is, and
// what's free of how much. Lit like a place while you're on it; a click
// opens it. Turns accent past 90% full, where it starts to matter.
Item {
    id: row

    required property var drive
    required property var app

    readonly property real used: drive.size > 0 ? Math.max(0, Math.min(1, (drive.size - drive.avail) / drive.size)) : 0
    readonly property bool current: row.app.cwd === row.drive.path
    readonly property bool full: used > 0.9

    implicitHeight: 52
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        radius: Appearance.rSm
        color: row.current ? Appearance.sel : (area.containsMouse ? Appearance.hover : "transparent")
    }

    MonoIcon {
        id: glyph
        anchors.left: fill.left
        anchors.leftMargin: 10
        y: 9
        name: row.drive.removable ? "upload" : "disk"
        size: 20
        inkColor: row.current ? Appearance.accent : Appearance.ink2
        accentColor: Appearance.accent
    }

    StyledText {
        id: name
        anchors.left: glyph.right
        anchors.leftMargin: 10
        anchors.right: fill.right
        anchors.rightMargin: 10
        y: 9
        text: row.drive.label
        elide: Text.ElideRight
        font.pixelSize: Appearance.fs(12.5)
        font.weight: Font.Medium
        color: Appearance.ink
    }

    // How full it is.
    Rectangle {
        id: track
        anchors.left: name.left
        anchors.right: name.right
        anchors.top: name.bottom
        anchors.topMargin: 5
        height: 4
        radius: 2
        color: Appearance.rule
        Rectangle {
            width: Math.max(height, parent.width * row.used)
            height: parent.height
            radius: 2
            color: row.full ? Appearance.accent : Appearance.ink2
        }
    }

    StyledText {
        anchors.left: name.left
        anchors.right: name.right
        anchors.top: track.bottom
        anchors.topMargin: 3
        text: FilesService.humanSize(row.drive.avail) + " free of " + FilesService.humanSize(row.drive.size)
        elide: Text.ElideRight
        font.pixelSize: Appearance.fs(10.5)
        color: row.full ? Appearance.accent : Appearance.ink3
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: row.app.go(row.drive.path)
    }
}
