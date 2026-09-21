pragma Singleton
import QtQuick
import Quickshell

// Shell-level shortcuts shown alongside Apps.pinned in the launcher's
// Pinned row. Only things that are actually wired up today — the mockup's
// PINNED list also had Wallpaper/Trash/Packages/etc. shortcuts, but those
// point at features that don't exist yet in this build, so they're left
// out rather than faked. Launcher.qml switches on `key` to run each one.
Singleton {
    id: root

    readonly property var items: [
        { key: "toggleTheme", label: "Toggle theme", icon: "moon" },
        { key: "lock", label: "Lock", icon: "lock" },
        { key: "reload", label: "Reload shell", icon: "refresh" }
    ]
}
