pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// Updates to Hyprshell itself (Settings → Updates): which parts of it have
// new commits on GitHub, from scripts/hyprshell-update.py, and putting them
// in when asked — in a terminal, where the installers can ask for your
// password and you can see what they do. Never on its own: a check only
// looks.
Singleton {
    id: root

    readonly property string script: (Quickshell.shellDir || Quickshell.shellRoot || "") + "/scripts/hyprshell-update.py"
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/hyprshell"

    property bool checking: false
    property string error: ""
    property string repo: ""
    property string branch: ""
    property bool localChanges: false
    property real checkedAt: 0
    // [{ id, name, note, behind, commits: [{ hash, subject, when }], root }]
    property var parts: []
    readonly property int pending: parts.reduce((n, p) => n + (p.behind > 0 ? 1 : 0), 0)

    function check() {
        if (checking) return;
        checking = true;
        checkProc.running = true;
    }
    Process {
        id: checkProc
        command: ["python3", root.script, "check"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    root.repo = r.repo || "";
                    root.branch = r.branch || "";
                    root.error = r.error || "";
                    root.localChanges = !!r.localChanges;
                    root.parts = r.parts || [];
                } catch (e) {
                    root.error = "The update check didn't answer (" + e + ")";
                }
                root.checkedAt = Date.now();
            }
        }
        onExited: code => {
            root.checking = false;
            if (code !== 0 && root.error === "") root.error = "The update check failed (python3 is needed)";
        }
    }

    // One part, or "all": pulled and installed in a terminal.
    function update(id) {
        Quickshell.execDetached(["sh", "-c", Config.Apps.termFinder, "hyprshell-update",
                                 "-e", "python3", root.script, "run", id]);
        done.reload();
        lastDone = done.text();
        waiting.restart();
    }

    // The terminal's run writes this when it's done; then it's looked at
    // again. Watched, and also read every few seconds while one may be
    // running, as a watch on a file not yet there can miss its arrival.
    property string lastDone: ""
    FileView {
        id: done
        path: root.stateDir + "/update-done"
        watchChanges: true
        printErrors: false
        blockLoading: true
        onFileChanged: reload()
        // Only while an update was started from here: read at startup it
        // means nothing, and a check fetches from GitHub.
        onLoaded: if (waiting.running && text() !== root.lastDone) {
            root.lastDone = text();
            waiting.stop();
            root.check();
        }
    }
    Timer {
        id: waiting
        interval: 4000
        repeat: true
        // An install can take a while (the apps build); half an hour at most.
        property int ticks: 0
        onRunningChanged: if (running) ticks = 0
        onTriggered: {
            if (++ticks > 450) { stop(); return; }
            done.reload();
        }
    }
}
