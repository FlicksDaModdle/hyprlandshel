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
// chose, and keep it running. Settings → Wallpaper is
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
    // for jq or python, then a group-separator line with what probe says.
    //
    // probe: whether a scene is one linux-wallpaperengine can draw. It
    // draws 2D scenes only; a 3D one has no "orthogonalprojection" in its
    // scene file, and fails with "General section must have orthogonal
    // projection info". The scene file is loose in the folder or inside
    // scene.pkg, which stores its files uncompressed, so the key's name is
    // there to find as text either way. "2d", "3d", or "none" when there is
    // no scene file to look in (a video, say). Remembered per folder until
    // its files change, since a scene.pkg can be hundreds of megabytes.
    Process {
        id: scanProc
        command: ["sh", "-c", `
            command -v ${root.binary} >/dev/null 2>&1 && echo installed
            cache="${root.cacheDir}/probe"; mkdir -p "$cache"
            probe() {
                set -- "$1"/scene.pkg "$1"/gifscene.pkg "$1"/*.json
                key=$(stat -c %Y:%s "$@" 2>/dev/null | tr '[:space:]' ' ')
                cf="$cache/$(printf '%s' "$d" | cksum | cut -d ' ' -f 1)"
                if [ -f "$cf" ] && [ "$(sed -n 1p "$cf")" = "$key" ]; then sed -n 2p "$cf"; return; fi
                if grep -qs '"orthogonalprojection"' "$@"; then r=2d
                elif [ -f "$d/scene.pkg" ] || [ -f "$d/gifscene.pkg" ] \
                     || [ "$(ls "$d"/*.json 2>/dev/null | wc -l)" -gt 1 ]; then r=3d
                else r=none; fi
                printf '%s\n%s\n' "$key" "$r" > "$cf"
                echo "$r"
            }
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
                    printf '\\n\\035'
                    probe "\${d%/}"
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
            const gs = rec.lastIndexOf("\x1d");
            const body = rec.slice(nl + 1, gs < 0 ? undefined : gs);
            // What probe said, and after it "assets" when the next library
            // has them — printed after this record, on its own line.
            const tail = gs < 0 ? "" : rec.slice(gs + 1);
            const probed = tail.split("\n")[0].trim();
            if (/^assets$/m.test(tail)) assets = true;
            if (seen[dir]) continue;
            seen[dir] = true;
            let p;
            // Wallpaper Engine writes some of these with a byte-order mark,
            // which JSON.parse refuses.
            try { p = JSON.parse(body.replace(/^\uFEFF/, "")); } catch (e) { continue; }
            // Its main file; without one there is nothing to draw.
            const file = String(p.file || "");
            if (file === "") continue;
            // The samples bundled with Wallpaper Engine leave "type" out —
            // it goes by the main file — and linux-wallpaperengine refuses
            // a project without one ("Project type missing"). The type is
            // worked out the same way here, and the wallpaper is started
            // from a copy that says it (see shimFor).
            const given = String(p.type || "").toLowerCase();
            const type = given || root.typeOf(file);
            // "application" wallpapers are Windows programs; there is
            // nothing linux-wallpaperengine can do with them, or with any
            // type it does not know.
            if (type !== "scene" && type !== "video" && type !== "web") continue;
            const id = dir.split("/").pop();
            found.push({
                dir: dir,
                id: id,
                title: String(p.title || id),
                preview: p.preview ? dir + "/" + p.preview : "",
                type: type,
                // What the copy has to add: linux-wallpaperengine requires
                // both of these.
                noType: given === "",
                noTitle: !p.title,
                // Why linux-wallpaperengine cannot draw it, when it is
                // known beforehand; the gallery greys these out.
                unsupported: type === "scene" && probed === "3d"
                             ? "3D scene — linux-wallpaperengine draws 2D scenes only" : ""
            });
        }
        found.sort((a, b) => a.title.localeCompare(b.title));
        root.hasAssets = assets;
        root.wallpapers = found;
        root.scanned = true;
    }

    function typeOf(file) {
        const ext = file.toLowerCase().split(".").pop();
        if (ext === "json") return "scene";
        if (["mp4", "webm", "mkv", "avi", "mov", "m4v"].includes(ext)) return "video";
        if (ext === "html" || ext === "htm") return "web";
        return "";
    }

    // Until the first scan is in, which wallpapers need a copy is not
    // known, so nothing starts.
    property bool scanned: false

    // The copy a wallpaper is started from when its project.json needs
    // something added: the original's files, hard-linked, and a
    // project.json that is the original with the type (and the title)
    // put in. The Steam folder itself is not touched — Steam would put it
    // back on the next update, and it is not the shell's to change.
    readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME")
                                        || Quickshell.env("HOME") + "/.cache") + "/hyprshell/live"
    function shimFor(w) { return root.cacheDir + "/" + w.id; }

    // ── running it ────────────────────────────────────────────────────────
    // One --screen-root per output, so each gets the wallpaper at its own
    // size. Without one linux-wallpaperengine opens an ordinary window.
    readonly property var screenNames: Quickshell.screens.map(s => s.name).filter(n => !!n)

    // The copy to make before starting, as [original, copy, what to add
    // to its project.json], or empty strings when it is used as it is.
    readonly property var shim: {
        const w = root.current;
        if (!w || (!w.noType && !w.noTitle)) return ["", "", ""];
        const add = (w.noType ? '"type":' + JSON.stringify(w.type) + "," : "")
                  + (w.noTitle ? '"title":' + JSON.stringify(w.title) + "," : "");
        return [w.dir, root.shimFor(w), add];
    }

    readonly property var args: {
        if (!root.enabled || !root.scanned || root.screenNames.length === 0) return [];
        // Known not to work: starting it would only fail.
        if (root.current && root.current.unsupported) return [];
        const bg = root.shim[1] || root.chosen;
        const a = ["--fps", String(Config.Appearance.liveFps)];
        if (!Config.Appearance.liveSound) a.push("--silent");
        if (!Config.Appearance.liveMouse) a.push("--disable-mouse", "--disable-parallax");
        for (const n of root.screenNames)
            a.push("--screen-root", n, "--scaling", "fill", "--bg", bg);
        return a;
    }
    // What the running one was started with. A rescan builds new objects
    // for the same wallpapers, which makes a new (equal) args; that is no
    // reason to restart it.
    property string launched: ""

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
        //
        //
        // The copy (see shimFor) is made here too, from $1-$3, so it is
        // always current with the original when the wallpaper starts. Hard
        // links, not symlinks: linux-wallpaperengine resolves every file to
        // its real path and refuses one outside the wallpaper's folder
        // ("Cannot find requested file in any of the mountpoints"). They
        // cost no space; across drives, where they cannot be made, it is a
        // plain copy. project.json is unlinked before it is written, so the
        // original is never written through its link. $3 is
        // the text to add, spliced in after the first opening brace, where
        // any JSON object can take another key; awk rather than sed, since
        // it is taken as it is rather than as a pattern.
        command: ["sh", "-c", `
            src=$1 dst=$2 add=$3; shift 3
            if [ -n "$src" ]; then
                rm -rf "$dst" && mkdir -p "$dst" || exit 1
                cp -al "$src/." "$dst/" 2>/dev/null || cp -a "$src/." "$dst/" || exit 1
                rm -f "$dst/project.json"
                add="$add" awk '!d && (i = index($0, "{")) { $0 = substr($0, 1, i) ENVIRON["add"] substr($0, i + 1); d = 1 } { print }' "$src/project.json" > "$dst/project.json" || exit 1
            fi
            pkill -x linux-wallpaper; i=0
            while pgrep -x linux-wallpaper >/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
            exec ${root.binary} "$@"`, "sh"].concat(root.shim).concat(root.args)
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
                root.error = root.shorten(last) || ("it exited with code " + code);
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

    // Its messages can carry the whole project.json after them
    // ("Project type missing. Contents: {…}"); the sentence is the part
    // worth showing.
    function shorten(line) {
        let t = String(line).replace(/\x1b\[[0-9;]*m/g, "").trim();
        const cut = t.indexOf(". Contents:");
        if (cut >= 0) t = t.slice(0, cut);
        // The ones with a plain-language reason.
        if (/orthogonal projection/.test(t))
            return "it is a 3D scene, and linux-wallpaperengine draws 2D scenes only";
        if (/valid assets folder/.test(t))
            return "Wallpaper Engine's assets were not found — install Wallpaper Engine from Steam";
        return t.length > 160 ? t.slice(0, 157) + "…" : t;
    }

    function restart() {
        retry.stop();
        if (!Config.Appearance.settingsReady) return;
        // With none chosen, one the shell did not start is left alone — it
        // may be yours, from hyprland.lua.
        if (root.args.length === 0) {
            if (!root.enabled && proc.running) { root.stopping = true; proc.running = false; }
            root.launched = "";
            return;
        }
        const key = JSON.stringify(root.shim.concat(root.args));
        if (proc.running && key === root.launched) return;
        root.launched = key;
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
        const w = root.wallpapers.find(x => x.dir === dirOrId || x.id === dirOrId);
        if (w && w.unsupported) return;
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
