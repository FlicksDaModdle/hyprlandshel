pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Requests to Hyprland over its own socket, without starting `hyprctl`.
//
// `hyprctl -j clients` is what the shell asks after every window event —
// a window opening, closing, moving, being focused — and `hyprctl eval`
// is every settings change. Each was a process: fork, load hyprctl, connect
// to this same socket, print, exit. Talking to the socket directly is the
// same request without any of that.
//
// Hyprland answers one request per connection and closes it, so each
// request is: connect, write, collect until the server hangs up. One at a
// time, in order; the queue makes bursts (a dozen events as a window
// opens) cost a dozen round trips on one socket, not a dozen processes.
//
// request(cmd, done) — cmd as hyprctl would send it ("j/clients",
// "/eval hl.config(...)"); done(reply) gets the text, or null when the
// socket isn't there (no Hyprland signature: started outside a session),
// and callers fall back to hyprctl.
Singleton {
    id: root

    readonly property string path: {
        const run = Quickshell.env("XDG_RUNTIME_DIR") || "";
        const sig = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "";
        return run !== "" && sig !== "" ? run + "/hypr/" + sig + "/.socket.sock" : "";
    }
    readonly property bool available: path !== "" && !broken
    // Set after repeated failures to connect: callers go back to hyprctl.
    property bool broken: false
    property int failures: 0

    property var queue: []
    property var current: null
    property bool gotBytes: false

    function request(cmd, done) {
        if (!available) { if (done) done(null); return; }
        queue = queue.concat([{ cmd: cmd, done: done || null }]);
        pump();
    }

    function pump() {
        if (current || queue.length === 0) return;
        const q = queue.slice();
        current = q.shift();
        queue = q;
        gotBytes = false;
        timeout.restart();
        sock.connected = true;
    }

    function finish(reply) {
        timeout.stop();
        const c = current;
        current = null;
        if (c && c.done) {
            try { c.done(reply); } catch (e) { console.warn("HyprIpc: handler for", c.cmd, "threw", e); }
        }
        pump();
    }

    Socket {
        id: sock
        path: root.path
        parser: StdioCollector {
            id: reply
            waitForEnd: false
            onDataChanged: root.gotBytes = true
        }
        onConnectionStateChanged: {
            if (connected) {
                if (!root.current) { connected = false; return; }
                write(root.current.cmd);
                flush();
                return;
            }
            // The server hung up: that is the end of the reply. Stop the
            // socket reconnecting by itself before anything else.
            sock.connected = false;
            if (!root.current) return;
            root.failures = 0;
            root.finish(root.gotBytes ? reply.text : "");
        }
        // Hyprland hanging up after its reply arrives here first, as
        // PeerClosedError (1), and then as the disconnect above: that one is
        // the normal end of a request, not a failure.
        onError: err => {
            if (err === 1 || !root.current) return;
            root.failures++;
            if (root.failures >= 3) {
                root.broken = true;
                console.warn("HyprIpc: can't reach", root.path, "— using hyprctl from here on");
            }
            sock.connected = false;
            root.finish(null);
        }
    }

    // A reply that never ends (Hyprland hung, or busy in a long reload)
    // must not hold up everything queued behind it.
    Timer {
        id: timeout
        interval: 3000
        onTriggered: {
            if (!root.current) return;
            sock.connected = false;
            root.finish(null);
        }
    }
}
