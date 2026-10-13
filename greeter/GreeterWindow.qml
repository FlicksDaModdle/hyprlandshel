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

    // Moving the pointer on this screen, or clicking it, brings the card
    // here. A real move, not the pointer merely being here when the screen
    // appears: Hyprland starts it in the middle of the first monitor, which
    // would otherwise claim the card before anyone touched anything.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: !win.primary
        enabled: !win.primary
        acceptedButtons: Qt.AllButtons
        property point first: Qt.point(-1, -1)
        function claim() { if (win.screen) win.greeter.pointerScreen = win.screen.name; }
        onEntered: first = Qt.point(mouseX, mouseY)
        onPositionChanged: mouse => {
            if (first.x < 0) { first = Qt.point(mouse.x, mouse.y); return; }
            if (Math.abs(mouse.x - first.x) + Math.abs(mouse.y - first.y) > 24) claim();
        }
        onExited: first = Qt.point(-1, -1)
        onEnabledChanged: first = Qt.point(-1, -1)
        onPressed: claim()
    }
}
