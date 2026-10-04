import QtQuick
import Hyprshell
import Hyprshell.Backend

// Every device, Windows' Performance tab style: a list down the left with
// a live sparkline each, and the chosen one's page — the big graph, the
// figures that matter now, and the facts that do not change.
Item {
    id: view
    property var frame: null

    // The list: [{ id, title, sub, series, series2, max, minScale }]
    readonly property var devices: {
        const out = [];
        const c = Monitor.cpu, m = Monitor.memory;
        out.push({ id: "cpu", title: "CPU", sub: Tasks.pct(c.percent || 0) + "  " + Tasks.mhz(c.mhz)
                   + (c.temp !== undefined ? "  " + Tasks.celsius(c.temp) : ""), series: "cpu", max: 100, icon: "cpu" });
        out.push({ id: "mem", title: "Memory", sub: Tasks.bytes(m.used) + " / " + Tasks.bytes(m.total, 0) + "  (" + Tasks.pct(m.percent || 0) + ")",
                   series: "mem", max: 100, icon: "database" });
        for (const d of Monitor.disks)
            out.push({ id: "disk/" + d.name, title: "Disk " + d.index + " (" + d.name + ")",
                       sub: d.type + "  " + Tasks.pct(d.active), series: "disk/" + d.name + "/active", max: 100, icon: "disk" });
        for (const n of Monitor.networks)
            out.push({ id: "net/" + n.name, title: n.type, sub: n.up ? "↓ " + Tasks.bits(n.rxBps) + "  ↑ " + Tasks.bits(n.txBps) : "Not connected",
                       series: "net/" + n.name + "/rx", series2: "net/" + n.name + "/tx", max: 0, minScale: 1024, icon: n.type === "Wi-Fi" ? "wifi" : "globe" });
        for (const g of Monitor.gpus)
            out.push({ id: "gpu/" + g.index, title: "GPU " + g.index, sub: g.asleep ? "Asleep" : (g.busy >= 0 ? Tasks.pct(g.busy) : g.driver)
                       + (g.temp !== undefined ? "  " + Tasks.celsius(g.temp) : ""),
                       series: "gpu/" + g.index + "/busy", max: 100, icon: "monitor" });
        if (Monitor.battery.present)
            out.push({ id: "battery", title: "Battery", sub: Monitor.battery.percent + "%  " + (Monitor.battery.watts > 0.1 ? Tasks.watts(Monitor.battery.watts) : Monitor.battery.status),
                       series: "bat/watts", max: 0, minScale: 5, icon: "battery" });
        return out;
    }
    readonly property string current: devices.some(d => d.id === Tasks.perfDevice) ? Tasks.perfDevice : "cpu"
    readonly property var disk: Monitor.disks.find(d => "disk/" + d.name === view.current) || ({})
    readonly property var net: Monitor.networks.find(n => "net/" + n.name === view.current) || ({})
    readonly property var gpu: Monitor.gpus.find(g => "gpu/" + g.index === view.current) || ({})

    // ── the list ──────────────────────────────────────────────────────────
    Item {
        id: side
        width: 250
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        SmoothScroll { target: sideList; anchors.fill: sideList; z: 5 }
        ListView {
            id: sideList
            anchors.fill: parent
            anchors.topMargin: 10
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: view.devices
            spacing: 2
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: view.current === modelData.id
                x: 10
                width: sideList.width - 20
                height: 66
                radius: Appearance.rSm
                color: on ? Appearance.sel : area.containsMouse ? Appearance.hover : "transparent"
                border.width: on ? 1 : 0
                border.color: Appearance.accent
                Graph {
                    x: 8; y: 9
                    width: 76; height: 48
                    source: Monitor
                    series: modelData.series
                    series2: modelData.series2 || ""
                    maxValue: modelData.max
                    minScale: modelData.minScale || 1
                    points: 30
                    grid: false
                    animate: Tasks.smoothNow
                    lineWidth: 1.2
                    color: Appearance.accent
                    color2: Appearance.ink3
                    Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: Appearance.edge; radius: 3 }
                }
                Column {
                    x: 96
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 104
                    spacing: 2
                    StyledText { width: parent.width; elide: Text.ElideRight; text: modelData.title; font.pixelSize: Appearance.fs(13); font.weight: Font.DemiBold }
                    StyledText { width: parent.width; elide: Text.ElideRight; text: modelData.sub; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink2 }
                }
                MouseArea {
                    id: area
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Tasks.perfDevice = modelData.id
                }
            }
        }
        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Appearance.rule }
    }

    // ── the page ──────────────────────────────────────────────────────────
    Loader {
        anchors.left: side.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        sourceComponent: view.current === "cpu" ? cpuPage
                       : view.current === "mem" ? memPage
                       : view.current.indexOf("disk/") === 0 ? diskPage
                       : view.current.indexOf("net/") === 0 ? netPage
                       : view.current.indexOf("gpu/") === 0 ? gpuPage
                       : view.current === "battery" ? batteryPage : cpuPage
    }

    // ── CPU ──
    Component {
        id: cpuPage
        PerfPage {
            id: cp
            property string mode: "overall"
            readonly property var c: Monitor.cpu
            readonly property var i: Monitor.info
            title: "CPU"
            model: cp.i.cpuModel || ""
            Row {
                spacing: 8
                Seg {
                    options: [{ label: "Overall", value: "overall" }, { label: "Logical processors", value: "cores" }].concat(
                        (cp.i.numa || []).length > 1 ? [{ label: "NUMA nodes", value: "numa" }] : [])
                    value: cp.mode
                    onPicked: v => cp.mode = v
                }
            }
            BigGraph {
                visible: cp.mode === "overall"
                width: parent.width
                height: 260
                caption: "% Utilization"
                series: "cpu"
            }
            // One small graph per logical processor.
            Grid {
                id: coreGrid
                visible: cp.mode === "cores"
                width: parent.width
                readonly property int n: Monitor.cores.length
                columns: Math.max(1, Math.ceil(Math.sqrt(n * 1.6)))
                spacing: 6
                Repeater {
                    model: cp.mode === "cores" ? coreGrid.n : 0
                    Item {
                        required property int index
                        width: (coreGrid.width - coreGrid.spacing * (coreGrid.columns - 1)) / coreGrid.columns
                        height: Math.max(52, Math.min(110, 330 / Math.ceil(coreGrid.n / coreGrid.columns)))
                        Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: Appearance.edge; radius: 3 }
                        Graph {
                            anchors.fill: parent
                            anchors.margins: 1
                            source: Monitor
                            series: "cpu/" + index
                            maxValue: 100
                            points: Tasks.points
                            animate: Tasks.smoothNow
                            grid: false
                            lineWidth: 1.1
                            color: Appearance.accent
                        }
                        StyledText {
                            x: 5; y: 3
                            text: index + "  " + Tasks.pct((Monitor.cores[index] || {}).percent || 0)
                                  + ((Monitor.cores[index] || {}).mhz ? "  " + Tasks.mhz(Monitor.cores[index].mhz) : "")
                            font.pixelSize: Appearance.fs(10)
                            color: Appearance.ink3
                        }
                    }
                }
            }
            Column {
                visible: cp.mode === "numa"
                width: parent.width
                spacing: 8
                Repeater {
                    model: cp.mode === "numa" ? cp.i.numa : []
                    KeyValue { required property var modelData; label: modelData.name; value: "CPUs " + modelData.cpus + " · " + Tasks.bytes(modelData.memory) }
                }
            }
            StatGrid {
                width: parent.width
                stats: [
                    { label: "Utilization", value: Tasks.pct(cp.c.percent || 0) },
                    { label: "Speed", value: Tasks.mhz(cp.c.mhz) },
                    { label: "Temperature", value: Tasks.celsius(cp.c.temp), alert: (cp.c.temp || 0) >= 90 },
                    { label: "Processes", value: Tasks.count(Monitor.system.processes) },
                    { label: "Threads", value: Tasks.count(Monitor.system.threads) },
                    { label: "Handles", value: Tasks.count(Monitor.system.handles) },
                    { label: "Up time", value: Tasks.duration(Monitor.system.uptime), wide: true },
                    { label: "Waiting for CPU", value: Tasks.pct(Monitor.pressure.cpuSome || 0), alert: (Monitor.pressure.cpuSome || 0) >= 25 },
                    { label: "User / kernel", value: Tasks.pct(cp.c.user || 0, 0) + " / " + Tasks.pct(cp.c.system || 0, 0) }
                ]
                facts: [
                    { label: "Base speed", value: cp.i.baseMHz ? Tasks.mhz(cp.i.baseMHz) : "" },
                    { label: "Maximum speed", value: cp.i.maxMHz ? Tasks.mhz(cp.i.maxMHz) : "" },
                    { label: "Sockets", value: String(cp.i.sockets || "") },
                    { label: "Cores", value: String(cp.i.cores || "") },
                    { label: "Logical processors", value: String(cp.i.threads || "") },
                    { label: "Virtualization", value: cp.i.virtualization ? cp.i.virtualization + " supported" : "Not available" },
                    { label: "L1 cache", value: cp.i.caches ? Tasks.bytes((cp.i.caches.L1d || 0) + (cp.i.caches.L1i || 0)) : "" },
                    { label: "L2 cache", value: cp.i.caches && cp.i.caches.L2 ? Tasks.bytes(cp.i.caches.L2) : "" },
                    { label: "L3 cache", value: cp.i.caches && cp.i.caches.L3 ? Tasks.bytes(cp.i.caches.L3) : "" },
                    { label: "Load average", value: [Monitor.system.load1, Monitor.system.load5, Monitor.system.load15].map(v => (v || 0).toFixed(2)).join("  ") },
                    { label: "Context switches", value: Tasks.count(cp.c.ctxPerSec) + "/s" },
                    { label: "Interrupts", value: Tasks.count(cp.c.intrPerSec) + "/s" },
                    { label: "Scaling driver", value: cp.i.scalingDriver || "" },
                    { label: "Governor", value: Monitor.system.governor || "" }
                ]
            }
        }
    }

    // ── Memory ──
    Component {
        id: memPage
        PerfPage {
            id: mp
            readonly property var m: Monitor.memory
            title: "Memory"
            model: Tasks.bytes(mp.m.total, 1)
            BigGraph {
                width: parent.width
                height: 220
                caption: "Memory in use"
                series: "mem"
                format: v => Tasks.bytes(mp.m.total, 1)
            }
            // What the memory holds, left to right, as Windows shows it.
            Column {
                width: parent.width
                spacing: 4
                StyledText { text: "Memory composition"; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                Rectangle {
                    id: comp
                    width: parent.width
                    height: 34
                    radius: 4
                    color: "transparent"
                    border.width: 1
                    border.color: Appearance.edge
                    clip: true
                    readonly property real total: Math.max(1, mp.m.total || 1)
                    readonly property var parts: [
                        { t: "In use", v: (mp.m.used || 0) - (mp.m.dirty || 0), c: Qt.rgba(Appearance.accent.r, Appearance.accent.g, Appearance.accent.b, 0.55) },
                        { t: "Modified", v: mp.m.dirty || 0, c: Qt.rgba(Appearance.accent.r, Appearance.accent.g, Appearance.accent.b, 0.85) },
                        { t: "Cached", v: mp.m.cached || 0, c: Appearance.sel },
                        { t: "Free", v: mp.m.free || 0, c: "transparent" }
                    ]
                    Row {
                        anchors.fill: parent
                        anchors.margins: 1
                        Repeater {
                            model: comp.parts
                            Rectangle {
                                required property var modelData
                                width: Math.max(0, (comp.width - 2) * modelData.v / comp.total)
                                height: parent.height
                                color: modelData.c
                                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Appearance.edge }
                                MouseArea { id: partArea; anchors.fill: parent; hoverEnabled: true }
                                StyledText {
                                    anchors.centerIn: parent
                                    visible: parent.width > implicitWidth + 10
                                    text: modelData.t
                                    font.pixelSize: Appearance.fs(10.5)
                                    color: Appearance.ink
                                }
                            }
                        }
                    }
                }
            }
            StatGrid {
                width: parent.width
                stats: [
                    { label: "In use", value: Tasks.bytes(mp.m.used) },
                    { label: "Available", value: Tasks.bytes(mp.m.available) },
                    { label: "Committed", value: Tasks.bytes(mp.m.committed, 0) + " / " + Tasks.bytes(mp.m.commitLimit, 0), wide: true },
                    { label: "Cached", value: Tasks.bytes(mp.m.cached) },
                    { label: "Swap", value: Tasks.bytes(mp.m.swapUsed) + " / " + Tasks.bytes(mp.m.swapTotal, 0), wide: true, alert: mp.m.swapTotal > 0 && mp.m.swapUsed / mp.m.swapTotal > 0.5 },
                    { label: "Waiting for memory", value: Tasks.pct(Monitor.pressure.memSome || 0), alert: (Monitor.pressure.memSome || 0) >= 5 },
                    { label: "Stalled entirely", value: Tasks.pct(Monitor.pressure.memFull || 0) }
                ]
                facts: [
                    { label: "Total", value: Tasks.bytes(mp.m.total) },
                    { label: "Free", value: Tasks.bytes(mp.m.free) },
                    { label: "Buffers", value: Tasks.bytes(mp.m.buffers) },
                    { label: "Shared", value: Tasks.bytes(mp.m.shared) },
                    { label: "Modified (dirty)", value: Tasks.bytes(mp.m.dirty) },
                    { label: "Kernel", value: Tasks.bytes(mp.m.kernel) },
                    { label: "Slab", value: Tasks.bytes(mp.m.slab) },
                    { label: "zram", value: mp.m.zramSize > 0 ? Tasks.bytes(mp.m.zramOriginal) + " stored in " + Tasks.bytes(mp.m.zramUsed)
                                                              + (mp.m.zramUsed > 0 ? " (" + (mp.m.zramOriginal / mp.m.zramUsed).toFixed(1) + "×)" : "") : "Not in use" }
                ]
            }
        }
    }

    // ── Disk ──
    Component {
        id: diskPage
        PerfPage {
            id: dp
            readonly property var d: view.disk
            title: "Disk " + (dp.d.index !== undefined ? dp.d.index : "") + " (" + (dp.d.name || "") + ")"
            model: dp.d.model || ""
            BigGraph {
                width: parent.width
                height: 180
                caption: "Active time"
                series: "disk/" + dp.d.name + "/active"
            }
            BigGraph {
                width: parent.width
                height: 160
                caption: "Disk transfer rate"
                series: "disk/" + dp.d.name + "/read"
                series2: "disk/" + dp.d.name + "/write"
                maxValue: 0
                minScale: 1048576
                format: v => Tasks.rate(v)
                legend: true
                legend1: "Read"
                legend2: "Write"
            }
            StatGrid {
                width: parent.width
                stats: [
                    { label: "Active time", value: Tasks.pct(dp.d.active || 0), alert: dp.d.active >= 90 },
                    { label: "Average response", value: (dp.d.responseMs || 0).toFixed(1) + " ms" },
                    { label: "Read speed", value: Tasks.rate(dp.d.readBps) },
                    { label: "Write speed", value: Tasks.rate(dp.d.writeBps) }
                ]
                facts: [
                    { label: "Capacity", value: Tasks.bytes(dp.d.size) },
                    { label: "Formatted", value: Tasks.bytes((dp.d.mounts || []).reduce((a, m) => a + m.total, 0)) },
                    { label: "System disk", value: dp.d.system ? "Yes" : "No" },
                    { label: "Type", value: dp.d.type || "" }
                ]
            }
            Column {
                width: parent.width
                spacing: 8
                Repeater {
                    model: dp.d.mounts || []
                    Column {
                        required property var modelData
                        width: parent.width
                        spacing: 4
                        Item {
                            width: parent.width
                            height: 18
                            StyledText { text: modelData.path + "  ·  " + modelData.fs + (modelData.readOnly ? "  ·  read-only" : ""); font.pixelSize: Appearance.fs(12) }
                            StyledText { anchors.right: parent.right; text: Tasks.bytes(modelData.free) + " free of " + Tasks.bytes(modelData.total); font.pixelSize: Appearance.fs(12); color: Appearance.ink2 }
                        }
                        Meter { width: parent.width; value: modelData.total > 0 ? modelData.used / modelData.total : 0 }
                    }
                }
            }
        }
    }

    // ── Network ──
    Component {
        id: netPage
        PerfPage {
            id: np
            readonly property var n: view.net
            title: np.n.type || "Network"
            model: np.n.name || ""
            BigGraph {
                width: parent.width
                height: 260
                caption: "Throughput"
                series: "net/" + np.n.name + "/rx"
                series2: "net/" + np.n.name + "/tx"
                maxValue: 0
                minScale: 1024
                format: v => Tasks.bits(v)
                legend: true
                legend1: "Receive"
                legend2: "Send"
            }
            StatGrid {
                width: parent.width
                stats: [
                    { label: "Receive", value: Tasks.bits(np.n.rxBps) },
                    { label: "Send", value: Tasks.bits(np.n.txBps) },
                    { label: "Received in all", value: Tasks.bytes(np.n.rxTotal) },
                    { label: "Sent in all", value: Tasks.bytes(np.n.txTotal) }
                ].concat(np.n.signalDbm !== undefined ? [{ label: "Signal", value: Math.round(np.n.signalDbm) + " dBm" }] : [])
                facts: [
                    { label: "Adapter", value: np.n.name || "" },
                    { label: "Connection type", value: np.n.type || "" },
                    { label: "State", value: np.n.up ? "Connected" : "Not connected" },
                    { label: "Link speed", value: np.n.speedMbps > 0 ? np.n.speedMbps + " Mbps" : "" },
                    { label: "IPv4 address", value: (np.n.ipv4 || []).join(", ") },
                    { label: "IPv6 address", value: (np.n.ipv6 || []).join("\n") },
                    { label: "Hardware address", value: np.n.mac || "" },
                    { label: "Driver", value: np.n.driver || "" }
                ]
            }
        }
    }

    // ── GPU ──
    Component {
        id: gpuPage
        PerfPage {
            id: gp
            readonly property var g: view.gpu
            title: "GPU " + (gp.g.index !== undefined ? gp.g.index : "")
            model: gp.g.name || ""
            Card {
                visible: !!gp.g.asleep
                width: parent.width
                height: 64
                StyledText {
                    anchors.fill: parent
                    anchors.margins: 14
                    wrapMode: Text.WordWrap
                    verticalAlignment: Text.AlignVCenter
                    text: "This GPU is powered down and will wake when something uses it. It is left asleep here: reading its figures would wake it, which on a laptop costs a lot of battery."
                    font.pixelSize: Appearance.fs(12)
                    color: Appearance.ink2
                }
            }
            BigGraph {
                visible: !gp.g.asleep
                width: parent.width
                height: 220
                caption: gp.g.busy >= 0 ? "Utilization" : "Utilization (not reported by this driver)"
                series: "gpu/" + gp.g.index + "/busy"
            }
            BigGraph {
                visible: !gp.g.asleep && gp.g.vramTotal > 0
                width: parent.width
                height: 120
                caption: "Dedicated memory"
                series: "gpu/" + gp.g.index + "/vram"
                format: v => Tasks.bytes(gp.g.vramTotal)
            }
            StatGrid {
                width: parent.width
                stats: [
                    { label: "Utilization", value: gp.g.busy >= 0 ? Tasks.pct(gp.g.busy) : "—" },
                    { label: "Dedicated memory", value: gp.g.vramTotal > 0 ? Tasks.bytes(gp.g.vramUsed) + " / " + Tasks.bytes(gp.g.vramTotal, 0) : "—", wide: true },
                    { label: "Shared memory", value: gp.g.gttTotal > 0 ? Tasks.bytes(gp.g.gttUsed) + " / " + Tasks.bytes(gp.g.gttTotal, 0) : "—", wide: true },
                    { label: "Temperature", value: Tasks.celsius(gp.g.temp) },
                    { label: "Power", value: gp.g.watts !== undefined ? Tasks.watts(gp.g.watts) : "—" },
                    { label: "Clock", value: gp.g.mhz ? Tasks.mhz(gp.g.mhz) : "—" }
                ]
                facts: [
                    { label: "Driver", value: gp.g.driver || "" },
                    { label: "Location", value: gp.g.slot || "" },
                    { label: "State", value: gp.g.asleep ? "Asleep" : "Active" },
                    { label: "Type", value: gp.g.integrated ? "Integrated" : "Discrete" }
                ]
            }
            // What is using it.
            Column {
                visible: !gp.g.asleep
                width: parent.width
                spacing: 2
                readonly property var users: Monitor.sampledAt > 0 ? Monitor.processes.top("gpu", 6).filter(p => p.value > 0.1) : []
                StyledText { text: "Using the GPU now"; font.pixelSize: Appearance.fs(12); font.weight: Font.DemiBold; color: Appearance.ink2; bottomPadding: 4 }
                StyledText { visible: parent.users.length === 0; text: "Nothing of yours is drawing with it."; font.pixelSize: Appearance.fs(12); color: Appearance.ink3 }
                Repeater {
                    model: parent.users
                    KeyValue { required property var modelData; label: modelData.name + " (" + modelData.pid + ")"; value: Tasks.pct(modelData.value); labelWidth: 260 }
                }
            }
        }
    }

    // ── Battery ──
    Component {
        id: batteryPage
        PerfPage {
            id: bp
            readonly property var b: Monitor.battery
            title: "Battery"
            model: [bp.b.vendor, bp.b.model].filter(s => s).join(" ")
            BigGraph {
                width: parent.width
                height: 200
                caption: bp.b.status === "Charging" ? "Charging rate" : "Power drawn"
                series: "bat/watts"
                maxValue: 0
                minScale: 5
                format: v => Tasks.watts(v)
            }
            BigGraph {
                width: parent.width
                height: 120
                caption: "Charge"
                series: "bat/percent"
            }
            StatGrid {
                width: parent.width
                stats: [
                    { label: "Charge", value: (bp.b.percent || 0) + "%" },
                    { label: "State", value: bp.b.status || "" },
                    { label: bp.b.status === "Charging" ? "Charging at" : "Drawing", value: Tasks.watts(bp.b.watts) },
                    { label: bp.b.status === "Charging" ? "Until full" : "Left", value: bp.b.secondsLeft > 0 ? Tasks.friendlyDuration(bp.b.secondsLeft) : "—" }
                ]
                facts: [
                    { label: "Energy now", value: bp.b.energyNow > 0 ? bp.b.energyNow.toFixed(1) + " Wh" : "" },
                    { label: "Full charge", value: bp.b.energyFull > 0 ? bp.b.energyFull.toFixed(1) + " Wh" : "" },
                    { label: "Design capacity", value: bp.b.energyDesign > 0 ? bp.b.energyDesign.toFixed(1) + " Wh" : "" },
                    { label: "Health", value: bp.b.health > 0 ? Tasks.pct(bp.b.health, 0) + " of new" : "" },
                    { label: "Charge cycles", value: bp.b.cycles >= 0 ? String(bp.b.cycles) : "" },
                    { label: "Charge limit", value: bp.b.chargeLimit ? bp.b.chargeLimit + "%" : "" },
                    { label: "Chemistry", value: bp.b.technology || "" },
                    { label: "On mains power", value: bp.b.ac ? "Yes" : "No" }
                ]
            }
        }
    }
}
