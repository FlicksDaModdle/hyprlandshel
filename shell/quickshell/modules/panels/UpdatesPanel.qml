import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Pending updates (services/Updates.qml): how many, how big, which, and
// Update now. Opened from the bar's package button or "Updates" in the
// launcher.
PanelSurface {
    id: root

    readonly property var up: Services.Updates
    readonly property var groups: [
        { label: "Official", items: up.items.filter(i => i.source === "repo") },
        { label: "AUR", items: up.items.filter(i => i.source === "aur") },
        { label: "Flatpak", items: up.items.filter(i => i.source === "flatpak") }
    ].filter(g => g.items.length > 0)

    implicitWidth: 380
    implicitHeight: Math.min(600, head.implicitHeight + listCol.implicitHeight + foot.implicitHeight + 40)

    Column {
        id: head
        x: 14; y: 12
        width: parent.width - 28
        spacing: 6

        Item {
            width: parent.width
            height: 28
            StyledText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Updates"
                font.pixelSize: Config.Appearance.fs(11)
                font.weight: Font.DemiBold
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.9
                color: Config.Appearance.ink2
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.up.checking ? "Checking…" : (root.up.checkedAt ? "Checked " + root.up.agoText() : "")
                    font.pixelSize: Config.Appearance.fs(11)
                    color: Config.Appearance.ink3
                }
                Rectangle {
                    width: 26; height: 26; radius: 13
                    color: refreshHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
                    MonoIcon {
                        anchors.centerIn: parent
                        name: "refresh"
                        size: 13
                        inkColor: Config.Appearance.ink
                        monochrome: true
                        RotationAnimation on rotation {
                            running: root.up.checking
                            loops: Animation.Infinite
                            from: 0; to: 360; duration: 900
                        }
                    }
                    HoverHandler { id: refreshHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.up.check() }
                }
            }
        }

        StyledText {
            width: parent.width
            wrapMode: Text.Wrap
            text: !root.up.haveCheckupdates ? "Install pacman-contrib to check for updates without a password (sudo pacman -S pacman-contrib)."
                : root.up.error !== "" ? "Could not check: " + root.up.error
                : root.up.count === 0 ? (root.up.checkedAt ? "Everything is up to date." : "Not checked yet.")
                : root.up.count + (root.up.count === 1 ? " update" : " updates")
                  + (root.up.totalSize > 0 ? " · " + root.up.sizeText(root.up.totalSize) + " to download" : "")
            font.pixelSize: Config.Appearance.fs(14)
            font.weight: Font.DemiBold
        }

        // Restarting: needed now, or after this update.
        Rectangle {
            visible: root.up.rebootNeeded || root.up.restartAfter
            width: parent.width
            height: rebootText.implicitHeight + 16
            radius: Config.Appearance.rSm
            color: Qt.rgba(Config.Appearance.accent.r, Config.Appearance.accent.g, Config.Appearance.accent.b, 0.14)
            StyledText {
                id: rebootText
                x: 10; y: 8
                width: parent.width - 20
                wrapMode: Text.Wrap
                text: root.up.rebootNeeded
                      ? "Restart to finish the last update — the kernel that is running has been replaced."
                      : "Includes a new kernel (" + root.up.kernelUpdates.map(k => k.name).join(", ")
                        + "): restart afterwards to use it."
                font.pixelSize: Config.Appearance.fs(11.5)
                color: Config.Appearance.ink
            }
        }
    }

    Flickable {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: head.bottom
        anchors.topMargin: 8
        anchors.bottom: foot.top
        anchors.bottomMargin: 8
        contentHeight: listCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: listCol
            x: 14
            width: parent.width - 28
            spacing: 2

            Repeater {
                model: root.groups
                Column {
                    id: grp
                    required property var modelData
                    width: listCol.width
                    spacing: 2
                    StyledText {
                        text: grp.modelData.label + " · " + grp.modelData.items.length
                        font.pixelSize: Config.Appearance.fs(10.5)
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 0.8
                        color: Config.Appearance.ink3
                        topPadding: 6
                        bottomPadding: 2
                    }
                    Repeater {
                        model: grp.modelData.items
                        Item {
                            id: pkg
                            required property var modelData
                            width: listCol.width
                            height: 34
                            Column {
                                anchors.left: parent.left
                                anchors.right: sizeLabel.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                StyledText {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: pkg.modelData.name
                                    font.pixelSize: Config.Appearance.fs(12)
                                    font.weight: root.up.isKernel(pkg.modelData.name) && pkg.modelData.source === "repo"
                                                 ? Font.DemiBold : Font.Normal
                                }
                                StyledText {
                                    width: parent.width
                                    elide: Text.ElideMiddle
                                    text: pkg.modelData.from ? pkg.modelData.from + "  →  " + pkg.modelData.to : pkg.modelData.to
                                    font.pixelSize: Config.Appearance.fs(10.5)
                                    color: Config.Appearance.ink3
                                }
                            }
                            StyledText {
                                id: sizeLabel
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.up.sizeText(pkg.modelData.size)
                                font.pixelSize: Config.Appearance.fs(11)
                                color: Config.Appearance.ink3
                            }
                        }
                    }
                }
            }
        }
    }

    Item {
        id: foot
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: 14
        implicitHeight: 34
        height: implicitHeight

        StyledText {
            anchors.left: parent.left
            anchors.right: updateBtn.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            wrapMode: Text.Wrap
            text: root.up.updating ? "Updating in a terminal…"
                : root.up.aurHelper ? "Runs " + root.up.aurHelper + " -Syu in a terminal"
                : "Runs sudo pacman -Syu in a terminal"
            font.pixelSize: Config.Appearance.fs(11)
            color: Config.Appearance.ink3
        }
        Rectangle {
            id: updateBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: updateText.implicitWidth + 28
            height: 32
            radius: 16
            opacity: root.up.count > 0 && !root.up.updating ? 1 : 0.45
            color: Config.Appearance.accent
            StyledText {
                id: updateText
                anchors.centerIn: parent
                text: "Update now"
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                color: Config.Appearance.inkOnAccent
            }
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { enabled: root.up.count > 0 && !root.up.updating; onTapped: root.up.updateNow() }
        }
    }
}
