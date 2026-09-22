import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"

// The bar's window-menu button.
//
// The mockup shows a per-app File/Edit/View menu bar. That needs a global
// menu protocol, and Wayland has none — no client on Hyprland exports its
// menus, so rendering File/Edit/View here would be drawing buttons that
// can't do anything. This keeps the mockup's affordance and fills it with
// actions that actually run; the menu itself is drawn by
// panels/WindowMenuPanel.qml, alongside every other dropdown.
Item {
    id: root

    required property var barWindow

    readonly property bool hasClient: Services.Compositor.activeClient !== null
    readonly property bool open: Config.UiState.windowMenuOpen

    implicitWidth: label.implicitWidth + 20
    implicitHeight: 26
    opacity: hasClient ? 1 : 0.45

    // If the window goes away while its menu is up, the menu has nothing
    // left to act on.
    onHasClientChanged: if (!hasClient && open) Config.UiState.closeAll();

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rSm
        color: root.open ? Config.Appearance.sel
             : (hover.hovered && root.hasClient ? Config.Appearance.hover : "transparent")
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    StyledText {
        id: label
        anchors.centerIn: parent
        text: "Window"
        font.pixelSize: Config.Appearance.fs(Config.Appearance.barMenuSize)
        color: Config.Appearance.ink
    }

    HoverHandler { id: hover; enabled: root.hasClient; cursorShape: Qt.PointingHandCursor }

    TapHandler {
        enabled: root.hasClient
        onTapped: {
            // Hand the panel layer this button's position on screen so the
            // menu can hang directly under it.
            const rect = root.barWindow.itemRect(root);
            Config.UiState.toggleWindowMenu(Math.round(rect.x));
        }
    }
}
