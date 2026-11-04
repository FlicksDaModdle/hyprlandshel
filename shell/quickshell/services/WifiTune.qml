pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "." as Services

// Settings → Wi-Fi & network → Wi-Fi performance, through
// scripts/wifi-tune.sh: NetworkManager's Wi-Fi through iwd (faster scans
// and joins) instead of wpa_supplicant, and the card's power saving off
// (steadier on MediaTek cards). Read as anyone; changed through pkexec,
// which asks for your password.
Singleton {
    id: root

    readonly property string script: Services.Agent.shellDir + "/scripts/wifi-tune.sh"

    property string backend: ""          // "iwd" | "wpa_supplicant"
    property bool iwdInstalled: false
    property string powersave: ""        // "on" | "off" | "default"
    property bool probed: false
    property bool busy: false
    property string status: ""
    property bool failed: false

    function refresh() { check.running = true; }
    Component.onCompleted: refresh()

    Process {
        id: check
        command: ["bash", root.script, "--status"]
        stdout: StdioCollector {
            onStreamFinished: {
                for (const line of text.split("\n")) {
                    const t = line.split("\t");
                    if (t[0] === "backend") root.backend = t[1];
                    else if (t[0] === "iwd") root.iwdInstalled = t[1] === "yes";
                    else if (t[0] === "powersave") root.powersave = t[1];
                }
                root.probed = true;
            }
        }
    }

    function setIwd(on) {
        run(["--iwd", on ? "on" : "off"],
            on ? (root.iwdInstalled ? "Switching to iwd…" : "Installing iwd and switching to it…") : "Switching back to wpa_supplicant…",
            on ? "Wi-Fi now goes through iwd. Wi-Fi reconnects by itself" : "Wi-Fi goes through wpa_supplicant again");
    }
    function setPowersave(on) {
        run(["--powersave", on ? "on" : "off"], "Changing power saving…",
            on ? "Power saving back on" : "Power saving off: steadier Wi-Fi, a little more battery");
    }

    function run(args, working, done) {
        if (root.busy) return;
        root.busy = true;
        root.failed = false;
        root.status = working;
        proc.done = done;
        proc.command = ["pkexec", "bash", root.script].concat(args);
        proc.running = true;
    }
    Process {
        id: proc
        property string done: ""
        stderr: StdioCollector { id: err }
        onExited: code => {
            root.busy = false;
            // pkexec: 126 is a dismissed or refused password, 127 not allowed.
            if (code === 0) { root.failed = false; root.status = proc.done; }
            else {
                root.failed = true;
                const said = err.text.trim().split("\n").pop().replace(/^wifi-tune: /, "");
                root.status = code === 126 || code === 127 ? "Not changed: the password wasn't given" : (said || "That didn't work");
            }
            root.refresh();
            // NetworkManager restarted: the Wi-Fi list is read again.
            settle.restart();
        }
    }
    Timer { id: settle; interval: 3000; onTriggered: Services.Network.refresh() }
}
