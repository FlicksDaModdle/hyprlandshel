pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Runs hyprshell-daemon (shell/rust/daemon): network, backlight, audio-device
// and night-light state, read straight from NetworkManager, sysfs,
// PulseAudio and /proc and pushed here as it changes — where the services
// otherwise poll nmcli, brightnessctl, pactl and pgrep.
//
// JSON a line each way, like hyprshell-agent (Agent.qml). The services
// listen to `event` and look at `has(module)`; each keeps its command-line
// path for when the daemon isn't built (no cargo at install time) or a
// part of it can't reach what it reads.
Singleton {
    id: root

    property bool running: false
    property bool missing: false
    property var modules: ({})

    // Which parts are answering: the network part says so in each event,
    // so a machine without NetworkManager falls back for that alone.
    property bool netLive: false
    property bool paLive: false
    property bool backlightLive: false
    property bool nightLightLive: false

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
            'for p in "$1/bin/hyprshell-daemon" "$(command -v hyprshell-daemon 2>/dev/null)"; do\n'
          + '  [ -n "$p" ] && [ -x "$p" ] && exec "$p"\n'
          + 'done\n'
          + 'exit 127', "daemon", root.shellDir]
        running: true
        stdout: SplitParser {
            onRead: line => {
                let ev;
                try { ev = JSON.parse(line); } catch (e) { return; }
                switch (ev.ev) {
                case "ready":      root.running = true; root.modules = ev.modules || {}; break;
                case "net":        root.netLive = ev.available === true; break;
                case "pa":         root.paLive = ev.available === true; break;
                case "backlight":  root.backlightLive = ev.available === true; break;
                case "nightlight": root.nightLightLive = true; break;
                }
                root.event(ev);
            }
        }
        stderr: SplitParser { onRead: line => console.log("hyprshell-daemon:", line) }
        onExited: code => {
            root.running = false;
            root.netLive = root.paLive = root.backlightLive = root.nightLightLive = false;
            root.event({ ev: "exited", code: code });
            if (code === 127) { root.missing = true; return; }
            restart.interval = Math.min(30000, restart.interval * 2);
            restart.start();
        }
    }

    Timer {
        id: restart
        interval: 1000
        onTriggered: proc.running = true
    }
    Timer {
        running: root.running
        interval: 60000
        onTriggered: restart.interval = 1000
    }
}
