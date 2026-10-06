pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Wi-Fi through nmcli, with hyprshell-daemon's agent (Services.Agent) as
// NetworkManager's secret agent — the part of KDE's network handling that a
// bare session lacks. When NetworkManager needs a password it has not got
// (a saved one that stopped working; a network set up in KDE, which keeps
// its secrets per user rather than in the profile) it asks the agents in
// the session, and without one the connection simply fails with "Secrets
// were required, but not provided". Here the question comes up in
// Settings → Network, and the answer can be saved into the profile so it is
// not asked again.
//
// University and office networks (WPA-Enterprise, 802.1X) take the options
// KDE's dialog has: the sign-in method (PEAP, TTLS, PWD), the inner method,
// an anonymous identity, a domain to check the server against, and which
// certificate to trust. Getting one of those wrong is the usual reason a
// campus network will not take a username and password that are right.
//
// Feeds the bar, the control center's Wi-Fi tile and list, and Settings →
// Network.
Singleton {
    id: root

    property bool wifiEnabled: false
    property bool connected: false
    property bool connecting: false
    property string ssid: ""
    property string activeUuid: ""
    property int signalStrength: 0     // 0-100
    property string security: ""
    property string ipv4: ""
    property string ifname: ""
    property bool vpnActive: false
    property string vpnName: ""
    property bool available: true      // false when NetworkManager isn't running

    // In range, strongest first, one per name:
    // [{ ssid, signal, security, inUse, known, enterprise, secured, band }]
    property var networks: []
    property bool scanning: false

    // Wi-Fi profiles NetworkManager has:
    // [{ uuid, name, ssid, autoconnect, keyMgmt, eap, enterprise }]
    property var saved: []
    readonly property var savedNames: root.saved.map(p => p.name).concat(root.saved.map(p => p.ssid))

    // About the connection in use: { hw, ip4, gateway, dns, ip6, freq, rate }.
    property var details: ({})

    // What went wrong, per network, in words. lastError is the newest, for
    // the places that show one line.
    property var errors: ({})
    property string lastError: ""
    property string busySsid: ""

    // NetworkManager asking for a password through the agent:
    // { id, name, uuid, ssid, setting, fields: [...], identity, again }.
    property var secrets: null

    // The network the Network pane should open with its form showing —
    // set by the control center when a network needs more than it can ask.
    property string focusSsid: ""

    readonly property string icon: !wifiEnabled ? "wifiOff" : (connected ? "wifi" : "wifiOff")
    readonly property string label: !available ? "no network"
                                  : !wifiEnabled ? "Wi-Fi off"
                                  : connecting ? "connecting…"
                                  : (connected ? ssid : "not connected")

    // ── what a network is ─────────────────────────────────────────────────
    // nmcli spells enterprise "WPA2 802.1X", "WPA3 802.1X", "802.1X" or,
    // on older builds, "EAP".
    function isEnterprise(ap) {
        const sec = ((ap && ap.security) || "").toUpperCase();
        return sec.indexOf("802.1X") >= 0 || sec.indexOf("EAP") >= 0;
    }
    function isSecured(ap) {
        const sec = ((ap && ap.security) || "").trim().toLowerCase();
        return sec !== "" && sec !== "open" && sec !== "--";
    }
    function profileFor(ssidOrName) {
        return root.saved.find(p => p.ssid === ssidOrName) || root.saved.find(p => p.name === ssidOrName) || null;
    }
    function isKnown(name) { return !!root.profileFor(name); }
    function needsPassword(ap) { return !!ap && root.isSecured(ap) && !root.isKnown(ap.ssid); }
    function needsIdentity(ap) { return root.needsPassword(ap) && root.isEnterprise(ap); }

    function securityLabel(ap) {
        if (!root.isSecured(ap)) return "Open";
        if (root.isEnterprise(ap)) return "Sign-in (802.1X)";
        const s = (ap.security || "").toUpperCase();
        if (s.indexOf("WPA3") >= 0) return "WPA3";
        if (s.indexOf("WPA2") >= 0) return "WPA2";
        if (s.indexOf("WEP") >= 0) return "WEP — insecure";
        return ap.security;
    }

    // nmcli's errors, as something to do about them.
    function explain(text) {
        const t = String(text || "").replace(/^Error:\s*/, "").trim();
        if (/Secrets were required, but not provided/i.test(t))
            return "The password wasn't accepted, or none was given.";
        if (/802\.1X supplicant took too long|supplicant.*(failed|disconnect)|802-1x/i.test(t))
            return "The network didn't accept the sign-in. The username and password may be right "
                 + "and the method wrong — open More options and try what your university lists "
                 + "(often PEAP with MSCHAPv2, or TTLS with PAP).";
        if (/No network with SSID/i.test(t))
            return "That network isn't in range any more.";
        if (/timed out|timeout/i.test(t))
            return "The network didn't answer in time.";
        if (/IP configuration could not be reserved|ip-config-unavailable|DHCP/i.test(t))
            return "Joined the network but didn't get an address from it (DHCP).";
        if (/Not authorized|not authorised|Insufficient privileges/i.test(t))
            return "You're not allowed to change network settings in this session (polkit).";
        if (/property is invalid|invalid.*property/i.test(t))
            return "NetworkManager refused one of the settings: " + t;
        return t.replace(/^Connection activation failed:\s*/, "");
    }

    function setError(name, text) {
        const e = Object.assign({}, root.errors);
        if (text) e[name] = text; else delete e[name];
        root.errors = e;
        if (text) root.lastError = text;
    }

    // ── keeping up ────────────────────────────────────────────────────────
    // NetworkManager says when something changes (`nmcli monitor`): a
    // connection coming up or dropping, the radio switched, a device
    // appearing. Each one re-reads, a beat later so a burst of them is one
    // read. Between events there is nothing to poll for, so the timer below
    // only catches what has no event — signal strength drifting — and does
    // that slowly unless a Wi-Fi list is actually on screen.
    //
    // It used to read everything every five seconds, and the network list
    // with `nmcli device wifi list`, which has NetworkManager *scan* if the
    // last scan is more than thirty seconds old: the Wi-Fi card was
    // scanning twice a minute for as long as the shell ran, and three
    // processes were started every five seconds to find out nothing had
    // changed.
    readonly property bool listWanted:
        (Config.UiState.settingsOpen && Config.UiState.settingsPane === "Network")
        || (Config.UiState.controlCenterOpen && Config.UiState.ccExpanded === "Wi-Fi")
    onListWantedChanged: {
        if (viaDaemon) Services.Daemon.send({ cmd: "net-watch", on: listWanted });
        if (listWanted) { refresh(); scan(); }
    }

    // ── hyprshell-daemon ──────────────────────────────────────────────────
    // When it is running and reaching NetworkManager, it pushes everything
    // below as it changes (from NetworkManager's own D-Bus signals), and
    // none of the nmcli reading runs. Actions — joining, forgetting,
    // profiles — still go through nmcli either way.
    readonly property bool viaDaemon: Services.Daemon.netLive
    onViaDaemonChanged: if (viaDaemon) Services.Daemon.send({ cmd: "net-watch", on: listWanted })
    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev !== "net" || ev.available !== true) return;
            root.available = true;
            root.applyRadio(!!ev.wifiEnabled);
            if (root.applyActive(ev.active || []) && ev.wifi) root.applyDetails(ev.wifi);
            if (root.wifiEnabled) root.applyAps(ev.aps || [], !!ev.full);
            if (ev.saved) root.applySaved(ev.saved);
        }
    }

    Timer {
        interval: root.listWanted ? 5000 : (root.monitorLive ? 60000 : 15000)
        running: !root.viaDaemon
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }
    // Saved profiles change rarely, and every change made here re-reads them.
    Timer {
        interval: root.listWanted ? 30000 : 300000
        running: !root.viaDaemon
        repeat: true
        triggeredOnStart: true
        onTriggered: savedProc.running = true
    }

    property bool monitorLive: false
    property int monitorEpoch: 0
    Process {
        id: monitorProc
        running: root.available && !root.viaDaemon && root.monitorEpoch >= 0
        command: ["sh", "-c", "export LC_ALL=C; command -v stdbuf >/dev/null 2>&1 && exec stdbuf -oL nmcli monitor; exec nmcli monitor"]
        stdout: SplitParser {
            onRead: line => { root.monitorLive = true; changed.restart(); }
        }
        onExited: { root.monitorLive = false; remonitor.restart(); }
    }
    Timer { id: changed; interval: 400; onTriggered: root.refresh() }
    // NetworkManager restarted, or was not up yet: try again, unhurried.
    Timer { id: remonitor; interval: 10000; onTriggered: if (!monitorProc.running) root.monitorEpoch++ }

    function refresh() {
        if (viaDaemon) { Services.Daemon.send({ cmd: "net-refresh" }); return; }
        radioProc.running = true;
        activeProc.running = true;
    }

    // nmcli escapes a literal ':' inside a terse field as '\:'.
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

    Process {
        id: radioProc
        command: ["nmcli", "-t", "radio", "wifi"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.applyRadio(text.trim() === "enabled");
                if (root.wifiEnabled) apProc.running = true;
            }
        }
        onExited: code => root.available = code === 0
    }

    Process {
        id: activeProc
        command: ["nmcli", "-t", "-f", "TYPE,STATE,UUID,DEVICE,NAME", "connection", "show", "--active"]
        stdout: StdioCollector {
            onStreamFinished: {
                const list = [];
                for (const line of text.trim().split("\n")) {
                    if (!line) continue;
                    const f = root.splitFields(line);
                    list.push({ type: f[0] || "", state: f[1] || "", uuid: f[2] || "",
                                device: f[3] || "", name: f.slice(4).join(":") });
                }
                const wifiDev = root.applyActive(list);
                if (wifiDev) { detailProc.command = ["nmcli", "-t", "-f",
                    "GENERAL.HWADDR,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS", "device", "show", wifiDev];
                    detailProc.running = true; }
            }
        }
    }

    // ── applying what was read ────────────────────────────────────────────
    // From nmcli's output or from hyprshell-daemon's events (Daemon.qml) —
    // the same shapes either way.
    function applyRadio(on) {
        root.wifiEnabled = on;
        if (!on) { root.networks = []; root.ssid = ""; root.signalStrength = 0; }
    }
    // [{ type, state, uuid, device, name }] → the Wi-Fi device in use, or "".
    function applyActive(list) {
                let wifi = false, activating = false, vpn = false, vpnLabel = "", dev = "", uuid = "";
                for (const a of list) {
                    const f = [a.type, a.state, a.uuid, a.device, a.name];
                    const type = f[0] || "";
                    if (type === "802-11-wireless" || type === "wifi") {
                        if (f[1] === "activated") wifi = true;
                        else activating = true;
                        dev = f[3] || "";
                        uuid = f[2] || "";
                    } else if (type === "vpn" || type === "wireguard" || type === "tun") {
                        vpn = true;
                        vpnLabel = f[4] || type;
                    }
                }
                root.connected = wifi;
                root.connecting = activating && !wifi;
                root.ifname = dev;
                root.activeUuid = uuid;
                root.vpnActive = vpn;
                root.vpnName = vpnLabel;
                if (!wifi) { root.ssid = root.connecting ? root.ssid : ""; root.signalStrength = 0; root.details = ({}); }
                return dev && wifi ? dev : "";
    }
    // { hw, ip4 ("a.b.c.d/24"), gateway, dns ([]), ip6 }
    function applyDetails(i) {
        const d = Object.assign({}, root.details);
        d.hw = i.hw || "";
        d.ip4 = i.ip4 || "";
        d.gateway = i.gateway || "";
        d.dns = (i.dns || []).join(", ");
        d.ip6 = i.ip6 || "";
        root.details = d;
        root.ipv4 = (d.ip4 || "").replace(/\/.*/, "");
    }

    Process {
        id: detailProc
        stdout: StdioCollector {
            onStreamFinished: {
                const d = { dns: [] };
                for (const line of text.split("\n")) {
                    const i = line.indexOf(":");
                    if (i < 0) continue;
                    const k = line.slice(0, i), v = line.slice(i + 1).replace(/\\:/g, ":");
                    if (k === "GENERAL.HWADDR") d.hw = v;
                    else if (k === "IP4.ADDRESS[1]") d.ip4 = v;
                    else if (k === "IP4.GATEWAY") d.gateway = v;
                    else if (k.indexOf("IP4.DNS") === 0) d.dns.push(v);
                    else if (k === "IP6.ADDRESS[1]") d.ip6 = v;
                }
                root.applyDetails(d);
            }
        }
    }

    // In range. IN-USE marks the one connected, which is also where the
    // live name, signal and security come from.
    Process {
        id: apProc
        // --rescan no: what NetworkManager already knows. Scanning is
        // scan()'s job, done when a list is put on screen.
        command: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY,FREQ,RATE", "device", "wifi", "list", "--rescan", "no"]
        stdout: StdioCollector {
            onStreamFinished: {
                const list = [];
                for (const line of text.trim().split("\n")) {
                    if (!line) continue;
                    const f = root.splitFields(line);
                    list.push({ inUse: (f[0] || "").indexOf("*") >= 0, ssid: f[1] || "",
                                signal: parseInt(f[2]) || 0, security: f[3] || "",
                                freq: parseInt(f[4]) || 0, rate: f[5] || "" });
                }
                root.applyAps(list, true);
            }
        }
    }
    // [{ inUse, ssid, signal, security, freq, rate }]. `complete` is false
    // when only the network in use was read (the daemon, with no list on
    // screen): that updates the name and signal and leaves the list be.
    function applyAps(list, complete) {
                const by = {};
                for (const a of list) {
                    const f = [a.inUse ? "*" : "", a.ssid, String(a.signal), a.security, String(a.freq), a.rate];
                    const name = f[1] || "";
                    if (!name) continue;
                    const freq = parseInt(f[4]) || 0;
                    const e = {
                        inUse: (f[0] || "").indexOf("*") >= 0,
                        ssid: name,
                        signal: parseInt(f[2]) || 0,
                        security: (f[3] || "").trim(),
                        band: freq >= 5925 ? "6 GHz" : freq >= 4900 ? "5 GHz" : freq > 0 ? "2.4 GHz" : "",
                        rate: f[5] || ""
                    };
                    const was = by[name];
                    // One per name: the access point in use, else the
                    // strongest — a campus has dozens of the same network.
                    if (!was || e.inUse || (!was.inUse && e.signal > was.signal)) by[name] = e;
                }
                const out = Object.keys(by).map(k => {
                    const e = by[k];
                    e.known = root.isKnown(e.ssid);
                    e.enterprise = root.isEnterprise(e);
                    e.secured = root.isSecured(e);
                    return e;
                });
                out.sort((a, b) => (b.inUse - a.inUse) || (b.known - a.known) || (b.signal - a.signal));
                for (const e of out) if (e.inUse) {
                    root.ssid = e.ssid;
                    root.signalStrength = e.signal;
                    root.security = root.securityLabel(e);
                    const d = Object.assign({}, root.details);
                    d.band = e.band;
                    d.rate = e.rate;
                    root.details = d;
                }
                if (complete) root.networks = out;
                root.scanning = false;
    }

    // Each Wi-Fi profile, with the three things about it the list needs.
    Process {
        id: savedProc
        command: ["sh", "-c",
            'nmcli -t -f UUID,TYPE,AUTOCONNECT,NAME connection show 2>/dev/null | while IFS= read -r line; do\n'
          + '  case "$line" in *:802-11-wireless:*) ;; *) continue ;; esac\n'
          + '  uuid=${line%%:*}\n'
          + '  printf "P\\t%s\\n" "$line"\n'
          + '  nmcli -t -f 802-11-wireless.ssid,802-11-wireless-security.key-mgmt,802-1x.eap \\\n'
          + '    connection show "$uuid" 2>/dev/null | while IFS= read -r f; do printf "F\\t%s\\t%s\\n" "$uuid" "$f"; done\n'
          + 'done']
        stdout: StdioCollector {
            onStreamFinished: {
                const by = {}, order = [];
                for (const line of text.split("\n")) {
                    const t = line.split("\t");
                    if (t[0] === "P" && t.length >= 2) {
                        const f = root.splitFields(t.slice(1).join("\t"));
                        by[f[0]] = { uuid: f[0], autoconnect: f[2] === "yes", name: f.slice(3).join(":"),
                                     ssid: "", keyMgmt: "", eap: "" };
                        order.push(f[0]);
                    } else if (t[0] === "F" && t.length >= 3 && by[t[1]]) {
                        const kv = t.slice(2).join("\t");
                        const i = kv.indexOf(":");
                        const k = kv.slice(0, i), v = kv.slice(i + 1).replace(/\\:/g, ":");
                        if (k === "802-11-wireless.ssid") by[t[1]].ssid = v;
                        else if (k === "802-11-wireless-security.key-mgmt") by[t[1]].keyMgmt = v;
                        else if (k === "802-1x.eap") by[t[1]].eap = v;
                    }
                }
                root.applySaved(order.map(u => by[u]));
            }
        }
    }

    // [{ uuid, autoconnect, name, ssid, keyMgmt, eap }]
    function applySaved(list) {
        root.saved = list.map(p => {
            p = Object.assign({}, p);
            if (!p.ssid) p.ssid = p.name;
            p.enterprise = p.keyMgmt === "wpa-eap" || p.keyMgmt === "ieee8021x";
            return p;
        });
    }

    // An enterprise profile's sign-in settings, read when its row opens:
    // { uuid: { eap, phase2, identity, anonymous, domain, ca, systemCa } }.
    property var profileInfo: ({})
    Process {
        id: profileProc
        property string uuid: ""
        stdout: StdioCollector {
            onStreamFinished: {
                const i = {};
                for (const line of text.split("\n")) {
                    const c = line.indexOf(":");
                    if (c < 0) continue;
                    i[line.slice(0, c)] = line.slice(c + 1).replace(/\\:/g, ":");
                }
                const p = Object.assign({}, root.profileInfo);
                p[profileProc.uuid] = {
                    eap: (i["802-1x.eap"] || "").split(",")[0],
                    phase2: i["802-1x.phase2-auth"] || i["802-1x.phase2-autheap"] || "",
                    identity: i["802-1x.identity"] || "",
                    anonymous: i["802-1x.anonymous-identity"] || "",
                    domain: i["802-1x.domain-suffix-match"] || "",
                    ca: i["802-1x.ca-cert"] || "",
                    systemCa: i["802-1x.system-ca-certs"] === "yes"
                };
                root.profileInfo = p;
            }
        }
    }
    function loadProfile(uuid) {
        if (!uuid || profileProc.running) return;
        profileProc.uuid = uuid;
        profileProc.command = ["nmcli", "-t", "-f",
            "802-1x.eap,802-1x.phase2-auth,802-1x.phase2-autheap,802-1x.identity,802-1x.anonymous-identity,"
            + "802-1x.domain-suffix-match,802-1x.ca-cert,802-1x.system-ca-certs",
            "connection", "show", uuid];
        profileProc.running = true;
    }

    // ── actions ───────────────────────────────────────────────────────────
    // One at a time, in order. A password reaches the script on stdin, which
    // reads it into $HYPRSHELL_WIFI_SECRET as its first line. nmcli itself
    // still takes it as an argument — for adding or changing a profile it
    // has no other way — so it is visible in /proc for the moment nmcli runs.
    property var queue: []
    Process {
        id: action
        property var job: null
        stdinEnabled: true
        onStarted: if (action.job && action.job.secret !== null) action.write(action.job.secret + "\n")
        stderr: StdioCollector {
            onStreamFinished: if (action.job) action.job.err = text.trim()
        }
        onExited: code => {
            const job = action.job;
            action.job = null;
            if (job) {
                if (job.ssid) {
                    root.setError(job.ssid, code === 0 ? "" : root.explain(job.err || ("nmcli exited with " + code)));
                    if (root.busySsid === job.ssid) root.busySsid = "";
                }
                if (code === 0 && !job.ssid) root.lastError = "";
                if (job.done) job.done(code === 0);
            }
            root.refresh();
            if (!root.viaDaemon) savedProc.running = true;
            root.pump();
        }
    }
    // secret: a string for a script that reads one, else null.
    function run(cmd, secret, ssid, done) {
        root.queue = root.queue.concat([{ cmd: cmd, secret: secret === undefined ? null : secret,
                                          ssid: ssid || "", done: done || null }]);
        root.pump();
    }
    readonly property string readSecret: 'IFS= read -r HYPRSHELL_WIFI_SECRET || HYPRSHELL_WIFI_SECRET=""\n'

    function pump() {
        if (action.running || root.queue.length === 0) return;
        const job = root.queue[0];
        root.queue = root.queue.slice(1);
        job.err = "";
        action.job = job;
        action.command = job.cmd;
        action.running = true;
    }

    function setWifiEnabled(on) {
        wifiEnabled = on;               // optimistic, corrected by the next poll
        run(["nmcli", "radio", "wifi", on ? "on" : "off"]);
        if (on) settle.restart();
    }
    Timer { id: settle; interval: 2000; onTriggered: root.scan() }
    function toggleWifi() { setWifiEnabled(!wifiEnabled); }

    function scan() {
        scanning = true;
        if (viaDaemon) { Services.Daemon.send({ cmd: "net-scan" }); return; }
        run(["nmcli", "device", "wifi", "rescan"]);
    }

    // Joins a network from the list. A saved one comes up as it is — or
    // with a new password, if one was typed because the old one failed. A
    // new home network takes its password; a new enterprise one goes
    // through joinEnterprise() with the options the form chose.
    function join(name, password) {
        if (!name) return;
        setError(name, "");
        busySsid = name;
        const p = root.profileFor(name);
        if (p) {
            if (password) {
                const field = p.enterprise ? "802-1x.password" : "wifi-sec.psk";
                run(["sh", "-c", root.readSecret + 'nmcli connection modify "$1" ' + field
                     + ' "$HYPRSHELL_WIFI_SECRET" ' + field + '-flags 0 && exec nmcli connection up "$1"',
                     "wifi-join", p.uuid], password, name);
            } else {
                run(["nmcli", "connection", "up", p.uuid], null, name);
            }
            return;
        }
        run(["sh", "-c", root.readSecret
           + 'if [ -n "$HYPRSHELL_WIFI_SECRET" ]; then\n'
           + '  exec nmcli device wifi connect "$1" password "$HYPRSHELL_WIFI_SECRET"\n'
           + 'fi\n'
           + 'exec nmcli device wifi connect "$1"', "wifi-join", name], password || "", name);
    }

    // Kept for the control center: a username makes it an enterprise join
    // with the usual settings.
    function connect(name, password, identity) {
        if ((identity || "").trim() !== "")
            joinEnterprise(name, { identity: identity.trim(), password: password });
        else join(name, password);
    }

    // opts: { identity, password, eap: peap|ttls|pwd, phase2: mschapv2|pap|
    //         gtc|md5|mschap, anonymous, domain, ca: none|system|<file>,
    //         hidden }
    //
    // A saved profile for the network is changed in place, so anything set
    // on it elsewhere that the form does not cover is kept. A new one that
    // will not come up is removed again — a broken profile would otherwise
    // be retried for ever.
    function joinEnterprise(name, opts) {
        if (!name) return;
        const o = opts || {};
        const eap = o.eap || "peap";
        const phase2 = eap === "pwd" ? "" : (o.phase2 || (eap === "ttls" ? "pap" : "mschapv2"));
        const ca = o.ca || "none";
        const props = [
            "wifi-sec.key-mgmt", "wpa-eap",
            "802-1x.eap", eap,
            "802-1x.phase2-auth", phase2,
            "802-1x.identity", o.identity || "",
            "802-1x.anonymous-identity", o.anonymous || "",
            "802-1x.domain-suffix-match", o.domain || "",
            "802-1x.system-ca-certs", ca === "system" ? "yes" : "no",
            "802-1x.ca-cert", ca !== "none" && ca !== "system" ? ca : "",
            "802-1x.password-flags", "0"
        ];
        if (o.hidden) props.push("802-11-wireless.hidden", "yes");
        setError(name, "");
        busySsid = name;
        const p = root.profileFor(name);
        run(["sh", "-c", root.readSecret
           + 'ssid=$1 uuid=$2 dev=$3; shift 3\n'
           + 'pw=""; [ -n "$HYPRSHELL_WIFI_SECRET" ] && pw="802-1x.password"\n'
           + 'if [ -n "$uuid" ]; then\n'
           + '  if [ -n "$pw" ]; then nmcli connection modify "$uuid" "$@" "$pw" "$HYPRSHELL_WIFI_SECRET" || exit $?\n'
           + '  else nmcli connection modify "$uuid" "$@" || exit $?; fi\n'
           + '  exec nmcli connection up "$uuid"\n'
           + 'fi\n'
           + 'set -- connection add type wifi con-name "$ssid" ssid "$ssid" ${dev:+ifname "$dev"} -- "$@"\n'
           + 'if [ -n "$pw" ]; then out=$(nmcli "$@" "$pw" "$HYPRSHELL_WIFI_SECRET") || exit $?\n'
           + 'else out=$(nmcli "$@") || exit $?; fi\n'
           + 'new=$(printf "%s" "$out" | sed -n "s/.*(\\([0-9a-f-]*\\)).*/\\1/p")\n'
           + 'if ! nmcli connection up "${new:-$ssid}"; then\n'
           + '  nmcli connection delete "${new:-$ssid}" >/dev/null 2>&1\n'
           + '  exit 1\n'
           + 'fi', "wifi-enterprise", name, p ? p.uuid : "", root.ifname].concat(props),
            o.password || "", name,
            ok => { if (ok && p) root.loadProfile(p.uuid); });
    }

    // A network that does not say its name. kind: open | psk | enterprise.
    function joinHidden(name, kind, password, opts) {
        if (!name) return;
        if (kind === "enterprise") {
            joinEnterprise(name, Object.assign({}, opts || {}, { password: password, hidden: true }));
            return;
        }
        setError(name, "");
        busySsid = name;
        run(["sh", "-c", root.readSecret
           + 'if [ -n "$HYPRSHELL_WIFI_SECRET" ]; then\n'
           + '  exec nmcli device wifi connect "$1" password "$HYPRSHELL_WIFI_SECRET" hidden yes\n'
           + 'fi\n'
           + 'exec nmcli device wifi connect "$1" hidden yes', "wifi-hidden", name],
            kind === "psk" ? (password || "") : "", name);
    }

    // Deletes the saved profile, so the next join asks again.
    function forget(nameOrUuid) {
        const p = root.saved.find(x => x.uuid === nameOrUuid) || root.profileFor(nameOrUuid);
        const id = p ? p.uuid : nameOrUuid;
        if (!id) return;
        if (p) setError(p.ssid, "");
        run(["nmcli", "connection", "delete", id]);
    }

    function setAutoconnect(uuid, on) {
        run(["nmcli", "connection", "modify", uuid, "connection.autoconnect", on ? "yes" : "no"]);
    }

    function disconnect() {
        if (!ifname) return;
        run(["nmcli", "device", "disconnect", ifname]);
    }

    function setVpn(on) {
        if (!on && vpnName) run(["nmcli", "connection", "down", vpnName]);
        else if (on)
            // The first configured VPN profile; with none, nothing happens
            // and the toggle springs back on the next poll.
            run(["sh", "-c",
                "nmcli -t -f NAME,TYPE connection show | awk -F: '$2==\"vpn\"||$2==\"wireguard\"{print $1; exit}' | xargs -r -I{} nmcli connection up {}"]);
    }

    function openEditor() { Quickshell.execDetached(["nm-connection-editor"]); }
    function strengthLabel(s) { return s + "%"; }

    // ── NetworkManager asking for a password ──────────────────────────────
    Connections {
        target: Services.Agent
        function onEvent(ev) {
            if (ev.ev === "nm-secrets") {
                root.secrets = ev;
                Config.UiState.openSettings("Network");
            } else if (ev.ev === "nm-cancel" || ev.ev === "exited") {
                if (!root.secrets || ev.ev === "exited" || root.secrets.id === ev.id) root.secrets = null;
            }
        }
    }

    // values: { psk } or { password }. remember: write it into the profile,
    // so NetworkManager has it next time without asking.
    function answerSecrets(values, remember) {
        const req = root.secrets;
        if (!req) return;
        root.secrets = null;
        Services.Agent.send({ cmd: "nm-reply", id: req.id, secrets: values });
        if (!remember || !req.uuid) return;
        const key = values.psk !== undefined ? "wifi-sec.psk"
                  : values.password !== undefined && req.setting === "802-1x" ? "802-1x.password" : "";
        if (!key) return;
        const secret = values.psk !== undefined ? values.psk : values.password;
        // After NetworkManager has used it, not while it is in the middle
        // of connecting with it.
        rememberLater.job = { uuid: req.uuid, key: key, secret: secret };
        rememberLater.restart();
    }
    function cancelSecrets() {
        const req = root.secrets;
        if (!req) return;
        root.secrets = null;
        Services.Agent.send({ cmd: "nm-reply", id: req.id, secrets: {} });
    }
    Timer {
        id: rememberLater
        property var job: null
        interval: 8000
        onTriggered: {
            const j = rememberLater.job;
            rememberLater.job = null;
            if (!j) return;
            root.run(["sh", "-c", root.readSecret
                      + 'exec nmcli connection modify "$1" "$2" "$HYPRSHELL_WIFI_SECRET" "$2-flags" 0',
                      "wifi-remember", j.uuid, j.key], j.secret);
        }
    }
}
