import QtQuick
import "../../config" as Config

// The shell's one way of moving things: quick off the mark, a little past
// where it is going, and back — how macOS moves a panel, a switch or a
// dock icon. Used as `Behavior on y { Spring {} }`.
//
// `bounce` scales the overshoot: 1 is the house amount (about 8%), 0 none
// — what leaving wants, since only an arrival needs to land. With Motion
// set to Smooth there is no overshoot anywhere, and Animation speed
// governs the duration as it does every other one.
NumberAnimation {
    property int ms: 380
    property real bounce: 1

    readonly property bool sprung: Config.Appearance.springy && bounce > 0

    duration: Config.Appearance.anim(sprung ? ms : Math.round(ms * 0.8))
    easing.type: sprung ? Easing.OutBack : Easing.OutCubic
    // Easing.OutBack's own 1.70158 overshoots by 10%; 1.5 is about 8%.
    easing.overshoot: 1.5 * bounce
}
