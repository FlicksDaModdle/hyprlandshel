import QtQuick
import QtQuick.Window
import Hyprshell
import Hyprshell.Backend

// The application window. Its decoration is the shell's own title bar,
// like Files' and the task manager's.
Window {
    id: win

    width: 1100
    height: 760
    minimumWidth: 480
    minimumHeight: 360
    visible: true
    title: viewer.current !== "" ? viewer.currentName + " — Images" : "Images"
    color: "transparent"

    readonly property bool fullscreen: win.visibility === Window.FullScreen
    function toggleMaximised() { win.visibility = win.visibility === Window.Maximized ? Window.Windowed : Window.Maximized; }
    function toggleFullscreen() { win.visibility = fullscreen ? Window.Windowed : Window.FullScreen; }
    function minimise() { win.visibility = Window.Minimized; }
    function close() { Qt.quit(); }

    Viewer {
        id: viewer
        anchors.fill: parent
        host: win
        Component.onCompleted: forceActiveFocus()
    }
}
