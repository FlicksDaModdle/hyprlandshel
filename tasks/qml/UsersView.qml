import QtQuick
import Hyprshell
import Hyprshell.Backend

// Who is using the machine: each account with processes running, what they
// add up to, and the login sessions behind them.
Item {
    id: view
    property var frame: null
    property var sessions: []
    Component.onCompleted: Tools.sessions()
    Timer { interval: 10000; running: true; repeat: true; onTriggered: Tools.sessions() }
    Connections { target: Tools; function onSessionsLoaded(list) { view.sessions = list; } }

    readonly property var users: (Monitor.sampledAt > 0 ? Monitor.processes.users() : []).map(u => Object.assign({}, u, {
        sessions: view.sessions.filter(s => s.uid === u.uid),
        key: String(u.uid)
    })).filter(u => Tasks.search === "" || u.name.toLowerCase().indexOf(Tasks.search.toLowerCase()) >= 0)

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Users"
        subtitle: view.sessions.length + " login session" + (view.sessions.length === 1 ? "" : "s")
    }
    Table {
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "key"
        sortKey: "cpu"
        sortDesc: true
        rows: view.users
        columns: [
            { k: "name", t: "User", glyph: u => "user", fmt: u => u.name + (u.me ? "  (you)" : "") },
            { k: "status", t: "Sessions", w: 220, fmt: u => u.sessions.map(s => (s.tty || s.seat || s["class"] || "session") + (s.idle ? " · idle" : "")).join(", ") || (u.uid < 1000 ? "System account" : "") },
            { k: "processes", t: "Processes", w: 96, num: true },
            { k: "cpu", t: "CPU", w: 80, num: true, fmt: u => Tasks.pct(u.cpu, 1) },
            { k: "mem", t: "Memory", w: 100, num: true, fmt: u => Tasks.bytes(u.mem) },
            { k: "disk", t: "Disk", w: 100, num: true, fmt: u => Tasks.rate(u.disk) },
            { k: "gpu", t: "GPU", w: 70, num: true, fmt: u => Tasks.pct(u.gpu) }
        ]
    }
}
