import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Notifications → Apps (services/Focus.qml): every app that has
// sent a notification, each with a switch. Off blocks it outright: nothing
// shown, nothing in the center, nothing kept in the history. On, it can be
// let through even while quiet (Always), or kept to the center without a
// banner (Silent).
Column {
    id: root

    readonly property var fc: Services.Focus
    width: parent ? parent.width : 560
    spacing: 10

    // The app's own icon, from its desktop entry, where one goes by its name.
    function entryFor(app) {
        const low = String(app).toLowerCase();
        const all = DesktopEntries.applications.values;
        return all.find(e => e.name.toLowerCase() === low)
            || all.find(e => e.id.toLowerCase() === low || e.id.toLowerCase().endsWith("." + low))
            || null;
    }

    StyledText {
        visible: root.fc.apps.length === 0
        width: parent.width
        wrapMode: Text.Wrap
        leftPadding: 4
        text: "Apps show up here once they have sent a notification."
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }

    Rectangle {
        visible: root.fc.apps.length > 0
        width: root.width
        height: appCol.implicitHeight
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        Column {
            id: appCol
            width: parent.width
            Repeater {
                model: root.fc.apps
                Item {
                    id: appRow
                    required property string modelData
                    required property int index
                    readonly property string rule: root.fc.rule(modelData)
                    readonly property bool allowed: rule !== "block" && rule !== "mute"
                    readonly property var entry: root.entryFor(modelData)
                    width: appCol.width
                    height: 56
                    HoverHandler { id: appHover }
                    Rectangle {
                        visible: appRow.index > 0
                        x: 16; width: parent.width - 32; height: 1
                        color: Config.Appearance.rule
                    }

                    // Its icon, or its initial on a tile.
                    Rectangle {
                        id: badge
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        width: 30; height: 30; radius: 8
                        color: icon.status === Image.Ready ? "transparent" : Config.Appearance.sel
                        opacity: appRow.allowed ? 1 : 0.45
                        Image {
                            id: icon
                            anchors.fill: parent
                            sourceSize: Qt.size(60, 60)
                            source: appRow.entry && appRow.entry.icon ? Quickshell.iconPath(appRow.entry.icon, true) : ""
                            fillMode: Image.PreserveAspectFit
                            smooth: true
                        }
                        StyledText {
                            anchors.centerIn: parent
                            visible: icon.status !== Image.Ready
                            text: appRow.modelData.charAt(0).toUpperCase()
                            font.pixelSize: Config.Appearance.fs(13)
                            font.weight: Font.DemiBold
                            color: Config.Appearance.ink2
                        }
                    }
                    Column {
                        anchors.left: badge.right
                        anchors.leftMargin: 12
                        anchors.right: seg.visible ? seg.left : toggle.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: appRow.modelData
                            font.pixelSize: Config.Appearance.fs(12.5)
                            font.weight: Font.Medium
                            color: appRow.allowed ? Config.Appearance.ink : Config.Appearance.ink3
                        }
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: !appRow.allowed ? "Blocked"
                                : appRow.rule === "always" ? "Banners even during Do not disturb"
                                : appRow.rule === "silent" ? "In the center, without a banner"
                                : "Banners and the center"
                            font.pixelSize: Config.Appearance.fs(11)
                            color: Config.Appearance.ink3
                        }
                    }
                    // How, while allowed.
                    Segmented {
                        id: seg
                        visible: appRow.allowed
                        anchors.right: toggle.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        segmentPadding: 10
                        options: [{ label: "Always", value: "always" }, { label: "Normal", value: "normal" },
                                  { label: "Silent", value: "silent" }]
                        value: appRow.rule
                        onSelected: v => root.fc.setRule(appRow.modelData, v)
                    }
                    Toggle {
                        id: toggle
                        anchors.right: forget.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        checked: appRow.allowed
                        onToggled: on => root.fc.setRule(appRow.modelData, on ? "normal" : "block")
                    }
                    // Off the list (it comes back with its next notification).
                    Rectangle {
                        id: forget
                        anchors.right: parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        width: 24; height: 24; radius: 12
                        opacity: appHover.hovered ? 1 : 0
                        color: forgetHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
                        MonoIcon { anchors.centerIn: parent; name: "x"; size: 12; inkColor: Config.Appearance.ink; monochrome: true }
                        HoverHandler { id: forgetHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: root.fc.forgetApp(appRow.modelData) }
                    }
                }
            }
        }
    }
}
