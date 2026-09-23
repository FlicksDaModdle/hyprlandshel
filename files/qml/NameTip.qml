import QtQuick
import Hyprshell

// The whole name, for when the row or tile could only show part of it.
//
// Only appears when the label is actually elided — a tooltip repeating a
// name you can already read in full is noise on every row you pass over.
Item {
    id: tip

    // The label being covered for, and the thing being hovered.
    required property var label
    required property bool hovered
    property string text: ""
    // Which way to open, so it never hangs off the window.
    property bool below: true

    readonly property bool wanted: tip.hovered && tip.label && tip.label.truncated

    visible: bubble.opacity > 0.01
    z: 900

    Timer {
        id: delay
        interval: 420
        onTriggered: bubble.opacity = 1
    }

    onWantedChanged: {
        if (wanted) delay.restart();
        else { delay.stop(); bubble.opacity = 0; }
    }

    Rectangle {
        id: bubble
        opacity: 0
        // Anchored to the label rather than the pointer: it is about the
        // name, and a bubble that chases the cursor is harder to read than
        // one that sits still under the thing it explains.
        x: 0
        y: tip.below ? 0 : -height
        width: Math.min(420, tipText.implicitWidth + 18)
        height: tipText.implicitHeight + 12
        radius: Appearance.rSm
        // Opaque on purpose: this sits over the list, and a translucent
        // bubble with file names showing through it is unreadable.
        color: Appearance.surface
        border.width: 1
        border.color: Appearance.rule

        Behavior on opacity {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }

        StyledText {
            id: tipText
            anchors.centerIn: parent
            width: Math.min(402, implicitWidth)
            text: tip.text
            elide: Text.ElideMiddle
            font.pixelSize: Appearance.fs(12)
            color: Appearance.ink
        }
    }
}
