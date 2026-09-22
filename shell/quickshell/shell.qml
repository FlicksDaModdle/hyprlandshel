//@ pragma UseQApplication

import Quickshell
import Quickshell.Io
import "config" as Config
import "services" as Services
import "modules/background"
import "modules/bar"
import "modules/dock"
import "modules/launcher"
import "modules/panels"
import "modules/notifications"
import "modules/overview"
import "modules/osd"
import "modules/settings"
import "modules/lock"

// Entry point. Run as `qs -c hyprshell` (this directory should live at
// ~/.config/quickshell/hyprshell/). hyprland.lua's autostart hook and
// keybinds assume that name.
ShellRoot {

    // Theming has no surface of its own, so no surface below would reference
    // it — and Quickshell builds a singleton on first reference, so without
    // this it would never be constructed and the terminal would never follow
    // the shell's theme. Root-object bindings are evaluated when the component
    // completes, so this reference is the thing that starts it.
    readonly property bool terminalThemed: Services.Theming.kittyPresent

    // Same reason: Devices has no surface, and it is what puts your saved
    // input and display settings back after a restart — Hyprland forgets
    // everything that isn't in hyprland.lua each time it launches.
    readonly property bool devicesRestored: Services.Devices.applied

    // Same again: Keybinds owns the generated binds.lua and is only reached
    // from the Settings pane, which may never be opened.
    readonly property int shortcutCount: Services.Keybinds.actions.length

    // Shell shortcuts, registered with the compositor over
    // hyprland-global-shortcuts-v1 instead of arriving as an IPC call from a
    // process a keybind spawned. See the file for why that changed.
    //
    // Through a Loader with a URL, not an import: GlobalShortcut is behind a
    // Quickshell build flag, and importing it directly on a build without it
    // would stop the shell from starting rather than just leaving the
    // shortcuts unregistered.
    Loader {
        id: shortcuts
        source: "modules/shortcuts/GlobalShortcuts.qml"
        onStatusChanged: {
            if (status === Loader.Error) {
                console.warn("Shell: global shortcuts unavailable — this Quickshell "
                             + "was built without HYPRLAND_GLOBAL_SHORTCUTS. "
                             + "Keybinds will need the hyprshellctl fallback.");
            }
        }
    }

    // ── surfaces ──────────────────────────────────────────────────────────
    // Ordered background to foreground, though each one sets its own
    // layer-shell layer and the compositor does the actual stacking.
    Wallpaper {}
    Bar {}
    Dock {}
    PanelLayer {}
    NotificationToasts {}
    Launcher {}
    Overview {}
    Osd {}
    Settings {}
    Lock {}

    // No Component.onCompleted here: QML will not attach one to ShellRoot.
    //
    // It also isn't needed. Singletons build on first reference, and Bar.qml
    // reads Notifications, Compositor, Audio, Network, Bluetooth, Brightness
    // and NightLight while laying out its own status area — so everything
    // that has to be live from startup is built by the bar. Session is only
    // reached when you pick something from the power menu, which is exactly
    // when it should come up.

    // ── IPC ───────────────────────────────────────────────────────────────
    // Reached from Hyprland keybinds via `qs ipc call shell <fn>`
    // (see ../hypr/hyprland.lua). Keeping every shortcut on this one target
    // means the compositor never has to know how the shell is structured.
    IpcHandler {
        target: "shell"

        // Panels
        function toggleLauncher(): void { Config.UiState.toggleLauncher(); }
        function toggleOverview(): void { Config.UiState.toggleOverview(); }
        function toggleControlCenter(): void { Config.UiState.toggleControlCenter(); }
        function toggleNotifications(): void { Config.UiState.toggleNotifications(); }
        function toggleCalendar(): void { Config.UiState.toggleCalendar(); }
        function togglePower(): void { Config.UiState.togglePower(); }
        function closePanels(): void { Config.UiState.closeAll(); }

        function openSettings(pane: string): void {
            Config.UiState.openSettings(pane && pane !== "" ? pane : "Appearance");
        }

        // Appearance
        function toggleTheme(): void { Config.Appearance.toggleTheme(); }
        function cycleTheme(): void { Config.Appearance.cycleTheme(); }
        function setTheme(name: string): void { Config.Appearance.setTheme(name); }
        function setWallpaper(path: string): void { Config.Appearance.wallpaper = path; }
        function setAccent(index: int): void { Config.Appearance.accentIndex = index; }

        // Session
        function lock(): void { Config.UiState.lock(); }
        function reloadShell(): void { Services.Session.reloadShell(); }

        // Levels. Bound to the media keys so the shell's own OSD is what
        // shows, instead of each hotkey silently poking wpctl.
        function volumeUp(): void { Services.Audio.step(0.05); }
        function volumeDown(): void { Services.Audio.step(-0.05); }
        function volumeMute(): void { Services.Audio.toggleMute(); }
        function micMute(): void { Services.Audio.toggleInputMute(); }
        function brightnessUp(): void { Services.Brightness.step(0.05); }
        function brightnessDown(): void { Services.Brightness.step(-0.05); }

        // Do not disturb
        function toggleDnd(): void { Services.Notifications.toggleDnd(); }

        // Re-push the theme to the terminal. Useful straight after installing
        // the kitty config into a session that is already running.
        function syncTheming(): void { Services.Theming.resync(); }

        // Windows
        function showDesktop(): void { Services.Compositor.toggleShowDesktop(); }
    }
}
