pragma Singleton
import QtQuick
import Quickshell
import "." as Services

// The launcher's calculator: sums and unit conversions ("12*7.5",
// "5 km in miles", "72f in c", "15% of 80"), worked out by hyprshell-daemon
// (rust/daemon/src/calc.rs) as you type. `result` is empty when what is in
// the box is not a calculation.
Singleton {
    id: root

    readonly property bool available: Services.Daemon.running && Services.Daemon.modules.calc === true
    property string query: ""
    property string result: ""
    property int lastId: 0

    function ask(q) {
        root.query = q;
        if (!root.available || q.trim() === "" || !/[0-9πτφ]/.test(q)) { root.result = ""; return; }
        root.lastId++;
        Services.Daemon.send({ cmd: "calc", id: root.lastId, query: q });
    }

    // Typed before the daemon was up: asked again once it is.
    onAvailableChanged: if (available && query !== "") ask(query)

    Connections {
        target: Services.Daemon
        function onEvent(ev) {
            if (ev.ev !== "calc" || ev.query !== root.query) return;
            root.result = ev.result || "";
        }
    }

    // What Enter copies: the number alone, without digit-group commas or
    // the unit — what you would paste into a field or a spreadsheet.
    function plain(r) {
        const m = /^(-?[0-9,.]+(?:×10\^-?[0-9]+)?)/.exec(r);
        return m ? m[1].replace(/,/g, "") : r;
    }
    function copy(r) {
        const text = root.plain(r);
        try { Quickshell.clipboardText = text; }
        catch (e) { Quickshell.execDetached(["wl-copy", "--", text]); }
    }
}
