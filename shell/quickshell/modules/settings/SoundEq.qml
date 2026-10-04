import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Sound → Output: the equalizer (services/AudioFx.qml). Ten
// bands and a preamp over everything played, on whichever output is in
// use; presets to start from; changes heard as they are made.
Rectangle {
    id: root

    readonly property var fx: Services.AudioFx
    readonly property var prefs: Config.Appearance
    readonly property bool on: prefs.eqEnabled
    readonly property color danger: "#d93a2b"

    height: col.implicitHeight + 32
    radius: Config.Appearance.r
    color: Config.Appearance.hover
    border.width: 1
    border.color: fx.eqStatus === "error" ? danger : Config.Appearance.rule

    Column {
        id: col
        x: 16; y: 16; width: parent.width - 32; spacing: 14

        Item {
            width: parent.width
            height: 40
            Rectangle {
                id: badge
                width: 40; height: 40; radius: 20
                color: root.on ? Config.Appearance.accent : Config.Appearance.div
                MonoIcon {
                    anchors.centerIn: parent
                    name: "sliders"; size: 19; monochrome: true
                    inkColor: root.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                }
            }
            Column {
                anchors.left: badge.right
                anchors.leftMargin: 12
                anchors.right: toggle.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                StyledText { text: "Equalizer"; font.pixelSize: Config.Appearance.fs(15); font.weight: Font.DemiBold }
                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: !root.fx.probed ? "Checking…"
                        : !root.fx.eqAvailable ? "Needs the pipewire program, which wasn't found"
                        : !root.on ? "Off — shape the sound of everything you play"
                        : root.fx.eqStatus === "starting" ? "Starting…"
                        : root.fx.eqStatus === "error" ? "Didn't start — see below"
                        : "On, for " + (Services.Audio.sink ? Services.Audio.displayName(Services.Audio.sink) : "the output") + " · " + root.prefs.eqPreset
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
            }
            Toggle {
                id: toggle
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                enabled: root.fx.eqAvailable
                checked: root.on
                onToggled: on => root.fx.setEnabled(on)
            }
        }

        StyledText {
            visible: root.fx.eqStatus === "error" && root.on
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.fx.eqError
            font.pixelSize: Config.Appearance.fs(12)
            color: root.danger
        }
        NetButton {
            visible: root.fx.eqStatus === "error" && root.on
            label: "Try again"
            onClicked: root.fx.retryEq()
        }

        // Presets.
        Flow {
            width: parent.width
            spacing: 6
            Repeater {
                model: root.fx.presets
                NetButton {
                    required property var modelData
                    label: modelData.name
                    primary: root.prefs.eqPreset === modelData.name
                    onClicked: root.fx.applyPreset(modelData)
                }
            }
            NetButton {
                visible: root.prefs.eqPreset === "Custom"
                label: "Custom"
                primary: true
            }
        }

        // The bands, with the preamp set apart on the left.
        Item {
            width: parent.width
            height: 200
            opacity: root.on ? 1 : 0.6

            SoundBandSlider {
                id: pre
                anchors.left: parent.left
                height: parent.height
                label: "Pre"
                value: root.prefs.eqPreamp
                onMoved: v => root.fx.setPreamp(v)
            }
            Rectangle {
                id: sep
                anchors.left: pre.right
                anchors.leftMargin: 10
                width: 1
                height: parent.height - 20
                y: 10
                color: Config.Appearance.rule
            }
            // dB scale beside the bands.
            Item {
                id: dbScale
                anchors.left: sep.right
                anchors.leftMargin: 6
                // Matches the band sliders' track: below the gain label,
                // above the frequency.
                y: 24
                width: 24
                height: parent.height - 48
                Repeater {
                    model: ["+12", "+6", "0", "−6", "−12"]
                    StyledText {
                        required property int index
                        required property var modelData
                        y: index * dbScale.height / 4 - height / 2
                        text: modelData
                        font.pixelSize: Config.Appearance.fs(9.5)
                        color: Config.Appearance.ink3
                    }
                }
            }
            Row {
                anchors.left: dbScale.right
                anchors.leftMargin: 4
                anchors.right: parent.right
                height: parent.height
                readonly property real bandW: width / 10
                Repeater {
                    model: 10
                    SoundBandSlider {
                        required property int index
                        width: parent.bandW
                        height: parent.height
                        label: root.fx.bandLabel(root.fx.bands[index])
                        value: root.fx.gains[index]
                        onMoved: v => root.fx.setGain(index, v)
                    }
                }
            }
        }

        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Changes are heard at once and kept. Drag a band, scroll on it, or double-click to put it back to 0. "
                  + "Boosting can clip loud passages — the presets lower the preamp to make room. "
                  + "The equalizer is an output of its own that passes the sound on to the device in use, so apps "
                  + "sent straight to another device (under Apps) play without it."
            font.pixelSize: Config.Appearance.fs(11.5)
            color: Config.Appearance.ink3
        }
    }
}
