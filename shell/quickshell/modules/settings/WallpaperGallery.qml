import QtQuick
import Quickshell.Widgets
import "../../config" as Config
import "../common"

// The live wallpapers you have, as their Workshop pictures. Click one to
// put it on the desktop; the one on it is ringed in the accent.
//
// Full-width rather than a control at the right of a row: these are
// pictures, and a strip of thumbnails the width of a slider says nothing.
Item {
    id: gallery

    // [{ dir, id, title, preview, type }]
    property var items: []
    property string value: ""
    signal picked(string dir)

    readonly property int gap: 12
    // As many columns of at least 150px as fit.
    readonly property int columns: Math.max(2, Math.floor((width + gap) / (150 + gap)))
    readonly property real tileW: (width - gap * (columns - 1)) / columns
    readonly property real thumbH: Math.round(tileW * 9 / 16)

    implicitHeight: flow.implicitHeight

    readonly property var typeNames: ({ scene: "Scene", video: "Video", web: "Web" })

    Flow {
        id: flow
        width: parent.width
        spacing: gallery.gap

        Repeater {
            model: gallery.items

            Item {
                id: tile
                required property var modelData
                readonly property bool current: modelData.dir === gallery.value
                readonly property bool gif: /\.gif$/i.test(modelData.preview)

                width: gallery.tileW
                height: gallery.thumbH + 44

                ClippingRectangle {
                    id: thumb
                    width: parent.width
                    height: gallery.thumbH
                    radius: Config.Appearance.rSm
                    color: Config.Appearance.surface

                    // The Workshop preview. Animated ones play while the
                    // pointer is on them and hold their first frame
                    // otherwise — a grid of them all moving at once is
                    // not something to read.
                    Loader {
                        anchors.fill: parent
                        active: tile.modelData.preview !== ""
                        sourceComponent: tile.gif ? animated : still
                    }
                    Component {
                        id: still
                        Image {
                            source: "file://" + tile.modelData.preview
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 360
                        }
                    }
                    Component {
                        id: animated
                        AnimatedImage {
                            source: "file://" + tile.modelData.preview
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            playing: hover.hovered
                        }
                    }
                }

                // Drawn over the picture rather than as its border, so the
                // ring is not cut by the clipping.
                Rectangle {
                    anchors.fill: thumb
                    radius: thumb.radius
                    color: "transparent"
                    border.width: tile.current ? 2 : 1
                    border.color: tile.current ? Config.Appearance.accent
                                 : hover.hovered ? Config.Appearance.div
                                 : Config.Appearance.rule
                }

                StyledText {
                    id: title
                    anchors.top: thumb.bottom
                    anchors.topMargin: 7
                    width: parent.width
                    elide: Text.ElideRight
                    text: tile.modelData.title
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: tile.current ? Font.DemiBold : Font.Medium
                    color: Config.Appearance.ink
                }
                StyledText {
                    anchors.top: title.bottom
                    anchors.topMargin: 1
                    width: parent.width
                    elide: Text.ElideRight
                    text: (tile.current ? "On the desktop · " : "")
                          + (gallery.typeNames[tile.modelData.type] || tile.modelData.type)
                    font.pixelSize: Config.Appearance.fs(11)
                    color: tile.current ? Config.Appearance.accent : Config.Appearance.ink3
                }

                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: gallery.picked(tile.modelData.dir) }
            }
        }
    }
}
