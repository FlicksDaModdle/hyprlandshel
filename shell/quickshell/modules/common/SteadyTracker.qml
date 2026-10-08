import QtQuick
import Quickshell.Services.Pipewire

// Keeps PipeWire nodes bound (their volumes and properties live) without the
// churn that crashes Quickshell.
//
// A PwObjectTracker bound straight to a list binds and unbinds as fast as
// the list changes, and a node let go while PipeWire still has an update on
// its way to it brings the whole shell down (PwNodeBoundAudio::onInfo on an
// unbound node). So: a node is taken on only once it has existed for a
// moment (an app's stream; devices at once) — long enough for its first updates to have arrived, and for
// whatever decides whether it belongs in the list to have settled — and is
// never let go while it still exists. It goes when PipeWire removes it, or
// when this tracker does.
Item {
    id: root
    visible: false

    property var nodes: []
    // How long a node has to have existed before it is bound.
    property int settleMs: 1200

    property var held: []
    property var seen: ({})

    onNodesChanged: settle.restart()
    Timer { id: settle; interval: 150; onTriggered: root.update() }
    // Ages new nodes in.
    Timer { id: again; interval: root.settleMs; onTriggered: root.update() }

    function alive(n) { return !!n && Pipewire.nodes.values.indexOf(n) >= 0; }

    function update() {
        const now = Date.now();
        const seen = root.seen;
        const next = root.held.filter(n => root.alive(n));
        let waiting = false;
        for (const n of root.nodes) {
            if (!n || next.indexOf(n) >= 0) continue;
            const k = String(n.id);
            if (seen[k] === undefined) seen[k] = now;
            // Devices are steady things and bound at once, so their levels
            // show the moment the pane opens; apps' streams come and go.
            if (!n.isStream || now - seen[k] >= root.settleMs) next.push(n);
            else waiting = true;
        }
        // Forget the times of nodes long gone.
        for (const k in seen) if (now - seen[k] > 600000) delete seen[k];
        const changed = next.length !== root.held.length || next.some((n, i) => n !== root.held[i]);
        if (changed) root.held = next;
        if (waiting) again.restart();
    }

    PwObjectTracker { objects: root.held }
}
