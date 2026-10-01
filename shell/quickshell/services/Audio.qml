pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../config" as Config

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

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource
    // false only when the binding says so outright: older Quickshell builds
    // have no `ready`, and undefined is not a reason to say audio is down.
    readonly property bool pipewireUp: Pipewire.ready !== false

    // Node properties (volume/mute) are only live while the node is bound.
    // Either default can be null before PipeWire is up, so the list is
    // filtered rather than handed nulls.
    PwObjectTracker {
        objects: [root.sink, root.source].filter(n => n !== null && n !== undefined)
    }

    // The ceiling a drag or a volume key can reach. PipeWire happily takes
    // more than 1.0 (software boost); unless that is asked for in Settings
    // the shell stops at 100% so a stray drag can't blow your ears out.
    readonly property real maxVolume: Config.Appearance.volumeBoost ? 1.5 : 1.0

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
    readonly property var sinks: nodes.filter(n => n.isSink && !n.isStream)
    readonly property var sources: nodes.filter(n => !n.isSink && !n.isStream)
    // Applications playing, and applications recording.
    readonly property var streams: nodes.filter(n => n.isSink && n.isStream && !isMonitor(n))
    readonly property var recorders: nodes.filter(n => !n.isSink && n.isStream && !isMonitor(n))

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

    function setDefaultSink(node) {
        if (node) Pipewire.preferredDefaultAudioSink = node;
    }
    function setDefaultSource(node) {
        if (node) Pipewire.preferredDefaultAudioSource = node;
    }

    function displayName(node) {
        if (!node) return "";
        return node.nickname || node.description || node.name || "";
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
    property bool pactlMissing: false
    property string lastError: ""

    // How many open things want the details kept fresh. watch(true) on
    // opening, watch(false) on closing; the subscription runs while any do.
    property int watchers: 0
    function watch(on) {
        watchers = Math.max(0, watchers + (on ? 1 : -1));
        if (on) refreshDetails();
    }

    function details(node) {
        if (!node) return {};
        const table = node.isSink ? pulse.sinks : pulse.sources;
        const d = table[node.name];
        if (!d) return {};
        const card = cards.find(c => (d.card >= 0 && c.index === d.card)
                                  || (d.deviceId !== "" && c.objectId === d.deviceId)) || null;
        const port = (d.ports || []).find(pt => pt.name === d.activePort) || null;
        return { ports: d.ports || [], activePort: d.activePort, port: port, card: card };
    }

    function refreshDetails() { detailsDebounce.restart(); }
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
        running: root.watchers > 0 && !root.pactlMissing && root.pipewireUp && root.subscribeEpoch >= 0
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
            + "for w in cards sinks sources sink-inputs; do pactl -f json list $w 2>/dev/null || echo '[]'; echo; echo '@@'; done"]
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
        const rawCards = parse(parts[0] || ""), rawSinks = parse(parts[1] || ""),
              rawSources = parse(parts[2] || ""), rawInputs = parse(parts[3] || "");

        cards = rawCards.map(c => {
            const p = c.properties || {};
            return {
                index: c.index,
                name: c.name,
                description: p["device.description"] || p["device.product.name"] || c.name,
                objectId: String(p["object.id"] || ""),
                activeProfile: c.active_profile || "",
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
    }

    // Which output a stream is playing to, by name; "" when unknown.
    function streamSinkName(node) {
        const i = node ? inputs[String(node.id)] : null;
        return i ? (sinkIndex[i.sink] || "") : "";
    }

    // ── changing what pactl knows ────────────────────────────────────────
    Process {
        id: actProc
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") root.lastError = text.trim().split("\n").pop()
        }
        onExited: root.refreshDetails()
    }
    function pactl(args) {
        if (pactlMissing) { lastError = "pactl isn't installed (it comes with pipewire-pulse)."; return; }
        lastError = "";
        actProc.running = false;
        actProc.command = ["pactl"].concat(args);
        actProc.running = true;
    }
    function setProfile(card, profile) { if (card) pactl(["set-card-profile", card.name, profile]); }
    function setPort(node, port) {
        if (node) pactl([node.isSink ? "set-sink-port" : "set-source-port", node.name, port]);
    }
    function moveStream(stream, sinkNode) {
        const i = stream ? inputs[String(stream.id)] : null;
        if (!i || !sinkNode) { lastError = "Couldn't find that stream to move it."; return; }
        pactl(["move-sink-input", String(i.index), sinkNode.name]);
    }

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
