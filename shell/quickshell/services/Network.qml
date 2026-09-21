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
    }

    Process {
        id: radioProc
        command: ["nmcli", "-t", "radio", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: root.wifiEnabled = text.trim() === "enabled"
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
                if (wifi) apProc.running = true;
                else { root.ssid = ""; root.signalStrength = 0; }
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
                        security: (f[3] || "").trim()
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
    Process { id: action; onExited: root.refresh() }

    function setWifiEnabled(on) {
        wifiEnabled = on;               // optimistic, corrected by next poll
        action.command = ["nmcli", "radio", "wifi", on ? "on" : "off"];
        action.running = true;
    }

    function toggleWifi() { setWifiEnabled(!wifiEnabled); }

    function scan() {
        scanning = true;
        action.command = ["nmcli", "device", "wifi", "rescan"];
        action.running = true;
    }

    // Connects to a known network. An unknown secured network needs a
    // password, which the shell has no prompt for — nm-connection-editor
    // is the right tool for that, so that's what it opens.
    function connect(name) {
        action.command = ["nmcli", "device", "wifi", "connect", name];
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
