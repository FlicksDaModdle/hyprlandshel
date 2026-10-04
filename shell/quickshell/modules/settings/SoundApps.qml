import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Sound → Apps: every app playing, with its own level, mute,
// balance and the output it plays through; every app recording, with its
// level and the microphone it listens to. WirePlumber remembers each
// app's level and device for next time.
Column {
    id: root

    readonly property var au: Services.Audio
    property string openKey: ""            // "<id>:route" or "<id>:more" for the row opened

    spacing: 16

    component Caption: StyledText {
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        color: Config.Appearance.ink3
    }

    // One app, playing or recording.
    component AppRow: Rectangle {
        id: app
        property var s: null
        property bool playing: true
        readonly property string routeKey: (s ? s.id : "") + ":route"
        readonly property string moreKey: (s ? s.id : "") + ":more"
        readonly property bool routeOpen: root.openKey === routeKey
        readonly property bool moreOpen: root.openKey === moreKey
        readonly property bool muted: root.au.nodeMuted(s)
        readonly property string deviceName: playing ? root.au.streamSinkName(s) : root.au.recorderSourceName(s)
        readonly property var devices: playing ? root.au.sinks : root.au.sources
        readonly property var device: devices.find(k => k.name === deviceName) || null
        readonly property real ceiling: playing ? root.au.maxVolume : 1.5

        width: root.width
        height: appCol.implicitHeight + 12
        radius: Config.Appearance.rSm
        color: appHover.hovered || routeOpen || moreOpen ? Config.Appearance.hover : "transparent"
        HoverHandler { id: appHover }

        Column {
            id: appCol
            x: 12; y: 6
            width: parent.width - 24
            spacing: 6
            Item {
                width: parent.width
                height: 36
                Rectangle {
                    id: appBadge
                    width: 34; height: 34; radius: 17
                    anchors.verticalCenter: parent.verticalCenter
                    color: app.muted ? Config.Appearance.div
                         : app.playing ? Config.Appearance.sel
                         : Qt.rgba(Config.Appearance.accent.r, Config.Appearance.accent.g, Config.Appearance.accent.b, 0.18)
                    MonoIcon {
                        anchors.centerIn: parent
                        name: app.muted ? (app.playing ? "volumeX" : "micOff")
                            : app.playing ? Config.Apps.iconFor(root.au.streamHint(app.s)) : "mic"
                        size: 16
                        inkColor: app.playing ? Config.Appearance.ink2 : Config.Appearance.accent
                        accentColor: Config.Appearance.accent
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.au.setNodeMuted(app.s, !app.muted) }
                }
                Column {
                    id: appText
                    anchors.left: appBadge.right
                    anchors.leftMargin: 12
                    width: Math.min(200, parent.width * 0.3)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.au.streamApp(app.s)
                        font.pixelSize: Config.Appearance.fs(13)
                        font.weight: Font.Medium
                    }
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        visible: text !== ""
                        text: root.au.streamMedia(app.s)
                        font.pixelSize: Config.Appearance.fs(11.5)
                        color: Config.Appearance.ink3
                    }
                }
                FillSlider {
                    anchors.left: appText.right
                    anchors.leftMargin: 12
                    anchors.right: appPct.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    trough: 12
                    showRule: true
                    fillColor: app.muted ? Config.Appearance.ink3 : Config.Appearance.accent
                    value: root.au.nodeVolume(app.s) / app.ceiling
                    onMoved: v => root.au.setNodeVolume(app.s, v * app.ceiling)
                    onReleased: v => root.au.setNodeVolume(app.s, v * app.ceiling)
                }
                StyledText {
                    id: appPct
                    width: 44
                    anchors.right: buttons.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: app.muted ? "Muted" : Math.round(root.au.nodeVolume(app.s) * 100) + "%"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink2
                }
                Row {
                    id: buttons
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6
                    NetButton {
                        visible: app.devices.length > 1
                        label: {
                            const t = app.device ? root.au.displayName(app.device) : (app.playing ? "Output" : "Input");
                            return (t.length > 16 ? t.slice(0, 15) + "…" : t) + "  ▾";
                        }
                        onClicked: root.openKey = app.routeOpen ? "" : app.routeKey
                    }
                    NetButton {
                        visible: root.au.hasBalance(app.s)
                        label: "···"
                        onClicked: root.openKey = app.moreOpen ? "" : app.moreKey
                    }
                }
            }
            // Where it plays, or what it records from.
            Column {
                visible: app.routeOpen
                width: parent.width
                leftPadding: 46
                spacing: 2
                Repeater {
                    model: app.routeOpen ? app.devices : []
                    Rectangle {
                        id: dest
                        required property var modelData
                        readonly property bool current: modelData.name === app.deviceName
                        width: appCol.width - 46
                        height: 30
                        radius: Config.Appearance.rSm
                        color: dest.current ? Config.Appearance.sel : destHover.hovered ? Config.Appearance.div : "transparent"
                        MonoIcon {
                            id: destIcon
                            x: 8
                            anchors.verticalCenter: parent.verticalCenter
                            name: root.au.deviceGlyph(dest.modelData)
                            size: 14; monochrome: true
                            inkColor: Config.Appearance.ink2
                        }
                        StyledText {
                            anchors.left: destIcon.right
                            anchors.leftMargin: 8
                            anchors.right: parent.right
                            anchors.rightMargin: 30
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: root.au.displayName(dest.modelData)
                            font.pixelSize: Config.Appearance.fs(12)
                            font.weight: dest.current ? Font.DemiBold : Font.Normal
                        }
                        MonoIcon {
                            visible: dest.current
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            name: "check"; size: 14; monochrome: true
                            inkColor: Config.Appearance.accent
                        }
                        HoverHandler { id: destHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            onTapped: {
                                if (!dest.current) {
                                    if (app.playing) root.au.moveStream(app.s, dest.modelData);
                                    else root.au.moveRecorder(app.s, dest.modelData);
                                }
                                root.openKey = "";
                            }
                        }
                    }
                }
            }
            // Its own balance.
            Item {
                visible: app.moreOpen
                width: parent.width
                height: 24
                StyledText {
                    id: abLabel
                    x: 46
                    width: 70
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Balance"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink2
                }
                SoundCenterSlider {
                    anchors.left: abLabel.right
                    anchors.right: parent.right
                    anchors.rightMargin: 60
                    anchors.verticalCenter: parent.verticalCenter
                    value: root.au.balance(app.s)
                    onMoved: v => root.au.setBalance(app.s, v)
                }
                StyledText {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property real b: root.au.balance(app.s)
                    text: Math.abs(b) < 0.01 ? "Centre" : Math.round(Math.abs(b) * 100) + (b < 0 ? " L" : " R")
                    font.pixelSize: Config.Appearance.fs(12)
                }
            }
        }
    }

    // ══ playing ══════════════════════════════════════════════════════════
    Caption { text: "Playing" }
    StyledText {
        visible: root.au.streams.length === 0
        width: root.width
        wrapMode: Text.WordWrap
        text: "Nothing is playing. Apps show up here while they make sound, each with its own level, "
              + "balance and output — remembered for next time."
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }
    Column {
        width: root.width
        spacing: 2
        Repeater {
            model: root.au.streams
            AppRow {
                required property var modelData
                s: modelData
                playing: true
            }
        }
    }

    // ══ recording ════════════════════════════════════════════════════════
    // Worth seeing for its own sake: it is how you find out what has the
    // microphone open.
    Caption { text: "Using a microphone" }
    StyledText {
        visible: root.au.recorders.length === 0
        width: root.width
        wrapMode: Text.WordWrap
        text: "No app is listening to a microphone right now."
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }
    Column {
        width: root.width
        spacing: 2
        Repeater {
            model: root.au.recorders
            AppRow {
                required property var modelData
                s: modelData
                playing: false
            }
        }
    }
}
