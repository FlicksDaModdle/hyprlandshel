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
    // The window manager owns the geometry in an application, so the
    // frame is simply the whole window: Main.qml anchors it, there is
    // nothing to place and nothing to animate.

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
        if (ctrl && event.key === Qt.Key_F) { searchField.begin(); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_I) { frame.app.showProperties(); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_D) { frame.app.duplicateSelected(); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_N) { frame.app.creatingFolder = true; event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_B) { frame.svc.toggleBookmark(frame.app.cwd); event.accepted = true; return; }
        if (ctrl && (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal)) {
            frame.app.zoom(10); event.accepted = true; return;
        }
        if (ctrl && event.key === Qt.Key_Minus) { frame.app.zoom(-10); event.accepted = true; return; }
        if (ctrl && event.key === Qt.Key_0) { frame.svc.iconSize = 100; event.accepted = true; return; }

        switch (event.key) {
        case Qt.Key_Escape:
            // Unwinds, in the order things were put up: a confirmation, the
            // properties sheet, the filter, the selection, then the window.
            if (frame.app.confirmingEmpty || frame.app.confirmingDelete) {
                frame.app.confirmingEmpty = false;
                frame.app.confirmingDelete = false;
            } else if (frame.app.propertiesFor) {
                frame.app.propertiesFor = null;
            } else if (frame.app.filtering || frame.app.filter !== "") {
                frame.app.filter = "";
                frame.app.filtering = false;
            } else if (frame.app.selection.length) {
                frame.app.selectNone();
            } else {
                frame.host.close();
            }
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
            // Shift is the everywhere-convention for "and do not keep it".
            if (event.modifiers & Qt.ShiftModifier) frame.app.confirmingDelete = true;
            else if (frame.app.inTrash) frame.app.confirmingEmpty = true;
            else frame.app.trashSelected();
            event.accepted = true;
            break;
        case Qt.Key_F5:
            frame.app.reload();
            event.accepted = true;
            break;
        case Qt.Key_Home:
        case Qt.Key_End: {
            const list = frame.app.visibleEntries;
            if (list.length) {
                const pick = event.key === Qt.Key_Home ? list[0] : list[list.length - 1];
                if (event.modifiers & Qt.ShiftModifier) frame.app.selectTo(pick.name, false);
                else frame.app.select(pick.name, false);
            }
            event.accepted = true;
            break;
        }
        case Qt.Key_PageUp:
        case Qt.Key_PageDown: {
            const per = frame.app.view === "grid" ? grid.columns * 3 : 12;
            frame.app.moveSelection(event.key === Qt.Key_PageUp ? -per : per);
            event.accepted = true;
            break;
        }
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
        default:
            // Anything printable jumps to the next name starting with it,
            // which is how a file list has always behaved. Modifiers are
            // excluded so a missed shortcut does not move the selection.
            if (!ctrl && !(event.modifiers & Qt.AltModifier)
                && event.text.length === 1 && event.text >= " ") {
                frame.app.jumpTo(event.text);
                event.accepted = true;
            }
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

        // Dragging the bar moves the window.
        //
        // This used to bail out whenever the host said `tiled`, which for
        // an application window is always — so the title bar could not be
        // dragged at all. Tiled is not a reason to refuse: moveTo() hands
        // the drag to the compositor, and dragging a tiled window is how
        // you swap it with another one. The compositor decides what the
        // gesture means; this only has to start it.
        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.OpenHandCursor
            property real pressX: 0
            property real pressY: 0
            // Started once per press, and only after the pointer has
            // actually travelled: the compositor takes the pointer for the
            // whole drag, so starting on the press itself would eat the
            // double-click that maximises.
            property bool moving: false
            onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; moving = false; }
            onReleased: moving = false
            onPositionChanged: mouse => {
                if (!pressed || moving) return;
                if (Math.abs(mouse.x - pressX) < 4 && Math.abs(mouse.y - pressY) < 4)
                    return;
                moving = true;
                const p = mapToItem(null, mouse.x, mouse.y);
                frame.host.moveTo(Math.round(p.x - pressX), Math.round(p.y - pressY));
            }
            onDoubleClicked: frame.host.toggleMaximised()
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11

            // The bead: accent while this window has focus, quiet ink when
            // it does not — as the browser's does — so the window being
            // typed into is the one with the colour in its corner.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 3
                height: 16
                radius: 2
                color: frame.host.active ? Appearance.accent : Appearance.ink3
            }

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "folder"
                size: 20
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

            // The window's own controls. They act on the window rather
            // than on any shell state — minimise and maximise are its
            // visibility, close ends the application.
            Repeater {
                model: frame.host.tiled
                    ? [
                    { glyph: "minus",  danger: false, act: () => frame.host.minimise() },
                    { glyph: "square", danger: false, act: () => frame.host.toggleMaximised() },
                    { glyph: "x",      danger: true,  act: () => frame.host.close() }
                ] : []

                Rectangle {
                    id: winBtn
                    required property var modelData
                    width: 30
                    height: 30
                    radius: Appearance.rSm
                    color: !btnArea.containsMouse ? "transparent"
                         : (modelData.danger ? Appearance.accent : Appearance.hover)

                    MonoIcon {
                        anchors.centerIn: parent
                        name: winBtn.modelData.glyph
                        size: 17
                        inkColor: btnArea.containsMouse && winBtn.modelData.danger
                                  ? Appearance.inkOnAccent : Appearance.ink2
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
        width: frame.app.showSidebar ? 192 : 0
        visible: width > 0
        clip: true

        Behavior on width { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

        Flickable {
            anchors.fill: parent
            anchors.topMargin: 4
            contentHeight: places.implicitHeight + 16
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: places
                width: parent.width
                spacing: 2

                StyledText {
                    x: 18
                    text: "PLACES"
                    font.pixelSize: Appearance.fs(10.5)
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.26
                    color: Appearance.ink3
                    topPadding: 8
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

                // The design's second section: whatever you have pinned.
                // The concept called it DOTFILES because that is what it
                // held; now that any folder can go here, it says so.
                // Hidden entirely when there is nothing in it, rather than
                // sitting there as an empty heading.
                StyledText {
                    x: 18
                    visible: frame.svc.bookmarks.length > 0
                    text: "PINNED"
                    font.pixelSize: Appearance.fs(10.5)
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.26
                    color: Appearance.ink3
                    topPadding: 10
                    bottomPadding: 6
                }

                Repeater {
                    model: frame.svc.bookmarks

                    PlaceRow {
                        required property var modelData
                        width: places.width
                        place: ({ label: frame.svc.basename(modelData),
                                  path: modelData, icon: "folder",
                                  removable: true })
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
        height: 48

        // Putting the sidebar away, for a narrow window.
        Rectangle {
            id: sidebarToggle
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: 30
            height: 30
            radius: Appearance.rSm
            color: sidebarArea.containsMouse ? Appearance.hover : "transparent"

            MonoIcon {
                anchors.centerIn: parent
                name: "panelsTopLeft"
                size: 20
                inkColor: frame.app.showSidebar ? Appearance.ink2 : Appearance.ink3
                monochrome: true
            }

            MouseArea {
                id: sidebarArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: frame.app.showSidebar = !frame.app.showSidebar
            }
        }

        Row {
            id: navRow
            anchors.left: sidebarToggle.right
            anchors.leftMargin: 4
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
                        size: 20
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
            anchors.right: searchPill.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            height: 30
            radius: Appearance.rSm
            // The concept's pill is the hover tint with a hairline around
            // it, not a solid surface — it sits *in* the toolbar rather
            // than on top of it.
            color: Appearance.hover
            border.width: 1
            border.color: Appearance.rule

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                onClicked: crumbEdit.begin()
            }

            // What fits, from the end. A deep path — /mnt/windows/Program
            // Files (x86)/Steam/steamapps/… — used to run out of the pill
            // and under the buttons beside it. Where you are is the end of
            // it, so that is what is kept: the folders before whatever fits
            // fold into "…", which goes up to the last of them. The whole
            // path is still ctrl-L, or a click on the pill, away.
            readonly property var crumbList: frame.app.inTrash
                ? [{ label: "Trash", path: frame.svc.trashFiles }]
                : frame.svc.crumbs(frame.app.cwd)
            // The longest a single name is shown; past it, it is elided.
            readonly property real crumbMax: 170

            FontMetrics {
                id: crumbMetrics
                font.family: Appearance.fontFamily
                font.pixelSize: Appearance.fs(11.5)
                font.weight: Font.DemiBold
            }

            // Each crumb's width as laid out below: its label (capped), the
            // label's padding, the chevron before it and the gaps.
            function crumbWidth(i) {
                const label = Math.min(crumbPill.crumbMax,
                                       Math.ceil(crumbMetrics.advanceWidth(crumbPill.crumbList[i].label)));
                return label + 10 + (i > 0 ? 15 + 2 : 0) + crumbRow.spacing;
            }
            readonly property real ellipsisWidth: 26 + 15 + 2 + 5
            readonly property int crumbStart: {
                const list = crumbPill.crumbList;
                const room = crumbRow.width;
                if (room <= 0) return 0;
                let used = 0;
                for (let i = list.length - 1; i >= 0; i--) {
                    used += crumbPill.crumbWidth(i);
                    // The one you are in is always shown, however long.
                    if (i < list.length - 1 && used + (i > 0 ? crumbPill.ellipsisWidth : 0) > room)
                        return i + 1;
                }
                return 0;
            }
            clip: true

            Row {
                id: crumbRow
                visible: !crumbEdit.active
                anchors.left: parent.left
                anchors.leftMargin: 11
                anchors.right: parent.right
                anchors.rightMargin: 11
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5

                // The folders folded away.
                Rectangle {
                    visible: crumbPill.crumbStart > 0
                    anchors.verticalCenter: parent.verticalCenter
                    width: 26
                    height: 22
                    radius: Appearance.rSm
                    color: moreArea.containsMouse ? Appearance.hover : "transparent"

                    StyledText {
                        anchors.centerIn: parent
                        text: "…"
                        font.pixelSize: Appearance.fs(12)
                        font.weight: Font.DemiBold
                        color: Appearance.ink2
                    }

                    MouseArea {
                        id: moreArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: frame.app.go(crumbPill.crumbList[crumbPill.crumbStart - 1].path)
                    }
                }

                Repeater {
                    model: crumbPill.crumbList.slice(crumbPill.crumbStart)

                    Row {
                        required property var modelData
                        required property int index
                        spacing: 2
                        anchors.verticalCenter: parent.verticalCenter

                        MonoIcon {
                            visible: index + crumbPill.crumbStart > 0
                            anchors.verticalCenter: parent.verticalCenter
                            name: "chevronRight"
                            size: 15
                            inkColor: Appearance.ink3
                            monochrome: true
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: crumbLabel.width + 10
                            height: 22
                            radius: Appearance.rSm
                            color: crumbArea.containsMouse ? Appearance.hover : "transparent"

                            StyledText {
                                id: crumbLabel
                                anchors.centerIn: parent
                                // The one you are in gets whatever room is
                                // left when even it does not fit, and is
                                // shortened with "…" rather than cut off.
                                width: Math.max(24, Math.min(implicitWidth, crumbPill.crumbMax,
                                    modelData.path === frame.app.cwd
                                        ? crumbRow.width - 10 - 17 - crumbRow.spacing
                                          - (crumbPill.crumbStart > 0 ? crumbPill.ellipsisWidth : 0)
                                        : crumbPill.crumbMax))
                                elide: Text.ElideRight
                                text: modelData.label
                                font.pixelSize: Appearance.fs(11.5)
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
                anchors.leftMargin: 11
                anchors.right: parent.right
                anchors.rightMargin: 11
                anchors.verticalCenter: parent.verticalCenter
                font.family: Appearance.fontFamily
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink
                selectionColor: Appearance.accent
                selectedTextColor: Appearance.inkOnAccent
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
        // One segmented control rather than two loose buttons: the tinted
        // container with a hairline is what makes the pair read as a single
        // choice, and it matches the breadcrumb beside it.
        Rectangle {
            id: viewRow
            anchors.right: newButton.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: viewButtons.implicitWidth + 6
            height: 30
            radius: Appearance.rSm
            color: Appearance.hover
            border.width: 1
            border.color: Appearance.rule

            Row {
                id: viewButtons
                anchors.centerIn: parent
                spacing: 2

                Repeater {
                    model: [
                        { glyph: "grid",   mode: "grid" },
                        { glyph: "list",   mode: "list" }
                    ]

                    Rectangle {
                        id: viewBtn
                        required property var modelData
                        readonly property bool on: FilesService.view === modelData.mode
                        width: 30
                        height: 26
                        radius: Appearance.rSm
                        color: on ? Appearance.accent
                             : (viewArea.containsMouse ? Appearance.sel : "transparent")

                        Behavior on color { ColorAnimation { duration: 160 } }

                        MonoIcon {
                            anchors.centerIn: parent
                            name: viewBtn.modelData.glyph
                            size: 19
                            inkColor: viewBtn.on ? Appearance.inkOnAccent : Appearance.ink2
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
        }

        // Narrowing the folder you are in. Not a search of the disk: the
        // list simply shrinks as you type, which is what both Nautilus and
        // Explorer do with the same gesture.
        Rectangle {
            id: searchPill
            anchors.right: pinButton.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: searchField.active || frame.app.filter !== "" ? 180 : 30
            height: 30
            radius: Appearance.rSm
            color: searchField.active || frame.app.filter !== ""
                   ? Appearance.surface
                   : (searchIconArea.containsMouse ? Appearance.hover : "transparent")

            Behavior on width { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

            MonoIcon {
                id: searchGlyph
                anchors.left: parent.left
                anchors.leftMargin: searchPill.width > 40 ? 10 : 9
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: 20
                inkColor: frame.app.filter !== "" ? Appearance.accent : Appearance.ink3
                monochrome: true
            }

            TextInput {
                id: searchField
                property bool active: false
                function begin() {
                    active = true;
                    frame.app.filtering = true;
                    forceActiveFocus();
                    selectAll();
                }
                function finish() {
                    active = false;
                    frame.app.filtering = false;
                    frame.forceActiveFocus();
                }

                visible: searchPill.width > 40
                anchors.left: searchGlyph.right
                anchors.leftMargin: 7
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                font.family: Appearance.fontFamily
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink
                selectionColor: Appearance.accent
                selectedTextColor: Appearance.inkOnAccent
                clip: true
                text: frame.app.filter
                onTextChanged: frame.app.filter = text
                Keys.onEscapePressed: { text = ""; finish(); }
                onAccepted: {
                    // Enter on a filtered list opens the only match, which
                    // is the point of having narrowed it.
                    const list = frame.app.visibleEntries;
                    if (list.length === 1) { finish(); frame.app.activate(list[0]); }
                    else frame.forceActiveFocus();
                }

                StyledText {
                    anchors.fill: parent
                    visible: searchField.text === ""
                    verticalAlignment: Text.AlignVCenter
                    text: "Filter"
                    font.pixelSize: Appearance.fs(12)
                    color: Appearance.ink3
                }
            }

            MouseArea {
                id: searchIconArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: !searchField.active && frame.app.filter === ""
                cursorShape: Qt.PointingHandCursor
                onClicked: searchField.begin()
            }
        }

        // Pin this folder into the sidebar. A star rather than a menu item,
        // because it is a toggle and it should show its state.
        Rectangle {
            id: toolbarRule
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: Appearance.rule
        }

        Rectangle {
            id: pinButton
            anchors.right: viewRow.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 30
            height: 30
            radius: Appearance.rSm
            visible: !frame.app.inTrash && frame.app.cwd !== ""
            color: pinArea.containsMouse ? Appearance.hover : "transparent"

            MonoIcon {
                anchors.centerIn: parent
                name: "star"
                size: 20
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
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: newRow.implicitWidth + 24
            height: 30
            radius: Appearance.rSm
            color: Appearance.accent
            opacity: newArea.containsMouse ? 0.9 : 1
            visible: !frame.app.inTrash

            Row {
                id: newRow
                anchors.centerIn: parent
                spacing: 7

                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "plus"
                    size: 18
                    inkColor: Appearance.inkOnAccent
                    monochrome: true
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "New"
                    font.pixelSize: Appearance.fs(11.5)
                    font.weight: Font.DemiBold
                    color: Appearance.inkOnAccent
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
                    size: 20
                    inkColor: frame.app.confirmingEmpty ? Appearance.inkOnAccent
                                                        : Appearance.ink2
                    monochrome: true
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: frame.app.confirmingEmpty ? "Delete them permanently?" : "Empty Trash"
                    font.pixelSize: Appearance.fs(13)
                    font.weight: Font.DemiBold
                    color: frame.app.confirmingEmpty ? Appearance.inkOnAccent
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
        anchors.bottom: deleteBar.top

        // Clicking the empty space drops the selection, the way every file
        // manager does; right-clicking it is the folder's own menu; and
        // dragging across it sweeps up whatever it touches.
        MouseArea {
            id: bandArea
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            hoverEnabled: false

            property real originX: 0
            property real originY: 0
            property bool banding: false
            // Whether the sweep adds to what was already picked.
            property bool additive: false

            onPressed: mouse => {
                if (mouse.button !== Qt.LeftButton) return;
                originX = mouse.x;
                originY = mouse.y;
                additive = (mouse.modifiers & Qt.ControlModifier) !== 0;
                banding = false;
            }

            onPositionChanged: mouse => {
                if (!pressed) return;
                if (!banding
                    && Math.abs(mouse.x - originX) + Math.abs(mouse.y - originY) < 6) return;
                banding = true;
                band.x = Math.min(originX, mouse.x);
                band.y = Math.min(originY, mouse.y);
                band.width = Math.abs(mouse.x - originX);
                band.height = Math.abs(mouse.y - originY);
                frame.sweep(band, bandArea.additive);
            }

            onReleased: banding = false

            onClicked: mouse => {
                if (banding) return;
                if (mouse.button === Qt.RightButton) {
                    const p = mapToItem(menuLayer, mouse.x, mouse.y);
                    frame.app.openMenu(p.x, p.y, null);
                } else {
                    frame.app.selectNone();
                }
            }
        }

        Rectangle {
            id: band
            visible: bandArea.banding
            z: 50
            color: Qt.rgba(Appearance.accent.r, Appearance.accent.g,
                           Appearance.accent.b, 0.14)
            border.width: 1
            border.color: Appearance.accent
            radius: 2
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
            anchors.leftMargin: frame.app.view === "grid" ? 12 : 0
            anchors.rightMargin: frame.app.view === "grid" ? 12 : 0
            anchors.topMargin: frame.app.view === "grid" ? 12 : 0
            anchors.bottomMargin: 0
            contentHeight: frame.app.view === "grid" ? grid.implicitHeight : list.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Grid {
                id: grid
                visible: frame.app.view === "grid"
                width: parent.width
                // The concept lays five across a 884px area, so a cell is
                // about 168 wide. Fixing the cell rather than the column
                // count keeps that airiness and still reflows: five at the
                // concept's size, more on a wider window.
                columns: Math.max(1, Math.floor(width / tileWidth))
                readonly property real tileWidth: Math.round(168 * FilesService.iconSize / 100)
                spacing: 4

                // The waiting-to-be-named folder sits first, as a tile you
                // type into, so a new folder never appears unnamed.
                NewNameTile {
                    visible: frame.app.creatingSomething
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

                ListHeader {
                    id: listHeader
                    width: list.width
                    app: frame.app
                    // The trash shows where things came from instead of the
                    // three columns, so its headings would be lying.
                    visible: !frame.app.inTrash
                    height: visible ? implicitHeight : 0
                }

                NewNameTile {
                    visible: frame.app.creatingSomething
                    width: list.width
                    app: frame.app
                    gridView: false
                }

                Repeater {
                    model: frame.app.visibleEntries

                    // A row, with the group heading that belongs above it
                    // when it starts a new run. The heading lives in the
                    // delegate rather than in the model so that the model
                    // stays exactly the list everything else indexes into.
                    Column {
                        id: rowGroup
                        required property var modelData
                        required property int index
                        width: list.width

                        readonly property string heading: frame.app.groupAt(rowGroup.index)

                        GroupHeading {
                            width: rowGroup.width
                            visible: rowGroup.heading !== ""
                            height: visible ? implicitHeight : 0
                            text: rowGroup.heading
                            firstOne: rowGroup.index === 0
                        }

                        FileRow {
                            width: rowGroup.width
                            entry: rowGroup.modelData
                            app: frame.app
                            sizeWidth: listHeader.sizeWidth
                            typeWidth: listHeader.typeWidth
                            timeWidth: listHeader.timeWidth
                        }
                    }
                }
            }
        }

        // An empty directory should say so rather than look broken.
        StyledText {
            anchors.centerIn: parent
            visible: !frame.app.loading && frame.app.visibleEntries.length === 0
                     && !frame.app.creatingSomething
            // In the order the reasons actually apply: a folder with
            // things in it is never "empty", and saying it is sends
            // someone looking for a file that is right there. A search
            // and a dialog's kind filter each hide entries the same way
            // hidden files do, and each used to be reported as the
            // other.
            text: frame.app.entries.length === 0
                  ? (frame.app.inTrash ? "The trash is empty" : "This folder is empty")
                : frame.app.filter.trim() !== ""
                  ? "No matches for \u201C" + frame.app.filter.trim() + "\u201D"
                : frame.app.kindFilter.length > 0
                  ? "Nothing here of the kind that was asked for"
                : "Nothing here but hidden files"
            font.pixelSize: Appearance.fs(13)
            color: Appearance.ink3
        }
    }

    // Which entries a rubber band is over. The delegates are asked where
    // they are rather than the geometry being recomputed here, so this
    // stays correct whatever the view is doing with its layout.
    function sweep(rect, additive) {
        const container = frame.app.view === "grid" ? grid : list;
        const picked = [];
        for (const child of container.children) {
            if (child.entry === undefined || !child.entry) continue;
            const top = child.mapToItem(body, 0, 0);
            if (top.x < rect.x + rect.width && top.x + child.width > rect.x
                && top.y < rect.y + rect.height && top.y + child.height > rect.y)
                picked.push(child.entry.name);
        }
        if (!additive) { frame.app.selection = picked; return; }
        const out = frame.app.selection.slice();
        for (const n of picked) if (out.indexOf(n) < 0) out.push(n);
        frame.app.selection = out;
    }

    // What a drag looks like. Off-screen, grabbed when the selection
    // changes; see DragBadge.
    DragBadge {
        id: dragBadge
        app: frame.app
        onImageChanged: frame.app.dragImage = dragBadge.image
    }

    // ── properties ────────────────────────────────────────────────────────
    Properties {
        id: properties
        app: frame.app
        x: Math.round((frame.width - width) / 2)
        y: Math.round((frame.height - height) / 2)
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

    // Deleting outright is the only thing in here that cannot be undone, so
    // it is asked for in the window rather than done on the keystroke.
    Rectangle {
        id: deleteBar
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.bottom: statusBar.top
        height: frame.app.confirmingDelete ? 48 : 0
        visible: height > 0
        clip: true
        color: Appearance.accent

        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: {
                const n = frame.app.selection.length;
                return "Delete " + (n === 1 ? "“" + frame.app.selection[0] + "”"
                                            : n + " items")
                       + " permanently? This cannot be undone.";
            }
            font.pixelSize: Appearance.fs(12)
            font.weight: Font.DemiBold
            color: Appearance.inkOnAccent
            elide: Text.ElideRight
            width: parent.width - 220
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Repeater {
                model: [
                    { n: "Cancel", act: () => frame.app.confirmingDelete = false },
                    { n: "Delete", act: () => frame.app.deleteSelected() }
                ]

                Rectangle {
                    id: confirmBtn
                    required property var modelData
                    width: 84
                    height: 30
                    radius: Appearance.rSm
                    color: confirmArea.containsMouse
                           ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(1, 1, 1, 0.16)

                    StyledText {
                        anchors.centerIn: parent
                        text: confirmBtn.modelData.n
                        font.pixelSize: Appearance.fs(12)
                        font.weight: Font.DemiBold
                        color: Appearance.inkOnAccent
                    }

                    MouseArea {
                        id: confirmArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: confirmBtn.modelData.act()
                    }
                }
            }
        }
    }

    // ── status bar ────────────────────────────────────────────────────────
    Item {
        id: statusBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 32

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Appearance.rule
        }

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: freeLabel.left
            anchors.rightMargin: 12
            elide: Text.ElideRight
            font.pixelSize: Appearance.fs(11)
            font.weight: Font.Normal
            color: frame.svc.lastError ? Appearance.accent : Appearance.ink3
            text: {
                if (frame.svc.lastError) return frame.svc.lastError;
                const n = frame.app.visibleEntries.length;
                const filtered = frame.app.filter.trim() !== "";
                const items = n + (n === 1 ? " item" : " items")
                              + (filtered ? " matching “" + frame.app.filter.trim() + "”" : "");
                const sel = frame.app.selection.length;
                if (!sel) return items;
                // The total is bytes of files; a directory's real size is a
                // walk of the disk, and doing one per selection change
                // would make picking things slow. Properties will count it.
                const bytes = frame.app.selectedBytes;
                const size = bytes > 0 ? " (" + frame.svc.humanSize(bytes) + ")" : "";
                if (sel === 1) return items + " · " + frame.app.selection[0] + " selected" + size;
                return items + " · " + sel + " selected" + size;
            }
        }

        StyledText {
            id: freeLabel
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: frame.svc.freeSpace
            font.pixelSize: Appearance.fs(11)
            font.weight: Font.Normal
            color: Appearance.ink3
        }
    }
}
