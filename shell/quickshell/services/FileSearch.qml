pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config
import "." as Services

// Files in the launcher's results: names under your home folder, matched
// as you type by hyprshell-daemon (rust/daemon/src/fsearch.rs), which
// indexes when the launcher opens and lets the index go after ten idle
// minutes. Hidden folders, node_modules, caches and the like are left out.
//
// Without the daemon, or with Settings → Launcher → "Search files" off,
// `results` stays empty and the launcher shows apps and commands only.
Singleton {
    id: root

    readonly property bool enabled: Config.Appearance.launcherFiles
    readonly property bool available: Services.Daemon.running && Services.Daemon.modules.files === true
    readonly property string home: Quickshell.env("HOME") || ""

    property string query: ""
    // [{ path (relative to home), name, dir, isDir }]
    property var results: []
    property bool indexing: false
    property int lastId: 0

    function tell() {
        if (root.available) Services.Daemon.send({ cmd: "fs-config", on: root.enabled });
    }
    onEnabledChanged: { tell(); if (!enabled) results = []; }
    onAvailableChanged: tell()

    // The launcher opened: get the index ready before the first key.
    function warm() {
        if (root.enabled && root.available) Services.Daemon.send({ cmd: "fs-warm" });
    }

    function search(q) {
        root.query = q;
        if (!root.enabled || !root.available || q.trim().length < 2) {
            root.results = [];
            return;
        }
        soon.restart();
    }
    // Typing fast sends the last query, not every one.
    Timer {
        id: soon
        interval: 70
        onTriggered: {
            root.lastId++;
            Services.Daemon.send({ cmd: "fs-search", id: root.lastId, query: root.query, limit: 6 });
        }
    }

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev !== "fs-results") return;
            // Only the answer to what is in the box now; and a later answer
            // to the same question (the index finished) replaces it.
            if (ev.query !== root.query) return;
            root.results = ev.results || [];
            root.indexing = ev.indexing === true;
        }
    }

    function absolute(rel) { return root.home + "/" + rel; }
    // "~/Documents/Taxes", for the result's second line.
    function where(r) { return r.dir === "" ? "~" : "~/" + r.dir; }

    // A folder opens in the shell's Files; a file in whatever opens it.
    function open(r) {
        if (r.isDir) Config.Apps.launchFiles(root.absolute(r.path));
        else Config.Apps.launch(["xdg-open", root.absolute(r.path)]);
    }

    // The pack's glyph for a kind of file.
    function icon(r) {
        if (r.isDir) return "folder";
        const ext = (r.name.lastIndexOf(".") > 0 ? r.name.slice(r.name.lastIndexOf(".") + 1) : "").toLowerCase();
        if (["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "bmp", "tiff"].indexOf(ext) >= 0) return "image";
        if (["mp4", "mkv", "webm", "mov", "avi"].indexOf(ext) >= 0) return "film";
        if (["mp3", "flac", "ogg", "opus", "wav", "m4a"].indexOf(ext) >= 0) return "music";
        if (["zip", "tar", "gz", "xz", "zst", "7z", "rar", "deb", "rpm"].indexOf(ext) >= 0) return "package";
        if (["c", "cpp", "h", "hpp", "rs", "py", "js", "ts", "qml", "lua", "sh", "go", "java", "json", "toml", "yaml", "yml", "html", "css"].indexOf(ext) >= 0) return "code";
        return "file";
    }
}
