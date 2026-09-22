import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services

// One overlay surface per monitor hosting every bar dropdown: control
// center, notifications, calendar, power menu and the desktop context menu.
//
// They live here rather than in the bar for two reasons. The bar is only
// `barHeight` tall, so anything hanging off it would be clipped by its own
// surface; and a single overlay gives one click-away target that dismisses
// whatever is open, which is what the mockup's full-screen catcher does.
//
// The surface is only mapped while something is open, so it never
// intercepts clicks meant for the desktop.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: layer
        required property var modelData

        screen: modelData
        visible: Config.UiState.anyPanelOpen && isPrimary
        color: "transparent"
        exclusiveZone: 0

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        WlrLayershell.namespace: "quickshell:panel"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // Panels follow the pointer's monitor: opening the control center
        // from the bar on the right-hand screen should not light it up on
        // the left one. Quickshell has no pointer-position API, so the
        // compositor's focused monitor is the stand-in — it's the monitor
        // whose bar you just clicked.
        readonly property bool isPrimary: {
            const focused = Services.Compositor.monitors.find(m => m.focused);
            return !focused || !modelData || focused.name === modelData.name;
        }

        // Click-away. Right-clicking bare backdrop reopens the desktop menu
        // at the new spot rather than just dismissing.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) Config.UiState.openDesktopMenu(mouse.x, mouse.y);
                else Config.UiState.closeAll();
            }
        }

        // Every dropdown right-aligns to the same gutter and hangs the same
        // distance below the bar, as in the mockup.
        readonly property real panelRight: layer.width - Config.Appearance.panelEdgeGap
        readonly property real panelTop: Config.Appearance.panelTop

        ControlCenter {
            id: cc
            visible: Config.UiState.controlCenterOpen
            x: layer.panelRight - width
            y: layer.panelTop
            opacity: visible ? 1 : 0
        }

        NotificationCenter {
            visible: Config.UiState.notificationsOpen
            x: layer.panelRight - width
            y: layer.panelTop
        }

        CalendarPanel {
            visible: Config.UiState.calendarOpen
            x: layer.panelRight - width
            y: layer.panelTop
        }

        PowerMenu {
            visible: Config.UiState.powerOpen
            x: layer.panelRight - width
            y: layer.panelTop
        }

        // The bar's window menu hangs under its button rather than at the
        // right gutter, so it reads as belonging to it.
        WindowMenuPanel {
            visible: Config.UiState.windowMenuOpen
            screenWidth: layer.width
            screenHeight: layer.height
            x: Math.max(8, Math.min(Config.UiState.windowMenuX, layer.width - width - 8))
            y: layer.panelTop
        }

        // The context menu opens at the pointer, nudged back on screen if
        // it would run off the right or bottom edge.
        DesktopMenu {
            id: ctx
            visible: Config.UiState.desktopMenuOpen
            x: Math.max(8, Math.min(Config.UiState.desktopMenuX, layer.width - width - 8))
            y: Math.max(Config.Appearance.barHeight + 4,
                        Math.min(Config.UiState.desktopMenuY, layer.height - height - 8))
        }
    }
}
