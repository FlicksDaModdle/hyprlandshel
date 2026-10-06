pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import "../config" as Config
import "." as Services

// The desktop notification server. This is what makes the bar's bell badge,
// the notification center and the banner toasts real: anything on the system
// that calls org.freedesktop.Notifications (notify-send, your browser, the
// package manager) lands here.
//
// `items` is the server's own tracked list, newest first — deriving from it
// rather than keeping a parallel array means a notification the sending app
// withdraws disappears from the center on its own.
//
// Do-not-disturb (the bar bell's context, the center's toggle, Settings →
// Notifications) suppresses banners but still files notifications in the
// center, which is what the mockup's copy promises: "Silence banners, keep
// them in the center".
Singleton {
    id: root

    NotificationServer {
        id: server

        keepOnReload: false
        actionsSupported: true
        actionIconsSupported: false
        bodySupported: true
        bodyMarkupSupported: true
        imageSupported: true
        persistenceSupported: true

        onNotification: notification => {
            // Tracking keeps the object alive after the sending app drops
            // it, so it stays listed in the center until dismissed here.
            notification.tracked = true;
            root.stamp(notification.id);
            Services.NotifHistory.add(notification);

            if (!Config.Appearance.dnd && !notification.transient) {
                root.popups = [notification].concat(root.popups);
            }
        }
    }

    // Newest first. trackedNotifications is in arrival order.
    readonly property var items: {
        const list = server.trackedNotifications.values.slice();
        list.reverse();
        return list;
    }

    // The subset currently on screen as a banner.
    property var popups: []

    readonly property int count: items.length
    readonly property bool hasAny: count > 0

    // Drop banners whose notification is gone (dismissed here, withdrawn by
    // the app, or expired server-side).
    onItemsChanged: {
        const live = popups.filter(n => n && items.indexOf(n) >= 0);
        if (live.length !== popups.length) popups = live;
    }

    // Turning DND on clears what's already on screen, rather than leaving
    // stale banners up until they time out.
    readonly property bool dnd: Config.Appearance.dnd
    onDndChanged: if (dnd) popups = [];

    // ── arrival times ─────────────────────────────────────────────────────
    // The protocol carries no timestamp, so the server records one per id.
    property var times: ({})
    function stamp(id) {
        const next = times;
        next[id] = Date.now();
        times = next;
        timesChanged();
    }
    function timeOf(n) {
        return n ? (times[n.id] || Date.now()) : Date.now();
    }

    // ── mutation ──────────────────────────────────────────────────────────

    function dismiss(n) {
        if (!n) return;
        dismissPopup(n);
        n.dismiss();
    }

    // Banner timed out or was swiped away: drop the banner, keep the entry
    // in the center.
    function dismissPopup(n) {
        popups = popups.filter(p => p !== n);
    }

    function clearAll() {
        const snapshot = items.slice();
        popups = [];
        for (const n of snapshot) {
            if (n) n.dismiss();
        }
    }

    function invoke(n, action) {
        if (!n) return;
        if (action) action.invoke();
        // Most senders expect the notification to go away once an action
        // runs; `resident` is the opt-out.
        if (!n.resident) dismiss(n);
        else dismissPopup(n);
    }

    // Clicking the body triggers the sender's "default" action if there is
    // one, otherwise it just dismisses.
    function activate(n) {
        if (!n) return;
        const def = n.actions.find(a => a.identifier === "default");
        if (def) invoke(n, def);
        else dismiss(n);
    }

    // Actions worth rendering as buttons — "default" is the whole-body
    // click, so it isn't one.
    function buttonActions(n) {
        return n ? n.actions.filter(a => a.identifier !== "default") : [];
    }

    function toggleDnd() {
        Config.Appearance.dnd = !Config.Appearance.dnd;
    }

    // ── grouping ──────────────────────────────────────────────────────────
    // Settings → Notifications → Grouping. "App" stacks by source, "Time"
    // leaves them in arrival order.
    readonly property var grouped: {
        if (Config.Appearance.grouping !== "App") {
            return items.map(n => ({ key: "n" + n.id, app: appNameOf(n), entries: [n] }));
        }
        const order = [];
        const byApp = ({});
        for (const n of items) {
            const name = appNameOf(n);
            if (!byApp[name]) { byApp[name] = []; order.push(name); }
            byApp[name].push(n);
        }
        return order.map(name => ({ key: name, app: name, entries: byApp[name] }));
    }

    function appNameOf(n) {
        if (!n) return "Notification";
        return n.appName || n.desktopEntry || "Notification";
    }

    // Best-fit glyph from the bespoke pack, so the center doesn't fall back
    // to a generic bell for every common source.
    function iconFor(n) {
        const name = appNameOf(n).toLowerCase();
        if (name.indexOf("update") >= 0 || name.indexOf("pacman") >= 0 || name.indexOf("apt") >= 0
            || name.indexOf("discover") >= 0) return "pkg";
        if (name.indexOf("screenshot") >= 0 || name.indexOf("grim") >= 0 || name.indexOf("capture") >= 0) return "camera";
        if (name.indexOf("batter") >= 0 || name.indexOf("power") >= 0) return "battery";
        if (name.indexOf("volume") >= 0 || name.indexOf("audio") >= 0 || name.indexOf("music") >= 0
            || name.indexOf("spotify") >= 0 || name.indexOf("mpd") >= 0) return "music";
        if (name.indexOf("network") >= 0 || name.indexOf("wifi") >= 0) return "wifi";
        if (name.indexOf("bluetooth") >= 0) return "bluetooth";
        if (name.indexOf("file") >= 0 || name.indexOf("download") >= 0 || name.indexOf("transfer") >= 0) return "download";
        if (name.indexOf("mail") >= 0 || name.indexOf("chat") >= 0 || name.indexOf("message") >= 0
            || name.indexOf("telegram") >= 0 || name.indexOf("signal") >= 0) return "stickyNote";
        if (name.indexOf("firefox") >= 0 || name.indexOf("chrom") >= 0 || name.indexOf("browser") >= 0) return "globe";
        return "bell";
    }

    // "now" / "24m" / "3h" — the compact stamp on each row.
    function relativeTime(ms) {
        tick;   // re-evaluate when the minute ticks over
        const mins = Math.floor((Date.now() - ms) / 60000);
        if (mins < 1) return "now";
        if (mins < 60) return mins + "m";
        const hours = Math.floor(mins / 60);
        if (hours < 24) return hours + "h";
        return Math.floor(hours / 24) + "d";
    }

    // Refreshes the relative stamps without touching the notification list.
    property int tick: 0
    Timer {
        interval: 30000
        running: root.hasAny
        repeat: true
        onTriggered: root.tick++
    }
}
