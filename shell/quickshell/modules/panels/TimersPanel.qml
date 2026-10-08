import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Timers, the pomodoro and alarms (services/Timers.qml). Opened from the
// bar's countdown, the clock's menu, or the launcher ("Timers").
PanelSurface {
    id: root

    readonly property var tm: Services.Timers
    readonly property real now: tm.now

    implicitWidth: 360
    implicitHeight: Math.min(640, col.implicitHeight + 24)

    // The custom-length field takes typing.
    Binding {
        target: Config.UiState
        property: "panelWantsKeyboard"
        value: true
        when: Config.UiState.timersOpen
    }

    // ── small pieces ──────────────────────────────────────────────────────
    component Caption: StyledText {
        font.pixelSize: Config.Appearance.fs(11)
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.9
        color: Config.Appearance.ink2
    }
    component Chip: Rectangle {
        id: chip
        property string text: ""
        property bool on: false
        property bool primary: false
        signal clicked
        width: chipText.implicitWidth + 22
        height: 28
        radius: height / 2
        color: chip.primary ? Config.Appearance.accent
             : chip.on ? Config.Appearance.sel
             : (chipHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
        StyledText {
            id: chipText
            anchors.centerIn: parent
            text: chip.text
            font.pixelSize: Config.Appearance.fs(11.5)
            font.weight: Font.DemiBold
            color: chip.primary ? Config.Appearance.inkOnAccent : Config.Appearance.ink
        }
        HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: chip.clicked() }
    }
    component Round: Rectangle {
        id: rb
        property string icon: ""
        property bool primary: false
        signal clicked
        width: 30; height: 30; radius: 15
        color: rb.primary ? Config.Appearance.accent : (rbHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
        MonoIcon {
            anchors.centerIn: parent
            name: rb.icon
            size: 14
            inkColor: rb.primary ? Config.Appearance.inkOnAccent : Config.Appearance.ink
            monochrome: true
        }
        HoverHandler { id: rbHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: rb.clicked() }
    }
    // − value +
    component Stepper: Row {
        id: st
        property int value: 0
        property int from: 0
        property int to: 59
        property int step: 1
        property bool wrap: false
        property bool pad: false
        property string suffix: ""
        signal changed(int value)
        spacing: 2
        function bump(d) {
            let v = st.value + d * st.step;
            if (st.wrap) v = ((v - st.from) % (st.to - st.from + 1) + (st.to - st.from + 1)) % (st.to - st.from + 1) + st.from;
            else v = Math.max(st.from, Math.min(st.to, v));
            st.changed(v);
        }
        Round { icon: "minus"; width: 24; height: 24; radius: 12; onClicked: st.bump(-1) }
        StyledText {
            width: Math.max(implicitWidth, 30)
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: (st.pad && st.value < 10 ? "0" : "") + st.value + st.suffix
            font.pixelSize: Config.Appearance.fs(13)
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
        Round { icon: "plus"; width: 24; height: 24; radius: 12; onClicked: st.bump(1) }
    }

    Flickable {
        id: timersPanelScroll
        KineticScroll { flick: timersPanelScroll }
        anchors.fill: parent
        contentHeight: col.implicitHeight + 24
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: col
            x: 14; y: 12
            width: parent.width - 28
            spacing: 10

            // ══ timers ═══════════════════════════════════════════════════
            Caption { text: "Timer" }

            Flow {
                width: parent.width
                spacing: 6
                Repeater {
                    model: [["1 min", 60], ["5 min", 300], ["10 min", 600], ["25 min", 1500], ["1 h", 3600]]
                    Chip {
                        required property var modelData
                        text: modelData[0]
                        onClicked: root.tm.addTimer(modelData[1])
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 32
                radius: Config.Appearance.rPill
                color: Config.Appearance.sel
                border.width: 1
                border.color: custom.activeFocus ? Config.Appearance.accent
                            : (root.badCustom ? "#d93a2b" : Config.Appearance.edge)
                MonoIcon {
                    id: customIcon
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    name: "timer"
                    size: 14
                    inkColor: Config.Appearance.ink3
                    monochrome: true
                }
                TextInput {
                    id: custom
                    anchors.left: customIcon.right
                    anchors.leftMargin: 8
                    anchors.right: startCustom.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    clip: true
                    color: Config.Appearance.ink
                    font.family: Config.Appearance.fontFamily
                    font.pixelSize: Config.Appearance.fs(12)
                    selectByMouse: true
                    selectionColor: Config.Appearance.accent
                    onTextChanged: root.badCustom = false
                    onAccepted: root.startCustom()
                    Keys.onEscapePressed: Config.UiState.closeAll()
                    StyledText {
                        anchors.fill: parent
                        visible: custom.text === ""
                        verticalAlignment: Text.AlignVCenter
                        text: "Any length, e.g. 45 or 1h30, tea"
                        font.pixelSize: Config.Appearance.fs(11.5)
                        color: Config.Appearance.ink3
                        elide: Text.ElideRight
                    }
                }
                Chip {
                    id: startCustom
                    anchors.right: parent.right
                    anchors.rightMargin: 3
                    anchors.verticalCenter: parent.verticalCenter
                    height: 26
                    text: "Start"
                    primary: custom.text !== ""
                    onClicked: root.startCustom()
                }
            }

            Repeater {
                model: root.tm.timers
                Rectangle {
                    id: trow
                    required property var modelData
                    readonly property var t: modelData
                    readonly property real remaining: { root.now; return root.tm.leftOf(t); }
                    width: col.width
                    height: 58
                    radius: Config.Appearance.rSm
                    color: Config.Appearance.hover

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: tbtns.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        StyledText {
                            text: root.tm.clock(trow.remaining)
                            font.pixelSize: Config.Appearance.fs(20)
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                            color: trow.t.running ? Config.Appearance.ink : Config.Appearance.ink3
                        }
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: trow.t.label + (trow.t.running ? "" : " · paused")
                            font.pixelSize: Config.Appearance.fs(11)
                            color: Config.Appearance.ink3
                        }
                    }
                    Row {
                        id: tbtns
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6
                        Round {
                            icon: trow.t.running ? "pause" : "play"
                            onClicked: trow.t.running ? root.tm.pauseTimer(trow.t.id) : root.tm.resumeTimer(trow.t.id)
                        }
                        Round { icon: "x"; onClicked: root.tm.cancelTimer(trow.t.id) }
                    }
                    // How much is left, along the bottom edge.
                    Rectangle {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 10
                        anchors.bottomMargin: 5
                        height: 3
                        radius: 1.5
                        width: (parent.width - 20) * Math.max(0, Math.min(1, trow.remaining / Math.max(1, trow.t.total)))
                        color: trow.t.running ? Config.Appearance.accent : Config.Appearance.ink3
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

            // ══ pomodoro ═════════════════════════════════════════════════
            Item {
                width: parent.width
                height: pcap.implicitHeight
                Caption { id: pcap; text: "Pomodoro" }
                StyledText {
                    anchors.right: parent.right
                    anchors.baseline: pcap.baseline
                    readonly property int done: root.tm.pomo.day === root.tm.today() ? root.tm.pomo.done : 0
                    text: done === 0 ? "" : done + (done === 1 ? " session" : " sessions") + " today"
                    font.pixelSize: Config.Appearance.fs(11)
                    color: Config.Appearance.ink3
                }
            }

            Rectangle {
                width: parent.width
                height: pomoCol.implicitHeight + 24
                radius: Config.Appearance.rSm
                color: Config.Appearance.hover

                Column {
                    id: pomoCol
                    x: 12; y: 12
                    width: parent.width - 24
                    spacing: 10

                    Item {
                        width: parent.width
                        height: 40
                        MonoIcon {
                            id: tomato
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            name: "pomodoro"
                            size: 26
                            inkColor: Config.Appearance.ink
                            accentColor: Config.Appearance.accent
                        }
                        Column {
                            anchors.left: tomato.right
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            StyledText {
                                text: root.tm.pomoActive
                                      ? root.tm.clock((root.now, root.tm.leftOf(root.tm.pomo)))
                                      : root.tm.pomoWork + ":00"
                                font.pixelSize: Config.Appearance.fs(20)
                                font.weight: Font.DemiBold
                                font.features: { "tnum": 1 }
                                color: root.tm.pomoActive && !root.tm.pomo.running ? Config.Appearance.ink3 : Config.Appearance.ink
                            }
                            StyledText {
                                text: root.tm.pomoActive
                                      ? root.tm.phaseName(root.tm.pomo.phase) + (root.tm.pomo.running ? "" : " · paused")
                                      : "Focus, then a break, on repeat"
                                font.pixelSize: Config.Appearance.fs(11)
                                color: Config.Appearance.ink3
                            }
                        }
                        Row {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            Round {
                                visible: !root.tm.pomoActive
                                icon: "play"
                                primary: true
                                onClicked: root.tm.pomoStart()
                            }
                            Round {
                                visible: root.tm.pomoActive
                                icon: root.tm.pomo.running ? "pause" : "play"
                                primary: !root.tm.pomo.running
                                onClicked: root.tm.pomo.running ? root.tm.pomoPause() : root.tm.pomoResume()
                            }
                            Round { visible: root.tm.pomoActive; icon: "skipForward"; onClicked: root.tm.pomoSkip() }
                            Round { visible: root.tm.pomoActive; icon: "square"; onClicked: root.tm.pomoStop() }
                        }
                    }

                    // The lengths, in minutes.
                    Grid {
                        columns: 2
                        columnSpacing: 28
                        rowSpacing: 8
                        Repeater {
                            model: [["Focus", "pomoWork", 5, 120, 5], ["Short break", "pomoShort", 1, 30, 1],
                                    ["Long break", "pomoLong", 5, 60, 5], ["Long break after", "pomoEvery", 2, 8, 1]]
                            Column {
                                required property var modelData
                                spacing: 3
                                StyledText {
                                    text: modelData[0]
                                    font.pixelSize: Config.Appearance.fs(10.5)
                                    color: Config.Appearance.ink3
                                }
                                Stepper {
                                    value: root.tm[modelData[1]]
                                    from: modelData[2]
                                    to: modelData[3]
                                    step: modelData[4]
                                    suffix: modelData[1] === "pomoEvery" ? " sessions" : " min"
                                    onChanged: v => {
                                        const L = { pomoWork: root.tm.pomoWork, pomoShort: root.tm.pomoShort,
                                                    pomoLong: root.tm.pomoLong, pomoEvery: root.tm.pomoEvery };
                                        L[modelData[1]] = v;
                                        root.tm.setPomoLengths(L.pomoWork, L.pomoShort, L.pomoLong, L.pomoEvery);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

            // ══ alarms ═══════════════════════════════════════════════════
            Item {
                width: parent.width
                height: acap.implicitHeight
                Caption { id: acap; text: "Alarms" }
                StyledText {
                    anchors.right: parent.right
                    anchors.baseline: acap.baseline
                    text: root.tm.nextAlarm ? "Next " + root.tm.untilText(root.tm.nextAlarm.at) : ""
                    font.pixelSize: Config.Appearance.fs(11)
                    color: Config.Appearance.ink3
                }
            }

            Repeater {
                model: root.tm.alarms
                Rectangle {
                    id: arow
                    required property var modelData
                    readonly property var a: modelData
                    width: col.width
                    height: 52
                    radius: Config.Appearance.rSm
                    color: Config.Appearance.hover
                    HoverHandler { id: arowHover }
                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.right: arowRight.left
                        anchors.verticalCenter: parent.verticalCenter
                        StyledText {
                            text: root.tm.alarmTime(arow.a)
                            font.pixelSize: Config.Appearance.fs(18)
                            font.weight: Font.DemiBold
                            font.features: { "tnum": 1 }
                            color: arow.a.on ? Config.Appearance.ink : Config.Appearance.ink3
                        }
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: arow.a.label + " · " + root.tm.daysText(arow.a.days)
                            font.pixelSize: Config.Appearance.fs(11)
                            color: Config.Appearance.ink3
                        }
                    }
                    Row {
                        id: arowRight
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Round {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: arowHover.hovered
                            icon: "trash"
                            width: 26; height: 26; radius: 13
                            onClicked: root.tm.removeAlarm(arow.a.id)
                        }
                        Toggle {
                            anchors.verticalCenter: parent.verticalCenter
                            checked: arow.a.on
                            onToggled: on => root.tm.updateAlarm(arow.a.id, { on: on })
                        }
                    }
                }
            }

            // A new one: the time, which days, a name.
            Rectangle {
                width: parent.width
                height: addCol.implicitHeight + 20
                radius: Config.Appearance.rSm
                color: "transparent"
                border.width: 1
                border.color: Config.Appearance.edge

                Column {
                    id: addCol
                    x: 10; y: 10
                    width: parent.width - 20
                    spacing: 8

                    Row {
                        spacing: 6
                        Stepper { value: root.newH; from: 0; to: 23; wrap: true; pad: true; onChanged: v => root.newH = v }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: ":"
                            font.pixelSize: Config.Appearance.fs(14)
                            font.weight: Font.DemiBold
                        }
                        Stepper { value: root.newM; from: 0; to: 55; step: 5; wrap: true; pad: true; onChanged: v => root.newM = v }
                        Item { width: 6; height: 1 }
                        Chip {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Add alarm"
                            primary: true
                            onClicked: {
                                root.tm.addAlarm(root.newH, root.newM, root.newDays.slice(),
                                                 alarmName.text.trim() || "Alarm");
                                alarmName.text = "";
                            }
                        }
                    }
                    Row {
                        spacing: 4
                        Repeater {
                            model: 7
                            Chip {
                                required property int index
                                // Monday first, as calendars here are.
                                readonly property int day: (index + 1) % 7
                                width: 32
                                text: root.tm.dayNames[day].slice(0, 2)
                                on: root.newDays.indexOf(day) >= 0
                                onClicked: root.newDays = on ? root.newDays.filter(d => d !== day)
                                                             : root.newDays.concat([day])
                            }
                        }
                    }
                    Rectangle {
                        width: parent.width
                        height: 28
                        radius: Config.Appearance.rPill
                        color: Config.Appearance.sel
                        TextInput {
                            id: alarmName
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            color: Config.Appearance.ink
                            font.family: Config.Appearance.fontFamily
                            font.pixelSize: Config.Appearance.fs(12)
                            StyledText {
                                anchors.fill: parent
                                visible: alarmName.text === ""
                                verticalAlignment: Text.AlignVCenter
                                text: root.newDays.length === 0 ? "Name (optional) · no days picked: rings once"
                                                                 : "Name (optional)"
                                font.pixelSize: Config.Appearance.fs(11.5)
                                color: Config.Appearance.ink3
                            }
                        }
                    }
                }
            }

            Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

            Item {
                width: parent.width
                height: 30
                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Play a sound"
                    font.pixelSize: Config.Appearance.fs(12)
                }
                Toggle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: root.tm.sound
                    onToggled: on => { root.tm.sound = on; root.tm.save(); }
                }
            }
        }
    }

    // ── the new alarm's choices ───────────────────────────────────────────
    property int newH: 7
    property int newM: 0
    property var newDays: [1, 2, 3, 4, 5]
    property bool badCustom: false

    // "25", "1h30", "90s" — and an optional name after a comma.
    function startCustom() {
        const text = custom.text;
        const comma = text.indexOf(",");
        const len = comma >= 0 ? text.slice(0, comma) : text;
        const name = comma >= 0 ? text.slice(comma + 1).trim() : "";
        const secs = tm.parseDuration(len);
        if (secs <= 0) { badCustom = true; return; }
        tm.addTimer(secs, name);
        custom.text = "";
    }
}
