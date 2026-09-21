pragma Singleton
import QtQuick
import Quickshell

// Design tokens, ported 1:1 from the Claude Design mockup's CSS custom
// properties ([data-shell] / [data-shell="dark"] in Hyprshell Live.dc.html).
// Every module reads colors/radii/dock geometry from here so the shell
// stays one visually consistent system as new pieces get built.
//
// This intentionally has no persistence yet (no theme.json read/write) —
// that lands with the Settings module, which is what actually edits these
// values in the mockup. For now they're sensible fixed defaults.
Singleton {
    id: root

    property bool dark: false

    // --- accent -------------------------------------------------------
    readonly property color accentLight: "#ec3013"
    readonly property color accentDark: "#ff563c"
    readonly property color accent: dark ? accentDark : accentLight
    readonly property color onAccent: dark ? "#2d2b2b" : "#fff2ef"

    // --- neutrals -------------------------------------------------------
    readonly property color ground: dark ? "#201e1d" : "#f3f2f2"
    readonly property color surface: dark ? "#2d2b2b" : "#eae9e9"
    readonly property color ink: dark ? "#f8f4f4" : "#201e1d"
    readonly property color ink2: dark ? "#bab6b6" : "#605d5d"
    readonly property color ink3: dark ? "#8a8686" : "#6b6868"

    readonly property color edge: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.16) : Qt.rgba(0.125, 0.118, 0.114, 0.14)
    readonly property color rule: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.10) : Qt.rgba(0.125, 0.118, 0.114, 0.09)
    readonly property color div: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.22) : Qt.rgba(0.125, 0.118, 0.114, 0.18)
    // Fully opaque by request — dock and launcher shouldn't show desktop
    // content through them (the mockup's translucency assumed real
    // compositor blur-behind, which isn't guaranteed to be set up).
    readonly property color panel: dark ? Qt.rgba(0.114, 0.106, 0.102, 1) : Qt.rgba(0.973, 0.969, 0.969, 1)
    readonly property color sheet: dark ? Qt.rgba(0.137, 0.129, 0.125, 0.88) : Qt.rgba(0.980, 0.976, 0.976, 0.9)
    readonly property color hover: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.09) : Qt.rgba(0.125, 0.118, 0.114, 0.07)
    readonly property color sel: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.14) : Qt.rgba(0.125, 0.118, 0.114, 0.10)
    readonly property color gloss: dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.6)

    readonly property color seam: Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.24 : 0.18)

    // --- radii, one family scaled by `roundingPct` (0 = square, 100 = default) --
    property real roundingPct: 100
    readonly property real rf: roundingPct / 100
    readonly property real rSm: Math.round(9 * rf)
    readonly property real r: Math.round(14 * rf)
    readonly property real rWin: r
    readonly property real rPanel: r
    readonly property real rTile: r
    readonly property real rDock: r
    readonly property real rCap: r

    property real blurRadius: 20
    property real uiScale: 1.0

    // --- dock ------------------------------------------------------------
    // "Position" / "Dock size" / "Icon size" / "Label for active app" /
    // "Auto-hide" rows in the mockup's Settings → Dock pane.
    property string dockPosition: "bottom" // "bottom" | "left"
    property real dockTileSize: 42         // 34-58, tile edge length
    property real dockIconPct: 50          // 30-72, glyph scale inside the tile
    property bool dockLabels: true
    property bool dockAutoHide: false

    readonly property real dockIconSize: Math.round(dockTileSize * dockIconPct / 100)
    readonly property real dockGlyphSize: Math.round(dockIconSize * 0.82)

    // Shared with Dock.qml's own layout math and read by other modules
    // (Launcher today) that need to position themselves relative to the
    // dock without re-deriving or duplicating these numbers.
    readonly property real dockPadH: 7
    readonly property real dockPadV: 5
    readonly property real dockTileSpacing: 3
    readonly property real dockEdgeGap: 12
    readonly property real dockTooltipRoom: 46
    readonly property real dockPanelBreadth: dockTileSize + dockPadV * 2
}
