import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../common"

// Settings → Display → HDR calibration's test pattern, on the display being
// set up: grey steps just above black, and a white for reference. The black
// level is right when the 0% square is black and the 1% one can just be
// told from it; set too high, they all look grey (washed out). A click or
// Esc closes it.
PanelWindow {
    id: pat

    required property var target       // a Quickshell screen
    signal done()

    screen: target
    color: "black"
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quickshell:hdrpattern"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property var steps: [0, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2]

    Item {
        anchors.fill: parent
        focus: true
        Keys.onEscapePressed: pat.done()

        Column {
            anchors.centerIn: parent
            spacing: 34

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 18
                Repeater {
                    model: pat.steps
                    Column {
                        required property real modelData
                        spacing: 10
                        Rectangle {
                            width: 110
                            height: 110
                            // Linear light to sRGB-encoded grey, so 1% is 1% of white.
                            readonly property real g: modelData <= 0.0031308 ? modelData * 12.92
                                                      : 1.055 * Math.pow(modelData, 1 / 2.4) - 0.055
                            color: Qt.rgba(g, g, g, 1)
                            border.width: modelData === 0 ? 1 : 0
                            border.color: Qt.rgba(0.08, 0.08, 0.08, 1)
                        }
                        StyledText {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: (modelData * 100) + "%"
                            font.pixelSize: 13
                            color: Qt.rgba(0.45, 0.45, 0.45, 1)
                        }
                    }
                }
                Column {
                    spacing: 10
                    Rectangle { width: 110; height: 110; color: "white" }
                    StyledText {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "white"
                        font.pixelSize: 13
                        color: Qt.rgba(0.45, 0.45, 0.45, 1)
                    }
                }
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                horizontalAlignment: Text.AlignHCenter
                text: "0% should be black, and 1% just visible beside it. All grey: the black level is too high.\n"
                      + "Change it in Settings → Display → HDR calibration. Click or press Esc to close."
                font.pixelSize: 14
                color: Qt.rgba(0.55, 0.55, 0.55, 1)
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: pat.done()
    }
}
