import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// USB sticks and SD cards: each drive with its filesystems, Open (in
// Files) and Eject, and the two choices — mount on plug-in, and say so.
// Opened from the drive button the bar shows while one is connected.
PanelSurface {
    id: root

    readonly property var usb: Services.Usb

    implicitWidth: 320
    implicitHeight: col.implicitHeight + 24

    Column {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 12
        spacing: 8

        StyledText {
            text: "Drives"
            font.pixelSize: Config.Appearance.fs(11)
            font.weight: Font.DemiBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.9
            color: Config.Appearance.ink2
        }

        StyledText {
            visible: root.usb.drives.length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: root.usb.daemonHas ? "Nothing plugged in" : "Needs hyprshell-daemon (install.sh builds it with cargo)"
            font.pixelSize: Config.Appearance.fs(12)
            color: Config.Appearance.ink3
        }

        Repeater {
            model: root.usb.drives

            Rectangle {
                id: card
                required property var modelData
                readonly property var d: modelData
                readonly property bool busy: root.usb.ejecting[d.path] === true
                width: col.width
                height: cardCol.implicitHeight + 20
                radius: Config.Appearance.rSm
                color: Config.Appearance.hover

                Column {
                    id: cardCol
                    x: 12; y: 10
                    width: parent.width - 24
                    spacing: 6

                    Item {
                        width: parent.width
                        height: 30
                        MonoIcon {
                            id: dIcon
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            name: "drive"
                            size: 18
                            inkColor: Config.Appearance.ink
                            accentColor: Config.Appearance.accent
                        }
                        Column {
                            anchors.left: dIcon.right
                            anchors.leftMargin: 10
                            anchors.right: ejectBtn.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: card.d.name
                                font.pixelSize: Config.Appearance.fs(12.5)
                                font.weight: Font.DemiBold
                            }
                            StyledText {
                                text: card.busy ? "Ejecting…" : card.d.size
                                font.pixelSize: Config.Appearance.fs(11)
                                color: Config.Appearance.ink3
                            }
                        }
                        Rectangle {
                            id: ejectBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            width: ejectText.implicitWidth + 20
                            height: 26
                            radius: height / 2
                            opacity: card.busy ? 0.5 : 1
                            color: ejectHover.hovered ? Config.Appearance.accent : Config.Appearance.sel
                            StyledText {
                                id: ejectText
                                anchors.centerIn: parent
                                text: "Eject"
                                font.pixelSize: Config.Appearance.fs(11.5)
                                font.weight: Font.DemiBold
                                color: ejectHover.hovered ? Config.Appearance.inkOnAccent : Config.Appearance.ink
                            }
                            HoverHandler { id: ejectHover; cursorShape: Qt.PointingHandCursor }
                            MouseArea { anchors.fill: parent; enabled: !card.busy; onClicked: root.usb.eject(card.d) }
                        }
                    }

                    Repeater {
                        model: card.d.parts
                        Rectangle {
                            id: part
                            required property var modelData
                            readonly property var p: modelData
                            width: cardCol.width
                            height: 34
                            radius: Config.Appearance.rPill
                            color: partHover.hovered && !part.p.locked ? Config.Appearance.sel : "transparent"
                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: 10
                                anchors.right: openText.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: root.usb.label(card.d, part.p) + " · " + (part.p.locked ? "encrypted" : (part.p.fs || "unknown"))
                                      + (part.p.mount ? "" : " · not mounted")
                                font.pixelSize: Config.Appearance.fs(12)
                                color: part.p.locked ? Config.Appearance.ink3 : Config.Appearance.ink
                            }
                            StyledText {
                                id: openText
                                anchors.right: parent.right
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !part.p.locked
                                text: "Open"
                                font.pixelSize: Config.Appearance.fs(11.5)
                                font.weight: Font.DemiBold
                                color: Config.Appearance.accent
                            }
                            HoverHandler { id: partHover; cursorShape: part.p.locked ? Qt.ArrowCursor : Qt.PointingHandCursor }
                            MouseArea {
                                anchors.fill: parent
                                enabled: !part.p.locked
                                onClicked: { Config.UiState.drivesOpen = false; root.usb.open(part.p); }
                            }
                        }
                    }
                }
            }
        }

        StyledText {
            visible: root.usb.error !== ""
            width: parent.width
            wrapMode: Text.Wrap
            text: root.usb.error.charAt(0).toUpperCase() + root.usb.error.slice(1)
            font.pixelSize: Config.Appearance.fs(11.5)
            color: "#d93a2b"
        }

        Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

        Repeater {
            model: [
                { n: "Open on plug-in", s: "Mount a drive as soon as it is connected", get: () => Config.Appearance.usbAutomount,
                  set: v => Config.Appearance.usbAutomount = v },
                { n: "Tell me", s: "A notification with Open and Eject", get: () => Config.Appearance.usbNotify,
                  set: v => Config.Appearance.usbNotify = v }
            ]
            Item {
                required property var modelData
                width: col.width
                height: 36
                Column {
                    anchors.left: parent.left
                    anchors.right: tg.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText { text: modelData.n; font.pixelSize: Config.Appearance.fs(12) }
                    StyledText { text: modelData.s; font.pixelSize: Config.Appearance.fs(10.5); color: Config.Appearance.ink3; width: parent.width; elide: Text.ElideRight }
                }
                Toggle {
                    id: tg
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: modelData.get()
                    onToggled: on => modelData.set(on)
                }
            }
        }
    }
}
