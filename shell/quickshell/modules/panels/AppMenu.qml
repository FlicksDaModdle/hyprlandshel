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

    readonly property var entries: Config.Apps.menuFor({
        key: Config.UiState.appMenuKey,
        cls: Config.UiState.appMenuClass,
        entry: Config.UiState.appMenuEntry,
        label: Config.UiState.appMenuLabel,
        icon: Config.UiState.appMenuIcon,
        fromDock: Config.UiState.appMenuFromDock
    })

    implicitWidth: 224
    implicitHeight: list.implicitHeight + 12

    MenuList {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 6
        entries: root.entries
        // Entries that open another surface close the menu after running,
        // so that surface isn't dismissed by it closing; Move left / right
        // keep it open, being clicked more than once.
        onDone: keepOpen => { if (!keepOpen) Config.UiState.appMenuOpen = false; }
    }
}
