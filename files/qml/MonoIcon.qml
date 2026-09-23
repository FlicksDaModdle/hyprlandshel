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
//
// Two things here are about how solid the result looks rather than what it
// draws, and both were answers to "the icons are low quality":
//
//   * the stroke width is compensated for the scale, so every glyph lands
//     2 device pixels wide whatever its size. The alternative — a fixed 2
//     authored units — is 2px only at size 24 and 1.08px at size 13, and a
//     stroke narrower than a pixel cannot be drawn solid by anything. It
//     spreads over two rows at partial coverage and reads as a smudge.
//     Measured: a glyph at 17px lays down 29% more ink this way.
//
//   * Shape.CurveRenderer, where the Qt running this has it (6.6+). It
//     antialiases curves analytically in the shader rather than
//     triangulating them, so edges stay clean at any scale. It is set from
//     JS rather than declared, because naming a property that does not
//     exist is a load error on older Qt and this still has to run there.
Item {
    id: root

    property string name: ""
    // `size` stays the property callers set. `drawSize` is what is drawn,
    // and it refuses to be nothing: a size arriving as 0, NaN or undefined
    // — a binding to a preference that has not loaded, an expression that
    // divided by something empty — used to draw a glyph of no size at all,
    // silently. From the outside that is a tile with a fill and no icon in
    // it, which reads as a missing icon rather than as a bug.
    property real size: 24
    readonly property real drawSize: (size > 0 && size === size) ? size : 24
    property color inkColor: "#605d5d"
    property color accentColor: "#ec3013"
    // Chrome glyphs have no accent element, so they take `inkColor`
    // throughout; setting this makes an app glyph render flat too (used by
    // the launcher's selected row, where the whole tile inverts).
    property bool monochrome: false

    readonly property var spec: IconData.icons[name] || ({})
    readonly property color accent: monochrome ? inkColor : accentColor

    // Authored units per device pixel: 1 at size 24, and more as the glyph
    // shrinks. A 2px device stroke is `2 * k` authored units.
    readonly property real k: 24 / Math.max(1, root.drawSize)
    readonly property real stroke: Math.max(2, 2 * root.k)
    // The heavier weight a few glyphs use keeps its 3:2 relationship.
    readonly property real strokeW: root.stroke * 1.5

    implicitWidth: drawSize
    implicitHeight: drawSize

    // Qt 6.6 and up. Undefined below that, where the enum does not exist —
    // reading it is safe, assigning the property would not be, so every
    // assignment below is behind this check and never runs on older Qt.
    readonly property var curveRenderer: Shape.CurveRenderer
    readonly property bool curves: root.curveRenderer !== undefined

    Item {
        width: 24
        height: 24
        scale: root.drawSize / 24
        transformOrigin: Item.TopLeft
        antialiasing: true

        // Filled accent region (palette's half-disc is the only one today).
        Shape {
            visible: !!root.spec.fill
            anchors.fill: parent
            Component.onCompleted: if (root.curves) preferredRendererType = root.curveRenderer
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
            Component.onCompleted: if (root.curves) preferredRendererType = root.curveRenderer
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
            Component.onCompleted: if (root.curves) preferredRendererType = root.curveRenderer
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
            Component.onCompleted: if (root.curves) preferredRendererType = root.curveRenderer
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
            Component.onCompleted: if (root.curves) preferredRendererType = root.curveRenderer
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
