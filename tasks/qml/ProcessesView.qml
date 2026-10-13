import QtQuick
import Hyprshell
import Hyprshell.Backend

// Every process: grouped the way Windows' Task Manager does it (Apps,
// Background, System), as the parent/child tree, or as one flat list —
// with the heat of each figure behind it, and everything that can be done
// to a process a right-click away.
Item {
    id: view
    property var frame: null

    readonly property var model: Monitor.processes
    property string selectedKey: ""
    property int selectedPid: 0
    property bool detailsOpen: false
    property var lastAction: null       // repeated as administrator when the kernel said no

    readonly property var allColumns: [
        { k: "status",  t: "Status",       w: 118, num: false },
        { k: "pid",     t: "PID",          w: 72,  num: true },
        { k: "user",    t: "User",         w: 96,  num: false },
        { k: "cpu",     t: "CPU",          w: 76,  num: true, total: () => Tasks.pct(view.model.totals.cpu || 0) },
        { k: "mem",     t: "Memory",       w: 96,  num: true, total: () => Tasks.pct(Monitor.memory.percent || 0) },
        { k: "disk",    t: "Disk",         w: 96,  num: true, total: () => Tasks.rate((view.model.totals.readBps || 0) + (view.model.totals.writeBps || 0)) },
        { k: "gpu",     t: "GPU",          w: 68,  num: true, total: () => Tasks.pct(Math.max(0, ...Monitor.gpus.map(g => g.busy || 0), 0)) },
        { k: "gpumem",  t: "GPU memory",   w: 96,  num: true },
        { k: "power",   t: "Power usage",  w: 104, num: false },
        { k: "threads", t: "Threads",      w: 72,  num: true }
    ]
    // The columns chosen, less whichever do not fit: a narrow window drops
    // the least useful first (power, then the GPU's, then threads, user,
    // PID and status) rather than pushing the rest off its right edge.
    readonly property real minName: 240
    readonly property var dropOrder: ["power", "gpumem", "threads", "user", "pid", "gpu", "status", "disk"]
    readonly property var columns: {
        let cols = allColumns.filter(c => Tasks.settings.columns.indexOf(c.k) >= 0);
        let sum = cols.reduce((a, c) => a + c.w, 0);
        // The scroll bar sits over the right edge: leave it its own room.
        const room = list.width - view.minName - 14;
        for (const k of view.dropOrder) {
            if (sum <= room) break;
            const c = cols.find(x => x.k === k);
            if (c) { cols = cols.filter(x => x !== c); sum -= c.w; }
        }
        return cols;
    }
    readonly property real fixedWidth: columns.reduce((a, c) => a + c.w, 0)
    readonly property real nameWidth: Math.max(view.minName, list.width - 14 - fixedWidth)

    Component.onCompleted: {
        view.readShell();
        if (Tasks.focusKey !== "") {
            view.select(Tasks.focusKey);
            Tasks.focusKey = "";
            Qt.callLater(() => { const i = view.model.rowOf(view.selectedKey); if (i >= 0) list.positionViewAtIndex(i, ListView.Center); });
        }
    }
    Binding { target: view.model; property: "filter"; value: Tasks.search }

    // ── actions ───────────────────────────────────────────────────────────
    function select(key) {
        view.selectedKey = key;
        const i = view.model.rowOf(key);
        view.selectedPid = i >= 0 ? view.model.row(i).pid : 0;
    }
    function current() { const i = view.model.rowOf(view.selectedKey); return i >= 0 ? view.model.row(i) : null; }
    function act(fn) {
        view.lastAction = fn;
        fn(false);
    }
    function endTask(r, sig) { if (r) act(admin => view.model.signal(r.pids, sig || 15, admin)); }
    Connections {
        target: Monitor.processes
        function onActionDone(ok, message, canRetry) {
            if (!view.frame) return;
            view.frame.toast.show(message, !ok, canRetry ? "Try as administrator" : "",
                                  canRetry && view.lastAction ? () => view.lastAction(true) : null);
        }
    }

    function menuFor(r) {
        if (!r || r.kind === 0) return [];
        const out = [];
        const stopped = r.status === "Suspended";
        if (r.kind === 1 || (r.expandable && view.model.mode === "tree"))
            out.push({ n: r.expanded ? "Collapse" : "Expand", icon: r.expanded ? "chevronUp" : "chevronDown", run: () => view.model.toggle(r.key) });
        if (r.address !== "")
            out.push({ n: "Switch to", icon: "cornerDownLeft", run: () => Tools.focusWindow(r.address) });
        out.push({ n: "End task", icon: "x", rule: out.length > 0, run: () => view.endTask(r, 15) });
        out.push({ n: "Kill", icon: "x", danger: true, run: () => view.endTask(r, 9) });
        out.push({ n: stopped ? "Resume" : "Suspend", icon: stopped ? "play" : "pause",
                   run: () => view.act(admin => view.model.signal(r.pids, stopped ? 18 : 19, admin)) });
        const eff = r.status === "Efficiency mode";
        out.push({ n: "Efficiency mode", icon: "zap", checked: eff,
                   run: () => view.act(admin => view.model.setEfficiency(r.pids, !eff, admin)) });
        out.push({ n: "Priority", icon: "sliders", sub: [
            { n: "Lowest (19)", nice: 19 }, { n: "Low (10)", nice: 10 }, { n: "Below normal (5)", nice: 5 },
            { n: "Normal (0)", nice: 0 }, { n: "Above normal (-5)", nice: -5 }, { n: "High (-10)", nice: -10 },
            { n: "Highest (-20)", nice: -20 }
        ].map(p => ({ n: p.n, checked: r.kind === 2 && r.nice === p.nice,
                      run: () => view.act(admin => view.model.setNice(r.pids, p.nice, admin)) })) });
        if (r.kind === 2)
            out.push({ n: "Processor affinity…", icon: "cpu", run: () => affinity.openFor(r) });
        out.push({ n: "Details", icon: "info", rule: true, run: () => { view.select(r.key); view.detailsOpen = true; } });
        if (r.exe !== "")
            out.push({ n: "Open file location", icon: "folderOpen", run: () => Tools.showInFolder(r.exe) });
        out.push({ n: "Search online", icon: "globe", run: () => Qt.openUrlExternally("https://duckduckgo.com/?q=" + encodeURIComponent(r.name + " linux process")) });
        out.push({ n: "Copy", icon: "file", sub: [
            { n: "Name", run: () => copy.text(r.name) },
            { n: "PID", run: () => copy.text(String(r.pid)) },
            { n: "Command line", active: r.cmd !== "", run: () => copy.text(r.cmd) }
        ] });
        return out;
    }
    QtObject {
        id: copy
        function text(t) { Tools.runDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "copy", t]); }
    }

    function optionsMenu() {
        const p = view.model;
        const r = view.current();
        const eff = !!r && r.status === "Efficiency mode";
        return [
            { n: "Efficiency mode", icon: "zap", checked: eff, active: !!r && r.kind > 0,
              run: () => view.act(admin => view.model.setEfficiency(r.pids, !eff, admin)) },
            { n: "Show kernel threads", rule: true, checked: p.showKernel, run: () => { p.showKernel = !p.showKernel; Tasks.set("showKernel", p.showKernel); } },
            { n: "Show other users' processes", checked: p.showOtherUsers, run: () => { p.showOtherUsers = !p.showOtherUsers; Tasks.set("showOthers", p.showOtherUsers); } },
            { n: "CPU as % of one core", checked: p.perCore, run: () => { p.perCore = !p.perCore; Tasks.set("perCore", p.perCore); } },
            { n: "Show shell memory", icon: "monitor", checked: Tasks.settings.shellMemory,
              run: () => { Tasks.set("shellMemory", !Tasks.settings.shellMemory); view.readShell(); } },
            { n: "Expand all", icon: "chevronDown", rule: true, run: () => p.expandAll(true) },
            { n: "Collapse all", icon: "chevronUp", run: () => p.expandAll(false) },
            { n: "Columns", icon: "list", rule: true, sub: view.allColumns.map(c => ({
                n: c.t, checked: Tasks.settings.columns.indexOf(c.k) >= 0,
                run: () => {
                    const cols = Tasks.settings.columns.slice();
                    const i = cols.indexOf(c.k);
                    if (i >= 0) cols.splice(i, 1); else cols.push(c.k);
                    Tasks.set("columns", view.allColumns.map(x => x.k).filter(k => cols.indexOf(k) >= 0));
                } })) }
        ];
    }

    // ── header ────────────────────────────────────────────────────────────
    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Processes"
        subtitle: Tasks.count(Monitor.system.processes) + " processes · " + Tasks.count(Monitor.system.threads) + " threads"
                  + (Tasks.search !== "" ? " · matching “" + Tasks.search + "”" : "")

        Seg {
            anchors.verticalCenter: parent.verticalCenter
            options: [{ label: "Apps", value: "apps" }, { label: "Tree", value: "tree" }, { label: "All", value: "flat" }]
            value: view.model.mode
            onPicked: v => { view.model.mode = v; Tasks.set("mode", v); }
        }
        ToolButton {
            anchors.verticalCenter: parent.verticalCenter
            icon: "plus"
            text: "Run new task"
            onClicked: runDialog.open = true
        }
        ToolButton {
            anchors.verticalCenter: parent.verticalCenter
            icon: "x"
            text: "End task"
            danger: true
            active: view.current() !== null && view.current().kind > 0 && !view.current().dead
            onClicked: view.endTask(view.current(), 15)
        }
        ToolButton {
            id: optBtn
            anchors.verticalCenter: parent.verticalCenter
            icon: "moreHorizontal"
            onClicked: {
                const p = optBtn.mapToItem(view.frame, 0, optBtn.height + 4);
                view.frame.menu.openAt(p.x - 200, p.y, view.optionsMenu());
            }
        }
    }

    // ── the shell's own use ───────────────────────────────────────────────
    // What hyprshell itself costs, in one place: the shell, its background
    // services, and (apart, since they are apps you chose to open) its own
    // apps. Read each sample while it is shown, and not at all otherwise.
    property var shellUse: ({ mem: 0, pss: 0, gpuMem: 0, cpu: 0, appMem: 0, parts: [] })
    function readShell() { if (Tasks.settings.shellMemory) view.shellUse = view.model.shellUsage(); }
    Connections {
        target: Monitor
        enabled: Tasks.settings.shellMemory
        function onUpdated() { view.readShell(); }
    }
    function shellGlyph(key) {
        const own = { shell: "monitor", "hyprshell-daemon": "settings", "hyprshell-maild": "stickyNote",
                      "hyprshell-agent": "wifi", helpers: "package" };
        return own[key] || Tasks.glyph(key);
    }

    Card {
        id: shellStrip
        visible: Tasks.settings.shellMemory
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: details.left
        anchors.leftMargin: 16
        anchors.rightMargin: 16
        height: visible ? Math.max(summary.implicitHeight, chips.implicitHeight) + 24 : 0

        Column {
            id: summary
            x: 16
            anchors.verticalCenter: parent.verticalCenter
            width: 168
            spacing: 2
            StyledText {
                text: "Hyprshell"
                font.pixelSize: Appearance.fs(11)
                font.weight: Font.DemiBold
                color: Appearance.ink3
            }
            StyledText {
                text: Tasks.bytes(view.shellUse.mem)
                font.pixelSize: Appearance.fs(22)
                font.weight: Font.DemiBold
                color: Appearance.ink
            }
            StyledText {
                width: parent.width
                elide: Text.ElideRight
                text: "Proportional " + Tasks.bytes(view.shellUse.pss)
                      + (view.shellUse.gpuMem > 0 ? " · video " + Tasks.bytes(view.shellUse.gpuMem) : "")
                font.pixelSize: Appearance.fs(11)
                color: Appearance.ink3
            }
        }
        Rectangle {
            id: split
            anchors.left: summary.right
            anchors.leftMargin: 8
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: 12
            width: 1
            color: Appearance.rule
        }
        Flow {
            id: chips
            anchors.left: split.right
            anchors.leftMargin: 14
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Repeater {
                model: view.shellUse.parts
                Rectangle {
                    id: chip
                    required property var modelData
                    readonly property bool app: modelData.role === "app"
                    width: chipRow.implicitWidth + 20
                    height: 30
                    radius: Appearance.rSm
                    color: chipArea.containsMouse ? Appearance.hover : "transparent"
                    border.width: 1
                    border.color: Appearance.rule
                    opacity: app ? 0.75 : 1
                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 7
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: view.shellGlyph(chip.modelData.key)
                            size: 14
                            inkColor: Appearance.ink2
                            accentColor: Appearance.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: chip.modelData.label + (chip.app ? " (app)" : "")
                            font.pixelSize: Appearance.fs(12)
                            color: Appearance.ink2
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Tasks.bytes(chip.modelData.mem)
                            font.pixelSize: Appearance.fs(12)
                            font.weight: Font.DemiBold
                            color: Appearance.ink
                        }
                    }
                    MouseArea {
                        id: chipArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            view.select("p:" + chip.modelData.pids[0]);
                            view.selectedPid = chip.modelData.pids[0];
                            view.detailsOpen = true;
                        }
                    }
                }
            }
            StyledText {
                visible: view.shellUse.parts.length === 0
                height: 30
                verticalAlignment: Text.AlignVCenter
                text: "The shell isn't running."
                font.pixelSize: Appearance.fs(12)
                color: Appearance.ink3
            }
        }
    }

    // ── table ─────────────────────────────────────────────────────────────
    Item {
        id: table
        anchors.top: shellStrip.visible ? shellStrip.bottom : head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: details.left
        anchors.bottom: parent.bottom

        Rectangle {
            id: headerRow
            width: parent.width
            height: 46
            color: "transparent"
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
            Row {
                x: 0
                height: parent.height
                Repeater {
                    model: [{ k: "name", t: "Name", w: view.nameWidth, num: false }].concat(view.columns)
                    Item {
                        id: hc
                        required property var modelData
                        readonly property bool sorted: view.model.sortKey === modelData.k
                        width: modelData.w
                        height: headerRow.height
                        Rectangle { anchors.fill: parent; color: hArea.containsMouse ? Appearance.hover : "transparent" }
                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.leftMargin: hc.modelData.k === "name" ? 20 : 8
                            anchors.rightMargin: 10
                            StyledText {
                                width: parent.width
                                horizontalAlignment: hc.modelData.num ? Text.AlignRight : Text.AlignLeft
                                visible: !!hc.modelData.total
                                text: hc.modelData.total ? hc.modelData.total() : ""
                                font.pixelSize: Appearance.fs(14)
                                font.weight: Font.DemiBold
                            }
                            StyledText {
                                width: parent.width
                                horizontalAlignment: hc.modelData.num ? Text.AlignRight : Text.AlignLeft
                                text: hc.modelData.t + (hc.sorted ? (view.model.sortDescending ? "  ▾" : "  ▴") : "")
                                font.pixelSize: Appearance.fs(11)
                                font.weight: hc.sorted ? Font.DemiBold : Font.Medium
                                color: hc.sorted ? Appearance.accent : Appearance.ink3
                                elide: Text.ElideRight
                            }
                        }
                        Rectangle { anchors.right: parent.right; width: 1; height: parent.height - 16; anchors.verticalCenter: parent.verticalCenter; color: Appearance.rule }
                        MouseArea {
                            id: hArea
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: mouse => {
                                if (mouse.button === Qt.RightButton) {
                                    const p = hArea.mapToItem(view.frame, mouse.x, mouse.y);
                                    view.frame.menu.openAt(p.x, p.y, view.optionsMenu().slice(-1)[0].sub);
                                    return;
                                }
                                const k = hc.modelData.k;
                                if (view.model.sortKey === k) view.model.sortDescending = !view.model.sortDescending;
                                else { view.model.sortKey = k; Tasks.set("sortKey", k); }
                            }
                        }
                    }
                }
            }
        }

        SmoothScroll { target: list; anchors.fill: list; z: 5 }
        ScrollBar { target: list; anchors.top: list.top; anchors.bottom: list.bottom; anchors.right: list.right; z: 6 }

        ListView {
            id: list
            anchors.top: headerRow.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: view.model
            reuseItems: true
            focus: true
            keyNavigationEnabled: false

            Keys.onPressed: event => {
                const n = view.model.count;
                let i = view.model.rowOf(view.selectedKey);
                const r = view.current();
                if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
                    i = Math.max(0, Math.min(n - 1, i + (event.key === Qt.Key_Down ? 1 : -1)));
                    view.select(view.model.row(i).key);
                    list.positionViewAtIndex(i, ListView.Contain);
                } else if (event.key === Qt.Key_Delete && r) {
                    view.endTask(r, (event.modifiers & Qt.ShiftModifier) ? 9 : 15);
                } else if ((event.key === Qt.Key_Right || event.key === Qt.Key_Left) && r && (r.kind === 1 || r.expandable || r.kind === 0)) {
                    view.model.setExpanded(r.key, event.key === Qt.Key_Right);
                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && r) {
                    view.detailsOpen = true;
                } else return;
                event.accepted = true;
            }

            delegate: Rectangle {
                id: row
                required property int index
                required property int kind
                required property string key
                required property int pid
                required property var pids
                required property int depth
                required property string name
                required property string title
                required property string icon
                required property string user
                required property string status
                required property real cpu
                required property real mem
                required property real disk
                required property real gpu
                required property real gpuMem
                required property int power
                required property int threads
                required property int nice
                required property string cmd
                required property string exe
                required property bool expandable
                required property bool expanded
                required property int count
                required property bool dead
                required property string address
                required property bool ioKnown

                readonly property bool chosen: view.selectedKey === row.key
                width: list.width
                height: row.kind === 0 ? 34 : 30
                color: row.dead ? Qt.rgba(Appearance.accent.r, Appearance.accent.g, Appearance.accent.b, 0.16)
                     : row.chosen ? Appearance.sel
                     : rowArea.containsMouse ? Appearance.hover : "transparent"

                function asMap() {
                    return { kind: row.kind, key: row.key, pid: row.pid, pids: row.pids, name: row.name, status: row.status,
                             nice: row.nice, cmd: row.cmd, exe: row.exe, expandable: row.expandable, expanded: row.expanded,
                             dead: row.dead, address: row.address };
                }

                // Section header: "Apps (5)".
                Row {
                    visible: row.kind === 0
                    x: 14
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "chevronRight"
                        rotation: row.expanded ? 90 : 0
                        size: 13
                        inkColor: Appearance.ink3
                        accentColor: inkColor
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.name + " (" + row.count + ")"
                        font.pixelSize: Appearance.fs(12.5)
                        font.weight: Font.DemiBold
                        color: Appearance.accent
                    }
                }

                // Name, with its fold, glyph and window title.
                Item {
                    visible: row.kind !== 0
                    width: view.nameWidth
                    height: parent.height
                    readonly property real indent: 12 + row.depth * 18
                    MonoIcon {
                        id: chevron
                        x: parent.indent
                        anchors.verticalCenter: parent.verticalCenter
                        visible: row.kind === 1 || row.expandable
                        name: "chevronRight"
                        rotation: row.expanded ? 90 : 0
                        size: 12
                        inkColor: Appearance.ink3
                        accentColor: inkColor
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: view.model.toggle(row.key)
                        }
                    }
                    MonoIcon {
                        id: glyph
                        x: parent.indent + 18
                        anchors.verticalCenter: parent.verticalCenter
                        name: Tasks.glyph(row.icon)
                        size: 16
                        inkColor: row.dead ? Appearance.ink3 : Appearance.ink2
                        accentColor: row.dead ? Appearance.ink3 : Appearance.accent
                    }
                    StyledText {
                        id: nameText
                        anchors.left: glyph.right
                        anchors.leftMargin: 9
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth, parent.width - x - 10)
                        elide: Text.ElideRight
                        text: row.name + (row.kind === 1 && row.count > 1 ? " (" + row.count + ")" : "")
                        font.pixelSize: Appearance.fs(12.5)
                        font.weight: row.kind === 1 ? Font.DemiBold : Font.Normal
                        font.strikeout: row.dead
                        color: row.dead ? Appearance.ink3 : Appearance.ink
                    }
                    StyledText {
                        anchors.left: nameText.right
                        anchors.leftMargin: 8
                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        visible: row.title !== "" && row.title !== row.name
                        text: row.title
                        font.pixelSize: Appearance.fs(11.5)
                        color: Appearance.ink3
                    }
                }

                // The figures, each with its heat behind it.
                Row {
                    visible: row.kind !== 0
                    x: view.nameWidth
                    height: parent.height
                    Repeater {
                        model: view.columns
                        Item {
                            id: cell
                            required property var modelData
                            width: modelData.w
                            height: row.height
                            readonly property real heat: {
                                switch (modelData.k) {
                                case "cpu": return row.cpu / (view.model.perCore ? 100 * Math.max(1, Monitor.cores.length) : 100) * 2.2;
                                case "mem": return Monitor.memory.total > 0 ? row.mem / Monitor.memory.total * 6 : 0;
                                case "disk": return row.disk / (40 * 1048576);
                                case "gpu": return row.gpu / 100 * 2;
                                case "power": return row.power / 4 * 0.9;
                                default: return 0;
                                }
                            }
                            Rectangle {
                                anchors.fill: parent
                                anchors.topMargin: 1
                                anchors.bottomMargin: 1
                                visible: cell.heat > 0.02 && !row.dead
                                color: Qt.rgba(Appearance.accent.r, Appearance.accent.g, Appearance.accent.b, Math.min(0.55, cell.heat * 0.55))
                            }
                            StyledText {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 10
                                verticalAlignment: Text.AlignVCenter
                                horizontalAlignment: cell.modelData.num ? Text.AlignRight : Text.AlignLeft
                                elide: Text.ElideRight
                                font.pixelSize: Appearance.fs(12)
                                color: row.dead ? Appearance.ink3 : cell.modelData.k === "status" && row.status === "Suspended" ? Appearance.accent : Appearance.ink
                                text: {
                                    switch (cell.modelData.k) {
                                    // Only what is worth noticing: a column of
                                    // "Sleeping" on every row says nothing.
                                    case "status": return row.status === "Sleeping" || row.status === "Running" ? "" : row.status;
                                    case "pid": return row.kind === 1 ? "" : String(row.pid);
                                    case "user": return row.user;
                                    case "cpu": return Tasks.pct(row.cpu, 1);
                                    case "mem": return Tasks.bytes(row.mem);
                                    case "disk": return row.ioKnown ? (row.disk < 1 ? "0 B/s" : Tasks.rate(row.disk)) : "—";
                                    case "gpu": return row.gpu > 0.05 ? Tasks.pct(row.gpu, 1) : "0%";
                                    case "gpumem": return row.gpuMem > 0 ? Tasks.bytes(row.gpuMem) : "";
                                    case "power": return row.dead ? "" : Tasks.powerNames[row.power];
                                    case "threads": return String(row.threads);
                                    }
                                    return "";
                                }
                            }
                        }
                    }
                }

                MouseArea {
                    id: rowArea
                    anchors.fill: parent
                    z: -1
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        list.forceActiveFocus();
                        if (row.kind === 0) { view.model.toggle(row.key); return; }
                        view.select(row.key);
                        if (mouse.button === Qt.RightButton) {
                            const p = rowArea.mapToItem(view.frame, mouse.x, mouse.y);
                            view.frame.menu.openAt(p.x, p.y, view.menuFor(row.asMap()));
                        }
                    }
                    onDoubleClicked: {
                        if (row.kind === 1 || row.expandable) view.model.toggle(row.key);
                        else if (row.address !== "") Tools.focusWindow(row.address);
                        else view.detailsOpen = true;
                    }
                }
            }

            StyledText {
                anchors.centerIn: parent
                visible: list.count === 0
                text: Tasks.search !== "" ? "No process matches “" + Tasks.search + "”" : "Reading processes…"
                font.pixelSize: Appearance.fs(13)
                color: Appearance.ink3
            }
        }
    }

    // ── details ───────────────────────────────────────────────────────────
    ProcessDetails {
        id: details
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: widthSpring.value
        pid: view.selectedPid
        onCloseRequested: view.detailsOpen = false
        onEndRequested: sig => view.endTask(view.current(), sig)
        Spring { id: widthSpring; to: view.detailsOpen && view.selectedPid > 0 ? Math.min(380, view.width * 0.4) : 0; response: 260; bounce: 0 }
    }

    // ── dialogs ───────────────────────────────────────────────────────────
    AffinityDialog {
        id: affinity
        anchors.fill: parent
        onApply: (pid, cpus) => view.act(admin => view.model.setAffinity(pid, cpus, admin))
    }
    RunDialog {
        id: runDialog
        anchors.fill: parent
    }
}
