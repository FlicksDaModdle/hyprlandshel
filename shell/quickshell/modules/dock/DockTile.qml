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

    readonly property bool hovered: hoverHandler.hovered
    readonly property bool accentFilled: highlight && active

    implicitWidth: showLabel ? Math.round(tileSize + labelText.implicitWidth + 21) : tileSize
    implicitHeight: tileSize
    Behavior on implicitWidth { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

    Rectangle {
        anchors.fill: parent
        radius: Config.Appearance.rTile
        color: root.accentFilled ? Config.Appearance.accent
             : (root.active ? Config.Appearance.sel
             : (root.hovered ? Config.Appearance.hover : "transparent"))
        border.width: root.active && !root.accentFilled ? 1 : 0
        border.color: Config.Appearance.seam
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    Row {
        anchors.centerIn: parent
        spacing: 9

        MonoIcon {
            anchors.verticalCenter: parent.verticalCenter
            name: root.iconName
            size: root.iconSize
            // The source design never dims dock glyphs — active and hover
            // change the tile's fill and the pips, not the glyph itself.
            inkColor: root.accentFilled ? Config.Appearance.onAccent : Config.Appearance.ink
            accentColor: root.accentFilled ? Config.Appearance.onAccent : Config.Appearance.accent
        }

        StyledText {
            id: labelText
            anchors.verticalCenter: parent.verticalCenter
            visible: root.showLabel
            text: root.label
            font.pixelSize: 11.5
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
                Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            }
        }
    }

    // ── tooltip ───────────────────────────────────────────────────────────
    Rectangle {
        id: tooltip
        z: 50
        visible: root.showTooltip && root.hovered && !root.showLabel
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
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: root.subtitle !== ""
                text: root.subtitle
                font.pixelSize: 10
                color: Config.Appearance.ink3
            }
        }
    }

    HoverHandler {
        id: hoverHandler
        cursorShape: Qt.PointingHandCursor
    }
    TapHandler {
        acceptedButtons: Qt.LeftButton
        onTapped: root.activated()
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
