pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import "." as Services

// What is using the microphone, the camera and the screen right now.
//
//   microphone  PipeWire audio-input streams. Not ones recording a
//               speaker's monitor (visualisers), PipeWire's and
//               WirePlumber's own, or the shell's level meters.
//   camera      PipeWire video streams reading a camera, plus apps that
//               open /dev/video* directly — most browsers do — which
//               hyprshell-daemon finds (rust/daemon/src/camera.rs).
//   screen      Hyprland's screencast event (the portal sharing a screen
//               or a window), and the PipeWire streams reading it, for
//               who is watching.
//
// Each is a list of app names; the bar shows a dot while any is in use.
Singleton {
    id: root

    // Every stream and video node bound, so its properties (the app's
    // name, what it records from) can be read. There are few of them.
    readonly property var candidates: Pipewire.nodes.values.filter(n => n && (n.isStream || n.type === 0
        || n.type === PwNodeType.VideoSource))
    PwObjectTracker { objects: root.candidates }

    function cls(n) { return (n.properties || {})["media.class"] || ""; }
    function appOf(n) {
        const p = n.properties || {};
        return p["application.name"] || p["application.process.binary"] || n.description || n.name || "An app";
    }
    function processOf(n) { return ((n.properties || {})["application.process.binary"] || "").toLowerCase(); }
    readonly property var system: ["pipewire", "wireplumber", "quickshell", "qs", "hyprshell-daemon"]

    // What a stream is reading from, by its links.
    function sourcesOf(n) {
        return Pipewire.links.values.filter(l => l && l.target === n && l.source).map(l => l.source);
    }

    readonly property var micApps: {
        const out = [];
        for (const n of candidates) {
            if (cls(n) !== "Stream/Input/Audio") continue;
            const p = n.properties || {};
            if (p["stream.capture.sink"] === "true" || p["stream.monitor"] === "true") continue;
            if (system.indexOf(processOf(n)) >= 0 || Services.Audio.isOurs(n)) continue;
            // Recording a speaker's monitor rather than a microphone.
            if (sourcesOf(n).some(s => s.isSink || (s.name || "").endsWith(".monitor"))) continue;
            const a = appOf(n);
            if (out.indexOf(a) < 0) out.push(a);
        }
        return out;
    }

    // Video sources that are the screen: the portal's, or one a capture
    // program offers under a name that says so.
    function isScreen(src) {
        const p = src.properties || {};
        const name = (src.name || "").toLowerCase();
        return name.indexOf("xdph") >= 0 || name.indexOf("screencast") >= 0
            || (p["media.role"] || "") === "Screen" || name.indexOf("screen") >= 0;
    }

    readonly property var pwCameraApps: {
        const out = [];
        for (const n of candidates) {
            if (cls(n) !== "Stream/Input/Video") continue;
            if (system.indexOf(processOf(n)) >= 0) continue;
            const srcs = sourcesOf(n);
            if (srcs.length > 0 && srcs.every(s => isScreen(s))) continue;
            const a = appOf(n);
            if (out.indexOf(a) < 0) out.push(a);
        }
        return out;
    }
    // From the daemon: [{ pid, name }].
    property var v4lApps: []
    readonly property var cameraApps: {
        const out = pwCameraApps.slice();
        for (const a of v4lApps) if (out.indexOf(a.name) < 0) out.push(a.name);
        return out;
    }

    readonly property var pwScreenApps: {
        const out = [];
        for (const n of candidates) {
            if (cls(n) !== "Stream/Input/Video") continue;
            const srcs = sourcesOf(n);
            if (srcs.length === 0 || !srcs.some(s => isScreen(s))) continue;
            const a = appOf(n);
            if (out.indexOf(a) < 0) out.push(a);
        }
        return out;
    }
    // Hyprland's own word: screencast>>1,0 (a monitor) or >>1,1 (a window).
    property bool hyprSharing: false
    property string hyprShareKind: ""
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name !== "screencast") return;
            const parts = String(event.data || "").split(",");
            root.hyprSharing = parts[0] === "1";
            root.hyprShareKind = parts[1] === "1" ? "a window" : parts[1] === "0" ? "a screen" : "";
        }
    }
    readonly property bool sharing: hyprSharing || pwScreenApps.length > 0
    readonly property var screenApps: pwScreenApps.length > 0 ? pwScreenApps
                                    : (hyprSharing ? ["Sharing " + (hyprShareKind || "the screen")] : [])

    readonly property bool mic: micApps.length > 0
    readonly property bool camera: cameraApps.length > 0
    readonly property bool any: mic || camera || sharing

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "camera") root.v4lApps = ev.apps || [];
            else if (ev.ev === "exited") root.v4lApps = [];
        }
    }
}
