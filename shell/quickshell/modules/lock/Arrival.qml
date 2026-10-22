import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"

// The way back to the desktop after an unlock.
//
// The lock screen ends on the bare wallpaper (LoginView's `leaving`). This
// is that same wallpaper, put up over the desktop on every screen while
// the lock is still there — so it is already showing in the first frame
// after the lock goes — and then faded, so the windows come up through it
// rather than appearing all at once. It takes no clicks and no keys, and
// is gone a moment later (UiState.arriving).
Variants {
    model: Config.UiState.arriving ? Quickshell.screens : []

    PanelWindow {
        id: win
        required property var modelData
        screen: modelData ?? null

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        mask: Region {}

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "quickshell:arrival"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        Ground {
            anchors.fill: parent
            screen: win.modelData
            running: true
            phase: Services.WallMotion.phaseFor(win.modelData ? String(win.modelData.name) : "")
            // Whole while locked; fading from the moment it isn't.
            opacity: Config.UiState.locked ? 1 : 0
            Behavior on opacity {
                NumberAnimation { duration: 520; easing.type: Easing.OutCubic }
            }
        }
    }
}
