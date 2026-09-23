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
        readonly property bool isPrimary: Services.Compositor.isFocusedScreen(modelData)

        visible: Config.UiState.overviewOpen && !Config.UiState.locked && isPrimary
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

        onVisibleChanged: if (visible) focusScope.forceActiveFocus();

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

            Keys.onEscapePressed: Config.UiState.closeAll()
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
                                color: Config.Appearance.panel
                                border.width: card.modelData.focused ? 2 : 1
                                border.color: card.modelData.focused
                                              ? Config.Appearance.accent : Config.Appearance.edge
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

                                        x: Math.round((modelData.x - overview.monitorX) * sx)
                                        y: Math.round((modelData.y - overview.monitorY) * sy)
                                        width: Math.max(12, Math.round(modelData.w * sx))
                                        height: Math.max(10, Math.round(modelData.h * sy))

                                        radius: 7
                                        color: isActive ? Config.Appearance.sel : Config.Appearance.hover
                                        border.width: 1
                                        border.color: thumbHover.hovered
                                                      ? Config.Appearance.accent : Config.Appearance.edge

                                        Row {
                                            anchors.centerIn: parent
                                            spacing: 6
                                            visible: thumb.width > 56 && thumb.height > 26

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

                                        HoverHandler { id: thumbHover; cursorShape: Qt.PointingHandCursor }
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
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Click a window to focus it · middle click to close · Esc to dismiss"
                    font.pixelSize: Config.Appearance.fs(11)
                    font.weight: Font.Normal
                    color: Config.Appearance.ink3
                }
            }
        }
    }
}
