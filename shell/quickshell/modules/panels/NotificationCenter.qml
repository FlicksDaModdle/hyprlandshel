import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The notification center: everything the server is still holding, with the
// do-not-disturb and Clear controls from the mockup's header.
//
// Rows carry the sender's real actions as buttons, so "Upgrade" / "Later" in
// the mockup become whatever the sending application actually offered.
PanelSurface {
    id: root

    readonly property var groups: Services.Notifications.grouped
    readonly property bool empty: Services.Notifications.count === 0

    implicitWidth: 396
    implicitHeight: Math.min(560, header.height + Math.max(70, listColumn.implicitHeight + 14))

    // ── header ────────────────────────────────────────────────────────────
    Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 52

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            text: "Notifications"
            font.pixelSize: Config.Appearance.fs(13)
            font.weight: Font.DemiBold
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: dndRow.implicitWidth + 20
                height: 28
                radius: 9
                color: Config.Appearance.dnd ? Config.Appearance.accent
                     : (dndHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
                Behavior on color { ColorAnimation { duration: 140 } }

                Row {
                    id: dndRow
                    anchors.centerIn: parent
                    spacing: 7
                    MonoIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "moon"
                        size: 13
                        inkColor: Config.Appearance.dnd ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                        monochrome: true
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Do not disturb"
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.dnd ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                    }
                }

                HoverHandler { id: dndHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: Services.Notifications.toggleDnd() }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                visible: !root.empty
                width: clearLabel.implicitWidth + 20
                height: 28
                radius: 9
                color: clearHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
                Behavior on color { ColorAnimation { duration: 120 } }

                StyledText {
                    id: clearLabel
                    anchors.centerIn: parent
                    text: "Clear"
                    font.pixelSize: Config.Appearance.fs(11)
                    font.weight: Font.DemiBold
                    color: Config.Appearance.ink2
                }

                HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: Services.Notifications.clearAll() }
            }
        }
    }

    // ── list ──────────────────────────────────────────────────────────────
    Flickable {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        contentHeight: listColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: listColumn
            x: 12
            width: parent.width - 24
            spacing: 6

            Repeater {
                model: root.groups

                Column {
                    id: group
                    required property var modelData
                    width: listColumn.width
                    spacing: 6

                    // Group heading, only when grouping by app and the group
                    // actually stacks.
                    StyledText {
                        visible: Config.Appearance.grouping === "App" && group.modelData.entries.length > 1
                        text: group.modelData.app + " · " + group.modelData.entries.length
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.DemiBold
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 0.8
                        color: Config.Appearance.ink3
                        topPadding: 4
                    }

                    Repeater {
                        model: group.modelData.entries
                        NotificationRow {
                            required property var modelData
                            width: listColumn.width
                            notification: modelData
                        }
                    }
                }
            }

            Rectangle {
                visible: root.empty
                width: listColumn.width
                height: 74
                radius: Config.Appearance.rCard
                color: Config.Appearance.hover

                StyledText {
                    anchors.centerIn: parent
                    text: Config.Appearance.dnd ? "Do not disturb is on" : "No notifications"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
            }
        }
    }
}
