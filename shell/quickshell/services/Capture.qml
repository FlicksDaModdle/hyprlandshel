pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../config" as Config
import "." as Services

// Screenshots, screen recordings and text from the screen.
//
//   shot(mode)     region | window | screen | all — saved to
//                  ~/Pictures/Screenshots and put on the clipboard, then
//                  either opened in the editor (ShotEditor) or announced
//                  with Edit and Show in Files. Region and window freeze the
//                  screen first, the way Windows' Snipping Tool does: every
//                  output is captured the moment the key goes down, and the
//                  choosing happens over that still picture
//                  (modules/capture/Snipper.qml), so a menu or a video holds
//                  still while you frame it. With freezing off, slurp
//                  chooses over the live screen as before.
//   record(mode)   region | screen — wf-recorder to ~/Videos/Recordings,
//                  with the desktop's sound, the microphone, or neither;
//                  the bar shows a red timer that stops it.
//   ocr()          a region's text (tesseract) onto the clipboard.
//
// Window mode offers the windows on screen as the boxes slurp snaps to.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance

    readonly property string picturesDir: Quickshell.env("HOME") + "/Pictures/Screenshots"
    readonly property string videosDir: Quickshell.env("HOME") + "/Videos/Recordings"

    property bool busy: false
    property string lastShot: ""
    property string lastError: ""

    // ── screenshots ──────────────────────────────────────────────────────
    // Panels are closed first and given a moment to leave the screen, so
    // a shot of the desktop is not a shot of the toolbar that took it.
    function shot(mode, opts) {
        if (busy) return;
        const o = opts || {};
        const m = mode || "region";
        if (prefs.captureFreeze && (m === "region" || m === "window")) {
            freeze("shot", m, o.delay !== undefined ? o.delay : prefs.captureDelay,
                   o.pointer !== undefined ? o.pointer : prefs.capturePointer);
            return;
        }
        busy = true;
        Config.UiState.closeAll();
        pending = { kind: "shot", mode: mode || "region", delay: o.delay !== undefined ? o.delay : prefs.captureDelay,
                    pointer: o.pointer !== undefined ? o.pointer : prefs.capturePointer };
        settle.restart();
    }
    function ocr() {
        if (busy) return;
        if (prefs.captureFreeze) { freeze("ocr", "region", 0, false); return; }
        busy = true;
        Config.UiState.closeAll();
        pending = { kind: "ocr" };
        settle.restart();
    }
    property var pending: null
    Timer {
        id: settle
        interval: 280
        onTriggered: {
            const p = root.pending;
            if (!p) { root.busy = false; return; }
            if (p.kind === "shot") root.runShot(p);
            else if (p.kind === "ocr") root.runOcr();
            else if (p.kind === "record") root.runRecord(p);
        }
    }

    // The windows on screen, as slurp's "x,y wxh label" lines.
    function windowBoxes() {
        const shown = (Services.Compositor.monitors || []).map(m => m.activeWorkspace ? m.activeWorkspace.id : -1);
        if (shown.length === 0) shown.push(Services.Compositor.focusedId);
        return (Services.Compositor.clients || [])
            .filter(c => c.w > 0 && c.h > 0 && (shown.indexOf(c.workspace) >= 0 || c.pinned))
            .map(c => c.x + "," + c.y + " " + c.w + "x" + c.h + " " + (c.title || c.cls).replace(/\n/g, " "))
            .join("\n");
    }
    function focusedOutput() {
        const m = Services.Compositor.focusedMonitor;
        return m ? (m.name || "") : "";
    }

    readonly property string shotScript: [
        'mode=$1; delay=$2; pointer=$3; dir=$4; out=$5; boxes=$6',
        'mkdir -p "$dir" || exit 3',
        'f="$dir/Screenshot_$(date +%Y-%m-%d_%H-%M-%S).png"',
        'g=""',
        'case "$mode" in',
        '  region) g=$(slurp -d < /dev/null) || exit 1 ;;',
        '  window) g=$(printf "%s\\n" "$boxes" | slurp -r) || exit 1 ;;',
        'esac',
        '[ "$delay" -gt 0 ] 2>/dev/null && sleep "$delay"',
        'c=""; [ "$pointer" = 1 ] && c="-c"',
        'if [ -n "$g" ]; then grim $c -g "$g" "$f"',
        'elif [ "$mode" = screen ] && [ -n "$out" ]; then grim $c -o "$out" "$f"',
        'else grim $c "$f"; fi || exit 2',
        'wl-copy --type image/png < "$f" 2>/dev/null',
        'printf "%s\\n" "$f"'
    ].join("\n")

    function runShot(p) {
        shotProc.command = ["sh", "-c", shotScript, "shot", p.mode, String(p.delay || 0), p.pointer ? "1" : "0",
                            picturesDir, focusedOutput(), p.mode === "window" ? windowBoxes() : ""];
        shotProc.running = true;
    }
    Process {
        id: shotProc
        stdout: StdioCollector { id: shotOut }
        stderr: StdioCollector { id: shotErr }
        onExited: code => {
            root.busy = false;
            root.pending = null;
            const f = shotOut.text.trim();
            if (code === 1) return;   // the selection was cancelled
            if (code !== 0 || f === "") {
                root.lastError = code === 3 ? "Could not create " + root.picturesDir
                               : (shotErr.text.trim() || "grim failed (is it installed?)");
                root.say("Screenshot failed", root.lastError, "", []);
                return;
            }
            root.delivered(f);
        }
    }

    // ── the frozen screen ────────────────────────────────────────────────
    // snip: null, or { kind: "shot" | "ocr", dir, files: { output: png } }
    // once every output has been captured. The overlay is up while it is
    // set; snipMode is what it is choosing (region | window | screen).
    property var snip: null
    property string snipMode: "region"
    property var freezeWant: null

    function freeze(kind, mode, delay, pointer) {
        busy = true;
        snipMode = mode;
        freezeWant = { kind: kind, delay: delay || 0, pointer: !!pointer };
        // A panel open over the screen would be frozen into the picture;
        // the toolbar that asked for this certainly should not be. Pressed
        // from the keyboard with nothing open, it freezes at once.
        if (Config.UiState.anyPanelOpen || Config.UiState.launcherOpen) {
            Config.UiState.closeAll();
            freezeSoon.interval = 280;
        } else freezeSoon.interval = 1;
        freezeSoon.restart();
    }
    Timer { id: freezeSoon; onTriggered: root.runFreeze() }
    function runFreeze() {
        const w = freezeWant;
        const dir = (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/hyprshell-snip-" + Date.now();
        const outs = Quickshell.screens.map(s => s.name).filter(n => !!n);
        freezeProc.command = ["sh", "-c",
            'command -v grim >/dev/null 2>&1 || exit 4; '
            + 'dir=$1; delay=$2; ptr=$3; pics=$4; shift 4; '
            + 'mkdir -p "$dir" "$pics" || exit 3; '
            + '[ "$delay" -gt 0 ] 2>/dev/null && sleep "$delay"; '
            + 'c=""; [ "$ptr" = 1 ] && c="-c"; '
            + 'for o in "$@"; do grim $c -o "$o" "$dir/$o.png" & done; wait; '
            + 'for o in "$@"; do [ -s "$dir/$o.png" ] && printf "%s\t%s\n" "$o" "$dir/$o.png"; done',
            "freeze", dir, String(w.delay), w.pointer ? "1" : "0", picturesDir].concat(outs);
        freezeProc.dir = dir;
        freezeProc.running = true;
    }
    Process {
        id: freezeProc
        property string dir: ""
        stdout: StdioCollector { id: freezeOut }
        stderr: StdioCollector { id: freezeErr }
        onExited: code => {
            const files = {};
            for (const line of freezeOut.text.split("\n")) {
                const t = line.split("\t");
                if (t.length === 2 && t[1] !== "") files[t[0]] = t[1];
            }
            if (code !== 0 || Object.keys(files).length === 0) {
                root.busy = false;
                root.lastError = code === 4 ? "Needs grim — sudo pacman -S grim"
                               : code === 3 ? "Could not create " + root.picturesDir
                               : (freezeErr.text.trim() || "grim could not capture the screen");
                root.say("Screenshot failed", root.lastError, "", []);
                root.cleanSnip(freezeProc.dir);
                return;
            }
            root.snip = { kind: root.freezeWant.kind, dir: freezeProc.dir, files: files };
        }
    }
    // Where the overlay saves what was chosen.
    function snipTarget() {
        if (!snip) return "";
        if (snip.kind === "ocr") return snip.dir + "/text.png";
        return picturesDir + "/Screenshot_" + Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss") + ".png";
    }
    function cancelSnip() {
        if (!snip) return;
        const dir = snip.dir;
        snip = null;
        busy = false;
        cleanSnip(dir);
    }
    // The overlay has written the chosen part to `path`.
    function snipSaved(path) {
        if (!snip) return;
        const s = snip;
        snip = null;
        if (s.kind === "ocr") {
            ocrFileProc.command = ["sh", "-c",
                'command -v tesseract >/dev/null 2>&1 || exit 4; '
                // At twice the size: screen text is small, and tesseract
                // reads it far better enlarged — grim -s did this before.
                + 'f=$1; lang=$2; dir=$3; '
                + 'if command -v magick >/dev/null 2>&1; then magick "$f" -resize 200% "$f.2x.png" && f="$f.2x.png"; fi; '
                + 'tesseract "$f" stdout -l "$lang" 2>/dev/null; r=$?; rm -rf "$dir"; exit $r',
                "ocr", path, prefs.captureOcrLang || "eng", s.dir];
            ocrFileProc.running = true;
            return;
        }
        copyProc.command = ["sh", "-c", 'wl-copy --type image/png < "$1" 2>/dev/null; rm -rf "$2"; true', "copy", path, s.dir];
        copyProc.file = path;
        copyProc.running = true;
    }
    function snipFailed(why) {
        const dir = snip ? snip.dir : "";
        snip = null;
        busy = false;
        cleanSnip(dir);
        say("Screenshot failed", why || "The picture could not be saved", "", []);
    }
    Process {
        id: copyProc
        property string file: ""
        onExited: { root.busy = false; root.delivered(copyProc.file); }
    }
    Process {
        id: ocrFileProc
        stdout: StdioCollector { id: ocrFileOut }
        onExited: code => { root.busy = false; root.ocrResult(code, ocrFileOut.text); }
    }
    Process { id: cleanProc }
    function cleanSnip(dir) {
        if (!dir || dir.indexOf("hyprshell-snip-") < 0) return;
        cleanProc.command = ["rm", "-rf", dir];
        cleanProc.running = true;
    }
    // A finished screenshot: to the editor, or announced.
    function delivered(f) {
        lastShot = f;
        if (prefs.captureEdit === "always") edit(f);
        else say("Screenshot saved", "Copied to the clipboard · " + f.replace(/^.*\//, ""), f,
                 [["edit", "Edit"], ["folder", "Show in Files"]]);
    }

    // ── the editor ───────────────────────────────────────────────────────
    function edit(path) { Config.UiState.shotEditorPath = path || lastShot; }

    // ── text from the screen ─────────────────────────────────────────────
    function runOcr() {
        ocrProc.command = ["sh", "-c",
            'command -v tesseract >/dev/null 2>&1 || exit 4; '
            + 'g=$(slurp -d < /dev/null) || exit 1; '
            // At twice the size: screen text is small, and tesseract reads
            // it far better enlarged.
            + 'grim -s 2 -g "$g" - | tesseract stdin stdout -l "$1" 2>/dev/null',
            "ocr", prefs.captureOcrLang || "eng"];
        ocrProc.running = true;
    }
    Process {
        id: ocrProc
        stdout: StdioCollector { id: ocrOut }
        onExited: code => {
            root.busy = false;
            root.pending = null;
            root.ocrResult(code, ocrOut.text);
        }
    }
    function ocrResult(code, out) {
        {
            if (code === 1) return;
            if (code === 4) { root.say("Text from screen", "Needs tesseract — sudo pacman -S tesseract tesseract-data-eng", "", []); return; }
            const text = out.replace(/\f/g, "").trim();
            if (text === "") { root.say("Text from screen", "No text found in that area.", "", []); return; }
            Quickshell.clipboardText = text;
            const first = text.split("\n")[0];
            root.say("Text copied", (first.length > 80 ? first.slice(0, 80) + "…" : first)
                     + (text.indexOf("\n") >= 0 ? " (+" + (text.split("\n").length - 1) + " lines)" : ""), "", []);
        }
    }

    // ── recording ────────────────────────────────────────────────────────
    property bool recording: false
    property real recordingSince: 0
    property string recordingFile: ""
    property real now: Date.now()
    Timer { interval: 1000; running: root.recording; repeat: true; onTriggered: root.now = Date.now() }
    readonly property int recordedSeconds: recording && recordingSince > 0 ? Math.max(0, Math.floor((now - recordingSince) / 1000)) : 0

    function record(mode, audio) {
        if (recording) { stopRecording(); return; }
        if (busy) return;
        busy = true;
        Config.UiState.closeAll();
        pending = { kind: "record", mode: mode || "screen", audio: audio !== undefined ? audio : prefs.captureAudio };
        settle.restart();
    }
    function toggleRecording() { recording ? stopRecording() : record(prefs.captureRecordMode); }
    function stopRecording() { if (recProc.running) recProc.signal(2); }

    function audioDevice(kind) {
        if (kind === "desktop") {
            const s = Pipewire.defaultAudioSink;
            return s ? s.name + ".monitor" : "";
        }
        if (kind === "mic") {
            const m = Pipewire.defaultAudioSource;
            return m ? m.name : "";
        }
        return "";
    }

    function runRecord(p) {
        const dev = audioDevice(p.audio);
        recProc.command = ["sh", "-c",
            'command -v wf-recorder >/dev/null 2>&1 || exit 4; '
            + 'mode=$1; dev=$2; dir=$3; out=$4; mkdir -p "$dir" || exit 3; '
            + 'f="$dir/Recording_$(date +%Y-%m-%d_%H-%M-%S).mp4"; '
            + 'set -- -f "$f"; '
            + 'if [ "$mode" = region ]; then g=$(slurp -d < /dev/null) || exit 1; set -- "$@" -g "$g"; '
            + 'elif [ -n "$out" ]; then set -- "$@" -o "$out"; fi; '
            + '[ -n "$dev" ] && set -- "$@" "--audio=$dev"; '
            + 'printf "FILE %s\\n" "$f"; '
            + 'exec wf-recorder -y "$@"',
            "record", p.mode, dev, videosDir, focusedOutput()];
        recProc.running = true;
    }
    Process {
        id: recProc
        stdout: SplitParser {
            onRead: line => {
                if (line.indexOf("FILE ") === 0) {
                    root.recordingFile = line.slice(5);
                    root.recordingSince = Date.now();
                    root.now = Date.now();
                    root.recording = true;
                    root.busy = false;
                }
            }
        }
        stderr: StdioCollector { id: recErr }
        onExited: code => {
            const was = root.recording;
            root.recording = false;
            root.busy = false;
            root.pending = null;
            if (code === 1 && !was) return;   // the selection was cancelled
            if (code === 4) { root.say("Screen recording", "Needs wf-recorder — sudo pacman -S wf-recorder", "", []); return; }
            if (!was) {
                root.say("Recording failed", recErr.text.trim().split("\n").pop() || ("wf-recorder exited with " + code), "", []);
                return;
            }
            root.say("Recording saved", root.clock(root.recordedSecondsAtStop()) + " · " + root.recordingFile.replace(/^.*\//, ""),
                     "", [["open", "Play"], ["folder", "Show in Files"]], root.recordingFile);
        }
    }
    function recordedSecondsAtStop() { return Math.max(0, Math.round((Date.now() - recordingSince) / 1000)); }
    function clock(s) {
        const two = n => (n < 10 ? "0" : "") + n;
        return Math.floor(s / 60) + ":" + two(s % 60);
    }

    // ── telling you ──────────────────────────────────────────────────────
    // A notification, with the shot itself as its picture, and actions
    // answered here.
    component Note: Process {
        id: note
        property string file: ""
        stdout: StdioCollector {
            onStreamFinished: {
                const act = text.trim();
                if (act === "edit") root.edit(note.file);
                else if (act === "folder") Config.Apps.launch(Config.Apps.filesCommand(note.file.replace(/\/[^/]*$/, "")));
                else if (act === "open") Quickshell.execDetached(["xdg-open", note.file]);
            }
        }
        onExited: note.destroy()
    }
    Component { id: noteComp; Note {} }
    function say(title, body, image, actions, file) {
        const args = ["notify-send", "-a", "Screenshot", "-i", "camera-photo"];
        if (image) args.push("-h", "string:image-path:file://" + image);
        for (const a of (actions || [])) args.push("-A", a[0] + "=" + a[1]);
        if (actions && actions.length > 0) args.push("--wait");
        args.push(title, body);
        const p = noteComp.createObject(root, { command: args, file: file || image || "" });
        p.running = true;
    }
}
