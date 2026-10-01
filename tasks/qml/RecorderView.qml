import QtQuick
import Hyprshell
import Hyprshell.Backend

// The flight recorder: turned on here, it records in the background all the
// time; afterwards a day can be replayed, the pointer scrubbing through it,
// with what was busiest at each moment.
Item {
    id: view
    property var frame: null
    property string day: Recorder.days.length > 0 ? Recorder.days[0].day : ""
    property string range: "day"
    property var rec: ({})
    property int at: -1                 // the point under the pointer

    function load() {
        if (view.day === "") { view.rec = ({}); return; }
        let from = 0;
        if (view.range !== "day") {
            const all = Recorder.loadDay(view.day, 0, 0, 2);
            const last = all.last || 0;
            from = last - (view.range === "hour" ? 3600000 : 4 * 3600000);
        }
        view.rec = Recorder.loadDay(view.day, from, 0, 600);
        view.at = -1;
    }
    onDayChanged: load()
    onRangeChanged: load()
    Component.onCompleted: load()
    Connections {
        target: Recorder
        function onActionDone(ok, message) { if (view.frame) view.frame.toast.show(message, !ok); }
    }
    Timer { interval: 15000; running: view.range !== "day"; repeat: true; onTriggered: view.load() }

    readonly property int n: (view.rec.t || []).length
    function timeAt(i) { return i >= 0 && i < view.n ? new Date(view.rec.t[i]).toLocaleTimeString(Qt.locale(), "HH:mm:ss") : ""; }
    function val(key, i) { const a = view.rec[key] || []; return i >= 0 && i < a.length ? a[i] : 0; }

    readonly property var lanes: [
        { title: "Processor", a: "cpu", max: 100, fmt: v => Tasks.pct(v) },
        { title: "Waiting (CPU · memory)", a: "psiCpu", b: "psiMem", max: 0, min: 5, fmt: v => Tasks.pct(v) },
        { title: "Memory", a: "mem", max: 100, fmt: v => Tasks.pct(v) },
        { title: "Disk (read · write)", a: "diskRead", b: "diskWrite", max: 0, min: 1048576, fmt: v => Tasks.rate(v) },
        { title: "Network (receive · send)", a: "netRx", b: "netTx", max: 0, min: 1024, fmt: v => Tasks.rate(v) },
        { title: "GPU", a: "gpu", max: 100, fmt: v => Tasks.pct(v) },
        { title: "Processor temperature", a: "temp", max: 0, min: 20, fmt: v => Tasks.celsius(v) },
        { title: "Power drawn", a: "watts", max: 0, min: 5, fmt: v => Tasks.watts(v) }
    ].filter(l => (view.rec[l.a] || []).some(v => v > 0) || l.a === "cpu" || l.a === "mem")

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "Flight recorder"
        subtitle: Recorder.running ? "Recording every 5 seconds, in the background" : Recorder.enabled ? "Turned on, but not running right now" : "Off"
        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            StyledText { anchors.verticalCenter: parent.verticalCenter; text: "Record"; font.pixelSize: Appearance.fs(12); color: Appearance.ink2 }
            Switch { anchors.verticalCenter: parent.verticalCenter; checked: Recorder.enabled; onToggled: on => Recorder.setEnabled(on) }
        }
        StyledText { anchors.verticalCenter: parent.verticalCenter; text: "Keep"; font.pixelSize: Appearance.fs(12); color: Appearance.ink2 }
        Seg {
            anchors.verticalCenter: parent.verticalCenter
            options: [{ label: "3 days", value: 3 }, { label: "7 days", value: 7 }, { label: "30 days", value: 30 }]
            value: Recorder.keepDays
            onPicked: v => Recorder.keepDays = v
        }
    }

    Card {
        visible: Recorder.days.length === 0
        anchors.top: head.bottom
        anchors.topMargin: 10
        x: 20
        width: parent.width - 40
        height: 96
        StyledText {
            anchors.fill: parent
            anchors.margins: 16
            wrapMode: Text.WordWrap
            verticalAlignment: Text.AlignVCenter
            text: "Nothing recorded yet. Turned on, the recorder runs in the background whether or not this window is open — a small process, at "
                  + "the lowest priority — and keeps the last few days. When the machine stalls, come back here afterwards and scrub to the moment: "
                  + "what the processor, memory, disks and GPU were doing, how hot it was, and what was busiest."
            font.pixelSize: Appearance.fs(12.5)
            color: Appearance.ink2
        }
    }

    // ── days ──
    ListView {
        id: days
        visible: Recorder.days.length > 0
        anchors.top: head.bottom
        anchors.topMargin: 8
        anchors.bottom: parent.bottom
        x: 12
        width: 150
        clip: true
        model: Recorder.days
        spacing: 2
        delegate: Rectangle {
            required property var modelData
            width: days.width - 8
            height: 44
            radius: Appearance.rSm
            color: view.day === modelData.day ? Appearance.sel : dArea.containsMouse ? Appearance.hover : "transparent"
            Column {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                StyledText { text: new Date(modelData.day + "T12:00:00").toLocaleDateString(Qt.locale(), "ddd d MMM"); font.pixelSize: Appearance.fs(12.5); font.weight: Font.Medium }
                StyledText { text: Tasks.bytes(modelData.size); font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
            }
            MouseArea { id: dArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: view.day = modelData.day }
        }
    }

    // ── the day ──
    Item {
        id: replay
        visible: Recorder.days.length > 0
        anchors.top: head.bottom
        anchors.topMargin: 8
        anchors.left: days.right
        anchors.leftMargin: 10
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 12

        Item {
            id: bar
            width: parent.width
            height: 34
            Seg {
                anchors.verticalCenter: parent.verticalCenter
                options: [{ label: "Whole day", value: "day" }, { label: "Last 4 hours", value: "4h" }, { label: "Last hour", value: "hour" }]
                value: view.range
                onPicked: v => view.range = v
            }
            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: view.n > 0 ? view.timeAt(0) + " – " + view.timeAt(view.n - 1) + " · " + view.rec.count + " samples" : "No samples in this range"
                font.pixelSize: Appearance.fs(11.5)
                color: Appearance.ink3
            }
        }

        // The lanes, one graph each, sharing the scrubber.
        Column {
            id: lanesCol
            anchors.top: bar.bottom
            anchors.topMargin: 6
            width: parent.width - side.width - 14
            spacing: 6
            readonly property real laneH: Math.max(46, (replay.height - bar.height - 12) / Math.max(1, view.lanes.length) - 6)
            Repeater {
                model: view.lanes
                Item {
                    required property var modelData
                    width: lanesCol.width
                    height: lanesCol.laneH
                    Rectangle { anchors.fill: g; color: "transparent"; border.width: 1; border.color: Appearance.edge; radius: 3 }
                    Graph {
                        id: g
                        anchors.fill: parent
                        anchors.topMargin: 16
                        series: "a"
                        series2: modelData.b ? "b" : ""
                        values: view.rec[modelData.a] || []
                        values2: modelData.b ? (view.rec[modelData.b] || []) : []
                        points: Math.max(2, view.n)
                        maxValue: modelData.max
                        minScale: modelData.min || 1
                        animate: false
                        grid: true
                        lineWidth: 1.2
                        color: Appearance.accent
                        color2: Appearance.ink2
                        gridColor: Appearance.rule
                    }
                    StyledText { text: modelData.title; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                    StyledText {
                        anchors.right: parent.right
                        text: view.at >= 0 ? modelData.fmt(view.val(modelData.a, view.at)) + (modelData.b ? " · " + modelData.fmt(view.val(modelData.b, view.at)) : "")
                                           : "max " + modelData.fmt(Math.max(0, ...(view.rec[modelData.a] || [0])))
                        font.pixelSize: Appearance.fs(11)
                        color: view.at >= 0 ? Appearance.ink : Appearance.ink3
                    }
                }
            }
        }
        // The scrubber line, across every lane.
        Rectangle {
            visible: view.at >= 0
            x: lanesCol.x + (view.n > 1 ? view.at / (view.n - 1) * lanesCol.width : 0)
            y: lanesCol.y
            width: 1
            height: lanesCol.height
            color: Appearance.accent
        }
        MouseArea {
            anchors.fill: lanesCol
            hoverEnabled: true
            onPositionChanged: mouse => view.at = view.n > 1 ? Math.max(0, Math.min(view.n - 1, Math.round(mouse.x / width * (view.n - 1)))) : -1
            onExited: view.at = -1
        }

        // What was busiest at that moment.
        Card {
            id: side
            anchors.right: parent.right
            anchors.top: bar.bottom
            anchors.topMargin: 6
            width: 230
            height: sideCol.implicitHeight + 24
            Column {
                id: sideCol
                x: 12; y: 12
                width: parent.width - 24
                spacing: 4
                StyledText { text: view.at >= 0 ? view.timeAt(view.at) : "Point at a moment"; font.pixelSize: Appearance.fs(13); font.weight: Font.DemiBold }
                StyledText { visible: view.at < 0; width: parent.width; wrapMode: Text.WordWrap; text: "Move along the graphs to see what was busiest then."; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3 }
                StyledText { visible: view.at >= 0; text: "Busiest processor"; topPadding: 6; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                Repeater {
                    model: view.at >= 0 ? ((view.rec.top || [])[view.at] || []) : []
                    KeyValue { required property var modelData; width: sideCol.width; labelWidth: 130; label: modelData[0]; value: Tasks.pct(modelData[1]) }
                }
                StyledText { visible: view.at >= 0; text: "Most memory"; topPadding: 6; font.pixelSize: Appearance.fs(11); color: Appearance.ink3 }
                Repeater {
                    model: view.at >= 0 ? ((view.rec.topMem || [])[view.at] || []) : []
                    KeyValue { required property var modelData; width: sideCol.width; labelWidth: 130; label: modelData[0]; value: Tasks.bytes(modelData[1] * 1048576) }
                }
            }
        }
    }
}
