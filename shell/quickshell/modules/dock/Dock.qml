import QtQuick
import Quickshell
import Quickshell.Wayland
import "../icons"
import "../../config" as Config

// The floating dock: Start (launcher) + task view, pinned apps (real
// running/active state from the compositor's toplevel list), unpinned but
// currently-running apps, then Settings + show-desktop. Bottom or left,
// matching Config.Appearance.dockPosition, with optional auto-hide.
PanelWindow {
    id: dock

    readonly property bool isLeft: Config.Appearance.dockPosition === "left"
    readonly property real tileSize: Config.Appearance.dockTileSize
    readonly property real iconSize: Config.Appearance.dockIconSize
    readonly property real glyphSize: Config.Appearance.dockGlyphSize
    readonly property real padH: Config.Appearance.dockPadH
    readonly property real padV: Config.Appearance.dockPadV
    readonly property real tileSpacing: Config.Appearance.dockTileSpacing
    readonly property real edgeGap: Config.Appearance.dockEdgeGap
    readonly property real tooltipRoom: Config.Appearance.dockTooltipRoom // headroom reserved for tiles' hover tooltips

    readonly property real panelBreadth: Config.Appearance.dockPanelBreadth // thickness of the pill on the short axis

    readonly property bool revealed: !Config.Appearance.dockAutoHide || windowHover.hovered || Config.UiState.launcherOpen

    // The window's short-axis size only needs to fit the *revealed* pill
    // (tooltip headroom + pill + edge gap) — the hidden position is meant
    // to fall outside these bounds entirely, which is what makes it
    // disappear (nothing renders past the wayland surface's own edge).
    // Sizing the window to also contain the hidden position was the bug:
    // it left a big gap between the revealed pill and the real screen
    // edge, so the dock sat far above the bottom instead of hugging it.
    readonly property real windowBreadth: tooltipRoom + panelBreadth + edgeGap

    // slide position of the pill along the main axis, within that window.
    readonly property real pillShownPos: tooltipRoom
    readonly property real pillHiddenPos: tooltipRoom + panelBreadth + 20
    property real pillPos: revealed ? pillShownPos : pillHiddenPos
    Behavior on pillPos { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }

    color: "transparent"
    exclusiveZone: 0

    anchors.bottom: !isLeft
    anchors.left: isLeft
    anchors.top: false
    anchors.right: false

    margins.bottom: 0
    margins.left: 0

    implicitWidth: isLeft ? windowBreadth : pill.implicitWidth
    implicitHeight: isLeft ? pill.implicitHeight : windowBreadth

    WlrLayershell.namespace: "quickshell:dock"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    HoverHandler { id: windowHover }

    Item {
        id: content
        anchors.fill: parent

        Rectangle {
            id: pill
            radius: Config.Appearance.rDock
            color: Config.Appearance.panel
            border.width: 1
            border.color: Config.Appearance.edge

            x: dock.isLeft ? dock.pillPos : Math.round((content.width - width) / 2)
            y: dock.isLeft ? Math.round((content.height - height) / 2) : dock.pillPos

            implicitWidth: tiles.implicitWidth + dock.padH * 2
            implicitHeight: tiles.implicitHeight + dock.padV * 2

            Flow {
                id: tiles
                anchors.centerIn: parent
                flow: dock.isLeft ? Flow.TopToBottom : Flow.LeftToRight
                spacing: dock.tileSpacing

                // --- Start / launcher ------------------------------------------------
                Item {
                    id: startTile
                    width: dock.tileSize
                    height: dock.tileSize

                    readonly property bool open: Config.UiState.launcherOpen

                    Rectangle {
                        anchors.fill: parent
                        radius: Config.Appearance.rTile
                        color: startTile.open ? Config.Appearance.accent : Config.Appearance.sel
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    MonoIcon {
                        anchors.centerIn: parent
                        name: "grid"
                        size: dock.iconSize
                        inkColor: startTile.open ? Config.Appearance.onAccent : Config.Appearance.ink
                        accentColor: startTile.open ? Config.Appearance.onAccent : Config.Appearance.accent
                    }

                    Rectangle {
                        visible: startHover.hovered && !startTile.open
                        opacity: visible ? 1 : 0
                        anchors.bottom: parent.top
                        anchors.bottomMargin: 12
                        // Left-aligned, not centered: Start is always the
                        // dock's leftmost tile, and the dock window is
                        // sized tight to the pill's content — a centered
                        // tooltip here would extend past the window's own
                        // left edge and get clipped (nothing renders
                        // outside the wayland surface bounds).
                        anchors.left: parent.left
                        radius: Config.Appearance.rSm
                        color: Config.Appearance.sheet
                        border.width: 1
                        border.color: Config.Appearance.edge
                        height: 28
                        width: startLabel.implicitWidth + 20
                        Text {
                            id: startLabel
                            anchors.centerIn: parent
                            text: "Start — super"
                            color: Config.Appearance.ink
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            font.family: "Inter"
                        }
                    }

                    HoverHandler { id: startHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: Config.UiState.toggleLauncher() }
                }

                // --- Task view / overview --------------------------------------------
                DockTile {
                    width: dock.tileSize
                    height: dock.tileSize
                    tileSize: dock.tileSize
                    iconSize: dock.glyphSize
                    iconName: "panelsTopLeft"
                    label: "Task view"
                    showTooltip: false
                    active: Config.UiState.overviewOpen
                    onActivated: Config.UiState.toggleOverview()
                }

                // Flow top-aligns children of unequal height, so give the
                // divider a tile-sized box and center the actual line in it.
                Item {
                    width: dock.isLeft ? dock.tileSize : 1
                    height: dock.isLeft ? 1 : dock.tileSize
                    Rectangle {
                        anchors.centerIn: parent
                        width: dock.isLeft ? 26 : 1
                        height: dock.isLeft ? 1 : 26
                        color: Config.Appearance.div
                    }
                }

                // --- Pinned apps -------------------------------------------------------
                Repeater {
                    model: Config.Apps.pinned

                    DockTile {
                        required property var modelData

                        readonly property var matches: dock.toplevelsFor(modelData)
                        readonly property bool isRunning: matches.length > 0
                        readonly property bool isActive: dock.isActiveApp(modelData)

                        width: implicitWidth
                        height: dock.tileSize
                        tileSize: dock.tileSize
                        iconSize: dock.iconSize
                        iconName: modelData.icon
                        label: modelData.label
                        running: isRunning
                        windowCount: matches.length
                        active: isActive
                        showLabel: isActive && Config.Appearance.dockLabels && !dock.isLeft
                        subtitle: isRunning ? (matches.length > 1 ? matches.length + " windows" : "1 window") : "not running"
                        onActivated: dock.launchOrFocus(modelData)
                    }
                }

                // --- Unpinned but running ------------------------------------------------
                Item {
                    visible: dock.unpinnedRunning.length > 0
                    width: dock.isLeft ? dock.tileSize : 1
                    height: dock.isLeft ? 1 : dock.tileSize
                    Rectangle {
                        anchors.centerIn: parent
                        width: dock.isLeft ? 26 : 1
                        height: dock.isLeft ? 1 : 26
                        color: Config.Appearance.div
                    }
                }

                Repeater {
                    model: dock.unpinnedRunning

                    DockTile {
                        required property var modelData

                        width: dock.tileSize
                        height: dock.tileSize
                        tileSize: dock.tileSize
                        iconSize: dock.iconSize
                        iconName: "cpu" // generic fallback glyph — see IconPaths.js
                        label: modelData.appId || "Unknown"
                        subtitle: "not pinned"
                        running: true
                        windowCount: 1
                        showPips: false
                        active: modelData.activated
                        onActivated: modelData.activate()

                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 3
                            width: 9
                            height: 2.5
                            radius: 1.25
                            color: Config.Appearance.ink3
                        }
                    }
                }

                Item {
                    width: dock.isLeft ? dock.tileSize : 1
                    height: dock.isLeft ? 1 : dock.tileSize
                    Rectangle {
                        anchors.centerIn: parent
                        width: dock.isLeft ? 26 : 1
                        height: dock.isLeft ? 1 : 26
                        color: Config.Appearance.div
                    }
                }

                // --- Settings shortcut + show desktop --------------------------------
                DockTile {
                    width: dock.tileSize
                    height: dock.tileSize
                    tileSize: dock.tileSize
                    iconSize: dock.glyphSize
                    iconName: "settings"
                    label: "Settings"
                    showTooltip: false
                    onActivated: Config.UiState.settingsOpen = !Config.UiState.settingsOpen
                }

                DockTile {
                    width: dock.tileSize
                    height: dock.tileSize
                    tileSize: dock.tileSize
                    iconSize: dock.glyphSize
                    iconName: "minus"
                    label: "Show desktop"
                    showTooltip: false
                    // TODO: Hyprland has no native "minimize all" dispatcher;
                    // wire this up once there's a helper script/IPC target for it.
                    onActivated: console.log("[dock] show desktop — not implemented yet")
                }
            }
        }
    }

    // --- app <-> toplevel matching -------------------------------------------

    function toplevelsFor(app) {
        return ToplevelManager.toplevels.values.filter(t => app.match.test(t.appId || ""));
    }

    function isActiveApp(app) {
        const a = ToplevelManager.activeToplevel;
        return !!a && app.match.test(a.appId || "");
    }

    readonly property var unpinnedRunning: ToplevelManager.toplevels.values.filter(
        t => !Config.Apps.pinned.some(app => app.match.test(t.appId || ""))
    )

    function launchOrFocus(app) {
        const matches = toplevelsFor(app);
        if (matches.length > 0) {
            const target = matches.find(t => t.activated) || matches[0];
            target.activate();
            return;
        }
        if (app.key === "appSettings") {
            Config.UiState.settingsOpen = !Config.UiState.settingsOpen;
            return;
        }
        if (app.exec.length > 0) {
            Quickshell.execDetached(app.exec);
        }
    }
}
