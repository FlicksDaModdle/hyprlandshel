pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config
import "." as Services

// Clipboard history, kept by hyprshell-daemon (rust/daemon/src/clip.rs)
// from the compositor's clipboard-manager protocol: everything copied,
// newest first, to put back with Super+Shift+V or the launcher's
// "Clipboard history".
//
// The daemon keeps it in $XDG_RUNTIME_DIR — memory, this login only — so
// a shell reload keeps it and logging out ends it. What a password manager
// marks as secret is never kept. Switching it off in Settings forgets
// everything.
//
// Without the daemon there is no history: `available` stays false and the
// panel says why.
Singleton {
    id: root

    readonly property bool enabled: Config.Appearance.clipboardHistory
    readonly property bool daemonHas: Services.Daemon.running && Services.Daemon.modules.clip === true
    property bool available: false
    property string error: ""
    // [{ id, kind: "text" | "image", preview, lines, size, time, path }]
    property var entries: []

    function copy(id) { Services.Daemon.send({ cmd: "clip-copy", id: id }); }
    function remove(id) {
        root.entries = root.entries.filter(e => e.id !== id);
        Services.Daemon.send({ cmd: "clip-delete", id: id });
    }
    function clear() {
        root.entries = [];
        Services.Daemon.send({ cmd: "clip-clear" });
    }

    function tell() {
        if (root.daemonHas)
            Services.Daemon.send({ cmd: "clip-enable", on: root.enabled,
                                   max: Math.max(5, Config.Appearance.clipboardMax) });
    }
    onEnabledChanged: tell()
    onDaemonHasChanged: tell()
    readonly property int max: Config.Appearance.clipboardMax
    onMaxChanged: tell()

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "clip") {
                root.available = ev.available === true;
                root.error = ev.error || "";
                root.entries = ev.enabled ? (ev.entries || []) : [];
            } else if (ev.ev === "exited") {
                root.available = false;
            }
        }
    }

    // "2 min ago", for the panel.
    function age(t) {
        const s = Math.max(0, Math.floor(Date.now() / 1000) - t);
        if (s < 45) return "just now";
        if (s < 3600) return Math.round(s / 60) + " min ago";
        if (s < 86400) return Math.round(s / 3600) + " h ago";
        return Math.round(s / 86400) + " d ago";
    }
    function sizeText(n) {
        if (n < 1024) return n + " B";
        if (n < 1048576) return (n / 1024).toFixed(0) + " KB";
        return (n / 1048576).toFixed(1) + " MB";
    }
}
