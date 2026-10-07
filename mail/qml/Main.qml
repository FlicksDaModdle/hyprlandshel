import QtQuick
import QtQuick.Window
import Hyprshell
import Hyprshell.Backend

// The window. Its decoration is the shell's title bar, like Files' and the
// task manager's.
Window {
    id: win

    width: 1280
    height: 800
    minimumWidth: 760
    minimumHeight: 480
    visible: true
    title: Mail.unread > 0 ? "Mail (" + Mail.unread + ")" : "Mail"
    color: "transparent"

    readonly property bool tiled: true
    function toggleMaximised() { win.visibility = win.visibility === Window.Maximized ? Window.Windowed : Window.Maximized; }
    function minimise() { win.visibility = Window.Minimized; }
    function close() { Qt.quit(); }

    MailFrame {
        anchors.fill: parent
        host: win
    }

    // A second launch, or a notification's "Open": come to the front with
    // what it asked for.
    Connections {
        target: MailApp
        function onRaiseRequested() { win.raise(); win.requestActivate(); }
    }
}
