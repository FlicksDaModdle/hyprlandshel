import QtQuick
import QtQuick.Shapes
import "../../config" as Config

// The theme's own ground — the mockup's tinted gradient: a diagonal base
// wash with two radial pools over it, retuned per theme and per tint. The
// desktop draws it when no picture or animation is chosen, and the lock
// screen and greeter draw it under whatever they show (Ground.qml).
Item {
    id: g

    readonly property var tint: Config.Appearance.tintSpec
    // String tints promoted to color values, so the radial washes can
    // fade their own hue out to alpha 0 instead of to grey.
    readonly property color baseA: tint.a
    readonly property color baseB: tint.b
    readonly property color pool1: tint.g1 !== "" ? tint.g1 : tint.a
    readonly property color pool2: tint.g2 !== "" ? tint.g2 : tint.a

    function fade(c) { return Qt.rgba(c.r, c.g, c.b, 0); }

    // The same two colours as a plain top-to-bottom gradient, under the
    // shapes: what shows where curved shapes can't be drawn (software
    // rendering), so the ground is never bare black.
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: g.baseA }
            GradientStop { position: 1; color: g.baseB }
        }
    }

    // ── base wash ─────────────────────────────────────────────────────
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillGradient: LinearGradient {
                // CSS `linear-gradient(168deg, a, b)`: near-vertical,
                // leaning right as it descends.
                x1: 0; y1: 0
                x2: g.width * 0.21; y2: g.height
                GradientStop { position: 0; color: g.baseA }
                GradientStop { position: 1; color: g.baseB }
            }
            startX: 0; startY: 0
            PathLine { x: g.width; y: 0 }
            PathLine { x: g.width; y: g.height }
            PathLine { x: 0; y: g.height }
            PathLine { x: 0; y: 0 }
        }
    }

    // ── upper-right pool ──────────────────────────────────────────────
    Shape {
        anchors.fill: parent
        visible: g.tint.g1 !== ""
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillGradient: RadialGradient {
                centerX: g.width * 0.78; centerY: g.height * 0.04
                centerRadius: g.width * 0.62
                focalX: centerX; focalY: centerY
                GradientStop { position: 0; color: g.pool1 }
                GradientStop { position: 0.58; color: g.fade(g.pool1) }
            }
            startX: 0; startY: 0
            PathLine { x: g.width; y: 0 }
            PathLine { x: g.width; y: g.height }
            PathLine { x: 0; y: g.height }
            PathLine { x: 0; y: 0 }
        }
    }

    // ── lower-left pool ───────────────────────────────────────────────
    Shape {
        anchors.fill: parent
        visible: g.tint.g2 !== ""
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillGradient: RadialGradient {
                centerX: g.width * 0.04; centerY: g.height * 0.96
                centerRadius: g.width * 0.55
                focalX: centerX; focalY: centerY
                GradientStop { position: 0; color: g.pool2 }
                GradientStop { position: 0.62; color: g.fade(g.pool2) }
            }
            startX: 0; startY: 0
            PathLine { x: g.width; y: 0 }
            PathLine { x: g.width; y: g.height }
            PathLine { x: 0; y: g.height }
            PathLine { x: 0; y: 0 }
        }
    }
}
