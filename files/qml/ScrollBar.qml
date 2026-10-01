import QtQuick
import Hyprshell

// A scroll bar for a Flickable: a slim thumb along the right edge that
// widens under the pointer, can be dragged, and jumps to where the track
// is clicked. Only there when there is something to scroll.
//
// Drawn rather than taken from QtQuick.Controls, which would bring a style
// of its own into a window that has none.
Item {
    id: bar

    required property Flickable target

    readonly property real range: Math.max(0, bar.target.contentHeight - bar.target.height)
    readonly property bool needed: bar.range > 1
    readonly property bool hot: area.containsMouse || area.dragging

    visible: bar.needed
    width: 14

    Rectangle {
        id: thumb
        anchors.right: parent.right
        anchors.rightMargin: 3
        width: bar.hot ? 8 : 5
        radius: width / 2
        height: Math.max(32, bar.height * bar.target.height / Math.max(1, bar.target.contentHeight))
        y: bar.range > 0
           ? (bar.height - height) * Math.max(0, Math.min(1, (bar.target.contentY - bar.target.originY) / bar.range))
           : 0
        color: area.dragging ? Appearance.accent : bar.hot ? Appearance.ink2 : Appearance.ink3
        opacity: bar.hot || bar.target.moving ? 0.9 : 0.55

        Behavior on width { NumberAnimation { duration: 120 } }
        Behavior on opacity { NumberAnimation { duration: 150 } }
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: true

        property bool dragging: false
        property real grab: 0

        function scrollTo(thumbY) {
            const travel = Math.max(1, bar.height - thumb.height);
            const f = Math.max(0, Math.min(1, thumbY / travel));
            bar.target.contentY = bar.target.originY + f * bar.range;
        }

        onPressed: mouse => {
            bar.target.cancelFlick();
            // On the thumb: hold it where it was taken. On the track: the
            // thumb comes to the pointer, and is held by its middle.
            area.grab = (mouse.y >= thumb.y && mouse.y <= thumb.y + thumb.height)
                        ? mouse.y - thumb.y : thumb.height / 2;
            area.dragging = true;
            area.scrollTo(mouse.y - area.grab);
        }
        onPositionChanged: mouse => { if (area.dragging) area.scrollTo(mouse.y - area.grab); }
        onReleased: area.dragging = false
        onCanceled: area.dragging = false
        // The wheel over the bar scrolls what it belongs to.
        onWheel: wheel => {
            const step = wheel.pixelDelta.y !== 0 ? wheel.pixelDelta.y : wheel.angleDelta.y / 120 * 80;
            bar.target.contentY = Math.max(bar.target.originY,
                                           Math.min(bar.target.originY + bar.range, bar.target.contentY - step));
        }
    }
}
