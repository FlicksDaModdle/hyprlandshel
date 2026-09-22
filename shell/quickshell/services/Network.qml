pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Wi-Fi / connectivity through nmcli. Newer Quickshell has a native
// Quickshell.Networking module, but shelling out to nmcli works on every
// version and on setups where the native module isn't built, so that's what
// this uses.
//
// Feeds the bar's SSID readout, the control center's Wi-Fi tile and its
// network drill-down list, and Settings → Network.
Singleton {
    id: root

    property bool wifiEnabled: false
    property bool connected: false
    property string ssid: ""
    property int signalStrength: 0     // 0-100
    property string security: ""
    property string ipv4: ""
    property string ifname: ""
    property bool vpnActive: false
    property string vpnName: ""
    property bool available: true      // false when NetworkManager isn't running

    // Visible access points, strongest first, deduplicated by SSID.
    property var networks: []
    property bool scanning: false

    // SSIDs NetworkManager already has a profile for. A known network needs
    // no password to rejoin, and is the only kind that can be forgotten.
    property var savedNames: []

    // What the last action said when it failed. nmcli is specific — wrong
    // password, no such network, device busy — and swallowing that left the
    // shell with nothing to show but a network that did not join.
    property string lastError: ""
    property string busySsid: ""

    readonly property string icon: !wifiEnabled ? "wifiOff" : (connected ? "wifi" : "wifiOff")
    readonly property string label: !available ? "no network"
                                  : !wifiEnabled ? "Wi-Fi off"
                                  : (connected ? ssid : "not connected")

    // ── polling ───────────────────────────────────────────────────────────
    // nmcli can emit a change stream, but a short poll is simpler and robust
    // against the monitor process dying; 5s is well under the rate at which
    // signal strength visibly drifts.
    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    function refresh() {
        radioProc.running = true;
        activeProc.running = true;
        savedProc.running = true;
    }

    function isKnown(name) { return (savedNames || []).indexOf(name) >= 0; }

    Process {
        id: savedProc
        command: ["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = [];
                for (const line of text.trim().split("\n")) {
                    if (!line) continue;
                    const f = root.splitFields(line);
                    if ((f[1] || "").indexOf("wireless") >= 0) out.push(f[0]);
                }
                root.savedNames = out;
            }
        }
    }

    Process {
        id: radioProc
        command: ["nmcli", "-t", "radio", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.wifiEnabled = text.trim() === "enabled";
                // Scan whenever the radio is on. Doing this only while already
                // connected meant the network picker stayed empty after you
                // turned Wi-Fi back on — there was nothing to connect *to*.
                if (root.wifiEnabled) apProc.running = true;
                else { root.networks = []; root.ssid = ""; root.signalStrength = 0; }
            }
        }
        onExited: code => { if (code !== 0) root.available = false; else root.available = true; }
    }

    // `nmcli -t -f ...` is colon-separated with backslash-escaped colons
    // inside fields, which is why splitting goes through splitFields().
    Process {
        id: activeProc
        command: ["nmcli", "-t", "-f", "TYPE,STATE,NAME,DEVICE", "connection", "show", "--active"]
        stdout: StdioCollector {
            onStreamFinished: {
                let wifi = false, vpn = false, vpnLabel = "", dev = "";
                for (const line of text.trim().split("\n")) {
                    if (!line) continue;
                    const f = root.splitFields(line);
                    const type = f[0] || "";
                    if (type === "802-11-wireless" || type === "wifi") {
                        wifi = true;
                        dev = f[3] || "";
                    } else if (type === "vpn" || type === "wireguard" || type === "tun") {
                        vpn = true;
                        vpnLabel = f[2] || type;
                    }
                }
                root.connected = wifi;
                root.ifname = dev;
                root.vpnActive = vpn;
                root.vpnName = vpnLabel;
                if (!wifi) { root.ssid = ""; root.signalStrength = 0; }
                if (dev) { ipProc.command = ["nmcli", "-t", "-f", "IP4.ADDRESS", "device", "show", dev]; ipProc.running = true; }
            }
        }
    }

    Process {
        id: ipProc
        stdout: StdioCollector {
            onStreamFinished: {
                const m = /IP4\.ADDRESS\[1\]:\s*([0-9.]+)/.exec(text);
                root.ipv4 = m ? m[1] : "";
            }
        }
    }

    // Access point list. IN-USE marks the connected one, which is also where
    // the live SSID / signal / security readings come from.
    Process {
        id: apProc
        command: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                const seen = {};
                const out = [];
                for (const line of text.trim().split("\n")) {
                    if (!line) continue;
                    const f = root.splitFields(line);
                    const name = f[1] || "";
                    if (!name || seen[name]) continue;
                    seen[name] = true;
                    const entry = {
                        inUse: (f[0] || "").indexOf("*") >= 0,
                        ssid: name,
                        signal: parseInt(f[2]) || 0,
                        security: (f[3] || "").trim(),
                        known: root.isKnown(name)
                    };
                    out.push(entry);
                    if (entry.inUse) {
                        root.ssid = entry.ssid;
                        root.signalStrength = entry.signal;
                        root.security = entry.security || "Open";
                    }
                }
                out.sort((a, b) => b.signal - a.signal);
                root.networks = out;
                root.scanning = false;
            }
        }
    }

    // nmcli escapes a literal ':' inside a field as '\:'.
    function splitFields(line) {
        const out = [];
        let cur = "";
        for (let i = 0; i < line.length; i++) {
            const c = line[i];
            if (c === "\\" && i + 1 < line.length) { cur += line[++i]; }
            else if (c === ":") { out.push(cur); cur = ""; }
            else cur += c;
        }
        out.push(cur);
        return out;
    }

    // ── actions ───────────────────────────────────────────────────────────
    // stderr is kept: "Secrets were required, but not provided" is how nmcli
    // says the password was wrong, and it is the one thing the person at the
    // keyboard needs to be told.
    Process {
        id: action
        stderr: StdioCollector {
            onStreamFinished: {
                const t = text.trim();
                root.lastError = t.replace(/^Error:\s*/, "");
            }
        }
        onExited: code => {
            if (code === 0) root.lastError = "";
            root.busySsid = "";
            root.refresh();
        }
    }

    function setWifiEnabled(on) {
        wifiEnabled = on;               // optimistic, corrected by next poll
        action.command = ["nmcli", "radio", "wifi", on ? "on" : "off"];
        action.running = true;
        // The radio needs a moment to come up before it can see anything, so
        // the first useful scan is a beat after the switch.
        if (on) settle.restart();
    }

    Timer {
        id: settle
        interval: 2000
        onTriggered: root.scan()
    }

    function toggleWifi() { setWifiEnabled(!wifiEnabled); }

    function scan() {
        scanning = true;
        action.command = ["nmcli", "device", "wifi", "rescan"];
        action.running = true;
    }

    // Joins a network. A known one needs nothing; an unknown secured one
    // needs the password, which the shell now asks for rather than sending
    // people to nm-connection-editor.
    //
    // `--ask` is deliberately not used: it would block on a terminal that
    // does not exist. Without a password nmcli tries the saved secret and
    // fails cleanly if there is none, which is what surfaces in lastError.
    function connect(name, password) {
        if (!name) return;
        lastError = "";
        busySsid = name;
        const cmd = ["nmcli", "device", "wifi", "connect", name];
        if (password && password !== "") { cmd.push("password"); cmd.push(password); }
        action.command = cmd;
        action.running = true;
    }

    // Whether joining this one will need a password from us: secured, and
    // NetworkManager has no profile for it yet.
    function needsPassword(ap) {
        if (!ap) return false;
        const sec = (ap.security || "").trim();
        return sec !== "" && sec.toLowerCase() !== "open" && !isKnown(ap.ssid);
    }

    // Deletes the saved profile, so the next join asks again.
    function forget(name) {
        if (!name) return;
        lastError = "";
        action.command = ["nmcli", "connection", "delete", name];
        action.running = true;
    }

    function disconnect() {
        if (!ifname) return;
        action.command = ["nmcli", "device", "disconnect", ifname];
        action.running = true;
    }

    function setVpn(on) {
        if (!on && vpnName) {
            action.command = ["nmcli", "connection", "down", vpnName];
            action.running = true;
        } else if (on) {
            // Bring up the first configured VPN profile; with none, this is
            // a no-op and the toggle springs back on the next poll.
            action.command = ["sh", "-c",
                "nmcli -t -f NAME,TYPE connection show | awk -F: '$2==\"vpn\"||$2==\"wireguard\"{print $1; exit}' | xargs -r -I{} nmcli connection up {}"];
            action.running = true;
        }
    }

    function openEditor() {
        Quickshell.execDetached(["nm-connection-editor"]);
    }

    // Bars-style strength label used in the CC list rows.
    function strengthLabel(s) {
        return s + "%";
    }
}
