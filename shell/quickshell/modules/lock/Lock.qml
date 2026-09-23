import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pam
import Quickshell.Services.UPower
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Session lock. The mockup's lock screen, made real: this is a Wayland
// session-lock surface, so the compositor guarantees nothing behind it is
// visible and nothing else can take input while it's up — and the password
// field authenticates against PAM, so the only way past it is your actual
// password.
//
// The mockup's "Click anywhere to unlock" is the one thing deliberately not
// carried over.
WlSessionLock {
    id: lock

    locked: Config.UiState.locked

    // Every monitor gets its own surface.
    surface: WlSessionLockSurface {
        id: surface
        color: Config.Appearance.ground

        property string entered: ""
        property string status: ""
        property bool failed: false
        property bool busy: pam.active

        SystemClock {
            id: clock
            precision: SystemClock.Seconds
        }

        readonly property var battery: UPower.displayDevice
        readonly property bool hasBattery: !!battery && battery.isLaptopBattery && battery.isPresent

        PamContext {
            id: pam
            // `login` exists on every distribution; a dedicated
            // /etc/pam.d/hyprshell isn't required for this to work.
            config: "login"
            user: Services.SysInfo.user

            onResponseRequiredChanged: {
                if (responseRequired) respond(surface.entered);
            }

            onCompleted: result => {
                if (result === PamResult.Success) {
                    surface.entered = "";
                    surface.status = "";
                    surface.failed = false;
                    Config.UiState.locked = false;
                } else {
                    surface.failed = true;
                    surface.entered = "";
                    surface.status = result === PamResult.MaxTries
                                     ? "Too many attempts" : "Wrong password";
                    shake.restart();
                }
            }

            onError: err => {
                surface.failed = true;
                surface.status = "Authentication unavailable";
            }
        }

        function submit() {
            if (pam.active || entered.length === 0) return;
            status = "Checking…";
            failed = false;
            if (!pam.start()) {
                failed = true;
                status = "Could not start authentication";
            }
        }

        // ── ground ────────────────────────────────────────────────────────
        // Same tint as the desktop, so locking reads as the same system
        // rather than a different program taking over.
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0; color: Config.Appearance.tintSpec.a }
                GradientStop { position: 1; color: Config.Appearance.tintSpec.b }
            }
        }

        FocusScope {
            anchors.fill: parent
            focus: true

            Component.onCompleted: forceActiveFocus()

            Keys.onPressed: event => {
                if (surface.busy) { event.accepted = true; return; }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    surface.submit();
                } else if (event.key === Qt.Key_Backspace) {
                    surface.entered = surface.entered.slice(0, -1);
                    surface.status = "";
                } else if (event.key === Qt.Key_Escape) {
                    surface.entered = "";
                    surface.status = "";
                } else if (event.text.length > 0 && event.text.charCodeAt(0) >= 32) {
                    surface.entered += event.text;
                    surface.failed = false;
                    surface.status = "";
                }
                event.accepted = true;
            }

            Column {
                anchors.centerIn: parent
                spacing: 34

                // Clock
                Column {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 8

                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDateTime(clock.date,
                              Config.Appearance.clock24 ? "HH:mm" : "h:mm AP")
                        font.pixelSize: Config.Appearance.fs(116)
                        font.weight: Font.Bold
                        font.letterSpacing: -4
                        color: Config.Appearance.ink
                    }
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDate(clock.date, "dddd d MMMM yyyy")
                        font.pixelSize: Config.Appearance.fs(17)
                        color: Config.Appearance.ink2
                    }
                }

                // Auth card
                PanelSurface {
                    id: authCard
                    anchors.horizontalCenter: parent.horizontalCenter
                    showSeam: false
                    radius: 18
                    color: Config.Appearance.panel

                    width: 360
                    height: authColumn.implicitHeight + 52

                    transform: Translate { id: shakeShift }

                    // A wrong password nudges the card, the standard cue.
                    SequentialAnimation {
                        id: shake
                        NumberAnimation { target: shakeShift; property: "x"; to: 9;  duration: 45 }
                        NumberAnimation { target: shakeShift; property: "x"; to: -9; duration: 70 }
                        NumberAnimation { target: shakeShift; property: "x"; to: 5;  duration: 60 }
                        NumberAnimation { target: shakeShift; property: "x"; to: 0;  duration: 50 }
                    }

                    Column {
                        id: authColumn
                        anchors.centerIn: parent
                        spacing: 16

                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 70
                            height: 70
                            radius: 35
                            color: Config.Appearance.accent

                            MonoIcon {
                                anchors.centerIn: parent
                                name: "user"
                                size: 32
                                inkColor: Config.Appearance.inkOnAccent
                                monochrome: true
                            }
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: Services.SysInfo.user
                            font.pixelSize: Config.Appearance.fs(16)
                            font.weight: Font.DemiBold
                        }

                        // Password field
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 300
                            height: 44
                            radius: Config.Appearance.rCard
                            color: Config.Appearance.hover
                            border.width: 1
                            border.color: surface.failed ? Config.Appearance.accent : Config.Appearance.edge
                            clip: true
                            Behavior on border.color { ColorAnimation { duration: 160 } }

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.right: submitBtn.left
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideLeft
                                // Dots rather than the characters, at the
                                // tracking the mockup uses.
                                text: "•".repeat(Math.min(surface.entered.length, 24))
                                font.pixelSize: Config.Appearance.fs(18)
                                font.letterSpacing: 5
                                color: Config.Appearance.ink2
                            }

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                visible: surface.entered.length === 0
                                text: surface.busy ? "Checking…" : "Password"
                                font.pixelSize: Config.Appearance.fs(13)
                                font.weight: Font.Normal
                                color: Config.Appearance.ink3
                            }

                            Rectangle {
                                id: submitBtn
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                width: 44
                                color: Config.Appearance.accent
                                opacity: surface.entered.length > 0 && !surface.busy ? 1 : 0.5

                                MonoIcon {
                                    anchors.centerIn: parent
                                    name: "cornerDownLeft"
                                    size: 18
                                    inkColor: Config.Appearance.inkOnAccent
                                    monochrome: true
                                }

                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: surface.submit() }
                            }
                        }

                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            height: 14
                            text: surface.status || (pam.message && pam.messageIsError ? pam.message : "")
                            font.pixelSize: Config.Appearance.fs(12)
                            font.weight: Font.Normal
                            color: surface.failed ? Config.Appearance.accent : Config.Appearance.ink3
                        }
                    }
                }

                // Status strip — the things worth knowing without unlocking.
                Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 18

                    Row {
                        spacing: 7
                        visible: surface.hasBattery
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: surface.battery && surface.battery.state === UPowerDeviceState.Charging
                                  ? "batteryCharging" : "battery"
                            size: 15
                            inkColor: Config.Appearance.ink3
                            monochrome: true
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: surface.hasBattery
                                  ? Math.round(surface.battery.percentage * 100) + "%" : ""
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink3
                        }
                    }

                    Row {
                        spacing: 7
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: Services.Network.icon
                            size: 15
                            inkColor: Config.Appearance.ink3
                            monochrome: true
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Services.Network.label
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink3
                        }
                    }

                    Row {
                        spacing: 7
                        visible: Services.Notifications.count > 0
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "bell"
                            size: 15
                            inkColor: Config.Appearance.ink3
                            monochrome: true
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: Services.Notifications.count
                                  + (Services.Notifications.count === 1
                                     ? " notification" : " notifications")
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink3
                        }
                    }
                }
            }
        }
    }
}
