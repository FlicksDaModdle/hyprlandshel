pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config
import "." as Services

// Owns the input-device and display settings, and is the reason they
// survive a restart.
//
// Hyprland's config is write-only over IPC: there is no call to read an
// option back, and every value it holds comes from hyprland.lua, which is
// re-read from scratch on every launch. So anything the Settings window
// changes at runtime is gone the next time you log in unless the shell
// remembers it and puts it back. That is this file.
//
// The values themselves live in theme.json (Config.Appearance), so they are
// editable by hand and backed up with the rest of your preferences.
Singleton {
    id: root

    readonly property var A: Config.Appearance

    // The whole input tree in one call. hl.config merges, so sending it as a
    // single statement is one hyprctl round trip instead of twenty.
    function inputTree() {
        return {
            input: {
                repeat_rate: A.repeatRate,
                repeat_delay: A.repeatDelay,
                numlock_by_default: A.numlock,
                follow_mouse: A.followMouse,
                sensitivity: A.sensitivity,
                accel_profile: A.accelProfile,
                left_handed: A.leftHanded,
                natural_scroll: A.mouseNaturalScroll,
                scroll_factor: A.mouseScrollFactor,
                touchpad: {
                    tap_to_click: A.tapToClick,
                    tap_and_drag: A.tapAndDrag,
                    drag_lock: A.dragLock,
                    natural_scroll: A.padNaturalScroll,
                    scroll_factor: A.padScrollFactor,
                    disable_while_typing: A.disableWhileTyping,
                    clickfinger_behavior: A.clickfinger,
                    tap_button_map: A.tapButtonMap,
                    middle_button_emulation: A.middleEmulation
                }
            },
            cursor: {
                hide_on_key_press: A.hideCursorOnKey,
                inactive_timeout: A.cursorTimeout
            }
        };
    }

    function applyInput() { Services.Compositor.setConfig(inputTree()); }

    // ── displays ──────────────────────────────────────────────────────────
    function displayMap() {
        if (!A.displays) return ({});
        try {
            const o = JSON.parse(A.displays);
            return (o && typeof o === "object") ? o : ({});
        } catch (e) {
            console.warn("Devices: theme.json displays is not valid JSON —", e);
            return ({});
        }
    }

    function rememberDisplay(name, mode, scale) {
        const map = displayMap();
        map[name] = { mode: mode, scale: scale };
        A.displays = JSON.stringify(map);
    }

    function forgetDisplays() { A.displays = ""; }

    // Only outputs that are actually connected are re-applied: a saved mode
    // for a monitor that isn't plugged in would be an error every launch.
    function applyDisplays() {
        const map = displayMap();
        const live = Services.Compositor.monitors || [];
        for (let i = 0; i < live.length; i++) {
            const m = live[i];
            const want = map[m.name];
            if (!want || !want.mode) continue;
            Services.Compositor.setMonitor({
                output: m.name, mode: want.mode, scale: want.scale || 1
            });
        }
    }

    // Waits for theme.json to have been read and for Hyprland to have told
    // us what is plugged in. Applying before either would push the built-in
    // defaults over the user's saved values, which is worse than not
    // applying at all.
    property bool applied: false

    Timer {
        interval: 1500
        running: true
        repeat: true
        onTriggered: {
            if (root.applied) { running = false; return; }
            if (!Services.Compositor.ipcReady
                && (Services.Compositor.monitors || []).length === 0) return;
            root.applied = true;
            root.applyInput();
            root.applyDisplays();
            running = false;
        }
    }
}
