import QtQuick
import Hyprshell
import Hyprshell.Backend

// The hardware and what drives it: PCI devices, USB devices, and the kernel
// modules loaded for them.
Item {
    id: view
    property var frame: null
    property string show: "pci"
    property var pci: Tools.pciDevices()
    property var usb: Tools.usbDevices()
    property var modules: Tools.kernelModules()
    property var info: ({})

    function matches(text) { return Tasks.search === "" || text.toLowerCase().indexOf(Tasks.search.toLowerCase()) >= 0; }
    function showModule(name) {
        if (!name) return;
        view.info = Tools.moduleInfo(name);
        view.info.name = name;
        modInfo.title = "Kernel module " + name;
        modInfo.open = true;
    }

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Drivers"
        subtitle: view.pci.length + " PCI devices · " + view.usb.length + " USB devices · " + view.modules.length + " modules loaded"
        Seg {
            anchors.verticalCenter: parent.verticalCenter
            options: [{ label: "Devices", value: "pci" }, { label: "USB", value: "usb" }, { label: "Kernel modules", value: "modules" }]
            value: view.show
            onPicked: v => view.show = v
        }
    }
    Table {
        visible: view.show === "pci"
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "slot"
        sortKey: "class"
        rows: view.pci.filter(d => view.matches(d.name + " " + d["class"] + " " + d.driver))
        columns: [
            { k: "name", t: "Device", glyph: d => /Display/.test(d["class"]) ? "monitor" : /Network|Ethernet/.test(d["class"]) ? "wifi"
                                                : /Audio|Multimedia/.test(d["class"]) ? "volume" : /NVMe|SATA|Storage/.test(d["class"]) ? "disk"
                                                : /USB/.test(d["class"]) ? "plus" : "cpu" },
            { k: "class", t: "Kind", w: 170 },
            { k: "driver", t: "Driver", w: 130, fmt: d => d.driver || "None", dim: d => !d.driver },
            { k: "version", t: "Version", w: 110 },
            { k: "power", t: "Power", w: 100, fmt: d => d.power === "suspended" ? "Asleep" : d.power === "active" ? "Awake" : d.power },
            { k: "slot", t: "Location", w: 120 }
        ]
        onActivated: d => view.showModule(d.module || d.driver)
        onContextMenu: (d, x, y) => view.frame.menu.openAt(x, y, [
            { n: "About its driver", icon: "info", active: !!d.driver, run: () => view.showModule(d.module || d.driver) },
            { n: "Search online", icon: "globe", run: () => Qt.openUrlExternally("https://duckduckgo.com/?q=" + encodeURIComponent(d.name + " linux driver")) }])
    }
    Table {
        visible: view.show === "usb"
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "bus"
        sortKey: "name"
        rows: view.usb.filter(d => !d.hub && view.matches((d.name || "") + " " + (d.maker || "") + " " + d.drivers.join(" ")))
        columns: [
            { k: "name", t: "Device", fmt: d => d.name || (d.vendor + ":" + d.product), glyph: d => "plus" },
            { k: "maker", t: "Maker", w: 200 },
            { k: "drivers", t: "Drivers", w: 180, fmt: d => d.drivers.join(", ") || "None", dim: d => d.drivers.length === 0 },
            { k: "speed", t: "Speed", w: 110, num: true, fmt: d => d.speed >= 1000 ? (d.speed / 1000) + " Gb/s" : d.speed + " Mb/s" },
            { k: "bus", t: "Port", w: 90 }
        ]
        onActivated: d => view.showModule(d.drivers[0])
    }
    Table {
        visible: view.show === "modules"
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "name"
        sortKey: "name"
        rows: view.modules.filter(m => view.matches(m.name + " " + m.usedBy.join(" ")))
        columns: [
            { k: "name", t: "Module", w: 220, glyph: m => "cpu" },
            { k: "size", t: "Size", w: 90, num: true, fmt: m => Tasks.bytes(m.size) },
            { k: "uses", t: "In use", w: 70, num: true },
            { k: "usedBy", t: "Used by", fmt: m => m.usedBy.join(", ") },
            { k: "version", t: "Version", w: 120 }
        ]
        onActivated: m => view.showModule(m.name)
        onContextMenu: (m, x, y) => view.frame.menu.openAt(x, y, [{ n: "About this module", icon: "info", run: () => view.showModule(m.name) }])
    }
    Modal {
        id: modInfo
        anchors.fill: parent
        boxWidth: 560
        Column {
            width: parent.width
            spacing: 2
            Repeater {
                model: [["Description", view.info.description], ["Version", view.info.version], ["Author", view.info.author],
                        ["License", view.info.license], ["File", view.info.filename], ["Depends on", view.info.depends],
                        ["Signed by", view.info.signer]].filter(r => r[1])
                KeyValue { required property var modelData; labelWidth: 110; label: modelData[0]; value: modelData[1] }
            }
            StyledText { visible: (view.info.parameters || []).length > 0; text: "Parameters"; topPadding: 10; font.pixelSize: Appearance.fs(12); font.weight: Font.DemiBold }
            Repeater {
                model: (view.info.parameters || []).slice(0, 14)
                StyledText { required property var modelData; width: parent.width; wrapMode: Text.WordWrap; text: modelData; font.pixelSize: Appearance.fs(11); color: Appearance.ink2 }
            }
            Item { width: 1; height: 12 }
            DialogButton { text: "Close"; onTriggered: modInfo.open = false }
        }
    }
}
