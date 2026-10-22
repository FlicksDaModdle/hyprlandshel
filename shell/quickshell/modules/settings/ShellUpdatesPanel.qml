import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Updates (services/ShellUpdates.qml): each installed part of
// Hyprshell, whether GitHub has anything new for it, what, and a button
// that puts it in — in a terminal, since installers ask for your password.
// Looked at when the pane opens and when asked; nothing updates by itself.
Column {
    id: root

    readonly property var up: Services.ShellUpdates
    width: parent ? parent.width : 560
    spacing: 12

    Component.onCompleted: root.up.check()

    // ── where it stands ───────────────────────────────────────────────
    Rectangle {
        width: root.width
        height: 64
        radius: Config.Appearance.r
        color: Config.Appearance.hover

        MonoIcon {
            id: statusIcon
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            name: root.up.error !== "" ? "alert" : root.up.pending > 0 ? "download" : "check"
            size: 22
            inkColor: root.up.error !== "" ? Config.Appearance.ink2 : Config.Appearance.ink
            accentColor: Config.Appearance.accent
        }
        Column {
            anchors.left: statusIcon.right
            anchors.leftMargin: 12
            anchors.right: buttons.left
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            StyledText {
                width: parent.width
                elide: Text.ElideRight
                text: root.up.checking ? "Looking for updates…"
                    : root.up.error !== "" ? "Couldn't look for updates"
                    : root.up.checkedAt === 0 ? "Not looked yet"
                    : root.up.pending === 0 ? "Everything is up to date"
                    : root.up.pending === 1 ? "An update for one part"
                    : "Updates for " + root.up.pending + " parts"
                font.pixelSize: Config.Appearance.fs(13.5)
                font.weight: Font.DemiBold
                color: Config.Appearance.ink
            }
            StyledText {
                width: parent.width
                elide: Text.ElideRight
                text: root.up.error !== "" ? root.up.error
                    : root.up.branch !== "" ? "From GitHub, " + root.up.branch.replace(/^origin\//, "")
                      + (root.up.checkedAt > 0 ? " · looked " + Qt.formatTime(new Date(root.up.checkedAt), "hh:mm") : "")
                    : ""
                font.pixelSize: Config.Appearance.fs(11)
                color: Config.Appearance.ink3
            }
        }
        Row {
            id: buttons
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8
            SettingsPillButton {
                label: root.up.checking ? "Looking…" : "Check now"
                icon: "refresh"
                active: !root.up.checking
                onClicked: root.up.check()
            }
            SettingsPillButton {
                visible: root.up.pending > 1
                label: "Update all"
                icon: "download"
                primary: true
                onClicked: root.up.update("all")
            }
        }
    }

    StyledText {
        visible: root.up.localChanges
        width: root.width
        wrapMode: Text.Wrap
        leftPadding: 4
        text: "Files in " + root.up.repo + " have been changed there. An update pulls only if they don't clash; commit or stash them first if it can't."
        font.pixelSize: Config.Appearance.fs(11.5)
        color: Config.Appearance.ink3
    }

    // ── each part ─────────────────────────────────────────────────────
    Rectangle {
        visible: root.up.parts.length > 0
        width: root.width
        height: partCol.implicitHeight
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        Column {
            id: partCol
            width: parent.width
            Repeater {
                model: root.up.parts
                Item {
                    id: part
                    required property var modelData
                    required property int index
                    readonly property bool behind: modelData.behind > 0
                    property bool open: false
                    width: partCol.width
                    height: head.height + (open && behind ? commitCol.implicitHeight + 12 : 0)
                    clip: true
                    Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                    Rectangle {
                        visible: part.index > 0
                        x: 16; width: parent.width - 32; height: 1
                        color: Config.Appearance.rule
                    }
                    Item {
                        id: head
                        width: parent.width
                        height: 60
                        Rectangle {
                            id: dot
                            anchors.left: parent.left
                            anchors.leftMargin: 18
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8; height: 8; radius: 4
                            color: part.behind ? Config.Appearance.accent : Config.Appearance.ink3
                            opacity: part.behind ? 1 : 0.5
                        }
                        Column {
                            anchors.left: dot.right
                            anchors.leftMargin: 14
                            anchors.right: actions.left
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 2
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: part.modelData.name
                                font.pixelSize: Config.Appearance.fs(13)
                                font.weight: Font.Medium
                                color: Config.Appearance.ink
                            }
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: part.behind
                                      ? (part.modelData.behind === 1 ? "1 change" : part.modelData.behind + " changes")
                                        + " · " + (part.modelData.commits.length ? part.modelData.commits[0].subject : "")
                                      : "Up to date · " + part.modelData.note
                                font.pixelSize: Config.Appearance.fs(11)
                                color: Config.Appearance.ink3
                            }
                        }
                        Row {
                            id: actions
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 6
                            SettingsPillButton {
                                visible: part.behind
                                label: part.open ? "Less" : "What's new"
                                onClicked: part.open = !part.open
                            }
                            SettingsPillButton {
                                visible: part.behind
                                label: part.modelData.root ? "Update (asks for your password)" : "Update"
                                icon: "download"
                                primary: true
                                onClicked: root.up.update(part.modelData.id)
                            }
                        }
                    }
                    // The changes, newest first.
                    Column {
                        id: commitCol
                        anchors.top: head.bottom
                        x: 40
                        width: parent.width - 56
                        spacing: 6
                        visible: part.open
                        Repeater {
                            model: part.modelData.commits
                            Row {
                                required property var modelData
                                width: commitCol.width
                                spacing: 8
                                StyledText {
                                    width: parent.width - when.width - 8
                                    elide: Text.ElideRight
                                    text: "• " + modelData.subject
                                    font.pixelSize: Config.Appearance.fs(11.5)
                                    color: Config.Appearance.ink2
                                }
                                StyledText {
                                    id: when
                                    text: modelData.when
                                    font.pixelSize: Config.Appearance.fs(11)
                                    color: Config.Appearance.ink3
                                }
                            }
                        }
                        StyledText {
                            visible: part.modelData.behind > part.modelData.commits.length
                            text: "and " + (part.modelData.behind - part.modelData.commits.length) + " more"
                            font.pixelSize: Config.Appearance.fs(11)
                            color: Config.Appearance.ink3
                        }
                    }
                }
            }
        }
    }

    StyledText {
        width: root.width
        wrapMode: Text.Wrap
        leftPadding: 4
        text: "Updating pulls the hyprshell folder from GitHub and runs that part's installer in a terminal, where it can ask for your password. Nothing updates by itself."
        font.pixelSize: Config.Appearance.fs(11)
        color: Config.Appearance.ink3
    }
}
