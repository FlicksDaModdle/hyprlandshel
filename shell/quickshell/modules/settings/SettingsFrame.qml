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

    showSeam: false
    color: Config.Appearance.sheet
    // Tiled, it is a real window: Hyprland rounds it and draws its border,
    // so ours would be a second outline on a different curve.
    radius: frame.host.tiled ? 0 : Config.Appearance.rWin
    showEdge: !frame.host.tiled

    // Tiled, the compositor decides the geometry and this fills whatever it
    // is given. Floating, the window is ours to place.
    width: frame.host.tiled ? frame.host.width
           : (frame.host.maximised ? frame.host.width - 16 : frame.host.normalWidth)
    height: frame.host.tiled ? frame.host.height
            : (frame.host.maximised
               ? Math.max(320, frame.host.workBottom - frame.host.workTop)
               : frame.host.normalHeight)

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

    Behavior on width  { NumberAnimation { duration: Config.Appearance.anim(140); easing.type: Easing.OutCubic } }
    Behavior on height { NumberAnimation { duration: Config.Appearance.anim(140); easing.type: Easing.OutCubic } }

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
            cursorShape: (frame.host.tiled || frame.host.maximised)
                             ? Qt.ArrowCursor : Qt.OpenHandCursor
            property real pressX: 0
            property real pressY: 0

            onPressed: mouse => { pressX = mouse.x; pressY = mouse.y; }
            onPositionChanged: mouse => {
                if (!pressed || frame.host.tiled || frame.host.maximised) return;
                const p = mapToItem(null, mouse.x, mouse.y);
                frame.host.moveTo(Math.round(p.x - pressX),
                                Math.round(p.y - pressY));
            }
            onDoubleClicked: if (!frame.host.tiled)
                                     Config.UiState.settingsMaximized = !frame.host.maximised
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
                    { glyph: "square", danger: false, act: () => Config.UiState.settingsMaximized = !frame.host.maximised },
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

        // Scrollable. With fourteen panes the list is taller than the
        // window at its default height, and a fixed Column would simply
        // clip the last entry with nothing to say so.
        Flickable {
            id: sidebarFlick
            anchors.fill: parent
            anchors.rightMargin: 1
            contentHeight: sidebarColumn.implicitHeight + 16
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick

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

                                Rectangle {
                                    anchors.fill: parent
                                    radius: Config.Appearance.rSm
                                    color: entry.active ? Config.Appearance.sel
                                         : (entryArea.containsMouse ? Config.Appearance.hover : "transparent")
                                    Behavior on color { ColorAnimation { duration: Config.Appearance.anim(120) } }
                                }

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
                                    opacity: entry.active ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: Config.Appearance.anim(180) } }
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

    // ── pane ──────────────────────────────────────────────────────────
    Flickable {
        id: paneFlick
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

            StyledText {
                text: frame.app.pane
                font.pixelSize: Config.Appearance.fs(17)
                font.weight: Font.Bold
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: frame.app.paneMeta[frame.app.pane].note
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
                    width: paneColumn.width
                    spec: modelData
                    // Popups reparent themselves here so they are neither
                    // clipped by the scrolling pane nor painted over by
                    // the rows that come after them.
                    overlay: popupLayer
                }
            }
        }
    }
}
