pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Bluetooth through bluetoothctl. Same reasoning as Network.qml: the native
// Quickshell.Bluetooth module is recent, bluetoothctl is everywhere.
//
// Feeds the control center's Bluetooth tile, its device drill-down, and
// Settings → Bluetooth.
Singleton {
    id: root

    property bool available: false
    property bool powered: false
    property bool discoverable: false
    property bool discovering: false
    property string controller: ""

    // [{ mac, name, connected, paired }]
    property var devices: []
    readonly property var connectedDevices: devices.filter(d => d.connected)
    readonly property int pairedCount: devices.length

    readonly property string label: !available ? "no adapter"
                                  : !powered ? "off"
                                  : (connectedDevices.length > 0
                                     ? connectedDevices[0].name
                                     : pairedCount + (pairedCount === 1 ? " paired" : " paired"))

    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function refresh() {
        showProc.running = true;
        devicesProc.running = true;
    }

    Process {
        id: showProc
        command: ["bluetoothctl", "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (!text.trim()) { root.available = false; return; }
                root.available = true;
                const ctrl = /Controller\s+(\S+)/.exec(text);
                root.controller = ctrl ? ctrl[1] : "";
                root.powered = /Powered:\s*yes/.test(text);
                root.discoverable = /Discoverable:\s*yes/.test(text);
                root.discovering = /Discovering:\s*yes/.test(text);
            }
        }
        onExited: code => { if (code !== 0) root.available = false; }
    }

    // "Device AA:BB:CC:DD:EE:FF Name" per line. Connection state needs a
    // second query, so `bluetoothctl info` is folded into one shell pipeline
    // rather than spawning a process per device.
    Process {
        id: devicesProc
        command: ["sh", "-c",
            "bluetoothctl devices Paired 2>/dev/null | while read -r _ mac name; do "
            + "state=$(bluetoothctl info \"$mac\" 2>/dev/null | grep -c 'Connected: yes'); "
            + "printf '%s\\t%s\\t%s\\n' \"$mac\" \"$state\" \"$name\"; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of text.trim().split("\n")) {
                    if (!line) continue;
                    const parts = line.split("\t");
                    if (parts.length < 3) continue;
                    out.push({
                        mac: parts[0],
                        connected: parts[1] === "1",
                        paired: true,
                        name: parts[2] || parts[0]
                    });
                }
                // Connected devices first, then alphabetical.
                out.sort((a, b) => (b.connected - a.connected) || a.name.localeCompare(b.name));
                root.devices = out;
            }
        }
    }

    Process { id: action; onExited: root.refresh() }

    function setPowered(on) {
        powered = on;
        action.command = ["bluetoothctl", "power", on ? "on" : "off"];
        action.running = true;
    }

    function togglePowered() { setPowered(!powered); }

    function setDiscoverable(on) {
        discoverable = on;
        action.command = ["bluetoothctl", "discoverable", on ? "on" : "off"];
        action.running = true;
    }

    function scan() {
        // `--timeout` keeps the scan bounded so it can't run forever if the
        // panel is closed mid-discovery.
        action.command = ["bluetoothctl", "--timeout", "15", "scan", "on"];
        action.running = true;
    }

    function connectDevice(mac) {
        action.command = ["bluetoothctl", "connect", mac];
        action.running = true;
    }

    function disconnectDevice(mac) {
        action.command = ["bluetoothctl", "disconnect", mac];
        action.running = true;
    }

    function toggleDevice(dev) {
        if (!dev) return;
        if (dev.connected) disconnectDevice(dev.mac);
        else connectDevice(dev.mac);
    }
}
