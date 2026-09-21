import QtQuick
import QtQuick.Shapes
import "IconPaths.js" as IconData

// Renders one glyph from the bespoke icon pack (see IconPaths.js): 2px
// monoline strokes plus zero or more accent-colored elements. Coordinates
// are authored on a fixed 24x24 grid and scaled to `size`.
Item {
    id: root

    property string name: ""
    property real size: 24
    property color inkColor: "#605d5d"
    property color accentColor: "#ec3013"

    implicitWidth: size
    implicitHeight: size

    readonly property var spec: IconData.icons[name] || []
    readonly property var strokeOps: spec.filter(op => op.type !== "circle")
    readonly property var circleOps: spec.filter(op => op.type === "circle")

    Item {
        id: canvas
        width: 24
        height: 24
        scale: root.size / 24
        transformOrigin: Item.TopLeft

        // Repeater delegates must be Items, and ShapePath isn't one — so
        // each stroke op gets its own single-path Shape (Item-derived),
        // stacked at (0,0) on the same 24x24 grid instead of one Shape
        // with a Repeater of ShapePath children.
        Repeater {
            model: root.strokeOps
            Shape {
                id: strokeShape
                required property var modelData
                width: 24
                height: 24
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: strokeShape.modelData.c === "accent" ? root.accentColor : root.inkColor
                    strokeWidth: strokeShape.modelData.w || 2
                    fillColor: "transparent"
                    capStyle: ShapePath.RoundCap
                    joinStyle: ShapePath.RoundJoin
                    PathSvg { path: strokeShape.modelData.d }
                }
            }
        }

        Repeater {
            model: root.circleOps
            Rectangle {
                required property var modelData
                x: modelData.cx - modelData.r
                y: modelData.cy - modelData.r
                width: modelData.r * 2
                height: modelData.r * 2
                radius: modelData.r
                color: modelData.fill === "accent" ? root.accentColor : "transparent"
                border.color: modelData.stroke === "ink" ? root.inkColor : "transparent"
                border.width: modelData.stroke === "ink" ? 2 : 0
            }
        }
    }
}
