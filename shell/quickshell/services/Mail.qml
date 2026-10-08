pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../config" as Config
import "." as Services

// Hyprshell Mail (mail/), from the shell's side: the unread count for the
// bar, accepted invitations for the calendar, and opening the app.
//
// It talks to hyprshell-maild over its socket, the same JSON lines the app
// uses, and only listens: the daemon announces new mail and changed counts
// itself. Without the daemon (Mail not installed, or not running) this is
// quietly absent — `available` false, nothing in the bar.
Singleton {
    id: root

    readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/hyprshell-mail.sock"
    readonly property bool available: sock.connected
    property int unread: 0
    property var byAccount: ({})
    // [{ uid, summary, start, end, allDay, location, response, … }]
    property var events: []

    // Found the way the terminal and Files are (Config.Apps): by name, then
    // in ~/.local/bin — which a session started by a display manager often
    // does not have on its PATH, and a bare name then started nothing — and
    // through the launch door, so it gets the session's current settings.
    readonly property string finder:
        'command -v hyprshell-mail >/dev/null 2>&1 && exec hyprshell-mail "$@"; '
        + 'for d in "$HOME/.local/bin" /usr/local/bin /usr/bin; do '
        + '[ -x "$d/hyprshell-mail" ] && exec "$d/hyprshell-mail" "$@"; done; '
        + 'notify-send "Mail" "Not installed yet — run mail/install.sh from the hyprshell folder" 2>/dev/null; exit 127'
    function run(args) { Config.Apps.launch(["sh", "-c", root.finder, "open-mail"].concat(args || [])); }

    // Open already: its window brought forward — a Wayland app cannot raise
    // itself, so a second start only reaches the first without showing it.
    function open() {
        const w = (Services.Compositor.clients || []).find(c => /^hyprshell-mail$/i.test(c.cls || ""));
        if (w && w.address) { Services.Compositor.focusClient(w.address); return; }
        root.run([]);
    }
    function compose(to) { root.run([to ? "mailto:" + to : "--compose"]); }
    function openMessage(id) { root.run(["--message=" + id]); }

    // Events on a given day, for the calendar's marks and list.
    function eventsOn(y, m, d) {
        const a = new Date(y, m, d).getTime() / 1000, b = a + 86400;
        return root.events.filter(e => e.start < b && e.end > a);
    }
    function upcoming(n) {
        const now = Date.now() / 1000;
        return root.events.filter(e => e.end > now).sort((x, y) => x.start - y.start).slice(0, n || 4);
    }

    property int rid: 0
    function send(cmd, args) {
        if (!sock.connected) return;
        const o = Object.assign({ cmd: cmd, rid: ++root.rid }, args || {});
        sock.write(JSON.stringify(o) + "\n");
        sock.flush();
    }
    function refreshEvents() {
        const now = Math.floor(Date.now() / 1000);
        root.send("events.list", { from: now - 40 * 86400, to: now + 400 * 86400 });
    }

    Socket {
        id: sock
        path: root.socketPath
        connected: false
        onConnectedChanged: {
            if (connected) { root.send("status"); root.refreshEvents(); }
            else retry.restart();
        }
        parser: SplitParser {
            onRead: line => {
                let m;
                try { m = JSON.parse(line); } catch (e) { return; }
                if (m.event === "unread") { root.unread = m.total || 0; root.byAccount = m.byAccount || {}; return; }
                if (m.event === "events") { root.refreshEvents(); return; }
                if (!m.ok || !m.result) return;
                const r = m.result;
                if (r.unread !== undefined && r.accounts !== undefined) { root.unread = r.unread; root.byAccount = r.byAccount || {}; }
                else if (Array.isArray(r) && (r.length === 0 || r[0].uid !== undefined && r[0].start !== undefined)) root.events = r;
            }
        }
    }
    // The daemon may start after the shell, or restart: keep knocking,
    // gently. A file test first, so a missing socket costs nothing.
    Timer {
        id: retry
        interval: 15000
        running: true
        repeat: true
        onTriggered: if (!sock.connected) probe.running = true
    }
    Process {
        id: probe
        command: ["test", "-S", root.socketPath]
        onExited: code => { if (code === 0) sock.connected = true; }
    }
    Component.onCompleted: probe.running = true
}
