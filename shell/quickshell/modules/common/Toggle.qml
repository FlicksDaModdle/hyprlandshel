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
    readonly property bool busy: xAnim.running || press.pressed
    readonly property real knobW: root.busy ? Math.round(knobBase * 1.35) : knobBase

    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? Config.Appearance.accent : Config.Appearance.sel
        opacity: root.enabled ? 1 : 0.45
        Behavior on color { ColorAnimation { duration: Config.Appearance.anim(220) } }

        // The accent arriving as a fill that grows from the knob's side,
        // rather than the whole track changing colour at once. Only drawn
        // on the way in; on the way out the track's own colour animation
        // carries it, which is the quieter direction.
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            height: parent.height
            width: root.checked ? parent.width : 0
            radius: height / 2
            color: Config.Appearance.accent
            visible: width > 0.5
            Behavior on width {
                NumberAnimation {
                    duration: Config.Appearance.anim(260)
                    easing.type: Easing.OutQuint
                }
            }
        }

        Rectangle {
            id: knob
            height: root.knobBase
            width: root.knobW
            radius: height / 2
            y: 2
            x: root.checked ? parent.width - width - 2 : 2
            color: root.checked ? Config.Appearance.inkOnAccent : Config.Appearance.ink2

            Behavior on x {
                NumberAnimation {
                    id: xAnim
                    duration: Config.Appearance.anim(260)
                    // A little past, then back. The overshoot is small
                    // enough to feel like weight rather than like a bounce.
                    easing.type: Easing.OutBack
                    easing.overshoot: 1.1
                }
            }
            Behavior on width {
                NumberAnimation {
                    duration: Config.Appearance.anim(180)
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on color { ColorAnimation { duration: Config.Appearance.anim(220) } }
        }
    }

    MouseArea {
        id: press
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggled(!root.checked)
    }
}
