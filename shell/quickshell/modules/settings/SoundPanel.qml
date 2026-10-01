import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Sound.
//
// Output and input, each its device in use with everything about it and
// the others a click away (SoundDevice.qml); then every app playing, with
// its own level and the output it plays to, and every app listening to a
// microphone; then the options, and a way out when sound has stopped
// working altogether.
//
// Everything shown here is bound to PipeWire for as long as the pane is
// open, so levels move as other programs move them, and devices appear and
// disappear as they are plugged in, paired or switched off — nothing here
// holds on to a device that has gone.
Column {
    id: panel

    width: parent ? parent.width : 560
    spacing: 16

    readonly property var au: Services.Audio
    readonly property color danger: "#d93a2b"
    // The window this is in is on screen: the microphone meter stops when
    // it isn't, so closing Settings never leaves the mic open.
    readonly property bool shown: Config.UiState.settingsOpen && visible
                                  && !!Window.window && Window.window.visible
    property var openStream: null       // the stream whose output list is open

    Component.onCompleted: au.watch(true)
    Component.onDestruction: au.watch(false)

    PwObjectTracker {
        objects: panel.au.sinks.concat(panel.au.sources, panel.au.streams, panel.au.recorders)
    }

    component Caption: StyledText {
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        color: Config.Appearance.ink3
    }

    // ══ no PipeWire ══════════════════════════════════════════════════════
    Rectangle {
        visible: !panel.au.pipewireUp
        width: panel.width
        height: down.implicitHeight + 32
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        border.width: 2
        border.color: Config.Appearance.accent
        Column {
            id: down
            x: 16; y: 16; width: parent.width - 32; spacing: 10
            StyledText { text: "PipeWire isn't running"; font.pixelSize: Config.Appearance.fs(15); font.weight: Font.DemiBold }
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Nothing can play or record until it is. Starting it again usually does it; if it keeps stopping, "
                      + "journalctl --user -u pipewire -u wireplumber says why."
                font.pixelSize: Config.Appearance.fs(12)
                color: Config.Appearance.ink3
            }
            NetButton {
                label: panel.au.restarting ? "Starting…" : "Start sound again"
                primary: true
                active: !panel.au.restarting
                onClicked: panel.au.restartAudio()
            }
        }
    }

    // ══ output ═══════════════════════════════════════════════════════════
    Caption { text: "Output" }
    SoundDevice { width: panel.width; output: true; shown: panel.shown }

    // ══ input ════════════════════════════════════════════════════════════
    Caption { text: "Input" }
    SoundDevice { width: panel.width; output: false; shown: panel.shown }

    // ══ apps ═════════════════════════════════════════════════════════════
    Caption { text: "Apps" }
    StyledText {
        visible: panel.au.streams.length === 0
        width: panel.width
        wrapMode: Text.WordWrap
        text: "Nothing is playing. Apps show up here while they make sound, each with its own level — "
              + "remembered for next time — and the output it plays through."
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }
    Column {
        visible: panel.au.streams.length > 0
        width: panel.width
        spacing: 2
        Repeater {
            model: panel.au.streams
            Rectangle {
                id: app
                required property var modelData
                readonly property var s: modelData
                readonly property bool open: !!panel.openStream && panel.openStream.id === s.id
                readonly property string sinkName: panel.au.streamSinkName(s)
                width: panel.width
                height: appCol.implicitHeight + 12
                radius: Config.Appearance.rSm
                color: appHover.hovered || app.open ? Config.Appearance.hover : "transparent"
                HoverHandler { id: appHover }

                Column {
                    id: appCol
                    x: 12; y: 6
                    width: parent.width - 24
                    spacing: 6
                    Item {
                        width: parent.width
                        height: 34
                        Rectangle {
                            id: appBadge
                            width: 32; height: 32; radius: 16
                            anchors.verticalCenter: parent.verticalCenter
                            color: panel.au.nodeMuted(app.s) ? Config.Appearance.div : Config.Appearance.sel
                            MonoIcon {
                                anchors.centerIn: parent
                                name: panel.au.nodeMuted(app.s) ? "volumeX" : Config.Apps.iconFor(panel.au.streamHint(app.s))
                                size: 16
                                inkColor: Config.Appearance.ink2
                                accentColor: Config.Appearance.accent
                            }
                            TapHandler { onTapped: panel.au.setNodeMuted(app.s, !panel.au.nodeMuted(app.s)) }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                        }
                        Column {
                            id: appText
                            anchors.left: appBadge.right
                            anchors.leftMargin: 12
                            width: Math.min(200, parent.width * 0.32)
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: panel.au.streamApp(app.s)
                                font.pixelSize: Config.Appearance.fs(13)
                                font.weight: Font.Medium
                            }
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                visible: text !== ""
                                text: panel.au.streamMedia(app.s)
                                font.pixelSize: Config.Appearance.fs(11.5)
                                color: Config.Appearance.ink3
                            }
                        }
                        FillSlider {
                            id: appVol
                            anchors.left: appText.right
                            anchors.leftMargin: 12
                            anchors.right: appPct.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            trough: 12
                            showRule: true
                            fillColor: panel.au.nodeMuted(app.s) ? Config.Appearance.ink3 : Config.Appearance.accent
                            value: panel.au.nodeVolume(app.s) / panel.au.maxVolume
                            onMoved: v => panel.au.setNodeVolume(app.s, v * panel.au.maxVolume)
                            onReleased: v => panel.au.setNodeVolume(app.s, v * panel.au.maxVolume)
                        }
                        StyledText {
                            id: appPct
                            width: 40
                            anchors.right: outBtn.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignRight
                            text: panel.au.nodeMuted(app.s) ? "Muted" : Math.round(panel.au.nodeVolume(app.s) * 100) + "%"
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink2
                        }
                        // Which output it plays to — only worth a button
                        // when there is more than one.
                        NetButton {
                            id: outBtn
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: panel.au.sinks.length > 1
                            width: visible ? implicitWidth : 0
                            label: {
                                const n = panel.au.sinks.find(k => k.name === app.sinkName);
                                const t = n ? panel.au.displayName(n) : "Output";
                                return (t.length > 18 ? t.slice(0, 17) + "…" : t) + "  ▾";
                            }
                            onClicked: panel.openStream = app.open ? null : app.s
                        }
                    }
                    // Its outputs, opened in place.
                    Column {
                        visible: app.open
                        width: parent.width
                        leftPadding: 44
                        spacing: 2
                        Repeater {
                            model: app.open ? panel.au.sinks : []
                            Rectangle {
                                id: dest
                                required property var modelData
                                readonly property bool current: modelData.name === app.sinkName
                                width: appCol.width - 44
                                height: 30
                                radius: Config.Appearance.rSm
                                color: dest.current ? Config.Appearance.sel : destHover.hovered ? Config.Appearance.div : "transparent"
                                MonoIcon {
                                    id: destIcon
                                    x: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: panel.au.deviceGlyph(dest.modelData)
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
                                    text: panel.au.displayName(dest.modelData)
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
                                        if (!dest.current) panel.au.moveStream(app.s, dest.modelData);
                                        panel.openStream = null;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Apps listening: worth seeing for its own sake — it is how you find
    // out what has the microphone open.
    StyledText {
        visible: panel.au.recorders.length > 0
        topPadding: 2
        text: "Using a microphone"
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.DemiBold
        color: Config.Appearance.ink3
    }
    Column {
        visible: panel.au.recorders.length > 0
        width: panel.width
        spacing: 2
        Repeater {
            model: panel.au.recorders
            Item {
                id: rec
                required property var modelData
                width: panel.width
                height: 40
                Rectangle {
                    id: recBadge
                    x: 12
                    width: 28; height: 28; radius: 14
                    anchors.verticalCenter: parent.verticalCenter
                    color: Qt.rgba(Config.Appearance.accent.r, Config.Appearance.accent.g, Config.Appearance.accent.b, 0.18)
                    MonoIcon {
                        anchors.centerIn: parent
                        name: panel.au.nodeMuted(rec.modelData) ? "micOff" : "mic"
                        size: 14; monochrome: true
                        inkColor: Config.Appearance.accent
                    }
                }
                StyledText {
                    anchors.left: recBadge.right
                    anchors.leftMargin: 12
                    anchors.right: recVol.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: panel.au.streamApp(rec.modelData)
                          + (panel.au.streamMedia(rec.modelData) !== "" ? "  ·  " + panel.au.streamMedia(rec.modelData) : "")
                    font.pixelSize: Config.Appearance.fs(13)
                }
                FillSlider {
                    id: recVol
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(220, panel.width * 0.35)
                    trough: 12
                    showRule: true
                    value: panel.au.nodeVolume(rec.modelData)
                    onMoved: v => panel.au.setNodeVolume(rec.modelData, v)
                    onReleased: v => panel.au.setNodeVolume(rec.modelData, v)
                }
            }
        }
    }

    // ══ options ══════════════════════════════════════════════════════════
    Caption { text: "Options" }
    Rectangle {
        width: panel.width
        height: opts.implicitHeight + 24
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule
        Column {
            id: opts
            x: 16; y: 12; width: parent.width - 32; spacing: 12

            Item {
                width: parent.width
                height: 34
                Column {
                    anchors.left: parent.left
                    anchors.right: stepSeg.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText { text: "Volume key step"; font.pixelSize: Config.Appearance.fs(13) }
                    StyledText { text: "How far one press of a volume key, or one notch on the bar, moves the level"; width: parent.width; elide: Text.ElideRight; font.pixelSize: Config.Appearance.fs(11.5); color: Config.Appearance.ink3 }
                }
                Segmented {
                    id: stepSeg
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    options: [{ label: "1%", value: "1" }, { label: "2%", value: "2" }, { label: "5%", value: "5" }, { label: "10%", value: "10" }]
                    value: String(Config.Appearance.volumeStep)
                    onSelected: v => Config.Appearance.volumeStep = parseInt(v)
                }
            }
            Item {
                width: parent.width
                height: 34
                Column {
                    anchors.left: parent.left
                    anchors.right: boostToggle.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText { text: "Allow above 100%"; font.pixelSize: Config.Appearance.fs(13) }
                    StyledText { text: "Up to 150%, for a quiet recording or weak speakers — loud sounds will distort"; width: parent.width; elide: Text.ElideRight; font.pixelSize: Config.Appearance.fs(11.5); color: Config.Appearance.ink3 }
                }
                Toggle {
                    id: boostToggle
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: Config.Appearance.volumeBoost
                    onToggled: on => {
                        Config.Appearance.volumeBoost = on;
                        // Coming back down, nothing stays above the new ceiling.
                        if (!on && panel.au.volume > 1) panel.au.setVolume(1);
                    }
                }
            }
            Item {
                width: parent.width
                height: 34
                Column {
                    anchors.left: parent.left
                    anchors.right: tickToggle.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText { text: "Sound on volume change"; font.pixelSize: Config.Appearance.fs(13) }
                    StyledText { text: "A short tick on each press of a volume key, to judge the level by ear"; width: parent.width; elide: Text.ElideRight; font.pixelSize: Config.Appearance.fs(11.5); color: Config.Appearance.ink3 }
                }
                Toggle {
                    id: tickToggle
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    checked: Config.Appearance.volumeFeedback
                    onToggled: on => Config.Appearance.volumeFeedback = on
                }
            }
        }
    }

    // ══ when it isn't working ════════════════════════════════════════════
    Caption { text: "Sound not working?" }
    Rectangle {
        width: panel.width
        height: fix.implicitHeight + 24
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        border.width: 1
        border.color: panel.au.lastError !== "" ? panel.danger : Config.Appearance.rule
        Column {
            id: fix
            x: 16; y: 12; width: parent.width - 32; spacing: 10
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "A headset stuck in the wrong mode, a device that came back silent, crackling after sleep: restarting "
                      + "the sound services fixes most of it, at the cost of a second of silence."
                font.pixelSize: Config.Appearance.fs(12)
                color: Config.Appearance.ink2
            }
            Row {
                spacing: 8
                NetButton {
                    label: panel.au.restarting ? "Restarting…" : "Restart sound"
                    active: !panel.au.restarting
                    onClicked: panel.au.restartAudio()
                }
                NetButton {
                    label: "Refresh devices"
                    onClicked: panel.au.refreshDetails()
                }
            }
            StyledText {
                visible: panel.au.pactlMissing
                width: parent.width
                wrapMode: Text.WordWrap
                text: "pactl isn't installed, so connectors, card modes and moving an app to another output aren't available. "
                      + "It comes with pipewire-pulse (or libpulse)."
                font.pixelSize: Config.Appearance.fs(12)
                color: Config.Appearance.ink3
            }
            StyledText {
                visible: panel.au.lastError !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                text: panel.au.lastError
                font.pixelSize: Config.Appearance.fs(12)
                color: panel.danger
            }
        }
    }
}
