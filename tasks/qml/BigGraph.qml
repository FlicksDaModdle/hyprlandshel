import QtQuick
import Hyprshell
import Hyprshell.Backend

// A device's main graph: framed, with what it measures, its scale and its
// time span written round it, as the Performance pages show them.
Item {
    id: big
    property string caption: ""
    property string series: ""
    property string series2: ""
    property real maxValue: 100
    property real minScale: 1
    property var format: v => Math.round(v) + "%"
    property bool legend: false
    property string legend1: ""
    property string legend2: ""
    implicitHeight: 220

    StyledText {
        id: cap
        text: big.caption
        font.pixelSize: Appearance.fs(11)
        color: Appearance.ink3
    }
    StyledText {
        anchors.right: parent.right
        text: big.format(g.scaleMax)
        font.pixelSize: Appearance.fs(11)
        color: Appearance.ink3
    }
    Rectangle {
        id: frameRect
        anchors.top: cap.bottom
        anchors.topMargin: 4
        anchors.bottom: foot.top
        anchors.bottomMargin: 4
        width: parent.width
        color: "transparent"
        border.width: 1
        border.color: Appearance.edge
        radius: 4
        Graph {
            id: g
            anchors.fill: parent
            anchors.margins: 1
            source: Monitor
            series: big.series
            series2: big.series2
            maxValue: big.maxValue
            minScale: big.minScale
            points: Tasks.points
            animate: Tasks.smoothNow
            color: Appearance.accent
            color2: Appearance.ink2
            gridColor: Appearance.rule
            lineWidth: 1.6
        }
    }
    Item {
        id: foot
        anchors.bottom: parent.bottom
        width: parent.width
        height: 16
        StyledText { text: Tasks.settings.span + " seconds"; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: big.legend
            spacing: 16
            Row { spacing: 5; Rectangle { width: 14; height: 2; color: Appearance.accent; anchors.verticalCenter: parent.verticalCenter }
                  StyledText { text: big.legend1; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 } }
            Row { spacing: 5; Rectangle { width: 14; height: 2; color: Appearance.ink2; anchors.verticalCenter: parent.verticalCenter }
                  StyledText { text: big.legend2; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 } }
        }
        StyledText { anchors.right: parent.right; text: "0"; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
    }
}
