import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The capture panel (Print): a picture or a video, of a region, a window,
// a screen or all of them, with the shell's own controls — a segmented
// switch for what kind, cards for what of, and settings-style rows for
// the rest — and one accent button that does it. Text reads a region's
// words onto the clipboard (services/Capture.qml does the work).
PanelSurface {
    id: root

    readonly property var cap: Services.Capture
    readonly property var ap: Config.Appearance
    property bool video: false
    property string mode: "region"

    implicitWidth: 404
    implicitHeight: col.implicitHeight + 32
    showSeam: false

    Binding {
        target: Config.UiState
        property: "panelWantsKeyboard"
        value: true
        when: Config.UiState.captureOpen
    }
    Item {
        focus: Config.UiState.captureOpen
        Keys.onEscapePressed: Config.UiState.closeAll()
        Keys.onReturnPressed: root.go()
        Keys.onEnterPressed: root.go()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_R) root.mode = "region";
            else if (event.key === Qt.Key_W && !root.video) root.mode = "window";
            else if (event.key === Qt.Key_S) root.mode = "screen";
            else if (event.key === Qt.Key_V) root.video = !root.video;
            else return;
            event.accepted = true;
        }
    }
    // A video has no window or all-screens choice: fall back to the region.
    onVideoChanged: if (video && (mode === "window" || mode === "all")) mode = "region"

    function go() {
        if (video) cap.record(mode, ap.captureAudio);
        else cap.shot(mode);
    }

    readonly property var modes: video
        ? [["region", "lasso", "Region"], ["screen", "monitor", "Screen"]]
        : [["region", "lasso", "Region"], ["window", "square", "Window"], ["screen", "monitor", "Screen"], ["all", "grid", "All screens"]]

    // A choice of what to take: a card that lights up in the accent.
    component ModeCard: Rectangle {
        id: card
        property string icon: ""
        property string label: ""
        property bool on: false
        signal clicked
        height: 74
        radius: Config.Appearance.rSm
        color: tint.value
        border.width: 1.5
        border.color: edge.value
        ColorSpring {
            id: tint
            to: card.on ? Qt.rgba(Config.Appearance.accent.r, Config.Appearance.accent.g, Config.Appearance.accent.b, 0.14)
                        : (cardHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
        }
        ColorSpring { id: edge; to: card.on ? Config.Appearance.accent : Config.Appearance.rule }
        scale: press.value
        Spring { id: press; to: cardTap.pressed ? 0.95 : 1; response: 260 }
        Column {
            anchors.centerIn: parent
            spacing: 7
            MonoIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: card.icon
                size: 22
                inkColor: card.on ? Config.Appearance.accent : Config.Appearance.ink
                accentColor: Config.Appearance.accent
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: card.label
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                color: card.on ? Config.Appearance.ink : Config.Appearance.ink2
            }
        }
        HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { id: cardTap; onTapped: card.clicked() }
    }

    // A settings-style row: what it is on the left, its control on the right.
    component OptionRow: Item {
        id: optRow
        property string label: ""
        property string hint: ""
        default property alias control: slot.data
        width: parent ? parent.width : 0
        height: 44
        Column {
            anchors.left: parent.left
            anchors.leftMargin: 14
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: slot.left
            anchors.rightMargin: 10
            spacing: 1
            StyledText {
                text: optRow.label
                font.pixelSize: Config.Appearance.fs(13)
                color: Config.Appearance.ink
                elide: Text.ElideRight
                width: parent.width
            }
            StyledText {
                visible: optRow.hint !== ""
                text: optRow.hint
                font.pixelSize: Config.Appearance.fs(11)
                color: Config.Appearance.ink3
                elide: Text.ElideRight
                width: parent.width
            }
        }
        Item {
            id: slot
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    Column {
        id: col
        x: 16; y: 16
        width: root.width - 32
        spacing: 14

        // What kind.
        Item {
            width: parent.width
            height: 32
            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 9
                MonoIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: root.video ? "film" : "camera"
                    size: 18
                    inkColor: Config.Appearance.ink
                    accentColor: Config.Appearance.accent
                }
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.video ? "Record the screen" : "Screenshot"
                    font.pixelSize: Config.Appearance.fs(15)
                    font.weight: Font.DemiBold
                    color: Config.Appearance.ink
                }
            }
            Segmented {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                options: ["Picture", "Video"]
                value: root.video ? "Video" : "Picture"
                onSelected: v => root.video = v === "Video"
            }
        }

        // What of.
        Row {
            id: modeRow
            width: parent.width
            spacing: 8
            Repeater {
                model: root.modes
                ModeCard {
                    required property var modelData
                    width: (modeRow.width - modeRow.spacing * (root.modes.length - 1)) / root.modes.length
                    icon: modelData[1]
                    label: modelData[2]
                    on: root.mode === modelData[0]
                    onClicked: root.mode = modelData[0]
                }
            }
        }

        // How.
        Rectangle {
            width: parent.width
            height: opts.implicitHeight
            radius: Config.Appearance.r
            color: Config.Appearance.hover
            border.width: 1
            border.color: Config.Appearance.rule
            Column {
                id: opts
                width: parent.width

                OptionRow {
                    visible: !root.video
                    label: "Delay"
                    Segmented {
                        segmentPadding: 9
                        options: [{ label: "Off", value: "0" }, { label: "3 s", value: "3" }, { label: "5 s", value: "5" }, { label: "10 s", value: "10" }]
                        value: String(root.ap.captureDelay)
                        onSelected: v => root.ap.captureDelay = parseInt(v)
                    }
                }
                OptionRow {
                    visible: root.video
                    label: "Sound"
                    Segmented {
                        segmentPadding: 9
                        options: [{ label: "None", value: "none" }, { label: "Desktop", value: "desktop" }, { label: "Microphone", value: "mic" }]
                        value: root.ap.captureAudio
                        onSelected: v => root.ap.captureAudio = v
                    }
                }
                Rectangle { width: parent.width - 28; x: 14; height: 1; color: Config.Appearance.rule }
                OptionRow {
                    label: "Show the pointer"
                    Toggle { checked: root.ap.capturePointer; onToggled: c => root.ap.capturePointer = c }
                }
                Rectangle { visible: !root.video; width: parent.width - 28; x: 14; height: 1; color: Config.Appearance.rule }
                OptionRow {
                    visible: !root.video
                    label: "Freeze the screen"
                    hint: "Menus and video hold still while you choose"
                    Toggle { checked: root.ap.captureFreeze; onToggled: c => root.ap.captureFreeze = c }
                }
                Rectangle { visible: !root.video; width: parent.width - 28; x: 14; height: 1; color: Config.Appearance.rule }
                OptionRow {
                    visible: !root.video
                    label: "Open the editor afterwards"
                    Toggle {
                        checked: root.ap.captureEdit === "always"
                        onToggled: c => root.ap.captureEdit = c ? "always" : "ask"
                    }
                }
            }
        }

        // Do it.
        Item {
            width: parent.width
            height: 40
            Rectangle {
                id: textBtn
                visible: !root.video
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: textRow.implicitWidth + 26
                height: 36
                radius: Config.Appearance.rSm
                color: textHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
                border.width: 1
                border.color: Config.Appearance.rule
                Row {
                    id: textRow
                    anchors.centerIn: parent
                    spacing: 7
                    MonoIcon { anchors.verticalCenter: parent.verticalCenter; name: "font"; size: 15; inkColor: Config.Appearance.ink; accentColor: Config.Appearance.accent }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Copy text"
                        font.pixelSize: Config.Appearance.fs(12.5)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink
                    }
                }
                HoverHandler { id: textHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.cap.ocr() }
            }
            Rectangle {
                id: goBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: goRow.implicitWidth + 32
                height: 40
                radius: 20
                color: goTint.value
                ColorSpring { id: goTint; to: goHover.hovered ? Qt.lighter(Config.Appearance.accent, 1.08) : Config.Appearance.accent }
                scale: goPress.value
                Spring { id: goPress; to: goTap.pressed ? 0.95 : 1; response: 260 }
                Row {
                    id: goRow
                    anchors.centerIn: parent
                    spacing: 9
                    // A shutter: a ring with a dot (a square to record).
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 18; height: 18; radius: 9
                        color: "transparent"
                        border.width: 2
                        border.color: Config.Appearance.inkOnAccent
                        Rectangle {
                            anchors.centerIn: parent
                            width: root.video ? 8 : 9; height: width
                            radius: root.video ? 2 : width / 2
                            color: Config.Appearance.inkOnAccent
                        }
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.video ? "Start recording" : (root.ap.captureDelay > 0 ? "Take in " + root.ap.captureDelay + " s" : "Take screenshot")
                        font.pixelSize: Config.Appearance.fs(13)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.inkOnAccent
                    }
                }
                HoverHandler { id: goHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { id: goTap; onTapped: root.go() }
            }
        }

        StyledText {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Enter to take · R W S to choose · Esc to close"
            font.pixelSize: Config.Appearance.fs(11)
            color: Config.Appearance.ink3
        }
    }
}
