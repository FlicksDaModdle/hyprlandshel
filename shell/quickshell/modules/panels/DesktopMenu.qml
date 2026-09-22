import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Right-click-the-desktop menu. Every entry does something real — opens a
// terminal in $HOME, changes the wallpaper, reloads the shell — rather than
// standing in for one.
PanelSurface {
    id: root

    showSeam: false

    readonly property var entries: [
        { n: "Open terminal here", k: "super ⏎", icon: "terminal",
          run: () => Quickshell.execDetached(Config.Apps.pinned[0].exec) },
        { n: "Open file manager",  k: "super E", icon: "folder",
          run: () => Quickshell.execDetached(Config.Apps.pinned[1].exec) },
        { n: "Overview",           k: "super ⇥", icon: "panelsTopLeft", rule: true,
          run: () => Config.UiState.toggleOverview() },
        { n: "Change wallpaper",   k: "",        icon: "image",
          run: () => Config.UiState.openSettings("Appearance") },
        { n: "Display settings",   k: "",        icon: "monitor",
          run: () => Config.UiState.openSettings("Display") },
        { n: "Toggle theme",       k: "super ⇧ T", icon: "moon", rule: true,
          run: () => Config.Appearance.toggleTheme() },
        { n: "Reload shell",       k: "super ⇧ R", icon: "refresh",
          run: () => Services.Session.reloadShell() }
    ]

    implicitWidth: 252
    implicitHeight: column.implicitHeight + 12

    Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 6
        spacing: 0

        Repeater {
            model: root.entries

            Item {
                id: entry
                required property var modelData
                width: column.width
                height: modelData.rule ? 41 : 36

                Rectangle {
                    // Most entries have no `rule` key at all, so this is
                    // undefined rather than false — and `visible` is a bool.
                    visible: entry.modelData.rule === true
                    anchors.top: parent.top
                    anchors.topMargin: 2
                    width: parent.width
                    height: 1
                    color: Config.Appearance.rule
                }

                Rectangle {
                    id: rowBg
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 36
                    radius: Config.Appearance.rPill
                    color: entryHover.hovered ? Config.Appearance.accent : "transparent"

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: entry.modelData.icon
                            size: 14
                            inkColor: entryHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink
                            accentColor: entryHover.hovered ? Config.Appearance.onAccent : Config.Appearance.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: entry.modelData.n
                            font.pixelSize: Config.Appearance.fs(12)
                            color: entryHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink
                        }
                    }

                    StyledText {
                        anchors.right: parent.right
                        anchors.rightMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        text: entry.modelData.k
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.Normal
                        color: entryHover.hovered ? Config.Appearance.onAccent : Config.Appearance.ink3
                    }
                }

                HoverHandler { id: entryHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        Config.UiState.desktopMenuOpen = false;
                        entry.modelData.run();
                    }
                }
            }
        }
    }
}
