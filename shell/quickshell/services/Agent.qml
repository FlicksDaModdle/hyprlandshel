pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Runs hyprshell-agent (shell/agent): the shell's Bluetooth backend and
// pairing agent, and its NetworkManager secret agent — what KDE's own
// background services do for its Bluetooth and network settings.
//
// One process for both, speaking JSON a line at a time. Bluetooth.qml and
// Network.qml listen to `event` and talk back through send(). The helper
// exits when its stdin closes, so a shell reload takes its agents with it
// and the new shell registers fresh ones.
//
// Built by install.sh into bin/ beside this tree. Without it — not built,
// or no Qt headers — `running` stays false, and Bluetooth.qml falls back to
// bluetoothctl, which can pair what asks no questions.
Singleton {
    id: root

    property bool running: false
    // Exited straight away for want of the binary: no point retrying.
    property bool missing: false
    property bool btAgent: false
    property bool nmAgent: false
    property string lastError: ""

    signal event(var ev)

    function send(obj) {
        if (!proc.running) return false;
        proc.write(JSON.stringify(obj) + "\n");
        return true;
    }

    readonly property string shellDir: Quickshell.shellDir || Quickshell.shellRoot || ""

    Process {
        id: proc
        stdinEnabled: true
        command: ["sh", "-c",
            'for p in "$1/bin/hyprshell-agent" "$(command -v hyprshell-agent 2>/dev/null)"; do\n'
          + '  [ -n "$p" ] && [ -x "$p" ] && exec "$p"\n'
          + 'done\n'
          + 'exit 127', "agent", root.shellDir]
        running: true
        stdout: SplitParser {
            onRead: line => {
                let ev;
                try { ev = JSON.parse(line); } catch (e) { return; }
                if (ev.ev === "ready") root.running = true;
                else if (ev.ev === "bt-agent") root.btAgent = !!ev.ok;
                else if (ev.ev === "nm-agent") root.nmAgent = !!ev.ok;
                else if (ev.ev === "fatal") root.lastError = ev.message || "";
                root.event(ev);
            }
        }
        stderr: SplitParser { onRead: line => console.log("hyprshell-agent:", line) }
        onExited: code => {
            root.running = false;
            root.btAgent = false;
            root.nmAgent = false;
            root.event({ ev: "exited", code: code });
            if (code === 127) { root.missing = true; return; }
            // A crash, or bluetoothd/NetworkManager restarting under it in a
            // way it did not survive: start again, a little later each time.
            restart.interval = Math.min(30000, restart.interval * 2);
            restart.start();
        }
    }

    Timer {
        id: restart
        interval: 1000
        onTriggered: proc.running = true
    }
    // A run that lasted resets the backoff.
    Timer {
        running: root.running
        interval: 60000
        onTriggered: restart.interval = 1000
    }
}
