import QtQuick
import Hyprshell

// 7-Zip's progress window, for the job in front: elapsed and remaining
// time, files, sizes, speed and ratio, what it is on, and Background,
// Pause and Cancel. It goes away by itself when a job succeeds, as 7-Zip's
// does; a test stays to say "There are no errors", and a failure stays to
// say what went wrong. A job sent to the background is a card in the
// corner instead (ArchiveJobs.qml).
PanelSurface {
    id: win

    required property var app
    readonly property var svc: FilesService
    readonly property var arc: Archives

    // The first job not in the background, and how many more wait behind.
    readonly property var front: {
        for (const j of win.arc.jobs) if (!j.background) return j;
        return null;
    }
    readonly property int waiting: win.arc.jobs.filter(j => !j.background).length - 1
    readonly property var j: win.front || ({})
    readonly property bool running: win.j.state === "running"

    showSeam: false
    color: Appearance.dialog
    visible: win.front !== null
    z: 960
    implicitWidth: 470
    implicitHeight: col.implicitHeight + titleBar.height + 28

    // Succeeded: away, as 7-Zip's window goes. A test is the exception —
    // its whole answer is that nothing is wrong.
    Connections {
        target: Archives
        function onFinished(job) {
            if (job && !job.background && job.state === "done" && job.kind !== "test") Archives.dismiss(job.id);
        }
    }

    // The clock the times are read from, ticking only while something runs.
    property real now: Date.now()
    Timer {
        interval: 500
        repeat: true
        running: win.visible && win.running
        onTriggered: win.now = Date.now()
    }
    onFrontChanged: { win.now = Date.now(); win.pw = ""; win.showPw = false; }

    property string pw: ""
    property bool showPw: false

    function clock(ms) {
        const s = Math.floor(ms / 1000), p = n => (n < 10 ? "0" : "") + n;
        return p(Math.floor(s / 3600)) + ":" + p(Math.floor(s / 60) % 60) + ":" + p(s % 60);
    }
    function size(n) { return n > 0 ? win.svc.humanSize(n) : ""; }

    readonly property real elapsed: win.arc.elapsed(win.front, win.now)
    readonly property real processed: win.j.total > 0 && win.j.percent >= 0 ? win.j.total * win.j.percent / 100 : 0
    readonly property string remaining: {
        if (!win.running || win.j.percent <= 0 || win.j.percent >= 100) return "";
        return win.clock(win.elapsed * (100 - win.j.percent) / win.j.percent);
    }
    readonly property string speed: win.elapsed > 900 && win.processed > 0
                                    ? win.svc.humanSize(Math.round(win.processed * 1000 / win.elapsed)) + "/s" : ""
    // Only once something real is on disk: 7-Zip holds a solid block in
    // memory, and until it writes one the file is its 32-byte header.
    readonly property bool written: win.j.outputSize > 1024
    readonly property string ratio: win.j.kind === "compress" && win.processed > 0 && win.written
                                    ? Math.round(100 * win.j.outputSize / win.processed) + "%" : ""

    function retry() {
        if (win.pw === "") return;
        Archives.retryWith(win.j.id, win.pw);
    }

    // ── title bar: "34% Adding", as 7-Zip's says ──────────────────────────
    Item {
        id: titleBar
        width: parent.width
        height: 38
        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: (win.running && win.j.percent >= 0 ? win.j.percent + "% " : "")
                  + (win.j.paused ? "Paused" : win.j.state === "failed" ? win.j.phase + ": Errors"
                     : win.j.state === "password" ? "Enter password" : (win.j.phase || ""))
                  + (win.waiting > 0 ? "   (+" + win.waiting + " waiting)" : "")
            font.pixelSize: Appearance.fs(12.5)
            font.weight: Font.DemiBold
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Appearance.rule }
    }

    component Pair: Item {
        id: pair
        property string label: ""
        property string value: ""
        width: 205
        height: 20
        StyledText {
            text: pair.label
            font.pixelSize: Appearance.fs(12)
            color: Appearance.ink2
        }
        StyledText {
            anchors.right: parent.right
            text: pair.value
            font.pixelSize: Appearance.fs(12)
        }
    }

    Column {
        id: col
        anchors.top: titleBar.bottom
        anchors.topMargin: 12
        x: 16
        width: parent.width - 32
        spacing: 10

        StyledText {
            width: parent.width
            elide: Text.ElideMiddle
            text: win.j.archive ? win.arc.shortPath(win.j.archive) : (win.j.title || "")
            font.pixelSize: Appearance.fs(11)
            color: Appearance.ink3
        }

        Grid {
            columns: 2
            columnSpacing: 28
            rowSpacing: 2
            Pair { label: "Elapsed time:"; value: win.clock(win.elapsed) }
            Pair { label: "Total size:"; value: win.size(win.j.total) }
            Pair { label: "Remaining time:"; value: win.remaining }
            Pair { label: "Speed:"; value: win.speed }
            Pair { label: "Files:"; value: win.j.files > 0 ? String(win.j.files) : "" }
            Pair { label: "Processed:"; value: win.size(win.processed) }
            Pair { label: win.j.kind === "compress" ? "Compression ratio:" : ""; value: win.ratio }
            Pair { label: win.j.kind === "compress" ? "Compressed size:" : ""; value: win.j.kind === "compress" && win.written ? win.size(win.j.outputSize) : "" }
        }

        StyledText {
            width: parent.width
            height: 18
            elide: Text.ElideMiddle
            text: win.running ? (win.j.current || "") : ""
            font.pixelSize: Appearance.fs(12)
        }

        // Progress, or a band sliding along when it can't be known.
        Rectangle {
            width: parent.width
            height: 14
            radius: 3
            color: Appearance.ground
            border.width: 1
            border.color: Appearance.rule
            clip: true
            Rectangle {
                visible: win.j.percent >= 0
                x: 1; y: 1
                height: parent.height - 2
                radius: 2
                width: (parent.width - 2) * Math.max(0, Math.min(1, (win.j.percent || 0) / 100))
                color: win.j.paused ? Appearance.ink3 : Appearance.accent
                Behavior on width { NumberAnimation { duration: 180 } }
            }
            Rectangle {
                id: band
                visible: win.j.percent < 0 && win.running
                y: 1
                height: parent.height - 2
                radius: 2
                width: parent.width * 0.3
                color: Appearance.accent
                NumberAnimation on x {
                    running: band.visible && !win.j.paused
                    loops: Animation.Infinite
                    from: -band.width
                    to: band.parent.width
                    duration: 1100
                }
            }
        }

        // ── finished: what 7-Zip has to say ──
        Rectangle {
            visible: win.j.state === "done" || win.j.state === "failed"
            width: parent.width
            height: Math.min(msgText.implicitHeight + 16, 160)
            radius: 4
            color: Appearance.ground
            border.width: 1
            border.color: Appearance.rule
            clip: true
            Flickable {
                anchors.fill: parent
                anchors.margins: 8
                contentHeight: msgText.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                StyledText {
                    id: msgText
                    width: parent.width
                    wrapMode: Text.WrapAnywhere
                    text: win.j.state === "done" ? "There are no errors"
                        : [win.j.error || ""].concat((win.j.log || []).filter(l => l !== win.j.error)).join("\n")
                    font.pixelSize: Appearance.fs(12)
                    color: win.j.state === "failed" ? Appearance.accent : Appearance.ink
                }
            }
        }

        // ── a password, for the archive that wanted one ──
        Column {
            visible: win.j.state === "password"
            width: parent.width
            spacing: 6
            StyledText {
                text: /wrong/i.test(win.j.error || "") ? "Wrong password? Enter password:" : "Enter password:"
                font.pixelSize: Appearance.fs(12)
            }
            Rectangle {
                width: parent.width
                height: 28
                radius: 4
                color: Appearance.ground
                border.width: pwIn.activeFocus ? 2 : 1
                border.color: pwIn.activeFocus ? Appearance.accent : Appearance.rule
                TextInput {
                    id: pwIn
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    verticalAlignment: Text.AlignVCenter
                    clip: true
                    echoMode: win.showPw ? TextInput.Normal : TextInput.Password
                    color: Appearance.ink
                    selectionColor: Appearance.accent
                    font.pixelSize: Appearance.fs(12)
                    text: win.pw
                    onTextEdited: win.pw = text
                    Keys.onReturnPressed: e => { e.accepted = true; win.retry(); }
                    Keys.onEnterPressed: e => { e.accepted = true; win.retry(); }
                }
            }
            Row {
                spacing: 7
                Rectangle {
                    width: 15; height: 15; radius: 3
                    anchors.verticalCenter: parent.verticalCenter
                    color: win.showPw ? Appearance.accent : Appearance.ground
                    border.width: win.showPw ? 0 : 1
                    border.color: Appearance.edge
                    StyledText {
                        anchors.centerIn: parent
                        visible: win.showPw
                        text: "✓"
                        font.pixelSize: Appearance.fs(11)
                        font.weight: Font.Bold
                        color: Appearance.inkOnAccent
                    }
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Show password"
                    font.pixelSize: Appearance.fs(12)
                }
                TapHandler { onTapped: win.showPw = !win.showPw }
            }
        }

        Item {
            width: parent.width
            height: 34
            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: 8
                DialogButton {
                    visible: win.running
                    text: "Background"
                    onTriggered: Archives.background(win.j.id, true)
                }
                DialogButton {
                    visible: win.running
                    text: win.j.paused ? "Continue" : "Pause"
                    onTriggered: Archives.pause(win.j.id, !win.j.paused)
                }
                DialogButton {
                    visible: win.running
                    text: "Cancel"
                    onTriggered: Archives.cancel(win.j.id)
                }
                DialogButton {
                    visible: win.j.state === "password"
                    text: "OK"
                    primary: true
                    enabled: win.pw !== ""
                    onTriggered: win.retry()
                }
                DialogButton {
                    visible: win.j.state === "password"
                    text: "Cancel"
                    onTriggered: Archives.dismiss(win.j.id)
                }
                DialogButton {
                    visible: win.j.state === "done" || win.j.state === "failed"
                    text: "Close"
                    primary: true
                    onTriggered: Archives.dismiss(win.j.id)
                }
            }
        }
    }
}
