import QtQuick
import Hyprshell
import Hyprshell.Backend

// How the machine trades speed for power and heat: the power profile, how
// the processor scales its clocks, what each core is running at, every
// temperature and fan, and what the battery is drawing.
Item {
    id: view
    property var frame: null

    // What can change the profile, found once.
    property bool hasPpd: false
    property bool hasAsus: false
    property var ppdProfiles: []
    property string ppdActive: ""
    property var asusProfiles: []
    property string asusActive: ""
    property var eppChoices: []
    property bool boostKnown: false
    property bool boostOn: false

    readonly property string cpufreq: "/sys/devices/system/cpu/cpu0/cpufreq/"

    function probe() {
        tools.command = ["sh", "-c", "command -v powerprofilesctl >/dev/null && echo ppd; command -v asusctl >/dev/null && echo asus; true"];
        tools.running = true;
        view.eppChoices = Tools.readFile(view.cpufreq + "energy_performance_available_preferences").trim().split(" ").filter(s => s);
        const b = Tools.readFile("/sys/devices/system/cpu/cpufreq/boost").trim();
        view.boostKnown = b !== "";
        view.boostOn = b === "1";
    }
    Component.onCompleted: probe()
    Proc {
        id: tools
        onFinished: (code, out) => {
            view.hasPpd = out.indexOf("ppd") >= 0;
            view.hasAsus = out.indexOf("asus") >= 0;
            if (view.hasPpd) { ppd.running = true; }
            if (view.hasAsus) { asus.running = true; }
        }
    }
    Proc {
        id: ppd
        command: ["powerprofilesctl", "list"]
        onFinished: (code, out) => {
            const list = [];
            let active = "";
            for (const line of out.split("\n")) {
                const m = /^(\*?)\s*([\w-]+):\s*$/.exec(line);
                if (m) { list.push(m[2]); if (m[1] === "*") active = m[2]; }
            }
            view.ppdProfiles = list;
            view.ppdActive = active;
        }
    }
    Proc {
        id: asus
        command: ["sh", "-c", "asusctl profile -l 2>/dev/null; echo ---; asusctl profile -p 2>/dev/null"]
        onFinished: (code, out) => {
            const parts = out.split("---");
            view.asusProfiles = (parts[0] || "").split("\n").map(s => s.trim()).filter(s => /^[A-Z][a-z]+$/.test(s));
            const m = /profile is (\w+)/i.exec(parts[1] || "");
            view.asusActive = m ? m[1] : "";
        }
    }
    Proc {
        id: setter
        property string done: ""
        onFinished: (code, out, err) => {
            if (view.frame) view.frame.toast.show(code === 0 ? setter.done : (err.trim() || "That didn't work."), code !== 0);
            view.probe();
            Monitor.refresh();
        }
    }
    function run(argv, done) { setter.done = done; setter.command = argv; setter.running = true; }
    // Writes to /sys need root: through pkexec, which asks via polkit.
    function rootWrite(glob, value, done) {
        run(["pkexec", "sh", "-c", 'for f in ' + glob + '; do printf %s "$1" > "$f"; done', "sh", value], done);
    }

    readonly property var b: Monitor.battery
    readonly property real maxMHz: Math.max(Monitor.info.maxMHz || 0, ...Monitor.cores.map(c => c.mhz || 0), 1)

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
            spacing: 14
            ViewHeader {
                width: parent.width
                title: "Power & frequency"
                subtitle: (Monitor.battery.present ? (Monitor.battery.ac ? "On mains power" : "On battery") : "Mains powered")
                          + (Monitor.system.platformProfile ? " · profile " + Monitor.system.platformProfile : "")
            }

            // ── profile ──
            Card {
                width: parent.width
                height: profCol.implicitHeight + 28
                Column {
                    id: profCol
                    x: 16; y: 14
                    width: parent.width - 32
                    spacing: 10
                    StyledText { text: "Power profile"; font.pixelSize: Appearance.fs(13.5); font.weight: Font.DemiBold }
                    StyledText {
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: "How hard the machine is allowed to run. Performance keeps clocks and fans up; power saving holds both down for battery and quiet."
                        font.pixelSize: Appearance.fs(12)
                        color: Appearance.ink2
                    }
                    Row {
                        visible: view.hasPpd && view.ppdProfiles.length > 0
                        spacing: 12
                        StyledText { anchors.verticalCenter: parent.verticalCenter; text: "System"; width: 70; font.pixelSize: Appearance.fs(12); color: Appearance.ink3 }
                        Seg {
                            options: view.ppdProfiles.map(p => ({ label: p.charAt(0).toUpperCase() + p.slice(1).replace("-", " "), value: p }))
                            value: view.ppdActive
                            onPicked: v => view.run(["powerprofilesctl", "set", v], "Power profile: " + v + ".")
                        }
                    }
                    Row {
                        visible: view.hasAsus && view.asusProfiles.length > 0
                        spacing: 12
                        StyledText { anchors.verticalCenter: parent.verticalCenter; text: "ASUS"; width: 70; font.pixelSize: Appearance.fs(12); color: Appearance.ink3 }
                        Seg {
                            options: view.asusProfiles.map(p => ({ label: p, value: p }))
                            value: view.asusActive
                            onPicked: v => view.run(["asusctl", "profile", "-P", v], "ASUS profile: " + v + ".")
                        }
                    }
                    Row {
                        visible: !view.hasPpd && !view.hasAsus && (Monitor.system.platformProfiles || []).length > 0
                        spacing: 12
                        StyledText { anchors.verticalCenter: parent.verticalCenter; text: "Firmware"; width: 70; font.pixelSize: Appearance.fs(12); color: Appearance.ink3 }
                        Seg {
                            options: (Monitor.system.platformProfiles || []).map(p => ({ label: p, value: p }))
                            value: Monitor.system.platformProfile
                            onPicked: v => view.rootWrite("/sys/firmware/acpi/platform_profile", v, "Profile: " + v + ".")
                        }
                    }
                    StyledText {
                        visible: !view.hasPpd && !view.hasAsus && (Monitor.system.platformProfiles || []).length === 0
                        text: "Nothing here offers power profiles. Installing power-profiles-daemon adds them."
                        font.pixelSize: Appearance.fs(12)
                        color: Appearance.ink3
                    }
                }
            }

            // ── processor ──
            Card {
                width: parent.width
                height: cpuCol.implicitHeight + 28
                Column {
                    id: cpuCol
                    x: 16; y: 14
                    width: parent.width - 32
                    spacing: 12
                    Item {
                        width: parent.width
                        height: 22
                        StyledText { text: "Processor clocks"; font.pixelSize: Appearance.fs(13.5); font.weight: Font.DemiBold }
                        StyledText {
                            anchors.right: parent.right
                            text: "Average " + Tasks.mhz(Monitor.cpu.mhz) + (Monitor.info.maxMHz ? " of " + Tasks.mhz(Monitor.info.maxMHz) : "")
                            font.pixelSize: Appearance.fs(12)
                            color: Appearance.ink2
                        }
                    }
                    Row {
                        spacing: 24
                        Stat { label: "Scaling driver"; value: Monitor.info.scalingDriver || "—"; big: false }
                        Stat { label: "Governor"; value: Monitor.system.governor || "—"; big: false }
                        Stat { label: "Energy preference"; value: Monitor.system.epp || "—"; big: false }
                        Row {
                            visible: view.boostKnown
                            spacing: 8
                            Stat { label: "Boost"; value: view.boostOn ? "On" : "Off"; big: false }
                            Switch {
                                anchors.verticalCenter: parent.verticalCenter
                                checked: view.boostOn
                                onToggled: on => view.rootWrite("/sys/devices/system/cpu/cpufreq/boost", on ? "1" : "0", on ? "Boost on." : "Boost off.")
                            }
                        }
                    }
                    Row {
                        visible: view.eppChoices.length > 0
                        spacing: 12
                        StyledText { anchors.verticalCenter: parent.verticalCenter; text: "Prefer"; font.pixelSize: Appearance.fs(12); color: Appearance.ink3 }
                        Seg {
                            options: view.eppChoices.map(p => ({ label: p.replace(/_/g, " "), value: p }))
                            value: Monitor.system.epp
                            onPicked: v => view.rootWrite("/sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference", v, "Energy preference: " + v + ".")
                        }
                    }
                    // Each core's clock right now.
                    Grid {
                        id: coreGrid
                        width: parent.width
                        columns: Math.max(1, Math.floor(width / 150))
                        columnSpacing: 14
                        rowSpacing: 8
                        Repeater {
                            model: Monitor.cores
                            Column {
                                required property var modelData
                                required property int index
                                width: (coreGrid.width - coreGrid.columnSpacing * (coreGrid.columns - 1)) / coreGrid.columns
                                spacing: 3
                                Item {
                                    width: parent.width
                                    height: 15
                                    StyledText { text: "CPU " + index; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                                    StyledText { anchors.right: parent.right; text: modelData.mhz ? Tasks.mhz(modelData.mhz) : Tasks.pct(modelData.percent); font.pixelSize: Appearance.fs(11) }
                                }
                                Meter { width: parent.width; value: modelData.mhz ? modelData.mhz / view.maxMHz : modelData.percent / 100 }
                            }
                        }
                    }
                }
            }

            // ── battery ──
            Card {
                visible: !!view.b.present
                width: parent.width
                height: batCol.implicitHeight + 28
                Column {
                    id: batCol
                    x: 16; y: 14
                    width: parent.width - 32
                    spacing: 12
                    StyledText { text: "Battery"; font.pixelSize: Appearance.fs(13.5); font.weight: Font.DemiBold }
                    Row {
                        spacing: 30
                        Stat { label: view.b.status === "Charging" ? "Charging at" : "Drawing"; value: Tasks.watts(view.b.watts) }
                        Stat { label: "Charge"; value: (view.b.percent || 0) + "%" }
                        Stat { label: view.b.status === "Charging" ? "Until full" : "Left"; value: view.b.secondsLeft > 0 ? Tasks.friendlyDuration(view.b.secondsLeft) : "—" }
                        Stat { label: "Health"; value: view.b.health > 0 ? Tasks.pct(view.b.health, 0) : "—" }
                    }
                    BigGraph {
                        width: parent.width
                        height: 140
                        caption: "Power"
                        series: "bat/watts"
                        maxValue: 0
                        minScale: 5
                        format: v => Tasks.watts(v)
                    }
                    Row {
                        visible: !!view.b.chargeLimitPath || view.hasAsus
                        spacing: 12
                        StyledText { anchors.verticalCenter: parent.verticalCenter; text: "Stop charging at"; font.pixelSize: Appearance.fs(12); color: Appearance.ink3 }
                        Seg {
                            options: [60, 80, 90, 100].map(v => ({ label: v + "%", value: v }))
                            value: view.b.chargeLimit || 100
                            onPicked: v => view.hasAsus ? view.run(["asusctl", "-c", String(v)], "Charging stops at " + v + "%.")
                                                        : view.rootWrite(view.b.chargeLimitPath, String(v), "Charging stops at " + v + "%.")
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Kept below full, a battery that lives on the charger lasts years longer."
                            font.pixelSize: Appearance.fs(11.5)
                            color: Appearance.ink3
                        }
                    }
                }
            }

            // ── heat ──
            Card {
                width: parent.width
                height: heatCol.implicitHeight + 28
                Column {
                    id: heatCol
                    x: 16; y: 14
                    width: parent.width - 32
                    spacing: 10
                    StyledText { text: "Temperatures and fans"; font.pixelSize: Appearance.fs(13.5); font.weight: Font.DemiBold }
                    StyledText {
                        visible: Monitor.sensors.length === 0 && Monitor.fans.length === 0
                        text: "The kernel reports no temperature sensors here."
                        font.pixelSize: Appearance.fs(12)
                        color: Appearance.ink3
                    }
                    Flow {
                        width: parent.width
                        spacing: 10
                        Repeater {
                            model: Monitor.sensors
                            Rectangle {
                                required property var modelData
                                width: Math.max(200, (heatCol.width - 20) / 3)
                                height: 74
                                radius: Appearance.rSm
                                color: Appearance.hover
                                border.width: 1
                                border.color: modelData.critical && modelData.celsius >= modelData.critical - 5 ? Appearance.accent : Appearance.rule
                                Column {
                                    x: 10; y: 8
                                    StyledText { text: modelData.chip + " · " + modelData.label; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                                    StyledText { text: Tasks.celsius(modelData.celsius); font.pixelSize: Appearance.fs(17); font.weight: Font.DemiBold }
                                }
                                Graph {
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    anchors.margins: 6
                                    width: parent.width * 0.5
                                    height: parent.height - 12
                                    source: Monitor
                                    series: "temp/" + modelData.chip + "/" + modelData.label
                                    maxValue: 0
                                    minScale: 10
                                    points: Tasks.points
                                    grid: false
                                    animate: Tasks.settings.smooth
                                    lineWidth: 1.2
                                    color: Appearance.accent
                                }
                            }
                        }
                        Repeater {
                            model: Monitor.fans
                            Rectangle {
                                required property var modelData
                                width: Math.max(200, (heatCol.width - 20) / 3)
                                height: 74
                                radius: Appearance.rSm
                                color: Appearance.hover
                                border.width: 1
                                border.color: Appearance.rule
                                Column {
                                    x: 10; y: 8
                                    StyledText { text: modelData.label; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                                    StyledText { text: modelData.rpm + " rpm"; font.pixelSize: Appearance.fs(17); font.weight: Font.DemiBold }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
