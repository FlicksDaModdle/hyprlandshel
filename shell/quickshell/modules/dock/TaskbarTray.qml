import QtQuick
import Quickshell
import Quickshell.Services.UPower
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"
import "../bar"

// The right end of the taskbar (Settings → Dock → Style → Taskbar): the top
// bar's status area, folded in the way Windows 11 has it — the tray, the
// shell's indicators while there's something to show (recording, privacy,
// timers, updates, mail, drives), quick settings as one button of icons,
// the time above the date, notifications, and the sliver at the very edge
// that shows the desktop.
//
// The indicators are the bar's own (modules/bar/Bar.qml), at the
// taskbar's button height; each panel they open rises from just above
// the taskbar (PanelLayer.panelY).
Row {
    id: tray

    required property var window          // the taskbar's PanelWindow
    property real us: 1
    function u(px) { return Math.max(1, Math.round(px * tray.us)); }
    readonly property real btnH: tray.u(40)

    spacing: tray.u(2)

    readonly property var battery: UPower.displayDevice
    readonly property bool hasBattery: !!battery && battery.isLaptopBattery && battery.isPresent
    readonly property int batteryPercent: hasBattery ? Math.round(battery.percentage * 100) : 0
    readonly property bool charging: hasBattery
        && (battery.state === UPowerDeviceState.Charging || battery.state === UPowerDeviceState.FullyCharged)

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    TrayRow {
        anchors.verticalCenter: parent.verticalCenter
        barWindow: tray.window
    }


        // Recording the screen: a red dot and how long; click to stop.
        BarButton {
            height: tray.btnH
            id: recPill
            anchors.verticalCenter: parent.verticalCenter
            visible: Services.Capture.recording
            spacing: 6
            onActivated: Services.Capture.stopRecording()

            Rectangle {
                id: recDot
                anchors.verticalCenter: parent.verticalCenter
                width: 10; height: 10; radius: 5
                color: "#e5484d"
                // Breathes: a slow spring pulled one way, then the other.
                property bool dim: false
                opacity: recBreath.value
                Spring { id: recBreath; to: recDot.dim ? 0.35 : 1; response: 1100; bounce: 0 }
                Timer {
                    running: recPill.visible
                    repeat: true
                    interval: 750
                    onTriggered: recDot.dim = !recDot.dim
                    onRunningChanged: if (!running) recDot.dim = false
                }
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: Services.Capture.clock(Services.Capture.recordedSeconds)
                font.pixelSize: Config.Appearance.barFs(0)
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
        }

        // The microphone, camera or screen in use: an accent pill
        // with one glyph for each, there only while something is.
        BarButton {
            height: tray.btnH
            id: privacyPill
            anchors.verticalCenter: parent.verticalCenter
            visible: Services.Privacy.any
            open: Config.UiState.privacyOpen
            spacing: 3
            onActivated: Config.UiState.togglePrivacy()

            Repeater {
                model: [["mic", Services.Privacy.mic], ["camera", Services.Privacy.camera],
                        ["monitor", Services.Privacy.sharing]].filter(e => e[1])
                Rectangle {
                    required property var modelData
                    anchors.verticalCenter: parent.verticalCenter
                    width: tray.u(Config.Appearance.barIconSize) + 8
                    height: width
                    radius: width / 2
                    color: Config.Appearance.accent
                    MonoIcon {
                        anchors.centerIn: parent
                        name: modelData[0]
                        size: tray.u(Config.Appearance.barIconSize) - 2
                        inkColor: Config.Appearance.inkOnAccent
                        monochrome: true
                    }
                }
            }
        }

        // A countdown, while a timer or the pomodoro runs: the one
        // that ends first. Paused, it stays, greyed.
        BarButton {
            height: tray.btnH
            id: timerPill
            readonly property var tm: Services.Timers
            readonly property var s: tm.soonest
            anchors.verticalCenter: parent.verticalCenter
            visible: tm.anyActive || tm.anyPaused
            open: Config.UiState.timersOpen
            spacing: 6
            onActivated: Config.UiState.toggleTimers()

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: timerPill.s && timerPill.s.kind === "pomodoro" ? "pomodoro" : "timer"
                size: tray.u(Config.Appearance.barIconSize)
                inkColor: Config.Appearance.ink
                accentColor: Config.Appearance.accent
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: timerPill.s ? timerPill.tm.clock((timerPill.tm.now, (timerPill.s.endsAt - timerPill.tm.now) / 1000))
                                  : "paused"
                font.pixelSize: Config.Appearance.barFs(0)
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: timerPill.s ? Config.Appearance.ink : Config.Appearance.ink3
            }
        }

        // Updates waiting: the package glyph and how many.
        BarButton {
            height: tray.btnH
            anchors.verticalCenter: parent.verticalCenter
            visible: Config.Appearance.updatesInBar && (Services.Updates.count > 0 || Services.Updates.rebootNeeded)
            open: Config.UiState.updatesOpen
            spacing: 5
            onActivated: Config.UiState.toggleUpdates()

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "package"
                size: tray.u(Config.Appearance.barIconSize)
                inkColor: Config.Appearance.ink
                accentColor: Config.Appearance.accent
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: Services.Updates.count > 0
                text: Services.Updates.count
                font.pixelSize: Config.Appearance.barFs(0)
                font.weight: Font.DemiBold
            }
        }

        // Mail: unread in every inbox, while Mail's service runs.
        BarButton {
            height: tray.btnH
            anchors.verticalCenter: parent.verticalCenter
            visible: Config.Appearance.mailInBar && Services.Mail.available
            spacing: 5
            onActivated: Services.Mail.open()

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "mail"
                size: tray.u(Config.Appearance.barIconSize)
                inkColor: Config.Appearance.ink
                accentColor: Services.Mail.unread > 0 ? Config.Appearance.accent : Config.Appearance.ink
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: Services.Mail.unread > 0
                text: Services.Mail.unread > 99 ? "99+" : Services.Mail.unread
                font.pixelSize: Config.Appearance.barFs(0)
                font.weight: Font.DemiBold
            }
        }

        // Removable drives, while one is connected.
        BarButton {
            height: tray.btnH
            anchors.verticalCenter: parent.verticalCenter
            visible: Services.Usb.drives.length > 0
            open: Config.UiState.drivesOpen
            onActivated: Config.UiState.toggleDrives()

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "drive"
                size: tray.u(Config.Appearance.barIconSize)
                inkColor: Config.Appearance.ink
                monochrome: true
            }
        }

        // Quick settings: network, volume and battery as one button of
        // icons, as Windows 11 draws it; the control center opens above it.
        // Scrolling over it changes the volume.
        BarButton {
            height: tray.btnH
            anchors.verticalCenter: parent.verticalCenter
            spacing: tray.u(10)
            padding: tray.u(10)
            open: Config.UiState.controlCenterOpen
            onActivated: Config.UiState.toggleControlCenter()
            onScrolled: delta => Services.Audio.step(delta * 0.05)

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: Services.Network.icon
                size: tray.u(Config.Appearance.barIconSize)
                inkColor: Config.Appearance.ink
                monochrome: true
            }
            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: Services.Audio.icon
                size: tray.u(Config.Appearance.barIconSize)
                inkColor: Services.Audio.muted ? Config.Appearance.ink3 : Config.Appearance.ink
                monochrome: true
            }
            Item {
                visible: tray.hasBattery
                anchors.verticalCenter: parent.verticalCenter
                width: tray.u(Config.Appearance.barIconSize)
                height: width
                MonoIcon {
                    anchors.fill: parent
                    name: tray.charging ? "batteryCharging" : "battery"
                    size: parent.width
                    inkColor: Config.Appearance.ink
                }
                // The level inside the outline: the glyph's body is
                // rrect(2.5, 7.5, 16.5, 9) on its 24 grid.
                Rectangle {
                    visible: !tray.charging
                    readonly property real k: parent.width / 24
                    x: 4.2 * k
                    y: 9.3 * k
                    height: 5.4 * k
                    width: Math.max(1, 13.5 * k * tray.batteryPercent / 100)
                    radius: 1
                    color: tray.batteryPercent <= 15 ? Config.Appearance.accent : Config.Appearance.ink
                }
            }
        }

        // The time above the date, right-aligned; the calendar opens
        // above it.
        BarButton {
            height: tray.btnH
            anchors.verticalCenter: parent.verticalCenter
            padding: tray.u(10)
            open: Config.UiState.calendarOpen
            onActivated: Config.UiState.toggleCalendar()

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                StyledText {
                    anchors.right: parent.right
                    text: Qt.formatDateTime(clock.date, Config.Appearance.clock24 ? "HH:mm" : "h:mm AP")
                    font.pixelSize: Config.Appearance.fs(tray.u(12))
                    font.weight: Font.Medium
                    font.features: { "tnum": 1 }
                    color: Config.Appearance.ink
                }
                StyledText {
                    anchors.right: parent.right
                    // The locale's short date (5/11/2026, 11/5/2026, 2026-11-05).
                    text: Qt.formatDate(clock.date, Qt.locale().dateFormat(Locale.ShortFormat)
                                                    .replace(/\byy\b/, "yyyy"))
                    font.pixelSize: Config.Appearance.fs(tray.u(12))
                    font.features: { "tnum": 1 }
                    color: Config.Appearance.ink
                }
            }
        }

        // Notifications
        BarButton {
            height: tray.btnH
            anchors.verticalCenter: parent.verticalCenter
            spacing: 7
            open: Config.UiState.notificationsOpen
            onActivated: Config.UiState.toggleNotifications()
            onSecondaryActivated: Services.Notifications.toggleDnd()

            MonoIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: Services.Focus.quiet ? "bellOff" : "bell"
                size: tray.u(Config.Appearance.barIconSize)
                inkColor: Services.Focus.quiet ? Config.Appearance.ink3 : Config.Appearance.ink
                monochrome: true
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: Config.Appearance.badges && Services.Notifications.count > 0
                width: Math.max(17, badge.implicitWidth + 10)
                height: 17
                radius: 9
                color: Config.Appearance.accent

                StyledText {
                    id: badge
                    anchors.centerIn: parent
                    text: Services.Notifications.count
                    font.pixelSize: Config.Appearance.fs(tray.u(Config.Appearance.barBadgeSize))
                    font.weight: Font.Bold
                    color: Config.Appearance.inkOnAccent
                }
            }
        }

    // Show desktop: the sliver at the very edge, as on Windows.
    Item {
        anchors.verticalCenter: parent.verticalCenter
        width: tray.u(10)
        height: tray.window ? tray.window.panelBreadth : tray.u(48)
        Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: 1
            height: parent.height * 0.4
            color: Config.Appearance.rule
            visible: deskHover.hovered
        }
        HoverHandler { id: deskHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: Services.Compositor.toggleShowDesktop() }
    }
}
