import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.UPower
import Quickshell.Services.Pipewire
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The Settings window's chrome, independent of which kind of window it is
// mounted in. See Settings.qml.
PanelSurface {
    id: frame

    // The window this is mounted in, and the object holding the state and
    // the row definitions. Settings.qml owns *what* is shown; this file is
    // only the chrome — title bar, sidebar, scroll area and geometry — so
    // one set of panes can be shown in two kinds of window without being
    // written twice.
    //
    // The host contract: width, height, tiled, maximised, normalWidth,
    // normalHeight, workTop, workBottom and moveTo(x, y).
    required property var host
    required property var app

    // Maximise: the compositor's, for a real window.
    function toggleMaximised() {
        if (frame.host.toggleMaximised) frame.host.toggleMaximised();
        else Config.UiState.settingsMaximized = !frame.host.maximised;
    }

    showSeam: false
    color: Config.Appearance.sheet
    // Tiled, it is a real window: Hyprland rounds it and draws its border,
    // so ours would be a second outline on a different curve.
    radius: frame.host.tiled ? 0 : Config.Appearance.rWin
    showEdge: !frame.host.tiled

    // Tiled, the compositor decides the geometry and this fills whatever it
    // is given. Floating, the window is ours to place.
    width: widthSpring.value
    height: heightSpring.value

    // -1 means "not placed yet", so it opens centred.
    x: frame.host.tiled ? 0
       : (frame.host.maximised ? 8
          : (Config.UiState.settingsX >= 0
             ? Math.max(0, Math.min(frame.host.width - width, Config.UiState.settingsX))
             : Math.round((frame.host.width - width) / 2)))
    y: frame.host.tiled ? 0
       : (frame.host.maximised ? frame.host.workTop
          : (Config.UiState.settingsY >= 0
             ? Math.max(Config.Appearance.barHeight,
                        Math.min(frame.host.height - height, Config.UiState.settingsY))
             : Math.round((frame.host.height - height) / 2)))

    // Maximising and restoring glide; tiled, the compositor is resizing
    // it and it follows exactly.
    Spring {
        id: widthSpring
        to: frame.host.tiled ? frame.host.width
            : (frame.host.maximised ? frame.host.width - 16 : frame.host.normalWidth)
        response: 300; bounce: 0.5; enabled: !frame.host.tiled
    }
    Spring {
        id: heightSpring
        to: frame.host.tiled ? frame.host.height
            : (frame.host.maximised
               ? Math.max(320, frame.host.workBottom - frame.host.workTop)
               : frame.host.normalHeight)
        response: 300; bounce: 0.5; enabled: !frame.host.tiled
    }

    // ── title bar ─────────────────────────────────────────────────────
    Item {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 40

        // Drag to move, double click to maximise — the mockup's own
        // `cursor: grab` title bar.
        MouseArea {
            anchors.fill: parent
            cursorShape: frame.host.maximised ? Qt.ArrowCursor : Qt.OpenHandCursor
            property real pressX: 0
            property real pressY: 0

            // A real window: the compositor does the moving, from the press.
            onPressed: mouse => {
                pressX = mouse.x; pressY = mouse.y;
                if (frame.host.tiled && !frame.host.maximised) frame.host.moveTo(0, 0);
            }
            onPositionChanged: mouse => {
                if (!pressed || frame.host.tiled || frame.host.maximised) return;
                const p = mapToItem(null, mouse.x, mouse.y);
                frame.host.moveTo(Math.round(p.x - pressX),
                                Math.round(p.y - pressY));
            }
            onDoubleClicked: frame.toggleMaximised()
        }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 11

            // Focus bead, accent because this window is the focused one
            // whenever it is up.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 3
                height: 16
                radius: 2
                color: Config.Appearance.accent
            }

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "settings"
                // 23, not the 20 the folder beside it in Files uses: these two
                // glyphs are the same nominal size but not the same optical
                // size. Measured at 20, the folder's ink is 16x14 device
                // pixels and the sliders' is 16x11 — a fifth shorter, and in
                // a title bar where everything is centred on one baseline
                // the height is what you read. At 23 it measures 17x13,
                // within a pixel of the folder on both axes.
                size: 23
                inkColor: Config.Appearance.ink2
                accentColor: Config.Appearance.accent
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Settings"
                font.pixelSize: Config.Appearance.fs(13)
                font.weight: Font.DemiBold
                font.letterSpacing: 0.13
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "quickshell · live"
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.Normal
                color: Config.Appearance.ink3
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Repeater {
                model: [
                    { glyph: "minus",  danger: false, act: () => Config.UiState.minimiseSettings() },
                    { glyph: "square", danger: false, act: () => frame.toggleMaximised() },
                    { glyph: "x",      danger: true,  act: () => Config.UiState.closeSettings() }
                ]

                Rectangle {
                    id: winBtn
                    required property var modelData
                    width: 30
                    height: 30
                    radius: Config.Appearance.rSm
                    color: !btnArea.containsMouse ? "transparent"
                         : (modelData.danger ? Config.Appearance.accent : Config.Appearance.hover)

                    MonoIcon {
                        anchors.centerIn: parent
                        name: winBtn.modelData.glyph
                        size: 17
                        inkColor: btnArea.containsMouse && winBtn.modelData.danger
                                  ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
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
            color: Config.Appearance.rule
        }
    }

    // Anything that has to float above the rows lives here: dropdown
    // menus and the colour picker. Inside the window so it moves with it,
    // but outside the pane's Flickable, which clips — a menu opened on a
    // row near the bottom was being cut in half by it, and later rows
    // painted straight over the top of it.
    Item {
        id: popupLayer
        anchors.fill: parent
        z: 900
        // Click-through except where a popup actually is; the popups add
        // their own input handling.
        enabled: children.length > 0

        // A popup positions itself with mapToItem, which is a function
        // call — QML cannot know when its answer changes, so a binding
        // using it evaluates once, before layout has happened, and then
        // never again. That is how they ended up drawn nowhere near
        // their control. Reading these makes those bindings re-evaluate
        // whenever anything that moves a row has moved.
        readonly property real scrollY: paneFlick.contentY
        readonly property string pane: frame.app.pane

        // What a popup frosts: the pane behind it. It is a sibling of
        // this overlay, not an ancestor, so sampling it is safe.
        readonly property Item backdrop: paneFlick
    }

    // ── sidebar ───────────────────────────────────────────────────────
    Rectangle {
        id: sidebar
        anchors.left: parent.left
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        width: 212
        color: "transparent"

        Rectangle {
            anchors.right: parent.right
            width: 1
            height: parent.height
            color: Config.Appearance.rule
        }

        // ── search ──────────────────────────────────────────────────────
        // Every pane's rows, by name and description (Settings.rankSettings,
        // the launcher's search too). While there is something typed, the
        // matches stand where the list of panes was; picking one opens its
        // pane at that row, flashed. Ctrl+F to get here, Escape to clear.
        property string query: searchInput.text.trim().toLowerCase()
        property var idx: []
        onQueryChanged: if (query !== "" && idx.length === 0) idx = frame.app.searchIndex()
        readonly property var hits: query.length < 1 ? [] : frame.app.rankSettings(query, idx, 40)
        function pick(h) {
            Config.UiState.openSettingsAt(h.e.pane, h.e.isPane ? "" : h.e.n);
        }

        Shortcut {
            sequence: "Ctrl+F"
            onActivated: { searchInput.forceActiveFocus(); searchInput.selectAll(); }
        }

        Rectangle {
            id: searchBox
            x: 8
            y: 8
            width: parent.width - 17
            height: 34
            radius: Config.Appearance.rSm
            color: Config.Appearance.hover
            border.width: 1
            border.color: searchInput.activeFocus ? Config.Appearance.accent : Config.Appearance.rule

            MonoIcon {
                id: searchGlyph
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                name: "search"
                size: 15
                inkColor: Config.Appearance.ink3
                monochrome: true
            }
            TextInput {
                id: searchInput
                anchors.left: searchGlyph.right
                anchors.leftMargin: 8
                anchors.right: clearBtn.left
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                color: Config.Appearance.ink
                selectionColor: Qt.rgba(Config.Appearance.accent.r, Config.Appearance.accent.g, Config.Appearance.accent.b, 0.35)
                font.pixelSize: Config.Appearance.fs(13)
                font.family: Config.Appearance.fontFamily
                clip: true
                Keys.onEscapePressed: event => {
                    if (text !== "") { text = ""; event.accepted = true; }
                    else event.accepted = false;
                }
                Keys.onReturnPressed: if (sidebar.hits.length > 0) sidebar.pick(sidebar.hits[0])
                Keys.onEnterPressed: if (sidebar.hits.length > 0) sidebar.pick(sidebar.hits[0])
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: searchInput.text === ""
                    text: "Search settings"
                    font.pixelSize: Config.Appearance.fs(13)
                    color: Config.Appearance.ink3
                }
            }
            Rectangle {
                id: clearBtn
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                visible: searchInput.text !== ""
                width: visible ? 22 : 0
                height: 22
                radius: 11
                color: clearHover.hovered ? Config.Appearance.sel : "transparent"
                MonoIcon { anchors.centerIn: parent; name: "x"; size: 12; inkColor: Config.Appearance.ink2; monochrome: true }
                HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: { searchInput.text = ""; searchInput.forceActiveFocus(); } }
            }
        }

        // The matches, while something is typed.
        Flickable {
            id: hitsFlick
            KineticScroll { flick: hitsFlick }
            visible: sidebar.query !== ""
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.rightMargin: 1
            anchors.top: searchBox.bottom
            anchors.topMargin: 6
            anchors.bottom: parent.bottom
            contentHeight: hitsColumn.implicitHeight + 16
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            Column {
                id: hitsColumn
                x: 8
                width: hitsFlick.width - 16
                spacing: 1

                StyledText {
                    visible: sidebar.hits.length === 0
                    width: parent.width
                    wrapMode: Text.Wrap
                    leftPadding: 10
                    topPadding: 10
                    text: "Nothing in Settings matches “" + searchInput.text.trim() + "”"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
                Repeater {
                    model: sidebar.hits
                    Rectangle {
                        id: hit
                        required property var modelData
                        required property int index
                        width: hitsColumn.width
                        height: 46
                        radius: Config.Appearance.rSm
                        color: hitHover.hovered || (hit.index === 0 && searchInput.activeFocus)
                               ? Config.Appearance.hover : "transparent"
                        MonoIcon {
                            id: hitIcon
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            name: (frame.app.paneMeta[hit.modelData.e.pane] || {}).icon || "settings"
                            size: 17
                            inkColor: Config.Appearance.ink2
                            monochrome: true
                        }
                        Column {
                            anchors.left: hitIcon.right
                            anchors.leftMargin: 10
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: hit.modelData.e.n
                                font.pixelSize: Config.Appearance.fs(12.5)
                                color: Config.Appearance.ink
                            }
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: hit.modelData.e.isPane ? "Page"
                                      : hit.modelData.e.pane + (hit.modelData.e.section ? " › " + hit.modelData.e.section : "")
                                font.pixelSize: Config.Appearance.fs(11)
                                color: Config.Appearance.ink3
                            }
                        }
                        HoverHandler { id: hitHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: sidebar.pick(hit.modelData) }
                    }
                }
            }
        }

        // Scrollable. With fourteen panes the list is taller than the
        // window at its default height, and a fixed Column would simply
        // clip the last entry with nothing to say so.
        Flickable {
            id: sidebarFlick
            KineticScroll { flick: sidebarFlick }
            visible: sidebar.query === ""
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: searchBox.bottom
            anchors.topMargin: 2
            anchors.bottom: parent.bottom
            anchors.rightMargin: 1
            contentHeight: sidebarColumn.implicitHeight + 16
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

            // The selection: one pill that slides — stretching on the way,
            // then settling — from the pane you were on to the one you
            // picked, rather than one fading out as another fades in.
            Rectangle {
                id: selPill
                // Its two edges, each on a spring: the leading one quick, the
                // trailing one slower, so it stretches as it goes and gathers
                // itself up when it lands.
                property real edgeTop: 0
                property real edgeBottom: 36
                property bool down: true
                property bool placed: false
                x: 8
                width: sidebarFlick.width - 16
                y: topSpring.value
                height: Math.max(8, bottomSpring.value - topSpring.value)
                radius: Config.Appearance.rSm
                color: Config.Appearance.sel
                visible: placed
                Spring { id: topSpring; to: selPill.edgeTop; enabled: selPill.placed
                         response: selPill.down ? 420 : 300; bounce: 0 }
                Spring { id: bottomSpring; to: selPill.edgeBottom; enabled: selPill.placed
                         response: selPill.down ? 300 : 420; bounce: 0 }
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    anchors.bottomMargin: 3
                    height: 2
                    radius: 1
                    color: Config.Appearance.accent
                }
            }
            function placeSel(item) {
                const p = item.mapToItem(sidebarColumn.parent, 0, 0);
                selPill.down = p.y >= selPill.edgeTop;
                selPill.edgeTop = p.y;
                selPill.edgeBottom = p.y + item.height;
                if (!selPill.placed) Qt.callLater(() => selPill.placed = true);
            }

            Column {
                id: sidebarColumn
                x: 8
                y: 8
                width: sidebarFlick.width - 16
                spacing: 0

                Repeater {
                    model: frame.app.paneGroups

                    Column {
                        id: group
                        required property var modelData
                        width: parent.width
                        spacing: 1
                        bottomPadding: 6

                        StyledText {
                            text: group.modelData.label
                            font.pixelSize: Config.Appearance.fs(11)
                            font.weight: Font.DemiBold
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 1.2
                            color: Config.Appearance.ink3
                            leftPadding: 10
                            topPadding: 8
                            bottomPadding: 8
                        }

                        Repeater {
                            model: group.modelData.items

                            Item {
                                id: entry
                                required property var modelData
                                readonly property bool active: frame.app.pane === modelData

                                width: group.width
                                height: 36

                                onActiveChanged: if (active) sidebarFlick.placeSel(entry)
                                onYChanged: if (active) sidebarFlick.placeSel(entry)
                                Component.onCompleted: if (active) Qt.callLater(() => sidebarFlick.placeSel(entry))
                                Connections {
                                    target: group
                                    function onYChanged() { if (entry.active) sidebarFlick.placeSel(entry); }
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    radius: Config.Appearance.rSm
                                    color: !entry.active && entryArea.containsMouse ? Config.Appearance.hover : "transparent"
                                }

                                Row {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.verticalCenterOffset: -1
                                    spacing: 10

                                    MonoIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: frame.app.paneMeta[entry.modelData].icon
                                        size: 20
                                        inkColor: entry.active ? Config.Appearance.accent : Config.Appearance.ink2
                                        monochrome: true
                                    }
                                    StyledText {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: entry.modelData
                                        font.pixelSize: Config.Appearance.fs(13)
                                    }
                                }

                                MouseArea {
                                    id: entryArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Config.UiState.settingsPane = entry.modelData
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── cards ─────────────────────────────────────────────────────────
    // Every pane is drawn as cards (Settings.cardPositions). Each row is
    // told where in its card it falls and draws that slice itself.
    readonly property var cardPositions: {
        const meta = frame.app.paneMeta[frame.app.pane];
        if (meta && meta.cards === false) return [];
        return frame.app.cardPositions(frame.app.rows || []);
    }

    // ── a row asked for by the launcher's search ──────────────────────
    // Once the pane's rows are built: scrolled into view, a little below
    // the top, and flashed.
    Connections {
        target: Config.UiState
        function onSettingsFocusSeqChanged() { focusSoon.restart(); }
    }
    Timer {
        id: focusSoon
        interval: 180
        onTriggered: {
            const want = Config.UiState.settingsFocus;
            if (want === "" || want === frame.app.pane) { paneFlick.contentY = 0; return; }
            for (let i = 0; i < paneColumn.children.length; ++i) {
                const item = paneColumn.children[i];
                if (item.spec && item.spec.n === want) {
                    const max = Math.max(0, paneFlick.contentHeight - paneFlick.height);
                    paneFlick.contentY = Math.max(0, Math.min(max, paneColumn.y + item.y - 80));
                    item.flash();
                    return;
                }
            }
        }
    }

    // ── pane ──────────────────────────────────────────────────────────
    Flickable {
        id: paneFlick
        KineticScroll { flick: paneFlick }
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        anchors.bottom: parent.bottom
        contentHeight: paneColumn.implicitHeight + 40
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        // Vertical only. Otherwise a sideways drag on a slider is read
        // as a flick and the pane takes the grab off the control.
        flickableDirection: Flickable.VerticalFlick

        Column {
            id: paneColumn
            x: 24
            y: 20
            width: parent.width - 48
            spacing: 0

            // A new pane rises into place rather than swapping in where
            // the last one was.
            // Both jump away and spring back.
            Spring { id: rise; to: 0; response: 340; bounce: 0 }
            Spring { id: paneFade; to: 1; response: 200; bounce: 0 }
            transform: Translate { y: rise.value }
            opacity: Math.max(0, Math.min(1, paneFade.value))
            Connections {
                target: frame.app
                function onPaneChanged() {
                    if (!Config.Appearance.animated) return;
                    rise.snap(24); rise.wake();
                    paneFade.snap(-0.15); paneFade.wake();
                }
            }

            StyledText {
                text: frame.app.pane
                font.pixelSize: Config.Appearance.fs(17)
                font.weight: Font.Bold
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: (frame.app.paneMeta[frame.app.pane] || ({})).note || ""
                font.pixelSize: Config.Appearance.fs(13)
                font.weight: Font.Normal
                color: Config.Appearance.ink3
                topPadding: 4
                bottomPadding: 12
            }

            Repeater {
                model: frame.app.rows
                SettingsRow {
                    required property var modelData
                    required property int index
                    width: paneColumn.width
                    spec: modelData
                    cardPos: frame.cardPositions[index] || ""
                    // Popups reparent themselves here so they are neither
                    // clipped by the scrolling pane nor painted over by
                    // the rows that come after them.
                    overlay: popupLayer
                }
            }
        }
    }
}
