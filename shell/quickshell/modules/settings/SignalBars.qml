import QtQuick
import "../../config" as Config

// Four rising bars for a Wi-Fi signal (0-100) — read at a glance, where a
// percentage has to be read.
Row {
    id: root
    property int signal: 0
    property color on: Config.Appearance.ink
    readonly property int lit: root.signal >= 75 ? 4 : root.signal >= 50 ? 3 : root.signal >= 25 ? 2 : root.signal > 0 ? 1 : 0

    spacing: 2
    height: 14
    Repeater {
        model: 4
        Rectangle {
            required property int index
            anchors.bottom: parent.bottom
            width: 3
            height: 4 + index * 3.3
            radius: 1
            color: index < root.lit ? root.on : Config.Appearance.div
        }
    }
}
