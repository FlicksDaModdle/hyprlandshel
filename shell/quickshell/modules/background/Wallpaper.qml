import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"

// The desktop ground. A real image (Settings → Wallpaper → Image), a
// contour map (Topographic, Topography.qml) or, by default, the mockup's
// tinted gradient: a diagonal base wash with two radial pools over it,
// retuned per theme and per tint choice.
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
        readonly property bool useTopo: !useImage && Config.Appearance.wallpaperStyle === "topo"
        readonly property bool useAnimated: !useImage && !useTopo && Config.Appearance.wallpaperStyle !== "gradient"
        readonly property bool useGradient: !useImage && !useTopo && !useAnimated

        // A still of what is drawn here, for the boot menu
        // (services/BootTheme.qml): asked of the main display's surface.
        Connections {
            target: Services.BootTheme
            function onGrabRequest(screenName, path) {
                if (!win.modelData || String(win.modelData.name) !== screenName) return;
                // The ground being drawn, at the screen's own pixels. (Not
                // the window's contentItem: it isn't QML's, and can't be
                // grabbed.)
                const item = win.useTopo ? topoGround : win.useAnimated ? animatedGround : gradientGround;
                const dpr = win.modelData.devicePixelRatio || 1;
                const ok = item.grabToImage(result => {
                    Services.BootTheme.grabbed(result.saveToFile(path) ? path : "");
                }, Qt.size(Math.round(win.width * dpr), Math.round(win.height * dpr)));
                if (!ok) Services.BootTheme.grabbed("");
            }
        }

        // ── the theme's gradient ──────────────────────────────────────────
        GradientGround {
            id: gradientGround
            anchors.fill: parent
            visible: win.useGradient
        }

        // Only loaded while it is the one shown.
        Loader {
            id: topoGround
            anchors.fill: parent
            active: win.useTopo
            sourceComponent: Topography { screen: win.modelData; motion: Services.WallMotion }
        }

        Loader {
            id: animatedGround
            anchors.fill: parent
            active: win.useAnimated
            sourceComponent: AnimatedWallpaper { screen: win.modelData; motion: Services.WallMotion }
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

        // ── coming in ─────────────────────────────────────────────────────
        // A new session starts dark — Hyprland's own background, the colour
        // under everything (shell/hypr: misc.background_color) — and the
        // wallpaper comes up out of it. A reload of the shell starts clear.
        Rectangle {
            id: curtain
            anchors.fill: parent
            color: "#201e1d"
            opacity: 0
            visible: opacity > 0.002
            NumberAnimation on opacity {
                id: lift
                running: false
                from: 1
                to: 0
                duration: 650
                easing.type: Easing.OutCubic
            }
            Component.onCompleted: {
                if (!Config.UiState.firstStart()) return;
                opacity = 1;
                // A beat for the picture to load before it's shown.
                liftSoon.start();
            }
            Timer { id: liftSoon; interval: 180; onTriggered: lift.start() }
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
