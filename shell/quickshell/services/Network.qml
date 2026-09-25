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

    // ── joining ───────────────────────────────────────────────────────────
    //
    // Two kinds of secured network, and they are joined by different
    // commands.
    //
    // A home network has one shared secret, and `nmcli device wifi
    // connect SSID password …` is the whole of it. A university or
    // office network is WPA-Enterprise: it authenticates *you*, with a
    // username and a password, over 802.1X — and nmcli has no one-shot
    // form for that. The profile has to be built first, with the EAP
    // method and the inner authentication named, and then brought up.
    //
    // Secrets go in the environment rather than in the arguments.
    // /proc/PID/cmdline is readable by anyone on the machine and
    // /proc/PID/environ is not, so a password on the command line is a
    // password anyone logged in can read while the join runs.

    // Does this one authenticate the person rather than the network?
    // nmcli spells it "WPA2 802.1X", or "WPA3 802.1X"; some builds say
    // "802.1X" alone and older ones say "EAP".
    function isEnterprise(ap) {
        const sec = ((ap && ap.security) || "").toUpperCase();
        return sec.indexOf("802.1X") >= 0 || sec.indexOf("EAP") >= 0;
    }

    // Whether joining this one will need a password from us: secured, and
    // NetworkManager has no profile for it yet.
    function needsPassword(ap) {
        if (!ap) return false;
        const sec = (ap.security || "").trim();
        return sec !== "" && sec.toLowerCase() !== "open" && !isKnown(ap.ssid);
    }

    // ...and a username as well.
    function needsIdentity(ap) {
        return root.needsPassword(ap) && root.isEnterprise(ap);
    }

    // `--ask` is deliberately not used anywhere here: it would block on a
    // terminal that does not exist. Without a password nmcli tries the
    // saved secret and fails cleanly if there is none, which is what
    // surfaces in lastError.
    function connect(name, password, identity) {
        if (!name) return;
        lastError = "";
        busySsid = name;

        const user = (identity || "").trim();
        if (user === "") {
            action.environment = ({ "HYPRSHELL_WIFI_PSK": password || "" });
            action.command = ["sh", "-c",
                'if [ -n "${HYPRSHELL_WIFI_PSK:-}" ]; then\n'
              + '  exec nmcli device wifi connect "$1" password "$HYPRSHELL_WIFI_PSK"\n'
              + 'fi\n'
              + 'exec nmcli device wifi connect "$1"\n',
                "wifi-join", name];
            action.running = true;
            return;
        }

        action.environment = ({
            "HYPRSHELL_WIFI_USER": user,
            "HYPRSHELL_WIFI_PSK": password || ""
        });
        action.command = ["sh", "-c", root.enterpriseScript, "wifi-join", name, root.ifname];
        action.running = true;
    }

    // PEAP with MSCHAPv2 inside it, which is what university networks ask
    // for — eduroam, and the campus networks built the same way.
    //
    // No CA certificate is named. One *should* be, and a network that
    // hands out a configuration profile is better followed than second
    // guessed; but there is nowhere in a Wi-Fi popover to ask for a
    // certificate file, and refusing to connect without one would mean
    // the shell simply could not join the network at all. So this joins
    // the way `nmcli` does when asked by hand, and anything more
    // particular is what "Open network settings" is for.
    readonly property string enterpriseScript:
        'ssid="$1"; dev="$2"\n'
        // An existing profile is brought up rather than replaced: it may
        // have been set up elsewhere with a certificate, a domain match
        // or an anonymous identity that this would throw away.
      + 'if nmcli -g NAME connection show 2>/dev/null | grep -Fxq "$ssid"; then\n'
      + '  exec nmcli connection up "$ssid"\n'
      + 'fi\n'
      + 'add() {\n'
      + '  nmcli connection add type wifi con-name "$ssid" "$@" ssid "$ssid" -- \\\n'
      + '    wifi-sec.key-mgmt wpa-eap \\\n'
      + '    802-1x.eap peap \\\n'
      + '    802-1x.phase2-auth mschapv2 \\\n'
      + '    802-1x.identity "$HYPRSHELL_WIFI_USER" \\\n'
      + '    802-1x.password "$HYPRSHELL_WIFI_PSK" >/dev/null\n'
      + '}\n'
      + 'if [ -n "$dev" ]; then add ifname "$dev"; else add; fi || exit $?\n'
        // A profile that was added but will not come up is worse than no
        // profile: the next attempt would take the branch above and try
        // to raise the broken one for ever.
      + 'if ! nmcli connection up "$ssid"; then\n'
      + '  nmcli connection delete "$ssid" >/dev/null 2>&1\n'
      + '  exit 1\n'
      + 'fi\n' 

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
