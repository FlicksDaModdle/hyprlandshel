import QtQuick
import Quickshell.Services.Pipewire
import "../../config" as Config

// A live level meter for one device: what the microphone is hearing, or
// what an output is playing.
//
// Its own file, loaded by URL from SoundPanel.qml, because the peak monitor
// arrived in Quickshell 0.3: on an older build this fails to load, the pane
// says so in a line, and everything else in it works.
Item {
    id: root

    property var node: null
    property bool live: true

    implicitHeight: 8
    implicitWidth: 200

    PwNodePeakMonitor {
        id: mon
        node: root.node
        enabled: root.live && !!root.node
    }

    // On a decibel scale from -60 dB to 0, which is how loud reads to an
    // ear; a linear one sits near empty for anything but a shout.
    readonly property real level: {
        const p = mon.peak;
        if (!(p > 0)) return 0;
        return Math.max(0, Math.min(1, 1 + 20 * Math.log(p) / Math.LN10 / 60));
    }
    // A slow-falling hold line, like a mixing desk's, so a single loud
    // moment stays readable.
    property real hold: 0
    onLevelChanged: if (level > hold) hold = level
    Timer {
        interval: 50
        running: root.live && root.hold > 0
        repeat: true
        onTriggered: root.hold = Math.max(root.level, root.hold - 0.02)
    }

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule
        clip: true

        Rectangle {
            width: parent.width * root.level
            height: parent.height
            radius: parent.radius
            color: root.level > 0.94 ? "#d93a2b" : Config.Appearance.accent
            Behavior on width { NumberAnimation { duration: 60 } }
        }
        Rectangle {
            visible: root.hold > 0.02
            x: Math.min(parent.width - 2, parent.width * root.hold)
            width: 2
            height: parent.height
            color: Config.Appearance.ink2
        }
    }
}
