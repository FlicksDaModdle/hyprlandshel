import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.UPower
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The top bar. Left: workspaces, the focused app and its window menu, and
// (optionally) task buttons. Right: system tray, notification bell, the
// status capsule that opens the control center, the clock that opens the
// calendar, and the power button.
//
// Every dropdown it owns lives in PanelLayer — the bar only flips UiState,
// so a panel can outlive a bar relayout and can't be clipped by the bar's
// own height.
//
// One bar per monitor, each showing that monitor's own workspaces.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: bar
        required property var modelData

        // Variants applies modelData after this binding is first evaluated,
        // so it sees undefined once on the way up. null is the same thing to
        // setScreen (use the default) and doesn't warn; the binding
        // re-evaluates to the real screen the moment modelData lands.
        // ...and nothing is drawn until it is a real one. `?? null` means
        // "the default screen" to setScreen, so during an output change —
        // plugging a monitor in, or changing a scale, which makes Hyprland
        // re-enumerate — a surface whose modelData has momentarily gone
        // would land on the default output instead. Two bars on one monitor
        // is what that looks like from the outside.
        readonly property bool hasScreen: !!modelData
        visible: hasScreen

        // What this output's shell is scaled to, relative to the rest.
        //
        // A layer-shell surface is specified in logical pixels, so the
        // compositor's own scale multiplies everything on that output —
        // the shell along with the applications. Running a laptop panel at
        // a scale that makes applications legible therefore makes the bar
        // large to match, and there was no way to say otherwise. This is
        // the shell's correction, per output: a 150% laptop can carry an
        // 85% bar while the monitor beside it stays at 100.
        //
        // Applied to the numbers rather than by scaling the whole bar with
        // a transform, which would resample the text.
        readonly property real us:
            Config.Appearance.screenScale(modelData ? modelData.name : "")
        function u(px) { return Math.max(1, Math.round(px * us)); }

        screen: modelData ?? null
        color: "transparent"

        anchors.top: true
        anchors.left: true
        anchors.right: true

        implicitHeight: bar.u(Config.Appearance.barHeight)
        // Explicit, for the same reason as the dock: three anchors would
        // otherwise let Auto decide, and the zone this reserves should be
        // the number this bar is, not a guess from its geometry.
        exclusionMode: ExclusionMode.Normal
        exclusiveZone: bar.u(Config.Appearance.barHeight)

        WlrLayershell.namespace: "quickshell:bar"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        readonly property var battery: UPower.displayDevice
        readonly property bool hasBattery: !!battery && battery.isLaptopBattery && battery.isPresent
        readonly property int batteryPercent: hasBattery ? Math.round(battery.percentage * 100) : 0
        readonly property bool charging: hasBattery
            && (battery.state === UPowerDeviceState.Charging || battery.state === UPowerDeviceState.FullyCharged)

        SystemClock {
            id: clock
            precision: SystemClock.Minutes
        }

        readonly property string timeText: Qt.formatDateTime(
            clock.date, Config.Appearance.clock24 ? "HH:mm" : "h:mm AP")
        readonly property string dateText: Qt.formatDateTime(clock.date, "ddd d MMM")

        // ── surface ───────────────────────────────────────────────────────
        Rectangle {
            anchors.fill: parent
            color: Config.Appearance.panel

            // Hairline edge plus the accent seam glow the mockup puts under
            // the bar.
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: Config.Appearance.edge
            }
            Rectangle {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: -1
                width: parent.width
                height: 1
                color: Config.Appearance.seam
            }
        }

        // ══ left cluster ═════════════════════════════════════════════════
        Row {
            id: left
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            Workspaces {
                barScale: bar.us
                anchors.verticalCenter: parent.verticalCenter
            }

            // Divider
            Item {
                width: 15
                height: 18
                anchors.verticalCenter: parent.verticalCenter
                Rectangle {
                    anchors.centerIn: parent
                    width: 1
                    height: 18
                    color: Config.Appearance.div
                }
            }

            // Focused app, with the accent underline from the mockup.
            Item {
                anchors.verticalCenter: parent.verticalCenter
                width: appName.implicitWidth + 20
                height: 26

                StyledText {
                    id: appName
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: -1
                    text: Services.Compositor.activeClass || "Desktop"
                    font.pixelSize: Config.Appearance.fs(bar.u(Config.Appearance.barAppSize))
                    font.weight: Font.Bold
                    font.letterSpacing: 0.16
                    color: Config.Appearance.ink
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 3
                    height: 2
                    radius: 1
                    color: Config.Appearance.accent
                    visible: Services.Compositor.activeClient !== null
                }
            }

            // Stands where the mockup's per-app menu bar does; see
            // WindowMenuButton.qml for why it carries window actions instead
            // of File/Edit/View. The menu itself is drawn by PanelLayer.
            WindowMenuButton {
                anchors.verticalCenter: parent.verticalCenter
                barWindow: bar
            }

            // Live window title, which is the other thing the mockup's
            // header area conveys ("~/dots" beside Terminal).
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: text !== "" && !Config.Appearance.showTasks
                width: Math.min(implicitWidth, Math.max(0, bar.width - left.x - right.width - 420))
                elide: Text.ElideRight
                text: Services.Compositor.activeTitle
                font.pixelSize: Config.Appearance.fs(bar.u(Config.Appearance.barTitleSize))
                font.weight: Font.Normal
                color: Config.Appearance.ink3
            }

            TaskButtons {
                anchors.verticalCenter: parent.verticalCenter
                visible: Config.Appearance.showTasks
                maxWidth: Math.max(0, bar.width - 560)
            }
        }

        // ══ right cluster ════════════════════════════════════════════════
        Row {
            id: right
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            TrayRow {
                anchors.verticalCenter: parent.verticalCenter
                barWindow: bar
            }

            // Notifications
            BarButton {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 7
                open: Config.UiState.notificationsOpen
                onActivated: Config.UiState.toggleNotifications()
                onSecondaryActivated: Services.Notifications.toggleDnd()

                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: Config.Appearance.dnd ? "bellOff" : "bell"
                    size: bar.u(Config.Appearance.barIconSize)
                    inkColor: Config.Appearance.dnd ? Config.Appearance.ink3 : Config.Appearance.ink
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
                        font.pixelSize: Config.Appearance.fs(bar.u(Config.Appearance.barBadgeSize))
                        font.weight: Font.Bold
                        color: Config.Appearance.inkOnAccent
                    }
                }
            }

            // Status capsule → control center
            BarButton {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 13
                padding: 12
                open: Config.UiState.controlCenterOpen
                onActivated: Config.UiState.toggleControlCenter()
                onScrolled: delta => Services.Audio.step(delta * 0.05)

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: Services.Network.icon
                        size: bar.u(Config.Appearance.barIconSize)
                        inkColor: Config.Appearance.ink
                        monochrome: true
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Services.Network.label
                        font.pixelSize: Config.Appearance.barFs(0)
                        color: Config.Appearance.ink2
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, 120)
                    }
                }

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: Services.Audio.icon
                        size: bar.u(Config.Appearance.barIconSize)
                        inkColor: Config.Appearance.ink
                        monochrome: true
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Services.Audio.muted ? "muted" : Services.Audio.volumePercent + "%"
                        font.pixelSize: Config.Appearance.barFs(0)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink2
                    }
                }

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    visible: bar.hasBattery

                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16

                        MonoIcon {
                            anchors.fill: parent
                            name: bar.charging ? "batteryCharging" : "battery"
                            size: bar.u(Config.Appearance.barIconSize)
                            inkColor: Config.Appearance.ink
                        }

                        // Real fill level, sized to sit inside the battery
                        // outline: the glyph's body is rrect(2.5,7.5,16.5,9)
                        // on the 24-grid, which at 16px leaves roughly 9px of
                        // interior once the 2px stroke is accounted for.
                        Rectangle {
                            visible: !bar.charging
                            x: 2.8
                            y: 6.2
                            height: 3.6
                            width: Math.max(1, 9.0 * bar.batteryPercent / 100)
                            radius: 1
                            color: bar.batteryPercent <= 15 ? Config.Appearance.accent : Config.Appearance.ink
                        }
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: bar.batteryPercent + "%"
                        font.pixelSize: Config.Appearance.barFs(0)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink2
                    }
                }
            }

            // Clock → calendar
            BarButton {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 10
                padding: 12
                open: Config.UiState.calendarOpen
                onActivated: Config.UiState.toggleCalendar()

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: bar.timeText
                    font.pixelSize: Config.Appearance.fs(bar.u(Config.Appearance.barClockSize))
                    font.weight: Font.DemiBold
                    color: Config.Appearance.ink
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: bar.dateText
                    font.pixelSize: Config.Appearance.barFs(0)
                    color: Config.Appearance.ink2
                }
            }

            // Power menu
            BarButton {
                anchors.verticalCenter: parent.verticalCenter
                padding: 5
                open: Config.UiState.powerOpen
                accentWhenOpen: true
                onActivated: Config.UiState.togglePower()

                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "power"
                    size: bar.u(Config.Appearance.barIconSize)
                    inkColor: Config.UiState.powerOpen ? Config.Appearance.inkOnAccent : Config.Appearance.ink
                    monochrome: true
                }
            }
        }
    }
}
