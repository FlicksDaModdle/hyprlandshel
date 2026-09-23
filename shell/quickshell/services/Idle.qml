pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// What happens when you leave the machine alone: lock, screen off, sleep.
//
// hypridle owns this, and hypridle is configured by a file rather than by
// any control interface, so this reads and writes
// ~/.config/hypr/hypridle.conf and restarts the daemon. The file is not
// ours — people put their own listeners in it — so the three this panel
// manages are written inside a marked block and everything outside it is
// carried across untouched.
Singleton {
    id: root

    // Minutes. 0 is off, and off means the listener is not written at all
    // rather than written with a timeout of zero, which hypridle reads as
    // "immediately".
    property int lockAfter: 10
    property int screenOffAfter: 12
    property int suspendAfter: 30

    property bool available: false
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

        root.lockAfter = root.readTimer(block, "loginctl lock-session");
        root.screenOffAfter = root.readTimer(block, "dpms off");
        root.suspendAfter = root.readTimer(block, "systemctl suspend");
        root.loaded = true;
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
            + root.listener(root.lockAfter, "loginctl lock-session", "")
            // Screen off has to come with its counterpart, or the panel
            // stays dark when you come back to it.
            + root.listener(root.screenOffAfter, "hyprctl dispatch dpms off",
                            "hyprctl dispatch dpms on")
            + root.listener(root.suspendAfter, "systemctl suspend", "")
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

        writeProc.command = ["sh", "-c",
            'mkdir -p "$(dirname "$1")" && cat > "$1" && '
            // Restart rather than reload: hypridle has no reload signal, and
            // a daemon that is not running yet has to be started anyway.
            + '{ pkill -x hypridle >/dev/null 2>&1 || true; } && '
            + 'sleep 0.2 && (setsid hypridle >/dev/null 2>&1 &) && echo ok',
            "idle", root.path];
        writeProc.stdinText = composed;
        writeProc.running = true;
    }

    property Process writeProc: Process {
        stdinEnabled: true
        onExited: (code) => {
            root.lastError = code === 0 ? "" : "could not write " + root.path;
        }
    }

    // ── is hypridle even here ─────────────────────────────────────────────
    property Process probe: Process {
        running: true
        command: ["sh", "-c", "command -v hypridle >/dev/null 2>&1 && echo yes"]
        stdout: StdioCollector {
            onStreamFinished: root.available = text.trim() === "yes"
        }
    }
}
