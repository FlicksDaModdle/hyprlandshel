pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../config" as Config
import "." as Services

// PipeWire audio: the default output and input, every device and every
// application stream, for the bar's volume readout, the control center's
// sliders, the volume OSD and Settings → Sound.
//
// Levels, mutes, balance and the default devices go through Quickshell's
// PipeWire binding. What it does not expose — a card's profiles (stereo,
// surround, a headset's two Bluetooth modes), a device's ports (speakers
// against headphones), which output an app is playing to — comes from
// pipewire-pulse's `pactl`, read as JSON and kept fresh by `pactl
// subscribe` for as long as something is looking (see watch()).
Singleton {
    id: root

    // The shell's own virtual devices (AudioFx.qml): the equalizer is an
    // output everything plays into, which passes the sound on to a real
    // one; noise suppression is an input, fed from a real microphone.
    // While one is the default, "the output" or "the microphone" everywhere
    // in the shell means the real device behind it — that is the one whose
    // volume the keys should move and whose name people expect to see.
    readonly property string eqSinkName: "hyprshell_eq"
    readonly property string eqOutName: "hyprshell_eq_out"
    readonly property string nsSourceName: "hyprshell_ns"
    readonly property string nsInName: "hyprshell_ns_in"
    function isOurs(n) {
        if (!n) return false;
        const p = n.properties || {};
        return (n.name || "").indexOf("hyprshell_") === 0
            || (p["application.name"] || "").indexOf("hyprshell-") === 0;
    }

    readonly property var rawSink: Pipewire.defaultAudioSink
    readonly property var rawSource: Pipewire.defaultAudioSource
    readonly property bool eqActive: !!rawSink && rawSink.name === eqSinkName
    readonly property bool nsActive: !!rawSource && rawSource.name === nsSourceName
    readonly property var eqSink: nodes.find(n => n.name === eqSinkName) || null
    readonly property var nsSource: nodes.find(n => n.name === nsSourceName) || null
    readonly property var sink: eqActive
        ? (sinks.find(n => n.name === Config.Appearance.eqTarget) || sinks[0] || rawSink) : rawSink
    readonly property var source: nsActive
        ? (sources.find(n => n.name === Config.Appearance.nsTarget) || sources[0] || rawSource) : rawSource
    // false only when the binding says so outright: older Quickshell builds
    // have no `ready`, and undefined is not a reason to say audio is down.
    readonly property bool pipewireUp: Pipewire.ready !== false

    // The level meters' peak monitor (PwNodePeakMonitor) arrived in
    // Quickshell 0.3.0 and crashes the whole shell there when a device's
    // channels differ from what it samples — fixed in 0.3.1. QML can tell
    // 0.3 from 0.2 but not 0.3.0 from 0.3.1, so ask the running binary
    // (this process's parent's executable) for its version, once.
    property string qsVersion: ""
    readonly property bool metersSafe: {
        const m = /(\d+)\.(\d+)\.(\d+)/.exec(qsVersion);
        if (!m) return false;
        const v = [Number(m[1]), Number(m[2]), Number(m[3])];
        return v[0] > 0 || v[1] > 3 || (v[1] === 3 && v[2] >= 1);
    }
    readonly property bool metersOn: metersSafe && Config.Appearance.soundMeters
    Process {
        running: true
        command: ["sh", "-c",
            'exe=$(readlink "/proc/$PPID/exe" 2>/dev/null); '
          + 'for q in "$exe" quickshell qs; do '
          + '  [ -n "$q" ] && command -v "$q" >/dev/null 2>&1 || continue; '
          + '  v=$("$q" --version 2>/dev/null); '
          + '  case "$v" in *[Qq]uickshell*) printf "%s\\n" "$v"; exit 0 ;; esac; '
          + 'done; true']
        stdout: StdioCollector { onStreamFinished: root.qsVersion = text.trim() }
    }

    // Node properties (volume/mute) are only live while the node is bound.
    // Either default can be null before PipeWire is up, so the list is
    // filtered rather than handed nulls.
    PwObjectTracker {
        objects: [root.sink, root.source, root.rawSink, root.rawSource].filter(n => n !== null && n !== undefined)
    }

    // The ceiling a drag or a volume key can reach, set in Settings →
    // Sound → Options: under 100% as a hearing limit, over it (to 150%) as
    // PipeWire's software boost. The older on/off boost setting still
    // counts as 150%.
    readonly property real maxVolume: Math.max(Config.Appearance.volumeMax,
                                               Config.Appearance.volumeBoost ? 150 : 0) / 100

    readonly property bool ready: !!sink && !!sink.audio
    readonly property real volume: ready ? sink.audio.volume : 0
    readonly property bool muted: ready ? sink.audio.muted : false
    readonly property int volumePercent: Math.round(volume * 100)

    readonly property bool sourceReady: !!source && !!source.audio
    readonly property real inputVolume: sourceReady ? source.audio.volume : 0
    readonly property bool inputMuted: sourceReady ? source.audio.muted : false
    readonly property int inputPercent: Math.round(inputVolume * 100)

    readonly property string sinkName: displayName(sink)
    readonly property string sourceName: displayName(source)

    // ── every node ───────────────────────────────────────────────────────
    // Monitor streams are someone measuring a level — pavucontrol's meters,
    // Quickshell's own peak monitor in Settings — and not something anyone
    // is listening to, so they are left out of the app lists.
    function isMonitor(n) {
        const p = n.properties || {};
        return p["stream.monitor"] === "true" || p["media.category"] === "Monitor";
    }
    readonly property var nodes: Pipewire.nodes.values.filter(n => !!n && !!n.audio)
    // Real devices, outputs and inputs.
    readonly property var sinks: nodes.filter(n => n.isSink && !n.isStream && !isOurs(n))
    readonly property var sources: nodes.filter(n => !n.isSink && !n.isStream && !isOurs(n))
    // Applications playing, and applications recording.
    readonly property var streams: nodes.filter(n => n.isSink && n.isStream && !isMonitor(n) && !isOurs(n))
    readonly property var recorders: nodes.filter(n => !n.isSink && n.isStream && !isMonitor(n) && !isOurs(n))

    // Devices left out of the lists in Settings (they still work).
    readonly property var hiddenNames: { try { return JSON.parse(Config.Appearance.soundHidden || "[]"); } catch (e) { return []; } }
    function isHidden(node) { return !!node && hiddenNames.indexOf(node.name) >= 0; }
    function setHidden(node, on) {
        if (!node) return;
        const list = hiddenNames.filter(n => n !== node.name);
        if (on) list.push(node.name);
        Config.Appearance.soundHidden = JSON.stringify(list);
    }
    // Names given to devices here, in place of the driver's.
    readonly property var nicknames: { try { return JSON.parse(Config.Appearance.soundNames || "{}"); } catch (e) { return {}; } }
    function setNickname(node, name) {
        if (!node) return;
        const map = Object.assign({}, nicknames);
        if ((name || "").trim() === "") delete map[node.name];
        else map[node.name] = name.trim();
        Config.Appearance.soundNames = JSON.stringify(map);
    }

    // Glyph that matches the current level, like the mockup's volume-2 /
    // volume-1 / volume-x set.
    readonly property string icon: muted || volume <= 0.001 ? "volumeX"
                                 : (volume < 0.5 ? "volumeLow" : "volume")

    function setVolume(v) {
        if (!ready) return;
        sink.audio.volume = Math.max(0, Math.min(maxVolume, v));
    }

    function setMuted(m) {
        if (ready) sink.audio.muted = m;
    }

    function toggleMute() {
        if (ready) {
            sink.audio.muted = !sink.audio.muted;
            Config.UiState.showOsd("volume", volume, sink.audio.muted);
            return;
        }
        fallbackMuted = !fallbackMuted;
        fallbackRun({ wp: "set-mute @DEFAULT_AUDIO_SINK@ toggle",
                      pa: "set-sink-mute @DEFAULT_SINK@ toggle" });
        Config.UiState.showOsd("volume", fallbackVolume, fallbackMuted);
    }

    // ── fallback ──────────────────────────────────────────────────────────
    // PipeWire's node is only live while Quickshell has it bound, and it can
    // be null — no default sink yet, a session where the binding never comes
    // up. The old code returned early in that case, which meant the volume
    // keys did nothing *and* showed no OSD, so there was no sign anything had
    // happened at all. wpctl (wireplumber) or pactl does the job instead, and
    // the OSD shows either way.
    property bool fallbackUsed: false
    property real fallbackVolume: 0
    property bool fallbackMuted: false

    Process { id: volProc }

    Process {
        id: volQuery
        stdout: StdioCollector {
            onStreamFinished: {
                // wpctl prints: "Volume: 0.45" or "Volume: 0.45 [MUTED]"
                const m = /Volume:\s*([\d.]+)(\s*\[MUTED\])?/.exec(text);
                if (!m) return;
                root.fallbackVolume = parseFloat(m[1]);
                root.fallbackMuted = !!m[2];
                root.fallbackUsed = true;
            }
        }
    }

    function fallbackRun(args) {
        volProc.running = false;
        volProc.command = ["sh", "-c",
            "if command -v wpctl >/dev/null 2>&1; then wpctl " + args.wp
            + "; elif command -v pactl >/dev/null 2>&1; then pactl " + args.pa + "; fi"];
        volProc.running = true;
        volQuery.command = ["sh", "-c",
            "command -v wpctl >/dev/null 2>&1 && wpctl get-volume @DEFAULT_AUDIO_SINK@"];
        volQuery.running = true;
    }

    // Callers speak in the old fixed 5% steps (0.05 a key press, the bar's
    // scroll wheel a multiple of it); the step set in Settings → Sound
    // scales that, so every caller follows it without knowing it exists.
    function step(delta) {
        delta = delta * Math.max(1, Config.Appearance.volumeStep) / 5;
        const pct = Math.round(Math.abs(delta) * 100);
        feedback();
        if (ready) {
            setVolume(volume + delta);
            Config.UiState.showOsd("volume", sink.audio.volume, sink.audio.muted);
            return;
        }
        const dir = delta > 0 ? "+" : "-";
        fallbackRun({
            // -l caps software boost, matching setVolume's own clamp.
            wp: "set-volume -l " + maxVolume.toFixed(1) + " @DEFAULT_AUDIO_SINK@ " + pct + "%" + dir,
            pa: "set-sink-volume @DEFAULT_SINK@ " + dir + pct + "%"
        });
        const shown = Math.max(0, Math.min(maxVolume, fallbackVolume + delta));
        fallbackVolume = shown;
        Config.UiState.showOsd("volume", shown, fallbackMuted);
    }

    function setInputVolume(v) {
        if (sourceReady) source.audio.volume = Math.max(0, Math.min(1.5, v));
    }

    function toggleInputMute() {
        if (sourceReady) {
            source.audio.muted = !source.audio.muted;
            Config.UiState.showOsd("mic", inputVolume, source.audio.muted);
            return;
        }
        fallbackRun({ wp: "set-mute @DEFAULT_AUDIO_SOURCE@ toggle",
                      pa: "set-source-mute @DEFAULT_SOURCE@ toggle" });
        Config.UiState.showOsd("mic", 0, true);
    }

    // With the equalizer or noise suppression in the way, "use this
    // device" re-points the effect at it and leaves the effect the default.
    function setDefaultSink(node) {
        if (!node) return;
        if (eqActive) {
            Config.Appearance.eqTarget = node.name;
            const out = nodes.find(n => n.name === eqOutName);
            if (out) moveStream(out, node);
            return;
        }
        Pipewire.preferredDefaultAudioSink = node;
    }
    function setDefaultSource(node) {
        if (!node) return;
        if (nsActive) {
            Config.Appearance.nsTarget = node.name;
            const inp = nodes.find(n => n.name === nsInName);
            if (inp) moveRecorder(inp, node);
            return;
        }
        Pipewire.preferredDefaultAudioSource = node;
    }
    // Straight to PipeWire, for AudioFx switching an effect in and out.
    function setRawDefaultSink(node) { if (node) Pipewire.preferredDefaultAudioSink = node; }
    function setRawDefaultSource(node) { if (node) Pipewire.preferredDefaultAudioSource = node; }

    function displayName(node) {
        if (!node) return "";
        return nicknames[node.name] || node.nickname || node.description || node.name || "";
    }
    function driverName(node) {
        return node ? (node.nickname || node.description || node.name || "") : "";
    }

    // ── any node ─────────────────────────────────────────────────────────
    // These all want the node bound; Settings → Sound tracks every node it
    // shows for as long as it is open.
    function nodeVolume(node) { return node && node.audio ? node.audio.volume : 0; }
    function nodeMuted(node) { return !!node && !!node.audio && node.audio.muted; }
    function setNodeVolume(node, v) {
        if (node && node.audio) node.audio.volume = Math.max(0, Math.min(node.isStream || node.isSink ? maxVolume : 1.5, v));
    }
    function setNodeMuted(node, m) { if (node && node.audio) node.audio.muted = m; }

    // Balance, -1 (all left) to 1 (all right), for a node with a front left
    // and front right. The louder side keeps the level; the other is turned
    // down — the way a balance knob works, so moving it never makes the
    // whole thing louder.
    function hasBalance(node) {
        if (!node || !node.audio) return false;
        const ch = node.audio.channels || [];
        return ch.indexOf(PwAudioChannel.FrontLeft) >= 0 && ch.indexOf(PwAudioChannel.FrontRight) >= 0;
    }
    function balance(node) {
        if (!hasBalance(node)) return 0;
        const ch = node.audio.channels, v = node.audio.volumes;
        const l = v[ch.indexOf(PwAudioChannel.FrontLeft)], r = v[ch.indexOf(PwAudioChannel.FrontRight)];
        const top = Math.max(l, r);
        if (top <= 0.0001) return 0;
        return r >= l ? 1 - l / top : -(1 - r / top);
    }
    function setBalance(node, b) {
        if (!hasBalance(node)) return;
        b = Math.max(-1, Math.min(1, b));
        if (Math.abs(b) < 0.03) b = 0;      // a little stickiness at the centre
        const ch = node.audio.channels;
        const vols = Array.from(node.audio.volumes);
        const level = Math.max.apply(null, vols);
        for (let i = 0; i < ch.length; i++) {
            const left = ch[i] === PwAudioChannel.FrontLeft || ch[i] === PwAudioChannel.RearLeft
                      || ch[i] === PwAudioChannel.SideLeft;
            const right = ch[i] === PwAudioChannel.FrontRight || ch[i] === PwAudioChannel.RearRight
                       || ch[i] === PwAudioChannel.SideRight;
            vols[i] = left ? level * (b > 0 ? 1 - b : 1)
                    : right ? level * (b < 0 ? 1 + b : 1)
                    : level;
        }
        node.audio.volumes = vols;
    }

    // Each channel on its own, for the Channels list.
    function setChannelVolume(node, i, v) {
        if (!node || !node.audio) return;
        const vols = Array.from(node.audio.volumes);
        if (i < 0 || i >= vols.length) return;
        vols[i] = Math.max(0, Math.min(node.isSink ? maxVolume : 1.5, v));
        node.audio.volumes = vols;
    }
    function channelName(c) {
        const n = {};
        n[PwAudioChannel.Mono] = "Mono";
        n[PwAudioChannel.FrontLeft] = "Front left"; n[PwAudioChannel.FrontRight] = "Front right";
        n[PwAudioChannel.FrontCenter] = "Centre"; n[PwAudioChannel.LowFrequencyEffects] = "Subwoofer";
        n[PwAudioChannel.RearLeft] = "Rear left"; n[PwAudioChannel.RearRight] = "Rear right";
        n[PwAudioChannel.RearCenter] = "Rear centre";
        n[PwAudioChannel.SideLeft] = "Side left"; n[PwAudioChannel.SideRight] = "Side right";
        return n[c] || ("Channel " + c);
    }

    // Fade, -1 (all front) to 1 (all rear), for surround: the same idea
    // as balance, front against back.
    function isRear(c) {
        return c === PwAudioChannel.RearLeft || c === PwAudioChannel.RearRight
            || c === PwAudioChannel.RearCenter || c === PwAudioChannel.SideLeft
            || c === PwAudioChannel.SideRight;
    }
    function isFront(c) {
        return c === PwAudioChannel.FrontLeft || c === PwAudioChannel.FrontRight
            || c === PwAudioChannel.FrontCenter;
    }
    function hasFade(node) {
        if (!node || !node.audio) return false;
        const ch = node.audio.channels || [];
        return ch.some(c => isRear(c)) && ch.some(c => isFront(c));
    }
    function fade(node) {
        if (!hasFade(node)) return 0;
        const ch = node.audio.channels, v = node.audio.volumes;
        let f = 0, r = 0;
        for (let i = 0; i < ch.length; i++) {
            if (isFront(ch[i])) f = Math.max(f, v[i]);
            else if (isRear(ch[i])) r = Math.max(r, v[i]);
        }
        const top = Math.max(f, r);
        if (top <= 0.0001) return 0;
        return r >= f ? 1 - f / top : -(1 - r / top);
    }
    function setFade(node, b) {
        if (!hasFade(node)) return;
        b = Math.max(-1, Math.min(1, b));
        if (Math.abs(b) < 0.03) b = 0;
        const ch = node.audio.channels;
        const vols = Array.from(node.audio.volumes);
        const level = Math.max.apply(null, vols);
        for (let i = 0; i < ch.length; i++) {
            vols[i] = isFront(ch[i]) ? level * (b > 0 ? 1 - b : 1)
                    : isRear(ch[i]) ? level * (b < 0 ? 1 + b : 1)
                    : level;
        }
        node.audio.volumes = vols;
    }

    // Short names for the speaker positions a test can be played on.
    function channelInfo(node) {
        if (!node || !node.audio) return [];
        const names = {};
        names[PwAudioChannel.FrontLeft] = ["FL", "Left", "front-left"];
        names[PwAudioChannel.FrontRight] = ["FR", "Right", "front-right"];
        names[PwAudioChannel.FrontCenter] = ["FC", "Centre", "front-center"];
        names[PwAudioChannel.LowFrequencyEffects] = ["LFE", "Subwoofer", "lfe"];
        names[PwAudioChannel.RearLeft] = ["RL", "Rear left", "rear-left"];
        names[PwAudioChannel.RearRight] = ["RR", "Rear right", "rear-right"];
        names[PwAudioChannel.SideLeft] = ["SL", "Side left", "side-left"];
        names[PwAudioChannel.SideRight] = ["SR", "Side right", "side-right"];
        return (node.audio.channels || []).filter(c => !!names[c])
            .map(c => ({ pos: names[c][0], label: names[c][1], file: names[c][2] }));
    }

    // What sort of thing a device is, for its glyph and its one-line
    // description. Read from what the port and the device say about
    // themselves; "speaker" and "mic" are the honest defaults.
    function deviceKind(node) {
        if (!node) return "speaker";
        const p = node.properties || {};
        const d = details(node);
        const hint = [p["device.form-factor"], p["device.icon-name"], p["device.bus"],
                      p["node.name"], d.port ? d.port.type + " " + d.port.name + " " + d.port.description : ""]
                     .join(" ").toLowerCase();
        if (/hdmi|displayport|\bdp\b/.test(hint)) return "monitor";
        if (/headphone|headset|hands-?free|handsfree/.test(hint)) return node.isSink ? "headphones" : "mic";
        if (/bluez|bluetooth/.test(hint)) return node.isSink ? "headphones" : "mic";
        return node.isSink ? "speaker" : "mic";
    }
    function deviceGlyph(node) {
        const k = deviceKind(node);
        return k === "monitor" ? "monitor" : k === "headphones" ? "headphones" : k === "mic" ? "mic" : "speaker";
    }

    // An application stream's own name, and what it is playing.
    function streamApp(node) {
        const p = node ? node.properties || {} : {};
        return p["application.name"] || p["application.process.binary"] || displayName(node) || "Unknown";
    }
    function streamMedia(node) {
        const p = node ? node.properties || {} : {};
        const m = p["media.name"] || "";
        // Browsers and players name the stream after themselves, or with a
        // stock label; neither says anything the app name hasn't.
        if (m === "" || m === streamApp(node) || /^(playback|audio ?stream|output|record|capture|(rec|play)stream)$/i.test(m)) return "";
        return m;
    }
    function streamHint(node) {
        const p = node ? node.properties || {} : {};
        return p["application.process.binary"] || p["application.icon-name"] || p["application.name"] || "";
    }

    // ── what pactl knows ─────────────────────────────────────────────────
    // cards: [{ index, name, description, profiles: [{ name, description,
    //           available }], activeProfile, objectId }]
    // pulse: { sinks, sources }, each name → { index, ports: [{ name,
    //           description, type, available }], activePort, card, deviceId }
    // inputs: stream node id → { index, sink }, for moving a stream
    property var cards: []
    property var pulse: ({ sinks: {}, sources: {} })
    property var inputs: ({})
    property var sinkIndex: ({})        // pulse index → sink name
    property var sourceIndex: ({})      // pulse index → source name
    property var outputs: ({})          // recording stream node id → { index, source }
    property bool pactlMissing: false
    property string lastError: ""

    // How many open things want the details kept fresh. watch(true) on
    // opening, watch(false) on closing; the subscription runs while any do.
    property int watchers: 0
    function watch(on) {
        watchers = Math.max(0, watchers + (on ? 1 : -1));
        if (viaDaemon) Services.Daemon.send({ cmd: "pa-watch", on: watchers > 0 });
        if (on) refreshDetails();
    }

    // ── hyprshell-daemon ──────────────────────────────────────────────────
    // When it is running it speaks PulseAudio's protocol itself: snapshots
    // in pactl's own JSON shapes, pushed as things change while watched, and
    // the same commands pactl was used for. Nothing below starts pactl then.
    readonly property bool viaDaemon: Services.Daemon.paLive
    onViaDaemonChanged: if (viaDaemon) Services.Daemon.send({ cmd: "pa-watch", on: watchers > 0 })
    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "pa" && ev.available === true) {
                root.pactlMissing = false;
                root.parseLists(ev.cards || [], ev.sinks || [], ev.sources || [], ev.sinkInputs || [], ev.sourceOutputs || []);
            } else if (ev.ev === "pa-done" && ev.ok === false) {
                const what = { "pa-profile": "change the mode", "pa-port": "change the connector",
                               "pa-move-input": "move the app", "pa-move-output": "move the app",
                               "pa-latency": "set the delay" }[ev.op] || "do that";
                root.lastError = "The sound server couldn't " + what + ".";
            }
        }
    }

    function details(node) {
        if (!node) return {};
        const table = node.isSink ? pulse.sinks : pulse.sources;
        const d = table[node.name];
        if (!d) return {};
        const card = cards.find(c => (d.card >= 0 && c.index === d.card)
                                  || (d.deviceId !== "" && c.objectId === d.deviceId)) || null;
        const port = (d.ports || []).find(pt => pt.name === d.activePort) || null;
        const cardPort = card && port ? (card.ports || []).find(cp => cp.name === port.name) || null : null;
        return { ports: d.ports || [], activePort: d.activePort, port: port, card: card,
                 spec: d.spec, channelMap: d.channelMap, latencyUs: d.latencyUs, state: d.state,
                 props: d.props, latencyOffsetMs: cardPort ? Math.round(cardPort.latencyOffset / 1000) : 0,
                 canOffset: !!cardPort };
    }

    function refreshDetails() {
        if (viaDaemon) { Services.Daemon.send({ cmd: "pa-snapshot" }); return; }
        detailsDebounce.restart();
    }
    Timer {
        id: detailsDebounce
        interval: 200
        onTriggered: {
            detailsProc.running = false;
            detailsProc.running = true;
        }
    }
    // A device coming or going is a change in the node list, and the card
    // behind it is what changes with it.
    Connections {
        target: Pipewire.nodes
        enabled: root.watchers > 0
        function onValuesChanged() { root.refreshDetails(); }
    }

    // Everything else: plugging headphones into the jack changes a port's
    // availability and which port is active without adding or removing a
    // single node, and a profile switched from pavucontrol is the same.
    // pipewire-pulse reports both as events; any of them re-reads.
    Process {
        id: subscribeProc
        // subscribeEpoch only re-runs the binding: a restart after an exit
        // has to go through it, since assigning `running` would break it.
        running: root.watchers > 0 && !root.viaDaemon && !root.pactlMissing && root.pipewireUp && root.subscribeEpoch >= 0
        // C locale, because the event lines are translated; line-buffered,
        // or events sit in a pipe buffer until it fills.
        command: ["sh", "-c", "export LC_ALL=C; command -v stdbuf >/dev/null 2>&1 && exec stdbuf -oL pactl subscribe; exec pactl subscribe"]
        stdout: SplitParser {
            onRead: line => {
                if (/'(change|new|remove)' on (card|sink|source|sink-input|server)/.test(line))
                    root.refreshDetails();
            }
        }
        // Restarted PipeWire takes the subscription with it.
        onExited: if (root.watchers > 0) resubscribe.restart()
    }
    property int subscribeEpoch: 0
    Timer {
        id: resubscribe
        interval: 2000
        onTriggered: if (root.watchers > 0 && !subscribeProc.running) root.subscribeEpoch++
    }

    Process {
        id: detailsProc
        command: ["sh", "-c",
            "command -v pactl >/dev/null 2>&1 || { echo NOPACTL; exit 0; }; "
            + "for w in cards sinks sources sink-inputs source-outputs; do pactl -f json list $w 2>/dev/null || echo '[]'; echo; echo '@@'; done"]
        stdout: StdioCollector {
            onStreamFinished: root.parseDetails(text)
        }
    }

    // pactl's JSON keyed some lists by name in older releases and made them
    // arrays in newer ones; both come out of here as arrays with names.
    function asList(x) {
        if (!x) return [];
        if (Array.isArray(x)) return x;
        return Object.keys(x).map(k => Object.assign({ name: k }, x[k]));
    }
    function isAvailable(a) {
        // "available", "not available" or "availability unknown" — and
        // unknown is how a jack that can't sense plugging reports itself, so
        // only a definite no counts as unplugged.
        return a === undefined || a === true || (typeof a === "string" && a.indexOf("not available") < 0);
    }
    function parseDetails(text) {
        if (text.trim() === "NOPACTL") { pactlMissing = true; return; }
        pactlMissing = false;
        const parts = text.split("@@");
        const parse = s => { try { const v = JSON.parse(s.trim() || "[]"); return Array.isArray(v) ? v : []; } catch (e) { return []; } };
        parseLists(parse(parts[0] || ""), parse(parts[1] || ""), parse(parts[2] || ""),
                   parse(parts[3] || ""), parse(parts[4] || ""));
    }
    // pactl's JSON lists, from pactl or from the daemon.
    function parseLists(rawCards, rawSinks, rawSources, rawInputs, rawOutputs) {

        cards = rawCards.map(c => {
            const p = c.properties || {};
            return {
                index: c.index,
                name: c.name,
                description: p["device.description"] || p["device.product.name"] || c.name,
                objectId: String(p["object.id"] || ""),
                activeProfile: c.active_profile || "",
                ports: asList(c.ports).map(pt => ({ name: pt.name, latencyOffset: Number(pt.latency_offset || 0) })),
                profiles: asList(c.profiles)
                    .sort((a, b) => (b.priority || 0) - (a.priority || 0))
                    .map(pr => ({ name: pr.name, description: pr.description || pr.name,
                                  available: pr.available !== false && pr.available !== "no" }))
            };
        });

        const table = list => {
            const out = {};
            for (const s of list) {
                const p = s.properties || {};
                out[s.name] = {
                    index: s.index,
                    card: typeof s.card === "number" ? s.card : -1,
                    deviceId: String(p["device.id"] || ""),
                    activePort: s.active_port || "",
                    state: s.state || "",
                    spec: s.sample_specification || "",
                    channelMap: s.channel_map || "",
                    latencyUs: s.latency ? Number(s.latency.actual || 0) : 0,
                    props: {
                        codec: p["api.bluez5.codec"] || "",
                        bus: p["device.bus"] || "",
                        api: p["device.api"] || "",
                        card: p["alsa.card_name"] || p["alsa.long_card_name"] || "",
                        path: p["api.alsa.path"] || p["api.bluez5.address"] || "",
                        formFactor: p["device.form_factor"] || ""
                    },
                    ports: asList(s.ports).map(pt => ({
                        name: pt.name, description: pt.description || pt.name,
                        type: pt.type || "", available: isAvailable(pt.availability ?? pt.available)
                    }))
                };
            }
            return out;
        };
        pulse = { sinks: table(rawSinks), sources: table(rawSources.filter(s => !(s.name || "").endsWith(".monitor"))) };

        const idx = {};
        for (const s of rawSinks) idx[s.index] = s.name;
        sinkIndex = idx;

        const ins = {};
        for (const i of rawInputs) {
            const id = (i.properties || {})["object.id"];
            if (id !== undefined) ins[String(id)] = { index: i.index, sink: i.sink };
        }
        inputs = ins;

        const sidx = {};
        for (const s of rawSources) sidx[s.index] = s.name;
        sourceIndex = sidx;
        const outs = {};
        for (const o of rawOutputs) {
            const id = (o.properties || {})["object.id"];
            if (id !== undefined) outs[String(id)] = { index: o.index, source: o.source };
        }
        outputs = outs;
        if (pendingMoves.length > 0) runPendingMoves();
    }

    // Which microphone an app is recording from, by name; "" when unknown.
    function recorderSourceName(node) {
        const o = node ? outputs[String(node.id)] : null;
        return o ? (sourceIndex[o.source] || "") : "";
    }

    // Which output a stream is playing to, by name; "" when unknown.
    function streamSinkName(node) {
        const i = node ? inputs[String(node.id)] : null;
        return i ? (sinkIndex[i.sink] || "") : "";
    }

    // ── changing what pactl knows ────────────────────────────────────────
    // One at a time, in order: two clicks in quick succession are two
    // commands, and starting the second must not kill the first.
    property var actQueue: []
    Process {
        id: actProc
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") root.lastError = text.trim().split("\n").pop()
        }
        onExited: {
            if (root.actQueue.length > 0) root.nextAction();
            else root.refreshDetails();
        }
    }
    function nextAction() {
        const q = actQueue.slice();
        const cmd = q.shift();
        actQueue = q;
        actProc.command = cmd;
        actProc.running = true;
    }
    function pactl(args) {
        if (viaDaemon) {
            const a = args;
            const cmd = a[0] === "set-card-profile" ? { cmd: "pa-profile", card: a[1], profile: a[2] }
                : a[0] === "set-sink-port" ? { cmd: "pa-port", kind: "sink", name: a[1], port: a[2] }
                : a[0] === "set-source-port" ? { cmd: "pa-port", kind: "source", name: a[1], port: a[2] }
                : a[0] === "move-sink-input" ? { cmd: "pa-move-input", index: parseInt(a[1]), sink: a[2] }
                : a[0] === "move-source-output" ? { cmd: "pa-move-output", index: parseInt(a[1]), source: a[2] }
                : a[0] === "set-port-latency-offset" ? { cmd: "pa-latency", card: a[1], port: a[2], usec: parseInt(a[3]) }
                : null;
            if (cmd) { lastError = ""; Services.Daemon.send(cmd); return; }
        }
        if (pactlMissing) { lastError = "pactl isn't installed (it comes with pipewire-pulse)."; return; }
        lastError = "";
        actQueue = actQueue.concat([["pactl"].concat(args)]);
        if (!actProc.running) nextAction();
    }
    function setProfile(card, profile) { if (card) pactl(["set-card-profile", card.name, profile]); }
    function setPort(node, port) {
        if (node) pactl([node.isSink ? "set-sink-port" : "set-source-port", node.name, port]);
    }
    // Sound and picture out of step — usually Bluetooth: delays (or
    // advances) this device's sound. Kept per connector by PipeWire.
    function setLatencyOffset(node, ms) {
        const d = details(node);
        if (!d.card || !d.port) { lastError = "This device has no connector to set a delay on."; return; }
        pactl(["set-port-latency-offset", d.card.name, d.port.name, String(Math.round(ms * 1000))]);
    }
    function moveRecorder(stream, sourceNode) {
        if (!stream || !sourceNode) return;
        const o = outputs[String(stream.id)];
        if (!o) { deferMove("output", stream.id, sourceNode.name); return; }
        pactl(["move-source-output", String(o.index), sourceNode.name]);
    }

    // A move asked for before pactl's tables know the stream — a stream
    // that only just started, or nothing has read them yet. Read them,
    // then do it.
    property var pendingMoves: []
    function deferMove(kind, id, target) {
        pendingMoves = pendingMoves.concat([{ kind: kind, id: String(id), target: target, tries: 0 }]);
        refreshDetails();
    }
    function runPendingMoves() {
        const later = [];
        for (const m of pendingMoves) {
            const i = m.kind === "input" ? inputs[m.id] : outputs[m.id];
            if (i) pactl([m.kind === "input" ? "move-sink-input" : "move-source-output", String(i.index), m.target]);
            else if (m.tries < 3) later.push(Object.assign({}, m, { tries: m.tries + 1 }));
        }
        pendingMoves = later;
        if (later.length > 0) refreshDetails();
    }
    function moveStream(stream, sinkNode) {
        if (!stream || !sinkNode) return;
        const i = inputs[String(stream.id)];
        if (!i) { deferMove("input", stream.id, sinkNode.name); return; }
        pactl(["move-sink-input", String(i.index), sinkNode.name]);
    }

    // ── new devices ──────────────────────────────────────────────────────
    // Headphones paired or a USB headset plugged in become the device in
    // use, when Settings asks for that. Only Bluetooth and USB: a monitor
    // waking up announces an HDMI output every time, and nobody wants the
    // sound jumping to it.
    // What was there last time, per direction — so a device unplugged and
    // plugged back in counts as new again.
    property var knownSinks: []
    property var knownSources: []
    property bool devicesSettled: false
    Timer { interval: 5000; running: root.pipewireUp; onTriggered: root.devicesSettled = true }
    function considerNew(list, isSink) {
        const before = isSink ? knownSinks : knownSources;
        if (devicesSettled && Config.Appearance.soundAutoSwitch) {
            for (const n of list) {
                if (before.indexOf(n.name) >= 0) continue;
                const p = n.properties || {};
                const hint = ((p["device.bus"] || "") + " " + n.name).toLowerCase();
                if (!/bluez|bluetooth|usb/.test(hint)) continue;
                if (isSink) setDefaultSink(n); else setDefaultSource(n);
            }
        }
        if (isSink) knownSinks = list.map(n => n.name);
        else knownSources = list.map(n => n.name);
    }
    onSinksChanged: considerNew(sinks, true)
    onSourcesChanged: considerNew(sources, false)

    // ── sounds ───────────────────────────────────────────────────────────
    // From the freedesktop sound theme (sound-theme-freedesktop), played
    // straight at the device in question so a test of the HDMI output is not
    // heard from the speakers.
    Process { id: playProc }
    function play(node, file, pos) {
        const dir = "/usr/share/sounds/freedesktop/stereo/";
        const target = node ? node.name : "";
        const script =
            'd="' + dir + '"; f="$d$1.oga"; [ -r "$f" ] || f="$d$2.oga"; [ -r "$f" ] || f="$d"bell.oga; '
            + '[ -r "$f" ] || exit 3; '
            + 'if command -v pw-play >/dev/null 2>&1; then '
            + '  if [ -n "$4" ]; then pw-play ${3:+--target "$3"} --channel-map "$4" "$f" 2>/dev/null && exit 0; fi; '
            + '  exec pw-play ${3:+--target "$3"} "$f"; '
            + 'elif command -v paplay >/dev/null 2>&1; then exec paplay ${3:+-d "$3"} "$f"; fi; exit 3';
        playProc.running = false;
        playProc.command = ["sh", "-c", script, "play", file, "audio-test-signal", target, pos || ""];
        playProc.running = true;
    }
    function testSound(node) { play(node, "audio-test-signal", ""); }
    function testChannel(node, ch) { play(node, "audio-channel-" + ch.file, ch.pos); }

    // The little tick on a volume key, when asked for — at most a few a
    // second while the key repeats.
    Timer { id: feedbackGap; interval: 120 }
    function feedback() {
        if (!Config.Appearance.volumeFeedback || feedbackGap.running) return;
        feedbackGap.start();
        play(sink, "audio-volume-change", "");
    }

    // ── when it all goes wrong ───────────────────────────────────────────
    // A Bluetooth headset stuck in the wrong mode, a device that vanished
    // and came back mute, a session where PipeWire never came up: restarting
    // the three user services is the standard cure and costs a second of
    // silence.
    Process {
        id: restartProc
        command: ["systemctl", "--user", "restart", "wireplumber.service", "pipewire.service", "pipewire-pulse.service"]
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") root.lastError = text.trim().split("\n").pop()
        }
        onExited: code => { root.restarting = false; root.refreshDetails(); }
    }
    property bool restarting: false
    function restartAudio() {
        lastError = "";
        restarting = true;
        restartProc.running = true;
    }
}
