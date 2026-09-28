import QtQuick
import Quickshell.Wayland

// A live picture of one window, fitted inside whatever box it is given.
//
// In a file of its own, and only ever reached through a Loader, because
// ScreencopyView exists only when Quickshell was built with screencopy. A
// dock that named it directly would fail to load at all on a build
// without it; this way the preview falls back to the app's icon and
// everything else carries on.
//
// Capturing a single window goes through hyprland-toplevel-export, which
// renders the window into a buffer of its own — so a window on another
// workspace, or hidden behind others, still comes out whole.
Item {
    id: root

    // A Quickshell Toplevel (HyprlandToplevel.wayland), or null.
    property var toplevel: null
    // True once the first frame has arrived.
    readonly property bool ready: view.hasContent

    ScreencopyView {
        id: view
        anchors.centerIn: parent
        captureSource: root.toplevel
        live: true
        // Sized from the window's own aspect ratio inside the box, rather
        // than stretched to fill it: a tall terminal and a wide browser
        // should both look like themselves.
        constraintSize: Qt.size(root.width, root.height)
        width: implicitWidth
        height: implicitHeight
    }
}
