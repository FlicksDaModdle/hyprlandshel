import QtQuick
import QtQuick.Effects

// Frosted glass behind a popup.
//
// The honest version of "blur the dropdown". Compositor blur — what the bar,
// dock and panels get — is a property of a *layer surface*, and blurs what is
// behind that surface on the desktop. A dropdown drawn inside the Settings
// window is not its own surface, so there is nothing for Hyprland to blur:
// what is behind it is the window's own rows.
//
// So this blurs those, which is what you would actually expect to see through
// a menu that belongs to a window. It samples the region the popup covers out
// of the item behind it and blurs the copy.
//
// Loaded through a Loader rather than imported directly, so that on a Qt
// without QtQuick.Effects the popup simply isn't frosted instead of the whole
// shell failing to start.
Item {
    id: root

    // What to sample, and which part of it, in that item's own coordinates.
    property Item sourceItem: null
    property rect sampleRect: Qt.rect(0, 0, 0, 0)
    property real radius: 0
    property real amount: 1.0
    // The widest the blur reaches, in pixels, at amount 1.
    property int blurMax: 40

    visible: sourceItem !== null && sampleRect.width > 0

    ShaderEffectSource {
        id: grab
        anchors.fill: parent
        sourceItem: root.sourceItem
        sourceRect: root.sampleRect
        // The popup is a sibling of what it samples, never an ancestor, so
        // there is no feedback loop to guard against.
        recursive: false
        hideSource: false
        live: true
        visible: false
    }

    MultiEffect {
        anchors.fill: parent
        source: grab
        blurEnabled: true
        blur: root.amount
        blurMax: root.blurMax
        // Exactly the popup's size: padding would let the blur spill out
        // past its edges as a faint smear.
        autoPaddingEnabled: false
        // Rounded to match the popup it sits inside, or the blur shows as a
        // square behind the corners.
        maskEnabled: true
        maskSource: mask
    }

    Item {
        id: mask
        anchors.fill: parent
        layer.enabled: true
        visible: false
        Rectangle {
            anchors.fill: parent
            radius: root.radius
            color: "black"
        }
    }
}
