pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Sound effects the shell runs itself, for Settings → Sound:
//
//   equalizer           ten bands and a preamp over everything played. A
//                       PipeWire filter-chain, run as its own `pipewire -c`
//                       process: a virtual output that becomes the default
//                       and passes the sound on to the real device.
//   noise suppression   RNNoise over the microphone, the same way round: a
//                       virtual input, fed from the real one, that becomes
//                       the default. Needs the RNNoise LADSPA plugin
//                       (noise-suppression-for-voice).
//   listen              the microphone played back through the output, to
//                       hear yourself — pipewire-pulse's loopback module.
//
// Each runs only while this shell does: quit it and the device goes, and
// WirePlumber moves everything back onto a real one. Nothing is written
// into PipeWire's own configuration.
//
// The gains move live (`pw-cli set-param`); the configuration file is only
// what the process starts from next time.
Singleton {
    id: root

    readonly property var au: Services.Audio
    readonly property var prefs: Config.Appearance
    readonly property string dir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/hyprshell"

    // ── what this machine has ────────────────────────────────────────────
    property bool probed: false
    property bool hasPipewire: false
    property bool hasPwCli: false
    property string rnnoisePlugin: ""
    readonly property bool eqAvailable: hasPipewire
    readonly property bool nsAvailable: hasPipewire && rnnoisePlugin !== ""

    Process {
        id: probe
        running: true
        command: ["sh", "-c",
            'command -v pipewire >/dev/null 2>&1 && echo PIPEWIRE; '
          + 'command -v pw-cli >/dev/null 2>&1 && echo PWCLI; '
          + 'for d in $(printf "%s" "$LADSPA_PATH" | tr ":" " ") /usr/lib/ladspa /usr/lib64/ladspa /usr/local/lib/ladspa "$HOME/.ladspa"; do '
          + '  [ -r "$d/librnnoise_ladspa.so" ] && { echo "RNNOISE $d/librnnoise_ladspa.so"; break; }; '
          + 'done; '
          // Listening left on by a shell that has since gone.
          + 'command -v pactl >/dev/null 2>&1 && pactl -f json list modules 2>/dev/null | tr "}" "\\n" '
          + '  | grep "hyprshell-listen" | grep -o "\\"index\\":[0-9]*" | cut -d: -f2 '
          + '  | while read -r i; do pactl unload-module "$i"; done; true']
        stdout: StdioCollector {
            onStreamFinished: {
                root.hasPipewire = /^PIPEWIRE$/m.test(text);
                root.hasPwCli = /^PWCLI$/m.test(text);
                const m = /^RNNOISE (.+)$/m.exec(text);
                root.rnnoisePlugin = m ? m[1].trim() : "";
                root.probed = true;
            }
        }
    }
    function reprobe() { probe.running = false; probe.running = true; }

    // ══ equalizer ════════════════════════════════════════════════════════
    readonly property var bands: [31, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    readonly property var gains: {
        const g = String(prefs.eqGains || "").split(",").map(v => parseFloat(v) || 0);
        while (g.length < 10) g.push(0);
        return g.slice(0, 10).map(v => Math.max(-12, Math.min(12, v)));
    }
    readonly property var presets: [
        { name: "Flat",          gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] },
        { name: "Bass boost",    gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0] },
        { name: "Bass cut",      gains: [-6, -5, -3, -1, 0, 0, 0, 0, 0, 0] },
        { name: "Treble boost",  gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6] },
        { name: "Vocal",         gains: [-3, -2, -1, 1, 3, 4, 3, 1, 0, -1] },
        { name: "Loudness",      gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5] },
        { name: "Laptop speakers", gains: [-4, -3, -1, 1, 2, 2, 2, 3, 3, 2] },
        { name: "Headphones",    gains: [2, 2, 1, 0, -1, 0, 1, 2, 2, 1] },
        { name: "Podcast",       gains: [-6, -4, -2, 0, 2, 3, 3, 2, 0, -2] }
    ]

    property string eqStatus: "off"     // off | starting | on | error
    property string eqError: ""
    property bool eqStopping: false
    property int eqEpoch: 0
    readonly property bool eqWanted: prefs.eqEnabled && eqAvailable && au.pipewireUp

    function bandLabel(f) { return f >= 1000 ? (f / 1000) + "k" : String(f); }
    function num(v) { return Number(v).toFixed(2); }

    function eqConf() {
        const nodes = ['{ type = builtin name = preamp label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = '
                       + num(prefs.eqPreamp) + ' } }'];
        const links = [];
        let prev = "preamp";
        for (let i = 0; i < 10; i++) {
            const label = i === 0 ? "bq_lowshelf" : i === 9 ? "bq_highshelf" : "bq_peaking";
            const q = i === 0 || i === 9 ? 0.7 : 1.0;
            const name = "eq_band_" + (i + 1);
            nodes.push('{ type = builtin name = ' + name + ' label = ' + label + ' control = { "Freq" = '
                       + num(bands[i]) + ' "Q" = ' + num(q) + ' "Gain" = ' + num(gains[i]) + ' } }');
            links.push('{ output = "' + prev + ':Out" input = "' + name + ':In" }');
            prev = name;
        }
        const target = prefs.eqTarget !== "" ? '\n                target.object = "' + prefs.eqTarget.replace(/"/g, "") + '"' : "";
        return 'context.properties = { log.level = 0 }\n'
            + 'context.spa-libs = {\n    audio.convert.* = audioconvert/libspa-audioconvert\n    support.* = support/libspa-support\n}\n'
            + 'context.modules = [\n'
            + '    { name = libpipewire-module-rt args = { nice.level = -11 } flags = [ ifexists nofail ] }\n'
            + '    { name = libpipewire-module-protocol-native }\n'
            + '    { name = libpipewire-module-client-node }\n'
            + '    { name = libpipewire-module-adapter }\n'
            + '    { name = libpipewire-module-filter-chain\n'
            + '        args = {\n'
            + '            node.description = "Equalizer"\n'
            + '            media.name = "Equalizer"\n'
            + '            filter.graph = {\n'
            + '                nodes = [\n                    ' + nodes.join("\n                    ") + '\n                ]\n'
            + '                links = [\n                    ' + links.join("\n                    ") + '\n                ]\n'
            + '            }\n'
            + '            audio.channels = 2\n'
            + '            audio.position = [ FL FR ]\n'
            + '            capture.props = {\n'
            + '                node.name = "' + au.eqSinkName + '"\n'
            + '                node.description = "Equalizer"\n'
            + '                media.class = Audio/Sink\n'
            + '            }\n'
            + '            playback.props = {\n'
            + '                node.name = "' + au.eqOutName + '"\n'
            + '                node.passive = true\n'
            + '                application.name = "hyprshell-eq"' + target + '\n'
            + '            }\n'
            + '        }\n'
            + '    }\n'
            + ']\n';
    }

    // Writes the configuration and becomes the filter: one process, whose
    // life is the equalizer's.
    Process {
        id: eqProc
        running: root.eqWanted && root.eqEpoch >= 0
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1" && exec pipewire -c "$1"',
                  "sh", root.dir + "/equalizer.conf", root.eqConf()]
        stderr: StdioCollector { id: eqErr }
        onStarted: { root.eqStatus = "starting"; root.eqError = ""; eqWatchdog.restart(); }
        onExited: code => {
            if (root.prefs.eqEnabled && !root.eqStopping) {
                root.eqStatus = "error";
                root.eqError = eqErr.text.split("\n").filter(l => l.trim() !== "").pop() || ("pipewire exited " + code);
            } else root.eqStatus = "off";
            root.eqStopping = false;
        }
    }
    // Running but no device after a while: PipeWire accepted the process
    // and then made nothing of it — usually a module missing from this
    // PipeWire build. Said, rather than left at "Starting…" for ever.
    Timer {
        id: eqWatchdog
        interval: 8000
        onTriggered: if (root.eqStatus === "starting" && !root.au.eqSink) {
            root.eqStatus = "error";
            root.eqError = "PipeWire started the equalizer but no device appeared. "
                         + (eqErr.text.split("\n").filter(l => l.trim() !== "").pop() || "Nothing was logged.");
        }
    }
    // The configuration is only read at start, so the command changing
    // under a running process (a new gain, a new target) must not restart
    // it — `command` is ignored until the next start anyway.

    // The device appears a moment after the process starts: make it the
    // default then. And on switching off, put the real device back first,
    // so nothing is left playing into a device about to vanish.
    Connections {
        target: root.au
        function onEqSinkChanged() { root.syncEq(); }
    }
    onEqWantedChanged: {
        if (!eqWanted) {
            const real = au.sinks.find(n => n.name === prefs.eqTarget) || au.sinks[0];
            if (au.eqActive && real) au.setRawDefaultSink(real);
            eqStopping = true;
        } else {
            // Remember the device it is going in front of.
            if (!au.eqActive && au.rawSink && !au.isOurs(au.rawSink)) prefs.eqTarget = au.rawSink.name;
        }
    }
    function syncEq() {
        if (!au.eqSink) return;
        if (eqWanted && !au.eqActive) {
            if (prefs.eqTarget === "" && au.rawSink && !au.isOurs(au.rawSink)) prefs.eqTarget = au.rawSink.name;
            au.setRawDefaultSink(au.eqSink);
            eqStatus = "on";
            pushGains();
        }
    }
    function setEnabled(on) { prefs.eqEnabled = on; if (on && eqStatus === "error") retryEq(); }
    function retryEq() { eqError = ""; eqEpoch++; }

    function setGain(i, db) {
        const g = gains.slice();
        g[i] = Math.round(Math.max(-12, Math.min(12, db)) * 2) / 2;
        prefs.eqGains = g.join(",");
        prefs.eqPreset = "Custom";
        pushGains();
    }
    function setPreamp(db) {
        prefs.eqPreamp = Math.round(Math.max(-12, Math.min(12, db)) * 2) / 2;
        pushGains();
    }
    function applyPreset(p) {
        prefs.eqGains = p.gains.join(",");
        prefs.eqPreset = p.name;
        // Boosting anything risks clipping; the preamp makes the room.
        const top = Math.max.apply(null, p.gains);
        prefs.eqPreamp = top > 0 ? -Math.ceil(top / 2) : 0;
        pushGains();
    }

    // Live: every band's gain to the running filter, at most every 60 ms
    // while a slider is dragged.
    Timer { id: pushSoon; interval: 60; onTriggered: root.sendGains() }
    function pushGains() { if (au.eqSink) pushSoon.restart(); }
    Process { id: paramProc }
    function sendGains() {
        if (!au.eqSink || !hasPwCli) return;
        const parts = ['"preamp:Gain" ' + num(prefs.eqPreamp)];
        for (let i = 0; i < 10; i++) parts.push('"eq_band_' + (i + 1) + ':Gain" ' + num(gains[i]));
        const props = '{ params = [ ' + parts.join(" ") + ' ] }';
        paramProc.running = false;
        paramProc.command = ["pw-cli", "set-param", String(au.eqSink.id), "Props", props];
        paramProc.running = true;
    }

    // ══ noise suppression ════════════════════════════════════════════════
    property string nsStatus: "off"
    property string nsError: ""
    property bool nsStopping: false
    property int nsEpoch: 0
    readonly property bool nsWanted: prefs.nsEnabled && nsAvailable && au.pipewireUp

    function nsConf() {
        const target = prefs.nsTarget !== "" ? '\n                target.object = "' + prefs.nsTarget.replace(/"/g, "") + '"' : "";
        return 'context.properties = { log.level = 0 }\n'
            + 'context.spa-libs = {\n    audio.convert.* = audioconvert/libspa-audioconvert\n    support.* = support/libspa-support\n}\n'
            + 'context.modules = [\n'
            + '    { name = libpipewire-module-rt args = { nice.level = -11 } flags = [ ifexists nofail ] }\n'
            + '    { name = libpipewire-module-protocol-native }\n'
            + '    { name = libpipewire-module-client-node }\n'
            + '    { name = libpipewire-module-adapter }\n'
            + '    { name = libpipewire-module-filter-chain\n'
            + '        args = {\n'
            + '            node.description = "Noise suppression"\n'
            + '            media.name = "Noise suppression"\n'
            + '            filter.graph = {\n'
            + '                nodes = [\n'
            + '                    { type = ladspa name = rnnoise plugin = "' + rnnoisePlugin + '" label = noise_suppressor_mono\n'
            + '                      control = { "VAD Threshold (%)" = ' + num(prefs.nsThreshold)
            + ' "VAD Grace Period (ms)" = 200.0 "Retroactive VAD Grace (ms)" = 0.0 } }\n'
            + '                ]\n'
            + '            }\n'
            + '            audio.rate = 48000\n'
            + '            audio.position = [ MONO ]\n'
            + '            capture.props = {\n'
            + '                node.name = "' + au.nsInName + '"\n'
            + '                node.passive = true\n'
            + '                application.name = "hyprshell-ns"' + target + '\n'
            + '            }\n'
            + '            playback.props = {\n'
            + '                node.name = "' + au.nsSourceName + '"\n'
            + '                node.description = "Microphone (noise suppressed)"\n'
            + '                media.class = Audio/Source\n'
            + '            }\n'
            + '        }\n'
            + '    }\n'
            + ']\n';
    }

    Process {
        id: nsProc
        running: root.nsWanted && root.nsEpoch >= 0
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1" && exec pipewire -c "$1"',
                  "sh", root.dir + "/noise-suppression.conf", root.nsConf()]
        stderr: StdioCollector { id: nsErr }
        onStarted: { root.nsStatus = "starting"; root.nsError = ""; nsWatchdog.restart(); }
        onExited: code => {
            if (root.prefs.nsEnabled && !root.nsStopping) {
                root.nsStatus = "error";
                root.nsError = nsErr.text.split("\n").filter(l => l.trim() !== "").pop() || ("pipewire exited " + code);
            } else root.nsStatus = "off";
            root.nsStopping = false;
        }
    }
    Connections {
        target: root.au
        function onNsSourceChanged() { root.syncNs(); }
    }
    onNsWantedChanged: {
        if (!nsWanted) {
            const real = au.sources.find(n => n.name === prefs.nsTarget) || au.sources[0];
            if (au.nsActive && real) au.setRawDefaultSource(real);
            nsStopping = true;
        } else if (!au.nsActive && au.rawSource && !au.isOurs(au.rawSource)) {
            prefs.nsTarget = au.rawSource.name;
        }
    }
    function syncNs() {
        if (!au.nsSource) return;
        if (nsWanted && !au.nsActive) {
            if (prefs.nsTarget === "" && au.rawSource && !au.isOurs(au.rawSource)) prefs.nsTarget = au.rawSource.name;
            au.setRawDefaultSource(au.nsSource);
            nsStatus = "on";
        }
    }
    Timer {
        id: nsWatchdog
        interval: 8000
        onTriggered: if (root.nsStatus === "starting" && !root.au.nsSource) {
            root.nsStatus = "error";
            root.nsError = "PipeWire started noise suppression but no microphone appeared — is the RNNoise plugin the "
                         + "LADSPA one? " + (nsErr.text.split("\n").filter(l => l.trim() !== "").pop() || "");
        }
    }
    function setNsEnabled(on) { prefs.nsEnabled = on; if (on && nsStatus === "error") retryNs(); }
    function retryNs() { nsError = ""; nsEpoch++; }
    Timer { id: nsPushSoon; interval: 80; onTriggered: root.sendNs() }
    Process { id: nsParamProc }
    function setNsThreshold(v) {
        prefs.nsThreshold = Math.round(Math.max(0, Math.min(99, v)));
        if (au.nsSource) nsPushSoon.restart();
    }
    function sendNs() {
        if (!au.nsSource || !hasPwCli) return;
        nsParamProc.running = false;
        nsParamProc.command = ["pw-cli", "set-param", String(au.nsSource.id), "Props",
                               '{ params = [ "rnnoise:VAD Threshold (%)" ' + num(prefs.nsThreshold) + ' ] }'];
        nsParamProc.running = true;
    }

    // ══ listen to a microphone ═══════════════════════════════════════════
    // Off whenever the shell starts: hearing yourself is not a thing to
    // come back to unannounced.
    property int listenModule: -1
    property string listenSource: ""
    readonly property bool listening: listenModule >= 0
    Process {
        id: listenOn
        stdout: StdioCollector {
            onStreamFinished: {
                const n = parseInt(text.trim());
                root.listenModule = isNaN(n) ? -1 : n;
                if (isNaN(n)) root.listenSource = "";
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") root.au.lastError = text.trim().split("\n").pop()
        }
    }
    Process { id: listenOff }
    function listen(on, sourceNode) {
        if (listenModule >= 0) {
            listenOff.command = ["pactl", "unload-module", String(listenModule)];
            listenOff.running = true;
            listenModule = -1;
            listenSource = "";
        }
        if (!on || !sourceNode) return;
        listenSource = sourceNode.name;
        listenOn.command = ["pactl", "load-module", "module-loopback",
                            "source=" + sourceNode.name, "latency_msec=40", "source_dont_move=true",
                            "sink_input_properties=application.name=hyprshell-listen",
                            "source_output_properties=application.name=hyprshell-listen"];
        listenOn.running = true;
    }
    Component.onDestruction: {
        if (listenModule >= 0) Quickshell.execDetached(["pactl", "unload-module", String(listenModule)]);
    }
}
