import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Every output, or every input, each with its own level and mute in the
// row, and the one in use marked. Clicking a row opens it in the
// inspector below (SoundInspector.qml) — any device, not only the one in
// use; "Use" makes it the one in use.
Column {
    id: root

    property bool output: true
    property string selectedName: ""
    signal selected(var node)
    property bool showHidden: false

    readonly property var au: Services.Audio
    readonly property var current: output ? au.sink : au.source
    readonly property var all: output ? au.sinks : au.sources
    readonly property int hiddenCount: all.filter(n => au.isHidden(n)).length
    readonly property var shownDevices: all.filter(n => showHidden || !au.isHidden(n) || n === current)

    spacing: 2

    StyledText {
        visible: root.all.length === 0
        width: root.width
        wrapMode: Text.WordWrap
        topPadding: 6
        bottomPadding: 6
        text: root.output
              ? "No outputs. If something is plugged in, its card may be switched off — try “Restart sound” under Options."
              : "No inputs. A Bluetooth headset's microphone only appears in its headset mode."
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }

    Repeater {
        model: root.shownDevices
        Rectangle {
            id: row
            required property var modelData
            readonly property var n: modelData
            readonly property bool inUse: !!root.current && root.current.name === n.name
            readonly property bool picked: root.selectedName === n.name
            readonly property var d: root.au.details(n)
            readonly property bool unplugged: !!d.port && !d.port.available
            readonly property bool muted: root.au.nodeMuted(n)
            width: root.width
            height: 56
            radius: Config.Appearance.rSm
            color: row.picked ? Config.Appearance.sel : rowHover.hovered ? Config.Appearance.hover : "transparent"
            border.width: row.inUse ? 1 : 0
            border.color: Config.Appearance.accent
            opacity: row.unplugged && !row.inUse ? 0.6 : 1

            HoverHandler { id: rowHover }
            TapHandler { onTapped: root.selected(row.n) }

            Rectangle {
                id: badge
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                width: 34; height: 34; radius: 17
                color: row.inUse && !row.muted ? Config.Appearance.accent : Config.Appearance.div
                MonoIcon {
                    anchors.centerIn: parent
                    name: row.muted ? (root.output ? "volumeX" : "micOff") : root.au.deviceGlyph(row.n)
                    size: 17
                    monochrome: true
                    inkColor: row.inUse && !row.muted ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                }
            }
            Column {
                anchors.left: badge.right
                anchors.leftMargin: 12
                anchors.right: controls.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.au.displayName(row.n)
                    font.pixelSize: Config.Appearance.fs(13)
                    font.weight: row.inUse ? Font.DemiBold : Font.Medium
                }
                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: [row.inUse ? "In use" : "",
                           row.inUse && root.output && root.au.eqActive ? "through the equalizer" : "",
                           row.inUse && !root.output && root.au.nsActive ? "noise suppressed" : "",
                           row.d.port && row.d.port.description !== root.au.displayName(row.n) ? row.d.port.description : "",
                           row.unplugged ? "unplugged" : "",
                           root.au.isHidden(row.n) ? "hidden" : ""].filter(s => s).join(" · ")
                    visible: text !== ""
                    font.pixelSize: Config.Appearance.fs(11.5)
                    color: row.inUse ? Config.Appearance.accent : Config.Appearance.ink3
                }
            }

            Row {
                id: controls
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                // Mute, in the row.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 28; height: 28; radius: 14
                    color: muteHover.hovered ? Config.Appearance.div : "transparent"
                    MonoIcon {
                        anchors.centerIn: parent
                        name: row.muted ? (root.output ? "volumeX" : "micOff") : (root.output ? "volume" : "mic")
                        size: 15; monochrome: true
                        inkColor: row.muted ? Config.Appearance.accent : Config.Appearance.ink2
                    }
                    HoverHandler { id: muteHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.au.setNodeMuted(row.n, !row.muted) }
                }
                FillSlider {
                    takesWheel: false
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(170, root.width * 0.24)
                    trough: 10
                    showRule: true
                    readonly property real ceiling: root.output ? root.au.maxVolume : 1.5
                    fillColor: row.muted ? Config.Appearance.ink3 : Config.Appearance.accent
                    value: root.au.nodeVolume(row.n) / ceiling
                    onMoved: v => root.au.setNodeVolume(row.n, v * ceiling)
                    onReleased: v => root.au.setNodeVolume(row.n, v * ceiling)
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 38
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(root.au.nodeVolume(row.n) * 100) + "%"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: root.au.nodeVolume(row.n) > 1.001 ? "#d93a2b" : Config.Appearance.ink2
                }
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 62; height: 30
                    NetButton {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !row.inUse
                        label: "Use"
                        onClicked: root.output ? root.au.setDefaultSink(row.n) : root.au.setDefaultSource(row.n)
                    }
                    MonoIcon {
                        anchors.centerIn: parent
                        visible: row.inUse
                        name: "check"; size: 16; monochrome: true
                        inkColor: Config.Appearance.accent
                    }
                }
            }
        }
    }

    StyledText {
        visible: root.hiddenCount > 0
        topPadding: 4
        leftPadding: 10
        text: root.showHidden ? "Hide the hidden devices again" : root.hiddenCount + " hidden — show them"
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.accent
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: root.showHidden = !root.showHidden }
    }
}
