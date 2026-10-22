pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Hyprshell Calendar (apps/calendar), from the shell's side: the events it
// keeps, for the bar's calendar, and opening the app.
//
// The app writes the coming year's occurrences — repeats worked out — to
// upcoming.json whenever its calendars change; this only reads that file.
// Mail's invitations are left out here, since Services.Mail has them
// already, with the message to open.
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (root.home + "/.local/share")
    // [{ uid, summary, location, start, end, allDay, calendar, color }]
    property var events: []

    FileView {
        path: root.dataHome + "/hyprshell-calendar/upcoming.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const all = JSON.parse(text() || "[]");
                root.events = Array.isArray(all) ? all.filter(e => e.calendar !== "Invitations") : [];
            } catch (e) {
                root.events = [];
            }
        }
        onLoadFailed: root.events = []
    }

    readonly property string finder:
        'command -v hyprshell-calendar >/dev/null 2>&1 && exec hyprshell-calendar "$@"; '
        + 'for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do '
        + '[ -x "$d/hyprshell-calendar" ] && exec "$d/hyprshell-calendar" "$@"; done; '
        + 'notify-send "Calendar" "Not installed yet — run apps/install.sh from the hyprshell folder" 2>/dev/null; exit 127'

    function open() {
        const w = (Services.Compositor.clients || []).find(c => /^hyprshell-calendar$/i.test(c.cls || ""));
        if (w && w.address) { Services.Compositor.focusClient(w.address); return; }
        Config.Apps.launch(["sh", "-c", root.finder, "open-calendar"]);
    }

    // Both sources: the Calendar's events and Mail's invitations.
    readonly property var all: root.events.concat(Services.Mail.available ? Services.Mail.events : [])
    function eventsOn(y, m, d) {
        const a = new Date(y, m, d).getTime() / 1000, b = a + 86400;
        return root.all.filter(e => e.start < b && e.end > a);
    }
    function upcoming(n) {
        const now = Date.now() / 1000;
        return root.all.filter(e => e.end > now).sort((x, y) => x.start - y.start).slice(0, n || 4);
    }
}
