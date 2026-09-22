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

    // What the last action said when it failed, and which device it was
    // about. bluetoothctl reports real reasons — "Failed to pair:
    // org.bluez.Error.AuthenticationCanceled" — and dropping them left a
    // device that simply never paired and never said why.
    property string lastError: ""
    property string busyMac: ""
    readonly property var connectedDevices: devices.filter(d => d.connected)
    // Paired, not merely seen: the list now includes whatever the last scan
    // turned up, and "3 paired" should not count a passing phone.
    readonly property int pairedCount: devices.filter(d => d.paired).length

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

    // "Device AA:BB:CC:DD:EE:FF Name" per line. Connection and pairing state
    // need a second query, so `bluetoothctl info` is folded into one shell
    // pipeline rather than spawning a process per device.
    //
    // `devices` rather than `devices Paired`: everything the adapter knows
    // about, which during a scan includes things not yet paired. Listing
    // only paired devices meant discovery found things the shell then
    // refused to show, and there was no way to pair anything from here.
    Process {
        id: devicesProc
        command: ["sh", "-c",
            "bluetoothctl devices 2>/dev/null | while read -r _ mac name; do "
            + "info=$(bluetoothctl info \"$mac\" 2>/dev/null); "
            + "conn=$(printf '%s' \"$info\" | grep -c 'Connected: yes'); "
            + "pair=$(printf '%s' \"$info\" | grep -c 'Paired: yes'); "
            + "trust=$(printf '%s' \"$info\" | grep -c 'Trusted: yes'); "
            + "icon=$(printf '%s' \"$info\" | sed -n 's/^\\s*Icon:\\s*//p' | head -n1); "
            + "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "
            + "\"$mac\" \"$conn\" \"$pair\" \"$trust\" \"$icon\" \"$name\"; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of text.trim().split("\n")) {
                    if (!line) continue;
                    const parts = line.split("\t");
                    if (parts.length < 6) continue;
                    out.push({
                        mac: parts[0],
                        connected: parts[1] === "1",
                        paired: parts[2] === "1",
                        trusted: parts[3] === "1",
                        kind: parts[4] || "",
                        name: parts[5] || parts[0]
                    });
                }
                // Connected first, then paired, then whatever the scan found.
                out.sort((a, b) => (b.connected - a.connected)
                                   || (b.paired - a.paired)
                                   || a.name.localeCompare(b.name));
                root.devices = out;
            }
        }
    }

    Process {
        id: action
        stdout: StdioCollector {
            onStreamFinished: {
                // bluetoothctl reports failures on stdout, not stderr.
                const m = /(Failed to \w+[^\n]*)/.exec(text);
                root.lastError = m ? m[1] : "";
            }
        }
        onExited: code => {
            if (code === 0 && !root.lastError) root.lastError = "";
            root.busyMac = "";
            root.refresh();
        }
    }

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

    // Pair, trust, then connect, in one go.
    //
    // Pairing alone leaves a device that has to be connected by hand every
    // time, and an untrusted one has to be re-authorised on every
    // reconnect — so all three are what "pair" means to anyone who is not
    // reading bluetoothctl's manual.
    //
    // --agent NoInputOutput accepts the "just works" pairing that headphones,
    // mice and most keyboards use. Anything that wants a passkey typed in
    // needs a terminal agent, and says so through lastError rather than
    // hanging.
    function pairDevice(mac) {
        if (!mac) return;
        lastError = "";
        busyMac = mac;
        action.command = ["sh", "-c",
            "bluetoothctl --agent NoInputNoOutput pair \"$1\" && "
            + "bluetoothctl trust \"$1\" && bluetoothctl connect \"$1\"",
            "bt-pair", mac];
        action.running = true;
    }

    // Drops the pairing entirely; the device has to be paired again after.
    function removeDevice(mac) {
        if (!mac) return;
        lastError = "";
        busyMac = mac;
        action.command = ["bluetoothctl", "remove", mac];
        action.running = true;
    }

    function connectDevice(mac) {
        busyMac = mac;
        action.command = ["bluetoothctl", "connect", mac];
        action.running = true;
    }

    function disconnectDevice(mac) {
        busyMac = mac;
        action.command = ["bluetoothctl", "disconnect", mac];
        action.running = true;
    }

    // One tap does the obvious thing for whatever state the device is in.
    function toggleDevice(dev) {
        if (!dev) return;
        if (dev.connected) disconnectDevice(dev.mac);
        else if (!dev.paired) pairDevice(dev.mac);
        else connectDevice(dev.mac);
    }

    // What that tap will do, for a button label.
    function actionFor(dev) {
        if (!dev) return "";
        if (dev.connected) return "Disconnect";
        return dev.paired ? "Connect" : "Pair";
    }
}
