//@ pragma UseQApplication

import Quickshell
import Quickshell.Io
import "modules/dock"
import "modules/launcher"
import "config" as Config

// Entry point. Run as `qs -c hyprshell` (this directory should live at
// ~/.config/quickshell/hyprshell/). hyprland.lua's autostart hook and
// keybinds assume that name.
ShellRoot {
    // Reached from Hyprland keybinds via `qs ipc call shell <fn>`
    // (see ../hypr/hyprland.lua). State lives in config/UiState.qml so
    // every module — Dock today, Launcher/Overview/etc. as they're built —
    // can react to the same toggles.
    IpcHandler {
        target: "shell"

        function toggleLauncher(): void {
            Config.UiState.toggleLauncher();
        }

        function toggleOverview(): void {
            Config.UiState.toggleOverview();
        }

        function toggleTheme(): void {
            Config.Appearance.dark = !Config.Appearance.dark;
        }

        function toggleSnapLayout(): void {
            // TODO: wired up once window snapping lands.
        }
    }

    Dock {}
    Launcher {}
}
