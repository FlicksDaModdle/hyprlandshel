import QtQuick

// A colour that changes the way Spring moves things: a critically damped
// spring from wherever it is now towards `to`, so a hover that comes and
// goes quickly turns back smoothly from the colour it reached.
//
//     ColorSpring { id: fill; to: area.containsMouse ? hover : rest }
//     color: fill.value
QtObject {
    id: root

    property color to: "transparent"
    property real response: 240
    property bool enabled: true

    // The colour it set out from, and the one it is going to; `value`
    // lies between them by how far the spring has got.
    property color from: "transparent"
    property color goal: "transparent"
    readonly property color value: {
        const t = Math.max(0, Math.min(1, mix.value));
        // A fade to or from transparent keeps the visible end's hue,
        // rather than passing through a dim grey on the way.
        let a = from, b = goal;
        if (a.a === 0) a = Qt.rgba(b.r, b.g, b.b, 0);
        if (b.a === 0) b = Qt.rgba(a.r, a.g, a.b, 0);
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
    }

    property Spring mix: Spring { to: 1; response: root.response; bounce: 0; enabled: root.enabled }

    property bool ready: false
    onToChanged: {
        if (!ready) return;
        from = value;
        goal = to;
        mix.velocity = 0;
        mix.value = 0;
        mix.wake();
    }
    Component.onCompleted: { from = to; goal = to; ready = true; }
}
