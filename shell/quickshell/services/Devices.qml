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

    // Lower case: QML rejects a property whose name starts with a
    // capital, because that is the namespace for types.
    readonly property var prefs: Config.Appearance

    // The whole input tree in one call. hl.config merges, so sending it as a
    // single statement is one hyprctl round trip instead of twenty.
    function inputTree() {
        return {
            input: {
                repeat_rate: prefs.repeatRate,
                repeat_delay: prefs.repeatDelay,
                numlock_by_default: prefs.numlock,
                follow_mouse: prefs.followMouse,
                sensitivity: prefs.sensitivity,
                accel_profile: prefs.accelProfile,
                left_handed: prefs.leftHanded,
                natural_scroll: prefs.mouseNaturalScroll,
                scroll_factor: prefs.mouseScrollFactor,
                touchpad: {
                    tap_to_click: prefs.tapToClick,
                    tap_and_drag: prefs.tapAndDrag,
                    drag_lock: prefs.dragLock,
                    natural_scroll: prefs.padNaturalScroll,
                    scroll_factor: prefs.padScrollFactor,
                    disable_while_typing: prefs.disableWhileTyping,
                    clickfinger_behavior: prefs.clickfinger,
                    tap_button_map: prefs.tapButtonMap,
                    middle_button_emulation: prefs.middleEmulation
                }
            },
            cursor: {
                hide_on_key_press: prefs.hideCursorOnKey,
                inactive_timeout: prefs.cursorTimeout
            }
        };
    }

    function applyInput() { Services.Compositor.setConfig(inputTree()); }

    // ── window frame ──────────────────────────────────────────────────────
    // Gaps, border thickness and the focused window's border colour. The
    // accent drives the border by default, so the compositor's idea of
    // "focused" matches the shell's everywhere else.
    function frameTree() {
        const col = ({ inactive_border: prefs.hyprColor(prefs.div, "aa") });
        if (prefs.borderFollowsAccent)
            col.active_border = prefs.hyprColor(prefs.accent, "ee");
        return {
            general: {
                gaps_in: prefs.gapsIn,
                gaps_out: prefs.gapsOut,
                border_size: prefs.borderSize,
                col: col
            }
        };
    }

    function applyFrame() { Services.Compositor.setConfig(frameTree()); }

    // The border should follow a theme flip or a new accent without waiting
    // for the next login.
    readonly property color accentNow: prefs.accent
    onAccentNowChanged: if (applied && prefs.borderFollowsAccent) applyFrame();

    // ── displays ──────────────────────────────────────────────────────────
    function displayMap() {
        if (!prefs.displays) return ({});
        try {
            const o = JSON.parse(prefs.displays);
            return (o && typeof o === "object") ? o : ({});
        } catch (e) {
            console.warn("Devices: theme.json displays is not valid JSON —", e);
            return ({});
        }
    }

    function rememberDisplay(name, mode, scale) {
        const map = displayMap();
        map[name] = { mode: mode, scale: scale };
        prefs.displays = JSON.stringify(map);
    }

    function forgetDisplays() { prefs.displays = ""; }

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
            root.applyFrame();
            root.applyDisplays();
            running = false;
        }
    }
}
