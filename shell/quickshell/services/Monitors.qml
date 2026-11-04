pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config
import "." as Services

// External monitors' brightness, each its own slider in the control
// center (the laptop's panel stays Services.Brightness).
//
// The daemon sets a monitor's own backlight over DDC/CI, the way its
// on-screen menu does. A monitor that does not answer — some don't, and
// many docks and hubs do not pass DDC through — is dimmed in software
// instead, through the gamma ramp: the backlight stays as it is, but the
// picture gets darker, which is what dimming is for at night. Those levels
// are kept here (DDC monitors remember their own) and put back when the
// shell starts.
//
// Below a DDC monitor's own 0% there is more: the bottom fifth of its
// slider is "extra dim", the backlight at 0 and the picture dimmed in
// software on top, down to a tenth. That level is kept here too.
Singleton {
    id: root

    // [{ output, name, method: "ddc" | "software", value: 0..1 }]
    property var displays: []
    // "setup" when DDC/CI could not be tried at all (no i2c-dev, or no
    // access to it): Settings says how to fix it.
    property string reason: ""
    readonly property bool available: displays.length > 0

    readonly property bool live: Services.Daemon.running && !!Services.Daemon.modules.ddc

    function dims() {
        try { return JSON.parse(Config.Appearance.monitorDims) || {}; } catch (e) { return {}; }
    }

    function display(output) { return root.displays.find(d => d.output === output) || null; }

    // A DDC monitor's slider: the bottom `split` is extra dim, the rest
    // its backlight, 0 to 100.
    readonly property real split: 0.2
    readonly property real floorDim: 0.1
    function ddcSlider(backlight, dim) {
        if (dim !== undefined && dim < 0.999)
            return root.split * Math.max(0, (dim - root.floorDim) / (1 - root.floorDim));
        return root.split + (1 - root.split) * Math.max(0, Math.min(100, backlight)) / 100;
    }

    // Writes go out at most every 40 ms while a slider is dragged; the
    // daemon sends a monitor only the newest of them.
    property var pending: ({})
    Timer {
        id: flush
        interval: 40
        onTriggered: {
            const p = root.pending;
            root.pending = {};
            for (const o in p) root.apply(o, p[o]);
        }
    }

    function set(output, v) {
        const d0 = root.display(output);
        v = Math.max(d0 && d0.method === "ddc" ? 0 : 0.05, Math.min(1, v));
        const d = root.display(output);
        if (!d) return;
        // Shown at once, sent shortly.
        root.displays = root.displays.map(x => x.output === output ? Object.assign({}, x, { value: v }) : x);
        const p = Object.assign({}, root.pending);
        p[output] = v;
        root.pending = p;
        if (!flush.running) flush.start();
    }

    function apply(output, v) {
        const d = root.display(output);
        if (!d) return;
        if (d.method === "ddc") {
            const all = root.dims();
            if (v >= root.split) {
                Services.Daemon.send({ cmd: "ddc-set", output: output,
                                       value: Math.round((v - root.split) / (1 - root.split) * 100) });
                // Out of extra dim: the picture back to full.
                if (all[output] !== undefined) {
                    Services.Daemon.send({ cmd: "gamma-dim", output: output, value: 100 });
                    delete all[output];
                    Config.Appearance.monitorDims = JSON.stringify(all);
                }
            } else {
                const dim = root.floorDim + (v / root.split) * (1 - root.floorDim);
                if (all[output] === undefined) Services.Daemon.send({ cmd: "ddc-set", output: output, value: 0 });
                Services.Daemon.send({ cmd: "gamma-dim", output: output, value: Math.round(dim * 100) });
                all[output] = Math.round(dim * 100) / 100;
                Config.Appearance.monitorDims = JSON.stringify(all);
            }
        } else {
            Services.Daemon.send({ cmd: "gamma-dim", output: output, value: Math.round(v * 100) });
            const all = root.dims();
            if (v >= 0.999) delete all[output]; else all[output] = Math.round(v * 100) / 100;
            Config.Appearance.monitorDims = JSON.stringify(all);
        }
    }

    function refresh() { if (root.live) Services.Daemon.send({ cmd: "ddc-refresh" }); }

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev !== "ddc") return;
            const saved = root.dims();
            const before = root.displays;
            root.reason = ev.reason || "";
            root.displays = (ev.displays || []).map(d => {
                const soft = d.method !== "ddc";
                // While a drag is being sent, keep the slider where it is.
                const mid = root.pending[d.output];
                return {
                    output: d.output,
                    name: d.name || d.output,
                    method: soft ? "software" : "ddc",
                    value: mid !== undefined ? mid
                         : soft ? (saved[d.output] !== undefined ? saved[d.output] : 1)
                         : root.ddcSlider(d.value || 0, saved[d.output]),
                };
            });
            // A monitor dimmed in software that has just appeared (or the
            // shell just started) gets its level back.
            for (const d of root.displays) {
                if (saved[d.output] !== undefined
                    && !before.some(b => b.output === d.output && b.method === d.method))
                    Services.Daemon.send({ cmd: "gamma-dim", output: d.output, value: Math.round(saved[d.output] * 100) });
            }
        }
    }

    onLiveChanged: if (live) refresh()

    // Plugging a monitor in or out: look again once things settle.
    readonly property int screenCount: Quickshell.screens.length
    onScreenCountChanged: rescan.restart()
    Timer { id: rescan; interval: 2500; onTriggered: root.refresh() }
}
