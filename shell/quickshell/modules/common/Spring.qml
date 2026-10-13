import QtQuick
import "../../config" as Config

// The shell's one way of moving things: a real spring.
//
//     Spring { id: grow; to: root.open ? 1 : 0 }
//     scale: grow.value
//
// Not an easing curve played over a fixed time. `value` is a mass on a
// damped spring pulled towards `to`, worked out exactly every frame
// (the closed-form solution, so a long frame never makes it jitter or
// blow up, and a 120 Hz screen gets 120 steps). When `to` changes while
// it is still moving it keeps its speed and turns towards the new place,
// the way something physical does, rather than restarting from a stop —
// which is what makes a hover, a drag or a quick open-and-close read as
// liquid instead of a sequence of separate animations.
//
// `response` is how long one swing of the spring takes, in ms (SwiftUI's
// meaning): most of the travel is over in about half of it. `bounce`
// says how far it swings past: 0 is critically damped — the quickest
// arrival that never overshoots, what leaving and fading want — and 1 the
// house amount, a settle of about 2% that you feel more than see.
// Settings → Appearance → Animation scales the house bounce and the
// speed; Smooth turns every bounce to 0.
QtObject {
    id: root

    // Where it is going.
    property real to: 0
    // Where it is. Bind to this.
    property real value: 0
    // How fast it is moving, in units per second.
    property real velocity: 0

    property real response: 380
    property real bounce: 1
    // Off, it jumps straight to `to` — for a first layout, or a change
    // that should not be seen.
    property bool enabled: true

    readonly property bool moving: driver.running

    readonly property real amount: Config.Appearance.springy
        ? Math.max(0, bounce) * Config.Appearance.motionBounce / 100 : 0
    // The damping ratio: 1 critically damped, below it a settle.
    // House: 0.8, a settle of about 1.5% — felt as give, not seen as bounce.
    readonly property real zeta: Math.max(0.5, 1 - 0.2 * amount)
    readonly property real omega: 2 * Math.PI / Math.max(0.02, response / 1000)
    readonly property bool live: enabled && Config.Appearance.animated

    signal settled()

    // Jump to `v` (or to `to`) and stop.
    function snap(v) {
        driver.stop();
        velocity = 0;
        value = v === undefined ? to : v;
    }
    // Start moving from wherever it is, at whatever speed it has — for
    // when `value` or `velocity` was set by hand.
    function wake() {
        if (!live) { snap(); settled(); return; }
        span = Math.max(Math.abs(to - value), Math.abs(velocity) / omega);
        fresh = true;
        driver.restart();
    }

    property bool ready: false
    // How far it set out to go, so "close enough to stop" scales with it:
    // a fraction of a pixel for a slide, much less for a scale.
    property real span: 1
    property bool fresh: false

    onToChanged: {
        if (!ready || !live) { snap(); if (ready) settled(); return; }
        wake();
    }
    onLiveChanged: if (!live) snap()
    Component.onCompleted: { ready = true; snap(); }

    function step(dt) {
        // The first frame after a start reports the time since whatever
        // ran last; a long frame is solved exactly but is still a jump.
        dt = Math.min(dt, fresh ? 1 / 60 : 1 / 15);
        fresh = false;
        if (!(dt > 0)) return;
        dt *= Config.Appearance.animSpeed / 100;
        const w = omega, z = zeta;
        const x = value - to, v = velocity;
        let nx, nv;
        if (z > 0.999) {
            const e = Math.exp(-w * dt);
            const b = v + w * x;
            nx = (x + b * dt) * e;
            nv = (b - w * (x + b * dt)) * e;
        } else {
            const wd = w * Math.sqrt(1 - z * z);
            const e = Math.exp(-z * w * dt);
            const c = Math.cos(wd * dt), s = Math.sin(wd * dt);
            const b = (v + z * w * x) / wd;
            nx = e * (x * c + b * s);
            nv = e * ((wd * b - z * w * x) * c - (z * w * b + wd * x) * s);
        }
        const eps = Math.max(1e-4, span * 5e-4);
        if (Math.abs(nx) < eps && Math.abs(nv) < eps * w) {
            snap();
            settled();
            return;
        }
        velocity = nv;
        value = to + nx;
    }

    property FrameAnimation driver: FrameAnimation {
        // The smoothed frame time once it is moving: the raw one jitters
        // with when the frame callback happened to run, and a spring
        // stepped by it carries that jitter into every position. The first
        // frame takes the raw one, since the average is from the last run.
        onTriggered: root.step(root.fresh || !(smoothFrameTime > 0) ? frameTime : smoothFrameTime)
    }
}
