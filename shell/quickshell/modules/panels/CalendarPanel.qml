import QtQuick
import Quickshell
import "../../config" as Config
import "../common"
import "../icons"

// Month calendar. Real dates, a real today marker, and arrows that page
// through months — the mockup's static September grid, made to work.
PanelSurface {
    id: root

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // Month being displayed, as an offset from the current one. Reset each
    // time the panel opens so it never comes back showing last March.
    property int monthOffset: 0
    onVisibleChanged: if (!visible) monthOffset = 0;

    readonly property date today: clock.date
    readonly property date shown: new Date(today.getFullYear(), today.getMonth() + monthOffset, 1)

    readonly property int shownYear: shown.getFullYear()
    readonly property int shownMonth: shown.getMonth()
    readonly property int daysInMonth: new Date(shownYear, shownMonth + 1, 0).getDate()
    readonly property int startWeekday: shown.getDay()      // 0 = Sunday

    readonly property var cells: {
        const out = [];
        for (let i = 0; i < startWeekday; i++) out.push({ day: 0, today: false });
        for (let d = 1; d <= daysInMonth; d++) {
            out.push({
                day: d,
                today: monthOffset === 0
                       && d === today.getDate()
                       && shownMonth === today.getMonth()
                       && shownYear === today.getFullYear()
            });
        }
        // Pad to whole weeks so the grid height doesn't jump between months.
        while (out.length % 7 !== 0) out.push({ day: 0, today: false });
        return out;
    }

    implicitWidth: 320
    implicitHeight: 14 + 34 + 10 + 24 + Math.ceil(cells.length / 7) * 36 + 14

    // ── header ────────────────────────────────────────────────────────────
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 12
        height: 34

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatDate(root.shown, "MMMM yyyy")
            font.pixelSize: 13
            font.weight: Font.DemiBold
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Repeater {
                model: [
                    { icon: "chevronLeft", delta: -1 },
                    { icon: "chevronRight", delta: 1 }
                ]

                Rectangle {
                    id: navBtn
                    required property var modelData
                    width: 26
                    height: 26
                    radius: Config.Appearance.rPill
                    color: navHover.hovered ? Config.Appearance.hover : "transparent"

                    MonoIcon {
                        anchors.centerIn: parent
                        name: navBtn.modelData.icon
                        size: 14
                        inkColor: Config.Appearance.ink2
                        monochrome: true
                    }

                    HoverHandler { id: navHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.monthOffset += navBtn.modelData.delta }
                }
            }
        }

        // Jump back to today by clicking the month name area when paged away.
        TapHandler {
            enabled: root.monthOffset !== 0
            onTapped: root.monthOffset = 0
        }
    }

    // ── grid ──────────────────────────────────────────────────────────────
    Grid {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.leftMargin: 14
        anchors.rightMargin: 14
        columns: 7
        spacing: 2

        readonly property real cellWidth: (width - spacing * 6) / 7

        Repeater {
            model: ["S", "M", "T", "W", "T", "F", "S"]

            Item {
                required property var modelData
                required property int index
                width: parent.cellWidth
                height: 24

                StyledText {
                    anchors.centerIn: parent
                    text: parent.modelData
                    font.pixelSize: 10.5
                    font.weight: Font.DemiBold
                    // Weekend columns sit back a step.
                    color: (parent.index === 0 || parent.index === 6)
                           ? Config.Appearance.div : Config.Appearance.ink3
                }
            }
        }

        Repeater {
            model: root.cells

            Rectangle {
                id: cell
                required property var modelData
                width: parent.cellWidth
                height: 34
                radius: 9
                color: modelData.today ? Config.Appearance.accent
                     : (modelData.day > 0 && cellHover.hovered ? Config.Appearance.hover : "transparent")
                Behavior on color { ColorAnimation { duration: 120 } }

                StyledText {
                    anchors.centerIn: parent
                    visible: cell.modelData.day > 0
                    text: cell.modelData.day
                    font.pixelSize: 12
                    color: cell.modelData.today ? Config.Appearance.onAccent : Config.Appearance.ink2
                }

                HoverHandler { id: cellHover; enabled: cell.modelData.day > 0 }
            }
        }
    }
}
