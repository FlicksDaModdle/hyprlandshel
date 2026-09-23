import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// One file in the list view: glyph, name, size, and when it changed. The
// trash shows where a thing came from instead of its size, because that is
// the only question worth asking about something you have deleted.
Item {
    id: row

    required property var entry
    required property var app

    readonly property var svc: Services.Files
    readonly property bool selected: row.app.isSelected(row.entry.name)
    readonly property bool renaming: row.app.renaming === row.entry.name

    implicitHeight: 34
    height: implicitHeight

    Rectangle {
        id: fill
        anchors.fill: parent
        anchors.bottomMargin: 1
        radius: Config.Appearance.rSm
        color: row.selected ? Config.Appearance.sel
             : (area.containsMouse ? Config.Appearance.hover : "transparent")

        Rectangle {
            visible: row.selected
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

    MonoIcon {
        id: glyph
        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        name: row.svc.iconFor(row.entry)
        size: 17
        inkColor: Config.Appearance.ink2
        accentColor: Config.Appearance.accent
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
        font.pixelSize: Config.Appearance.fs(13)
        font.weight: row.selected ? Font.DemiBold : Font.Medium
        color: row.entry.broken ? Config.Appearance.ink3 : Config.Appearance.ink
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

    StyledText {
        id: sizeLabel
        anchors.right: timeLabel.left
        anchors.rightMargin: 16
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        width: row.app.inTrash ? 0 : 74
        visible: !row.app.inTrash
        text: row.entry.dir ? "--" : row.svc.humanSize(row.entry.size)
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }

    StyledText {
        id: timeLabel
        anchors.right: parent.right
        anchors.rightMargin: 14
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        width: row.app.inTrash ? 280 : 92
        elide: Text.ElideLeft
        text: row.app.inTrash
              ? (row.svc.trashOrigins[row.entry.name]
                 ? row.svc.pretty(row.svc.parent(row.svc.trashOrigins[row.entry.name]))
                 : "")
              : row.svc.humanTime(row.entry.mtime)
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }

    MouseArea {
        id: area
        anchors.fill: fill
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton
        onClicked: mouse => row.app.select(row.entry.name,
                                           (mouse.modifiers & Qt.ControlModifier) !== 0)
        onDoubleClicked: row.app.activate(row.entry)
    }
}
