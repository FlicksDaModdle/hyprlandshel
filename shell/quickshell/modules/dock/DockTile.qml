import QtQuick
import "../icons"
import "../../config" as Config

// One dock tile: pinned app, unpinned-but-running app, or a plain utility
// button (Start, task view, Settings, show desktop) depending on which
// properties the caller sets. Mirrors the mockup's dockTile() output.
Item {
    id: root

    property string label: ""
    property string iconName: ""
    property string subtitle: ""
    property bool running: false
    property bool active: false
    property bool showLabel: false
    property bool showTooltip: true
    property bool showPips: true
    property int windowCount: 0
    property real tileSize: 42
    property real iconSize: 21
    // Source design never dims dock icons — active/hover only change the
    // tile's background and the running-window pips, not the glyph color.
    property color iconInk: Config.Appearance.ink

    signal activated()

    readonly property bool hovered: hoverHandler.hovered

    implicitWidth: showLabel ? Math.round(tileSize + labelText.implicitWidth + 21) : tileSize
    implicitHeight: tileSize

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rTile
        color: root.active ? Config.Appearance.sel : (root.hovered ? Config.Appearance.hover : "transparent")
        border.width: root.active ? 1 : 0
        border.color: Config.Appearance.seam
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    Row {
        anchors.centerIn: parent
        spacing: 9

        MonoIcon {
            name: root.iconName
            size: root.iconSize
            inkColor: root.iconInk
            accentColor: Config.Appearance.accent
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            id: labelText
            visible: root.showLabel
            text: root.label
            color: Config.Appearance.ink
            font.pixelSize: 12
            font.weight: Font.DemiBold
            font.family: "Inter"
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 3
        spacing: 2
        visible: root.showPips && root.running

        Repeater {
            model: Math.min(root.windowCount, 3)
            Rectangle {
                required property int index
                width: root.active && index === 0 ? 14 : 6
                height: 2.5
                radius: 1.25
                color: root.active ? Config.Appearance.accent : Config.Appearance.ink3
                Behavior on width { NumberAnimation { duration: 120 } }
            }
        }
    }

    Rectangle {
        id: tooltip
        z: 5
        visible: root.showTooltip && root.hovered && !root.showLabel
        opacity: visible ? 1 : 0
        anchors.bottom: parent.top
        anchors.bottomMargin: 12
        anchors.horizontalCenter: parent.horizontalCenter
        radius: Config.Appearance.rSm
        color: Config.Appearance.sheet
        border.width: 1
        border.color: Config.Appearance.edge
        height: 30
        width: tooltipRow.implicitWidth + 22

        Row {
            id: tooltipRow
            anchors.centerIn: parent
            spacing: 9
            Text { text: root.label; color: Config.Appearance.ink; font.pixelSize: 11; font.weight: Font.DemiBold; font.family: "Inter" }
            Text {
                text: root.subtitle
                visible: root.subtitle !== ""
                color: Config.Appearance.ink3
                font.pixelSize: 10
                font.weight: Font.Medium
                font.family: "Inter"
            }
        }
    }

    HoverHandler {
        id: hoverHandler
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        onTapped: root.activated()
    }
}
