import QtQuick
import Hyprterm

// The chrome, from the concept: a 40px title bar carrying the accent
// bead, the app's own icon, the name and the directory, then the three
// window buttons — and the terminal itself under it, inset by the
// padding the design asks for.
Rectangle {
    id: frame

    required property var host
    // The session on screen. Null for the instant between the last tab
    // closing and the window going.
    required property var term

    // The grid the view works out to, read by the window when it makes a
    // new session so that it starts at this size rather than at 80x24.
    readonly property int viewRows: view.rows
    readonly property int viewCols: view.cols

    readonly property var sessions: frame.host.sessions
    readonly property bool showTabs: sessions.length > 0

    // Square and edgeless: it is always a real window, and Hyprland rounds
    // its corners and draws its border. A rounded edge of its own inside
    // that put two outlines on two different curves at every corner.
    color: Appearance.bg
    clip: true

    // ── title bar ─────────────────────────────────────────────────────────
    Item {
        id: titleBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 40

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.OpenHandCursor
            property real pressX: 0
            property real pressY: 0
            property bool moving: false
            onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; moving = false; }
            onReleased: moving = false
            // Handed to the compositor once the pointer has travelled, so
            // the double click that maximises still gets through.
            onPositionChanged: mouse => {
                if (!pressed || moving) return;
                if (Math.abs(mouse.x - pressX) < 4 && Math.abs(mouse.y - pressY) < 4) return;
                moving = true;
                frame.host.moveTo();
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

            // The same 20px as the file manager's folder, and not
            // monochrome: the glyph has an accent element — the line after
            // the prompt — and drawing it in ink made the one icon on the
            // desktop that did not carry the accent. The concept's 15px is
            // in its own scale; this is the one the rest of the shell
            // actually ships.
            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "terminal"
                size: 20
                inkColor: Appearance.ink2
                accentColor: Appearance.accent
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Terminal"
                font.pixelSize: Appearance.fs(12.5)
                font.weight: Font.DemiBold
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: frame.term && frame.term.cwd !== ""
                      ? Appearance.pretty(frame.term.cwd) : ""
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
                elide: Text.ElideMiddle
                width: Math.min(implicitWidth, frame.width - 360)
            }
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // A new session. Left of the window buttons, and a little
            // apart from them: opening a tab and closing the window are
            // not things to have next to each other.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 28
                height: 28
                radius: Appearance.rSm
                color: plusHover.hovered ? Appearance.hover : "transparent"

                MonoIcon {
                    anchors.centerIn: parent
                    name: "plus"
                    size: 15
                    inkColor: Appearance.ink2
                    monochrome: true
                }

                HoverHandler { id: plusHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: frame.host.newTab() }
            }

            Item { width: 8; height: 1 }

            Repeater {
                model: [
                    { glyph: "minus",  danger: false },
                    { glyph: "square", danger: false },
                    { glyph: "x",      danger: true }
                ]

                Rectangle {
                    required property var modelData
                    required property int index
                    width: 28
                    height: 28
                    radius: Appearance.rSm
                    color: !hover.hovered ? "transparent"
                         : (modelData.danger ? Appearance.accent : Appearance.hover)

                    MonoIcon {
                        anchors.centerIn: parent
                        name: parent.modelData.glyph
                        size: 17
                        inkColor: hover.hovered && parent.modelData.danger
                                  ? Appearance.inkOnAccent : Appearance.ink2
                        monochrome: true
                    }

                    HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            if (parent.index === 0) frame.host.minimise();
                            else if (parent.index === 1) frame.host.toggleMaximised();
                            else frame.host.close();
                        }
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

    // ── tabs ──────────────────────────────────────────────────────────────
    //
    // Always, including for a single session. It was hidden until there
    // were two on the grounds that one tab says nothing — but a strip
    // that appears when you open a second tab also makes the window jump
    // and the grid reflow underneath whatever is running, and it hides
    // where the tabs are from anyone who has not found them yet. A fixed
    // row of chrome costs 34px and never moves.
    Item {
        id: tabStrip
        visible: frame.showTabs
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: titleBar.bottom
        height: visible ? 34 : 0

        Flickable {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            clip: true
            contentWidth: tabs.width
            flickableDirection: Flickable.HorizontalFlick
            interactive: contentWidth > width

            Row {
                id: tabs
                height: parent.height
                spacing: 4

                Repeater {
                    model: frame.sessions

                    Rectangle {
                        id: tab
                        required property var modelData
                        required property int index
                        readonly property bool active: index === frame.host.current
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(200, Math.max(96, label.implicitWidth + 44))
                        height: 26
                        radius: Appearance.rSm
                        color: active ? Appearance.sel
                             : (tabHover.hovered ? Appearance.hover : "transparent")

                        // The accent marks the live one, the way it marks
                        // the window's own title.
                        Rectangle {
                            visible: tab.active
                            anchors.left: parent.left
                            anchors.leftMargin: 7
                            anchors.verticalCenter: parent.verticalCenter
                            width: 2
                            height: 12
                            radius: 1
                            color: Appearance.accent
                        }

                        StyledText {
                            id: label
                            anchors.left: parent.left
                            anchors.leftMargin: tab.active ? 15 : 10
                            anchors.right: closeBtn.left
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideMiddle
                            // What the session is.
                            //
                            // A program that sets a title — vim, ssh, top
                            // — is saying something worth showing. A shell
                            // setting "user@host: /long/path" is not: it
                            // is the same words on every tab, with the one
                            // distinguishing part at the end where the
                            // elide eats it. That shape is recognised, and
                            // the directory's own name used instead —
                            // taken from the title itself when the shell
                            // has not sent OSC 7, which plenty do not.
                            //
                            // The colon is excluded from both halves of
                            // the pattern because \S+ is greedy and would
                            // eat it, leaving nothing for the colon to
                            // match and the test always false.
                            text: {
                                const t = tab.modelData;
                                if (!t) return "Terminal";
                                const shell = /^[^\s:]+@[^\s:]+\s*:\s*(.*)$/.exec(t.title);
                                if (t.title !== "" && !shell) return t.title;
                                const path = t.cwd !== "" ? Appearance.pretty(t.cwd)
                                           : (shell ? shell[1] : "");
                                if (path !== "") {
                                    const cut = path.lastIndexOf("/");
                                    return cut >= 0 && cut < path.length - 1
                                           ? path.slice(cut + 1) : path;
                                }
                                return t.title !== "" ? t.title
                                                      : "Terminal " + (tab.index + 1);
                            }
                            font.pixelSize: Appearance.fs(11.5)
                            font.weight: tab.active ? Font.DemiBold : Font.Normal
                            color: tab.active ? Appearance.ink : Appearance.ink2
                        }

                        Rectangle {
                            id: closeBtn
                            anchors.right: parent.right
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            width: 18
                            height: 18
                            radius: Appearance.rSm
                            color: closeHover.hovered ? Appearance.accent : "transparent"

                            MonoIcon {
                                anchors.centerIn: parent
                                name: "x"
                                size: 11
                                inkColor: closeHover.hovered ? Appearance.inkOnAccent
                                                             : Appearance.ink3
                                monochrome: true
                            }

                            HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: frame.host.closeTab(tab.index) }
                        }

                        HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: frame.host.selectTab(tab.index)
                            // The middle button closes a tab everywhere
                            // else that has tabs.
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            onSingleTapped: eventPoint => {
                                if (eventPoint.event.button === Qt.MiddleButton)
                                    frame.host.closeTab(tab.index);
                                else
                                    frame.host.selectTab(tab.index);
                            }
                        }
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

    // ── the terminal ──────────────────────────────────────────────────────
    TermView {
        id: view
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: tabStrip.visible ? tabStrip.bottom : titleBar.bottom
        anchors.bottom: parent.bottom
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        anchors.topMargin: 16
        anchors.bottomMargin: 20

        term: frame.term
        fontFamily: Appearance.monoFamily
        fontSize: Appearance.monoSize
        lineHeight: Appearance.monoLineHeight
        selectionColor: Qt.rgba(Appearance.accent.r, Appearance.accent.g,
                                Appearance.accent.b, 0.30)
        cursorColor: Appearance.accent
        focused: frame.host.active

        Component.onCompleted: forceActiveFocus()

        onNewTabRequested: frame.host.newTab()
        onCloseTabRequested: frame.host.closeTab(frame.host.current)
        onNextTabRequested: frame.host.stepTab(1)
        onPreviousTabRequested: frame.host.stepTab(-1)
        onTabRequested: index => frame.host.selectTab(index)

        onContextMenuRequested: (x, y) => {
            const p = view.mapToItem(frame, x, y);
            contextMenu.openAt(p.x, p.y);
        }

        // Every session, not just the one on screen. A program in a
        // background tab that still believes the window is the size it was
        // when it last had the screen redraws itself wrongly the moment it
        // comes back.
        onGridChanged: {
            if (view.rows <= 0 || view.cols <= 0) return;
            for (const t of frame.sessions) t.setSize(view.rows, view.cols);
        }
    }

    // ── the scrollbar ────────────────────────────────────────────────────
    // In the margin to the right of the grid, so it never covers text.
    // Faint while nothing is happening, there in full while scrolling,
    // scrolled up, hovered or dragged. Gone in the alternate screen, which
    // has no scrollback (vim, less and htop scroll themselves).
    Item {
        id: scrollbar
        readonly property int lines: frame.term ? frame.term.scrollbackLines : 0
        readonly property int offset: frame.term ? frame.term.scrollOffset : 0
        readonly property int rows: Math.max(1, view.rows)
        readonly property bool active: hover.hovered || drag.pressed || recent.running || offset > 0
        // The thumb is the screen's share of everything there is to see.
        readonly property real thumbH: Math.max(28, height * rows / (rows + lines))
        readonly property real travel: Math.max(1, height - thumbH)

        visible: frame.term !== null && lines > 0 && !frame.term.altScreen
        anchors.left: view.right
        anchors.leftMargin: 4
        anchors.top: view.top
        anchors.bottom: view.bottom
        width: 12
        z: 5
        opacity: active ? 1 : 0.35
        Behavior on opacity { NumberAnimation { duration: 180 } }

        // Shown for a moment after any scroll, however it happened.
        onOffsetChanged: recent.restart()
        Timer { id: recent; interval: 1200 }

        HoverHandler { id: hover; cursorShape: Qt.ArrowCursor }

        Rectangle {
            id: thumb
            anchors.right: parent.right
            anchors.rightMargin: 2
            width: hover.hovered || drag.pressed ? 8 : 4
            Behavior on width { NumberAnimation { duration: 120 } }
            radius: width / 2
            height: scrollbar.thumbH
            // Offset 0 is the live screen, at the bottom.
            y: scrollbar.lines > 0 ? scrollbar.travel * (1 - scrollbar.offset / scrollbar.lines) : 0
            color: drag.pressed ? Appearance.accent
                 : Qt.rgba(Appearance.ink.r, Appearance.ink.g, Appearance.ink.b, hover.hovered ? 0.55 : 0.40)
        }

        MouseArea {
            id: drag
            anchors.fill: parent
            property real grab: -1
            function offsetAt(y) {
                const top = Math.max(0, Math.min(scrollbar.travel, y - grab));
                return Math.round(scrollbar.lines * (1 - top / scrollbar.travel));
            }
            onPressed: mouse => {
                // On the thumb: drag from where it was caught. On the
                // track: jump so the thumb is centred on the pointer.
                if (mouse.y >= thumb.y && mouse.y <= thumb.y + thumb.height) grab = mouse.y - thumb.y;
                else grab = scrollbar.thumbH / 2;
                frame.term.scrollOffset = offsetAt(mouse.y);
            }
            onPositionChanged: mouse => { if (pressed) frame.term.scrollOffset = offsetAt(mouse.y); }
            onReleased: view.forceActiveFocus()
        }
    }

    // Switching tabs moves the keyboard back to the grid, and the newly
    // shown session gets the window's current size in case it was made
    // before the window settled.
    Connections {
        target: frame.host
        function onCurrentChanged() {
            if (frame.term && view.rows > 0) frame.term.setSize(view.rows, view.cols);
            view.forceActiveFocus();
        }
    }

    // Anywhere else dismisses the menu, and the click that dismisses it
    // does nothing else — clicking away from a menu is how you say "not
    // that", and landing a selection or a cursor move at the same time
    // would be acting on it anyway.
    MouseArea {
        anchors.fill: parent
        visible: contextMenu.open
        z: 899
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: {
            contextMenu.close();
            view.forceActiveFocus();
        }
    }

    TermMenu {
        id: contextMenu
        view: view
        host: frame.host
    }
}
