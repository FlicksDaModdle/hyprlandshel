import QtQuick
import QtQuick.Window
import QtQml
import QtQuick.Shapes
import Quickshell
import "../../config" as Config
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

    // How the glyph is drawn and its edges smoothed:
    //
    //   "image"   the glyph written out as SVG and rasterised once into an
    //             image, which Qt caches and shares: every bar, dock and
    //             menu icon of the same name, size and colours is one
    //             texture between them. Antialiased by the SVG renderer.
    //             The default — the others cost up to four vector shapes
    //             per icon, and "layer" an offscreen texture each on top,
    //             which across the hundreds of icons in the shell was a
    //             large part of its memory. Falls back to the shapes when
    //             this Qt cannot read SVG.
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
    readonly property string smoothing: Config.Appearance.iconSmoothing
    readonly property int renderer: smoothing === "curve"
                                    ? Shape.CurveRenderer : Shape.GeometryRenderer
    readonly property bool multisample: smoothing === "layer"
    property bool imageFailed: false
    readonly property bool asImage: smoothing === "image" && !imageFailed

    // A glyph handed over directly, for something that is being drawn
    // and has no name yet. The icon maker's previews are the real
    // MonoIcon at the real sizes, which is the only way to find out at
    // 16px that what reads beautifully at 48 is a smudge — and an
    // unsaved drawing cannot be looked up by name, because there is
    // nothing to look up.
    property var specOverride: null

    // The built-in pack first, then the ones you made.
    //
    // That order and not the other way round: a user glyph that happened
    // to be called "folder" would otherwise replace the folder icon
    // everywhere in the shell, including in places that are not apps at
    // all. Names are how icons are referred to, so the pack owns its own.
    readonly property var spec: root.specOverride
                                || IconData.icons[name]
                                || Config.UserIcons.spec(name)
                                || ({})
    readonly property color accent: monochrome ? inkColor : accentColor

    // The stroke is compensated for the scale, so every glyph lands 2
    // device pixels wide whatever its size. A fixed 2 authored units is
    // 2px only at size 24 and 1.08px at size 13, and a stroke narrower
    // than a pixel cannot be drawn solid by anything — it spreads over two
    // rows at partial coverage and reads as a smudge. Measured: a glyph at
    // 17px lays down 29% more ink this way.
    readonly property real k: 24 / Math.max(1, root.drawSize)
    readonly property real stroke: Math.max(2, 2 * root.k)
    // The heavier weight a few glyphs use keeps its 3:2 relationship.
    readonly property real strokeW: root.stroke * 1.5

    implicitWidth: drawSize
    implicitHeight: drawSize

    // ── as one shared image ──────────────────────────────────────────────
    function hex(c) {
        const h = v => ("0" + Math.round(v * 255).toString(16)).slice(-2);
        return "#" + h(c.r) + h(c.g) + h(c.b);
    }
    function paint(c, kind) {
        return kind + '="' + hex(c) + '"' + (c.a < 0.999 ? " " + kind + '-opacity="' + c.a.toFixed(3) + '"' : "");
    }
    readonly property string svgSource: {
        if (!root.asImage) return "";
        const sp = root.spec;
        const ink = root.inkColor, acc = root.accent;
        const line = (d, c, w) => d ? '<path d="' + d + '" fill="none" ' + paint(c, "stroke") + ' stroke-width="' + w
                                      + '" stroke-linecap="round" stroke-linejoin="round"/>' : "";
        const area = (d, c) => d ? '<path d="' + d + '" ' + paint(c, "fill") + ' fill-rule="evenodd"/>' : "";
        let out = '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24">'
            + area(sp.fillInk, ink) + area(sp.fill, acc)
            + line(sp.ink, ink, root.stroke) + line(sp.acc, acc, root.stroke)
            + line(sp.inkW, ink, root.strokeW) + line(sp.accW, acc, root.strokeW);
        for (const d of (sp.dots || []))
            out += '<circle cx="' + d.cx + '" cy="' + d.cy + '" r="' + d.r + '" ' + paint(d.c === "acc" ? acc : ink, "fill") + '/>';
        return "data:image/svg+xml;utf8," + encodeURIComponent(out + "</svg>");
    }
    // Drawn at exactly the window's own pixels, and shown one image pixel
    // to one screen pixel.
    //
    // Qt renders an SVG at the screen's resolution only when its URL ends
    // in "svg", which a data: URL never does (it ends in %3E). So with
    // sourceSize at the logical size, every glyph was rasterised at 1x and
    // then stretched by the display's scale (1.5, 2…) with linear
    // filtering: soft edges on every icon in the shell. Now the image is
    // made at size × the window's real scale (QsWindow: fractional scales
    // included, which Screen's integer one is not) and the item is sized so
    // that's one-to-one.
    //
    // Sampled smoothly, not nearest. Nearest is exact only at a scale of
    // exactly 1, and icons are often under one that isn't: the dock's tiles
    // lift to 1.12 under the pointer and their springs settle a hair off 1.
    // There nearest drops or doubles a row of pixels, and strokes come out
    // uneven and jagged. Smooth at one-to-one is as sharp as nearest.
    readonly property real dpr: {
        const w = QsWindow.window;
        const r = w && w.devicePixelRatio > 0 ? w.devicePixelRatio : Screen.devicePixelRatio;
        return r > 0 ? r : 1;
    }
    readonly property int texPx: Math.max(1, Math.round(root.drawSize * root.dpr))

    // On the screen's pixel grid. At a fractional scale (5/3 on a 2560×1600
    // panel at 1.67) a position that's whole in the layout is usually a
    // third or two-thirds of the way between real pixels, and an image
    // drawn there is spread across two of them: soft, however sharp the
    // image is. So the glyph is nudged by under a pixel to land on one.
    //
    // Worked out where the icon is placed, not every frame: when it's
    // made, shown, moved or resized within its parent, when the scale
    // changes, and once more a moment after it's shown, for a panel that
    // slides in. Something still moving is soft only while it moves.
    property real snapX: 0
    property real snapY: 0
    readonly property real imgBase: (root.drawSize - root.texPx / root.dpr) / 2
    function resnap() {
        if (!root.asImage || !root.visible || !(root.dpr > 0)) return;
        const p = root.mapToItem(null, root.imgBase, root.imgBase);
        if (!p) return;
        const dx = Math.round(p.x * root.dpr) / root.dpr - p.x;
        const dy = Math.round(p.y * root.dpr) / root.dpr - p.y;
        if (Math.abs(dx - root.snapX) > 0.001) root.snapX = dx;
        if (Math.abs(dy - root.snapY) > 0.001) root.snapY = dy;
    }
    function resnapSoon() { Qt.callLater(root.resnap); }
    onXChanged: resnapSoon()
    onYChanged: resnapSoon()
    onDrawSizeChanged: resnapSoon()
    onDprChanged: resnapSoon()
    onVisibleChanged: if (visible) { resnapSoon(); settle.restart(); }
    Component.onCompleted: { resnapSoon(); settle.restart(); }
    Timer { id: settle; interval: 450; onTriggered: root.resnap() }
    // Its parent and the one above that moving it along (the dock
    // re-centring as apps open, a row re-flowing) without its own x
    // changing.
    Connections {
        target: root.parent
        ignoreUnknownSignals: true
        function onXChanged() { root.resnapSoon(); }
        function onYChanged() { root.resnapSoon(); }
        function onWidthChanged() { root.resnapSoon(); }
        function onHeightChanged() { root.resnapSoon(); }
    }
    Connections {
        target: root.parent ? root.parent.parent : null
        ignoreUnknownSignals: true
        function onXChanged() { root.resnapSoon(); }
        function onYChanged() { root.resnapSoon(); }
        function onWidthChanged() { root.resnapSoon(); }
        function onHeightChanged() { root.resnapSoon(); }
    }

    Image {
        visible: root.asImage
        width: root.texPx / root.dpr
        height: root.texPx / root.dpr
        x: root.imgBase + root.snapX
        y: root.imgBase + root.snapY
        source: root.svgSource
        sourceSize: Qt.size(root.texPx, root.texPx)
        cache: true
        smooth: true
        mipmap: false
        asynchronous: false
        onStatusChanged: if (status === Image.Error) root.imageFailed = true
    }

    // ── as vector shapes ─────────────────────────────────────────────────
    // Only built when they are what is drawn.
    Loader {
        active: !root.asImage
        sourceComponent: shapes
    }
    Component {
        id: shapes
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
            // An invalid size, not undefined, for the case where the layer
            // is off.
            //
            // textureSize is a QSize and undefined is not one: assigning it
            // printed a warning per glyph per frame, which on a desktop with
            // a dock, a launcher and a settings window open is a wall of
            // them. Qt's own default for this property is a default-
            // constructed QSize, which is invalid and means "use the item's
            // size" — Qt.size(-1, -1) is that, said out loud.
            layer.textureSize: root.multisample
                               ? Qt.size(Math.ceil(width * 2), Math.ceil(height * 2))
                               : Qt.size(-1, -1)

            // Filled regions. Two of them, because a fill used to be accent
            // and nothing else — which was fine while the only one in the
            // pack was palette's half-disc, and wrong the moment a logo
            // traced from an image wanted to be a plain ink silhouette.
            //
            // Odd-even, stated rather than left to the default: a traced
            // shape carries its holes as further subpaths, and under a
            // winding rule the hole in a letter O fills in.
            Shape {
                visible: !!root.spec.fillInk
                anchors.fill: parent
                preferredRendererType: root.renderer
                ShapePath {
                    fillColor: root.inkColor
                    fillRule: ShapePath.OddEvenFill
                    strokeWidth: 0
                    strokeColor: "transparent"
                    PathSvg { path: root.spec.fillInk || "" }
                }
            }

            Shape {
                visible: !!root.spec.fill
                anchors.fill: parent
                preferredRendererType: root.renderer
                ShapePath {
                    fillColor: root.accent
                    fillRule: ShapePath.OddEvenFill
                    strokeWidth: 0
                    strokeColor: "transparent"
                    PathSvg { path: root.spec.fill || "" }
                }
            }

            Shape {
                visible: !!root.spec.ink
                anchors.fill: parent
                preferredRendererType: root.renderer
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
                preferredRendererType: root.renderer
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
                preferredRendererType: root.renderer
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
                preferredRendererType: root.renderer
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
}
