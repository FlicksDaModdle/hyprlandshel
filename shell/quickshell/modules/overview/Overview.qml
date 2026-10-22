import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Workspace overview. The mockup draws fixed rectangles; these are the real
// windows, laid out at the proportions the compositor reports, so a card is
// a recognisable picture of that workspace.
//
// Click a card to switch to it, click a window to focus that window, middle
// click a window to close it.
// One per screen, mapped only on the focused one — the same shape the bar,
// dock and panel layer use. Without it this is a single surface on whichever
// output the compositor picks, so on two monitors it opens on the wrong one
// about half the time.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: overview
        required property var modelData

        // Variants applies modelData after this binding is first evaluated,
        // so it sees undefined once on the way up. null is the same thing to
        // setScreen (use the default) and doesn't warn.
        screen: modelData ?? null
        // ...and nothing is drawn until it is a real one. `?? null` means
        // "the default screen" to setScreen, so during an output change —
        // plugging a monitor in, or changing a scale, which makes Hyprland
        // re-enumerate — a surface whose modelData has momentarily gone
        // would land on the default output instead. Two bars on one monitor
        // is what that looks like from the outside.
        readonly property bool hasScreen: !!modelData
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
        readonly property bool isPrimary: Services.Compositor.isFocusedScreen(modelData)

        visible: hasScreen && Config.UiState.overviewOpen
                 && !Config.UiState.locked && isPrimary
        color: "transparent"
        exclusiveZone: 0

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        WlrLayershell.namespace: "quickshell:overview"
        WlrLayershell.layer: WlrLayer.Overlay
        // Needs focus so Escape closes it.
        WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

        // The monitor this overview is drawn for, used to scale window rects.
        //
        // Matched by name against the screen this instance is on, rather
        // than by scanning for a focused flag: that flag is not always set
        // on the list Quickshell hands over, and when the scan found nothing
        // this fell back to monitors[0] and drew every thumbnail at the
        // wrong aspect ratio on the second display.
        readonly property var monitor: {
            const all = Services.Compositor.monitors || [];
            const want = modelData ? modelData.name : "";
            for (let i = 0; i < all.length; i++)
                if (all[i] && all[i].name === want) return all[i];
            const focusedName = Services.Compositor.focusedMonitorName;
            for (let i = 0; i < all.length; i++)
                if (all[i] && all[i].name === focusedName) return all[i];
            return all[0] || null;
        }
        readonly property real monitorW: monitor ? Math.max(1, monitor.width) : 1920
        readonly property real monitorH: monitor ? Math.max(1, monitor.height) : 1080
        readonly property real monitorX: monitor ? monitor.x : 0
        readonly property real monitorY: monitor ? monitor.y : 0

        readonly property var slots: Services.Compositor.workspaceSlots

        // Card size follows the monitor's aspect ratio so thumbnails aren't
        // stretched on ultrawides or portrait panels.
        readonly property real cardWidth: 312
        readonly property real cardHeight: Math.round(cardWidth * monitorH / monitorW)

        onVisibleChanged: {
            if (visible) focusScope.forceActiveFocus();
            else cancelDrag();
        }

        // ── dragging a window to another workspace ───────────────────────
        // A window picked up in one card is carried as a copy under the
        // pointer (`ghost`, below); the card it's over lights, and letting
        // go there moves the window, leaving you where you are.
        property var dragging: null       // { address, ws, toplevel, cls }
        property point dragPos: Qt.point(0, 0)
        property point dragGrab: Qt.point(0, 0)
        property real dragW: 0
        property real dragH: 0
        property int dropWs: -1
        // One past the last workspace: a new one, made by moving there.
        readonly property int newWs: {
            let top = 0;
            for (const s of slots) if (s.id > top) top = s.id;
            return top + 1;
        }

        function beginDrag(win, toplevel, w, h, grab, scenePos) {
            dragging = { address: win.address, ws: win.workspace, toplevel: toplevel, cls: win.cls };
            // Shown a little larger than the thumbnail it came from, so
            // there's something to see under the pointer.
            const k = Math.max(1, Math.min(2.2, 180 / Math.max(1, w)));
            dragW = w * k;
            dragH = h * k;
            dragGrab = Qt.point(grab.x * k, grab.y * k);
            dragTo(scenePos);
        }
        function dragTo(p) {
            dragPos = p;
            dropWs = workspaceAt(p);
        }
        function endDrag() {
            if (dragging && dropWs > 0 && dropWs !== dragging.ws)
                Services.Compositor.moveClientToWorkspace(dragging.address, dropWs);
            cancelDrag();
        }
        function cancelDrag() {
            dragging = null;
            dropWs = -1;
        }
        // The workspace whose card is under a point in the window.
        function workspaceAt(p) {
            for (let i = 0; i < cards.count; i++) {
                const c = cards.itemAt(i);
                if (!c) continue;
                const q = c.mapFromItem(null, p.x, p.y);
                if (q.x >= 0 && q.y >= 0 && q.x < c.width && q.y < c.height) return c.modelData.id;
            }
            if (newCard.visible) {
                const q = newCard.mapFromItem(null, p.x, p.y);
                if (q.x >= 0 && q.y >= 0 && q.x < newCard.width && q.y < newCard.height) return newWs;
            }
            return -1;
        }

        Rectangle {
            anchors.fill: parent
            color: Config.Appearance.scrim

            MouseArea {
                anchors.fill: parent
                onClicked: Config.UiState.closeAll()
            }
        }

        FocusScope {
            id: focusScope
            anchors.fill: parent
            focus: true

            Keys.onEscapePressed: {
                if (overview.dragging) overview.cancelDrag();
                else Config.UiState.closeAll();
            }
            Keys.onPressed: event => {
                // Number keys jump straight to a workspace, the same as they do
                // outside the overview.
                if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) {
                    Services.Compositor.focusWorkspace(event.key - Qt.Key_0);
                    Config.UiState.closeAll();
                    event.accepted = true;
                }
            }

            Column {
                anchors.centerIn: parent
                spacing: 26

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Workspaces"
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.DemiBold
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1.7
                    color: Config.Appearance.ink2
                }

                // Wrap onto more rows rather than overflowing on a busy session.
                Grid {
                    anchors.horizontalCenter: parent.horizontalCenter
                    columns: Math.max(1, Math.min(overview.slots.length,
                                Math.floor((overview.width - 80) / (overview.cardWidth + 18))))
                    spacing: 18

                    Repeater {
                        id: cards
                        model: overview.slots

                        Item {
                            id: card
                            required property var modelData

                            width: overview.cardWidth
                            height: overview.cardHeight

                            readonly property var windows: Services.Compositor.clientsOn(modelData.id)

                            Rectangle {
                                id: cardBg
                                anchors.fill: parent
                                radius: Config.Appearance.rCard
                                readonly property bool dropHere: overview.dragging !== null
                                    && overview.dropWs === card.modelData.id
                                    && overview.dragging.ws !== card.modelData.id
                                border.width: card.modelData.focused || dropHere ? 2 : 1
                                border.color: dropHere ? Config.Appearance.accent
                                              : card.modelData.focused
                                                ? Config.Appearance.accent : Config.Appearance.edge
                                color: dropHere ? Qt.tint(Config.Appearance.panel, Config.Appearance.seam)
                                                : Config.Appearance.panel
                                clip: true

                                // Windows, positioned at their real proportions
                                // within the monitor.
                                Repeater {
                                    model: card.windows

                                    Rectangle {
                                        id: thumb
                                        required property var modelData

                                        readonly property real sx: cardBg.width / overview.monitorW
                                        readonly property real sy: cardBg.height / overview.monitorH
                                        readonly property bool isActive:
                                            modelData.address === Services.Compositor.activeAddress
                                        readonly property bool lifted: overview.dragging !== null
                                            && overview.dragging.address === modelData.address
                                        // Looked up rather than carried: a window's
                                        // toplevel can arrive a moment after it does.
                                        readonly property var toplevel: {
                                            const t = Services.Compositor.toplevelFor(modelData.address);
                                            return t ? t.wayland : null;
                                        }
                                        readonly property bool pictured: capture.item !== null && capture.item.ready

                                        x: Math.round((modelData.x - overview.monitorX) * sx)
                                        y: Math.round((modelData.y - overview.monitorY) * sy)
                                        width: Math.max(12, Math.round(modelData.w * sx))
                                        height: Math.max(10, Math.round(modelData.h * sy))

                                        radius: 5
                                        clip: true
                                        color: pictured ? "transparent"
                                               : isActive ? Config.Appearance.sel : Config.Appearance.hover
                                        // Left behind, faint, while its copy is carried.
                                        opacity: lifted ? 0.35 : 1

                                        // The window itself, live while the overview
                                        // is up (dock/WindowThumb.qml: only loaded
                                        // where Quickshell can capture windows).
                                        Loader {
                                            id: capture
                                            anchors.fill: parent
                                            active: overview.visible && thumb.toplevel !== null
                                            source: "../dock/WindowThumb.qml"
                                            onLoaded: item.toplevel = Qt.binding(() => thumb.toplevel)
                                        }

                                        // Its icon and name until the picture comes, or
                                        // if it can't.
                                        Row {
                                            anchors.centerIn: parent
                                            spacing: 6
                                            visible: !thumb.pictured && thumb.width > 56 && thumb.height > 26

                                            MonoIcon {
                                                anchors.verticalCenter: parent.verticalCenter
                                                name: Config.Apps.iconFor(thumb.modelData.cls)
                                                size: Math.min(18, thumb.height - 10)
                                                inkColor: Config.Appearance.ink2
                                                accentColor: Config.Appearance.accent
                                            }

                                            StyledText {
                                                anchors.verticalCenter: parent.verticalCenter
                                                visible: thumb.width > 118
                                                width: Math.min(implicitWidth, thumb.width - 44)
                                                elide: Text.ElideRight
                                                text: Config.Apps.labelFor(thumb.modelData.cls)
                                                font.pixelSize: Config.Appearance.fs(11)
                                                font.weight: Font.DemiBold
                                                color: Config.Appearance.ink2
                                            }
                                        }

                                        // The edge, over the picture.
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: parent.radius
                                            color: "transparent"
                                            border.width: thumb.isActive || thumbHover.hovered ? 2 : 1
                                            border.color: thumbHover.hovered ? Config.Appearance.accent
                                                          : thumb.isActive ? Config.Appearance.ink3
                                                          : Config.Appearance.edge
                                        }

                                        HoverHandler { id: thumbHover; cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor }
                                        TapHandler {
                                            onTapped: {
                                                Services.Compositor.focusClient(thumb.modelData.address);
                                                Config.UiState.closeAll();
                                            }
                                        }
                                        TapHandler {
                                            acceptedButtons: Qt.MiddleButton
                                            gesturePolicy: TapHandler.ReleaseWithinBounds
                                            onTapped: Services.Compositor.closeClient(thumb.modelData.address)
                                        }
                                        // Picked up and carried to another workspace.
                                        DragHandler {
                                            id: drag
                                            target: null
                                            onActiveChanged: {
                                                if (active) {
                                                    const at = centroid.scenePressPosition;
                                                    const inThumb = thumb.mapFromItem(null, at.x, at.y);
                                                    overview.beginDrag(thumb.modelData, thumb.toplevel,
                                                                       thumb.width, thumb.height, inThumb, at);
                                                } else {
                                                    overview.endDrag();
                                                }
                                            }
                                            onCentroidChanged: if (active) overview.dragTo(centroid.scenePosition)
                                        }
                                    }
                                }

                                StyledText {
                                    anchors.centerIn: parent
                                    visible: card.windows.length === 0
                                    text: "Empty"
                                    font.pixelSize: Config.Appearance.fs(12)
                                    color: Config.Appearance.ink3
                                }
                            }

                            // Workspace label
                            Rectangle {
                                anchors.left: parent.left
                                anchors.bottom: parent.bottom
                                anchors.margins: 10
                                width: cardLabel.implicitWidth + 20
                                height: 26
                                radius: 8
                                color: card.modelData.focused
                                       ? Config.Appearance.accent : Config.Appearance.sel

                                StyledText {
                                    id: cardLabel
                                    anchors.centerIn: parent
                                    text: (card.modelData.workspace && card.modelData.workspace.name
                                           && card.modelData.workspace.name !== String(card.modelData.id))
                                          ? card.modelData.workspace.name
                                          : "Workspace " + card.modelData.id
                                    font.pixelSize: Config.Appearance.fs(11)
                                    font.weight: Font.DemiBold
                                    color: card.modelData.focused
                                           ? Config.Appearance.inkOnAccent : Config.Appearance.ink
                                }
                            }

                            // Window count
                            Rectangle {
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                anchors.margins: 10
                                visible: card.windows.length > 0
                                width: 26
                                height: 26
                                radius: 8
                                color: Config.Appearance.sel

                                StyledText {
                                    anchors.centerIn: parent
                                    text: card.windows.length
                                    font.pixelSize: Config.Appearance.fs(11)
                                    font.weight: Font.DemiBold
                                    color: Config.Appearance.ink2
                                }
                            }

                            // Clicking bare card area switches workspace. Sits
                            // below the window thumbnails so they win.
                            TapHandler {
                                gesturePolicy: TapHandler.ReleaseWithinBounds
                                onTapped: {
                                    Services.Compositor.focusWorkspace(card.modelData.id);
                                    Config.UiState.closeAll();
                                }
                            }
                        }
                    }

                    // While a window is carried: somewhere new to put it.
                    // (A Grid leaves out what isn't visible.)
                    Rectangle {
                        id: newCard
                        visible: overview.dragging !== null
                        width: overview.cardWidth
                        height: overview.cardHeight
                        radius: Config.Appearance.rCard
                        readonly property bool dropHere: overview.dropWs === overview.newWs
                        color: dropHere ? Qt.tint(Config.Appearance.panel, Config.Appearance.seam)
                                        : Config.Appearance.panel
                        border.width: dropHere ? 2 : 1
                        border.color: dropHere ? Config.Appearance.accent : Config.Appearance.edge

                        Column {
                            anchors.centerIn: parent
                            spacing: 8
                            MonoIcon {
                                anchors.horizontalCenter: parent.horizontalCenter
                                name: "plus"
                                size: 22
                                inkColor: newCard.dropHere ? Config.Appearance.accent : Config.Appearance.ink2
                                accentColor: Config.Appearance.accent
                            }
                            StyledText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "New workspace"
                                font.pixelSize: Config.Appearance.fs(12)
                                font.weight: Font.DemiBold
                                color: newCard.dropHere ? Config.Appearance.ink : Config.Appearance.ink2
                            }
                        }
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Click a window to focus it · drag it to another workspace · middle click to close · Esc to dismiss"
                    font.pixelSize: Config.Appearance.fs(11)
                    font.weight: Font.Normal
                    color: Config.Appearance.ink3
                }
            }

            // The window being carried, under the pointer.
            Rectangle {
                id: ghost
                visible: overview.dragging !== null
                x: overview.dragPos.x - overview.dragGrab.x
                y: overview.dragPos.y - overview.dragGrab.y
                width: overview.dragW
                height: overview.dragH
                radius: 7
                clip: true
                color: Config.Appearance.sel
                opacity: 0.94
                readonly property bool pictured: ghostCapture.item !== null && ghostCapture.item.ready

                Loader {
                    id: ghostCapture
                    anchors.fill: parent
                    active: ghost.visible && !!overview.dragging && overview.dragging.toplevel !== null
                    source: "../dock/WindowThumb.qml"
                    onLoaded: item.toplevel = Qt.binding(() => overview.dragging ? overview.dragging.toplevel : null)
                }
                MonoIcon {
                    anchors.centerIn: parent
                    visible: !ghost.pictured
                    name: overview.dragging ? Config.Apps.iconFor(overview.dragging.cls) : "square"
                    size: 22
                    inkColor: Config.Appearance.ink
                    accentColor: Config.Appearance.accent
                }
                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: "transparent"
                    border.width: 2
                    border.color: Config.Appearance.accent
                }
            }
        }
    }
}
