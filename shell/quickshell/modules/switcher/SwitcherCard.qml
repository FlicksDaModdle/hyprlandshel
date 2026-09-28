import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// What Alt+Tab draws: one entry per window, the selected one marked, in
// one of three styles —
//
//   thumbnails  a picture of each window with its title above it
//   icons       large app icons, and the selected window's title beneath
//   list        one row per window: icon, title, app
//
// Nothing here decides anything. The entries, the selection and what a
// click means all belong to services/Switcher.qml; this reports hovers and
// clicks and draws what it is told.
Rectangle {
    id: card

    property var entries: []
    property int index: 0
    property string style: "thumbnails"
    // Percent of the default size, from Settings.
    property real sizePct: 100
    property bool showTags: true
    property real us: 1
    property real maxWidth: 1600

    signal hoveredEntry(int i)
    signal picked(int i)
    signal closeRequested(int i)

    function u(px) { return Math.max(1, Math.round(px * card.us)); }
    readonly property real k: Math.max(0.6, Math.min(1.6, card.sizePct / 100))

    readonly property real pad: u(14)
    readonly property real gap: u(8)

    // Tags only earn their space when the entries are not all on one
    // workspace — with Alt+Tab scoped to the current one, every tag would
    // say the same thing.
    readonly property bool tagsWorth: {
        if (!card.showTags || card.entries.length < 2) return false;
        const first = card.entries[0].workspace;
        return card.entries.some(e => e.workspace !== first);
    }
    function tagFor(e) {
        const n = String(e.workspaceName || "");
        if (n.indexOf("special:") === 0) return n.slice(8);
        return e.workspace > 0 ? String(e.workspace) : n;
    }

    // ── geometry per style ────────────────────────────────────────────────
    readonly property real tileW: style === "list" ? u(460 * k)
                                : style === "icons" ? u(88 * k)
                                : u(224 * k)
    readonly property real titleH: u(28)
    readonly property real pictureH: Math.round(card.tileW * 0.6)
    readonly property real tileH: style === "list" ? u(42 * k)
                                : style === "icons" ? card.tileW
                                : card.titleH + card.pictureH + u(8)

    // As many across as fit, then wrap. The list is one column.
    readonly property int perRow: style === "list" ? 1
        : Math.max(1, Math.floor((card.maxWidth - card.pad * 2 + card.gap)
                                 / (card.tileW + card.gap)))
    readonly property int cols: Math.max(1, Math.min(card.entries.length, card.perRow))
    readonly property int rows: Math.max(1, Math.ceil(card.entries.length / card.perRow))
    readonly property real gridW: card.cols * card.tileW + (card.cols - 1) * card.gap
    readonly property real gridH: card.rows * card.tileH + (card.rows - 1) * card.gap
    // The icons style names the selection underneath, since the tiles
    // themselves carry no text.
    readonly property real captionH: style === "icons" ? u(34) : 0

    // Wide enough for the grid, and in the icons style for the title
    // beneath it too, up to a point — two icons should not leave room for
    // only half a title.
    implicitWidth: Math.min(card.maxWidth,
        Math.max(card.gridW,
                 card.style === "icons" ? Math.min(caption.implicitWidth, card.u(560)) : 0)
        + card.pad * 2)
    implicitHeight: card.gridH + card.captionH + card.pad * 2

    radius: Config.Appearance.rDock
    color: Config.Appearance.panel
    border.width: 1
    border.color: Config.Appearance.edge

    Grid {
        id: grid
        x: Math.round((card.width - card.gridW) / 2)
        y: card.pad
        columns: card.cols
        spacing: card.gap

        Repeater {
            model: card.entries

            Item {
                id: tile
                required property var modelData
                required property int index

                readonly property bool selected: tile.index === card.index
                readonly property var toplevel: {
                    if (card.style !== "thumbnails") return null;
                    const t = Services.Compositor.toplevelFor(tile.modelData.address);
                    return t ? t.wayland : null;
                }

                width: card.tileW
                height: card.tileH

                Rectangle {
                    anchors.fill: parent
                    radius: Config.Appearance.rTile
                    color: tile.selected ? Config.Appearance.sel
                         : (tileMouse.containsMouse ? Config.Appearance.hover : "transparent")
                    border.width: tile.selected ? 2 : 0
                    border.color: Config.Appearance.accent
                    Behavior on color { ColorAnimation { duration: Config.Appearance.anim(90) } }
                }

                // ── thumbnails ──────────────────────────────────────────
                Item {
                    anchors.fill: parent
                    visible: card.style === "thumbnails"

                    Row {
                        id: titleRow
                        x: card.u(8)
                        width: parent.width - card.u(16) - (tag.visible ? tag.width + card.u(6) : 0)
                        height: card.titleH
                        spacing: card.u(7)
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: tile.modelData.icon
                            size: card.u(16)
                            monochrome: true
                            inkColor: tile.selected ? Config.Appearance.ink : Config.Appearance.ink2
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: titleRow.width - card.u(16) - titleRow.spacing
                            elide: Text.ElideRight
                            text: tile.modelData.title
                            font.pixelSize: Config.Appearance.fs(Math.max(10, card.u(12)))
                            font.weight: tile.selected ? Font.DemiBold : Font.Medium
                            color: tile.selected ? Config.Appearance.ink : Config.Appearance.ink2
                        }
                    }

                    Item {
                        x: card.u(6)
                        y: card.titleH
                        width: parent.width - card.u(12)
                        height: card.pictureH
                        clip: true

                        Rectangle {
                            anchors.fill: parent
                            radius: Config.Appearance.rSm
                            color: Config.Appearance.hover
                            visible: !(capture.item && capture.item.ready)
                            MonoIcon {
                                anchors.centerIn: parent
                                name: tile.modelData.icon
                                size: Math.min(parent.height * 0.42, card.u(44))
                                inkColor: Config.Appearance.ink3
                                accentColor: Config.Appearance.accent
                            }
                        }
                        Loader {
                            id: capture
                            anchors.fill: parent
                            active: tile.toplevel !== null
                            source: "../dock/WindowThumb.qml"
                            onLoaded: {
                                item.toplevel = Qt.binding(() => tile.toplevel);
                                // One frame for everything, and the
                                // selection kept moving.
                                item.live = Qt.binding(() => tile.selected);
                            }
                        }
                    }
                }

                // ── icons ───────────────────────────────────────────────
                MonoIcon {
                    anchors.centerIn: parent
                    visible: card.style === "icons"
                    name: tile.modelData.icon
                    size: Math.round(card.tileW * 0.5)
                    inkColor: Config.Appearance.ink
                    accentColor: Config.Appearance.accent
                }

                // ── list ────────────────────────────────────────────────
                Row {
                    visible: card.style === "list"
                    x: card.u(12)
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - card.u(24) - (tag.visible ? tag.width + card.u(8) : 0)
                           - (countBadge.visible ? countBadge.width + card.u(8) : 0)
                    spacing: card.u(10)
                    MonoIcon {
                        id: listIcon
                        anchors.verticalCenter: parent.verticalCenter
                        name: tile.modelData.icon
                        size: card.u(20 * card.k)
                        inkColor: Config.Appearance.ink
                        accentColor: Config.Appearance.accent
                    }
                    StyledText {
                        id: listTitle
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(implicitWidth,
                                        parent.width - listIcon.width - parent.spacing * 2 - listApp.width)
                        elide: Text.ElideRight
                        text: tile.modelData.title
                        font.pixelSize: Config.Appearance.fs(Math.max(11, card.u(13 * card.k)))
                        font.weight: tile.selected ? Font.DemiBold : Font.Medium
                    }
                    StyledText {
                        id: listApp
                        anchors.verticalCenter: parent.verticalCenter
                        visible: text !== "" && text !== tile.modelData.title
                        text: tile.modelData.label || ""
                        font.pixelSize: Config.Appearance.fs(Math.max(10, card.u(12 * card.k)))
                        color: Config.Appearance.ink3
                    }
                }

                // ── workspace tag, and the count when grouped ───────────
                Rectangle {
                    id: tag
                    visible: card.tagsWorth
                    anchors.right: parent.right
                    anchors.rightMargin: card.u(6)
                    y: card.style === "thumbnails" ? Math.round((card.titleH - height) / 2)
                     : card.style === "list" ? Math.round((parent.height - height) / 2)
                     : card.u(5)
                    height: card.u(18)
                    width: Math.max(height, tagText.implicitWidth + card.u(10))
                    radius: height / 2
                    color: Config.Appearance.hover
                    border.width: 1
                    border.color: Config.Appearance.edge
                    StyledText {
                        id: tagText
                        anchors.centerIn: parent
                        text: card.tagFor(tile.modelData)
                        font.pixelSize: Config.Appearance.fs(Math.max(9, card.u(10)))
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink2
                    }
                }
                // Bottom left of a picture or an icon; in a list row, on the
                // right beside the tag, where it is not sitting on the icon.
                Rectangle {
                    id: countBadge
                    visible: tile.modelData.count > 1
                    x: card.style === "list"
                       ? parent.width - card.u(6) - width
                         - (tag.visible ? tag.width + card.u(6) : 0)
                       : card.u(6)
                    y: card.style === "list" ? Math.round((parent.height - height) / 2)
                                             : parent.height - height - card.u(6)
                    height: card.u(18)
                    width: countText.implicitWidth + card.u(10)
                    radius: height / 2
                    color: Config.Appearance.accent
                    StyledText {
                        id: countText
                        anchors.centerIn: parent
                        text: tile.modelData.count
                        font.pixelSize: Config.Appearance.fs(Math.max(9, card.u(10)))
                        font.weight: Font.Bold
                        color: Config.Appearance.inkOnAccent
                    }
                }

                MouseArea {
                    id: tileMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                    // Moving, not merely being under the pointer: the card
                    // can open with the pointer already resting on a tile,
                    // and that must not steal the selection from the
                    // keyboard.
                    onPositionChanged: card.hoveredEntry(tile.index)
                    onClicked: mouse => {
                        if (mouse.button === Qt.MiddleButton) card.closeRequested(tile.index);
                        else card.picked(tile.index);
                    }
                }
            }
        }
    }

    // The selected window's title, for the icons style.
    StyledText {
        id: caption
        visible: card.style === "icons"
        x: card.pad
        y: card.pad + card.gridH + card.u(8)
        width: card.width - card.pad * 2
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        text: {
            const e = card.entries[card.index];
            return e ? e.title : "";
        }
        font.pixelSize: Config.Appearance.fs(Math.max(11, card.u(13)))
        font.weight: Font.DemiBold
    }
}
