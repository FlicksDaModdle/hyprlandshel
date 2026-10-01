import QtQuick
import Hyprshell
import Hyprshell.Backend

// Everything about one process, beside the list: read afresh each sample.
Rectangle {
    id: panel
    property int pid: 0
    signal closeRequested()
    signal endRequested(int sig)

    readonly property var d: panel.width > 40 && panel.pid > 0 && Monitor.sampledAt > 0 ? Monitor.processes.details(panel.pid) : ({})
    readonly property var m: panel.d.memory || ({})

    color: Appearance.hover
    clip: true
    visible: width > 1
    Rectangle { width: 1; height: parent.height; color: Appearance.rule }

    Item {
        id: top
        x: 16
        width: parent.width - 24
        height: 44
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 40
            elide: Text.ElideRight
            text: panel.d.name ? panel.d.name + "  ·  " + panel.pid : "Process " + panel.pid + " has exited"
            font.pixelSize: Appearance.fs(13.5)
            font.weight: Font.DemiBold
        }
        ToolButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            icon: "x"
            onClicked: panel.closeRequested()
        }
    }

    SmoothScroll { target: flick; anchors.fill: flick; z: 5 }
    Flickable {
        id: flick
        anchors.top: top.bottom
        anchors.bottom: buttons.top
        x: 16
        width: parent.width - 24
        contentHeight: col.implicitHeight + 10
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        Column {
            id: col
            width: flick.width
            spacing: 2
            component Head: StyledText {
                topPadding: 10
                bottomPadding: 3
                font.pixelSize: Appearance.fs(11)
                font.weight: Font.DemiBold
                font.letterSpacing: 0.8
                color: Appearance.ink3
            }
            Head { text: "PROCESS" }
            KeyValue { labelWidth: 110; label: "User"; value: panel.d.user || "" }
            KeyValue { labelWidth: 110; label: "Parent"; value: panel.d.ppid ? (panel.d.parent || "?") + " (" + panel.d.ppid + ")" : "" }
            KeyValue { labelWidth: 110; label: "Program"; value: panel.d.exe || "" }
            KeyValue { labelWidth: 110; label: "Folder"; value: panel.d.cwd || "" }
            KeyValue { labelWidth: 110; label: "Command line"; value: panel.d.cmd || "" }
            KeyValue { labelWidth: 110; label: "Control group"; value: panel.d.cgroup || "" }
            Head { text: "MEMORY" }
            KeyValue { labelWidth: 110; label: "Private"; value: Tasks.bytes(panel.m.RssAnon) }
            KeyValue { labelWidth: 110; label: "Shared files"; value: Tasks.bytes(panel.m.RssFile) }
            KeyValue { labelWidth: 110; label: "Shared memory"; value: Tasks.bytes(panel.m.RssShmem) }
            KeyValue { labelWidth: 110; label: "Swapped out"; value: Tasks.bytes(panel.m.VmSwap) }
            KeyValue { labelWidth: 110; label: "Address space"; value: Tasks.bytes(panel.m.VmSize) }
            KeyValue { labelWidth: 110; label: "Peak resident"; value: Tasks.bytes(panel.m.VmHWM) }
            Head { text: "CPU" }
            KeyValue { labelWidth: 110; label: "CPU time"; value: panel.d.cpuSeconds !== undefined ? Tasks.duration(panel.d.cpuSeconds) : "" }
            KeyValue { labelWidth: 110; label: "Threads"; value: String(panel.d.threads || "") }
            KeyValue { labelWidth: 110; label: "Priority"; value: panel.d.nice !== undefined ? "nice " + panel.d.nice + " · " + (panel.d.policy || "") : "" }
            KeyValue { labelWidth: 110; label: "Runs on"; value: panel.d.cpusAllowed ? "CPUs " + panel.d.cpusAllowed : "" }
            KeyValue { labelWidth: 110; label: "Switches"; value: panel.d.ctxVoluntary !== undefined ? Tasks.count(panel.d.ctxVoluntary) + " waited, " + Tasks.count(panel.d.ctxForced) + " preempted" : "" }
            Head { text: "INPUT / OUTPUT" }
            KeyValue { labelWidth: 110; label: "Read"; value: panel.d.ioKnown ? Tasks.bytes(panel.d.readTotal) : "Not readable without root" }
            KeyValue { labelWidth: 110; label: "Written"; value: panel.d.ioKnown ? Tasks.bytes(panel.d.writeTotal) : "" }
            KeyValue { labelWidth: 110; label: "I/O priority"; value: panel.d.ioClass ? panel.d.ioClass + " " + panel.d.ioLevel : "" }
            KeyValue { labelWidth: 110; label: "Open"; value: panel.d.fdsKnown ? panel.d.fds + " (" + panel.d.files + " files, " + panel.d.sockets + " sockets, " + panel.d.pipes + " pipes)" : "Not readable without root" }
            KeyValue { labelWidth: 110; label: "OOM score"; value: panel.d.oomScore !== undefined ? String(panel.d.oomScore) : "" }
            Head { text: "CHILDREN"; visible: (panel.d.children || []).length > 0 }
            Repeater {
                model: panel.d.children || []
                KeyValue { required property var modelData; labelWidth: 110; label: String(modelData.pid); value: modelData.name }
            }
        }
    }

    Row {
        id: buttons
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 12
        x: 16
        spacing: 8
        DialogButton { text: "End task"; primary: true; enabled: !!panel.d.name; onTriggered: panel.endRequested(15) }
        DialogButton { text: "Kill"; enabled: !!panel.d.name; onTriggered: panel.endRequested(9) }
        DialogButton { text: "Show file"; enabled: !!panel.d.exe; onTriggered: Tools.showInFolder(panel.d.exe) }
    }
}
