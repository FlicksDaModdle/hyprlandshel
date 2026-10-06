import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The capture toolbar (Print): a picture or a video, of a region, a
// window or the screen, with a delay and the pointer, sound for a video,
// and Text to read a region's words onto the clipboard
// (services/Capture.qml does the work).
PanelSurface {
    id: root

    readonly property var cap: Services.Capture
    readonly property var ap: Config.Appearance
    property bool video: false
    property string mode: "region"

    implicitWidth: row.implicitWidth + 28
    implicitHeight: col.implicitHeight + 24
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
    }

    function go() {
        if (video) cap.record(mode === "window" ? "region" : mode, ap.captureAudio);
        else cap.shot(mode);
    }

    component Tool: Rectangle {
        id: tool
        property string icon: ""
        property string label: ""
        property bool on: false
        property bool small: false
        signal clicked
        width: small ? Math.max(56, toolCol.implicitWidth + 16) : 74
        height: small ? 30 : 60
        radius: Config.Appearance.rSm
        color: tool.on ? Config.Appearance.accent : (toolHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
        Column {
            id: toolCol
            anchors.centerIn: parent
            spacing: 4
            visible: !tool.small
            MonoIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: tool.icon
                size: 18
                inkColor: tool.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink
                accentColor: tool.on ? Config.Appearance.inkOnAccent : Config.Appearance.accent
            }
            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: tool.label
                font.pixelSize: Config.Appearance.fs(11)
                font.weight: Font.DemiBold
                color: tool.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink
            }
        }
        StyledText {
            anchors.centerIn: parent
            visible: tool.small
            text: tool.label
            font.pixelSize: Config.Appearance.fs(11.5)
            font.weight: Font.DemiBold
            color: tool.on ? Config.Appearance.inkOnAccent : Config.Appearance.ink
        }
        HoverHandler { id: toolHover; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: tool.clicked() }
    }

    Column {
        id: col
        x: 14; y: 12
        spacing: 10

        Row {
            id: row
            spacing: 6

            // Picture or video.
            Column {
                spacing: 4
                Tool { small: true; label: "Picture"; on: !root.video; onClicked: root.video = false }
                Tool { small: true; label: "Video"; on: root.video; onClicked: root.video = true }
            }
            Rectangle { width: 1; height: 64; color: Config.Appearance.rule }

            Tool { icon: "lasso"; label: "Region"; on: root.mode === "region"; onClicked: root.mode = "region" }
            Tool {
                icon: "square"; label: "Window"
                visible: !root.video
                on: root.mode === "window"
                onClicked: root.mode = "window"
            }
            Tool { icon: "monitor"; label: "Screen"; on: root.mode === "screen"; onClicked: root.mode = "screen" }
            Tool {
                icon: "grid"; label: "All"
                visible: !root.video
                on: root.mode === "all"
                onClicked: root.mode = "all"
            }
            Rectangle { width: 1; height: 64; color: Config.Appearance.rule }

            // The big one.
            Rectangle {
                width: 64; height: 60
                radius: Config.Appearance.rSm
                color: goHover.hovered ? Qt.darker(Config.Appearance.accent, 1.08) : Config.Appearance.accent
                Column {
                    anchors.centerIn: parent
                    spacing: 4
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 18; height: 18; radius: 9
                        color: "transparent"
                        border.width: 2
                        border.color: Config.Appearance.inkOnAccent
                        Rectangle {
                            anchors.centerIn: parent
                            width: root.video ? 8 : 10; height: width
                            radius: root.video ? 2 : 5
                            color: Config.Appearance.inkOnAccent
                        }
                    }
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.video ? "Record" : "Capture"
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.inkOnAccent
                    }
                }
                HoverHandler { id: goHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.go() }
            }

            Tool {
                icon: "font"; label: "Text"
                visible: !root.video
                onClicked: root.cap.ocr()
            }
        }

        // Options, small.
        Row {
            spacing: 6
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.video ? "Sound" : "Delay"
                font.pixelSize: Config.Appearance.fs(11)
                color: Config.Appearance.ink3
                rightPadding: 2
            }
            Repeater {
                model: root.video
                    ? [["None", "none"], ["Desktop", "desktop"], ["Microphone", "mic"]]
                    : [["Off", 0], ["3 s", 3], ["5 s", 5], ["10 s", 10]]
                Tool {
                    required property var modelData
                    small: true
                    label: modelData[0]
                    on: root.video ? root.ap.captureAudio === modelData[1] : root.ap.captureDelay === modelData[1]
                    onClicked: root.video ? root.ap.captureAudio = modelData[1] : root.ap.captureDelay = modelData[1]
                }
            }
            Item { width: 8; height: 1 }
            Tool {
                visible: !root.video
                small: true
                label: "Pointer"
                on: root.ap.capturePointer
                onClicked: root.ap.capturePointer = !root.ap.capturePointer
            }
            Tool {
                visible: !root.video
                small: true
                label: "Edit after"
                on: root.ap.captureEdit === "always"
                onClicked: root.ap.captureEdit = root.ap.captureEdit === "always" ? "ask" : "always"
            }
        }
    }
}
