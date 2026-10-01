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
        menu.subs = [];
        menu.target = entry || null;
        // Right-clicking something outside the selection makes it the
        // selection first, the way every file manager does; right-clicking
        // inside one leaves the whole selection alone.
        if (entry && !menu.app.isSelected(entry.name)) menu.app.select(entry.name, false);
        if (!entry) menu.app.clearSelection();
        menu.atX = x;
        menu.atY = y;
        menu.open = true;
    }
    // Where it was asked for, kept inside the window. A binding, not set
    // once in openAt: the entries — and so the height — follow the
    // selection, which openAt has only just changed.
    property real atX: 0
    property real atY: 0
    x: Math.max(6, Math.min(menu.atX, (menu.parent ? menu.parent.width : 0) - menu.implicitWidth - 6))
    y: Math.max(6, Math.min(menu.atY, (menu.parent ? menu.parent.height : 0) - menu.implicitHeight - 6))

    function close() { menu.open = false; menu.target = null; menu.subs = []; }

    // Cascading submenus, 7-Zip's and its CRC SHA: the open ones, outermost
    // first, as { from, entries, x, y }. Drawn beside this one, on the
    // same layer.
    property var subs: []
    readonly property real subWidth: 270

    function rowHeight(e) { return e.rule === true ? 41 : 36; }
    function isOpenSub(e) {
        const k = e.lvl || 0;
        return !!e.sub && menu.subs.length > k && menu.subs[k].from === e.n;
    }
    // Hovering a row opens its submenu, or closes any deeper one.
    function hoverAt(e, item) {
        const k = e.lvl || 0;
        if (!e.sub) { if (menu.subs.length > k) menu.subs = menu.subs.slice(0, k); return; }
        if (menu.isOpenSub(e)) return;
        const host = menu.parent;
        if (!host) return;
        const p = item.mapToItem(host, 0, 0);
        const entries = e.sub.map(x => Object.assign({}, x, { lvl: k + 1 }));
        const h = entries.reduce((a, x) => a + menu.rowHeight(x), 0) + 12;
        let x = p.x + item.width + 4;
        if (x + menu.subWidth > host.width - 6) x = p.x - menu.subWidth - 4;
        const y = Math.max(6, Math.min(p.y - 6, host.height - h - 6));
        menu.subs = menu.subs.slice(0, k).concat([{ from: e.n, entries: entries, x: x, y: y }]);
    }

    readonly property int count: menu.app.selection.length
    readonly property string plural: count === 1 ? "" : "s"

    // What 7-Zip puts in Explorer's menu for this selection.
    function sevenZip(t) {
        const app = menu.app;
        const one = menu.count === 1;
        const base = one ? (t.dir ? t.name : (t.name.replace(/\.[^./]+$/, "") || t.name))
                         : (menu.svc.basename(app.cwd) || "Archive");
        const isArc = one && !t.dir && Archives.isArchive(t.name);
        const out = [];
        if (one && !t.dir)
            out.push({ n: "Open archive", icon: "archive", run: () => app.browseArchive(t) });
        if (isArc) {
            const stem = Archives.stem(t.name);
            out.push({ n: "Extract files...", icon: "folderOpen", run: () => app.extractTo(t) });
            out.push({ n: "Extract Here", icon: "download", run: () => app.extractHere(t) });
            out.push({ n: "Extract to \"" + stem + "/\"", icon: "folder", run: () => app.extractToFolder(t) });
            out.push({ n: "Test archive", icon: "check", run: () => Archives.test(menu.svc.join(app.cwd, t.name), "") });
        }
        out.push({ n: "Add to archive...", icon: "package", rule: out.length > 0, run: () => app.compressSelected() });
        out.push({ n: "Add to \"" + base + ".7z\"", icon: "archive", run: () => app.quickAdd(base + ".7z", "7z") });
        out.push({ n: "Add to \"" + base + ".zip\"", icon: "archive", run: () => app.quickAdd(base + ".zip", "zip") });
        out.push({ n: "CRC SHA", icon: "hash", rule: true,
                   sub: Archives.hashMethods.map(m => ({ n: m, icon: "hash", run: () => app.checksumSelected(m) })) });
        return out;
    }

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
            if (t.dir) {
                out.push({ n: "Open in terminal", icon: "terminal",
                           run: () => menu.svc.openTerminal(menu.svc.join(menu.app.cwd, t.name)) });
                // Any folder can go in the sidebar, not just the one you
                // happen to be standing in.
                const path = menu.svc.join(menu.app.cwd, t.name);
                out.push({ n: menu.svc.isBookmarked(path)
                              ? "Remove from sidebar" : "Add to sidebar",
                           icon: "star",
                           run: () => menu.svc.toggleBookmark(path) });
            }

            // 7-Zip's own menu, cascaded as it is in Explorer.
            out.push({ n: "7-Zip", icon: "archive", rule: true, sub: menu.sevenZip(t) });

            out.push({ n: "Cut", icon: "x", rule: true,
                       run: () => menu.svc.cut(menu.app.selectedPaths()) });
            out.push({ n: "Copy", icon: "file",
                       run: () => menu.svc.copyToClipboard(menu.app.selectedPaths()) });
            out.push({ n: "Copy path", icon: "code",
                       run: () => menu.svc.copyPathToClipboard(menu.app.selectedPaths()) });
            out.push({ n: "Duplicate", icon: "plus",
                       run: () => menu.app.duplicateSelected() });
            out.push({ n: "Rename…", icon: "sliders", rule: true,
                       run: () => { if (menu.count === 1) menu.app.renaming = t.name; } });
            out.push({ n: "Move to trash", icon: "trash",
                       run: () => menu.app.trashSelected() });
            out.push({ n: "Delete permanently…", icon: "x",
                       run: () => menu.app.confirmingDelete = true });
            out.push({ n: "Properties", icon: "info", rule: true,
                       run: () => menu.app.showProperties() });
        } else {
            out.push({ n: "New folder", icon: "plus",
                       run: () => menu.app.creatingFolder = true });
            out.push({ n: "New file", icon: "file",
                       run: () => menu.app.creatingFile = true });
            if (menu.svc.hasClipboard)
                out.push({ n: "Paste", icon: "download",
                           run: () => menu.app.pasteHere() });
            out.push({ n: "Open in terminal", icon: "terminal", rule: true,
                       run: () => menu.svc.openTerminal(menu.app.cwd) });
            // The same words as the per-folder entry above, so the two
            // ways of doing it do not read as two different features.
            out.push({ n: menu.svc.isBookmarked(menu.app.cwd)
                          ? "Remove this folder from sidebar"
                          : "Add this folder to sidebar",
                       icon: "star",
                       run: () => menu.svc.toggleBookmark(menu.app.cwd) });
            // Only offered where it does something: grouping follows the
            // date sort, so under any other sort this would be a switch
            // with no visible effect.
            if (menu.svc.sortBy === "modified" && !menu.app.inTrash)
                out.push({ n: menu.svc.groupByDate
                              ? "Stop grouping by date" : "Group by date",
                           icon: "list", rule: true,
                           run: () => menu.svc.groupByDate = !menu.svc.groupByDate });

            out.push({ n: "Select all", icon: "check", rule: true,
                       run: () => menu.app.selectAll() });
            out.push({ n: "Invert selection", icon: "refresh",
                       run: () => menu.app.invertSelection() });
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

    // One row, for this menu and its submenus alike.
    Component {
        id: rowComp

        Item {
            id: item
            required property var modelData
            readonly property bool lit: rowHover.hovered || menu.isOpenSub(item.modelData)
            width: parent ? parent.width : 0
            height: menu.rowHeight(item.modelData)

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
                color: item.lit ? Appearance.accent : "transparent"

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 11
                    anchors.right: parent.right
                    anchors.rightMargin: 30
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    MonoIcon {
                        id: rowIcon
                        anchors.verticalCenter: parent.verticalCenter
                        name: item.modelData.icon
                        size: 18
                        inkColor: item.lit ? Appearance.inkOnAccent : Appearance.ink
                        accentColor: item.lit ? Appearance.inkOnAccent : Appearance.accent
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - rowIcon.width - 10
                        elide: Text.ElideMiddle
                        text: item.modelData.n
                        font.pixelSize: Appearance.fs(12)
                        color: item.lit ? Appearance.inkOnAccent : Appearance.ink
                    }
                }
                MonoIcon {
                    visible: !!item.modelData.sub
                    anchors.right: parent.right
                    anchors.rightMargin: 9
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevronRight"
                    size: 14
                    inkColor: item.lit ? Appearance.inkOnAccent : Appearance.ink2
                    accentColor: inkColor
                }

                HoverHandler {
                    id: rowHover
                    cursorShape: Qt.PointingHandCursor
                    onHoveredChanged: if (hovered) menu.hoverAt(item.modelData, item)
                }
                TapHandler {
                    onTapped: {
                        if (item.modelData.sub) { menu.hoverAt(item.modelData, item); return; }
                        const run = item.modelData.run;
                        menu.close();
                        if (run) run();
                    }
                }
            }
        }
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
            delegate: rowComp
        }
    }

    // The submenus, beside this one on the window's menu layer.
    Item {
        parent: menu.parent
        anchors.fill: parent
        z: 901
        Repeater {
            model: menu.open ? menu.subs : []
            PanelSurface {
                id: subPanel
                required property var modelData
                showSeam: false
                x: subPanel.modelData.x
                y: subPanel.modelData.y
                width: menu.subWidth
                height: subCol.implicitHeight + 12

                Column {
                    id: subCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 6
                    Repeater {
                        model: subPanel.modelData.entries
                        delegate: rowComp
                    }
                }
            }
        }
    }
}
