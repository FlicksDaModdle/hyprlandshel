import QtQuick
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"

// Now Playing: the cover, what it is, where it is, and everything you can
// do to it.
//
// The mockup also carries an "Up next" queue below the volume row. MPRIS
// has no queue — TrackList is optional and almost nothing implements it —
// so the panel ends at the volume row rather than showing three invented
// rows that would not be what plays next.
PanelSurface {
    id: root

    readonly property var media: Services.Media

    // The player's own volume when it has one. A good half of what
    // registers on MPRIS (Spotify, most browsers) does not, and a slider
    // that does nothing is worse than one that moves the output it is
    // actually coming out of — so when the player has no volume of its
    // own, this row is the system output's.
    readonly property bool ownVolume: root.media.canVolume
    readonly property real volume: root.ownVolume ? root.media.volume
                                                  : Services.Audio.volume

    implicitWidth: 352
    implicitHeight: col.implicitHeight

    // While this is on screen the service keeps polling the position even
    // if the track is paused, so a seek made somewhere else shows up here.
    // Tracked with a flag of its own rather than off `visible`, so the
    // count cannot go out by one if the panel is torn down while open.
    property bool counted: false
    function setWatch(on) {
        if (on === root.counted) return;
        root.counted = on;
        if (on) Services.Media.watch();
        else Services.Media.unwatch();
    }
    onVisibleChanged: root.setWatch(root.visible)
    Component.onDestruction: root.setWatch(false)

    // Clicks that land on the panel's own background stay on the panel.
    // Declared first so every control below sits on top of it.
    MouseArea {
        anchors.fill: parent
    }

    Column {
        id: col
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top

        // ── header ────────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 35

            StyledText {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: "NOW PLAYING"
                font.pixelSize: Config.Appearance.fs(11)
                font.weight: Font.DemiBold
                font.letterSpacing: 0.88     // 0.08em
                color: Config.Appearance.ink2
            }

            StyledText {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                // Whichever player this is, named by itself.
                text: root.media.identity + " · mpris"
                font.pixelSize: Config.Appearance.fs(10.5)
                font.weight: Font.Normal
                color: Config.Appearance.ink3
                elide: Text.ElideRight
                width: Math.min(implicitWidth, 170)
                horizontalAlignment: Text.AlignRight
            }
        }

        // ── the track ─────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 78

            AlbumArt {
                id: art
                x: 14
                width: 78
                height: 78
                source: root.media.artUrl
            }

            Column {
                anchors.left: art.right
                anchors.leftMargin: 14
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                StyledText {
                    width: parent.width
                    text: root.media.title
                    font.pixelSize: Config.Appearance.fs(16)
                    font.weight: Font.Bold
                    font.letterSpacing: -0.16    // -0.01em
                    lineHeight: 1.15
                    lineHeightMode: Text.ProportionalHeight
                    // Song titles are long and this column is 232px wide,
                    // so it wraps once and then gives up rather than
                    // pushing the artist out of the tile.
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: Config.Appearance.ink
                }
                StyledText {
                    width: parent.width
                    visible: text !== ""
                    text: root.media.artist
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.Medium
                    elide: Text.ElideRight
                    color: Config.Appearance.ink2
                }
                StyledText {
                    width: parent.width
                    visible: text !== ""
                    text: root.media.album
                    font.pixelSize: Config.Appearance.fs(11)
                    font.weight: Font.Normal
                    elide: Text.ElideRight
                    color: Config.Appearance.ink3
                }
            }
        }

        // ── where it is ───────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 45

            // A 4px track with a knob, which FillSlider deliberately has
            // not got: its sliders are levels, and this is a position.
            Item {
                id: seek
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.right: parent.right
                anchors.rightMargin: 14
                y: 14
                height: 14

                readonly property real shown:
                    seekArea.pressed ? seekArea.dragAt : root.media.progress

                Rectangle {
                    id: seekTrack
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    radius: 3
                    color: Config.Appearance.div

                    Rectangle {
                        width: Math.round(parent.width * seek.shown)
                        height: parent.height
                        radius: parent.radius
                        color: Config.Appearance.accent
                    }

                    // The knob's ring is the panel's own colour, so it
                    // reads as sitting above the track rather than on it.
                    Rectangle {
                        x: Math.round(seekTrack.width * seek.shown) - width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 10
                        height: 10
                        radius: 5
                        color: Config.Appearance.accent
                        visible: root.media.length > 0

                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width + 6
                            height: parent.height + 6
                            radius: width / 2
                            z: -1
                            color: Config.Appearance.panel
                        }
                    }
                }

                MouseArea {
                    id: seekArea
                    anchors.fill: parent
                    enabled: root.media.canSeek && root.media.length > 0
                    cursorShape: Qt.PointingHandCursor
                    preventStealing: true

                    property real dragAt: 0

                    function apply(mouse) {
                        dragAt = Math.max(0, Math.min(1, mouse.x / Math.max(1, width)));
                    }

                    onPressed: mouse => apply(mouse)
                    onPositionChanged: mouse => { if (pressed) apply(mouse); }
                    onReleased: root.media.seekTo(dragAt)
                }
            }

            StyledText {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.top: seek.bottom
                anchors.topMargin: 6
                // While dragging, the clock shows where you are dragging
                // to. Reading the old position under a knob you have
                // already moved is how you end up seeking twice.
                text: root.media.clock(seek.shown * root.media.length)
                font.pixelSize: Config.Appearance.fs(10.5)
                font.weight: Font.DemiBold
                color: Config.Appearance.ink2
            }

            StyledText {
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.top: seek.bottom
                anchors.topMargin: 6
                text: root.media.length > 0 ? root.media.clock(root.media.length) : "--:--"
                font.pixelSize: Config.Appearance.fs(10.5)
                font.weight: Font.Medium
                color: Config.Appearance.ink3
            }
        }

        // ── transport ─────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 68

            Row {
                anchors.centerIn: parent
                spacing: 6

                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    size: 30
                    iconSize: 14
                    icon: "shuffle"
                    active: root.media.shuffle
                    enabled: root.media.canShuffle
                    inkColor: Config.Appearance.ink3
                    onActivated: root.media.toggleShuffle()
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    size: 34
                    iconSize: 17
                    icon: "skipBack"
                    enabled: root.media.canPrev
                    onActivated: root.media.previous()
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    size: 44
                    iconSize: 19
                    icon: root.media.playing ? "pause" : "play"
                    accent: true
                    enabled: root.media.canToggle
                    onActivated: root.media.toggle()
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    size: 34
                    iconSize: 17
                    icon: "skipForward"
                    enabled: root.media.canNext
                    onActivated: root.media.next()
                }
                IconButton {
                    anchors.verticalCenter: parent.verticalCenter
                    size: 30
                    iconSize: 14
                    // Looping one track is a different thing from looping
                    // the playlist, and the mockup's single repeat glyph
                    // cannot say which — so the marked one says it.
                    icon: root.media.loop === "track" ? "repeatOne" : "repeat"
                    active: root.media.loop !== "none"
                    enabled: root.media.canLoop
                    inkColor: Config.Appearance.ink3
                    onActivated: root.media.cycleLoop()
                }
            }
        }

        // ── volume ────────────────────────────────────────────────────────
        Item {
            width: parent.width
            height: 40

            Rectangle {
                anchors.top: parent.top
                width: parent.width
                height: 1
                color: Config.Appearance.rule
            }

            MonoIcon {
                id: spk
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 0.5    // the 1px rule above
                name: "speaker"
                size: 15
                monochrome: true
                inkColor: Config.Appearance.ink2
            }

            FillSlider {
                id: vol
                anchors.left: spk.right
                anchors.leftMargin: 10
                anchors.right: pct.left
                anchors.rightMargin: 10
                anchors.verticalCenter: spk.verticalCenter
                trough: 4
                radius: 3
                value: root.volume
                fillColor: Config.Appearance.ink2
                trackColor: Config.Appearance.div
                onMoved: v => {
                    if (root.ownVolume) root.media.setVolume(v);
                    else Services.Audio.setVolume(v);
                }
            }

            StyledText {
                id: pct
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: spk.verticalCenter
                width: 30
                horizontalAlignment: Text.AlignRight
                text: Math.round(vol.shownValue * 100) + "%"
                font.pixelSize: Config.Appearance.fs(10.5)
                font.weight: Font.DemiBold
                color: Config.Appearance.ink3
            }
        }
    }
}
