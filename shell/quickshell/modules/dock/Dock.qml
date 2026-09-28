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
        //
        // Nothing is reserved until the settings have been read. They are
        // read from disk asynchronously, so for the first moments of a
        // session every preference is at its default — auto-hide off —
        // and a dock that reserved its strip on the strength of that
        // pushed every window aside for a dock that was about to turn out
        // to be hidden. The correction that followed never reached the
        // compositor, so the session stayed offset until auto-hide was
        // toggled off and on by hand. Starting at nothing and growing
        // once, if it turns out to be wanted, is the order that works.
        exclusiveZone: (!Config.Appearance.settingsReady
                        || Config.Appearance.dockAutoHide)
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

        // Per-output scale, the same one the bar uses.
        //
        // Without it, Settings → Displays → Shell scale moved the bar on
        // one monitor and left the dock the same size on both — which is
        // exactly the half-applied look the setting exists to fix. Every
        // measurement below goes through u(), so one number changes all
        // of them together.
        readonly property real us:
            Config.Appearance.screenScale(modelData ? modelData.name : "")
        function u(px) { return Math.max(1, Math.round(px * us)); }

        readonly property real tileSize: u(Config.Appearance.dockTileSize)
        readonly property real iconSize: u(Config.Appearance.dockIconSize)
        readonly property real padH: u(Config.Appearance.dockPadH)
        readonly property real padV: u(Config.Appearance.dockPadV)
        readonly property real tileSpacing: u(Config.Appearance.dockTileSpacing)
        readonly property real edgeGap: u(Config.Appearance.dockEdgeGap)
        // The shell owns this and writes it to Hyprland (Settings → Shell →
        // Hyprland → Outer gaps), so reading the preference is reading what
        // the compositor is actually doing.
        readonly property real gapsOut: Math.max(0, Config.Appearance.gapsOut)
        // Headroom reserved above the pill for tiles' hover tooltips.
        readonly property real tooltipRoom: u(Config.Appearance.dockTooltipRoom)

        // Window previews rise above the tile they belong to, so the
        // surface carries room for the tallest card it can show as well as
        // for a tooltip. Set aside for good rather than grown when a card
        // opens: the surface is anchored at the bottom, so growing it moves
        // its top edge, and everything laid out from the top — the pill
        // included — would jump for the frame it took the compositor to
        // catch up. None of it takes input unless a card is showing (see
        // the mask), and the space reserved from windows is set separately
        // (exclusiveZone), so the extra height costs nothing.
        //
        // Along the bottom edge only. On the left there is nowhere above a
        // tile to put a card, and those tiles keep their tooltips.
        readonly property bool previewsOn: Config.Appearance.dockPreviews && !isLeft
        readonly property real previewGap: u(10)
        readonly property real headroom: previewsOn
            ? Math.max(tooltipRoom, Math.ceil(preview.fullHeight) + previewGap + u(4))
            : tooltipRoom
        readonly property real panelBreadth: u(Config.Appearance.dockPanelBreadth)

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
            if (launcherHere) {
                afterLauncher = false;
                afterLauncherHold.stop();
                closePreview();
            }
            else if (visible && Config.UiState.holdDockAfterLauncher) {
                afterLauncher = true;
                afterLauncherHold.restart();
            }
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

        // The window's own hover is enough, because the revealed mask runs
        // unbroken from the pill down to the screen edge: there is no
        // untracked gap between the edge strip and the pill for the
        // pointer to cross on its way up. (It does not reach above the
        // pill — see the mask below — but nothing approaches from there.)
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
        readonly property real windowBreadth: headroom + panelBreadth + edgeGap
        readonly property real pillShownPos: headroom
        readonly property real pillHiddenPos: headroom + panelBreadth + 20

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

        // What takes clicks.
        //
        // Hidden: a thin strip along the screen edge, spanning it, so the
        // pointer finds it anywhere.
        //
        // Revealed: the pill, a margin to either side of it so the pointer
        // can approach along the edge without hover dropping in untracked
        // space, and everything between the pill and the screen edge —
        // but *nothing past the pill on the inward side*.
        //
        // That last part is the whole point. The surface is taller than
        // the pill by the room its tooltips need, and the mask used to
        // cover all of it. Tooltips are pictures, not buttons, so nothing
        // there needs input — but with auto-hide on there is no exclusive
        // zone, so a real window sits under that headroom, and a band
        // across it as wide as the dock quietly swallowed every click.
        readonly property real maskPad: 40

        // The four numbers, worked out once instead of four times inside
        // the Region's bindings — and clamped, which is the part that
        // matters: the pill's hidden position is deliberately outside the
        // surface, so an unclamped height goes negative and the mask
        // disappears just as the pointer is trying to find it.
        //
        // `- 3` keeps a strip along the screen edge inside the mask at all
        // times. That strip is what the pointer lands on to bring the dock
        // back, and it has to stay live through the whole slide up.
        readonly property real maskNearEdge:
            isLeft ? Math.max(3, Math.min(Math.ceil(pill.x + pill.width), width))
                   : Math.max(0, Math.min(Math.round(pill.y), height - 3))

        readonly property real maskX: !revealed || isLeft
            ? 0 : Math.max(0, Math.round(pill.x - maskPad))
        readonly property real maskY: revealed
            ? (isLeft ? Math.max(0, Math.round(pill.y - maskPad)) : maskNearEdge)
            : (isLeft ? 0 : height - 3)
        readonly property real maskW: revealed
            ? (isLeft ? maskNearEdge : Math.ceil(pill.width + maskPad * 2))
            : (isLeft ? 3 : width)
        readonly property real maskH: revealed
            ? (isLeft ? Math.ceil(pill.height + maskPad * 2) : height - maskNearEdge)
            : (isLeft ? height : 3)

        mask: Region {
            x: dock.maskX
            y: dock.maskY
            width: dock.maskW
            height: dock.maskH

            // The preview card, and the gap between it and the pill. The
            // pointer crosses that gap on its way up to the card, and a gap
            // outside the mask is a gap where the dock does not have the
            // pointer — hover drops, auto-hide starts counting, and the
            // card starts closing, halfway through reaching for it.
            // Nothing at all while no card is showing, so the headroom
            // stays click-through.
            Region {
                x: preview.shown ? Math.round(preview.x) : 0
                y: preview.shown ? Math.round(preview.y) : 0
                width: preview.shown ? Math.ceil(preview.width) : 0
                height: preview.shown ? Math.max(0, Math.ceil(pill.y - preview.y)) : 0
            }
        }

        HoverHandler { id: windowHover }

        // ── window/app state ──────────────────────────────────────────────
        //
        // Only the windows on the workspace this dock's own monitor is
        // showing, unless Settings → Dock says every workspace — the way
        // Windows 11's taskbar can keep each desktop to itself. Everything
        // below reads this one list: the running pips and window counts,
        // clicking to cycle, the preview card, and which unpinned apps get
        // a tile at all. So an app whose windows are all on another
        // workspace looks, and behaves, as not running here: clicking it
        // opens a window here rather than pulling you over there.
        //
        // Per monitor, not per focused workspace: two monitors show two
        // workspaces, and each dock belongs to the one it is on.
        readonly property string screenName: modelData ? modelData.name : ""
        readonly property bool scopeAll: Config.Appearance.dockScope === "all"
        readonly property var clients: scopeAll
            ? Services.Compositor.clients
            : Services.Compositor.clientsShownOn(screenName)

        // The focused window only counts as active here if it is one of
        // this dock's windows. Otherwise the dock on the other monitor lit
        // up an app it is not showing.
        readonly property bool activeHere:
            clients.some(c => c.address === Services.Compositor.activeAddress)
        readonly property string activeClass:
            activeHere ? Services.Compositor.activeClass : ""

        function windowsFor(app) {
            return clients.filter(c => app.match.test(c.cls || ""));
        }

        function isActiveApp(app) {
            return activeClass !== "" && app.match.test(activeClass);
        }

        // Apps with windows open that aren't pinned, so they still show up
        // in the dock while they're running.
        //
        // A string of class names, one per line, and not a list of objects.
        // The list was rebuilt on every window event — a browser changing
        // its title is one — and a Repeater handed a new list of objects
        // destroys every tile and builds it again. That dropped the hover
        // under the pointer, and it would take down a window preview
        // anchored to the tile along with it. A string that comes out the
        // same raises no change at all, so the tiles are only rebuilt when
        // the set of apps actually changes; each tile finds its own
        // windows.
        readonly property string unpinnedKey: {
            const seen = ({});
            const out = [];
            for (const c of clients) {
                const cls = c.cls || "";
                if (!cls || seen[cls]) continue;
                if (Config.Apps.pinnedFor(cls)) continue;
                seen[cls] = true;
                out.push(cls);
            }
            return out.join("\n");
        }
        readonly property var unpinnedClasses:
            unpinnedKey === "" ? [] : unpinnedKey.split("\n")

        // ── rearranging, by dragging a pinned tile ────────────────────────
        //
        // While a tile is carried the list itself is left alone — handing
        // the Repeater a new order would destroy the tile being dragged,
        // and the drag with it. Instead each tile is slid by `slideFor()`:
        // the carried one by however far the pointer has gone, the ones it
        // has passed by one tile's width the other way, so the gap opens
        // where it would land. Letting go writes the new order once.
        //
        // Where it lands is worked out against where the tiles were when
        // the drag began (`dragSlots`), since the slides do not move their
        // layout positions and the answer must not chase itself.
        property string dragKey: ""
        property int dragFrom: -1
        property int dragTo: -1
        property real dragAlong: 0
        property var dragSlots: []
        // The instant after a drop: the tiles are rebuilt in their new
        // order, already where they belong, and must not slide there again.
        property bool dragSettling: false

        function dragStart(index, key) {
            dock.closePreview();
            const slots = [];
            for (let j = 0; j < pinnedTiles.count; j++) {
                const t = pinnedTiles.itemAt(j);
                if (!t) return;
                slots.push(dock.isLeft ? { start: t.y, size: t.height }
                                       : { start: t.x, size: t.width });
            }
            dock.dragSlots = slots;
            dock.dragAlong = 0;
            dock.dragFrom = index;
            dock.dragTo = index;
            dock.dragKey = key;
        }

        function dragMove(along) {
            const s = dock.dragSlots, f = dock.dragFrom;
            if (f < 0 || f >= s.length) return;
            // Kept within the pinned tiles, so it cannot be dropped over
            // Start or Settings, or carried out of the pill.
            const first = s[0].start - s[f].start;
            const last = s[s.length - 1].start + s[s.length - 1].size - s[f].start - s[f].size;
            dock.dragAlong = Math.max(first, Math.min(last, along));
            const centre = s[f].start + s[f].size / 2 + dock.dragAlong;
            // A tile counts as passed once the carried one's centre reaches
            // its centre — for the ones it is moving towards. Held against
            // the end of the pinned tiles the two centres are exactly
            // equal, and without that the last place could not be reached.
            let to = 0;
            for (let j = 0; j < s.length; j++) {
                const c = s[j].start + s[j].size / 2;
                if (j < f ? c < centre : (j > f && c <= centre)) to++;
            }
            dock.dragTo = to;
        }

        function dragEnd() {
            const key = dock.dragKey, from = dock.dragFrom, to = dock.dragTo;
            if (key === "") return;
            // After the handler that called this has returned: the move
            // rebuilds every pinned tile, the one reporting this included.
            Qt.callLater(() => {
                if (to >= 0 && to !== from) {
                    dock.dragSettling = true;
                    Config.Apps.move(key, to);
                }
                dock.dragKey = "";
                dock.dragFrom = -1;
                dock.dragTo = -1;
                dock.dragAlong = 0;
                Qt.callLater(() => dock.dragSettling = false);
            });
        }

        function slideFor(index) {
            const f = dock.dragFrom, t = dock.dragTo;
            if (f < 0) return 0;
            if (index === f) return dock.dragAlong;
            const step = (dock.dragSlots[f] ? dock.dragSlots[f].size : dock.tileSize)
                         + dock.tileSpacing;
            if (f < t && index > f && index <= t) return -step;
            if (t < f && index >= t && index < f) return step;
            return 0;
        }

        // ── window previews ───────────────────────────────────────────────
        //
        // What the card is showing: a key naming the tile, and how to find
        // that app's windows. Kept as a way to look them up rather than as
        // a list, so a window opening or closing while the card is up
        // appears in it or leaves it.
        property string previewKey: ""
        property var previewApp: null       // a pinned app, or null
        property string previewCls: ""      // an unpinned app's class
        property string previewIcon: ""
        // Cleared by QML itself if the tile is destroyed, which closes the
        // card rather than leaving it pointing at nothing.
        property Item previewTile: null

        // A hover that has not been there long enough to open a card yet.
        property var pendingSpec: null
        property Item pendingTile: null

        // The running app tile under the pointer, if there is one.
        property string hoverKey: ""

        readonly property var previewWindows: {
            if (previewKey === "") return [];
            if (previewApp) return windowsFor(previewApp);
            return clients.filter(c => c.cls === previewCls);
        }
        readonly property bool previewOpen:
            previewsOn && previewKey !== "" && previewWindows.length > 0

        // Called by every app tile as the pointer comes and goes. `spec` is
        // { key, app, cls, icon, running }.
        //
        // The first card waits a moment, so sweeping the pointer along the
        // dock does not flash one up for every app it passes. Once one is
        // open, moving to the next running app switches straight to its
        // card, the way a taskbar does.
        function tileHover(spec, tile, on) {
            if (!dock.previewsOn || dock.dragKey !== "") return;
            if (on && spec.running) {
                dock.hoverKey = spec.key;
                previewCloseDelay.stop();
                if (dock.previewKey !== "") { dock.showPreview(spec, tile); return; }
                dock.pendingSpec = spec;
                dock.pendingTile = tile;
                previewOpenDelay.restart();
                return;
            }
            if (dock.hoverKey === spec.key) dock.hoverKey = "";
            if (dock.pendingSpec && dock.pendingSpec.key === spec.key)
                previewOpenDelay.stop();
            if (dock.previewKey !== "") previewCloseDelay.restart();
        }

        function showPreview(spec, tile) {
            dock.previewApp = spec.app || null;
            dock.previewCls = spec.cls || "";
            dock.previewIcon = spec.icon || "";
            dock.previewTile = tile;
            dock.previewKey = spec.key;
        }

        function closePreview() {
            previewOpenDelay.stop();
            previewCloseDelay.stop();
            dock.pendingSpec = null;
            dock.pendingTile = null;
            dock.previewKey = "";
            dock.previewTile = null;
            dock.previewApp = null;
        }

        Timer {
            id: previewOpenDelay
            interval: 380
            onTriggered: {
                const spec = dock.pendingSpec;
                if (spec && dock.hoverKey === spec.key && dock.pendingTile)
                    dock.showPreview(spec, dock.pendingTile);
            }
        }
        // Long enough to cross from the tile up into the card, or across
        // the gap between two tiles, without the card blinking out.
        Timer {
            id: previewCloseDelay
            interval: 300
            onTriggered: if (dock.hoverKey === "" && !preview.hovered) dock.closePreview();
        }
        Connections {
            target: preview
            function onHoveredChanged() {
                if (preview.hovered) previewCloseDelay.stop();
                else if (dock.previewKey !== "") previewCloseDelay.restart();
            }
        }

        // Everything else that ends a card: the dock sliding away, being
        // hidden, the launcher opening over it, the setting going off, the
        // tile disappearing, or the app's last window closing.
        onRevealedChanged: if (!revealed) closePreview();
        onVisibleChanged: if (!visible) closePreview();
        onPreviewsOnChanged: if (!previewsOn) closePreview();
        onPreviewTileChanged: if (previewKey !== "" && !previewTile) closePreview();
        onPreviewWindowsChanged:
            if (previewKey !== "" && previewWindows.length === 0) closePreview();

        // Where the card is centred: over its tile, which moves whenever a
        // tile beside it grows its label. mapToItem is a plain call, so the
        // geometry it depends on is read first to make this re-run.
        readonly property real previewAnchorX: {
            const t = dock.previewTile;
            if (!t) return dock.width / 2;
            void pill.x; void pill.width; void tiles.x; void t.x; void t.width;
            return t.mapToItem(null, t.width / 2, 0).x;
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
                                   key, cls, label, icon, true);
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
                    onActivated: Config.UiState.toggleLauncherFromDock()
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
                    id: pinnedTiles
                    model: Config.Apps.pinned

                    DockTile {
                        id: pinnedTile
                        required property var modelData
                        required property int index

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
                        // The card names every window, so a running app's
                        // tooltip would only say less, underneath it.
                        showTooltip: !(dock.previewsOn && wins.length > 0)
                        tooltipEdge: dock.isLeft ? Qt.RightEdge : Qt.TopEdge
                        subtitle: wins.length === 0 ? "not running"
                                : (wins.length === 1 ? "1 window" : wins.length + " windows")

                        onHoveredChanged: dock.tileHover(
                            { key: "pin:" + modelData.key, app: modelData,
                              icon: modelData.icon, running: wins.length > 0 },
                            pinnedTile, hovered)

                        onActivated: {
                            dock.closePreview();
                            dock.launchOrFocus(modelData);
                        }
                        // Right click opens the tile's menu — new window,
                        // re-point it at a different application, or unpin.
                        // Opening a fresh instance moved in there, since it
                        // is one of three things you might want and no longer
                        // the only one.
                        onSecondaryActivated: {
                            dock.closePreview();
                            dock.openTileMenu(
                                pinnedTile, modelData.key, "", modelData.label, modelData.icon);
                        }
                        onMiddleActivated: {
                            if (wins.length > 0) Services.Compositor.closeClient(wins[0].address);
                        }

                        // Drag to rearrange: press, move along the dock,
                        // let go where it should be.
                        draggable: Config.Apps.pinned.length > 1
                        vertical: dock.isLeft
                        slide: dock.slideFor(index)
                        slideAnimated: !dock.dragSettling && index !== dock.dragFrom
                        onDragStarted: dock.dragStart(index, modelData.key)
                        onDragMoved: along => dock.dragMove(along)
                        onDragFinished: dock.dragEnd()
                    }
                }

                // ── Unpinned but running ──────────────────────────────────
                DockDivider {
                    isLeft: dock.isLeft
                    tileSize: dock.tileSize
                    visible: dock.unpinnedClasses.length > 0
                }

                Repeater {
                    model: dock.unpinnedClasses

                    DockTile {
                        id: unpinnedTile
                        required property string modelData

                        readonly property string cls: modelData
                        readonly property var wins:
                            dock.clients.filter(x => x.cls === unpinnedTile.cls)
                        readonly property string appLabel: Config.Apps.labelFor(cls)
                        readonly property string appIcon: Config.Apps.iconFor(cls)
                        readonly property bool isActive: dock.activeClass === cls

                        width: implicitWidth
                        height: dock.tileSize
                        tileSize: dock.tileSize
                        iconSize: dock.iconSize
                        iconName: appIcon
                        label: appLabel
                        subtitle: "not pinned"
                        running: wins.length > 0
                        windowCount: wins.length
                        active: isActive
                        showTooltip: !(dock.previewsOn && wins.length > 0)
                        // The same rule as a pinned tile. It was missing
                        // here, so an application that was running but
                        // not pinned never showed its name — not even
                        // when it was the one you were looking at, which
                        // is the only time a dock says a name at all.
                        showLabel: isActive && Config.Appearance.dockLabels && !dock.isLeft
                        tooltipEdge: dock.isLeft ? Qt.RightEdge : Qt.TopEdge

                        onHoveredChanged: dock.tileHover(
                            { key: "cls:" + cls, cls: cls, icon: appIcon,
                              running: wins.length > 0 },
                            unpinnedTile, hovered)

                        onActivated: {
                            dock.closePreview();
                            if (wins.length === 0) return;
                            const at = wins.findIndex(
                                c => c.address === Services.Compositor.activeAddress);
                            const next = at >= 0 ? wins[(at + 1) % wins.length] : wins[0];
                            Services.Compositor.focusClient(next.address);
                        }
                        onSecondaryActivated: {
                            dock.closePreview();
                            dock.openTileMenu(unpinnedTile, "", cls, appLabel, appIcon);
                        }
                        onMiddleActivated:
                            if (wins.length > 0) Services.Compositor.closeClient(wins[0].address)
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

        // ── the preview card ──────────────────────────────────────────────
        DockPreview {
            id: preview

            readonly property bool shown: dock.previewOpen

            // Emptied when closed, which destroys every picture in it and
            // stops each live capture along with it.
            windows: shown ? dock.previewWindows : []
            iconName: dock.previewIcon
            us: dock.us
            maxWidth: dock.width - dock.u(24)

            // Centred over its tile, kept a margin inside the screen.
            x: Math.round(Math.max(dock.u(12),
                          Math.min(dock.width - width - dock.u(12),
                                   dock.previewAnchorX - width / 2)))
            y: Math.round(pill.y - height - dock.previewGap)

            visible: opacity > 0.01
            opacity: shown ? 1 : 0
            // Fades in and is gone at once on the way out: its pictures are
            // released the moment it closes, and an empty card fading away
            // would be the last thing it showed.
            Behavior on opacity {
                enabled: preview.shown
                NumberAnimation { duration: Config.Appearance.anim(130); easing.type: Easing.OutCubic }
            }
            transform: Translate {
                y: preview.shown ? 0 : dock.u(6)
                Behavior on y {
                    enabled: preview.shown
                    NumberAnimation { duration: Config.Appearance.anim(160); easing.type: Easing.OutCubic }
                }
            }

            onPicked: address => {
                dock.closePreview();
                // Focusing a window on another workspace takes you there.
                Services.Compositor.focusClient(address);
            }
            onCloseRequested: address => Services.Compositor.closeClient(address)
        }
    }
}
