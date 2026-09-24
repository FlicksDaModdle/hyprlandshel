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
                layout: prefs.hyprLayout,
                col: col
            },
            decoration: {
                rounding: prefs.hyprRounding,
                // Hyprland's inactive opacity is a fraction, the setting is a
                // percentage — nobody wants to type 0.92 into a slider.
                inactive_opacity: Math.max(0.4, Math.min(1, prefs.hyprInactiveOpacity / 100)),
                blur: {
                    enabled: prefs.hyprBlur,
                    size: prefs.hyprBlurSize,
                    passes: prefs.hyprBlurPasses
                },
                shadow: { enabled: prefs.hyprShadow }
            },
            input: { follow_mouse: prefs.hyprFocusFollowsMouse ? 1 : 0 }
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
        const had = map[name] || ({});
        map[name] = { mode: mode, scale: scale, position: had.position };
        prefs.displays = JSON.stringify(map);
    }

    // Where the output sits on the desktop plane, kept beside its mode and
    // scale because Hyprland's monitor line carries all three at once.
    //
    // Without this, an arrangement dragged into place in Settings lasted
    // until the next login and then went back to however Hyprland chose to
    // lay the outputs out — which for two monitors is left-to-right in
    // whatever order they were detected, and is exactly what someone
    // opening that panel is trying to change.
    function rememberDisplayPosition(name, x, y) {
        const map = displayMap();
        const had = map[name] || ({});
        map[name] = { mode: had.mode, scale: had.scale,
                      position: Math.round(x) + "x" + Math.round(y) };
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
            if (!want) continue;
            // An entry may hold only a position — an arrangement dragged
            // into place without the mode ever being touched. The monitor
            // line needs a mode regardless, so its current one is filled
            // in rather than the entry being skipped, which is what used
            // to happen and why positions never came back.
            const ipc = m.lastIpcObject || ({});
            const mode = want.mode
                || ((ipc.width || m.width) + "x" + (ipc.height || m.height)
                    + "@" + (Math.round((ipc.refreshRate || 60) * 1000) / 1000));
            const spec = { output: m.name, mode: mode,
                           scale: want.scale || m.scale || 1 };
            // Left out when unknown, so Hyprland places it as it likes
            // rather than being told to put it at the origin.
            if (want.position) spec.position = want.position;
            Services.Compositor.setMonitor(spec);
        }
    }

    // Waits for theme.json to have been read and for Hyprland to have told
    // us what is plugged in. Applying before either would push the built-in
    // defaults over the user's saved values, which is worse than not
    // applying at all.
    property bool applied: false

    // hyprctl reload discards every runtime override, so everything the
    // shell owns goes back on afterwards.
    Connections {
        target: Services.Compositor
        function onConfigReloaded() {
            if (!root.applied) return;
            root.applyInput();
            root.applyFrame();
            root.applyDisplays();
        }
    }

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
