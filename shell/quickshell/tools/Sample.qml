import QtQuick
import QtQuick.Shapes
import "../modules/icons/IconPaths.js" as IconData

// One glyph, drawn with a renderer the caller picks. Deliberately not
// MonoIcon: the point of the sheet is to compare the two renderers, and
// MonoIcon takes that decision from a setting.
Item {
    id: root
    property string name: ""
    property real size: 22
    property int renderer: Shape.GeometryRenderer
    property color inkColor: "#e8e5e4"
    property color accentColor: "#ff563c"

    readonly property var spec: IconData.icons[name] || ({})
    readonly property real stroke: Math.max(2, 2 * (24 / Math.max(1, size)))

    implicitWidth: size
    implicitHeight: size

    Item {
        width: 24; height: 24
        scale: root.size / 24
        transformOrigin: Item.TopLeft
        antialiasing: true

        Shape {
            visible: !!root.spec.fill
            anchors.fill: parent
            preferredRendererType: root.renderer
            ShapePath {
                fillColor: root.accentColor; strokeWidth: 0; strokeColor: "transparent"
                PathSvg { path: root.spec.fill || "" }
            }
        }
        Shape {
            visible: !!root.spec.ink
            anchors.fill: parent
            preferredRendererType: root.renderer
            ShapePath {
                strokeColor: root.inkColor; strokeWidth: root.stroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.spec.ink || "" }
            }
        }
        Shape {
            visible: !!root.spec.acc
            anchors.fill: parent
            preferredRendererType: root.renderer
            ShapePath {
                strokeColor: root.accentColor; strokeWidth: root.stroke
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap; joinStyle: ShapePath.RoundJoin
                PathSvg { path: root.spec.acc || "" }
            }
        }
        Repeater {
            model: root.spec.dots || []
            Rectangle {
                required property var modelData
                x: modelData.cx - modelData.r; y: modelData.cy - modelData.r
                width: modelData.r * 2; height: modelData.r * 2
                radius: modelData.r; antialiasing: true
                color: modelData.c === "acc" ? root.accentColor : root.inkColor
            }
        }
    }
}
