pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
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

    function applyInput() {
        Services.Compositor.setConfig(inputTree());
        applyTouchpads();
        scanPointers.running = true;
    }

    // ── mouse and touchpad apart ──────────────────────────────────────────
    //
    // Hyprland has one pointer speed and one acceleration profile for
    // everything, in input: — its touchpad section has neither. So those
    // two input values are the mouse's, and each touchpad is given its own
    // over the top with hl.device, which Hyprland lets set any pointer's
    // separately. That needs the touchpads' names: `hyprctl devices`
    // lists every pointer without saying which is which, and libinput
    // names a touchpad for what it is ("…Touchpad", "…TouchPad",
    // "Magic Trackpad"), so they are picked out by name. Settings →
    // Touchpad shows what was found.
    property var touchpads: []
    property var pointers: []

    function isTouchpad(name) {
        return /touch-?pad|track-?pad|clickpad|glidepoint/i.test(name || "");
    }

    function touchpadTree(name) {
        return { name: name,
                 sensitivity: prefs.padSensitivityNow,
                 accel_profile: prefs.padAccelNow };
    }

    function applyTouchpads() {
        for (const name of root.touchpads) Services.Compositor.setDevice(touchpadTree(name));
    }

    Process {
        id: scanPointers
        command: ["hyprctl", "devices", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let mice = [];
                try { mice = (JSON.parse(text).mice || []).map(m => m.name).filter(n => !!n); }
                catch (e) { return; }
                root.pointers = mice;
                const found = mice.filter(n => root.isTouchpad(n));
                const fresh = found.some(n => root.touchpads.indexOf(n) < 0);
                root.touchpads = found;
                // Sent again only when one appears that was not there
                // before; the rest already have theirs, and Hyprland keeps
                // them by name.
                if (fresh && root.applied) root.applyTouchpads();
            }
        }
    }
    // A touchpad that arrives later — a Bluetooth one — is picked up here.
    Timer {
        interval: 20000
        running: root.applied
        repeat: true
        onTriggered: scanPointers.running = true
    }

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
    // The one exception is `batteryRate`, the shell's own (see modeFor),
    // which is read here and never sent.
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
        // A rate chosen by hand is a fresh start for keeping it (see enforce).
        root.fixes = Object.assign({}, root.fixes, { [name]: [] });
        root.contested = Object.assign({}, root.contested, { [name]: undefined });
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

    // ── on battery ────────────────────────────────────────────────────────
    //
    // A display can run at another rate on battery: `batteryRate` in its
    // entry, in Hz, and none means the same as plugged in. The resolution
    // stays whatever `mode` says; only the rate changes, to the one the
    // output actually has nearest that number at that resolution, since a
    // rate Hyprland is not offered exactly is one it will not set.
    readonly property bool onBattery: UPower.onBattery

    function nearestRate(ipc, res, hz) {
        let best = hz, gap = Infinity;
        for (const s of ipc.availableModes || []) {
            const m = /^(\d+x\d+)@([\d.]+)/.exec(s);
            if (!m || m[1] !== res) continue;
            const r = parseFloat(m[2]);
            if (Math.abs(r - hz) < gap) { gap = Math.abs(r - hz); best = r; }
        }
        return Math.round(best * 1000) / 1000;
    }

    // The mode to run now: the saved one, at the battery rate when there
    // is one and the machine is on battery.
    function modeFor(name, want, live) {
        const ipc = live.lastIpcObject || ({});
        const mode = want.mode
            || ((ipc.width || live.width) + "x" + (ipc.height || live.height)
                + "@" + (Math.round((ipc.refreshRate || 60) * 1000) / 1000));
        if (!root.onBattery || !(want.batteryRate > 0)) return mode;
        const res = mode.split("@")[0];
        return res + "@" + root.nearestRate(ipc, res, want.batteryRate);
    }

    function setBatteryRate(name, hz) {
        saveDisplay(name, { batteryRate: hz > 0 ? hz : undefined });
        root.contested = Object.assign({}, root.contested, { [name]: undefined });
        applyDisplay(name);
        Services.Compositor.refreshMonitors();
    }

    // ── keeping it there ──────────────────────────────────────────────────
    //
    // Hyprland puts an output back on hyprland.lua's rule whenever it sets
    // it up again — a panel re-initialised as the power source changes, a
    // monitor re-plugged — and the rule shipped is "preferred", which on
    // many laptop panels is 60 Hz. Something else may set it outright, too:
    // asusd runs its bat_command on unplugging. Either way the rate chosen
    // in Settings was gone until the next login.
    //
    // So a saved rate is checked after anything that could have moved it —
    // the power source changing, an output coming or going, and every half
    // minute besides, since a mode set from outside raises no event — and
    // put back when it is off. Three fixes inside a minute means something
    // is setting it on purpose; the shell stops there rather than fight it,
    // and Settings says so. Changing the power source or the rate again
    // starts over.
    property var fixes: ({})      // output → [times it was put back]
    property var contested: ({})  // output → the rate something else keeps setting

    function enforce() {
        if (!root.applied) return;
        // Still changing, or the report may predate the change: look again
        // once it has settled.
        if (Date.now() - root.lastSend < 2500 || secondStep.running) { root.checkSoon(); return; }
        if (Date.now() - root.reportedAt > 1200) { root.checkSoon(); return; }
        const map = displayMap();
        const now = Date.now();
        for (const live of Services.Compositor.monitors || []) {
            if (!live || !map[live.name] || !(map[live.name].mode || map[live.name].batteryRate)) continue;
            const ipc = live.lastIpcObject || ({});
            if (!ipc.refreshRate) continue;
            const want = parseFloat(root.modeFor(live.name, map[live.name], live).split("@")[1]);
            if (!(want > 0) || Math.abs(ipc.refreshRate - want) < 0.5) continue;
            if (root.contested[live.name] !== undefined) continue;
            const recent = (root.fixes[live.name] || []).filter(t => now - t < 60000);
            if (recent.length >= 3) {
                console.warn("Devices:", live.name, "keeps going to", ipc.refreshRate,
                             "Hz instead of", want, "— something else sets it, or the driver",
                             "refuses it (Hyprland's log says which); leaving it");
                root.contested = Object.assign({}, root.contested,
                                               { [live.name]: Math.round(ipc.refreshRate) });
                continue;
            }
            recent.push(now);
            root.fixes = Object.assign({}, root.fixes, { [live.name]: recent });
            console.log("Devices:", live.name, "was at", ipc.refreshRate, "Hz; putting back", want);
            root.fixDisplay(live.name, ipc.refreshRate);
        }
    }

    // A check a moment after each nudge, once Hyprland's report is fresh.
    Timer {
        id: recheck
        interval: 1500
        onTriggered: root.enforce()
    }
    // When Hyprland's report was last asked for; enforce() only trusts one
    // asked for just before it runs.
    property real reportedAt: 0
    function checkSoon() {
        Services.Compositor.refreshMonitors();
        root.reportedAt = Date.now() + recheck.interval - 1000;
        recheck.restart();
    }

    // The power source changing is when the rate matters: apply the one for
    // it, and look again over the next few seconds for whatever else reacts
    // to the same unplugging.
    //
    // It has to hold for a couple of seconds first: a charger at its charge
    // limit, or a loose plug, can report AC and battery by turns, and each
    // turn would otherwise change the rate.
    onOnBatteryChanged: {
        console.log("Devices: power source is now", root.onBattery ? "battery" : "AC");
        powerSettle.restart();
    }
    property bool actedOnBattery: false
    Timer {
        id: powerSettle
        interval: 2500
        onTriggered: {
            if (!root.applied || root.onBattery === root.actedOnBattery) return;
            root.actedOnBattery = root.onBattery;
            root.fixes = ({});
            root.contested = ({});
            root.applyDisplays();
            powerFollowUp.left = 3;
            powerFollowUp.restart();
            root.checkSoon();
        }
    }
    Timer {
        id: powerFollowUp
        property int left: 0
        interval: 3000
        repeat: true
        onTriggered: {
            root.checkSoon();
            if (--left <= 0) stop();
        }
    }

    Timer {
        interval: 30000
        repeat: true
        running: root.applied && prefs.displays !== ""
        onTriggered: root.checkSoon()
    }

    Connections {
        target: Services.Compositor
        function onOutputsChanged() { root.checkSoon(); }
    }

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
        spec.mode = root.modeFor(name, want, live);
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

    // Hyprland keeps the rule it was last asked for, not the mode it ended
    // up on, and skips a rule identical to that one. So once an output has
    // fallen to another rate — the driver refusing the asked-for mode, which
    // makes Hyprland drop to the panel's preferred one; a reset it did not
    // record — asking for the saved rate again changes nothing, however
    // often it is asked: it still has that rule. When the output is not at
    // the rate wanted, the rule for what it is actually running goes first,
    // and the wanted one a moment later, which Hyprland then really applies.
    property var pendingSpecs: ({})
    Timer {
        id: secondStep
        interval: 400
        onTriggered: {
            const p = root.pendingSpecs;
            root.pendingSpecs = ({});
            root.lastSend = Date.now();
            for (const n in p) Services.Compositor.setMonitor(p[n]);
            Services.Compositor.refreshMonitors();
        }
    }

    // When the last rule went out: Hyprland's report of an output is not to
    // be believed for a moment after, while it is still changing it.
    property real lastSend: 0

    function applyDisplay(name) {
        const spec = displaySpec(name);
        if (!spec) return;
        root.lastSend = Date.now();
        Services.Compositor.setMonitor(spec);
    }

    // The two-step, for an output known — from a fresh report — to be off
    // the rate it should be at. Only enforce() calls it: the first step
    // sets the output to what it was last reported running, so from a
    // stale report it would change a display that was already right. That
    // is what a reload did, straight after which the report still said
    // what the output ran before it.
    function fixDisplay(name, runningHz) {
        const spec = displaySpec(name);
        const live = (Services.Compositor.monitors || []).find(m => m && m.name === name);
        if (!spec || !live) return;
        const ipc = live.lastIpcObject || ({});
        root.lastSend = Date.now();
        Services.Compositor.setMonitor(Object.assign({}, spec, {
            mode: (ipc.width || live.width) + "x" + (ipc.height || live.height)
                  + "@" + (Math.round(runningHz * 1000) / 1000) }));
        root.pendingSpecs = Object.assign({}, root.pendingSpecs, { [name]: spec });
        secondStep.restart();
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
            root.checkSoon();
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
            root.actedOnBattery = root.onBattery;
            root.applyInput();
            root.applyFrame();
            root.applyDisplays();
            root.checkSoon();
            running = false;
        }
    }
}
