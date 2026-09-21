import QtQuick
import "../../config" as Config

// A pill-shaped hit target in the top bar: 26px tall, rounded, hover tint,
// and a "held open" state for the ones that own a dropdown. Content goes in
// the default slot and is laid out in a centered row.
//
// This file's own children are assigned to `data` explicitly. Redeclaring
// the default property as an alias applies inside the defining file too, so
// left implicit they would be reparented into the Row they're meant to
// contain.
Item {
    id: root

    default property alias contentData: row.data

    property real spacing: 8
    property real padding: 10
    property bool open: false               // this button's panel is showing
    property bool accentWhenOpen: false     // power button inverts instead of tinting
    property bool interactive: true

    signal activated()
    signal secondaryActivated()
    signal scrolled(int delta)

    readonly property bool hovered: hover.hovered

    implicitWidth: Math.max(26, row.implicitWidth + padding * 2)
    implicitHeight: 26

    data: [
        Rectangle {
            anchors.fill: root
            radius: Config.Appearance.rCap
            color: root.open
                   ? (root.accentWhenOpen ? Config.Appearance.accent : Config.Appearance.sel)
                   : (root.hovered && root.interactive ? Config.Appearance.hover : "transparent")
            Behavior on color { ColorAnimation { duration: 120 } }
        },

        Row {
            id: row
            anchors.centerIn: root
            spacing: root.spacing
        },

        HoverHandler {
            id: hover
            enabled: root.interactive
            cursorShape: Qt.PointingHandCursor
        },

        TapHandler {
            enabled: root.interactive
            acceptedButtons: Qt.LeftButton
            onTapped: root.activated()
        },

        TapHandler {
            enabled: root.interactive
            acceptedButtons: Qt.RightButton
            gesturePolicy: TapHandler.ReleaseWithinBounds
            onTapped: root.secondaryActivated()
        },

        WheelHandler {
            enabled: root.interactive
            onWheel: event => root.scrolled(event.angleDelta.y > 0 ? 1 : -1)
        }
    ]
}
