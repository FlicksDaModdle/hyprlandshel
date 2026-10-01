import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Sound: one direction's devices — the output, or the input.
//
// The device in use at the top with everything about it: its level, mute,
// balance, a test (or, for a microphone, what it is hearing), which
// connector it uses and the mode its card is in. Below it every other
// device of the same kind, each one click from being the one in use.
Column {
    id: root

    property bool output: true
    property bool shown: true               // false while the window is hidden: stops the meter
    readonly property var au: Services.Audio
    readonly property var node: output ? au.sink : au.source
    readonly property var devices: output ? au.sinks : au.sources
    readonly property var others: devices.filter(n => n !== root.node)
    // details() reads the pactl tables, so this follows them as they change.
    readonly property var info: au.details(root.node)
    readonly property color danger: "#d93a2b"
    property bool profilesOpen: false

    spacing: 10

    // ══ no device ════════════════════════════════════════════════════════
    Rectangle {
        visible: !root.node
        width: root.width
        height: none.implicitHeight + 28
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule
        Column {
            id: none
            x: 16; y: 14; width: parent.width - 32; spacing: 4
            StyledText {
                text: root.output ? "No output device" : "No microphone"
                font.pixelSize: Config.Appearance.fs(14)
                font.weight: Font.DemiBold
            }
            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: root.devices.length > 0
                      ? "None is chosen as the default — pick one below."
                      : root.output
                        ? "PipeWire doesn't see anything to play through. If a device is plugged in, its card may be switched off — see “Sound not working?” at the bottom."
                        : "Nothing to record from is connected, or its card is in an output-only mode."
                font.pixelSize: Config.Appearance.fs(12)
                color: Config.Appearance.ink3
            }
        }
    }

    // ══ the one in use ═══════════════════════════════════════════════════
    Rectangle {
        visible: !!root.node
        width: root.width
        height: main.implicitHeight + 32
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule

        Column {
            id: main
            x: 16; y: 16; width: parent.width - 32; spacing: 14

            // Name, what it is, and mute.
            Item {
                width: parent.width
                height: 40
                Rectangle {
                    id: badge
                    width: 40; height: 40; radius: 20
                    color: Services.Audio.nodeMuted(root.node) ? Config.Appearance.div : Config.Appearance.accent
                    MonoIcon {
                        anchors.centerIn: parent
                        name: Services.Audio.nodeMuted(root.node) ? (root.output ? "volumeX" : "micOff")
                                                                  : root.au.deviceGlyph(root.node)
                        size: 20
                        monochrome: true
                        inkColor: Services.Audio.nodeMuted(root.node) ? Config.Appearance.ink2 : Config.Appearance.inkOnAccent
                    }
                }
                Column {
                    anchors.left: badge.right
                    anchors.leftMargin: 12
                    anchors.right: muteBtn.left
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.au.displayName(root.node)
                        font.pixelSize: Config.Appearance.fs(15)
                        font.weight: Font.DemiBold
                    }
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        // The connector, unless it only repeats the name;
                        // the card's mode has its own row below.
                        text: [root.info.port && root.info.port.description !== root.au.displayName(root.node)
                                   ? root.info.port.description : "",
                               root.au.nodeMuted(root.node) ? "Muted" : ""].filter(s => s).join(" · ")
                              || (root.output ? "Default output" : "Default input")
                        font.pixelSize: Config.Appearance.fs(12)
                        color: Config.Appearance.ink3
                    }
                }
                NetButton {
                    id: muteBtn
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    label: root.au.nodeMuted(root.node) ? "Unmute" : "Mute"
                    primary: root.au.nodeMuted(root.node)
                    onClicked: root.au.setNodeMuted(root.node, !root.au.nodeMuted(root.node))
                }
            }

            // Level.
            Item {
                width: parent.width
                height: 22
                StyledText {
                    id: volLabel
                    width: 74
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.output ? "Volume" : "Input level"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink2
                }
                FillSlider {
                    id: vol
                    anchors.left: volLabel.right
                    anchors.right: volValue.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    trough: 14
                    showRule: true
                    readonly property real ceiling: root.output ? root.au.maxVolume : 1.5
                    value: root.au.nodeVolume(root.node) / ceiling
                    onMoved: v => root.au.setNodeVolume(root.node, v * ceiling)
                    onReleased: v => root.au.setNodeVolume(root.node, v * ceiling)
                    // 100% marked when the range goes past it.
                    Rectangle {
                        visible: vol.ceiling > 1
                        x: parent.width / vol.ceiling - 1
                        y: -3
                        width: 2
                        height: parent.height + 6
                        color: Config.Appearance.ink3
                        opacity: 0.6
                    }
                }
                StyledText {
                    id: volValue
                    width: 44
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(root.au.nodeVolume(root.node) * 100) + "%"
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.DemiBold
                    color: root.au.nodeVolume(root.node) > 1.001 ? root.danger : Config.Appearance.ink
                }
            }

            // Balance, for anything with a left and a right.
            Item {
                visible: root.output && root.au.hasBalance(root.node)
                width: parent.width
                height: 22
                StyledText {
                    id: balLabel
                    width: 74
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Balance"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink2
                }
                StyledText {
                    id: lMark
                    anchors.left: balLabel.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "L"
                    font.pixelSize: Config.Appearance.fs(11)
                    color: Config.Appearance.ink3
                }
                Item {
                    id: balTrack
                    anchors.left: lMark.right
                    anchors.leftMargin: 8
                    anchors.right: rMark.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    height: 14
                    readonly property real b: root.au.balance(root.node)
                    Rectangle {
                        anchors.fill: parent
                        radius: Config.Appearance.rSm
                        color: Config.Appearance.ground
                        border.width: 1
                        border.color: Config.Appearance.rule
                    }
                    // The fill runs from the centre to where it is set.
                    Rectangle {
                        readonly property real c: balTrack.width / 2
                        x: balTrack.b < 0 ? c + balTrack.b * c : c
                        width: Math.max(2, Math.abs(balTrack.b) * c)
                        height: parent.height
                        radius: Config.Appearance.rSm
                        color: Config.Appearance.accent
                    }
                    Rectangle {
                        x: parent.width / 2 - 1
                        width: 2; height: parent.height
                        color: Config.Appearance.ink3
                    }
                    MouseArea {
                        anchors.fill: parent
                        anchors.topMargin: -6
                        anchors.bottomMargin: -6
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true
                        function set(x) { root.au.setBalance(root.node, (x / width) * 2 - 1); }
                        onPressed: mouse => set(mouse.x)
                        onPositionChanged: mouse => { if (pressed) set(mouse.x); }
                        onDoubleClicked: root.au.setBalance(root.node, 0)
                    }
                }
                StyledText {
                    id: rMark
                    anchors.right: balValue.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: "R"
                    font.pixelSize: Config.Appearance.fs(11)
                    color: Config.Appearance.ink3
                }
                StyledText {
                    id: balValue
                    width: 44
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: Math.abs(balTrack.b) < 0.01 ? "Centre"
                        : Math.round(Math.abs(balTrack.b) * 100) + (balTrack.b < 0 ? " L" : " R")
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink
                }
            }

            // What the microphone hears, live.
            Item {
                visible: !root.output
                width: parent.width
                height: 22
                StyledText {
                    id: hearLabel
                    width: 74
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Hearing"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink2
                }
                Loader {
                    id: meter
                    anchors.left: hearLabel.right
                    anchors.right: parent.right
                    anchors.rightMargin: 54
                    anchors.verticalCenter: parent.verticalCenter
                    height: 10
                    active: !root.output && root.shown && !!root.node
                    source: "SoundLevel.qml"
                    onLoaded: {
                        item.node = Qt.binding(() => root.node);
                        item.live = Qt.binding(() => root.shown);
                    }
                }
                StyledText {
                    visible: meter.status === Loader.Error
                    anchors.left: hearLabel.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "A live meter needs Quickshell 0.3 or newer"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
            }

            // Test sounds, straight to this device.
            Flow {
                visible: root.output
                width: parent.width
                spacing: 6
                StyledText {
                    width: 74
                    height: 30
                    verticalAlignment: Text.AlignVCenter
                    text: "Test"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink2
                }
                NetButton { label: "Play a sound"; onClicked: root.au.testSound(root.node) }
                Repeater {
                    model: root.output ? root.au.channelInfo(root.node) : []
                    NetButton {
                        required property var modelData
                        visible: root.au.channelInfo(root.node).length > 1
                        label: modelData.label
                        onClicked: root.au.testChannel(root.node, modelData)
                    }
                }
            }

            // Connector — speakers or headphones, line in or the headset mic.
            Flow {
                visible: (root.info.ports || []).length > 1
                width: parent.width
                spacing: 6
                StyledText {
                    width: 74
                    height: 30
                    verticalAlignment: Text.AlignVCenter
                    text: "Connector"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink2
                }
                Repeater {
                    model: root.info.ports || []
                    NetButton {
                        required property var modelData
                        label: modelData.description + (modelData.available ? "" : " (unplugged)")
                        primary: modelData.name === root.info.activePort
                        active: modelData.available || modelData.name === root.info.activePort
                        onClicked: if (modelData.name !== root.info.activePort) root.au.setPort(root.node, modelData.name)
                    }
                }
            }

            // The card's mode.
            Column {
                visible: !!root.info.card && root.info.card.profiles.length > 1
                width: parent.width
                spacing: 4
                Item {
                    width: parent.width
                    height: 30
                    StyledText {
                        id: modeLabel
                        width: 74
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Mode"
                        font.pixelSize: Config.Appearance.fs(12)
                        color: Config.Appearance.ink2
                    }
                    StyledText {
                        anchors.left: modeLabel.right
                        anchors.right: modeBtn.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: root.info.card
                              ? ((root.info.card.profiles.find(p => p.name === root.info.card.activeProfile) || {}).description || root.info.card.activeProfile)
                              : ""
                        font.pixelSize: Config.Appearance.fs(12)
                    }
                    NetButton {
                        id: modeBtn
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        label: root.profilesOpen ? "Done" : "Change"
                        onClicked: root.profilesOpen = !root.profilesOpen
                    }
                }
                StyledText {
                    visible: root.profilesOpen
                    width: parent.width
                    wrapMode: Text.WordWrap
                    leftPadding: 74
                    text: root.output
                          ? "A Bluetooth headset has two: high quality for listening, or a headset mode that turns its microphone on at phone-call quality. HDMI and surround cards list each speaker layout."
                          : "A Bluetooth headset's microphone only works in its headset mode, which lowers what you hear to phone-call quality."
                    font.pixelSize: Config.Appearance.fs(11.5)
                    color: Config.Appearance.ink3
                }
                Repeater {
                    model: root.profilesOpen && root.info.card ? root.info.card.profiles : []
                    Rectangle {
                        id: prof
                        required property var modelData
                        readonly property bool current: !!root.info.card && modelData.name === root.info.card.activeProfile
                        x: 74
                        width: parent.width - 74
                        height: 30
                        radius: Config.Appearance.rSm
                        opacity: modelData.available ? 1 : 0.5
                        color: prof.current ? Config.Appearance.sel : profHover.hovered ? Config.Appearance.hover : "transparent"
                        StyledText {
                            x: 10
                            width: parent.width - 40
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: prof.modelData.description + (prof.modelData.available ? "" : " — not available now")
                            font.pixelSize: Config.Appearance.fs(12)
                            font.weight: prof.current ? Font.DemiBold : Font.Normal
                        }
                        MonoIcon {
                            visible: prof.current
                            anchors.right: parent.right
                            anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            name: "check"; size: 14; monochrome: true
                            inkColor: Config.Appearance.accent
                        }
                        HoverHandler { id: profHover; cursorShape: Qt.PointingHandCursor }
                        TapHandler {
                            enabled: prof.modelData.available && !prof.current
                            onTapped: root.au.setProfile(root.info.card, prof.modelData.name)
                        }
                    }
                }
            }
        }
    }

    // ══ every other device ═══════════════════════════════════════════════
    StyledText {
        visible: root.others.length > 0
        topPadding: 2
        text: root.output ? "Other outputs" : "Other inputs"
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.DemiBold
        color: Config.Appearance.ink3
    }
    Column {
        visible: root.others.length > 0
        width: root.width
        spacing: 2
        Repeater {
            model: root.others
            Rectangle {
                id: other
                required property var modelData
                readonly property var d: root.au.details(modelData)
                readonly property bool unplugged: !!d.port && !d.port.available
                width: root.width
                height: 50
                radius: Config.Appearance.rSm
                color: otherHover.hovered ? Config.Appearance.hover : "transparent"
                HoverHandler { id: otherHover }
                Rectangle {
                    id: oBadge
                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 32; height: 32; radius: 16
                    color: Config.Appearance.div
                    MonoIcon {
                        anchors.centerIn: parent
                        name: root.au.deviceGlyph(other.modelData)
                        size: 16; monochrome: true
                        inkColor: Config.Appearance.ink2
                    }
                }
                Column {
                    anchors.left: oBadge.right
                    anchors.leftMargin: 12
                    anchors.right: useBtn.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 1
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.au.displayName(other.modelData)
                        font.pixelSize: Config.Appearance.fs(13)
                        font.weight: Font.Medium
                    }
                    StyledText {
                        width: parent.width
                        elide: Text.ElideRight
                        text: [other.d.port ? other.d.port.description : "",
                               other.unplugged ? "unplugged" : ""].filter(s => s).join(" · ")
                        visible: text !== ""
                        font.pixelSize: Config.Appearance.fs(11.5)
                        color: Config.Appearance.ink3
                    }
                }
                NetButton {
                    id: useBtn
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    label: "Use"
                    onClicked: root.output ? root.au.setDefaultSink(other.modelData) : root.au.setDefaultSource(other.modelData)
                }
            }
        }
    }
}
