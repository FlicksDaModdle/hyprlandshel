pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Backlight via brightnessctl. Machines without a backlight (desktops) just
// report unavailable, and every consumer — the control center's brightness
// slider, the OSD, Settings → Display — hides itself rather than showing a
// dead control.
//
// brightnessctl's machine-readable format is:
//     <device>,<class>,<current>,<percent>%,<max>
Singleton {
    id: root

    property int current: 0
    property int maximum: 0
    property string device: ""
    readonly property bool available: maximum > 0
    readonly property real value: available ? current / maximum : 0
    readonly property int percent: Math.round(value * 100)

    // Writes are debounced: dragging the slider would otherwise spawn a
    // brightnessctl process per pixel of travel.
    property real pendingValue: -1

    // ── hyprshell-daemon ──────────────────────────────────────────────────
    // When it is running it reads the backlight from sysfs itself, hears the
    // kernel announce changes, and sets it through logind — so none of the
    // brightnessctl reading and writing below runs.
    readonly property bool viaDaemon: Services.Daemon.backlightLive
    onViaDaemonChanged: if (viaDaemon) Services.Daemon.send({ cmd: "bl-watch", on: shown })
    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "backlight" && ev.available === true) {
                // While a drag is being sent, the daemon's echo of an older
                // value would pull the slider back under the pointer.
                if (root.pendingValue >= 0 || daemonFlush.running) return;
                root.device = ev.device || "";
                root.maximum = ev.max || 0;
                root.current = ev.value || 0;
            } else if (ev.ev === "backlight-error") {
                root.lastError = ev.message || "";
            }
        }
    }
    Timer {
        id: daemonFlush
        interval: 30
        onTriggered: {
            if (root.pendingValue < 0) return;
            Services.Daemon.send({ cmd: "bl-set", value: Math.max(1, Math.round(root.pendingValue * root.maximum)) });
            root.pendingValue = -1;
        }
    }

    Process {
        id: query
        // Runs immediately so `available` is known before anything reads it;
        // Component.onCompleted does not attach to a Singleton.
        running: true
        command: ["brightnessctl", "-m"]
        stdout: StdioCollector {
            onStreamFinished: {
                const line = text.trim().split("\n")[0] || "";
                const parts = line.split(",");
                if (parts.length < 5) return;
                root.device = parts[0];
                root.current = parseInt(parts[2]) || 0;
                root.maximum = parseInt(parts[4]) || 0;
            }
        }
    }

    // Why a write failed matters here: brightnessctl needs either its
    // setuid helper, a udev rule, or you in the `video` group, and without
    // one of those every write fails with a permission error that used to go
    // straight to /dev/null — the slider moved and the screen didn't.
    property string lastError: ""

    Process {
        id: setter
        stderr: StdioCollector {
            onStreamFinished: {
                const msg = text.trim();
                if (msg) {
                    root.lastError = msg.split("\n")[0];
                    console.warn("Brightness: brightnessctl:", root.lastError);
                }
            }
        }
        onExited: {
            // Re-send anything that arrived while this one was running.
            if (root.pendingValue >= 0) flush.restart();
        }
    }

    Timer {
        id: flush
        interval: 40
        onTriggered: {
            if (root.pendingValue < 0) return;
            const pct = Math.round(root.pendingValue * 100);
            root.pendingValue = -1;
            // -n1 keeps a minimum of 1% so the screen never goes fully black.
            //
            // Assigning running while the process is still up is a no-op, so
            // a write landing mid-flight used to be dropped silently. The
            // last value asked for is kept and re-sent when it exits.
            if (setter.running) { root.pendingValue = clampedPending(pct); return; }
            setter.command = ["brightnessctl", "-m", "-n1", "set", pct + "%"];
            setter.running = true;
            refresh.restart();
        }
    }

    // Re-read after any change so external tools (hotkeys bound straight to
    // brightnessctl, power management) stay reflected in the UI.
    Timer {
        id: refresh
        interval: 120
        onTriggered: query.running = true
    }

    // Something else changing the backlight (hypridle dimming, a key bound
    // straight to brightnessctl) is only worth catching quickly while a
    // slider is on screen; otherwise once a minute, and once more the
    // moment one appears.
    readonly property bool shown: Config.UiState.controlCenterOpen || Config.UiState.settingsOpen
    onShownChanged: {
        if (viaDaemon) Services.Daemon.send({ cmd: "bl-watch", on: shown });
        else if (shown && available) query.running = true;
    }
    Timer {
        interval: root.shown ? 10000 : 60000
        running: root.available && !root.viaDaemon
        repeat: true
        onTriggered: query.running = true
    }

    function clampedPending(pct) { return Math.max(0.01, Math.min(1, pct / 100)); }

    // ── extra dim ─────────────────────────────────────────────────────────
    // Below the backlight's own lowest: the bottom fifth of the slider
    // keeps the backlight at 1% and dims the picture on top, through the
    // daemon's gamma ramp (as Monitors.qml does for external monitors),
    // down to a tenth. Kept with the monitors' levels, by the panel's name.
    readonly property string panel: {
        const m = (Services.Compositor.monitors || []).find(o => o && /^(eDP|LVDS|DSI)/.test(String(o.name)));
        return m ? m.name : "";
    }
    readonly property bool canExtraDim: panel !== "" && Services.Daemon.running && Services.Daemon.modules.gamma === true
    readonly property real split: canExtraDim ? 0.2 : 0
    readonly property real floorDim: 0.1
    function savedDim() {
        try { const d = JSON.parse(Config.Appearance.monitorDims || "{}")[root.panel]; return d === undefined ? 1 : d; }
        catch (e) { return 1; }
    }
    property real extraDim: 1
    // Where the slider stands: the extra-dim range, then the backlight.
    readonly property real slider: extraDim < 0.999
        ? split * Math.max(0, (extraDim - floorDim) / (1 - floorDim))
        : split + (1 - split) * value
    readonly property string sliderLabel: extraDim < 0.999 ? "extra dim" : percent + "%"
    function setSlider(v) {
        if (!available) return;
        v = Math.max(0, Math.min(1, v));
        if (!canExtraDim || v >= split) {
            set(split > 0 ? (v - split) / (1 - split) : v);
            return;
        }
        const dim = floorDim + (v / split) * (1 - floorDim);
        if (root.extraDim >= 0.999) set(0.01);
        root.applyDim(dim);
    }
    function applyDim(dim) {
        root.extraDim = dim;
        Services.Daemon.send({ cmd: "gamma-dim", output: root.panel, value: Math.round(dim * 100) });
        let all = {};
        try { all = JSON.parse(Config.Appearance.monitorDims || "{}") || {}; } catch (e) { }
        if (dim >= 0.999) delete all[root.panel]; else all[root.panel] = Math.round(dim * 100) / 100;
        Config.Appearance.monitorDims = JSON.stringify(all);
    }
    // Back at login, once the daemon can do it.
    onCanExtraDimChanged: if (canExtraDim) { const d = savedDim(); if (d < 0.999) applyDim(d); }

    function set(v) {
        if (!available) return;
        // Any backlight change (a key, the slider above the extra-dim
        // range) ends extra dim.
        if (root.extraDim < 0.999) root.applyDim(1);
        const clamped = Math.max(0.01, Math.min(1, v));
        // Update optimistically so the slider tracks the pointer.
        current = Math.round(clamped * maximum);
        pendingValue = clamped;
        if (viaDaemon) daemonFlush.restart();
        else flush.restart();
    }

    function step(delta) {
        if (!available) return;
        // Resolve the target before set(), which moves `value` underneath us.
        const target = Math.max(0.01, Math.min(1, value + delta));
        set(target);
        Config.UiState.showOsd("brightness", target, false);
    }
}
