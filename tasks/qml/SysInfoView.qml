import QtQuick
import Hyprshell
import Hyprshell.Backend

// The machine, as the old System Information panel set it out: what it is,
// what is in it, what it runs.
Item {
    id: view
    property var frame: null
    readonly property var i: Monitor.info

    readonly property var sections: [
        { title: "This computer", icon: "monitor", rows: [
            ["Manufacturer", view.i.vendor], ["Model", [view.i.product, view.i.productVersion].filter(s => s && s !== "None" && s !== "To be filled by O.E.M.").join(" ")],
            ["Board", [view.i.boardVendor, view.i.board].filter(s => s).join(" ")],
            ["Firmware", [view.i.biosVendor, view.i.bios, view.i.biosDate ? "(" + view.i.biosDate + ")" : ""].filter(s => s).join(" ")],
            ["Boot mode", view.i.firmware], ["Host name", view.i.hostname] ] },
        { title: "Operating system", icon: "settings", rows: [
            ["System", view.i.os], ["Kernel", view.i.kernel + " (" + view.i.arch + ")"],
            ["Desktop", (view.i.desktop || "") + (view.i.session ? " on " + view.i.session : "")],
            ["Up since", Tasks.stamp(Date.now() / 1000 - (Monitor.system.uptime || 0))], ["Qt", view.i.qt] ] },
        { title: "Processor", icon: "cpu", rows: [
            ["Model", view.i.cpuModel], ["Cores", (view.i.cores || "?") + " cores, " + (view.i.threads || "?") + " threads, " + (view.i.sockets || 1) + " socket"],
            ["Speed", [view.i.baseMHz ? "base " + Tasks.mhz(view.i.baseMHz) : "", view.i.maxMHz ? "up to " + Tasks.mhz(view.i.maxMHz) : ""].filter(s => s).join(", ")],
            ["Cache", view.i.caches ? ["L1 " + Tasks.bytes((view.i.caches.L1d || 0) + (view.i.caches.L1i || 0)), view.i.caches.L2 ? "L2 " + Tasks.bytes(view.i.caches.L2) : "", view.i.caches.L3 ? "L3 " + Tasks.bytes(view.i.caches.L3) : ""].filter(s => s).join(" · ") : ""],
            ["Virtualization", view.i.virtualization || "Not available"] ] },
        { title: "Memory", icon: "database", rows: [
            ["Installed", Tasks.bytes(view.i.memory)], ["Swap", Tasks.bytes(Monitor.memory.swapTotal)],
            ["zram", Monitor.memory.zramSize > 0 ? Tasks.bytes(Monitor.memory.zramSize) : "None"] ] },
        { title: "Graphics", icon: "monitor", rows: Monitor.gpus.map(g => [g.integrated ? "Integrated" : "Discrete",
            g.name + " · " + g.driver + (g.vramTotal > 0 ? " · " + Tasks.bytes(g.vramTotal, 0) : "")]) },
        { title: "Storage", icon: "disk", rows: Monitor.disks.map(d => ["Disk " + d.index, d.model + " · " + d.type + " · " + Tasks.bytes(d.size, 0)]) },
        { title: "Network", icon: "globe", rows: Monitor.networks.map(n => [n.type, n.name + " · " + (n.driver || "") + (n.mac ? " · " + n.mac : "")]) },
        { title: "Battery", icon: "battery", rows: Monitor.battery.present ? [
            ["Model", [Monitor.battery.vendor, Monitor.battery.model].filter(s => s).join(" ")],
            ["Capacity", Monitor.battery.energyFull > 0 ? Monitor.battery.energyFull.toFixed(1) + " Wh of " + Monitor.battery.energyDesign.toFixed(1) + " Wh designed" : ""],
            ["Cycles", Monitor.battery.cycles >= 0 ? String(Monitor.battery.cycles) : ""] ] : [] }
    ].filter(s => s.rows.length > 0)

    function asText() {
        return view.sections.map(s => s.title + "\n" + s.rows.map(r => "  " + r[0] + ": " + (r[1] || "")).join("\n")).join("\n\n");
    }

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
            x: 20; y: 6
            width: flick.width - 40
            spacing: 12
            ViewHeader {
                width: parent.width
                title: "System info"
                subtitle: (view.i.vendor || "") + " " + (view.i.product || "")
                ToolButton {
                    anchors.verticalCenter: parent.verticalCenter
                    icon: "file"
                    text: "Copy all"
                    onClicked: { Tools.runDetached(["sh", "-c", 'printf %s "$1" | wl-copy', "copy", view.asText()]); view.frame.toast.show("Copied.", false); }
                }
            }
            Flow {
                width: parent.width
                spacing: 12
                Repeater {
                    model: view.sections
                    Card {
                        required property var modelData
                        width: col.width >= 900 ? (col.width - 12) / 2 : col.width
                        height: secCol.implicitHeight + 26
                        Column {
                            id: secCol
                            x: 16; y: 13
                            width: parent.width - 32
                            spacing: 2
                            Row {
                                spacing: 8
                                bottomPadding: 4
                                MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: modelData.icon; size: 16; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                                StyledText { anchors.verticalCenter: parent.verticalCenter; text: modelData.title; font.pixelSize: Appearance.fs(13); font.weight: Font.DemiBold }
                            }
                            Repeater {
                                model: modelData.rows
                                KeyValue { required property var modelData; labelWidth: 120; label: modelData[0]; value: modelData[1] || "" }
                            }
                        }
                    }
                }
            }
        }
    }
}
