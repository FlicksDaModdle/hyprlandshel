pragma Singleton
import QtQuick
import Quickshell
import "../config" as Config
import "." as Services

// Notification history, kept by hyprshell-daemon (rust/daemon/src/nhist.rs):
// every notification shown, still there after it is dismissed, to find
// again from the notification center's History.
//
// Kept on disk (~/.local/state/hyprshell/notifications.json, this user
// only) for the days chosen in Settings → Notifications; switching it off
// forgets everything. A notification its sender marks transient (a volume
// change, a "copied") is never kept.
Singleton {
    id: root

    readonly property var prefs: Config.Appearance
    readonly property bool daemonHas: Services.Daemon.running && Services.Daemon.modules.nhist === true
    readonly property bool on: daemonHas && prefs.notifHistory

    // The center's History view, while it is showing: what was asked for
    // and what came back, newest first.
    property bool active: false
    property string query: ""
    // [{ id, app, summary, body, icon, urgency, time }]
    property var entries: []
    property int total: 0
    property int asked: 0

    function add(n) {
        if (!root.on || !n || n.transient) return;
        Services.Daemon.send({ cmd: "nh-add", app: n.appName || n.desktopEntry || "",
                               summary: n.summary || "", body: n.body || "",
                               icon: n.appIcon || "", urgency: Number(n.urgency) || 0 });
    }
    function remove(id) {
        root.entries = root.entries.filter(e => e.id !== id);
        Services.Daemon.send({ cmd: "nh-delete", id: id });
    }
    function clear() {
        root.entries = [];
        Services.Daemon.send({ cmd: "nh-clear" });
    }

    function search() {
        if (!root.daemonHas || !root.active) return;
        root.asked++;
        Services.Daemon.send({ cmd: "nh-search", id: root.asked, query: root.query, limit: 300 });
    }
    onQueryChanged: searchSoon.restart()
    onActiveChanged: if (active) search()
    Timer { id: searchSoon; interval: 120; onTriggered: root.search() }

    // Only once the settings are read: a days' limit sent before then
    // would be the default, and prune what the chosen one keeps.
    function tell() {
        if (root.daemonHas && root.prefs.settingsReady)
            Services.Daemon.send({ cmd: "nh-config", on: root.prefs.notifHistory,
                                   days: Math.max(1, root.prefs.notifHistoryDays) });
    }
    readonly property string config: [daemonHas, prefs.settingsReady, prefs.notifHistory, prefs.notifHistoryDays].join("|")
    onConfigChanged: tell()

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev === "nh-changed") {
                root.total = ev.total || 0;
                if (root.active) searchSoon.restart();
            } else if (ev.ev === "nh-results") {
                // An answer to an older question is already out of date.
                if (ev.id !== root.asked) return;
                root.entries = ev.entries || [];
                root.total = ev.total || 0;
            }
        }
    }

    // "Today" / "Yesterday" / "Mon 3 Oct" — the day headings.
    function dayOf(t) {
        const d = new Date(t * 1000), now = new Date();
        const start = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
        const ms = d.getTime();
        if (ms >= start) return "Today";
        if (ms >= start - 86400000) return "Yesterday";
        return Qt.formatDate(d, "ddd d MMM");
    }
    function timeOf(t) {
        return Qt.formatTime(new Date(t * 1000), Config.Appearance.clock24 ? "HH:mm" : "h:mm AP");
    }
    // Entries in runs by day, for the list: [{ day, entries }].
    readonly property var byDay: {
        const out = [];
        for (const e of root.entries) {
            const day = dayOf(e.time);
            if (out.length === 0 || out[out.length - 1].day !== day) out.push({ day: day, entries: [] });
            out[out.length - 1].entries.push(e);
        }
        return out;
    }
}
