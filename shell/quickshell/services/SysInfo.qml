pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config

// Machine facts for Settings → About, the control center header and the
// power menu's footer. One shell poll gathers the lot rather than spawning a
// process per field.
Singleton {
    id: root

    property string user: Quickshell.env("USER") || "user"
    property string host: ""
    property string cpuModel: ""
    property int cpuCores: 0
    property int cpuThreads: 0

    property real memTotalKb: 0
    property real memUsedKb: 0
    readonly property real memRatio: memTotalKb > 0 ? memUsedKb / memTotalKb : 0

    property real diskTotalKb: 0
    property real diskUsedKb: 0
    readonly property real diskRatio: diskTotalKb > 0 ? diskUsedKb / diskTotalKb : 0

    property real uptimeSeconds: 0
    property string compositorVersion: ""
    property string kernel: ""
    property string distro: ""
    property string keymap: ""

    readonly property string uptimeLabel: {
        const s = uptimeSeconds;
        const d = Math.floor(s / 86400);
        const h = Math.floor((s % 86400) / 3600);
        const m = Math.floor((s % 3600) / 60);
        if (d > 0) return d + "d " + h + "h";
        if (h > 0) return h + "h " + m + "m";
        return m + "m";
    }

    function gib(kb) { return (kb / 1048576).toFixed(1) + " GB"; }

    readonly property string memLabel: memTotalKb > 0 ? gib(memUsedKb) + " of " + gib(memTotalKb) + " in use" : "—"
    readonly property string diskLabel: diskTotalKb > 0 ? gib(diskUsedKb) + " of " + gib(diskTotalKb) + " used" : "—"

    // Fields are emitted as `key<TAB>value` lines so parsing stays trivial.
    Process {
        id: poll
        command: ["sh", "-c",
            "printf 'host\\t%s\\n' \"$(uname -n)\"; "
            + "printf 'kernel\\t%s\\n' \"$(uname -r)\"; "
            + "printf 'uptime\\t%s\\n' \"$(cut -d' ' -f1 /proc/uptime)\"; "
            + "awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf \"mem\\t%d\\t%d\\n\", t, t-a}' /proc/meminfo; "
            + "awk -F: '/^model name/{m=$2} /^processor/{th++} /^cpu cores/{c=$2} END{gsub(/^ +/,\"\",m); printf \"cpu\\t%s\\t%d\\t%d\\n\", m, c, th}' /proc/cpuinfo; "
            + "df -Pk / | awk 'NR==2{printf \"disk\\t%d\\t%d\\n\", $2, $3}'; "
            + ". /etc/os-release 2>/dev/null; printf 'distro\\t%s\\n' \"${PRETTY_NAME:-Linux}\"; "
            + "printf 'wm\\t%s\\n' \"$(hyprctl version -j 2>/dev/null | sed -n 's/.*\"tag\": *\"\\([^\"]*\\)\".*/\\1/p' | head -1)\"; "
            + "printf 'keymap\\t%s\\n' \"$(hyprctl -j devices 2>/dev/null | sed -n 's/.*\"active_keymap\": *\"\\([^\"]*\\)\".*/\\1/p' | head -1)\""]

        stdout: StdioCollector {
            onStreamFinished: {
                for (const line of text.split("\n")) {
                    const f = line.split("\t");
                    switch (f[0]) {
                    case "host":    root.host = f[1] || ""; break;
                    case "kernel":  root.kernel = f[1] || ""; break;
                    case "uptime":  root.uptimeSeconds = parseFloat(f[1]) || 0; break;
                    case "distro":  root.distro = f[1] || ""; break;
                    case "wm":      root.compositorVersion = f[1] || ""; break;
                    case "keymap":  root.keymap = f[1] || ""; break;
                    case "mem":
                        root.memTotalKb = parseFloat(f[1]) || 0;
                        root.memUsedKb = parseFloat(f[2]) || 0;
                        break;
                    case "disk":
                        root.diskTotalKb = parseFloat(f[1]) || 0;
                        root.diskUsedKb = parseFloat(f[2]) || 0;
                        break;
                    case "cpu":
                        root.cpuModel = f[1] || "";
                        root.cpuCores = parseInt(f[2]) || 0;
                        root.cpuThreads = parseInt(f[3]) || 0;
                        break;
                    }
                }
            }
        }
    }

    // Read once at start, then again only while something showing the
    // changing parts (uptime, memory, disk) is open: the read starts a
    // dozen small processes, and doing that every fifteen seconds all day
    // for pages nobody was looking at was most of what this shell cost
    // when idle.
    Component.onCompleted: poll.running = true
    Timer {
        interval: 15000
        running: Config.UiState.settingsOpen || Config.UiState.powerOpen || Config.UiState.controlCenterOpen
        repeat: true
        triggeredOnStart: true
        onTriggered: poll.running = true
    }

    function refresh() { poll.running = true; }

    readonly property string cpuLabel: cpuThreads > 0
        ? cpuCores + (cpuCores === 1 ? " core · " : " cores · ") + cpuThreads + " threads"
        : "—"

    // "hyprland · wayland · 2 monitors" in the control center header.
    function sessionLabel(monitorCount) {
        const wm = compositorVersion ? "hyprland " + compositorVersion : "hyprland";
        const mons = monitorCount === 1 ? "1 monitor" : monitorCount + " monitors";
        return wm + " · wayland · " + mons;
    }
}
