import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services

// The desktop ground. Either a real image (Settings → Appearance →
// Wallpaper) or, by default, the mockup's tinted gradient: a diagonal base
// wash with two radial pools over it, retuned per theme and per tint choice.
//
// A live wallpaper (Services.LiveWallpaper) is its own program's surface on
// the layer above this one; this stays underneath it as what shows while it
// loads and what comes back if it stops.
//
// Also the desktop's own hit surface — right-clicking bare desktop opens the
// shell's context menu, and left-clicking dismisses whatever panel is open.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: win
        required property var modelData

        // Variants applies modelData after this binding is first evaluated,
        // so it sees undefined once on the way up. null is the same thing to
        // setScreen (use the default) and doesn't warn; the binding
        // re-evaluates to the real screen the moment modelData lands.
        screen: modelData ?? null
        // ...and nothing is drawn until it is a real one. `?? null` means
        // "the default screen" to setScreen, so during an output change —
        // plugging a monitor in, or changing a scale, which makes Hyprland
        // re-enumerate — a surface whose modelData has momentarily gone
        // would land on the default output instead. Two bars on one monitor
        // is what that looks like from the outside.
        readonly property bool hasScreen: !!modelData
        visible: hasScreen
        // Covers the whole output, exclusive zones and all.
        //
        // An always-on dock reserves its strip, and a layer surface that
        // respects that reservation gets shrunk by it — so the wallpaper
        // stopped at the dock and what showed behind and beside it was the
        // compositor's own background, not the desktop. The same shrinking
        // moved the launcher's bottom edge up off the screen edge, which is
        // the one place it must stay anchored, and took its click-away
        // target with it: the desktop beside the dock stopped dismissing
        // it. Reserving space is for *windows*, not for the shell's own
        // full-screen surfaces.
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        exclusiveZone: 0

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        WlrLayershell.namespace: "quickshell:wallpaper"
        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        readonly property var tint: Config.Appearance.tintSpec
        // Nothing here draws differently for it, but reading it is what
        // starts the service — singletons are built on first use, and this
        // is the one surface every session has.
        readonly property bool live: Services.LiveWallpaper.enabled
        readonly property bool useImage: Config.Appearance.wallpaper !== ""

        // String tints promoted to color values, so the radial washes can
        // fade their own hue out to alpha 0 instead of to grey.
        readonly property color baseA: tint.a
        readonly property color baseB: tint.b
        readonly property color pool1: tint.g1 !== "" ? tint.g1 : tint.a
        readonly property color pool2: tint.g2 !== "" ? tint.g2 : tint.a

        function fade(c) { return Qt.rgba(c.r, c.g, c.b, 0); }

        // ── base wash ─────────────────────────────────────────────────────
        Shape {
            anchors.fill: parent
            visible: !win.useImage
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: 0
                strokeColor: "transparent"
                fillGradient: LinearGradient {
                    // CSS `linear-gradient(168deg, a, b)`: near-vertical,
                    // leaning right as it descends.
                    x1: 0; y1: 0
                    x2: win.width * 0.21; y2: win.height
                    GradientStop { position: 0; color: win.baseA }
                    GradientStop { position: 1; color: win.baseB }
                }
                startX: 0; startY: 0
                PathLine { x: win.width; y: 0 }
                PathLine { x: win.width; y: win.height }
                PathLine { x: 0; y: win.height }
                PathLine { x: 0; y: 0 }
            }
        }

        // ── upper-right pool ──────────────────────────────────────────────
        Shape {
            anchors.fill: parent
            visible: !win.useImage && win.tint.g1 !== ""
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: 0
                strokeColor: "transparent"
                fillGradient: RadialGradient {
                    centerX: win.width * 0.78; centerY: win.height * 0.04
                    centerRadius: win.width * 0.62
                    focalX: centerX; focalY: centerY
                    GradientStop { position: 0; color: win.pool1 }
                    GradientStop { position: 0.58; color: win.fade(win.pool1) }
                }
                startX: 0; startY: 0
                PathLine { x: win.width; y: 0 }
                PathLine { x: win.width; y: win.height }
                PathLine { x: 0; y: win.height }
                PathLine { x: 0; y: 0 }
            }
        }

        // ── lower-left pool ───────────────────────────────────────────────
        Shape {
            anchors.fill: parent
            visible: !win.useImage && win.tint.g2 !== ""
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                strokeWidth: 0
                strokeColor: "transparent"
                fillGradient: RadialGradient {
                    centerX: win.width * 0.04; centerY: win.height * 0.96
                    centerRadius: win.width * 0.55
                    focalX: centerX; focalY: centerY
                    GradientStop { position: 0; color: win.pool2 }
                    GradientStop { position: 0.62; color: win.fade(win.pool2) }
                }
                startX: 0; startY: 0
                PathLine { x: win.width; y: 0 }
                PathLine { x: win.width; y: win.height }
                PathLine { x: 0; y: win.height }
                PathLine { x: 0; y: 0 }
            }
        }

        Image {
            anchors.fill: parent
            visible: win.useImage
            source: win.useImage ? "file://" + Config.Appearance.wallpaper : ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            // Very large wallpapers are downscaled on load rather than held
            // at full resolution per monitor.
            sourceSize.width: win.width
            sourceSize.height: win.height
        }

        // ── desktop interactions ──────────────────────────────────────────
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    Config.UiState.openDesktopMenu(mouse.x, mouse.y);
                } else {
                    Config.UiState.closeAll();
                }
            }
        }
    }
}
