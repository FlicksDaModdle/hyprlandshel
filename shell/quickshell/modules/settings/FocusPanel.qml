import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Notifications → Focus (services/Focus.qml): quiet hours on a
// schedule, and how each app that has sent anything may interrupt.
Column {
    id: root

    readonly property var fc: Services.Focus
    width: parent ? parent.width : 560
    spacing: 10

    component Round: Rectangle {
        id: rb
        property string icon: ""
        signal clicked
        width: 24; height: 24; radius: 12
        color: rbHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
        MonoIcon { anchors.centerIn: parent; name: rb.icon; size: 12; inkColor: Config.Appearance.ink; monochrome: true }
        HoverHandler { id: rbHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: rb.clicked() }
    }
    // A time of day, a quarter of an hour a step.
    component TimeStep: Row {
        id: ts
        property string value: "00:00"
        signal changed(string value)
        spacing: 4
        function bump(d) {
            const m = (Services.Focus.minutes(ts.value) + d * 15 + 1440) % 1440;
            const two = n => (n < 10 ? "0" : "") + n;
            ts.changed(two(Math.floor(m / 60)) + ":" + two(m % 60));
        }
        Round { icon: "minus"; onClicked: ts.bump(-1) }
        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: 44
            horizontalAlignment: Text.AlignHCenter
            text: ts.value
            font.pixelSize: Config.Appearance.fs(13)
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
        Round { icon: "plus"; onClicked: ts.bump(1) }
    }

    // ── now ───────────────────────────────────────────────────────────────
    StyledText {
        width: parent.width
        wrapMode: Text.Wrap
        text: root.fc.quiet ? "Quiet now: " + root.fc.reason + "."
            : root.fc.current ? "Quiet hours set aside until " + root.fc.hm(new Date(root.fc.current.endsAt))
                                   + " — the bell turns them back on."
            : "Not quiet now."
        font.pixelSize: Config.Appearance.fs(12)
        color: root.fc.quiet ? Config.Appearance.accent : Config.Appearance.ink3
    }

    // ── quiet hours ───────────────────────────────────────────────────────
    Repeater {
        model: root.fc.schedules
        Rectangle {
            id: card
            required property var modelData
            readonly property var sch: modelData
            width: root.width
            height: cardCol.implicitHeight + 20
            radius: Config.Appearance.rSm
            color: Config.Appearance.hover

            Column {
                id: cardCol
                x: 12; y: 10
                width: parent.width - 24
                spacing: 8

                Item {
                    width: parent.width
                    height: 28
                    TextInput {
                        id: nameField
                        anchors.left: parent.left
                        anchors.right: cardBtns.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: card.sch.name
                        color: Config.Appearance.ink
                        font.family: Config.Appearance.fontFamily
                        font.pixelSize: Config.Appearance.fs(13)
                        font.weight: Font.DemiBold
                        selectByMouse: true
                        clip: true
                        onEditingFinished: if (text.trim() !== card.sch.name)
                            root.fc.updateSchedule(card.sch.id, { name: text.trim() || "Focus" })
                    }
                    Row {
                        id: cardBtns
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8
                        Round { anchors.verticalCenter: parent.verticalCenter; icon: "trash"; onClicked: root.fc.removeSchedule(card.sch.id) }
                        Toggle {
                            anchors.verticalCenter: parent.verticalCenter
                            checked: card.sch.on
                            onToggled: on => root.fc.updateSchedule(card.sch.id, { on: on })
                        }
                    }
                }

                Row {
                    spacing: 10
                    StyledText { anchors.verticalCenter: parent.verticalCenter; text: "From"; font.pixelSize: Config.Appearance.fs(12); color: Config.Appearance.ink3 }
                    TimeStep { value: card.sch.from; onChanged: v => root.fc.updateSchedule(card.sch.id, { from: v }) }
                    StyledText { anchors.verticalCenter: parent.verticalCenter; text: "to"; font.pixelSize: Config.Appearance.fs(12); color: Config.Appearance.ink3 }
                    TimeStep { value: card.sch.to; onChanged: v => root.fc.updateSchedule(card.sch.id, { to: v }) }
                }

                Row {
                    spacing: 4
                    Repeater {
                        model: 7
                        Rectangle {
                            id: dayChip
                            required property int index
                            readonly property int day: (index + 1) % 7   // Monday first
                            readonly property bool on: (card.sch.days || []).indexOf(day) >= 0
                            width: 34; height: 26; radius: 13
                            color: on ? Config.Appearance.accent : (dayHover.hovered ? Config.Appearance.hover : Config.Appearance.sel)
                            StyledText {
                                anchors.centerIn: parent
                                text: ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"][dayChip.day]
                                font.pixelSize: Config.Appearance.fs(11)
                                font.weight: Font.DemiBold
                                color: dayChip.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                            }
                            HoverHandler { id: dayHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    const days = card.sch.days || [];
                                    root.fc.updateSchedule(card.sch.id, {
                                        days: dayChip.on ? days.filter(d => d !== dayChip.day) : days.concat([dayChip.day]).sort()
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Rectangle {
        width: addText.implicitWidth + 28
        height: 30
        radius: 15
        color: addHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
        Row {
            anchors.centerIn: parent
            spacing: 6
            MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: "plus"; size: 13; inkColor: Config.Appearance.ink; monochrome: true }
            StyledText { id: addText; anchors.verticalCenter: parent.verticalCenter; text: "Add quiet hours"; font.pixelSize: Config.Appearance.fs(12); font.weight: Font.DemiBold }
        }
        HoverHandler { id: addHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: root.fc.addSchedule() }
    }

    // ── apps ──────────────────────────────────────────────────────────────
    Item { width: 1; height: 6 }
    StyledText {
        text: "Apps"
        font.pixelSize: Config.Appearance.fs(13)
        font.weight: Font.DemiBold
    }
    StyledText {
        width: parent.width
        wrapMode: Text.Wrap
        text: "Always: a banner even while quiet. Silent: no banner, kept in the center. "
              + "Mute: neither — only the history keeps it."
        font.pixelSize: Config.Appearance.fs(11.5)
        color: Config.Appearance.ink3
    }
    StyledText {
        visible: root.fc.apps.length === 0
        text: "Apps show up here once they have sent a notification."
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }
    Repeater {
        model: root.fc.apps
        Item {
            id: appRow
            required property string modelData
            width: root.width
            height: 38
            HoverHandler { id: appHover }
            StyledText {
                anchors.left: parent.left
                anchors.right: seg.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: appRow.modelData
                font.pixelSize: Config.Appearance.fs(12.5)
            }
            Segmented {
                id: seg
                anchors.right: forget.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                segmentPadding: 10
                options: [{ label: "Always", value: "always" }, { label: "Normal", value: "normal" },
                          { label: "Silent", value: "silent" }, { label: "Mute", value: "mute" }]
                value: root.fc.rule(appRow.modelData)
                onSelected: v => root.fc.setRule(appRow.modelData, v)
            }
            Round {
                id: forget
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                opacity: appHover.hovered ? 1 : 0
                icon: "x"
                onClicked: root.fc.forgetApp(appRow.modelData)
            }
        }
    }
}
