import QtQuick
import "../../config" as Config
import "../common"
import "../icons"

// One dock tile: a pinned app, an unpinned-but-running app, or a plain
// utility button (Start, overview, Settings, show desktop) depending on
// which properties the caller sets.
//
// Running windows show as pips under the glyph — the focused app's first pip
// stretches into a bar, which is how the mockup marks focus.
Item {
    id: root

    property string label: ""
    property string iconName: ""
    property string subtitle: ""
    property bool running: false
    property bool active: false
    property bool showLabel: false
    property bool showTooltip: true
    property bool showPips: true
    // Start's tile keeps an accent fill while its panel is open, rather than
    // the subtle selected tint the app tiles use.
    property bool highlight: false
    property int windowCount: 0
    property real tileSize: 42
    property real iconSize: 21

    // Tooltips flip to the side when the dock is on the left edge.
    property int tooltipEdge: Qt.TopEdge
    property int tooltipAlign: Qt.AlignHCenter

    signal activated()
    signal secondaryActivated()
    signal middleActivated()

    // ── dragging, to rearrange the dock ───────────────────────────────────
    // A tile only reports the drag; the dock decides where it would land
    // and slides the others aside through `slide`. Along the dock's own
    // axis only, which is the only direction a tile can go.
    property bool draggable: false
    property bool vertical: false
    property real slide: 0
    property bool slideAnimated: true
    readonly property bool dragging: dragHandler.active
    signal dragStarted()
    signal dragMoved(real along)
    signal dragFinished()

    z: dragging ? 10 : 0
    // Lifted a little while carried, so it reads as picked up.
    scale: dragging ? 1.08 : 1
    Behavior on scale { Spring { ms: 300 } }
    transform: Translate {
        x: root.vertical ? 0 : root.slide
        y: root.vertical ? root.slide : 0
        Behavior on x { enabled: root.slideAnimated; Spring { ms: 320; bounce: 0.7 } }
        Behavior on y { enabled: root.slideAnimated; Spring { ms: 320; bounce: 0.7 } }
    }

    readonly property bool hovered: hoverHandler.hovered
    readonly property bool accentFilled: highlight && active

    implicitWidth: showLabel ? Math.round(tileSize + labelText.implicitWidth + 21) : tileSize
    implicitHeight: tileSize
    // Matches the label's fade, and eases out of the same curve the rest of
    // the dock uses. Until the surface stopped being resized to the pill on
    // every frame of this, no easing here could have looked smooth.
    Behavior on implicitWidth { Spring { ms: 360; bounce: 0.6 } }

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rTile
        color: root.accentFilled ? Config.Appearance.accent
             : (root.active ? Config.Appearance.sel
             : (root.hovered ? Config.Appearance.hover : "transparent"))
        border.width: root.active && !root.accentFilled ? 1 : 0
        border.color: Config.Appearance.seam
        Behavior on color { ColorAnimation { duration: Config.Appearance.anim(120) } }
    }

    // ── launching ─────────────────────────────────────────────────────────
    // An app tile that isn't running bounces when clicked, until its window
    // turns up — or a few hops, if it is slow or never shows one.
    property bool bounceOnLaunch: false
    property real hop: 0
    property int hopCount: 0
    function launchBounce() {
        if (!bounceOnLaunch || running || !Config.Appearance.animated) return;
        hopCount = 0;
        hops.restart();
    }
    SequentialAnimation {
        id: hops
        loops: Animation.Infinite
        onStopped: root.hop = 0
        NumberAnimation { target: root; property: "hop"; to: -Math.round(root.tileSize * 0.38); duration: Config.Appearance.anim(260); easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "hop"; to: 0; duration: Config.Appearance.anim(300); easing.type: Easing.OutBounce }
        PauseAnimation { duration: Config.Appearance.anim(120) }
        // Landed: again only while there is still nothing to show for it.
        ScriptAction { script: { root.hopCount++; if (root.running || root.hopCount >= 3) hops.stop(); } }
    }

    Row {
        id: glyphRow
        anchors.centerIn: parent
        spacing: 9
        // Lifts a little under the pointer and gives under a press; the
        // launch hop rides on top.
        transform: Translate { y: root.hop * (root.vertical ? 0 : 1); x: root.hop * (root.vertical ? -1 : 0) }
        scale: tapper.pressed ? 0.86 : (root.hovered && !root.dragging && !root.showLabel ? 1.12 : 1)
        Behavior on scale { Spring { ms: 320; bounce: 1.2 } }

        MonoIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: root.iconName
            size: root.iconSize
            // The source design never dims dock glyphs — active and hover
            // change the tile's fill and the pips, not the glyph itself.
            inkColor: root.accentFilled ? Config.Appearance.inkOnAccent : Config.Appearance.ink
            accentColor: root.accentFilled ? Config.Appearance.inkOnAccent : Config.Appearance.accent
        }

        StyledText {
            id: labelText
            anchors.verticalCenter: parent.verticalCenter
            // Fades on the way out rather than being cut off by the tile
            // closing over it. Kept in the layout until the fade is done,
            // or the Row would reflow the glyph sideways halfway through.
            visible: root.showLabel || opacity > 0.01
            opacity: root.showLabel ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: Config.Appearance.anim(90) } }
            text: root.label
            font.pixelSize: Config.Appearance.fs(Config.Appearance.dockLabelSize)
            font.weight: Font.DemiBold
        }
    }

    // Running-window pips
    Row {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 3
        spacing: 2
        visible: root.showPips && root.running

        Repeater {
            model: Math.min(root.windowCount, 3)

            Rectangle {
                required property int index
                width: root.active && index === 0 ? 14 : 6
                height: 2.5
                radius: 1.25
                color: root.active ? Config.Appearance.accent : Config.Appearance.ink3
                Behavior on width { Spring { ms: 300 } }
            }
        }
    }

    // ── tooltip ───────────────────────────────────────────────────────────
    Rectangle {
        id: tooltip
        z: 50
        visible: root.showTooltip && root.hovered && !root.showLabel && !root.dragging
        radius: Config.Appearance.rSm
        color: Config.Appearance.sheet
        border.width: 1
        border.color: Config.Appearance.edge
        height: 30
        width: tooltipRow.implicitWidth + 22

        anchors.bottom: root.tooltipEdge === Qt.TopEdge ? parent.top : undefined
        anchors.bottomMargin: 12
        anchors.left: root.tooltipEdge === Qt.RightEdge
                      ? parent.right
                      : (root.tooltipAlign === Qt.AlignLeft ? parent.left : undefined)
        anchors.leftMargin: root.tooltipEdge === Qt.RightEdge ? 12 : 0
        anchors.horizontalCenter: (root.tooltipEdge === Qt.TopEdge
                                   && root.tooltipAlign === Qt.AlignHCenter)
                                  ? parent.horizontalCenter : undefined
        anchors.verticalCenter: root.tooltipEdge === Qt.RightEdge
                                ? parent.verticalCenter : undefined

        Row {
            id: tooltipRow
            anchors.centerIn: parent
            spacing: 9

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.label
                font.pixelSize: Config.Appearance.fs(Config.Appearance.dockLabelSize - 1)
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.subtitle !== ""
                text: root.subtitle
                font.pixelSize: Config.Appearance.fs(Config.Appearance.dockLabelSize - 2)
                color: Config.Appearance.ink3
            }
        }
    }

    HoverHandler {
        id: hoverHandler
        cursorShape: root.dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor
    }
    // Takes over from the left-button TapHandler below only once the
    // pointer has moved past the platform's drag distance, so a click is
    // still a click.
    DragHandler {
        id: dragHandler
        enabled: root.draggable
        target: null
        acceptedButtons: Qt.LeftButton
        onActiveChanged: active ? root.dragStarted() : root.dragFinished()
        onActiveTranslationChanged:
            if (active) root.dragMoved(root.vertical ? activeTranslation.y : activeTranslation.x)
    }
    TapHandler {
        id: tapper
        acceptedButtons: Qt.LeftButton
        onTapped: { root.launchBounce(); root.activated(); }
    }
    TapHandler {
        acceptedButtons: Qt.RightButton
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.secondaryActivated()
    }
    TapHandler {
        acceptedButtons: Qt.MiddleButton
        gesturePolicy: TapHandler.ReleaseWithinBounds
        onTapped: root.middleActivated()
    }
}
