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

        readonly property real barH: bar.u(Config.Appearance.barHeight)
        implicitHeight: barH

        // ── getting out of the way ────────────────────────────────────
        //
        // The same shape as the dock's auto-hide, upside down. The
        // surface stays the bar's height and the bar slides *within* it;
        // the hidden position is above the surface's own top edge, and
        // nothing renders past that, which is what makes it disappear.
        //
        // Hysteresis for the same reason as the dock: revealing on hover
        // alone fights itself. The pointer reaches the strip, the bar
        // slides down from under it, the pointer is no longer on the
        // strip, and it slides back. So hovering latches it open and only
        // a moment away from the surface closes it.
        property bool hoverLatch: false
        readonly property bool hoveredNow: barHover.hovered

        onHoveredNowChanged: {
            if (hoveredNow) {
                hideDelay.stop();
                // Already out: stays out. Hidden: only once the pointer
                // has rested on the edge a moment — passing over the top
                // of the screen on the way to a tab or a menu is not a
                // request for the bar.
                if (hoverLatch || Config.Appearance.barRevealDelay <= 0) hoverLatch = true;
                else revealDelay.restart();
            } else {
                revealDelay.stop();
                hideDelay.restart();
            }
        }

        Timer {
            id: revealDelay
            interval: Math.max(1, Config.Appearance.barRevealDelay)
            onTriggered: if (bar.hoveredNow) bar.hoverLatch = true;
        }

        Timer {
            id: hideDelay
            interval: 420
            onTriggered: if (!bar.hoveredNow) bar.hoverLatch = false;
        }

        // A panel hangs off the bar, so the bar has to still be there
        // while one is open — otherwise opening the calendar takes away
        // the clock it came out of, and the panel is left floating with
        // a gap where the bar was.
        //
        // Only on the screen the panels are actually on: the flags are
        // global, and without this every bar on every monitor came out
        // when a dropdown opened on one of them.
        readonly property bool onFocusedScreen:
            Services.Compositor.isFocusedScreen(modelData)
        readonly property bool panelHere:
            Config.UiState.anyPanelOpen && onFocusedScreen

        // With the dock hidden as well there is nothing on screen at all
        // while the launcher is up, so the bar comes out with it — on the
        // launcher's screen — and goes when it closes.
        readonly property bool launcherHere: Config.UiState.launcherOpen
                                             && Config.Appearance.dockAutoHide
                                             && onFocusedScreen

        readonly property bool revealed: !Config.Appearance.barAutoHide
                                         || hoverLatch
                                         || panelHere
                                         || launcherHere

        // Where the bar sits inside its surface. Hidden is one bar-height
        // up, which is out.
        property real barPos: revealed ? 0 : -barH
        Behavior on barPos {
            NumberAnimation {
                duration: Config.Appearance.anim(240)
                easing.type: Easing.OutCubic
            }
        }

        // Explicit, for the same reason as the dock: three anchors would
        // otherwise let Auto decide, and the zone this reserves should be
        // the number this bar is, not a guess from its geometry.
        exclusionMode: ExclusionMode.Normal
        // Nothing is reserved until the settings have been read — see the
        // long version of why on the dock. A bar that reserved its strip
        // on the strength of a default that is about to be contradicted
        // leaves the session offset for good.
        exclusiveZone: (!Config.Appearance.settingsReady
                        || Config.Appearance.barAutoHide)
                       ? 0 : barH

        // What takes clicks.
        //
        // Revealed: all of it. Hidden: a strip along the very top, which
        // is what the pointer lands on to bring it back — and nothing
        // else, or a band across the top of the screen would swallow
        // clicks meant for the window underneath. With auto-hide on there
        // is no exclusive zone, so there really is a window under there.
        mask: Region {
            x: 0
            y: 0
            width: bar.width
            height: bar.revealed ? bar.height : 3
        }

        HoverHandler { id: barHover }

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

        // Everything the bar draws, in one box that slides.
        //
        // The surface stays put and this moves inside it, so hiding
        // is one animated number rather than an anchor change on every
        // piece — and the pieces go on anchoring to each other exactly
        // as they did, because `parent` is still the full width of the
        // bar.
        Item {
            id: strip
            anchors.left: parent.left
            anchors.right: parent.right
            y: bar.barPos
            height: bar.barH

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
            }

            // ══ the middle ═══════════════════════════════════════════════════
            //
            // The window title and the task buttons used to sit at the end of
            // the left Row, capped by a guess at how much of the bar to leave
            // alone. Now that something is centred on the bar, the thing they
            // must not reach is the pill, and neither a Row nor a guess can
            // say where that is — so they are anchored between the left
            // cluster and the pill and given exactly what is left.
            //
            // The pill's own width comes from `room`, which reads the two
            // clusters and not these, so nothing here feeds back into it.
            readonly property real middleRoom: Math.max(0,
                (media.visible ? media.x : right.x) - (left.x + left.width) - 22)

            // Live window title, which is the other thing the mockup's
            // header area conveys ("~/dots" beside Terminal).
            StyledText {
                anchors.left: left.right
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: text !== "" && !Config.Appearance.showTasks
                width: Math.min(implicitWidth, strip.middleRoom)
                elide: Text.ElideRight
                text: Services.Compositor.activeTitle
                font.pixelSize: Config.Appearance.fs(bar.u(Config.Appearance.barTitleSize))
                font.weight: Font.Normal
                color: Config.Appearance.ink3
            }

            TaskButtons {
                anchors.left: left.right
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                visible: Config.Appearance.showTasks
                maxWidth: strip.middleRoom
            }

            // ══ what is playing ══════════════════════════════════════════════
            //
            // Centred on the bar itself rather than placed between the two
            // clusters, as in the mockup — a pill that drifted with the length
            // of the focused window's title would never be in the same place
            // twice. It is told how much room there is between them and gives
            // up its text, and then itself, rather than running underneath.
            MediaPill {
                id: media
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                barScale: bar.us
                // Centred, so what it has is the narrower of the two sides,
                // doubled. Neither cluster's width depends on the pill.
                room: bar.width - 2 * Math.max(left.x + left.width, right.width + 10) - 16
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

                // Recording the screen: a red dot and how long; click to stop.
                BarButton {
                    id: recPill
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Services.Capture.recording
                    spacing: 6
                    onActivated: Services.Capture.stopRecording()

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10; height: 10; radius: 5
                        color: "#e5484d"
                        SequentialAnimation on opacity {
                            running: recPill.visible
                            loops: Animation.Infinite
                            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
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
                            width: bar.u(Config.Appearance.barIconSize) + 8
                            height: width
                            radius: width / 2
                            color: Config.Appearance.accent
                            MonoIcon {
                                anchors.centerIn: parent
                                name: modelData[0]
                                size: bar.u(Config.Appearance.barIconSize) - 2
                                inkColor: Config.Appearance.inkOnAccent
                                monochrome: true
                            }
                        }
                    }
                }

                // A countdown, while a timer or the pomodoro runs: the one
                // that ends first. Paused, it stays, greyed.
                BarButton {
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
                        size: bar.u(Config.Appearance.barIconSize)
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
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Config.Appearance.updatesInBar && (Services.Updates.count > 0 || Services.Updates.rebootNeeded)
                    open: Config.UiState.updatesOpen
                    spacing: 5
                    onActivated: Config.UiState.toggleUpdates()

                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "package"
                        size: bar.u(Config.Appearance.barIconSize)
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
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Config.Appearance.mailInBar && Services.Mail.available
                    spacing: 5
                    onActivated: Services.Mail.open()

                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "mail"
                        size: bar.u(Config.Appearance.barIconSize)
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
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Services.Usb.drives.length > 0
                    open: Config.UiState.drivesOpen
                    onActivated: Config.UiState.toggleDrives()

                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "drive"
                        size: bar.u(Config.Appearance.barIconSize)
                        inkColor: Config.Appearance.ink
                        monochrome: true
                    }
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
                        name: Services.Focus.quiet ? "bellOff" : "bell"
                        size: bar.u(Config.Appearance.barIconSize)
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
}
