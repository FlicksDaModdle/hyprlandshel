import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// What is playing, in the middle of the bar: artwork, title and artist, a
// four-bar equaliser, transport buttons, and the track's progress riding
// the pill's lower edge. Clicking anywhere that isn't a button opens the
// Now Playing panel.
//
// Only mapped while something is actually registered on MPRIS — an empty
// pill in the middle of the bar is worse than a gap, and the bar's two
// clusters are laid out as though this were not here, so nothing shifts
// when it appears.
Item {
    id: root

    // The bar's per-output scale, as the rest of the bar uses it.
    property real barScale: 1
    function u(px) { return Math.max(1, Math.round(px * root.barScale)); }

    // How much of the bar is free between the left and right clusters.
    // The pill gives up its text first and then itself.
    property real room: 400

    readonly property var media: Services.Media
    readonly property bool playing: media.playing

    // Everything that is not the title column — artwork, equaliser,
    // divider, three buttons and the gaps between them — comes to 142,
    // plus the 9 before the column itself. 168 is the mockup's cap on the
    // column; between the two the pill narrows, below it the column goes
    // and the pill carries on without it, and below `minPill` there is no
    // room for even that.
    readonly property real textRoom:
        Math.max(0, Math.min(root.u(168), root.room - root.u(151)))
    readonly property bool showText: root.textRoom >= root.u(70)
    readonly property real minPill: root.u(148)

    visible: root.media.available && root.room >= root.minPill
    implicitWidth: pill.width
    implicitHeight: root.u(30)

    Rectangle {
        id: pill
        height: parent.height
        width: content.width + root.u(8)
        radius: Config.Appearance.rCap
        color: Config.UiState.mediaOpen ? Config.Appearance.hover
             : hover.hovered ? Config.Appearance.hover : "transparent"

        HoverHandler { id: hover }

        // The whole pill is the panel's button; the controls below sit on
        // top of it and take their own clicks.
        MouseArea {
            anchors.fill: parent
            onClicked: Config.UiState.toggleMedia()
        }

        Row {
            id: content
            x: root.u(4)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.u(9)

            AlbumArt {
                anchors.verticalCenter: parent.verticalCenter
                width: root.u(22)
                height: root.u(22)
                radius: Config.Appearance.rSm
                source: root.media.artUrl
            }

            // Title over artist. Given a fixed width rather than an elided
            // implicit one so the pill's width follows the space the bar
            // has, not the length of the song.
            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: root.textRoom
                visible: root.showText
                spacing: root.u(3)

                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    text: root.media.title
                    font.pixelSize: Config.Appearance.fs(root.u(11.5))
                    font.weight: Font.DemiBold
                    color: Config.Appearance.ink
                }
                StyledText {
                    width: parent.width
                    elide: Text.ElideRight
                    visible: text !== ""
                    text: root.media.artist
                    font.pixelSize: Config.Appearance.fs(root.u(10))
                    font.weight: Font.Medium
                    color: Config.Appearance.ink3
                }
            }

            // Four bars rising and falling out of step with each other.
            // The second one is the accent, as in the mockup.
            Row {
                id: eq
                anchors.verticalCenter: parent.verticalCenter
                height: root.u(12)
                spacing: root.u(2)

                Repeater {
                    model: 4

                    Item {
                        id: cell
                        required property int index
                        width: root.u(2)
                        height: eq.height

                        // Animated as a level rather than as a height so
                        // that stopping the animation leaves a binding
                        // behind: a `NumberAnimation on height` that has
                        // been stopped keeps whatever height it had when
                        // it stopped, which is a different bar every time
                        // you pause.
                        property real level: 0.28

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: Math.max(1, Math.round(eq.height * cell.level))
                            radius: width / 2
                            color: cell.index === 1 ? Config.Appearance.accent
                                                    : Config.Appearance.ink3
                        }

                        // The mockup's `eq` keyframes: 0.28 → 1 → 0.28,
                        // a little slower for each bar along, each
                        // starting a beat after the one before it. The
                        // stagger is outside the loop because a delay in
                        // CSS happens once, before the first pass.
                        SequentialAnimation {
                            running: root.playing && root.visible
                                     && Config.Appearance.animated
                            onStopped: cell.level = 0.28

                            PauseAnimation {
                                duration: Config.Appearance.anim(cell.index * 90)
                            }

                            SequentialAnimation {
                                loops: Animation.Infinite
                                NumberAnimation {
                                    target: cell; property: "level"; to: 1
                                    duration: Config.Appearance.anim(380 + cell.index * 65)
                                    easing.type: Easing.InOutSine
                                }
                                NumberAnimation {
                                    target: cell; property: "level"; to: 0.28
                                    duration: Config.Appearance.anim(380 + cell.index * 65)
                                    easing.type: Easing.InOutSine
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: root.u(16)
                color: Config.Appearance.div
            }

            Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.u(1)

                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    size: root.u(22)
                    icon: "skipBack"
                    iconSize: root.u(13)
                    enabled: root.media.canPrev
                    onActivated: root.media.previous()
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    size: root.u(24)
                    icon: root.playing ? "pause" : "play"
                    iconSize: root.u(13)
                    accent: true
                    enabled: root.media.canToggle
                    onActivated: root.media.toggle()
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    size: root.u(22)
                    icon: "skipForward"
                    iconSize: root.u(13)
                    enabled: root.media.canNext
                    onActivated: root.media.next()
                }
            }
        }

        // The seek line, on the pill's bottom edge. Two pixels tall, so
        // the hit area is stretched either side of it — a 2px target is
        // not one you can hit.
        Item {
            id: seek
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: root.u(4)
            anchors.rightMargin: root.u(4)
            // The mockup hangs this 5px below the pill, which on a 30px
            // pill in a 40px bar puts the line exactly on the bar's own
            // bottom edge. The rest of the box is above it, reaching back
            // into the pill, so there is something to grab.
            height: track.height + root.u(5)
            y: parent.height + root.u(5) - height
            visible: root.media.length > 0

            Rectangle {
                id: track
                anchors.bottom: parent.bottom
                width: parent.width
                height: 2
                radius: 1
                color: Config.Appearance.div

                Rectangle {
                    width: Math.round(parent.width * seekArea.shown)
                    height: parent.height
                    radius: parent.radius
                    color: Config.Appearance.accent
                }
            }

            MouseArea {
                id: seekArea
                anchors.fill: parent
                enabled: root.media.canSeek
                cursorShape: Qt.PointingHandCursor
                preventStealing: true

                // The live position, unless a drag is in progress — then
                // it is where the pointer is, so the line follows the
                // finger rather than waiting for the player to answer.
                property real dragAt: 0
                readonly property real shown:
                    pressed ? dragAt : root.media.progress

                function apply(mouse) {
                    dragAt = Math.max(0, Math.min(1, mouse.x / Math.max(1, width)));
                }

                onPressed: mouse => apply(mouse)
                onPositionChanged: mouse => { if (pressed) apply(mouse); }
                onReleased: root.media.seekTo(dragAt)
            }
        }
    }
}
