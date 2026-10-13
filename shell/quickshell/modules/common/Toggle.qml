import QtQuick
import "../../config" as Config

// 40x22 pill switch — the mockup's toggle, used in Settings rows and the
// control center's drill-down header.
//
// The knob does three things at once rather than sliding: it stretches
// along the direction of travel, leans past its destination and settles,
// and the track's fill grows out from under it. A switch that only
// translates reads as a diagram of a switch; this reads as one being
// thrown.
Item {
    id: root

    // Bound by the caller to live state; never written from in here, so
    // that binding survives being clicked.
    property bool checked: false
    signal toggled(bool checked)

    implicitWidth: 40
    implicitHeight: 22

    readonly property real knobBase: height - 4
    // Squashed while it travels and while it is held, the way a physical
    // control gives a little.
    readonly property bool busy: pos.moving || press.pressed
    readonly property real knobW: root.busy ? Math.round(knobBase * 1.35) : knobBase

    // Where the knob is, 0 off to 1 on: a spring, so it leans a little
    // past and settles, and a second click mid-throw turns it round.
    Spring { id: pos; to: root.checked ? 1 : 0; response: 300 }
    Spring { id: stretch; to: root.knobW; response: 200; bounce: 0 }
    Spring { id: fill; to: root.checked ? 1 : 0; response: 300; bounce: 0 }
    ColorSpring { id: trackCol; to: root.checked ? Config.Appearance.accent : Config.Appearance.sel }
    ColorSpring { id: knobCol; to: root.checked ? Config.Appearance.inkOnAccent : Config.Appearance.ink2 }

    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: trackCol.value
        opacity: root.enabled ? 1 : 0.45

        // The accent arriving as a fill that grows from the knob's side,
        // rather than the whole track changing colour at once. Only drawn
        // on the way in; on the way out the track's own colour animation
        // carries it, which is the quieter direction.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            height: parent.height
            width: parent.width * Math.max(0, fill.value)
            radius: height / 2
            color: Config.Appearance.accent
            visible: width > 0.5 && root.checked
        }

        Rectangle {
            id: knob
            height: root.knobBase
            width: stretch.value
            radius: height / 2
            y: 2
            x: 2 + pos.value * (parent.width - width - 4)
            color: knobCol.value
        }
    }

    MouseArea {
        id: press
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
