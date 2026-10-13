//@ pragma Env QS_NO_RELOAD_POPUP=1
import QtQuick
import Quickshell
import Quickshell.Io
import "shell/config" as Config

// Hyprshell's login screen, run by greetd.
//
//   greetd  →  Hyprland, with greeter/hyprland.lua  →  quickshell -p this file
//
// When you log in, the session you chose is handed to greetd and this
// exits; hyprland.lua then ends the greeter's Hyprland, and greetd starts
// your session in its place.
ShellRoot {
    id: root

    GreeterState { id: greeter }
    // Your desktop's screen scale and pointer, on the login screen too.
    GreeterLook { greeter: greeter }

    // Dressed as the person picked: their own theme — accent, light or
    // dark, rounding, fonts, wallpaper — as their shell last saved it.
    // Without one, the greeter's own (install.sh --theme).
    Binding {
        target: Config.Appearance
        property: "themeFile"
        value: userTheme.there ? userTheme.path : ""
    }
    // Whether the person picked has a copy at all — someone who has never
    // run the shell has none, and gets the greeter's own look, not the
    // last person's.
    FileView {
        id: userTheme
        property bool there: false
        path: greeter.userDir !== "" ? greeter.userDir + "/theme.json" : ""
        printErrors: false
        onPathChanged: there = false
        onLoaded: there = true
        onLoadFailed: there = false
    }

    // Which screen has the card; the rest show the time.
    //
    // It used to be simply the first screen Hyprland lists, which on a
    // laptop is its own panel — so with a monitor plugged in, the card was
    // on the laptop (lid shut, or just not the screen being looked at) and
    // the monitor in front of you showed a clock and nothing to type into.
    //
    // Now: an external monitor over the laptop's own panel (the biggest, if
    // there are several), and after that wherever you move the pointer or
    // click — the card, and the keyboard with it, come to that screen.
    function isInternal(s) { return /^(eDP|LVDS|DSI)/i.test(String(s.name || "")); }
    readonly property var defaultScreen: {
        const all = Quickshell.screens;
        if (all.length === 0) return null;
        const outside = all.filter(s => !root.isInternal(s));
        const pool = outside.length > 0 ? outside : all;
        let best = pool[0];
        for (const s of pool)
            if (s.width * s.height > best.width * best.height) best = s;
        return best;
    }
    readonly property var primaryScreen: {
        const want = greeter.pointerScreen;
        if (want !== "") {
            const s = Quickshell.screens.find(x => x.name === want);
            if (s) return s;
        }
        return root.defaultScreen;
    }

    // A layer-shell window on Wayland, which is where greetd runs it; an
    // ordinary one anywhere else, for previews.
    readonly property url windowFile: Quickshell.env("WAYLAND_DISPLAY")
        ? Qt.resolvedUrl("GreeterWindow.qml") : Qt.resolvedUrl("GreeterWindowX11.qml")

    Variants {
        model: Quickshell.screens

        delegate: Component {
            QtObject {
                id: slot
                required property var modelData
                property var window: null

                Component.onCompleted: {
                    const c = Qt.createComponent(root.windowFile);
                    if (c.status !== Component.Ready) {
                        console.error("greeter: " + c.errorString());
                        return;
                    }
                    slot.window = c.createObject(slot, {
                        screen: slot.modelData,
                        greeter: greeter,
                        primary: slot.modelData === root.primaryScreen
                    });
                    if (slot.window)
                        slot.window.primary = Qt.binding(() => slot.modelData === root.primaryScreen);
                }
                Component.onDestruction: if (slot.window) slot.window.destroy()
            }
        }
    }
}
