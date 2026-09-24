import QtQuick
import "../../config" as Config
import "../icons"

// A square hit target with one glyph in it: the transport buttons on the
// media pill and in the Now Playing panel, and anything else shaped like
// them.
//
// Three looks, which is all the mockup uses: plain (transparent, lights up
// on hover), `active` (a held toggle — accent glyph on the selection
// tint), and `accent` (the primary action, accent fill). A disabled button
// is dimmed and stops taking clicks, rather than being hidden: a transport
// row that loses a button when the player says it cannot skip back jumps
// about under the pointer.
Rectangle {
    id: root

    property real size: 30
    property string icon: ""
    property real iconSize: 14
    property bool accent: false
    property bool active: false
    property color inkColor: Config.Appearance.ink

    signal activated

    width: size
    height: size
    radius: Config.Appearance.rCap
    opacity: enabled ? 1 : 0.35

    color: root.accent
           ? (hover.hovered ? Qt.lighter(Config.Appearance.accent, 1.08)
                            : Config.Appearance.accent)
         : root.active
           ? (hover.hovered ? Config.Appearance.hover : Config.Appearance.sel)
         : hover.hovered ? Config.Appearance.hover
         : "transparent"

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }

    MonoIcon {
        anchors.centerIn: parent
        name: root.icon
        size: root.iconSize
        monochrome: true
        inkColor: root.accent ? Config.Appearance.inkOnAccent
                : root.active ? Config.Appearance.accent
                : root.inkColor
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.activated()
    }
}
