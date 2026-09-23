import QtQuick
import QtQuick.Shapes
import "IconPaths.js" as IconData

// Renders one glyph from the bespoke icon pack (see IconPaths.js): monoline
// strokes plus zero or more accent-colored elements, authored on a fixed
// 24x24 grid and scaled to `size`.
//
// IconPaths pre-merges every stroke of the same color and width into a
// single path string, so a glyph costs at most four Shapes (usually two)
// regardless of how many strokes it has.
Item {
    id: root

    property string name: ""
    property real size: 24
    property color inkColor: "#605d5d"
    property color accentColor: "#ec3013"
    // Chrome glyphs have no accent element, so they take `inkColor`
    // throughout; setting this makes an app glyph render flat too (used by
    // the launcher's selected row, where the whole tile inverts).
    property bool monochrome: false

    readonly property var spec: IconData.icons[name] || ({})
    readonly property color accent: monochrome ? inkColor : accentColor

    // The stroke is compensated for the scale, so every glyph lands 2
    // device pixels wide whatever its size. A fixed 2 authored units is
    // 2px only at size 24 and 1.08px at size 13, and a stroke narrower
    // than a pixel cannot be drawn solid by anything — it spreads over two
    // rows at partial coverage and reads as a smudge. Measured: a glyph at
    // 17px lays down 29% more ink this way.
    readonly property real k: 24 / Math.max(1, root.size)
    readonly property real stroke: Math.max(2, 2 * root.k)
    // The heavier weight a few glyphs use keeps its 3:2 relationship.
    readonly property real strokeW: root.stroke * 1.5

    implicitWidth: size
    implicitHeight: size

    Item {
        width: 24
        height: 24
        scale: root.size / 24
        transformOrigin: Item.TopLeft
        antialiasing: true

        // Filled accent region (palette's half-disc is the only one today).
        Shape {
            visible: !!root.spec.fill
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: root.accent
                strokeWidth: 0
                strokeColor: "transparent"
                PathSvg { path: root.spec.fill || "" }
            }
        }

        Shape {
            visible: !!root.spec.ink
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: root.inkColor
                strokeWidth: root.stroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.spec.ink || "" }
            }
        }

        Shape {
            visible: !!root.spec.acc
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: root.accent
                strokeWidth: root.stroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.spec.acc || "" }
            }
        }

        Shape {
            visible: !!root.spec.inkW
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: root.inkColor
                strokeWidth: root.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.spec.inkW || "" }
            }
        }

        Shape {
            visible: !!root.spec.accW
            anchors.fill: parent
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeColor: root.accent
                strokeWidth: root.strokeW
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.spec.accW || "" }
            }
        }

        Repeater {
            model: root.spec.dots || []
            Rectangle {
                required property var modelData
                x: modelData.cx - modelData.r
                y: modelData.cy - modelData.r
                width: modelData.r * 2
                height: modelData.r * 2
                radius: modelData.r
                antialiasing: true
                color: modelData.c === "acc" ? root.accent : root.inkColor
            }
        }
    }
}
