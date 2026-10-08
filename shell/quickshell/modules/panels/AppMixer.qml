import QtQuick
import Quickshell
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Control center → Volume → Apps: the volume mixer. The output's own level
// at the top, then one slider per app playing, each muted by tapping its
// icon. With the equalizer set to chosen apps, each row also says whether
// that app goes through it, and a tap on "EQ" changes that.
Column {
    id: root

    readonly property var au: Services.Audio
    readonly property var fx: Services.AudioFx
    readonly property var ap: Config.Appearance
    readonly property bool eqChoice: fx.eqWanted && fx.eqPerApp

    // Live volumes and app names need the streams bound.
    SteadyTracker { nodes: root.au.streams }

    // ── header ───────────────────────────────────────────────────────────
    Item {
        width: parent.width
        height: 50

        Rectangle {
            id: backBtn
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            width: 30; height: 30
            radius: root.ap.rSm
            color: backHover.hovered ? root.ap.hover : "transparent"
            MonoIcon {
                anchors.centerIn: parent
                name: "chevronLeft"; size: 15
                inkColor: root.ap.ink2; monochrome: true
            }
            HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: Config.UiState.ccExpanded = "" }
        }
        Column {
            anchors.left: backBtn.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            StyledText {
                text: "Volume mixer"
                font.pixelSize: root.ap.fs(13)
                font.weight: Font.DemiBold
            }
            StyledText {
                width: parent.width
                elide: Text.ElideRight
                text: root.au.streams.length === 0 ? "Nothing is playing"
                    : root.au.streams.length === 1 ? "1 app playing" : root.au.streams.length + " apps playing"
                font.pixelSize: root.ap.fs(11)
                color: root.ap.ink3
            }
        }
    }

    // ── one level ────────────────────────────────────────────────────────
    component Level: Column {
        id: lv
        property var node: null
        property string title: ""
        property string sub: ""
        property string icon: "speaker"
        property bool device: false
        readonly property bool muted: device ? root.au.muted : root.au.nodeMuted(node)
        readonly property real vol: device ? root.au.volume : root.au.nodeVolume(node)
        readonly property bool eqOn: !device && root.fx.isEqApp(node)

        width: parent ? parent.width : 0
        spacing: 7

        Item {
            width: parent.width
            height: 30
            Rectangle {
                id: badge
                width: 30; height: 30; radius: 15
                anchors.verticalCenter: parent.verticalCenter
                color: lv.muted ? root.ap.div : badgeHover.hovered ? root.ap.sel : root.ap.hover
                scale: badgeTap.pressed ? 0.88 : 1
                Behavior on scale { SpringAnimation { spring: 5; damping: 0.32; epsilon: 0.002 } }
                Behavior on color { ColorAnimation { duration: root.ap.anim(140) } }
                MonoIcon {
                    anchors.centerIn: parent
                    name: lv.muted ? "volumeX" : lv.icon
                    size: 15
                    inkColor: root.ap.ink2
                    accentColor: root.ap.accent
                    monochrome: lv.device || lv.muted
                }
                HoverHandler { id: badgeHover; cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    id: badgeTap
                    onTapped: lv.device ? root.au.setMuted(!lv.muted) : root.au.setNodeMuted(lv.node, !lv.muted)
                }
            }
            Column {
                anchors.left: badge.right
                anchors.leftMargin: 10
                anchors.right: eqPill.visible ? eqPill.left : pct.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1
                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: lv.title
                    font.pixelSize: root.ap.fs(12)
                    font.weight: Font.DemiBold
                }
                StyledText {
                    visible: text !== ""
                    width: parent.width
                    elide: Text.ElideRight
                    text: lv.sub
                    font.pixelSize: root.ap.fs(10.5)
                    color: root.ap.ink3
                }
            }
            Rectangle {
                id: eqPill
                visible: !lv.device && root.eqChoice
                anchors.right: pct.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: eqText.implicitWidth + 16
                height: 22
                radius: 11
                color: lv.eqOn ? root.ap.accent : eqHover.hovered ? root.ap.sel : "transparent"
                border.width: lv.eqOn ? 0 : 1
                border.color: root.ap.rule
                Behavior on color { ColorAnimation { duration: root.ap.anim(140) } }
                StyledText {
                    id: eqText
                    anchors.centerIn: parent
                    text: "EQ"
                    font.pixelSize: root.ap.fs(10.5)
                    font.weight: Font.DemiBold
                    color: lv.eqOn ? root.ap.inkOnAccent : root.ap.ink3
                }
                HoverHandler { id: eqHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.fx.setEqApp(lv.node, !lv.eqOn) }
            }
            StyledText {
                id: pct
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 38
                horizontalAlignment: Text.AlignRight
                text: lv.muted ? "muted" : Math.round(lv.vol * 100) + "%"
                font.pixelSize: root.ap.fs(11.5)
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
                color: lv.muted ? root.ap.ink3 : root.ap.ink
            }
        }
        FillSlider {
            width: parent.width
            trough: 16
            radius: 8
            opacity: lv.muted ? 0.55 : 1
            // Past 100% is the software boost; the slider spans whatever
            // ceiling Sound → Options allows.
            value: lv.vol / Math.max(1, root.au.maxVolume)
            onMoved: v => {
                const x = v * Math.max(1, root.au.maxVolume);
                if (lv.device) root.au.setVolume(x); else root.au.setNodeVolume(lv.node, x);
            }
        }
    }

    Column {
        x: 16
        width: parent.width - 32
        spacing: 14
        topPadding: 4
        bottomPadding: 8

        Level {
            device: true
            title: root.au.sinkName || "Output"
            sub: root.fx.eqWanted && !root.fx.eqPerApp ? "Through the equalizer" : ""
            icon: root.au.deviceGlyph(root.au.sink)
        }

        Rectangle { width: parent.width; height: 1; color: root.ap.rule; visible: root.au.streams.length > 0 }

        Flickable {
            id: appMixerScroll
            KineticScroll { flick: appMixerScroll }
            width: parent.width
            height: Math.min(300, appCol.implicitHeight)
            contentHeight: appCol.implicitHeight
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: appCol
                width: parent.width
                spacing: 14
                Repeater {
                    model: root.au.streams
                    Level {
                        required property var modelData
                        node: modelData
                        title: root.au.streamApp(modelData)
                        sub: root.au.streamMedia(modelData)
                        icon: Config.Apps.iconFor(root.au.streamHint(modelData))
                    }
                }
            }
        }

        StyledText {
            visible: root.au.streams.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Apps show here while they play sound, each with its own level."
            font.pixelSize: root.ap.fs(11.5)
            color: root.ap.ink3
        }
    }

    // ── footer ───────────────────────────────────────────────────────────
    Item {
        width: parent.width
        height: 44
        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: moreLabel.implicitWidth + 20
            height: 26
            radius: root.ap.rSm
            color: moreHover.hovered ? root.ap.sel : "transparent"
            StyledText {
                id: moreLabel
                anchors.centerIn: parent
                text: "Sound settings"
                font.pixelSize: root.ap.fs(11)
                font.weight: Font.DemiBold
                color: moreHover.hovered ? root.ap.ink : root.ap.ink3
            }
            HoverHandler { id: moreHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: Config.UiState.openSettings("Sound") }
        }
    }
}
