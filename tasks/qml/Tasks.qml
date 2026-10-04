pragma Singleton
import QtQuick
import Hyprshell.Backend
import "Glyphs.js" as Glyphs

// The task manager's own state — which view is open, the search, what was
// last selected — and its settings, kept in
// ~/.config/hyprshell-tasks/settings.json. Also the number formatting
// every view shares.
QtObject {
    id: root

    property string view: "summary"
    property string search: ""
    // A process the Processes view should show selected when it opens: the
    // Summary's "Show" and the Performance view's lists set it.
    property string focusKey: ""
    // The device the Performance view shows: "cpu", "mem", "disk/nvme0n1",
    // "net/wlan0", "gpu/0", "battery".
    property string perfDevice: "cpu"
    function show(view, key) { if (key) root.focusKey = key; root.view = view; }

    // ── settings ──────────────────────────────────────────────────────────
    property var settings: ({
        interval: 1000,          // ms between samples
        smooth: true,            // 60 Hz graphs
        span: 60,                // seconds a graph shows
        tombstone: 5,            // seconds an exited process stays
        perCore: false,          // CPU % of one core rather than the machine
        showKernel: false,
        showOthers: true,
        mode: "apps",
        sortKey: "cpu",
        columns: ["status", "cpu", "mem", "disk", "gpu", "power"],
        navCollapsed: false,
        startView: "summary"
    })
    readonly property string path: Sys.configDir() + "/hyprshell-tasks/settings.json"
    function load() {
        const text = Sys.readFile(root.path);
        if (!text) return;
        try {
            const saved = JSON.parse(text);
            root.settings = Object.assign({}, root.settings, saved);
        } catch (e) {}
    }
    function set(key, value) {
        const s = Object.assign({}, root.settings);
        s[key] = value;
        root.settings = s;
        saveTimer.restart();
    }
    property Timer saveTimer: Timer {
        interval: 400
        onTriggered: Sys.writeFile(root.path, JSON.stringify(root.settings, null, 2))
    }
    Component.onCompleted: {
        load();
        Monitor.interval = root.settings.interval;
        const p = Monitor.processes;
        p.tombstoneSeconds = root.settings.tombstone;
        p.perCore = root.settings.perCore;
        p.showKernel = root.settings.showKernel;
        p.showOtherUsers = root.settings.showOthers;
        p.mode = root.settings.mode;
        p.sortKey = root.settings.sortKey;
        root.view = startView !== "" ? startView : root.settings.startView;
    }

    // How many samples a graph shows: its span over the update interval,
    // within the history Monitor keeps.
    // On battery and discharging. Smooth graphs redraw at the display's
    // own rate for as long as they are on screen — 120 times a second on a
    // fast panel — so on battery they step once a sample instead.
    readonly property bool onBattery: !!Monitor.battery && Monitor.battery.present === true
                                      && Monitor.battery.status === "Discharging"
    readonly property bool smoothNow: root.settings.smooth && !root.onBattery

    readonly property int points: Math.max(10, Math.min(Monitor.historySize, Math.round(root.settings.span * 1000 / Math.max(250, root.settings.interval))))

    // ── formatting ────────────────────────────────────────────────────────
    function glyph(hint) { return Glyphs.forHint(hint); }

    // Binary units, as the kernel counts memory: 1 GB here is 1024³.
    function bytes(n, digits) {
        if (n === undefined || n === null || n < 0 || isNaN(n)) return "—";
        const u = ["B", "KB", "MB", "GB", "TB", "PB"];
        let i = 0;
        while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
        const d = digits !== undefined ? digits : (n >= 100 || i === 0 ? 0 : 1);
        return n.toFixed(d) + " " + u[i];
    }
    function rate(n) { return n === undefined || n < 0 ? "—" : root.bytes(n) + "/s"; }
    // Network speeds in bits, as links are rated.
    function bits(n) {
        if (n === undefined || n < 0) return "—";
        n *= 8;
        const u = ["bps", "Kbps", "Mbps", "Gbps"];
        let i = 0;
        while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
        return n.toFixed(n >= 100 || i === 0 ? 0 : 1) + " " + u[i];
    }
    function pct(n, digits) { return n === undefined || n < 0 || isNaN(n) ? "—" : n.toFixed(digits === undefined ? (n < 10 && n > 0 ? 1 : 0) : digits) + "%"; }
    function mhz(n) { return !n ? "—" : n >= 1000 ? (n / 1000).toFixed(2) + " GHz" : Math.round(n) + " MHz"; }
    function celsius(n) { return n === undefined || n === null || n < -100 ? "—" : Math.round(n) + " °C"; }
    function watts(n) { return n === undefined || n < 0 ? "—" : n.toFixed(n < 10 ? 1 : 0) + " W"; }
    function duration(s) {
        if (s === undefined || s < 0) return "—";
        s = Math.floor(s);
        const d = Math.floor(s / 86400), h = Math.floor(s / 3600) % 24, m = Math.floor(s / 60) % 60, sec = s % 60;
        const p = n => (n < 10 ? "0" : "") + n;
        return (d > 0 ? d + ":" : "") + p(h) + ":" + p(m) + ":" + p(sec);
    }
    function friendlyDuration(s) {
        if (s === undefined || s < 0) return "—";
        if (s < 90) return Math.round(s) + " s";
        if (s < 5400) return Math.round(s / 60) + " min";
        if (s < 172800) return (s / 3600).toFixed(1) + " h";
        return Math.round(s / 86400) + " days";
    }
    function count(n) { return n === undefined ? "—" : Math.round(n).toLocaleString(Qt.locale("en_US"), "f", 0); }
    readonly property var powerNames: ["Very low", "Low", "Moderate", "High", "Very high"]
    function stamp(epochSecs) {
        if (!epochSecs) return "—";
        return new Date(epochSecs * 1000).toLocaleString(Qt.locale(), "yyyy-MM-dd HH:mm");
    }
}
