import QtQuick
import Quickshell
import Quickshell.Hyprland
import "../../config" as Config
import "../../services" as Services

// Every shell shortcut, registered with the compositor directly.
//
// This replaces the old chain — keybind spawns a process, process finds the
// running shell, process opens an IPC socket, shell acts — of which every
// link could fail silently, because nobody watches a keybind's stderr. It
// was failing: the IPC call worked by hand and did nothing from a bind.
//
// hyprland-global-shortcuts-v1 removes all of it. The shell tells Hyprland
// "I have a shortcut called hyprshell:launcher"; hyprland.lua binds a key to
// `global, hyprshell:launcher`; the event arrives here over the Wayland
// connection the shell already has open. No qs binary to find on PATH, no
// socket to match, no config selector to get right.
//
// `hyprctl globalshortcuts` lists what registered, which makes this the
// first part of the chain that can actually be inspected from outside.
//
// Loaded through a Loader with a URL rather than imported directly:
// GlobalShortcut is behind a build flag, and on a Quickshell without it a
// direct import would stop the whole shell from starting.
QtObject {
    id: root

    // One per action. The name is what hyprland.lua binds to, so these are
    // API — changing one breaks the binding until the config is regenerated.
    readonly property list<QtObject> shortcuts: [
        GlobalShortcut {
            appid: "hyprshell"; name: "launcher"
            description: "Open the launcher"
            onPressed: Config.UiState.toggleLauncher()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "overview"
            description: "Workspace overview"
            onPressed: Config.UiState.toggleOverview()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "control"
            description: "Control center"
            onPressed: Config.UiState.toggleControlCenter()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "notifications"
            description: "Notification center"
            onPressed: Config.UiState.toggleNotifications()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "calendar"
            description: "Calendar"
            onPressed: Config.UiState.toggleCalendar()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "power"
            description: "Power menu"
            onPressed: Config.UiState.togglePower()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "dnd"
            description: "Toggle do not disturb"
            onPressed: Services.Notifications.toggleDnd()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "settings"
            description: "Open settings"
            onPressed: Config.UiState.openSettings("Appearance")
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "theme"
            description: "Toggle light/dark"
            onPressed: Config.Appearance.toggleTheme()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "lock"
            description: "Lock the session"
            onPressed: Config.UiState.lock()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "reload"
            description: "Reload the shell"
            onPressed: Services.Session.reloadShell()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "showdesktop"
            description: "Show the desktop"
            onPressed: Services.Compositor.toggleShowDesktop()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "volumeup"
            description: "Volume up"
            onPressed: Services.Audio.step(0.05)
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "volumedown"
            description: "Volume down"
            onPressed: Services.Audio.step(-0.05)
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "volumemute"
            description: "Mute output"
            onPressed: Services.Audio.toggleMute()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "micmute"
            description: "Mute microphone"
            onPressed: Services.Audio.toggleInputMute()
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "brightnessup"
            description: "Brightness up"
            onPressed: Services.Brightness.step(0.05)
        },
        GlobalShortcut {
            appid: "hyprshell"; name: "brightnessdown"
            description: "Brightness down"
            onPressed: Services.Brightness.step(-0.05)
        }
    ]
}
