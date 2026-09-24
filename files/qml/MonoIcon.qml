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

    // How the edges are smoothed. Three settings because the two things
    // that can do it have different costs and different risks:
    //
    //   "off"     Shape's geometry renderer, raw. Triangulated, no
    //             antialiasing of its own — this is what the glyphs looked
    //             like after the curve renderer was switched off, and the
    //             answer to "there is no antialiasing on any icons".
    //   "layer"   the same renderer, multisampled 4x as one layer per
    //             glyph. An old, widely supported Qt Quick feature that
    //             does not change how the path is rasterised, only how the
    //             result is resolved. The default.
    //   "curve"   Shape.CurveRenderer, which antialiases analytically in
    //             the shader. The best edges, and the one that dropped the
    //             dock's grid and panelsTopLeft glyphs entirely on real
    //             hardware while looking perfect in every check here.
    //
    // Neither smoothing path can be verified in this repository: every
    // render used to check these glyphs runs on Qt's software backend,
    // which ignores both layer.samples and preferredRendererType and
    // rasterises its own way. So the default is the conservative one and
    // the others are a switch, not a promise.
    readonly property bool multisample: Appearance.iconSmoothing === "layer"
    readonly property bool curves:
        Appearance.iconSmoothing === "curve" && Shape.CurveRenderer !== undefined
    readonly property var curveRenderer: Shape.CurveRenderer

    Item {
        width: 24
        height: 24
        scale: root.drawSize / 24
        transformOrigin: Item.TopLeft
        antialiasing: true
        // Supersampled, not just multisampled. `layer.samples` asks the
        // GPU for MSAA and is ignored by backends that have none, which
        // leaves a layer resolved at 1:1 and looking softer than no layer
        // at all. Rendering the layer at twice the size and letting it
        // scale down is antialiasing that does not depend on the backend
        // having anything in particular, and the samples request rides
        // along for the hardware that does honour it.
        layer.enabled: root.multisample
        layer.samples: 4
        layer.smooth: true
        layer.textureSize: root.multisample
                           ? Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                           // Not undefined: textureSize is a QSize and
                           // has no such value, so assigning it warned
                           // once per glyph. Qt's own default is an
                           // invalid QSize, meaning "use the item's
                           // size", which is what this says.
                           : Qt.size(-1, -1)

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
