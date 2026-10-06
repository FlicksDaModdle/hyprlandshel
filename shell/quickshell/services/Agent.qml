pragma Singleton
import QtQuick
import Quickshell
import "." as Services

// The shell's Bluetooth backend and pairing agent, and its NetworkManager
// secret agent — what KDE's own background services do for its Bluetooth
// and network settings. hyprshell-daemon (shell/rust, src/agent.rs) does
// the work; this is the shell's side of it.
//
// Bluetooth.qml and Network.qml listen to `event` and talk back through
// send(). Without the daemon (no cargo at install time) `running` stays
// false, and Bluetooth.qml falls back to bluetoothctl, which can pair what
// asks no questions.
Singleton {
    id: root

    readonly property bool running: Services.Daemon.running && Services.Daemon.modules.agent === true
    // The daemon is not built, or is too old to have the part.
    readonly property bool missing: Services.Daemon.missing
        || (Services.Daemon.running && Services.Daemon.modules.agent !== true)
    property bool btAgent: false
    property bool nmAgent: false
    property string lastError: ""

    signal event(var ev)

    function send(obj) { return root.running ? Services.Daemon.send(obj) : false; }

    readonly property string shellDir: Quickshell.shellDir || Quickshell.shellRoot || ""

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            const t = ev.ev || "";
            if (t === "exited") {
                root.btAgent = false;
                root.nmAgent = false;
                root.event({ ev: "exited" });
                return;
            }
            if (!(t.startsWith("bt") || t.startsWith("nm-") || t === "agent-fatal")) return;
            if (t === "bt-agent") root.btAgent = !!ev.ok;
            else if (t === "nm-agent") root.nmAgent = !!ev.ok;
            else if (t === "agent-fatal") root.lastError = ev.message || "";
            root.event(ev);
        }
    }
}
