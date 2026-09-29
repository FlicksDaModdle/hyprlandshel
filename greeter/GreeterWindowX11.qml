import QtQuick
import Quickshell

// The same window under X11, where there is no layer shell. Only for
// trying the greeter out and for its tests; greetd always runs it on
// Wayland (see hyprland.lua).
PanelWindow {
    id: win

    required property var greeter
    property bool primary: true

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    focusable: win.primary
    color: "black"

    Surface {
        anchors.fill: parent
        greeter: win.greeter
        primary: win.primary
    }
}
