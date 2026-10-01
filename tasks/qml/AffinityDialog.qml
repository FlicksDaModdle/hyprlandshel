import QtQuick
import Hyprshell
import Hyprshell.Backend

// Which logical processors a process may run on.
Modal {
    id: dlg
    property int pid: 0
    property var allowed: []
    signal apply(int pid, var cpus)
    function openFor(r) {
        dlg.pid = r.pid;
        dlg.title = "Processor affinity — " + r.name;
        dlg.allowed = Monitor.processes.affinity(r.pid);
        dlg.open = true;
    }
    boxWidth: 460
    Column {
        width: parent.width
        spacing: 12
        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Which processors it may run on. Every thread it has now is moved; threads it starts later inherit this."
            font.pixelSize: Appearance.fs(12)
            color: Appearance.ink2
        }
        Flow {
            width: parent.width
            spacing: 6
            Repeater {
                model: Monitor.cores.length
                Rectangle {
                    required property int index
                    readonly property bool on: dlg.allowed.indexOf(index) >= 0
                    width: 52; height: 30
                    radius: Appearance.rSm
                    color: on ? Appearance.accent : Appearance.hover
                    StyledText {
                        anchors.centerIn: parent
                        text: "CPU " + index
                        font.pixelSize: Appearance.fs(11)
                        color: parent.on ? Appearance.inkOnAccent : Appearance.ink2
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            const a = dlg.allowed.slice();
                            const i = a.indexOf(index);
                            if (i >= 0) a.splice(i, 1); else a.push(index);
                            dlg.allowed = a.sort((x, y) => x - y);
                        }
                    }
                }
            }
        }
        Row {
            spacing: 8
            DialogButton { text: "All"; onTriggered: dlg.allowed = Array.from({ length: Monitor.cores.length }, (_, i) => i) }
            DialogButton { text: "OK"; primary: true; enabled: dlg.allowed.length > 0; onTriggered: { dlg.apply(dlg.pid, dlg.allowed); dlg.open = false; } }
            DialogButton { text: "Cancel"; onTriggered: dlg.open = false }
        }
    }
}
