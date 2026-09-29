pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Live wallpapers — Wallpaper Engine's, drawn by linux-wallpaperengine.
//
// It is a separate program that puts its own surface on each output, so
// the shell's part is to find the wallpapers, start it with the one you
// chose, and keep it running. Settings → Appearance → Live wallpaper is
// the picker.
//
// Where it sits. linux-wallpaperengine draws on the layer above the
// shell's own ground (Wallpaper.qml), which stays underneath it: the
// gradient or image is what shows while a wallpaper loads, and what comes
// back if it stops. With the mouse off, its surface takes no input at all —
// Hyprland passes a click on a surface with an empty input region to the
// one below it — so right-clicking the desktop still opens the shell's
// menu. With the mouse on, the wallpaper gets the pointer for its parallax
// and cursor effects, and the desktop underneath gets nothing.
//
// The wallpapers are the ones you have subscribed to in Wallpaper Engine's
// Workshop on Steam, plus its own bundled and made-by-you projects — found
// in every Steam library, not only the default one. Most of them also need
// Wallpaper Engine itself installed, for its shared assets.
Singleton {
    id: root

    readonly property string binary: "linux-wallpaperengine"

    // ── what there is ─────────────────────────────────────────────────────
    property bool installed: false
    property bool hasAssets: false
    property bool scanning: false
    // [{ dir, id, title, preview, type }], by title.
    property var wallpapers: []

    // ── what is running ───────────────────────────────────────────────────
    readonly property string chosen: Config.Appearance.liveWallpaper
    readonly property bool enabled: chosen !== ""
    readonly property bool running: proc.running
    // Why it is not running, when it should be: the last thing it said.
    property string error: ""

    readonly property var current: {
        for (const w of root.wallpapers)
            if (w.dir === root.chosen || w.id === root.chosen) return w;
        return null;
    }
    readonly property string currentTitle: current ? current.title
        : (chosen === "" ? "" : chosen.replace(/\/+$/, "").split("/").pop())

    // ── finding them ──────────────────────────────────────────────────────
    // Every Steam library, from each Steam install's libraryfolders.vdf,
    // resolved so the ~/.steam/steam symlink does not list everything twice.
    // Each wallpaper folder is printed as a record-separator line with its
    // path, then its project.json, which is parsed here rather than asking
    // for jq or python.
    Process {
        id: scanProc
        command: ["sh", "-c", `
            command -v ${root.binary} >/dev/null 2>&1 && echo installed
            for base in "$HOME/.steam/steam" "$HOME/.local/share/Steam" \\
                        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \\
                        "$HOME/snap/steam/common/.local/share/Steam"; do
                [ -d "$base/steamapps" ] || continue
                printf '%s\\n' "$base"
                vdf="$base/steamapps/libraryfolders.vdf"
                [ -f "$vdf" ] && sed -n 's/^[[:space:]]*"path"[[:space:]]*"\\(.*\\)"[[:space:]]*$/\\1/p' "$vdf"
            done | while IFS= read -r lib; do
                readlink -f "$lib" 2>/dev/null
            done | sort -u | while IFS= read -r lib; do
                we="$lib/steamapps/common/wallpaper_engine"
                [ -d "$we/assets" ] && echo assets
                for d in "$lib"/steamapps/workshop/content/431960/*/ \\
                         "$we"/projects/defaultprojects/*/ "$we"/projects/myprojects/*/; do
                    [ -f "$d/project.json" ] || continue
                    printf '\\036%s\\n' "\${d%/}"
                    cat "$d/project.json"
                    printf '\\n'
                done
            done`]
        stdout: StdioCollector {
            onStreamFinished: root.parseScan(text)
        }
        onExited: root.scanning = false
    }

    function scan() {
        if (scanProc.running) return;
        root.scanning = true;
        scanProc.running = true;
    }

    function parseScan(text) {
        const records = text.split("\x1e");
        const head = records.shift();
        root.installed = /^installed$/m.test(head);
        let assets = /^assets$/m.test(head);
        const seen = {};
        const found = [];
        for (const rec of records) {
            const nl = rec.indexOf("\n");
            if (nl < 0) continue;
            const dir = rec.slice(0, nl);
            let body = rec.slice(nl + 1);
            // "assets" for the next library is printed after this record's
            // JSON, on its own line, so it is peeled off the end.
            if (/\nassets\s*$/.test(body)) { assets = true; body = body.replace(/\nassets\s*$/, ""); }
            if (seen[dir]) continue;
            seen[dir] = true;
            let p;
            // Wallpaper Engine writes some of these with a byte-order mark,
            // which JSON.parse refuses.
            try { p = JSON.parse(body.replace(/^\uFEFF/, "")); } catch (e) { continue; }
            const type = String(p.type || "").toLowerCase();
            // "application" wallpapers are Windows programs; there is
            // nothing linux-wallpaperengine can do with them.
            if (type === "application") continue;
            const id = dir.split("/").pop();
            found.push({
                dir: dir,
                id: id,
                title: String(p.title || id),
                preview: p.preview ? dir + "/" + p.preview : "",
                type: type || "scene"
            });
        }
        found.sort((a, b) => a.title.localeCompare(b.title));
        root.hasAssets = assets;
        root.wallpapers = found;
    }

    // ── running it ────────────────────────────────────────────────────────
    // One --screen-root per output, so each gets the wallpaper at its own
    // size. Without one linux-wallpaperengine opens an ordinary window.
    readonly property var screenNames: Quickshell.screens.map(s => s.name).filter(n => !!n)

    readonly property var args: {
        if (!root.enabled || root.screenNames.length === 0) return [];
        const a = ["--fps", String(Config.Appearance.liveFps)];
        if (!Config.Appearance.liveSound) a.push("--silent");
        if (!Config.Appearance.liveMouse) a.push("--disable-mouse", "--disable-parallax");
        for (const n of root.screenNames)
            a.push("--screen-root", n, "--scaling", "fill", "--bg", root.chosen);
        return a;
    }

    // The last few lines it wrote to stderr, for when it stops.
    property var tail: []
    property real startedAt: 0
    property int quickFailures: 0
    // Set while the shell itself is stopping or restarting it, so that exit
    // is not taken for a crash.
    property bool stopping: false

    Process {
        id: proc
        // Anything left from a shell that did not get to stop it — a crash,
        // a reload that raced — is stopped first, or there would be two
        // wallpapers fighting over each output. `exec` so that stopping
        // this process stops the wallpaper, not just a shell around it.
        //
        // comm is the first 15 characters of the program name.
        command: ["sh", "-c",
            "pkill -x linux-wallpaper; i=0; "
            + "while pgrep -x linux-wallpaper >/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done; "
            + "exec " + root.binary + " \"$@\"", "sh"].concat(root.args)
        stderr: SplitParser {
            onRead: line => {
                const t = root.tail.slice(-4);
                t.push(line);
                root.tail = t;
            }
        }
        onStarted: {
            root.startedAt = Date.now();
            root.error = "";
        }
        onExited: (code, status) => {
            if (root.stopping) { root.stopping = false; return; }
            if (!root.enabled) return;
            const last = root.tail.filter(l => l.trim() !== "").pop() || "";
            // One that ran for a while and then died (a driver reset, a
            // suspend it did not survive) is started again. One that dies
            // straight away will do so every time — a wallpaper it cannot
            // draw, assets it cannot find — and is left stopped, with what
            // it said.
            if (Date.now() - root.startedAt > 20000) root.quickFailures = 0;
            else root.quickFailures++;
            if (root.quickFailures >= 2) {
                root.error = last || ("it exited with code " + code);
                return;
            }
            retry.restart();
        }
    }

    Timer { id: retry; interval: 2000; onTriggered: root.restart() }

    // Output changes arrive as a burst — a monitor re-enumerating removes
    // and adds — so the restart waits for them to settle.
    Timer { id: settle; interval: 600; onTriggered: root.restart() }
    onArgsChanged: settle.restart()

    function restart() {
        retry.stop();
        if (!Config.Appearance.settingsReady) return;
        // With none chosen, one the shell did not start is left alone — it
        // may be yours, from hyprland.lua.
        if (root.args.length === 0) {
            if (proc.running) { root.stopping = true; proc.running = false; }
            return;
        }
        root.tail = [];
        root.error = "";
        // It maps once, so the rule only has to be there before it starts.
        // Sent every time because a config reload drops runtime rules.
        Services.Compositor.evalLua('hl.layer_rule({ name = "wallpaper-live-fade", '
            + 'match = { namespace = "^linux-wallpaperengine$" }, animation = "fade" })');
        if (proc.running) {
            root.stopping = true;
            proc.running = false;
        }
        // Setting running while the old one is still exiting is picked up
        // when it has gone (Process starts it from onFinished).
        proc.running = true;
    }

    // Choosing one again after it failed gets a fresh start.
    function choose(dirOrId) {
        root.quickFailures = 0;
        root.error = "";
        if (Config.Appearance.liveWallpaper === dirOrId) root.restart();
        else Config.Appearance.liveWallpaper = dirOrId;
    }

    function stop() { Config.Appearance.liveWallpaper = ""; }

    // theme.json is read asynchronously, so the choice is not known until
    // it has been; starting on the default would stop the wallpaper and
    // start it again a moment later.
    Connections {
        target: Config.Appearance
        function onSettingsReadyChanged() { if (Config.Appearance.settingsReady) settle.restart(); }
    }

    Component.onCompleted: {
        root.scan();
        if (Config.Appearance.settingsReady) settle.restart();
    }
}
