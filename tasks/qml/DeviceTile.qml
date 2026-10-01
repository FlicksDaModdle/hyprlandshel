import QtQuick
import Hyprshell
import Hyprshell.Backend

// One device on the Summary: what it is, its headline figure, a line or two
// under it, and its graph. Opens its Performance page.
Card {
    id: tile
    property string icon: ""
    property string title: ""
    property string value: ""
    property string detail: ""
    property string detail2: ""
    property string series: ""
    property string series2: ""
    property real maxValue: 100
    property real minScale: 1
    property string device: ""
    property int level: 0           // 2 red, 1 amber-ish, 0 normal

    implicitHeight: 152
    color: area.containsMouse ? Appearance.sel : Appearance.hover
    border.color: tile.level >= 2 ? Appearance.accent : Appearance.rule

    Row {
        x: 14; y: 12
        spacing: 8
        MonoIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: tile.icon
            size: 17
            inkColor: Appearance.ink2
            accentColor: Appearance.accent
        }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            text: tile.title
            font.pixelSize: Appearance.fs(12)
            font.weight: Font.DemiBold
            color: Appearance.ink2
            width: Math.min(implicitWidth, tile.width - 60)
            elide: Text.ElideRight
        }
    }
    StyledText {
        x: 14; y: 36
        text: tile.value
        font.pixelSize: Appearance.fs(22)
        font.weight: Font.DemiBold
        color: tile.level >= 2 ? Appearance.accent : Appearance.ink
    }
    Column {
        x: 14; y: 68
        width: tile.width - 28
        StyledText { width: parent.width; elide: Text.ElideRight; text: tile.detail; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3 }
        StyledText { width: parent.width; elide: Text.ElideRight; text: tile.detail2; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3; visible: text !== "" }
    }
    Graph {
        visible: tile.series !== ""
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 1
        height: 44
        source: Monitor
        series: tile.series
        series2: tile.series2
        maxValue: tile.maxValue
        minScale: tile.minScale
        grid: false
        animate: Tasks.settings.smooth
        points: Tasks.points
        lineWidth: 1.3
        color: Appearance.accent
        color2: Appearance.ink3
    }
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { Tasks.perfDevice = tile.device; Tasks.view = tile.device === "battery" || tile.device.indexOf("temp") === 0 ? (tile.device === "battery" ? "performance" : "power") : "performance"; }
    }
}
