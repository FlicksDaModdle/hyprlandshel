import QtQuick
import Hyprshell
import QtQuick.Window
import Hyprshell.Backend

// The application window.
//
// An ordinary Qt toplevel, which is the point of being a separate program:
// the compositor tiles it, focuses it and applies window rules like any
// other application, and a drag out of it goes through the normal Wayland
// data-device rather than a layer-shell surface, which is not a drag source.
//
// The decoration is the designed title bar rather than the compositor's —
// main.cpp asks Qt not to draw one of its own — so moving and maximising go
// through startSystemMove() and the window's visibility.
Window {
    id: win

    width: 1100
    height: 700
    minimumWidth: 640
    minimumHeight: 420
    visible: !portalOnly
    title: files.cwd === "" ? "Files"
                            : "Files — " + FilesService.pretty(files.cwd)
    color: "transparent"

    // The host contract FilesFrame reads. In an application the window
    // manager owns the geometry, so this is the tiled case throughout and
    // the frame simply fills what it is given.
    readonly property bool tiled: true
    readonly property bool maximised: win.visibility === Window.Maximized
    readonly property real normalWidth: win.width
    readonly property real normalHeight: win.height
    readonly property real workTop: 0
    readonly property real workBottom: win.height
    function moveTo(x, y) { win.startSystemMove(); }
    function toggleMaximised() {
        win.visibility = win.maximised ? Window.Windowed : Window.Maximized;
    }
    function minimise() { win.visibility = Window.Minimized; }
    function close() { Qt.quit(); }

    Files {
        id: files
        // `startPath` is set from the command line, so opening a folder from
        // another application lands in that folder.
        Component.onCompleted: files.go(startPath && startPath !== ""
                                        ? startPath : FilesService.home)
    }

    // "Show in file manager", from anywhere on the desktop. Several paths
    // at once is legal and means several windows to a real file manager;
    // this one window takes the first and ignores the rest, which is
    // honest about what it can do rather than opening one and pretending.
    Connections {
        target: FileManager1
        function onShowFolders(paths) {
            if (paths.length > 0) { files.reveal(paths[0], true); win.requestActivate(); }
        }
        function onShowItems(paths) {
            if (paths.length > 0) { files.reveal(paths[0], false); win.requestActivate(); }
        }
        function onShowItemProperties(paths) {
            if (paths.length === 0) return;
            files.reveal(paths[0], false);
            win.requestActivate();
            // The sheet needs the entry, which only exists once the
            // listing has come back.
            files.pendingProperties = files.svc.basename(paths[0]);
        }
    }

    // Dialogs asked for over the portal. One window each, keyed by the
    // token the portal handed us, because a browser downloading two things
    // at once asks twice and neither answer may go to the wrong caller.
    Component {
        id: dialogComponent
        FileDialog {}
    }

    Connections {
        target: Portal
        function onDialogRequested(token, mode, title, appId, startFolder,
                                   suggestedName, multiple, directory, filters) {
            const dlg = dialogComponent.createObject(null, {
                token: token, mode: mode, startFolder: startFolder,
                suggestedName: suggestedName, multiple: multiple,
                directory: directory, filters: filters
            });
            if (!dlg) { Portal.finish(token, []); return; }
            dlg.chosen.connect(function (t, paths) { Portal.finish(t, paths); });
        }
    }

    FilesFrame {
        anchors.fill: parent
        host: win
        app: files
    }
}
