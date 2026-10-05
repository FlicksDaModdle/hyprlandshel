pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Machine facts for Settings → About, the control center header and the
// power menu's footer.
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

    // Read straight from the files the old shell pipeline read (/proc,
    // /etc/os-release) and from Hyprland's socket — no processes, except
    // `df` for the disk, which has no file to read. The facts that never
    // change while running (model, kernel, distribution) are read once.
    FileView { id: fHost; path: "/proc/sys/kernel/hostname"; printErrors: false; blockLoading: true }
    FileView { id: fKernel; path: "/proc/sys/kernel/osrelease"; printErrors: false; blockLoading: true }
    FileView { id: fUptime; path: "/proc/uptime"; printErrors: false; blockLoading: true }
    FileView { id: fMem; path: "/proc/meminfo"; printErrors: false; blockLoading: true }
    FileView { id: fCpu; path: "/proc/cpuinfo"; printErrors: false; blockLoading: true }
    FileView { id: fOs; path: "/etc/os-release"; printErrors: false; blockLoading: true }

    function readOnce() {
        fHost.reload(); fKernel.reload(); fCpu.reload(); fOs.reload();
        {
            root.host = String(fHost.text() || "").trim();
            root.kernel = String(fKernel.text() || "").trim();
            const os = /^PRETTY_NAME="?([^"\n]*)"?/m.exec(String(fOs.text() || ""));
            root.distro = os ? os[1] : "Linux";
            const cpu = String(fCpu.text() || "");
            const model = /^model name\s*:\s*(.+)$/m.exec(cpu);
            root.cpuModel = model ? model[1].trim() : "";
            root.cpuThreads = (cpu.match(/^processor\s*:/gm) || []).length;
            const cores = /^cpu cores\s*:\s*(\d+)/m.exec(cpu);
            root.cpuCores = cores ? parseInt(cores[1]) : root.cpuThreads;
        }
        Services.HyprIpc.request("j/version", r => {
            if (r === null) return;
            try { root.compositorVersion = JSON.parse(r).tag || ""; } catch (e) {}
        });
    }
    function readLive() {
        fUptime.reload(); fMem.reload();
        {
            root.uptimeSeconds = parseFloat(String(fUptime.text() || "0").split(" ")[0]) || 0;
            const mem = String(fMem.text() || "");
            const kb = key => { const m = new RegExp("^" + key + ":\\s*(\\d+)", "m").exec(mem); return m ? parseFloat(m[1]) : 0; };
            root.memTotalKb = kb("MemTotal");
            root.memUsedKb = root.memTotalKb - kb("MemAvailable");
        }
        Services.HyprIpc.request("j/devices", r => {
            if (r === null) return;
            try {
                const kbs = (JSON.parse(r).keyboards || []);
                const main = kbs.find(k => k.main) || kbs[0];
                root.keymap = main ? (main.active_keymap || "") : "";
            } catch (e) {}
        });
        df.running = true;
    }
    Process {
        id: df
        command: ["df", "-Pk", "/"]
        stdout: StdioCollector {
            onStreamFinished: {
                const f = (text.split("\n")[1] || "").trim().split(/\s+/);
                root.diskTotalKb = parseFloat(f[1]) || 0;
                root.diskUsedKb = parseFloat(f[2]) || 0;
            }
        }
    }

    // Read once at start, then again only while something showing the
    // changing parts (uptime, memory, disk) is open.
    Component.onCompleted: { readOnce(); readLive(); }
    Timer {
        interval: 15000
        running: Config.UiState.settingsOpen || Config.UiState.powerOpen || Config.UiState.controlCenterOpen
        repeat: true
        triggeredOnStart: true
        onTriggered: root.readLive()
    }

    function refresh() { readLive(); }

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
