import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Session menu. Every entry runs a real session action: hyprlock for the
// screen, `hyprctl dispatch exit` to end the Wayland session, and systemd's
// loginctl for suspend/reboot/power off.
PanelSurface {
    id: root

    readonly property var entries: [
        { n: "Lock",       k: "super L",   icon: "lock",    run: () => Config.UiState.lock() },
        { n: "Suspend",    k: "",          icon: "moon",    run: () => Services.Session.suspend() },
        { n: "Log out",    k: "super ⇧ E", icon: "logOut",  run: () => Services.Session.logout() },
        { n: "Restart",    k: "",          icon: "reboot",  run: () => Services.Session.reboot() },
        { n: "Power off",  k: "",          icon: "power",   run: () => Services.Session.powerOff() }
    ]

    implicitWidth: 248
    implicitHeight: 14 + 24 + entries.length * 43 + 8 + 30

    // ── heading ───────────────────────────────────────────────────────────
    Item {
        id: heading
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 12
        height: 24

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: "Session"
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.9
            color: Config.Appearance.ink2
        }

        StyledText {
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: Services.SysInfo.user
            font.pixelSize: 11
            font.weight: Font.Normal
            color: Config.Appearance.ink3
        }
    }

    // ── entries ───────────────────────────────────────────────────────────
    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: heading.bottom
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        spacing: 1

        Repeater {
            model: root.entries

            Item {
                id: entry
                required property var modelData
                width: parent.width
                height: 42

                Rectangle {
                    anchors.fill: parent
                    radius: Config.Appearance.rSm
                    color: entryHover.hovered ? Config.Appearance.hover : "transparent"
                    Behavior on color { ColorAnimation { duration: 120 } }
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 10

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 26
                        height: 26
                        radius: Config.Appearance.rSm
                        color: Config.Appearance.hover
                        border.width: 1
                        border.color: Config.Appearance.rule

                        MonoIcon {
                            anchors.centerIn: parent
                            name: entry.modelData.icon
                            size: 14
                            inkColor: entryHover.hovered ? Config.Appearance.accent : Config.Appearance.ink2
                            monochrome: true
                        }
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: entry.modelData.n
                        font.pixelSize: 13
                    }
                }

                StyledText {
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: entry.modelData.k
                    font.pixelSize: 11
                    font.weight: Font.Normal
                    color: Config.Appearance.ink3
                }

                HoverHandler { id: entryHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        Config.UiState.closeAll();
                        entry.modelData.run();
                    }
                }
            }
        }
    }

    // ── footer ────────────────────────────────────────────────────────────
    Item {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 30

        Rectangle {
            anchors.top: parent.top
            width: parent.width
            height: 1
            color: Config.Appearance.rule
        }

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: "Uptime " + Services.SysInfo.uptimeLabel
            font.pixelSize: 11
            font.weight: Font.Normal
            color: Config.Appearance.ink3
        }

        StyledText {
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            text: Services.SysInfo.compositorVersion
                  ? "Hyprland " + Services.SysInfo.compositorVersion : "Hyprland"
            font.pixelSize: 11
            font.weight: Font.Normal
            color: Config.Appearance.ink3
        }
    }
}
