import QtQuick
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Notifications
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// One notification card, shared by the notification center and the banner
// toasts. Icon plate, app name and stamp, summary, body, the sender's own
// action buttons, and a close affordance.
Rectangle {
    id: root

    required property var notification
    property bool showActions: true

    readonly property var actions: notification ? Services.Notifications.buttonActions(notification) : []
    readonly property bool urgent: notification && notification.urgency === NotificationUrgency.Critical
    readonly property bool hasImage: notification && notification.image !== ""
    // The spec's app_icon is an icon-theme name, not a path.
    readonly property string appIconSource:
        notification ? Config.Apps.themeIcon(notification.appIcon) : ""

    radius: Config.Appearance.rCard
    color: hover.hovered ? Config.Appearance.sel : Config.Appearance.hover
    Behavior on color { ColorAnimation { duration: Config.Appearance.anim(120) } }

    implicitHeight: body.implicitHeight + 24

    // Critical notifications get an accent rail rather than a different
    // background, so the card stays legible in both themes.
    Rectangle {
        visible: root.urgent
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.margins: 6
        width: 2
        radius: 1
        color: Config.Appearance.accent
    }

    Row {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 12
        spacing: 12

        // Icon plate: the sender's image if it sent one, its app icon if the
        // theme has it, otherwise a pack glyph chosen from the app name.
        Rectangle {
            width: 30
            height: 30
            radius: 9
            color: Config.Appearance.sel
            clip: true

            IconImage {
                anchors.fill: parent
                visible: root.hasImage
                source: root.hasImage ? root.notification.image : ""
            }

            IconImage {
                anchors.centerIn: parent
                width: 16
                height: 16
                visible: !root.hasImage && root.appIconSource !== ""
                source: root.appIconSource
            }

            MonoIcon {
                anchors.centerIn: parent
                visible: !root.hasImage && root.appIconSource === ""
                name: Services.Notifications.iconFor(root.notification)
                size: 15
                inkColor: Config.Appearance.ink
                accentColor: Config.Appearance.accent
            }
        }

        Column {
            width: parent.width - 30 - 12 - 22 - 12
            spacing: 5

            Item {
                width: parent.width
                height: appName.implicitHeight

                StyledText {
                    id: appName
                    anchors.left: parent.left
                    anchors.right: stamp.left
                    anchors.rightMargin: 10
                    elide: Text.ElideRight
                    text: Services.Notifications.appNameOf(root.notification)
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.DemiBold
                }

                StyledText {
                    id: stamp
                    anchors.right: parent.right
                    anchors.baseline: appName.baseline
                    text: root.notification
                          ? Services.Notifications.relativeTime(
                                Services.Notifications.timeOf(root.notification))
                          : ""
                    font.pixelSize: Config.Appearance.fs(11)
                    font.weight: Font.Normal
                    color: Config.Appearance.ink3
                }
            }

            StyledText {
                width: parent.width
                visible: text !== ""
                text: root.notification ? root.notification.summary : ""
                font.pixelSize: Config.Appearance.fs(13)
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                visible: text !== ""
                text: root.notification ? root.notification.body : ""
                font.pixelSize: Config.Appearance.fs(13)
                font.weight: Font.Normal
                color: Config.Appearance.ink2
                wrapMode: Text.WordWrap
                maximumLineCount: 5
                elide: Text.ElideRight
                // The server advertises body markup, so senders may use the
                // small HTML subset the spec allows.
                textFormat: Text.StyledText
            }

            // The sender's own actions.
            Row {
                visible: root.showActions && root.actions.length > 0
                spacing: 6
                topPadding: 4

                Repeater {
                    model: root.actions

                    Rectangle {
                        id: actionBtn
                        required property var modelData
                        required property int index

                        width: actionLabel.implicitWidth + 24
                        height: 30
                        radius: Config.Appearance.rPill
                        // First action is the primary one, like the mockup's
                        // "Upgrade" against "Later".
                        color: index === 0 ? Config.Appearance.accent : Config.Appearance.sel
                        opacity: actionHover.hovered ? 0.88 : 1

                        StyledText {
                            id: actionLabel
                            anchors.centerIn: parent
                            text: actionBtn.modelData.text
                            font.pixelSize: Config.Appearance.fs(11)
                            font.weight: Font.DemiBold
                            color: actionBtn.index === 0 ? Config.Appearance.inkOnAccent : Config.Appearance.ink
                        }

                        HoverHandler { id: actionHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: Services.Notifications.invoke(root.notification, actionBtn.modelData)
                        }
                    }
                }
            }
        }

        // Close
        Rectangle {
            width: 22
            height: 22
            radius: 7
            color: closeHover.hovered ? Config.Appearance.sel : "transparent"

            MonoIcon {
                anchors.centerIn: parent
                name: "x"
                size: 13
                inkColor: Config.Appearance.ink3
                monochrome: true
            }

            HoverHandler { id: closeHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: Services.Notifications.dismiss(root.notification) }
        }
    }

    HoverHandler { id: hover }

    TapHandler {
        // Clicking the card runs the sender's default action, if it has one.
        onTapped: Services.Notifications.activate(root.notification)
    }
}
