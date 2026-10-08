pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services
import "EqMath.js" as EqM
import "../modules/common"

// Sound effects the shell runs itself, for Settings → Sound:
//
//   equalizer           parametric: up to sixteen bands — bells, shelves,
//                       cuts from 12 to 48 dB/octave, notches, band
//                       passes — and a preamp over everything played. A
//                       PipeWire filter-chain: a virtual output that
//                       becomes the default and passes the sound on to the
//                       real device. Loaded into hyprshell-daemon when it
//                       is running, or else run as a `pipewire -c` process
//                       of its own.
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

    // Where the filter-chains run: inside hyprshell-daemon when it has the
    // part (one PipeWire client in a process already running), else each
    // as a `pipewire -c` process. Neither while the daemon is starting, so
    // the two never both make the same device.
    readonly property bool fxDaemon: Services.Daemon.running && Services.Daemon.modules.fx === true
    readonly property bool fxProcess: Services.Daemon.missing
        || (Services.Daemon.running && Services.Daemon.modules.fx !== true)

    // ── what this machine has ────────────────────────────────────────────
    property bool probed: false
    property bool hasPipewire: false
    property bool hasPwCli: false
    property string rnnoisePlugin: ""
    readonly property bool eqAvailable: hasPipewire || fxDaemon
    readonly property bool nsAvailable: (hasPipewire || fxDaemon) && rnnoisePlugin !== ""

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
    // The bands, as Settings keeps them (EqMath.js has the shape). Each
    // is one or more of PipeWire's builtin biquads, named b<id>_<n>, so a
    // band keeps its nodes however the others move.
    readonly property var bands: EqM.parse(prefs.peqBands)
    // In the chain: every band that is on, and the gain types even while
    // off (at 0 dB) — switching one of those is then a change of gain,
    // heard at once, rather than a new chain. Cuts, notches and band
    // passes cannot be made neutral, so switching them rebuilds it.
    readonly property var chainBands: bands.filter(b => b.on || EqM.hasGain(b.type))
    // What the chain is built from; anything else about a band moves live.
    readonly property string structure: chainBands.map(b => b.id + ":" + b.type
                                         + (EqM.isCut(b.type) ? "/" + b.slope : "")).join(",")

    // The ten-band equalizer this replaced kept its gains in eqGains;
    // those become bands the first time this runs.
    Connections {
        target: root.prefs
        function onSettingsReadyChanged() { root.migrate(); }
    }
    Component.onCompleted: migrate()
    // The old gains are zeroed once carried over, so this happens once —
    // and still happens if the settings were late to load and the bands
    // were started empty before they arrived.
    Connections {
        target: root.prefs
        function onEqGainsChanged() { root.migrate(); }
    }
    function migrate() {
        if (!prefs.settingsReady) return;
        const old = EqM.fromGraphic(prefs.eqGains);
        if (prefs.peqBands === "" || (prefs.peqBands === "[]" && old.length > 0)) {
            prefs.peqBands = JSON.stringify(old);
            if (old.length > 0) {
                prefs.eqGains = "0,0,0,0,0,0,0,0,0,0";
                if (prefs.eqPreset === "Flat") prefs.eqPreset = "Custom";
            }
        }
    }

    readonly property var builtinPresets: EqM.PRESETS
    readonly property var userPresets: {
        try {
            const a = JSON.parse(prefs.peqPresets || "[]");
            return Array.isArray(a) ? a.filter(p => p && typeof p.name === "string") : [];
        } catch (e) { return []; }
    }

    property string eqStatus: "off"     // off | starting | on | error
    property string eqError: ""
    property bool eqStopping: false
    property int eqEpoch: 0
    readonly property bool eqWanted: prefs.eqEnabled && eqAvailable && au.pipewireUp

    function num(v) { return Number(v).toFixed(2); }

    function eqArgs() {
        const nodes = ['{ type = builtin name = preamp label = bq_highshelf control = { "Freq" = 0.0 "Q" = 1.0 "Gain" = '
                       + num(prefs.eqPreamp) + ' } }'];
        const links = [];
        let prev = "preamp";
        for (const b of chainBands) {
            const st = EqM.stages(b);
            for (let k = 0; k < st.length; k++) {
                const name = "b" + b.id + "_" + k;
                nodes.push('{ type = builtin name = ' + name + ' label = ' + st[k].label + ' control = { "Freq" = '
                           + num(st[k].freq) + ' "Q" = ' + num(st[k].q) + ' "Gain" = ' + num(b.on ? st[k].gain : 0) + ' } }');
                links.push('{ output = "' + prev + ':Out" input = "' + name + ':In" }');
                prev = name;
            }
        }
        const target = prefs.eqTarget !== "" ? '\n                target.object = "' + prefs.eqTarget.replace(/"/g, "") + '"' : "";
        return '{\n'
            + '            node.description = "Equalizer"\n'
            + '            media.name = "Equalizer"\n'
            + '            filter.graph = {\n'
            + '                nodes = [\n                    ' + nodes.join("\n                    ") + '\n                ]\n'
            + (links.length ? '                links = [\n                    ' + links.join("\n                    ") + '\n                ]\n' : '')
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
            + '        }';
    }
    // A whole PipeWire configuration around a filter-chain, for running
    // it as a process of its own.
    function conf(args) {
        return 'context.properties = { log.level = 0 }\n'
            + 'context.spa-libs = {\n    audio.convert.* = audioconvert/libspa-audioconvert\n    support.* = support/libspa-support\n}\n'
            + 'context.modules = [\n'
            + '    { name = libpipewire-module-rt args = { nice.level = -11 } flags = [ ifexists nofail ] }\n'
            + '    { name = libpipewire-module-protocol-native }\n'
            + '    { name = libpipewire-module-client-node }\n'
            + '    { name = libpipewire-module-adapter }\n'
            + '    { name = libpipewire-module-filter-chain\n'
            + '        args = ' + args + '\n'
            + '    }\n'
            + ']\n';
    }

    // Writes the configuration and becomes the filter: one process, whose
    // life is the equalizer's.
    Process {
        id: eqProc
        running: root.eqWanted && root.fxProcess && !root.eqRebuilding && root.eqEpoch >= 0
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1" && exec pipewire -c "$1"',
                  "sh", root.dir + "/equalizer.conf", root.conf(root.eqArgs())]
        stderr: StdioCollector { id: eqErr }
        onStarted: { root.eqStatus = "starting"; root.eqError = ""; eqWatchdog.restart(); }
        onExited: code => {
            if (root.fxDaemon) return; // handed over to the daemon
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
                         + (root.fxDaemon ? "" : (eqErr.text.split("\n").filter(l => l.trim() !== "").pop() || "Nothing was logged."));
        }
    }

    // The same, in the daemon: loaded when wanted, unloaded when not.
    readonly property bool eqInDaemon: eqWanted && fxDaemon
    onEqInDaemonChanged: daemonSync("eq")
    onEqEpochChanged: if (eqInDaemon) daemonSync("eq")
    onNsInDaemonChanged: daemonSync("ns")
    onNsEpochChanged: if (nsInDaemon) daemonSync("ns")

    function daemonSync(key) {
        const eq = key === "eq";
        if (eq ? eqInDaemon : nsInDaemon) {
            if (eq) { eqStatus = "starting"; eqError = ""; eqWatchdog.restart(); }
            else { nsStatus = "starting"; nsError = ""; nsWatchdog.restart(); }
            Services.Daemon.send({ cmd: "fx-load", key: key, args: eq ? eqArgs() : nsArgs() });
        } else if (fxDaemon) {
            Services.Daemon.send({ cmd: "fx-unload", key: key });
        }
    }

    // PipeWire restarting takes the chains with it; brought back a few
    // times, then said.
    property int fxRetries: 0
    Timer {
        id: fxRetry
        interval: 3000
        onTriggered: {
            root.fxRetries++;
            if (root.eqInDaemon && root.eqStatus === "error") root.daemonSync("eq");
            if (root.nsInDaemon && root.nsStatus === "error") root.daemonSync("ns");
        }
    }
    onEqStatusChanged: if (eqStatus === "on") fxRetries = 0
    onNsStatusChanged: if (nsStatus === "on") fxRetries = 0

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "exited") {
                // Its chains went with it; loaded again when it is back.
                if (root.eqWanted && root.eqStatus !== "error") root.eqStatus = "starting";
                if (root.nsWanted && root.nsStatus !== "error") root.nsStatus = "starting";
                return;
            }
            if (ev.ev !== "fx" || ev.loaded) return;
            const eq = ev.key === "eq";
            const wanted = eq ? root.eqInDaemon : root.nsInDaemon;
            if (wanted && ev.error) {
                if (eq) { root.eqStatus = "error"; root.eqError = ev.error; }
                else { root.nsStatus = "error"; root.nsError = ev.error; }
                if (root.fxRetries < 3) fxRetry.restart();
            } else if (!wanted) {
                if (eq) { root.eqStatus = "off"; root.eqStopping = false; }
                else { root.nsStatus = "off"; root.nsStopping = false; }
            }
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
        if (!eqWanted) return;
        if (prefs.eqTarget === "" && au.rawSink && !au.isOurs(au.rawSink)) prefs.eqTarget = au.rawSink.name;
        if (eqPerApp) {
            // Only the chosen apps go through it: the device stays the
            // default, and the equalizer plays into whichever that is.
            if (au.eqActive) {
                const real = au.sinks.find(n => n.name === prefs.eqTarget) || au.sinks[0];
                if (real) au.setRawDefaultSink(real);
            }
            routeSoon.restart();
        } else if (!au.eqActive) {
            au.setRawDefaultSink(au.eqSink);
        }
        eqStatus = "on";
        pushGains();
    }
    function setEnabled(on) { prefs.eqEnabled = on; if (on && eqStatus === "error") retryEq(); }

    // ── for some apps only ───────────────────────────────────────────────
    // With eqScope "apps" the equalizer is not the default output: the
    // streams of the apps chosen are pointed at it one by one (PipeWire's
    // target.object, which WirePlumber follows and remembers per app), and
    // everything else plays straight to the device. An app is known by its
    // binary, or else its name, so a stream started later — the next song,
    // the next tab — goes the same way.
    readonly property bool eqPerApp: prefs.eqScope === "apps"
    readonly property var eqApps: { try { return JSON.parse(prefs.eqApps || "[]"); } catch (e) { return []; } }
    function appKey(s) {
        const p = s ? s.properties || {} : {};
        return p["application.process.binary"] || p["application.name"] || (s ? s.name : "") || "";
    }
    function isEqApp(s) { const k = appKey(s); return k !== "" && eqApps.indexOf(k) >= 0; }
    function isEqAppKey(k) { return eqApps.indexOf(k) >= 0; }
    function setEqAppKey(k, on) {
        if (k === "") return;
        const list = eqApps.filter(x => x !== k);
        if (on) list.push(k);
        prefs.eqApps = JSON.stringify(list);
    }
    function setEqApp(s, on) { setEqAppKey(appKey(s), on); }
    function setScope(scope) { prefs.eqScope = scope === "apps" ? "apps" : "all"; }
    onEqPerAppChanged: syncEq()

    // Streams' properties (their app) only arrive once they are bound.
    readonly property bool routing: eqWanted && eqPerApp
    SteadyTracker { nodes: root.routing ? root.au.streams : [] }
    // pactl's tables, to see which streams are still on the equalizer.
    property bool watching: false
    onRoutingChanged: {
        if (routing !== watching) { watching = routing; au.watch(routing); }
        if (!routing) unrouteAll();
        routeSoon.restart();
    }

    // Which streams were pointed at the equalizer, by node id.
    property var routed: ({})
    readonly property string routeKey: routing
        ? au.streams.map(s => s.id + "=" + appKey(s) + ">" + au.streamSinkName(s)).join(",") + "|" + prefs.eqApps
          + "|" + (au.eqSink ? au.eqSink.id : -1)
        : ""
    onRouteKeyChanged: if (routing) routeSoon.restart()
    Timer { id: routeSoon; interval: 400; onTriggered: root.route() }

    function route() {
        if (!routing || !au.eqSink) return;
        const next = {};
        for (const s of au.streams) {
            const k = String(s.id);
            const want = isEqApp(s);
            const on = routed[k] === true || au.streamSinkName(s) === au.eqSinkName;
            if (want) {
                if (routed[k] !== true) target(s.id, au.eqSinkName);
                next[k] = true;
            } else if (on) {
                target(s.id, "");
            }
        }
        routed = next;
    }
    // Everything pointed at the equalizer let go again, to follow the
    // default — on switching it off or back to every app.
    function unrouteAll() {
        for (const k in routed) if (routed[k] && au.streams.some(s => String(s.id) === k)) target(parseInt(k), "");
        routed = ({});
    }
    property var metaQueue: []
    function target(id, sinkName) {
        const cmd = sinkName !== ""
            ? ["pw-metadata", String(id), "target.object", sinkName]
            : ["pw-metadata", "-d", String(id), "target.object"];
        metaQueue = metaQueue.concat([cmd]);
        if (!metaProc.running) nextMeta();
    }
    function nextMeta() {
        const q = metaQueue.slice();
        metaProc.command = q.shift();
        metaQueue = q;
        metaProc.running = true;
    }
    Process {
        id: metaProc
        onExited: if (root.metaQueue.length > 0) root.nextMeta()
    }
    // The device chosen while only some apps are equalized is the one the
    // equalizer plays into as well.
    Connections {
        target: root.au
        enabled: root.routing
        function onRawSinkChanged() {
            const r = root.au.rawSink;
            if (!r || root.au.isOurs(r) || r.name === root.prefs.eqTarget) return;
            root.prefs.eqTarget = r.name;
            const out = root.au.nodes.find(n => n.name === root.au.eqOutName);
            if (out) root.au.moveStream(out, r);
        }
    }
    function retryEq() { eqError = ""; eqEpoch++; }

    // ── the bands, changed ───────────────────────────────────────────────
    // A band's frequency, gain and Q move live; a change in what the chain
    // is made of (a band added, removed, of another type or slope) builds it
    // again, a moment after the last such change. The device goes and comes
    // back with it, and the sound with it — a fraction of a second.
    property bool eqRebuilding: false
    onStructureChanged: if (eqWanted) rebuildSoon.restart()
    Timer {
        id: rebuildSoon
        interval: 350
        onTriggered: root.rebuild()
    }
    function rebuild() {
        if (!eqWanted) return;
        if (eqInDaemon) { daemonSync("eq"); return; }
        if (!fxProcess) return;
        // The process reads its configuration once: stopped, and started
        // again with the new one once it has gone.
        eqStopping = true;
        eqRebuilding = true;
        rebuildGap.restart();
    }
    Timer { id: rebuildGap; interval: 450; onTriggered: root.eqRebuilding = false }

    function store(list, custom) {
        prefs.peqBands = JSON.stringify(list.map(b => EqM.clean(b, b.id)));
        if (custom !== false) prefs.eqPreset = "Custom";
        pushGains();
    }
    function band(id) { return bands.find(b => b.id === id) || null; }
    // patch: any of type, freq, gain, q, slope, on.
    function setBand(id, patch) {
        store(bands.map(b => {
            if (b.id !== id) return b;
            const n = Object.assign({}, b, patch);
            // A band turned into a cut or a notch has no gain to keep.
            if (patch.type !== undefined && !EqM.hasGain(n.type)) n.gain = 0;
            if (patch.type !== undefined && EqM.isCut(n.type) && !EqM.isCut(b.type)) n.q = 0.71;
            return n;
        }));
    }
    // Returns the new band's id, or -1 when there are already as many as
    // there can be.
    function addBand(freq, gain) {
        if (bands.length >= EqM.MAX_BANDS) return -1;
        const id = EqM.nextId(bands);
        store(bands.concat([EqM.bandAt(freq, gain || 0, id)]));
        return id;
    }
    function removeBand(id) { store(bands.filter(b => b.id !== id)); }
    function toggleBand(id) { const b = band(id); if (b) setBand(id, { on: !b.on }); }
    function setPreamp(db) {
        prefs.eqPreamp = Math.round(Math.max(-24, Math.min(24, db)) * 10) / 10;
        pushGains();
    }
    // The preamp down by however far the curve rises above 0 dB, so the
    // loudest passage still has room: what a mastering engineer would do
    // before anything else.
    function autoPreamp() {
        const top = EqM.peakBoost(bands.filter(b => b.on));
        setPreamp(top > 0.05 ? -Math.ceil(top * 10) / 10 : 0);
    }
    function reset() {
        prefs.peqBands = "[]";
        prefs.eqPreamp = 0;
        prefs.eqPreset = "Flat";
        pushGains();
    }
    function applyPreset(p) {
        const list = p.user ? (p.bands || []).map((b, i) => EqM.clean(b, i + 1)) : EqM.presetBands(p);
        prefs.peqBands = JSON.stringify(list);
        prefs.eqPreset = p.name;
        if (p.user && typeof p.preamp === "number") prefs.eqPreamp = p.preamp;
        else {
            const top = EqM.peakBoost(list);
            prefs.eqPreamp = top > 0.05 ? -Math.ceil(top * 10) / 10 : 0;
        }
        pushGains();
    }
    // Yours, kept beside the built-in ones: the bands and the preamp as
    // they are now, under a name (the same name replaces it).
    function savePreset(name) {
        name = String(name || "").trim().slice(0, 40);
        if (name === "") return false;
        const list = userPresets.filter(p => p.name !== name);
        list.push({ name: name, preamp: prefs.eqPreamp, bands: bands });
        list.sort((a, b) => a.name.localeCompare(b.name));
        prefs.peqPresets = JSON.stringify(list);
        prefs.eqPreset = name;
        return true;
    }
    function deletePreset(name) {
        prefs.peqPresets = JSON.stringify(userPresets.filter(p => p.name !== name));
        if (prefs.eqPreset === name) prefs.eqPreset = "Custom";
    }

    // Live: every stage's frequency, Q and gain to the running filter, at
    // most every 50 ms while something is dragged. Only when the chain it
    // is sent to is the one these bands describe; a rebuild on its way
    // brings them with it.
    Timer { id: pushSoon; interval: 50; onTriggered: root.sendGains() }
    function pushGains() { if (au.eqSink) pushSoon.restart(); }
    Process { id: paramProc }
    property string sentStructure: ""
    function sendGains() {
        if (!au.eqSink || !hasPwCli) return;
        if (rebuildSoon.running || eqRebuilding) return;
        const parts = ['"preamp:Gain" ' + num(prefs.eqPreamp)];
        for (const b of chainBands) {
            const st = EqM.stages(b);
            for (let k = 0; k < st.length; k++) {
                const n = '"b' + b.id + '_' + k + ':';
                parts.push(n + 'Freq" ' + num(st[k].freq), n + 'Q" ' + num(st[k].q),
                           n + 'Gain" ' + num(b.on ? st[k].gain : 0));
            }
        }
        const props = '{ params = [ ' + parts.join(" ") + ' ] }';
        if (paramProc.running) { pushSoon.restart(); return; }
        paramProc.command = ["pw-cli", "set-param", String(au.eqSink.id), "Props", props];
        paramProc.running = true;
    }

    // ══ noise suppression ════════════════════════════════════════════════
    property string nsStatus: "off"
    property string nsError: ""
    property bool nsStopping: false
    property int nsEpoch: 0
    readonly property bool nsWanted: prefs.nsEnabled && nsAvailable && au.pipewireUp
    readonly property bool nsInDaemon: nsWanted && fxDaemon

    function nsArgs() {
        const target = prefs.nsTarget !== "" ? '\n                target.object = "' + prefs.nsTarget.replace(/"/g, "") + '"' : "";
        return '{\n'
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
            + '        }';
    }

    Process {
        id: nsProc
        running: root.nsWanted && root.fxProcess && root.nsEpoch >= 0
        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "%s" "$2" > "$1" && exec pipewire -c "$1"',
                  "sh", root.dir + "/noise-suppression.conf", root.conf(root.nsArgs())]
        stderr: StdioCollector { id: nsErr }
        onStarted: { root.nsStatus = "starting"; root.nsError = ""; nsWatchdog.restart(); }
        onExited: code => {
            if (root.fxDaemon) return;
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
