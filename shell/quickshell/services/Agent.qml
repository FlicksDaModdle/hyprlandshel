pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Services

// The shell's Bluetooth backend and pairing agent, and its NetworkManager
// secret agent — what KDE's own background services do for its Bluetooth
// and network settings.
//
// Two programs can answer, speaking the same JSON: hyprshell-daemon (Rust,
// shell/rust), which does it beside the network, audio and backlight work
// it already does; and hyprshell-agent (C++, shell/agent), the separate
// process it replaces. The daemon is used when it has the part; the C++
// helper runs only when the daemon isn't built (no cargo at install time)
// or is an older one without it — never both, since only one may be
// BlueZ's agent. Bluetooth.qml and Network.qml listen to `event` and talk
// back through send() and don't know which answered.
//
// Without either, `running` stays false, and Bluetooth.qml falls back to
// bluetoothctl, which can pair what asks no questions.
Singleton {
    id: root

    readonly property bool viaDaemon: Services.Daemon.running && Services.Daemon.modules.agent === true
    // The daemon is gone for good or answered without the part.
    readonly property bool useHelper: Services.Daemon.missing
        || (Services.Daemon.running && Services.Daemon.modules.agent !== true)

    property bool helperRunning: false
    property bool helperLaunched: false
    readonly property bool running: viaDaemon || helperRunning
    // Neither can be started: no point waiting.
    readonly property bool missing: helperMissing && useHelper
    property bool helperMissing: false
    property bool btAgent: false
    property bool nmAgent: false
    property string lastError: ""

    signal event(var ev)

    function send(obj) {
        if (root.viaDaemon) return Services.Daemon.send(obj);
        if (!proc.running) return false;
        proc.write(JSON.stringify(obj) + "\n");
        return true;
    }

    readonly property string shellDir: Quickshell.shellDir || Quickshell.shellRoot || ""

    function take(ev) {
        if (ev.ev === "bt-agent") root.btAgent = !!ev.ok;
        else if (ev.ev === "nm-agent") root.nmAgent = !!ev.ok;
        else if (ev.ev === "fatal" || ev.ev === "agent-fatal") root.lastError = ev.message || "";
        root.event(ev);
    }

    function lost() {
        root.btAgent = false;
        root.nmAgent = false;
        root.event({ ev: "exited" });
    }

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            const t = ev.ev || "";
            if (t === "exited") {
                if (!root.helperRunning) root.lost();
            } else if (t.startsWith("bt") || t.startsWith("nm-") || t === "agent-fatal") {
                if (root.viaDaemon) root.take(ev);
            }
        }
    }

    onUseHelperChanged: {
        if (useHelper && !proc.running && !helperMissing) proc.running = true;
        else if (!useHelper && proc.running) proc.running = false;
    }
    Component.onCompleted: if (useHelper) proc.running = true

    Process {
        id: proc
        stdinEnabled: true
        command: ["sh", "-c",
            'for p in "$1/bin/hyprshell-agent" "$(command -v hyprshell-agent 2>/dev/null)"; do\n'
          + '  [ -n "$p" ] && [ -x "$p" ] && exec "$p"\n'
          + 'done\n'
          + 'exit 127', "agent", root.shellDir]
        stdout: SplitParser {
            onRead: line => {
                let ev;
                try { ev = JSON.parse(line); } catch (e) { return; }
                if (ev.ev === "ready") root.helperRunning = true;
                root.take(ev);
            }
        }
        stderr: SplitParser { onRead: line => console.log("hyprshell-agent:", line) }
        onStarted: root.helperLaunched = true
        onExited: code => {
            // Quickshell can report an exit for a process never started.
            if (!root.helperLaunched) return;
            root.helperLaunched = false;
            root.helperRunning = false;
            root.lost();
            if (code === 127) { root.helperMissing = true; return; }
            if (!root.useHelper) return;
            // A crash, or bluetoothd/NetworkManager restarting under it in a
            // way it did not survive: start again, a little later each time.
            restart.interval = Math.min(30000, restart.interval * 2);
            restart.start();
        }
    }

    Timer {
        id: restart
        interval: 1000
        onTriggered: if (root.useHelper) proc.running = true
    }
    // A run that lasted resets the backoff.
    Timer {
        running: root.helperRunning
        interval: 60000
        onTriggered: restart.interval = 1000
    }
}
