import QtQuick
import Hyprshell
import Hyprshell.Backend

// What each app has used: processor time, GPU time and disk traffic, since
// the flight recorder started keeping count — or, without it, since this
// window opened.
Item {
    id: view
    property var frame: null
    readonly property var recorded: Recorder.appTotals
    readonly property bool fromRecorder: view.recorded.length > 0
    readonly property var rows: (view.fromRecorder ? view.recorded : (Monitor.sampledAt > 0 ? Monitor.processes.appTotals() : []))
        .filter(a => Tasks.search === "" || a.name.toLowerCase().indexOf(Tasks.search.toLowerCase()) >= 0)

    ViewHeader {
        id: head
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 16
        y: 6
        title: "App history"
        subtitle: view.fromRecorder ? "Since " + Tasks.stamp(Recorder.since / 1000) + ", from the flight recorder"
                                    : "Since this window opened — turn on the flight recorder to keep count across days"
        ToolButton {
            anchors.verticalCenter: parent.verticalCenter
            visible: !Recorder.enabled
            icon: "film"
            text: "Turn on the recorder"
            onClicked: Tasks.view = "recorder"
        }
    }
    Table {
        anchors.top: head.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        keyField: "key"
        sortKey: "cpuSeconds"
        sortDesc: true
        rows: view.rows
        emptyText: "No app has used anything yet."
        columns: [
            { k: "name", t: "Name", glyph: a => Tasks.glyph(a.icon || a.name) },
            { k: "cpuSeconds", t: "CPU time", w: 120, num: true, fmt: a => Tasks.duration(a.cpuSeconds) },
            { k: "gpuSeconds", t: "GPU time", w: 120, num: true, fmt: a => Tasks.duration(a.gpuSeconds || 0) },
            { k: "diskBytes", t: "Disk", w: 120, num: true, fmt: a => Tasks.bytes(a.diskBytes || 0) },
            { k: "lastSeen", t: "Last used", w: 150, num: true, fmt: a => Tasks.stamp((a.lastSeen || 0) / 1000) }
        ]
    }
}
