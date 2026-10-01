import QtQuick
import Hyprshell
import Hyprshell.Backend

// systemd's services, the system's and your own: what is running, what
// starts at boot, and start / stop / restart / enable / disable.
Item {
    id: view
    property var frame: null
    property bool user: false
    property string show: "running"
    property var services: []
    property bool loading: true

    function load() { view.loading = true; Tools.loadServices(view.user); }
    Component.onCompleted: load()
    onUserChanged: load()
    Timer { interval: 10000; running: true; repeat: true; onTriggered: Tools.loadServices(view.user) }
    Connections {
        target: Tools
        function onServicesLoaded(user, list) { if (user === view.user) { view.services = list; view.loading = false; } }
        function onActionDone(ok, message) {
            if (view.frame) view.frame.toast.show(message, !ok);
            refreshSoon.restart();
        }
    }
    Timer { id: refreshSoon; interval: 600; onTriggered: Tools.loadServices(view.user) }

    readonly property var shown: view.services.filter(s =>
        (view.show === "all" || (view.show === "running" ? s.active === "active" : view.show === "failed" ? s.active === "failed" : true))
        && (Tasks.search === "" || (s.unit + " " + (s.description || "")).toLowerCase().indexOf(Tasks.search.toLowerCase()) >= 0))

    function act(s, action) { Tools.serviceAction(view.user, s.unit, action); }
    function menuFor(s) {
        const running = s.active === "active";
        const enabled = s.enabled === "enabled";
        return [
            { n: "Start", icon: "play", active: !running, run: () => view.act(s, "start") },
            { n: "Stop", icon: "square", active: running, run: () => view.act(s, "stop") },
            { n: "Restart", icon: "rotateCw", run: () => view.act(s, "restart") },
            { n: enabled ? "Don't start at boot" : "Start at boot", icon: "power", rule: true,
              active: s.enabled === "enabled" || s.enabled === "disabled",
              run: () => view.act(s, enabled ? "disable" : "enable") },
            { n: "Show its log", icon: "list", rule: true,
              run: () => Tools.openTerminal(["journalctl"].concat(view.user ? ["--user"] : []).concat(["-u", s.unit, "-e", "-f"])) },
            { n: "Show in Processes", icon: "cpu", active: s.pid > 0, run: () => Tasks.show("processes", "p:" + s.pid) },
            { n: "Open unit file", icon: "file", active: !!s.path, run: () => Tools.showInFolder(s.path) }
        ];
    }

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Services"
        subtitle: view.services.filter(s => s.active === "active").length + " running"
                  + (view.services.some(s => s.active === "failed") ? " · " + view.services.filter(s => s.active === "failed").length + " failed" : "")
                  + " · " + view.services.length + " in all"
        Seg {
            anchors.verticalCenter: parent.verticalCenter
            options: [{ label: "System", value: false }, { label: "Mine", value: true }]
            value: view.user
            onPicked: v => view.user = v
        }
        Seg {
            anchors.verticalCenter: parent.verticalCenter
            options: [{ label: "Running", value: "running" }, { label: "Failed", value: "failed" }, { label: "All", value: "all" }]
            value: view.show
            onPicked: v => view.show = v
        }
        ToolButton { anchors.verticalCenter: parent.verticalCenter; icon: "play"; text: "Start"; active: !!table.selected && table.selected.active !== "active"; onClicked: view.act(table.selected, "start") }
        ToolButton { anchors.verticalCenter: parent.verticalCenter; icon: "square"; text: "Stop"; active: !!table.selected && table.selected.active === "active"; onClicked: view.act(table.selected, "stop") }
        ToolButton { anchors.verticalCenter: parent.verticalCenter; icon: "rotateCw"; text: "Restart"; active: !!table.selected; onClicked: view.act(table.selected, "restart") }
    }

    Table {
        id: table
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "unit"
        sortKey: "unit"
        loading: view.loading
        rows: view.shown
        emptyText: view.show === "failed" ? "No service has failed." : "No services match."
        columns: [
            { k: "unit", t: "Name", w: 260, fmt: s => s.unit.replace(/\.service$/, ""), glyph: s => Tasks.glyph(s.unit) },
            { k: "description", t: "Description" },
            { k: "active", t: "Status", w: 130, fmt: s => s.active === "active" ? (s.sub === "running" ? "Running" : s.sub) : s.active === "failed" ? "Failed" : "Stopped",
              alert: s => s.active === "failed", dim: s => s.active !== "active" },
            { k: "enabled", t: "At boot", w: 110, fmt: s => ({ enabled: "Starts", disabled: "Manual", static: "As needed", masked: "Masked", indirect: "Indirect", generated: "Generated", alias: "Alias" })[s.enabled] || s.enabled },
            { k: "pid", t: "PID", w: 72, num: true, fmt: s => s.pid > 0 ? String(s.pid) : "" , sort: s => s.pid },
            { k: "memory", t: "Memory", w: 96, num: true, fmt: s => s.memory >= 0 ? Tasks.bytes(s.memory) : "", sort: s => s.memory },
            { k: "cpuSeconds", t: "CPU time", w: 96, num: true, fmt: s => s.cpuSeconds >= 0 ? Tasks.duration(s.cpuSeconds) : "", sort: s => s.cpuSeconds }
        ]
        onContextMenu: (s, x, y) => view.frame.menu.openAt(x, y, view.menuFor(s))
        onActivated: s => view.frame.menu.openAt(table.width / 2, 200, view.menuFor(s))
    }
}
