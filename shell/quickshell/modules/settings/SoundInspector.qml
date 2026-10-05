import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Sound: everything about one device — whichever is picked in
// the list above (SoundDeviceList.qml), in use or not.
//
// Level and mute; balance, and fade on surround; every channel on its own;
// a live meter of what it is playing or hearing; test sounds; which
// connector it uses and the mode its card is in; a delay to bring sound
// and picture back into step; what format it runs at; and a name and a
// place in the list of your choosing.
Rectangle {
    id: root

    property var node: null
    property bool output: true
    property bool shown: true               // false while the window is hidden: stops the meter

    readonly property var au: Services.Audio
    readonly property var current: output ? au.sink : au.source
    readonly property bool inUse: !!node && !!current && current.name === node.name
    // details() reads the pactl tables, so this follows them as they change.
    readonly property var info: au.details(node)
    readonly property bool muted: au.nodeMuted(node)
    readonly property color danger: "#d93a2b"
    readonly property real labelW: 96

    property bool channelsOpen: false
    property bool profilesOpen: false
    property bool detailsOpen: false
    property bool renaming: false
    property string nameDraft: ""

    onNodeChanged: { channelsOpen = false; profilesOpen = false; renaming = false; }

    visible: !!node
    height: col.implicitHeight + 32
    radius: Config.Appearance.r
    color: Config.Appearance.hover
    border.width: 1
    border.color: Config.Appearance.rule

    component Label: StyledText {
        width: root.labelW
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink2
    }
    component Hint: StyledText {
        font.pixelSize: Config.Appearance.fs(11.5)
        color: Config.Appearance.ink3
    }

    Column {
        id: col
        x: 16; y: 16; width: parent.width - 32; spacing: 14

        // ── who it is ──
        Item {
            width: parent.width
            height: 42
            Rectangle {
                id: badge
                width: 42; height: 42; radius: 21
                color: root.muted ? Config.Appearance.div : Config.Appearance.accent
                MonoIcon {
                    anchors.centerIn: parent
                    name: root.muted ? (root.output ? "volumeX" : "micOff") : root.au.deviceGlyph(root.node)
                    size: 21; monochrome: true
                    inkColor: root.muted ? Config.Appearance.ink2 : Config.Appearance.inkOnAccent
                }
            }
            Column {
                anchors.left: badge.right
                anchors.leftMargin: 12
                anchors.right: headButtons.left
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
                    text: [root.inUse ? (root.output ? "The output in use" : "The microphone in use") : "Not in use",
                           root.au.displayName(root.node) !== root.au.driverName(root.node) ? root.au.driverName(root.node) : "",
                           root.muted ? "muted" : ""].filter(s => s).join(" · ")
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }
            }
            Row {
                id: headButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                NetButton {
                    visible: !root.inUse
                    label: "Use this"
                    primary: true
                    onClicked: root.output ? root.au.setDefaultSink(root.node) : root.au.setDefaultSource(root.node)
                }
                NetButton {
                    label: root.muted ? "Unmute" : "Mute"
                    primary: root.muted
                    onClicked: root.au.setNodeMuted(root.node, !root.muted)
                }
            }
        }

        // ── level ──
        Item {
            width: parent.width
            height: 22
            Label { id: volLabel; anchors.verticalCenter: parent.verticalCenter; text: root.output ? "Volume" : "Input level" }
            Rectangle {
                id: minus
                anchors.left: volLabel.right
                anchors.verticalCenter: parent.verticalCenter
                width: 22; height: 22; radius: 11
                color: minusHover.hovered ? Config.Appearance.div : "transparent"
                MonoIcon { anchors.centerIn: parent; name: "minus"; size: 12; monochrome: true; inkColor: Config.Appearance.ink2 }
                HoverHandler { id: minusHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.au.setNodeVolume(root.node, root.au.nodeVolume(root.node) - Config.Appearance.volumeStep / 100) }
            }
            FillSlider {
                id: vol
                anchors.left: minus.right
                anchors.leftMargin: 6
                anchors.right: plus.left
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                trough: 14
                showRule: true
                readonly property real ceiling: root.output ? root.au.maxVolume : 1.5
                fillColor: root.muted ? Config.Appearance.ink3 : Config.Appearance.accent
                value: root.au.nodeVolume(root.node) / ceiling
                onMoved: v => root.au.setNodeVolume(root.node, v * ceiling)
                onReleased: v => root.au.setNodeVolume(root.node, v * ceiling)
                Rectangle {
                    visible: vol.ceiling > 1
                    x: parent.width / vol.ceiling - 1
                    y: -3; width: 2; height: parent.height + 6
                    color: Config.Appearance.ink3
                    opacity: 0.6
                }
            }
            Rectangle {
                id: plus
                anchors.right: volValue.left
                anchors.rightMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                width: 22; height: 22; radius: 11
                color: plusHover.hovered ? Config.Appearance.div : "transparent"
                MonoIcon { anchors.centerIn: parent; name: "plus"; size: 12; monochrome: true; inkColor: Config.Appearance.ink2 }
                HoverHandler { id: plusHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.au.setNodeVolume(root.node, root.au.nodeVolume(root.node) + Config.Appearance.volumeStep / 100) }
            }
            StyledText {
                id: volValue
                width: 46
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                text: Math.round(root.au.nodeVolume(root.node) * 100) + "%"
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                color: root.au.nodeVolume(root.node) > 1.001 ? root.danger : Config.Appearance.ink
            }
        }

        // ── live level ──
        Item {
            visible: root.au.metersOn || !root.au.metersSafe
            width: parent.width
            height: 22
            Label { id: meterLabel; anchors.verticalCenter: parent.verticalCenter; text: root.output ? "Playing" : "Hearing" }
            Loader {
                id: meter
                anchors.left: meterLabel.right
                anchors.right: parent.right
                anchors.rightMargin: 50
                anchors.verticalCenter: parent.verticalCenter
                height: 10
                active: root.shown && !!root.node && root.au.metersOn
                source: "SoundLevel.qml"
                onLoaded: {
                    item.node = Qt.binding(() => root.node);
                    item.live = Qt.binding(() => root.shown);
                }
            }
            Hint {
                visible: meter.status === Loader.Error || !root.au.metersSafe
                anchors.left: meterLabel.right
                anchors.verticalCenter: parent.verticalCenter
                text: "A live meter needs Quickshell 0.3.1 or newer"
            }
        }

        // ── balance and fade ──
        Item {
            visible: root.au.hasBalance(root.node)
            width: parent.width
            height: 22
            Label { id: balLabel; anchors.verticalCenter: parent.verticalCenter; text: "Balance" }
            Hint { id: lMark; anchors.left: balLabel.right; anchors.verticalCenter: parent.verticalCenter; text: "L" }
            SoundCenterSlider {
                anchors.left: lMark.right
                anchors.leftMargin: 8
                anchors.right: rMark.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                value: root.au.balance(root.node)
                onMoved: v => root.au.setBalance(root.node, v)
            }
            Hint { id: rMark; anchors.right: balValue.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: "R" }
            StyledText {
                id: balValue
                width: 46
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                readonly property real b: root.au.balance(root.node)
                text: Math.abs(b) < 0.01 ? "Centre" : Math.round(Math.abs(b) * 100) + (b < 0 ? " L" : " R")
                font.pixelSize: Config.Appearance.fs(12)
            }
        }
        Item {
            visible: root.au.hasFade(root.node)
            width: parent.width
            height: 22
            Label { id: fadeLabel; anchors.verticalCenter: parent.verticalCenter; text: "Fade" }
            Hint { id: fMark; anchors.left: fadeLabel.right; anchors.verticalCenter: parent.verticalCenter; text: "Front" }
            SoundCenterSlider {
                anchors.left: fMark.right
                anchors.leftMargin: 8
                anchors.right: bMark.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                value: root.au.fade(root.node)
                onMoved: v => root.au.setFade(root.node, v)
            }
            Hint { id: bMark; anchors.right: fadeValue.left; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: "Rear" }
            StyledText {
                id: fadeValue
                width: 46
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                readonly property real f: root.au.fade(root.node)
                text: Math.abs(f) < 0.01 ? "Centre" : Math.round(Math.abs(f) * 100) + (f < 0 ? " F" : " R")
                font.pixelSize: Config.Appearance.fs(12)
            }
        }

        // ── each channel ──
        Column {
            visible: !!root.node && !!root.node.audio && (root.node.audio.channels || []).length > 1
            width: parent.width
            spacing: 6
            Item {
                width: parent.width
                height: 22
                Label { id: chLabel; anchors.verticalCenter: parent.verticalCenter; text: "Channels" }
                Hint {
                    anchors.left: chLabel.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.node && root.node.audio ? (root.node.audio.channels || []).length + " — "
                          + (root.channelsOpen ? "hide" : "set each one") : ""
                    color: Config.Appearance.accent
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.channelsOpen = !root.channelsOpen }
                }
            }
            Repeater {
                model: root.channelsOpen && root.node && root.node.audio ? (root.node.audio.channels || []).length : 0
                Item {
                    id: chRow
                    required property int index
                    readonly property real v: root.node && root.node.audio ? (root.node.audio.volumes[index] || 0) : 0
                    width: col.width
                    height: 20
                    StyledText {
                        id: chName
                        x: root.labelW
                        width: 90
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: root.au.channelName(root.node.audio.channels[chRow.index])
                        font.pixelSize: Config.Appearance.fs(11.5)
                        color: Config.Appearance.ink2
                    }
                    FillSlider {
                        anchors.left: chName.right
                        anchors.leftMargin: 6
                        anchors.right: chPct.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        trough: 8
                        showRule: true
                        readonly property real ceiling: root.output ? root.au.maxVolume : 1.5
                        value: chRow.v / ceiling
                        onMoved: val => root.au.setChannelVolume(root.node, chRow.index, val * ceiling)
                        onReleased: val => root.au.setChannelVolume(root.node, chRow.index, val * ceiling)
                    }
                    StyledText {
                        id: chPct
                        width: 46
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(chRow.v * 100) + "%"
                        font.pixelSize: Config.Appearance.fs(11.5)
                        color: Config.Appearance.ink2
                    }
                }
            }
        }

        // ── test ──
        Flow {
            visible: root.output
            width: parent.width
            spacing: 6
            Label { height: 30; verticalAlignment: Text.AlignVCenter; text: "Test" }
            NetButton { label: "Play a sound"; onClicked: root.au.testSound(root.node) }
            Repeater {
                model: root.output && root.au.channelInfo(root.node).length > 1 ? root.au.channelInfo(root.node) : []
                NetButton {
                    required property var modelData
                    label: modelData.label
                    onClicked: root.au.testChannel(root.node, modelData)
                }
            }
        }

        // ── connector ──
        Flow {
            visible: (root.info.ports || []).length > 1
            width: parent.width
            spacing: 6
            Label { height: 30; verticalAlignment: Text.AlignVCenter; text: "Connector" }
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

        // ── the card's mode ──
        Column {
            visible: !!root.info.card && root.info.card.profiles.length > 1
            width: parent.width
            spacing: 4
            Item {
                width: parent.width
                height: 30
                Label { id: modeLabel; anchors.verticalCenter: parent.verticalCenter; text: "Mode" }
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
            Hint {
                visible: root.profilesOpen
                width: parent.width
                wrapMode: Text.WordWrap
                leftPadding: root.labelW
                text: root.output
                      ? "A Bluetooth headset has a high-quality mode for listening and a headset mode that turns its microphone on at call quality; the codec is part of the name. HDMI and surround cards list each speaker layout. “Off” switches the card off."
                      : "A Bluetooth headset's microphone only works in its headset mode, which lowers what you hear to call quality."
            }
            Repeater {
                model: root.profilesOpen && root.info.card ? root.info.card.profiles : []
                Rectangle {
                    id: prof
                    required property var modelData
                    readonly property bool current: !!root.info.card && modelData.name === root.info.card.activeProfile
                    x: root.labelW
                    width: col.width - root.labelW
                    height: 30
                    radius: Config.Appearance.rSm
                    opacity: modelData.available ? 1 : 0.5
                    color: prof.current ? Config.Appearance.sel : profHover.hovered ? Config.Appearance.div : "transparent"
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

        // ── sync ──
        // Up to half a second either way; applied once the slider rests,
        // since each change is a command to PipeWire.
        Column {
            visible: !!root.info.canOffset
            width: parent.width
            spacing: 4
            Item {
                width: parent.width
                height: 22
                property real draft: root.info.latencyOffsetMs || 0
                Label { id: syncLabel; anchors.verticalCenter: parent.verticalCenter; text: "Delay" }
                SoundCenterSlider {
                    anchors.left: syncLabel.right
                    anchors.right: syncValue.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    value: parent.draft / 500
                    onMoved: v => { parent.draft = Math.round(v * 500 / 10) * 10; syncApply.restart(); }
                }
                StyledText {
                    id: syncValue
                    width: 60
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignRight
                    text: (parent.draft > 0 ? "+" : "") + parent.draft + " ms"
                    font.pixelSize: Config.Appearance.fs(12)
                }
                Timer {
                    id: syncApply
                    interval: 350
                    onTriggered: root.au.setLatencyOffset(root.node, parent.draft)
                }
            }
            Hint {
                width: parent.width
                wrapMode: Text.WordWrap
                leftPadding: root.labelW
                text: root.output
                      ? "Sound ahead of the picture — common on Bluetooth — moves right. Kept for this connector."
                      : "Shifts this microphone in time against other sound, for recording in step."
            }
        }

        // ── format and the rest ──
        Column {
            width: parent.width
            spacing: 4
            Item {
                width: parent.width
                height: 20
                Label { id: detLabel; anchors.verticalCenter: parent.verticalCenter; text: "Details" }
                Hint {
                    anchors.left: detLabel.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: [root.info.spec || "", root.info.props && root.info.props.codec ? root.info.props.codec.toUpperCase() : ""].filter(s => s).join(" · ")
                          + (root.detailsOpen ? "  — hide" : "  — more")
                    color: Config.Appearance.accent
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.detailsOpen = !root.detailsOpen }
                }
            }
            Repeater {
                model: !root.detailsOpen || !root.node ? [] : [
                    ["Format", root.info.spec || "—"],
                    ["Channels", (root.info.channelMap || "—").split(",").join(", ")],
                    ["Latency", root.info.latencyUs ? (root.info.latencyUs / 1000).toFixed(1) + " ms" : "—"],
                    ["State", root.info.state ? root.info.state.toLowerCase() : "—"],
                    ["Codec", root.info.props && root.info.props.codec ? root.info.props.codec.toUpperCase() : ""],
                    ["Connection", root.info.props ? [root.info.props.bus, root.info.props.api].filter(s => s).join(" · ") : ""],
                    ["Card", root.info.props ? root.info.props.card : ""],
                    ["Address", root.info.props ? root.info.props.path : ""],
                    ["PipeWire name", root.node.name],
                    ["Node", "#" + root.node.id]
                ].filter(r => r[1] !== "")
                Item {
                    required property var modelData
                    width: col.width
                    height: 18
                    StyledText {
                        x: root.labelW
                        width: 110
                        text: modelData[0]
                        font.pixelSize: Config.Appearance.fs(11.5)
                        color: Config.Appearance.ink3
                    }
                    StyledText {
                        x: root.labelW + 110
                        width: col.width - root.labelW - 110
                        elide: Text.ElideMiddle
                        text: modelData[1]
                        font.pixelSize: Config.Appearance.fs(11.5)
                        font.family: Config.Appearance.monoFamily
                    }
                }
            }
        }

        // ── name, and the list ──
        Item {
            width: parent.width
            height: 30
            Label { id: nameLabel; anchors.verticalCenter: parent.verticalCenter; text: "Name" }
            StyledText {
                visible: !root.renaming
                anchors.left: nameLabel.right
                anchors.right: nameButtons.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                text: root.au.displayName(root.node)
                font.pixelSize: Config.Appearance.fs(12)
            }
            NetField {
                visible: root.renaming
                anchors.left: nameLabel.right
                anchors.right: nameButtons.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                placeholder: root.au.driverName(root.node)
                text: root.nameDraft
                onEdited: t => root.nameDraft = t
                onAccepted: { root.au.setNickname(root.node, root.nameDraft); root.renaming = false; }
            }
            Row {
                id: nameButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                NetButton {
                    label: root.renaming ? "Save" : "Rename"
                    primary: root.renaming
                    onClicked: {
                        if (root.renaming) { root.au.setNickname(root.node, root.nameDraft); root.renaming = false; }
                        else { root.nameDraft = root.au.nicknames[root.node.name] || ""; root.renaming = true; }
                    }
                }
                NetButton {
                    visible: root.renaming || !!root.au.nicknames[root.node ? root.node.name : ""]
                    label: root.renaming ? "Cancel" : "Original name"
                    onClicked: {
                        if (root.renaming) root.renaming = false;
                        else root.au.setNickname(root.node, "");
                    }
                }
                NetButton {
                    visible: !root.renaming
                    label: root.au.isHidden(root.node) ? "Show in list" : "Hide from list"
                    onClicked: root.au.setHidden(root.node, !root.au.isHidden(root.node))
                }
            }
        }
    }
}
