import QtQuick
import Hyprshell
import Hyprshell.Backend

// Quick benchmarks of this machine, each kept so the next run has
// something to be compared against.
Item {
    id: view
    property var frame: null
    property string diskPath: Tools.home() + "/.cache"

    Connections {
        target: Bench
        function onFailed(message) { if (view.frame) view.frame.toast.show(message, true); }
        function onFinished(result) { if (view.frame) view.frame.toast.show("Done.", false); }
    }
    function last(kind, skip) { return Bench.results.filter(r => r.kind === kind)[skip || 0] || null; }
    function change(now, before) {
        if (!now || !before || !before) return "";
        const d = (now - before) / before * 100;
        return Math.abs(d) < 1 ? "same as last time" : (d > 0 ? "+" : "") + d.toFixed(0) + "% on last time";
    }

    readonly property var cards: [
        { kind: "cpu", title: "Processor", icon: "cpu",
          about: "Integer and floating-point work on one thread for 3 s, then on every thread for 4 s.",
          figures: r => [["One thread", r.single.toFixed(0) + " M/s", r.single, "single"],
                         ["All " + r.threads + " threads", r.multi.toFixed(0) + " M/s", r.multi, "multi"],
                         ["Scaling", r.scaling.toFixed(1) + "×", r.scaling, "scaling"]] },
        { kind: "memory", title: "Memory", icon: "database",
          about: "Copying 512 MB back and forth for 3 s, then a random walk through 256 MB.",
          figures: r => [["Bandwidth", r.bandwidth.toFixed(1) + " GB/s", r.bandwidth, "bandwidth"],
                         ["Latency", r.latency.toFixed(1) + " ns", -r.latency, "latency"]] },
        { kind: "disk", title: "Disk", icon: "disk",
          about: "Writes and reads a 1 GB file, then 4 KB reads at random for 4 s — bypassing the cache where the filesystem allows.",
          figures: r => [["Write", r.write.toFixed(0) + " MB/s", r.write, "write"],
                         ["Read", r.read.toFixed(0) + " MB/s", r.read, "read"],
                         ["4K random", Math.round(r.iops).toLocaleString(Qt.locale("en_US"), "f", 0) + " IOPS", r.iops, "iops"]] }
    ]

    SmoothScroll { target: flick; anchors.fill: flick; z: 5 }
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
                title: "Benchmarks"
                subtitle: "Close what you can before running: anything else busy counts against the score"
                ToolButton { anchors.verticalCenter: parent.verticalCenter; visible: Bench.running; icon: "x"; text: "Cancel"; onClicked: Bench.cancel() }
            }
            Repeater {
                model: view.cards
                Card {
                    id: card
                    required property var modelData
                    readonly property var r: view.last(modelData.kind)
                    readonly property var prev: view.last(modelData.kind, 1)
                    readonly property bool mine: Bench.running && Bench.current === modelData.kind
                    width: col.width
                    height: cardCol.implicitHeight + 28
                    Column {
                        id: cardCol
                        x: 16; y: 14
                        width: parent.width - 32
                        spacing: 10
                        Item {
                            width: parent.width
                            height: 34
                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 9
                                MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: card.modelData.icon; size: 20; inkColor: Appearance.ink2; accentColor: Appearance.accent }
                                StyledText { anchors.verticalCenter: parent.verticalCenter; text: card.modelData.title; font.pixelSize: Appearance.fs(14); font.weight: Font.DemiBold }
                            }
                            Row {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 8
                                SevenCombo {
                                    visible: card.modelData.kind === "disk"
                                    width: 220
                                    model: Monitor.disks.reduce((acc, d) => acc.concat((d.mounts || []).filter(m => !m.readOnly).map(m => m.path)), [Tools.home() + "/.cache"])
                                    value: view.diskPath
                                    onPicked: v => view.diskPath = v
                                }
                                DialogButton {
                                    text: card.mine ? "Running…" : "Run"
                                    primary: true
                                    enabled: !Bench.running
                                    onTriggered: Bench.run(card.modelData.kind, card.modelData.kind === "disk" ? view.diskPath : "")
                                }
                            }
                        }
                        StyledText { width: parent.width; wrapMode: Text.WordWrap; text: card.modelData.about; font.pixelSize: Appearance.fs(12); color: Appearance.ink2 }
                        Column {
                            visible: card.mine
                            width: parent.width
                            spacing: 4
                            StyledText { text: Bench.stage; font.pixelSize: Appearance.fs(11.5); color: Appearance.ink3 }
                            Meter { width: parent.width; height: 8; value: Bench.progress }
                        }
                        Row {
                            visible: !!card.r && !card.mine
                            spacing: 34
                            Repeater {
                                model: card.r ? card.modelData.figures(card.r) : []
                                Column {
                                    required property var modelData
                                    spacing: 2
                                    Stat { label: modelData[0]; value: modelData[1] }
                                    StyledText {
                                        readonly property var before: card.prev ? card.modelData.figures(card.prev).find(f => f[3] === modelData[3]) : null
                                        text: before ? view.change(modelData[2], before[2]) : ""
                                        font.pixelSize: Appearance.fs(11)
                                        color: Appearance.ink3
                                    }
                                }
                            }
                        }
                        StyledText {
                            visible: !!card.r && !card.mine
                            text: card.r ? "Last run " + Tasks.stamp(card.r.at / 1000) + (card.r.path ? " on " + card.r.path + (card.r.direct ? "" : " (through the cache)") : "") : ""
                            font.pixelSize: Appearance.fs(11)
                            color: Appearance.ink3
                        }
                    }
                }
            }
            Item {
                width: parent.width
                height: 24
                visible: Bench.results.length > 0
                StyledText { anchors.verticalCenter: parent.verticalCenter; text: "Every run"; font.pixelSize: Appearance.fs(13); font.weight: Font.DemiBold }
                ToolButton { anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; text: "Forget them"; onClicked: Bench.clearResults() }
            }
            Repeater {
                model: Bench.results
                KeyValue {
                    required property var modelData
                    width: col.width
                    labelWidth: 230
                    label: Tasks.stamp(modelData.at / 1000) + "  ·  " + (view.cards.find(c => c.kind === modelData.kind) || {}).title
                    value: (view.cards.find(c => c.kind === modelData.kind) || { figures: () => [] }).figures(modelData).map(f => f[0] + " " + f[1]).join("   ·   ")
                }
            }
        }
    }
}
