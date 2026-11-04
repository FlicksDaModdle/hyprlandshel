import QtQuick

// Scrolling the way a browser does it, for a Flickable: laid over it, it
// takes the wheel and moves `target` itself.
//
//   a mouse wheel   each notch glides to where it is going and eases to a
//                   stop, and notches given quickly add up into one glide;
//   a touchpad      the content follows the fingers exactly, and when they
//                   lift it carries on at the speed they were moving and
//                   slows to a stop: Flickable's own flick, set up as the
//                   shell's Settings has it (KineticScroll.qml), so the two
//                   feel the same.
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

    acceptedButtons: Qt.NoButton

    // What each scroll was, for when it doesn't feel right:
    // QT_LOGGING_RULES="hyprshell.scroll.debug=true" hyprshell-tasks
    LoggingCategory {
        id: log
        name: "hyprshell.scroll"
        defaultLogLevel: LoggingCategory.Warning
    }

    property real pos: 0            // where the content is, unrounded
    property real lastSet: 0        // what was last given to the target
    property real pending: 0        // wheel: distance still to travel

    readonly property real minY: ss.target.originY
    readonly property real maxY: ss.target.originY + Math.max(0, ss.target.contentHeight - ss.target.height)
    readonly property bool moving: ss.pending !== 0

    function stop() { ss.pending = 0; }

    // Picks up from wherever the content is now — a scroll bar drag, a
    // folder change, a key — rather than from where this last left it.
    function sync() {
        if (Math.abs(ss.target.contentY - ss.lastSet) > 0.5) { ss.stop(); ss.pos = ss.target.contentY; }
    }
    function place(y) {
        const c = Math.max(ss.minY, Math.min(ss.maxY, y));
        if (c !== y) ss.pending = 0;     // the end stops it
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
        console.debug(log, "wheel phase", wheel.phase, "angle", wheel.angleDelta.y, "pixel", wheel.pixelDelta.y,
                      "inverted", wheel.inverted, "contentY", Math.round(ss.target.contentY), "max", Math.round(ss.maxY));
        wheel.accepted = true;
        // Not on every event: a touchpad can send its "lifted" twice, and
        // stopping here on the second one killed the coast the first had
        // just started. A wheel stops it, and fingers that touch or move.
        if (wheel.phase === Qt.NoScrollPhase) {
            ss.target.cancelFlick();
            ss.sync();
        }
        // Only a touchpad sends scroll phases. Pixel deltas are no test:
        // on Wayland Qt gives them for a plain mouse wheel too, and the
        // mouse then coasted like a touchpad.
        const phased = wheel.phase !== Qt.NoScrollPhase;
        const touchpad = phased;

        if (!touchpad) {
            // A wheel. Turning the other way drops what is left of the
            // last glide rather than fighting it.
            const d = -wheel.angleDelta.y / 120 * ss.notch;
            if (d === 0) return;
            if (ss.pending !== 0 && Math.sign(d) !== Math.sign(ss.pending)) ss.pending = 0;
            // Never queue more than a screenful beyond where it stands.
            ss.pending = Math.max(-ss.target.height * 1.5, Math.min(ss.target.height * 1.5, ss.pending + d));
            return;
        }

        // A touchpad, the way Settings in the shell does it
        // (KineticScroll.qml): the content follows the fingers 1:1, and on
        // lifting carries on at the speed they were moving, slowing under
        // Flickable's own deceleration — unless they had stopped first.
        // Momentum from the system, where there is one (not on Linux):
        // followed, with none of our own added.
        if (wheel.phase === Qt.ScrollMomentum) {
            ss.place(ss.target.contentY - (wheel.pixelDelta.y || wheel.angleDelta.y / 120 * ss.notch));
            return;
        }
        ss.finger(wheel.phase, -(wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 120 * ss.notch));
    }

    // Fingers on the touchpad: the phase, and how far they moved the
    // content (in contentY's direction).
    //
    // Inside the list the content follows them 1:1. Past either end it
    // stretches, less the further it goes, and springs back when they let
    // go — rather than stopping dead, which on a short list (a side rail)
    // was all a flick ever did.
    property real raw: 0     // where the fingers would have it, unstretched
    function finger(phase, d) {
        if (phase === Qt.ScrollBegin) {
            ss.stop();
            ss.target.cancelFlick();
            ss.samples = [];
            ss.raw = ss.target.contentY;
        }
        if (d !== 0) {
            // A lone movement far beyond the ones before it is the touchpad
            // glitching (here: 213 px among 10s): kept to their pace, or
            // the list leaps.
            const prev = ss.samples.length > 0 ? Math.abs(ss.samples[ss.samples.length - 1].dy) : 0;
            if (Math.abs(d) > 60 && Math.abs(d) > 4 * Math.max(prev, 8))
                d = Math.sign(d) * Math.max(prev, 8);
            ss.pending = 0;
            ss.target.cancelFlick();
            // Picked up from wherever it is, unless this gesture is already
            // stretching it.
            if (ss.target.contentY >= ss.minY && ss.target.contentY <= ss.maxY) ss.raw = ss.target.contentY;
            ss.raw += d;
            ss.stretch(ss.raw);
            const list = ss.samples.length > 16 ? ss.samples.slice(-16) : ss.samples.slice();
            list.push({ t: Date.now(), dy: d });
            ss.samples = list;
        }
        if (phase === Qt.ScrollEnd) ss.release();
    }
    function rubber(x) {
        const most = Math.min(90, ss.target.height * 0.18);
        return most * (1 - 1 / (x / most * 0.6 + 1));
    }
    function stretch(y) {
        let v = y;
        if (y < ss.minY) v = ss.minY - ss.rubber(ss.minY - y);
        else if (y > ss.maxY) v = ss.maxY + ss.rubber(y - ss.maxY);
        ss.pos = v;
        ss.lastSet = v;
        ss.target.contentY = v;
    }

    // Recent finger movement, { t, dy }.
    property var samples: []
    function release() {
        const s = ss.samples;
        ss.samples = [];
        // Stretched past an end: back to it.
        if (ss.target.contentY < ss.minY - 0.5 || ss.target.contentY > ss.maxY + 0.5) {
            console.debug(log, "lifted while stretched: back to the end");
            ss.target.returnToBounds();
            return;
        }
        if (s.length === 0) return;
        const last = s[s.length - 1];
        // Fingers that stopped before lifting leave it where it is.
        if (Date.now() - last.t > 50) return;
        const win = s.filter(e => last.t - e.t <= 90);
        const dt = (last.t - win[0].t) / 1000;
        const v = win.length >= 2 && dt > 0 ? win.slice(1).reduce((a, e) => a + e.dy, 0) / dt : last.dy * 60;
        console.debug(log, "lifted:", s.length, "samples, speed", Math.round(v), "px/s");
        if (Math.abs(v) < 120) return;
        // flick() takes the content's velocity as a drag gives it: positive
        // moves it down, which is scrolling up.
        ss.target.flick(0, -v);
        console.debug(log, "coast from", Math.round(ss.target.contentY), "started:", ss.target.flicking,
                      "range", Math.round(ss.minY), "to", Math.round(ss.maxY), "height", Math.round(ss.target.height));
        coastCheck.from = ss.target.contentY;
        coastCheck.restart();
    }
    // (For the log: where the coast got to.)
    Timer {
        id: coastCheck
        property real from: 0
        interval: 350
        onTriggered: console.debug(log, "coast after 0.35 s:", Math.round(coastCheck.from), "->",
                                   Math.round(ss.target.contentY), "still moving:", ss.target.flicking)
    }
    Component.onCompleted: {
        ss.target.flickDeceleration = 1800;
        ss.target.maximumFlickVelocity = 7000;
        // A flick that reaches an end goes a little past it and comes back.
        ss.target.boundsBehavior = Flickable.OvershootBounds;
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
            ss.place(y);
        }
    }
}
