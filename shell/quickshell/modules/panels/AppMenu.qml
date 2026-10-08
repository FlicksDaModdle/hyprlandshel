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

    // The shell's own tiles (Settings, Files, Terminal, Music) are opened
    // through the shell's commands, so re-pointing one at another program
    // would do nothing — but any of them can be unpinned.
    readonly property bool isShellTile: Config.Apps.isShellTile(key)

    readonly property var entries: {
        const out = [];
        if (entry && entry.exec && entry.exec.length > 0) {
            out.push({ n: "Open new window", icon: "plus",
                       run: () => Config.Apps.launch(Config.Apps.commandFor(entry)) });
        } else if (cls !== "") {
            out.push({ n: "Open new window", icon: "plus",
                       run: () => Config.Apps.launch(Config.Apps.commandFor({ exec: [cls] })) });
        }
        // One place along, for when a drag is fiddly — on a touchpad, or a
        // dock of small tiles. Named for the way the dock runs, and left
        // out at either end. The menu stays open, so a tile can be walked
        // several places with repeated clicks.
        if (pinned && Config.UiState.appMenuFromDock) {
            const at = Config.Apps.indexOf(root.key);
            const last = Config.Apps.pinned.length - 1;
            const side = Config.Appearance.dockLeft;
            if (at > 0)
                out.push({ n: side ? "Move up" : "Move left",
                           icon: side ? "chevronUp" : "chevronLeft", rule: out.length > 0,
                           keepOpen: true,
                           run: () => Config.Apps.move(root.key, at - 1) });
            if (at >= 0 && at < last)
                out.push({ n: side ? "Move down" : "Move right",
                           icon: side ? "chevronDown" : "chevronRight",
                           rule: out.length > 0 && at === 0,
                           keepOpen: true,
                           run: () => Config.Apps.move(root.key, at + 1) });
        }
        // Offered for the Settings tile too, unlike the two below it: a
        // different picture cannot break a tile, where a different
        // application or no tile at all can.
        if (pinned) {
            out.push({ n: "Change icon…", icon: "palette", rule: out.length > 0,
                       run: () => Config.UiState.openIconPicker(root.key) });
        }
        if (pinned && !isShellTile)
            out.push({ n: "Choose application…", icon: "grid", rule: false,
                       run: () => Config.UiState.pickAppFor(root.key) });
        // Every tile can go, the built-in ones too.
        if (pinned) {
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
                            inkColor: rowHover.hovered ? Config.Appearance.inkOnAccent
                                                       : Config.Appearance.ink
                            accentColor: rowHover.hovered ? Config.Appearance.inkOnAccent
                                                          : Config.Appearance.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: item.modelData.n
                            font.pixelSize: Config.Appearance.fs(12)
                            color: rowHover.hovered ? Config.Appearance.inkOnAccent
                                                    : Config.Appearance.ink
                        }
                    }

                    HoverHandler { id: rowHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            const run = item.modelData.run;
                            const keepOpen = item.modelData.keepOpen === true;
                            // Entries that don't close the menu themselves —
                            // anything that opens another surface — are closed
                            // here, after running, so the surface it opens
                            // isn't immediately dismissed by closeAll().
                            // Except the ones marked to stay: Move left /
                            // right, which are clicked more than once.
                            if (run) run();
                            if (Config.UiState.appMenuOpen && !keepOpen)
                                Config.UiState.appMenuOpen = false;
                        }
                    }
                }
            }
        }
    }
}
