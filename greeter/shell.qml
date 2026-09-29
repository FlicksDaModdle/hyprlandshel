//@ pragma Env QS_NO_RELOAD_POPUP=1
import QtQuick
import Quickshell

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

    // The card goes on the first screen Hyprland lists — the one its own
    // monitor order puts first — and the rest show the time.
    readonly property var primaryScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null

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
                }
                Component.onDestruction: if (slot.window) slot.window.destroy()
            }
        }
    }
}
