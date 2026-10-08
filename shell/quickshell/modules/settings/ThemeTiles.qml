import QtQuick
import "../../config" as Config
import "../common"

// Light, Dark and Auto as pictures of themselves rather than three words:
// a window in each, in the accent, and Auto split down the middle. The one
// in use has the accent ring round it.
Item {
    id: root

    readonly property var ap: Config.Appearance
    property string value: ap.theme
    signal picked(string value)

    implicitHeight: 112

    readonly property var tiles: [
        { value: "light", label: "Light" },
        { value: "dark",  label: "Dark" },
        { value: "auto",  label: "Auto", note: "Dark after sunset" }
    ]
    // The two palettes, fixed, so each tile shows its own theme whichever
    // is in use.
    readonly property var light: ({ ground: "#f3f2f2", sheet: "#fbfafa", ink: "#201e1d", ink3: "#9a9696", rule: "#e2e0e0" })
    readonly property var dark:  ({ ground: "#201e1d", sheet: "#2b2928", ink: "#f8f4f4", ink3: "#77736f", rule: "#3a3837" })

    Row {
        spacing: 12
        Repeater {
            model: root.tiles
            Column {
                id: tile
                required property var modelData
                readonly property bool chosen: root.value === modelData.value
                spacing: 7

                Rectangle {
                    width: 132; height: 82
                    radius: root.ap.rSm + 2
                    color: "transparent"
                    border.width: tile.chosen ? 2 : 1
                    border.color: tile.chosen ? root.ap.accent : root.ap.rule

                    Item {
                        anchors.fill: parent
                        anchors.margins: 4
                        clip: true
                        // Light on the left, dark on the right; Auto shows
                        // both halves, the others one of them throughout.
                        Repeater {
                            model: tile.modelData.value === "auto" ? [root.light, root.dark]
                                 : [tile.modelData.value === "dark" ? root.dark : root.light]
                            Rectangle {
                                id: half
                                required property var modelData
                                required property int index
                                readonly property int halves: tile.modelData.value === "auto" ? 2 : 1
                                x: index * parent.width / halves
                                width: parent.width / halves
                                height: parent.height
                                radius: root.ap.rSm - 1
                                color: modelData.ground
                                clip: true
                                // A window, offset so it reads across the split.
                                Rectangle {
                                    x: 12 - half.x; y: 12
                                    width: 104; height: 70
                                    radius: 5
                                    color: half.modelData.sheet
                                    border.width: 1
                                    border.color: half.modelData.rule
                                    Rectangle { x: 7; y: 7; width: 3; height: 7; radius: 1.5; color: root.ap.accent }
                                    Rectangle { x: 14; y: 9; width: 32; height: 3; radius: 1.5; color: half.modelData.ink }
                                    Column {
                                        x: 8; y: 22; spacing: 5
                                        Repeater {
                                            model: [0.75, 0.5, 0.62]
                                            Rectangle {
                                                required property var modelData
                                                width: 86 * modelData; height: 3; radius: 1.5
                                                color: half.modelData.ink3
                                            }
                                        }
                                    }
                                    Rectangle { x: 8; y: 46; width: 26; height: 9; radius: 3; color: root.ap.accent }
                                }
                            }
                        }
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.picked(tile.modelData.value) }
                }
                Row {
                    spacing: 6
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 14; height: 14; radius: 7
                        color: "transparent"
                        border.width: tile.chosen ? 4.5 : 1.5
                        border.color: tile.chosen ? root.ap.accent : root.ap.ink3
                    }
                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: tile.modelData.label
                        font.pixelSize: root.ap.fs(12.5)
                        font.weight: tile.chosen ? Font.DemiBold : Font.Medium
                        color: tile.chosen ? root.ap.ink : root.ap.ink2
                    }
                }
            }
        }
    }
}
