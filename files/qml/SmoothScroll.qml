import QtQuick

// Scrolling the way a browser does it, for a Flickable: laid over it, it
// takes the wheel and moves `target` itself.
//
//   a mouse wheel   each notch glides to where it is going and eases to a
//                   stop, and notches given quickly add up into one glide;
//   a touchpad      the content follows the fingers exactly, and when they
//                   lift it carries on at the speed they were moving and
//                   slows to a stop under friction.
//
// Qt's own Flickable moves a fixed step per notch and stops dead the moment
// a touchpad lets go: on Linux nothing synthesises the coasting, not the
// compositor and not Qt, so each application that wants it does it itself.
//
// Takes no buttons, so every click goes through to what is underneath.
MouseArea {
    id: ss

    required property Flickable target

    // Pixels per wheel notch.
    property real notch: 110
    // Seconds: how quickly a notch's glide settles (the time constant of an
    // exponential ease — most of the way there in about three of these).
    property real ease: 0.075
    // Seconds: how long a touchpad's coast lasts (the time constant of the
    // friction). Longer is slipperier.
    property real glide: 0.45

    acceptedButtons: Qt.NoButton

    property real pos: 0            // where the content is, unrounded
    property real lastSet: 0        // what was last given to the target
    property real pending: 0        // wheel: distance still to travel
    property real velocity: 0       // touchpad: px/s once the fingers lift
    property bool fingers: false    // a touchpad gesture is in progress
    property real lastAt: 0         // ms, the last touchpad movement

    readonly property real minY: ss.target.originY
    readonly property real maxY: ss.target.originY + Math.max(0, ss.target.contentHeight - ss.target.height)
    readonly property bool moving: ss.pending !== 0 || (!ss.fingers && ss.velocity !== 0)

    function stop() { ss.pending = 0; ss.velocity = 0; }

    // Picks up from wherever the content is now — a scroll bar drag, a
    // folder change, a key — rather than from where this last left it.
    function sync() {
        if (Math.abs(ss.target.contentY - ss.lastSet) > 0.5) { ss.stop(); ss.pos = ss.target.contentY; }
    }
    function place(y) {
        const c = Math.max(ss.minY, Math.min(ss.maxY, y));
        if (c !== y) { ss.pending = 0; ss.velocity = 0; }     // the end stops it
        ss.pos = c;
        // Whole pixels, so text does not shimmer between them on the way.
        ss.lastSet = Math.round(c);
        ss.target.contentY = ss.lastSet;
    }

    Connections {
        target: ss.target
        function onContentYChanged() { if (Math.abs(ss.target.contentY - ss.lastSet) > 0.5) ss.stop(); }
        function onContentHeightChanged() { if (ss.pos > ss.maxY) ss.place(ss.maxY); }
    }

    onWheel: wheel => {
        wheel.accepted = true;
        ss.target.cancelFlick();
        ss.sync();
        const phased = wheel.phase !== Qt.NoScrollPhase;
        const touchpad = phased || wheel.pixelDelta.y !== 0;

        if (!touchpad) {
            // A wheel. Turning the other way drops what is left of the
            // last glide rather than fighting it.
            ss.velocity = 0;
            const d = -wheel.angleDelta.y / 120 * ss.notch;
            if (d === 0) return;
            if (ss.pending !== 0 && Math.sign(d) !== Math.sign(ss.pending)) ss.pending = 0;
            // Never queue more than a screenful beyond where it stands.
            ss.pending = Math.max(-ss.target.height * 1.5, Math.min(ss.target.height * 1.5, ss.pending + d));
            return;
        }

        const now = Date.now();
        // A new gesture catches whatever is still coasting, as a finger on
        // a moving page does, and starts its speed afresh.
        const fresh = wheel.phase === Qt.ScrollBegin || !ss.fingers;
        if (fresh) { ss.stop(); ss.fingers = true; }
        if (wheel.phase === Qt.ScrollEnd) {
            // Fingers off. If they had stopped before lifting, so does this.
            ss.fingers = false;
            if (now - ss.lastAt > 60) ss.velocity = 0;
            return;
        }
        // Momentum from the system, where there is one (not on Linux):
        // follow it, and add none of our own.
        if (wheel.phase === Qt.ScrollMomentum) {
            ss.velocity = 0;
            ss.place(ss.pos - (wheel.pixelDelta.y || wheel.angleDelta.y / 120 * ss.notch));
            return;
        }

        ss.pending = 0;
        ss.fingers = true;
        const d = -(wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 120 * ss.notch);
        const dt = Math.max(0.004, (now - ss.lastAt) / 1000);
        const v = d / dt;
        // Smoothed over the last few events: one jittery delta should not
        // decide how far the coast goes. The first of a gesture has no
        // interval to measure, so it sets none.
        ss.velocity = fresh || dt > 0.1 ? 0 : (ss.velocity === 0 ? v : ss.velocity * 0.6 + v * 0.4);
        ss.velocity = Math.max(-9000, Math.min(9000, ss.velocity));
        ss.lastAt = now;
        ss.place(ss.pos + d);
        // A touchpad that sends no phases has no "lifted" either; a pause
        // in its events stands in for one.
        if (!phased) lift.restart();
    }

    Timer {
        id: lift
        interval: 70
        onTriggered: ss.fingers = false
    }

    FrameAnimation {
        running: ss.moving
        onTriggered: {
            const dt = Math.min(0.05, Math.max(0.001, frameTime));
            let y = ss.pos;
            if (ss.pending !== 0) {
                let step = ss.pending * (1 - Math.exp(-dt / ss.ease));
                if (Math.abs(ss.pending - step) < 0.5) step = ss.pending;
                ss.pending -= step;
                y += step;
            }
            if (!ss.fingers && ss.velocity !== 0) {
                y += ss.velocity * dt;
                ss.velocity *= Math.exp(-dt / ss.glide);
                if (Math.abs(ss.velocity) < 12) ss.velocity = 0;
            }
            ss.place(y);
        }
    }
}
