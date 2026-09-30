import QtQuick
import Quickshell.Widgets
import "../../config" as Config
import "../common"

// The live wallpapers you have, as a still from each, small enough that a
// library of them fits without a long scroll. Click one to put it on the
// desktop; the one on it is ringed in the accent and ticked.
//
// With a `state` (an object the pane owns, so what was typed survives the
// rows being rebuilt) there is a search field above it.
//
// Full-width rather than a control at the right of a row: these are
// pictures, and a strip of thumbnails the width of a slider says nothing.
Item {
    id: gallery

    // [{ dir, title, preview, badge? }]
    property var items: []
    property string value: ""
    // Picking several rather than the one on screen: `selection` is
    // ticked, and a click adds or takes away.
    property bool multi: false
    property var selection: []
    // { search }, or null for no bar.
    property QtObject state: null
    signal picked(string dir)

    readonly property string query: state ? state.search.trim().toLowerCase() : ""
    readonly property var shown: gallery.items.filter(w =>
        gallery.query === "" || w.title.toLowerCase().indexOf(gallery.query) >= 0)

    readonly property int gap: 10
    // As many columns of at least 118px as fit.
    readonly property int columns: Math.max(3, Math.floor((width + gap) / (118 + gap)))
    readonly property real tileW: (width - gap * (columns - 1)) / columns
    readonly property real thumbH: Math.round(tileW * 9 / 16)

    implicitHeight: column.implicitHeight

    Column {
        id: column
        width: parent.width
        spacing: 12

        // ── search, once there are enough to need one ─────────────────────
        Row {
            visible: !!gallery.state && gallery.items.length > 8
            width: parent.width

            Rectangle {
                id: searchBox
                width: parent.width
                height: 32
                radius: Config.Appearance.rSm
                color: Config.Appearance.ground
                border.width: search.activeFocus ? 2 : 1
                border.color: search.activeFocus ? Config.Appearance.accent : Config.Appearance.rule

                TextInput {
                    id: search
                    anchors.fill: parent
                    anchors.leftMargin: 11
                    anchors.rightMargin: 30
                    verticalAlignment: Text.AlignVCenter
                    clip: true
                    color: Config.Appearance.ink
                    font.family: Config.Appearance.fontFamily
                    font.pixelSize: Config.Appearance.fs(12)
                    selectByMouse: true
                    text: gallery.state ? gallery.state.search : ""
                    onTextEdited: if (gallery.state) gallery.state.search = text
                    Keys.onEscapePressed: { text = ""; if (gallery.state) gallery.state.search = ""; }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text === ""
                        text: "Search " + gallery.items.length
                              + (gallery.items.length === 1 ? " wallpaper" : " wallpapers")
                        font.pixelSize: Config.Appearance.fs(12)
                        color: Config.Appearance.ink3
                    }
                }

                // Clear.
                StyledText {
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    visible: search.text !== ""
                    text: "×"
                    font.pixelSize: Config.Appearance.fs(16)
                    color: clearHover.hovered ? Config.Appearance.ink : Config.Appearance.ink3
                    HoverHandler { id: clearHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: { search.text = ""; if (gallery.state) gallery.state.search = ""; }
                    }
                }
            }

        }

        // ── the pictures ──────────────────────────────────────────────────
        Flow {
            id: flow
            width: parent.width
            spacing: gallery.gap

            Repeater {
                model: gallery.shown

                Item {
                    id: tile
                    required property var modelData
                    readonly property bool current: gallery.multi
                        ? gallery.selection.indexOf(modelData.dir) >= 0
                        : modelData.dir === gallery.value
                    readonly property bool gif: /\.gif$/i.test(modelData.preview)

                    width: gallery.tileW
                    height: gallery.thumbH + 24

                    ClippingRectangle {
                        id: thumb
                        width: parent.width
                        height: gallery.thumbH
                        radius: Config.Appearance.rSm
                        color: Config.Appearance.surface

                        // Nothing to show yet — its still is being made, or
                        // there is no ffmpeg to make one.
                        StyledText {
                            anchors.centerIn: parent
                            visible: tile.modelData.preview === ""
                            text: "▶"
                            font.pixelSize: Config.Appearance.fs(18)
                            color: Config.Appearance.ink3
                        }

                        // Its picture. Animated ones play while the
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
                                sourceSize.width: 280
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

                    // Drawn over the picture rather than as its border, so
                    // the ring is not cut by the clipping.
                    Rectangle {
                        anchors.fill: thumb
                        radius: thumb.radius
                        color: "transparent"
                        border.width: tile.current ? 2 : 1
                        border.color: tile.current ? Config.Appearance.accent
                                     : hover.hovered ? Config.Appearance.div
                                     : Config.Appearance.rule
                    }

                    // A word on the picture, when the item has one.
                    Rectangle {
                        visible: !!tile.modelData.badge
                        anchors.left: thumb.left
                        anchors.bottom: thumb.bottom
                        anchors.margins: 5
                        width: badge.implicitWidth + 10
                        height: 16
                        radius: 8
                        color: Qt.rgba(0, 0, 0, 0.55)
                        StyledText {
                            id: badge
                            anchors.centerIn: parent
                            text: tile.modelData.badge || ""
                            font.pixelSize: Config.Appearance.fs(10)
                            font.weight: Font.DemiBold
                            color: "white"
                        }
                    }

                    // The one on the desktop, or in the playlist.
                    Rectangle {
                        visible: tile.current
                        anchors.right: thumb.right
                        anchors.top: thumb.top
                        anchors.margins: 5
                        width: 18
                        height: 18
                        radius: 9
                        color: Config.Appearance.accent
                        StyledText {
                            anchors.centerIn: parent
                            text: "✓"
                            font.pixelSize: Config.Appearance.fs(11)
                            font.weight: Font.Bold
                            color: Config.Appearance.inkOnAccent
                        }
                    }

                    StyledText {
                        anchors.top: thumb.bottom
                        anchors.topMargin: 5
                        width: parent.width
                        elide: Text.ElideRight
                        text: tile.modelData.title
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: tile.current ? Font.DemiBold : Font.Medium
                        color: tile.current ? Config.Appearance.accent : Config.Appearance.ink
                    }

                    HoverHandler {
                        id: hover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        onTapped: gallery.picked(tile.modelData.dir)
                    }
                }
            }
        }

        // Nothing matched what was typed.
        StyledText {
            visible: gallery.shown.length === 0 && gallery.items.length > 0
            width: parent.width
            text: "Nothing called “" + gallery.query + "”"
            font.pixelSize: Config.Appearance.fs(12)
            color: Config.Appearance.ink3
        }
    }
}
