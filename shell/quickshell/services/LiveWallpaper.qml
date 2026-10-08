pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "../config" as Config
import "." as Services

// Live wallpapers: a video playing on the desktop, by mpvpaper.
//
// mpvpaper is mpv on a layer surface — the video decoded by the graphics
// card's own decoder (hwdec), which is the cheapest way there is to put
// something moving on a desktop: a looping clip costs a few percent of one
// core and hardly wakes the GPU. The shell finds the videos, starts it with
// the one chosen and keeps it running; Settings → Wallpaper is the picker.
//
// Where it sits. mpvpaper draws on the bottom layer, above the shell's own
// ground (Wallpaper.qml), which stays underneath: the gradient or image is
// what shows while a video loads, and what comes back if it stops. Its
// surface takes no input — Hyprland passes a click on a surface with an
// empty input region to the one below — so right-clicking the desktop still
// opens the shell's menu.
//
// The videos are the ones in the folders listed in Settings (by default
// ~/Videos/Wallpapers, and a level of subfolders in each), plus single
// files added there. Wallpaper Engine's video wallpapers are plain video
// files in their Workshop folders, so adding
// …/steamapps/workshop/content/431960 lists those too.
Singleton {
    id: root

    readonly property string binary: "mpvpaper"
    readonly property string home: Quickshell.env("HOME")
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || root.home + "/.cache")
                                       + "/hyprshell/live"
    readonly property string defaultFolder: root.home + "/Videos/Wallpapers"

    // ── what there is ─────────────────────────────────────────────────────
    property bool installed: false
    property bool hasFfmpeg: false
    property bool scanning: false
    property bool scanned: false
    // [{ dir, title, preview }], by title. `dir` is the video's path — the
    // name is the gallery's, which is shared with other pickers.
    property var wallpapers: []

    readonly property var folders: {
        try {
            const a = JSON.parse(Config.Appearance.liveFolders || "null");
            if (Array.isArray(a)) return a.filter(x => typeof x === "string" && x !== "");
        } catch (e) {}
        return [root.defaultFolder];
    }
    readonly property var files: {
        try {
            const a = JSON.parse(Config.Appearance.liveFiles || "[]");
            return Array.isArray(a) ? a.filter(x => typeof x === "string" && x !== "") : [];
        } catch (e) { return []; }
    }
    function addFolder(dir) {
        dir = String(dir || "").replace(/\/+$/, "");
        if (dir === "" || root.folders.indexOf(dir) >= 0) return;
        Config.Appearance.liveFolders = JSON.stringify(root.folders.concat([dir]));
        Qt.callLater(root.scan);
    }
    function removeFolder(dir) {
        Config.Appearance.liveFolders = JSON.stringify(root.folders.filter(d => d !== dir));
        Qt.callLater(root.scan);
    }
    function addFile(path) {
        if (!root.isVideo(path) || root.files.indexOf(path) >= 0) return;
        Config.Appearance.liveFiles = JSON.stringify(root.files.concat([path]));
        Qt.callLater(root.scan);
    }
    function resetSources() {
        Config.Appearance.liveFolders = "";
        Config.Appearance.liveFiles = "";
        Qt.callLater(root.scan);
    }

    readonly property var videoExt: /\.(mp4|m4v|webm|mkv|mov|avi|ogv|gif)$/i
    function isVideo(p) { return root.videoExt.test(String(p || "")); }

    // ── finding them ──────────────────────────────────────────────────────
    // Prints "V<tab>path<tab>thumbnail" for each video, the thumbnail empty
    // while there is none yet, and "T<tab>path<tab>thumbnail" for each one
    // still to make. A thumbnail is named by the checksum of the video's
    // path, so it survives a rescan and needs no index.
    Process {
        id: scanProc
        command: ["sh", "-c", `
            command -v ${root.binary} >/dev/null 2>&1 && echo installed
            command -v ffmpeg >/dev/null 2>&1 && echo ffmpeg
            thumbs=$1 n=$2; shift 2
            mkdir -p "$thumbs"
            list() {
                i=0
                for f in "$@"; do
                    i=$((i + 1))
                    if [ $i -le $n ]; then
                        [ -d "$f" ] && find -L "$f" -maxdepth 2 -type f \\( -iname '*.mp4' -o -iname '*.m4v' \\
                            -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.avi' \\
                            -o -iname '*.ogv' -o -iname '*.gif' \\) 2>/dev/null
                    else
                        [ -f "$f" ] && printf '%s\\n' "$f"
                    fi
                done
            }
            list "$@" | while IFS= read -r v; do
                t="$thumbs/$(printf '%s' "$v" | cksum | cut -d' ' -f1).jpg"
                if [ -s "$t" ]; then printf 'V\\t%s\\t%s\\n' "$v" "$t"
                else printf 'V\\t%s\\t\\n' "$v"; printf 'T\\t%s\\t%s\\n' "$v" "$t"; fi
            done`, "sh", root.cacheDir + "/thumbs", String(root.folders.length)]
            .concat(root.folders).concat(root.files)
        stdout: StdioCollector { onStreamFinished: root.parseScan(text) }
        onExited: root.scanning = false
    }
    function scan() {
        if (scanProc.running) return;
        root.scanning = true;
        scanProc.running = true;
    }
    function parseScan(text) {
        const found = [], seen = {}, todo = [];
        let inst = false, ff = false;
        for (const line of text.split("\n")) {
            if (line === "installed") { inst = true; continue; }
            if (line === "ffmpeg") { ff = true; continue; }
            const p = line.split("\t");
            if (p.length < 3) continue;
            if (p[0] === "T") { todo.push(p[1], p[2]); continue; }
            if (p[0] !== "V" || seen[p[1]]) continue;
            seen[p[1]] = true;
            const name = p[1].split("/").pop().replace(/\.[^.]+$/, "");
            found.push({ dir: p[1], title: name.replace(/[_]+/g, " "), preview: p[2] });
        }
        found.sort((a, b) => a.title.localeCompare(b.title));
        root.installed = inst;
        root.hasFfmpeg = ff;
        root.wallpapers = found;
        root.scanned = true;
        if (ff && todo.length > 0 && !thumbProc.running) {
            thumbProc.command = thumbProc.script.concat(todo);
            thumbProc.running = true;
        }
    }

    // A frame a second in, a still for the gallery; the first frame when
    // the video is shorter than that. Then a rescan picks them up.
    Process {
        id: thumbProc
        readonly property var script: ["nice", "-n", "15", "sh", "-c", `
            made=0
            while [ $# -ge 2 ]; do
                v=$1 t=$2; shift 2
                ffmpeg -nostdin -loglevel error -ss 1 -i "$v" -frames:v 1 -vf scale=360:-2 -y "$t" 2>/dev/null
                [ -s "$t" ] || ffmpeg -nostdin -loglevel error -i "$v" -frames:v 1 -vf scale=360:-2 -y "$t" 2>/dev/null
                [ -s "$t" ] && made=1
            done
            echo $made`, "sh"]
        stdout: StdioCollector { onStreamFinished: if (text.trim() === "1") Qt.callLater(root.scan) }
    }

    // ── what is on screen ─────────────────────────────────────────────────
    readonly property string chosen: Config.Appearance.liveWallpaper
    // Only a video: what was chosen before this was mpvpaper's (a Wallpaper
    // Engine folder) is not something it can play.
    readonly property bool enabled: root.chosen !== "" && root.isVideo(root.chosen)

    function find(path) {
        if (!path) return null;
        for (const w of root.wallpapers)
            if (w.dir === path) return w;
        return null;
    }
    readonly property var current: root.find(root.chosen)
    readonly property string currentTitle: current ? current.title
        : (chosen === "" ? "" : chosen.split("/").pop().replace(/\.[^.]+$/, ""))

    // HYPRSHELL_LIVE_SCREENS, a comma-separated list of output names, stands
    // in for the real ones — for trying the layouts on one screen.
    readonly property var screenNames: {
        const fake = Quickshell.env("HYPRSHELL_LIVE_SCREENS");
        if (fake) return fake.split(",").filter(n => !!n);
        return Quickshell.screens.map(s => s.name).filter(n => !!n);
    }

    // A video per screen, { "<output>": "<video>" }, for "each".
    readonly property var screenMap: {
        try { return JSON.parse(Config.Appearance.liveScreens || "{}") || {}; }
        catch (e) { return {}; }
    }
    readonly property string layout: root.screenNames.length > 1 && Config.Appearance.liveLayout === "each"
                                     ? "each" : "same"
    function wallpaperFor(screen) {
        const v = root.screenMap[screen];
        return root.layout === "each" && v && root.isVideo(v) ? v : root.chosen;
    }
    function chooseFor(screen, path) {
        const m = JSON.parse(JSON.stringify(root.screenMap));
        if (path) m[screen] = path; else delete m[screen];
        Config.Appearance.liveScreens = JSON.stringify(m);
        root.error = "";
    }

    // ── running it ────────────────────────────────────────────────────────
    // mpv's own options. Hardware decoding where it is safe, the "fast"
    // profile (no expensive scalers — a wallpaper is not a film), looped.
    readonly property string mpvOptions: {
        const A = Config.Appearance;
        const o = ["hwdec=auto-safe", "profile=fast", "loop", "keep-open=yes"];
        if (!A.liveSound || A.liveVolume <= 0) o.push("no-audio");
        else o.push("volume=" + Math.round(A.liveVolume));
        // Fill crops to the screen; fit leaves bars; stretch ignores the
        // video's shape.
        if (A.liveScaling === "fit") o.push("panscan=0.0");
        else if (A.liveScaling === "stretch") o.push("keepaspect=no");
        else o.push("panscan=1.0");
        return o.join(" ");
    }

    // What to run: one mpvpaper for every screen when they all show the same
    // video — one decode, drawn to each, and a monitor plugged in later gets
    // it too — or one per screen. "output\u0001video" each.
    readonly property var launches: {
        if (!root.enabled || !root.installed) return [];
        if (root.layout === "same") return ["*\u0001" + root.chosen];
        return root.screenNames.map(n => n + "\u0001" + root.wallpaperFor(n));
    }

    // Why one is not running, when it should be: the last thing it said.
    property string error: ""
    property int runningCount: 0
    readonly property bool running: root.runningCount > 0

    Variants {
        model: root.launches

        Scope {
            id: launch
            required property string modelData
            readonly property string output: modelData.split("\u0001")[0]
            readonly property string video: modelData.split("\u0001")[1]
            property real startedAt: 0
            property int quickFailures: 0
            property string last: ""
            property bool restarting: false
            // Counted in runningCount — undone on exit, or when this is
            // taken away while it runs, which ends it without an exit.
            property bool counted: false

            Process {
                id: player
                // Below the compositor for the processor: a frame of
                // wallpaper can wait, a frame of the desktop cannot.
                command: ["nice", "-n", "10", root.binary, "-l", "bottom",
                          "-o", root.mpvOptions, launch.output, launch.video]
                running: true
                stderr: SplitParser {
                    onRead: line => { if (line.trim() !== "") launch.last = line.trim(); }
                }
                onStarted: {
                    launch.counted = true;
                    root.runningCount++;
                    launch.startedAt = Date.now();
                    // Started while the rest are paused — the next video
                    // of a rotation behind a maximised window, say.
                    if (root.paused) player.signal(19);   // SIGSTOP
                }
                onExited: code => {
                    if (launch.counted) root.runningCount--;
                    launch.counted = false;
                    if (launch.restarting) { launch.restarting = false; retry.restart(); return; }
                    // One that ran for a while and then died (a driver
                    // reset, a suspend it did not survive) is started
                    // again. One that dies straight away will do so every
                    // time — a file it cannot play — and is left stopped,
                    // with what it said.
                    if (Date.now() - launch.startedAt > 20000) launch.quickFailures = 0;
                    else launch.quickFailures++;
                    if (launch.quickFailures >= 2) {
                        const t = launch.last.replace(/\x1b\[[0-9;]*m/g, "");
                        root.error = (t.length > 160 ? t.slice(0, 157) + "…" : t)
                                     || ("mpvpaper exited with code " + code);
                        return;
                    }
                    retry.restart();
                }
            }
            Timer { id: retry; interval: 1500; onTriggered: player.running = true }

            // mpv takes its options when it starts: a changed one is a
            // restart. Settle first, so a slider dragged is one restart.
            Timer {
                id: settle
                interval: 600
                onTriggered: {
                    launch.quickFailures = 0;
                    if (player.running) {
                        launch.restarting = true;
                        if (root.paused) player.signal(18);
                        player.running = false;
                    } else player.running = true;
                }
            }
            Connections {
                target: root
                function onMpvOptionsChanged() { settle.restart(); }
                // After a reload or a mode change: started afresh, and given
                // its two tries again — it may have died twice while the
                // output was being set up.
                function onRestartAll() {
                    launch.quickFailures = 0;
                    settle.restart();
                }
            }

            Component.onCompleted: root.fadeRule()
            Component.onDestruction: {
                if (launch.counted) root.runningCount--;
                // A stopped process does not act on SIGTERM until continued.
                if (root.paused) player.signal(18);
            }
        }
    }

    // Fading in rather than popping; the rule is named, so adding it again
    // replaces it. hyprland.lua has it too — this is for a config without.
    function fadeRule() {
        Services.Compositor.evalLua('hl.layer_rule({ name = "wallpaper-live-fade", '
            + 'match = { namespace = "^mpvpaper$" }, animation = "fade" })');
    }

    // ── when the compositor changes under it ─────────────────────────────
    // `hyprctl reload` re-applies hyprland.lua's monitor rules, and the shell
    // then puts your display settings back — two mode changes in a second.
    // mpvpaper does not survive that well: it either keeps its old surface
    // and stops drawing (the video frozen) or exits while the output is
    // half set up, twice, and is given up on as a file it cannot play.
    // So once things settle after a reload, or after an output changes mode,
    // size, scale or rotation, every player is started again.
    signal restartAll()
    readonly property string outputShape: (Services.Compositor.monitors || []).map(m => {
        if (!m) return "";
        const o = m.lastIpcObject || ({});
        return [m.name, m.width, m.height, m.scale, o.refreshRate, o.transform, o.disabled].join(":");
    }).join(",")
    // What the outputs were when the players last started; changes while
    // the shell is still starting up (the first reports filling in) are not
    // a reason to restart anything.
    property string knownShape: ""
    property bool settledIn: false
    Timer {
        interval: 8000
        running: true
        onTriggered: { root.knownShape = root.outputShape; root.settledIn = true; }
    }
    onOutputShapeChanged: if (root.settledIn && root.outputShape !== root.knownShape) outputSettle.restart()
    Connections {
        target: Services.Compositor
        function onConfigReloaded() { if (root.settledIn) outputSettle.restart(); }
        function onOutputsChanged() { if (root.settledIn) outputSettle.restart(); }
    }
    // Long enough for Devices' two-step mode set to finish; each change
    // pushes it back.
    Timer {
        id: outputSettle
        interval: 2500
        onTriggered: {
            root.knownShape = root.outputShape;
            if (root.launches.length === 0) return;
            console.log("LiveWallpaper: outputs changed, starting the video again");
            root.error = "";
            root.fadeRule();
            root.restartAll();
        }
    }

    // ── pausing ───────────────────────────────────────────────────────────
    // Stopped outright — SIGSTOP, which costs nothing while it lasts — when
    // every screen is covered, and continued the moment one is not.
    // Hyprland keeps showing its last frame meanwhile.
    //
    // Covered is a tiled window (tiles fill the screen, less the gaps), a
    // maximised one or a fullscreen one; floating windows alone leave the
    // desktop showing.
    readonly property bool shouldPause: {
        const mode = Config.Appearance.livePauseCovered;
        if (!root.running) return false;
        if (Config.Appearance.livePauseOnBattery && UPower.onBattery) return true;
        if (mode === "never") return false;
        const names = root.screenNames;
        if (names.length === 0) return false;
        for (const n of names) {
            const cs = Services.Compositor.clientsShownOn(n);
            const covered = mode === "windows" ? cs.length > 0
                : cs.some(c => !c.floating || c.fullscreenMode > 0);
            if (!covered) return false;
        }
        return true;
    }
    property bool paused: false
    // Switching workspaces passes through states that are neither; the
    // decision waits for them to settle.
    onShouldPauseChanged: pauseSettle.restart()
    Timer {
        id: pauseSettle
        interval: 600
        onTriggered: root.setPaused(root.shouldPause)
    }
    onRunningChanged: if (!root.running) root.paused = false
    Process { id: sigProc }
    function setPaused(on) {
        if (on === root.paused) return;
        root.paused = on;
        console.log("LiveWallpaper:", on ? "paused" : "playing again");
        sigProc.command = ["pkill", on ? "-STOP" : "-CONT", "-x", root.binary];
        sigProc.running = true;
    }

    // ── choosing ──────────────────────────────────────────────────────────
    function choose(path) {
        root.error = "";
        Config.Appearance.liveWallpaper = path;
    }
    function stop() {
        root.error = "";
        Config.Appearance.liveWallpaper = "";
    }
    // The next video, in order or shuffled.
    function next() {
        const list = root.wallpapers.map(w => w.dir);
        if (list.length === 0) return;
        const at = list.indexOf(root.chosen);
        let pick = list[(at + 1) % list.length];
        if (Config.Appearance.liveOrder === "random" && list.length > 1)
            do pick = list[Math.floor(Math.random() * list.length)]; while (pick === root.chosen);
        root.choose(pick);
    }
    Timer {
        interval: Math.max(1, Config.Appearance.liveDelay) * 60000
        repeat: true
        running: Config.Appearance.liveRotate && root.enabled && root.wallpapers.length > 1
        onTriggered: root.next()
    }

    // Anything left from a shell that did not get to stop it — a crash, a
    // reload that raced — is stopped before the first start, or there would
    // be two videos fighting over each output.
    // The scan waits for it, since nothing starts before a scan says
    // mpvpaper is there.
    Process {
        id: reaper
        command: ["sh", "-c", "pkill -CONT -x mpvpaper; pkill -x mpvpaper; true"]
        onExited: root.scan()
    }
    Component.onCompleted: reaper.running = true
}
