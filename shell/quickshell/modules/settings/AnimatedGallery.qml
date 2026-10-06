import QtQuick
import "../../config" as Config
import "../common"
import "../background"
import "../background/Palettes.js" as Palettes

// Settings → Wallpaper → Animated: every style as a small live preview to
// pick from, and the palettes as strips of their five colours. Choosing a
// palette while the topographic map is up gives the map those colours.
Column {
    id: root

    readonly property var ap: Config.Appearance
    width: parent ? parent.width : 560
    spacing: 14

    readonly property int cols: width > 620 ? 4 : 3
    readonly property real tileW: (width - (cols - 1) * 10) / cols

    Flow {
        width: root.width
        spacing: 10
        Repeater {
            model: Palettes.styles
            Column {
                id: tile
                required property var modelData
                readonly property bool chosen: root.ap.wallpaperStyle === modelData.key
                spacing: 5
                Rectangle {
                    width: root.tileW
                    height: Math.round(root.tileW * 10 / 16)
                    radius: Config.Appearance.rSm
                    color: "transparent"
                    clip: true
                    border.width: tile.chosen ? 2 : 1
                    border.color: tile.chosen ? Config.Appearance.accent : Config.Appearance.edge
                    Loader {
                        anchors.fill: parent
                        anchors.margins: tile.chosen ? 2 : 1
                        sourceComponent: tile.modelData.key === "topo" ? topoPreview : animPreview
                        Component { id: topoPreview; Topography { preview: true } }
                        Component { id: animPreview; AnimatedWallpaper { preview: true; style: tile.modelData.key } }
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler {
                        onTapped: {
                            root.ap.wallpaperStyle = tile.modelData.key;
                            root.ap.animLastStyle = tile.modelData.key;
                        }
                    }
                }
                StyledText {
                    text: tile.modelData.name
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: tile.chosen ? Font.DemiBold : Font.Normal
                    color: tile.chosen ? Config.Appearance.ink : Config.Appearance.ink2
                }
            }
        }
    }

    StyledText {
        text: "Palette"
        font.pixelSize: Config.Appearance.fs(13)
        font.weight: Font.DemiBold
    }

    Flow {
        width: root.width
        spacing: 8
        Repeater {
            model: [{ key: "theme", name: "Theme" }].concat(Palettes.presets).concat([{ key: "custom", name: "Custom" }])
            Column {
                id: chip
                required property var modelData
                readonly property bool chosen: root.ap.wallpaperStyle === "topo"
                    ? (modelData.key === "theme" ? root.ap.topoGround === "theme" : false)
                    : root.ap.animPalette === modelData.key
                readonly property var strip: modelData.key === "theme"
                    ? [Config.Appearance.tintSpec.b, Config.Appearance.tintSpec.a, Config.Appearance.accent,
                       Config.Appearance.accent, Config.Appearance.ink]
                    : modelData.key === "custom"
                    ? [root.ap.animBg1, root.ap.animBg2, root.ap.animC1, root.ap.animC2, root.ap.animC3]
                    : [modelData.bg1, modelData.bg2, modelData.c1, modelData.c2, modelData.c3]
                spacing: 4
                Rectangle {
                    width: 74; height: 30
                    radius: 8
                    color: "transparent"
                    border.width: chip.chosen ? 2 : 1
                    border.color: chip.chosen ? Config.Appearance.accent : Config.Appearance.edge
                    Row {
                        anchors.fill: parent
                        anchors.margins: chip.chosen ? 3 : 2
                        Repeater {
                            model: chip.strip
                            Rectangle {
                                required property var modelData
                                required property int index
                                width: (parent.width) / 5
                                height: parent.height
                                color: modelData
                                radius: index === 0 || index === 4 ? 5 : 0
                            }
                        }
                    }
                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: root.choose(chip.modelData) }
                }
                StyledText {
                    text: chip.modelData.name
                    font.pixelSize: Config.Appearance.fs(10.5)
                    color: chip.chosen ? Config.Appearance.ink : Config.Appearance.ink3
                }
            }
        }
    }

    function choose(p) {
        ap.animPalette = p.key;
        if (ap.wallpaperStyle !== "topo") return;
        // The map takes the palette as its ground and its lines.
        if (p.key === "theme") { ap.topoGround = "theme"; ap.topoLine = "ink"; return; }
        const c = p.key === "custom"
            ? { bg1: ap.animBg1, bg2: ap.animBg2, c1: ap.animC1 }
            : p;
        ap.topoGround = "custom";
        ap.topoLow = c.bg1;
        ap.topoHigh = c.bg2;
        ap.topoLine = "custom";
        ap.topoLineCustom = c.c1;
    }
}
