pragma Singleton
import QtQuick
import Quickshell

// Shell-level commands shown in the launcher alongside real applications —
// the mockup's EXTRA list and the non-app half of its pinned grid.
//
// Only things that are actually wired up appear here. Launcher.qml switches
// on `key` to run each one.
Singleton {
    id: root

    readonly property var items: [
        { key: "overview",   label: "Overview",     icon: "panelsTopLeft", cat: "Command · workspaces" },
        { key: "settings",   label: "Settings",     icon: "settings",      cat: "System · shell and device" },
        { key: "theme",      label: "Theme",        icon: "palette",       cat: "Command · switch light / dark" },
        { key: "capture",    label: "Screenshot",   icon: "camera",        cat: "Command · grab a region" },
        { key: "displays",   label: "Displays",     icon: "monitor",       cat: "System · monitors and scaling" },
        // Here as well as as a desktop entry: the entry only exists once
        // tasks/install.sh has run and the shell has seen it, and this
        // works either way — it says how to install it when it isn't.
        { key: "tasks",      label: "Task Manager", icon: "cpu",           cat: "System · processes, performance, services, startup apps" },
        { key: "sound",      label: "Sound",        icon: "volume",        cat: "System · output and input" },
        { key: "network",    label: "Network",      icon: "wifi",          cat: "System · wireless" },
        { key: "bluetooth",  label: "Bluetooth",    icon: "bluetooth",     cat: "System · paired devices" },
        { key: "keybinds",   label: "Keybinds",     icon: "keyboard",      cat: "Command · cheatsheet" },
        { key: "osk",        label: "On-screen keyboard", icon: "keyboard",  cat: "Command · type without a keyboard" },
        { key: "iconmaker",  label: "Icon Maker",   icon: "palette",       cat: "Command · draw a shell icon" },
        { key: "wallpaper",  label: "Wallpaper",    icon: "image",         cat: "Command · change the ground" },
        { key: "reload",     label: "Reload shell", icon: "refresh",       cat: "Command · re-read the QML tree" },
        { key: "lock",       label: "Lock",         icon: "lock",          cat: "Session · lock the screen" },
        { key: "logout",     label: "Log out",      icon: "logOut",        cat: "Session · end this session" },
        { key: "suspend",    label: "Suspend",      icon: "moon",          cat: "Session · sleep" },
        { key: "poweroff",   label: "Power off",    icon: "power",         cat: "Session · shut down" }
    ]
}
