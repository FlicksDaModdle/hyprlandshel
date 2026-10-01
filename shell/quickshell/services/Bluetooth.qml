pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Bluetooth: the adapter, its devices, and pairing.
//
// Through hyprshell-agent (Services.Agent) when it is there: live state from
// BlueZ, and a pairing agent — the thing that answers "does this code match
// the one on the phone?" and "type this code on the keyboard". Pairing
// without one fails with AuthenticationFailed for anything that asks, which
// is phones, most keyboards and many newer headphones.
//
// Without the agent, bluetoothctl as before: polled every few seconds, able
// to pair what asks nothing.
//
// Feeds the control center's Bluetooth tile and list, and Settings →
// Bluetooth.
Singleton {
    id: root

    readonly property bool live: Services.Agent.running

    property bool available: false
    property bool powered: false
    property bool discoverable: false
    property bool discovering: false
    property string controller: ""       // the adapter's name, as others see it

    // [{ mac, name, named, kind, connected, paired, trusted, battery }]
    property var devices: []
    property string devicesKey: ""

    // What failed, per device, in words: { mac: "…" }. And what is under
    // way: { mac: "pair" | "connect" | … }.
    property var errors: ({})
    property var busy: ({})

    // A question from the pairing agent waiting for an answer:
    // { id, kind: confirm | pin | passkey | authorize | service, mac, name,
    //   passkey?, uuid? }. And a code to show while a keyboard is typed on:
    // { kind: pin | passkey, code, mac, name, entered? }.
    property var request: null
    property var display: null

    // Kept for the control center, which shows one line.
    property string lastError: ""
    readonly property string busyMac: Object.keys(root.busy)[0] || ""

    readonly property var connectedDevices: devices.filter(d => d.connected)
    readonly property var pairedDevices: devices.filter(d => d.paired)
    // Found by a scan and not paired. Ones known only by their address are
    // counted but kept out of the list — a crowded room has dozens.
    readonly property var nearbyDevices: devices.filter(d => !d.paired && d.named)
    readonly property int unnamedCount: devices.filter(d => !d.paired && !d.named).length
    readonly property int pairedCount: pairedDevices.length

    readonly property string label: !available ? "no adapter"
                                  : !powered ? "off"
                                  : (connectedDevices.length > 0
                                     ? connectedDevices[0].name
                                     : pairedCount + " paired")

    // ── what it is ────────────────────────────────────────────────────────
    // BlueZ's icon names, as a word and as one of the shell's glyphs.
    function kindLabel(kind) {
        const k = kind || "";
        if (k.indexOf("headset") >= 0 || k.indexOf("headphone") >= 0) return "Headphones";
        if (k.indexOf("audio") >= 0) return "Speaker";
        if (k.indexOf("keyboard") >= 0) return "Keyboard";
        if (k.indexOf("mouse") >= 0) return "Mouse";
        if (k.indexOf("gaming") >= 0 || k.indexOf("joystick") >= 0) return "Controller";
        if (k.indexOf("phone") >= 0) return "Phone";
        if (k.indexOf("computer") >= 0) return "Computer";
        if (k.indexOf("tablet") >= 0) return "Tablet";
        return "";
    }
    function glyph(kind) {
        const k = kind || "";
        if (k.indexOf("headset") >= 0 || k.indexOf("headphone") >= 0) return "headphones";
        if (k.indexOf("audio") >= 0) return "speaker";
        if (k.indexOf("keyboard") >= 0) return "keyboard";
        if (k.indexOf("mouse") >= 0) return "mouse";
        if (k.indexOf("gaming") >= 0 || k.indexOf("joystick") >= 0) return "gamepad";
        if (k.indexOf("computer") >= 0) return "monitor";
        return "bluetooth";
    }

    // BlueZ's errors, as something to do about them.
    function explain(name, message) {
        const n = String(name || ""), m = String(message || "");
        if (/AuthenticationFailed/.test(n))
            return "The device refused to pair. Put it in pairing mode and try again — and if it was "
                 + "paired with another computer (or with Windows on this one), remove that pairing "
                 + "on the device first.";
        if (/AuthenticationCanceled/.test(n))
            return "Pairing was cancelled on the device, or nobody answered in time.";
        if (/AuthenticationRejected/.test(n))
            return "The pairing was declined.";
        if (/AuthenticationTimeout/.test(n))
            return "The device didn't answer in time. Put it in pairing mode and try again.";
        if (/ConnectionAttemptFailed/.test(n) || /page-timeout|Host is down|le-connection-abort/.test(m))
            return "Couldn't reach it. Make sure it's switched on and nearby.";
        if (/profile-unavailable/.test(m))
            return "It paired, but nothing here can use it. For headphones and speakers, PipeWire's "
                 + "Bluetooth support has to be installed (wireplumber with libspa-bluetooth).";
        if (/rfkill|Not Powered|NotReady/.test(n + m))
            return "Bluetooth is switched off or blocked — airplane mode, or the laptop's radio key.";
        if (/InProgress/.test(n))
            return "Already working on it.";
        if (/DoesNotExist/.test(n))
            return "That device is gone — scan again.";
        return m || n;
    }

    // ── through the agent ─────────────────────────────────────────────────
    Connections {
        target: Services.Agent
        function onEvent(ev) {
            switch (ev.ev) {
            case "bt": {
                root.available = !!ev.available;
                const a = ev.adapter || {};
                root.powered = !!a.powered;
                root.discoverable = !!a.discoverable;
                root.discovering = !!a.discovering;
                root.controller = a.name || "";
                // Signal strength is left out: it moves every second during
                // a scan, and each move would rebuild every list showing
                // these for nothing anyone looks at.
                const out = (ev.devices || []).map(d => ({
                    mac: d.mac, name: d.name || d.mac, named: !!d.named, kind: d.icon || "",
                    connected: !!d.connected, paired: !!d.paired, trusted: !!d.trusted,
                    battery: d.battery === undefined ? -1 : d.battery
                }));
                out.sort((x, y) => (y.connected - x.connected) || (y.paired - x.paired)
                                   || x.name.localeCompare(y.name));
                const key = JSON.stringify(out);
                if (key !== root.devicesKey) { root.devicesKey = key; root.devices = out; }
                break;
            }
            case "bt-busy":
                if (ev.mac) root.setBusy(ev.mac, ev.op);
                root.clearError(ev.mac);
                break;
            case "bt-done":
                if (ev.mac) root.setBusy(ev.mac, "");
                // Pairing stops the search (it competes for the radio);
                // with the pane still open, it picks up again after.
                if (Object.keys(root.busy).length === 0) Qt.callLater(root.syncScan);
                if (root.display && root.display.mac === ev.mac) root.display = null;
                if (root.request && root.request.mac === ev.mac) root.request = null;
                break;
            case "bt-error": {
                if (/AlreadyExists|AlreadyConnected/.test(ev.error || "")) break;
                const text = root.explain(ev.error, ev.message);
                root.lastError = text;
                if (ev.mac) {
                    const e = Object.assign({}, root.errors);
                    e[ev.mac] = text;
                    root.errors = e;
                }
                break;
            }
            case "bt-request":
                root.request = ev;
                root.bringForward();
                break;
            case "bt-display":
                root.display = ev;
                root.bringForward();
                break;
            case "bt-cancel":
                root.request = null;
                root.display = null;
                break;
            case "exited":
                root.request = null;
                root.display = null;
                root.busy = ({});
                break;
            }
        }
    }

    // A question nobody can see is a pairing that times out, so Settings
    // comes up on the Bluetooth pane to ask it.
    function bringForward() {
        Config.UiState.openSettings("Bluetooth");
    }

    function setBusy(mac, op) {
        const b = Object.assign({}, root.busy);
        if (op) b[mac] = op; else delete b[mac];
        root.busy = b;
    }
    function clearError(mac) {
        if (!root.errors[mac]) return;
        const e = Object.assign({}, root.errors);
        delete e[mac];
        root.errors = e;
    }

    // Answers the agent's question: accept or not, with the PIN or passkey
    // typed in when that was the question.
    function answer(accept, value) {
        if (!root.request) return;
        Services.Agent.send({ cmd: "bt-reply", id: root.request.id, accept: !!accept,
                              value: String(value === undefined ? "" : value) });
        root.request = null;
    }

    // ── actions ───────────────────────────────────────────────────────────
    function refresh() {
        if (root.live) Services.Agent.send({ cmd: "bt-hello" });
        else { showProc.running = true; devicesProc.running = true; }
    }

    function setPowered(on) {
        powered = on;
        if (root.live) Services.Agent.send({ cmd: "bt-power", on: on });
        else legacy(["bluetoothctl", "power", on ? "on" : "off"]);
    }
    function togglePowered() { setPowered(!powered); }

    function setDiscoverable(on) {
        discoverable = on;
        if (root.live) Services.Agent.send({ cmd: "bt-discoverable", on: on });
        else legacy(["bluetoothctl", "discoverable", on ? "on" : "off"]);
    }

    // Looking for devices: on while Settings → Bluetooth is open, or for
    // half a minute from scan() (the control center's list).
    readonly property bool keepScanning: Config.UiState.settingsOpen
                                         && Config.UiState.settingsPane === "Bluetooth"
    onKeepScanningChanged: root.syncScan()
    Timer { id: scanFor; interval: 30000; onTriggered: root.syncScan() }
    function scan() {
        if (!root.live) { legacy(["bluetoothctl", "--timeout", "15", "scan", "on"]); return; }
        scanFor.restart();
        root.syncScan();
    }
    function syncScan() {
        if (!root.live || !root.powered) return;
        const want = root.keepScanning || scanFor.running;
        if (want !== root.discovering) Services.Agent.send({ cmd: "bt-scan", on: want });
    }
    onPoweredChanged: root.syncScan()
    onLiveChanged: { root.syncScan(); if (!root.live) root.refresh(); }

    // Pair, trust and connect, in one go: what "pair" means to anyone not
    // reading BlueZ's manual. Trusted is what lets it come back by itself.
    function pairDevice(mac) {
        if (!mac) return;
        clearError(mac);
        lastError = "";
        if (root.live) { Services.Agent.send({ cmd: "bt-pair", mac: mac }); return; }
        setBusy(mac, "pair");
        legacy(["sh", "-c", "bluetoothctl --agent NoInputNoOutput pair \"$1\" && "
                + "bluetoothctl trust \"$1\" && bluetoothctl connect \"$1\"", "bt-pair", mac], mac);
    }
    function cancelPairing(mac) {
        if (root.request && root.request.mac === mac) answer(false);
        if (root.live) Services.Agent.send({ cmd: "bt-cancel", mac: mac });
    }
    // Drops the pairing; it has to be paired again after this.
    function removeDevice(mac) {
        if (!mac) return;
        clearError(mac);
        if (root.live) Services.Agent.send({ cmd: "bt-remove", mac: mac });
        else { setBusy(mac, "remove"); legacy(["bluetoothctl", "remove", mac], mac); }
    }
    function connectDevice(mac) {
        clearError(mac);
        if (root.live) Services.Agent.send({ cmd: "bt-connect", mac: mac });
        else { setBusy(mac, "connect"); legacy(["bluetoothctl", "connect", mac], mac); }
    }
    function disconnectDevice(mac) {
        clearError(mac);
        if (root.live) Services.Agent.send({ cmd: "bt-disconnect", mac: mac });
        else { setBusy(mac, "disconnect"); legacy(["bluetoothctl", "disconnect", mac], mac); }
    }

    // One tap does the obvious thing for whatever state the device is in.
    function toggleDevice(dev) {
        if (!dev) return;
        if (dev.connected) disconnectDevice(dev.mac);
        else if (!dev.paired) pairDevice(dev.mac);
        else connectDevice(dev.mac);
    }
    function actionFor(dev) {
        if (!dev) return "";
        if (dev.connected) return "Disconnect";
        return dev.paired ? "Connect" : "Pair";
    }

    // ── without the agent: bluetoothctl ───────────────────────────────────
    Timer {
        interval: 5000
        running: !root.live
        repeat: true
        triggeredOnStart: true
        onTriggered: { showProc.running = true; devicesProc.running = true; }
    }

    Process {
        id: showProc
        command: ["bluetoothctl", "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.live) return;
                if (!text.trim()) { root.available = false; return; }
                root.available = true;
                const alias = /Alias:\s*(.+)/.exec(text);
                root.controller = alias ? alias[1].trim() : "";
                root.powered = /Powered:\s*yes/.test(text);
                root.discoverable = /Discoverable:\s*yes/.test(text);
                root.discovering = /Discovering:\s*yes/.test(text);
            }
        }
        onExited: code => { if (code !== 0 && !root.live) root.available = false; }
    }

    Process {
        id: devicesProc
        command: ["sh", "-c",
            "bluetoothctl devices 2>/dev/null | while read -r _ mac name; do "
            + "info=$(bluetoothctl info \"$mac\" 2>/dev/null); "
            + "conn=$(printf '%s' \"$info\" | grep -c 'Connected: yes'); "
            + "pair=$(printf '%s' \"$info\" | grep -c 'Paired: yes'); "
            + "trust=$(printf '%s' \"$info\" | grep -c 'Trusted: yes'); "
            + "named=$(printf '%s' \"$info\" | grep -c '^\\s*Name:'); "
            + "icon=$(printf '%s' \"$info\" | sed -n 's/^\\s*Icon:\\s*//p' | head -n1); "
            + "bat=$(printf '%s' \"$info\" | sed -n 's/.*Battery Percentage:.*(\\([0-9]*\\)).*/\\1/p' | head -n1); "
            + "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "
            + "\"$mac\" \"$conn\" \"$pair\" \"$trust\" \"$named\" \"$icon\" \"${bat:--1}\" \"$name\"; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (root.live) return;
                const out = [];
                for (const line of text.trim().split("\n")) {
                    const p = line.split("\t");
                    if (p.length < 8) continue;
                    out.push({ mac: p[0], connected: p[1] === "1", paired: p[2] === "1",
                               trusted: p[3] === "1", named: p[4] !== "0", kind: p[5] || "",
                               battery: parseInt(p[6]), name: p[7] || p[0] });
                }
                out.sort((a, b) => (b.connected - a.connected) || (b.paired - a.paired)
                                   || a.name.localeCompare(b.name));
                root.devices = out;
            }
        }
    }

    property string legacyMac: ""
    Process {
        id: action
        stdout: StdioCollector {
            onStreamFinished: {
                // bluetoothctl reports failures on stdout.
                const m = /Failed to \w+:?\s*([^\n]*)/.exec(text);
                if (!m) return;
                const name = (/org\.bluez\.Error\.\w+/.exec(m[1]) || [""])[0];
                const text2 = root.explain(name, m[1]);
                root.lastError = text2;
                if (root.legacyMac) {
                    const e = Object.assign({}, root.errors);
                    e[root.legacyMac] = text2;
                    root.errors = e;
                }
            }
        }
        onExited: {
            if (root.legacyMac) root.setBusy(root.legacyMac, "");
            root.legacyMac = "";
            showProc.running = true;
            devicesProc.running = true;
        }
    }
    function legacy(cmd, mac) {
        root.legacyMac = mac || "";
        action.command = cmd;
        action.running = true;
    }
}
