import QtQuick
import "../../config" as Config

// Wheel and trackpad scrolling for a Flickable, the way Firefox does it.
// Declared inside the Flickable it scrolls: `KineticScroll { flick: list }`.
//
// Qt's own handling moves with a trackpad and then stops dead the moment
// the fingers lift: Wayland sends no momentum, and expects the client to
// carry it on. So a trackpad (pixel deltas, with scroll phases) moves the
// content 1:1 under the fingers, and on lifting it keeps going at the
// speed they were moving and slows to a stop — unless the fingers had
// already stopped, when it stays put. Fingers back on the trackpad catch
// it. A mouse wheel, which has notches and no lift, moves a fixed step
// per notch with a short glide and stops exactly there.
//
// It sits under the content, so anything in it that takes the wheel
// itself (a dial, a graph) still gets it first; such controls ask
// `UiState.scrollLatched` to let a trackpad scroll already under way pass
// through them.
MouseArea {
    id: root

    required property Flickable flick
    // One notch of a mouse wheel.
    property real notch: 96
    // How quickly a flick slows, in px/s².
    property real friction: 1800

    x: flick.originX
    y: flick.originY - flick.topMargin
    width: Math.max(flick.contentWidth, flick.width)
    height: Math.max(flick.contentHeight + flick.topMargin + flick.bottomMargin, flick.height)
    z: -1
    acceptedButtons: Qt.NoButton

    Component.onCompleted: {
        flick.flickDeceleration = friction;
        flick.maximumFlickVelocity = 7000;
    }

    readonly property real minY: flick.originY - flick.topMargin
    readonly property real maxY: Math.max(minY, flick.originY + flick.contentHeight + flick.bottomMargin - flick.height)
    function clampY(y) { return Math.max(minY, Math.min(maxY, y)); }

    // Recent finger movement: { t, dy }, dy as the change in contentY.
    property var samples: []
    property bool sawPhases: false
    property real wheelTarget: 0

    NumberAnimation {
        id: glide
        target: root.flick
        property: "contentY"
        duration: Config.Appearance.anim(170)
        easing.type: Easing.OutCubic
    }
    // Without scroll phases there is no "lifted": a pause stands in for it.
    Timer { id: pause; interval: 60; onTriggered: root.release(true) }

    function stopAll() {
        flick.cancelFlick();
        glide.stop();
    }

    function release(afterPause) {
        pause.stop();
        let v = 0;
        const s = samples;
        samples = [];
        if (s.length === 0) return;
        const last = s[s.length - 1];
        // Fingers that stopped before lifting leave it where it is.
        // (Without phases the lift is only noticed a pause later.)
        if (Date.now() - last.t > (afterPause ? pause.interval + 40 : 50)) return;
        const win = s.filter(e => last.t - e.t <= 90);
        const dt = (last.t - win[0].t) / 1000;
        if (win.length >= 2 && dt > 0)
            v = win.slice(1).reduce((a, e) => a + e.dy, 0) / dt;
        else
            v = last.dy * 60;
        if (Math.abs(v) < 120 || !Config.Appearance.animated) return;
        // flick() takes the content's velocity the way a drag gives it:
        // positive moves it down, which is scrolling up.
        flick.flick(0, -v);
    }

    onWheel: wheel => {
        if (!scroll(wheel.pixelDelta.x, wheel.pixelDelta.y, wheel.angleDelta.y, wheel.phase))
            wheel.accepted = false;
    }

    // One wheel event, as numbers. Returns whether it was used.
    function scroll(pixelX, pixelY, angleY, phase) {
        const trackpad = pixelY !== 0 || pixelX !== 0 || phase !== Qt.NoScrollPhase;
        if (!trackpad) {
            const steps = angleY / 120;
            if (steps === 0) return false;
            flick.cancelFlick();
            const from = glide.running ? root.wheelTarget : flick.contentY;
            root.wheelTarget = clampY(from - steps * root.notch);
            glide.stop();
            glide.to = root.wheelTarget;
            glide.start();
            return true;
        }

        if (phase !== Qt.NoScrollPhase) root.sawPhases = true;
        Config.UiState.scrollLatch = Date.now() + 300;
        if (phase === Qt.ScrollBegin) { stopAll(); samples = []; }

        const dy = -pixelY;
        if (dy !== 0) {
            stopAll();
            flick.contentY = clampY(flick.contentY + dy);
            const s = samples.length > 16 ? samples.slice(-16) : samples.slice();
            s.push({ t: Date.now(), dy: dy });
            samples = s;
        }
        if (phase === Qt.ScrollEnd) release();
        else if (!root.sawPhases) pause.restart();
        return true;
    }
}
