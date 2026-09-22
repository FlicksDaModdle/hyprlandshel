pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../config" as Config

// PipeWire audio: default sink/source volume and mute, plus the sink list
// the control center's "Output device" row and Settings → Sound switch
// between. Drives the mockup's bar volume readout, the CC sliders and the
// volume OSD.
Singleton {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource

    // Node properties (volume/mute) are only live while the node is bound.
    // Either default can be null before PipeWire is up, so the list is
    // filtered rather than handed nulls.
    PwObjectTracker {
        objects: [root.sink, root.source].filter(n => n !== null && n !== undefined)
    }

    readonly property bool ready: !!sink && !!sink.audio
    readonly property real volume: ready ? sink.audio.volume : 0
    readonly property bool muted: ready ? sink.audio.muted : false
    readonly property int volumePercent: Math.round(volume * 100)

    readonly property bool sourceReady: !!source && !!source.audio
    readonly property real inputVolume: sourceReady ? source.audio.volume : 0
    readonly property bool inputMuted: sourceReady ? source.audio.muted : false
    readonly property int inputPercent: Math.round(inputVolume * 100)

    readonly property string sinkName: sink ? (sink.nickname || sink.description || sink.name || "") : ""
    readonly property string sourceName: source ? (source.nickname || source.description || source.name || "") : ""

    // Real output devices, minus per-application streams.
    readonly property var sinks: Pipewire.nodes.values.filter(n => n.isSink && !n.isStream)
    readonly property var sources: Pipewire.nodes.values.filter(n => !n.isSink && !n.isStream && n.audio)

    // Glyph that matches the current level, like the mockup's volume-2 /
    // volume-1 / volume-x set.
    readonly property string icon: muted || volume <= 0.001 ? "volumeX"
                                 : (volume < 0.5 ? "volumeLow" : "volume")

    function setVolume(v) {
        if (!ready) return;
        // PipeWire happily accepts >1.0 (software boost); the shell caps at
        // 100% so a stray drag can't blow your ears out.
        sink.audio.volume = Math.max(0, Math.min(1, v));
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

    function step(delta) {
        const pct = Math.round(Math.abs(delta) * 100);
        if (ready) {
            setVolume(volume + delta);
            Config.UiState.showOsd("volume", sink.audio.volume, sink.audio.muted);
            return;
        }
        const dir = delta > 0 ? "+" : "-";
        fallbackRun({
            // -l caps software boost at 100%, matching setVolume's own clamp.
            wp: "set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ " + pct + "%" + dir,
            pa: "set-sink-volume @DEFAULT_SINK@ " + dir + pct + "%"
        });
        const shown = Math.max(0, Math.min(1, fallbackVolume + delta));
        fallbackVolume = shown;
        Config.UiState.showOsd("volume", shown, fallbackMuted);
    }

    function setInputVolume(v) {
        if (sourceReady) source.audio.volume = Math.max(0, Math.min(1, v));
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
        Pipewire.preferredDefaultAudioSink = node;
    }

    function displayName(node) {
        if (!node) return "";
        return node.nickname || node.description || node.name || "";
    }
}
