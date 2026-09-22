import QtQuick
import Quickshell
import Quickshell.Hyprland
import "../../config" as Config
import "../../services" as Services

// Every shell shortcut, registered with the compositor directly.
//
// hyprland-global-shortcuts-v1: the shell tells Hyprland "I have a shortcut
// called hyprshell:launcher", and anything on the session can then dispatch
// `global, hyprshell:launcher` to it, over the Wayland connection the shell
// already has open. `hyprctl globalshortcuts` lists what registered.
//
// The config's own keybinds used to come this way and no longer do. The
// protocol is behind a Quickshell build flag; on a build without it nothing
// here registers, and a bind pointing at an unregistered shortcut does
// nothing and reports nothing — which is exactly what happened. Those binds
// call shell.qml's IpcHandler through hyprshellctl instead, which works on
// every build. This file stays for everything else that might want to reach
// the shell: other compositor binds, scripts, a remote, a stream deck.
//
// Each shortcut therefore has to do the same thing as the IpcHandler
// function of the same purpose. Keep the two in step.
//
// Loaded through a Loader with a URL rather than imported directly:
// GlobalShortcut is behind that build flag, and a direct import would stop
// the whole shell from starting on a Quickshell without it.
//
// Scope rather than a bare QtObject: it is Quickshell's own
// reload-propagating container, and GlobalShortcut registers itself from a
// post-reload hook, so this is the container built for holding them.
//
// The names are API — anything dispatching to them breaks if one changes.
Scope {
    id: root

    GlobalShortcut {
        appid: "hyprshell"
        name: "launcher"
        description: "Open the launcher"
        onPressed: Config.UiState.toggleLauncher()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "overview"
        description: "Workspace overview"
        onPressed: Config.UiState.toggleOverview()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "control"
        description: "Control center"
        onPressed: Config.UiState.toggleControlCenter()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "notifications"
        description: "Notification center"
        onPressed: Config.UiState.toggleNotifications()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "calendar"
        description: "Calendar"
        onPressed: Config.UiState.toggleCalendar()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "power"
        description: "Power menu"
        onPressed: Config.UiState.togglePower()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "dnd"
        description: "Toggle do not disturb"
        onPressed: Services.Notifications.toggleDnd()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "settings"
        description: "Open settings"
        onPressed: Config.UiState.openSettings("Appearance")
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "theme"
        description: "Toggle light/dark"
        onPressed: Config.Appearance.toggleTheme()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "lock"
        description: "Lock the session"
        onPressed: Config.UiState.lock()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "reload"
        description: "Reload the shell"
        onPressed: Services.Session.reloadShell()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "showdesktop"
        description: "Show the desktop"
        onPressed: Services.Compositor.toggleShowDesktop()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "volumeup"
        description: "Volume up"
        onPressed: Services.Audio.step(0.05)
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "volumedown"
        description: "Volume down"
        onPressed: Services.Audio.step(-0.05)
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "volumemute"
        description: "Mute output"
        onPressed: Services.Audio.toggleMute()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "micmute"
        description: "Mute microphone"
        onPressed: Services.Audio.toggleInputMute()
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "brightnessup"
        description: "Brightness up"
        onPressed: Services.Brightness.step(0.05)
    }

    GlobalShortcut {
        appid: "hyprshell"
        name: "brightnessdown"
        description: "Brightness down"
        onPressed: Services.Brightness.step(-0.05)
    }
}
