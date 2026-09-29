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
        const col = ({ inactive_border: prefs.hyprColor(prefs.inactiveBorderColor, "aa") });
        if (prefs.borderFollowsAccent)
            col.active_border = prefs.hyprColor(prefs.activeBorderColor, "ee");
        return {
            general: {
                gaps_in: prefs.gapsIn,
                gaps_out: prefs.gapsOut,
                border_size: prefs.borderSize,
                layout: prefs.hyprLayout,
                col: col
            },
            decoration: {
                // Corner rounding scales every radius, the windows' own
                // corners included: the px value is theirs at 100%. Without
                // this, 0% squared everything the shell and its apps draw
                // — the browser too — inside a window that stayed round.
                rounding: Math.round(prefs.hyprRounding * prefs.rf),
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

    // The borders should follow a theme flip, a new accent or either
    // brightness without waiting for the next login. As the strings sent,
    // so only a change Hyprland would actually see applies anything — and
    // the inactive colour, which a theme flip changes too, is covered as
    // well as the accent.
    readonly property string bordersNow: JSON.stringify(frameTree().general.col)
    onBordersNowChanged: if (applied) applyFrame();

    // Likewise the window corners, as Corner rounding moves.
    readonly property real roundingNow: prefs.rf
    onRoundingNowChanged: if (applied) applyFrame();

    // ── displays ──────────────────────────────────────────────────────────
    //
    // One entry per output, keyed by name, and every key inside an entry is
    // spelled the way hl.monitor spells it — `mode`, `scale`, `position`,
    // `bitdepth`, `cm`, `sdrbrightness`, `sdrsaturation`,
    // `supports_wide_color`, `supports_hdr`. That is not a coincidence kept
    // up by hand: building the table to send is then a copy, and a field
    // added to one side cannot arrive on the other under a different name.
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

    // Merged into whatever the entry already holds, never replacing it.
    //
    // Each control in the Display pane owns one or two keys and none of
    // them should be able to forget the rest. Writing the resolution used
    // to rebuild the entry as { mode, scale, position }, which was the
    // whole entry at the time and is now most of the way to dropping the
    // colour settings sitting beside it. Passing undefined removes a key.
    function saveDisplay(name, patch) {
        const map = displayMap();
        const had = map[name] || ({});
        const next = ({});
        for (const k in had) next[k] = had[k];
        for (const k in patch) {
            if (patch[k] === undefined) delete next[k];
            else next[k] = patch[k];
        }
        map[name] = next;
        prefs.displays = JSON.stringify(map);
    }

    function rememberDisplay(name, mode, scale) {
        saveDisplay(name, { mode: mode, scale: scale });
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
        saveDisplay(name, { position: Math.round(x) + "x" + Math.round(y) });
    }

    function forgetDisplays() { prefs.displays = ""; }

    // ── colour ────────────────────────────────────────────────────────────
    //
    // Bit depth and colour management, applied through the same monitor
    // rule as the mode. `bitdepth` is 8 or 10; `cm` is one of the names in
    // Hyprland's own table — auto, srgb, wide, edid, hdr, hdredid, dcip3,
    // dp3, adobe — and anything else is rejected with "invalid cm". The two
    // sdr* values scale SDR content inside an HDR blend, where white would
    // otherwise sit at the reference 80 nits and look grey next to HDR
    // highlights. supports_wide_color and supports_hdr are the overrides
    // for a panel whose EDID undersells it: -1 no, 0 believe the EDID, 1
    // yes.
    //
    // Turning something off stores the off value rather than dropping the
    // key, because hl.monitor merges into the rule the output already has:
    // a removed `bitdepth` leaves 10 in the compositor with nothing in the
    // panel still claiming it.
    function rememberColour(name, patch) {
        saveDisplay(name, patch);
        applyDisplay(name);
        Services.Compositor.refreshMonitors();
    }

    // The fields an entry may carry, in the order hl.monitor reads them.
    // mode and scale are handled separately because they are never left
    // out — see displaySpec.
    readonly property var monitorFields: [
        "position", "bitdepth", "cm", "sdrbrightness", "sdrsaturation",
        "supports_wide_color", "supports_hdr"
    ]

    // The whole monitor table for one output, or null when it isn't
    // plugged in.
    function displaySpec(name) {
        const live = (Services.Compositor.monitors || []).find(m => m && m.name === name);
        if (!live) return null;
        const want = displayMap()[name] || ({});
        const ipc = live.lastIpcObject || ({});

        const spec = ({ output: name });

        // An entry may hold only a position — an arrangement dragged into
        // place without the mode ever being touched — or only a colour
        // setting. The mode and the scale go in regardless, filled from
        // what the output is doing now, because hl.monitor's own defaults
        // for them are "preferred" and "auto" rather than "leave it": the
        // first table ever sent for an output that hyprland.lua does not
        // name would otherwise change its resolution as a side effect of
        // switching on 10-bit.
        spec.mode = want.mode
            || ((ipc.width || live.width) + "x" + (ipc.height || live.height)
                + "@" + (Math.round((ipc.refreshRate || 60) * 1000) / 1000));
        spec.scale = want.scale || live.scale || 1;

        // Only keys the entry actually carries. Stating every colour field
        // every time would overwrite a `bitdepth = 10` written by hand in
        // hyprland.lua the first time somebody dragged this monitor
        // somewhere else.
        for (let i = 0; i < root.monitorFields.length; i++) {
            const k = root.monitorFields[i];
            if (want[k] !== undefined) spec[k] = want[k];
        }
        return spec;
    }

    function applyDisplay(name) {
        const spec = displaySpec(name);
        if (spec) Services.Compositor.setMonitor(spec);
    }

    // Only outputs that are actually connected are re-applied: a saved mode
    // for a monitor that isn't plugged in would be an error every launch.
    function applyDisplays() {
        const map = displayMap();
        const live = Services.Compositor.monitors || [];
        for (let i = 0; i < live.length; i++) {
            const m = live[i];
            if (m && map[m.name]) root.applyDisplay(m.name);
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
