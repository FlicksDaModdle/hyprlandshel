import QtQuick
import "../../config" as Config

// Face unlock's glyph, at the top of the login and lock screens (and over
// the camera in Settings): a lens of three arcs around a face drawn in
// dots, the pattern an IR camera's projector throws onto you.
//
//   state "looking"   the lens turns, and a band of light sweeps down
//                     through the dots, top to bottom, over and over
//   state "found"     the lens closes into a whole ring, in the accent,
//                     and the dots give way to a tick
//   state "failed"    the lens stops and reddens, the dots dim, a shake
//   state "idle"      all of it, standing still
//   state ""          gone
//
// Drawn on a Canvas rather than with Shapes: the login screen can be on a
// software renderer, which draws no curved Shape.
Item {
    id: root

    property string state: ""
    property color ink: "white"
    property color accent: Config.Appearance.accent
    property color bad: Qt.rgba(1, 0.42, 0.38, 1)
    property real size: 64
    // The dot face inside the lens; off where something else is in there
    // (the camera's picture, in Settings).
    property bool showFace: true

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    // In and out.
    readonly property bool shown: state !== ""
    opacity: showSpring.value
    visible: opacity > 0.01
    scale: 0.85 + 0.15 * showSpring.value
    Spring { id: showSpring; to: root.shown ? 1 : 0; response: 420; bounce: 0.5 }

    // While looking: the sweep's place (0 top to 1 bottom, every 1.6 s) and
    // the lens's turn (a full turn every 9 s).
    property real sweep: -1
    property real turn: 0
    FrameAnimation {
        running: root.visible && root.state === "looking" && Config.Appearance.animated
        onTriggered: {
            const now = Date.now();
            root.sweep = (now % 1600) / 1600 * 1.4 - 0.2;
            root.turn = (now % 9000) / 9000 * 2 * Math.PI;
        }
    }
    onStateChanged: {
        if (state === "failed") {
            shake.velocity = 900;
            shake.wake();
        }
        if (state !== "looking") sweep = -1;
    }

    // The lens's gaps closing (found), the tick drawing itself, the dots
    // dimming (failed).
    Spring { id: close; to: root.state === "found" ? 1 : 0; response: 460; bounce: 0.4 }
    Spring { id: tick; to: root.state === "found" ? 1 : 0; response: 560; bounce: 0 }
    Spring { id: dim; to: root.state === "failed" ? 1 : 0; response: 360; bounce: 0 }
    // A sideways shake, as the password field does.
    Spring { id: shake; to: 0; response: 300; bounce: 2.2 }
    ColorSpring {
        id: tint
        to: root.state === "found" ? root.accent : root.state === "failed" ? root.bad : root.ink
    }

    transform: Translate { x: shake.value * 0.04 }

    // The face, as dots: a head and shoulders, on a grid, worked out once
    // (in units of the glyph's size).
    readonly property var dots: {
        const out = [];
        const step = 0.075;
        for (let y = 0.2; y <= 0.86; y += step) {
            for (let x = 0.2; x <= 0.8; x += step) {
                const hx = (x - 0.5) / 0.17, hy = (y - 0.42) / 0.2;
                const head = hx * hx + hy * hy <= 1;
                const sx = (x - 0.5) / 0.31, sy = (y - 0.92) / 0.22;
                const shoulders = y > 0.68 && sx * sx + sy * sy <= 1;
                // Inside the lens, with room to spare.
                const r = Math.hypot(x - 0.5, y - 0.5);
                if ((head || shoulders) && r < 0.36) out.push([x, y]);
            }
        }
        return out;
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        antialiasing: true
        renderStrategy: Canvas.Cooperative

        readonly property real sweep: root.sweep
        readonly property real turn: root.turn
        readonly property real closeP: close.value
        readonly property real tickP: tick.value
        readonly property real dimP: dim.value
        readonly property color col: tint.value
        onSweepChanged: requestPaint()
        onTurnChanged: requestPaint()
        onClosePChanged: requestPaint()
        onTickPChanged: requestPaint()
        onDimPChanged: requestPaint()
        onColChanged: requestPaint()
        onWidthChanged: requestPaint()
        readonly property bool face: root.showFace
        onFaceChanged: requestPaint()

        onPaint: {
            const ctx = getContext("2d");
            const s = width;
            ctx.reset();
            ctx.lineCap = "round";
            ctx.strokeStyle = col;
            ctx.fillStyle = col;
            const lw = Math.max(2, s * 0.045);
            ctx.lineWidth = lw;
            const cx = s / 2, cy = s / 2;

            // ── the lens ─────────────────────────────────────────────────
            // Three arcs with gaps between, turning while it looks; the
            // gaps close as it finds you.
            const R = s / 2 - lw;
            const gap = (1 - Math.max(0, Math.min(1, closeP))) * 0.55;
            for (let i = 0; i < 3; i++) {
                const a0 = turn + i * 2 * Math.PI / 3 + gap / 2;
                const a1 = turn + (i + 1) * 2 * Math.PI / 3 - gap / 2;
                ctx.beginPath();
                ctx.arc(cx, cy, R, a0, a1, false);
                ctx.stroke();
            }
            // A fainter inner ring, the lens's glass.
            ctx.globalAlpha = 0.22 * (1 - tickP);
            ctx.lineWidth = Math.max(1, lw * 0.5);
            ctx.beginPath();
            ctx.arc(cx, cy, R - lw * 1.6, 0, 2 * Math.PI, false);
            ctx.stroke();
            ctx.lineWidth = lw;
            ctx.globalAlpha = 1;

            // ── the face, in dots ────────────────────────────────────────
            // Lit where the sweep is passing; dim on a failure; fading as
            // the tick comes.
            const fade = 1 - tickP;
            if (fade > 0.01 && root.showFace) {
                const dr = Math.max(1, s * 0.022);
                for (const d of root.dots) {
                    let a = 0.35;
                    if (sweep > -0.5) {
                        const t = (d[1] - sweep) / 0.09;
                        a = 0.28 + 0.72 * Math.exp(-t * t);
                    } else if (dimP < 0.01) {
                        a = 0.75;
                    }
                    a *= (1 - 0.6 * dimP) * fade;
                    ctx.globalAlpha = a;
                    ctx.beginPath();
                    ctx.arc(d[0] * s, d[1] * s, dr, 0, 2 * Math.PI, false);
                    ctx.fill();
                }
                ctx.globalAlpha = 1;
            }

            // ── the tick ─────────────────────────────────────────────────
            if (tickP > 0.01) {
                const p0 = [s * 0.33, s * 0.52], p1 = [s * 0.45, s * 0.64], p2 = [s * 0.68, s * 0.39];
                const l1 = Math.hypot(p1[0] - p0[0], p1[1] - p0[1]);
                const l2 = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]);
                let d = Math.min(1, tickP) * (l1 + l2);
                ctx.lineWidth = lw * 1.3;
                ctx.lineJoin = "round";
                ctx.beginPath();
                ctx.moveTo(p0[0], p0[1]);
                if (d <= l1) {
                    ctx.lineTo(p0[0] + (p1[0] - p0[0]) * d / l1, p0[1] + (p1[1] - p0[1]) * d / l1);
                } else {
                    ctx.lineTo(p1[0], p1[1]);
                    d -= l1;
                    ctx.lineTo(p1[0] + (p2[0] - p1[0]) * d / l2, p1[1] + (p2[1] - p1[1]) * d / l2);
                }
                ctx.stroke();
            }
        }
    }
}
