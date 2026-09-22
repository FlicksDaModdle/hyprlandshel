import QtQuick
import "../../config" as Config

// The chrome every dropdown panel shares: translucent sheet, hairline edge,
// rounded corners, and the 2px accent seam across the top that the mockup
// puts on the control center, notifications, calendar, power menu and
// launcher alike.
//
// Children go in the default slot. The edge and seam are drawn above them,
// so a panel that runs content to the very top (a full-bleed header row)
// still gets a clean border.
//
// This was a Quickshell ClippingRectangle, which clips children to the
// *rounded* corners rather than to the bounding box. It was dropped: that
// type needs Qt 6.7 and a compiled shader, and on a build where the shader
// doesn't load you get its internal mask instead of the panel — a white box
// with a red smear in it, which is exactly what it did. A plain Rectangle
// has no such dependency.
//
// The corner clipping is not missed. Every panel insets its content from the
// edge and none of them paints a background into a corner, so there is
// nothing for the arcs to cut. If one ever does, give that child its own
// topLeftRadius / topRightRadius to match.
Rectangle {
    id: root

    // Length of the solid accent run before it fades into the seam tint.
    property real seamLead: 40
    property bool showSeam: true

    radius: Config.Appearance.rPanel
    color: Config.Appearance.panel
    clip: true

    Rectangle {
        anchors.fill: parent
        z: 100
        // parent used to be the ClippingRectangle's internal content item,
        // which has no radius — so this read undefined and QML warned on
        // every panel at startup.
        radius: root.radius
        color: "transparent"
        border.width: 1
        border.color: Config.Appearance.edge
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
            color: Config.Appearance.accent
        }
        Rectangle {
            width: Math.max(0, seam.width - Math.min(root.seamLead, seam.width))
            height: 2
            color: Config.Appearance.seam
        }
    }
}
