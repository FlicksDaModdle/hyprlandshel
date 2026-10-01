import QtQuick
import Hyprshell

// Archive work sent to the background — 7-Zip's Background button — as
// cards in the corner of the window: what it is, how far along, and the
// way back to its progress window. A finished one offers to show what it
// made and then goes by itself; a failed one stays, with why — and when
// the why is a password, a field to give one and try again.
Column {
    id: jobs

    required property var app
    readonly property var arc: Archives

    width: 320
    spacing: 8

    // Done: show it, then go away on its own after a while.
    Connections {
        target: Archives
        function onFinished(job) {
            if (!job || job.state !== "done" || !job.background) return;
            reaper.createObject(jobs, { jobId: job.id });
        }
    }
    Component {
        id: reaper
        Timer {
            property int jobId: 0
            interval: 8000
            running: true
            onTriggered: { Archives.dismiss(jobId); destroy(); }
        }
    }

    // Opens the folder something landed in, with it selected.
    function reveal(job) {
        const path = String(job.output || "");
        if (path === "") return;
        if (job.kind === "extract") jobs.app.go(path);
        else {
            const dir = path.slice(0, path.lastIndexOf("/")) || "/";
            jobs.app.pendingSelect = path.slice(path.lastIndexOf("/") + 1);
            if (dir !== jobs.app.cwd) jobs.app.go(dir); else jobs.app.reload();
        }
        Archives.dismiss(job.id);
    }

    Repeater {
        model: jobs.arc.jobs.filter(j => j.background)

        PanelSurface {
            id: card
            required property var modelData
            readonly property var j: modelData
            property string pw: ""
            showSeam: false
            width: jobs.width
            implicitHeight: cardCol.implicitHeight + 24

            Column {
                id: cardCol
                x: 12; y: 12
                width: parent.width - 24
                spacing: 8

                StyledText {
                    width: parent.width
                    elide: Text.ElideMiddle
                    text: card.j.title
                    font.pixelSize: Appearance.fs(12)
                    font.weight: Font.DemiBold
                }
                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: card.j.state === "running"
                          ? [card.j.paused ? "Paused" : card.j.phase, card.j.percent > 0 ? card.j.percent + "%" : ""].filter(s => s).join(" · ")
                        : card.j.state === "done" ? (card.j.kind === "test" ? "Everything checks out." : "Done.")
                        : card.j.error
                    visible: text !== ""
                    font.pixelSize: Appearance.fs(11)
                    color: card.j.state === "failed" ? Appearance.accent : Appearance.ink3
                }

                // Progress: a fill, or a sliding band when it can't be known.
                Rectangle {
                    visible: card.j.state === "running"
                    width: parent.width
                    height: 6
                    radius: 3
                    color: Appearance.surface
                    clip: true
                    Rectangle {
                        visible: card.j.percent >= 0
                        height: parent.height
                        radius: 3
                        width: parent.width * Math.max(0.02, card.j.percent / 100)
                        color: card.j.paused ? Appearance.ink3 : Appearance.accent
                        Behavior on width { NumberAnimation { duration: 180 } }
                    }
                    Rectangle {
                        id: band
                        visible: card.j.percent < 0
                        height: parent.height
                        radius: 3
                        width: parent.width * 0.3
                        color: Appearance.accent
                        NumberAnimation on x {
                            running: band.visible
                            loops: Animation.Infinite
                            from: -band.width
                            to: band.parent.width
                            duration: 1100
                        }
                    }
                }

                Row {
                    visible: card.j.state === "password"
                    spacing: 8
                    Rectangle {
                        width: cardCol.width - goPw.width - 8
                        height: 30
                        radius: Appearance.rSm
                        color: Appearance.ground
                        border.width: pwIn.activeFocus ? 2 : 1
                        border.color: pwIn.activeFocus ? Appearance.accent : Appearance.rule
                        TextInput {
                            id: pwIn
                            anchors.fill: parent
                            anchors.leftMargin: 9
                            anchors.rightMargin: 9
                            verticalAlignment: Text.AlignVCenter
                            clip: true
                            echoMode: TextInput.Password
                            color: Appearance.ink
                            font.pixelSize: Appearance.fs(12)
                            onTextEdited: card.pw = text
                            Keys.onReturnPressed: e => { e.accepted = true; if (card.pw !== "") Archives.retryWith(card.j.id, card.pw); }
                            Keys.onEnterPressed: e => { e.accepted = true; if (card.pw !== "") Archives.retryWith(card.j.id, card.pw); }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: pwIn.text === ""
                                text: "Password"
                                font.pixelSize: Appearance.fs(12)
                                color: Appearance.ink3
                            }
                        }
                    }
                    Rectangle {
                        id: goPw
                        width: goText.implicitWidth + 22
                        height: 30
                        radius: Appearance.rSm
                        color: Appearance.accent
                        opacity: card.pw !== "" ? 1 : 0.45
                        StyledText {
                            id: goText
                            anchors.centerIn: parent
                            text: "Try again"
                            font.pixelSize: Appearance.fs(12)
                            font.weight: Font.DemiBold
                            color: Appearance.inkOnAccent
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (card.pw !== "") Archives.retryWith(card.j.id, card.pw)
                        }
                    }
                }

                Row {
                    spacing: 14
                    Repeater {
                        model: card.j.state === "running" ? [{ t: "Show", a: "front" },
                                                             { t: card.j.paused ? "Continue" : "Pause", a: "pause" },
                                                             { t: "Cancel", a: "cancel" }]
                             : card.j.state === "done" && card.j.output !== "" && card.j.kind !== "test"
                               ? [{ t: "Show", a: "show" }, { t: "Dismiss", a: "dismiss" }]
                             : [{ t: "Dismiss", a: "dismiss" }]
                        StyledText {
                            required property var modelData
                            text: modelData.t
                            font.pixelSize: Appearance.fs(12)
                            font.weight: Font.DemiBold
                            color: Appearance.accent
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -4
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (modelData.a === "cancel") Archives.cancel(card.j.id);
                                    else if (modelData.a === "front") Archives.background(card.j.id, false);
                                    else if (modelData.a === "pause") Archives.pause(card.j.id, !card.j.paused);
                                    else if (modelData.a === "show") jobs.reveal(card.j);
                                    else Archives.dismiss(card.j.id);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
