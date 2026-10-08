import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Settings → Sound.
//
// At the top, the output and the microphone in use with their levels —
// what most visits are for. Below, four tabs:
//
//   Output    every output with its level in the row; any one opened in
//             full (SoundInspector.qml); the equalizer (SoundEq.qml)
//   Input     every microphone the same way; noise suppression; hearing
//             yourself through the output
//   Apps      every app playing or recording, each with its own level and
//             device (SoundApps.qml)
//   Options   volume keys, the volume limit, switching to new devices,
//             and getting sound back when it has stopped
//
// Everything shown is bound to PipeWire while the pane is open, so it moves
// as other programs move it, and devices come and go as they are plugged
// in, paired or switched off.
Column {
    id: panel

    width: parent ? parent.width : 560
    spacing: 16

    readonly property var au: Services.Audio
    readonly property var fx: Services.AudioFx
    readonly property var prefs: Config.Appearance
    readonly property color danger: "#d93a2b"
    // The window this is in is on screen: the meters stop when it isn't,
    // so closing Settings never leaves a microphone open.
    readonly property bool shown: Config.UiState.settingsOpen && visible
                                  && !!Window.window && Window.window.visible
    readonly property string tab: ["output", "input", "apps", "options"].indexOf(prefs.soundTab) >= 0 ? prefs.soundTab : "output"

    // The device open in each tab's inspector: the one picked, while it is
    // still there, else the one in use.
    property string pickedOut: ""
    property string pickedIn: ""
    readonly property var inspectOut: au.sinks.find(n => n.name === pickedOut) || au.sink
    readonly property var inspectIn: au.sources.find(n => n.name === pickedIn) || au.source

    Component.onCompleted: au.watch(true)
    Component.onDestruction: au.watch(false)

    // Everything the pane shows, bound — steadily (SteadyTracker.qml): the
    // lists change as apps start and stop and as the equalizer comes and
    // goes, and binding and unbinding at that pace crashed Quickshell.
    SteadyTracker {
        nodes: panel.au.sinks.concat(panel.au.sources, panel.au.streams, panel.au.recorders,
                                     [panel.au.rawSink, panel.au.rawSource].filter(n => !!n))
    }

    component Caption: StyledText {
        font.pixelSize: Config.Appearance.fs(12)
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
        color: Config.Appearance.ink3
    }
    component Card: Rectangle {
        radius: Config.Appearance.r
        color: Config.Appearance.hover
        border.width: 1
        border.color: Config.Appearance.rule
    }
    component Line: StyledText {
        wrapMode: Text.WordWrap
        font.pixelSize: Config.Appearance.fs(12)
        color: Config.Appearance.ink3
    }

    // ══ no PipeWire ══════════════════════════════════════════════════════
    Card {
        visible: !panel.au.pipewireUp
        width: panel.width
        height: down.implicitHeight + 32
        border.width: 2
        border.color: Config.Appearance.accent
        Column {
            id: down
            x: 16; y: 16; width: parent.width - 32; spacing: 10
            StyledText { text: "PipeWire isn't running"; font.pixelSize: Config.Appearance.fs(15); font.weight: Font.DemiBold }
            Line {
                width: parent.width
                text: "Nothing can play or record until it is. Starting it again usually does it; if it keeps stopping, "
                      + "journalctl --user -u pipewire -u wireplumber says why."
            }
            NetButton {
                label: panel.au.restarting ? "Starting…" : "Start sound again"
                primary: true
                active: !panel.au.restarting
                onClicked: panel.au.restartAudio()
            }
        }
    }

    // ══ at a glance ══════════════════════════════════════════════════════
    Card {
        width: panel.width
        height: 118
        Row {
            x: 16; y: 14
            width: parent.width - 32
            height: parent.height - 28
            spacing: 16
            Repeater {
                model: [true, false]
                Item {
                    id: glance
                    required property var modelData
                    readonly property bool out: modelData
                    readonly property var n: out ? panel.au.sink : panel.au.source
                    readonly property bool muted: panel.au.nodeMuted(n)
                    readonly property real ceiling: out ? panel.au.maxVolume : 1.5
                    width: (parent.width - 16) / 2
                    height: parent.height

                    Rectangle {
                        id: gBadge
                        width: 38; height: 38; radius: 19
                        color: glance.muted || !glance.n ? Config.Appearance.div : Config.Appearance.accent
                        MonoIcon {
                            anchors.centerIn: parent
                            name: glance.muted ? (glance.out ? "volumeX" : "micOff")
                                : glance.out ? panel.au.deviceGlyph(glance.n) : "mic"
                            size: 18; monochrome: true
                            inkColor: glance.muted || !glance.n ? Config.Appearance.ink2 : Config.Appearance.inkOnAccent
                        }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: panel.au.setNodeMuted(glance.n, !glance.muted) }
                    }
                    Column {
                        anchors.left: gBadge.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.verticalCenter: gBadge.verticalCenter
                        spacing: 1
                        StyledText {
                            text: glance.out ? "Output" : "Microphone"
                            font.pixelSize: Config.Appearance.fs(11)
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 0.5
                            color: Config.Appearance.ink3
                        }
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: glance.n ? panel.au.displayName(glance.n) : (glance.out ? "No output" : "No microphone")
                            font.pixelSize: Config.Appearance.fs(13)
                            font.weight: Font.DemiBold
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            TapHandler { onTapped: panel.prefs.soundTab = glance.out ? "output" : "input" }
                        }
                    }
                    FillSlider {
                        takesWheel: false
                        id: gSlider
                        anchors.left: parent.left
                        anchors.right: gPct.left
                        anchors.rightMargin: 8
                        y: 52
                        trough: 14
                        showRule: true
                        enabled: !!glance.n
                        fillColor: glance.muted ? Config.Appearance.ink3 : Config.Appearance.accent
                        value: panel.au.nodeVolume(glance.n) / glance.ceiling
                        onMoved: v => panel.au.setNodeVolume(glance.n, v * glance.ceiling)
                        onReleased: v => panel.au.setNodeVolume(glance.n, v * glance.ceiling)
                    }
                    StyledText {
                        id: gPct
                        width: 42
                        anchors.right: parent.right
                        anchors.verticalCenter: gSlider.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        text: glance.muted ? "Muted" : Math.round(panel.au.nodeVolume(glance.n) * 100) + "%"
                        font.pixelSize: Config.Appearance.fs(12)
                        font.weight: Font.DemiBold
                    }
                    // What the microphone hears; what the output plays.
                    Loader {
                        id: gMeter
                        anchors.left: parent.left
                        anchors.right: gPct.left
                        anchors.rightMargin: 8
                        y: 76
                        height: 6
                        active: panel.shown && !!glance.n && panel.au.metersOn
                        source: "SoundLevel.qml"
                        onLoaded: {
                            item.node = Qt.binding(() => glance.n);
                            item.live = Qt.binding(() => panel.shown);
                        }
                    }
                    StyledText {
                        anchors.left: parent.left
                        y: 86
                        text: [glance.out && panel.au.eqActive ? "Equalizer on" : "",
                               !glance.out && panel.au.nsActive ? "Noise suppression on" : "",
                               !glance.out && panel.fx.listening ? "Listening through the output" : ""].filter(s => s).join(" · ")
                        font.pixelSize: Config.Appearance.fs(11)
                        color: Config.Appearance.accent
                    }
                }
            }
        }
    }

    // ══ tabs ═════════════════════════════════════════════════════════════
    Segmented {
        options: [{ label: "Output", value: "output" },
                  { label: "Input", value: "input" },
                  { label: "Apps" + (panel.au.streams.length + panel.au.recorders.length > 0
                                     ? "  " + (panel.au.streams.length + panel.au.recorders.length) : ""), value: "apps" },
                  { label: "Options", value: "options" }]
        value: panel.tab
        onSelected: v => panel.prefs.soundTab = v
    }

    // ── output ──
    Column {
        visible: panel.tab === "output"
        width: panel.width
        spacing: 14
        Caption { text: "Outputs" }
        SoundDeviceList {
            width: panel.width
            output: true
            selectedName: panel.inspectOut ? panel.inspectOut.name : ""
            onSelected: node => panel.pickedOut = node.name
        }
        SoundInspector {
            width: panel.width
            output: true
            node: panel.inspectOut
            shown: panel.shown && panel.tab === "output"
        }
        Caption { text: "Equalizer" }
        SoundEq { width: panel.width }
    }

    // ── input ──
    Column {
        visible: panel.tab === "input"
        width: panel.width
        spacing: 14
        Caption { text: "Inputs" }
        SoundDeviceList {
            width: panel.width
            output: false
            selectedName: panel.inspectIn ? panel.inspectIn.name : ""
            onSelected: node => panel.pickedIn = node.name
        }
        SoundInspector {
            width: panel.width
            output: false
            node: panel.inspectIn
            shown: panel.shown && panel.tab === "input"
        }

        Caption { text: "Microphone effects" }
        // Noise suppression.
        Card {
            width: panel.width
            height: nsCol.implicitHeight + 32
            border.color: panel.fx.nsStatus === "error" && panel.prefs.nsEnabled ? panel.danger : Config.Appearance.rule
            Column {
                id: nsCol
                x: 16; y: 16; width: parent.width - 32; spacing: 12
                Item {
                    width: parent.width
                    height: 40
                    Rectangle {
                        id: nsBadge
                        width: 40; height: 40; radius: 20
                        color: panel.prefs.nsEnabled ? Config.Appearance.accent : Config.Appearance.div
                        MonoIcon {
                            anchors.centerIn: parent
                            name: "mic"; size: 19; monochrome: true
                            inkColor: panel.prefs.nsEnabled ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                        }
                    }
                    Column {
                        anchors.left: nsBadge.right
                        anchors.leftMargin: 12
                        anchors.right: nsToggle.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        StyledText { text: "Noise suppression"; font.pixelSize: Config.Appearance.fs(15); font.weight: Font.DemiBold }
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: !panel.fx.probed ? "Checking…"
                                : !panel.fx.nsAvailable ? "Needs the RNNoise plugin — install noise-suppression-for-voice"
                                : !panel.prefs.nsEnabled ? "Off — keyboard, fans and traffic go out with your voice"
                                : panel.fx.nsStatus === "starting" ? "Starting…"
                                : panel.fx.nsStatus === "error" ? "Didn't start — see below"
                                : "On, for " + (panel.au.source ? panel.au.displayName(panel.au.source) : "the microphone")
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink3
                        }
                    }
                    Toggle {
                        id: nsToggle
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        enabled: panel.fx.nsAvailable
                        checked: panel.prefs.nsEnabled
                        onToggled: on => panel.fx.setNsEnabled(on)
                    }
                }
                Item {
                    visible: panel.fx.nsAvailable
                    width: parent.width
                    height: 22
                    StyledText {
                        id: thLabel
                        width: 96
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Strictness"
                        font.pixelSize: Config.Appearance.fs(12)
                        color: Config.Appearance.ink2
                    }
                    FillSlider {
                        takesWheel: false
                        anchors.left: thLabel.right
                        anchors.right: thValue.left
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        trough: 12
                        showRule: true
                        value: panel.prefs.nsThreshold / 99
                        onMoved: v => panel.fx.setNsThreshold(v * 99)
                        onReleased: v => panel.fx.setNsThreshold(v * 99)
                    }
                    StyledText {
                        id: thValue
                        width: 46
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        horizontalAlignment: Text.AlignRight
                        text: panel.prefs.nsThreshold + "%"
                        font.pixelSize: Config.Appearance.fs(12)
                    }
                }
                Line {
                    width: parent.width
                    text: panel.fx.nsStatus === "error" && panel.prefs.nsEnabled ? panel.fx.nsError
                        : "How sure it has to be that it hears a voice before letting sound through. Higher cuts more "
                          + "noise and, past a point, the start of words. Apps hear a new input, “Microphone (noise "
                          + "suppressed)”, which becomes the default."
                    color: panel.fx.nsStatus === "error" && panel.prefs.nsEnabled ? panel.danger : Config.Appearance.ink3
                }
                NetButton {
                    visible: panel.fx.nsStatus === "error" && panel.prefs.nsEnabled
                    label: "Try again"
                    onClicked: panel.fx.retryNs()
                }
            }
        }
        // Hear yourself.
        Card {
            width: panel.width
            height: lsCol.implicitHeight + 32
            Column {
                id: lsCol
                x: 16; y: 16; width: parent.width - 32; spacing: 10
                Item {
                    width: parent.width
                    height: 40
                    Rectangle {
                        id: lsBadge
                        width: 40; height: 40; radius: 20
                        color: panel.fx.listening ? Config.Appearance.accent : Config.Appearance.div
                        MonoIcon {
                            anchors.centerIn: parent
                            name: "headphones"; size: 19; monochrome: true
                            inkColor: panel.fx.listening ? Config.Appearance.inkOnAccent : Config.Appearance.ink2
                        }
                    }
                    Column {
                        anchors.left: lsBadge.right
                        anchors.leftMargin: 12
                        anchors.right: lsToggle.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        StyledText { text: "Listen to this microphone"; font.pixelSize: Config.Appearance.fs(15); font.weight: Font.DemiBold }
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: panel.fx.listening
                                  ? "Playing " + panel.au.displayName(panel.au.sources.find(n => n.name === panel.fx.listenSource)) + " through " + panel.au.displayName(panel.au.sink)
                                  : "Hear what " + (panel.inspectIn ? panel.au.displayName(panel.inspectIn) : "the microphone") + " picks up, live"
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink3
                        }
                    }
                    Toggle {
                        id: lsToggle
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        enabled: !panel.au.pactlMissing && !!panel.inspectIn
                        checked: panel.fx.listening
                        onToggled: on => panel.fx.listen(on, panel.inspectIn)
                    }
                }
                Line {
                    width: parent.width
                    text: "Use headphones: through speakers it feeds back. Switches itself off when the shell restarts."
                }
            }
        }
    }

    // ── apps ──
    SoundApps {
        visible: panel.tab === "apps"
        width: panel.width
    }

    // ── options ──
    Column {
        visible: panel.tab === "options"
        width: panel.width
        spacing: 14

        Caption { text: "Volume" }
        Card {
            width: panel.width
            height: opts.implicitHeight + 24
            Column {
                id: opts
                x: 16; y: 12; width: parent.width - 32; spacing: 14

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
                        value: String(panel.prefs.volumeStep)
                        onSelected: v => panel.prefs.volumeStep = parseInt(v)
                    }
                }
                Column {
                    id: limitBox
                    width: parent.width
                    spacing: 8
                    readonly property int limit: Math.max(panel.prefs.volumeMax, panel.prefs.volumeBoost ? 150 : 0)
                    Item {
                        width: parent.width
                        height: 34
                        Column {
                            anchors.left: parent.left
                            anchors.right: limitValue.left
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            StyledText { text: "Maximum volume"; font.pixelSize: Config.Appearance.fs(13) }
                            StyledText {
                                width: parent.width
                                elide: Text.ElideRight
                                text: limitBox.limit < 100 ? "A limit, to protect your hearing — nothing goes louder than this"
                                    : limitBox.limit > 100 ? "Past 100% is software boost: louder, and loud passages distort"
                                    : "100% — as loud as the device goes without distortion"
                                font.pixelSize: Config.Appearance.fs(11.5)
                                color: Config.Appearance.ink3
                            }
                        }
                        StyledText {
                            id: limitValue
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: limitBox.limit + "%"
                            font.pixelSize: Config.Appearance.fs(13)
                            font.weight: Font.DemiBold
                            color: limitBox.limit > 100 ? panel.danger : Config.Appearance.ink
                        }
                    }
                    FillSlider {
                        takesWheel: false
                        width: parent.width
                        trough: 12
                        showRule: true
                        // 30% to 150%, in steps of 5.
                        value: (limitBox.limit - 30) / 120
                        onMoved: v => { panel.prefs.volumeBoost = false; panel.prefs.volumeMax = Math.round((30 + v * 120) / 5) * 5; }
                        onReleased: v => {
                            panel.prefs.volumeBoost = false;
                            panel.prefs.volumeMax = Math.round((30 + v * 120) / 5) * 5;
                            if (panel.au.volume > panel.au.maxVolume) panel.au.setVolume(panel.au.maxVolume);
                        }
                        Rectangle {
                            x: parent.width * (70 / 120) - 1
                            y: -3; width: 2; height: parent.height + 6
                            color: Config.Appearance.ink3
                            opacity: 0.6
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
                        checked: panel.prefs.volumeFeedback
                        onToggled: on => panel.prefs.volumeFeedback = on
                    }
                }
            }
        }

        Caption { text: "Devices" }
        Card {
            width: panel.width
            height: devOpts.implicitHeight + 24
            Column {
                id: devOpts
                x: 16; y: 12; width: parent.width - 32; spacing: 14
                Item {
                    width: parent.width
                    height: 34
                    Column {
                        anchors.left: parent.left
                        anchors.right: autoToggle.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        StyledText { text: "Switch to new devices"; font.pixelSize: Config.Appearance.fs(13) }
                        StyledText { text: "Headphones that connect over Bluetooth or USB become the output (or input) in use"; width: parent.width; elide: Text.ElideRight; font.pixelSize: Config.Appearance.fs(11.5); color: Config.Appearance.ink3 }
                    }
                    Toggle {
                        id: autoToggle
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        checked: panel.prefs.soundAutoSwitch
                        onToggled: on => panel.prefs.soundAutoSwitch = on
                    }
                }
                Item {
                    width: parent.width
                    height: 34
                    Column {
                        anchors.left: parent.left
                        anchors.right: meterToggle.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        StyledText { text: "Live level meters"; font.pixelSize: Config.Appearance.fs(13) }
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: panel.au.metersSafe
                                ? "What each device is playing or hearing, as it happens"
                                : "Needs Quickshell 0.3.1 or newer — the meter in "
                                  + (panel.au.qsVersion || "this version") + " can crash the shell"
                            font.pixelSize: Config.Appearance.fs(11.5)
                            color: Config.Appearance.ink3
                        }
                    }
                    Toggle {
                        id: meterToggle
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        enabled: panel.au.metersSafe
                        checked: panel.au.metersOn
                        onToggled: on => panel.prefs.soundMeters = on
                    }
                }
                Item {
                    width: parent.width
                    height: 34
                    Column {
                        anchors.left: parent.left
                        anchors.right: resetNames.left
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        StyledText { text: "Names and hidden devices"; font.pixelSize: Config.Appearance.fs(13) }
                        StyledText {
                            width: parent.width
                            elide: Text.ElideRight
                            text: Object.keys(panel.au.nicknames).length + " renamed, " + panel.au.hiddenNames.length + " hidden — set in each device's details"
                            font.pixelSize: Config.Appearance.fs(11.5)
                            color: Config.Appearance.ink3
                        }
                    }
                    NetButton {
                        id: resetNames
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        label: "Reset all"
                        active: Object.keys(panel.au.nicknames).length + panel.au.hiddenNames.length > 0
                        onClicked: { panel.prefs.soundNames = "{}"; panel.prefs.soundHidden = "[]"; }
                    }
                }
            }
        }

        Caption { text: "Sound not working?" }
        Card {
            width: panel.width
            height: fix.implicitHeight + 24
            border.color: panel.au.lastError !== "" ? panel.danger : Config.Appearance.rule
            Column {
                id: fix
                x: 16; y: 12; width: parent.width - 32; spacing: 10
                Line {
                    width: parent.width
                    color: Config.Appearance.ink2
                    text: "A headset stuck in the wrong mode, a device that came back silent, crackling after sleep: restarting "
                          + "the sound services fixes most of it, at the cost of a second of silence."
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
                        onClicked: { panel.au.refreshDetails(); panel.fx.reprobe(); }
                    }
                    NetButton {
                        label: "Advanced mixer"
                        onClicked: Config.Apps.launch(["sh", "-c",
                            'for m in pavucontrol pwvucontrol pavucontrol-qt; do command -v "$m" >/dev/null 2>&1 && exec "$m"; done; '
                            + 'notify-send "Sound" "No mixer installed — pavucontrol or pwvucontrol" 2>/dev/null'])
                    }
                }
                Line {
                    visible: panel.au.pactlMissing
                    width: parent.width
                    text: "pactl isn't installed, so connectors, card modes, delays and moving an app to another device "
                          + "aren't available. It comes with pipewire-pulse (or libpulse)."
                }
                Line {
                    visible: panel.au.lastError !== ""
                    width: parent.width
                    text: panel.au.lastError
                    color: panel.danger
                }
            }
        }
    }
}
