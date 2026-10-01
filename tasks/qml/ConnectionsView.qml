import QtQuick
import Hyprshell
import Hyprshell.Backend

// Every network connection and listening port, with the process behind it.
Item {
    id: view
    property var frame: null
    property string show: "established"
    property var conns: []
    function load() { view.conns = Tools.connections(); }
    Component.onCompleted: load()
    Timer { interval: 2000; running: !Monitor.paused; repeat: true; onTriggered: view.load() }

    function addr(a, port) { return a.indexOf(":") >= 0 ? "[" + a + "]:" + port : a + ":" + port; }
    readonly property var shown: view.conns.map((c, i) => Object.assign({ key: c.proto + c.inode + ":" + i }, c)).filter(c =>
        (view.show === "all" || (view.show === "listening" ? (c.state === "Listening" || (c.proto.startsWith("UDP") && c.remotePort === 0))
                                                         : c.state === "Established" || c.state === "Connected"))
        && (Tasks.search === "" || (c.process + " " + c.local + " " + c.localPort + " " + c.remote + " " + c.remotePort + " " + c.pid)
                                   .toLowerCase().indexOf(Tasks.search.toLowerCase()) >= 0))

    function menuFor(c) {
        return [
            { n: "Show the process", icon: "cpu", active: c.pid > 0, run: () => Tasks.show("processes", "p:" + c.pid) },
            { n: "Copy remote address", icon: "file", run: () => Tools.runDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "copy", view.addr(c.remote, c.remotePort)]) },
            { n: "Look up the address", icon: "globe", active: c.remote !== "0.0.0.0" && c.remote !== "::",
              run: () => Qt.openUrlExternally("https://ipinfo.io/" + c.remote) },
            { n: "End the process", icon: "x", rule: true, active: c.pid > 0, run: () => Monitor.processes.signal([c.pid], 15) }
        ];
    }

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Connections"
        subtitle: view.conns.filter(c => c.state === "Established").length + " established · "
                  + view.conns.filter(c => c.state === "Listening").length + " listening"
        Seg {
            anchors.verticalCenter: parent.verticalCenter
            options: [{ label: "Established", value: "established" }, { label: "Listening", value: "listening" }, { label: "All", value: "all" }]
            value: view.show
            onPicked: v => view.show = v
        }
    }
    Table {
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "key"
        sortKey: "process"
        rows: view.shown
        emptyText: "No connections."
        columns: [
            { k: "process", t: "Process", w: 200, fmt: c => c.process || (c.uid === 0 ? "(root)" : "(another user)"), glyph: c => Tasks.glyph(c.process),
              dim: c => !c.process },
            { k: "pid", t: "PID", w: 70, num: true, fmt: c => c.pid > 0 ? String(c.pid) : "" },
            { k: "proto", t: "Protocol", w: 80 },
            { k: "local", t: "Local address", fmt: c => view.addr(c.local, c.localPort) },
            { k: "remote", t: "Remote address", fmt: c => c.remotePort > 0 ? view.addr(c.remote, c.remotePort) : "" },
            { k: "state", t: "State", w: 120 }
        ]
        onContextMenu: (c, x, y) => view.frame.menu.openAt(x, y, view.menuFor(c))
    }
}
