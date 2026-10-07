pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
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

    function open() { Quickshell.execDetached(["hyprshell-mail"]); }
    function compose(to) { Quickshell.execDetached(["hyprshell-mail", to ? "mailto:" + to : "--compose"]); }
    function openMessage(id) { Quickshell.execDetached(["hyprshell-mail", "--message=" + id]); }

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
