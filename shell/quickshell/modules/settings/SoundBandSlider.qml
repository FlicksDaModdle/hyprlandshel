import QtQuick
import "../../config" as Config
import "../common"

// One equalizer band: a vertical slider from -12 to +12 dB, with the
// gain above it and the frequency below. A double-click resets it to 0.
Item {
    id: root

    property real value: 0              // dB
    property string label: ""
    signal moved(real value)

    implicitWidth: 38
    implicitHeight: 190

    StyledText {
        id: gainText
        anchors.horizontalCenter: parent.horizontalCenter
        text: (root.value > 0 ? "+" : "") + root.value.toFixed(root.value % 1 === 0 ? 0 : 1)
        font.pixelSize: Config.Appearance.fs(10.5)
        font.weight: Font.DemiBold
        color: Math.abs(root.value) < 0.01 ? Config.Appearance.ink3 : Config.Appearance.ink
    }
    Item {
        id: track
        anchors.top: gainText.bottom
        anchors.topMargin: 6
        anchors.bottom: freq.top
        anchors.bottomMargin: 6
        anchors.horizontalCenter: parent.horizontalCenter
        width: 10
        readonly property real zeroY: height / 2
        readonly property real valueY: height / 2 - (root.value / 12) * (height / 2)
        opacity: root.enabled ? 1 : 0.45

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Config.Appearance.ground
            border.width: 1
            border.color: Config.Appearance.rule
        }
        Rectangle {
            x: 0
            width: parent.width
            y: Math.min(track.zeroY, track.valueY)
            height: Math.max(2, Math.abs(track.valueY - track.zeroY))
            radius: width / 2
            color: Config.Appearance.accent
        }
        Rectangle {
            x: -3; width: parent.width + 6
            y: track.zeroY - 0.5; height: 1
            color: Config.Appearance.ink3
            opacity: 0.6
        }
        Rectangle {
            width: 18; height: 18; radius: 9
            anchors.horizontalCenter: parent.horizontalCenter
            y: track.valueY - 9
            color: Config.Appearance.panel
            border.width: 2
            border.color: Config.Appearance.accent
        }
        MouseArea {
            anchors.fill: parent
            anchors.leftMargin: -14
            anchors.rightMargin: -14

            cursorShape: Qt.PointingHandCursor
            preventStealing: true
            function set(y) {
                const v = (track.zeroY - y) / (track.height / 2) * 12;
                root.moved(Math.round(Math.max(-12, Math.min(12, v)) * 2) / 2);
            }
            onPressed: mouse => set(mouse.y)
            onPositionChanged: mouse => { if (pressed) set(mouse.y); }
            onDoubleClicked: root.moved(0)
            onWheel: wheel => root.moved(Math.max(-12, Math.min(12, root.value + (wheel.angleDelta.y > 0 ? 0.5 : -0.5))))
        }
    }
    StyledText {
        id: freq
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.label
        font.pixelSize: Config.Appearance.fs(10.5)
        color: Config.Appearance.ink3
    }
}
