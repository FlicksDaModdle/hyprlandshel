import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The floating dock: Start (launcher) and overview, pinned apps with real
// running/focused state from the compositor, any unpinned app that happens
// to be running, then Settings and show-desktop.
//
// Bottom or left per Settings → Dock, with optional auto-hide. One per
// monitor, like the bar.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: dock
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
        color: "transparent"
        // Normal, explicitly. Auto reserves space for the whole surface
        // when exactly three anchors are set, and this surface is anchored
        // on three and is much taller than the dock — it carries the
        // tooltip headroom above the pill. Left on Auto it would reserve
        // all of that, pushing every window and every other layer down by
        // a tooltip's height for no reason anyone could see.
        exclusionMode: ExclusionMode.Normal

        // Windows are kept clear of the dock when it is always there, and
        // not when it hides — an auto-hiding dock that still reserved its
        // strip would be a band of unusable desktop with nothing in it.
        //
        // Only the pill and its edge gap: the tooltip headroom above it is
        // part of the surface but not part of the dock, and reserving that
        // too would push every window down by a tooltip's height.
        exclusiveZone: Config.Appearance.dockAutoHide
                       ? 0
                       // The pill, plus a gap on each side of it, less
                       // whatever Hyprland is already insetting windows by.
                       //
                       // Twice the gap alone was still uneven, because a
                       // tiled window does not sit on the edge of the
                       // usable area — general:gaps_out holds it off by
                       // that much again. So the gap above came out as
                       // edgeGap + gaps_out against edgeGap below, and grew
                       // wider the more gaps you ran. Subtracting it here
                       // hands that part of the job back to the compositor,
                       // which is already doing it.
                       //
                       // Floored at the pill itself: with gaps wider than
                       // twice the dock's own spacing there is nothing left
                       // to give back, and a window is never allowed to
                       // reach the pill.
                       : Math.round(Math.max(panelBreadth,
                                    panelBreadth + edgeGap * 2 - gapsOut))
        visible: hasScreen && !Config.UiState.locked

        readonly property bool isLeft: Config.Appearance.dockLeft
        readonly property real tileSize: Config.Appearance.dockTileSize
        readonly property real iconSize: Config.Appearance.dockIconSize
        readonly property real padH: Config.Appearance.dockPadH
        readonly property real padV: Config.Appearance.dockPadV
        readonly property real tileSpacing: Config.Appearance.dockTileSpacing
        readonly property real edgeGap: Config.Appearance.dockEdgeGap
        // The shell owns this and writes it to Hyprland (Settings → Shell →
        // Hyprland → Outer gaps), so reading the preference is reading what
        // the compositor is actually doing.
        readonly property real gapsOut: Math.max(0, Config.Appearance.gapsOut)
        // Headroom reserved above the pill for tiles' hover tooltips.
        readonly property real tooltipRoom: Config.Appearance.dockTooltipRoom
        readonly property real panelBreadth: Config.Appearance.dockPanelBreadth

        // Is this the screen the user is actually on? The launcher is global
        // state, so without this every dock on every monitor slid out when
        // the start menu opened — including the one you weren't looking at.
        readonly property bool onFocusedScreen:
            Services.Compositor.isFocusedScreen(modelData)

        // Auto-hide with hysteresis.
        //
        // The naive version — reveal while hovered — fights itself: the
        // pointer reaches the edge strip, the pill slides out from under it,
        // the pointer is no longer over the strip, and it slides back. Then
        // moving *up* into the revealed pill crosses the gap where neither
        // is true and it retracts under you. That is the glitchiness.
        //
        // So: hovering the surface latches it open, and it only closes after
        // the pointer has been away for a moment. Nothing that happens while
        // the pointer is inside can retract it.
        property bool hoverLatch: false

        // The launcher shrinking back into the pill has to land on a pill
        // that is still there. With auto-hide on, closing the launcher
        // used to drop the last reason to be out, so the dock slid away
        // underneath the collapse and Escape looked like dismissing the
        // whole thing rather than putting it back. It stays out for a
        // moment afterwards, which is long enough to see what happened
        // and to reach it.
        property bool afterLauncher: false
        readonly property bool launcherHere:
            Config.UiState.launcherOpen && onFocusedScreen
        onLauncherHereChanged: {
            if (launcherHere) { afterLauncher = false; afterLauncherHold.stop(); }
            else if (visible) { afterLauncher = true; afterLauncherHold.restart(); }
        }
        Timer {
            id: afterLauncherHold
            interval: 1400
            onTriggered: dock.afterLauncher = false
        }

        readonly property bool revealed: !Config.Appearance.dockAutoHide
                                         || hoverLatch
                                         || launcherHere
                                         || afterLauncher

        onHoveredNowChanged: {
            if (hoveredNow) { hideDelay.stop(); hoverLatch = true; }
            else hideDelay.restart();
        }

        // The mask covers the whole surface while revealed, so the
        // window's own hover is enough — there is no untracked gap left
        // between the edge strip and the pill.
        readonly property bool hoveredNow: windowHover.hovered

        Timer {
            id: hideDelay
            interval: 420
            onTriggered: if (!dock.hoveredNow) dock.hoverLatch = false;
        }

        // The window's short-axis size only needs to fit the *revealed* pill
        // (tooltip headroom + pill + edge gap). The hidden position falls
        // outside those bounds on purpose — nothing renders past the Wayland
        // surface's own edge, and that's what makes it disappear.
        readonly property real windowBreadth: tooltipRoom + panelBreadth + edgeGap
        readonly property real pillShownPos: tooltipRoom
        readonly property real pillHiddenPos: tooltipRoom + panelBreadth + 20

        property real pillPos: revealed ? pillShownPos : pillHiddenPos
        Behavior on pillPos { NumberAnimation { duration: Config.Appearance.anim(260); easing.type: Easing.OutCubic } }

        // The surface spans the whole edge and the pill is centred inside
        // it, rather than the surface being cut to the pill.
        //
        // It used to be the pill's exact size, which meant every animation
        // that changes a tile's width — the active app's label sliding out,
        // or collapsing when you press show desktop — resized the Wayland
        // surface on every frame of it. Each of those is a round trip with
        // the compositor, so the label collapse was visibly coarser than
        // the tile animation driving it, and the surface's own right edge
        // showed as a square of unpainted space while it caught up. It also
        // left the last tile's hover fill flush against the boundary, where
        // it clipped.
        //
        // Nothing here needs the surface to be tight: input is masked to
        // the pill below, so the slack on either side stays click-through.
        // Bottom: pinned left, right and bottom, so the width is the
        // screen's and only the height is ours. Left: pinned top, bottom
        // and left, so the height is the screen's and only the width is.
        anchors.bottom: true
        anchors.left: true
        anchors.right: !isLeft
        anchors.top: isLeft

        implicitWidth: isLeft ? windowBreadth : 0
        implicitHeight: isLeft ? 0 : windowBreadth

        WlrLayershell.namespace: "quickshell:dock"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // Only the pill itself takes clicks; the tooltip headroom and edge
        // gap around it stay click-through so the desktop underneath is
        // still reachable.
        // While hidden, only a thin strip along the screen edge takes input,
        // so the desktop behind stays reachable. While revealed, the whole
        // surface does — otherwise the pointer crosses untracked empty space
        // between the strip and the pill, hover drops, and it retracts
        // mid-approach.
        // Revealed, this is the pill plus the room its tooltips need and a
        // margin either side, so the pointer can approach without hover
        // dropping in untracked space — but not the whole edge of the
        // screen, which is what "the whole surface" would now mean.
        // Hidden, it is the thin strip along the edge that brings it back,
        // and that does span the edge so the pointer finds it anywhere.
        readonly property real maskPad: 40
        mask: Region {
            x: dock.revealed && !dock.isLeft
               ? Math.max(0, Math.round(pill.x - dock.maskPad)) : 0
            y: dock.revealed
               ? (dock.isLeft ? Math.max(0, Math.round(pill.y - dock.maskPad)) : 0)
               : (dock.isLeft ? 0 : dock.height - 3)
            width: dock.revealed
                   ? (dock.isLeft ? dock.width
                                  : Math.ceil(pill.width + dock.maskPad * 2))
                   : (dock.isLeft ? 3 : dock.width)
            height: dock.revealed
                    ? (dock.isLeft ? Math.ceil(pill.height + dock.maskPad * 2)
                                   : dock.height)
                    : (dock.isLeft ? dock.height : 3)
        }

        HoverHandler { id: windowHover }

        // ── window/app state ──────────────────────────────────────────────
        readonly property var clients: Services.Compositor.clients
        readonly property string activeClass: Services.Compositor.activeClass

        function windowsFor(app) {
            return clients.filter(c => app.match.test(c.cls || ""));
        }

        function isActiveApp(app) {
            return activeClass !== "" && app.match.test(activeClass);
        }

        // Apps with windows open that aren't pinned, so they still show up
        // in the dock while they're running.
        readonly property var unpinnedApps: {
            const seen = ({});
            const out = [];
            for (const c of clients) {
                const cls = c.cls || "";
                if (!cls || seen[cls]) continue;
                if (Config.Apps.pinnedFor(cls)) continue;
                seen[cls] = true;
                out.push({
                    cls: cls,
                    label: Config.Apps.labelFor(cls),
                    icon: Config.Apps.iconFor(cls),
                    windows: clients.filter(x => x.cls === cls)
                });
            }
            return out;
        }

        function launchOrFocus(app) {
            const wins = windowsFor(app);
            if (wins.length > 0) {
                // Already focused with more than one window: cycle.
                const at = wins.findIndex(c => c.address === Services.Compositor.activeAddress);
                const next = at >= 0 ? wins[(at + 1) % wins.length] : wins[0];
                Services.Compositor.focusClient(next.address);
                return;
            }
            if (Config.Apps.isShellTile(app.key)) {
                Services.Commands.run(Config.Apps.shellTiles[app.key]);
                return;
            }
            if (app.exec && app.exec.length > 0) Quickshell.execDetached(app.exec);
        }

        // The menu is drawn on the panel-layer surface, which covers the whole
    // screen, so the tile's position has to be given in screen coordinates.
    // A layer-shell window has no meaningful x/y of its own, so they are
    // derived from how this one is anchored: bottom-centred, or left-centred
    // when the dock is on the left edge.
    function openTileMenu(tile, key, cls, label, icon) {
        const local = tile.mapToItem(null, tile.width / 2, 0);
        const sw = dock.screen ? dock.screen.width : dock.width;
        const sh = dock.screen ? dock.screen.height : dock.height;
        const originX = dock.isLeft ? 0 : Math.round((sw - dock.width) / 2);
        const originY = dock.isLeft ? Math.round((sh - dock.height) / 2)
                                    : sh - dock.height;
        Config.UiState.openAppMenu(originX + local.x, originY + local.y,
                                   key, cls, label, icon);
    }

    function launchNew(app) {
            if (Config.Apps.isShellTile(app.key)) {
                Services.Commands.run(Config.Apps.shellTiles[app.key]);
                return;
            }
            if (app.exec && app.exec.length > 0) Quickshell.execDetached(app.exec);
        }

        // ── pill ──────────────────────────────────────────────────────────
        Rectangle {
            id: pill
            radius: Config.Appearance.rDock
            color: Config.Appearance.panel
            border.width: 1
            border.color: Config.Appearance.edge

            x: dock.isLeft ? dock.pillPos : Math.round((dock.width - width) / 2)
            y: dock.isLeft ? Math.round((dock.height - height) / 2) : dock.pillPos

            implicitWidth: (dock.isLeft ? tiles.implicitWidth : tiles.implicitWidth) + dock.padH * 2
            implicitHeight: tiles.implicitHeight + dock.padV * 2

            // The launcher grows out of this shape, so it has to know it.
            // Only the focused screen's dock reports, or two monitors would
            // take turns overwriting each other.
            Binding {
                target: Config.UiState
                property: "dockPillWidth"
                value: pill.implicitWidth
                when: dock.onFocusedScreen
                restoreMode: Binding.RestoreNone
            }
            Binding {
                target: Config.UiState
                property: "dockPillHeight"
                value: pill.implicitHeight
                when: dock.onFocusedScreen
                restoreMode: Binding.RestoreNone
            }

            // While the launcher is out, it *is* this pill — it starts at
            // exactly this rectangle and grows. Two of them on screen at
            // once would give the trick away, so this one steps aside.
            opacity: (Config.Appearance.launcherMorph
                      && Config.UiState.launcherOpen && dock.onFocusedScreen) ? 0 : 1
            visible: opacity > 0.01
            Behavior on opacity { NumberAnimation { duration: Config.Appearance.anim(90) } }

            // The mockup's `inset 0 1px 0 var(--gloss)` reads as a soft
            // highlight on a translucent panel over a darker backdrop. Drawn
            // as a literal 1px line on a light dock it is just a white stripe
            // along the top edge, so it is left out.

            Flow {
                id: tiles
                anchors.centerIn: parent
                flow: dock.isLeft ? Flow.TopToBottom : Flow.LeftToRight
                spacing: dock.tileSpacing

                // ── Start / launcher ──────────────────────────────────────
                DockTile {
                    width: dock.tileSize
                    height: dock.tileSize
                    tileSize: dock.tileSize
                    iconSize: dock.iconSize
                    iconName: "grid"
                    label: "Start"
                    subtitle: "super"
                    highlight: true
                    active: Config.UiState.launcherOpen
                    tooltipEdge: dock.isLeft ? Qt.RightEdge : Qt.TopEdge
                    // Start is always the dock's first tile and the pill is
                    // sized tight to its content, so a centered tooltip here
                    // would be clipped by the surface's own edge.
                    tooltipAlign: dock.isLeft ? Qt.AlignVCenter : Qt.AlignLeft
                    onActivated: Config.UiState.toggleLauncher()
                }

                // ── Overview ──────────────────────────────────────────────
                DockTile {
                    width: dock.tileSize
                    height: dock.tileSize
                    tileSize: dock.tileSize
                    iconSize: dock.iconSize
                    iconName: "panelsTopLeft"
                    label: "Overview"
                    subtitle: "super tab"
                    active: Config.UiState.overviewOpen
                    tooltipEdge: dock.isLeft ? Qt.RightEdge : Qt.TopEdge
                    onActivated: Config.UiState.toggleOverview()
                }

                DockDivider { isLeft: dock.isLeft; tileSize: dock.tileSize }

                // ── Pinned apps ───────────────────────────────────────────
                Repeater {
                    model: Config.Apps.pinned

                    DockTile {
                        id: pinnedTile
                        required property var modelData

                        readonly property var wins: dock.windowsFor(modelData)
                        readonly property bool isActive: dock.isActiveApp(modelData)

                        width: implicitWidth
                        height: dock.tileSize
                        tileSize: dock.tileSize
                        iconSize: dock.iconSize
                        iconName: modelData.icon
                        label: modelData.label
                        running: wins.length > 0
                        windowCount: wins.length
                        active: isActive
                        showLabel: isActive && Config.Appearance.dockLabels && !dock.isLeft
                        tooltipEdge: dock.isLeft ? Qt.RightEdge : Qt.TopEdge
                        subtitle: wins.length === 0 ? "not running"
                                : (wins.length === 1 ? "1 window" : wins.length + " windows")

                        onActivated: dock.launchOrFocus(modelData)
                        // Right click opens the tile's menu — new window,
                        // re-point it at a different application, or unpin.
                        // Opening a fresh instance moved in there, since it
                        // is one of three things you might want and no longer
                        // the only one.
                        onSecondaryActivated: dock.openTileMenu(
                            pinnedTile, modelData.key, "", modelData.label, modelData.icon)
                        onMiddleActivated: {
                            if (wins.length > 0) Services.Compositor.closeClient(wins[0].address);
                        }
                    }
                }

                // ── Unpinned but running ──────────────────────────────────
                DockDivider {
                    isLeft: dock.isLeft
                    tileSize: dock.tileSize
                    visible: dock.unpinnedApps.length > 0
                }

                Repeater {
                    model: dock.unpinnedApps

                    DockTile {
                        id: unpinnedTile
                        required property var modelData

                        readonly property bool isActive:
                            Services.Compositor.activeClass === modelData.cls

                        width: dock.tileSize
                        height: dock.tileSize
                        tileSize: dock.tileSize
                        iconSize: dock.iconSize
                        iconName: modelData.icon
                        label: modelData.label
                        subtitle: "not pinned"
                        running: true
                        windowCount: modelData.windows.length
                        active: isActive
                        tooltipEdge: dock.isLeft ? Qt.RightEdge : Qt.TopEdge

                        onActivated: {
                            const wins = modelData.windows;
                            const at = wins.findIndex(
                                c => c.address === Services.Compositor.activeAddress);
                            const next = at >= 0 ? wins[(at + 1) % wins.length] : wins[0];
                            Services.Compositor.focusClient(next.address);
                        }
                        onSecondaryActivated: dock.openTileMenu(
                            unpinnedTile, "", modelData.cls, modelData.label, modelData.icon)
                        onMiddleActivated:
                            Services.Compositor.closeClient(modelData.windows[0].address)
                    }
                }

                DockDivider { isLeft: dock.isLeft; tileSize: dock.tileSize }

                // ── Settings + show desktop ───────────────────────────────
                DockTile {
                    width: dock.tileSize
                    height: dock.tileSize
                    tileSize: dock.tileSize
                    iconSize: dock.iconSize
                    iconName: "settings"
                    label: "Settings"
                    active: Config.UiState.settingsOpen
                    tooltipEdge: dock.isLeft ? Qt.RightEdge : Qt.TopEdge
                    onActivated: Config.UiState.openSettings()
                }

                DockTile {
                    width: dock.tileSize
                    height: dock.tileSize
                    tileSize: dock.tileSize
                    iconSize: dock.iconSize
                    iconName: "minus"
                    label: "Show desktop"
                    subtitle: "toggle"
                    tooltipEdge: dock.isLeft ? Qt.RightEdge : Qt.TopEdge
                    // Hyprland has no minimise-all dispatcher; switching to a
                    // scratch workspace and back is the working equivalent.
                    onActivated: Services.Compositor.toggleShowDesktop()
                }
            }
        }
    }
}
