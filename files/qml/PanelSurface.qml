import QtQuick
import Hyprshell

// The chrome every dropdown panel shares: translucent sheet, hairline edge,
// rounded corners, and the 2px accent seam across the top that the mockup
// puts on the control center, notifications, calendar, power menu and
// launcher alike.
//
// Children go in the default slot and are clipped to the rounded corners.
// The edge and seam are drawn above them, so a panel that runs content to
// the very top (a full-bleed header row) still gets a clean border.
//
// Deliberately no `default property alias`: redeclaring the default property
// would also capture this file's own children and try to reparent them into
// the alias target.
// Quickshell's ClippingRectangle rounds the clip to the corner radius; a
// plain Rectangle with `clip` clips to the bounding box, which would leave
// content poking out of the rounded corners. An OpaqueMask layer gets the
// same result with nothing but QtQuick.
Rectangle {
    id: root
    clip: true

    // Length of the solid accent run before it fades into the seam tint.
    property real seamLead: 40
    property bool showSeam: true

    radius: Appearance.rPanel
    color: Appearance.panel

    Rectangle {
        anchors.fill: parent
        z: 100
        // root, not parent: the mask layer puts children in an
        // internal content Item, which has no radius of its own. Reading
        // parent.radius here gave undefined, so the hairline edge was drawn
        // with square corners around a rounded panel.
        radius: root.radius
        color: "transparent"
        border.width: 1
        border.color: Appearance.edge
        // Purely decorative — must not eat clicks meant for the content.
        enabled: false
    }

    Row {
        id: seam
        visible: root.showSeam
        z: 99
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 2
        enabled: false

        Rectangle {
            width: Math.min(root.seamLead, seam.width)
            height: 2
            color: Appearance.accent
        }
        Rectangle {
            width: Math.max(0, seam.width - Math.min(root.seamLead, seam.width))
            height: 2
            color: Appearance.seam
        }
    }
}
