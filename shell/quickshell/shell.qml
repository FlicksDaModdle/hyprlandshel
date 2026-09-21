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

    // Singletons are created lazily on first use, but several have to be
    // alive whether or not a surface is showing them right now — the
    // notification server must accept notifications with the center closed,
    // and the pollers behind the bar need to have started. Touching them
    // once here brings them all up with the shell.
    Component.onCompleted: {
        const started = [
            Services.Notifications, Services.Compositor, Services.Audio,
            Services.Brightness, Services.Network, Services.Bluetooth,
            Services.NightLight, Services.SysInfo, Services.Session
        ];
        Services.Compositor.refresh();
    }

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

        // Windows
        function showDesktop(): void { Services.Compositor.toggleShowDesktop(); }
    }
}
