import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// The card that rises out of a running app's dock tile: one live picture
// per window, each with its title, and a click on one goes to that window.
//
// It lives on the dock's own surface rather than in a popup window of its
// own. The pointer has to travel from the tile up into the card, and on
// two surfaces that trip crosses a gap where neither one has it — the
// dock's hover drops, auto-hide starts counting, and the card closes
// under the pointer on its way there. On one surface there is nothing to
// cross.
Rectangle {
    id: card

    // Client records from Services.Compositor.clients, for this app.
    property var windows: []
    property string iconName: ""
    // Whatever the dock's u() makes of a design pixel on this output.
    property real us: 1
    // The widest the card may be before its pictures shrink, then scroll.
    property real maxWidth: 1200

    signal picked(string address)
    signal closeRequested(string address)

    readonly property bool hovered: cardHover.hovered

    function u(px) { return Math.max(1, Math.round(px * card.us)); }

    readonly property real pad: u(8)
    readonly property real gap: u(6)
    readonly property real titleH: u(28)
    readonly property int count: windows.length

    // 200 wide at most, shrinking to fit the screen, and never below 112 —
    // past that a picture stops saying which window it is, and the row
    // scrolls instead.
    readonly property real thumbW: {
        const n = Math.max(1, card.count);
        const room = (card.maxWidth - card.pad * 2 - card.gap * (n - 1)) / n;
        return Math.round(Math.max(u(112), Math.min(u(200), room)));
    }
    readonly property real imageH: Math.round(card.thumbW * 0.6)
    // What the card needs, fixed by the widest picture it can show, so the
    // dock can set aside room for it without waiting for it to open.
    readonly property real fullHeight: pad * 2 + titleH + u(200) * 0.6 + u(6)

    readonly property real rowWidth:
        card.count * card.thumbW + Math.max(0, card.count - 1) * card.gap

    implicitWidth: Math.min(card.maxWidth, card.rowWidth + card.pad * 2)
    implicitHeight: card.pad * 2 + card.titleH + card.imageH + u(6)

    radius: Config.Appearance.rDock
    color: Config.Appearance.panel
    border.width: 1
    border.color: Config.Appearance.edge

    HoverHandler { id: cardHover }

    Flickable {
        id: strip
        anchors.fill: parent
        anchors.margins: card.pad
        contentWidth: row.width
        contentHeight: height
        interactive: contentWidth > width
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Row {
            id: row
            height: strip.height
            spacing: card.gap

            Repeater {
                model: card.windows

                Item {
                    id: thumb
                    required property var modelData
                    required property int index

                    readonly property bool current:
                        modelData.address === Services.Compositor.activeAddress
                    // A HoverHandler rather than the MouseArea's own
                    // containsMouse: the close button's MouseArea sits on
                    // top and takes the hover, which would drop the
                    // highlight, and the button with it, the moment the
                    // pointer reached the button. Handlers are passive and
                    // keep seeing the pointer underneath.
                    //
                    // And the MouseArea below takes no hover at all, because
                    // one that does can stop hover reaching a handler on its
                    // parent — which on Qt 5 left the close button hidden
                    // for good, so a click aimed at it landed on the picture
                    // and went to the window instead of closing it.
                    readonly property bool hot: thumbHover.hovered
                                                || closeHover.hovered
                    HoverHandler {
                        id: thumbHover
                        cursorShape: Qt.PointingHandCursor
                    }

                    // Looked up rather than carried: the toplevel for a
                    // window can arrive a moment after the window does.
                    readonly property var toplevel: {
                        const t = Services.Compositor.toplevelFor(modelData.address);
                        return t ? t.wayland : null;
                    }

                    width: card.thumbW
                    height: row.height

                    Rectangle {
                        anchors.fill: parent
                        radius: Config.Appearance.rTile
                        color: thumb.hot ? Config.Appearance.sel
                             : (thumb.current ? Config.Appearance.hover : "transparent")
                        border.width: thumb.current ? 1 : 0
                        border.color: Config.Appearance.seam
                        Behavior on color { ColorAnimation { duration: Config.Appearance.anim(110) } }
                    }

                    // ── title ───────────────────────────────────────────
                    Row {
                        id: titleRow
                        x: card.u(7)
                        width: parent.width - card.u(7) - closeBtn.width - card.u(8)
                        height: card.titleH
                        spacing: card.u(6)

                        // One colour at this size: the glyph's accent
                        // stroke, drawn at fifteen pixels, reads as a
                        // coloured blob rather than a detail.
                        MonoIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: card.iconName
                            size: card.u(15)
                            monochrome: true
                            inkColor: thumb.current ? Config.Appearance.ink
                                                    : Config.Appearance.ink2
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: titleRow.width - card.u(15) - titleRow.spacing
                            elide: Text.ElideRight
                            text: thumb.modelData.title || thumb.modelData.cls || "Window"
                            font.pixelSize: Config.Appearance.fs(Math.max(10, card.u(12)))
                            font.weight: thumb.current ? Font.DemiBold : Font.Medium
                            color: thumb.current ? Config.Appearance.ink : Config.Appearance.ink2
                        }
                    }

                    // ── picture ─────────────────────────────────────────
                    Item {
                        id: imageBox
                        x: card.u(5)
                        y: card.titleH
                        width: parent.width - card.u(10)
                        height: card.imageH
                        clip: true

                        // Underneath the picture, and all there is when
                        // there is no picture: a Quickshell without
                        // screencopy, a window the compositor has not
                        // matched to a toplevel yet, or the frame before
                        // the first capture lands.
                        Rectangle {
                            anchors.fill: parent
                            radius: Config.Appearance.rSm
                            color: Config.Appearance.hover
                            visible: !(capture.item && capture.item.ready)

                            MonoIcon {
                                anchors.centerIn: parent
                                name: card.iconName
                                size: Math.min(parent.height * 0.42, card.u(40))
                                inkColor: Config.Appearance.ink3
                                accentColor: Config.Appearance.accent
                            }
                        }

                        Loader {
                            id: capture
                            anchors.fill: parent
                            active: thumb.toplevel !== null
                            source: "WindowThumb.qml"
                            onLoaded: item.toplevel = Qt.binding(() => thumb.toplevel)
                        }
                    }

                    MouseArea {
                        id: thumbMouse
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        // Middle click closes, as it does on the tile.
                        onClicked: mouse => {
                            if (mouse.button === Qt.MiddleButton)
                                card.closeRequested(thumb.modelData.address);
                            else
                                card.picked(thumb.modelData.address);
                        }
                    }

                    // ── close ───────────────────────────────────────────
                    // Declared after the MouseArea so it sits above it and
                    // takes its own click.
                    Rectangle {
                        id: closeBtn
                        anchors.right: parent.right
                        anchors.rightMargin: card.u(5)
                        y: Math.round((card.titleH - height) / 2)
                        width: card.u(20)
                        height: width
                        radius: Config.Appearance.rSm
                        visible: thumb.hot
                        color: closeHover.hovered ? Config.Appearance.accent : "transparent"

                        // Hover through a handler here too. Nothing in this
                        // card takes hover through a MouseArea, because one
                        // that did could hide the pointer from the card's
                        // own HoverHandler — and the card closes a moment
                        // after it thinks the pointer has left, which would
                        // be underneath a pointer resting on this button.
                        HoverHandler {
                            id: closeHover
                            cursorShape: Qt.PointingHandCursor
                        }

                        MonoIcon {
                            anchors.centerIn: parent
                            name: "x"
                            size: card.u(13)
                            monochrome: true
                            inkColor: closeHover.hovered ? Config.Appearance.inkOnAccent
                                                               : Config.Appearance.ink2
                        }

                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent
                            onClicked: card.closeRequested(thumb.modelData.address)
                        }
                    }
                }
            }
        }
    }
}
