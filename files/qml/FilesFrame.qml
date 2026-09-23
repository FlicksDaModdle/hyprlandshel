import QtQuick
import Hyprshell

// The file manager's chrome, independent of which kind of window it is
// mounted in. See Files.qml.
//
// The layout is the design's: a title bar with the accent bead, a places
// sidebar with item counts, a pill breadcrumb with the view switch and the
// New button beside it, the files themselves, and a status bar.
PanelSurface {
    id: frame

    // The host contract, the same one SettingsFrame uses: width, height,
    // tiled, maximised, normalWidth, normalHeight, workTop, workBottom and
    // moveTo(x, y). `app` is Files.qml, which holds the state.
    required property var host
    required property var app

    readonly property var svc: FilesService

    showSeam: false
    color: Appearance.sheet
    radius: Appearance.rWin

    width: frame.host.tiled ? frame.host.width
           : (frame.host.maximised ? frame.host.width - 16 : frame.host.normalWidth)
    height: frame.host.tiled ? frame.host.height
            : (frame.host.maximised
               ? Math.max(320, frame.host.workBottom - frame.host.workTop)
               : frame.host.normalHeight)

    x: frame.host.tiled ? 0
       : (frame.host.maximised ? 8
          : (Config.UiState.filesX >= 0
             ? Math.max(0, Math.min(frame.host.width - width, Config.UiState.filesX))
             : Math.round((frame.host.width - width) / 2)))
    y: frame.host.tiled ? 0
       : (frame.host.maximised ? frame.host.workTop
          : (Config.UiState.filesY >= 0
             ? Math.max(Appearance.barHeight,
                        Math.min(frame.host.height - height, Config.UiState.filesY))
             : Math.round((frame.host.height - height) / 2)))

    Behavior on width  { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Behavior on height { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    // ── keyboard ──────────────────────────────────────────────────────────
    // On the frame rather than on the view, so the shortcuts work wherever
    // the focus happens to be — except while a name is being typed, which
    // takes focus itself and gets first refusal on every key.
    focus: true
    Keys.onPressed: event => {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        if (ctrl && event.key === Qt.Key_A) { frame.app.selectAll(); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_C) { frame.svc.copyToClipboard(frame.app.selectedPaths()); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_X) { frame.svc.cut(frame.app.selectedPaths()); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_V) { frame.app.pasteHere(); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_H) { FilesService.showHidden = !FilesService.showHidden; event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_L) { crumbEdit.begin(); event.accepted = true; return; }

        switch (event.key) {
        case Qt.Key_Escape:
            if (frame.app.confirmingEmpty) frame.app.confirmingEmpty = false;
            else if (frame.app.selection.length) frame.app.clearSelection();
            else Config.UiState.closeFiles();
            event.accepted = true;
            break;
        case Qt.Key_Backspace:  frame.app.up(); event.accepted = true; break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (frame.app.selection.length === 1)
                frame.app.activate(frame.app.visibleEntries.find(e => e.name === frame.app.selection[0]));
            event.accepted = true;
            break;
        case Qt.Key_Delete:
            if (frame.app.inTrash) frame.app.confirmingEmpty = true;
            else frame.app.trashSelected();
            event.accepted = true;
            break;
        case Qt.Key_F2:
            if (frame.app.selection.length === 1) frame.app.renaming = frame.app.selection[0];
            event.accepted = true;
            break;
        case Qt.Key_Left:  frame.app.moveSelection(-1); event.accepted = true; break;
        case Qt.Key_Right: frame.app.moveSelection(1);  event.accepted = true; break;
        case Qt.Key_Up:
            frame.app.moveSelection(frame.app.view === "grid" ? -grid.columns : -1);
            event.accepted = true;
            break;
        case Qt.Key_Down:
            frame.app.moveSelection(frame.app.view === "grid" ? grid.columns : 1);
            event.accepted = true;
            break;
        }
    }

    // ── title bar ─────────────────────────────────────────────────────────
    Item {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 40

        MouseArea {
            anchors.fill: parent
            cursorShape: (frame.host.tiled || frame.host.maximised)
                             ? Qt.ArrowCursor : Qt.OpenHandCursor
            property real pressX: 0
            property real pressY: 0
            onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; }
            onPositionChanged: mouse => {
                if (!pressed || frame.host.tiled || frame.host.maximised) return;
                const p = mapToItem(null, mouse.x, mouse.y);
                frame.host.moveTo(Math.round(p.x - pressX), Math.round(p.y - pressY));
            }
            onDoubleClicked: if (!frame.host.tiled)
                                 Config.UiState.filesMaximized = !frame.host.maximised
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 3
                height: 16
                radius: 2
                color: Appearance.accent
            }

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "folder"
                size: 15
                inkColor: Appearance.ink2
                accentColor: Appearance.accent
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Files"
                font.pixelSize: Appearance.fs(13)
                font.weight: Font.DemiBold
                font.letterSpacing: 0.13
            }

            // The folder you are in, beside the title, as the design has it.
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: frame.app.inTrash ? "Trash" : frame.svc.basename(frame.app.cwd)
                font.pixelSize: Appearance.fs(12)
                font.weight: Font.Normal
                color: Appearance.ink3
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 220)
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // Tiled, the compositor owns the geometry: a maximise button
            // would do nothing and a minimise button would be a confusing
            // way to close. Only the close button means anything there.
            Repeater {
                model: frame.host.tiled
                    ? [{ glyph: "x", danger: true, act: () => Config.UiState.closeFiles() }]
                    : [
                    { glyph: "minus",  danger: false, act: () => Config.UiState.minimiseFiles() },
                    { glyph: "square", danger: false, act: () => Config.UiState.filesMaximized = !frame.host.maximised },
                    { glyph: "x",      danger: true,  act: () => Config.UiState.closeFiles() }
                ]

                Rectangle {
                    id: winBtn
                    required property var modelData
                    width: 28
                    height: 28
                    radius: Appearance.rSm
                    color: !btnArea.containsMouse ? "transparent"
                         : (modelData.danger ? Appearance.accent : Appearance.hover)

                    MonoIcon {
                        anchors.centerIn: parent
                        name: winBtn.modelData.glyph
                        size: 13
                        inkColor: btnArea.containsMouse && winBtn.modelData.danger
                                  ? Appearance.onAccent : Appearance.ink2
                        monochrome: true
                    }

                    MouseArea {
                        id: btnArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: winBtn.modelData.act()
                    }
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            color: Appearance.rule
        }
    }

    // ── places sidebar ────────────────────────────────────────────────────
    Item {
        id: sidebar
        anchors.left: parent.left
        anchors.top: titleBar.bottom
        anchors.bottom: statusBar.top
        width: 232

        Flickable {
            anchors.fill: parent
            anchors.topMargin: 14
            contentHeight: places.implicitHeight + 24
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: places
                width: parent.width
                spacing: 2

                StyledText {
                    x: 20
                    text: "PLACES"
                    font.pixelSize: Appearance.fs(10)
                    font.weight: Font.Bold
                    font.letterSpacing: 1.1
                    color: Appearance.accent
                    bottomPadding: 6
                }

                Repeater {
                    model: frame.svc.places

                    PlaceRow {
                        required property var modelData
                        width: places.width
                        place: modelData
                        app: frame.app
                        count: frame.svc.placeCounts[modelData.path]
                    }
                }

                // The design's DOTFILES section: whatever you have pinned.
                // Hidden entirely when there is nothing in it, rather than
                // sitting there as an empty heading.
                StyledText {
                    x: 20
                    visible: frame.svc.bookmarks.length > 0
                    text: "BOOKMARKS"
                    font.pixelSize: Appearance.fs(10)
                    font.weight: Font.Bold
                    font.letterSpacing: 1.1
                    color: Appearance.ink3
                    topPadding: 14
                    bottomPadding: 6
                }

                Repeater {
                    model: frame.svc.bookmarks

                    PlaceRow {
                        required property var modelData
                        width: places.width
                        place: ({ label: frame.svc.basename(modelData),
                                  path: modelData, icon: "folder" })
                        app: frame.app
                        count: frame.svc.placeCounts[modelData]
                    }
                }
            }
        }

        Rectangle {
            anchors.right: parent.right
            width: 1
            height: parent.height
            color: Appearance.rule
        }
    }

    // ── toolbar: back/forward, breadcrumb, view switch, New ───────────────
    Item {
        id: toolbar
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        height: 68

        Row {
            id: navRow
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Repeater {
                model: [
                    { glyph: "chevronLeft",  act: () => frame.app.back(),    on: frame.app.canBack },
                    { glyph: "chevronRight", act: () => frame.app.forward(), on: frame.app.canForward }
                ]

                Rectangle {
                    id: navBtn
                    required property var modelData
                    width: 30
                    height: 30
                    radius: Appearance.rSm
                    color: navArea.containsMouse && navBtn.modelData.on
                           ? Appearance.hover : "transparent"

                    MonoIcon {
                        anchors.centerIn: parent
                        name: navBtn.modelData.glyph
                        size: 16
                        inkColor: navBtn.modelData.on ? Appearance.ink2
                                                      : Appearance.ink3
                        monochrome: true
                        opacity: navBtn.modelData.on ? 1 : 0.4
                    }

                    MouseArea {
                        id: navArea
                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: navBtn.modelData.on
                        cursorShape: Qt.PointingHandCursor
                        onClicked: navBtn.modelData.act()
                    }
                }
            }
        }

        // The breadcrumb, in its pill. Clicking a segment goes there;
        // ctrl-L or clicking the empty part turns it into a path field.
        Rectangle {
            id: crumbPill
            anchors.left: navRow.right
            anchors.leftMargin: 10
            anchors.right: pinButton.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            height: 40
            radius: Appearance.rSm
            color: Appearance.surface

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                onClicked: crumbEdit.begin()
            }

            Row {
                id: crumbRow
                visible: !crumbEdit.active
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Repeater {
                    model: frame.app.inTrash
                           ? [{ label: "Trash", path: frame.svc.trashFiles }]
                           : frame.svc.crumbs(frame.app.cwd)

                    Row {
                        required property var modelData
                        required property int index
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter

                        MonoIcon {
                            visible: index > 0
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevronRight"
                            size: 13
                            inkColor: Appearance.ink3
                            monochrome: true
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: crumbLabel.implicitWidth + 14
                            height: 26
                            radius: Appearance.rSm
                            color: crumbArea.containsMouse ? Appearance.hover : "transparent"

                            StyledText {
                                id: crumbLabel
                                anchors.centerIn: parent
                                text: modelData.label
                                font.pixelSize: Appearance.fs(13)
                                // Where you are, by path rather than by
                                // counting children: a Repeater is itself
                                // one of its parent's children, so an index
                                // compared against children.length is off
                                // by one and silently picks the wrong
                                // segment.
                                font.weight: modelData.path === frame.app.cwd
                                             ? Font.DemiBold : Font.Medium
                                color: modelData.path === frame.app.cwd
                                       ? Appearance.ink : Appearance.ink2
                            }

                            MouseArea {
                                id: crumbArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: frame.app.go(modelData.path)
                            }
                        }
                    }
                }
            }

            // Type a path. Escape puts the crumbs back.
            TextInput {
                id: crumbEdit
                property bool active: false
                function begin() {
                    text = frame.svc.pretty(frame.app.cwd);
                    active = true;
                    forceActiveFocus();
                    selectAll();
                }
                function finish() {
                    active = false;
                    frame.forceActiveFocus();
                }

                visible: active
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                font.family: Appearance.fontFamily
                font.pixelSize: Appearance.fs(13)
                color: Appearance.ink
                selectionColor: Appearance.accent
                selectedTextColor: Appearance.onAccent
                clip: true

                onAccepted: {
                    const want = text.trim().replace(/^~/, frame.svc.home);
                    finish();
                    if (want) frame.app.go(want);
                }
                Keys.onEscapePressed: finish()
            }
        }

        // Grid / list, then New — the design's own pair.
        Row {
            id: viewRow
            anchors.right: newButton.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Repeater {
                model: [
                    { glyph: "grid",   mode: "grid" },
                    { glyph: "layout", mode: "list" }
                ]

                Rectangle {
                    id: viewBtn
                    required property var modelData
                    readonly property bool on: FilesService.view === modelData.mode
                    width: 38
                    height: 34
                    radius: Appearance.rSm
                    color: on ? Appearance.accent
                         : (viewArea.containsMouse ? Appearance.hover : "transparent")

                    MonoIcon {
                        anchors.centerIn: parent
                        name: viewBtn.modelData.glyph
                        size: 16
                        inkColor: viewBtn.on ? Appearance.onAccent : Appearance.ink2
                        monochrome: true
                    }

                    MouseArea {
                        id: viewArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: FilesService.view = viewBtn.modelData.mode
                    }
                }
            }
        }

        // Pin this folder into the sidebar. A star rather than a menu item,
        // because it is a toggle and it should show its state.
        Rectangle {
            id: pinButton
            anchors.right: viewRow.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 34
            height: 34
            radius: Appearance.rSm
            visible: !frame.app.inTrash && frame.app.cwd !== ""
            color: pinArea.containsMouse ? Appearance.hover : "transparent"

            MonoIcon {
                anchors.centerIn: parent
                name: "star"
                size: 16
                inkColor: frame.svc.isBookmarked(frame.app.cwd)
                          ? Appearance.accent : Appearance.ink3
                monochrome: true
            }

            MouseArea {
                id: pinArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: frame.svc.toggleBookmark(frame.app.cwd)
            }
        }

        Rectangle {
            id: newButton
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            width: newRow.implicitWidth + 30
            height: 38
            radius: Appearance.rSm
            color: Appearance.accent
            opacity: newArea.containsMouse ? 0.9 : 1
            visible: !frame.app.inTrash

            Row {
                id: newRow
                anchors.centerIn: parent
                spacing: 6

                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "plus"
                    size: 15
                    inkColor: Appearance.onAccent
                    monochrome: true
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "New"
                    font.pixelSize: Appearance.fs(13)
                    font.weight: Font.DemiBold
                    color: Appearance.onAccent
                }
            }

            MouseArea {
                id: newArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: frame.app.creatingFolder = true
            }
        }

        // Emptying the trash is the one thing in here that cannot be undone,
        // so it asks, in place, rather than doing it and hoping.
        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            width: emptyRow.implicitWidth + 30
            height: 38
            radius: Appearance.rSm
            color: frame.app.confirmingEmpty ? Appearance.accent : Appearance.surface
            visible: frame.app.inTrash && frame.app.visibleEntries.length > 0

            Row {
                id: emptyRow
                anchors.centerIn: parent
                spacing: 6

                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "trash"
                    size: 15
                    inkColor: frame.app.confirmingEmpty ? Appearance.onAccent
                                                        : Appearance.ink2
                    monochrome: true
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: frame.app.confirmingEmpty ? "Delete them permanently?" : "Empty Trash"
                    font.pixelSize: Appearance.fs(13)
                    font.weight: Font.DemiBold
                    color: frame.app.confirmingEmpty ? Appearance.onAccent
                                                     : Appearance.ink
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (frame.app.confirmingEmpty) {
                        frame.svc.emptyTrash();
                        frame.app.confirmingEmpty = false;
                    } else {
                        frame.app.confirmingEmpty = true;
                    }
                }
            }
        }
    }

    // ── the files ─────────────────────────────────────────────────────────
    Item {
        id: body
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.top: toolbar.bottom
        anchors.bottom: statusBar.top

        // Clicking the empty space drops the selection, the way every file
        // manager does; right-clicking it is the folder's own menu.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    const p = mapToItem(menuLayer, mouse.x, mouse.y);
                    frame.app.openMenu(p.x, p.y, null);
                } else {
                    frame.app.clearSelection();
                }
            }
        }

        // Anything dropped on the folder's own space lands in the folder.
        DropArea {
            anchors.fill: parent
            keys: ["text/uri-list"]
            onDropped: drop => frame.app.dropOnto(drop, frame.app.cwd)
        }

        Flickable {
            id: flick
            anchors.fill: parent
            anchors.margins: 16
            contentHeight: frame.app.view === "grid" ? grid.implicitHeight : list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Grid {
                id: grid
                visible: frame.app.view === "grid"
                width: parent.width
                columns: Math.max(1, Math.floor(width / tileWidth))
                readonly property real tileWidth: Math.round(140 * FilesService.iconSize / 100)
                spacing: 0

                // The waiting-to-be-named folder sits first, as a tile you
                // type into, so a new folder never appears unnamed.
                NewNameTile {
                    visible: frame.app.creatingFolder
                    width: grid.tileWidth
                    app: frame.app
                    gridView: true
                }

                Repeater {
                    model: frame.app.visibleEntries

                    FileTile {
                        id: gridTile
                        required property var modelData
                        width: grid.tileWidth
                        entry: modelData
                        app: frame.app
                        // A row of slack either side, so scrolling does not
                        // show a column of empty plates catching up.
                        inView: (gridTile.y + gridTile.height) > flick.contentY - gridTile.height
                                && gridTile.y < flick.contentY + flick.height + gridTile.height
                    }
                }
            }

            Column {
                id: list
                visible: frame.app.view === "list"
                width: parent.width
                spacing: 0

                NewNameTile {
                    visible: frame.app.creatingFolder
                    width: list.width
                    app: frame.app
                    gridView: false
                }

                Repeater {
                    model: frame.app.visibleEntries

                    FileRow {
                        required property var modelData
                        width: list.width
                        entry: modelData
                        app: frame.app
                    }
                }
            }
        }

        // An empty directory should say so rather than look broken.
        StyledText {
            anchors.centerIn: parent
            visible: !frame.app.loading && frame.app.visibleEntries.length === 0
                     && !frame.app.creatingFolder
            text: frame.app.inTrash ? "The trash is empty"
                : (frame.app.entries.length > 0 ? "Nothing here but hidden files"
                                                : "This folder is empty")
            font.pixelSize: Appearance.fs(13)
            color: Appearance.ink3
        }
    }

    // ── the right-click menu ──────────────────────────────────────────────
    // Above every other part of the window, with a full-window catcher
    // under it so a click anywhere else puts it away.
    Item {
        id: menuLayer
        anchors.fill: parent
        z: 900

        MouseArea {
            anchors.fill: parent
            visible: fileMenu.open
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPressed: fileMenu.close()
        }

        FileMenu {
            id: fileMenu
            app: frame.app
        }
    }

    Component.onCompleted: {
        frame.app.menuLayer = menuLayer;
        frame.app.menu = fileMenu;
    }

    // ── status bar ────────────────────────────────────────────────────────
    Item {
        id: statusBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 34

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Appearance.rule
        }

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: freeLabel.left
            anchors.rightMargin: 12
            elide: Text.ElideRight
            font.pixelSize: Appearance.fs(12)
            color: frame.svc.lastError ? Appearance.accent : Appearance.ink3
            text: {
                if (frame.svc.lastError) return frame.svc.lastError;
                const n = frame.app.visibleEntries.length;
                const items = n + (n === 1 ? " item" : " items");
                const sel = frame.app.selection.length;
                if (sel === 1) return items + " · " + frame.app.selection[0] + " selected";
                if (sel > 1) return items + " · " + sel + " selected";
                return items;
            }
        }

        StyledText {
            id: freeLabel
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: frame.svc.freeSpace
            font.pixelSize: Appearance.fs(12)
            color: Appearance.ink3
        }
    }
}
