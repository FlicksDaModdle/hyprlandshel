import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// What is using the microphone, the camera and the screen
// (services/Privacy.qml). Opened from the dot in the bar.
PanelSurface {
    id: root

    readonly property var pv: Services.Privacy

    implicitWidth: 320
    implicitHeight: col.implicitHeight + 24

    Column {
        id: col
        x: 14; y: 12
        width: parent.width - 28
        spacing: 12

        StyledText {
            text: "In use"
            font.pixelSize: Config.Appearance.fs(11)
            font.weight: Font.DemiBold
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.9
            color: Config.Appearance.ink2
        }

        StyledText {
            visible: !root.pv.any
            text: "Nothing is using the microphone, camera or screen."
            width: parent.width
            wrapMode: Text.Wrap
            font.pixelSize: Config.Appearance.fs(12)
            color: Config.Appearance.ink3
        }

        Repeater {
            model: [
                { on: root.pv.mic, icon: "mic", what: "Microphone", apps: root.pv.micApps },
                { on: root.pv.camera, icon: "camera", what: "Camera", apps: root.pv.cameraApps },
                { on: root.pv.sharing, icon: "monitor", what: "Screen", apps: root.pv.screenApps }
            ]
            Item {
                id: entry
                required property var modelData
                visible: modelData.on
                width: col.width
                height: visible ? 40 : 0

                Rectangle {
                    id: badge
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 32; height: 32; radius: 16
                    color: Config.Appearance.accent
                    MonoIcon {
                        anchors.centerIn: parent
                        name: entry.modelData.icon
                        size: 16
                        inkColor: Config.Appearance.inkOnAccent
                        monochrome: true
                    }
                }
                Column {
                    anchors.left: badge.right
                    anchors.leftMargin: 10
                    anchors.right: action.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText {
                        text: entry.modelData.what
                        font.pixelSize: Config.Appearance.fs(12.5)
                        font.weight: Font.DemiBold
                    }
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: entry.modelData.apps.join(", ")
                        font.pixelSize: Config.Appearance.fs(11.5)
                        color: Config.Appearance.ink3
                    }
                }
                // The microphone can be muted from here, for whoever has it.
                Rectangle {
                    id: action
                    visible: entry.modelData.icon === "mic"
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: visible ? muteText.implicitWidth + 20 : 0
                    height: 26
                    radius: 13
                    color: muteHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
                    StyledText {
                        id: muteText
                        anchors.centerIn: parent
                        text: Services.Audio.inputMuted ? "Unmute" : "Mute"
                        font.pixelSize: Config.Appearance.fs(11.5)
                        font.weight: Font.DemiBold
                    }
                    HoverHandler { id: muteHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: Services.Audio.toggleInputMute() }
                }
            }
        }
    }
}
