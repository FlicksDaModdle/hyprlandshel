import QtQuick
import Hyprshell
import Hyprshell.Backend
import "Diagnose.js" as Diagnose

// The home page: what, if anything, is slowing the machine down, every
// device at a glance, and what is busiest.
Item {
    id: view
    property var frame: null

    readonly property var findings: Diagnose.findings(Monitor, Monitor.processes)
    readonly property real gap: 12
    readonly property int cols: Math.max(1, Math.min(4, Math.floor((flick.width - 40 + gap) / (250 + gap))))
    readonly property real tileW: (flick.width - 40 - gap * (cols - 1)) / cols

    SmoothScroll { target: flick; anchors.fill: flick; z: 5 }
    ScrollBar { target: flick; anchors.top: flick.top; anchors.bottom: flick.bottom; anchors.right: parent.right; z: 6 }

    Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: col.implicitHeight + 30
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: col
            x: 20
            y: 6
            width: flick.width - 40
            spacing: 14

            ViewHeader {
                width: parent.width
                title: "Summary"
                subtitle: (Monitor.info.hostname || "") + " · up " + Tasks.friendlyDuration(Monitor.system.uptime)
                          + " · " + Tasks.count(Monitor.system.processes) + " processes"
            }

            // ── what is slowing things down ──
            Card {
                width: parent.width
                height: diag.implicitHeight + 28
                border.color: view.findings.some(f => f.level >= 2) ? Appearance.accent : Appearance.rule
                Column {
                    id: diag
                    x: 16; y: 14
                    width: parent.width - 32
                    spacing: 10
                    Row {
                        spacing: 9
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: view.findings.some(f => f.level >= 2) ? "info" : "check"
                            size: 18
                            inkColor: view.findings.some(f => f.level >= 2) ? Appearance.accent : Appearance.ink2
                            accentColor: Appearance.accent
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: view.findings.some(f => f.level >= 2) ? "What's slowing things down"
                                : view.findings.length > 0 ? "Running smoothly, with a few things worth knowing"
                                : "Nothing is holding things up"
                            font.pixelSize: Appearance.fs(14)
                            font.weight: Font.DemiBold
                        }
                    }
                    StyledText {
                        visible: view.findings.length === 0
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "Nothing is waiting on the processor, memory or the disk, and there is room to spare: "
                              + Tasks.pct(100 - (Monitor.cpu.percent || 0)) + " of the processor and "
                              + Tasks.bytes(Monitor.memory.available) + " of memory are free."
                        font.pixelSize: Appearance.fs(12)
                        color: Appearance.ink2
                    }
                    Repeater {
                        model: view.findings
                        Item {
                            required property var modelData
                            width: diag.width
                            height: Math.max(40, fText.implicitHeight + 8)
                            Rectangle {
                                width: 3
                                height: parent.height - 6
                                y: 3
                                radius: 2
                                color: modelData.level >= 2 ? Appearance.accent : Appearance.ink3
                            }
                            MonoIcon {
                                x: 14
                                y: 6
                                name: modelData.icon
                                size: 17
                                inkColor: modelData.level >= 2 ? Appearance.accent : Appearance.ink2
                                accentColor: Appearance.accent
                            }
                            Column {
                                id: fText
                                x: 42
                                y: 3
                                width: parent.width - 42 - showBtn.width - 10
                                spacing: 2
                                StyledText { width: parent.width; wrapMode: Text.WordWrap; text: modelData.title; font.pixelSize: Appearance.fs(12.5); font.weight: Font.DemiBold }
                                StyledText { width: parent.width; wrapMode: Text.WordWrap; text: modelData.detail; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink2; visible: text !== "" }
                            }
                            ToolButton {
                                id: showBtn
                                anchors.right: parent.right
                                y: 2
                                text: "Show"
                                onClicked: Tasks.show(modelData.view, modelData.key)
                            }
                        }
                    }
                }
            }

            // ── devices ──
            Flow {
                width: parent.width
                spacing: view.gap
                DeviceTile {
                    width: view.tileW
                    icon: "cpu"
                    title: "Processor"
                    device: "cpu"
                    value: Tasks.pct(Monitor.cpu.percent || 0)
                    detail: Tasks.mhz(Monitor.cpu.mhz) + (Monitor.cpu.temp !== undefined ? " · " + Tasks.celsius(Monitor.cpu.temp) : "")
                    detail2: (Monitor.info.cores || "?") + " cores, " + (Monitor.info.threads || "?") + " threads"
                    series: "cpu"
                    level: (Monitor.pressure.cpuSome || 0) >= 25 ? 2 : 0
                }
                DeviceTile {
                    width: view.tileW
                    icon: "database"
                    title: "Memory"
                    device: "mem"
                    value: Tasks.bytes(Monitor.memory.used) + " / " + Tasks.bytes(Monitor.memory.total, 0)
                    detail: Tasks.pct(Monitor.memory.percent || 0) + " in use · " + Tasks.bytes(Monitor.memory.available) + " available"
                    detail2: Monitor.memory.swapTotal > 0 ? "Swap " + Tasks.bytes(Monitor.memory.swapUsed) + " of " + Tasks.bytes(Monitor.memory.swapTotal) : ""
                    series: "mem"
                    level: (Monitor.pressure.memSome || 0) >= 5 ? 2 : 0
                }
                Repeater {
                    model: Monitor.gpus
                    DeviceTile {
                        required property var modelData
                        width: view.tileW
                        icon: "monitor"
                        title: modelData.name
                        device: "gpu/" + modelData.index
                        value: modelData.asleep ? "Asleep" : modelData.busy >= 0 ? Tasks.pct(modelData.busy) : "—"
                        detail: modelData.asleep ? "Powered down until something uses it"
                              : (modelData.vramTotal > 0 ? Tasks.bytes(modelData.vramUsed) + " of " + Tasks.bytes(modelData.vramTotal, 0) + " memory" : modelData.driver)
                        detail2: modelData.asleep ? "" : [modelData.temp !== undefined ? Tasks.celsius(modelData.temp) : "", modelData.watts !== undefined ? Tasks.watts(modelData.watts) : ""].filter(s => s).join(" · ")
                        series: modelData.asleep ? "" : "gpu/" + modelData.index + "/busy"
                    }
                }
                Repeater {
                    model: Monitor.disks
                    DeviceTile {
                        required property var modelData
                        width: view.tileW
                        icon: "disk"
                        title: "Disk " + modelData.index + " · " + modelData.model
                        device: "disk/" + modelData.name
                        value: Tasks.pct(modelData.active)
                        detail: "Read " + Tasks.rate(modelData.readBps) + " · Write " + Tasks.rate(modelData.writeBps)
                        detail2: modelData.type + " · " + Tasks.bytes(modelData.size, 0)
                        series: "disk/" + modelData.name + "/active"
                        level: modelData.active >= 90 ? 2 : 0
                    }
                }
                Repeater {
                    model: Monitor.networks.filter(n => n.up)
                    DeviceTile {
                        required property var modelData
                        width: view.tileW
                        icon: modelData.type === "Wi-Fi" ? "wifi" : "globe"
                        title: modelData.type + " · " + modelData.name
                        device: "net/" + modelData.name
                        value: "↓ " + Tasks.bits(modelData.rxBps)
                        detail: "↑ " + Tasks.bits(modelData.txBps)
                        detail2: (modelData.ipv4 || []).join(", ")
                        series: "net/" + modelData.name + "/rx"
                        series2: "net/" + modelData.name + "/tx"
                        maxValue: 0
                        minScale: 1024
                    }
                }
                DeviceTile {
                    visible: !!Monitor.battery.present
                    width: view.tileW
                    icon: Monitor.battery.ac ? "batteryCharging" : "battery"
                    title: "Battery"
                    device: "battery"
                    value: (Monitor.battery.percent || 0) + "%"
                    detail: (Monitor.battery.status || "") + (Monitor.battery.watts > 0.1 ? " · " + Tasks.watts(Monitor.battery.watts) : "")
                    detail2: Monitor.battery.secondsLeft > 0 ? Tasks.friendlyDuration(Monitor.battery.secondsLeft) + (Monitor.battery.status === "Charging" ? " to full" : " left") : ""
                    series: "bat/watts"
                    maxValue: 0
                    minScale: 5
                }
                DeviceTile {
                    visible: Monitor.sensors.length > 0
                    width: view.tileW
                    icon: "zap"
                    title: "Thermals"
                    device: "temps"
                    value: Monitor.cpu.temp !== undefined ? Tasks.celsius(Monitor.cpu.temp) : Tasks.celsius((Monitor.sensors[0] || {}).celsius)
                    detail: Monitor.cpu.temp !== undefined ? "Processor" : ((Monitor.sensors[0] || {}).chip || "")
                    detail2: Monitor.fans.length > 0 ? Monitor.fans.map(f => f.rpm + " rpm").join(" · ") : ""
                    series: Monitor.cpu.temp !== undefined ? "cpu/temp" : ""
                    maxValue: 105
                    level: (Monitor.cpu.temp || 0) >= 95 ? 2 : 0
                }
            }

            // ── what is busiest ──
            StyledText {
                text: "Busiest right now"
                font.pixelSize: Appearance.fs(14)
                font.weight: Font.DemiBold
                topPadding: 6
            }
            Flow {
                width: parent.width
                spacing: view.gap
                Repeater {
                    model: [
                        { key: "cpu", title: "Processor", fmt: v => Tasks.pct(v) },
                        { key: "mem", title: "Memory", fmt: v => Tasks.bytes(v) },
                        { key: "disk", title: "Disk", fmt: v => Tasks.rate(v) },
                        { key: "gpu", title: "GPU", fmt: v => Tasks.pct(v) }
                    ]
                    Card {
                        id: topCard
                        required property var modelData
                        readonly property var rows: Monitor.sampledAt > 0 ? Monitor.processes.top(modelData.key, 5) : []
                        width: view.cols >= 4 ? view.tileW : (parent.width - view.gap) / 2
                        height: topCol.implicitHeight + 24
                        Column {
                            id: topCol
                            x: 12; y: 12
                            width: parent.width - 24
                            spacing: 2
                            StyledText {
                                text: topCard.modelData.title
                                font.pixelSize: Appearance.fs(12)
                                font.weight: Font.DemiBold
                                color: Appearance.ink2
                                bottomPadding: 4
                            }
                            Repeater {
                                model: topCard.rows
                                Rectangle {
                                    required property var modelData
                                    width: topCol.width
                                    height: 28
                                    radius: Appearance.rSm
                                    color: rowArea.containsMouse ? Appearance.hover : "transparent"
                                    MonoIcon {
                                        x: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: Tasks.glyph(modelData.icon)
                                        size: 15
                                        inkColor: Appearance.ink2
                                        accentColor: Appearance.accent
                                    }
                                    StyledText {
                                        x: 30
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: parent.width - 30 - valText.width - 12
                                        elide: Text.ElideRight
                                        text: modelData.name
                                        font.pixelSize: Appearance.fs(12)
                                    }
                                    StyledText {
                                        id: valText
                                        anchors.right: parent.right
                                        anchors.rightMargin: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: topCard.modelData.fmt(modelData.value)
                                        font.pixelSize: Appearance.fs(12)
                                        color: Appearance.ink2
                                    }
                                    MouseArea {
                                        id: rowArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Tasks.show("processes", "p:" + modelData.pid)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
