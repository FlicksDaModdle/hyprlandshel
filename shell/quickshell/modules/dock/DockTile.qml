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
    scale: scaleSpring.value
    Spring { id: scaleSpring; to: root.dragging ? 1.08 : 1; response: 260 }
    transform: Translate {
        x: xSpring.value
        y: ySpring.value
    }
    Spring { id: xSpring; to: root.vertical ? 0 : root.slide; response: 270; bounce: 0.7; enabled: root.slideAnimated }
    Spring { id: ySpring; to: root.vertical ? root.slide : 0; response: 270; bounce: 0.7; enabled: root.slideAnimated }

    readonly property bool hovered: hoverHandler.hovered
    readonly property bool accentFilled: highlight && active

    implicitWidth: implicitWidthSpring.value
    implicitHeight: tileSize
    // Matches the label's fade, and eases out of the same curve the rest of
    // the dock uses. Until the surface stopped being resized to the pill on
    // every frame of this, no easing here could have looked smooth.
    Spring { id: implicitWidthSpring; to: root.showLabel ? Math.round(root.tileSize + labelText.implicitWidth + 21) : root.tileSize; response: 310; bounce: 0.6 }

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rTile
        color: tint1.value
        border.width: root.active && !root.accentFilled ? 1 : 0
        border.color: Config.Appearance.seam
        ColorSpring { id: tint1; to: root.accentFilled ? Config.Appearance.accent
                 : (root.active ? Config.Appearance.sel
                 : (root.hovered ? Config.Appearance.hover : "transparent")) }
    }

    // ── launching ─────────────────────────────────────────────────────────
    // An app tile that isn't running bounces when clicked, until its window
    // turns up — or a few hops, if it is slow or never shows one.
    property bool bounceOnLaunch: false
    // The hop is a flick upwards on a spring that pulls the icon back
    // down: it rises, comes back, and settles with a small rebound.
    readonly property real hop: hopSpring.value
    property int hopCount: 0
    Spring { id: hopSpring; to: 0; response: 420 }
    function launchBounce() {
        if (!bounceOnLaunch || running || !Config.Appearance.animated) return;
        hopCount = 0;
        hops.restart();
    }
    Timer {
        id: hops
        interval: Math.max(1, Config.Appearance.anim(640))
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            // Again only while there is still nothing to show for it.
            if (root.running || root.hopCount >= 3) { stop(); return; }
            root.hopCount++;
            hopSpring.velocity = -root.tileSize * hopSpring.omega * 0.95;
            hopSpring.wake();
        }
    }

    Row {
        id: glyphRow
        anchors.centerIn: parent
        spacing: 9
        // Lifts a little under the pointer and gives under a press; the
        // launch hop rides on top.
        transform: Translate { y: root.hop * (root.vertical ? 0 : 1); x: root.hop * (root.vertical ? -1 : 0) }
        scale: scaleSpring2.value
        Spring { id: scaleSpring2; to: tapper.pressed ? 0.86 : (root.hovered && !root.dragging && !root.showLabel ? 1.12 : 1); response: 270 }

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
            opacity: opacitySpring.value
            Spring { id: opacitySpring; to: root.showLabel ? 1 : 0; response: 140; bounce: 0 }
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
                width: widthSpring.value
                height: 2.5
                radius: 1.25
                color: root.active ? Config.Appearance.accent : Config.Appearance.ink3
                Spring { id: widthSpring; to: root.active && index === 0 ? 14 : 6; response: 260 }
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
