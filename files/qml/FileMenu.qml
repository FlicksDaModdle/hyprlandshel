import QtQuick
import Hyprshell

// The right-click menu, for a file, for several files, or for the empty
// space of the folder itself.
//
// It lives inside the Files window rather than on the panel layer, because
// the window is a surface of its own and a menu drawn on another one would
// be behind it. That also means it positions itself in the window's
// coordinates, which is what `openAt` is given.
PanelSurface {
    id: menu

    required property var app
    readonly property var svc: FilesService

    // What was right-clicked: an entry, or null for the background.
    property var target: null
    property bool open: false

    showSeam: false
    visible: open
    z: 900
    implicitWidth: 236
    implicitHeight: column.implicitHeight + 12

    function openAt(x, y, entry) {
        menu.target = entry || null;
        // Right-clicking something outside the selection makes it the
        // selection first, the way every file manager does; right-clicking
        // inside one leaves the whole selection alone.
        if (entry && !menu.app.isSelected(entry.name)) menu.app.select(entry.name, false);
        if (!entry) menu.app.clearSelection();
        menu.open = true;
        // Flip rather than overflow when it would leave the window.
        const parentW = menu.parent ? menu.parent.width : 0;
        const parentH = menu.parent ? menu.parent.height : 0;
        menu.x = Math.max(6, Math.min(x, parentW - menu.implicitWidth - 6));
        menu.y = Math.max(6, Math.min(y, parentH - menu.implicitHeight - 6));
    }

    function close() { menu.open = false; menu.target = null; }

    readonly property int count: menu.app.selection.length
    readonly property string plural: count === 1 ? "" : "s"

    readonly property var entries: {
        const out = [];
        const t = menu.target;

        if (menu.app.inTrash) {
            if (t) {
                out.push({ n: "Restore" + (count > 1 ? " " + count + " items" : ""),
                           icon: "rotateCw",
                           run: () => menu.app.restoreSelected() });
                out.push({ n: "Delete permanently", icon: "trash",
                           run: () => { menu.app.trashSelected(); } });
            }
            out.push({ n: "Empty trash", icon: "trash", rule: out.length > 0,
                       run: () => menu.app.confirmingEmpty = true });
            return out;
        }

        if (t) {
            out.push({ n: t.dir ? "Open" : "Open", icon: t.dir ? "folderOpen" : "cornerDownLeft",
                       run: () => menu.app.activate(t) });
            if (!t.dir)
                out.push({ n: "Open with…", icon: "grid",
                           run: () => menu.svc.openWith(menu.svc.join(menu.app.cwd, t.name)) });
            if (t.dir)
                out.push({ n: "Open in terminal", icon: "terminal",
                           run: () => menu.svc.openTerminal(menu.svc.join(menu.app.cwd, t.name)) });

            out.push({ n: "Cut", icon: "x", rule: true,
                       run: () => menu.svc.cut(menu.app.selectedPaths()) });
            out.push({ n: "Copy", icon: "file",
                       run: () => menu.svc.copyToClipboard(menu.app.selectedPaths()) });
            out.push({ n: "Copy path", icon: "code",
                       run: () => menu.svc.copyPathToClipboard(menu.app.selectedPaths()) });
            out.push({ n: "Rename…", icon: "sliders", rule: true,
                       run: () => { if (menu.count === 1) menu.app.renaming = t.name; } });
            out.push({ n: "Move to trash", icon: "trash",
                       run: () => menu.app.trashSelected() });
        } else {
            out.push({ n: "New folder", icon: "plus",
                       run: () => menu.app.creatingFolder = true });
            if (menu.svc.hasClipboard)
                out.push({ n: "Paste", icon: "download",
                           run: () => menu.app.pasteHere() });
            out.push({ n: "Open in terminal", icon: "terminal", rule: true,
                       run: () => menu.svc.openTerminal(menu.app.cwd) });
            out.push({ n: menu.svc.isBookmarked(menu.app.cwd)
                          ? "Remove bookmark" : "Bookmark this folder",
                       icon: "star",
                       run: () => menu.svc.toggleBookmark(menu.app.cwd) });
            out.push({ n: FilesService.showHidden
                          ? "Hide hidden files" : "Show hidden files",
                       icon: "eye", rule: true,
                       run: () => FilesService.showHidden =
                                  !FilesService.showHidden });
            // No settings window of its own: the view controls are in the
            // toolbar and the rest is a small JSON file.
        }
        return out;
    }

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 6
        spacing: 0

        Repeater {
            model: menu.entries

            Item {
                id: item
                required property var modelData
                width: column.width
                height: modelData.rule === true ? 41 : 36

                Rectangle {
                    visible: item.modelData.rule === true
                    anchors.top: parent.top
                    anchors.topMargin: 2
                    width: parent.width
                    height: 1
                    color: Appearance.rule
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 36
                    radius: Appearance.rPill
                    color: rowHover.hovered ? Appearance.accent : "transparent"

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: item.modelData.icon
                            size: 14
                            inkColor: rowHover.hovered ? Appearance.onAccent
                                                       : Appearance.ink
                            accentColor: rowHover.hovered ? Appearance.onAccent
                                                          : Appearance.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: item.modelData.n
                            font.pixelSize: Appearance.fs(12)
                            color: rowHover.hovered ? Appearance.onAccent
                                                    : Appearance.ink
                        }
                    }

                    HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            const run = item.modelData.run;
                            menu.close();
                            if (run) run();
                        }
                    }
                }
            }
        }
    }
}
