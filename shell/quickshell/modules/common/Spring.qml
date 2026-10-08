import QtQuick
import "../../config" as Config

// The shell's one way of moving things: a spring. Quick off the mark, a
// little past where it is going, and an easy settle. Used as
// `Behavior on y { Spring {} }`, or on its own with target, property and to.
//
// The curve is a damped sine (Easing.OutElastic with a long period), which
// is what an underdamped spring's step response is: with period p it
// reaches the target at p/4 of the duration, swings 2^(-5p) past it at p/2
// and settles, with no second swing worth seeing. So most of the travel is
// over in the first fifth — quick for its length — and the rest is the
// settle. Unlike Easing.OutBack, which overshoots once and snaps back,
// nothing about it is abrupt.
//
// `bounce` scales the overshoot: 1 is the house amount (about 6%), 0 none
// — what leaving wants, since only an arrival needs to land. Settings →
// Appearance → Animation sets how bouncy the house amount is and how fast
// everything runs; Smooth turns the overshoot off everywhere.
NumberAnimation {
    property int ms: 380
    property real bounce: 1

    readonly property real amount: Config.Appearance.springy
        ? Math.max(0, bounce) * Config.Appearance.motionBounce / 100 : 0
    readonly property real overshoot: Math.min(0.2, 0.06 * amount)

    duration: Config.Appearance.anim(overshoot > 0.002 ? ms : Math.round(ms * 0.75))
    easing.type: overshoot > 0.002 ? Easing.OutElastic : Easing.OutQuint
    easing.amplitude: 1
    easing.period: overshoot > 0.002 ? Math.max(0.3, Math.min(2, -Math.log(overshoot) / Math.LN2 / 5)) : 0.3
}
