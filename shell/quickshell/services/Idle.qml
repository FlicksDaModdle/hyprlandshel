pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// What happens when you leave the machine alone: lock, screen off, sleep.
//
// Built in, through hyprshell-daemon (rust/daemon/src/idle.rs): the
// compositor's idle timers, which an app keeping the screen on (a video,
// a call) already holds; held here too while media plays or a window is
// fullscreen, if chosen, and by the control center's Keep awake. Lock
// draws the shell's own lock screen; screen off and on go to Hyprland;
// sleep to logind, with the screen locked first whoever asked for it.
//
// Without the daemon, hypridle: configured by a file rather than by any
// control interface, so this reads and writes ~/.config/hypr/hypridle.conf
// and restarts it. The file is not ours — people put their own listeners
// in it — so the three this panel manages are written inside a marked
// block and everything outside it is carried across untouched. Moving to
// the built-in one takes that block's timings and then removes the block.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance
    readonly property bool builtin: Services.Daemon.running && Services.Daemon.modules.idle === true
    // The control center's Keep awake: until switched off or the shell
    // restarts.
    property bool keepAwake: false
    property var held: []
    property string error: ""

    readonly property bool mediaHold: prefs.idleHoldMedia && Services.Media.playing
    readonly property bool fullscreenHold: prefs.idleHoldFullscreen
        && !!Services.Compositor.activeClient && Services.Compositor.activeClient.fullscreenMode === 2
    onKeepAwakeChanged: hold("awake", keepAwake)
    onMediaHoldChanged: hold("media", mediaHold)
    onFullscreenHoldChanged: hold("fullscreen", fullscreenHold)
    function hold(why, on) { if (builtin) Services.Daemon.send({ cmd: "idle-hold", why: why, on: on }); }

    function configure() {
        if (!builtin || !prefs.settingsReady) return;
        Services.Daemon.send({ cmd: "idle-config", lock: prefs.idleLock * 60, off: prefs.idleOff * 60,
                               suspend: prefs.idleSuspend * 60 });
        Services.Daemon.send({ cmd: "idle-lock-before-sleep", on: Services.Session.lockBeforeSleep });
        hold("awake", keepAwake);
        hold("media", mediaHold);
        hold("fullscreen", fullscreenHold);
    }
    readonly property string config: [builtin, prefs.settingsReady, prefs.idleLock, prefs.idleOff, prefs.idleSuspend].join("|")
    onConfigChanged: configSoon.restart()
    Timer { id: configSoon; interval: 150; onTriggered: { root.migrate(); root.configure(); } }

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "idle") {
                root.held = ev.held || [];
                root.error = ev.error || "";
            } else if (ev.ev === "idle-action") {
                switch (ev.action) {
                case "lock":
                    Config.UiState.lock();
                    // Give the lock surface a moment to be on screen
                    // before a waiting sleep goes ahead.
                    lockedSoon.restart();
                    break;
                case "screen-off": Services.Compositor.dispatch('hl.dsp.dpms({ action = "off" })'); break;
                case "screen-on":  Services.Compositor.dispatch('hl.dsp.dpms({ action = "on" })'); break;
                }
            }
        }
    }
    Timer { id: lockedSoon; interval: 400; onTriggered: Services.Daemon.send({ cmd: "idle-locked" }) }

    // Once: hypridle's timings (from our block in its file) become the
    // built-in one's, the block goes, and hypridle stops unless the file
    // still has listeners of its own.
    function migrate() {
        if (!builtin || !prefs.settingsReady || prefs.idleMigrated || !root.loaded) return;
        const body = file.text() || "";
        const a = body.indexOf(root.beginMark), b = body.indexOf(root.endMark);
        if (a >= 0 && b > a) {
            prefs.idleLock = root.fileLock;
            prefs.idleOff = root.fileOff;
            prefs.idleSuspend = root.fileSuspend;
            const rest = (body.slice(0, a) + body.slice(b + root.endMark.length))
                .replace(/\n{3,}/g, "\n\n").replace(/\s+$/, "");
            migrateProc.command = ["sh", "-c",
                'if [ -n "$2" ]; then printf "%s\\n" "$2" > "$1"; else : > "$1"; fi; '
                + 'pkill -x hypridle >/dev/null 2>&1; '
                + 'grep -q listener "$1" && (setsid hypridle >/dev/null 2>&1 &); true',
                "idle", root.path, rest];
            migrateProc.running = true;
        } else {
            stopHypridle.running = true;
        }
        prefs.idleMigrated = true;
    }
    property Process migrateProc: Process {}
    property Process stopHypridle: Process {
        command: ["sh", "-c", 'f="$HOME/.config/hypr/hypridle.conf"; [ -f "$f" ] && grep -q listener "$f" || pkill -x hypridle; true']
    }

    // Minutes. 0 is off, and off means the listener is not written at all
    // rather than written with a timeout of zero, which hypridle reads as
    // "immediately".
    property int fileLock: 10
    property int fileOff: 12
    property int fileSuspend: 30
    // What Settings shows: the built-in timings when built in.
    readonly property int lockAfter: builtin ? prefs.idleLock : fileLock
    readonly property int screenOffAfter: builtin ? prefs.idleOff : fileOff
    readonly property int suspendAfter: builtin ? prefs.idleSuspend : fileSuspend
    function setLock(v) { if (builtin) prefs.idleLock = v; else { fileLock = v; save(); } }
    function setOff(v) { if (builtin) prefs.idleOff = v; else { fileOff = v; save(); } }
    function setSuspend(v) { if (builtin) prefs.idleSuspend = v; else { fileSuspend = v; save(); } }

    property bool hypridle: false
    readonly property bool available: builtin || hypridle
    property bool loaded: false
    property string lastError: ""

    readonly property string path:
        Quickshell.env("HOME") + "/.config/hypr/hypridle.conf"

    readonly property string beginMark: "# >>> hyprshell idle >>>"
    readonly property string endMark:   "# <<< hyprshell idle <<<"

    // ── reading ───────────────────────────────────────────────────────────
    FileView {
        id: file
        path: root.path
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.parse(file.text())
        // A machine with no hypridle config yet is the normal case on a
        // fresh install, not an error.
        onLoadFailed: { root.loaded = true; root.parse(""); }
    }

    function parse(text) {
        const body = String(text || "");
        // Only our own block is read back. A listener someone wrote by hand
        // outside it is theirs, and reporting it here as if this panel had
        // set it would mean the next save silently rewrote it.
        const a = body.indexOf(root.beginMark);
        const b = body.indexOf(root.endMark);
        const block = (a >= 0 && b > a) ? body.slice(a, b) : "";

        root.fileLock = root.readTimer(block, "loginctl lock-session");
        root.fileOff = root.readTimer(block, "dpms off");
        root.fileSuspend = root.readTimer(block, "systemctl suspend");
        root.loaded = true;
        configSoon.restart();
    }

    // Each listener is a `timeout` line followed by the command it runs, so
    // the command is what identifies it and the timeout is the line above.
    function readTimer(block, needle) {
        const lines = block.split("\n");
        let pending = 0;
        for (const line of lines) {
            const t = /^\s*timeout\s*=\s*(\d+)/.exec(line);
            if (t) { pending = parseInt(t[1], 10) || 0; continue; }
            if (line.indexOf(needle) >= 0 && pending > 0)
                return Math.round(pending / 60);
        }
        return 0;
    }

    // ── writing ───────────────────────────────────────────────────────────
    function listener(minutes, onTimeout, onResume) {
        if (minutes <= 0) return "";
        return "listener {\n"
             + "    timeout = " + Math.round(minutes * 60) + "\n"
             + "    on-timeout = " + onTimeout + "\n"
             + (onResume ? "    on-resume = " + onResume + "\n" : "")
             + "}\n";
    }

    function save() {
        const block = root.beginMark + "\n"
            + "# Written by Hyprshell (Settings -> Display). Anything outside\n"
            + "# these two markers is left alone; anything inside is not.\n"
            + root.listener(root.fileLock, "loginctl lock-session", "")
            // Screen off has to come with its counterpart, or the panel
            // stays dark when you come back to it.
            + root.listener(root.fileOff, "hyprctl dispatch dpms off",
                            "hyprctl dispatch dpms on")
            + root.listener(root.fileSuspend, "systemctl suspend", "")
            + root.endMark + "\n";

        // The rest of the file, with any previous block of ours cut out.
        let body = file.text() || "";
        const a = body.indexOf(root.beginMark);
        const b = body.indexOf(root.endMark);
        if (a >= 0 && b > a)
            body = body.slice(0, a) + body.slice(b + root.endMark.length);
        body = body.replace(/\n{3,}/g, "\n\n");
        // Trailing whitespace trimmed outright and the gap written back
        // deliberately, so saving twice produces the same file. Joining
        // "whatever was left" to the block grew the file by a newline on
        // every save — which is how the Kvantum config used to behave, and
        // the reason anything that rewrites a file here gets a fixpoint
        // test.
        body = body.replace(/\s+$/, "");
        const composed = (body === "" ? "" : body + "\n\n") + block;

        // The text as an argument: Quickshell's Process has no stdin text
        // to hand over (a `stdinText` assignment here failed outright, so
        // these settings never saved).
        writeProc.command = ["sh", "-c",
            'mkdir -p "$(dirname "$1")" && printf "%s\\n" "$2" > "$1" && '
            // Restart rather than reload: hypridle has no reload signal, and
            // a daemon that is not running yet has to be started anyway.
            + '{ pkill -x hypridle >/dev/null 2>&1 || true; } && '
            + 'sleep 0.2 && (setsid hypridle >/dev/null 2>&1 &) && echo ok',
            "idle", root.path, composed.replace(/\n$/, "")];
        writeProc.running = true;
    }

    property Process writeProc: Process {
        onExited: (code) => {
            root.lastError = code === 0 ? "" : "could not write " + root.path;
        }
    }

    // ── is hypridle even here ─────────────────────────────────────────────
    property Process probe: Process {
        running: true
        command: ["sh", "-c", "command -v hypridle >/dev/null 2>&1 && echo yes"]
        stdout: StdioCollector {
            onStreamFinished: root.hypridle = text.trim() === "yes"
        }
    }
}
