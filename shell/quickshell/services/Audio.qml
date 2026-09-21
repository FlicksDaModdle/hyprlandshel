pragma Singleton
import QtQuick
import Quickshell
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
        if (!ready) return;
        sink.audio.muted = !sink.audio.muted;
        Config.UiState.showOsd("volume", volume, sink.audio.muted);
    }

    function step(delta) {
        if (!ready) return;
        setVolume(volume + delta);
        Config.UiState.showOsd("volume", sink.audio.volume, sink.audio.muted);
    }

    function setInputVolume(v) {
        if (sourceReady) source.audio.volume = Math.max(0, Math.min(1, v));
    }

    function toggleInputMute() {
        if (!sourceReady) return;
        source.audio.muted = !source.audio.muted;
        Config.UiState.showOsd("mic", inputVolume, source.audio.muted);
    }

    function setDefaultSink(node) {
        Pipewire.preferredDefaultAudioSink = node;
    }

    function displayName(node) {
        if (!node) return "";
        return node.nickname || node.description || node.name || "";
    }
}
