//@ pragma UseQApplication

import Quickshell
import Quickshell.Io
import "config" as Config
import "services" as Services
import "modules/background"
import "modules/bar"
import "modules/dock"
import "modules/launcher"
import "modules/osk"
import "modules/panels"
import "modules/notifications"
import "modules/overview"
import "modules/osd"
import "modules/settings"
import "modules/iconmaker"
import "modules/lock"
import "modules/switcher"
import "modules/corners"

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

    // And again, but this one matters most: Commands owns the table of
    // everything the shell can be asked to do *and* the watcher that the
    // keyboard shortcuts talk to. Nothing else references it at startup, so
    // without this line the shortcuts would not work until something else
    // happened to touch the singleton.
    readonly property bool commandsReady: Services.Commands.watching

    // And again: Kvantum writes a Qt style out of the current theme, and
    // nothing else in the shell has any reason to look at it.
    readonly property bool qtThemed: Services.Kvantum.enabled

    // And the pointer: Cursor draws and installs the accent cursor theme,
    // and nothing else would build it before Settings was opened.
    readonly property bool cursorThemed: Services.Cursor.enabled

    // And sound effects: an equalizer or noise suppression left on comes
    // back at login only if something starts AudioFx.
    readonly property bool audioFxStarted: Services.AudioFx.probed || true

    // And clipboard history, which has to be listening before anything is
    // copied, not from the first time its panel opens.
    readonly property bool clipboardStarted: Services.Clipboard.enabled || true

    // And the wallpaper's accent, which has to follow a wallpaper changed
    // from anywhere, Settings open or not.
    readonly property bool wallAccentStarted: Services.WallpaperAccent.enabled || true

    // And the ROG laptop controls, whose keyboard light follows the accent
    // when chosen, Settings open or not.
    readonly property bool rogStarted: Services.Rog.available || true

    // And idle: the lock, screen off and sleep timers have to be set from
    // the start, Settings open or not.
    readonly property bool idleStarted: Services.Idle.available || true

    // And removable drives, which mount and notify on their own.
    readonly property bool usbStarted: Services.Usb.available || true

    // And Battery saver, which has no surface and acts on its own.
    readonly property bool powerSaverStarted: Services.PowerSaver.active || true

    // Shell shortcuts, registered with the compositor over
    // hyprland-global-shortcuts-v1, so anything on the session can dispatch
    // `global, hyprshell:<name>` to the shell.
    //
    // The config's own keybinds do not use them: this protocol is behind a
    // Quickshell build flag, and on a build without it the registrations
    // never happen and every bind pointing at one is a silent no-op. They
    // call the IpcHandler below through hyprshellctl instead, which works on
    // every build. These stay for everything else that might want them.
    //
    // Loaded from a URL rather than imported, because importing a module
    // this build may not have would stop the whole shell from starting
    // instead of just leaving the shortcuts unregistered.
    //
    // Quickshell's own LazyLoader, not QtQuick's Loader: this file does not
    // import QtQuick (nothing else in it is visual), and a QtQuick Loader
    // here is a hard "Loader is not a type" at load — which is exactly what
    // it was. LazyLoader is a plain QObject from Quickshell, takes the same
    // source URL, and holds a Scope perfectly well.
    //
    // A build without the protocol logs Quickshell's own warning naming the
    // missing type and carries on with item left null. Nothing else in the
    // shell touches it, and the keybinds do not go this way, so that is the
    // end of it.
    LazyLoader {
        id: shortcuts
        source: "modules/shortcuts/GlobalShortcuts.qml"
        loading: true
    }

    // The polkit agent: the password prompt for anything acting as
    // administrator. Loaded the same way and for the same reason as the
    // shortcuts above — Quickshell.Services.Polkit is a build option, and a
    // build without it should lose the prompt, not the shell.
    LazyLoader {
        id: polkit
        source: "modules/polkit/PolkitPrompt.qml"
        loading: true
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
    // Above the panels, since it is there to type into whatever is on
    // top of them.
    Osk {}
    Overview {}
    Osd {}
    Settings {}
    // Built when opened and let go when closed — it is a whole editor,
    // and most sessions never open it. Kept while a drawing is unsaved, so
    // closing the window (or locking the screen) doesn't throw work away.
    LazyLoader {
        id: iconMaker
        active: Config.UiState.iconMakerOpen || (!!iconMaker.item && iconMaker.item.dirty)
        IconMaker {}
    }
    Lock {}
    AltTab {}
    // Last: over everything, the screen's own corners rounded off.
    ScreenCorners {}

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
    // The same commands over Quickshell's IPC socket, for `qs ipc call` and
    // for anything else that wants to drive the shell. Every function hands
    // straight to the Commands table, which is also what the keyboard
    // shortcuts reach, so the two cannot drift into doing different things.
    //
    // This is no longer how the keybinds get here: finding this process from
    // outside turned out to be the unreliable part. See Commands.qml.
    IpcHandler {
        target: "shell"

        // Panels
        function toggleLauncher(): void { Services.Commands.run("toggleLauncher"); }
        function toggleOverview(): void { Services.Commands.run("toggleOverview"); }
        function toggleControlCenter(): void { Services.Commands.run("toggleControlCenter"); }
        function toggleNotifications(): void { Services.Commands.run("toggleNotifications"); }
        function toggleCalendar(): void { Services.Commands.run("toggleCalendar"); }
        function togglePower(): void { Services.Commands.run("togglePower"); }
        function toggleClipboard(): void { Services.Commands.run("toggleClipboard"); }
        function closePanels(): void { Services.Commands.run("closePanels"); }
        function openSettings(pane: string): void { Services.Commands.run("openSettings " + pane); }
        function openFiles(path: string): void { Services.Commands.run("openFiles " + path); }

        // Appearance
        function toggleTheme(): void { Services.Commands.run("toggleTheme"); }
        function cycleTheme(): void { Services.Commands.run("cycleTheme"); }
        function setTheme(name: string): void { Services.Commands.run("setTheme " + name); }
        function setWallpaper(path: string): void { Services.Commands.run("setWallpaper " + path); }
        function setLiveWallpaper(path: string): void { Services.Commands.run("setLiveWallpaper " + path); }
        function nextLiveWallpaper(): void { Services.Commands.run("nextLiveWallpaper"); }
        function setAccent(index: int): void { Services.Commands.run("setAccent " + index); }
        function syncTheming(): void { Services.Commands.run("syncTheming"); }

        // Session
        function lock(): void { Services.Commands.run("lock"); }
        function reloadShell(): void { Services.Commands.run("reloadShell"); }

        // Levels
        function volumeUp(): void { Services.Commands.run("volumeUp"); }
        function volumeDown(): void { Services.Commands.run("volumeDown"); }
        function volumeMute(): void { Services.Commands.run("volumeMute"); }
        function micMute(): void { Services.Commands.run("micMute"); }
        function brightnessUp(): void { Services.Commands.run("brightnessUp"); }
        function brightnessDown(): void { Services.Commands.run("brightnessDown"); }

        // Notifications and windows
        function toggleDnd(): void { Services.Commands.run("toggleDnd"); }
        function showDesktop(): void { Services.Commands.run("showDesktop"); }
        // next | prev | commit | cancel — what the Alt+Tab binds send.
        function altTab(action: string): void { Services.Switcher.command(action); }
    }
}
