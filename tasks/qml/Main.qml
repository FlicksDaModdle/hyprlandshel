import QtQuick
import QtQuick.Window
import Hyprshell
import Hyprshell.Backend

// The application window. Its decoration is the shell's title bar, like
// the file manager's.
Window {
    id: win

    width: 1180
    height: 760
    minimumWidth: 720
    minimumHeight: 480
    visible: true
    title: "Task Manager"
    color: "transparent"

    readonly property bool tiled: true
    function toggleMaximised() { win.visibility = win.visibility === Window.Maximized ? Window.Windowed : Window.Maximized; }
    function minimise() { win.visibility = Window.Minimized; }
    function close() { Qt.quit(); }

    // Sampling only matters while someone can see the result. Minimised,
    // it slows to a sample every few seconds, which keeps the histories
    // going without the cost; in the background on battery, to every two.
    readonly property int wantInterval: win.visibility === Window.Minimized
        ? Math.max(4000, Tasks.settings.interval)
        : Tasks.onBattery && !win.active ? Math.max(2000, Tasks.settings.interval)
        : Tasks.settings.interval
    onWantIntervalChanged: Monitor.interval = wantInterval

    TasksFrame {
        anchors.fill: parent
        host: win
    }
}
