import QtQuick
import Quickshell
import Quickshell.Wayland

// One screen's greeter, as a layer over everything. The primary screen's
// takes the keyboard outright, so typing goes to the password from the
// first key with nothing to click first; the others take none, as two
// surfaces cannot both hold it.
PanelWindow {
    id: win

    required property var greeter
    property bool primary: true

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "black"

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "hyprshell-greeter"
    WlrLayershell.keyboardFocus: win.primary ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Surface {
        anchors.fill: parent
        greeter: win.greeter
        primary: win.primary
        screen: win.screen
    }
}
