import QtQuick
import Quickshell
import "../../config" as Config
import "../common"
import "../icons"

// Right-click menu for a dock or launcher tile. What it offers depends on
// what you right-clicked:
//
//   a pinned tile      open a new window, re-point it at a different
//                      application, or unpin it
//   a running app that launch-or-focus, or pin it so it stays after the
//   isn't pinned       window closes
//
// "Choose application" hands off to the launcher in picker mode rather than
// growing a second app browser here — the launcher already indexes every
// .desktop entry on the machine and searches them.
PanelSurface {
    id: root

    showSeam: false

    readonly property string key: Config.UiState.appMenuKey
    readonly property string cls: Config.UiState.appMenuClass
    readonly property bool pinned: key !== "" && Config.Apps.isPinned(key)
    readonly property var entry: pinned
        ? Config.Apps.pinned.find(e => e.key === key) : null

    // The Settings tile is the shell's own and has no application behind it,
    // so re-pointing or unpinning it would just break the dock.
    readonly property bool isShellTile: Config.Apps.isShellTile(key)

    readonly property var entries: {
        const out = [];
        if (entry && entry.exec && entry.exec.length > 0) {
            out.push({ n: "Open new window", icon: "plus",
                       run: () => Quickshell.execDetached(entry.exec) });
        } else if (cls !== "") {
            out.push({ n: "Open new window", icon: "plus",
                       run: () => Quickshell.execDetached([cls]) });
        }
        if (pinned && !isShellTile) {
            out.push({ n: "Choose application…", icon: "grid", rule: out.length > 0,
                       run: () => Config.UiState.pickAppFor(root.key) });
            out.push({ n: "Unpin from dock", icon: "minus",
                       run: () => { Config.Apps.unpin(root.key);
                                    Config.UiState.appMenuOpen = false; } });
        } else if (!pinned && cls !== "") {
            out.push({ n: "Pin to dock", icon: "plus", rule: out.length > 0,
                       run: () => { Config.Apps.pinClass(root.cls,
                                        Config.UiState.appMenuLabel,
                                        Config.UiState.appMenuIcon);
                                    Config.UiState.appMenuOpen = false; } });
        }
        out.push({ n: "Dock settings", icon: "settings", rule: out.length > 0,
                   run: () => Config.UiState.openSettings("Dock") });
        return out;
    }

    implicitWidth: 224
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
                    color: Config.Appearance.rule
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 36
                    radius: Config.Appearance.rPill
                    color: rowHover.hovered ? Config.Appearance.accent : "transparent"

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 11
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 10

                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: item.modelData.icon
                            size: 14
                            inkColor: rowHover.hovered ? Config.Appearance.onAccent
                                                       : Config.Appearance.ink
                            accentColor: rowHover.hovered ? Config.Appearance.onAccent
                                                          : Config.Appearance.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: item.modelData.n
                            font.pixelSize: Config.Appearance.fs(12)
                            color: rowHover.hovered ? Config.Appearance.onAccent
                                                    : Config.Appearance.ink
                        }
                    }

                    HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            const run = item.modelData.run;
                            // Entries that don't close the menu themselves —
                            // anything that opens another surface — are closed
                            // here, after running, so the surface it opens
                            // isn't immediately dismissed by closeAll().
                            if (run) run();
                            if (Config.UiState.appMenuOpen)
                                Config.UiState.appMenuOpen = false;
                        }
                    }
                }
            }
        }
    }
}
