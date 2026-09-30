pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services
import "WeProps.js" as WeProps

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
//
// What Wallpaper Engine lets you set on Windows is set here too, as far as
// linux-wallpaperengine can carry it: each wallpaper's own options (its
// "user properties", passed as --set-property), playback, a wallpaper per
// screen or one across them, and a playlist. Options go in and out as
// Wallpaper Engine's "Share JSON"; playlists and what is on screen go in and
// out of its config.json. The formats are in WeProps.js.
Singleton {
    id: root

    readonly property string binary: "linux-wallpaperengine"

    // ── what there is ─────────────────────────────────────────────────────
    property string weConfig: ""
    property bool installed: false
    property bool hasAssets: false
    property bool scanning: false
    // [{ dir, id, title, preview, type, unsupported, props }], by title.
    property var wallpapers: []

    // ── what is running ───────────────────────────────────────────────────
    readonly property string chosen: Config.Appearance.liveWallpaper
    readonly property bool enabled: chosen !== ""
    readonly property bool running: proc.running
    // Why it is not running, when it should be: the last thing it said.
    property string error: ""

    function find(dirOrId) {
        if (!dirOrId) return null;
        for (const w of root.wallpapers)
            if (w.dir === dirOrId || w.id === dirOrId) return w;
        return null;
    }
    readonly property var current: root.find(root.chosen)
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
                [ -f "$we/config.json" ] && printf 'weconfig:%s\\n' "$we/config.json"
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
        // Wallpaper Engine's own settings file, where it is installed
        // through Steam here (under Proton, say): where import and export
        // start. The first library that has one.
        const wc = /(?:^|\n)weconfig:([^\n]*)/.exec(text);
        root.weConfig = wc ? wc[1] : "";
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
                             ? "3D scene — linux-wallpaperengine draws 2D scenes only" : "",
                // Its own options, as Wallpaper Engine lists them.
                props: WeProps.parseProps(p)
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
    //
    // HYPRSHELL_LIVE_SCREENS, a comma-separated list of output names, stands
    // in for the real ones — for trying the layouts on one screen, as the
    // greeter's HYPRSHELL_GREETER_* do. Unset, it is the screens there are.
    readonly property var screenNames: {
        const fake = Quickshell.env("HYPRSHELL_LIVE_SCREENS");
        if (fake) return fake.split(",").filter(n => !!n);
        return Quickshell.screens.map(s => s.name).filter(n => !!n);
    }

    // ── each wallpaper's options ──────────────────────────────────────────
    // Only what differs from the wallpaper's own defaults is kept, so a
    // wallpaper whose author changes a default gets the new one.
    readonly property var propStore: {
        try { return JSON.parse(Config.Appearance.liveProps || "{}") || {}; }
        catch (e) { return {}; }
    }
    function overridesFor(w) { return (w && root.propStore[w.id]) || {}; }
    function valuesFor(w) {
        const v = {};
        if (!w) return v;
        for (const p of w.props) if (!p.caption) v[p.name] = p.value;
        return Object.assign(v, root.overridesFor(w));
    }
    function changedCount(w) { return Object.keys(root.overridesFor(w)).length; }

    function setProps(w, values) {
        if (!w) return;
        const store = JSON.parse(JSON.stringify(root.propStore));
        const mine = store[w.id] || {};
        for (const name in values) {
            const p = w.props.find(x => x.name === name && !x.caption);
            if (!p) continue;
            if (WeProps.same(p, values[name], p.value)) delete mine[name];
            else mine[name] = values[name];
        }
        if (Object.keys(mine).length > 0) store[w.id] = mine;
        else delete store[w.id];
        Config.Appearance.liveProps = JSON.stringify(store);
    }
    function setProp(w, name, value) { const o = {}; o[name] = value; root.setProps(w, o); }
    function resetProps(w) {
        if (!w) return;
        const store = JSON.parse(JSON.stringify(root.propStore));
        delete store[w.id];
        Config.Appearance.liveProps = JSON.stringify(store);
    }

    // ── which wallpaper where ─────────────────────────────────────────────
    readonly property var screenMap: {
        try { return JSON.parse(Config.Appearance.liveScreens || "{}") || {}; }
        catch (e) { return {}; }
    }
    readonly property string layout: root.screenNames.length > 1 ? Config.Appearance.liveLayout : "same"
    function wallpaperFor(screen) {
        if (root.layout === "each" && root.screenMap[screen]) return root.screenMap[screen];
        return root.chosen;
    }
    function chooseFor(screen, dir) {
        const m = JSON.parse(JSON.stringify(root.screenMap));
        if (dir) m[screen] = dir; else delete m[screen];
        Config.Appearance.liveScreens = JSON.stringify(m);
        root.quickFailures = 0;
        root.error = "";
    }

    // The wallpapers on screen, each once.
    readonly property var used: {
        const out = [];
        const names = root.layout === "each" ? root.screenNames : [""];
        for (const n of names) {
            const w = root.find(n === "" ? root.chosen : root.wallpaperFor(n));
            if (w && out.indexOf(w) < 0) out.push(w);
        }
        return out;
    }

    // What to start a wallpaper from: its folder, or its copy (shimFor).
    function bgFor(dirOrId) {
        const w = root.find(dirOrId);
        if (w && w.unsupported) return "";
        return w && (w.noType || w.noTitle) ? root.shimFor(w) : dirOrId;
    }

    // The copies to make before starting: a count, then [original, copy,
    // what to add to its project.json] for each.
    readonly property var shim: {
        const out = [];
        for (const w of root.used) {
            if (!w.noType && !w.noTitle) continue;
            const add = (w.noType ? '"type":' + JSON.stringify(w.type) + "," : "")
                      + (w.noTitle ? '"title":' + JSON.stringify(w.title) + "," : "");
            out.push(w.dir, root.shimFor(w), add);
        }
        return [String(out.length / 3)].concat(out);
    }

    readonly property var args: {
        if (!root.enabled || !root.scanned || root.screenNames.length === 0) return [];
        const A = Config.Appearance;
        const a = ["--fps", String(Math.max(1, A.liveFps))];
        if (!A.liveSound || A.liveVolume <= 0) a.push("--silent");
        // It takes 0-128.
        else a.push("--volume", String(Math.round(A.liveVolume * 1.28)));
        if (!A.liveAutomute) a.push("--noautomute");
        if (!A.liveAudioReactive) a.push("--no-audio-processing");
        if (A.livePause === "never") a.push("--no-fullscreen-pause");
        else if (A.livePause === "focused") a.push("--fullscreen-pause-only-active");
        if (!A.liveParticles) a.push("--disable-particles");
        if (!A.liveMouse) a.push("--disable-mouse", "--disable-parallax");
        else if (!A.liveParallax) a.push("--disable-parallax");

        // The options changed on the wallpapers on screen. They are one
        // list for the whole program, so two wallpapers with an option of
        // the same name share it.
        const set = {};
        for (const w of root.used) {
            const o = root.overridesFor(w);
            for (const p of w.props)
                if (!p.caption && p.name in o) set[p.name] = WeProps.toArg(p, o[p.name]);
        }
        for (const k in set) a.push("--set-property", set[k]);

        const sc = A.liveScaling || "fill";
        if (root.layout === "span") {
            const bg = root.bgFor(root.chosen);
            if (!bg) return [];
            a.push("--screen-span", root.screenNames.join(","), "--scaling", sc, "--bg", bg);
            return a;
        }
        let any = false;
        for (const n of root.screenNames) {
            const bg = root.bgFor(root.wallpaperFor(n));
            // Known not to work: starting it would only fail.
            if (!bg) continue;
            a.push("--screen-root", n, "--scaling", sc, "--bg", bg);
            any = true;
        }
        return any ? a : [];
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
        // The copies (see shimFor) are made here too, from the count in $1
        // and three arguments each after it, so they are
        // always current with the original when the wallpaper starts. Hard
        // links, not symlinks: linux-wallpaperengine resolves every file to
        // its real path and refuses one outside the wallpaper's folder
        // ("Cannot find requested file in any of the mountpoints"). They
        // cost no space; across drives, where they cannot be made, it is a
        // plain copy. project.json is unlinked before it is written, so the
        // original is never written through its link. The third of each is
        // the text to add, spliced in after the first opening brace, where any JSON
        // object can take another key; awk rather than sed, since it is
        // taken as it is rather than as a pattern.
        //
        // libcef.so is preloaded when it can be found beside the binary.
        // Chromium's close() wrapper in it finds libc's with
        // dlsym(RTLD_NEXT), which only searches libraries loaded after
        // libcef; linux-wallpaperengine loads libc first, so the lookup
        // fails and Chromium stops the program on purpose — "close symbol
        // missing", then a trace trap — for web wallpapers. Loading libcef
        // first is the workaround its issue gives (Almamu/
        // linux-wallpaperengine#628); the fix upstream is not merged yet.
        // It changes nothing else: libcef is loaded either way.
        command: ["sh", "-c", `
            n=$1; shift
            while [ "$n" -gt 0 ]; do
                src=$1 dst=$2 add=$3; shift 3; n=$((n - 1))
                rm -rf "$dst" && mkdir -p "$dst" || exit 1
                cp -al "$src/." "$dst/" 2>/dev/null || cp -a "$src/." "$dst/" || exit 1
                rm -f "$dst/project.json"
                add="$add" awk '!d && (i = index($0, "{")) { $0 = substr($0, 1, i) ENVIRON["add"] substr($0, i + 1); d = 1 } { print }' "$src/project.json" > "$dst/project.json" || exit 1
            done
            pkill -x linux-wallpaper; i=0
            while pgrep -x linux-wallpaper >/dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
            real=$(readlink -f "$(command -v ${root.binary})")
            for cef in "\${real%/*}/libcef.so" /opt/linux-wallpaperengine/libcef.so \
                       /usr/lib/linux-wallpaperengine/libcef.so; do
                [ -f "$cef" ] || continue
                export LD_PRELOAD="$cef\${LD_PRELOAD:+:$LD_PRELOAD}"
                break
            done
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
    // and adds — so the restart waits for them to settle. linux-
    // wallpaperengine takes its options only when it starts, so an option
    // changed is a restart as well.
    // Settings changes too: an option clicked through several values
    // restarts it once, at the end.
    Timer { id: settle; interval: 800; onTriggered: root.restart() }
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
        if (/close symbol missing/.test(t))
            return "its web engine crashed on start (linux-wallpaperengine #628), "
                 + "and libcef.so was not found beside it to work around that";
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

    // ── playlist ──────────────────────────────────────────────────────────
    // Wallpaper Engine's: a list of wallpapers the desktop moves through on
    // a timer, in order or shuffled.
    readonly property var playlist: {
        try {
            const a = JSON.parse(Config.Appearance.livePlaylist || "[]");
            return Array.isArray(a) ? a.filter(x => typeof x === "string") : [];
        } catch (e) { return []; }
    }
    function inPlaylist(dir) { return root.playlist.indexOf(dir) >= 0; }
    function togglePlaylist(dir) {
        const a = root.playlist.slice();
        const i = a.indexOf(dir);
        if (i >= 0) a.splice(i, 1); else a.push(dir);
        Config.Appearance.livePlaylist = JSON.stringify(a);
    }
    // The ones that can be shown here now.
    readonly property var playable: root.playlist.filter(d => { const w = root.find(d); return w && !w.unsupported; })

    function next() {
        const list = root.playable;
        if (list.length === 0) return;
        const at = list.indexOf(root.current ? root.current.dir : root.chosen);
        let pick;
        if (Config.Appearance.liveOrder === "random" && list.length > 1) {
            do pick = list[Math.floor(Math.random() * list.length)]; while (pick === list[at]);
        } else pick = list[(at + 1) % list.length];
        root.choose(pick);
    }

    Timer {
        id: rotation
        interval: Math.max(1, Config.Appearance.liveDelay) * 60000
        repeat: true
        running: Config.Appearance.liveRotate && root.enabled && root.playable.length > 1
        onTriggered: root.next()
    }

    // ── files, dialogs, the clipboard ─────────────────────────────────────
    // What the last import or export did, for the row that started it.
    property string shareStatus: ""
    property string configStatus: ""

    // A file dialog from whichever of zenity and kdialog is there. The
    // chosen path goes to `then`; cancelling calls nothing.
    property var pickThen: null
    Process {
        id: pickProc
        stdout: StdioCollector {
            onStreamFinished: {
                const f = text.trim();
                const then = root.pickThen;
                root.pickThen = null;
                if (f !== "" && then) then(f);
            }
        }
        onExited: code => {
            if (code === 3) {
                root.pickThen = null;
                root.shareStatus = root.configStatus = "Needs zenity or kdialog for a file dialog";
            }
        }
    }
    function pick(save, title, start, then) {
        root.pickThen = then;
        pickProc.command = ["sh", "-c", `
            mode=$1 title=$2 start=$3
            if command -v zenity >/dev/null 2>&1; then
                if [ "$mode" = save ]; then
                    zenity --file-selection --save --confirm-overwrite --title="$title" \\
                           --filename="$start" --file-filter='JSON | *.json' --file-filter='All files | *'
                else
                    zenity --file-selection --title="$title" --filename="$start" \\
                           --file-filter='JSON | *.json' --file-filter='All files | *'
                fi
            elif command -v kdialog >/dev/null 2>&1; then
                if [ "$mode" = save ]; then kdialog --title "$title" --getsavefilename "$start" '*.json|JSON'
                else kdialog --title "$title" --getopenfilename "$start" '*.json|JSON'; fi
            else exit 3; fi`, "sh", save ? "save" : "open", title, start];
        pickProc.running = true;
    }

    // Reads a file; `then` gets its text, or null when there is none.
    property var readThen: null
    Process {
        id: readProc
        stdout: StdioCollector { id: readOut }
        onExited: code => {
            const then = root.readThen;
            root.readThen = null;
            if (then) then(code === 0 ? readOut.text : null);
        }
    }
    function readFile(path, then) {
        root.readThen = then;
        readProc.command = ["sh", "-c", '[ -f "$1" ] && cat -- "$1"', "sh", path];
        readProc.running = true;
    }

    // Writes a file through a temporary one beside it, so a failed write
    // leaves the old file whole. With `backup`, a file that is there is
    // first copied to <name>.before-hyprshell, once.
    property string writeText: ""
    property var writeThen: null
    Process {
        id: writeProc
        stdinEnabled: true
        onStarted: {
            write(root.writeText);
            stdinEnabled = false;
        }
        onExited: code => {
            const then = root.writeThen;
            root.writeThen = null;
            stdinEnabled = true;
            if (then) then(code === 0);
        }
    }
    function writeFile(path, text, backup, then) {
        root.writeText = text;
        root.writeThen = then;
        writeProc.command = ["sh", "-c", `
            f=$1
            if [ "$2" = backup ] && [ -f "$f" ] && [ ! -e "$f.before-hyprshell" ]; then
                cp -p -- "$f" "$f.before-hyprshell" || exit 1
            fi
            cat > "$f.hyprshell-new" && mv -f -- "$f.hyprshell-new" "$f"`, "sh", path, backup ? "backup" : ""];
        writeProc.running = true;
    }

    Process { id: copyProc }
    property var pasteThen: null
    Process {
        id: pasteProc
        command: ["wl-paste", "--no-newline"]
        stdout: StdioCollector { id: pasteOut }
        onExited: code => {
            const then = root.pasteThen;
            root.pasteThen = null;
            if (then) then(code === 0 ? pasteOut.text : null);
        }
    }

    function safeName(t) { return String(t).replace(/[\\/:*?"<>|]+/g, " ").trim() || "wallpaper"; }
    readonly property string home: Quickshell.env("HOME")

    // ── Share JSON ────────────────────────────────────────────────────────
    function shareText(w) {
        return JSON.stringify(WeProps.shareJson(w.props, root.valuesFor(w)), null, "\t");
    }

    function copyShare() {
        const w = root.current;
        if (!w) return;
        copyProc.command = ["wl-copy", "--", root.shareText(w)];
        copyProc.running = true;
        root.shareStatus = "Copied " + w.title + "'s options";
    }

    function saveShare() {
        const w = root.current;
        if (!w) return;
        root.pick(true, "Save " + w.title + "'s options", root.home + "/" + root.safeName(w.title) + ".json", f => {
            root.writeFile(f, root.shareText(w) + "\n", false, ok => {
                root.shareStatus = ok ? "Saved to " + f : "Could not write " + f;
            });
        });
    }

    function applyShare(text, from) {
        const w = root.current;
        if (!w) return;
        if (text === null || String(text).trim() === "") { root.shareStatus = "Nothing to read from " + from; return; }
        let data;
        try { data = JSON.parse(String(text).replace(/^\uFEFF/, "")); }
        catch (e) { root.shareStatus = "That is not JSON — nothing changed"; return; }
        const r = WeProps.importValues(w.props, data);
        if (!r.ok || r.applied === 0) {
            root.shareStatus = "None of it is an option " + w.title + " has — nothing changed";
            return;
        }
        root.setProps(w, r.values);
        root.shareStatus = "Applied " + r.applied + (r.applied === 1 ? " option" : " options")
            + (r.skipped > 0 ? "; " + r.skipped + " not for this wallpaper" : "");
    }

    function pasteShare() {
        root.pasteThen = t => root.applyShare(t, "the clipboard");
        pasteProc.running = true;
    }

    function loadShare() {
        if (!root.current) return;
        root.pick(false, "Load options for " + root.current.title, root.home + "/", f => {
            root.readFile(f, t => root.applyShare(t, f));
        });
    }

    // ── config.json ───────────────────────────────────────────────────────
    function byKey(key) {
        for (const w of root.wallpapers) if (WeProps.keyOf(w.dir) === key) return w;
        return null;
    }

    function importConfig() {
        root.pick(false, "Import Wallpaper Engine's config.json",
                  root.weConfig || root.home + "/", f => root.readFile(f, t => {
            let cfg;
            try { cfg = JSON.parse(String(t || "").replace(/^\uFEFF/, "")); }
            catch (e) { root.configStatus = "That is not JSON — nothing changed"; return; }
            const r = WeProps.readConfig(cfg);
            if (!r.ok) { root.configStatus = "That is not Wallpaper Engine's config.json"; return; }
            const A = Config.Appearance;
            const said = [];
            // The playlist the first screen runs, or else the first there is.
            const first = r.selected[0];
            const list = (first && first.playlist) || r.playlists[0];
            if (list) {
                const dirs = [], missing = [];
                for (const k of list.keys) {
                    const w = root.byKey(k);
                    if (w) { if (dirs.indexOf(w.dir) < 0) dirs.push(w.dir); } else missing.push(k);
                }
                A.livePlaylist = JSON.stringify(dirs);
                A.liveListName = list.name || "Wallpaper Engine";
                if (list.settings.delay > 0) A.liveDelay = Math.round(list.settings.delay);
                if (list.settings.order === "random" || list.settings.order === "sequential")
                    A.liveOrder = list.settings.order;
                A.liveRotate = !!(first && first.playlist) && dirs.length > 1;
                said.push("playlist “" + A.liveListName + "”, " + dirs.length + " wallpapers"
                          + (missing.length ? " (" + missing.length + " not installed here)" : ""));
            }
            // What each screen shows: the first here gets the first there,
            // and so on.
            const shown = r.selected.map(e => root.byKey(e.key)).filter(w => w && !w.unsupported);
            if (shown.length > 0) {
                root.choose(shown[0].dir);
                said.push(shown[0].title + " on screen");
                if (shown.length > 1 && root.screenNames.length > 1) {
                    const m = {};
                    root.screenNames.forEach((n, i) => { if (shown[i]) m[n] = shown[i].dir; });
                    A.liveScreens = JSON.stringify(m);
                    A.liveLayout = "each";
                }
            }
            root.configStatus = said.length ? "Imported " + said.join(", ")
                                            : "It has no playlists or wallpapers to bring over";
        }));
    }

    function exportConfig() {
        root.pick(true, "Export to Wallpaper Engine's config.json",
                  root.weConfig || root.home + "/config.json", f => root.readFile(f, t => {
            let existing = null;
            if (t !== null && String(t).trim() !== "") {
                try { existing = JSON.parse(String(t).replace(/^\uFEFF/, "")); }
                catch (e) {
                    root.configStatus = f + " is not JSON — left alone";
                    return;
                }
            }
            const A = Config.Appearance;
            const out = WeProps.writeConfig(existing, {
                name: A.liveListName || "Hyprshell",
                dirs: root.playlist.filter(d => root.find(d)),
                localKeys: root.wallpapers.map(w => WeProps.keyOf(w.dir)),
                delay: Math.max(1, A.liveDelay),
                order: A.liveOrder,
                current: root.current ? root.current.dir : "",
                rotate: A.liveRotate
            });
            root.writeFile(f, JSON.stringify(out, null, "\t") + "\n", existing !== null, ok => {
                root.configStatus = !ok ? "Could not write " + f
                    : "Exported to " + f + (existing ? " — the old one is beside it, .before-hyprshell" : "");
            });
        }));
    }

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
